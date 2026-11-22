import 'dart:io';

/// Everything Aran does that is bound to a specific operating system lives
/// behind this interface.
///
/// The point is not abstraction for its own sake: the rules for "where do I put
/// data", "how do I start a daemon", "how do I ask for elevation", "how does the
/// desktop proxy work" differ completely between distributions (systemd vs
/// OpenRC), desktops (KDE vs GNOME) and OSes (Windows UAC, Android VpnService).
/// Hardcoding any of them makes the app a one-machine program.
abstract class AranPlatform {
  String get id; // linux | windows | macos | android

  /// Executable suffix (`.exe` on Windows, empty elsewhere).
  String get exeSuffix;

  /// Portable build: everything lives next to the executable, no system
  /// integration (no systemd unit, no autostart entry, no /etc writes).
  bool get portable;

  /// Does this host/deployment support a system service supervisor?
  bool get supportsSystemService;

  /// Which supervisor: systemd | systemd-user | openrc | runit | none.
  String get serviceKind;

  /// Scope for the systemd supervisor: `user` (no root) or `system` (elevated).
  String get serviceScope;
  set serviceScope(String value);

  /// Per-user writable state (config, runtime config, logs, snapshots).
  Directory dataDir(String? xdgDataHome, String home);

  /// Per-user config root — where other clients keep their config, used to seed
  /// imports and to find geo assets.
  List<String> foreignConfigDirs(String home);

  /// Directories searched for geo assets (Country.mmdb, geosite.dat …).
  List<String> geoAssetDirs(String home);

  /// Names to look for on PATH when no bundled/system kernel path is configured.
  List<String> kernelNames();

  /// Absolute paths worth probing before PATH (may be empty).
  List<String> kernelSearchPaths(String home);

  /// Dynamic discovery: scan PATH + well-known bin dirs for anything that looks
  /// like a proxy kernel, instead of relying on a fixed list of absolute paths.
  List<String> discoverKernels(String home);

  /// How to run a helper script of the given kind (`python`, `shell`).
  /// Returns null when no interpreter is available on this machine.
  List<String>? scriptCommand(String kind);

  // ---- supervision ----
  Future<bool> supervisorAvailable();
  bool serviceInstalled();
  String serviceUnitPath();
  Future<ProcessResult> installService({
    required String scriptPath,
    required String dataDir,
    required String kernelPath,
  });
  Future<ProcessResult> uninstallService(String scriptPath);
  Future<ProcessResult> controlService(String verb); // start|stop|restart
  Future<Map<String, String>> serviceStatus();

  /// Reload the supervisor and enable the unit at boot.
  Future<void> enableService();

  // ---- privileges ----
  /// Run a command with elevation (pkexec/sudo, UAC, …). Callers handle the
  /// case where the user cancels.
  Future<ProcessResult> elevated(List<String> argv);

  // ---- desktop integration ----
  Future<bool> desktopProxyActive();
  Future<void> setDesktopProxy(int port, {required bool enable});
  String get desktopProxyLabel;

  Future<void> notify(String title, String body, {bool urgent = false});

  // ---- TUN ----
  Future<bool> tunCapable(String kernelPath);
  Future<bool> grantTunCapability(String kernelPath);

  Future<void> openPath(String path);

  /// chmod +x equivalent.
  Future<void> makeExecutable(String path);

  /// Login autostart (XDG autostart file on Linux, HKCU Run key on Windows).
  Future<bool> autoStartEnabled();
  Future<void> setAutoStart(bool enabled, {required String execPath, required String iconPath});

  /// Is [pid] the process we think it is? Guards pid reuse before we signal it.
  Future<bool> isOurProcess(int pid, String needle);
}
