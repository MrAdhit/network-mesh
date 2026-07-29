/// `MeshRail` — the left rail: app mark, destinations, status block.
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';

import '../icons/mesh_icons.dart';
import '../theme/theme.dart';
import 'badge.dart';
import 'button.dart';
import 'motion.dart';
import 'path_triad.dart';
import 'tooltip.dart';

/// One rail destination.
class MeshDestination {
  const MeshDestination({required this.glyph, required this.label});

  final MeshGlyph glyph;

  /// Sentence case, one word where possible.
  final String label;
}

/// Everything the rail's bottom block shows.
///
/// This is the seam between the shell and the data layer: the shell renders a
/// `ValueListenable<MeshRailStatus>` and knows nothing else. The data phase
/// implements one by folding `DaemonStore` and `SessionStore` into this shape —
/// no other part of the shell needs to change.
@immutable
class MeshRailStatus {
  const MeshRailStatus({
    this.daemonReachable,
    this.enrolled = false,
    this.direct = MeshPathState.unknown,
    this.cloudflare = MeshPathState.unknown,
    this.tailscale = MeshPathState.unknown,
    this.detail,
    this.sessionEmail,
    this.sessionExpired = false,
  });

  /// Nothing known yet: what the rail shows before the first poll lands.
  const MeshRailStatus.unknown() : this();

  /// Null while the first poll is still in flight.
  final bool? daemonReachable;

  /// The daemon is up but has not joined a network.
  final bool enrolled;

  /// The daemon's own triad: direct is the daemon's reachability, the other two
  /// are its backhaul planes.
  final MeshPathState direct;
  final MeshPathState cloudflare;
  final MeshPathState tailscale;

  /// A short second line: node name when enrolled, the OS error when not.
  final String? detail;

  /// Null when there is no control plane session.
  final String? sessionEmail;

  final bool sessionExpired;

  /// The word under the triad.
  String get daemonLabel => switch (daemonReachable) {
    null => 'Connecting',
    false => 'Unreachable',
    true => enrolled ? 'Enrolled' : 'Not enrolled',
  };

  MeshTone get daemonTone => switch (daemonReachable) {
    null => MeshTone.neutral,
    false => MeshTone.alarm,
    true => enrolled ? MeshTone.signal : MeshTone.caution,
  };

  String get sessionLabel => sessionEmail == null
      ? 'Signed out'
      : (sessionExpired ? 'Session expired' : sessionEmail!);

  MeshTone get sessionTone => sessionEmail == null
      ? MeshTone.neutral
      : (sessionExpired ? MeshTone.caution : MeshTone.link);

  @override
  bool operator ==(Object other) =>
      other is MeshRailStatus &&
      other.daemonReachable == daemonReachable &&
      other.enrolled == enrolled &&
      other.direct == direct &&
      other.cloudflare == cloudflare &&
      other.tailscale == tailscale &&
      other.detail == detail &&
      other.sessionEmail == sessionEmail &&
      other.sessionExpired == sessionExpired;

  @override
  int get hashCode => Object.hash(
    daemonReachable,
    enrolled,
    direct,
    cloudflare,
    tailscale,
    detail,
    sessionEmail,
    sessionExpired,
  );
}

/// The rail. 220px, or 72px collapsed to icons.
class MeshRail extends StatelessWidget {
  const MeshRail({
    required this.destinations,
    required this.selectedIndex,
    required this.onSelect,
    this.status,
    this.collapsed = false,
    super.key,
  });

  final List<MeshDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  /// Null renders the resting "connecting" state.
  final ValueListenable<MeshRailStatus>? status;

  final bool collapsed;

  /// One destination's slot: 32px of item plus a 1px gap top and bottom.
  static const double _itemHeight = 32;
  static const double _itemExtent = _itemHeight + 2;

  /// The spark's own width — the 2px signal edge, now travelling.
  static const double _sparkWidth = 2;

  /// Icons in the rail, one step up from the 16px kit default: at 220px wide
  /// the rail is the app's furniture, not a toolbar.
  static const double _iconSize = 18;

