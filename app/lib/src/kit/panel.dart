/// `MeshPanel` — the card, lit from above, and [MeshRingBorder], the lit ring
/// every surface in the kit wears.
///
/// Also the shapes that go inside a panel: [MeshDivider], [MeshField] (label
/// above value), [MeshFact]/[MeshFacts] (label beside value, the CLI's
/// alignment), [MeshErrorNote] and [MeshWireError], the two ways the app quotes
/// a failure, and [MeshCommandLine], which is how one quotes a command to run.
library;

import 'package:flutter/widgets.dart';

import '../theme/theme.dart';
import 'copyable.dart';

/// The border of a lit surface: `FilamentTokens.ring` painted as a 1px ring.
///
/// One implementation, worn by everything that rings a lit surface — panels,
/// stat tiles, dialogs, the banner. The ring is a statement about where the
/// light is, and two surfaces lit from different places would break the room.
///
/// It is a [BoxBorder] rather than a painter so a surface keeps the single
/// [BoxDecoration] it already had: swapping `Border.all(color: hairline)` for
/// this leaves the fill, the radius, the shade and the layout exactly where
/// they were, because [dimensions] is still one pixel on every side.
///
/// Not interpolable: `BoxBorder.lerp` only knows how to blend `Border`, so a
/// decoration wearing this ring must not be handed to an `AnimatedContainer`.
/// Nothing in the kit does — a panel's ring changes with the theme, and the
/// theme does not crossfade.
@immutable
class MeshRingBorder extends BoxBorder {
  const MeshRingBorder(
    this.tokens, {
    this.base,
    this.opacity = 1,
    this.width = FilamentMetrics.hairline,
  });

  final FilamentTokens tokens;

  /// What the sides run at. Null means `hairline`.
  final Color? base;

  /// Scales the whole ring. Stat tiles wear it at 0.6: a tile sits in the page,
  /// not on top of it.
  final double opacity;

  final double width;

  LinearGradient get _gradient => tokens.ring(base: base, opacity: opacity);

  /// The lit top edge, as a plain side. For the rare caller that wants one
  /// stripe of the ring rather than the ring.
  @override
  BorderSide get top => BorderSide(color: _gradient.colors.first, width: width);

  /// The shaded bottom edge, as a plain side.
  @override
  BorderSide get bottom =>
      BorderSide(color: _gradient.colors.last, width: width);

  /// One width the whole way round, which is what uniform means for layout.
  @override
  bool get isUniform => true;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(width);

