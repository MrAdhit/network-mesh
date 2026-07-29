/// Filament's icons: hand-drawn line paths on a 16x16 grid, 1.5px stroke,
/// round caps, drawn by a [CustomPainter]. No icon font, no Material glyphs.
///
/// The set is small on purpose. If a screen wants an icon that is not here, the
/// screen probably wants a word instead.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The whole icon set.
enum MeshGlyph {
  /// Overview. A heartbeat trace.
  pulse,

  /// Peers. Three connected nodes.
  nodes,

  /// Network. A globe.
  globe,

  /// Settings.
  gear,

  /// Enrollment keys.
  key,

  /// Copy to clipboard.
  copy,

  /// Refresh / poll now.
  refresh,

  /// Ping. A radar sweep.
  radar,

  /// Disclosure. Points down at rest; rotate with `turns`.
  chevron,

  /// Dismiss.
  close,

  /// Degraded or destructive warning.
  warning,

  /// Leave the network.
  power,

  /// Reveal a secret.
  eye,

  /// Hide a secret.
  eyeOff,
}

/// Draws one [MeshGlyph], inheriting the ambient text colour unless [color] is
/// given.
///
/// The glyph is authored on a 16x16 grid and scaled to [size], so stroke weight
/// scales with it and stays visually consistent.
class MeshIcon extends StatelessWidget {
  const MeshIcon(
    this.glyph, {
    this.size = 16,
    this.color,
    this.turns = 0,
    this.strokeWidth = 1.5,
    super.key,
  });

  final MeshGlyph glyph;
  final double size;

  /// Defaults to the ambient [DefaultTextStyle] colour.
  final Color? color;

  /// Rotation in turns. 0.25 turns a down-chevron into a left-pointing one.
  final double turns;

  /// On the 16px grid. Scaled with [size].
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final resolved =
        color ??
        DefaultTextStyle.of(context).style.color ??
        const Color(0xFFE6EBF0);
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _MeshIconPainter(
          glyph: glyph,
          color: resolved,
          turns: turns,
          strokeWidth: strokeWidth,
        ),
        isComplex: false,
      ),
    );
  }
}

class _MeshIconPainter extends CustomPainter {
  _MeshIconPainter({
    required this.glyph,
    required this.color,
    required this.turns,
    required this.strokeWidth,
  });

  final MeshGlyph glyph;
  final Color color;
  final double turns;
  final double strokeWidth;

