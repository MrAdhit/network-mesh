/// `MeshPathTriad` — the signature mark: direct, cloudflare, tailscale, always
/// in that order, wherever a peer appears.
library;

import 'package:flutter/widgets.dart';

import '../theme/theme.dart';
import 'motion.dart';
import 'tooltip.dart';

/// What one bar of the triad is saying.
enum MeshPathState {
  /// Full height, `signal`, glow. The path carrying the traffic.
  winning,

  /// 60% height, `signalDim`.
  up,

  /// 60% height, `caution`. Loss at or above 5%.
  lossy,

  /// 30% height, outlined `alarm`.
  down,

  /// 30% height, `hairlineHigh`. Never configured, or never probed.
  unknown;

  /// Maps a path report onto a bar.
  ///
  /// [lossPct] is the daemon's `loss_pct`, already 0..100.
  static MeshPathState from({
    required bool up,
    required bool winning,
    double lossPct = 0,
    bool configured = true,
  }) {
    if (!configured) return MeshPathState.unknown;
    if (!up) return MeshPathState.down;
    if (lossPct >= lossyThreshold) return MeshPathState.lossy;
    return winning ? MeshPathState.winning : MeshPathState.up;
  }

  /// DESIGN.md: lossy is loss >= 5%.
  static const double lossyThreshold = 5;

  /// The word the tooltip uses.
  String get label => switch (this) {
    MeshPathState.winning => 'Winning',
    MeshPathState.up => 'Up',
    MeshPathState.lossy => 'Lossy',
    MeshPathState.down => 'Down',
    MeshPathState.unknown => 'Not configured',
  };
}

/// Three short vertical bars: direct, cloudflare, tailscale.
///
/// Bars are 3x12 with a 2px gap at rest. Pass a larger [height] for the rail
/// indicator and the Overview headline, which reuse the same mark.
///
/// Bars spring between heights and crossfade between state colours. When the
/// winning slot moves, the triad runs the handoff pulse: the glow leaves the
/// old bar while a slightly over-bright one lands on the new. Failover is the
/// product's whole point, and this is the one moment allowed to draw the eye.
class MeshPathTriad extends StatefulWidget {
  const MeshPathTriad({
    required this.direct,
    required this.cloudflare,
    required this.tailscale,
    this.height = FilamentMetrics.triadBarHeight,
    this.barWidth = FilamentMetrics.triadBarWidth,
    this.gap = FilamentMetrics.triadGap,
    this.showTooltip = true,
    super.key,
  });

  /// All three unknown. The resting state before the daemon answers.
  const MeshPathTriad.unknown({
    double height = FilamentMetrics.triadBarHeight,
    double barWidth = FilamentMetrics.triadBarWidth,
    double gap = FilamentMetrics.triadGap,
    bool showTooltip = true,
    Key? key,
  }) : this(
         direct: MeshPathState.unknown,
         cloudflare: MeshPathState.unknown,
         tailscale: MeshPathState.unknown,
         height: height,
         barWidth: barWidth,
         gap: gap,
         showTooltip: showTooltip,
         key: key,
       );

  final MeshPathState direct;
  final MeshPathState cloudflare;
  final MeshPathState tailscale;
  final double height;
  final double barWidth;
  final double gap;

  /// Hovering names the paths. Off for decorative uses, like the app mark.
  final bool showTooltip;

  List<MeshPathState> get states => [direct, cloudflare, tailscale];

  /// Which bar is carrying the traffic, or -1.
  int get winner => states.indexOf(MeshPathState.winning);

  static const List<String> _names = ['Direct', 'Cloudflare', 'Tailscale'];

  String get _tooltip {
    final s = states;
    return [
      for (var i = 0; i < 3; i++) '${_names[i]}: ${s[i].label}',
    ].join('\n');
  }

  @override
  State<MeshPathTriad> createState() => _MeshPathTriadState();
}

