import 'package:aran_core/aran_core.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../engine.dart';
import 'common.dart';

Color verdictColor(Verdict v) => switch (v) {
      Verdict.takeOver => green,
      Verdict.dead => red,
      Verdict.hold => amber,
      Verdict.noData => dim,
    };

String verdictLabel(Verdict v) => switch (v) {
      Verdict.takeOver => '建议切换',
      Verdict.dead => '判死切换',
      Verdict.hold => '保持',
      Verdict.noData => '无数据',
    };

class StatusPage extends StatelessWidget {
  final AppState state;
  const StatusPage({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final engine = state.engine;
    if (engine == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('代理未开启', style: mono.copyWith(color: dim, fontSize: 14)),
            const SizedBox(height: 8),
            Text('点右上角「开启代理」，Aran 会拉起 mihomo 并开始调度',
                style: mono.copyWith(color: dim, fontSize: 12)),
          ],
        ),
      );
    }
    return ValueListenableBuilder<Snapshot>(
      valueListenable: engine.snapshot,
      builder: (context, snap, _) {
        if (!snap.connected) {
          return Center(child: Text(snap.error ?? '连接中…', style: mono.copyWith(color: dim)));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CurrentCard(snap: snap),
            _TrafficStrip(snap: snap),
            const SectionTitle('节点排行榜', tail: '「说明」列就是它为什么不是首选 · 点一行可手动切换'),
            Expanded(child: _RankTable(state: state, snap: snap)),
            Container(height: 1, color: lineStrong),
            const SectionTitle('决策时间线', tail: '包含被否决的决策'),
            SizedBox(height: 170, child: _Timeline(snap: snap)),
            _Footer(snap: snap, state: state),
          ],
        );
      },
    );
  }
}

/// Throughput sparkline: last ~2 minutes of kernel traffic, updated每秒。
class _TrafficStrip extends StatelessWidget {
  final Snapshot snap;
  const _TrafficStrip({required this.snap});

  @override
  Widget build(BuildContext context) {
    final rates = snap.rates;
    final peak = rates.isEmpty ? 0.0 : rates.reduce((a, b) => a > b ? a : b);
    final current = rates.isEmpty ? 0.0 : rates.last;
    return Container(
      height: 54,
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: line, width: 1))),
      child: Row(children: [
        Text('流量', style: mono.copyWith(fontSize: 11, color: dim)),
        const SizedBox(width: 10),
        Text('${current.toStringAsFixed(2)} MB/s', style: mono.copyWith(fontSize: 12, color: text)),
        const SizedBox(width: 10),
        Text('峰值 ${peak.toStringAsFixed(1)}', style: mono.copyWith(fontSize: 11, color: dim)),
        const SizedBox(width: 16),
        Expanded(
          child: CustomPaint(
            painter: _SparkPainter(rates: rates, color: blue, line: line),
            child: const SizedBox(height: 30, width: double.infinity),
          ),
        ),
      ]),
    );
  }
}

class _SparkPainter extends CustomPainter {
  final List<double> rates;
  final Color color;
  final Color line;
  _SparkPainter({required this.rates, required this.color, required this.line});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
        Offset(0, size.height), Offset(size.width, size.height), Paint()..color = line..strokeWidth = 1);
    if (rates.length < 2) return;
    final maxV = rates.reduce((a, b) => a > b ? a : b).clamp(0.001, double.infinity);
    final path = Path();
    for (var i = 0; i < rates.length; i++) {
      final x = size.width * i / (rates.length - 1);
      final y = size.height - (rates[i] / maxV) * (size.height - 4);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
        path, Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6);
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.rates != rates;
}

class _CurrentCard extends StatelessWidget {
  final Snapshot snap;
  const _CurrentCard({required this.snap});

  @override
  Widget build(BuildContext context) {
    final cur = snap.current;
    final d = snap.decision;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: line, width: borderWidth))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('当前节点 · ${snap.group}', style: mono.copyWith(color: dim, fontSize: 11, letterSpacing: 1)),
                const SizedBox(height: 6),
                Text(cur?.name ?? '(无)', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                if (cur != null)
                  Wrap(spacing: 18, runSpacing: 6, children: [
                    _kv('倍率', '×${cur.multiplier}'),
                    _kv('延迟', cur.delayMs == null ? '—' : '${cur.delayMs!.round()} ms'),
                    _kv('吞吐', cur.throughputMbps == null ? '—' : '${cur.throughputMbps!.toStringAsFixed(1)} MB/s'),
                    _kv('评分', cur.score.finalScore.toStringAsFixed(1)),
                    _kv('构成', 'L${cur.score.latency.round()} R${cur.score.reliability.round()} '
                        'S${cur.score.stability.round()} T${cur.score.throughput.round()}'),
                  ]),
              ],
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            flex: 2,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: panel,
                border: Border(left: BorderSide(color: d == null ? dim : verdictColor(d.verdict), width: 3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d == null ? '—' : verdictLabel(d.verdict),
                      style: mono.copyWith(
                          color: d == null ? dim : verdictColor(d.verdict),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1)),
                  const SizedBox(height: 6),
                  Text(d?.reason ?? '等待第一轮探测…', style: const TextStyle(fontSize: 13, height: 1.4)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Row(mainAxisSize: MainAxisSize.min, children: [
        Text('$k ', style: mono.copyWith(color: dim, fontSize: 12)),
        Text(v, style: mono.copyWith(fontSize: 13)),
      ]);
}

class _RankTable extends StatelessWidget {
  final AppState state;
  final Snapshot snap;
  const _RankTable({required this.state, required this.snap});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
          color: panel,
          child: Row(children: const [
            SizedBox(width: 28, child: Text('#', style: mono)),
            Expanded(flex: 4, child: Text('节点', style: mono)),
            SizedBox(width: 54, child: Text('倍率', style: mono)),
            SizedBox(width: 78, child: Text('延迟', style: mono)),
            SizedBox(width: 78, child: Text('吞吐', style: mono)),
            SizedBox(width: 176, child: Text('L / R / S / T', style: mono)),
            SizedBox(width: 74, child: Text('综合', style: mono)),
            Expanded(flex: 4, child: Text('说明', style: mono)),
            SizedBox(width: 56, child: Text('', style: mono)),
          ]),
        ),
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.zero,
            itemCount: snap.ranked.length,
            itemBuilder: (context, i) => _RankRow(state: state, rank: i + 1, node: snap.ranked[i], group: snap.group),
          ),
        ),
      ],
    );
  }
}

