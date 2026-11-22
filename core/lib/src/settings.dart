import 'dart:convert';

import 'config_transform.dart';

/// Everything the user can tune. Two groups:
///   * kernel options → baked into the generated mihomo config
///   * scheduler options → used by Aran's own decision loop
class AranSettings {
  // ---- kernel ----
  final bool autoPort;

  /// mixed = one mixed-port; split = separate HTTP (port) + SOCKS (socks-port)
  final String portMode;
  final int mixedPort;
  final int httpPort;
  final int socksPort;
  final bool allowLan;
  final bool ipv6;
  final String logLevel;
  final bool geoAutoUpdate;
  final bool unifiedDelay;
  final bool tcpConcurrent;
  final bool snifferEnabled;
  final bool tunEnabled; // requires the privileged helper; UI marks it as pending

  // ---- dns ----
  final bool dnsEnabled;
  final String dnsEnhancedMode; // fake-ip | redir-host
  final String fakeIpRange;
  final List<String> nameservers;
  final List<String> fallback;

  // ---- scheduler ----
  final bool takeover;
  final double threshold;
  final int cooldownMinutes;
  final String testUrl;
  final int testTimeoutMs;

  /// system | light | dark
  final String themeMode;

  /// modern | constructivist
  final String themeStyle;

  /// Accent colour as #RRGGBB; empty = follow the style's own accent.
  final String accentColor;

  /// Global text scale; the UI was designed at 11-13px which is too small for
  /// most people at 100%.
  final double uiScale;

  /// Collapsed (icon-only) navigation rail.
  final bool compactRail;

  /// Explicit mihomo binary. Empty = auto-detect.
  final String kernelPath;

  /// builtin (mihomo's own DNS) | smartdns (external sidecar)
  final String dnsProvider;
  /// Explicit smartdns binary; empty = auto-detect (PATH / data dir / embedded).
  final String smartDnsPath;
  final List<String> smartdnsUpstreams;
  final int smartdnsCache;
  final bool smartdnsSpeedCheck;
  final bool smartdnsIpv4Only;

  /// keep (订阅原样) | cnDirect (国内直连) | proxyAll (全代理) | whitelist (只代理非国内)
  final String rulesMode;

  /// off | strict | always — controls whether connections report a process.
  final String findProcessMode;

  /// Which proxy group Aran drives. Empty = auto (largest group).
  final String takeoverGroup;

  /// Delete groups no rule references.
  final bool pruneUnreferencedGroups;

  /// Start Aran (and the proxy) when the session logs in.
  final bool autoStart;

  /// Keep running in the system tray instead of quitting on window close.
  final bool trayEnabled;

  /// Target shell for the copied proxy environment snippet.
  final String envShell;

  /// Start with the window hidden in the tray (proxy still comes up).
  final bool startMinimized;

  /// Point the desktop's system proxy at our mixed port (KDE / GNOME).
  final bool systemProxy;

  /// Desktop notifications (node switches, quota, failures).
  final bool notifyEnabled;

  /// Hand groups back to a kernel url-test group if Aran stops responding.
  final bool watchdogEnabled;

  /// managed = the GUI spawns mihomo; service = systemd runs it (GUI is a client)
  final String runMode;

  /// Fixed endpoints used in service mode (the unit cannot ask us for ports).
  final int servicePort;
  final int serviceControllerPort;
  final String serviceSecret;

  /// Per-group region preference, e.g. {'TikTok': '新加坡'}. Empty = any node.
  final Map<String, String> groupPrefs;

  /// Per-group control mode: auto | suggest | off. Missing = follow the global
  /// "自动切换" switch.
  final Map<String, String> groupModes;

