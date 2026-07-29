/// `MeshStatTile` — a short fact as a tile: small label on top, big number
/// under it. And [MeshStatRow], which lays a handful of them in an equal row.
///
/// This is the shape DESIGN.md asks for in place of label-value form rows for
/// short facts — an address, an uptime, a peer count. A tile row reads at a
/// glance; a form has to be read.
library;

import 'package:flutter/widgets.dart';

import '../theme/theme.dart';
import 'panel.dart';

/// One fact on a quiet tile.
///
/// The value slot takes any widget, so a screen can hand it a
/// `MeshTickingMeasure`, a `MeshCopyable`, a status line, or plain text. Plain
/// [Text] inherits the stat size from the tile; a widget that resolves its own
/// style from the theme should be given `theme.type.stat` (or `.hero` for the
/// one reading on the screen that outranks the others) explicitly.
class MeshStatTile extends StatelessWidget {
  const MeshStatTile({
    required this.label,
    required this.child,
    this.footnote,
    super.key,
  });

  /// 11px, tracked, `textDim`. Sentence case, and short — this is the caption
  /// on an instrument, not a sentence.
  final String label;

  /// The reading. Set two steps above its label, which is the whole point of
  /// the shape.
  final Widget child;

  /// An optional third line under the value: a unit-less qualifier, an "as of",
  /// a peer name. `small`, and never where the eye lands first.
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;

    return DecoratedBox(
      decoration: BoxDecoration(
        // Quieter than a panel on purpose: tiles sit inside the page, not on
        // top of it, so they get the fill and a whisper of a ring — no shadow,
        // no inner top edge, nothing that would make them float. The ring is
        // the panel's, at 0.6: same light, less of it.
        color: tokens.surfaceHigh.withValues(alpha: tokens.isDark ? 0.5 : 0.7),
        border: MeshRingBorder(tokens, opacity: 0.6),
        borderRadius: BorderRadius.circular(FilamentRadius.control),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          FilamentSpace.x3,
          FilamentSpace.x2 + 2,
          FilamentSpace.x3,
          FilamentSpace.x3,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.type.label, overflow: TextOverflow.clip),
            const SizedBox(height: FilamentSpace.x2 - 1),
            DefaultTextStyle(style: theme.type.stat, child: child),
            if (footnote != null) ...[
              const SizedBox(height: FilamentSpace.x1),
              Text(
                footnote!,
                style: theme.type.small,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Tiles in a row, equal width and equal height.
///
/// Equal width because a row of facts is a row of facts — sizing each tile to
/// its own number would turn the row into a ragged sentence. Equal height so
/// the labels line up whether or not a tile carries a footnote.
class MeshStatRow extends StatelessWidget {
  const MeshStatRow(this.children, {this.gap = FilamentSpace.x3, super.key});

  final List<Widget> children;

  /// Between tiles. Tighter than [FilamentSpace.gap] between panels: these are
  /// one object, not several.
  final double gap;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) SizedBox(width: gap),
            Expanded(child: children[i]),
          ],
        ],
      ),
    );
  }
}