  static const double _grid = 16;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width, size.height) / _grid;
    canvas
      ..save()
      ..translate(size.width / 2, size.height / 2);
    if (turns != 0) canvas.rotate(turns * 2 * math.pi);
    canvas
      ..scale(scale)
      ..translate(-_grid / 2, -_grid / 2);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    _draw(canvas, stroke, fill);
    canvas.restore();
  }

  void _draw(Canvas canvas, Paint stroke, Paint fill) {
    switch (glyph) {
      case MeshGlyph.pulse:
        canvas.drawPath(
          _poly(const [
            Offset(1.4, 8),
            Offset(4.6, 8),
            Offset(6.2, 3.6),
            Offset(9.0, 12.4),
            Offset(10.6, 8),
            Offset(14.6, 8),
          ]),
          stroke,
        );

      case MeshGlyph.nodes:
        const a = Offset(4, 4.6);
        const b = Offset(12, 4.6);
        const c = Offset(8, 12);
        const r = 1.9;
        canvas
          ..drawPath(_segment(a, b, r), stroke)
          ..drawPath(_segment(a, c, r), stroke)
          ..drawPath(_segment(b, c, r), stroke)
          ..drawCircle(a, r, stroke)
          ..drawCircle(b, r, stroke)
          ..drawCircle(c, r, stroke);

      case MeshGlyph.globe:
        const center = Offset(8, 8);
        canvas
          ..drawCircle(center, 6.2, stroke)
          ..drawOval(
            Rect.fromCenter(center: center, width: 6.4, height: 12.4),
            stroke,
          )
          ..drawLine(const Offset(2.0, 8), const Offset(14.0, 8), stroke)
          ..drawPath(_arcPath(center, 6.2, 0.28, math.pi - 0.56), stroke);

      case MeshGlyph.gear:
        const center = Offset(8, 8);
        canvas
          ..drawCircle(center, 2.2, stroke)
          ..drawCircle(center, 4.8, stroke);
        // Stubby teeth around the body. Thin radial spokes read as a sun.
        final tooth = Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth * 1.5
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true;
        for (var i = 0; i < 8; i++) {
          final angle = i * math.pi / 4 + math.pi / 8;
          final d = Offset(math.cos(angle), math.sin(angle));
          canvas.drawLine(center + d * 4.4, center + d * 6.2, tooth);
        }

      case MeshGlyph.key:
        const bow = Offset(4.9, 11.1);
        canvas
          ..drawCircle(bow, 2.7, stroke)
          ..drawLine(const Offset(6.9, 9.2), const Offset(13.6, 2.5), stroke)
          ..drawLine(const Offset(10.4, 5.7), const Offset(12.0, 7.3), stroke)
          ..drawLine(const Offset(8.8, 7.3), const Offset(10.1, 8.6), stroke);

      case MeshGlyph.copy:
        canvas
          ..drawRRect(
            RRect.fromRectAndRadius(
              const Rect.fromLTWH(1.6, 5.6, 8.8, 8.8),
              const Radius.circular(1.6),
            ),
            stroke,
          )
          ..drawPath(_copyBack(), stroke);

      case MeshGlyph.refresh:
        const center = Offset(8, 8);
        const radius = 5.4;
        const start = -math.pi / 2 + 1.1;
        const sweep = math.pi * 2 - 1.1;
        canvas.drawPath(_arcPath(center, radius, start, sweep), stroke);
        // Arrowhead on the end of the sweep, opening back along the tangent.
        const end = start + sweep;
        final tip = center + Offset(math.cos(end), math.sin(end)) * radius;
        final back = Offset(math.sin(end), -math.cos(end));
        canvas
          ..drawLine(tip, tip + _rotate(back, 0.5) * 3.6, stroke)
          ..drawLine(tip, tip + _rotate(back, -0.5) * 3.6, stroke);

      case MeshGlyph.radar:
        const origin = Offset(3.4, 8);
        canvas.drawCircle(origin, 1.3, fill);
        for (final r in const [4.6, 8.0]) {
          canvas.drawPath(_arcPath(origin, r, -0.95, 1.9), stroke);
        }

      case MeshGlyph.chevron:
        canvas.drawPath(
          _poly(const [Offset(3.6, 6.0), Offset(8, 10.4), Offset(12.4, 6.0)]),
          stroke,
        );

      case MeshGlyph.close:
        canvas
          ..drawLine(const Offset(4, 4), const Offset(12, 12), stroke)
          ..drawLine(const Offset(12, 4), const Offset(4, 12), stroke);

      case MeshGlyph.warning:
        canvas
          ..drawPath(
            _poly(const [
              Offset(8, 2.4),
              Offset(14.4, 13.2),
              Offset(1.6, 13.2),
            ], close: true),
            stroke,
          )
          ..drawLine(const Offset(8, 6.6), const Offset(8, 9.6), stroke)
          ..drawCircle(const Offset(8, 11.4), 0.75, fill);

      case MeshGlyph.power:
        const center = Offset(8, 8.8);
        canvas
          ..drawPath(
            _arcPath(center, 5.3, -math.pi / 2 + 0.62, math.pi * 2 - 1.24),
            stroke,
          )
          ..drawLine(const Offset(8, 2.0), const Offset(8, 7.4), stroke);

      case MeshGlyph.eye:
        canvas
          ..drawPath(_eyeOutline(), stroke)
          ..drawCircle(const Offset(8, 8), 2.1, stroke);

      case MeshGlyph.eyeOff:
        canvas
          ..drawPath(_eyeOutline(), stroke)
          ..drawCircle(const Offset(8, 8), 2.1, stroke)
          ..drawLine(const Offset(2.6, 13.4), const Offset(13.4, 2.6), stroke);
    }
  }

  /// A polyline through [points].
  static Path _poly(List<Offset> points, {bool close = false}) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    if (close) path.close();
    return path;
  }

  /// The part of a line between two circles of radius [r] — keeps the node
  /// connectors from poking into the node circles.
  static Path _segment(Offset a, Offset b, double r) {
    final d = b - a;
    final len = d.distance;
    if (len <= r * 2) return Path();
    final unit = d / len;
    return _poly([a + unit * (r + 0.7), b - unit * (r + 0.7)]);
  }

  static Offset _rotate(Offset v, double radians) {
    final c = math.cos(radians);
    final s = math.sin(radians);
    return Offset(v.dx * c - v.dy * s, v.dx * s + v.dy * c);
  }

  static Path _arcPath(
    Offset center,
    double radius,
    double start,
    double sweep,
  ) =>
      Path()
        ..addArc(Rect.fromCircle(center: center, radius: radius), start, sweep);

  /// The rear sheet of the copy icon: an L that stops where the front sheet
  /// covers it, so the two strokes never overlap.
  static Path _copyBack() => Path()
    ..moveTo(10.4, 11.6)
    ..lineTo(12.9, 11.6)
    ..quadraticBezierTo(14.4, 11.6, 14.4, 10.1)
    ..lineTo(14.4, 3.1)
    ..quadraticBezierTo(14.4, 1.6, 12.9, 1.6)
    ..lineTo(5.1, 1.6)
    ..quadraticBezierTo(3.6, 1.6, 3.6, 3.1)
    ..lineTo(3.6, 5.6);

  static Path _eyeOutline() => Path()
    ..moveTo(1.4, 8)
    ..quadraticBezierTo(8, 2.0, 14.6, 8)
    ..quadraticBezierTo(8, 14.0, 1.4, 8)
    ..close();

  @override
  bool shouldRepaint(_MeshIconPainter old) =>
      old.glyph != glyph ||
      old.color != color ||
      old.turns != turns ||
      old.strokeWidth != strokeWidth;
}
