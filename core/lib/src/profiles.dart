import 'dart:convert';
import 'dart:io';

import 'config_transform.dart';

class Profile {
  final String id;
  final String name;
  final String? url;
  final DateTime updatedAt;
  final int bytes;
  final bool active;

  /// Directory the config came from; used to find geo assets next to it.
  final String? homeDir;

  /// Per-subscription auto-update interval in hours; null = use the app default.
  final int? autoUpdateHours;

  /// Subscription quota, in bytes. Null = unknown.
  final int? trafficUsed;
  final int? trafficTotal;
  final DateTime? expireAt;

  /// When the panel only prints "剩余流量：xx GB" we cannot derive used/total,
  /// but we can still show what the user asked for: what is left.
  final int? trafficLeftNotice;

  const Profile({
    required this.id,
    required this.name,
    required this.url,
    required this.updatedAt,
    required this.bytes,
    required this.active,
    this.homeDir,
    this.trafficUsed,
    this.trafficTotal,
    this.expireAt,
    this.trafficLeftNotice,
    this.autoUpdateHours,
  });

  int? get trafficLeft =>
      (trafficTotal != null && trafficUsed != null)
          ? (trafficTotal! - trafficUsed!).clamp(0, trafficTotal!)
          : trafficLeftNotice;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'updatedAt': updatedAt.toIso8601String(),
        'bytes': bytes,
        'active': active,
        'homeDir': homeDir,
        'trafficUsed': trafficUsed,
        'trafficTotal': trafficTotal,
        'trafficLeftNotice': trafficLeftNotice,
        'expireAt': expireAt?.toIso8601String(),
        'autoUpdateHours': autoUpdateHours,
      };

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        id: j['id'] as String,
        name: j['name'] as String,
        url: j['url'] as String?,
        updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? '') ?? DateTime(1970),
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        active: j['active'] as bool? ?? false,
        homeDir: j['homeDir'] as String?,
        trafficUsed: (j['trafficUsed'] as num?)?.toInt(),
        trafficTotal: (j['trafficTotal'] as num?)?.toInt(),
        trafficLeftNotice: (j['trafficLeftNotice'] as num?)?.toInt(),
        expireAt: DateTime.tryParse(j['expireAt'] as String? ?? ''),
      );

  Profile copyWith({
    String? name,
    DateTime? updatedAt,
    int? bytes,
    bool? active,
    String? url,
    int? trafficUsed,
    int? trafficTotal,
    DateTime? expireAt,
    int? trafficLeftNotice,
    int? autoUpdateHours,
  }) =>
      Profile(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        updatedAt: updatedAt ?? this.updatedAt,
        bytes: bytes ?? this.bytes,
        active: active ?? this.active,
        homeDir: homeDir,
        // Must fall back to the current values: _save() calls copyWith(active: …)
        // and would otherwise wipe the quota info on every write.
        trafficUsed: trafficUsed ?? this.trafficUsed,
        trafficTotal: trafficTotal ?? this.trafficTotal,
        expireAt: expireAt ?? this.expireAt,
        trafficLeftNotice: trafficLeftNotice ?? this.trafficLeftNotice,
        autoUpdateHours: autoUpdateHours ?? this.autoUpdateHours,
      );
}

/// Profiles = subscription configs Aran can run. This is the part that makes
/// Aran a client rather than a dashboard: it fetches, stores, updates and
/// activates the actual mihomo config.
class ProfileStore {
  final Directory dataDir;
  final List<Profile> _profiles = [];
  String? _activeId;

  ProfileStore(this.dataDir);

  List<Profile> get profiles => List.unmodifiable(_profiles);
  String? get activeId => _activeId;
  Profile? get active => _profiles.where((p) => p.id == _activeId).firstOrNull;

  File get _index => File('${dataDir.path}/profiles/index.json');
  File configFile(String id) => File('${dataDir.path}/profiles/$id/config.yaml');

