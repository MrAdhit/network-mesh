/// Filament's colour, shape, space and motion tokens.
///
/// Widget code never writes a literal colour, radius or duration. It reads one
/// of these. `FilamentTokens` carries the palette (dark and light are the same
/// class with different constructors, so a widget can hold one and not care);
/// the rest are const namespaces because they do not change with brightness.
library;

import 'package:flutter/physics.dart'
    show SpringDescription, SpringSimulation, Tolerance;
import 'package:flutter/widgets.dart';

/// One resolved palette. See DESIGN.md for what each token means.
///
/// The two constructors are the whole theme system: `FilamentTokens.dark()` is
/// the primary theme, `FilamentTokens.light()` its first-class sibling.
class FilamentTokens {
  const FilamentTokens._({
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surfaceHigh,
    required this.hairline,
    required this.hairlineHigh,
    required this.text,
    required this.textDim,
    required this.textFaint,
    required this.signal,
    required this.signalDim,
    required this.caution,
    required this.alarm,
    required this.link,
  });

  /// The dark palette. Primary theme.
  const FilamentTokens.dark()
    : this._(
        brightness: Brightness.dark,
        bg: const Color(0xFF0B0E11),
        surface: const Color(0xFF11151A),
        surfaceHigh: const Color(0xFF171C23),
        hairline: const Color(0xFF222A33),
        hairlineHigh: const Color(0xFF2E3844),
        text: const Color(0xFFE6EBF0),
        textDim: const Color(0xFF98A5B3),
        textFaint: const Color(0xFF5C6B7A),
        signal: const Color(0xFF46C98C),
        signalDim: const Color(0xFF2E6B4F),
        caution: const Color(0xFFD9A544),
        alarm: const Color(0xFFD96552),
        link: const Color(0xFF6AA1D8),
      );

  /// The light palette.
  const FilamentTokens.light()
    : this._(
        brightness: Brightness.light,
        bg: const Color(0xFFF2F4F7),
        surface: const Color(0xFFFBFCFD),
        surfaceHigh: const Color(0xFFEDF0F4),
        hairline: const Color(0xFFD9E0E7),
        hairlineHigh: const Color(0xFFB9C4CF),
        text: const Color(0xFF1A222B),
        textDim: const Color(0xFF5A6875),
        textFaint: const Color(0xFF93A0AC),
        signal: const Color(0xFF1F9E68),
        signalDim: const Color(0xFF8FC9AE),
        caution: const Color(0xFFB07E1E),
        alarm: const Color(0xFFC24A37),
        link: const Color(0xFF3B76B4),
      );

  /// Picks the palette for a brightness.
  factory FilamentTokens.of(Brightness brightness) =>
      brightness == Brightness.dark
      ? const FilamentTokens.dark()
      : const FilamentTokens.light();

  final Brightness brightness;

  /// Window background.
  final Color bg;

  /// Panels, rail.
  final Color surface;

  /// Hover, pressed, input fills.
  final Color surfaceHigh;

  /// Default borders, dividers.
  final Color hairline;

  /// Focused/hovered borders.
  final Color hairlineHigh;

  /// Primary text.
  final Color text;

  /// Labels, secondary text.
  final Color textDim;

  /// Disabled, units, placeholders.
  final Color textFaint;

  /// Up, winning path, primary action.
  final Color signal;

  /// Up but not winning.
  final Color signalDim;

  /// Degraded, lossy, expiring.
  final Color caution;

  /// Down, errors, destructive.
  final Color alarm;

  /// Links, relay/info accents.
  final Color link;

  bool get isDark => brightness == Brightness.dark;

  // ---- depth: surfaces are lit from above ----
  //
  // Four tokens, one per layer of the effect. A panel wears all four: the
  // [panelFill] gradient breathes lighter at the top, [edgeLight] draws the 1px
  // inner top edge, [shade] puts the ambient shadow underneath, and the window
  // behind it carries [haze]. [bloom] is the fifth thing, and the only one that
  // is coloured: live indicators glow in their own colour.