  const AranSettings({
    this.autoPort = true,
    this.portMode = 'mixed',
    this.mixedPort = 7890,
    this.httpPort = 7891,
    this.socksPort = 7892,
    this.allowLan = false,
    this.ipv6 = false,
    this.logLevel = 'info',
    this.geoAutoUpdate = false,
    this.unifiedDelay = true,
    this.tcpConcurrent = true,
    this.snifferEnabled = true,
    this.tunEnabled = false,
    this.dnsEnabled = true,
    this.dnsEnhancedMode = 'fake-ip',
    this.fakeIpRange = '198.18.0.1/16',
    this.nameservers = const ['223.5.5.5', '119.29.29.29'],
    this.fallback = const [],
    this.takeover = false,
    this.threshold = 1.30,
    this.cooldownMinutes = 5,
    this.testUrl = 'https://cp.cloudflare.com/generate_204',
    this.testTimeoutMs = 5000,
    this.themeMode = 'dark',
    this.themeStyle = 'modern',
    this.accentColor = '',
    this.uiScale = 1.15,
    this.compactRail = false,
    this.kernelPath = '',
    this.dnsProvider = 'builtin',
    this.smartDnsPath = '',
    this.smartdnsUpstreams = const ['223.5.5.5', '119.29.29.29', 'https://doh.pub/dns-query'],
    this.smartdnsCache = 4096,
    this.smartdnsSpeedCheck = true,
    this.smartdnsIpv4Only = false,
    this.rulesMode = 'cnDirect',
    this.findProcessMode = 'always',
    this.takeoverGroup = '',
    this.pruneUnreferencedGroups = true,
    this.autoStart = false,
    this.trayEnabled = true,
    this.envShell = 'bash',
    this.startMinimized = true,
    this.systemProxy = false,
    this.notifyEnabled = true,
    this.watchdogEnabled = true,
    this.runMode = 'managed',
    this.servicePort = 7890,
    this.serviceControllerPort = 9091,
    this.serviceSecret = 'aran-service',
    this.groupPrefs = const {},
    this.groupModes = const {},
  });

