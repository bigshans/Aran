import 'dart:io';

import 'platform/factory.dart';

/// Kernels owned by the user (downloaded on demand into the data directory).
/// Nothing is shipped inside the app bundle: distro packaging and GPL licensing
/// both prefer that the binary stays outside the application package.
///
/// Relying on whatever `mihomo` happens to be in PATH makes Aran fragile on
/// machines that don't have it (or have a 3-year-old build). The app therefore
/// supports a bundled copy under `assets/bin/`, extracted once into the data
/// directory and preferred over the system binary.
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
    await target.parent.create(recursive: true);
    final stale = !await target.exists() ||
        await target.length() != await source.length() ||
        (await target.lastModified()).isBefore(await source.lastModified());
    if (stale) {
      await source.copy(target.path);
      await createPlatform().makeExecutable(target.path);
    }
    return target.path;
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