  /// Where a rail item's icon starts: the item's own inset plus its padding.
  /// The app mark sits on the same line.
  static const double _gutter = FilamentSpace.x2 + FilamentSpace.x3;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;

    return Container(
      width: collapsed
          ? FilamentMetrics.railCollapsedWidth
          : FilamentMetrics.railWidth,
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border(right: BorderSide(color: tokens.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _mark(theme),
          const SizedBox(height: FilamentSpace.x2),
          SizedBox(
            height: destinations.length * _itemExtent,
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < destinations.length; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: FilamentSpace.x2,
                          vertical: 1,
                        ),
                        child: _RailItem(
                          destination: destinations[i],
                          selected: i == selectedIndex,
                          collapsed: collapsed,
                          height: _itemHeight,
                          iconSize: _iconSize,
                          onTap: () => onSelect(i),
                        ),
                      ),
                  ],
                ),
                // One light, travelling. Never rebuilt per destination: the
                // spark is the same object wherever it lands.
                _Spark(
                  index: selectedIndex,
                  extent: _itemExtent,
                  height: _itemHeight,
                  width: _sparkWidth,
                  left: FilamentSpace.x2,
                  color: tokens.signal,
                ),
              ],
            ),
          ),
          const Spacer(),
          _StatusBlock(status: status, collapsed: collapsed),
        ],
      ),
    );
  }

  Widget _mark(FilamentTheme theme) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        collapsed ? 0 : _gutter,
        FilamentSpace.x5,
        FilamentSpace.x3,
        FilamentSpace.x4,
      ),
      child: Row(
        mainAxisAlignment: collapsed
            ? MainAxisAlignment.center
            : MainAxisAlignment.start,
        children: [
          _AppMark(tokens: theme.tokens),
          if (!collapsed) ...[
            const SizedBox(width: FilamentSpace.x3),
            Text('Mesh', style: theme.type.emphasis),
          ],
        ],
      ),
    );
  }
}

/// The wordmark: the triad's own silhouette, blooming.
///
/// Deliberately not a [MeshPathTriad] and deliberately not `signal`-coloured:
/// the mark is the product's shape, not a report, and a green triad up here
/// would read as "everything is up" before the daemon has said a word. It gets
/// the depth treatment instead — the bars are lit, and the tall one glows.
class _AppMark extends StatelessWidget {
  const _AppMark({required this.tokens});

  final FilamentTokens tokens;

  /// The triad's geometry at mark scale: 3px bars, 2px gaps, 60/100/60.
  static const double _barWidth = FilamentMetrics.triadBarWidth;
  static const double _tall = 18;
  static const double _short = _tall * 0.6;

  @override
  Widget build(BuildContext context) {
    Widget bar(double height, Color color, {bool glow = false}) => Container(
      width: _barWidth,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(FilamentRadius.pill),
        boxShadow: glow
            ? tokens.bloom(color, intensity: 0.8, blurScale: 0.8)
            : null,
      ),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        bar(_short, tokens.textFaint),
        const SizedBox(width: FilamentMetrics.triadGap),
        bar(_tall, tokens.text, glow: true),
        const SizedBox(width: FilamentMetrics.triadGap),
        bar(_short, tokens.textFaint),
      ],
    );
  }
}

/// The traveling spark: the active item's 2px signal edge, kept as one light
/// that slides to whichever destination was picked and settles there.
///
/// It carries its glow with it. A second click mid-flight retargets from the
/// spark's current position and speed, so a run down the rail with the arrow
/// keys is one continuous move, not four.
class _Spark extends StatelessWidget {
  const _Spark({
    required this.index,
    required this.extent,
    required this.height,
    required this.width,
    required this.left,
    required this.color,
  });

  final int index;
  final double extent;
  final double height;
  final double width;
  final double left;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final tokens = FilamentTheme.tokensOf(context);
    return MeshSpringBuilder(
      value: index * extent,
      builder: (context, top, child) =>
          Positioned(top: top + 1, left: left, child: child!),
      child: IgnorePointer(
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(width / 2),
            // A 2px light with the full bloom behind it would smear down the
            // rail as it travels; two thirds of the blur keeps it a filament.
            boxShadow: tokens.bloom(color, blurScale: 0.65, spread: 1),
          ),
        ),
      ),
    );
  }
}

