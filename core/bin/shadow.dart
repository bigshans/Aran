// Shadow mode: observe, score, recommend — never write.
//
//   dart run bin/shadow.dart --group "trumpyun - 特朗普云" --auto-group "自动选择"
//
// Prints one line per second: what mihomo uses, what Aran would use, and why it
// did or did not switch. Every decision is appended to the audit log.

import 'dart:async';
import 'dart:io';

import 'package:aran_core/aran_core.dart';

const _realTypes = {
  'Vless', 'Vmess', 'Shadowsocks', 'ShadowsocksR', 'Trojan', 'Hysteria', 'Hysteria2',
  'Tuic', 'Socks', 'Http', 'WireGuard', 'Ssh', 'Snell', 'Http2', 'AnyTLS', 'Masque',
};

bool _isPseudo(String name) =>
    name.contains('：') ||
    name.toLowerCase().startsWith('http') ||
    RegExp(r'剩余流量|套餐到期|距离下次|防走失|更新订阅|官网|指引|客服').hasMatch(name);

Future<void> main(List<String> args) async {
  final opt = _Opts.parse(args);
  final api = MihomoApi(addr: opt.addr, secret: opt.secret);

  stdout.writeln('aran shadow · ${opt.addr} · group=${opt.group}');
  stdout.writeln('takeover=${opt.takeover}  audit=${opt.auditPath}');

  final audit = AuditLog(opt.auditPath);
  await audit.open();

  // Discover the pool once; refresh membership on every poll afterwards.
  final pool = <String, NodeState>{};
  String? lastCurrent;
  DateTime? lastSwitchAt;

  final engine = DecisionEngine(threshold: opt.threshold, cooldown: opt.cooldown);

  final scheduler = ProbeScheduler(api);
  final observer = Observer(api);

  var running = true;
  ProcessSignal.sigint.watch().listen((_) {
    running = false;
  });

  var lastPrint = DateTime.fromMillisecondsSinceEpoch(0);
  var lastDecisionKey = '';

  while (running) {
    final now = DateTime.now();

    // --- refresh group state (cheap, every other tick) ---
    try {
      final proxies = await api.proxies();
      final nodes = _extractNodes(proxies, opt.group);
      for (final name in nodes) {
        pool.putIfAbsent(name, () => NodeState(name: name, multiplier: NodeState.parseMultiplier(name)));
      }
      // drop nodes that disappeared from the subscription
      pool.removeWhere((name, _) => !nodes.contains(name));

      final auto = opt.autoGroup.isEmpty ? opt.group : opt.autoGroup;
      lastCurrent = (proxies[auto]?['now'] as String?) ??
          (proxies[opt.group]?['now'] as String?);
    } catch (e) {
      stdout.writeln('[${_ts(now)}] api error: $e');
      await Future<void>.delayed(const Duration(seconds: 2));
      continue;
    }

    // --- passive observation ---
    await observer.poll(pool, now);
    scheduler.idle = observer.isIdle(now);

    // --- score & decide ---
    final scored = pool.values.toList()..sort((a, b) => Score.of(b).finalScore.compareTo(Score.of(a).finalScore));
    final candidates = scored.map((n) => n.name).toList();

    final probedCount = pool.values.where((n) => n.probed).length;
    final warmup = pool.isNotEmpty && probedCount / pool.length < 0.7;

    final decision = engine.evaluate(
      group: opt.group,
      currentName: lastCurrent,
      candidates: scored,
      now: now,
      lastSwitchAt: lastSwitchAt,
      scoreOf: Score.of,
      warmup: warmup,
      warmupDetail: '（已探测 $probedCount/${pool.length}）',
    );

    final key = '${decision.verdict}|${decision.from}|${decision.to}|${decision.reason}';
    if (key != lastDecisionKey) {
      audit.write(decision);
      lastDecisionKey = key;
      if (decision.acts) {
        if (opt.takeover) {
          try {
            await api.select(opt.group, decision.to!);
            lastSwitchAt = now;
            stdout.writeln('[${_ts(now)}] ⚡ APPLIED → ${decision.to}  (${decision.reason})');
          } catch (e) {
            stdout.writeln('[${_ts(now)}] ✗ apply failed: $e');
          }
        } else {
          lastSwitchAt = now; // pretend, so cooldown semantics are exercised
          stdout.writeln('[${_ts(now)}] 💡 WOULD SWITCH → ${decision.to}  (${decision.reason})');
        }
      }
    }

    // --- status line ---
    if (now.difference(lastPrint) >= opt.printEvery) {
      lastPrint = now;
      _printStatus(now, pool, lastCurrent, decision, scheduler, observer);
    }

    // --- probes (rate limited inside) ---
    await scheduler.tick(
      nodes: pool,
      current: lastCurrent,
      candidates: candidates,
      now: now,
    );

    await Future<void>.delayed(const Duration(milliseconds: 1000));
  }

  await audit.close();
  api.close();
  stdout.writeln('bye. probes=${scheduler.probeCount} fails=${scheduler.failCount}');
}

