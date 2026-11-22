import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api.dart';
import 'platform/factory.dart';
import 'config_transform.dart';
import 'settings.dart';

enum KernelState { stopped, starting, running, failed }

class KernelStatus {
  final KernelState state;
  final String? version;
  final String? error;
  final int? pid;
  final String controllerAddr;
  final String secret;

  const KernelStatus({
    required this.state,
    this.version,
    this.error,
    this.pid,
    this.controllerAddr = '127.0.0.1:9090',
    this.secret = '',
  });

  bool get ready => state == KernelState.running;

  KernelStatus copyWith({KernelState? state, String? version, String? error, int? pid}) => KernelStatus(
        state: state ?? this.state,
        version: version ?? this.version,
        error: error,
        pid: pid ?? this.pid,
        controllerAddr: controllerAddr,
        secret: secret,
      );
}

/// Owns the mihomo process: spawn, wait-until-ready, stream logs, stop.
///
/// User-space only for now — TUN needs a privileged helper, which is the next
/// milestone. Everything here works unprivileged, which also makes it safe to
/// develop against without touching the host network.
class KernelManager {
  final String binary;

  String get binaryPath => binary;
  final Directory dataDir;
  final void Function(String line) onLog;
  final AranPlatform platform;

  Process? _proc;
  KernelStatus _status = const KernelStatus(state: KernelState.stopped);
  int _mixedPort = 0;
  int _httpPort = 0;
  int _socksPort = 0;
  int _controllerPort = 9090;
  String _secret = '';
  String? _activeConfigPath;

  /// Groups the rules actually reference — these are the ones Aran drives.
  List<String> managedGroups = const [];
  String fallbackGroup = '';
  List<String> prunedGroups = const [];
  String mainGroup = '';

  KernelManager({
    required this.binary,
    required this.dataDir,
    required this.onLog,
    AranPlatform? platform,
  }) : platform = platform ?? createPlatform();

  KernelStatus get status => _status;
  int get mixedPort => _mixedPort;
  int get httpPort => _httpPort;
  int get socksPort => _socksPort;

  /// Ports actually bound by the running kernel (what the UI must show).
  Map<String, int> get activePorts => switch (_status.state) {
        KernelState.running => {
            if (_mixedPort > 0) 'mixed': _mixedPort,
            if (_httpPort > 0) 'http': _httpPort,
            if (_socksPort > 0) 'socks': _socksPort,
          },
        _ => const {},
      };
  int get controllerPort => _controllerPort;
  String get secret => _secret;
  bool get isRunning => _proc != null;

