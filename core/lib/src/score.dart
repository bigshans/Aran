import 'dart:math' as math;

import 'model.dart';

/// Fully explainable score breakdown. Every number here can be shown to the user.
class Score {
  final double latency; // L
  final double reliability; // R
  final double stability; // S
  final double throughput; // T
  final double quality;
  final double multiplier;
  final double costFactor;
  final double finalScore;

  const Score({
    required this.latency,
    required this.reliability,
    required this.stability,
    required this.throughput,
    required this.quality,
    required this.multiplier,
    required this.costFactor,
    required this.finalScore,
  });

  static const double wLatency = 0.40;
  static const double wReliability = 0.30;
  static const double wStability = 0.15;
  static const double wThroughput = 0.15;

  /// multiplier exponent (alpha) — 0 disables cost awareness.
  static const double alpha = 0.5;

  /// Hard cap on how much a cheap node may be favoured / an expensive node punished.
  /// Without the cap, an x0.1 node beats everything by a factor of 3 no matter how bad it is.
  static const double maxCostBonus = 1.20;
  static const double maxCostPenalty = 0.70;

  static double _clamp(double v) => v.clamp(0.0, 1.0).toDouble();

  factory Score.of(NodeState n) {
    final delay = n.delayEwma;

    // L: log curve — 50ms = 100, 500ms = 0. Linear curves flatten too early
    // and let a 260ms node score nearly the same as an 80ms one.
    final l = delay == null
        ? 0.0
        : 100 * _clamp(math.log(500 / delay.clamp(50.0, 500.0)) / math.log(10));

    // R: recent probe success ratio; unknown history is neutral (50), not punished.
    final r = n.history.isEmpty ? 50.0 : 100 * (1 - n.failRate);

    // S: jitter penalty, 150ms of jitter wipes the score out.
    final s = delay == null ? 0.0 : 100 * _clamp(1 - n.jitterEwma / 150);

    // T: log-scaled, 50 MB/s == full marks; unknown throughput is neutral.
    final t = !n.hasThroughput
        ? 50.0
        : 100 * _clamp(math.log(n.throughputMbps + 1) / math.log(51));

    final quality = wLatency * l + wReliability * r + wStability * s + wThroughput * t;
    final rawCost = 1 / math.pow(n.multiplier, alpha);
    final cost = rawCost.toDouble().clamp(maxCostPenalty, maxCostBonus);
    final finalScore = quality * cost;
    return Score(
      latency: l,
      reliability: r,
      stability: s,
      throughput: t,
      quality: quality,
      multiplier: n.multiplier,
      costFactor: cost.toDouble(),
      finalScore: finalScore.toDouble(),
    );
  }

  String get compact =>
      'L${latency.round()} R${reliability.round()} S${stability.round()} T${throughput.round()}';

  Map<String, dynamic> toJson() => {
        'L': double.parse(latency.toStringAsFixed(1)),
        'R': double.parse(reliability.toStringAsFixed(1)),
        'S': double.parse(stability.toStringAsFixed(1)),
        'T': double.parse(throughput.toStringAsFixed(1)),
        'quality': double.parse(quality.toStringAsFixed(1)),
        'mult': multiplier,
        'cost': double.parse(costFactor.toStringAsFixed(3)),
        'final': double.parse(finalScore.toStringAsFixed(1)),
      };
}