  /// The 1px inner top edge of a panel: white at 6% (90% in light).
  ///
  /// Not `text` at low alpha — the edge is a reflection, and a reflection is
  /// the colour of the light, not of the thing.
  Color get edgeLight => _white.withValues(alpha: isDark ? 0.06 : 0.9);

  /// How strong the window's phosphor haze is: `signal` at 4% (3% in light).
  double get hazeOpacity => isDark ? 0.04 : 0.03;

  /// The window-background aurora: a radial wash of `signal`, anchored
  /// top-left, fading out well before the far corner.
  ///
  /// Painted over `bg`. If you can point at it in a screenshot it is too
  /// strong — it exists so the background is not a flat sheet, nothing more.
  Gradient get haze => RadialGradient(
    center: const Alignment(-1, -1),
    radius: 1.35,
    colors: <Color>[
      signal.withValues(alpha: hazeOpacity),
      // Fading to transparent *signal* rather than to a transparent black
      // keeps the midpoints from silting up grey.
      signal.withValues(alpha: 0),
    ],
  );

  /// The ambient shadow under a panel. Black at 35%, blur 24, 8 down; in light,
  /// the ink colour at 10%, blur 20, 6 down.
  List<BoxShadow> get shade => <BoxShadow>[
    BoxShadow(
      color: isDark
          ? _black.withValues(alpha: 0.35)
          : const Color(0xFF1A222B).withValues(alpha: 0.1),
      blurRadius: isDark ? 24 : 20,
      offset: Offset(0, isDark ? 8 : 6),
    ),
  ];

  /// The alpha a bloom starts at: 25% dark, 20% light.
  double get bloomOpacity => isDark ? 0.25 : 0.2;

  /// The blur a bloom starts at: 10 dark, 8 light.
  double get bloomBlur => isDark ? 10 : 8;

  /// The glow a live thing casts into its surroundings, in its own colour.
  ///
  /// [intensity] scales the alpha and [blurScale] the radius — the handoff
  /// pulse swells both, a small dot wants less of each. It blooms; it never
  /// flares. Returns nothing at all once the intensity has faded out, so a
  /// dead glow costs no layer.
  List<BoxShadow> bloom(
    Color owner, {
    double intensity = 1,
    double blurScale = 1,
    double spread = 0,
  }) {
    final a = (bloomOpacity * intensity).clamp(0.0, 1.0);
    if (a <= 0.002) return const <BoxShadow>[];
    return <BoxShadow>[
      BoxShadow(
        color: owner.withValues(alpha: a),
        blurRadius: bloomBlur * blurScale,
        spreadRadius: spread,
      ),
    ];
  }

  /// A panel's fill: lighter where the light lands, `surface` where it does
  /// not. Quiet enough that you only notice it when it is gone.
  ///
  /// Dark leans the top toward `surfaceHigh`, which is the lighter token there.
  /// In light `surfaceHigh` is the *darker* one, so the same instruction would
  /// light the panel from below; the light theme shades the bottom instead and
  /// the read is the same.
  Gradient get panelFill => LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: isDark
        ? <Color>[Color.lerp(surface, surfaceHigh, 0.85)!, surface]
        : <Color>[surface, Color.lerp(surface, surfaceHigh, 0.55)!],
  );

  static const Color _white = Color(0xFFFFFFFF);
  static const Color _black = Color(0xFF000000);

  /// Nudges a fill toward the foreground for hover, away from it for press.
  ///
  /// "Hover brightens fill, press darkens" is stated for the dark theme; in
  /// light the same intent means the opposite direction, so this works off
  /// brightness rather than hardcoding lighter/darker.
  Color hovered(Color base) => _shift(base, isDark ? 0.07 : -0.045);

  /// The pressed counterpart of [hovered].
  Color pressed(Color base) => _shift(base, isDark ? -0.05 : -0.09);

  /// Same colour at a different alpha. Used for glows, scrims and bands.
  static Color alpha(Color c, double a) => c.withValues(alpha: a);

  static Color _shift(Color c, double amount) {
    final target = amount >= 0 ? 1.0 : 0.0;
    final t = amount.abs();
    double mix(double channel) => channel + (target - channel) * t;
    return Color.from(
      alpha: c.a,
      red: mix(c.r),
      green: mix(c.g),
      blue: mix(c.b),
    );
  }
}

