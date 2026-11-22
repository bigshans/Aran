import 'model.dart';
import 'score.dart';

enum Verdict {
  /// switch to [Decision.to]
  takeOver,

  /// keep the current node (with a reason why we did not switch)
  hold,

  /// current node declared dead, must leave regardless of cooldown
  dead,

  /// nothing usable
  noData,
}

class Decision {
  final DateTime at;
  final String group;
  final String? from;
  final String? to;
  final Verdict verdict;
  final String reason;
  final Map<String, dynamic> data;

  const Decision({
    required this.at,
    required this.group,
    required this.from,
    required this.to,
    required this.verdict,
    required this.reason,
    this.data = const {},
  });

  bool get acts => verdict == Verdict.takeOver || verdict == Verdict.dead;

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'group': group,
        'from': from,
        'to': to,
        'verdict': verdict.name,
        'reason': reason,
        'data': data,
      };
}

class DecisionEngine {
  /// Switch only when the candidate is this much better.
  final double threshold;

  /// After a switch, do not switch again for this long (death is exempt).
  final Duration cooldown;

  /// Consecutive failed probes that mean "dead".
  final int deathStreak;

  const DecisionEngine({
    this.threshold = 1.30,
    this.cooldown = const Duration(minutes: 5),
    this.deathStreak = 2,
  });

  Decision evaluate({
    required String group,
    required String? currentName,
    required List<NodeState> candidates,
    required DateTime now,
    DateTime? lastSwitchAt,
    required Score Function(NodeState) scoreOf,
    bool warmup = false,
    String warmupDetail = '',
  }) {
    if (warmup) {
      return Decision(
        at: now,
        group: group,
        from: currentName,
        to: null,
        verdict: Verdict.noData,
        reason: '预热中$warmupDetail，暂不做决策',
      );
    }
    if (candidates.isEmpty) {
      return Decision(
        at: now,
        group: group,
        from: currentName,
        to: null,
        verdict: Verdict.noData,
        reason: '没有任何候选节点',
      );
    }

    final scored = [
      for (final n in candidates)
        if (n.delayEwma != null || n.history.isNotEmpty) (node: n, score: scoreOf(n))
    ]..sort((a, b) => b.score.finalScore.compareTo(a.score.finalScore));

    final usable = scored.where((e) => e.node.alive && e.node.delayEwma != null).toList();

    if (usable.isEmpty) {
      return Decision(
        at: now,
        group: group,
        from: currentName,
        to: null,
        verdict: Verdict.noData,
        reason: '全部节点判死或尚无探测数据',
        data: {'candidates': scored.length},
      );
    }

    final best = usable.first;
    final cur = candidates.where((n) => n.name == currentName).firstOrNull;

    if (cur == null) {
      return Decision(
        at: now,
        group: group,
        from: currentName,
        to: best.node.name,
        verdict: Verdict.takeOver,
        reason: '冷启动：无当前节点，直接选评分最高的 ${best.node.name}',
        data: {'best': best.score.toJson()},
      );
    }

    final curScore = scoreOf(cur);

    // 1) Death always wins: no cooldown, no threshold.
    if (cur.failStreak >= deathStreak) {
      return Decision(
        at: now,
        group: group,
        from: cur.name,
        to: best.node.name,
        verdict: Verdict.dead,
        reason: '${cur.name} 连续 ${cur.failStreak} 次探测失败，判死；切到 ${best.node.name}（${best.score.compact}）',
        data: {
          'current': curScore.toJson(),
          'best': best.score.toJson(),
          'lastError': cur.lastError,
        },
      );
    }

    // Current node is already the best: say so, instead of "X leads by 0.0%".
    if (best.node.name == cur.name) {
      final rival = usable.where((e) => e.node.name != cur.name).firstOrNull;
      final lead = rival == null
          ? ''
          : '，领先第二名 ${rival.node.name} ${((curScore.finalScore / rival.score.finalScore - 1) * 100).toStringAsFixed(1)}%';
      return Decision(
        at: now,
        group: group,
        from: cur.name,
        to: cur.name,
        verdict: Verdict.hold,
        reason: '当前已是最优（评分 ${curScore.finalScore.toStringAsFixed(1)}$lead）',
        data: {'current': curScore.toJson(), 'rival': rival?.score.toJson()},
      );
    }

    // Current node has no usable measurement yet: switching is justified, but
    // calling it a "975% lead" is meaningless noise.
    if (cur.delayEwma == null) {
      return Decision(
        at: now,
        group: group,
        from: cur.name,
        to: best.node.name,
        verdict: Verdict.takeOver,
        reason: '${cur.name} 尚无可用探测数据，改用 ${best.node.name}（${best.score.compact}）',
        data: {'current': curScore.toJson(), 'best': best.score.toJson()},
      );
    }

    final ratio = curScore.finalScore <= 0 ? double.infinity : best.score.finalScore / curScore.finalScore;
    final pct = (ratio - 1) * 100;

    // 2) Quality upgrade, gated by threshold and cooldown.
    if (ratio >= threshold) {
      if (lastSwitchAt != null && now.difference(lastSwitchAt) < cooldown) {
        final left = cooldown - now.difference(lastSwitchAt);
        return Decision(
          at: now,
          group: group,
          from: cur.name,
          to: best.node.name,
          verdict: Verdict.hold,
          reason: '${best.node.name} 领先 ${pct.toStringAsFixed(1)}%（达阈值），但冷却中，还剩 ${left.inSeconds}s',
          data: {'current': curScore.toJson(), 'best': best.score.toJson(), 'ratio': ratio},
        );
      }
      return Decision(
        at: now,
        group: group,
        from: cur.name,
        to: best.node.name,
        verdict: Verdict.takeOver,
        reason: '${best.node.name} 领先 ${pct.toStringAsFixed(1)}% '
            '（质量 ${best.score.quality.toStringAsFixed(1)} vs ${curScore.quality.toStringAsFixed(1)}，倍率 ×${best.node.multiplier} vs ×${cur.multiplier}）',
        data: {'current': curScore.toJson(), 'best': best.score.toJson(), 'ratio': ratio},
      );
    }

    // 3) Hold — and record *why* we refused, which is the whole point.
    return Decision(
      at: now,
      group: group,
      from: cur.name,
      to: best.node.name,
      verdict: Verdict.hold,
      reason: '${best.node.name} 仅领先 ${pct.toStringAsFixed(1)}%（阈值 ${((threshold - 1) * 100).round()}%），不切',
      data: {'current': curScore.toJson(), 'best': best.score.toJson(), 'ratio': ratio},
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
