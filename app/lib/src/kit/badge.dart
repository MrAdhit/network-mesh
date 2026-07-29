/// `MeshBadge` — an 11px pill with a quiet fill.
library;

import 'package:flutter/widgets.dart';

import '../theme/theme.dart';

/// Small standing facts: "expired", "not configured", "3", "you".
///
/// A badge never carries an action. If it is clickable it is a button.
class MeshBadge extends StatelessWidget {
  const MeshBadge(
    this.label, {
    this.tone = MeshTone.neutral,
    this.mono = false,
    this.leading,
    super.key,
  });

  final String label;
  final MeshTone tone;

  /// For counts, versions and anything else that is really a number.
  final bool mono;

  /// A dot or icon before the label.
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;
    final color = tone == MeshTone.neutral
        ? tokens.textDim
        : tone.color(tokens);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: tone.fill(tokens),
        border: Border.all(color: tone.border(tokens)),
        borderRadius: BorderRadius.circular(FilamentRadius.pill),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(leading == null ? 8 : 6, 3, 8, 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leading != null) ...[
              leading!,
              const SizedBox(width: FilamentSpace.x1 + 1),
            ],
            Text(
              label,
              style: (mono ? theme.type.monoSmall : theme.type.label).copyWith(
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
