/// `MeshToast` — bottom-right transient notices, one at a time.
///
/// Toasts are for things that succeeded and left no trace on screen ("key
/// minted", "copied"). Failures belong in the panel that caused them, quoted
/// verbatim, not here.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../icons/mesh_icons.dart';
import '../theme/theme.dart';
import 'motion.dart';
import 'status_dot.dart';

abstract final class MeshToast {
  static OverlayEntry? _current;

  /// Replaces any toast already on screen.
  static void show(
    BuildContext context,
    String message, {
    MeshTone tone = MeshTone.neutral,
    Duration duration = const Duration(seconds: 3),
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    dismiss();

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _MeshToastHost(
        message: message,
        tone: tone,
        duration: duration,
        onGone: () {
          if (identical(_current, entry)) {
            _current = null;
            entry.remove();
          }
        },
      ),
    );
    _current = entry;
    overlay.insert(entry);
  }

  /// Removes the current toast immediately, if any.
  static void dismiss() {
    _current?.remove();
    _current = null;
  }
}

class _MeshToastHost extends StatefulWidget {
  const _MeshToastHost({
    required this.message,
    required this.tone,
    required this.duration,
    required this.onGone,
  });

  final String message;
  final MeshTone tone;
  final Duration duration;
  final VoidCallback onGone;

  @override
  State<_MeshToastHost> createState() => _MeshToastHostState();
}

class _MeshToastHostState extends State<_MeshToastHost>
    with SingleTickerProviderStateMixin {
  /// 0 is 12px below the resting place and invisible, 1 is landed. The entry
  /// springs; the exit is timed, because leaving does not get to overshoot.
  late final MeshSpring _rise = MeshSpring(vsync: this);
  Timer? _timer;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _rise.reduced = FilamentMotion.reducedIn(context);
    if (_started) return;
    _started = true;
    _rise.animateTo(1);
    _timer = Timer(widget.duration, () async {
      if (!mounted) return;
      _rise.animateTo(0, tempo: FilamentMotion.dismiss(context));
      await Future<void>.delayed(FilamentMotion.dismiss(context).duration);
      if (mounted) widget.onGone();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _rise.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;

    return Positioned(
      right: FilamentSpace.x5,
      bottom: FilamentSpace.x5,
      child: AnimatedBuilder(
        animation: _rise.animation,
        builder: (context, child) {
          final t = _rise.value;
          return Opacity(
            opacity: t.clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, (1 - t) * FilamentMotion.toastRise),
              child: child,
            ),
          );
        },
        child: IgnorePointer(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: tokens.surfaceHigh,
                border: Border.all(color: tokens.hairlineHigh),
                borderRadius: BorderRadius.circular(FilamentRadius.panel),
                boxShadow: tokens.shade,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: FilamentSpace.x4,
                  vertical: FilamentSpace.x3,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.tone == MeshTone.alarm ||
                        widget.tone == MeshTone.caution)
                      MeshIcon(
                        MeshGlyph.warning,
                        size: 14,
                        color: widget.tone.color(tokens),
                      )
                    else
                      MeshStatusDot(
                        tone: widget.tone,
                        size: 7,
                        glow: widget.tone == MeshTone.signal,
                      ),
                    const SizedBox(width: FilamentSpace.x2),
                    Flexible(
                      child: Text(widget.message, style: theme.type.body),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
