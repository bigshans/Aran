import 'dart:io';

import 'platform.dart';

/// Linux implementation. Every assumption about "this machine" is written down
/// here — systemd, polkit, KDE/GNOME, glibc binaries — and nowhere else.
enum InitSystem { systemd, openrc, runit, none }

class LinuxPlatform implements AranPlatform {
  /// Detected once: what actually supervises services on this host.
  static InitSystem detectInit() {
    if (Directory('/run/systemd/system').existsSync()) return InitSystem.systemd;
    if (File('/sbin/openrc').existsSync() || Directory('/run/openrc').existsSync()) return InitSystem.openrc;
    if (Directory('/run/runit').existsSync() || File('/usr/bin/sv').existsSync()) return InitSystem.runit;
    return InitSystem.none;
  }

  InitSystem get init => detectInit();

  @override
  String get id => 'linux';

  @override
  String get exeSuffix => '';

  /// Portable when a `portable` marker sits next to the executable, or when
  /// ARAN_PORTABLE=1 is set (AppImage / unpacked tarball / USB stick).
  @override
  bool get portable {
    if (Platform.environment['ARAN_PORTABLE'] == '1') return true;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    return File('$exeDir/portable').existsSync();
  }

  @override
  bool get supportsSystemService => !portable && init != InitSystem.none;

  @override
  String get serviceKind => portable ? 'none' : init.name;

  @override
  Directory dataDir(String? xdgDataHome, String home) {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    // Not `<exeDir>/data`: Flutter keeps its own assets there.
    if (portable) return Directory('$exeDir/aran-data');
    return Directory('${xdgDataHome ?? '$home/.local/share'}/aran');
  }

  @override
  List<String> foreignConfigDirs(String home) => [
        '$home/.config/mihomo',
        '$home/.config/sparkle/work',
        '$home/.config/clash',
        '$home/.config/clash-verge',
        '$home/.config/io.github.clash-verge-rev.clash-verge-rev',
        '$home/.local/share/mihomo',
        '/etc/mihomo',
        '/usr/share/mihomo',
      ];

  @override
  List<String> geoAssetDirs(String home) => foreignConfigDirs(home);

  @override
  List<String> kernelNames() => const ['mihomo', 'clash-meta', 'clash'];

  @override
  List<String> kernelSearchPaths(String home) => [
        '/usr/bin/mihomo',
        '/usr/local/bin/mihomo',
        '/usr/bin/clash-meta',
        '/usr/bin/clash',
        '$home/.local/bin/mihomo',
        '$home/go/bin/clash',
      ];

  /// Names we accept as "a proxy kernel". Versioned builds (`mihomo-alpha`) are
  /// included; GUI bundles that happen to be called mihomo-* are not.
  static bool _looksLikeKernel(String base) {
    if (base == 'mihomo' || base == 'clash' || base == 'clash-meta' || base == 'mihomo-alpha') return true;
    if (base.startsWith('mihomo') || base.startsWith('clash-meta')) {
      const gui = ['party', 'verge', 'nyanpasu', 'nyanpasu', 'for', 'gui', 'desktop'];
      return !gui.any(base.toLowerCase().contains);
    }
    return false;
  }