class _RankRow extends StatelessWidget {
  final AppState state;
  final int rank;
  final RankedNode node;
  final String group;
  const _RankRow({required this.state, required this.rank, required this.node, required this.group});

  @override
  Widget build(BuildContext context) {
    final s = node.score;
    return Container(
      color: node.isCurrent ? panelAlt : Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Row(
        children: [
          SizedBox(width: 28, child: Text('$rank', style: mono.copyWith(color: dim))),
          Expanded(
            flex: 4,
            child: Row(children: [
              if (node.isCurrent) ...[
                Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(color: blue.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(radius)),
                  child: Text('在用', style: mono.copyWith(color: blue, fontSize: 10)),
                ),
              ],
              Flexible(
                child: Text(node.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: node.alive ? text : red)),
              ),
            ]),
          ),
          SizedBox(width: 54, child: Text('×${node.multiplier}', style: mono.copyWith(color: node.multiplier > 1 ? amber : dim))),
          SizedBox(width: 70, child: Text(node.delayMs == null ? '—' : '${node.delayMs!.round()} ms', style: mono)),
          SizedBox(
            width: 78,
            child: Text(node.throughputMbps?.toStringAsFixed(1) ?? '—',
                style: mono.copyWith(color: node.throughputMbps == null ? dim : text)),
          ),
          SizedBox(
            width: 176,
            child: Text(
              '${s.latency.round()} / ${s.reliability.round()} / ${s.stability.round()} / ${s.throughput.round()}',
              style: mono.copyWith(fontSize: 12, color: dim),
            ),
          ),
          SizedBox(
            width: 74,
            child: Text(s.finalScore.toStringAsFixed(1),
                style: mono.copyWith(fontWeight: FontWeight.w700, color: node.isCurrent ? blue : text)),
          ),
          Expanded(
            flex: 4,
            child: Text(node.isCurrent ? '正在使用' : node.why,
                style: mono.copyWith(fontSize: 12, color: node.isCurrent ? blue : dim),
                overflow: TextOverflow.ellipsis),
          ),
          SizedBox(
            width: 56,
            child: node.isCurrent
                ? const SizedBox.shrink()
                : InkWell(
                    onTap: () => state.selectNode(group, node.name),
                    child: Text('切到', style: mono.copyWith(fontSize: 12, color: blue)),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Timeline extends StatelessWidget {
  final Snapshot snap;
  const _Timeline({required this.snap});

  @override
  Widget build(BuildContext context) {
    if (snap.timeline.isEmpty) return Center(child: Text('暂无决策', style: mono.copyWith(color: dim)));
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      itemCount: snap.timeline.length,
      itemBuilder: (context, i) {
        final d = snap.timeline[i];
        final t = '${d.at.hour.toString().padLeft(2, '0')}:'
            '${d.at.minute.toString().padLeft(2, '0')}:'
            '${d.at.second.toString().padLeft(2, '0')}';
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 68,
                child: Text(t, maxLines: 1, softWrap: false, style: mono.copyWith(color: dim, fontSize: 11.5)),
              ),
              SizedBox(
                width: 104,
                child: Text(d.group,
                    maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis,
                    style: mono.copyWith(color: dim, fontSize: 11.5)),
              ),
              SizedBox(
                width: 76,
                child: Text(verdictLabel(d.verdict),
                    maxLines: 1, softWrap: false,
                    style: mono.copyWith(color: verdictColor(d.verdict), fontSize: 11.5)),
              ),
              Expanded(child: Text(d.reason, style: const TextStyle(fontSize: 12, height: 1.35))),
            ],
          ),
        );
      },
    );
  }
}

class _Footer extends StatelessWidget {
  final Snapshot snap;
  final AppState state;
  const _Footer({required this.snap, required this.state});

  @override
  Widget build(BuildContext context) {
    final parts = [
      '池 ${snap.poolSize}',
      '可用 ${snap.usable}',
      '已探测 ${snap.probed}',
      '探测 ${snap.probeCount}（失败 ${snap.failCount}）',
      snap.idle ? '空闲模式' : '活跃',
      '连接 ${snap.activeConnections}',
      '流量 ${snap.trafficMb.toStringAsFixed(1)} MB',
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: line, width: borderWidth))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(parts.join('   ·   '), style: mono.copyWith(color: dim, fontSize: 11)),
          if (state.lastAction != null) ...[
            const SizedBox(height: 4),
            Text(
              '最近操作 ${state.lastAction!.at.hour.toString().padLeft(2, '0')}:'
              '${state.lastAction!.at.minute.toString().padLeft(2, '0')}:'
              '${state.lastAction!.at.second.toString().padLeft(2, '0')} · ${state.lastAction!.text}',
              style: mono.copyWith(fontSize: 11, color: state.lastAction!.ok ? green : red),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}
