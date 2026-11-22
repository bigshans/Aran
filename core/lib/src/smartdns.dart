import 'dart:async';

import 'bundled.dart';
import 'dart:convert';
import 'dart:io';

/// Optional SmartDNS sidecar.
///
/// SmartDNS is not a library: it is a separate daemon. Aran runs it as a child
/// process listening on loopback, and points mihomo's `nameserver` at it. That
/// way mihomo keeps doing fake-ip / routing, while upstream selection + caching
/// (SmartDNS' job: pick the fastest IP across many upstreams) happens inside it.
///
/// If the binary is missing the module simply stays off; nothing else breaks.
class SmartDns {
  /// Discovered from PATH + the usual bin dirs; never a fixed absolute list.
  static List<String> get candidates {
    final home = Platform.environment['HOME'] ?? '.';
    final exe = Platform.isWindows ? 'smartdns.exe' : 'smartdns';
    final sep = Platform.isWindows ? ';' : ':';
    final dirs = <String>{
      ...(Platform.environment['PATH'] ?? '').split(sep).where((d) => d.isNotEmpty),
      '$_localData/bin',
      '$home/.local/bin',
      '/usr/bin',
      '/usr/local/bin',
      '/usr/sbin',
    };
    return [for (final d in dirs) '$d/$exe'];
  }

  static String get _localData {
    final local = Platform.environment['LOCALAPPDATA'];
    if (local != null) return '$local\\Aran';
    // Windows 上 HOME 通常未定义，回退到 './local' 会变成相对路径并创建失败
    if (Platform.isWindows) {
      final profile = Platform.environment['USERPROFILE'] ??
          Platform.environment['APPDATA'] ??
          'C:\\Users\\Public';
      return '$profile\\AppData\\Local\\Aran';
    }
    final home = Platform.environment['HOME'] ?? '.';
    return '$home/.local/share/aran';
  }

  final Directory dataDir;
  final void Function(String line) onLog;

  Process? _proc;
  int port = 0;
  bool _running = false;

  SmartDns({required this.dataDir, required this.onLog});

  bool get running => _running;

  /// Explicit binary from settings (empty = auto).
  String explicitPath = '';
  String get address => '127.0.0.1:$port';

  static String? _extracted;

  /// Resolution order: explicit setting → embedded/downloaded in the data dir →
  /// anything found on PATH.
  static Future<String?> resolveBinary(Directory dataDir, {String? explicit}) async {
    final custom = explicit?.trim() ?? '';
    if (custom.isNotEmpty && File(custom).existsSync()) {
      _extracted = custom;
      return custom;
    }
    final bundled = await Bundled.extract('smartdns', dataDir) ?? Bundled.existing('smartdns', dataDir);
    if (bundled != null) {
      _extracted = bundled;
      return bundled;
    }
    return findBinary();
  }

  /// Candidates that actually exist on this machine (for the settings dropdown).
  static List<String> discover() {
    // Dedupe symlinks: /bin → /usr/bin, /usr/sbin → /usr/bin.
    final byReal = <String, String>{};
    for (final c in candidates) {
      if (!File(c).existsSync()) continue;
      String real;
      try {
        real = File(c).resolveSymbolicLinksSync();
      } catch (_) {
        real = c;
      }
      final existing = byReal[real];
      if (existing == null || c.length < existing.length || existing.startsWith('/bin/')) {
        byReal[real] = c.startsWith('/bin/') ? existing ?? c : c;
      }
    }
    final list = byReal.values.toList()..sort();
    return list;
  }

  static Future<String?> probeVersion(String path) async {
    try {
      final r = await Process.run(path, ['-v']);
      final out = '${r.stdout}${r.stderr}'.trim();
      if (r.exitCode != 0 || out.isEmpty) return null;
      return out.split('\n').first.trim();
    } catch (_) {
      return null;
    }
  }

  static String? findBinary() {
    if (_extracted != null && File(_extracted!).existsSync()) return _extracted;
    for (final p in candidates) {
      if (File(p).existsSync()) return p;
    }
    final path = Platform.environment['PATH'] ?? '';
    for (final dir in path.split(':')) {
      final f = File('$dir/smartdns');
      if (f.existsSync()) return f.path;
    }
    return null;
  }

  static bool get available => _extracted != null || findBinary() != null;

  /// smartdns 有两套实现，CLI 不同：
  ///   pymumu/smartdns (C):  smartdns -f -c conf -x pid   （POSIX 为主）
  ///   mokeyish/smartdns-rs: smartdns run -c conf          （Rust，有 Windows 构建）
  /// 用 `run --help` 探测：只有 Rust 版有 run 子命令。
  static final Map<String, bool> _rsCache = {};

  static Future<bool> isRustVariant(String bin) async {
    final hit = _rsCache[bin];
    if (hit != null) return hit;
    var rs = false;
    try {
      final r = await Process.run(bin, ['run', '--help']);
      rs = r.exitCode == 0 && '${r.stdout}${r.stderr}'.toLowerCase().contains('run');
    } catch (_) {}
    _rsCache[bin] = rs;
    return rs;
  }