/// The 4px spacing grid.
abstract final class FilamentSpace {
  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x5 = 20;
  static const double x6 = 24;
  static const double x8 = 32;

  /// Padding inside a panel.
  static const double panel = 20;

  /// Gap between panels.
  static const double gap = 16;
}

/// Corner radii. Panels 10, controls 6, pills and dots 999.
abstract final class FilamentRadius {
  static const double panel = 10;
  static const double control = 6;
  static const double pill = 999;
}

/// Fixed sizes the layout depends on.
abstract final class FilamentMetrics {
  static const double railWidth = 220;
  static const double railCollapsedWidth = 72;

  /// Content column max width. The column is centred in the space right of the
  /// rail: the app composes like a page, it does not hug a corner of a void.
  static const double contentMaxWidth = 960;

  /// Every control in the kit is this tall.
  static const double controlHeight = 28;

  static const double hairline = 1;
  static const double focusRing = 1.5;
  static const double focusRingOffset = 1;

  /// Focus ring opacity: 1.5px `signal` at 40%.
  static const double focusRingOpacity = 0.4;

  /// Path triad bars: 3x12 at rest, 2px gap.
  static const double triadBarWidth = 3;
  static const double triadBarHeight = 12;
  static const double triadGap = 2;
}

/// How long a move takes and what shape it travels in.
///
/// Widgets never write a duration or a curve; they ask [FilamentMotion] for a
/// tempo and spread it into whatever they are driving.
@immutable
class FilamentTempo {
  const FilamentTempo({required this.duration, required this.curve});

  final Duration duration;
  final Curve curve;

  /// This tempo's shape over someone else's timeline — a route animation, say.
  /// Cheaper and leak-free next to a `CurvedAnimation`, which owns a listener.
  Animation<double> drive(Animation<double> parent) =>
      parent.drive(CurveTween(curve: curve));