  @override
  List<String> discoverKernels(String home) {
    final dirs = <String>{
      // PATH is the source of truth; everything else is a fallback.
      ...(Platform.environment['PATH'] ?? '').split(':').where((d) => d.isNotEmpty),
      '/usr/bin',
      '/usr/local/bin',
      '/usr/sbin',
      '/snap/bin',
      '$home/.local/bin',
      '$home/bin',
      '$home/go/bin',
      '$home/.local/share/aran/bin',
    };
    // /opt/*/bin and /opt/* are common for tarball installs.
    for (final root in ['/opt', '$home/.local/opt']) {
      final d = Directory(root);
      if (!d.existsSync()) continue;
      for (final e in d.listSync(followLinks: false)) {
        if (e is Directory) {
          dirs.add('${e.path}/bin');
          dirs.add(e.path);
        }
      }
    }

    final found = <String>{};
    for (final dir in dirs) {
      final d = Directory(dir);
      if (!d.existsSync()) continue;
      List<FileSystemEntity> entries;
      try {
        entries = d.listSync(followLinks: true);
      } catch (_) {
        continue;
      }
      for (final e in entries) {
        if (e is! File) continue;
        final base = e.path.split('/').last;
        if (!_looksLikeKernel(base)) continue;
        if (!_executable(e.path)) continue;
        found.add(e.path);
      }
    }

    // /bin → /usr/bin, /usr/sbin → /usr/bin symlinks would otherwise list the
    // same binary several times; dedupe by real path, keeping the shortest.
    final byReal = <String, String>{};
    for (final path in found) {
      String real;
      try {
        real = File(path).resolveSymbolicLinksSync();
      } catch (_) {
        real = path;
      }
      // Prefer the canonical /usr/bin path over its /bin alias.
      int ugly(String p0) => (p0.startsWith('/bin/') || p0.startsWith('/sbin/')) ? 1 : 0;
      final existing = byReal[real];
      if (existing == null ||
          ugly(path) < ugly(existing) ||
          (ugly(path) == ugly(existing) && path.length < existing.length)) {
        byReal[real] = path;
      }
    }

    // Rank: managed copy first, then plain mihomo, then clash-meta, then rest.
    final list = byReal.values.toList();
    int rank(String p) {
      final b = p.split('/').last;
      if (p.contains('/aran/bin/')) return 0;
      if (b == 'mihomo') return 1;
      if (b.startsWith('mihomo')) return 2;
      if (b == 'clash-meta') return 3;
      return 4;
    }

    list.sort((a, b) => rank(a).compareTo(rank(b)));
    return list;
  }

  static bool _executable(String path) {
    try {
      final mode = File(path).statSync().mode;
      return (mode & 0x49) != 0; // any execute bit
    } catch (_) {
      return false;
    }
  }

  @override
  List<String>? scriptCommand(String kind) {
    switch (kind) {
      case 'python':
        for (final p in ['/usr/bin/python3', '/usr/local/bin/python3']) {
          if (File(p).existsSync()) return ['python3'];
        }
        return ['python3'];
      default:
        return ['bash'];
    }
  }

  // ---- supervision: systemd today, and we say so when it is missing ----

  @override
  Future<bool> supervisorAvailable() async {
    final r = await Process.run('systemctl', ['--version']);
    return r.exitCode == 0;
  }

  @override
  bool serviceInstalled() {
    switch (init) {
      case InitSystem.systemd:
        return File('/etc/systemd/system/aran-kernel.service').existsSync();
      case InitSystem.openrc:
        return File('/etc/init.d/aran-kernel').existsSync();
      case InitSystem.runit:
        return File('/etc/sv/aran-kernel/run').existsSync();
      case InitSystem.none:
        return false;
    }
  }

  @override
  String serviceUnitPath() {
    switch (init) {
      case InitSystem.systemd:
        return '/etc/systemd/system/aran-kernel.service';
      case InitSystem.openrc:
        return '/etc/init.d/aran-kernel';
      case InitSystem.runit:
        return '/etc/sv/aran-kernel/run';
      case InitSystem.none:
        return '(unsupported)';
    }
  }

  @override
  Future<ProcessResult> installService({
    required String scriptPath,
    required String dataDir,
    required String kernelPath,
  }) async {
    // The unit/script body is generated by the caller into `scriptPath`.
    switch (init) {
      case InitSystem.systemd:
        return elevated(['install', '-m', '644', scriptPath, serviceUnitPath()]);
      case InitSystem.openrc:
        return elevated(['install', '-m', '755', scriptPath, serviceUnitPath()]);
      case InitSystem.runit:
        final dir = File(serviceUnitPath()).parent.path;
        final r = await elevated(['mkdir', '-p', dir]);
        if (r.exitCode != 0) return r;
        return elevated(['install', '-m', '755', scriptPath, serviceUnitPath()]);
      case InitSystem.none:
        return Future.value(ProcessResult(1, 0, '', 'no supported init system'));
    }
  }