  String buildConfig({
    required List<String> upstreams,
    required int cacheSize,
    required bool ipv4Only,
    required bool speedCheck,
  }) {
    final servers = upstreams.where((e) => e.trim().isNotEmpty).toList();
    return [
      // Loopback only. `bind` is UDP, `bind-tcp` keeps a TCP fallback alive for
      // mihomo (and for the readiness probe, which must speak UDP).
      'bind 127.0.0.1:$port',
      'bind-tcp 127.0.0.1:$port',
      'cache-size $cacheSize',
      'cache-persist yes',
      'prefetch-domain yes',
      'serve-expired yes',
      'serve-expired-ttl 0',
      'serve-expired-reply-ttl 5',
      'speed-check-mode ${speedCheck ? 'ping,tcp:443' : 'none'}',
      'log-level warn',
      if (ipv4Only) 'force-AAAA-SOA yes',
      'dualstack-ip-selection yes',
      'dualstack-ip-selection-threshold 30',
      '',
      ...servers.map((s) => 'server $s'),
      '',
      'nameserver /cn/223.5.5.5',
      'nameserver /cn/119.29.29.29',
    ].join('\n');
  }

  Future<bool> start({
    required List<String> upstreams,
    int cacheSize = 4096,
    bool ipv4Only = false,
    bool speedCheck = true,
  }) async {
    final bin = await resolveBinary(dataDir, explicit: explicitPath);
    if (bin == null) {
      onLog('[err] 未找到 smartdns，可先安装：sudo pacman -S smartdns');
      return false;
    }
    await stop();

    // Let the OS pick a free loopback port for us.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = probe.port;
    await probe.close();

    await dataDir.create(recursive: true);
    final conf = File('${dataDir.path}/smartdns.conf');
    await conf.writeAsString(buildConfig(
      upstreams: upstreams,
      cacheSize: cacheSize,
      ipv4Only: ipv4Only,
      speedCheck: speedCheck,
    ));

    try {
      // 约定：Linux 用 pymumu/smartdns（原版 C 实现，发行版仓库里就有），
      //       Windows 用 mokeyish/smartdns-rs（唯一有 Windows 构建的实现）。
      // 两者的 CLI 不同，这里按平台决定；若首选用法立刻失败，再回退另一种。
      final pymumuArgs = <String>['-f', '-c', conf.path, '-x', '${dataDir.path}/smartdns.pid'];
      final rustArgs = <String>['run', '-c', conf.path];
      var argv = Platform.isWindows ? rustArgs : pymumuArgs;
      var proc = await Process.start(bin, argv);
      onLog('[smartdns] 启动：$bin ${argv.join(' ')}');
      // 立刻退出说明命令行用法不对（例如把 rs 版放到 Linux 上），换另一种再试。
      final earlyExit = await proc.exitCode
          .timeout(const Duration(milliseconds: 800), onTimeout: () => -999)
          .then((code) => code != -999 && code != 0);
      if (earlyExit) {
        final alt = Platform.isWindows ? pymumuArgs : rustArgs;
        onLog('[smartdns] 首选用法失败，回退：${alt.join(' ')}');
        proc = await Process.start(bin, alt);
        argv = alt;
        onLog('[smartdns] 启动：$bin ${argv.join(' ')}');
      }
      _proc = proc;
      _running = true;
      proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => onLog('[smartdns] $l'));
      proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => onLog('[smartdns] $l'));
      unawaited(proc.exitCode.then((code) {
        if (_proc == proc) {
          _proc = null;
          _running = false;
          onLog('[err] smartdns 退出，code=$code');
        }
      }));

      // Wait until it actually answers a DNS query, otherwise mihomo would be
      // left without a resolver. smartdns listens on UDP, so probe over UDP.
      final deadline = DateTime.now().add(const Duration(seconds: 6));
      while (DateTime.now().isBefore(deadline)) {
        if (await _probeUdp(port)) {
          onLog('smartdns 已就绪：${address}（上游 ${upstreams.length} 个）');
          return true;
        }
        if (_proc == null) break;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      onLog('[err] smartdns 启动后 6 秒内未监听 ${address}');
      await stop();
      return false;
    } catch (e) {
      onLog('[err] smartdns 启动失败：$e');
      await stop();
      return false;
    }
  }

  /// Minimal DNS query for `www.baidu.com A`; any well-formed reply counts.
  static Future<bool> _probeUdp(int port) async {
    final query = <int>[
      0x12, 0x34, 0x01, 0x00, // id, flags: standard query, recursion desired
      0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x03, 0x77, 0x77, 0x77, // "www"
      0x06, 0x62, 0x61, 0x69, 0x64, 0x75, // "baidu"
      0x03, 0x63, 0x6f, 0x6d, // "com"
      0x00, 0x00, 0x01, 0x00, 0x01, // QTYPE=A QCLASS=IN
    ];
    RawDatagramSocket? sock;
    try {
      sock = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final done = Completer<bool>();
      final sub = sock.listen((event) {
        if (event == RawSocketEvent.read && !done.isCompleted) {
          final dg = sock!.receive();
          if (dg != null && dg.data.length >= 12) done.complete(true);
        }
      });
      sock.send(query, InternetAddress.loopbackIPv4, port);
      final ok = await done.future.timeout(const Duration(milliseconds: 500), onTimeout: () => false);
      await sub.cancel();
      return ok;
    } catch (_) {
      return false;
    } finally {
      sock?.close();
    }
  }

  Future<void> stop() async {
    final proc = _proc;
    _proc = null;
    _running = false;
    if (proc != null) {
      proc.kill(ProcessSignal.sigterm);
      await proc.exitCode.timeout(const Duration(seconds: 2), onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        return -1;
      });
    }
  }
}
