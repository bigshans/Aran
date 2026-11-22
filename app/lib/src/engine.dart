import 'dart:async';
import 'dart:io';

import 'package:aran_core/aran_core.dart';
import 'package:flutter/foundation.dart';

/// How aggressively the scheduler is allowed to spend battery.
///
/// Desktop never leaves [active]; a phone has three states (docs/ANDROID.md
/// 决策 #13/#14): foreground, backgrounded, screen off. The whole point is that
/// no probe fires while nobody is using the tunnel — switching nodes then has no
/// beneficiary, it just wakes the radio.
enum EnginePowerMode {
  /// Foreground: 10s current / 60s candidates / 600s rest / 1s tick.
  active,

  /// Backgrounded but still reachable: slow everything down, keep a heartbeat.
  background,

  /// Screen off: only the node in use, every five minutes.
  screenOff,
}

class RankedNode {
  final String name;
  final double multiplier;
  final double? delayMs;
  final double? throughputMbps;
  final Score score;
  final bool isCurrent;
  final bool probed;
  final bool alive;
  final int failStreak;
  final double ratioVsCurrent;
  final bool currentHasData;

  const RankedNode({
    required this.name,
    required this.multiplier,
    required this.delayMs,
    required this.throughputMbps,
    required this.score,
    required this.isCurrent,
    required this.probed,
    required this.alive,
    required this.failStreak,
    required this.ratioVsCurrent,
    this.currentHasData = true,
  });

  String get why {
    if (!probed) return '尚未探测';
    if (!alive) return '已判死（连续 $failStreak 次失败）';
    if (isCurrent) return '正在使用';
    if (!currentHasData) return '当前节点尚无探测数据';
    if (ratioVsCurrent.isInfinite) return '当前节点无数据，可接管';
    final pct = (ratioVsCurrent - 1) * 100;
    if (pct >= 30) return '领先 ${pct.toStringAsFixed(1)}%，达到切换阈值';
    if (pct >= 0) return '领先 ${pct.toStringAsFixed(1)}%，未达 30% 阈值';
    return '落后 ${(-pct).toStringAsFixed(1)}%，不切换';
  }
}

class Snapshot {
  final bool connected;
  final String kernelVersion;
  final String group;
  final String? currentName;
  final RankedNode? current;
  final List<RankedNode> ranked;
  final Decision? decision;
  final List<Decision> timeline;
  final int poolSize;
  final int usable;
  final int probed;
  final int probeCount;
  final int failCount;
  final bool idle;
  final int activeConnections;
  final double trafficMb;
  final DateTime at;
  final List<double> rates;

  /// Separate directions for the Android notification (MB/s).
  final double upRate;
  final double downRate;

  /// Cumulative bytes per direction (for the idle notification line).
  final int upBytes;
  final int downBytes;
  final List<String> managedGroups;
  final String? error;

  const Snapshot({
    required this.connected,
    required this.kernelVersion,
    required this.group,
    required this.currentName,
    required this.current,
    required this.ranked,
    required this.decision,
    required this.timeline,
    required this.poolSize,
    required this.usable,
    required this.probed,
    required this.probeCount,
    required this.failCount,
    required this.idle,
    required this.activeConnections,
    required this.trafficMb,
    required this.at,
    this.rates = const [],
    this.upRate = 0,
    this.downRate = 0,
    this.upBytes = 0,
    this.downBytes = 0,
    this.managedGroups = const [],
    this.error,
  });

  static Snapshot offline(String error) => Snapshot(
        connected: false,
        kernelVersion: '?',
        group: '',
        currentName: null,
        current: null,
        ranked: const [],
        decision: null,
        timeline: const [],
        poolSize: 0,
        usable: 0,
        probed: 0,
        probeCount: 0,
        failCount: 0,
        idle: true,
        activeConnections: 0,
        trafficMb: 0,
        at: DateTime.now(),
        rates: const [],
        upRate: 0,
        downRate: 0,
        upBytes: 0,
        downBytes: 0,
        managedGroups: const [],
        error: error,
      );
}

/// The scheduling loop: observation, scoring, decisions, audit.
class Engine {
  final ValueNotifier<Snapshot> snapshot = ValueNotifier(Snapshot.offline('正在连接内核…'));

  String addr;
  String secret;
  String? configuredGroup;
  bool takeover;
  double threshold;
  Duration cooldown;
  final String auditPath;
  final String testUrl;
  final int testTimeoutMs;

  late MihomoApi _api;
  late ProbeScheduler _scheduler;
  late Observer _observer;
  late AuditLog _audit;
  late DecisionEngine _engine;

