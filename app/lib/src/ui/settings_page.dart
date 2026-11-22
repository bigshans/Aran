import 'dart:async';
import 'dart:io';

import 'package:aran_core/aran_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import 'common.dart';

class SettingsPage extends StatefulWidget {
  final AppState state;
  const SettingsPage({super.key, required this.state});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late AranSettings _draft;
  late final Map<String, TextEditingController> _ctrl;
  Timer? _debounce;
  DateTime? _appliedAt;
  bool? _tunCapable;

  AppState get s => widget.state;

  static const _scales = {'紧凑': 1.0, '标准': 1.2, '大': 1.35, '特大': 1.5};

  @override
  void initState() {
    super.initState();
    _draft = s.settings;
    _ctrl = {
      'port': TextEditingController(text: '${_draft.mixedPort}'),
      'httpPort': TextEditingController(text: '${_draft.httpPort}'),
      'socksPort': TextEditingController(text: '${_draft.socksPort}'),
      'fakeIpRange': TextEditingController(text: _draft.fakeIpRange),
      'nameservers': TextEditingController(text: _draft.nameservers.join('\n')),
      'fallback': TextEditingController(text: _draft.fallback.join('\n')),
      'smartdnsUpstreams': TextEditingController(text: _draft.smartdnsUpstreams.join('\n')),
      'smartdnsCache': TextEditingController(text: '${_draft.smartdnsCache}'),
      'threshold': TextEditingController(text: ((_draft.threshold - 1) * 100).round().toString()),
      'cooldown': TextEditingController(text: '${_draft.cooldownMinutes}'),
      'testUrl': TextEditingController(text: _draft.testUrl),
      'testTimeout': TextEditingController(text: '${_draft.testTimeoutMs}'),
    };
    // Editing *is* applying: switches/dropdowns apply at once, text fields apply
    // shortly after typing stops. No save button.
    for (final c in _ctrl.values) {
      c.addListener(_queueSave);
    }
    s.tunCapable().then((v) {
      if (mounted) setState(() => _tunCapable = v);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final c in _ctrl.values) {
      c.removeListener(_queueSave);
      c.dispose();
    }
    super.dispose();
  }

  void _queueSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), _apply);
  }

  void _applyNow() {
    _debounce?.cancel();
    _apply();
  }

  Future<void> _apply() async {
    if (!mounted) return;
    await s.saveSettings(_collect());
    if (mounted) setState(() => _appliedAt = DateTime.now());
  }

  void _update(AranSettings next) {
    setState(() => _draft = next);
    _applyNow();
  }

  AranSettings _collect() {
    List<String> lines(String key) =>
        _ctrl[key]!.text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    int? num(String key) => int.tryParse(_ctrl[key]!.text.trim());
    return _draft.copyWith(
      mixedPort: num('port') ?? _draft.mixedPort,
      httpPort: num('httpPort') ?? _draft.httpPort,
      socksPort: num('socksPort') ?? _draft.socksPort,
      fakeIpRange: _ctrl['fakeIpRange']!.text.trim(),
      nameservers: lines('nameservers'),
      fallback: lines('fallback'),
      smartdnsUpstreams: lines('smartdnsUpstreams'),
      smartdnsCache: num('smartdnsCache') ?? _draft.smartdnsCache,
      threshold: 1 + (double.tryParse(_ctrl['threshold']!.text.trim()) ?? 30) / 100,
      cooldownMinutes: num('cooldown') ?? _draft.cooldownMinutes,
      testUrl: _ctrl['testUrl']!.text.trim(),
      testTimeoutMs: num('testTimeout') ?? _draft.testTimeoutMs,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            children: [
              _card('外观', [
                _row('主题', '跟随系统 / 浅色 / 深色', _dropdown(
                  value: s.settings.themeMode,
                  items: const ['system', 'light', 'dark'],
                  onChanged: (v) => s.setThemeMode(v),
                )),
                _row('主题色', '影响强调色、开关、选中态；留空则跟随风格默认',
                    _accentPicker(context)),
                _row('界面风格', 'modern=轻量现代；constructivist=纸白/墨黑/朱红，硬边直角粗线',
                    _dropdown(
                      value: s.settings.themeStyle,
                      width: 150,
                      items: const ['modern', 'constructivist'],
                      onChanged: (v) => s.setThemeStyle(v),
                    )),
                _row('字体大小', '全局缩放，立即生效',
                    _dropdown(
                      value: _scaleKey(s.settings.uiScale),
                      items: _scales.keys.toList(),
                      onChanged: (v) => s.setUiScale(_scales[v] ?? 1.2),
                    )),
              ]),
              _card('系统集成', [
                _row('运行模式',
                    'managed=GUI 拉起内核（关窗口即停）；service=systemd 托管（关窗口照跑，开机自启，TUN 免授权）。'
                    '端口只有一套（混合 ${_draft.mixedPort}），两种模式共用',
                    _dropdown(
                      value: _draft.runMode,
                      width: 130,
                      items: const ['managed', 'service'],
                      onChanged: (v) => _update(_draft.copyWith(runMode: v)),
                    )),
                if (_draft.runMode == 'service' && s.supportsSystemService) ...[
                  _row('服务范围',
                      _draft.serviceScope == 'user'
                          ? (Platform.isWindows
                              ? '当前用户（登录计划任务）：不需要管理员，但登录后才启动且不能建 TUN'
                              : '当前用户（systemctl --user）：不需要 root，重启内核不会弹密码')
                          : (Platform.isWindows
                              ? '系统级（Windows 服务）：安装与启停都需要 UAC'
                              : '系统级（/etc/systemd/system）：每次操作都要提权，需要 polkit/sudo'),
                      _dropdown(
                        value: _draft.serviceScope,
                        width: 130,
                        items: const ['user', 'system'],
                        onChanged: (v) => _update(_draft.copyWith(serviceScope: v)),
                      )),
                  _row('服务', _serviceDescribe(), Row(mainAxisSize: MainAxisSize.min, children: [
                    _servicePrimaryButton(),
                    const SizedBox(width: 8),
                    _serviceMenu(context),
                  ])),
                ],
                _row('内核来源', _kernelSourceDescribe(), _kernelSourceBadge()),
                _row('直接启动内核', '不用 systemd，由 Aran 自己拉起并管理进程',
                    Btn(
                      label: '直接启动',
                      small: true,
                      loading: s.isPending('direct'),
                      onTap: () => s.runPending('direct', () => s.startKernelDirect()),
                    )),
                _row('系统代理', '把桌面（KDE/GNOME）代理指向本机混合端口；与 TUN 二选一',
                    _toggle(s.settings.systemProxy, (v) => s.setSystemProxy(v))),
                _row('桌面通知', '订阅更新失败、流量告急、内核异常时发系统通知',
                    _toggle(s.settings.notifyEnabled,
                        (v) => s.saveSettings(s.settings.copyWith(notifyEnabled: v)))),
                _row('开机自启', '登录桌面时自动启动 Aran 并开启代理（写 ~/.config/autostart）',
                    _toggle(s.autoStartInstalled, (v) => s.setAutoStart(v))),
                _row('常驻托盘', '关闭窗口时隐藏到托盘而不是退出（改动后重启 Aran 生效）',
                    _toggle(s.settings.trayEnabled, (v) => s.saveSettings(s.settings.copyWith(trayEnabled: v)))),
                _row('启动时最小化', '启动即隐藏到托盘，只在后台跑代理（下次启动生效）',
                    _toggle(s.settings.startMinimized,
                        (v) => s.saveSettings(s.settings.copyWith(startMinimized: v)))),
                if (_draft.tunEnabled && _tunCapable == false)
                  _row(
                    'TUN 需要授权',
                    '当前内核没有 CAP_NET_ADMIN（内嵌/下载的副本默认不带），点右侧授权一次',
                    Btn(
                      label: '授权此内核',
                      small: true,
                      color: amber,
                      loading: s.isPending('tuncap'),
                      onTap: () => s.runPending('tuncap', () async {
                        await s.installTunCapability();
                        final ok = await s.tunCapable();
                        if (mounted) setState(() => _tunCapable = ok);
                      }),
                    ),
                  ),
                _row(
                  'TUN 模式',
                  _tunCapable == null
                      ? '检测权限中…'
                      : _tunCapable!
                          ? '已具备 CAP_NET_ADMIN：接管全部流量，CLI/游戏/Docker 都走代理'
                          : '尚未授权：点右侧按钮一次性授予 CAP_NET_ADMIN（无需 root 常驻）',
                  _toggle(_draft.tunEnabled, (v) async {
                    if (v && _tunCapable == false) {
                      await s.installTunCapability();
                      final ok = await s.tunCapable();
                      if (mounted) setState(() => _tunCapable = ok);
                      if (!ok) return;
                    }
                    _update(_draft.copyWith(tunEnabled: v));
                  }),
                ),
                _row('TUN 权限', '等价命令：sudo setcap cap_net_admin,cap_net_raw+eip /usr/bin/mihomo',
                    Btn(
                      label: _tunCapable == true ? '重新授权' : '授权',
                      small: true,
                      loading: s.isPending('tuncap'),
                      onTap: () async {
                        await s.runPending('tuncap', () async {
                          await s.installTunCapability();
                          final ok = await s.tunCapable();
                          if (mounted) setState(() => _tunCapable = ok);
                        });
                      },
                    )),
                _row(
                  '诊断包',
                  '打包 kernel.log / audit.jsonl / systemd 状态 / 脱敏设置（不含节点凭据）',
                  Btn(
                    label: '导出',
                    icon: Icons.archive,
                    small: true,
                    loading: s.isPending('diag'),
                    onTap: () => s.runPending('diag', () => s.exportDiagnostics()),
                  ),
                ),
                _row(
                  '环境变量',
                  '按所选 shell 的语法生成代理变量，复制给终端里的 CLI 工具用',
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    _dropdown(
                      value: s.settings.envShell,
                      items: const ['bash', 'zsh', 'fish', 'nushell', 'powershell', 'csh'],
                      onChanged: (v) => s.saveSettings(s.settings.copyWith(envShell: v)),
                    ),
                    const SizedBox(width: 8),
                    Btn(
                      label: '查看 / 复制',
                      icon: Icons.copy,
                      small: true,
                      onTap: _showEnvDialog,
                    ),
                  ]),
                ),
              ]),
              _card('内核', [
                _kernelRow(),
                if (s.settings.kernelPath.trim().isNotEmpty &&
                    !File(s.settings.kernelPath.trim()).existsSync())
                  _row(
                    '内核路径无效',
                    '${s.settings.kernelPath.trim()} 不存在，已回退到自动探测',
                    Btn(
                      label: '清除',
                      small: true,
                      color: red,
                      onTap: () => s.saveSettings(s.settings.copyWith(kernelPath: '')),
                    ),
                  ),
                if (s.portable)
                  _row('便携模式', '数据与内核都在应用目录（${s.dataDir.path}），不写系统位置、不使用 systemd',
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: amber.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(radius)),
                        child: Text('portable', style: mono.copyWith(fontSize: 11, color: amber)),
                      )),
                if (!File(s.resolveKernel()).existsSync())
                  _row(
                    '未找到内核',
                    '本机没有 mihomo。可以一键下载官方 release 到 ${s.dataDir.path}/bin（不会打进应用包）',
                    Btn(
                      label: '下载内核',
                      icon: Icons.download,
                      small: true,
                      color: amber,
                      loading: s.isPending('kernelinstall'),
                      onTap: () => s.runPending('kernelinstall', () => s.installKernel()),
                    ),
                  ),
                _row(
                  '内核更新',
                  s.latestKernelVersion == null
                      ? '当前 ${s.kernel.status.version ?? '?'} · 未检查'
                      : '当前 ${s.kernel.status.version ?? '?'} · 最新 ${s.latestKernelVersion}',
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Btn(
                      label: '检查',
                      small: true,
                      loading: s.isPending('check'),
                      onTap: () => s.runPending('check', () => s.checkKernelUpdate()),
                    ),
                    const SizedBox(width: 8),
                    Btn(
                      label: '升级',
                      small: true,
                      color: amber,
                      loading: s.isPending('upgrade'),
                      onTap: () => s.runPending('upgrade', () => s.upgradeKernel()),
                    ),
                  ]),
                ),
                _row('进程匹配', '连接页显示发起连接的进程；always 最准但略耗 CPU',
                    _dropdown(
                      value: _draft.findProcessMode,
                      items: const ['always', 'strict', 'off'],
                      onChanged: (v) => _update(_draft.copyWith(findProcessMode: v)),
                    )),
                _row('端口自动分配', '每次启动由系统分配空闲端口',
                    _toggle(_draft.autoPort, (v) => _update(_draft.copyWith(autoPort: v)))),
                _row('端口模式', '混合=一个端口同时支持 HTTP/SOCKS；分开=各自独立端口',
                    _dropdown(
                      value: _draft.portMode,
                      items: const ['mixed', 'split'],
                      onChanged: (v) => _update(_draft.copyWith(portMode: v)),
                    )),
                if (_draft.portMode == 'mixed')
                  _row('混合端口', _portHint('mixed'), _portControl('port', 'mixed'))
                else ...[
                  _row('HTTP 端口', _portHint('http'), _portControl('httpPort', 'http')),
                  _row('SOCKS 端口', _portHint('socks'), _portControl('socksPort', 'socks')),
                ],
                _row('允许局域网', 'bind 到 0.0.0.0，同网段设备可用这台机器做代理',
                    _toggle(_draft.allowLan, (v) => _update(_draft.copyWith(allowLan: v)))),
                _row('IPv6', '开启后 DNS 与出站会使用 IPv6',
                    _toggle(_draft.ipv6, (v) => _update(_draft.copyWith(ipv6: v)))),
                _row('日志等级', '',
                    _dropdown(
                      value: _draft.logLevel,
                      items: const ['silent', 'error', 'warning', 'info', 'debug'],
                      onChanged: (v) => _update(_draft.copyWith(logLevel: v)),
                    )),
                _row('统一延迟', 'unified-delay：消除不同协议握手差异导致的延迟偏差',
                    _toggle(_draft.unifiedDelay, (v) => _update(_draft.copyWith(unifiedDelay: v)))),
                _row('TCP 并发', 'tcp-concurrent：并发连接所有解析结果，取最先成功的',
                    _toggle(_draft.tcpConcurrent, (v) => _update(_draft.copyWith(tcpConcurrent: v)))),
                _row('geo 自动更新', '启动时更新 GeoIP/GeoSite（需要外网）',
                    _toggle(_draft.geoAutoUpdate, (v) => _update(_draft.copyWith(geoAutoUpdate: v)))),
              ]),
              _card('分流', [
                _row('路由模式', '国内直连=CN 流量不走代理；白名单=只代理境外；全部代理=一切走节点',
                    _dropdown(
                      value: _draft.rulesMode,
                      width: 150,
                      items: const ['cnDirect', 'whitelist', 'proxyAll', 'keep'],
                      onChanged: (v) => _update(_draft.copyWith(rulesMode: v)),
                    )),
                _row('精简分组', '删除没有任何规则引用的分组（机场常塞一堆「自动」副本）',
                    _toggle(_draft.pruneUnreferencedGroups,
                        (v) => _update(_draft.copyWith(pruneUnreferencedGroups: v)))),
              ]),
              _card('DNS', [
                _row('启用 DNS', '关闭后使用订阅里的 DNS 配置（如果有）',
                    _toggle(_draft.dnsEnabled, (v) => _update(_draft.copyWith(dnsEnabled: v)))),
                _row('模式', 'fake-ip 更快但部分程序会看到假 IP；redir-host 兼容性更好',
                    _dropdown(
                      value: _draft.dnsEnhancedMode,
                      items: const ['fake-ip', 'redir-host'],
                      onChanged: (v) => _update(_draft.copyWith(dnsEnhancedMode: v)),
                    )),
                _row('fake-ip 网段', '', _text('fakeIpRange', width: 180)),
                _row('nameserver', '每行一个；支持 DoH；SmartDNS 启用时此项被接管',
                    _multiline('nameservers')),
                _row('fallback', '每行一个；用于解析被污染的域名', _multiline('fallback', lines: 2)),
              ]),
              if (!Platform.isWindows) _card('SmartDNS（可选）', [
                _row('SmartDNS 二进制', _smartDnsHint(), _smartDnsPicker(context)),
                _row(
                  '启用 SmartDNS',
                  SmartDns.available
                      ? '外部 smartdns 进程做多上游测速 + 缓存，mihomo 只做 fake-ip 与分流'
                      : '未安装：sudo pacman -S smartdns（装好后重启 Aran 即可启用）',
                  _toggle(
                    _draft.dnsProvider == 'smartdns',
                    SmartDns.available
                        ? (v) => _update(_draft.copyWith(dnsProvider: v ? 'smartdns' : 'builtin'))
                        : null,
                  ),
                ),
                _row('上游服务器', '每行一个；支持 IP、IP:port、DoH URL',
                    _multiline('smartdnsUpstreams')),
                _row('缓存条数', '', _text('smartdnsCache', width: 110)),
                _row('测速选择', '按 ping / tcp:443 选最快的 IP',
                    _toggle(_draft.smartdnsSpeedCheck, (v) => _update(_draft.copyWith(smartdnsSpeedCheck: v)))),
                _row('仅 IPv4', '强制返回 A 记录（AAAA 返回 SOA）',
                    _toggle(_draft.smartdnsIpv4Only, (v) => _update(_draft.copyWith(smartdnsIpv4Only: v)))),
              ]),
              if (Platform.isWindows)
                _card('DNS', [
                  _row('DNS 提供方', 'smartdns 不支持 Windows（上游无 Windows 构建），使用 mihomo 内置 DNS',
                      Text('builtin', style: mono.copyWith(fontSize: 12, color: dim))),
                ]),
              _card('嗅探', [
                _row('启用嗅探', 'sniffer：从 TLS SNI / HTTP Host 还原域名，提高分流准确率',
                    _toggle(_draft.snifferEnabled, (v) => _update(_draft.copyWith(snifferEnabled: v)))),
              ]),
              _card('调度（Aran）', [
                _row('全局自动切换', '关闭=所有组只给建议；单个组可在代理页单独设置',
                    _toggle(s.takeover, (v) => s.setTakeover(v))),
                _row('切换阈值', '候选节点要比当前好这么多（%）才切', _text('threshold', width: 90)),
                _row('冷却（分钟）', '切换后这段时间内不再因「质量更好」而切换（判死不豁免）',
                    _text('cooldown', width: 90)),
              ]),
              _card('探测', [
                _row('探测 URL', '建议用 generate_204 或你自己的轻量端点', _text('testUrl', width: 380)),
                _row('探测超时', '毫秒', _text('testTimeout', width: 90)),
              ]),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  '数据目录：${s.dataDir.path}\n'
                  '运行时配置：${s.dataDir.path}/config.yaml　内核日志：kernel.log　审计：audit.jsonl',
                  style: mono.copyWith(fontSize: 11, color: dim, height: 1.7),
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: line, width: borderWidth))),
          child: Row(children: [
            Icon(_appliedAt == null ? Icons.info_outline : Icons.check_circle,
                size: 13, color: _appliedAt == null ? dim : green),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _appliedAt == null
                    ? '修改即时生效：开关/下拉立即应用，文本框停止输入后自动应用；内核走热重载，不重启进程'
                    : '已应用 · ${_appliedAt!.hour.toString().padLeft(2, '0')}:'
                        '${_appliedAt!.minute.toString().padLeft(2, '0')}:'
                        '${_appliedAt!.second.toString().padLeft(2, '0')}',
                style: mono.copyWith(fontSize: 11, color: _appliedAt == null ? dim : green),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Btn(label: '还原为已保存值', onTap: _resetFromSaved),
          ]),
        ),
      ],
    );
  }

  /// polkit 在某些会话里不可用（无 agent / 被策略拒绝），这时给出一条可直接粘贴的命令。
  Future<void> _showManualInstall(BuildContext context) async {
    final cmd = s.manualInstallCommand();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('手动安装 systemd 服务'),
        content: SizedBox(
          width: 640,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('在终端执行：', style: mono.copyWith(fontSize: 12, color: dim)),
            const SizedBox(height: 8),
            SelectableText(cmd, style: mono.copyWith(fontSize: 12, height: 1.6, color: text)),
            const SizedBox(height: 12),
            Text('安装后回到这里点「刷新状态」；卸载命令在 scripts/uninstall-service.sh。',
                style: mono.copyWith(fontSize: 11, color: dim)),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: cmd));
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('复制命令'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  Future<void> _showEnvDialog() async {
    final text = s.envScript();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          Text('代理环境变量 · ${s.settings.envShell}'),
          const Spacer(),
          Btn(label: '复制', icon: Icons.copy, small: true, onTap: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (ctx.mounted) Navigator.pop(ctx);
          }),
        ]),
        content: SizedBox(
          width: 620,
          child: SelectableText(text, style: mono.copyWith(fontSize: 12, height: 1.7)),
        ),
      ),
    );
  }

  void _resetFromSaved() {
    setState(() {
      _draft = s.settings;
      _ctrl['port']!.text = '${s.settings.mixedPort}';
      _ctrl['httpPort']!.text = '${s.settings.httpPort}';
      _ctrl['socksPort']!.text = '${s.settings.socksPort}';
      _ctrl['fakeIpRange']!.text = s.settings.fakeIpRange;
      _ctrl['nameservers']!.text = s.settings.nameservers.join('\n');
      _ctrl['fallback']!.text = s.settings.fallback.join('\n');
      _ctrl['smartdnsUpstreams']!.text = s.settings.smartdnsUpstreams.join('\n');
      _ctrl['smartdnsCache']!.text = '${s.settings.smartdnsCache}';
      _ctrl['threshold']!.text = ((s.settings.threshold - 1) * 100).round().toString();
      _ctrl['cooldown']!.text = '${s.settings.cooldownMinutes}';
      _ctrl['testUrl']!.text = s.settings.testUrl;
      _ctrl['testTimeout']!.text = '${s.settings.testTimeoutMs}';
    });
  }

  static String _scaleKey(double v) {
    var best = '标准';
    var bestDiff = 1e9;
    _scales.forEach((k, val) {
      final d = (val - v).abs();
      if (d < bestDiff) {
        bestDiff = d;
        best = k;
      }
    });
    return best;
  }

  String _kernelSourceDescribe() {
    if (!s.proxyRunning) return '内核未运行';
    if (s.systemdKernel) return 'systemd 托管（aran-kernel.service）';
    return 'Aran 直接拉起（子进程，关闭代理即停止）';
  }

  Widget _kernelSourceBadge() {
    final running = s.proxyRunning;
    final systemd = s.systemdKernel;
    final color = !running ? dim : systemd ? blue : green;
    final label = !running ? '未运行' : systemd ? 'systemd' : '直连内核';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(radius)),
      child: Text(label, style: mono.copyWith(fontSize: 11, color: color)),
    );
  }

  String _serviceDescribe() {
    final info = s.serviceInfo;
    if (info.isEmpty) return '切换为 service 模式后可查看 systemd 状态';
    if (info['installed'] == 'no') return '未安装 aran-kernel.service';
    final active = info['active'] ?? '?';
    final enabled = info['enabled'] ?? '?';
    final pid = info['pid'] ?? '';
    return 'active=$active · enabled=$enabled'
        '${pid.isNotEmpty && pid != '0' ? ' · pid=$pid' : ''}';
  }

  Widget _serviceBadge() {
    final info = s.serviceInfo;
    final installed = info['installed'] != 'no';
    final active = info['active'] == 'active';
    final color = !installed ? dim : active ? green : red;
    final label = !installed ? '未安装' : active ? '运行中' : '未运行';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(radius)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
        const SizedBox(width: 6),
        Text(label, style: mono.copyWith(fontSize: 11, color: color)),
      ]),
    );
  }

  String _portHint(String kind) {
    final active = s.kernel.activePorts[kind];
    if (_draft.autoPort) {
      return active == null ? '自动分配：启动后由系统分配空闲端口' : '本次随机分配：$active（重启代理会变）';
    }
    return '固定端口；改动会重启监听';
  }

  Widget _portControl(String key, String kind) {
    final active = s.kernel.activePorts[kind];
    if (_draft.autoPort) {
      return SizedBox(
        width: 110,
        child: Container(
          height: 34,
          alignment: Alignment.centerRight,
          child: Text(active == null ? 'auto' : '$active',
              style: mono.copyWith(fontSize: 13, color: active == null ? dim : green)),
        ),
      );
    }
    return _text(key, width: 110, onChanged: (_) => _update(_draft.copyWith(autoPort: false)));
  }

  Widget _kernelRow() {
    final found = s.discoverKernels();
    const auto = '自动探测';
    const custom = '自定义路径…';
    final raw = s.settings.kernelPath.trim();
    final current = raw.isEmpty ? auto : raw;
    final rawExists = raw.isNotEmpty && File(raw).existsSync();
    final invalidEntry = raw.isNotEmpty && !rawExists ? '$raw（文件不存在）' : null;
    final items = [
      auto,
      ...found,
      if (invalidEntry != null) invalidEntry,
      if (rawExists && !found.contains(raw)) raw,
      custom,
    ];
    final selected = items.contains(current) ? current : custom;

    return _row(
      '内核二进制',
      s.kernel.status.version == null
          ? '选择要运行的 mihomo 内核'
          : '当前运行：${s.kernel.status.version} · 来源 ${s.kernelSource}',
      Row(mainAxisSize: MainAxisSize.min, children: [
        Btn(
          label: '校验',
          small: true,
          onTap: () async {
            final path = selected == auto ? s.resolveKernel() : selected;
            final v = await s.probeKernelVersion(path);
            if (v == null) {
              s.setError('无法执行内核：$path');
            } else {
              s.setError(null);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('$path → $v'), duration: const Duration(seconds: 3)),
              );
            }
          },
        ),
        const SizedBox(width: 8),
        _dropdown(
          value: selected,
          width: 300,
          items: items,
          onChanged: (v) async {
            if (v == custom) {
              final ctrl = TextEditingController(text: s.settings.kernelPath);
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('指定内核路径'),
                  content: TextField(
                    controller: ctrl,
                    autofocus: true,
                    style: mono.copyWith(fontSize: 12),
                    decoration: const InputDecoration(
                      labelText: '可执行文件',
                      hintText: '/usr/bin/mihomo',
                    ),
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('使用')),
                  ],
                ),
              );
              if (ok == true) await s.saveSettings(s.settings.copyWith(kernelPath: ctrl.text.trim()));
              return;
            }
            await s.saveSettings(s.settings.copyWith(kernelPath: v == auto ? '' : v));
          },
        ),
      ]),
    );
  }

  static const _presets = <String, String>{
    '朱红': '#D0342C',
    '靛蓝': '#2A5CAA',
    '墨绿': '#1E6B3A',
    '琥珀': '#C07700',
    '紫罗兰': '#6C4AB6',
    '青': '#0E7490',
    '石墨': '#3F3F46',
  };

  Widget _accentPicker(BuildContext context) {
    final current = s.settings.accentColor.toUpperCase();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final e in _presets.entries)
          Tooltip(
            message: '${e.key} ${e.value}',
            child: InkWell(
              onTap: () => s.setAccentColor(e.value),
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: Color(int.parse('FF${e.value.substring(1)}', radix: 16)),
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(
                    color: current == e.value ? text : line,
                    width: current == e.value ? 2 : 1,
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(width: 4),
        Btn(
          label: '自定义',
          small: true,
          onTap: () async {
            final ctrl = TextEditingController(text: s.settings.accentColor);
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('自定义主题色'),
                content: TextField(
                  controller: ctrl,
                  autofocus: true,
                  style: mono.copyWith(fontSize: 12),
                  decoration: const InputDecoration(labelText: '十六进制颜色', hintText: '#D0342C'),
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                  FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('应用')),
                ],
              ),
            );
            if (ok == true) await s.setAccentColor(ctrl.text);
          },
        ),
        Btn(
          label: '默认',
          small: true,
          color: dim,
          onTap: () => s.setAccentColor(''),
        ),
      ],
    );
  }

  String _smartDnsHint() {
    final explicit = s.settings.smartDnsPath.trim();
    if (explicit.isEmpty) {
      final found = s.discoverSmartDns();
      return found.isEmpty ? '未检测到 smartdns（PATH 与数据目录都没有）' : '自动探测到 ${found.length} 个候选';
    }
    return File(explicit).existsSync() ? '使用指定路径' : '$explicit（文件不存在）';
  }

  Widget _smartDnsPicker(BuildContext context) {
    final found = s.discoverSmartDns();
    final explicit = s.settings.smartDnsPath.trim();
    final current = explicit.isEmpty
        ? '自动探测'
        : (File(explicit).existsSync() ? explicit : '$explicit（不存在）');
    final items = <String>[
      '自动探测',
      ...found,
      if (explicit.isNotEmpty && !found.contains(explicit)) '$explicit（不存在）',
      '自定义路径…',
    ];
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Btn(
        label: '校验',
        small: true,
        onTap: () async {
          final path = explicit.isEmpty ? (found.firstOrNull ?? '') : explicit;
          if (path.isEmpty) {
            s.setError('没有可校验的 smartdns');
            return;
          }
          final v = await s.probeSmartDns(path);
          s.setError(v == null ? '无法执行：$path' : null);
          if (v != null && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('$path → $v'), duration: const Duration(seconds: 3)),
            );
          }
        },
      ),
      const SizedBox(width: 8),
      _dropdown(
        value: items.contains(current) ? current : items.first,
        width: 320,
        items: items,
        onChanged: (v) async {
          if (v == '自定义路径…') {
            final ctrl = TextEditingController(text: s.settings.smartDnsPath);
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('指定 smartdns 路径'),
                content: TextField(
                  controller: ctrl,
                  autofocus: true,
                  style: mono.copyWith(fontSize: 12),
                  decoration: const InputDecoration(labelText: '可执行文件', hintText: '/usr/bin/smartdns'),
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                  FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('使用')),
                ],
              ),
            );
            if (ok == true) {
              await s.saveSettings(s.settings.copyWith(smartDnsPath: ctrl.text.trim()));
            }
            return;
          }
          await s.saveSettings(
              s.settings.copyWith(smartDnsPath: v == '自动探测' ? '' : v.replaceAll('（不存在）', '')));
        },
      ),
    ]);
  }

  /// One button whose meaning follows the state: install → start → stop.
  Widget _servicePrimaryButton() {
    if (!s.supportsSystemService) return Btn(label: '不支持服务', small: true, onTap: null);
    final info = s.serviceInfo;
    final installed = info['installed'] == 'yes';
    final active = info['active'] == 'active';
    if (!installed) {
      return Btn(
        label: '安装',
        small: true,
        filled: true,
        loading: s.isPending('svcinstall'),
        onTap: () => s.runPending('svcinstall', () => s.installService()),
      );
    }
    return Btn(
      label: active ? '停止' : '启动',
      small: true,
      filled: true,
      color: active ? red : green,
      loading: s.isPending(active ? 'svcstop' : 'svcstart'),
      onTap: active
          ? () => s.runPending('svcstop', () => s.stopService())
          : () => s.startServiceNow(),
    );
  }

  Widget _serviceMenu(BuildContext context) {
    final installed = s.serviceInfo['installed'] == 'yes';
    return PopupMenuButton<String>(
      tooltip: '更多服务操作',
      color: panel,
      position: PopupMenuPosition.under,
      icon: Icon(Icons.more_horiz, size: 18, color: dim),
      onSelected: (v) {
        switch (v) {
          case 'restart':
            s.runPending('svcrestart', () async {
              await s.restartKernel();
              s.pokeServiceStatus();
            });
          case 'logs':
            _showServiceLogs(context);
          case 'manual':
            _showManualInstall(context);
          case 'remove':
            s.removeService();
        }
      },
      itemBuilder: (context) => [
        _svcItem('restart', '重启内核', Icons.refresh, enabled: installed),
        _svcItem('logs', '查看服务日志', Icons.article_outlined),
        _svcItem('manual', '手动命令', Icons.terminal),
        const PopupMenuDivider(),
        _svcItem('remove', '卸载服务', Icons.delete_outline, color: red, enabled: installed),
      ],
    );
  }

  PopupMenuItem<String> _svcItem(String value, String label, IconData icon,
      {Color? color, bool enabled = true}) {
    final c = enabled ? (color ?? text) : dim;
    return PopupMenuItem(
      value: value,
      height: 38,
      enabled: enabled,
      child: Row(children: [
        Icon(icon, size: 15, color: c),
        const SizedBox(width: 10),
        Text(label, style: mono.copyWith(fontSize: 12, color: c)),
      ]),
    );
  }

  Future<void> _showServiceLogs(BuildContext context) async {
    final logs = await s.loadServiceLogs();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('服务日志'),
        content: SizedBox(
          width: 900,
          height: 460,
          child: SingleChildScrollView(
            child: SelectableText(logs, style: mono.copyWith(fontSize: 11.5, height: 1.5)),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭'))],
      ),
    );
  }

  Widget _card(String title, List<Widget> rows) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          color: panel,
          border: constructivist
              ? Border(top: BorderSide(color: lineStrong, width: 1))
              : Border.all(color: line, width: borderWidth),
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
              child: Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: text)),
            ),
            for (final r in rows) r,
            const SizedBox(height: 8),
          ],
        ),
      );

  Widget _row(String label, String hint, Widget trailing, {bool disabled = false}) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 150,
              child: Text(label, style: TextStyle(fontSize: 13, color: disabled ? dim : text)),
            ),
            Expanded(
              child: hint.isEmpty
                  ? const SizedBox.shrink()
                  : Text(hint, style: mono.copyWith(fontSize: 11, color: dim, height: 1.4)),
            ),
            const SizedBox(width: 12),
            trailing,
          ],
        ),
      );

  Widget _toggle(bool value, ValueChanged<bool>? onChanged) => Transform.scale(
        scale: 0.75,
        child: Switch(value: value, onChanged: onChanged, activeThumbColor: blue),
      );

  Widget _text(String key, {double width = 200, bool enabled = true, ValueChanged<String>? onChanged}) => SizedBox(
        width: width,
        child: TextField(
          controller: _ctrl[key],
          enabled: enabled,
          onChanged: onChanged,
          style: mono.copyWith(fontSize: 12),
          decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
        ),
      );

  Widget _multiline(String key, {int lines = 3}) => SizedBox(
        width: 420,
        child: TextField(
          controller: _ctrl[key],
          maxLines: lines,
          style: mono.copyWith(fontSize: 12),
          decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
        ),
      );

  Widget _dropdown({
    required String value,
    required List<String> items,
    required ValueChanged<String> onChanged,
    double width = 130,
  }) {
    final safe = items.contains(value) ? value : items.first;
    return SizedBox(
      width: width,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(border: Border.all(color: line, width: borderWidth), borderRadius: BorderRadius.circular(radius)),
        child: DropdownButton<String>(
          value: safe,
          isExpanded: true,
          isDense: true,
          dropdownColor: panel,
          underline: const SizedBox.shrink(),
          style: mono.copyWith(fontSize: 12, color: text),
          items: [for (final i in items) DropdownMenuItem(value: i, child: Text(i))],
          onChanged: (v) => v == null ? null : onChanged(v),
        ),
      ),
    );
  }
}
