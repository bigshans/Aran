import 'dart:async';
import 'dart:io';

import 'package:aran_core/aran_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/legacy.dart';
import 'package:window_manager/legacy.dart';

import '../app_state.dart';
import 'common.dart';
import 'connections_page.dart';
import 'logs_page.dart';
import 'profiles_page.dart';
import 'settings_page.dart';
import 'proxies_page.dart';
import 'status_page.dart';

class Shell extends StatefulWidget {
  final AppState state;
  const Shell({super.key, required this.state});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with TrayListener, WindowListener {
  /// Resize handling: while the user drags the window edge we keep laying the
  /// page out at the *old* size (just clipped), and reflow once when the gesture
  /// settles. Continuous reflow during drag is what made the content flicker.
  bool _frozenLayout = false;
  Size _frozenSize = const Size(1280, 800);
  Timer? _resizeDebounce;
  // ARAN_PAGE lets us open a specific tab (used for screenshots / smoke tests
  // on compositors that do not forward synthetic clicks).
  int _page = int.tryParse(Platform.environment['ARAN_PAGE'] ?? '') ?? 0;

  @override
  void initState() {
    super.initState();
    stdout.writeln('ARAN_PAGE=$_page');
    _initTray();
    widget.state.addListener(_onStateChanged);
  }

  String get _trayIconPath =>
      '${File(Platform.resolvedExecutable).parent.path}/data/flutter_assets/assets/icon.png';

  Future<void> _initTray() async {
    if (!widget.state.settings.trayEnabled) return;
    try {
      await windowManager.setPreventClose(true);
      windowManager.addListener(this);
      trayManager.addListener(this);
      if (File(_trayIconPath).existsSync()) {
        await trayManager.setIcon(_trayIconPath);
      }
      await _refreshTrayMenu();
      await trayManager.setToolTip('Aran');
    } catch (e) {
      stdout.writeln('tray unavailable: $e');
    }
  }

  /// Rebuild the tray menu from live state; it is the main control surface when
  /// the window is hidden.
  Future<void> _refreshTrayMenu() async {
    final AppState st = widget.state;
    final running = st.proxyRunning;
    final snap = st.engine?.snapshot.value;
    final node = snap?.currentName;
    try {
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: '显示 Aran'),
        MenuItem(type: 'separator'),
        MenuItem(key: 'toggle', label: running ? '⏻ 关闭代理' : '⏻ 开启代理'),
        MenuItem(key: 'restart', label: '↻ 重启内核'),
        MenuItem(type: 'separator'),
        if (node != null) MenuItem(key: 'noop', label: '当前节点：$node'),
        MenuItem(key: 'best', label: '切到评分最高的节点'),
        MenuItem(type: 'separator'),
        MenuItem(key: 'mode-rule', label: '出站模式：规则'),
        MenuItem(key: 'mode-global', label: '出站模式：全局'),
        MenuItem(key: 'mode-direct', label: '出站模式：直连'),
        MenuItem(type: 'separator'),
        MenuItem(key: 'takeover', type: 'checkbox', checked: st.takeover, label: '自动切换节点'),
        MenuItem(key: 'sysproxy', type: 'checkbox', checked: st.settings.systemProxy, label: '系统代理'),
        MenuItem(key: 'tun', type: 'checkbox', checked: st.settings.tunEnabled, label: 'TUN 模式'),
        MenuItem(type: 'separator'),
        for (final p in st.profiles.profiles.take(6))
          MenuItem(
            key: 'profile:${p.id}',
            label: '${p.id == st.profiles.activeId ? '● ' : '　'}配置：${p.name}',
          ),
        MenuItem(key: 'subupdate', label: '↻ 更新当前订阅'),
        MenuItem(key: 'copyenv', label: '复制代理环境变量'),
        MenuItem(key: 'datadir', label: '打开数据目录'),
        MenuItem(type: 'separator'),
        MenuItem(key: 'quit-keep', label: '退出（保留内核）'),
        MenuItem(key: 'quit', label: '退出并停止代理'),
      ]));
    } catch (e) {
      stdout.writeln('tray menu: $e');
    }
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onWindowResize() {
    if (!_frozenLayout) {
      final size = _frozenSize;
      setState(() {
        _frozenLayout = true;
        _frozenSize = size;
      });
    }
    _resizeDebounce?.cancel();
    _resizeDebounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      setState(() {
        _frozenLayout = false;
      });
    });
  }

  @override
  void onWindowMinimize() async {
    if (widget.state.settings.trayEnabled) {
      await windowManager.hide();
    }
  }

  @override
  void onWindowClose() async {
    if (widget.state.settings.trayEnabled) {
      await windowManager.hide();
    } else {
      await widget.state.stopProxy();
      await windowManager.destroy();
    }
  }

  @override
  void onTrayIconMouseDown() => _showWindow();

  /// Quit without touching the kernel (only meaningful when systemd owns it, or
  /// when you want the orphan to be reaped on next start).
  Future<void> _quit({required bool keepKernel}) async {
    if (!keepKernel) await widget.state.stopProxy();
    await trayManager.destroy();
    exit(0);
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
      case 'status':
        await _showWindow();
      case 'toggle':
        if (widget.state.proxyRunning) {
          await widget.state.stopProxy();
        } else {
          await widget.state.startProxy();
        }
        await _refreshTrayMenu();
      case 'restart':
        await widget.state.restartKernel();
        await _refreshTrayMenu();
      case 'best':
        final snap = widget.state.engine?.snapshot.value;
        final top = snap?.ranked.firstOrNull;
        if (top != null) {
          await widget.state.selectNode(snap!.group, top.name);
          await _refreshTrayMenu();
        }
      case 'mode-rule':
        await widget.state.setMode('rule');
      case 'mode-global':
        await widget.state.setMode('global');
      case 'mode-direct':
        await widget.state.setMode('direct');
      case 'takeover':
        widget.state.setTakeover(!widget.state.takeover);
        await _refreshTrayMenu();
      case 'sysproxy':
        await widget.state.setSystemProxy(!widget.state.settings.systemProxy);
        await _refreshTrayMenu();
      case 'tun':
        await widget.state.setTun(!widget.state.settings.tunEnabled);
        await _refreshTrayMenu();
      case 'subupdate':
        final active = widget.state.profiles.activeId;
        if (active != null) await widget.state.updateProfile(active);
        await _refreshTrayMenu();
      case final String k when k.startsWith('profile:'):
        await widget.state.activateProfile(k.substring('profile:'.length));
        await _refreshTrayMenu();
      case 'copyenv':
        await Clipboard.setData(ClipboardData(text: widget.state.envScript()));
      case 'datadir':
        await Process.run('xdg-open', [widget.state.dataDir.path]);
      case 'quit-keep':
        await _quit(keepKernel: true);
      case 'quit':
        await _quit(keepKernel: false);
    }
  }

  void _onStateChanged() {
    final st = widget.state;
    final sig = '${st.proxyRunning}|${st.takeover}|${st.settings.tunEnabled}|${st.settings.systemProxy}|'
        '${st.profiles.activeId}|${st.engine?.snapshot.value.currentName}|${st.settings.groupModes}';
    if (sig == _lastMenuSig && !_menuStale) return;
    _lastMenuSig = sig;
    _menuStale = false;
    _refreshTrayMenu();
  }

  String _lastMenuSig = '';
  bool _menuStale = false;

  @override
  void dispose() {
    _resizeDebounce?.cancel();
    widget.state.removeListener(_onStateChanged);
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    super.dispose();
  }

  AppState get s => widget.state;

  @override
  Widget build(BuildContext context) {
    final actual = MediaQuery.sizeOf(context);
    if (!_frozenLayout) _frozenSize = actual;

    return AnimatedBuilder(
      animation: s,
      builder: (context, _) {
        final render = _frozenLayout ? _frozenSize : actual;
        return ClipRect(
          child: SizedBox(
            width: render.width,
            height: render.height,
            child: _scaffold(context),
          ),
        );
      },
    );
  }

  Widget _scaffold(BuildContext context) {
    return Scaffold(
          body: Column(
            children: [
              _TopBar(state: s, onPower: _togglePower),
              ErrorBanner(message: s.error, onDismiss: () => s.setError(null)),
              _NoticeBar(state: s),
              Expanded(
                child: Row(
                  children: [
                    _Rail(
                      index: _page,
                      compact: s.settings.compactRail,
                      onToggleCompact: () => s.setCompactRail(!s.settings.compactRail),
                      onSelect: (i) => setState(() => _page = i),
                    ),
                    VerticalDivider(width: 1, color: line),
                    Expanded(child: _body()),
                  ],
                ),
              ),
            ],
          ),
    );
  }

  Widget _body() {
    switch (_page) {
      case 0:
        return StatusPage(state: s);
      case 1:
        return ProxiesPage(state: s);
      case 2:
        return ProfilesPage(state: s);
      case 3:
        return ConnectionsPage(state: s);
      case 4:
        return LogsPage(state: s);
      case 5:
        return SettingsPage(state: s);
      default:
        return const _IconPreview();
    }
  }

  Future<void> _togglePower() async {
    if (s.proxyRunning) {
      await s.stopProxy();
    } else {
      await s.startProxy();
    }
  }
}

