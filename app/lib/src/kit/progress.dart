/// `MeshProgress` — the kit's one progress primitive: a hairline track, a
/// signal fill that travels rather than jumps, and the count in the data face
/// above it.
///
/// It is an instrument reading, not a decoration. The bar carries the shape of
/// the answer and the mono readout carries the answer itself, which is the
/// house rule everywhere else: numbers are the heroes, the graphic is the
/// ground they sit on. Nothing here spins, pulses or flares.
///
/// Two modes, because the app has two kinds of waiting:
///
/// * **determinate** — bytes are landing and both ends agree on the total, so
///   the fill is a fraction and the readout is `12.4 / 48.2 MB  26%`;
/// * **indeterminate** — the phases with no measurable middle (hashing a file,
///   the authorization prompt, the privileged step). One band of light travels
///   the track and the readout is silent, because inventing a percentage for a
///   step that has none is the app lying about something it cannot see.
library;

import 'package:flutter/widgets.dart';

import '../theme/theme.dart';
import '../util/format.dart';

/// How tall the track is. Thin enough to read as a hairline the fill lights
/// up, rather than as a tube something is poured into.
const double _trackHeight = 4;

/// One pass of the indeterminate band.
///
/// Deliberately not a [FilamentTempo]: a tempo says how a move between two
/// states is shaped, and this never arrives anywhere. The period lives here for
/// the same reason `MeshSpinner` owns its rotation.
const Duration _sweepPeriod = Duration(milliseconds: 1150);

/// How much of the track the travelling band covers.
const double _sweepWidth = 0.32;

/// Where the band sits when it is exactly off one end.
///
/// `Alignment` lerps a child across the *free* space, so a band this wide has
/// to travel past ±1 to clear the ends: at ±[_sweepTravel] its near edge is
/// flush with the far edge of the track and the loop has no visible seam.
const double _sweepTravel = (1 + _sweepWidth) / (1 - _sweepWidth);

/// A phase of work, with its label, its reading and its bar.
///
/// ```dart
/// MeshProgress(
///   label: 'Downloading meshd',
///   value: store.downloadProgress,
///   received: store.downloadedBytes,
///   total: store.downloadTotalBytes,
/// )
/// ```
class MeshProgress extends StatelessWidget {
  const MeshProgress({
    required this.label,
    this.value,
    this.received,
    this.total,
    this.detail,
    this.tone = MeshTone.signal,
    super.key,
  });

  /// The one with no measurable middle: the band travels and the readout is
  /// whatever [detail] says, which is usually nothing.
  const MeshProgress.indeterminate({
    required String label,
    String? detail,
    MeshTone tone = MeshTone.signal,
    Key? key,
  }) : this(label: label, detail: detail, tone: tone, key: key);

  /// What is happening, in the CLI's voice: 'Downloading meshd'.
  final String label;

  /// 0..1, or null for a phase that cannot report a fraction.
  final double? value;

  /// Bytes down, and the total when there is one. Both null for phases that
  /// are not moving bytes.
  final int? received;
  final int? total;

  /// A quiet line under the bar, in the app's own voice.
  final String? detail;

  /// Signal by default — this is work the user asked for, and the fill is the
  /// one coloured thing in the panel while it runs.
  final MeshTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final color = tone.color(theme.tokens);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                label,
                style: theme.type.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            _Readout(value: value, received: received, total: total),
          ],
        ),
        const SizedBox(height: FilamentSpace.x2),
        _Track(value: value, color: color),
        if (detail != null && detail!.isNotEmpty) ...[
          const SizedBox(height: FilamentSpace.x2),
          Text(detail!, style: theme.type.small),
        ],
      ],
    );
  }
}

/// The count, in the data face: bytes if there are any, then the percentage.
///
/// Neither number rolls. A needle is for a reading a person watches settle;
/// a download already changes several times a second, and tweening one moving
/// number into the next only makes it lag behind what has actually landed.
class _Readout extends StatelessWidget {
  const _Readout({required this.value, required this.received, this.total});

