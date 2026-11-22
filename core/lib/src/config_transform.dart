/// Line/structure-aware surgery for mihomo configs, without a YAML dependency.
///
/// Airports emit two very different styles:
///
///   block style                        flow style
///   proxies:                           proxies:
///     - name: 节点A                       - { name: 节点A, type: vless, ... }
///       type: vless                      proxy-groups:
///   proxy-groups:                        - { name: 组, type: url-test, proxies: [A, B] }
///     - name: 组
///       type: url-test
///       proxies:
///         - 节点A
///
/// A naive line filter works for the first and silently breaks the second (left
/// over references to removed placeholder nodes => kernel refuses to start), so
/// groups are parsed into records and re-emitted in block style.
library;

/// Patch applied to an existing top-level section instead of replacing it.
/// Replacing `dns:` wholesale silently drops `nameserver-policy`,
/// `respect-rules`, `fake-ip-filter` … i.e. mihomo's own DNS routing.
class SectionPatch {
  final Map<String, String> scalars;
  final Map<String, List<String>> lists;
  final Set<String> remove;

  const SectionPatch({
    this.scalars = const {},
    this.lists = const {},
    this.remove = const {},
  });

  bool get isEmpty => scalars.isEmpty && lists.isEmpty && remove.isEmpty;

  List<String> applyTo(List<String> body) {
    // Indentation is whatever the subscription uses (2, 4, …) — never assume.
    var childIndent = 0;
    for (final line in body.skip(1)) {
      if (line.trim().isEmpty) continue;
      childIndent = line.length - line.trimLeft().length;
      break;
    }
    final pad = ' ' * (childIndent == 0 ? 2 : childIndent);

    final out = <String>[body.first];
    final seen = <String>{};
    var i = 1;
    while (i < body.length) {
      final line = body[i];
      final trimmed = line.trimLeft();
      final indent = line.length - trimmed.length;
      final isKey = trimmed.isNotEmpty &&
          indent == childIndent &&
          trimmed.contains(':') &&
          !trimmed.startsWith('-');

      if (!isKey) {
        out.add(line);
        i++;
        continue;
      }

      final key = trimmed.substring(0, trimmed.indexOf(':')).trim();

      // Consume the key's whole block (deeper indented lines / list items).
      var j = i + 1;
      while (j < body.length) {
        final l = body[j];
        if (l.trim().isEmpty) {
          j++;
          continue;
        }
        if (l.length - l.trimLeft().length > indent) {
          j++;
          continue;
        }
        break;
      }

      if (remove.contains(key)) {
        i = j;
        continue;
      }
      if (scalars.containsKey(key)) {
        out.add('$pad$key: ${scalars[key]}');
        seen.add(key);
        i = j;
        continue;
      }
      if (lists.containsKey(key)) {
        out.add('$pad$key:');
        for (final item in lists[key]!) {
          out.add('$pad  - $item');
        }
        seen.add(key);
        i = j;
        continue;
      }
      out.addAll(body.sublist(i, j));
      i = j;
    }

    for (final e in scalars.entries) {
      if (!seen.contains(e.key)) out.add('$pad${e.key}: ${e.value}');
    }
    for (final e in lists.entries) {
      if (seen.contains(e.key)) continue;
      out.add('$pad${e.key}:');
      for (final item in e.value) {
        out.add('$pad  - $item');
      }
    }
    return out;
  }
}

class _Group {
  final String name;
  String type;
  final List<String> members;
  final List<String> extraKeys; // raw "key: value" lines, already trimmed
  final bool wasFlow;

  _Group({
    required this.name,
    required this.type,
    required this.members,
    required this.extraKeys,
    required this.wasFlow,
  });
}

class ConfigTransform {
  /// Scalar top-level keys to force, e.g. `mixed-port`.
  final Map<String, String> overrides;

  /// Section name -> replacement block. Empty string deletes the section.
  final Map<String, String?> sections;

  /// Section name -> merge patch (preferred over [sections] when both are set).
  final Map<String, SectionPatch> patches;

