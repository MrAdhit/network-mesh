/// Number and time formatting, in the CLI's voice: terse, lowercase, honest.
///
/// The formatters are pure and return the number without its unit, because
/// DESIGN.md sets units in `textFaint` one size below the number. [MeshMeasure]
/// is the rendering half of that rule — it is here rather than in the kit so
/// the split value and its presentation stay in one file. [MeshLive] is the
/// other half of how a value reaches the screen: it crossfades when the number
/// changes under the reader.
library;

import 'package:flutter/widgets.dart';

import '../theme/theme.dart';

/// A number and its unit, kept apart so they can be styled apart.
typedef MeasureParts = ({String value, String unit});

// ---- latency ----

/// Round-trip times, at meshctl's precision: two decimals under 10ms, one
/// under 100, none above. `null` becomes an em-less dash.
String formatMs(double? ms) {
  if (ms == null) return '—';
  if (!ms.isFinite) return '—';
  final v = ms.abs();
  if (v < 10) return ms.toStringAsFixed(2);
  if (v < 100) return ms.toStringAsFixed(1);
  return ms.toStringAsFixed(0);
}

/// [formatMs] split from its unit. The unit is empty when there is no value,
/// so a missing RTT renders as a bare dash rather than "— ms".
MeasureParts msParts(double? ms) =>
    (value: formatMs(ms), unit: ms == null || !ms.isFinite ? '' : 'ms');

// ---- percentages ----

/// Loss and other percentages. The daemon already reports 0..100, so this does
/// not rescale; it only trims. Whole numbers lose their decimal.
String formatPercent(double? pct, {int decimals = 1}) {
  if (pct == null || !pct.isFinite) return '—';
  if (pct == pct.roundToDouble()) return pct.toStringAsFixed(0);
  return pct.toStringAsFixed(decimals);
}

/// [formatPercent] split from its sign.
MeasureParts percentParts(double? pct, {int decimals = 1}) => (
  value: formatPercent(pct, decimals: decimals),
  unit: pct == null || !pct.isFinite ? '' : '%',
);

// ---- counts ----

/// A whole count, split the way [msParts] splits a latency: no unit, because
/// the label above the number already says what is being counted.
///
/// The rounding is what lets an integer roll through [MeshTickingMeasure] — the
/// needle tweens through the fractions between two counts and this renders each
/// frame as the count it has reached.
MeasureParts countParts(double? n) =>
    (value: n == null || !n.isFinite ? '—' : n.round().toString(), unit: '');

// ---- durations ----

/// Uptime as `3d 4h 12m`: at most three units, starting at the largest
/// non-zero one, trailing zeros dropped. Under a minute it reads in seconds.
String formatUptime(Duration d) {
  if (d.isNegative) return '0s';
  final days = d.inDays;
  final hours = d.inHours % 24;
  final minutes = d.inMinutes % 60;
  final seconds = d.inSeconds % 60;

  final parts = <String>[];
  if (days > 0) {
    parts.addAll(['${days}d', '${hours}h', '${minutes}m']);
  } else if (hours > 0) {
    parts.addAll(['${hours}h', '${minutes}m', '${seconds}s']);
  } else if (minutes > 0) {
    parts.addAll(['${minutes}m', '${seconds}s']);
  } else {
    parts.add('${seconds}s');
  }
  // Drop trailing zero units so "2h 0m 0s" reads "2h".
  while (parts.length > 1 && parts.last.startsWith('0')) {
    parts.removeLast();
  }
  return parts.join(' ');
}

/// The daemon reports uptime in whole seconds.
String formatUptimeSecs(int secs) => formatUptime(Duration(seconds: secs));

/// Short form for spans that are not uptime: `12s`, `4m`, `2h`, `3d`.
String formatSpan(Duration d) {
  final s = d.abs();
  if (s.inSeconds < 60) return '${s.inSeconds}s';
  if (s.inMinutes < 60) return '${s.inMinutes}m';
  if (s.inHours < 24) return '${s.inHours}h';
  return '${s.inDays}d';
}

// ---- timestamps ----

/// Relative timestamps: `just now`, `12s ago`, `4m ago`, `3d ago`. Beyond a
/// month it gives an absolute `2026-07-28` instead, because "47d ago" is not
/// something anyone can read at a glance.
String formatAgo(DateTime? when, {DateTime? now}) {
  if (when == null) return 'never';
  final clock = now ?? DateTime.now();
  final delta = clock.difference(when);
  if (delta.isNegative) {
    // Clock skew, or an expiry in the future.
    return 'in ${formatSpan(delta)}';
  }
  if (delta.inSeconds < 5) return 'just now';
  if (delta.inDays > 30) return formatDate(when);
  return '${formatSpan(delta)} ago';
}

/// How long until [when], for expiries: `in 4h`, `expired`.
String formatUntil(DateTime? when, {DateTime? now}) {
  if (when == null) return 'never';
  final delta = when.difference(now ?? DateTime.now());
  if (delta.isNegative) return 'expired';
  if (delta.inSeconds < 60) return 'in ${delta.inSeconds}s';
  return 'in ${formatSpan(delta)}';
}