  AranSettings copyWith({
    bool? autoPort,
    String? portMode,
    int? mixedPort,
    int? httpPort,
    int? socksPort,
    bool? allowLan,
    bool? ipv6,
    String? logLevel,
    bool? geoAutoUpdate,
    bool? unifiedDelay,
    bool? tcpConcurrent,
    bool? snifferEnabled,
    bool? tunEnabled,
    bool? dnsEnabled,
    String? dnsEnhancedMode,
    String? fakeIpRange,
    List<String>? nameservers,
    List<String>? fallback,
    bool? takeover,
    double? threshold,
    int? cooldownMinutes,
    String? testUrl,
    int? testTimeoutMs,
    String? themeMode,
    String? themeStyle,
    String? accentColor,
    double? uiScale,
    bool? compactRail,
    String? kernelPath,
    String? dnsProvider,
    String? smartDnsPath,
    List<String>? smartdnsUpstreams,
    int? smartdnsCache,
    bool? smartdnsSpeedCheck,
    bool? smartdnsIpv4Only,
    String? rulesMode,
    String? findProcessMode,
    String? takeoverGroup,
    bool? pruneUnreferencedGroups,
    bool? autoStart,
    bool? trayEnabled,
    String? envShell,
    bool? startMinimized,
    bool? systemProxy,
    bool? notifyEnabled,
    bool? watchdogEnabled,
    String? runMode,
    int? servicePort,
    int? serviceControllerPort,
    String? serviceSecret,
    Map<String, String>? groupPrefs,
    Map<String, String>? groupModes,
  }) =>
      AranSettings(
        autoPort: autoPort ?? this.autoPort,
        portMode: portMode ?? this.portMode,
        mixedPort: mixedPort ?? this.mixedPort,
        httpPort: httpPort ?? this.httpPort,
        socksPort: socksPort ?? this.socksPort,
        allowLan: allowLan ?? this.allowLan,
        ipv6: ipv6 ?? this.ipv6,
        logLevel: logLevel ?? this.logLevel,
        geoAutoUpdate: geoAutoUpdate ?? this.geoAutoUpdate,
        unifiedDelay: unifiedDelay ?? this.unifiedDelay,
        tcpConcurrent: tcpConcurrent ?? this.tcpConcurrent,
        snifferEnabled: snifferEnabled ?? this.snifferEnabled,
        tunEnabled: tunEnabled ?? this.tunEnabled,
        dnsEnabled: dnsEnabled ?? this.dnsEnabled,
        dnsEnhancedMode: dnsEnhancedMode ?? this.dnsEnhancedMode,
        fakeIpRange: fakeIpRange ?? this.fakeIpRange,
        nameservers: nameservers ?? this.nameservers,
        fallback: fallback ?? this.fallback,
        takeover: takeover ?? this.takeover,
        threshold: threshold ?? this.threshold,
        cooldownMinutes: cooldownMinutes ?? this.cooldownMinutes,
        testUrl: testUrl ?? this.testUrl,
        testTimeoutMs: testTimeoutMs ?? this.testTimeoutMs,
        themeMode: themeMode ?? this.themeMode,
        themeStyle: themeStyle ?? this.themeStyle,
        accentColor: accentColor ?? this.accentColor,
        uiScale: uiScale ?? this.uiScale,
        compactRail: compactRail ?? this.compactRail,
        kernelPath: kernelPath ?? this.kernelPath,
        dnsProvider: dnsProvider ?? this.dnsProvider,
        smartDnsPath: smartDnsPath ?? this.smartDnsPath,
        smartdnsUpstreams: smartdnsUpstreams ?? this.smartdnsUpstreams,
        smartdnsCache: smartdnsCache ?? this.smartdnsCache,
        smartdnsSpeedCheck: smartdnsSpeedCheck ?? this.smartdnsSpeedCheck,
        smartdnsIpv4Only: smartdnsIpv4Only ?? this.smartdnsIpv4Only,
        rulesMode: rulesMode ?? this.rulesMode,
        findProcessMode: findProcessMode ?? this.findProcessMode,
        takeoverGroup: takeoverGroup ?? this.takeoverGroup,
        pruneUnreferencedGroups: pruneUnreferencedGroups ?? this.pruneUnreferencedGroups,
        autoStart: autoStart ?? this.autoStart,
        trayEnabled: trayEnabled ?? this.trayEnabled,
        envShell: envShell ?? this.envShell,
        startMinimized: startMinimized ?? this.startMinimized,
        systemProxy: systemProxy ?? this.systemProxy,
        notifyEnabled: notifyEnabled ?? this.notifyEnabled,
        watchdogEnabled: watchdogEnabled ?? this.watchdogEnabled,
        runMode: runMode ?? this.runMode,
        servicePort: servicePort ?? this.servicePort,
        serviceControllerPort: serviceControllerPort ?? this.serviceControllerPort,
        serviceSecret: serviceSecret ?? this.serviceSecret,
        groupPrefs: groupPrefs ?? this.groupPrefs,
        groupModes: groupModes ?? this.groupModes,
      );

  Map<String, dynamic> toJson() => {
        'autoPort': autoPort,
        'portMode': portMode,
        'mixedPort': mixedPort,
        'httpPort': httpPort,
        'socksPort': socksPort,
        'allowLan': allowLan,
        'ipv6': ipv6,
        'logLevel': logLevel,
        'geoAutoUpdate': geoAutoUpdate,
        'unifiedDelay': unifiedDelay,
        'tcpConcurrent': tcpConcurrent,
        'snifferEnabled': snifferEnabled,
        'tunEnabled': tunEnabled,
        'dnsEnabled': dnsEnabled,
        'dnsEnhancedMode': dnsEnhancedMode,
        'fakeIpRange': fakeIpRange,
        'nameservers': nameservers,
        'fallback': fallback,
        'takeover': takeover,
        'threshold': threshold,
        'cooldownMinutes': cooldownMinutes,
        'testUrl': testUrl,
        'testTimeoutMs': testTimeoutMs,
        'themeMode': themeMode,
        'themeStyle': themeStyle,
        'accentColor': accentColor,
        'uiScale': uiScale,
        'compactRail': compactRail,
        'kernelPath': kernelPath,
        'dnsProvider': dnsProvider,
        'smartDnsPath': smartDnsPath,
        'smartdnsUpstreams': smartdnsUpstreams,
        'smartdnsCache': smartdnsCache,
        'smartdnsSpeedCheck': smartdnsSpeedCheck,
        'smartdnsIpv4Only': smartdnsIpv4Only,
        'rulesMode': rulesMode,
        'findProcessMode': findProcessMode,
        'takeoverGroup': takeoverGroup,
        'pruneUnreferencedGroups': pruneUnreferencedGroups,
        'autoStart': autoStart,
        'trayEnabled': trayEnabled,
        'envShell': envShell,
        'startMinimized': startMinimized,
        'systemProxy': systemProxy,
        'notifyEnabled': notifyEnabled,
        'watchdogEnabled': watchdogEnabled,
        'runMode': runMode,
        'servicePort': servicePort,
        'serviceControllerPort': serviceControllerPort,
        'serviceSecret': serviceSecret,
        'groupPrefs': groupPrefs,
        'groupModes': groupModes,
      };