  final Map<String, NodeState> _pool = {};
  final List<Decision> _timeline = [];
  final List<double> _rates = []; // MB/s over the last ~120 ticks
  int _lastBytes = 0;
  DateTime? _lastRateAt;
  final Map<String, DateTime> _lastSwitch = {};
  final Map<String, String?> _groupCurrent = {};

  /// Groups Aran drives (every group a rule references).
  List<String> managedGroups = const [];

  /// Optional region filter per group, e.g. {'TikTok': '新加坡'}.
  Map<String, String> groupPrefs = const {};

  /// Per-group control: auto | suggest | off (missing = follow the global switch).
  Map<String, String> groupModes = const {};

  void setGroupModes(Map<String, String> modes) => groupModes = Map.unmodifiable(modes);

  String modeFor(String group) => groupModes[group] ?? (takeover ? 'auto' : 'suggest');

  String? _group;
  String? _current;
  String _version = '?';
  bool _running = false;
  bool _sampling = false;
  Timer? _timer;
  Timer? _observerTimer;

  EnginePowerMode _power = EnginePowerMode.active;
  EnginePowerMode get power => _power;
  final Map<String, String> _lastGroupKeys = {};

  Engine({
    this.addr = '127.0.0.1:9090',
    this.secret = '',
    this.configuredGroup,
    this.takeover = false,
    this.threshold = 1.30,
    this.cooldown = const Duration(minutes: 5),
    String? auditPath,
    this.testUrl = 'https://cp.cloudflare.com/generate_204',
    this.testTimeoutMs = 5000,
  }) : auditPath = auditPath ?? defaultAuditPath();

  static String defaultAuditPath() {
    // Never hand-build a POSIX path: on Windows `HOME` is usually unset, which
    // turned this into the relative './local/share/aran' and threw EACCES.
    final p = createPlatform();
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    final dir = p.dataDir(Platform.environment['XDG_DATA_HOME'], home);
    return '${dir.path}${Platform.pathSeparator}audit.jsonl';
  }

  String? get group => _group;

  Future<void> start() async {
    if (_running) return;
    _running = true;
    _api = MihomoApi(addr: addr, secret: secret);
    _scheduler = ProbeScheduler(_api)
      ..testUrl = testUrl
      ..testTimeoutMs = testTimeoutMs;
    _observer = Observer(_api);
    _audit = AuditLog(auditPath);
    await _audit.open();
    _engine = DecisionEngine(threshold: threshold, cooldown: cooldown);
    try {
      _version = await _api.version();
    } catch (_) {
      _version = '?';
    }
    _restartTimers();
  }

  /// Switch the whole loop between battery profiles. Safe to call repeatedly;
  /// no-ops when nothing changes so a lifecycle storm does not thrash timers.
  void setPowerMode(EnginePowerMode mode) {
    if (_power == mode) return;
    _power = mode;
    if (!_running) return;
    _applyProbeIntervals();
    _restartTimers();
  }

  void _applyProbeIntervals() {
    switch (_power) {
      case EnginePowerMode.active:
        _scheduler
          ..currentInterval = const Duration(seconds: 10)
          ..candidateInterval = const Duration(seconds: 60)
          ..restInterval = const Duration(seconds: 600)
          ..idleInterval = const Duration(seconds: 60);
      case EnginePowerMode.background:
        // Nothing is being watched; keep the current node healthy and refresh the
        // rest rarely. 5 minutes is what the platform's Doze would allow anyway.
        _scheduler
          ..currentInterval = const Duration(seconds: 60)
          ..candidateInterval = const Duration(minutes: 10)
          ..restInterval = const Duration(minutes: 60)
          ..idleInterval = const Duration(minutes: 10);
      case EnginePowerMode.screenOff:
        // docs/ANDROID.md 决策 #13: only the node in use gets a heartbeat; every
        // other probe is effectively disabled (one hour > any plausible sleep).
        _scheduler
          ..currentInterval = const Duration(minutes: 5)
          ..candidateInterval = const Duration(hours: 1)
          ..restInterval = const Duration(hours: 2)
          ..idleInterval = const Duration(minutes: 5);
    }
  }

  void _restartTimers() {
    _timer?.cancel();
    _observerTimer?.cancel();
    final tick = switch (_power) {
      EnginePowerMode.active => const Duration(seconds: 1),
      EnginePowerMode.background => const Duration(seconds: 5),
      EnginePowerMode.screenOff => const Duration(seconds: 30),
    };
    final sample = switch (_power) {
      EnginePowerMode.active => const Duration(milliseconds: 200),
      EnginePowerMode.background => const Duration(seconds: 1),
      EnginePowerMode.screenOff => const Duration(seconds: 5),
    };
    _timer = Timer.periodic(tick, (_) => _tick());
    _observerTimer = Timer.periodic(sample, (_) => _sample());
  }

