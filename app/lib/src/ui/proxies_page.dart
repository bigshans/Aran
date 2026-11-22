import 'dart:async';

import 'package:aran_core/aran_core.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import 'common.dart';

class ProxiesPage extends StatefulWidget {
  final AppState state;
  const ProxiesPage({super.key, required this.state});

  @override
  State<ProxiesPage> createState() => _ProxiesPageState();
}

class _ProxiesPageState extends State<ProxiesPage> {
  Map<String, dynamic> _proxies = const {};
  Map<String, int> _tested = const {};
  Timer? _timer;
  String? _testing;
  String _query = '';
  bool _onlyReachable = false;
  final Set<String> _expanded = {};
  bool _autoExpanded = false;

  static const _groupTypes = {'Selector', 'URLTest', 'Fallback', 'LoadBalance'};

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!s.proxyRunning) return;
    final p = await s.fetchProxies();
    if (!mounted || p.isEmpty) return;
    setState(() {
      _proxies = p;
      // Auto-expand the group Aran drives, exactly once. Doing it whenever the
      // set is empty would re-open a group the user just collapsed.
      if (!_autoExpanded) {
        _autoExpanded = true;
        final target = s.engine?.group;
        if (target != null && p.containsKey(target)) _expanded.add(target);
      }
    });
  }

  Future<void> _testGroup(String group) async {
    setState(() => _testing = group);
    final r = await s.testGroupDelays(group);
    if (mounted) {
      setState(() {
        _tested = {..._tested, ...r};
        _testing = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!s.proxyRunning) {
      return Center(child: Text('代理未开启', style: mono.copyWith(color: dim)));
    }
    if (_proxies.isEmpty) {
      return Center(child: Text('正在读取代理组…', style: mono.copyWith(color: dim)));
    }

    final groups = _proxies.entries
        .where((e) => _groupTypes.contains((e.value as Map)['type']))
        .where((e) => e.key != 'GLOBAL')
        .toList();

    return Column(
      children: [
        _toolbar(),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
            itemCount: groups.length,
            itemBuilder: (context, i) => _groupCard(groups[i].key, groups[i].value as Map),
          ),
        ),
      ],
    );
  }

  Widget _toolbar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: line, width: borderWidth))),
      child: Row(children: [
        SizedBox(
          width: 260,
          height: 32,
          child: TextField(
            onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
            style: mono.copyWith(fontSize: 12),
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索节点…',
              hintStyle: mono.copyWith(fontSize: 12, color: dim),
              prefixIcon: Icon(Icons.search, size: 15, color: dim),
              prefixIconConstraints: const BoxConstraints(minWidth: 32),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(radius)),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(radius),
                borderSide: BorderSide(color: line, width: borderWidth),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Btn(
          label: _onlyReachable ? '仅显示可用' : '显示全部',
          small: true,
          filled: _onlyReachable,
          onTap: () => setState(() => _onlyReachable = !_onlyReachable),
        ),
        const Spacer(),
        Text('共 ${_proxies.length} 个节点 / ${_groupTypes.length} 类组',
            style: mono.copyWith(fontSize: 11, color: dim)),
      ]),
    );
  }

  Widget _groupCard(String name, Map group) {
    final now = group['now'] as String?;
    final members = (group['all'] as List?)?.cast<String>() ?? const <String>[];
    final isAuto = group['type'] != 'Selector';
    final aranDriven = s.engine?.managedGroups.contains(name) ?? false;
    final expanded = _expanded.contains(name);

    final nodes = members.where((m) => !_groupTypes.contains((_proxies[m] as Map?)?['type'])).toList();
    final visible = nodes.where((n) {
      if (_query.isNotEmpty && !n.toLowerCase().contains(_query)) return false;
      if (_onlyReachable && (_tested[n] ?? _lastDelay(n)) == null) return false;
      return true;
    }).toList()
      ..sort((a, b) {
        final da = _tested[a] ?? _lastDelay(a) ?? 1 << 30;
        final db = _tested[b] ?? _lastDelay(b) ?? 1 << 30;
        return da.compareTo(db);
      });

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: panel,
        border: constructivist
            ? Border(left: BorderSide(color: lineStrong, width: 2))
            : Border.all(color: line, width: borderWidth),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => expanded ? _expanded.remove(name) : _expanded.add(name)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
              child: Row(children: [
                Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 18, color: dim),
                const SizedBox(width: 6),
                Text(name, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: text)),
                const SizedBox(width: 8),
                _tag(isAuto ? group['type'] as String : 'select', dim),
                const SizedBox(width: 5),
                if (aranDriven)
                  _tag(s.takeover ? 'Aran 自动切换' : 'Aran 仅建议', s.takeover ? amber : blue)
                else
                  _tag('不由 Aran 管理', dim),
                const SizedBox(width: 12),
                if (now != null)
                  Flexible(
                    child: Text(now, style: mono.copyWith(fontSize: 11.5, color: blue), overflow: TextOverflow.ellipsis),
                  ),
                const SizedBox(width: 8),
                Text('${visible.length}/${nodes.length}', style: mono.copyWith(fontSize: 11, color: dim)),
                const SizedBox(width: 10),
                _modeDropdown(name),
                const SizedBox(width: 6),
                _prefDropdown(name),
                const SizedBox(width: 8),
                Btn(
                  label: _testing == name ? '测速中…' : '测速',
                  icon: Icons.speed,
                  small: true,
                  onTap: _testing == null ? () => _testGroup(name) : null,
                ),
              ]),
            ),
          ),
          if (expanded) ...[
            Divider(height: 1, color: line),
            for (final n in visible) _nodeRow(group: name, node: n, selected: n == now),
            if (visible.isEmpty)
              Padding(
                padding: const EdgeInsets.all(18),
                child: Text('没有匹配的节点', style: mono.copyWith(fontSize: 12, color: dim)),
              ),
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }

  static const _regions = ['自动', '日本', '新加坡', '香港', '台湾', '美国', '韩国'];

  /// Per-group control: follow global switch, force auto, only suggest, or hand
  /// the group back to mihomo / manual selection entirely.
  Widget _modeDropdown(String group) {
    final override = s.settings.groupModes[group];
    final effective = override ?? (s.takeover ? 'auto' : 'suggest');
    final label = switch (effective) {
      'auto' => '自动切换',
      'suggest' => '仅建议',
      _ => '不管理',
    };
    final color = switch (effective) {
      'auto' => amber,
      'suggest' => blue,
      _ => dim,
    };
    return Container(
      height: 27,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(border: Border.all(color: line, width: borderWidth), borderRadius: BorderRadius.circular(radius)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: override ?? '',
          isDense: true,
          dropdownColor: panel,
          style: mono.copyWith(fontSize: 11.5, color: color),
          items: const [
            DropdownMenuItem(value: '', child: Text('控制：跟随全局')),
            DropdownMenuItem(value: 'auto', child: Text('控制：自动切换')),
            DropdownMenuItem(value: 'suggest', child: Text('控制：仅建议')),
            DropdownMenuItem(value: 'off', child: Text('控制：不管理')),
          ],
          onChanged: (v) => s.setGroupMode(group, v ?? ''),
          selectedItemBuilder: (context) => [
            for (final entry in const ['', 'auto', 'suggest', 'off'])
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  entry.isEmpty ? '控制：$label' : '控制：${switch (entry) {
                    'auto' => '自动切换',
                    'suggest' => '仅建议',
                    _ => '不管理',
                  }}',
                  style: mono.copyWith(fontSize: 11.5, color: entry.isEmpty ? color : color),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Per-group region preference: "TikTok 优先新加坡" is a routing decision the
  /// user should be able to make without editing YAML.
  Widget _prefDropdown(String group) {
    final current = s.settings.groupPrefs[group] ?? '';
    final label = current.isEmpty ? '自动' : current;
    return Container(
      height: 27,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(border: Border.all(color: line, width: borderWidth), borderRadius: BorderRadius.circular(radius)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: label,
          isDense: true,
          dropdownColor: panel,
          style: mono.copyWith(fontSize: 11.5, color: current.isEmpty ? dim : blue),
          items: [
            for (final r in _regions)
              DropdownMenuItem(value: r, child: Text(r == '自动' ? '地区：自动' : '地区：$r')),
          ],
          onChanged: (v) {
            if (v == null) return;
            s.setGroupPref(group, v == '自动' ? '' : v);
          },
        ),
      ),
    );
  }

  Widget _tag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(radius)),
        child: Text(text, style: mono.copyWith(fontSize: 10, color: color)),
      );

  int? _lastDelay(String name) {
    final node = _proxies[name];
    if (node is! Map) return null;
    final history = node['history'];
    if (history is List && history.isNotEmpty) {
      final last = history.last;
      if (last is Map) {
        final d = last['delay'];
        if (d is num && d > 0) return d.toInt();
      }
    }
    return null;
  }

  /// Airport names embed the multiplier; render it as a badge instead.
  String _cleanName(String name) =>
      name.replaceFirst(RegExp(r'\s*[xX×]\s*[0-9]+(\.[0-9]+)?\s*$'), '').trim();

  Widget _nodeRow({required String group, required String node, required bool selected}) {
    final mult = NodeState.parseMultiplier(node);
    final delay = _tested[node] ?? _lastDelay(node);
    final delayColor = delay == null
        ? dim
        : delay < 150
            ? green
            : delay < 300
                ? amber
                : red;

    return Material(
      color: selected ? blue.withValues(alpha: 0.08) : Colors.transparent,
      child: InkWell(
        onTap: () => s.selectNode(group, node),
        hoverColor: blue.withValues(alpha: 0.05),
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: line, width: constructivist ? 0.5 : borderWidth)),
          ),
          child: Row(children: [
            SizedBox(
              width: 3,
              height: 16,
              child: selected ? DecoratedBox(decoration: BoxDecoration(color: blue, borderRadius: BorderRadius.circular(radius))) : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _cleanName(node),
                style: mono.copyWith(fontSize: 12, color: selected ? blue : text),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (mult > 1)
              Container(
                margin: const EdgeInsets.only(right: 10),
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: amber.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(radius),
                ),
                child: Text('×$mult', style: mono.copyWith(fontSize: 10, color: amber)),
              ),
            // latency bar: 0..400ms mapped to width
            SizedBox(
              width: 90,
              child: Align(
                alignment: Alignment.centerRight,
                child: Container(
                  height: 4,
                  width: delay == null ? 0 : (90 * (delay / 400).clamp(0.06, 1.0)),
                  decoration: BoxDecoration(color: delayColor, borderRadius: BorderRadius.circular(radius)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 62,
              child: Text(
                delay == null ? '—' : '${delay}ms',
                textAlign: TextAlign.right,
                style: mono.copyWith(fontSize: 11.5, color: delayColor),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 40,
              child: selected ? Icon(Icons.check, size: 14, color: blue) : const SizedBox.shrink(),
            ),
          ]),
        ),
      ),
    );
  }
}