/// Transient feedback for every action: what happened, when, and whether it worked.
class _NoticeBar extends StatelessWidget {
  final AppState state;
  const _NoticeBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final n = state.notice;
    if (n == null) return const SizedBox.shrink();
    final color = n.ok ? green : red;
    final t = '${n.at.hour.toString().padLeft(2, '0')}:'
        '${n.at.minute.toString().padLeft(2, '0')}:'
        '${n.at.second.toString().padLeft(2, '0')}';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 6, 16, 6),
      color: color.withValues(alpha: 0.12),
      child: Row(children: [
        Icon(n.ok ? Icons.check_circle : Icons.error, size: 14, color: color),
        const SizedBox(width: 8),
        Text(t, style: mono.copyWith(fontSize: 11, color: dim)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(n.text, style: mono.copyWith(fontSize: 12, color: color), overflow: TextOverflow.ellipsis),
        ),
      ]),
    );
  }
}

class _Rail extends StatelessWidget {
  final int index;
  final ValueChanged<int> onSelect;
  final bool compact;
  final VoidCallback onToggleCompact;
  const _Rail({
    required this.index,
    required this.onSelect,
    required this.compact,
    required this.onToggleCompact,
  });

  @override
  Widget build(BuildContext context) {
    const items = [
      (Icons.insights, '状态'),
      (Icons.hub, '代理'),
      (Icons.list_alt, '配置'),
      (Icons.swap_vert, '连接'),
      (Icons.terminal, '日志'),
      (Icons.tune, '设置'),
    ];
    return Container(
      width: compact ? 60 : 116,
      color: panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 6),
          for (var i = 0; i < items.length; i++)
            _RailItem(
              icon: items[i].$1,
              label: items[i].$2,
              selected: i == index,
              compact: compact,
              onTap: () => onSelect(i),
            ),
          const Spacer(),
          _RailToggle(compact: compact, onTap: onToggleCompact),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;
  const _RailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? (constructivist ? Colors.white : blue) : dim;
    final content = Container(
      height: 48,
      decoration: BoxDecoration(
        color: selected
            ? (constructivist ? blue : blue.withValues(alpha: 0.10))
            : Colors.transparent,
        border: Border(
          left: BorderSide(color: selected ? blue : Colors.transparent, width: 2.5),
        ),
      ),
      child: Row(
        mainAxisAlignment: compact ? MainAxisAlignment.center : MainAxisAlignment.start,
        children: [
          if (!compact) const SizedBox(width: 22),
          Icon(icon, size: 18, color: color),
          if (!compact) ...[
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                label,
                softWrap: false,
                overflow: TextOverflow.clip,
                style: mono.copyWith(
                  fontSize: 12.5,
                  color: color,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ],
      ),
    );
    return Tooltip(
      message: compact ? label : '',
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        color: Colors.transparent,
        child: InkWell(onTap: onTap, hoverColor: blue.withValues(alpha: 0.05), child: content),
      ),
    );
  }
}

class _RailToggle extends StatelessWidget {
  final bool compact;
  final VoidCallback onTap;
  const _RailToggle({required this.compact, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: compact ? '展开侧栏' : '收起侧栏',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          hoverColor: blue.withValues(alpha: 0.05),
          child: SizedBox(
            height: 40,
            child: Row(
              mainAxisAlignment: compact ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: [
                if (!compact) const SizedBox(width: 24),
                Icon(compact ? Icons.chevron_right : Icons.chevron_left, size: 18, color: dim),
                if (!compact) ...[
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text('收起',
                        softWrap: false,
                        overflow: TextOverflow.clip,
                        style: mono.copyWith(fontSize: 11, color: dim)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final AppState state;
  final VoidCallback onPower;
  const _TopBar({required this.state, required this.onPower});

  @override
  Widget build(BuildContext context) {
    final kernel = state.kernel.status;
    final running = state.proxyRunning;
    final profile = state.profiles.active;

    return Container(
      height: 54,
      padding: const EdgeInsets.fromLTRB(18, 0, 16, 0),
      decoration: BoxDecoration(
        color: panel,
        border: Border(bottom: BorderSide(color: lineStrong, width: 1)),
      ),
      child: Row(
        children: [
          const AranMark(size: 22),
          const SizedBox(width: 10),
          Text(
            constructivist ? 'ARAN' : 'Aran',
            style: TextStyle(
              fontSize: constructivist ? 15 : 16,
              fontWeight: FontWeight.w700,
              letterSpacing: constructivist ? 4 : 0.5,
              color: text,
            ),
          ),
          if (constructivist) ...[
            const SizedBox(width: 10),
            Container(width: 22, height: 2, color: blue),
          ],
          const SizedBox(width: 14),
          if (state.busy)
            SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: amber),
            )
          else
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(shape: BoxShape.circle, color: _kernelColor(kernel.state)),
            ),
          const SizedBox(width: 7),
          Tooltip(
            message: running
                ? 'mihomo ${kernel.version ?? ''} · ${state.systemdKernel ? 'systemd 托管' : 'Aran 直接拉起'}'
                : '代理未开启',
            child: Text(
              running
                  ? (state.systemdKernel ? 'systemd' : '直连')
                  : kernel.state == KernelState.starting
                      ? '启动中…'
                      : kernel.state == KernelState.failed
                          ? '内核异常'
                          : '未开启',
              style: mono.copyWith(fontSize: 11.5, color: dim),
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: (profile == null ? amber : green).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(radius),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(profile == null ? Icons.error_outline : Icons.check_circle,
                  size: 12, color: profile == null ? amber : green),
              const SizedBox(width: 5),
              Text(
                profile?.name ?? '未选择配置',
                style: mono.copyWith(fontSize: 11, color: profile == null ? amber : green),
              ),
            ]),
          ),
          if (profile != null) ...[
            if (profile.trafficLeft != null) ...[
              const SizedBox(width: 10),
              _quotaChip(profile),
              if (profile.trafficTotal != null && profile.trafficUsed != null) ...[
                const SizedBox(width: 8),
                QuotaBar(
                  used: profile.trafficUsed!,
                  total: profile.trafficTotal!,
                  width: 70,
                  height: 4,
                  showPercent: false,
                ),
              ],
            ],
          ],
          const Spacer(),
          Tooltip(
            message: '主题：${state.themeLabel}',
            child: InkWell(
              onTap: () => state.setThemeMode(state.nextThemeMode),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Icon(
                  switch (state.settings.themeMode) {
                    'light' => Icons.light_mode,
                    'dark' => Icons.dark_mode,
                    _ => Icons.brightness_auto,
                  },
                  size: 16,
                  color: dim,
                ),
              ),
            ),
          ),
          if (running) ...[
            const SizedBox(width: 8),
            CheckRow(
              label: '系统',
              value: state.settings.systemProxy,
              color: green,
              loading: state.isPending('sysproxy'),
              tooltip: '把桌面代理指向本机混合端口（与 TUN 二选一）',
              onChanged: (v) => state.runPending('sysproxy', () => state.setSystemProxy(v)),
            ),
            const SizedBox(width: 2),
            CheckRow(
              label: 'TUN',
              value: state.settings.tunEnabled,
              color: green,
              loading: state.isPending('tun'),
              tooltip: '接管全部流量，需要 CAP_NET_ADMIN',
              onChanged: (v) => state.runPending('tun', () => state.setTun(v)),
            ),
            const SizedBox(width: 8),
            _ModeSwitch(state: state),
            const SizedBox(width: 8),
            CheckRow(
              label: '自动切换',
              value: state.takeover,
              color: amber,
              tooltip: '关闭后 Aran 只给建议，不实际切节点',
              onChanged: (v) => state.setTakeover(v),
            ),
          ],
          const SizedBox(width: 10),
          if (running) ...[
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: state.isPending('restart')
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.6, color: amber),
                    )
                  : InkWell(
                      onTap: () => state.runPending('restart', () => state.restartKernel()),
                      child: Icon(Icons.refresh, size: 16, color: dim),
                    ),
            ),
          ],
          Btn(
            label: state.busy ? '处理中…' : (running ? '关闭代理' : '开启代理'),
            icon: Icons.power_settings_new,
            color: running ? red : green,
            filled: true,
            onTap: state.busy ? null : onPower,
          ),
        ],
      ),
    );
  }

