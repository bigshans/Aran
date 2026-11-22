import 'dart:io';

import 'platform/factory.dart';

/// Kernel binaries, in two shapes:
///
///  * **内嵌内核** — shipped inside the app package at `assets/bin/<name>[.exe]`
///    (built with `scripts/build-app.sh --kernel …`). Extracted once into the
///    data dir so it can be executed and upgraded independently of the package.
///  * **已下载内核** — fetched at runtime into `<data>/bin/<name>`.
///
/// A third source is the system binary found by the platform adapter, used when
/// neither of the above exists.
class Bundled {
  /// Directory the Flutter bundle keeps its assets in.
  static Directory get assetsDir =>
      Directory('${File(Platform.resolvedExecutable).parent.path}/data/flutter_assets/assets');

  static String get _exeName => Platform.isWindows ? '.exe' : '';

  /// Where a user-installed / downloaded kernel lives: `<data>/bin/<name>`.
  static String managedPath(String name, Directory dataDir) =>
      '${dataDir.path}/bin/$name$_exeName';

  /// Bootstrap copy shipped next to the app, if this build flavour includes one.
  /// Optional by design: slim/packaged builds ship nothing, portable builds may
  /// carry the binary so a machine with no kernel and no network still works.
  static Future<String?> extract(String name, Directory dataDir) async {
    final source = File('${assetsDir.path}/bin/$name$_exeName');
    if (!await source.exists()) return null;

    final target = File(managedPath(name, dataDir));
    try {
      await target.parent.create(recursive: true);
      final stale = !await target.exists() ||
          await target.length() != await source.length() ||
          (await target.lastModified()).isBefore(await source.lastModified());
      if (stale) {
        await source.copy(target.path);
        await createPlatform().makeExecutable(target.path);
      }
      // The copy must actually be runnable; if not, fall through to the asset
      // (read-only data dir, noexec mount, wrong permissions after upgrade).
      if (await _runnable(target.path)) return target.path;
    } catch (_) {
      // Extraction failed (read-only $HOME, full disk, noexec tmpfs …).
    }
    return await _runnable(source.path) ? source.path : target.path;
  }

  /// Cheap check: file exists and can be spawned at all.
  static Future<bool> _runnable(String path) async {
    final f = File(path);
    if (!await f.exists()) return false;
    try {
      final r = await Process.run(path, ['-v'], stdoutEncoding: null, stderrEncoding: null);
      // Any exit code is fine: mihomo -v returns 0, but we only care that the
      // kernel actually started (an EACCES/EACCES shows up as exitCode -1/126).
      return r.exitCode != 126 && r.exitCode != 127;
    } catch (_) {
      return false;
    }
  }

  static String? bundledPath(String name) {
    final f = File('${assetsDir.path}/bin/$name$_exeName');
    return f.existsSync() ? f.path : null;
  }

  /// Path of an already downloaded kernel, or null.
  static String? existing(String name, Directory dataDir) {
    final f = File(managedPath(name, dataDir));
    return f.existsSync() ? f.path : null;
  }
}