  @override
  ShapeBorder scale(double t) =>
      MeshRingBorder(tokens, base: base, opacity: opacity, width: width * t);

  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    TextDirection? textDirection,
    BoxShape shape = BoxShape.rectangle,
    BorderRadius? borderRadius,
  }) {
    if (width <= 0 || rect.isEmpty) return;
    final paint = Paint()
      // Shaded over the whole box, not over the stroke: the gradient describes
      // where the light falls on the surface, and the ring samples it.
      ..shader = _gradient.createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..isAntiAlias = true;
    // A stroke straddles its path, so the ring runs half a width inside the
    // box — where [dimensions] has already told the layout it is.
    switch (shape) {
      case BoxShape.circle:
        canvas.drawCircle(rect.center, (rect.shortestSide - width) / 2, paint);
      case BoxShape.rectangle:
        canvas.drawRRect(
          (borderRadius ?? BorderRadius.zero).toRRect(rect).deflate(width / 2),
          paint,
        );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is MeshRingBorder &&
      other.tokens.brightness == tokens.brightness &&
      other.base == base &&
      other.opacity == opacity &&
      other.width == width;

  @override
  int get hashCode => Object.hash(tokens.brightness, base, opacity, width);
}

/// A box lit from above: a fill that breathes lighter at the top, a
/// [MeshRingBorder] that catches the same light at the top of the ring and
/// falls away at the bottom, the `edgeLight` reflection just inside that ring,
/// and the `shade` ambient shadow underneath.
///
/// Not an elevation ramp — there is one depth in the system and every panel
/// wears it. The header is a 15px/600 title on the left and actions on the
/// right, separated from the body by a hairline. The gap between two panels is
/// [FilamentSpace.gap].
class MeshPanel extends StatelessWidget {
  const MeshPanel({
    this.title,
    this.subtitle,
    this.actions = const <Widget>[],
    this.child,
    this.padding = const EdgeInsets.all(FilamentSpace.panel),
    this.footer,
    this.accent,
    super.key,
  });

  /// Sentence case, never Title Case.
  final String? title;

  /// A quiet line under the title, inside the header.
  final String? subtitle;

  /// Right side of the header row.
  final List<Widget> actions;

  final Widget? child;

  /// Body padding. Set to [EdgeInsets.zero] for tables, which draw their own.
  final EdgeInsetsGeometry padding;

  /// Optional block below the body, above the bottom border, on `surfaceHigh`.
  final Widget? footer;

  /// A 2px left edge in this colour. Used to mark a panel that is reporting a
  /// state (alarm for a failed backhaul, caution for something expiring).
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;
    final hasHeader = title != null || actions.isNotEmpty;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: tokens.panelFill,
        border: MeshRingBorder(tokens),
        borderRadius: BorderRadius.circular(FilamentRadius.panel),
        boxShadow: tokens.shade,
      ),
      child: ClipRRect(
        // Clipped so the accent edge, the top edge and the footer fill all stop
        // at the radius.
        borderRadius: BorderRadius.circular(FilamentRadius.panel - 1),
        // A Stack, not a Row: the panel's height comes from its content, and a
        // stretched Row would demand a height nobody has yet.
        child: Stack(
          children: [
            Padding(
              padding: EdgeInsets.only(left: accent == null ? 0 : 2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (hasHeader) _header(theme),
                  if (child != null) Padding(padding: padding, child: child),
                  if (footer != null)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: tokens.surfaceHigh,
                        border: Border(top: BorderSide(color: tokens.hairline)),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: FilamentSpace.panel,
                          vertical: FilamentSpace.x3,
                        ),
                        child: footer,
                      ),
                    ),
                ],
              ),
            ),
            if (accent != null)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 2,
                child: ColoredBox(color: accent!),
              ),
            _EdgeLight(color: tokens.edgeLight),
          ],
        ),
      ),
    );
  }

  Widget _header(FilamentTheme theme) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.tokens.hairline)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          FilamentSpace.panel,
          FilamentSpace.x3 + 2,
          FilamentSpace.x3,
          FilamentSpace.x3 + 2,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null) Text(title!, style: theme.type.section),
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(subtitle!, style: theme.type.small),
                  ],
                ],
              ),
            ),
            if (actions.isNotEmpty)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < actions.length; i++) ...[
                    if (i > 0) const SizedBox(width: FilamentSpace.x2),
                    actions[i],
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// The reflection along the top inside edge of a panel.
///
/// It fades out towards the corners rather than running the full width: a hard
/// stop where a rounded corner starts reads as a seam, and light does not have
/// seams.
class _EdgeLight extends StatelessWidget {
  const _EdgeLight({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      height: FilamentMetrics.hairline,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: <Color>[
                color.withValues(alpha: 0),
                color,
                color,
                color.withValues(alpha: 0),
              ],
              stops: const <double>[0, 0.08, 0.92, 1],
            ),
          ),
        ),
      ),
    );
  }
}

/// Panels of the same shape sharing a row, stacked when the column gets too
/// narrow to read them side by side.
///
/// This is the rhythm rule from DESIGN.md made reusable: two backhaul cards
/// share a row, a table takes the full column, and no screen is one full-width
/// box after another five times. Every panel in the row gets the same width.
class MeshPanelRow extends StatelessWidget {
  const MeshPanelRow({
    required this.children,
    this.stackBelow = 620,
    super.key,
  });

  /// Left to right while there is room; top to bottom once there is not.
  final List<Widget> children;

  /// Below this much width the row becomes a column. Two credential forms stop
  /// being readable well before the rail collapses, so the default is generous;
  /// a pair of short status cards can afford a smaller number.
  final double stackBelow;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < stackBelow) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(height: FilamentSpace.gap),
                children[i],
              ],
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(width: FilamentSpace.gap),
              Expanded(child: children[i]),
            ],
          ],
        );
      },
    );
  }
}

/// A 1px hairline. Horizontal by default.
class MeshDivider extends StatelessWidget {
  const MeshDivider({this.vertical = false, this.inset = 0, super.key});

  final bool vertical;
  final double inset;