  @override
  Future<ProcessResult> uninstallService(String scriptPath) => elevated(['bash', scriptPath]);

  @override
  Future<ProcessResult> controlService(String verb) {
    switch (init) {
      case InitSystem.systemd:
        return elevated(['systemctl', verb, 'aran-kernel.service']);
      case InitSystem.openrc:
        final action = verb == 'restart' ? 'restart' : verb == 'stop' ? 'stop' : 'start';
        return elevated(['rc-service', 'aran-kernel', action]);
      case InitSystem.runit:
        final action = verb == 'stop' ? 'down' : 'up';
        return elevated(['sv', action, 'aran-kernel']);
      case InitSystem.none:
        return Future.value(ProcessResult(1, 0, '', 'no supported init system'));
    }
  }

  @override
  Future<Map<String, String>> serviceStatus() async {
    final info = <String, String>{
      'installed': serviceInstalled() ? 'yes' : 'no',
      'init': init.name,
    };
    if (init != InitSystem.systemd) {
      // OpenRC/runit: report the unit presence only, liveness comes from the API.
      info['active'] = serviceInstalled() ? 'installed' : 'no-unit';
      info['enabled'] = 'n/a';
      return info;
    }
    try {
      info['active'] = '${(await Process.run('systemctl', ['is-active', 'aran-kernel.service'])).stdout}'.trim();
      info['enabled'] =
          '${(await Process.run('systemctl', ['is-enabled', 'aran-kernel.service'])).stdout}'.trim();
      info['pid'] =
          '${(await Process.run('systemctl', ['show', '-p', 'MainPID', '--value', 'aran-kernel.service'])).stdout}'
              .trim();
    } catch (_) {
      info['active'] = 'unknown';
    }
    return info;
  }

  @override
  Future<void> enableService() async {
    switch (init) {
      case InitSystem.systemd:
        await elevated(['systemctl', 'daemon-reload']);
        await elevated(['systemctl', 'enable', 'aran-kernel.service']);
      case InitSystem.openrc:
        await elevated(['rc-update', 'add', 'aran-kernel', 'default']);
      case InitSystem.runit:
        await elevated(['ln', '-sf', '/etc/sv/aran-kernel', '/var/service/aran-kernel']);
      case InitSystem.none:
        break;
    }
  }

  @override
  Future<ProcessResult> elevated(List<String> argv) async {
    // polkit first (session agent shows a prompt), sudo as a last resort.
    final hasPkexec = File('/usr/bin/pkexec').existsSync();
    if (hasPkexec) return Process.run('pkexec', argv);
    return Process.run('sudo', argv);
  }

  // ---- desktop proxy: whichever desktop is actually running ----

  bool get _isKde => (Platform.environment['XDG_CURRENT_DESKTOP'] ?? '').toUpperCase().contains('KDE');

  bool get _isGnome {
    final d = (Platform.environment['XDG_CURRENT_DESKTOP'] ?? '').toUpperCase();
    return d.contains('GNOME') || d.contains('UNITY') || d.contains('CINNAMON') || d.contains('BUDGIE');
  }

  @override
  String get desktopProxyLabel => _isKde ? 'KDE' : _isGnome ? 'GNOME' : '未识别桌面';

  @override
  Future<bool> desktopProxyActive() async {
    try {
      if (_isKde) {
        final r = await Process.run('kreadconfig6',
            ['--file', 'kioslaverc', '--group', 'Proxy Settings', '--key', 'ProxyType']);
        return '${r.stdout}'.trim() == '1';
      }
      if (_isGnome) {
        final r = await Process.run('gsettings', ['get', 'org.gnome.system.proxy', 'mode']);
        return '${r.stdout}'.contains('manual');
      }
    } catch (_) {}
    return false;
  }

