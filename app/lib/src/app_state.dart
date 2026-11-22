import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aran_core/aran_core.dart';
import 'package:flutter/material.dart';

import 'engine.dart';

/// Owns everything that makes Aran a client: the kernel process, the profiles,
/// the scheduler, and the controller connection.
class AppState extends ChangeNotifier {
  final Directory dataDir;

  late final ProfileStore profiles;
  late KernelManager kernel;

  Engine? engine;
  MihomoApi? api;

  final List<String> logs = [];
  bool busy = false;

  /// Last action result, surfaced as an on-screen toast. Every user-visible
  /// action reports here — silently swallowing failures is what made the UI feel
  /// unresponsive.
  ({String text, bool ok, DateTime at})? notice;

  /// Same as [notice] but never auto-cleared: the status bar always shows the
  /// last thing that happened, so "did that button do anything?" has an answer.
  ({String text, bool ok, DateTime at})? lastAction;
  Timer? _noticeTimer;

  void _notice(String text, {bool ok = true}) {
    lastAction = (text: text, ok: ok, at: DateTime.now());
    notice = lastAction;
    _noticeTimer?.cancel();
    _noticeTimer = Timer(const Duration(seconds: 5), () {
      notice = null;
      notifyListeners();
    });
    notifyListeners();
  }

  final Set<String> _pending = {};

  /// Per-action pending flags, so the button that triggered a slow call can show
  /// its own spinner instead of just going grey.
  bool isPending(String key) => _pending.contains(key);

  Future<T?> runPending<T>(String key, Future<T> Function() body) async {
    if (_pending.contains(key)) return null;
    _pending.add(key);
    notifyListeners();
    try {
      return await body();
    } finally {
      _pending.remove(key);
      notifyListeners();
    }
  }

