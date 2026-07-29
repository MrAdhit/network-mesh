/// The motion primitives the kit springs on.
///
/// `FilamentMotion` says how fast and what shape; this file is the machinery
/// that runs it. Everything that moves in the kit goes through [MeshSpring] or
/// one of the builders below — a widget that reaches for its own curve is a
/// bug, and one that checks the reduced-motion flag itself is a duplicate of
/// the resolver in `FilamentMotion`.
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/physics.dart' show SpringDescription, SpringSimulation;
import 'package:flutter/widgets.dart';

import '../theme/theme.dart';

/// One double on the settle spring, retargetable mid-flight.
///
/// A second call to [animateTo] before the first has landed does not queue and
/// does not restart: the new simulation begins at the current position *and*
/// the current velocity, so the value keeps moving through the change of mind.
/// Handing it the target it is already heading for costs nothing, which is what
/// keeps a 2s poll from animating anything.
///
/// Set [reduced] and every move becomes the 90ms linear crossfade instead. The
/// builders below read it off the platform for you.
class MeshSpring implements ValueListenable<double> {
  MeshSpring({
    required TickerProvider vsync,
    double value = 0,
    SpringDescription? spring,
    bool reduced = false,
  }) : _spring = spring ?? FilamentMotion.settleSpring,
       _reduced = reduced,
       _target = value,
       _controller = AnimationController.unbounded(vsync: vsync, value: value);

  final AnimationController _controller;
  SpringDescription _spring;
  bool _reduced;
  double _target;

  /// Where the value is right now — overshoot included, so clamp at the call
  /// site if the extra sliver would show as a gap.
  @override
  double get value => _controller.value;

  /// Units per second, 0 at rest. What a retarget carries over.
  double get velocity => _controller.velocity;

  /// Where it is heading.
  double get target => _target;

  bool get isAnimating => _controller.isAnimating;

  /// For `AnimatedBuilder`, or anything else that wants the raw animation.
  Animation<double> get animation => _controller.view;

  @override
  void addListener(VoidCallback listener) => _controller.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _controller.removeListener(listener);

  /// Swaps the spring under a moving value. The in-flight move retargets onto
  /// the new one rather than finishing on the old.
  set spring(SpringDescription value) {
    if (identical(_spring, value)) return;
    _spring = value;
    if (isAnimating && !_reduced) _start(_target);
  }

  bool get reduced => _reduced;

  set reduced(bool value) {
    if (_reduced == value) return;
    _reduced = value;
    // Mid-flight when the platform changes its mind: land it immediately
    // rather than let a spring finish under someone who asked for stillness.
    if (value && isAnimating) snapTo(_target);
  }

  /// Heads for [target]. Already heading there? Nothing happens.
  ///
  /// Pass a [tempo] to run this one move on a timed curve instead of the
  /// spring — what "leaving" wants: dismissals do not overshoot.
  void animateTo(double target, {FilamentTempo? tempo}) {
    if (target == _target) return;
    _target = target;
    _run(target, tempo);
  }

  /// Re-runs the current target, spring or tempo. Only for a widget that has
  /// just had its target changed out from under it by something other than
  /// [animateTo] — most callers want [animateTo].
  void restart({FilamentTempo? tempo}) => _run(_target, tempo);

  void _run(double target, FilamentTempo? tempo) {
    final timed = tempo ?? (_reduced ? FilamentMotion.reducedTempo : null);
    if (timed != null) {
      if (_controller.value == target) {
        _controller.stop();
        return;
      }
      _controller.animateTo(
        target,
        duration: timed.duration,
        curve: timed.curve,
      );
      return;
    }
    _start(target);
  }

  void _start(double target) {
    final from = _controller.value;
    final speed = _controller.velocity;
    if (from == target && speed == 0) {
      _controller.stop();
      return;
    }
    _controller.animateWith(
      SpringSimulation(
        _spring,
        from,
        target,
        speed,
        tolerance: FilamentMotion.settleTolerance,
      ),
    );
  }

  /// Teleports. For arrival, where there is nothing to travel from.
  void snapTo(double value) {
    _target = value;
    _controller
      ..stop()
      ..value = value;
  }

  void dispose() => _controller.dispose();
}

/// Springs [value] and rebuilds with wherever the spring has got to.
///
/// ```dart
/// MeshSpringBuilder(
///   value: open ? 1 : 0,
///   builder: (context, t, child) => Opacity(opacity: t.clamp(0, 1), child: child),
///   child: panel,
/// )
/// ```
///
/// The [child] is built once and handed back to [builder] on every frame, so
/// put anything that does not depend on the animation there.
class MeshSpringBuilder extends StatefulWidget {
  const MeshSpringBuilder({
    required this.value,
    required this.builder,
    this.spring,
    this.child,
    super.key,
  });

