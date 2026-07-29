/// `MeshPanel` — the card, lit from above.
///
/// Also the shapes that go inside one: [MeshDivider], [MeshField] (label above
/// value), [MeshFact]/[MeshFacts] (label beside value, the CLI's alignment) and
/// [MeshErrorNote], which is how every panel in the app quotes a failure.
library;

import 'package:flutter/widgets.dart';

import '../theme/theme.dart';

/// A box lit from above: a fill that breathes lighter at the top, a 1px
/// hairline border with the `edgeLight` reflection just inside its top, and the
/// `shade` ambient shadow underneath.
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
        border: Border.all(color: tokens.hairline),
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

/// An error, quoted verbatim in mono, inside the panel that caused it.
///
/// Never a dialog, never reworded. The daemon and the control plane are better
/// at saying what went wrong than we are.
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
