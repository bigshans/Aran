import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import 'common.dart';

class ConnectionsPage extends StatefulWidget {
  final AppState state;
  const ConnectionsPage({super.key, required this.state});

  @override
  State<ConnectionsPage> createState() => _ConnectionsPageState();
}

class _ConnectionsPageState extends State<ConnectionsPage> {
  List<dynamic> _conns = const [];
  int _upTotal = 0;
  int _downTotal = 0;
  Timer? _timer;

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (!s.proxyRunning) return;
    final c = await s.fetchConnections();
    final totals = await s.fetchTrafficTotals();
    if (!mounted) return;
    setState(() {
      _conns = c;
      _upTotal = totals.$1;
      _downTotal = totals.$2;
    });
  }

  // Single source of truth for column geometry: header and rows both use these,
  // so they cannot drift apart.
  static const double _wRule = 170;
  static const double _wProc = 110;
  static const double _wUp = 96;
  static const double _wDown = 96;
  static const double _wDur = 76;
  static const double _wClose = 40;
  static const double _pad = 20;

  @override
  Widget build(BuildContext context) {
    if (!s.proxyRunning) {
      return Center(child: Text('代理未开启', style: mono.copyWith(color: dim)));
    }
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(_pad, 14, _pad, 8),
          child: Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('活动连接', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: text)),
              Text('${_conns.length} 条 · 每秒刷新', style: mono.copyWith(color: dim, fontSize: 11)),
              Text('累计 ↑ ${fmtBytes(_upTotal)}  ↓ ${fmtBytes(_downTotal)}',
                  style: mono.copyWith(color: dim, fontSize: 11)),
            ],
          ),
        ),
        if (!_narrow(context)) _header(),
        Expanded(
          child: _conns.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('没有活动连接', style: mono.copyWith(color: dim)),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: 460,
                        child: Text(
                          '未开启 TUN 时，只有主动使用 127.0.0.1:${s.kernel.activePorts['mixed'] ?? s.kernel.activePorts['http'] ?? 0} 的程序会出现在这里；'
                          '浏览器若未配置系统代理、CLI/游戏等直连流量不会进入内核。',
                          textAlign: TextAlign.center,
                          style: mono.copyWith(fontSize: 11, color: dim, height: 1.6),
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _conns.length,
                  itemBuilder: (context, i) => _narrow(context)
                      ? _card(_conns[i] as Map)
                      : _row(_conns[i] as Map),
                ),
        ),
      ],
    );
  }

  bool _narrow(BuildContext context) => MediaQuery.sizeOf(context).width < 600;

  /// Phone layout: eight columns cannot fit; one connection becomes a small card
  /// with the destination on top and the numbers underneath.
  Widget _card(Map c) {
    final meta = (c['metadata'] as Map?) ?? const {};
    final host = (meta['host'] as String?)?.isNotEmpty == true
        ? meta['host'] as String
        : '${meta['destinationIP'] ?? '?'}:${meta['destinationPort'] ?? ''}';
    final rule = c['rule'] == null ? '—' : '${c['rule']}(${c['rulePayload'] ?? ''})';
    final chains = (c['chains'] as List?)?.cast<String>() ?? const <String>[];
    final up = (c['upload'] as num?)?.toInt() ?? 0;
    final down = (c['download'] as num?)?.toInt() ?? 0;
    final start = DateTime.tryParse(c['start'] as String? ?? '');
    final dur = start == null ? '' : _dur(DateTime.now().difference(start));
    return Container(
      margin: const EdgeInsets.fromLTRB(_pad, 0, _pad, 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(radius + 1),
        border: Border.all(color: line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono.copyWith(fontSize: 12, color: text)),
            ),
            InkWell(
              onTap: () => s.closeConnection(c['id'] as String),
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Icon(Icons.close, size: 15, color: red),
              ),
            ),
          ]),
          const SizedBox(height: 4),
          Text(chains.isEmpty ? '直连' : chains.reversed.join(' → '),
              maxLines: 1, overflow: TextOverflow.ellipsis, style: mono.copyWith(fontSize: 11, color: blue)),
          const SizedBox(height: 4),
          Text(
            [
              rule,
              if (_process(meta) != '—') _process(meta),
              '↑${_bytes(up)}',
              '↓${_bytes(down)}',
              if (dur.isNotEmpty) dur,
            ].join('  ·  '),
            style: mono.copyWith(fontSize: 10.5, color: dim),
          ),
        ],
      ),
    );
  }

  Widget _header() {
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: _pad),
      color: panel,
      child: Row(children: [
        SizedBox(width: _wRule, child: Text('规则', style: mono.copyWith(fontSize: 11, color: dim))),
        SizedBox(width: _wProc, child: Text('进程', style: mono.copyWith(fontSize: 11, color: dim))),
        Expanded(flex: 5, child: Text('目标', style: mono.copyWith(fontSize: 11, color: dim))),
        Expanded(flex: 3, child: Text('链路', style: mono.copyWith(fontSize: 11, color: dim))),
        SizedBox(width: _wUp, child: Text('上行', textAlign: TextAlign.right, style: mono.copyWith(fontSize: 11, color: dim))),
        SizedBox(width: _wDown, child: Text('下行', textAlign: TextAlign.right, style: mono.copyWith(fontSize: 11, color: dim))),
        SizedBox(width: _wDur, child: Text('时长', textAlign: TextAlign.right, style: mono.copyWith(fontSize: 11, color: dim))),
        const SizedBox(width: _wClose),
      ]),
    );
  }

  Widget _row(Map c) {
    final meta = (c['metadata'] as Map?) ?? const {};
    final host = (meta['host'] as String?)?.isNotEmpty == true
        ? meta['host'] as String
        : '${meta['destinationIP'] ?? '?'}:${meta['destinationPort'] ?? ''}';
    final rule = c['rule'] == null ? '—' : '${c['rule']}(${c['rulePayload'] ?? ''})';
    final chains = (c['chains'] as List?)?.cast<String>() ?? const <String>[];
    final up = (c['upload'] as num?)?.toInt() ?? 0;
    final down = (c['download'] as num?)?.toInt() ?? 0;
    final start = DateTime.tryParse(c['start'] as String? ?? '');
    final dur = start == null ? '' : _dur(DateTime.now().difference(start));

    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: _pad),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: line, width: constructivist ? 0.5 : 1))),
      child: Row(children: [
        SizedBox(
          width: _wRule,
          child: Text(rule, style: mono.copyWith(fontSize: 11, color: dim), overflow: TextOverflow.ellipsis),
        ),
        SizedBox(
          width: _wProc,
          child: Text(_process(meta), style: mono.copyWith(fontSize: 11, color: dim), overflow: TextOverflow.ellipsis),
        ),
        Expanded(
          flex: 5,
          child: Text(host, style: mono.copyWith(fontSize: 12, color: text), overflow: TextOverflow.ellipsis),
        ),
        Expanded(
          flex: 3,
          child: Text(chains.isEmpty ? '直连' : chains.reversed.join(' → '),
              style: mono.copyWith(fontSize: 11.5, color: blue), overflow: TextOverflow.ellipsis),
        ),
        SizedBox(
          width: _wUp,
          child: Text(_bytes(up), textAlign: TextAlign.right, style: mono.copyWith(fontSize: 11.5, color: dim)),
        ),
        SizedBox(
          width: _wDown,
          child: Text(_bytes(down), textAlign: TextAlign.right, style: mono.copyWith(fontSize: 11.5, color: text)),
        ),
        SizedBox(
          width: _wDur,
          child: Text(dur, textAlign: TextAlign.right, style: mono.copyWith(fontSize: 11.5, color: dim)),
        ),
        SizedBox(
          width: _wClose,
          child: Align(
            alignment: Alignment.centerRight,
            child: InkWell(
              onTap: () => s.closeConnection(c['id'] as String),
              child: Icon(Icons.close, size: 14, color: red),
            ),
          ),
        ),
      ]),
    );
  }

  /// mihomo only reports a process when find-process-mode is not `off`.
  String _process(Map meta) {
    final p = meta['processPath'] as String?;
    if (p == null || p.isEmpty) return '—';
    return p.split('/').last;
  }

  String _bytes(int b) {
    if (b > 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    if (b > 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '$b B';
  }

  String _dur(Duration d) =>
      d.inHours > 0 ? '${d.inHours}h${d.inMinutes % 60}m' : '${d.inMinutes}m${d.inSeconds % 60}s';
}