  Widget _quotaChip(Profile p) {
    final left = p.trafficLeft!;
    final total = p.trafficTotal;
    final ratio = (total != null && total > 0) ? left / total : null;
    final color = ratio == null
        ? blue
        : ratio < 0.1
            ? red
            : ratio < 0.3
                ? amber
                : green;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Text('剩余 ${fmtBytes(left)}', style: mono.copyWith(fontSize: 10.5, color: color)),
    );
  }

  static Color _kernelColor(KernelState s) => switch (s) {
        KernelState.running => green,
        KernelState.starting => amber,
        KernelState.failed => red,
        KernelState.stopped => dim,
      };
}

class _ModeSwitch extends StatefulWidget {
  final AppState state;
  const _ModeSwitch({required this.state});

  @override
  State<_ModeSwitch> createState() => _ModeSwitchState();
}

class _ModeSwitchState extends State<_ModeSwitch> {
  String _mode = 'rule';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final m = await widget.state.fetchMode();
    if (mounted) setState(() => _mode = m);
  }

  @override
  Widget build(BuildContext context) {
    return Segment(
      value: _mode,
      options: const [('rule', '规则'), ('global', '全局'), ('direct', '直连')],
      onChanged: (v) async {
        await widget.state.setMode(v);
        if (mounted) setState(() => _mode = v);
      },
    );
  }
}

class _IconPreview extends StatelessWidget {
  const _IconPreview();

  static const icons = <String, IconData>{
    'insights': Icons.insights,
    'dashboard': Icons.dashboard,
    'dns': Icons.dns_outlined,
    'public': Icons.public,
    'tune': Icons.tune,
    'settings': Icons.settings_outlined,
    'swap_vert': Icons.swap_vert,
    'link': Icons.link,
    'terminal': Icons.terminal,
    'speed': Icons.speed,
    'power': Icons.power_settings_new,
    'refresh': Icons.refresh,
    'arrow_drop_down': Icons.arrow_drop_down,
    'bolt': Icons.bolt,
    'article': Icons.article_outlined,
  };

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Wrap(
        spacing: 18,
        runSpacing: 18,
        children: [
          for (final e in icons.entries)
            SizedBox(
              width: 92,
              child: Column(children: [
                Icon(e.value, size: 26),
                const SizedBox(height: 6),
                Text(e.key, style: mono.copyWith(fontSize: 10, color: dim)),
              ]),
            ),
        ],
      ),
    );
  }
}
