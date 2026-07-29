/// `MeshScaffold` — rail plus content column, and the travel between screens.
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';

import '../theme/theme.dart';
import 'motion.dart';
import 'rail.dart';

/// The window's one layout: a fixed rail on the left, and a content column
/// capped at 960px and centred in what is left.
///
/// The window itself is `bg` under the phosphor haze — a radial wash of
/// `signal` anchored at the top-left corner, at an opacity you are meant to
/// feel rather than see.
///
/// Screens are kept alive in a [MeshScreenSwitcher] so switching destinations
/// does not restart their scroll position or their state, and so the change
/// travels in the direction the rail's spark just moved.
class MeshScaffold extends StatelessWidget {
  const MeshScaffold({
    required this.destinations,
    required this.selectedIndex,
    required this.onSelect,
    required this.children,
    this.railStatus,
    this.contentMaxWidth = FilamentMetrics.contentMaxWidth,
    super.key,
  });

  final List<MeshDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  /// One per destination, same order.
  final List<Widget> children;

  /// The rail's bottom block. Null renders the resting state.
  final ValueListenable<MeshRailStatus>? railStatus;

  final double contentMaxWidth;

  /// Below this window width the rail drops to icons.
  static const double _collapseBelow = 1000;

  @override
  Widget build(BuildContext context) {
    assert(
      destinations.length == children.length,
      'MeshScaffold needs one child per destination.',
    );
    final tokens = FilamentTheme.tokensOf(context);

    // Two layers, because a BoxDecoration's gradient replaces its colour
    // rather than sitting on it: `bg` first, then the haze over it.
    return ColoredBox(
      color: tokens.bg,
      child: DecoratedBox(
        decoration: BoxDecoration(gradient: tokens.haze),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final collapsed = constraints.maxWidth < _collapseBelow;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MeshRail(
                  destinations: destinations,
                  selectedIndex: selectedIndex,
                  onSelect: onSelect,
                  status: railStatus,
                  collapsed: collapsed,
                ),
                Expanded(
                  child: Align(
                    // Centred, not hugging the rail: past 960px of window the
                    // column sits in the middle of the space it was given.
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: contentMaxWidth,
                        minHeight: constraints.maxHeight,
                        maxHeight: constraints.maxHeight,
                      ),
                      child: MeshScreenSwitcher(
                        index: selectedIndex,
                        children: children,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// One screen at a time, all of them alive, and the change between them
/// travelling in the direction the rail moved.
///
/// The whole thing is one number per screen — its **slot**, where `0` is on
/// screen, `-1` is one step above it and `+1` one step below. Screen `i` always
/// wants slot `sign(i - index)`, so the destinations keep their rail order in
/// space and a transition is nothing more than every slot heading for its new
/// value on `drift`. Moving down the rail therefore drifts the screen you left
/// up and brings the new one in from below; moving up reverses it, without a
/// single `if` about direction anywhere.
///
/// Picking a third destination mid-flight retargets the slots from where they
/// are and with the momentum they had: nothing queues, and nothing finishes a
/// transition you have already abandoned. A screen parked off stage crosses to
/// the other side instantly instead of flying past the one you are reading.
///
/// Off-stage screens are laid out with the same constraints as the visible one
/// and keep their state — a scroll offset survives a there-and-back — but they
/// are not painted, not hit-tested, not focusable, and their tickers are muted,
/// so nothing you are not looking at asks for a frame.
///
/// Reduced motion drops the travel and leaves the crossfade, which is the rule
/// for everything: meaning survives, travel does not.
class MeshScreenSwitcher extends StatefulWidget {
  const MeshScreenSwitcher({
    required this.index,
    required this.children,
    super.key,
  });

  /// The destination on screen.
  final int index;

  /// One per destination, in rail order. Order is the spatial model: the
  /// screens above [index] leave upwards and the ones below leave downwards.
  final List<Widget> children;

  @override
  State<MeshScreenSwitcher> createState() => _MeshScreenSwitcherState();
}

class _MeshScreenSwitcherState extends State<MeshScreenSwitcher>
    with TickerProviderStateMixin {
  /// One slot per child, in the same order.
  final List<MeshSpring> _slots = <MeshSpring>[];

  /// Past this far out a screen is fully faded, so it can leave the stage.
  static const double _gone = 0.999;

  @override
  void initState() {
    super.initState();
    // Boot is not an arrival: every screen starts parked at its resting slot,
    // and the first thing anyone sees is the panels of the first screen
    // arriving, not the whole app sliding in from somewhere.
    _fit();
  }

  @override
  void didUpdateWidget(MeshScreenSwitcher old) {
    super.didUpdateWidget(old);
    _fit();
    if (widget.index != old.index) _travel();
  }

  @override
  void dispose() {
    for (final slot in _slots) {
      slot.dispose();
    }
    super.dispose();
  }

  /// Where screen [i] sits when nothing is moving.
  double _restingSlot(int i) => (i - widget.index).sign.toDouble();

  /// Grows or shrinks the slot list to match the children.
  void _fit() {
    while (_slots.length < widget.children.length) {
      _slots.add(MeshSpring(vsync: this, value: _restingSlot(_slots.length)));
    }
    while (_slots.length > widget.children.length) {
      _slots.removeLast().dispose();
    }
  }

  void _travel() {
    final tempo = FilamentMotion.drift(context);
    for (var i = 0; i < _slots.length; i++) {
      final slot = _slots[i];
      final target = _restingSlot(i);
      if (slot.target == target) continue;
      if (i == widget.index || slot.value.abs() < _gone) {
        // The screen you asked for, and anything still visible on its way out,
        // travel. A retarget picks up the position and velocity it had.
        slot.animateTo(target, tempo: tempo);
      } else {
        // Already off stage: it changes sides where nobody can see it.
        slot.snapTo(target);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final distance = FilamentMotion.reducedIn(context)
        ? 0.0
        : FilamentMotion.screenSlide;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        for (var i = 0; i < widget.children.length; i++)
          // One builder per screen, each holding its own child: a frame of the
          // transition rebuilds four wrappers, not four screens.
          AnimatedBuilder(
            animation: _slots[i].animation,
            key: ValueKey<int>(i),
            child: widget.children[i],
            builder: (context, child) => _stage(i, child!, distance),
          ),
      ],
    );
  }

  /// The wrapper is the same shape on every frame, on stage or off. Swapping
  /// widget types around a screen would rebuild it from scratch, which is the
  /// one thing this widget exists to avoid.
  Widget _stage(int i, Widget child, double distance) {
    final slot = _slots[i].value;
    final travelled = slot.abs().clamp(0.0, 1.0);
    final onStage = travelled < _gone;
    return ExcludeFocus(
      excluding: !onStage,
      child: IgnorePointer(
        // The screen on its way out is a picture, not a control surface.
        ignoring: !onStage || i != widget.index,
        child: Offstage(
          offstage: !onStage,
          child: Opacity(
            opacity: 1 - travelled,
            child: Transform.translate(
              offset: Offset(0, slot * distance),
              child: TickerMode(enabled: onStage, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// The standard screen body: a scrolling column of panels with the screen's
/// title above them.
///
/// Screens use this so padding, gaps and scroll behaviour stay identical
/// across destinations.
///
/// It also owns **panel arrival**: the first time the screen is seen, its
/// header and panels rise [FilamentMotion.slide] and fade in, top to bottom,
/// [FilamentMotion.stagger] apart. Once. A poll, a rebuild, or coming back to a
/// screen you have already been on never replays it — arrival is a fact about
/// the screen, not about the data on it.
class MeshScreen extends StatefulWidget {
  const MeshScreen({
    required this.title,
    required this.children,
    this.actions = const <Widget>[],
    this.subtitle,
    this.scrollable = true,
    super.key,
  });

  final String title;
  final String? subtitle;

  /// Right of the title.
  final List<Widget> actions;

  /// Panels, top to bottom. Gaps are inserted between them.
  final List<Widget> children;

  final bool scrollable;

  @override
  State<MeshScreen> createState() => _MeshScreenState();
}

class _MeshScreenState extends State<MeshScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _arrival = AnimationController(vsync: this);

  /// Whether the screen has ever been on stage. Until it has, there is nothing
  /// to arrive in front of.
  bool _started = false;

  /// Set once the last panel has landed. From then on the wrappers are
  /// identities and cost nothing.
  bool _arrived = false;

  // The arrival's shape, fixed when it starts so that a panel appearing
  // mid-flight cannot stretch the timeline under the panels above it.
  double _rampMs = 1;
  double _staggerMs = 0;
  double _totalMs = 1;
  double _rise = 0;
  Curve _curve = Curves.linear;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Arrival is the first time the screen is *seen*, not the first time it is
    // built: the scaffold builds every destination up front and holds the ones
    // you are not looking at off stage with their tickers muted. That mute is
    // the signal — when it lifts, the screen is on screen.
    if (!_started && TickerMode.valuesOf(context).enabled) _begin();
  }

  void _begin() {
    _started = true;
    final tempo = FilamentMotion.drift(context);
    final reduced = FilamentMotion.reducedIn(context);
    _curve = tempo.curve;
    _rampMs = tempo.duration.inMicroseconds / 1000;
    // Reduced motion keeps the fade and drops both the travel and the
    // procession: everything lands at once, 90ms, no rise.
    _staggerMs = reduced ? 0 : FilamentMotion.stagger.inMicroseconds / 1000;
    _rise = reduced ? 0 : FilamentMotion.slide;
    _totalMs = _rampMs + _staggerMs * widget.children.length;
    _arrival
      ..duration = Duration(microseconds: (_totalMs * 1000).round())
      ..addStatusListener(_onStatus)
      ..forward(from: 0);
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _arrived || !mounted) return;
    setState(() => _arrived = true);
  }

  @override
  void dispose() {
    _arrival.dispose();
    super.dispose();
  }

  /// How far step [step] has arrived: 0 nowhere, 1 landed. Step 0 is the
  /// header, so the screen reads top to bottom as one procession rather than a
  /// title that is already there watching its panels turn up.
  double _phase(int step) {
    if (!_started || _arrived) return 1;
    final raw = _arrival.value;
    if (raw >= 1) return 1;
    final t = (raw * _totalMs - _staggerMs * step) / _rampMs;
    return _curve.transform(t.clamp(0.0, 1.0));
  }

  /// Always the same widgets around [child], landed or not: a wrapper that
  /// appears and disappears would rebuild the panel under it.
  Widget _arrive(int step, Widget child) => AnimatedBuilder(
    animation: _arrival,
    child: child,
    builder: (context, child) {
      final t = _phase(step);
      return Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * _rise),
          child: child,
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _arrive(
          0,
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.title, style: theme.type.section),
                    if (widget.subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(widget.subtitle!, style: theme.type.small),
                    ],
                  ],
                ),
              ),
              if (widget.actions.isNotEmpty)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < widget.actions.length; i++) ...[
                      if (i > 0) const SizedBox(width: FilamentSpace.x2),
                      widget.actions[i],
                    ],
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: FilamentSpace.x5),
        for (var i = 0; i < widget.children.length; i++) ...[
          if (i > 0) const SizedBox(height: FilamentSpace.gap),
          _arrive(i + 1, widget.children[i]),
        ],
      ],
    );

    // Room at the bottom for the shade under the last panel, which would
    // otherwise be clipped by the scroll view's edge.
    const padding = EdgeInsets.fromLTRB(
      FilamentSpace.x5,
      FilamentSpace.x5,
      FilamentSpace.x5,
      FilamentSpace.x8,
    );

    if (!widget.scrollable) {
      return Padding(padding: padding, child: content);
    }
    return SingleChildScrollView(padding: padding, child: content);
  }
}
