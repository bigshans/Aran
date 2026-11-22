/// Node bookkeeping: everything Aran knows about a single proxy node.
class NodeState {
  final String name;

  /// Billing multiplier parsed from the node name (`x0.1`, `x2.0`); 1.0 if absent.
  final double multiplier;

  /// EWMA of probe round-trip time (ms). null until first successful probe.
  double? delayEwma;

  /// EWMA of |delay - delayEwma| (ms).
  double jitterEwma = 0;

  /// Consecutive failed probes. 2 == declared dead.
  int failStreak = 0;

  /// Ring buffer of recent probe outcomes (true = ok).
  final List<bool> history = <bool>[];

  DateTime? lastProbeAt;
  DateTime? lastOkAt;
  String? lastError;

  /// Passive throughput: EWMA of observed MB/s, weighted by sample duration.
  double throughputMbps = 0;
  double throughputSeconds = 0;

  /// Bytes observed on this node since Aran started.
  int observedBytes = 0;

  /// Currently active connections routed through this node.
  int activeConnections = 0;

  NodeState({required this.name, required this.multiplier});

  static final RegExp _multRe = RegExp(r'[xX×]\s*([0-9]+(?:\.[0-9]+)?)');

  static double parseMultiplier(String name) {
    final matches = _multRe.allMatches(name);
    if (matches.isEmpty) return 1.0;
    final v = double.tryParse(matches.last.group(1)!);
    if (v == null || v <= 0) return 1.0;
    return v;
  }

  double get failRate {
    if (history.isEmpty) return 0;
    final fails = history.where((ok) => !ok).length;
    return fails / history.length;
  }

  bool get alive => failStreak < 2;

  /// Has this node ever been probed?
  bool get probed => lastProbeAt != null;

  /// Minimum passive observation before throughput is considered meaningful.
  static const double minThroughputSeconds = 1.0;

  /// Do we have enough real traffic samples to trust a throughput number?
  bool get hasThroughput => throughputSeconds >= minThroughputSeconds;

  void recordProbe(DateTime at, ProbeOutcomeLike outcome) {
    lastProbeAt = at;
    final list = List<bool>.from(history)..add(outcome.ok);
    history
      ..clear()
      ..addAll(list.length > 20 ? list.sublist(list.length - 20) : list);

    if (outcome.ok && outcome.rttMs != null) {
      failStreak = 0;
      lastOkAt = at;
      lastError = null;
      final rtt = outcome.rttMs!.toDouble();
      final prev = delayEwma;
      if (prev == null) {
        delayEwma = rtt;
        jitterEwma = 0;
      } else {
        delayEwma = prev * 0.7 + rtt * 0.3;
        final dev = (rtt - prev).abs();
        jitterEwma = jitterEwma * 0.7 + dev * 0.3;
      }
    } else {
      failStreak++;
      lastError = outcome.error;
    }
  }

  /// Feed a passively observed throughput sample (MB/s over [seconds]).
  void recordThroughput(double mbps, double seconds) {
    if (seconds <= 0) return;
    final w = seconds.clamp(0.0, 10.0);
    final total = throughputSeconds + w;
    throughputMbps = (throughputMbps * throughputSeconds + mbps * w) / total;
    throughputSeconds = total;
  }
}

/// Structural stand-in so model doesn't depend on api.dart.
class ProbeOutcomeLike {
  final bool ok;
  final int? rttMs;
  final String? error;
  const ProbeOutcomeLike({required this.ok, this.rttMs, this.error});
}
