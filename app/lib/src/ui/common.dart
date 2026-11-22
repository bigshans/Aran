import 'package:flutter/material.dart';

const mono = TextStyle(fontFamily: 'monospace', fontFeatures: [FontFeature.tabularFigures()]);

/// Palette shared by both themes. Kept as getters over a single mutable slot:
/// the widget tree is rebuilt from [Shell], which calls [usePalette] first, so
/// every descendant sees the palette that matches the active brightness.
class AranPalette {
  final Color bg;
  final Color panel;
  final Color panelAlt;
  final Color line;

  /// Structural rule (header underline, section titles). Defaults to [line].
  final Color lineStrong;
  final Color text;
  final Color dim;
  final Color blue;
  final Color green;
  final Color amber;
  final Color red;

  /// Shape language. Constructivism: hard corners, heavy rules.
  final double radius;
  final double borderWidth;
  final bool capitals;

  AranPalette withAccent(Color accent) => AranPalette(
        bg: bg,
        panel: panel,
        panelAlt: panelAlt,
        line: line,
        lineStrong: lineStrong,
        text: text,
        dim: dim,
        blue: accent,
        green: green,
        amber: amber,
        red: red,
        radius: radius,
        borderWidth: borderWidth,
        capitals: capitals,
      );

  const AranPalette({
    required this.bg,
    required this.panel,
    required this.panelAlt,
    required this.line,
    Color? lineStrong,
    required this.text,
    required this.dim,
    required this.blue,
    required this.green,
    required this.amber,
    required this.red,
    this.radius = 4,
    this.borderWidth = 1,
    this.capitals = false,
  }) : lineStrong = lineStrong ?? line;
}

const darkPalette = AranPalette(
  radius: 4,
  borderWidth: 1,
  bg: Color(0xFF0E1116),
  panel: Color(0xFF141922),
  panelAlt: Color(0xFF17202C),
  line: Color(0xFF1B2029),
  lineStrong: Color(0xFF1B2029),
  text: Color(0xFFECEDEF),
  dim: Color(0xFF8A93A0),
  blue: Color(0xFF60A5FA),
  green: Color(0xFF4ADE80),
  amber: Color(0xFFFBBF24),
  red: Color(0xFFF87171),
);

const lightPalette = AranPalette(
  radius: 4,
  borderWidth: 1,
  bg: Color(0xFFF7F8FA),
  panel: Color(0xFFFFFFFF),
  panelAlt: Color(0xFFEDF2FB),
  line: Color(0xFFDDE1E8),
  lineStrong: Color(0xFFDDE1E8),
  text: Color(0xFF12161C),
  dim: Color(0xFF69707C),
  blue: Color(0xFF1D6FE0),
  green: Color(0xFF15803D),
  amber: Color(0xFFB45309),
  red: Color(0xFFDC2626),
);

/// Paper, ink, vermilion. Hard corners, 2px rules, uppercase micro-labels.
const constructivistLight = AranPalette(
  radius: 0,
  borderWidth: 1,
  capitals: true,
  bg: Color(0xFFEDE7DB),
  panel: Color(0xFFF5F1E8),
  panelAlt: Color(0xFFE2DACA),
  line: Color(0xFFB9B1A1),
  lineStrong: Color(0xFF141414),
  text: Color(0xFF141414),
  dim: Color(0xFF5C5750),
  blue: Color(0xFFD0342C),
  green: Color(0xFF1E6B3A),
  amber: Color(0xFFB26B00),
  red: Color(0xFF8B0000),
);

const constructivistDark = AranPalette(
  radius: 0,
  borderWidth: 1,
  capitals: true,
  bg: Color(0xFF121110),
  panel: Color(0xFF1B1A18),
  panelAlt: Color(0xFF24221F),
  line: Color(0xFF3A3733),
  lineStrong: Color(0xFFF2EDE4),
  text: Color(0xFFF2EDE4),
  dim: Color(0xFF9A948A),
  blue: Color(0xFFFF4438),
  green: Color(0xFF3FA96B),
  amber: Color(0xFFE0A030),
  red: Color(0xFFFF6055),
);

AranPalette _palette = darkPalette;
String _style = 'modern';

Color? _parseHex(String hex) {
  var h = hex.trim().replaceFirst('#', '');
  if (h.length == 6) h = 'FF$h';
  if (h.length != 8) return null;
  final v = int.tryParse(h, radix: 16);
  return v == null ? null : Color(v);
}

String? accentFromSettings(String? hex) {
  if (hex == null || hex.trim().isEmpty) return null;
  final c = _parseHex(hex);
  if (c == null) return null;
  return hex.trim();
}

