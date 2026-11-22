import 'dart:async';

import 'api.dart';
import 'model.dart';

/// Passive observation: learn real per-node throughput from live connections.
///
/// Costs nothing — no probe traffic, no radio wakeups. If the user is idle there
/// is simply no data, which is exactly what we want on battery.
class Observer {
  final MihomoApi api;

  /// Per-connection cumulative bytes, keyed by connection id. Sampling the
  /// delta per connection (instead of per node totals) is what makes short-lived
  /// connections visible at all: `/connections` only lists live sockets, so a
  /// node-level diff silently loses everything that closed between two polls.
  final Map<String, int> _connBytes = {};
  DateTime? _prevAt;
  bool activity = false;

  /// Total bytes seen since start (monotonic).
  int totalBytes = 0;

  /// Active connection count per node.
  final Map<String, int> activePerNode = {};

  Observer(this.api);

  Future<void> poll(Map<String, NodeState> nodes, DateTime now) async {
    List<dynamic> conns;
    try {
      conns = await api.connections();
    } catch (_) {
      return;
    }

    final seen = <String, int>{};
    final deltaPerNode = <String, int>{};
    final active = <String, int>{};
    final nowAt = now;
    final secs = _prevAt == null ? 0.0 : nowAt.difference(_prevAt!).inMilliseconds / 1000.0;

    for (final raw in conns) {
      if (raw is! Map) continue;
      final chains = (raw['chains'] as List?)?.cast<dynamic>() ?? const [];
      String? nodeName;
      for (final c in chains) {
        if (nodes.containsKey(c)) {
          nodeName = c as String;
          break;
        }
      }
      if (nodeName == null) continue;

      final id = (raw['id'] as String?) ?? raw['start']?.toString() ?? nodeName;
      final bytes = ((raw['upload'] as num?)?.toInt() ?? 0) + ((raw['download'] as num?)?.toInt() ?? 0);
      seen[id] = bytes;
      active[nodeName] = (active[nodeName] ?? 0) + 1;

      final prev = _connBytes[id] ?? 0;
      final delta = bytes - prev;
      if (delta > 0) {
        deltaPerNode[nodeName] = (deltaPerNode[nodeName] ?? 0) + delta;
      }
    }

    _connBytes
      ..clear()
      ..addAll(seen);

    activePerNode
      ..clear()
      ..addAll(active);

    var deltaTotal = 0;
    deltaPerNode.forEach((name, delta) {
      deltaTotal += delta;
      final node = nodes[name];
      if (node == null) return;
      node.observedBytes += delta;
      // Only trust samples that carried enough bytes over enough time.
      if (delta >= 100000 && secs >= 0.25) {
        node.recordThroughput(delta / 1e6 / secs, secs); // MB/s
      }
    });

    totalBytes += deltaTotal;
    activity = deltaTotal > 0;
    _prevAt = nowAt;
  }

  /// True if no traffic has been observed for [window].
  bool isIdle(DateTime now, {Duration window = const Duration(seconds: 180)}) {
    // Before the first poll completes we know nothing; assume busy so the
    // warm-up sweep is allowed to run.
    if (_prevAt == null) return false;
    if (activity) {
      _lastActivity = now;
      return false;
    }
    final last = _lastActivity;
    if (last == null) return true;
    return now.difference(last) > window;
  }

  DateTime? _lastActivity;
}
