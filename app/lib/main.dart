import 'dart:io';

import 'package:aran_core/aran_core.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/legacy.dart';

import 'src/app_state.dart';
import 'src/ui/common.dart';
import 'src/ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // A single widget exception should not leave a blank grey page: show what
  // broke and where, so the next bug is diagnosable from a screenshot.
  ErrorWidget.builder = (details) => Material(
        color: const Color(0xFFEDE7DB),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('界面渲染出错',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFFD0342C))),
              const SizedBox(height: 8),
              Text(
                '${details.exception}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Color(0xFF17171A)),
              ),
            ],
          ),
        ),
      );
  final home = Platform.environment['HOME'] ?? '.';
  // Path policy lives in the platform layer: XDG normally, app-local in
  // portable mode (marker file next to the executable or ARAN_PORTABLE=1).
  final dataDir = createPlatform().dataDir(Platform.environment['XDG_DATA_HOME'], home);
  // Single instance via pidfile. (flock would work too, but Dart's lock() blocks
  // instead of failing, which makes the second launch hang silently.)
  await dataDir.create(recursive: true);
  final pidFile = File('${dataDir.path}/aran.pid');
  if (await pidFile.exists()) {
    final pid = int.tryParse((await pidFile.readAsString()).trim());
    if (pid != null && pid != pid_self && await _isAranProcess(pid)) {
      await Process.run('notify-send', ['Aran', '已经有一个 Aran 在运行']);
      exit(0);
    }
  }
  await pidFile.writeAsString('$pid_self');
  ProcessSignal.sigterm.watch().listen((_) async {
    try {
      if ((await pidFile.readAsString()).trim() == '$pid_self') await pidFile.delete();
    } catch (_) {}
    exit(0);
  });

  final state = AppState(dataDir);
  await state.init();

  await windowManager.ensureInitialized();
  // Keep the floor低 enough to fit a 1366x768 screen at 125% scaling; a too-large
  // minimumSize is the usual reason a window "won't resize".
  const windowOptions = WindowOptions(
    size: Size(1280, 800),
    minimumSize: Size(820, 520),
    center: true,
    title: 'Aran',
    titleBarStyle: TitleBarStyle.normal,
    skipTaskbar: false,
  );
  final startHidden = state.settings.trayEnabled && state.settings.startMinimized;
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    if (startHidden) {
      // Lightweight mode: never map the window. Calling hide() on a mapped
      // window is reverted by the compositor on first map, so stay unmapped.
      await windowManager.setSkipTaskbar(true);
    } else {
      await windowManager.show();
      await windowManager.focus();
    }
    // Make sure nothing left the window locked to a fixed size.
    await windowManager.setResizable(true);
    await windowManager.setMinimumSize(const Size(820, 520));
    // Windows sometimes maps the window at a stale or absurd geometry (it can
    // end up as a 90 px sliver on the right edge of the screen), which makes the
    // whole layout collapse. Clamp to a sane size and re-centre.
    final bounds = await windowManager.getBounds();
    if (bounds.width < 700 || bounds.height < 400) {
      await windowManager.setSize(const Size(1280, 800));
      await windowManager.setAlignment(Alignment.center);
    }
  });

  // Never leave an orphan kernel behind when the window is closed with a signal.
  // Windows has no POSIX signals: watching SIGTERM throws OS Error 50 and takes
  // the whole app down, so this is POSIX-only.
  if (!Platform.isWindows) {
    for (final sig in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
      sig.watch().listen((_) async {
        await state.stopProxy();
        exit(0);
      });
    }
  }

  runApp(AranApp(state: state));
}

int get pid_self => pid;

/// Is this pid really an Aran instance (guards against pid reuse)?
Future<bool> _isAranProcess(int pid) async {
  try {
    final cmdline = await File('/proc/$pid/cmdline').readAsString();
    return cmdline.contains('aran_app');
  } catch (_) {
    return false;
  }
}

class AranApp extends StatefulWidget {
  final AppState state;
  const AranApp({super.key, required this.state});

  @override
  State<AranApp> createState() => _AranAppState();
}

class _AranAppState extends State<AranApp> {
  AppState get state => widget.state;

  String _themeSig = '';

  String get _style => state.settings.themeStyle;

  @override
  void initState() {
    super.initState();
    _themeSig = _sig();
    state.addListener(_onState);
  }

  @override
  void dispose() {
    state.removeListener(_onState);
    super.dispose();
  }

  String _sig() =>
      '${state.settings.themeMode}|${state.settings.themeStyle}|${state.settings.uiScale}|${state.settings.accentColor}';

  /// Only rebuild the MaterialApp (and thus the whole tree) when theme-related
  /// settings change. Rebuilding it on every log line caused visible churn while
  /// the window was being resized.
  void _onState() {
    final sig = _sig();
    if (sig == _themeSig) return;
    _themeSig = sig;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (context) => MaterialApp(
        title: 'Aran',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light, style: _style, accent: state.settings.accentColor),
        darkTheme: buildTheme(Brightness.dark, style: _style, accent: state.settings.accentColor),
        themeMode: state.themeMode,
        builder: (context, child) {
          // Resolve once per frame, before any descendant builds: every widget
          // reads the palette through getters in common.dart.
          final brightness = switch (state.settings.themeMode) {
            'light' => Brightness.light,
            'dark' => Brightness.dark,
            _ => state.systemDark ? Brightness.dark : Brightness.light,
          };
          usePalette(brightness,
              style: state.settings.themeStyle, accent: state.settings.accentColor);
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(state.settings.uiScale),
            ),
            child: child ?? const SizedBox.shrink(),
          );
        },
        scrollBehavior: const AranScrollBehavior(),
        home: Shell(state: state),
      ),
    );
  }
}