  void setTakeover(bool value) => takeover = value;

  void setGroups(List<String> groups, Map<String, String> prefs) {
    managedGroups = List.unmodifiable(groups);
    groupPrefs = Map.unmodifiable(prefs);
    _lastSwitch.clear();
    _groupCurrent.clear();
  }

  /// No longer used: Aran drives every rule-referenced group. Kept as a no-op
  /// shim so older call sites keep compiling.
  void setGroup(String? name) {
    configuredGroup = (name == null || name.isEmpty) ? null : name;
    _pool.clear();
    _timeline.clear();
    _lastSwitch.clear();
    _lastGroupKeys.clear();
  }

  Future<void> _sample() async {
    if (!_running || _sampling || _pool.isEmpty) return;
    _sampling = true;
    try {
      await _observer.poll(_pool, DateTime.now());
    } catch (_) {
    } finally {
      _sampling = false;
    }
  }

  Future<void> dispose() async {
    _running = false;
    _timer?.cancel();
    _observerTimer?.cancel();
    snapshot.value = Snapshot.offline('已停止');
    await _audit.close();
    _api.close();
  }

  static const _realTypes = {
    // These are mihomo's /proxies `type` strings verbatim. `Socks5` (not `Socks`)
    // is what a socks5 outbound reports — missing it made every socks node
    // invisible to the scheduler (found on Android, 2026-11-22).
    'Vless', 'Vmess', 'Shadowsocks', 'ShadowsocksR', 'Trojan', 'Hysteria', 'Hysteria2',
    'Tuic', 'Socks', 'Socks5', 'Http', 'WireGuard', 'Ssh', 'Snell', 'Http2', 'AnyTLS', 'Masque',
  };

  static bool isPseudo(String name) =>
      name.contains('：') ||
      name.toLowerCase().startsWith('http') ||
      RegExp(r'剩余流量|套餐到期|距离下次|防走失|更新订阅|官网|指引|客服|Dont\.use|不可用|请购买|过期')
          .hasMatch(name);