  /// The target. Changing it retargets from wherever the spring is.
  final double value;

  final ValueWidgetBuilder<double> builder;

  /// Defaults to the settle spring, which is what everything in the kit uses.
  final SpringDescription? spring;

  final Widget? child;

  @override
  State<MeshSpringBuilder> createState() => _MeshSpringBuilderState();
}

class _MeshSpringBuilderState extends State<MeshSpringBuilder>
    with SingleTickerProviderStateMixin {
  late final MeshSpring _spring = MeshSpring(
    vsync: this,
    value: widget.value,
    spring: widget.spring,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _spring.reduced = FilamentMotion.reducedIn(context);
  }

  @override
  void didUpdateWidget(MeshSpringBuilder old) {
    super.didUpdateWidget(old);
    if (widget.spring != null) _spring.spring = widget.spring!;
    _spring.animateTo(widget.value);
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _spring.animation,
    builder: (context, child) => widget.builder(context, _spring.value, child),
    child: widget.child,
  );
}

/// [MeshSpringBuilder] in two dimensions: x and y each get their own spring, so
/// a diagonal retarget keeps the momentum it had on both axes.
class MeshSpringOffsetBuilder extends StatefulWidget {
  const MeshSpringOffsetBuilder({
    required this.value,
    required this.builder,
    this.spring,
    this.child,
    super.key,
  });

  final Offset value;
  final ValueWidgetBuilder<Offset> builder;
  final SpringDescription? spring;
  final Widget? child;

  @override
  State<MeshSpringOffsetBuilder> createState() =>
      _MeshSpringOffsetBuilderState();
}

class _MeshSpringOffsetBuilderState extends State<MeshSpringOffsetBuilder>
    with TickerProviderStateMixin {
  late final MeshSpring _x = MeshSpring(
    vsync: this,
    value: widget.value.dx,
    spring: widget.spring,
  );
  late final MeshSpring _y = MeshSpring(
    vsync: this,
    value: widget.value.dy,
    spring: widget.spring,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = FilamentMotion.reducedIn(context);
    _x.reduced = reduced;
    _y.reduced = reduced;
  }

  @override
  void didUpdateWidget(MeshSpringOffsetBuilder old) {
    super.didUpdateWidget(old);
    if (widget.spring != null) {
      _x.spring = widget.spring!;
      _y.spring = widget.spring!;
    }
    _x.animateTo(widget.value.dx);
    _y.animateTo(widget.value.dy);
  }

  @override
  void dispose() {
    _x.dispose();
    _y.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge(<Listenable>[_x.animation, _y.animation]),
    builder: (context, child) =>
        widget.builder(context, Offset(_x.value, _y.value), child),
    child: widget.child,
  );
}

/// Eases [color] to its new value on a tempo — `drift` unless you say
/// otherwise. Colours do not spring: an overshoot past a token is a colour the
/// palette does not contain.
class MeshColorBuilder extends StatelessWidget {
  const MeshColorBuilder({
    required this.color,
    required this.builder,
    this.tempo,
    this.child,
    super.key,
  });

  final Color color;
  final ValueWidgetBuilder<Color> builder;

  /// Defaults to `FilamentMotion.drift(context)`.
  final FilamentTempo? tempo;

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final resolved = tempo ?? FilamentMotion.drift(context);
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: color),
      duration: resolved.duration,
      curve: resolved.curve,
      builder: (context, value, child) =>
          builder(context, value ?? color, child),
      child: child,
    );
  }
}

/// Opens and closes [child] vertically on the settle spring — `AnimatedSize`
/// for the one case the kit has, a row revealing what is under it.
///
/// The child keeps its natural height and is clipped to a fraction of it, so
/// nothing inside relayouts as it opens. Overshoot is clamped: past full height
/// there is nothing left to reveal.
class MeshSpringReveal extends StatelessWidget {
  const MeshSpringReveal({
    required this.open,
    required this.reveal,
    this.alignment = Alignment.topCenter,
    super.key,
  });

  final bool open;

  /// Built only while there is something to see — never while closed, and
  /// again on the way back down until the row is flat.
  final WidgetBuilder reveal;

  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    return MeshSpringBuilder(
      value: open ? 1 : 0,
      builder: (context, t, _) {
        final factor = t.clamp(0.0, 1.0);
        // A spring lands near zero rather than on it; a hair of a row is not
        // worth keeping a subtree alive for.
        if (!open && factor < 0.001) return const SizedBox.shrink();
        return ClipRect(
          child: Align(
            alignment: alignment,
            heightFactor: factor,
            child: reveal(context),
          ),
        );
      },
    );
  }
}