  /// Run an action with uniform feedback: busy flag, success toast, error toast.
  Future<T?> track<T>(String label, Future<T> Function() body, {String? success}) async {
    if (busy) return null;
    busy = true;
    notifyListeners();
    try {
      final result = await body();
      _log('$label：完成');
      _notice(success ?? '$label 成功');
      return result;
    } catch (e) {
      error = '$label 失败：$e';
      _log('[err] $error');
      _notice(error!, ok: false);
      return null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }
  String? error;
  bool takeover = false;

  AranSettings settings = const AranSettings();
  late final SmartDns smartdns;
  late final Notifier notifier;
  Timer? _autoUpdateTimer;

  /// Flutter on Linux only sees the GTK theme, which on KDE is often light even
  /// when the desktop is dark. Ask KDE/gsettings directly.
  bool systemDark = true;
  File get _settingsFile => File('${dataDir.path}/settings.json');

  AppState(this.dataDir);

  bool get proxyRunning => engine != null && (serviceMode || kernel.isRunning);
  String? get controllerAddr => kernel.status.state == KernelState.running ? kernel.status.controllerAddr : null;

  Future<void> init() async {
    platform = createPlatform();
    platform.serviceScope = settings.serviceScope;
    await dataDir.create(recursive: true);
    systemDark = await _detectSystemDark();
    final raw = await _settingsFile.exists() ? await _settingsFile.readAsString() : null;
    if (raw != null) settings = AranSettings.tryParse(raw) ?? settings;
    takeover = settings.takeover;

    profiles = ProfileStore(dataDir);
    await profiles.load();
    final embedded = Bundled.bundledPath('mihomo') != null;
    _managedKernel = await Bundled.extract('mihomo', dataDir) ?? Bundled.existing('mihomo', dataDir);
    _embeddedKernel = embedded && _managedKernel != null;
    if (_managedKernel != null) {
      _log(_embeddedKernel ? '使用内嵌内核：$_managedKernel' : '使用已下载内核：$_managedKernel');
    }

    notifier = Notifier(enabled: settings.notifyEnabled, onLog: _log);
    _startAutoUpdate();
    smartdns = SmartDns(dataDir: dataDir, onLog: _log);
    kernel = KernelManager(
      binary: resolveKernel(),
      dataDir: dataDir,
      onLog: _log,
    );
    // Keep the autostart entry in sync with the setting (it may have been
    // removed by a system update or the file moved).
    _autoStartCached = await platform.autoStartEnabled();
    if (settings.autoStart != _autoStartCached) {
      await setAutoStart(settings.autoStart);
    }

    _startServicePolling();
    unawaited(refreshServiceInfo());

    // Restore the previous power state: a client that forgets it was on is annoying.
    if (profiles.active != null) {
      unawaited(startProxy());
    } else {
      // No profile means no proxy to start, but a desktop proxy left pointing at
      // a stale port is worse than none — reconcile it with the run mode.
      unawaited(_reconcileDesktopProxy());
    }
    notifyListeners();
  }

  static Future<bool> _detectSystemDark() async {
    final home = Platform.environment['HOME'] ?? '.';
    try {
      final kdeglobals = File('$home/.config/kdeglobals');
      if (await kdeglobals.exists()) {
        final text = await kdeglobals.readAsString();
        final m = RegExp(r'^ColorScheme=(.+)$', multiLine: true).firstMatch(text);
        if (m != null) return m.group(1)!.toLowerCase().contains('dark');
      }
    } catch (_) {}
    try {
      final r = await Process.run('gsettings', ['get', 'org.gnome.desktop.interface', 'color-scheme']);
      final out = '${r.stdout}'.trim();
      if (out.contains('dark')) return true;
      if (out.contains('light') || out.contains('default')) return false;
    } catch (_) {}
    return true;
  }

  /// Every kernel binary we can find on this machine, so the user can pick one.
  /// Discovery is the platform's job; we only prepend the copy Aran itself
  /// downloaded into its data dir.
  List<String> discoverKernels() {
    final home = Platform.environment['HOME'] ?? '.';
    final found = platform.discoverKernels(home);
    final managed = _managedKernel;
    if (managed != null && File(managed).existsSync() && !found.contains(managed)) {
      return [managed, ...found];
    }
    return found;
  }

  /// Resolved once at startup: bundled copy wins, then the user's explicit
  /// path, then the system binary, then PATH.
  /// Where the running kernel comes from, for the UI.
  /// 内嵌内核 = extracted from the app package; 已下载 = fetched into dataDir;
  /// 系统 = found on PATH; 自定义 = explicit path in settings.
  String get kernelSource {
    final path = kernel.binaryPath;
    final custom = settings.kernelPath.trim();
    if (custom.isNotEmpty && custom == path) return '自定义';
    final managed = Bundled.managedPath('mihomo', dataDir);
    if (path == managed && _embeddedKernel) return '内嵌内核';
    if (path == managed) return '已下载';
    return '系统';
  }

  bool _embeddedKernel = false;

  /// Kernels downloaded into the data dir (never shipped inside the package).
  String? _managedKernel;

  String resolveKernel() {
    final custom = settings.kernelPath.trim();
    if (custom.isNotEmpty && File(custom).existsSync()) return custom;
    if (_managedKernel != null && File(_managedKernel!).existsSync()) return _managedKernel!;
    final managed = Bundled.existing('mihomo', dataDir);
    if (managed != null) return managed;
    final found = discoverKernels();
    return found.isNotEmpty ? found.first : 'mihomo';
  }

  /// `<binary> -v` — used to validate a hand-picked kernel.
  Future<String?> probeKernelVersion(String path) async {
    try {
      final r = await Process.run(path, ['-v']);
      final out = '${r.stdout}${r.stderr}'.trim();
      if (r.exitCode != 0) return null;
      return out.split('\n').first.trim();
    } catch (_) {
      return null;
    }
  }

  void _log(String line) {
    // Also persist: on a headless/CI machine the in-app log page is unreadable.
    try {
      final f = File('${dataDir.path}/app.log');
      f.writeAsStringSync('${DateTime.now().toIso8601String()} $line\n', mode: FileMode.append, flush: false);
    } catch (_) {}
    if (line.startsWith('[err]') && settings.notifyEnabled && line.contains('内核')) {
      unawaited(notifier.send('Aran 内核异常', line, urgent: true));
    }
    logs.insert(0, line);
    if (logs.length > 400) logs.removeLast();
    notifyListeners();
  }

  void setError(String? message) {
    error = message;
    notifyListeners();
  }

  late final AranPlatform platform;

  /// Portable build: no system service, no autostart, everything app-local.
  bool get portable => platform.portable;
  bool get supportsSystemService => platform.supportsSystemService;

  bool get serviceMode => settings.runMode == 'service' && supportsSystemService;

  /// True when this session's kernel was spawned by Aran (not systemd), even if
  /// the configured mode is `service`. Lets "restart kernel" act on the process
  /// instead of bouncing a unit that may not even be installed.
  bool directKernel = false;

  bool get systemdKernel => serviceMode && !directKernel;

  /// 用户点过「直接启动内核」——只有这种显式选择才不交给 supervisor。
  bool _directRequested = false;

  bool get serviceUnitInstalled => platform.serviceInstalled();
  bool get _externalKernel => serviceMode;

  // ---- watchdog ----
  Process? _watchdog;
  Timer? _heartbeat;
  File get _heartbeatFile => File('${dataDir.path}/heartbeat');

  /// Touch a heartbeat file每秒；watchdog 发现它超过 30s 没更新，就把 Aran 钉住的
  /// 组交还给内核的 url-test 兜底组 —— 这样 GUI 崩了也不会「节点死了但没人切」。
  Future<void> _startWatchdog() async {
    _stopWatchdog();
    if (!settings.watchdogEnabled || kernel.fallbackGroup.isEmpty) return;
    final addr = kernel.status.controllerAddr;
    if (addr.isEmpty) return;
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 1), (_) {
      try {
        _heartbeatFile.writeAsStringSync('${DateTime.now().millisecondsSinceEpoch}');
      } catch (_) {}
    });
    try {
      _heartbeatFile.writeAsStringSync('${DateTime.now().millisecondsSinceEpoch}');
      // Generated into the data dir: no helper script ships inside the bundle.
      final watchdogFile = File('${dataDir.path}/scripts/watchdog.py');
      await watchdogFile.parent.create(recursive: true);
      await watchdogFile.writeAsString(watchdogScript);
      final path = watchdogFile.path;
      _watchdog = null;
      final python = platform.scriptCommand('python');
      if (python == null) {
        _log('当前平台没有 python，看门狗已跳过');
        return;
      }
      Process.start(python.first, [
        ...python.skip(1),
        path,
        addr,
        serviceMode ? settings.serviceSecret : kernel.secret,
        _heartbeatFile.path,
        kernel.fallbackGroup,
        ...kernel.managedGroups.where((g) => g != kernel.fallbackGroup),
      ]).then((p) {
        _watchdog = p;
        p.stdout.transform(const SystemEncoding().decoder).listen(_log);
      });
      _log('看门狗已启动：${kernel.managedGroups.length} 组 → ${kernel.fallbackGroup}');
    } catch (e) {
      _log('[err] 看门狗启动失败：$e');
    }
  }

  void _stopWatchdog() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _watchdog?.kill(ProcessSignal.sigterm);
    _watchdog = null;
  }

  /// Subscription refresh: on start (if stale) and hourly afterwards.
  void _startAutoUpdate() {
    _autoUpdateTimer?.cancel();
    _autoUpdateTimer = Timer.periodic(const Duration(hours: 1), (_) => _autoUpdateStale());
    unawaited(_autoUpdateStale());
  }

  DateTime? lastAutoUpdateCheck;

  Future<void> _autoUpdateStale() async {
    lastAutoUpdateCheck = DateTime.now();
    var updated = 0;
    final now = DateTime.now();
    for (final p in profiles.profiles.where((p) => p.url != null)) {
      // Each subscription carries its own interval; 24h is the default.
      final hours = p.autoUpdateHours ?? 24;
      if (hours <= 0) continue;
      if (now.difference(p.updatedAt) < Duration(hours: hours)) continue;
      try {
        final before = p;
        final after = await profiles.update(p.id);
        _log('自动更新订阅：${after.name}（${(after.bytes / 1024).toStringAsFixed(0)} KB）');
        final left = after.trafficLeft;
        if (left != null) {
          final total = after.trafficTotal;
          final ratio = total != null && total > 0 ? left / total : null;
          if (ratio != null && ratio < 0.1) {
            await notifier.send('订阅流量告急', '${after.name} 剩余 ${(left / 1e9).toStringAsFixed(2)} GB', urgent: true);
          }
        }
        if (profiles.activeId == after.id && proxyRunning) await _reloadOrRestart();
        _notice('订阅已自动更新：${after.name}');
        updated++;
        assert(before.id == after.id);
      } catch (e) {
        _log('[err] 自动更新失败 ${p.name}: $e');
        await notifier.send('订阅更新失败', '${p.name}：$e', urgent: true);
      }
    }
    notifyListeners();
    if (updated > 0) {
      await notifier.send('订阅已更新', '$updated 个配置已刷新');
    }
  }

  /// Manual "check now" (used by the settings row button).
  Future<void> checkUpdatesNow() async {
    _notice('正在检查订阅更新…');
    await _autoUpdateStale();
    _notice(lastAutoUpdateCheck == null ? '未启用自动更新' : '订阅检查完成');
  }

  /// Live systemd state for the service-mode kernel.
  Map<String, String> serviceInfo = const {};
  Timer? _servicePoll;

  Future<void> refreshServiceInfo() async {
    if (!serviceMode) {
      serviceInfo = const {};
      notifyListeners();
      return;
    }
    try {
      serviceInfo = await platform.serviceStatus();
    } catch (_) {
      serviceInfo = const {'active': 'unknown'};
    }
    notifyListeners();
  }

  void _startServicePolling() {
    _servicePoll?.cancel();
    if (!serviceMode) return;
    _servicePoll = Timer.periodic(const Duration(milliseconds: 1500), (_) => refreshServiceInfo());
  }

  /// Restart the kernel no matter who owns it (our child or systemd).
  Future<void> restartKernel() async {
    busy = true;
    notifyListeners();
    try {
      // A transient failure used to latch `directKernel` for the whole session,
      // so the UI claimed "service" while the GUI quietly owned the process.
      // Only an explicit "直接启动内核" keeps us off the supervisor.
      if (serviceMode && serviceUnitInstalled && directKernel && !_directRequested) {
        directKernel = false;
        _log('服务可用，重新交给 supervisor 接管');
      }
      if (systemdKernel) {
        _notice('正在重启 systemd 内核…');
        final wasRunning = proxyRunning;
        final e = engine;
        engine = null;
        api?.close();
        api = null;
        await e?.dispose();
        await _systemctl(['restart', 'aran-kernel.service']);
        await refreshServiceInfo();
        if (wasRunning) await _startServiceKernel();
        _log('已重启系统服务内核');
        _notice('已重启 systemd 内核');
      } else {
        // Direct kernel (or managed mode): restart the process ourselves.
        await restartProxy();
        _log('已重启内核进程（pid 由 Aran 管理）');
        _notice('已重启内核进程');
      }
    } catch (e) {
      error = '重启内核失败：$e';
      _notice(error!, ok: false);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<ProcessResult> _systemctl(List<String> args) async {
    if (args.isEmpty) return ProcessResult(0, 0, '', '');
    return platform.controlService(args.first);
  }

  Future<String?> serviceState() async => (await platform.serviceStatus())['active'];


  /// Manual fallback when polkit is unavailable/cancelled. The unit file is
  /// generated by Aran at install time — there is no install script to ship.
  String manualInstallCommand() {
    final unit = ServiceUnit(kernelPath: kernel.binaryPath, dataDir: dataDir.path);
    final kind = platform.serviceKind;
    final staged = '${dataDir.path}/${unit.unitName}';

    if (kind == 'systemd-user') {
      // No sudo anywhere: everything is inside the user's own systemd instance.
      final home = Platform.environment['HOME'] ?? '.';
      final target = '$home/.config/systemd/user/${unit.unitName}';
      return 'mkdir -p ~/.config/systemd/user '
          '&& cp "$staged" "$target" '
          '&& systemctl --user daemon-reload '
          '&& systemctl --user enable --now aran-kernel.service';
    }
    if (kind == 'task-user') {
      return 'schtasks /create /f /tn AranKernel /tr \'"${kernel.binaryPath}" -d "${dataDir.path}"\' '
          '/sc onlogon /rl LIMITED';
    }
    final target = unit.pathFor(kind);
    final mode = kind == 'systemd' ? '644' : '755';
    final enable = switch (kind) {
      'openrc' => ' && sudo rc-update add aran-kernel default',
      'runit' => ' && sudo ln -sf /etc/sv/aran-kernel /var/service/aran-kernel',
      _ => ' && sudo systemctl daemon-reload && sudo systemctl enable aran-kernel.service',
    };
    return 'sudo install -m $mode $staged $target$enable';
  }

  /// Resume polling immediately (called after every service action).
  void pokeServiceStatus() {
    _startServicePolling();
    unawaited(refreshServiceInfo());
  }

  Future<void> removeService() async {
    await runPending('svcremove', () async {
      final r = await platform.removeService();
      _notice(r.exitCode == 0 ? '服务已卸载' : '卸载失败：${r.stderr}', ok: r.exitCode == 0);
      pokeServiceStatus();
    });
  }

  Future<String> loadServiceLogs() => platform.serviceLogs();

  Future<void> startServiceNow() async {
    await runPending('svcstart', () async {
      final r = await platform.controlService('start');
      _notice(r.exitCode == 0 ? '服务已启动' : '启动失败：${r.stderr}', ok: r.exitCode == 0);
      pokeServiceStatus();
    });
  }

  Future<void> installService() async {
    busy = true;
    notifyListeners();
    try {
      if (!supportsSystemService) {
        _notice('当前环境不支持系统服务（便携模式或没有受支持的 init）', ok: false);
        return;
      }
      final kind = platform.serviceKind;
      final unit = ServiceUnit(kernelPath: kernel.binaryPath, dataDir: dataDir.path);
      // Unit file is generated here, staged in our data dir, then installed by
      // the platform-specific supervisor path. Nothing ships in the bundle.
      final staged = File('${dataDir.path}/${unit.unitName}');
      final home = Platform.environment['HOME'] ?? '.';
      final body = kind == 'systemd-user' ? unit.userContent() : unit.contentFor(kind);
      await staged.writeAsString(body);
      if (kind == 'systemd-user') {
        _log('用户级服务：$home/.config/systemd/user/aran-kernel.service（无需 root）');
      }

      _notice('正在申请管理员授权，请在弹窗中输入密码…');
      final r = await platform
          .installService(scriptPath: staged.path, dataDir: dataDir.path, kernelPath: kernel.binaryPath)
          .timeout(const Duration(seconds: 90), onTimeout: () => ProcessResult(-1, 0, '', '等待授权超时'));
      final out = '${r.stdout}'.trim();
      final err = '${r.stderr}'.trim();
      _log('install-service($kind) rc=${r.exitCode} ${out.isEmpty ? err : out}');

      if (r.exitCode == 0) {
        await platform.enableService();
        _notice('服务已安装（$kind）：${unit.pathFor(kind)}');
      } else {
        error = '安装服务失败（$kind, rc=${r.exitCode}）：${err.isNotEmpty ? err : out}';
        _notice(error!, ok: false);
        _log('手动安装：${manualInstallCommand()}');
      }
      await refreshServiceInfo();
    } catch (e) {
      error = '安装服务失败：$e';
      _notice(error!, ok: false);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Spawn mihomo from the GUI regardless of the configured mode — the
  /// lightweight path for people who don't want systemd involved.
  Future<void> startKernelDirect() async {
    _directRequested = true;
    directKernel = true;
    await startProxy();
  }

  Future<void> restartService() async {
    try {
      final r = await _systemctl(['restart', 'aran-kernel.service']);
      if (r.exitCode != 0) {
        error = '重启服务失败：${r.stderr}';
        _notice(error!, ok: false);
      } else {
        _notice('systemd 服务已重启');
      }
      _log('已重启 aran-kernel.service');
      await refreshServiceInfo();
    } catch (e) {
      error = '重启服务失败：$e';
    }
    notifyListeners();
  }

  Future<void> stopService() async {
    try {
      await _systemctl(['stop', 'aran-kernel.service']);
      _notice('systemd 服务已停止');
    } catch (e) {
      _notice('停止服务失败：$e', ok: false);
    }
    await refreshServiceInfo();
    notifyListeners();
  }

  Future<void> _startServiceKernel() async {
    // First run in service mode: install the unit instead of failing with
    // "Unit not found".
    if (!platform.serviceInstalled()) {
      _log('未检测到服务单元，先安装…');
      await installService();
      if (!platform.serviceInstalled()) {
        error = 'systemd 服务未安装（需要一次授权）';
        notifyListeners();
        return;
      }
    }
    final config = profiles.activeConfigText;
    if (config == null) {
      error = '还没有可用的配置';
      return;
    }
    final home = Platform.environment['HOME'] ?? '.';
    final smartdnsAddress = settings.dnsProvider == 'smartdns' && settings.dnsEnabled
        ? (smartdns.running ? smartdns.address : null)
        : null;
    if (settings.dnsProvider == 'smartdns' && settings.dnsEnabled && !smartdns.running && SmartDns.available) {
      await smartdns.start(
        upstreams: settings.smartdnsUpstreams,
        cacheSize: settings.smartdnsCache,
        ipv4Only: settings.smartdnsIpv4Only,
        speedCheck: settings.smartdnsSpeedCheck,
      );
    }
    await kernel.writeServiceConfig(
      config,
      settings: settings,
      port: settings.mixedPort,
      controllerPort: settings.controllerPort,
      secret: settings.serviceSecret,
      smartdnsAddress: smartdnsAddress,
      assetDirs: [
        if (profiles.active?.homeDir != null) profiles.active!.homeDir!,
        '$home/.config/mihomo',
        '$home/.config/sparkle/work',
        '/usr/share/mihomo',
      ],
    );
    final r = await _systemctl(['restart', 'aran-kernel.service']);
    if (r.exitCode != 0) {
      error = '启动服务失败：${r.stderr}';
      notifyListeners();
      return;
    }
    // The service kernel is a separate process; its ports come from the config
    // we just wrote, so the desktop proxy has to follow them (it used to be left
    // pointing at whatever the previous run mode bound).
    unawaited(_refreshSystemProxy());

    // Wait until the controller answers.
    final addr = '127.0.0.1:${settings.controllerPort}';
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final probe = MihomoApi(addr: addr, secret: settings.serviceSecret);
      try {
        await probe.version();
        probe.close();
        api = MihomoApi(addr: addr, secret: settings.serviceSecret);
        engine = Engine(
          addr: addr,
          secret: settings.serviceSecret,
          takeover: takeover,
          threshold: settings.threshold,
          cooldown: Duration(minutes: settings.cooldownMinutes),
          testUrl: settings.testUrl,
          testTimeoutMs: settings.testTimeoutMs,
        );
        engine!.setGroups(
          kernel.managedGroups.isEmpty
              ? <String>[if (kernel.mainGroup.isNotEmpty) kernel.mainGroup]
              : kernel.managedGroups,
          settings.groupPrefs,
        );
        engine!.setGroupModes(settings.groupModes);
        await engine!.start();
        _log('已连接系统服务内核：$addr');
        return;
      } catch (_) {
        probe.close();
      }
    }
    error = '服务已启动但控制器无响应（检查 systemctl status aran-kernel）';
  }

  Future<void> startProxy() async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    var ok = false;
    try {
      if (systemdKernel) {
        _notice('正在重启 systemd 内核…');
        directKernel = false;
        await _startServiceKernel();
        ok = proxyRunning;
        _notice(ok ? '已通过 systemd 启动内核' : (error ?? '启动失败'), ok: ok);
        return;
      }
      if (serviceMode) {
        _log('未使用 systemd（服务未安装或已选择直连），Aran 直接拉起内核');
        directKernel = true;
      }
      final config = profiles.activeConfigText;
      if (config == null) {
        error = '还没有可用的配置，先去「配置」页导入订阅';
        return;
      }
      final home = Platform.environment['HOME'] ?? '.';
      String? smartdnsAddress;
      if (settings.dnsProvider == 'smartdns' && settings.dnsEnabled) {
        if (!SmartDns.available) {
          _log('[err] 未安装 smartdns，回退到内置 DNS（sudo pacman -S smartdns）');
        } else {
          smartdns.explicitPath = settings.smartDnsPath;
          final ok = await smartdns.start(
            upstreams: settings.smartdnsUpstreams,
            cacheSize: settings.smartdnsCache,
            ipv4Only: settings.smartdnsIpv4Only,
            speedCheck: settings.smartdnsSpeedCheck,
          );
          if (ok) smartdnsAddress = smartdns.address;
        }
      }
      final status = await kernel.start(
        config,
        settings: settings,
        smartdnsAddress: smartdnsAddress,
        assetDirs: [
          if (profiles.active?.homeDir != null) profiles.active!.homeDir!,
          '$home/.config/mihomo',
          '$home/.config/sparkle/work',
          '$home/.config/clash',
          '/usr/share/mihomo',
          '/etc/mihomo',
        ],
      );
      if (status.state != KernelState.running) {
        error = status.error ?? '内核启动失败';
        return;
      }
      api = MihomoApi(addr: status.controllerAddr, secret: status.secret);
      await _ensureValidSelection();
      engine = Engine(
        addr: status.controllerAddr,
        secret: status.secret,
        takeover: takeover,
        configuredGroup: settings.takeoverGroup.isEmpty ? null : settings.takeoverGroup,
        threshold: settings.threshold,
        cooldown: Duration(minutes: settings.cooldownMinutes),
        testUrl: settings.testUrl,
        testTimeoutMs: settings.testTimeoutMs,
      );
      engine!.setGroups(
        kernel.managedGroups.isEmpty
            ? <String>[if (kernel.mainGroup.isNotEmpty) kernel.mainGroup]
            : kernel.managedGroups,
        settings.groupPrefs,
      );
      engine!.setGroupModes(settings.groupModes);
      await engine!.start();
      await _refreshSystemProxy();
      await _reconcileDesktopProxy();
      await _startWatchdog();
      ok = true;
    } catch (e) {
      error = '$e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Converting `url-test` groups to `select` means the kernel no longer picks a
  /// node for us — and airports ship placeholder nodes ("Dont.use.this.node")
  /// that sit first in the list. Without this the config would simply not work.
  Future<void> _ensureValidSelection() async {
    try {
      final proxies = await api!.proxies();
      String? target;
      var best = -1;
      for (final e in proxies.entries) {
        if (e.key == 'GLOBAL') continue;
        final v = e.value;
        if (v is! Map || v['type'] != 'Selector') continue;
        final count = (v['all'] as List?)?.length ?? 0;
        if (count > best) {
          best = count;
          target = e.key;
        }
      }
      if (target == null) return;
      final group = proxies[target] as Map;
      final now = group['now'] as String?;
      final members = (group['all'] as List?)?.cast<String>() ?? const <String>[];

      bool usable(String n) {
        final v = proxies[n];
        if (v is! Map) return false;
        final t = v['type'];
        if (t == 'Selector' || t == 'URLTest' || t == 'Fallback' || t == 'Direct' || t == 'Reject') return false;
        return !Engine.isPseudo(n);
      }

      if (now != null && usable(now)) return;
      final first = members.where(usable).firstOrNull;
      if (first == null) return;
      await api!.select(target, first);
      _log('初始化选择：$target → $first（配置默认指向占位/无效节点）');
      notifyListeners();
    } catch (e) {
      _log('[err] 初始化选择失败：$e');
    }
  }

  Future<void> stopProxy() async {
    if (busy) return;
    busy = true;
    notifyListeners();
    final e = engine;
    engine = null;
    api?.close();
    api = null;
    await e?.dispose();
    if (systemdKernel) {
      await stopService();
    } else {
      await kernel.stop();
    }
    await smartdns.stop();
    _stopWatchdog();
    busy = false;
    _notice(systemdKernel && serviceUnitInstalled ? '已停止服务内核' : '代理已关闭，内核已退出');
    notifyListeners();
  }

  /// Apply the active profile to a running kernel without restarting it.
  Future<void> _reloadOrRestart() async {
    if (!proxyRunning) {
      notifyListeners();
      return;
    }
    final config = profiles.activeConfigText;
    if (config == null) {
      notifyListeners();
      return;
    }
    String? smartdnsAddress = smartdns.running ? smartdns.address : null;
    if (settings.dnsProvider == 'smartdns' && settings.dnsEnabled && smartdnsAddress == null) {
      smartdns.explicitPath = settings.smartDnsPath;
      if (SmartDns.available &&
          await smartdns.start(
            upstreams: settings.smartdnsUpstreams,
            cacheSize: settings.smartdnsCache,
            ipv4Only: settings.smartdnsIpv4Only,
            speedCheck: settings.smartdnsSpeedCheck,
          )) {
        smartdnsAddress = smartdns.address;
      }
    }
    final ok = await kernel.hotReload(
      config,
      settings: settings,
      smartdnsAddress: smartdnsAddress,
    );
    if (ok) {
      await _ensureValidSelection();
      engine?.setGroups(
        kernel.managedGroups.isEmpty
            ? <String>[if (kernel.mainGroup.isNotEmpty) kernel.mainGroup]
            : kernel.managedGroups,
        settings.groupPrefs,
      );
      engine?.setGroupModes(settings.groupModes);
      notifyListeners();
    } else {
      await restartProxy();
    }
  }

  Future<void> restartProxy() async {
    final wasRunning = proxyRunning;
    await stopProxy();
    if (wasRunning) await startProxy();
  }

  /// Bundle logs + redacted settings into a tarball for troubleshooting.
  /// Deliberately excludes profile configs: they contain node credentials.
  Future<String?> exportDiagnostics() async {
    busy = true;
    notifyListeners();
    try {
      final outDir = Directory('${dataDir.path}/exports')..createSync(recursive: true);
      final stamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
      final stage = Directory('${outDir.path}/diag-$stamp')..createSync(recursive: true);

      // summary
      final summary = StringBuffer()
        ..writeln('Aran diagnostics · $stamp')
        ..writeln('app: ${Platform.resolvedExecutable}')
        ..writeln('data: ${dataDir.path}')
        ..writeln('kernel: ${kernel.binaryPath} · ${kernel.status.version ?? '?'}')
        ..writeln('kernel source: ${systemdKernel ? 'systemd' : 'direct'}')
        ..writeln('kernel state: ${kernel.status.state.name}')
        ..writeln('service: ${serviceInfo}')
        ..writeln('smartdns: ${smartdns.running ? smartdns.address : 'off'}')
        ..writeln('ports: ${kernel.activePorts}')
        ..writeln('driver groups: ${kernel.managedGroups}')
        ..writeln('profiles: ${profiles.profiles.map((p) => '${p.name}(${p.url != null ? 'url' : 'file'})').join(', ')}')
        ..writeln('host: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
      File('${stage.path}/summary.txt').writeAsStringSync(summary.toString());

      // settings without the controller secret
      final settingsJson = settings.toJson()..remove('serviceSecret');
      File('${stage.path}/settings.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(settingsJson));

      for (final name in ['kernel.log', 'audit.jsonl']) {
        final f = File('${dataDir.path}/$name');
        if (f.existsSync()) {
          final lines = await f.readAsLines();
          File('${stage.path}/$name').writeAsStringSync(
              lines.length > 3000 ? lines.sublist(lines.length - 3000).join('\n') : lines.join('\n'));
        }
      }
      try {
        final r = await Process.run('systemctl', ['status', 'aran-kernel.service', '--no-pager', '-l']);
        File('${stage.path}/systemd.txt').writeAsStringSync('${r.stdout}${r.stderr}');
      } catch (_) {}

      final archive = '${outDir.path}/aran-diag-$stamp.tar.gz';
      await Process.run('tar', ['-czf', archive, '-C', outDir.path, 'diag-$stamp']);
      await Directory(stage.path).delete(recursive: true);
      _log('诊断包：$archive');
      _notice('诊断包已生成：$archive');
      return archive;
    } catch (e) {
      _notice('导出诊断包失败：$e', ok: false);
      return null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Per-subscription auto-update interval (0 = off for this one).
  /// No kernel on this machine? Fetch the official release into the user data
  /// dir. Nothing is embedded in the package — licensing, size and distro
  /// packaging all want the binary outside the app bundle.
  Future<void> installKernel() async {
    busy = true;
    _notice('正在获取内核版本信息…');
    notifyListeners();
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      final req = await client.getUrl(Uri.parse('https://api.github.com/repos/MetaCubeX/mihomo/releases/latest'));
      req.headers.set(HttpHeaders.userAgentHeader, 'Aran');
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      client.close();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final version = (json['tag_name'] as String?)?.replaceFirst('v', '');
      if (version == null) throw const FormatException('无法解析 release 信息');
      await _downloadKernel(version);
    } catch (e) {
      _notice('下载内核失败：$e', ok: false);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Latest mihomo release known from GitHub (null = not checked / offline).
  String? latestKernelVersion;

  Future<void> checkKernelUpdate() async {
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final req = await client.getUrl(Uri.parse('https://api.github.com/repos/MetaCubeX/mihomo/releases/latest'));
      req.headers.set(HttpHeaders.userAgentHeader, 'Aran');
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      client.close();
      final json = jsonDecode(body) as Map<String, dynamic>;
      latestKernelVersion = (json['tag_name'] as String?)?.replaceFirst('v', '');
      final current = kernel.status.version ?? '';
      if (latestKernelVersion == null) {
        _notice('无法获取内核版本信息', ok: false);
      } else if (_versionAtLeast(current, latestKernelVersion!)) {
        _notice('内核已是最新（$current）');
      } else {
        _notice('发现新内核 $latestKernelVersion（当前 $current），点「升级」下载');
      }
    } catch (e) {
      _notice('检查内核更新失败：$e', ok: false);
    }
    notifyListeners();
  }

  /// Download a specific mihomo version into `<data>/bin/mihomo`.
  Future<void> _downloadKernel(String version) async {
    _notice('正在下载 mihomo $version…');
    final arch = Platform.version.contains('arm64') ? 'arm64' : 'amd64';
    final asset = 'mihomo-linux-$arch-$version.gz';
    final url = 'https://github.com/MetaCubeX/mihomo/releases/download/v$version/$asset';
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.userAgentHeader, 'Aran');
    req.followRedirects = true;
    final res = await req.close();
    if (res.statusCode >= 300) throw HttpException('HTTP ${res.statusCode}');
    final gz = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    client.close();

    final binary = gzip.decode(gz);
    final target = File(Bundled.managedPath('mihomo', dataDir));
    await target.parent.create(recursive: true);
    await target.writeAsBytes(binary);
    await platform.makeExecutable(target.path);
    _managedKernel = target.path;
    latestKernelVersion = version;
    _log('内核已安装：${target.path} ($version)');
    _notice('内核已就绪：$version → ${target.path}');
    await notifier.send('Aran', '内核已更新到 $version');
    if (proxyRunning) await restartKernel();
  }

  /// Upgrade the running kernel to the latest release.
  Future<void> upgradeKernel() async {
    if (latestKernelVersion == null) {
      await checkKernelUpdate();
      if (latestKernelVersion == null) return;
    }
    busy = true;
    notifyListeners();
    try {
      await _downloadKernel(latestKernelVersion!);
    } catch (e) {
      _notice('内核升级失败：$e', ok: false);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  static bool _versionAtLeast(String current, String latest) {
    final a = current.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final b = latest.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    for (var i = 0; i < 3; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return true;
  }

  /// Roll a subscription back to a snapshot and reload the kernel.
  Future<void> restoreSnapshot(String id, File snap) async {
    busy = true;
    notifyListeners();
    try {
      await profiles.restore(id, snap);
      _log('已回滚配置：${snap.path.split('/').last}');
      if (proxyRunning && profiles.activeId == id) await _reloadOrRestart();
      _notice('已回滚到 ${snap.path.split('/').last}');
    } catch (e) {
      _notice('回滚失败：$e', ok: false);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> setProfileAutoUpdate(String id, int hours) async {
    await profiles.updateMeta(id, autoUpdateHours: hours);
    _notice('${profiles.profiles.firstWhere((p) => p.id == id).name} · 自动更新：${hours == 0 ? '关闭' : '$hours 小时'}');
    notifyListeners();
  }

  Future<void> setGroupMode(String group, String mode) async {
    final next = {...settings.groupModes};
    if (mode.isEmpty) {
      next.remove(group);
    } else {
      next[group] = mode;
    }
    settings = settings.copyWith(groupModes: next);
    await _writeSettings();
    engine?.setGroupModes(next);
    _log('分组控制：$group → ${mode.isEmpty ? '跟随全局' : mode}');
    notifyListeners();
  }

  Future<void> setGroupPref(String group, String pref) async {
    final next = {...settings.groupPrefs};
    if (pref.isEmpty) {
      next.remove(group);
    } else {
      next[group] = pref;
    }
    settings = settings.copyWith(groupPrefs: next);
    await _writeSettings();
    engine?.setGroups(
      kernel.managedGroups.isEmpty ? <String>[if (kernel.mainGroup.isNotEmpty) kernel.mainGroup] : kernel.managedGroups,
      settings.groupPrefs,
    );
    notifyListeners();
  }

  Future<void> setTakeoverGroup(String name) async {
    settings = settings.copyWith(takeoverGroup: name);
    await _writeSettings();
    engine?.setGroup(name);
    _log('Aran 接管策略组：$name');
    notifyListeners();
  }

  void setTakeover(bool value) {
    takeover = value;
    engine?.setTakeover(value);
    settings = settings.copyWith(takeover: value);
    unawaited(_writeSettings());
    notifyListeners();
  }

  bool _autoStartCached = false;
  bool get autoStartInstalled => _autoStartCached;

  /// Autostart is platform-specific (XDG .desktop vs HKCU Run key).
  Future<void> setAutoStart(bool enabled) async {
    try {
      final exe = Platform.resolvedExecutable;
      final icon = '${File(exe).parent.path}${Platform.pathSeparator}data'
          '${Platform.pathSeparator}flutter_assets${Platform.pathSeparator}assets'
          '${Platform.pathSeparator}icon.png';
      await platform.setAutoStart(enabled, execPath: exe, iconPath: icon);
      _autoStartCached = await platform.autoStartEnabled();
      settings = settings.copyWith(autoStart: enabled);
      await _writeSettings();
      _log(enabled ? '已启用开机自启：$exe' : '已关闭开机自启');
      _notice(enabled ? '已启用开机自启' : '已关闭开机自启');
    } catch (e) {
      error = '设置开机自启失败：$e';
      _notice(error!, ok: false);
    }
    notifyListeners();
  }

  // ---- system proxy / TUN (both delegated to the platform) ----

  Future<bool> systemProxyActive() => platform.desktopProxyActive();

  /// The port the *running* kernel actually binds. Managed mode reports what the
  /// process really bound (autoPort may have picked something); service mode has
  /// no handle on the process, so it is whatever we wrote into config.yaml.
  int? get desktopProxyPort {
    if (settings.runMode == 'service') {
      // A service kernel never starts in socks/http-only mode by accident —
      // it always mirrors the configured mixed port.
      return settings.mixedPort > 0 ? settings.mixedPort : null;
    }
    return kernel.activePorts['mixed'] ?? kernel.activePorts['http'];
  }

  /// TUN and system proxy are alternatives: enabling one turns the other off.
  Future<void> setSystemProxy(bool enabled) async {
    final port = desktopProxyPort;
    if (enabled && port == null) {
      _notice('内核未运行，先开启代理', ok: false);
      return;
    }
    try {
      if (enabled && settings.tunEnabled) {
        await saveSettings(settings.copyWith(tunEnabled: false));
        _log('开启系统代理，自动关闭 TUN');
      }
      await platform.setDesktopProxy(port ?? 0, enable: enabled);
      settings = settings.copyWith(systemProxy: enabled);
      await _writeSettings();
      _notice(enabled ? '系统代理已开启（${platform.desktopProxyLabel}）→ 127.0.0.1:$port' : '系统代理已关闭');
      notifyListeners();
    } catch (e) {
      _notice('系统代理设置失败：$e', ok: false);
    }
  }

  /// Re-apply after the kernel rebound its ports (restart / mode change).
  Future<void> _refreshSystemProxyAfterSave(AranSettings next) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final port = next.runMode == 'service'
        ? (next.mixedPort > 0 ? next.mixedPort : null)
        : (kernel.activePorts['mixed'] ?? kernel.activePorts['http']);
    if (port == null) return;
    try {
      await platform.setDesktopProxy(port, enable: true);
      _log('系统代理已重新指向 127.0.0.1:$port');
    } catch (_) {}
  }

  /// On startup: if the desktop proxy claims to be on, make sure it points at the
  /// port this run mode actually binds (a mode switch used to leave it stale).
  Future<void> _reconcileDesktopProxy() async {
    try {
      final active = await platform.desktopProxyActive();
      final port = desktopProxyPort;
      if (!active || port == null) return;
      await platform.setDesktopProxy(port, enable: true);
      _log('系统代理已校准到 127.0.0.1:$port');
    } catch (_) {}
  }

  Future<void> _refreshSystemProxy() async {
    if (!settings.systemProxy) return;
    final port = desktopProxyPort;
    if (port == null) return;
    try {
      await platform.setDesktopProxy(port, enable: true);
    } catch (_) {}
  }

  Future<bool> tunCapable() => platform.tunCapable(kernel.binaryPath);

  Future<bool> installTunCapability() async {
    final ok = await platform.grantTunCapability(kernel.binaryPath);
    if (ok) {
      _log('已授予 TUN 权限：${kernel.binaryPath}');
      _notice('TUN 权限已授予');
    } else {
      error = 'TUN 授权失败或被取消';
      _notice(error!, ok: false);
    }
    notifyListeners();
    return ok;
  }

  /// Enable/disable TUN (requires CAP_NET_ADMIN on Linux, admin + wintun on
  /// Windows). Never throws: the reason is surfaced as a notice.
  Future<void> setTun(bool enabled) async {
    if (enabled) {
      final capable = await tunCapable();
      if (!capable) {
        _notice('正在申请 TUN 权限…');
        final granted = await installTunCapability();
        if (!granted || !await tunCapable()) {
          _notice('TUN 不可用：缺少权限或 wintun', ok: false);
          return;
        }
      }
    }
    if (enabled && settings.systemProxy) {
      await platform.setDesktopProxy(0, enable: false);
      settings = settings.copyWith(systemProxy: false);
      _log('开启 TUN，自动关闭系统代理');
    }
    await saveSettings(settings.copyWith(tunEnabled: enabled));
    _notice(enabled ? 'TUN 已开启（热重载生效）' : 'TUN 已关闭');
  }

  /// Shell snippet for terminals / CLI tools that ignore system proxy settings.
  /// Each shell spells it differently, so emit the right dialect.
  String envScript({String? shell}) {
    final kind = shell ?? settings.envShell;
    final ports = kernel.activePorts;
    final httpPort = ports['mixed'] ?? ports['http'];
    if (httpPort == null) return '# Aran: 代理未启动';
    final socksPort = ports['mixed'] ?? ports['socks'] ?? httpPort;

    final http = 'http://127.0.0.1:$httpPort';
    final socks = 'socks5://127.0.0.1:$socksPort';
    const noProxy = 'localhost,127.0.0.1,::1,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12';

    switch (kind) {
      case 'fish':
        return ['# Aran · fish', 'set -gx http_proxy $http', 'set -gx https_proxy $http',
          'set -gx all_proxy $socks', 'set -gx no_proxy $noProxy'].join('\n');
      case 'nushell':
        return ['# Aran · nushell', '\$env.http_proxy = "$http"', '\$env.https_proxy = "$http"',
          '\$env.all_proxy = "$socks"', '\$env.no_proxy = "$noProxy"'].join('\n');
      case 'powershell':
        return ['# Aran · PowerShell', '\$env:http_proxy = "$http"', '\$env:https_proxy = "$http"',
          '\$env:all_proxy = "$socks"', '\$env:no_proxy = "$noProxy"'].join('\n');
      case 'csh':
        return ['# Aran · csh/tcsh', 'setenv http_proxy $http', 'setenv https_proxy $http',
          'setenv all_proxy $socks', 'setenv no_proxy $noProxy'].join('\n');
      case 'zsh':
        return ['# Aran · zsh', 'export http_proxy=$http', 'export https_proxy=$http',
          'export all_proxy=$socks', 'export no_proxy=$noProxy',
          'export HTTP_PROXY=\$http_proxy HTTPS_PROXY=\$https_proxy ALL_PROXY=\$all_proxy'].join('\n');
      default:
        return ['# Aran · bash/sh', 'export http_proxy=$http', 'export https_proxy=$http',
          'export all_proxy=$socks', 'export no_proxy=$noProxy',
          'export HTTP_PROXY="\$http_proxy" HTTPS_PROXY="\$https_proxy" ALL_PROXY="\$all_proxy"'].join('\n');
    }
  }

  /// True when this build embeds service templates (内嵌服务文件).
  bool get serviceTemplatesEmbedded =>
      ServiceUnit(kernelPath: kernel.binaryPath, dataDir: dataDir.path).hasEmbeddedTemplates;

  Future<void> setAccentColor(String hex) async {
    settings = settings.copyWith(accentColor: hex.trim());
    await _writeSettings();
    notifyListeners();
  }

  /// smartdns binaries found on this machine (for the settings dropdown).
  List<String> discoverSmartDns() {
    final found = SmartDns.discover();
    final explicit = settings.smartDnsPath.trim();
    if (explicit.isNotEmpty && File(explicit).existsSync() && !found.contains(explicit)) {
      return [explicit, ...found];
    }
    return found;
  }

  Future<String?> probeSmartDns(String path) => SmartDns.probeVersion(path);

  Future<void> setThemeStyle(String style) async {
    settings = settings.copyWith(themeStyle: style);
    await _writeSettings();
    notifyListeners();
  }

  Future<void> setUiScale(double scale) async {
    settings = settings.copyWith(uiScale: scale);
    await _writeSettings();
    notifyListeners();
  }

  Future<void> setCompactRail(bool value) async {
    settings = settings.copyWith(compactRail: value);
    await _writeSettings();
    notifyListeners();
  }

  Future<void> setThemeMode(String mode) async {
    settings = settings.copyWith(themeMode: mode);
    await _writeSettings();
    notifyListeners();
  }

  ThemeMode get themeMode => switch (settings.themeMode) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  String get nextThemeMode => switch (settings.themeMode) {
        'system' => 'light',
        'light' => 'dark',
        _ => 'system',
      };

  String get themeLabel => switch (settings.themeMode) {
        'light' => '浅色',
        'dark' => '深色',
        _ => '跟随系统',
      };

  Future<void> saveSettings(AranSettings next) async {
    final kernelChanged = next.kernelPath != settings.kernelPath;
    final kernelAffecting = next.mixedPort != settings.mixedPort ||
        next.autoPort != settings.autoPort ||
        next.allowLan != settings.allowLan ||
        next.ipv6 != settings.ipv6 ||
        next.logLevel != settings.logLevel ||
        next.geoAutoUpdate != settings.geoAutoUpdate ||
        next.unifiedDelay != settings.unifiedDelay ||
        next.tcpConcurrent != settings.tcpConcurrent ||
        next.snifferEnabled != settings.snifferEnabled ||
        next.dnsEnabled != settings.dnsEnabled ||
        next.dnsEnhancedMode != settings.dnsEnhancedMode ||
        next.fakeIpRange != settings.fakeIpRange ||
        next.nameservers.join(',') != settings.nameservers.join(',') ||
        next.fallback.join(',') != settings.fallback.join(',');

    settings = next.copyWith(takeover: takeover);
    notifier.notifyEnabled(settings.notifyEnabled);
    await _writeSettings();
    _startAutoUpdate();
    if (next.serviceScope != settings.serviceScope) {
      platform.serviceScope = next.serviceScope;
    }
    if (next.runMode == 'service') {
      _startServicePolling();
      unawaited(refreshServiceInfo());
    }
    if (next.runMode != settings.runMode &&
        next.systemProxy) {
      // Port moved (managed ⇄ service) — repoint the desktop proxy or it dies.
      unawaited(_refreshSystemProxyAfterSave(next));
    }
    if (kernelChanged) {
      // A different binary really does need a real restart.
      await kernel.stop();
      kernel = KernelManager(binary: resolveKernel(), dataDir: dataDir, onLog: _log);
      if (proxyRunning) await restartProxy();
      notifyListeners();
      return;
    }
    if (proxyRunning && kernelAffecting) {
      await _reloadOrRestart();
    } else {
      engine?.setTakeover(takeover);
      notifyListeners();
    }
  }

  Future<void> _writeSettings() async {
    try {
      await dataDir.create(recursive: true);
    systemDark = await _detectSystemDark();
      await _settingsFile.writeAsString(jsonEncode(settings.toJson()));
    } catch (e) {
      _log('[err] 设置保存失败：$e');
    }
  }

  // ---- profiles ----

  Future<void> activateProfile(String id) async {
    await profiles.activate(id);
    if (proxyRunning) {
      await _reloadOrRestart();
    } else {
      notifyListeners();
    }
  }

  Future<void> addProfileFromUrl(String url, {String? name}) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final p = await profiles.addFromUrl(url, name: name);
      if (proxyRunning && profiles.activeId == p.id) await _reloadOrRestart();
      _log('已导入配置：${p.name}（${(p.bytes / 1024).toStringAsFixed(0)} KB）');
    } catch (e) {
      error = '$e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> addProfileFromFile(String path, {String? name}) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final p = await profiles.addFromFile(path, name: name);
      if (proxyRunning && profiles.activeId == p.id) await _reloadOrRestart();
      _log('已导入配置：${p.name}');
    } catch (e) {
      error = '$e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<String> readProfileText(String id) => profiles.readConfig(id);

  Future<void> saveProfileMeta(String id, {String? name, String? url, int? autoUpdateHours}) async {
    busy = true;
    notifyListeners();
    try {
      await profiles.updateMeta(id, name: name, url: url, autoUpdateHours: autoUpdateHours);
      _log('已更新订阅信息：${name ?? ''}${url == null ? '' : ' · $url'}');
    } catch (e) {
      error = '$e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<bool> saveProfileText(String id, String text) async {
    if (!ConfigTransform.looksLikeMihomoConfig(text)) {
      error = '内容看起来不是 mihomo 配置（缺少 proxies / proxy-groups）';
      notifyListeners();
      return false;
    }
    busy = true;
    notifyListeners();
    try {
      await profiles.writeConfig(id, text);
      _log('已保存配置：${profiles.profiles.firstWhere((p) => p.id == id).name}');
      if (proxyRunning && profiles.active?.id == id) await _reloadOrRestart();
      return true;
    } catch (e) {
      error = '$e';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> updateProfile(String id, {bool viaProxy = false}) async {
    busy = true;
    notifyListeners();
    try {
      final addr = viaProxy ? '127.0.0.1:${kernel.activePorts['mixed'] ?? kernel.activePorts['http'] ?? 0}' : null;
      await profiles.update(id, proxyAddress: viaProxy ? addr : null);
      if (proxyRunning && profiles.active?.id == id) await _reloadOrRestart();
      _log('订阅已更新');
    } catch (e) {
      error = '$e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> removeProfile(String id) async {
    busy = true;
    notifyListeners();
    try {
      final wasActive = profiles.activeId == id;
      await profiles.remove(id);
      if (wasActive && proxyRunning) await _reloadOrRestart();
    } catch (e) {
      error = '$e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  // ---- controller actions ----

  Future<void> selectNode(String group, String node) async {
    try {
      await api?.select(group, node);
      _log('手动切换：$group → $node');
      _notice('$group → $node');
      notifyListeners();
    } catch (e) {
      error = '切换节点失败：$e';
      _notice(error!, ok: false);
      notifyListeners();
    }
  }

  Future<Map<String, int>> testGroupDelays(String group) async {
    try {
      return await api?.groupDelay(group) ?? const {};
    } catch (e) {
      error = '$e';
      return const {};
    }
  }

  Future<void> closeConnection(String id) async {
    try {
      await api?.closeConnection(id);
    } catch (e) {
      error = '$e';
    }
  }

  Future<void> setMode(String mode) async {
    try {
      await api?.setMode(mode);
      _log('出站模式：$mode');
      _notice('出站模式 → ${const {'rule': '规则', 'global': '全局', 'direct': '直连'}[mode] ?? mode}');
      notifyListeners();
    } catch (e) {
      error = '$e';
    }
  }

  Future<Map<String, dynamic>> fetchProxies() async {
    if (api == null) return const {};
    try {
      return await api!.proxies();
    } catch (_) {
      return const {};
    }
  }

  Future<List<dynamic>> fetchConnections() async {
    if (api == null) return const [];
    try {
      return await api!.connections();
    } catch (_) {
      return const [];
    }
  }

  /// (uploadTotal, downloadTotal) accumulated by the kernel since it started.
  Future<(int, int)> fetchTrafficTotals() async {
    if (api == null) return (0, 0);
    try {
      return await api!.connectionTotals();
    } catch (_) {
      return (0, 0);
    }
  }

  Future<String> fetchMode() async {
    if (api == null) return 'rule';
    try {
      return await api!.mode();
    } catch (_) {
      return 'rule';
    }
  }

  @override
  void dispose() {
    _stopWatchdog();
    _servicePoll?.cancel();
    engine?.dispose();
    api?.close();
    smartdns.stop();
    kernel.stop();
    super.dispose();
  }
}


extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