  Future<void> _tick() async {
    if (!_running) return;
    final now = DateTime.now();
    Map<String, dynamic> proxies;
    try {
      proxies = await _api.proxies();
    } catch (e) {
      snapshot.value = Snapshot.offline('连不上内核 $addr：$e');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      return;
    }

    final primary = _discover(proxies);
    final List<String> groups = managedGroups.isNotEmpty
        ? managedGroups
        : <String>[?primary];
    if (groups.isEmpty) {
      snapshot.value = Snapshot.offline('这份配置里没有可用的策略组');
      return;
    }

    // Pool = union of every node in every managed group.
    final names = <String>{};
    for (final g in groups) {
      for (final n in _members(proxies, g)) {
        names.add(n);
      }
    }
    for (final name in names) {
      _pool.putIfAbsent(name, () => NodeState(name: name, multiplier: NodeState.parseMultiplier(name)));
    }
    _pool.removeWhere((name, _) => !names.contains(name));

    _scheduler.idle = _observer.isIdle(now);

    // Throughput history for the sparkline (bytes seen by the kernel).
    final totalBytes = _observer.totalBytes;
    final lastAt = _lastRateAt;
    if (lastAt != null && totalBytes >= _lastBytes) {
      final secs = now.difference(lastAt).inMilliseconds / 1000.0;
      if (secs > 0) {
        _rates.add((totalBytes - _lastBytes) / 1e6 / secs);
        if (_rates.length > 120) _rates.removeAt(0);
      }
    }
    _lastBytes = totalBytes;
    _lastRateAt = now;

    final probedCount = _pool.values.where((n) => n.probed).length;
    final warmup = _pool.isNotEmpty && probedCount / _pool.length < 0.7;

    // Drive each managed group independently.
    for (final group in groups) {
      if (!proxies.containsKey(group)) continue;
      final mode = modeFor(group);
      if (mode == 'off') continue; // fully handed back to the kernel / manual choice
      final current = _currentOf(proxies, group);
      _groupCurrent[group] = current;

      final members = _members(proxies, group)
          .where((n) => _matchesPref(n, groupPrefs[group]))
          .toList();
      final candidates = members
          .map((n) => _pool[n])
          .whereType<NodeState>()
          .toList()
        ..sort((a, b) => Score.of(b).finalScore.compareTo(Score.of(a).finalScore));

      final decision = _engine.evaluate(
        group: group,
        currentName: current,
        candidates: candidates,
        now: now,
        lastSwitchAt: _lastSwitch[group],
        scoreOf: Score.of,
        warmup: warmup,
        warmupDetail: '（已探测 $probedCount/${_pool.length}）',
      );

      final key = '${decision.group}|${decision.verdict}|${decision.to}|${decision.reason}';
      if (key == _lastGroupKeys[group]) continue;
      _lastGroupKeys[group] = key;

      _audit.write(decision);
      if (decision.acts) {
        _lastSwitch[group] = now;
        if (mode == 'auto') {
          try {
            await _api.select(group, decision.to!);
          } catch (_) {}
        }
      }

      if (_timeline.isNotEmpty &&
          _timeline.first.verdict == decision.verdict &&
          _timeline.first.group == decision.group &&
          _timeline.first.from == decision.from &&
          _timeline.first.to == decision.to) {
        _timeline[0] = decision;
      } else {
        _timeline.insert(0, decision);
        if (_timeline.length > 80) _timeline.removeLast();
      }
    }

    // Primary group feeds the status page.
    final primaryGroup = groups.first;
    _group = primaryGroup;
    _current = _groupCurrent[primaryGroup];
    final curState = _current == null ? null : _pool[_current];
    final curScore = curState == null ? null : Score.of(curState);

    final sorted = _pool.values.toList()
      ..sort((a, b) => Score.of(b).finalScore.compareTo(Score.of(a).finalScore));

    snapshot.value = Snapshot(
      connected: true,
      kernelVersion: _version,
      group: primaryGroup,
      currentName: _current,
      current: curState == null ? null : _row(curState, curScore?.finalScore),
      ranked: sorted.take(40).map((n) => _row(n, curScore?.finalScore)).toList(),
      decision: _timeline.isEmpty ? null : _timeline.firstWhere(
        (d) => d.group == primaryGroup,
        orElse: () => _timeline.first,
      ),
      timeline: List.unmodifiable(_timeline),
      poolSize: _pool.length,
      usable: sorted.where((n) => n.alive && n.delayEwma != null).length,
      probed: probedCount,
      probeCount: _scheduler.probeCount,
      failCount: _scheduler.failCount,
      idle: _scheduler.idle,
      activeConnections: _observer.activePerNode.values.fold(0, (a, b) => a + b),
      trafficMb: _observer.totalBytes / 1e6,
      at: now,
      rates: List.unmodifiable(_rates),
      upRate: _observer.upRateMbps,
      downRate: _observer.downRateMbps,
      upBytes: _observer.upBytes,
      downBytes: _observer.downBytes,
      managedGroups: List.unmodifiable(groups),
    );

    await _scheduler.tick(
      nodes: _pool,
      current: _current,
      candidates: sorted.map((n) => n.name).toList(),
      now: now,
    );
  }

  bool _matchesPref(String node, String? pref) {
    if (pref == null || pref.isEmpty) return true;
    return node.toLowerCase().contains(pref.toLowerCase());
  }

  List<String> _members(Map<String, dynamic> proxies, String group) {
    final g = proxies[group];
    if (g is! Map) return const [];
    final all = (g['all'] as List?)?.cast<String>() ?? const <String>[];
    return [
      for (final name in all)
        if (_realTypes.contains(proxies[name]?['type']) && !isPseudo(name)) name
    ];
  }

  String? _currentOf(Map<String, dynamic> proxies, String group) {
    var current = (proxies[group]?['now'] as String?);
    final hop = current == null ? null : proxies[current];
    if (hop is Map) {
      final inner = hop['now'];
      if (inner is String) current = inner;
    }
    return current;
  }

  String? _discover(Map<String, dynamic> proxies) {
    String? best;
    var bestCount = -1;
    proxies.forEach((name, value) {
      if (name == 'GLOBAL' || value is! Map || value['type'] != 'Selector') return;
      final count = (value['all'] as List?)?.length ?? 0;
      if (count > bestCount) {
        bestCount = count;
        best = name;
      }
    });
    return best;
  }

  NodeState? get _currentState => _current == null ? null : _pool[_current];

  RankedNode _row(NodeState n, double? curFinal) {
    final sc = Score.of(n);
    final ratio = (curFinal == null || curFinal <= 0) ? double.infinity : sc.finalScore / curFinal;
    return RankedNode(
      name: n.name,
      multiplier: n.multiplier,
      delayMs: n.delayEwma,
      throughputMbps: n.hasThroughput ? n.throughputMbps : null,
      score: sc,
      isCurrent: n.name == _current,
      probed: n.probed,
      alive: n.alive,
      failStreak: n.failStreak,
      ratioVsCurrent: ratio,
      currentHasData: _currentState?.delayEwma != null,
    );
  }
}
