/// `MeshBanner` — the shell's calm notice, and [MeshBannerHost], the strip at
/// the top of the window it slides into.
///
/// This is what the app does instead of a takeover. Something the user set up
/// has drifted — the engine stopped, a session expired — and the app says so in
/// one line, offers the one action that fixes it, and otherwise gets out of the
/// way. The data below keeps its own dimmed, stale look; nothing is blocked,
/// nothing has to be dismissed before the app can be used again.
library;

import 'package:flutter/widgets.dart';

import '../theme/theme.dart';
import 'panel.dart';

/// One line, one action, one accent edge.
///
/// A panel's fill and a panel's ring, so it belongs to the same room as
/// everything under it, plus the 2px [tone] edge that says what kind of news
/// this is: `caution` for something that stopped and can be started again,
/// `alarm` for something that failed. Anything quieter than that is not worth a
/// banner, and anything louder is a dialog, which this deliberately is not.
///
/// [action] is a slot rather than a label and a callback: the fix is usually an
/// async, privileged thing the screen already knows how to run, and it arrives
/// here as the button it already built. Keep it compact, and put whatever the
/// user needs to know before pressing it — that macOS is about to ask for a
/// password, say — in that button's tooltip.
class MeshBanner extends StatelessWidget {
  const MeshBanner({
    required this.message,
    this.action,
    this.tone = MeshTone.caution,
    super.key,
  });

  /// One sentence, in the app's own words. Never a path, never a URL: a banner
  /// is a primary surface, and the mechanics live in Settings.
  final String message;

  /// The one thing that fixes it. Usually a secondary [MeshButton].
  final Widget? action;

  /// `caution` or `alarm`.
  final MeshTone tone;

  /// The accent edge, and the padding that keeps the text off it.
  static const double _accent = 2;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: tokens.panelFill,
        border: MeshRingBorder(tokens),
        borderRadius: BorderRadius.circular(FilamentRadius.panel),
        boxShadow: tokens.shade,
      ),
      child: ClipRRect(
        // Clipped so the accent edge stops at the radius.
        borderRadius: BorderRadius.circular(FilamentRadius.panel - 1),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                FilamentSpace.x5 + _accent,
                FilamentSpace.x3,
                FilamentSpace.x3,
                FilamentSpace.x3,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      message,
                      style: theme.type.body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (action != null) ...[
                    const SizedBox(width: FilamentSpace.x4),
                    // Unbounded on this axis, so the button hugs its label
                    // instead of filling the banner.
                    action!,
                  ],
                ],
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: _accent,
              child: ColoredBox(color: tone.color(tokens)),
            ),
          ],
        ),
      ),
    );
  }
}

/// The strip a [MeshBanner] arrives in, above everything else in the window.
///
/// Wrap the shell in one. With no banner it is nothing at all — no strip, no
/// gap, no layout of its own. When one turns up it comes down over the top edge
/// of the window on `drift` and pushes the shell below it; when the thing it
/// was reporting is fixed it leaves the same way, and the last banner is kept
/// alive until it has finished going so nobody watches a sentence vanish
/// mid-sentence.
///
/// It is above the rail as well as the content because the news is about the
/// app, not about the screen you happen to be on.
class MeshBannerHost extends StatefulWidget {
  const MeshBannerHost({required this.child, this.banner, super.key});

  /// The shell.
  final Widget child;

  /// Null when there is nothing to say, which is almost always.
  final Widget? banner;

  @override
  State<MeshBannerHost> createState() => _MeshBannerHostState();
}

class _MeshBannerHostState extends State<MeshBannerHost> {
  /// The last banner handed to us, held while it leaves.
  Widget? _shown;

  @override
  void initState() {
    super.initState();
    _shown = widget.banner;
  }

  @override
  void didUpdateWidget(MeshBannerHost old) {
    super.didUpdateWidget(old);
    if (widget.banner != null) _shown = widget.banner;
  }

  @override
  Widget build(BuildContext context) {
    final tempo = FilamentMotion.drift(context);
    final open = widget.banner != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween<double>(end: open ? 1 : 0),
          duration: tempo.duration,
          curve: tempo.curve,
          // Once it is gone it is gone: keeping the widget alive would keep a
          // dead notice's subtree in the tree for the life of the app.
          onEnd: () {
            if (!open && _shown != null) setState(() => _shown = null);
          },
          child: _shown == null
              ? null
              : Padding(
                  padding: const EdgeInsets.fromLTRB(
                    FilamentSpace.gap,
                    FilamentSpace.gap,
                    FilamentSpace.gap,
                    0,
                  ),
                  child: _shown,
                ),
          builder: (context, t, child) {
            if (child == null || t <= 0.001) return const SizedBox.shrink();
            return ClipRect(
              child: Align(
                // Anchored to the bottom of the clip, so the strip opens
                // downwards and the banner reads as sliding in over the top
                // edge of the window rather than growing out of nothing.
                alignment: Alignment.bottomCenter,
                heightFactor: t.clamp(0.0, 1.0),
                child: Opacity(opacity: t.clamp(0.0, 1.0), child: child),
              ),
            );
          },
        ),
        Expanded(child: widget.child),
      ],
    );
  }
}
