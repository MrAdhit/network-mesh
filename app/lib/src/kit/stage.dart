/// `MeshStage` — the full-window layout first run happens on, and
/// [MeshStepTriad], the triad that doubles as its step indicator.
///
/// A stage is the opposite shape to a screen: no rail, no scrolling column of
/// panels, one decision in the middle of the window with room around it. The
/// app wears it exactly once in its life, and never again after arrival.
library;

import 'package:flutter/widgets.dart';

import '../theme/theme.dart';
import 'motion.dart';

/// One stage of the first-run flow, filling the window.
///
/// The window is `bg` under the same phosphor haze the shell wears, so crossing
/// from the last stage to the dashboard is a change of content and not a change
/// of room. Everything else is a slot, because a stage is a layout and the
/// words belong to the screen that knows them: the [mark] up top, the [title]
/// and its [message], a [body] for whatever the stage is actually asking, the
/// [action] zone, its [footnote] — the honest line about what the button is
/// about to do — and the [indicator], parked bottom-centre.
///
/// The content column is capped at [maxWidth] and centred; past the window's
/// height it scrolls rather than clipping, so a short window still reaches the
/// button.
class MeshStage extends StatelessWidget {
  const MeshStage({
    required this.title,
    this.mark,
    this.message,
    this.body,
    this.action,
    this.footnote,
    this.indicator,
    this.maxWidth = defaultMaxWidth,
    super.key,
  });

  /// Narrower than the shell's 960: a stage is one column of prose and one
  /// button, and prose set wider than this stops being a sentence you can take
  /// in at a glance.
  static const double defaultMaxWidth = 560;

  /// Room kept clear at the bottom for [indicator], which floats over the
  /// column rather than sitting under it — the step you are on should not move
  /// because a stage grew a paragraph.
  static const double _indicatorZone = 96;

  /// The product's shape, above the title. Usually the app mark, blooming.
  final Widget? mark;

  /// Sentence case, one line. 20/600.
  final String title;

  /// One sentence under the title. Not a paragraph, and never a URL.
  final String? message;

  /// What the stage is asking: a progress treatment, a field, two cards.
  final Widget? body;

  /// The primary action zone, centred. One button, or a button and its way out.
  final Widget? action;

  /// The quiet line under the action — what is about to happen, in our words.
  final String? footnote;

  /// Bottom-centre. A [MeshStepTriad] in the flow; anything in a preview.
  final Widget? indicator;

  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;

    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (mark != null) ...[
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [mark!]),
          const SizedBox(height: FilamentSpace.x6),
        ],
        Text(title, style: theme.type.stage, textAlign: TextAlign.center),
        if (message != null) ...[
          const SizedBox(height: FilamentSpace.x3),
          Text(
            message!,
            style: theme.type.bodyDim,
            textAlign: TextAlign.center,
          ),
        ],
        if (body != null) ...[const SizedBox(height: FilamentSpace.x8), body!],
        if (action != null) ...[
          const SizedBox(height: FilamentSpace.x8),
          // A Row that hugs, not a Center: a kit button fills any bounded width
          // it is offered — even a loose one — and a 560px-wide primary action
          // reads as a banner rather than a button. Inside a shrink-wrapping
          // Row the width is unbounded, so the button takes its label's.
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [action!]),
        ],
        if (footnote != null) ...[
          const SizedBox(height: FilamentSpace.x3),
          Text(footnote!, style: theme.type.small, textAlign: TextAlign.center),
        ],
      ],
    );

    // Two layers, as in the shell: a BoxDecoration's gradient replaces its
    // colour rather than sitting on it, so `bg` goes down first and the haze
    // over it.
    return ColoredBox(
      color: tokens.bg,
      child: DecoratedBox(
        decoration: BoxDecoration(gradient: tokens.haze),
        child: Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    FilamentSpace.x6,
                    FilamentSpace.x8,
                    FilamentSpace.x6,
                    indicator == null ? FilamentSpace.x8 : _indicatorZone,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxWidth),
                      child: column,
                    ),
                  ),
                ),
              ),
            ),
            if (indicator != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: FilamentSpace.x8,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [indicator!],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The step indicator: the triad again, one bar per stage, igniting as each one
/// completes.
///
/// The mark is the progress bar. A stage still ahead is a short `signalDim`
/// bar — up, not winning, the same thing that shape says everywhere else in the
/// app; a stage behind you is the full-height `signal` bar with its bloom. Both
/// ends of that are already in the palette, which is why the indicator needs no
/// colour of its own.
///
/// Each bar springs on its own, so completing a stage ignites one bar without
/// disturbing its neighbours, and the whole thing lands lit at arrival. Reduced
/// motion collapses the ignition to the 90ms crossfade, like everything else:
/// the bar is lit either way, it simply does not travel there.
class MeshStepTriad extends StatelessWidget {
  const MeshStepTriad({
    required this.stagesLit,
    this.barWidth = 5,
    this.height = 24,
    this.gap = 6,
    super.key,
  });

  /// The triad is three bars. Always.
  static const int stages = 3;

  /// How many stages are behind you: 0 lights nothing, [stages] is the whole
  /// mark. Out-of-range values are clamped rather than asserted — this is a
  /// derived number and a wizard mid-flight should never crash over it.
  final int stagesLit;

  /// The mark at stage scale. The rest of the app draws it 3x12; this one is
  /// the size of a thing you are meant to look at.
  final double barWidth;
  final double height;
  final double gap;

  /// An unlit bar is the triad's "up, not winning" height.
  static const double _unlit = 0.6;

  @override
  Widget build(BuildContext context) {
    final lit = stagesLit.clamp(0, stages);
    return SizedBox(
      height: height,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < stages; i++) ...[
            if (i > 0) SizedBox(width: gap),
            _StepBar(
              lit: i < lit,
              width: barWidth,
              height: height,
              unlitFraction: _unlit,
            ),
          ],
        ],
      ),
    );
  }
}

/// One bar of [MeshStepTriad]: height, colour and bloom all riding the one
/// spring, so an ignition is a single move and not three.
class _StepBar extends StatelessWidget {
  const _StepBar({
    required this.lit,
    required this.width,
    required this.height,
    required this.unlitFraction,
  });

  final bool lit;
  final double width;
  final double height;
  final double unlitFraction;

  @override
  Widget build(BuildContext context) {
    final tokens = FilamentTheme.tokensOf(context);
    return MeshSpringBuilder(
      value: lit ? 1 : 0,
      builder: (context, t, _) {
        // The spring's overshoot lives in the glow: a bar that grew past its
        // own box would have to be clipped, and a clipped overshoot is a jump.
        final settled = t.clamp(0.0, 1.0);
        return Container(
          width: width,
          height: height * (unlitFraction + (1 - unlitFraction) * settled),
          decoration: BoxDecoration(
            color: Color.lerp(tokens.signalDim, tokens.signal, settled),
            borderRadius: BorderRadius.circular(FilamentRadius.pill),
            boxShadow: tokens.bloom(
              tokens.signal,
              intensity: t.clamp(0.0, 1.25),
            ),
          ),
        );
      },
    );
  }
}