/// `2026-07-28`, local time.
String formatDate(DateTime when) {
  final d = when.toLocal();
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// `2026-07-28 14:03`, local time.
String formatDateTime(DateTime when) {
  final d = when.toLocal();
  return '${formatDate(d)} '
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';
}

// ---- words ----

/// `1 peer` / `3 peers`. Pass [plural] when adding an `s` is wrong.
String countOf(int n, String singular, [String? plural]) =>
    '$n ${n == 1 ? singular : (plural ?? '${singular}s')}';

/// Shortens an id for a table cell, keeping both ends: `a1b2c3…9f8e`.
String shortId(String id, {int head = 6, int tail = 4}) =>
    id.length <= head + tail + 1
    ? id
    : '${id.substring(0, head)}…'
          '${id.substring(id.length - tail)}';

// ---- rendering ----

/// A number with its unit set in `textFaint`, one size down: `12.4 ms`.
///
/// Pass the number's style; the unit's style is derived from it.
class MeshMeasure extends StatelessWidget {
  const MeshMeasure(
    this.parts, {
    this.style,
    this.color,
    this.gap = 3,
    super.key,
  });

  /// A latency, percentage or other split value.
  final MeasureParts parts;

  /// Defaults to the 12px mono data style.
  final TextStyle? style;

  /// Overrides the number's colour only; the unit stays faint.
  final Color? color;

  final double gap;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final numberStyle = (style ?? theme.type.mono).copyWith(color: color);
    if (parts.unit.isEmpty) {
      return Text(parts.value, style: numberStyle);
    }
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: parts.value, style: numberStyle),
          TextSpan(
            text: '${' ' * (gap ~/ 3 + 1)}${parts.unit}',
            style: theme.type.unitFor(numberStyle),
          ),
        ],
      ),
    );
  }
}

/// A [MeshMeasure] whose number rolls to its new reading instead of swapping.
///
/// The instrument-needle rule: the hero RTT ticks like a meter, it does not
/// blink. The value is tweened over 300ms and rendered through [format] on
/// every frame, so the digits roll through the intermediate readings in the
/// formatter's own precision. Use it for numbers a reader watches; [MeshLive]
/// stays the right answer for anything that is not a number.
///
/// A reading that arrives from or falls to null snaps — there is no path
/// between a number and a dash worth travelling.
class MeshTickingMeasure extends StatefulWidget {
  const MeshTickingMeasure({
    required this.value,
    required this.format,
    this.style,
    this.color,
    this.gap = 3,
    super.key,
  });

  /// The reading itself, not its text. Null renders whatever [format] makes of
  /// null — a dash, by convention.
  final double? value;

  /// The formatter this measure renders through: [msParts], [percentParts], or
  /// any other splitter of a number from its unit.
  final MeasureParts Function(double?) format;

  final TextStyle? style;
  final Color? color;
  final double gap;

  @override
  State<MeshTickingMeasure> createState() => _MeshTickingMeasureState();
}

class _MeshTickingMeasureState extends State<MeshTickingMeasure>
    with SingleTickerProviderStateMixin {
  late final AnimationController _roll = AnimationController(vsync: this);
  late double? _from = widget.value;
  late double? _to = widget.value;

  static bool _rollable(double? v) => v != null && v.isFinite;

  @override
  void didUpdateWidget(MeshTickingMeasure old) {
    super.didUpdateWidget(old);
    if (widget.value == old.value) return;
    if (!_rollable(widget.value) || !_rollable(_displayed)) {
      _roll.stop();
      _from = _to = widget.value;
      return;
    }
    final tempo = FilamentMotion.tick(context);
    _from = _displayed;
    _to = widget.value;
    _roll
      ..duration = tempo.duration
      ..forward(from: 0);
  }

  /// Where the needle is right now.
  double? get _displayed {
    final from = _from;
    final to = _to;
    if (from == null || to == null || !_roll.isAnimating) return to;
    final t = FilamentMotion.tick(context).curve.transform(_roll.value);
    return from + (to - from) * t;
  }

  @override
  void dispose() {
    _roll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _roll,
      builder: (context, _) => MeshMeasure(
        widget.format(_displayed),
        style: widget.style,
        color: widget.color,
        gap: widget.gap,
      ),
    );
  }
}

/// Crossfades its child whenever [value] changes. Live numbers change under
/// the reader every couple of seconds; DESIGN.md says they replace themselves
/// rather than blink.
///
/// [value] is the identity of the current reading, not the widget: equal
/// values do not animate at all, so a poll that returns the same number costs
/// nothing.
class MeshLive extends StatelessWidget {
  const MeshLive({
    required this.value,
    required this.child,
    this.alignment = Alignment.centerLeft,
    super.key,
  });

  final Object? value;
  final Widget child;

  /// How the outgoing and incoming readings are stacked while they cross.
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    final drift = FilamentMotion.drift(context);
    return AnimatedSwitcher(
      duration: drift.duration,
      switchInCurve: drift.curve,
      switchOutCurve: drift.curve,
      layoutBuilder: (current, previous) =>
          Stack(alignment: alignment, children: [...previous, ?current]),
      child: KeyedSubtree(key: ValueKey<Object?>(value), child: child),
    );
  }
}