List<String> _extractNodes(Map<String, dynamic> proxies, String group) {
  final g = proxies[group];
  if (g is! Map) return const [];
  final all = (g['all'] as List?)?.cast<String>() ?? const <String>[];
  return [
    for (final name in all)
      if (_realTypes.contains(proxies[name]?['type']) && !_isPseudo(name)) name
  ];
}

void _printStatus(DateTime now, Map<String, NodeState> pool, String? current, Decision d, ProbeScheduler s, Observer o) {
  final cur = current == null ? null : pool[current];
  final usable = pool.values.where((n) => n.alive && n.delayEwma != null).toList()
    ..sort((a, b) => Score.of(b).finalScore.compareTo(Score.of(a).finalScore));
  final best = usable.isEmpty ? null : usable.first;

  String fmt(NodeState? n) {
    if (n == null) return '(none)';
    final sc = Score.of(n);
    final delay = n.delayEwma == null ? '?' : '${n.delayEwma!.round()}ms';
    final mbps = n.throughputSeconds < 3 ? '?' : n.throughputMbps.toStringAsFixed(1);
    return '${n.name}  x${n.multiplier}  delay=$delay tp=$mbps  '
        'L${sc.latency.round()} R${sc.reliability.round()} S${sc.stability.round()} T${sc.throughput.round()} '
        '-> ${sc.finalScore.toStringAsFixed(1)}';
  }

  stdout.writeln('[${_ts(now)}] ${'-' * 58}');
  stdout.writeln('  cur  ${fmt(cur)}');
  stdout.writeln('  best ${fmt(best)}');
  for (final n in usable.take(5)) {
    stdout.writeln('       . ${fmt(n)}');
  }
  stdout.writeln('  =>   ${d.verdict.name.toUpperCase()}  ${d.reason}');
  stdout.writeln('  pool=${pool.length} usable=${usable.length} '
      'probed=${pool.values.where((n) => n.probed).length} '
      'probes=${s.probeCount}/${s.failCount}fail '
      'idle=${s.idle} active=${o.activePerNode.length} '
      'traffic=${(o.totalBytes / 1e6).toStringAsFixed(1)}MB '
      'withTp=${pool.values.where((n) => n.hasThroughput).map((n) => '${n.name}:${n.throughputMbps.toStringAsFixed(1)}').take(3).join(' | ')}');
}

String _ts(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

class _Opts {
  final String addr;
  final String secret;
  final String group;
  final String autoGroup;
  final String auditPath;
  final double threshold;
  final Duration cooldown;
  final Duration printEvery;
  final bool takeover;

  _Opts({
    required this.addr,
    required this.secret,
    required this.group,
    required this.autoGroup,
    required this.auditPath,
    required this.threshold,
    required this.cooldown,
    required this.printEvery,
    required this.takeover,
  });

  static _Opts parse(List<String> args) {
    String get(String k, String fallback) {
      final i = args.indexOf('--$k');
      return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
    }

    return _Opts(
      addr: get('addr', '127.0.0.1:9090'),
      secret: get('secret', 'aran-dev'),
      group: get('group', 'trumpyun - 特朗普云'),
      autoGroup: get('auto-group', '自动选择'),
      auditPath: get('audit', '${Platform.environment['HOME'] ?? '.'}/project/Aran/.data/audit.jsonl'),
      threshold: double.tryParse(get('threshold', '1.30')) ?? 1.30,
      cooldown: Duration(minutes: int.tryParse(get('cooldown-min', '5')) ?? 5),
      printEvery: Duration(seconds: int.tryParse(get('print-every', '10')) ?? 10),
      takeover: args.contains('--takeover'),
    );
  }
}