  factory AranSettings.fromJson(Map<String, dynamic> j) {
    List<String> list(Object? v, List<String> d) =>
        v is List ? v.map((e) => '$e').toList() : d;
    return AranSettings(
      autoPort: j['autoPort'] as bool? ?? true,
      portMode: j['portMode'] as String? ?? 'mixed',
      mixedPort: (j['mixedPort'] as num?)?.toInt() ?? 7890,
      httpPort: (j['httpPort'] as num?)?.toInt() ?? 7891,
      socksPort: (j['socksPort'] as num?)?.toInt() ?? 7892,
      allowLan: j['allowLan'] as bool? ?? false,
      ipv6: j['ipv6'] as bool? ?? false,
      logLevel: j['logLevel'] as String? ?? 'info',
      geoAutoUpdate: j['geoAutoUpdate'] as bool? ?? false,
      unifiedDelay: j['unifiedDelay'] as bool? ?? true,
      tcpConcurrent: j['tcpConcurrent'] as bool? ?? true,
      snifferEnabled: j['snifferEnabled'] as bool? ?? true,
      tunEnabled: j['tunEnabled'] as bool? ?? false,
      dnsEnabled: j['dnsEnabled'] as bool? ?? true,
      dnsEnhancedMode: j['dnsEnhancedMode'] as String? ?? 'fake-ip',
      fakeIpRange: j['fakeIpRange'] as String? ?? '198.18.0.1/16',
      nameservers: list(j['nameservers'], const ['223.5.5.5', '119.29.29.29']),
      fallback: list(j['fallback'], const []),
      takeover: j['takeover'] as bool? ?? false,
      threshold: (j['threshold'] as num?)?.toDouble() ?? 1.30,
      cooldownMinutes: (j['cooldownMinutes'] as num?)?.toInt() ?? 5,
      testUrl: j['testUrl'] as String? ?? 'https://cp.cloudflare.com/generate_204',
      testTimeoutMs: (j['testTimeoutMs'] as num?)?.toInt() ?? 5000,
      themeMode: j['themeMode'] as String? ?? 'dark',
      themeStyle: j['themeStyle'] as String? ?? 'modern',
      accentColor: j['accentColor'] as String? ?? '',
      uiScale: (j['uiScale'] as num?)?.toDouble() ?? 1.15,
      compactRail: j['compactRail'] as bool? ?? false,
      kernelPath: j['kernelPath'] as String? ?? '',
      dnsProvider: j['dnsProvider'] as String? ?? 'builtin',
      smartDnsPath: j['smartDnsPath'] as String? ?? '',
      smartdnsUpstreams: list(j['smartdnsUpstreams'], const ['223.5.5.5', '119.29.29.29']),
      smartdnsCache: (j['smartdnsCache'] as num?)?.toInt() ?? 4096,
      smartdnsSpeedCheck: j['smartdnsSpeedCheck'] as bool? ?? true,
      smartdnsIpv4Only: j['smartdnsIpv4Only'] as bool? ?? false,
      rulesMode: j['rulesMode'] as String? ?? 'cnDirect',
      findProcessMode: j['findProcessMode'] as String? ?? 'always',
      takeoverGroup: j['takeoverGroup'] as String? ?? '',
      pruneUnreferencedGroups: j['pruneUnreferencedGroups'] as bool? ?? true,
      autoStart: j['autoStart'] as bool? ?? false,
      trayEnabled: j['trayEnabled'] as bool? ?? true,
      envShell: j['envShell'] as String? ?? 'bash',
      startMinimized: j['startMinimized'] as bool? ?? true,
      systemProxy: j['systemProxy'] as bool? ?? false,
      notifyEnabled: j['notifyEnabled'] as bool? ?? true,
      watchdogEnabled: j['watchdogEnabled'] as bool? ?? true,
      runMode: j['runMode'] as String? ?? 'managed',
      servicePort: (j['servicePort'] as num?)?.toInt() ?? 7890,
      serviceControllerPort: (j['serviceControllerPort'] as num?)?.toInt() ?? 9091,
      serviceSecret: j['serviceSecret'] as String? ?? 'aran-service',
      groupPrefs: (j['groupPrefs'] as Map?)?.map((k, v) => MapEntry('$k', '$v')) ?? const {},
      groupModes: (j['groupModes'] as Map?)?.map((k, v) => MapEntry('$k', '$v')) ?? const {},
    );
  }

