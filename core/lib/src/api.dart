import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Thin client for the mihomo (clash.meta) RESTful external controller.
///
/// Only the endpoints Aran actually needs. No third-party packages.
class MihomoApi {
  final Uri base;
  final String secret;
  final Duration timeout;
  final HttpClient _client;

  MihomoApi({
    String addr = '127.0.0.1:9090',
    this.secret = '',
    this.timeout = const Duration(seconds: 6),
  })  : base = Uri.parse('http://$addr'),
        _client = HttpClient()..connectionTimeout = const Duration(seconds: 3);

  Future<HttpClientResponse> _open(String method, String path, {Object? body}) async {
    final req = await _client.openUrl(method, base.resolve(path));
    if (secret.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $secret');
    }
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(body)));
    }
    return req.close().timeout(timeout);
  }

  Future<String> _body(HttpClientResponse res) async {
    final chunks = <int>[];
    await for (final c in res) {
      chunks.addAll(c);
    }
    return utf8.decode(chunks, allowMalformed: true);
  }

  Future<Map<String, dynamic>> _json(String method, String path, {Object? body}) async {
    final res = await _open(method, path, body: body);
    final text = await _body(res);
    if (res.statusCode >= 300) {
      throw ApiException('$method $path -> ${res.statusCode}: $text');
    }
    if (text.isEmpty) return const {};
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
    throw ApiException('$method $path: unexpected payload type ${decoded.runtimeType}');
  }

  Future<String> version() async =>
      (await _json('GET', '/version'))['version']?.toString() ?? 'unknown';

  /// All proxies and proxy groups, keyed by name.
  Future<Map<String, dynamic>> proxies() async =>
      (await _json('GET', '/proxies'))['proxies'] as Map<String, dynamic>;

  /// Live connections (used for passive throughput observation).
  Future<List<dynamic>> connections() async =>
      (await _json('GET', '/connections'))['connections'] as List<dynamic>? ?? const [];

  /// Probe a single proxy through the kernel: `GET /proxies/{name}/delay`.
  Future<ProbeOutcome> probe(
    String name, {
    String url = 'https://cp.cloudflare.com/generate_204',
    int timeoutMs = 5000,

  }) async {
    final sw = Stopwatch()..start();
    try {
      final res = await _open('GET',
          '/proxies/${Uri.encodeComponent(name)}/delay?url=${Uri.encodeQueryComponent(url)}&timeout=$timeoutMs');
      final text = await _body(res);
      if (res.statusCode != 200) {
        return ProbeOutcome(ok: false, rttMs: null, wallMs: sw.elapsedMilliseconds, error: 'HTTP ${res.statusCode}');
      }
      final decoded = jsonDecode(text);
      final d = decoded is Map ? decoded['delay'] : null;
      if (d is int && d > 0) {
        return ProbeOutcome(ok: true, rttMs: d, wallMs: sw.elapsedMilliseconds);
      }
      return ProbeOutcome(ok: false, rttMs: null, wallMs: sw.elapsedMilliseconds, error: 'no delay');
    } catch (e) {
      return ProbeOutcome(ok: false, rttMs: null, wallMs: sw.elapsedMilliseconds, error: '$e');
    }
  }

  /// Select a node inside a proxy group. This is the only write Aran performs.
  Future<void> select(String group, String node) async {
    await _json('PUT', '/proxies/${Uri.encodeComponent(group)}', body: {'name': node});
  }

  /// Test every member of a group (mihomo does it kernel-side). Returns name -> delay ms.
  Future<Map<String, int>> groupDelay(
    String group, {
    String url = 'https://cp.cloudflare.com/generate_204',
    int timeoutMs = 5000,
  }) async {
    final raw = await _json('GET',
        '/group/${Uri.encodeComponent(group)}/delay?url=${Uri.encodeQueryComponent(url)}&timeout=$timeoutMs');
    final out = <String, int>{};
    raw.forEach((k, v) {
      if (v is num) out[k] = v.toInt();
    });
    return out;
  }

  /// Apply runtime-patchable settings without reloading the whole config
  /// (ports, mode, log-level, allow-lan …). Existing connections survive.
  Future<void> patchConfigs(Map<String, dynamic> body) async {
    await _json('PATCH', '/configs', body: body);
  }

  /// Reload the config file in place: no process restart, PID stays the same.
  Future<void> reloadConfig(String path) async {
    await _json('PUT', '/configs?force=true', body: {'path': path});
  }

  /// Current outbound mode: rule / global / direct.
  Future<String> mode() async => (await _json('GET', '/configs'))['mode']?.toString() ?? 'rule';

  Future<void> setMode(String mode) async {
    await _json('PATCH', '/configs', body: {'mode': mode});
  }

  /// Bytes the kernel has moved since start: (upload, download).
  Future<(int, int)> connectionTotals() async {
    final raw = await _json('GET', '/connections');
    return (
      (raw['uploadTotal'] as num?)?.toInt() ?? 0,
      (raw['downloadTotal'] as num?)?.toInt() ?? 0,
    );
  }

  /// Kill a live connection (the "关闭" button in a real client's connection list).
  Future<void> closeConnection(String id) async {
    await _json('DELETE', '/connections/${Uri.encodeComponent(id)}');
  }

  /// Clear any fixed selection on a group.
  Future<void> unfix(String group) async {
    await _open('DELETE', '/proxies/${Uri.encodeComponent(group)}');
  }

  void close() => _client.close(force: true);
}

class ProbeOutcome {
  final bool ok;
  final int? rttMs;
  final int wallMs;
  final String? error;
  const ProbeOutcome({required this.ok, required this.rttMs, required this.wallMs, this.error});

  @override
  String toString() => ok ? '${rttMs}ms' : 'FAIL(${error ?? '?'})';
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => 'ApiException: $message';
}
