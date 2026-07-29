/// `MeshSparkline` — a 1.5px polyline of RTT history over its own fill. No axes.
library;

import 'package:flutter/widgets.dart';

import '../theme/theme.dart';

/// Recent history of one number, drawn small enough to sit in a table row.
///
/// The area under the line is filled with the line's own colour fading to
/// nothing, which is what gives a 20px-tall chart any weight at all.
///
/// Gaps (a probe that got no answer) are `null` and break both the line and the
/// fill rather than interpolating across them, because a missing sample is
/// information.
class MeshSparkline extends StatelessWidget {
  const MeshSparkline({
    required this.values,
    this.width = 96,
    this.height = 20,
    this.color,
    this.showBand = true,
    this.fill = true,
    super.key,
  });

  /// Oldest first. Nulls are gaps.
  final List<double?> values;

  final double width;
  final double height;

  /// Defaults to `signal`.
  final Color? color;

  /// The faint min/max band behind the line.
  final bool showBand;

  /// The gradient under the line. Off for a bare trace.
  final bool fill;

  /// How much of `hairlineHigh` the min/max band gets, per theme.
  ///
  /// The band is the box inset 2px, always: the line touches its own min and
  /// max by definition, so the band is a ground for the trace rather than a
  /// reading, and its whole job is to be felt and not seen. That lands at a
  /// different number per theme. On a dark panel a slightly lighter plate reads
  /// as light falling on the chart, which is the house style. On a white one
  /// the same 18% is a grey card printed on the panel, and at the 18–20px a
  /// table row gives it that card *is* the widget, so it reads as a filled
  /// cell rather than as anything about the data. 7% is as much as light can
  /// take before the tint turns back into a rectangle.
  static double _bandAlpha(FilamentTokens tokens) =>
      tokens.isDark ? 0.18 : 0.07;

  @override
  Widget build(BuildContext context) {
    final tokens = FilamentTheme.tokensOf(context);
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _SparklinePainter(
          values: values,
          line: color ?? tokens.signal,
          band: tokens.hairlineHigh.withValues(alpha: _bandAlpha(tokens)),
          showBand: showBand,
          fill: fill,
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.values,
    required this.line,
    required this.band,
    required this.showBand,
    required this.fill,
  });

  final List<double?> values;
  final Color line;

  /// Already carrying its alpha — see `MeshSparkline._bandAlpha`.
  final Color band;
  final bool showBand;
  final bool fill;

  /// Where the fill starts, right under the line.
  static const double _fillTopAlpha = 0.26;

  @override
  void paint(Canvas canvas, Size size) {
    final present = values.whereType<double>().toList(growable: false);
    if (present.isEmpty) return;

    var min = present.first;
    var max = present.first;
    for (final v in present) {
      if (v < min) min = v;
      if (v > max) max = v;
    }
    // A flat series still needs a band to sit in.
    final span = (max - min).abs() < 1e-9 ? 1.0 : max - min;

    const pad = 2.0;
    final usable = size.height - pad * 2;
    double y(double v) => pad + usable - ((v - min) / span) * usable;
    double x(int i) => values.length == 1
        ? size.width / 2
        : i * size.width / (values.length - 1);

    if (showBand && present.length > 1) {
      canvas.drawRect(
        Rect.fromLTRB(0, y(max), size.width, y(min)),
        // Quieter than it was: with a fill under the line, a heavy band turns
        // the chart into two competing blocks.
        Paint()..color = band,
      );
    }

    final paint = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    // Collected rather than drawn straight into a path, because the fill needs
    // each run of present samples closed to the floor on its own — one path
    // across a gap would fill under the gap too.
    final runs = <List<Offset>>[];
    List<Offset>? run;
    final singletons = <Offset>[];
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v == null) {
        run = null;
        continue;
      }
      final p = Offset(x(i), y(v));
      if (run == null) {
        // A lone sample between two gaps has no segment; remember it as a dot.
        final nextIsGap = i + 1 >= values.length || values[i + 1] == null;
        if (nextIsGap) {
          singletons.add(p);
          continue;
        }
        run = <Offset>[p];
        runs.add(run);
      } else {
        run.add(p);
      }
    }

    if (fill) {
      for (final r in runs) {
        final under = Path()..moveTo(r.first.dx, size.height);
        var top = size.height;
        for (final p in r) {
          under.lineTo(p.dx, p.dy);
          if (p.dy < top) top = p.dy;
        }
        under
          ..lineTo(r.last.dx, size.height)
          ..close();
        canvas.drawPath(
          under,
          Paint()
            ..isAntiAlias = true
            // Each run fades from its own high point rather than from the
            // series': a low stretch after a gap would otherwise sit in the
            // transparent tail of a shared gradient and read as unfilled.
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                line.withValues(alpha: _fillTopAlpha),
                line.withValues(alpha: 0),
              ],
            ).createShader(Rect.fromLTRB(0, top, size.width, size.height)),
        );
      }
    }

    final path = Path();
    for (final r in runs) {
      path.moveTo(r.first.dx, r.first.dy);
      for (var i = 1; i < r.length; i++) {
        path.lineTo(r[i].dx, r[i].dy);
      }
    }
    canvas.drawPath(path, paint);
    for (final p in singletons) {
      canvas.drawCircle(
        p,
        1.1,
        Paint()
          ..color = line
          ..isAntiAlias = true,
      );
    }
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.line != line ||
      old.band != band ||
      old.showBand != showBand ||
      old.fill != fill ||
      !_same(old.values, values);

  static bool _same(List<double?> a, List<double?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