class _RailItem extends StatefulWidget {
  const _RailItem({
    required this.destination,
    required this.selected,
    required this.collapsed,
    required this.height,
    required this.iconSize,
    required this.onTap,
  });

  final MeshDestination destination;
  final bool selected;
  final bool collapsed;
  final double height;
  final double iconSize;
  final VoidCallback onTap;

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;
    final active = widget.selected;
    final foreground = active
        ? tokens.text
        : (_hovered || _focused ? tokens.text : tokens.textDim);
    final touch = FilamentMotion.touch(context);

    // No left edge here any more — that light lives in [_Spark] and travels.
    // The left padding keeps the 2px it used to occupy so the icons hold their
    // column while the spark moves over them.
    Widget body = AnimatedContainer(
      duration: touch.duration,
      curve: touch.curve,
      height: widget.height,
      decoration: BoxDecoration(
        color: active
            ? tokens.surfaceHigh
            : (_hovered ? tokens.surfaceHigh.withValues(alpha: 0.6) : null),
        borderRadius: BorderRadius.circular(FilamentRadius.control),
      ),
      padding: EdgeInsets.only(left: widget.collapsed ? 0 : FilamentSpace.x3),
      child: Row(
        mainAxisAlignment: widget.collapsed
            ? MainAxisAlignment.center
            : MainAxisAlignment.start,
        children: [
          MeshIcon(
            widget.destination.glyph,
            size: widget.iconSize,
            color: foreground,
          ),
          if (!widget.collapsed) ...[
            const SizedBox(width: FilamentSpace.x3),
            Text(
              widget.destination.label,
              style: theme.type.body.copyWith(
                color: foreground,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ],
      ),
    );

    body = MeshFocusRing(focused: _focused, child: body);

    body = FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (v) => setState(() => _hovered = v),
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: body,
      ),
    );

    return widget.collapsed
        ? MeshTooltip(message: widget.destination.label, child: body)
        : body;
  }
}

class _StatusBlock extends StatelessWidget {
  const _StatusBlock({required this.status, required this.collapsed});

  final ValueListenable<MeshRailStatus>? status;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final listenable = status;
    if (listenable == null) {
      return _build(context, const MeshRailStatus.unknown());
    }
    return ValueListenableBuilder<MeshRailStatus>(
      valueListenable: listenable,
      builder: (context, value, _) => _build(context, value),
    );
  }

  Widget _build(BuildContext context, MeshRailStatus s) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;

    final triad = MeshPathTriad(
      direct: s.direct,
      cloudflare: s.cloudflare,
      tailscale: s.tailscale,
      height: 16,
      barWidth: 3,
      gap: 3,
    );

    if (collapsed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: FilamentSpace.x4),
        child: MeshTooltip(
          message: '${s.daemonLabel}\n${s.sessionLabel}',
          child: Center(child: triad),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: tokens.hairline)),
      ),
      padding: const EdgeInsets.fromLTRB(
        MeshRail._gutter,
        FilamentSpace.x4,
        FilamentSpace.x3,
        FilamentSpace.x5,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              triad,
              const SizedBox(width: FilamentSpace.x3),
              Expanded(
                child: AnimatedSwitcher(
                  duration: FilamentMotion.drift(context).duration,
                  switchInCurve: FilamentMotion.drift(context).curve,
                  child: Text(
                    s.daemonLabel,
                    key: ValueKey(s.daemonLabel),
                    style: theme.type.body.copyWith(
                      color: s.daemonTone.color(tokens),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
          if (s.detail != null) ...[
            const SizedBox(height: FilamentSpace.x1 + 1),
            Text(
              s.detail!,
              style: theme.type.monoSmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: FilamentSpace.x4),
          MeshTooltip(
            message: s.sessionEmail == null
                ? 'No control plane session'
                : s.sessionEmail!,
            child: MeshBadge(
              s.sessionLabel,
              tone: s.sessionTone,
              mono: s.sessionEmail != null && !s.sessionExpired,
            ),
          ),
        ],
      ),
    );
  }
}