  @override
  Widget build(BuildContext context) {
    final color = FilamentTheme.tokensOf(context).hairline;
    return Padding(
      padding: vertical
          ? EdgeInsets.symmetric(vertical: inset)
          : EdgeInsets.symmetric(horizontal: inset),
      child: SizedBox(
        width: vertical ? FilamentMetrics.hairline : double.infinity,
        height: vertical ? double.infinity : FilamentMetrics.hairline,
        child: ColoredBox(color: color),
      ),
    );
  }
}

/// A label above a value, the shape most of Overview is made of.
///
/// The label is 11px `textDim`; the value is whatever widget you pass, so it
/// can be mono text, a copyable, a measure or a status line.
class MeshField extends StatelessWidget {
  const MeshField({
    required this.label,
    required this.child,
    this.gap = FilamentSpace.x1 + 1,
    super.key,
  });

  final String label;
  final Widget child;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.type.label),
        SizedBox(height: gap),
        child,
      ],
    );
  }
}

/// A CLI-style line: a fixed-width label column and a value beside it.
///
/// [MeshField] puts the label above the value, which is right for Overview's
/// cards. A settings-style panel reads better as aligned columns, exactly the
/// way `meshctl network` prints.
class MeshFact extends StatelessWidget {
  const MeshFact({
    required this.label,
    required this.child,
    this.labelWidth = 120,
    super.key,
  });

  /// 11px `textDim`, sentence case.
  final String label;

  final Widget child;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: labelWidth,
          child: Padding(
            // Sits the 11px label on the baseline of a 13px value.
            padding: const EdgeInsets.only(top: 2),
            child: Text(label, style: theme.type.label),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

/// A stack of [MeshFact]s with the gap between them already set.
class MeshFacts extends StatelessWidget {
  const MeshFacts(this.children, {this.gap = FilamentSpace.x3, super.key});

  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          children[i],
        ],
      ],
    );
  }
}

/// A failure that arrived over a wire, in the two registers DESIGN.md fixes.
///
/// The headline is ours: what happened, in the words the person in front of the
/// screen would use, and never a path or a URL. Under it, in mono, is whatever
/// the daemon or the control plane actually said, verbatim — they are better at
/// saying what went wrong than we are, and rewriting it would only lose the one
/// detail that turns out to matter.
///
/// This is the shape for every primary surface. [MeshErrorNote] is the same
/// idea with the layers the other way up, for the panels in Settings where the
/// wire's own words *are* the point and our line is the afterthought.
class MeshWireError extends StatelessWidget {
  const MeshWireError({
    required this.headline,
    required this.detail,
    this.hint,
    super.key,
  });

  /// Sentence case, one line, our voice.
  final String headline;

  /// The wire's words. Never rewritten, never truncated.
  final String detail;

  /// An optional third line in our voice, when there is something to add.
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(headline, style: theme.type.emphasis),
        const SizedBox(height: FilamentSpace.x2),
        Text(detail, style: theme.type.error),
        if (hint != null && hint!.isNotEmpty) ...[
          const SizedBox(height: FilamentSpace.x1 + 1),
          Text(hint!, style: theme.type.small),
        ],
      ],
    );
  }
}

/// An error, quoted verbatim in mono, inside the panel that caused it.
///
/// Never a dialog, never reworded. The daemon and the control plane are better
/// at saying what went wrong than we are. See [MeshWireError] for the shape a
/// primary surface uses, where our headline comes first.
class MeshErrorNote extends StatelessWidget {
  const MeshErrorNote(this.message, {this.hint, super.key});

  final String message;

  /// A second line in the app's own voice, when there is something useful to
  /// add — the chmod suggestion, for instance.
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(message, style: theme.type.error),
        if (hint != null && hint!.isNotEmpty) ...[
          const SizedBox(height: FilamentSpace.x1 + 1),
          Text(hint!, style: theme.type.small),
        ],
      ],
    );
  }
}

/// A shell command, in a box, copyable.
///
/// The only shape in the app that tells anyone to go and run something: the
/// chmod that opens a root-only socket, the install.sh one-liner on a platform
/// this app does not manage. Set in the data face, because a command is a
/// string to be reproduced exactly and not prose.
class MeshCommandLine extends StatelessWidget {
  const MeshCommandLine(this.command, {super.key});

  final String command;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.tokens.surfaceHigh,
        border: Border.all(color: theme.tokens.hairline),
        borderRadius: BorderRadius.circular(FilamentRadius.control),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: FilamentSpace.x3,
          vertical: FilamentSpace.x2 + 2,
        ),
        child: MeshCopyable(command, style: theme.type.mono),
      ),
    );
  }
}