  final double? value;
  final int? received;
  final int? total;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final received = this.received;
    final total = this.total;
    final value = this.value;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (received != null) ...[
          MeshMeasure(bytesParts(received), style: theme.type.mono),
          if (total != null && total > 0) ...[
            Text(' / ', style: theme.type.monoSmall),
            MeshMeasure(bytesParts(total), style: theme.type.mono),
          ],
        ],
        if (value != null) ...[
          if (received != null) const SizedBox(width: FilamentSpace.x3),
          MeshMeasure(
            percentParts((value.clamp(0.0, 1.0)) * 100, decimals: 0),
            style: theme.type.monoEmphasis,
          ),
        ],
      ],
    );
  }
}

/// The bar itself: `hairline` ground, `signal` fill.
class _Track extends StatelessWidget {
  const _Track({required this.value, required this.color});

  final double? value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final tokens = FilamentTheme.tokensOf(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(FilamentRadius.pill),
      child: SizedBox(
        height: _trackHeight,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.hairline,
            borderRadius: BorderRadius.circular(FilamentRadius.pill),
          ),
          child: value == null
              ? _Sweep(color: color)
              : _Fill(fraction: value!.clamp(0.0, 1.0), color: color),
        ),
      ),
    );
  }
}

/// The determinate fill. It travels to its new fraction on `drift` — bytes
/// arrive in whatever lumps the network hands over, and a bar that stepped
/// with them would twitch instead of filling.
class _Fill extends StatelessWidget {
  const _Fill({required this.fraction, required this.color});

  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final tokens = FilamentTheme.tokensOf(context);
    final drift = FilamentMotion.drift(context);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: fraction),
      duration: drift.duration,
      curve: drift.curve,
      builder: (context, t, _) => FractionallySizedBox(
        alignment: Alignment.centerLeft,
        // A fill of literally nothing is a dot of colour at the left end
        // claiming something has happened.
        widthFactor: t <= 0 ? 0 : t.clamp(0.0, 1.0),
        // Both factors, always. The fill is a bare `DecoratedBox` with no
        // child, so its height comes from nowhere else: leave this off and it
        // lays out at the right width and zero height, which is a bar that
        // reads as dead at every fraction.
        heightFactor: 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(FilamentRadius.pill),
            // The fill is live, so it blooms — gently. At 4px tall the
            // full-strength glow is a smudge twice the height of the bar.
            boxShadow: tokens.bloom(color, intensity: 0.7, blurScale: 0.5),
          ),
        ),
      ),
    );
  }
}

/// The indeterminate band: one length of light travelling the track at a
/// constant speed, soft at both ends. Light along a filament, which is the
/// metaphor the whole system is named for.
///
/// Under reduced motion it stops travelling and becomes a dim full-width fill:
/// the meaning is "busy, and nobody can say how far along", and that survives
/// without the journey.
class _Sweep extends StatefulWidget {
  const _Sweep({required this.color});

  final Color color;

  @override
  State<_Sweep> createState() => _SweepState();
}

class _SweepState extends State<_Sweep> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _sweepPeriod,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = FilamentMotion.reducedIn(context);
    if (reduced && _controller.isAnimating) {
      _controller.stop();
    } else if (!reduced && !_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (FilamentMotion.reducedIn(context)) {
      return ColoredBox(color: widget.color.withValues(alpha: 0.45));
    }
    final band = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: <Color>[
            widget.color.withValues(alpha: 0),
            widget.color,
            widget.color.withValues(alpha: 0),
          ],
        ),
      ),
    );
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => FractionallySizedBox(
        // In off the left end, out past the right, once per period.
        alignment: Alignment(_sweepTravel * (_controller.value * 2 - 1), 0),
        widthFactor: _sweepWidth,
        // As in `_Fill`: the band has no child to be tall for it.
        heightFactor: 1,
        child: child,
      ),
      child: band,
    );
  }
}
