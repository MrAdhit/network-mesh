/// The pieces the four stages share: the product mark at stage scale, the way
/// a stage reports a failure, and the quiet card a choice is made on.
///
/// Nothing here is general enough for the kit. A stage is a shape the app wears
/// once, and these are the three parts of it that would otherwise be written
/// four times.
library;

import 'package:flutter/widgets.dart';

import '../../icons/mesh_icons.dart';
import '../../kit/panel.dart';
import '../../theme/theme.dart';

/// The product's shape at stage scale: the triad's silhouette, blooming.
///
/// The same mark the rail wears, drawn larger and without the wordmark beside
/// it. Deliberately not `signal`-coloured and deliberately not a
/// `MeshPathTriad`: this is the product's shape, not a report about paths, and
/// a green triad on the welcome screen would claim the mesh was up before the
/// app had spoken to anything.
class SetupMark extends StatelessWidget {
  const SetupMark({this.height = 44, super.key});

  /// The tall bar's height. The short ones are 60% of it, as everywhere else.
  final double height;

  @override
  Widget build(BuildContext context) {
    final tokens = FilamentTheme.tokensOf(context);
    final width = height / 7.3;
    final gap = width * 0.8;

    Widget bar(double h, Color color, {bool glow = false}) => Container(
      width: width,
      height: h,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(FilamentRadius.pill),
        boxShadow: glow ? tokens.bloom(color, blurScale: 1.4) : null,
      ),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        bar(height * 0.6, tokens.textFaint),
        SizedBox(width: gap),
        bar(height, tokens.text, glow: true),
        SizedBox(width: gap),
        bar(height * 0.6, tokens.textFaint),
      ],
    );
  }
}

/// A failure on a stage: what happened in our words, then the wire's own words
/// in mono underneath.
///
/// The rule from DESIGN.md, made into the one shape first run uses for it. The
/// headline is never the daemon's sentence reworded and the detail is never
/// rewritten — a person reads the first line, and the second is what they paste
/// to somebody who can help.
///
/// The dashboard's version of the same rule is `MeshWireError`, which is set
/// left and unboxed because it lands inside a panel. A stage has no panel: it
/// is a centred column on the bare window, and a bare mono line at that scale
/// reads as a caption rather than as the thing that went wrong.
class SetupFailure extends StatelessWidget {
  const SetupFailure({required this.headline, required this.detail, super.key});

  /// Sentence case, our voice: "Couldn't download the engine".
  final String headline;

  /// Verbatim, from the daemon, the control plane or the shell.
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(headline, style: theme.type.emphasis, textAlign: TextAlign.center),
        const SizedBox(height: FilamentSpace.x3),
        DecoratedBox(
          decoration: BoxDecoration(
            color: theme.tokens.surfaceHigh,
            border: MeshRingBorder(theme.tokens, opacity: 0.6),
            borderRadius: BorderRadius.circular(FilamentRadius.control),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FilamentSpace.x3,
              vertical: FilamentSpace.x2 + 2,
            ),
            child: Text(detail, style: theme.type.error),
          ),
        ),
      ],
    );
  }
}

/// One of the two ways onto a network, as a card.
///
/// Closed, it is a title, a sentence and a chevron, and the whole card is the
/// target — the choice is the card, not a button inside it. Open, the chevron
/// goes and [child] is what the card is actually asking. The other card recedes
/// at the same moment, which is what makes this a decision rather than a form
/// with two halves.
class SetupCard extends StatefulWidget {
  const SetupCard({
    required this.title,
    required this.message,
    this.onOpen,
    this.child,
    super.key,
  });

  final String title;

  /// One line. What this path is, not how it works.
  final String message;

  /// Null once the card is open.
  final VoidCallback? onOpen;

  /// The card's contents once it is the one being asked.
  final Widget? child;

  @override
  State<SetupCard> createState() => _SetupCardState();
}

class _SetupCardState extends State<SetupCard> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;
    final open = widget.onOpen == null;
    final lit = !open && (_hovered || _focused);
    final touch = FilamentMotion.touch(context);

    final head = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.title, style: theme.type.section),
              const SizedBox(height: 3),
              Text(widget.message, style: theme.type.bodyDim),
            ],
          ),
        ),
        if (!open) ...[
          const SizedBox(width: FilamentSpace.x4),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: MeshIcon(
              MeshGlyph.chevron,
              // A down chevron a quarter turn the other way points the way in.
              turns: -0.25,
              size: 16,
              color: lit ? tokens.text : tokens.textFaint,
            ),
          ),
        ],
      ],
    );

    final body = Padding(
      padding: const EdgeInsets.all(FilamentSpace.panel),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          head,
          if (widget.child != null) ...[
            const SizedBox(height: FilamentSpace.x5),
            widget.child!,
          ],
        ],
      ),
    );

    // The ring stays exactly where it is on hover: it is a statement about
    // where the light is, and it does not interpolate. What moves is the fill,
    // the way it moves under every other control in the kit.
    final card = DecoratedBox(
      decoration: BoxDecoration(
        gradient: tokens.panelFill,
        border: MeshRingBorder(tokens),
        borderRadius: BorderRadius.circular(FilamentRadius.panel),
        boxShadow: tokens.shade,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(FilamentRadius.panel - 1),
        child: Stack(
          children: [
            Positioned.fill(
              child: AnimatedContainer(
                duration: touch.duration,
                curve: touch.curve,
                color: lit
                    ? tokens.hovered(tokens.surface)
                    : tokens.surface.withValues(alpha: 0),
              ),
            ),
            body,
          ],
        ),
      ),
    );

    if (open) return card;

    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (v) => setState(() => _hovered = v),
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onOpen?.call();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onOpen,
        child: card,
      ),
    );
  }
}