  /// The same tempo over a slice of a longer timeline: use when one controller
  /// runs two things at different lengths (a dialog's backdrop and its panel).
  Animation<double> driveInterval(Animation<double> parent, Duration within) {
    final span = within.inMicroseconds;
    if (span <= 0 || duration.inMicroseconds >= span) return drive(parent);
    return parent.drive(
      CurveTween(
        curve: Interval(0, duration.inMicroseconds / span, curve: curve),
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FilamentTempo &&
      other.duration == duration &&
      other.curve == curve;

  @override
  int get hashCode => Object.hash(duration, curve);
}

/// Signal travels. Three tempos, defined here and nowhere else.
///
/// - **touch** — 120ms ease-out: hover fills, press states, focus rings.
/// - **drift** — 240ms emphasized decelerate: screen changes, panel fades,
///   colour crossfades, anything that travels without being grabbed.
/// - **settle** — a spring (stiffness 550, damping ratio 0.85): the rail spark,
///   dialogs, toasts, chevrons, triad bars, row expansion.
///
/// Every context-taking accessor already answers reduced motion — when the
/// platform asks for it every tempo collapses to a 90ms linear crossfade, so
/// call sites never test the flag themselves.
abstract final class FilamentMotion {
  // ---- the three tempos, unresolved ----

  /// 120ms ease-out. Prefer [touch], which honours reduced motion.
  static const FilamentTempo touchTempo = FilamentTempo(
    duration: Duration(milliseconds: 120),
    curve: Cubic(0.2, 0, 0, 1),
  );

  /// 240ms emphasized decelerate. Prefer [drift].
  static const FilamentTempo driftTempo = FilamentTempo(
    duration: Duration(milliseconds: 240),
    curve: Cubic(0.05, 0.7, 0.1, 1),
  );

  /// The settle spring itself, for [AnimationController.animateWith]. The
  /// retargetable form lives in `kit/motion.dart` as `MeshSpring`.
  static final SpringDescription settleSpring =
      SpringDescription.withDampingRatio(mass: 1, stiffness: 550, ratio: 0.85);

  /// [settleSpring] flattened into a curve, for the places that can only take
  /// a duration and a curve (route transitions, `AnimatedRotation`). Same
  /// shape, minus the mid-flight retargeting. Prefer [settle].
  static final FilamentTempo settleTempo = FilamentTempo(
    duration: _settleSpan,
    curve: _SpringCurve(settleSpring, _settleSpan),
  );

  /// Instrument needles: a number rolls to its new value over 300ms.
  static const FilamentTempo tickTempo = FilamentTempo(
    duration: Duration(milliseconds: 300),
    curve: Cubic(0.05, 0.7, 0.1, 1),
  );

  /// Leaving is faster than arriving and does not spring: dialogs dismiss and
  /// toasts drop on this.
  static const FilamentTempo dismissTempo = FilamentTempo(
    duration: Duration(milliseconds: 150),
    curve: Cubic(0.4, 0, 1, 1),
  );

  /// What every tempo becomes when the platform asks for reduced motion.
  static const FilamentTempo reducedTempo = FilamentTempo(
    duration: Duration(milliseconds: 90),
    curve: Curves.linear,
  );

  // ---- resolved against the platform ----

  /// The one place the reduced-motion flag is read.
  static bool reducedIn(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  static FilamentTempo touch(BuildContext context) =>
      reducedIn(context) ? reducedTempo : touchTempo;

  static FilamentTempo drift(BuildContext context) =>
      reducedIn(context) ? reducedTempo : driftTempo;

  static FilamentTempo settle(BuildContext context) =>
      reducedIn(context) ? reducedTempo : settleTempo;

  static FilamentTempo tick(BuildContext context) =>
      reducedIn(context) ? reducedTempo : tickTempo;

  static FilamentTempo dismiss(BuildContext context) =>
      reducedIn(context) ? reducedTempo : dismissTempo;

  // ---- distances ----

  /// Slide distance that accompanies a fade.
  static const double slide = 8;

  /// Screens arrive from this far away, in the direction of travel.
  static const double screenSlide = 12;

  /// Panels arrive top to bottom, this far apart. Arrival happens once; a poll
  /// or a rebuild never replays it.
  static const Duration stagger = Duration(milliseconds: 30);

  /// Toasts spring up this far.
  static const double toastRise = 12;

  /// A pressed control scales to this. Transform only, never layout.
  static const double pressScale = 0.98;

  /// A dialog panel scales in from this.
  static const double dialogScale = 0.96;

  /// The handoff pulse: the one moment allowed to draw the eye.
  static const Duration pulse = Duration(milliseconds: 400);

  /// How far the landing glow overshoots during the handoff pulse.
  static const double pulseOvershoot = 0.9;

  /// When a spring is close enough to call it landed.
  ///
  /// Looser than the physics default on purpose: the last half-pixel of a
  /// spring is not something anyone can see, and waiting for it would leave
  /// transitions ticking long after they look finished.
  static const Tolerance settleTolerance = Tolerance(
    distance: 0.002,
    velocity: 0.02,
  );

  /// How long the settle spring takes to come to rest from a unit step.
  ///
  /// Measured off the simulation rather than guessed, so the flattened
  /// [settleTempo] and the live spring stay the same length if the spring is
  /// ever retuned.
  static final Duration _settleSpan = _measureSettle(settleSpring);

  static Duration _measureSettle(SpringDescription spring) {
    final simulation = SpringSimulation(
      spring,
      0,
      1,
      0,
      tolerance: settleTolerance,
    );
    const step = 1 / 240;
    var t = step;
    while (t < 2 && !simulation.isDone(t)) {
      t += step;
    }
    return Duration(microseconds: (t * Duration.microsecondsPerSecond).round());
  }
}

/// The settle spring sampled as a plain curve over [_span].
class _SpringCurve extends Curve {
  _SpringCurve(SpringDescription spring, Duration span)
    : _simulation = SpringSimulation(spring, 0, 1, 0),
      _seconds = span.inMicroseconds / Duration.microsecondsPerSecond;

  final SpringSimulation _simulation;
  final double _seconds;

  @override
  double transformInternal(double t) => _simulation.x(t * _seconds);
}
