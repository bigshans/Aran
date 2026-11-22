import 'dart:io';

import 'platform.dart';

/// Windows implementation.
///
/// Design notes (things that differ fundamentally from Linux):
///  * no systemd: the supervisor is the Windows Service Manager (`sc.exe`), and
///    running a service needs the caller to be elevated (UAC);
///  * TUN needs `wintun.dll` next to the kernel **and** administrator rights —
///    there is no `setcap` equivalent, so capability is per-run;
///  * the system proxy is a per-user registry setting
///    (`HKCU\...\Internet Settings`), applied via `reg.exe`;
///  * notifications go through PowerShell (no notify-send);
///  * paths use `%LOCALAPPDATA%`, and a portable build keeps everything next to
///    the executable.
class WindowsPlatform implements AranPlatform {
  static const _serviceName = 'AranKernel';

  @override
  String get id => 'windows';

  @override
  String get exeSuffix => '.exe';

  String get _localAppData =>
      Platform.environment['LOCALAPPDATA'] ?? '${Platform.environment['USERPROFILE']}/AppData/Local';

  String get _appData => Platform.environment['APPDATA'] ?? '${Platform.environment['USERPROFILE']}/AppData/Roaming';

  String get _userProfile => Platform.environment['USERPROFILE'] ?? '.';

  @override
  bool get portable {
    if (Platform.environment['ARAN_PORTABLE'] == '1') return true;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    return File('$exeDir\\portable').existsSync() || File('$exeDir/portable').existsSync();
  }

  @override
  bool get supportsSystemService => !portable;

  @override
  String get serviceKind => portable ? 'none' : 'winsw';

  @override
  String serviceScope = 'system';

  @override
  Directory dataDir(String? xdgDataHome, String home) {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    if (portable) return Directory('$exeDir\\aran-data');
    return Directory('$_localAppData\\Aran');
  }

  @override
  List<String> foreignConfigDirs(String home) => [
        '$_userProfile\\.config\\mihomo',
        '$_appData\\io.github.clash-verge-rev.clash-verge-rev',
        '$_appData\\clash-verge',
        '$_localAppData\\mihomo',
        '$_userProfile\\.config\\clash',
      ];

  @override
  List<String> geoAssetDirs(String home) => foreignConfigDirs(home);

  @override
  List<String> kernelNames() => const ['mihomo', 'clash-meta', 'clash'];

  @override
  List<String> kernelSearchPaths(String home) => [
        '$_localAppData\\Aran\\bin\\mihomo.exe',
        '$_userProfile\\scoop\\shims\\mihomo.exe',
        'C:\\ProgramData\\chocolatey\\bin\\mihomo.exe',
        'C:\\Program Files\\mihomo\\mihomo.exe',
      ];