  /// Top-level scalar keys to delete outright (e.g. `mixed-port` when using
  /// separate HTTP/SOCKS ports).
  final Set<String> dropKeys;

  final bool convertAutoGroups;

  /// Remove placeholder "proxies" (traffic counters, notices, Dont.use nodes).
  final bool dropPseudoProxies;

  /// keep | cnDirect | proxyAll | whitelist
  final String rulesMode;

  final String? proxyGroupName;

  /// Delete groups that no rule references (airports emit unused "自动" copies).
  final bool pruneUnreferencedGroups;

  /// Extra url-test group used by the watchdog when Aran disappears.
  final String? fallbackGroupName;

  const ConfigTransform({
    this.overrides = const {},
    this.sections = const {},
    this.patches = const {},
    this.dropKeys = const {},
    this.convertAutoGroups = true,
    this.dropPseudoProxies = true,
    this.rulesMode = 'keep',
    this.proxyGroupName,
    this.pruneUnreferencedGroups = false,
    this.fallbackGroupName,
  });

  static const _autoGroupTypes = {'url-test', 'fallback', 'load-balance'};
  static const _autoGroupKeys = {'url', 'interval', 'tolerance', 'lazy', 'expected-status', 'max-failed-times'};

  static final pseudoPattern =
      RegExp(r'剩余流量|套餐到期|距离下次|防走失|更新订阅|官网|指引|客服|Dont\.use|不可用|请购买|过期|电报群|防失联');

  static bool isPseudo(String name) =>
      name.contains('：') || name.toLowerCase().startsWith('http') || pseudoPattern.hasMatch(name);

  static bool looksLikeMihomoConfig(String text) =>
      text.contains('proxies:') || text.contains('proxy-groups:') || text.contains('mixed-port:');

  static String _unquote(String s) {
    var t = s.trim();
    if (t.length >= 2 &&
        ((t.startsWith("'") && t.endsWith("'")) || (t.startsWith('"') && t.endsWith('"')))) {
      t = t.substring(1, t.length - 1);
    }
    return t.trim();
  }

  static String _quote(String s) {
    if (s.isEmpty) return "''";
    final needs = s.contains(',') || s.contains(':') || s.contains('#') || s.contains('[') ||
        s.contains(']') || s.contains('{') || s.contains('}') || s.contains("'") ||
        s.trim() != s || s.startsWith('-') || s.startsWith('!') || s.startsWith('&') || s.startsWith('*');
    if (!needs) return s;
    return "'${s.replaceAll("'", "''")}'";
  }

