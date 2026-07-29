/// `MeshTooltip` — a small surfaceHigh bubble on hover.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../theme/theme.dart';

/// Names a thing on hover. Used on triads, icon-only buttons and truncated ids.
///
/// Appears after [waitDuration], fades in flat, never follows the pointer and
/// never blocks it.
class MeshTooltip extends StatefulWidget {
  const MeshTooltip({
    required this.message,
    required this.child,
    this.waitDuration = const Duration(milliseconds: 400),
    this.maxWidth = 260,
    super.key,
  });

  /// Plain text; newlines are honoured. Empty means no tooltip at all.
  final String message;
  final Widget child;
  final Duration waitDuration;
  final double maxWidth;

  @override
  State<MeshTooltip> createState() => _MeshTooltipState();
}

class _MeshTooltipState extends State<MeshTooltip> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _entry;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _remove();
    super.dispose();
  }

  void _scheduleShow() {
    if (widget.message.isEmpty || _entry != null) return;
    _timer?.cancel();
    _timer = Timer(widget.waitDuration, _show);
  }

  void _show() {
    if (!mounted || _entry != null) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;

    // Above unless there is no room above, in which case below.
    final box = context.findRenderObject() as RenderBox?;
    var above = true;
    if (box != null && box.hasSize) {
      final top = box.localToGlobal(Offset.zero).dy;
      above = top > 56;
    }

    final theme = FilamentTheme.of(context);
    _entry = OverlayEntry(
      builder: (_) => Positioned(
        left: 0,
        top: 0,
        child: CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: above ? Alignment.topCenter : Alignment.bottomCenter,
          followerAnchor: above ? Alignment.bottomCenter : Alignment.topCenter,
          offset: Offset(0, above ? -6 : 6),
          child: IgnorePointer(
            child: _Bubble(
              message: widget.message,
              maxWidth: widget.maxWidth,
              tokens: theme.tokens,
              style: theme.type.small.copyWith(color: theme.tokens.textDim),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_entry!);
  }

  void _hide() {
    _timer?.cancel();
    _remove();
  }

  void _remove() {
    _entry?.remove();
    _entry = null;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.message.isEmpty) return widget.child;
    return CompositedTransformTarget(
      link: _link,
      child: MouseRegion(
        onEnter: (_) => _scheduleShow(),
        onExit: (_) => _hide(),
        child: widget.child,
      ),
    );
  }
}

class _Bubble extends StatefulWidget {
  const _Bubble({
    required this.message,
    required this.maxWidth,
    required this.tokens,
    required this.style,
  });

  final String message;
  final double maxWidth;
  final FilamentTokens tokens;
  final TextStyle style;

  @override
  State<_Bubble> createState() => _BubbleState();
}

class _BubbleState extends State<_Bubble> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The bubble is born fading in, so the tempo has to be resolved before the
    // first frame rather than at the next state change.
    _controller.duration = FilamentMotion.touch(context).duration;
    if (!_started) {
      _started = true;
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: FilamentMotion.touch(context).drive(_controller),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.maxWidth),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: widget.tokens.surfaceHigh,
            border: Border.all(color: widget.tokens.hairline),
            borderRadius: BorderRadius.circular(FilamentRadius.control),
            boxShadow: widget.tokens.shade,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FilamentSpace.x2 + 2,
              vertical: FilamentSpace.x2 - 2,
            ),
            child: Text(
              widget.message,
              style: widget.style,
              textAlign: TextAlign.left,
            ),
          ),
        ),
      ),
    );
  }
}