class _MeshPathTriadState extends State<MeshPathTriad>
    with TickerProviderStateMixin {
  /// One spring per bar, so a triad where two bars move at once does not have
  /// to move them in lockstep.
  late final List<MeshSpring> _heights = [
    for (final state in widget.states)
      MeshSpring(vsync: this, value: _fractionOf(state)),
  ];

  /// The colour/shape crossfade. Colours ease; only heights spring.
  late final AnimationController _fade = AnimationController(vsync: this);

  /// The handoff. Runs once per winner change and is never retriggered by a
  /// poll that reports the same thing.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: FilamentMotion.pulse,
  );

  List<_BarLook>? _from;
  List<_BarLook>? _to;
  int _pulseFrom = -1;
  int _pulseTo = -1;

  bool get _reduced => FilamentMotion.reducedIn(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tokens = FilamentTheme.tokensOf(context);
    for (final spring in _heights) {
      spring.reduced = _reduced;
    }
    final next = _looksFor(widget.states, tokens);
    if (_to == null) {
      // Arrival: the mark is simply there. Nothing has changed yet.
      _from = next;
      _to = next;
      return;
    }
    _crossfadeTo(next);
  }

  @override
  void didUpdateWidget(MeshPathTriad old) {
    super.didUpdateWidget(old);
    final states = widget.states;
    final tokens = FilamentTheme.tokensOf(context);

    for (var i = 0; i < states.length; i++) {
      _heights[i].animateTo(_fractionOf(states[i]));
    }
    _crossfadeTo(_looksFor(states, tokens));

    // The handoff, detected the only place it can be: the config we were
    // handed last against the one we have now.
    final was = old.winner;
    final now = widget.winner;
    if (was != now && now >= 0 && !_reduced) {
      _pulseFrom = was;
      _pulseTo = now;
      _pulse.forward(from: 0);
    }
  }

  /// Retargets the colour crossfade from whatever is on screen right now, so a
  /// second change mid-fade does not snap back to the last discrete state.
  void _crossfadeTo(List<_BarLook> next) {
    if (_to != null && _sameLooks(_to!, next)) return;
    _from = _currentLooks();
    _to = next;
    final tempo = FilamentMotion.drift(context);
    _fade
      ..duration = tempo.duration
      ..forward(from: 0);
  }

  List<_BarLook> _currentLooks() {
    final from = _from!;
    final to = _to!;
    final t = _fade.isAnimating
        ? FilamentMotion.drift(context).curve.transform(_fade.value)
        : 1.0;
    return [
      for (var i = 0; i < to.length; i++) _BarLook.lerp(from[i], to[i], t),
    ];
  }

  @override
  void dispose() {
    for (final spring in _heights) {
      spring.dispose();
    }
    _fade.dispose();
    _pulse.dispose();
    super.dispose();
  }

  static double _fractionOf(MeshPathState state) => switch (state) {
    MeshPathState.winning => 1,
    MeshPathState.up || MeshPathState.lossy => 0.6,
    MeshPathState.down || MeshPathState.unknown => 0.3,
  };

  static List<_BarLook> _looksFor(
    List<MeshPathState> states,
    FilamentTokens t,
  ) => [
    for (final state in states)
      switch (state) {
        MeshPathState.winning => _BarLook(color: t.signal, glow: 1),
        MeshPathState.up => _BarLook(color: t.signalDim),
        MeshPathState.lossy => _BarLook(color: t.caution),
        // A down bar is hollow: the absence of fill is the point.
        MeshPathState.down => _BarLook(color: t.alarm, fill: 0, stroke: 1),
        MeshPathState.unknown => _BarLook(color: t.hairlineHigh),
      },
  ];

  static bool _sameLooks(List<_BarLook> a, List<_BarLook> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final size = Size(widget.barWidth * 3 + widget.gap * 2, widget.height);
    final curve = FilamentMotion.drift(context).curve;
    final tokens = FilamentTheme.tokensOf(context);
    // The bloom, scaled to the mark: a 3px bar under the full blur is a
    // smudge; the rail's 16px triad and the hero's larger one earn more of it.
    final bloomBlur =
        tokens.bloomBlur * (0.45 + widget.height / 60).clamp(0.45, 1.0);

    final mark = AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        ..._heights.map((s) => s.animation),
        _fade,
        _pulse,
      ]),
      builder: (context, _) {
        final t = curve.transform(_fade.value);
        final from = _from!;
        final to = _to!;
        return CustomPaint(
          size: size,
          painter: _TriadPainter(
            bars: [
              for (var i = 0; i < to.length; i++)
                _BarLook.lerp(
                  from[i],
                  to[i],
                  t,
                ).withGlow(_glowAt(i), _blurAt(i)),
            ],
            fractions: [
              for (final spring in _heights) spring.value.clamp(0.05, 1.0),
            ],
            barWidth: widget.barWidth,
            gap: widget.gap,
            bloomOpacity: tokens.bloomOpacity,
            bloomBlur: bloomBlur,
          ),
        );
      },
    );

    final sized = SizedBox(width: size.width, height: size.height, child: mark);
    if (!widget.showTooltip) return sized;
    return MeshTooltip(message: widget._tooltip, child: sized);
  }

  /// The pulse envelope: 1 at both ends, [FilamentMotion.pulseOvershoot] over
  /// at the middle. Only the bar being handed to swells.
  double _glowAt(int index) {
    if (!_pulse.isAnimating) return 1;
    final p = _pulse.value;
    if (index == _pulseTo) return 1 + FilamentMotion.pulseOvershoot * _hump(p);
    // The glow leaves the old bar faster than its colour does.
    if (index == _pulseFrom) return (1 - p * 1.6).clamp(0.0, 1.0);
    return 1;
  }

  double _blurAt(int index) {
    if (!_pulse.isAnimating || index != _pulseTo) return 1;
    return 1 + 0.75 * _hump(_pulse.value);
  }

  static double _hump(double p) => 4 * p * (1 - p);
}