  /// Index of the bracket that closes `open` at [start]; -1 when unbalanced.
  static int _closing(String s, int start, String open, String close) {
    var depth = 0;
    var inSingle = false;
    var inDouble = false;
    for (var i = start; i < s.length; i++) {
      final c = s[i];
      if (inSingle) {
        if (c == "'") inSingle = false;
        continue;
      }
      if (inDouble) {
        if (c == '"') inDouble = false;
        continue;
      }
      if (c == "'") {
        inSingle = true;
      } else if (c == '"') {
        inDouble = true;
      } else if (c == open) {
        depth++;
      } else if (c == close) {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  /// Split a flow list body (`a, 'b c', [d]`) on top-level commas.
  static List<String> _splitTop(String body) {
    final out = <String>[];
    var buf = StringBuffer();
    var depth = 0;
    var inSingle = false;
    var inDouble = false;
    for (var i = 0; i < body.length; i++) {
      final c = body[i];
      if (inSingle) {
        buf.write(c);
        if (c == "'") inSingle = false;
        continue;
      }
      if (inDouble) {
        buf.write(c);
        if (c == '"') inDouble = false;
        continue;
      }
      switch (c) {
        case "'":
          inSingle = true;
          buf.write(c);
        case '"':
          inDouble = true;
          buf.write(c);
        case '[':
        case '{':
          depth++;
          buf.write(c);
        case ']':
        case '}':
          depth--;
          buf.write(c);
        case ',':
          if (depth == 0) {
            out.add(buf.toString());
            buf = StringBuffer();
          } else {
            buf.write(c);
          }
        default:
          buf.write(c);
      }
    }
    if (buf.toString().trim().isNotEmpty) out.add(buf.toString());
    return out;
  }

  /// Parse a flow map body (`name: X, type: select, proxies: [a, b]`).
  static Map<String, String> _parseFlowMap(String body) {
    final map = <String, String>{};
    for (final part in _splitTop(body)) {
      final idx = part.indexOf(':');
      if (idx <= 0) continue;
      final key = part.substring(0, idx).trim();
      final value = part.substring(idx + 1).trim();
      if (key.isEmpty) continue;
      map[key] = value;
    }
    return map;
  }

  static List<String> _flowListMembers(String raw) {
    var body = raw.trim();
    if (body.startsWith('[') && body.endsWith(']')) body = body.substring(1, body.length - 1);
    return [for (final p in _splitTop(body)) _unquote(p)];
  }

  ({
    String config,
    List<String> convertedGroups,
    List<String> droppedProxies,
    List<String> managedGroups,
    List<String> prunedGroups,
  }) apply(String source) {
    final lines = source.split('\n');
    final out = <String>[];

    // Split into top-level sections, keeping their order and raw content.
    final order = <String>[];
    final bodies = <String, List<String>>{};
    final headless = <String>[]; // lines before the first top-level key
    String? current;
    for (final line in lines) {
      final isTop = line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('\t') && !line.startsWith('-');
      if (isTop && line.contains(':')) {
        current = line.substring(0, line.indexOf(':')).trim();
        order.add(current);
        bodies.putIfAbsent(current, () => []).add(line);
        continue;
      }
      if (current == null) {
        headless.add(line);
      } else {
        bodies[current]!.add(line);
      }
    }

    final convertedGroups = <String>[];
    final dropped = <String>[];
    final keptProxies = <String>{};

    // ---- proxies ----
    if (bodies.containsKey('proxies')) {
      final raw = bodies['proxies']!;
      final kept = <String>[raw.first];
      var dropping = false;
      for (final line in raw.skip(1)) {
        final t = line.trimLeft();
        final startsEntry = t.startsWith('- ');
        if (startsEntry) {
          String name;
          if (t.startsWith('- {')) {
            final inner = t.substring(2).trim();
            final map = _parseFlowMap(inner.startsWith('{') ? inner.substring(1, inner.length - 1) : inner);
            name = _unquote(map['name'] ?? '');
          } else {
            name = _unquote(t.substring(2).split(':').skip(1).join(':'));
          }
          dropping = dropPseudoProxies && isPseudo(name);
          if (dropping) {
            dropped.add(name);
          } else {
            keptProxies.add(name);
          }
        }
        if (!dropping) kept.add(line);
      }
      bodies['proxies'] = kept;
    }

    // Which groups do rules actually name? Those are the ones worth managing.
    final ruleTargets = <String>{};
    if (bodies.containsKey('rules')) {
      for (final line in bodies['rules']!.skip(1)) {
        final t = line.trim();
        if (!t.startsWith('- ')) continue;
        final rule = _unquote(t.substring(2).trim());
        var parts = rule.split(',').map((e) => e.trim()).toList();
        while (parts.isNotEmpty && (parts.last == 'no-resolve' || parts.last == 'src')) {
          parts = parts.sublist(0, parts.length - 1);
        }
        if (parts.isEmpty) continue;
        ruleTargets.add(parts.first.toUpperCase() == 'MATCH' && parts.length > 1 ? parts[1] : parts.last);
      }
    }

    final prunedGroups = <String>[];
    final managedNames = <String>[];
    var mainGroupName = 'PROXY';

    // ---- proxy-groups ----
    if (bodies.containsKey('proxy-groups')) {
      var groups = _parseGroups(bodies['proxy-groups']!);
      mainGroupName = proxyGroupName ??
          (groups.isEmpty
              ? null
              : ([...groups]..sort((a, b) => b.members.length.compareTo(a.members.length))).first.name) ??
          'PROXY';

      if (pruneUnreferencedGroups) {
        // Keep: groups named by rules, plus the main group, plus groups that are
        // members of kept groups (nested selectors).
        // Strictly: a group survives only if a rule names it (or it is the main
        // group). Stale "自动" copies that merely appear as members of the main
        // group are dropped too — they add noise, not capability.
        final keep = <String>{
          ...groups.map((g) => g.name).where(ruleTargets.contains),
          if (proxyGroupName != null) proxyGroupName!,
        };
        prunedGroups.addAll(groups.map((g) => g.name).where((n) => !keep.contains(n)));
        groups = groups.where((g) => keep.contains(g.name)).toList();
      }
      final rebuilt = <String>['proxy-groups:'];
      for (final g in groups) {
        final members = <String>[];
        for (final m in g.members) {
          if (m.isEmpty) continue;
          if (dropPseudoProxies && isPseudo(m)) continue;
          // A member we dropped from `proxies` must not be referenced either.
          final isGroupRef = groups.any((x) => x.name == m);
          if (!isGroupRef && keptProxies.isNotEmpty && !keptProxies.contains(m)) continue;
          if (!members.contains(m)) members.add(m);
        }

        var type = g.type;
        if (convertAutoGroups && _autoGroupTypes.contains(type)) {
          type = 'select';
          convertedGroups.add(g.name);
        }

        if (ruleTargets.contains(g.name) || g.name == mainGroupName) managedNames.add(g.name);
        rebuilt.add('  - name: ${_quote(g.name)}');
        rebuilt.add('    type: $type');
        for (final k in g.extraKeys) {
          final key = k.split(':').first.trim();
          if (convertAutoGroups && _autoGroupKeys.contains(key)) continue;
          rebuilt.add('    $k');
        }
        if (members.isEmpty) {
          rebuilt.add('    proxies: []');
        } else {
          rebuilt.add('    proxies:');
          for (final m in members) {
            rebuilt.add('      - ${_quote(m)}');
          }
        }
      }
      if (fallbackGroupName != null && keptProxies.isNotEmpty) {
        rebuilt.add('  - name: ${_quote(fallbackGroupName!)}');
        rebuilt.add('    type: url-test');
        rebuilt.add("    url: 'https://cp.cloudflare.com/generate_204'");
        rebuilt.add('    interval: 120');
        rebuilt.add('    tolerance: 30');
        rebuilt.add('    proxies:');
        for (final p in keptProxies) {
          rebuilt.add('      - ${_quote(p)}');
        }
      }
      bodies['proxy-groups'] = rebuilt;
    }

    // ---- rules ----
    final capturedRules = <String>[];
    if (bodies.containsKey('rules')) {
      for (final line in bodies['rules']!.skip(1)) {
        final t = line.trim();
        if (t.startsWith('- ')) capturedRules.add(_unquote(t.substring(2).trim()));
        if (t.startsWith('- [')) capturedRules.add(t.substring(2).trim());
      }
    }


    if (rulesMode != 'keep') {
      final generated = <String>['rules:'];
      void add(String r) => generated.add('  - $r');
      switch (rulesMode) {
        case 'cnDirect':
          add('GEOIP,PRIVATE,DIRECT');
          add('GEOSITE,private,DIRECT');
          add('GEOSITE,cn,DIRECT');
          add('GEOIP,CN,DIRECT');
          for (final r in capturedRules) {
            if (r.toUpperCase().startsWith('MATCH')) continue;
            add(r);
          }
          add('MATCH,$mainGroupName');
        case 'proxyAll':
          add('MATCH,$mainGroupName');
        case 'whitelist':
          add('GEOIP,PRIVATE,DIRECT');
          add('GEOSITE,cn,DIRECT');
          add('GEOIP,CN,DIRECT');
          add('MATCH,$mainGroupName');
      }
      bodies['rules'] = generated;
      if (!order.contains('rules')) order.add('rules');
    }

    // ---- assemble ----
    out.addAll(headless);
    for (final key in order) {
      final body = bodies[key];
      if (body == null) continue;

      if (dropKeys.contains(key)) continue;
      if (patches.containsKey(key)) {
        out.addAll(patches[key]!.applyTo(body));
        continue;
      }
      if (sections.containsKey(key)) {
        final replacement = sections[key];
        if (replacement != null && replacement.trim().isNotEmpty) out.add(replacement);
        continue;
      }
      if (overrides.containsKey(key)) {
        out.add('$key: ${overrides[key]}');
        continue;
      }
      out.addAll(body);
    }

    // keys/sections the source never had
    final missingKeys = overrides.entries.where((e) => !order.contains(e.key)).toList();
    if (missingKeys.isNotEmpty) {
      final insertAt = headless.isEmpty ? 0 : headless.length;
      out.insertAll(insertAt, missingKeys.map((e) => '${e.key}: ${e.value}'));
    }
    for (final entry in patches.entries) {
      if (order.contains(entry.key)) continue;
      if (entry.value.isEmpty) continue;
      final body = entry.value.applyTo(<String>['${entry.key}:']);
      out.addAll(body);
    }
    for (final entry in sections.entries) {
      if (order.contains(entry.key)) continue;
      final body = entry.value;
      if (body == null || body.trim().isEmpty) continue;
      out.add(body);
    }

    final managed = managedNames;

    return (
      config: out.join('\n'),
      convertedGroups: convertedGroups,
      droppedProxies: dropped,
      managedGroups: managed,
      prunedGroups: prunedGroups,
    );
  }

  /// Parse both block and flow style group entries into records.
  static List<_Group> _parseGroups(List<String> raw) {
    final groups = <_Group>[];
    var i = 0;
    while (i < raw.length) {
      final line = raw[i];
      final t = line.trim();

      if (t.startsWith('- {')) {
        final open = line.indexOf('{');
        final close = _closing(line, open, '{', '}');
        final inner = close > open ? line.substring(open + 1, close) : line.substring(open + 1);
        final map = _parseFlowMap(inner);
        final name = _unquote(map['name'] ?? '');
        if (name.isEmpty) {
          i++;
          continue;
        }
        final proxiesRaw = map['proxies'] ?? '[]';
        final members = _flowListMembers(proxiesRaw);
        final extras = <String>[];
        map.forEach((k, v) {
          if (k == 'name' || k == 'type' || k == 'proxies') return;
          extras.add('$k: $v');
        });
        groups.add(_Group(
          name: name,
          type: _unquote(map['type'] ?? 'select'),
          members: members,
          extraKeys: extras,
          wasFlow: true,
        ));
        i++;
        continue;
      }

      if (t.startsWith('- name:')) {
        final name = _unquote(t.substring('- name:'.length));
        var type = 'select';
        final members = <String>[];
        final extras = <String>[];
        i++;
        while (i < raw.length) {
          final nt = raw[i].trim();
          if (nt.startsWith('- name:') || nt.startsWith('- {')) break;
          if (nt.isEmpty) {
            i++;
            continue;
          }
          if (nt.startsWith('type:')) {
            type = _unquote(nt.substring(5));
            i++;
            continue;
          }
          if (nt.startsWith('proxies:')) {
            final rest = nt.substring('proxies:'.length).trim();
            if (rest.startsWith('[')) {
              members.addAll(_flowListMembers(rest));
              i++;
            } else {
              i++;
              while (i < raw.length && raw[i].trim().startsWith('- ')) {
                members.add(_unquote(raw[i].trim().substring(2)));
                i++;
              }
            }
            continue;
          }
          extras.add(nt);
          i++;
        }
        groups.add(_Group(name: name, type: type, members: members, extraKeys: extras, wasFlow: false));
        continue;
      }
      i++;
    }
    return groups;
  }

  /// Largest group = the one unmatched traffic should go to.
  static String? detectMainGroup(String groupBlock) {
    final groups = _parseGroups(groupBlock.split('\n'));
    if (groups.isEmpty) return null;
    final sorted = [...groups]..sort((a, b) => b.members.length.compareTo(a.members.length));
    return sorted.first.name;
  }
}
