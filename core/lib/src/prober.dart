import 'dart:async';

import 'api.dart';
import 'model.dart';

/// Layered probe scheduler.
///
/// Budget rule: spend almost everything on the node we are actually using and on
/// the few that could replace it. The rest of the pool is refreshed slowly.
class ProbeScheduler {
  final MihomoApi api;

  Duration currentInterval;
  Duration candidateInterval;
  Duration restInterval;
  Duration idleInterval;
  int maxConcurrent;

  /// Burst guard: never start more than this many probes in a single tick.
  int maxLaunchPerTick = 8;

  /// Probe target and timeout (configurable in settings).
  String testUrl = 'https://cp.cloudflare.com/generate_204';
  int testTimeoutMs = 5000;

  /// Idle = no observed traffic. Collapses to a single heartbeat.
  bool idle = false;

  final Set<String> _inflight = {};
  int probeCount = 0;
  int failCount = 0;

  ProbeScheduler(
    this.api, {
    this.currentInterval = const Duration(seconds: 10),
    this.candidateInterval = const Duration(seconds: 60),
    this.restInterval = const Duration(seconds: 600),
    this.idleInterval = const Duration(seconds: 60),
    this.maxConcurrent = 6,
  });

  bool get busy => _inflight.isNotEmpty;

  /// [current]: the node in use. [candidates]: nodes that could take over (best first).
  /// [all]: the whole usable pool.
  Future<void> tick({
    required Map<String, NodeState> nodes,
    required String? current,
    required List<String> candidates,
    required DateTime now,
  }) async {
    final due = <(String, int)>[]; // (name, overdue ms)

    for (final n in nodes.values) {
      if (_inflight.contains(n.name)) continue;

      // Warm-up first: a node we have never measured cannot be judged at all,
      // so it is due immediately regardless of idle mode or tier.
      final last = n.lastProbeAt;
      if (last == null) {
        due.add((n.name, 1 << 30));
        continue;
      }

      final isCurrent = n.name == current;
      final candIdx = candidates.indexOf(n.name);
      final Duration? interval;
      if (idle) {
        interval = isCurrent ? idleInterval : null;
      } else if (isCurrent) {
        interval = currentInterval;
      } else if (candIdx >= 0 && candIdx < 3) {
        interval = candidateInterval;
      } else {
        interval = restInterval;
      }
      if (interval == null) continue;

      final elapsed = now.difference(last);
      if (elapsed >= interval) due.add((n.name, elapsed.inMilliseconds - interval.inMilliseconds));
    }

    due.sort((a, b) => b.$2.compareTo(a.$2));

    var launched = 0;
    for (final entry in due) {
      if (_inflight.length >= maxConcurrent || launched >= maxLaunchPerTick) break;
      launched++;
      final name = entry.$1;
      _inflight.add(name);
      final node = nodes[name]!;
      unawaited(api.probe(name, url: testUrl, timeoutMs: testTimeoutMs).then((outcome) {
        node.recordProbe(DateTime.now(), ProbeOutcomeLike(ok: outcome.ok, rttMs: outcome.rttMs, error: outcome.error));
        probeCount++;
        if (!outcome.ok) failCount++;
      }).whenComplete(() => _inflight.remove(name)));
    }
  }
}
