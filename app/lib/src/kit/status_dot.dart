/// `MeshStatusDot` — 8px dot, optional glow. The word beside it says the state.
library;

import 'package:flutter/widgets.dart';

import '../theme/theme.dart';

/// A round state indicator.
///
/// The glow is the `bloom` token: the dot's own colour, softened. Reserve it
/// for live "up" states so it means something.
class MeshStatusDot extends StatelessWidget {
  const MeshStatusDot({
    required this.tone,
    this.size = 8,
    this.glow = false,
    this.hollow = false,
    super.key,
  });

  /// A dot that is up and live.
  const MeshStatusDot.up({double size = 8, Key? key})
    : this(tone: MeshTone.signal, glow: true, size: size, key: key);

  /// A dot that is down.
  const MeshStatusDot.down({double size = 8, Key? key})
    : this(tone: MeshTone.alarm, size: size, key: key);

  /// A dot for a state nobody has reported yet.
  const MeshStatusDot.unknown({double size = 8, Key? key})
    : this(tone: MeshTone.neutral, hollow: true, size: size, key: key);

  final MeshTone tone;
  final double size;
  final bool glow;

  /// Outline only, for "not configured" and "unknown".
  final bool hollow;

  @override
  Widget build(BuildContext context) {
    final tokens = FilamentTheme.tokensOf(context);
    final color = hollow && tone == MeshTone.neutral
        ? tokens.hairlineHigh
        : tone.color(tokens);
    final drift = FilamentMotion.drift(context);
    return AnimatedContainer(
      duration: drift.duration,
      curve: drift.curve,
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: hollow ? null : color,
        shape: BoxShape.circle,
        border: hollow ? Border.all(color: color, width: 1.2) : null,
        // The bloom is scaled off the dot: an 8px dot under a 10px blur is a
        // smudge, the same blur under a 16px one is a halo.
        boxShadow: glow && !hollow
            ? tokens.bloom(color, blurScale: size / 14, spread: size / 12)
            : null,
      ),
    );
  }
}

/// A dot with the word that names the state next to it.
///
/// `MeshStatusLine(tone: MeshTone.signal, label: 'Up', detail: '10.7.0.3')`
/// reads as "• Up  10.7.0.3", which is exactly how the CLI says it.
class MeshStatusLine extends StatelessWidget {
  const MeshStatusLine({
    required this.tone,
    required this.label,
    this.detail,
    this.glow = false,
    this.hollow = false,
    this.style,
    super.key,
  });

  final MeshTone tone;
  final String label;

  /// Mono, dim, after the label. Addresses and reasons go here.
  final String? detail;

  final bool glow;
  final bool hollow;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MeshStatusDot(tone: tone, glow: glow, hollow: hollow),
        const SizedBox(width: FilamentSpace.x2),
        Text(
          label,
          style: (style ?? theme.type.body).copyWith(
            color: tone == MeshTone.neutral
                ? theme.tokens.textDim
                : tone.color(theme.tokens),
          ),
        ),
        if (detail != null) ...[
          const SizedBox(width: FilamentSpace.x2),
          Flexible(
            child: Text(
              detail!,
              style: theme.type.monoSmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    );
  }
}