void usePalette(Brightness brightness, {String style = 'modern', String? accent}) {
  _style = style;
  final constructivist = style == 'constructivist';
  var base = constructivist
      ? (brightness == Brightness.dark ? constructivistDark : constructivistLight)
      : (brightness == Brightness.dark ? darkPalette : lightPalette);
  final c = accent == null || accent.isEmpty ? null : _parseHex(accent);
  if (c != null) base = base.withAccent(c);
  _palette = base;
}

bool get constructivist => _style == 'constructivist';

AranPalette get palette => _palette;

Color get bg => _palette.bg;
Color get panel => _palette.panel;
Color get panelAlt => _palette.panelAlt;
Color get line => _palette.line;
Color get lineStrong => _palette.lineStrong;
Color get text => _palette.text;
Color get dim => _palette.dim;
Color get blue => _palette.blue;
Color get green => _palette.green;
Color get amber => _palette.amber;
Color get red => _palette.red;
double get radius => _palette.radius;
double get borderWidth => _palette.borderWidth;

/// Micro-labels are uppercase in the constructivist skin.
String caps(String text) => _palette.capitals ? text.toUpperCase() : text;

ThemeData buildTheme(Brightness brightness, {String style = 'modern', String? accent}) {
  final constructivistStyle = style == 'constructivist';
  final p = constructivistStyle
      ? (brightness == Brightness.dark ? constructivistDark : constructivistLight)
      : (brightness == Brightness.dark ? darkPalette : lightPalette);
  final accentColor = (accent != null && accent.isNotEmpty) ? (_parseHex(accent) ?? p.blue) : p.blue;
  final r = BorderRadius.circular(p.radius);
  final scheme = ColorScheme.fromSeed(seedColor: accentColor, brightness: brightness).copyWith(
    surface: p.bg,
    onSurface: p.text,
    primary: accentColor,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    dialogTheme: DialogThemeData(backgroundColor: p.panel, shape: RoundedRectangleBorder(borderRadius: r)),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {}),
    splashFactory: NoSplash.splashFactory,
    textTheme: ThemeData(brightness: brightness).textTheme.apply(bodyColor: p.text, displayColor: p.text),
  );
}

/// The mark: a vermilion triangle (A) crossed by an ink bar, on paper.
/// Drawn, not imported, so it stays crisp at any size and follows the palette.
class AranMark extends StatelessWidget {
  final double size;
  const AranMark({super.key, this.size = 22});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _MarkPainter(accent: blue),
    );
  }
}

class _MarkPainter extends CustomPainter {
  final Color accent;
  const _MarkPainter({required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    double x(num v) => s * v / 512;
    Path poly(List<num> pts) {
      final p = Path()..moveTo(x(pts[0]), x(pts[1]));
      for (var i = 2; i < pts.length; i += 2) {
        p.lineTo(x(pts[i]), x(pts[i + 1]));
      }
      return p..close();
    }

    // Transparent background: only the letterform is drawn (mirrors icon.svg).
    final fill = Paint()
      ..color = accent
      ..isAntiAlias = true;
    final round = Paint()
      ..color = accent
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeWidth = x(20)
      ..strokeJoin = StrokeJoin.round;
    for (final pts in <List<num>>[
      [247, 110, 287, 110, 205, 400, 121, 400],
      [247, 110, 287, 110, 391, 400, 307, 400],
      [180, 316, 332, 316, 332, 364, 180, 364],
    ]) {
      final path = poly(pts);
      canvas.drawPath(path, fill);
      canvas.drawPath(path, round);
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.accent != accent;
}

class SectionTitle extends StatelessWidget {
  final String title;
  final String tail;
  final Widget? trailing;
  const SectionTitle(this.title, {super.key, this.tail = '', this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Row(children: [
        Text(caps(title),
            style: TextStyle(
                fontSize: 13,
                fontWeight: constructivist ? FontWeight.w800 : FontWeight.w600,
                letterSpacing: constructivist ? 1.6 : 0.5,
                color: text)),
        if (constructivist) ...[
          const SizedBox(width: 10),
          Expanded(child: Container(height: 1, color: lineStrong)),
        ],
        const SizedBox(width: 10),
        if (tail.isNotEmpty) Expanded(child: Text(tail, style: mono.copyWith(color: dim, fontSize: 11))),
        ?trailing,
      ]),
    );
  }
}

class Btn extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final Color? color;
  final bool filled;
  final bool small;

  /// Shows a spinner and blocks clicks while the action is in flight.
  final bool loading;

  /// One button, one geometry. Every control in the app derives from these.
  static const double heightMd = 32;
  static const double heightSm = 27;

  const Btn({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.color,
    this.filled = false,
    this.small = false,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? blue;
    final disabled = onTap == null || loading;
    final fg = disabled ? dim : c;
    final h = small ? heightSm : heightMd;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        height: h,
        padding: EdgeInsets.symmetric(horizontal: small ? 9 : 12),
        decoration: BoxDecoration(
          color: filled ? c.withValues(alpha: 0.16) : Colors.transparent,
          border: Border.all(color: disabled ? line : c.withValues(alpha: 0.55)),
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (loading) ...[
            SizedBox(
              width: small ? 11 : 13,
              height: small ? 11 : 13,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: fg),
            ),
            const SizedBox(width: 6),
          ] else if (icon != null) ...[
            Icon(icon, size: small ? 13 : 15, color: fg),
            const SizedBox(width: 6),
          ],
          Text(label, style: mono.copyWith(fontSize: small ? 11.5 : 12.5, color: fg, height: 1)),
        ]),
      ),
    );
  }
}