/// Everything about one bar except how tall it is: colours and shape lerp,
/// height springs.
@immutable
class _BarLook {
  const _BarLook({
    required this.color,
    this.fill = 1,
    this.stroke = 0,
    this.glow = 0,
    this.blur = 1,
  });

  final Color color;

  /// 1 solid, 0 hollow.
  final double fill;

  /// 1 outlined, 0 not. The counterpart of [fill] while a bar goes down.
  final double stroke;

  /// Multiplier on the system's one glow.
  final double glow;

  /// Multiplier on the glow's blur, for the landing swell.
  final double blur;

  _BarLook withGlow(double factor, double blurFactor) => _BarLook(
    color: color,
    fill: fill,
    stroke: stroke,
    glow: glow * factor,
    blur: blur * blurFactor,
  );

  static _BarLook lerp(_BarLook a, _BarLook b, double t) => _BarLook(
    color: Color.lerp(a.color, b.color, t)!,
    fill: a.fill + (b.fill - a.fill) * t,
    stroke: a.stroke + (b.stroke - a.stroke) * t,
    glow: a.glow + (b.glow - a.glow) * t,
    blur: a.blur + (b.blur - a.blur) * t,
  );

  @override
  bool operator ==(Object other) =>
      other is _BarLook &&
      other.color == color &&
      other.fill == fill &&
      other.stroke == stroke &&
      other.glow == glow &&
      other.blur == blur;

  @override
  int get hashCode => Object.hash(color, fill, stroke, glow, blur);
}

class _TriadPainter extends CustomPainter {
  _TriadPainter({
    required this.bars,
    required this.fractions,
    required this.barWidth,
    required this.gap,
    required this.bloomOpacity,
    required this.bloomBlur,
  });

  final List<_BarLook> bars;
  final List<double> fractions;
  final double barWidth;
  final double gap;

  /// The `bloom` token, already resolved for the theme and this mark's size.
  final double bloomOpacity;
  final double bloomBlur;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < bars.length; i++) {
      _bar(canvas, size, i * (barWidth + gap), bars[i], fractions[i]);
    }
  }

  void _bar(
    Canvas canvas,
    Size size,
    double left,
    _BarLook look,
    double fraction,
  ) {
    final h = size.height * fraction;
    final rect = Rect.fromLTWH(left, size.height - h, barWidth, h);
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(barWidth / 2));

    if (look.glow > 0.001) {
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = look.color.withValues(
            alpha: (bloomOpacity * look.glow).clamp(0.0, 1.0),
          )
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            bloomBlur * look.blur,
          ),
      );
    }

    if (look.fill > 0.001) {
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = look.color.withValues(alpha: look.color.a * look.fill)
          ..isAntiAlias = true,
      );
    }

    if (look.stroke > 0.001) {
      canvas.drawRRect(
        rrect.deflate(0.4),
        Paint()
          ..color = look.color.withValues(alpha: look.color.a * look.stroke)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.9
          ..isAntiAlias = true,
      );
    }
  }

  @override
  bool shouldRepaint(_TriadPainter old) =>
      old.barWidth != barWidth ||
      old.gap != gap ||
      old.bloomOpacity != bloomOpacity ||
      old.bloomBlur != bloomBlur ||
      !_same(old.bars, bars) ||
      !_sameNumbers(old.fractions, fractions);

  static bool _same(List<_BarLook> a, List<_BarLook> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameNumbers(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