  @override
  Future<void> setDesktopProxy(int port, {required bool enable}) async {
    if (_isKde) {
      final addr = 'http://127.0.0.1:$port';
      Future<void> set(String key, String value) =>
          Process.run('kwriteconfig6', ['--file', 'kioslaverc', '--group', 'Proxy Settings', '--key', key, value]);
      if (!enable) {
        await set('ProxyType', '0');
      } else {
        await set('ProxyType', '1');
        await set('httpProxy', addr);
        await set('httpsProxy', addr);
        await set('socksProxy', 'socks://127.0.0.1:$port');
        await set('NoProxyFor', 'localhost,127.0.0.1,::1');
      }
      await Process.run('dbus-send',
          ['--type=signal', '/KIO/Scheduler', 'org.kde.KIO.Scheduler.reparseSlaveConfiguration', 'string:']);
      return;
    }
    if (_isGnome) {
      Future<void> g(List<String> args) => Process.run('gsettings', args);
      if (!enable) {
        await g(['set', 'org.gnome.system.proxy', 'mode', 'none']);
        return;
      }
      await g(['set', 'org.gnome.system.proxy', 'mode', 'manual']);
      await g(['set', 'org.gnome.system.proxy.http', 'host', '127.0.0.1']);
      await g(['set', 'org.gnome.system.proxy.http', 'port', '$port']);
      await g(['set', 'org.gnome.system.proxy.https', 'host', '127.0.0.1']);
      await g(['set', 'org.gnome.system.proxy.https', 'port', '$port']);
      await g(['set', 'org.gnome.system.proxy', 'ignore-hosts', "['localhost','127.0.0.1','::1']"]);
      return;
    }
    throw StateError('当前桌面（${Platform.environment['XDG_CURRENT_DESKTOP'] ?? '未知'}）不支持自动设置系统代理');
  }

  @override
  Future<void> notify(String title, String body, {bool urgent = false}) async {
    try {
      await Process.run('notify-send', [
        if (urgent) ...['-u', 'critical'],
        '-a',
        'Aran',
        title,
        body,
      ]);
    } catch (_) {}
  }

  // ---- TUN: capabilities on the binary, no root daemon ----

  @override
  Future<bool> tunCapable(String kernelPath) async {
    try {
      final r = await Process.run('getcap', [kernelPath]);
      return '${r.stdout}'.contains('cap_net_admin');
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> grantTunCapability(String kernelPath) async {
    final r = await elevated(['setcap', 'cap_net_admin,cap_net_raw+eip', kernelPath]);
    return r.exitCode == 0;
  }

  File get _autostartFile {
    final home = Platform.environment['HOME'] ?? '.';
    return File('$home/.config/autostart/aran.desktop');
  }

  @override
  Future<bool> autoStartEnabled() async => _autostartFile.existsSync();

  @override
  Future<void> setAutoStart(bool enabled, {required String execPath, required String iconPath}) async {
    if (!enabled) {
      if (await _autostartFile.exists()) await _autostartFile.delete();
      return;
    }
    await _autostartFile.parent.create(recursive: true);
    await _autostartFile.writeAsString('''[Desktop Entry]
Type=Application
Name=Aran
Comment=Proxy scheduler
Exec=$execPath
Icon=$iconPath
Terminal=false
X-GNOME-Autostart-enabled=true
''');
  }

  @override
  Future<bool> isOurProcess(int pid, String needle) async {
    try {
      final cmdline = await File('/proc/$pid/cmdline').readAsString();
      return cmdline.contains(needle);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> makeExecutable(String path) async {
    try {
      await Process.run('chmod', ['+x', path]);
    } catch (_) {}
  }

  @override
  Future<void> openPath(String path) async {
    try {
      await Process.run('xdg-open', [path]);
    } catch (_) {}
  }
}