/// Compact checkbox + label, sized to sit inline with [Btn] in the top bar.
class CheckRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Color? color;
  final String? tooltip;

  /// Show a spinner instead of the checkbox while the action is in flight.
  final bool loading;

  const CheckRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.color,
    this.tooltip,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = value ? (color ?? blue) : dim;
    final row = InkWell(
      onTap: loading ? null : () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 30,
            height: 30,
            child: loading
                ? Center(child: SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.6, color: c)))
                : Checkbox(
              value: value,
              onChanged: (v) => onChanged(v ?? false),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              activeColor: c,
              checkColor: bg,
              side: BorderSide(color: line, width: 1),
            ),
          ),
          const SizedBox(width: 2),
          Text(label, style: mono.copyWith(fontSize: 11.5, color: c)),
        ]),
      ),
    );
    return tooltip == null ? row : Tooltip(message: tooltip!, child: row);
  }
}

/// Segmented control sharing the same height as [Btn].
class Segment extends StatelessWidget {
  final List<(String, String)> options; // (value, label)
  final String value;
  final ValueChanged<String> onChanged;
  const Segment({super.key, required this.options, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < options.length; i++)
        Padding(
          padding: EdgeInsets.only(right: i == options.length - 1 ? 0 : 4),
          child: Btn(
            label: options[i].$2,
            small: true,
            filled: options[i].$1 == value,
            color: options[i].$1 == value ? blue : dim,
            onTap: () => onChanged(options[i].$1),
          ),
        ),
    ]);
  }
}

class ErrorBanner extends StatelessWidget {
  final String? message;
  final VoidCallback onDismiss;
  const ErrorBanner({super.key, required this.message, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    if (message == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
      color: red.withValues(alpha: 0.12),
      child: Row(children: [
        Icon(Icons.error_outline_rounded, size: 16, color: red),
        const SizedBox(width: 8),
        Expanded(child: Text(message!, style: mono.copyWith(color: red, fontSize: 12))),
        IconButton(icon: Icon(Icons.close_rounded, size: 16, color: red), onPressed: onDismiss),
      ]),
    );
  }
}


/// Persistent scrollbars everywhere. They overlay the viewport (they do not
/// steal width), so table rows keep lining up with their headers.
class AranScrollBehavior extends MaterialScrollBehavior {
  const AranScrollBehavior();

  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) {
    return Scrollbar(
      controller: details.controller,
      thumbVisibility: true,
      trackVisibility: false,
      thickness: 8,
      radius: Radius.circular(radius),
      child: child,
    );
  }
}


/// Horizontal usage bar. Used for subscription quota and anywhere else a ratio
/// reads better than two numbers.
class QuotaBar extends StatelessWidget {
  final int used;
  final int total;
  final double width;
  final double height;
  final String? label;
  final bool showPercent;

  const QuotaBar({
    super.key,
    required this.used,
    required this.total,
    this.width = 140,
    this.height = 5,
    this.label,
    this.showPercent = true,
  });

  @override
  Widget build(BuildContext context) {
    final ratio = total <= 0 ? 0.0 : (used / total).clamp(0.0, 1.0);
    final left = 1 - ratio;
    final color = left < 0.1 ? red : left < 0.3 ? amber : green;
    return Row(children: [
      Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: line,
          borderRadius: BorderRadius.circular(height),
        ),
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: ratio == 0 ? 0.001 : ratio,
          child: Container(
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(height)),
          ),
        ),
      ),
      if (showPercent) ...[
        const SizedBox(width: 8),
        Text('${(ratio * 100).toStringAsFixed(0)}%',
            style: mono.copyWith(fontSize: 10.5, color: color)),
      ],
      if (label != null) ...[
        const SizedBox(width: 8),
        Text(label!, style: mono.copyWith(fontSize: 10.5, color: dim)),
      ],
    ]);
  }
}

String fmtBytes(int? bytes) {
  if (bytes == null) return '—';
  const tb = 1024 * 1024 * 1024 * 1024;
  const gb = 1024 * 1024 * 1024;
  const mb = 1024 * 1024;
  if (bytes >= tb) return '${(bytes / tb).toStringAsFixed(2)} TB';
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '$bytes B';
}