  @override
  List<String> discoverKernels(String home) {
    final dirs = <String>{
      ...(Platform.environment['PATH'] ?? '').split(';').where((d) => d.trim().isNotEmpty),
      '$_localAppData\\Aran\\bin',
      '$_userProfile\\scoop\\shims',
      'C:\\ProgramData\\chocolatey\\bin',
    };
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
        final base = e.path.split(RegExp(r'[\\/]')).last.toLowerCase();
        if (base == 'mihomo.exe' ||
            base == 'clash-meta.exe' ||
            base == 'clash.exe' ||
            base.startsWith('mihomo-') && base.endsWith('.exe')) {
          found.add(e.path);
        }
      }
    }
    return found.toList();
  }

  @override
  List<String>? scriptCommand(String kind) {
    // python is only needed for the watchdog; on Windows we use PowerShell.
    switch (kind) {
      case 'python':
        return null;
      default:
        return ['powershell', '-NoProfile', '-Command'];
    }
  }

  // ---- supervision: Windows Service Manager ----

  @override
  Future<bool> supervisorAvailable() async {
    final r = await Process.run('sc.exe', ['query']);
    return r.exitCode == 0;
  }

  @override
  bool serviceInstalled() {
    final r = Process.runSync('sc.exe', ['query', _serviceName]);
    return r.exitCode == 0;
  }

  @override
  String serviceUnitPath() => 'sc.exe:$_serviceName';

  @override
  Future<ProcessResult> installService({
    required String scriptPath,
    required String dataDir,
    required String kernelPath,
  }) async {
    // `binPath` must be one quoted argument; sc.exe needs the space after '='.
    final bin = '"$kernelPath" -d "$dataDir"';
    return elevated(['sc.exe', 'create', _serviceName, 'binPath=', bin, 'start=', 'auto']);
  }

  @override
  Future<ProcessResult> uninstallService(String scriptPath) =>
      elevated(['sc.exe', 'delete', _serviceName]);

  @override
  Future<ProcessResult> controlService(String verb) {
    final action = switch (verb) {
      'restart' => 'restart', // handled below
      'stop' => 'stop',
      _ => 'start',
    };
    if (verb == 'restart') return elevated(['sc.exe', 'stop', _serviceName]);
    return elevated(['sc.exe', action, _serviceName]);
  }

  @override
  Future<Map<String, String>> serviceStatus() async {
    final info = <String, String>{'installed': serviceInstalled() ? 'yes' : 'no', 'init': 'winsw'};
    try {
      final r = await Process.run('sc.exe', ['query', _serviceName]);
      final text = '${r.stdout}';
      info['active'] = text.contains('RUNNING')
          ? 'active'
          : text.contains('STOPPED')
              ? 'inactive'
              : 'unknown';
      info['enabled'] = 'auto';
    } catch (_) {
      info['active'] = 'unknown';
    }
    return info;
  }

  @override
  Future<void> enableService() async {
    await elevated(['sc.exe', 'config', _serviceName, 'start=', 'auto']);
  }

  @override
  Future<ProcessResult> elevated(List<String> argv) async {
    // UAC prompt; -Wait so we can report the exit code. Arguments are joined
    // into a single -ArgumentList string, hence the quoting.
    return Process.run('powershell', [
      '-NoProfile',
      '-Command',
      'Start-Process -FilePath "\${argv[0]}" '
          '-ArgumentList \'${argv.skip(1).map((a) => a.contains(" ") ? '"$a"' : a).join(" ")}\' '
          '-Verb RunAs -Wait -PassThru | Select-Object -ExpandProperty ExitCode',
    ]);
  }

  // ---- desktop proxy: per-user registry ----

  Future<bool> _isElevatedAdmin() async {
    final r = await Process.run('net', ['session']);
    return r.exitCode == 0;
  }

  @override
  String get desktopProxyLabel => 'Windows（IE/WinINet 设置）';

  @override
  Future<bool> desktopProxyActive() async {
    final r = await Process.run('reg', [
      'query',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
      '/v',
      'ProxyEnable',
    ]);
    return '${r.stdout}'.contains('0x1');
  }

  @override
  Future<void> setDesktopProxy(int port, {required bool enable}) async {
    const key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
    if (enable) {
      await Process.run('reg', ['add', key, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '1', '/f']);
      await Process.run(
          'reg', ['add', key, '/v', 'ProxyServer', '/t', 'REG_SZ', '/d', '127.0.0.1:$port', '/f']);
      await Process.run('reg', [
        'add', key, '/v', 'ProxyOverride', '/t', 'REG_SZ', '/d', '<local>;127.0.0.1;::1', '/f',
      ]);
    } else {
      await Process.run('reg', ['add', key, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '0', '/f']);
    }
    // Notify WinINet hosts that settings changed.
    await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      r'$s=Add-Type -MemberDefinition "[DllImport(\"wininet.dll\")]public static extern bool InternetSetOption(IntPtr h,int o,IntPtr b,int l);" -Name W -PassThru; [W]::InternetSetOption([IntPtr]::Zero,39,[IntPtr]::Zero,0); [W]::InternetSetOption([IntPtr]::Zero,37,[IntPtr]::Zero,0)',
    ]);
  }

  static String _psQuote(String v) => v.replaceAll('"', "'").replaceAll('`', '');

  @override
  Future<void> notify(String title, String body, {bool urgent = false}) async {
    // PowerShell balloon tip: the only notification path without a plugin.
    final script = [
      'Add-Type -AssemblyName System.Windows.Forms',
      r'$n = New-Object System.Windows.Forms.NotifyIcon',
      r'$n.Icon = [System.Drawing.SystemIcons]::Information',
      r'$n.Visible = $true',
      '\$n.ShowBalloonTip(4000, "${_psQuote(title)}", "${_psQuote(body)}", 1)',
      'Start-Sleep -Seconds 4',
      r'$n.Dispose()',
    ].join('; ');
    try {
      await Process.run('powershell', ['-NoProfile', '-Command', script]);
    } catch (_) {}
  }

  // ---- TUN: wintun.dll + admin, no capability equivalent ----

  Future<bool> _hasWintun(String kernelPath) async {
    final dir = File(kernelPath).parent.path;
    return File('$dir\\wintun.dll').existsSync() || File('wintun.dll').existsSync();
  }

  @override
  Future<bool> tunCapable(String kernelPath) async =>
      await _isElevatedAdmin() && await _hasWintun(kernelPath);

  @override
  Future<bool> grantTunCapability(String kernelPath) async {
    // Windows has no setcap: TUN requires running elevated, and wintun.dll must
    // sit next to mihomo.exe. Report what is missing instead of pretending.
    final wintun = await _hasWintun(kernelPath);
    final admin = await _isElevatedAdmin();
    if (!wintun || !admin) return false;
    return true;
  }

  @override
  Future<void> openPath(String path) async {
    try {
      await Process.run('explorer.exe', [path]);
    } catch (_) {}
  }

  @override
  Future<void> makeExecutable(String path) async {
    // Windows has no execute bit.
  }

  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  @override
  Future<bool> autoStartEnabled() async {
    final r = await Process.run('reg', ['query', _runKey, '/v', 'Aran']);
    return r.exitCode == 0 && '${r.stdout}'.contains('Aran');
  }

  @override
  Future<void> setAutoStart(bool enabled, {required String execPath, required String iconPath}) async {
    if (enabled) {
      await Process.run('reg', ['add', _runKey, '/v', 'Aran', '/t', 'REG_SZ', '/d', '"$execPath"', '/f']);
    } else {
      await Process.run('reg', ['delete', _runKey, '/v', 'Aran', '/f']);
    }
  }

  @override
  Future<bool> isOurProcess(int pid, String needle) async {
    try {
      final r = await Process.run('tasklist.exe', ['/FI', 'PID eq $pid', '/FO', 'CSV', '/NH']);
      final out = '${r.stdout}'.trim();
      if (out.isEmpty || out.contains('No tasks')) return false;
      final name = out.split(',').first.replaceAll('"', '').toLowerCase();
      return name.contains(needle.toLowerCase()) || name.contains('mihomo');
    } catch (_) {
      return false;
    }
  }
}
