import 'dart:async';
import 'dart:io';

/// Desktop notifications, no plugin: Linux desktops all ship `notify-send`.
/// Failures are swallowed on purpose — a missing notifier must never break the
/// proxy, it only means you don't get the popup.
class Notifier {
  bool enabled;
  final void Function(String line)? onLog;

  Notifier({this.enabled = true, this.onLog});

  void notifyEnabled(bool value) => enabled = value;

  Future<void> send(String title, String body, {bool urgent = false}) async {
    if (!enabled) return;
    try {
      final r = await Process.run('notify-send', [
        if (urgent) ...['-u', 'critical'],
        '-a', 'Aran',
        title,
        body,
      ]);
      if (r.exitCode != 0) onLog?.call('[notify] ${r.stderr}');
    } catch (e) {
      onLog?.call('[notify] $e');
    }
  }
}