  /// Port 0 => let the OS choose a free port.
  Future<int> _freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = s.port;
    await s.close();
    return p;
  }

  static const _geoAssets = [
    'Country.mmdb', 'country.mmdb', 'geosite.dat', 'geoip.dat', 'geoip.metadb', 'ASN.mmdb', 'GeoSite.dat', 'GeoIP.dat',
  ];

  /// mihomo refuses to route without geo assets, and a bare data dir has none.
  /// Link whatever we can find on the host instead of re-downloading them.
  Future<void> _linkGeoAssets(List<String> searchDirs) async {
    for (final name in _geoAssets) {
      final target = Link('${dataDir.path}/$name');
      final existing = File('${dataDir.path}/$name');
      if (await existing.exists()) continue;
      for (final dir in searchDirs) {
        final candidate = File('$dir/$name');
        if (await candidate.exists()) {
          try {
            if (await target.exists()) await target.delete();
            await target.create(candidate.path);
            onLog('geo 资源：$name ← $dir');
          } catch (e) {
            onLog('[err] 无法链接 $name：$e');
          }
          break;
        }
      }
    }
  }

  /// Build a runtime config from a profile and start the kernel on it.
  Future<KernelStatus> start(
    String profileConfigText, {
    AranSettings settings = const AranSettings(),
    List<String> extraArgs = const [],
    List<String> assetDirs = const [],
    String? smartdnsAddress,
  }) async {
    await stop();
    _status = _status.copyWith(state: KernelState.starting, error: null);
    try {
      final split = settings.portMode == 'split';
      _mixedPort = 0;
      _httpPort = 0;
      _socksPort = 0;
      if (split) {
        _httpPort = settings.autoPort ? await _freePort() : settings.httpPort;
        _socksPort = settings.autoPort ? await _freePort() : settings.socksPort;
      } else {
        _mixedPort = settings.autoPort ? await _freePort() : settings.mixedPort;
      }
      _controllerPort = await _freePort();
      _secret = base64Url.encode(List<int>.generate(18, (i) => (DateTime.now().microsecond + i * 37) & 0xff))
          .replaceAll('=', '');

      final transform = ConfigTransform(
        rulesMode: settings.rulesMode,
        pruneUnreferencedGroups: settings.pruneUnreferencedGroups,
        fallbackGroupName: settings.watchdogEnabled ? 'Aran-Auto' : null,
        overrides: settings.scalarOverrides(
          controllerPort: _controllerPort,
          secret: _secret,
          mixedPort: split ? null : _mixedPort,
          httpPort: split ? _httpPort : null,
          socksPort: split ? _socksPort : null,
        ),
        dropKeys: split ? const {'mixed-port'} : const {'port', 'socks-port'},
        patches: {
          'dns': settings.dnsPatch(smartdnsAddress: smartdnsAddress),
          'sniffer': settings.snifferPatch(),
          // Keep the chosen node / fake-ip mappings across reloads and restarts.
          'profile': const SectionPatch(scalars: {
            'store-selected': 'true',
            'store-fake-ip': 'true',
          }),
        },
        sections: {
          // Emitted only when TUN is enabled (needs CAP_NET_ADMIN).
          'tun': settings.tunBlock().isEmpty ? '' : settings.tunBlock(),
        },
      );
      final result = transform.apply(profileConfigText);
      managedGroups = result.managedGroups;
      prunedGroups = result.prunedGroups;
      mainGroup = managedGroups.isNotEmpty ? managedGroups.first : '';
      fallbackGroup = settings.watchdogEnabled ? 'Aran-Auto' : '';

      await dataDir.create(recursive: true);
      await _linkGeoAssets(assetDirs);
      // mihomo always loads <data-dir>/config.yaml; anything else is ignored.
      final runtimeFile = File('${dataDir.path}/config.yaml');
      await runtimeFile.writeAsString(result.config);
      _activeConfigPath = runtimeFile.path;

      managedGroups = result.managedGroups;
      prunedGroups = result.prunedGroups;
      mainGroup = managedGroups.isNotEmpty ? managedGroups.first : '';
      if (prunedGroups.isNotEmpty) {
        onLog('已删除 ${prunedGroups.length} 个无规则引用的分组：${prunedGroups.join('、')}');
      }
      if (managedGroups.isNotEmpty) {
        onLog('Aran 接管分组（${managedGroups.length}）：${managedGroups.join('、')}');
      }
      if (settings.rulesMode != 'keep') {
        onLog('分流模式：${settings.rulesMode}（已重新生成 rules）');
      }
      if (result.droppedProxies.isNotEmpty) {
        onLog('已剔除 ${result.droppedProxies.length} 个占位节点：${result.droppedProxies.take(3).join('、')}…');
      }
      if (result.convertedGroups.isNotEmpty) {
        onLog('已将 ${result.convertedGroups.length} 个自动策略组改写为由 Aran 接管：'
            '${result.convertedGroups.join('、')}');
      }

      await _reapStale();
      final proc = await Process.start(binary, ['-d', dataDir.path, ...extraArgs]);
      _proc = proc;
      await File('${dataDir.path}/kernel.pid').writeAsString('${proc.pid}');

      final logSink = File('${dataDir.path}/kernel.log').openWrite(mode: FileMode.append);
      void emit(String l) {
        logSink.writeln(l);
        onLog(l);
      }

      proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(emit);
      proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => emit('[err] $l'));
      unawaited(proc.exitCode.then((_) => logSink.close()));
      unawaited(proc.exitCode.then((code) {
        if (_proc == proc) {
          _proc = null;
          _status = _status.copyWith(
            state: code == 0 ? KernelState.stopped : KernelState.failed,
            error: code == 0 ? null : '内核退出（code $code）',
          );
          onLog('内核已退出，code=$code');
        }
      }));

      final api = MihomoApi(addr: '127.0.0.1:$_controllerPort', secret: _secret);
      final deadline = DateTime.now().add(const Duration(seconds: 12));
      String? version;
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        try {
          version = await api.version();
          break;
        } catch (_) {
          if (_proc == null) break;
        }
      }
      api.close();

      if (version == null) {
        _status = _status.copyWith(state: KernelState.failed, error: '内核启动后 12 秒内控制器未就绪');
        await stop();
        return _status;
      }

      _status = KernelStatus(
        state: KernelState.running,
        version: version,
        pid: proc.pid,
        controllerAddr: '127.0.0.1:$_controllerPort',
        secret: _secret,
      );
      return _status;
    } catch (e) {
      _status = _status.copyWith(state: KernelState.failed, error: '$e');
      await stop();
      return _status;
    }
  }

  /// A previous run may have been killed without a clean shutdown (SIGKILL,
  /// compositor crash), leaving an orphan kernel holding its ports.
  Future<void> _reapStale() async {
    final f = File('${dataDir.path}/kernel.pid');
    if (!await f.exists()) return;
    final pid = int.tryParse((await f.readAsString()).trim());
    await f.delete();
    if (pid == null) return;
    if (await _isOurs(pid)) {
      onLog('清理上一次遗留的内核进程 pid=$pid');
      Process.killPid(pid, ProcessSignal.sigterm);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      Process.killPid(pid, ProcessSignal.sigkill);
    }
  }

  Future<bool> _isOurs(int pid) => platform.isOurProcess(pid, dataDir.path);

  /// Regenerate the runtime config (same ports, same controller secret) and ask
  /// the running kernel to reload it. Falls back to a full restart.
  Future<bool> hotReload(
    String profileConfigText, {
    required AranSettings settings,
    String? smartdnsAddress,
    List<String> assetDirs = const [],
  }) async {
    if (_status.state != KernelState.running) return false;
    try {
      final transform = ConfigTransform(
        rulesMode: settings.rulesMode,
        pruneUnreferencedGroups: settings.pruneUnreferencedGroups,
        fallbackGroupName: settings.watchdogEnabled ? 'Aran-Auto' : null,
        overrides: settings.scalarOverrides(
          controllerPort: _controllerPort,
          secret: _secret,
          mixedPort: _mixedPort > 0 ? _mixedPort : null,
          httpPort: _httpPort > 0 ? _httpPort : null,
          socksPort: _socksPort > 0 ? _socksPort : null,
        ),
        dropKeys: _mixedPort > 0 ? const {'port', 'socks-port'} : const {'mixed-port'},
        patches: {
          'dns': settings.dnsPatch(smartdnsAddress: smartdnsAddress),
          'sniffer': settings.snifferPatch(),
          // Keep the chosen node / fake-ip mappings across reloads and restarts.
          'profile': const SectionPatch(scalars: {
            'store-selected': 'true',
            'store-fake-ip': 'true',
          }),
        },
        sections: {'tun': settings.tunBlock().isEmpty ? '' : settings.tunBlock()},
      );
      final result = transform.apply(profileConfigText);
      managedGroups = result.managedGroups;
      prunedGroups = result.prunedGroups;
      mainGroup = managedGroups.isNotEmpty ? managedGroups.first : '';
      fallbackGroup = settings.watchdogEnabled ? 'Aran-Auto' : '';

      final runtimeFile = File('${dataDir.path}/config.yaml');
      await runtimeFile.writeAsString(result.config);

      final api = MihomoApi(addr: '127.0.0.1:$_controllerPort', secret: _secret);
      try {
        await api.reloadConfig(runtimeFile.path);
      } finally {
        api.close();
      }
      onLog('配置已热重载（内核未重启，pid=$pid）');
      return true;
    } catch (e) {
      onLog('[err] 热重载失败，回退为重启内核：$e');
      return false;
    }
  }

  int? get pid => _status.pid;

  /// Service mode: write the runtime config for a fixed endpoint set, without
  /// spawning anything. systemd owns the process; the GUI only talks to the API.
  Future<String> writeServiceConfig(
    String profileConfigText, {
    required AranSettings settings,
    required int port,
    required int controllerPort,
    required String secret,
    String? smartdnsAddress,
    List<String> assetDirs = const [],
  }) async {
    final split = settings.portMode == 'split';
    _mixedPort = split ? 0 : port;
    _httpPort = split ? port : 0;
    _socksPort = split ? port + 1 : 0;
    _controllerPort = controllerPort;
    _secret = secret;

    final transform = ConfigTransform(
      rulesMode: settings.rulesMode,
      pruneUnreferencedGroups: settings.pruneUnreferencedGroups,
      fallbackGroupName: settings.watchdogEnabled ? 'Aran-Auto' : null,
      overrides: settings.scalarOverrides(
        controllerPort: controllerPort,
        secret: secret,
        mixedPort: split ? null : port,
        httpPort: split ? port : null,
        socksPort: split ? port + 1 : null,
      ),
      dropKeys: split ? const {'mixed-port'} : const {'port', 'socks-port'},
      patches: {
        'dns': settings.dnsPatch(smartdnsAddress: smartdnsAddress),
        'sniffer': settings.snifferPatch(),
        'profile': const SectionPatch(scalars: {'store-selected': 'true', 'store-fake-ip': 'true'}),
      },
      sections: {'tun': settings.tunBlock().isEmpty ? '' : settings.tunBlock()},
    );
    final result = transform.apply(profileConfigText);

    await dataDir.create(recursive: true);
    await _linkGeoAssets(assetDirs);
    final runtimeFile = File('${dataDir.path}/config.yaml');
    await runtimeFile.writeAsString(result.config);
    managedGroups = result.managedGroups;
    prunedGroups = result.prunedGroups;
    mainGroup = managedGroups.isNotEmpty ? managedGroups.first : '';
    fallbackGroup = settings.watchdogEnabled ? 'Aran-Auto' : '';
    return runtimeFile.path;
  }

  Future<void> stop() async {
    final proc = _proc;
    _proc = null;
    if (proc != null) {
      proc.kill(ProcessSignal.sigterm);
      await proc.exitCode.timeout(const Duration(seconds: 3), onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        return -1;
      });
    }
    _status = const KernelStatus(state: KernelState.stopped);
    try {
      final f = File('${dataDir.path}/kernel.pid');
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  String? get activeConfigPath => _activeConfigPath;
}