  Future<void> load() async {
    await Directory('${dataDir.path}/profiles').create(recursive: true);
    _profiles.clear();
    if (await _index.exists()) {
      try {
        final json = jsonDecode(await _index.readAsString()) as Map<String, dynamic>;
        for (final raw in (json['profiles'] as List? ?? const [])) {
          final p = Profile.fromJson(raw as Map<String, dynamic>);
          if (await configFile(p.id).exists()) _profiles.add(p);
        }
        _activeId = json['active'] as String?;
      } catch (_) {
        // corrupted index: start clean rather than crash
      }
    }
    // Self-heal quota info: panels put it either in the response header (already
    // stored) or in "剩余流量：xx GB" notice nodes. Older entries may have lost it.
    var healed = false;
    for (var i = 0; i < _profiles.length; i++) {
      final p = _profiles[i];
      if (p.trafficUsed != null || p.trafficLeftNotice != null) continue;
      final f = configFile(p.id);
      if (!await f.exists()) continue;
      final text = await f.readAsString();
      final left = _noticeBytes(text, '剩余流量');
      final used = _noticeBytes(text, '已用流量');
      final total = _noticeBytes(text, '总流量');
      final expire = _noticeExpire(text);
      if (left == null && used == null && total == null && expire == null) continue;
      _profiles[i] = p.copyWith(
        trafficUsed: used,
        trafficTotal: total,
        trafficLeftNotice: left,
        expireAt: expire,
      );
      healed = true;
    }
    if (healed) await _save();

    _profiles.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Future<void> _save() async {
    await Directory('${dataDir.path}/profiles').create(recursive: true);
    await _index.writeAsString(jsonEncode({
      'active': _activeId,
      'profiles': [
        for (final p in _profiles) p.copyWith(active: p.id == _activeId).toJson(),
      ],
    }));
  }

  String _newId() => 'p${DateTime.now().millisecondsSinceEpoch}';

  String? get activeConfigText {
    final a = active;
    if (a == null) return null;
    final f = configFile(a.id);
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  Future<Profile> addFromUrl(String url, {String? name, String? proxyAddress}) async {
    final res = await _download(url, proxyAddress: proxyAddress);
    final text = res.text;
    final id = _newId();
    await configFile(id).parent.create(recursive: true);
    await configFile(id).writeAsString(text);
    final p = Profile(
      id: id,
      name: name?.isNotEmpty == true ? name! : _guessName(url),
      url: url,
      updatedAt: DateTime.now(),
      bytes: text.length,
      active: false,
      trafficUsed: res.used,
      trafficTotal: res.total,
      expireAt: res.expire,
      trafficLeftNotice: res.used == null && res.total == null ? _noticeBytes(text, '剩余流量') : null,
    );
    _profiles.add(p);
    if (_activeId == null || !_profiles.any((x) => x.id == _activeId)) _activeId = id;
    await _save();
    return p;
  }

  /// Import from text we already have in memory: a file the user picked through
  /// SAF (no filesystem path on Android) or a QR code that contained the config
  /// itself. Accepts a base64 blob, same as [addFromFile]'s downloaded siblings.
  Future<Profile> addFromText(String raw, {String? name}) async {
    var text = raw;
    if (!ConfigTransform.looksLikeMihomoConfig(text)) {
      try {
        final decoded = utf8.decode(base64.decode(text.replaceAll(RegExp(r'\s'), '')), allowMalformed: true);
        if (ConfigTransform.looksLikeMihomoConfig(decoded)) text = decoded;
      } catch (_) {}
    }
    if (!ConfigTransform.looksLikeMihomoConfig(text)) {
      throw const FormatException('这段内容看起来不是 mihomo/clash 配置（找不到 proxies / proxy-groups）');
    }
    final id = _newId();
    await configFile(id).parent.create(recursive: true);
    await configFile(id).writeAsString(text);
    final p = Profile(
      id: id,
      name: name?.isNotEmpty == true ? name! : '导入的配置',
      url: null,
      updatedAt: DateTime.now(),
      bytes: text.length,
      active: false,
      trafficUsed: _noticeBytes(text, '已用流量'),
      trafficTotal: _noticeBytes(text, '总流量'),
      trafficLeftNotice: _noticeBytes(text, '剩余流量'),
    );
    _profiles.add(p);
    if (_activeId == null || !_profiles.any((x) => x.id == _activeId)) _activeId = id;
    await _save();
    return p;
  }

  Future<Profile> addFromFile(String path, {String? name}) async {
    final text = await File(path).readAsString();
    if (!ConfigTransform.looksLikeMihomoConfig(text)) {
      throw const FormatException('这个文件看起来不是 mihomo/clash 配置（找不到 proxies / proxy-groups）');
    }
    final id = _newId();
    await configFile(id).parent.create(recursive: true);
    await configFile(id).writeAsString(text);
    final p = Profile(
      id: id,
      name: name ?? path.split('/').last,
      url: null,
      updatedAt: DateTime.now(),
      bytes: text.length,
      active: false,
      homeDir: File(path).parent.path,
      // Local files carry no `subscription-userinfo` header, so fall back to the
      // notice entries airports inject into the config.
      trafficUsed: _noticeBytes(text, '已用流量'),
      trafficTotal: _noticeBytes(text, '总流量'),
      trafficLeftNotice: _noticeBytes(text, '剩余流量'),
      expireAt: _noticeExpire(text),
    );
    _profiles.add(p);
    if (_activeId == null || !_profiles.any((x) => x.id == _activeId)) _activeId = id;
    await _save();
    return p;
  }

  Future<Profile> update(String id, {String? proxyAddress}) async {
    final i = _profiles.indexWhere((p) => p.id == id);
    if (i < 0) throw StateError('profile $id not found');
    final p = _profiles[i];
    if (p.url == null) return p;
    final res = await _download(p.url!, proxyAddress: proxyAddress);
    final text = res.text;
    await snapshot(id);
    await configFile(id).writeAsString(text);
    final updated = p.copyWith(
      updatedAt: DateTime.now(),
      bytes: text.length,
      trafficUsed: res.used,
      trafficTotal: res.total,
      expireAt: res.expire,
      trafficLeftNotice: res.used == null && res.total == null ? _noticeBytes(text, '剩余流量') : null,
    );
    _profiles[i] = updated;
    await _save();
    return updated;
  }

  Future<void> remove(String id) async {
    _profiles.removeWhere((p) => p.id == id);
    if (_activeId == id) _activeId = _profiles.firstOrNull?.id;
    final f = configFile(id);
    if (await f.exists()) await f.delete();
    await _save();
  }

  Directory snapshotsDir(String id) => Directory('${dataDir.path}/snapshots/$id');

  /// Save a copy of the current config before overwriting it. Keeps the last
  /// [_keepSnapshots] copies so a bad edit or a broken subscription update can
  /// always be rolled back.
  static const int _keepSnapshots = 10;

  Future<void> snapshot(String id) async {
    final src = configFile(id);
    if (!await src.exists()) return;
    final dir = snapshotsDir(id);
    await dir.create(recursive: true);
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    await src.copy('${dir.path}/$stamp.yaml');

    final files = (await dir.list().toList())
        .whereType<File>()
        .where((f) => f.path.endsWith('.yaml'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    while (files.length > _keepSnapshots) {
      await files.removeAt(0).delete();
    }
  }

  Future<List<File>> snapshots(String id) async {
    final dir = snapshotsDir(id);
    if (!await dir.exists()) return const [];
    final files = (await dir.list().toList()).whereType<File>().where((f) => f.path.endsWith('.yaml')).toList()
      ..sort((a, b) => b.path.compareTo(a.path)); // newest first
    return files;
  }

  /// Roll a profile back to a snapshot (and snapshot the current state first).
  Future<void> deleteSnapshot(String id, File snap) async {
    if (await snap.exists()) await snap.delete();
  }

  Future<void> clearSnapshots(String id) async {
    final dir = snapshotsDir(id);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<void> restore(String id, File snap) async {
    await snapshot(id); // keep the current state too
    await snap.copy(configFile(id).path);
    final i = _profiles.indexWhere((p) => p.id == id);
    if (i >= 0) {
      final size = await configFile(id).length();
      _profiles[i] = _profiles[i].copyWith(updatedAt: DateTime.now(), bytes: size);
      await _save();
    }
  }

  Future<String> readConfig(String id) async => configFile(id).readAsString();

  /// Overwrite a profile's config (manual editing). The caller decides whether
  /// to restart the kernel afterwards.
  Future<void> writeConfig(String id, String text) async {
    final i = _profiles.indexWhere((p) => p.id == id);
    if (i < 0) throw StateError('profile $id not found');
    await snapshot(id);
    await configFile(id).writeAsString(text);
    _profiles[i] = _profiles[i].copyWith(updatedAt: DateTime.now(), bytes: text.length);
    await _save();
  }

  /// Edit name / subscription URL without touching the cached config.
  Future<void> updateMeta(String id, {String? name, String? url, int? autoUpdateHours}) async {
    final i = _profiles.indexWhere((p) => p.id == id);
    if (i < 0) throw StateError('profile $id not found');
    _profiles[i] = _profiles[i].copyWith(name: name, url: url, autoUpdateHours: autoUpdateHours);
    await _save();
  }

  Future<void> activate(String id) async {
    _activeId = id;
    await _save();
  }

  Future<void> rename(String id, String name) async {
    final i = _profiles.indexWhere((p) => p.id == id);
    if (i < 0) return;
    _profiles[i] = _profiles[i].copyWith(name: name);
    await _save();
  }

  // ---- quota parsing -------------------------------------------------------
  // Two sources, in order of trust: the `subscription-userinfo` response header
  // (standard across panels), then the human-readable notice "nodes" that many
  // airports inject into the config itself.

  static int? _toBytes(double value, String unit) {
    final mult = switch (unit.toUpperCase()) {
      'TB' => 1024 * 1024 * 1024 * 1024,
      'GB' => 1024 * 1024 * 1024,
      'MB' => 1024 * 1024,
      _ => 1,
    };
    return (value * mult).round();
  }

  static int? _noticeBytes(String text, String label) {
    final m = RegExp('$label[：:]\\s*([\\d.]+)\\s*(GB|MB|TB)').firstMatch(text);
    if (m == null) return null;
    return _toBytes(double.tryParse(m.group(1)!) ?? 0, m.group(2)!);
  }

  static DateTime? _noticeExpire(String text) {
    final m = RegExp(r'套餐到期[：:]\s*(\d{4}-\d{2}-\d{2})').firstMatch(text);
    return m == null ? null : DateTime.tryParse(m.group(1)!);
  }

  Future<({String text, int? used, int? total, DateTime? expire})> _download(
    String url, {
    String? proxyAddress,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    if (proxyAddress != null && proxyAddress.isNotEmpty) {
      // Fetch the subscription through our own proxy (some panels are only
      // reachable that way, or the direct route is throttled).
      client.findProxy = (uri) => 'PROXY $proxyAddress';
    }
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, 'clash-verge/v2.0.0 Aran/0.1');
      req.headers.set('Accept', '*/*');
      final res = await req.close().timeout(const Duration(seconds: 45));
      if (res.statusCode >= 300) {
        throw HttpException('HTTP ${res.statusCode} 下载订阅失败');
      }

      final userInfo = res.headers.value('subscription-userinfo');
      final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      var text = utf8.decode(bytes, allowMalformed: true).trim();

      if (!ConfigTransform.looksLikeMihomoConfig(text)) {
        try {
          final decoded = utf8.decode(base64.decode(text.replaceAll(RegExp(r'\s'), '')), allowMalformed: true);
          if (ConfigTransform.looksLikeMihomoConfig(decoded)) text = decoded;
        } catch (_) {}
      }
      if (!ConfigTransform.looksLikeMihomoConfig(text)) {
        throw const FormatException('订阅内容不是 mihomo 配置（可能需要转换器或登录）');
      }

      int? used;
      int? total;
      DateTime? expire;
      if (userInfo != null) {
        for (final part in userInfo.split(';')) {
          final kv = part.split('=');
          if (kv.length != 2) continue;
          final key = kv[0].trim();
          final value = int.tryParse(kv[1].trim());
          if (value == null) continue;
          switch (key) {
            case 'upload':
            case 'download':
              used = (used ?? 0) + value;
            case 'total':
              total = value;
            case 'expire':
              if (value > 0) expire = DateTime.fromMillisecondsSinceEpoch(value * 1000);
          }
        }
      }

      return (
        text: text,
        used: used ?? _noticeBytes(text, '已用流量'),
        total: total ?? _noticeBytes(text, '总流量'),
        expire: expire ?? _noticeExpire(text),
      );
    } finally {
      client.close(force: true);
    }
  }

  String _guessName(String url) {
    final host = Uri.tryParse(url)?.host;
    return host == null || host.isEmpty ? '订阅' : host;
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