  static AranSettings? tryParse(String text) {
    try {
      final j = jsonDecode(text);
      return j is Map<String, dynamic> ? AranSettings.fromJson(j) : null;
    } catch (_) {
      return null;
    }
  }

  /// Scalar top-level keys written into the runtime config.
  Map<String, String> scalarOverrides({
    required int? controllerPort,
    required String secret,
    int? mixedPort,
    int? httpPort,
    int? socksPort,
  }) =>
      {
        if (mixedPort != null) 'mixed-port': '$mixedPort',
        if (httpPort != null) 'port': '$httpPort',
        if (socksPort != null) 'socks-port': '$socksPort',
        'allow-lan': '$allowLan',
        'ipv6': '$ipv6',
        'log-level': logLevel,
        'unified-delay': '$unifiedDelay',
        'tcp-concurrent': '$tcpConcurrent',
        'geo-auto-update': '$geoAutoUpdate',
        'find-process-mode': findProcessMode,
        'external-controller': '127.0.0.1:${controllerPort ?? 9090}',
        'secret': secret,
      };

  /// Merge patch for `dns:` — deliberately *not* a full replacement, so the
  /// subscription's own `nameserver-policy` / `fake-ip-filter` / `respect-rules`
  /// keep working.
  SectionPatch dnsPatch({String? smartdnsAddress}) {
    if (!dnsEnabled) return const SectionPatch(scalars: {'enable': 'false'});

    final useSmartdns = dnsProvider == 'smartdns' && smartdnsAddress != null;
    return SectionPatch(
      scalars: {
        'enable': 'true',
        'ipv6': '$ipv6',
        'enhanced-mode': dnsEnhancedMode,
        if (dnsEnhancedMode == 'fake-ip') 'fake-ip-range': fakeIpRange,
        // Resolve proxy-server domains with plain DNS: pointing these at DoH or
        // at smartdns means one broken resolver takes every node down with it.
        'proxy-server-nameserver': '[223.5.5.5, 119.29.29.29]',
      },
      lists: {
        'default-nameserver': const ['223.5.5.5', '119.29.29.29'],
        if (useSmartdns)
          'nameserver': [smartdnsAddress]
        else
          'nameserver': nameservers,
      },
    );
  }

  /// TUN needs CAP_NET_ADMIN (see scripts/install-tun-cap.sh). Only emitted when
  /// the user actually enabled it — a stale block would break startup.
  String tunBlock() {
    if (!tunEnabled) return '';
    return [
      'tun:',
      '  enable: true',
      '  stack: gvisor',
      '  device: aran0',
      '  auto-route: true',
      '  auto-detect-interface: true',
      '  dns-hijack:',
      '    - any:53',
      '  strict-route: false',
      '  mtu: 9000',
    ].join('\n');
  }

  /// Only flips `enable`; every other sniffer key (skip-domain, sniff ports…)
  /// is left to the subscription.
  SectionPatch snifferPatch() => SectionPatch(scalars: {'enable': '$snifferEnabled'});

}
