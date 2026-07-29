/// `MeshButton` — four variants, 28px tall, radius 6, no ripple. Plus the
/// icon-only form, the spinner they share, and the two async variants that
/// hold their own busy state.
library;

import 'dart:async' show unawaited;
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../icons/mesh_icons.dart';
import '../theme/theme.dart';
import 'motion.dart';
import 'tooltip.dart';

/// Which statement the button is making.
///
/// There is at most one [primary] per screen — it is the only decorated thing
/// in a resting UI that is not reporting state.
enum MeshButtonVariant { primary, secondary, destructive, ghost }

/// The kit's button. Hover brightens the fill, press darkens it, focus draws
/// the ring. Nothing ripples.
class MeshButton extends StatefulWidget {
  const MeshButton({
    required this.label,
    required this.onPressed,
    this.variant = MeshButtonVariant.secondary,
    this.glyph,
    this.busy = false,
    this.autofocus = false,
    this.expand = false,
    this.tooltip,
    super.key,
  });

  /// Signal fill, `bg`-coloured text. One per screen.
  const MeshButton.primary({
    required String label,
    required VoidCallback? onPressed,
    MeshGlyph? glyph,
    bool busy = false,
    bool autofocus = false,
    bool expand = false,
    String? tooltip,
    Key? key,
  }) : this(
         label: label,
         onPressed: onPressed,
         variant: MeshButtonVariant.primary,
         glyph: glyph,
         busy: busy,
         autofocus: autofocus,
         expand: expand,
         tooltip: tooltip,
         key: key,
       );

  /// Alarm text and border. Never autofocused inside a dialog.
  const MeshButton.destructive({
    required String label,
    required VoidCallback? onPressed,
    MeshGlyph? glyph,
    bool busy = false,
    bool expand = false,
    String? tooltip,
    Key? key,
  }) : this(
         label: label,
         onPressed: onPressed,
         variant: MeshButtonVariant.destructive,
         glyph: glyph,
         busy: busy,
         expand: expand,
         tooltip: tooltip,
         key: key,
       );

  /// Text only.
  const MeshButton.ghost({
    required String label,
    required VoidCallback? onPressed,
    MeshGlyph? glyph,
    bool busy = false,
    String? tooltip,
    Key? key,
  }) : this(
         label: label,
         onPressed: onPressed,
         variant: MeshButtonVariant.ghost,
         glyph: glyph,
         busy: busy,
         tooltip: tooltip,
         key: key,
       );

  final String label;

  /// Null disables the button.
  final VoidCallback? onPressed;

  final MeshButtonVariant variant;
  final MeshGlyph? glyph;

  /// Shows a spinner in place of the label and refuses presses. Every async
  /// action gets one.
  final bool busy;

  final bool autofocus;

  /// Fills the available width instead of hugging the label.
  final bool expand;

  final String? tooltip;

  @override
  State<MeshButton> createState() => _MeshButtonState();
}

class _MeshButtonState extends State<MeshButton> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  bool get _enabled => widget.onPressed != null && !widget.busy;

  void _activate() {
    if (_enabled) widget.onPressed!();
  }

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;
    final style = _resolve(tokens);

    Widget content = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.glyph != null) ...[
          MeshIcon(widget.glyph!, size: 15, color: style.foreground),
          const SizedBox(width: FilamentSpace.x2 - 1),
        ],
        Text(
          widget.label,
          style: theme.type.body.copyWith(
            color: style.foreground,
            fontWeight: widget.variant == MeshButtonVariant.primary
                ? FontWeight.w600
                : FontWeight.w500,
          ),
        ),
      ],
    );

    if (widget.busy) {
      // Keep the label's width so the row does not twitch mid-request.
      content = Stack(
        alignment: Alignment.center,
        children: [
          Opacity(opacity: 0, child: content),
          MeshSpinner(size: 14, color: style.foreground),
        ],
      );
    }

    // A ghost has no edge to sit inside, so it needs less air than a button
    // that does; a glyph brings its own.
    final horizontal = widget.variant == MeshButtonVariant.ghost
        ? FilamentSpace.x2 + 2
        : (widget.glyph == null ? FilamentSpace.x3 + 2 : FilamentSpace.x3);

    final touch = FilamentMotion.touch(context);
    Widget button = AnimatedContainer(
      duration: touch.duration,
      curve: touch.curve,
      height: FilamentMetrics.controlHeight,
      padding: EdgeInsets.symmetric(horizontal: horizontal),
      decoration: BoxDecoration(
        color: style.fill,
        border: style.border == null ? null : Border.all(color: style.border!),
        borderRadius: BorderRadius.circular(FilamentRadius.control),
      ),
      alignment: Alignment.center,
      child: content,
    );

    button = CustomPaint(
      foregroundPainter: _focused && _enabled
          ? _FocusRingPainter(tokens.signal)
          : null,
      child: button,
    );

    button = MeshPressScale(pressed: _pressed && _enabled, child: button);

    button = FocusableActionDetector(
      enabled: _enabled,
      autofocus: widget.autofocus,
      mouseCursor: _enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onShowHoverHighlight: (v) => setState(() => _hovered = v),
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _activate();
            return null;
          },
        ),
        ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
          onInvoke: (_) {
            _activate();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
        onTap: _enabled ? _activate : null,
        child: button,
      ),
    );

    if (widget.tooltip != null) {
      button = MeshTooltip(message: widget.tooltip!, child: button);
    }
    return widget.expand
        ? SizedBox(width: double.infinity, child: button)
        : button;
  }

  _ButtonStyle _resolve(FilamentTokens t) {
    if (!_enabled) {
      final disabledFill = widget.variant == MeshButtonVariant.primary
          ? t.surfaceHigh
          : null;
      return _ButtonStyle(
        fill: widget.busy && widget.variant == MeshButtonVariant.primary
            ? t.signal.withValues(alpha: 0.5)
            : disabledFill,
        border: widget.variant == MeshButtonVariant.ghost ? null : t.hairline,
        foreground: widget.busy && widget.variant == MeshButtonVariant.primary
            ? t.bg
            : t.textFaint,
      );
    }

    Color state(Color base) =>
        _pressed ? t.pressed(base) : (_hovered ? t.hovered(base) : base);

    return switch (widget.variant) {
      MeshButtonVariant.primary => _ButtonStyle(
        fill: state(t.signal),
        border: null,
        foreground: t.bg,
      ),
      MeshButtonVariant.secondary => _ButtonStyle(
        fill: _pressed
            ? t.pressed(t.surfaceHigh)
            : (_hovered ? t.surfaceHigh : null),
        border: _hovered || _focused ? t.hairlineHigh : t.hairline,
        foreground: t.text,
      ),
      MeshButtonVariant.destructive => _ButtonStyle(
        fill: _hovered
            ? t.alarm.withValues(alpha: _pressed ? 0.22 : 0.14)
            : null,
        border: t.alarm.withValues(alpha: _hovered || _focused ? 0.7 : 0.45),
        foreground: t.alarm,
      ),
      MeshButtonVariant.ghost => _ButtonStyle(
        fill: _pressed
            ? t.pressed(t.surfaceHigh)
            : (_hovered ? t.surfaceHigh : null),
        border: null,
        foreground: _hovered ? t.text : t.textDim,
      ),
    };
  }
}

class _ButtonStyle {
  const _ButtonStyle({
    required this.fill,
    required this.border,
    required this.foreground,
  });

  final Color? fill;
  final Color? border;
  final Color foreground;
}

/// An icon-only button, for panel headers and table rows.
class MeshIconButton extends StatelessWidget {
  const MeshIconButton({
    required this.glyph,
    required this.onPressed,
    required this.tooltip,
    this.tone,
    this.size = 26,
    this.busy = false,
    this.turns = 0,
    super.key,
  });

  final MeshGlyph glyph;
  final VoidCallback? onPressed;

  /// Required: an icon with no label needs a name on hover.
  final String tooltip;

  final MeshTone? tone;
  final double size;
  final bool busy;
  final double turns;

  @override
  Widget build(BuildContext context) {
    return _MeshIconButtonBody(
      glyph: glyph,
      onPressed: onPressed,
      tooltip: tooltip,
      tone: tone,
      size: size,
      busy: busy,
      turns: turns,
    );
  }
}

class _MeshIconButtonBody extends StatefulWidget {
  const _MeshIconButtonBody({
    required this.glyph,
    required this.onPressed,
    required this.tooltip,
    required this.tone,
    required this.size,
    required this.busy,
    required this.turns,
  });

  final MeshGlyph glyph;
  final VoidCallback? onPressed;
  final String tooltip;
  final MeshTone? tone;
  final double size;
  final bool busy;
  final double turns;

  @override
  State<_MeshIconButtonBody> createState() => _MeshIconButtonBodyState();
}

class _MeshIconButtonBodyState extends State<_MeshIconButtonBody> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  bool get _enabled => widget.onPressed != null && !widget.busy;

  @override
  Widget build(BuildContext context) {
    final tokens = FilamentTheme.tokensOf(context);
    final base = widget.tone?.color(tokens) ?? tokens.textDim;
    final color = !_enabled
        ? tokens.textFaint
        : (_hovered || _focused
              ? (widget.tone == null ? tokens.text : base)
              : base);

    final touch = FilamentMotion.touch(context);
    Widget body = AnimatedContainer(
      duration: touch.duration,
      curve: touch.curve,
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: _enabled && (_hovered || _pressed)
            ? (_pressed
                  ? tokens.pressed(tokens.surfaceHigh)
                  : tokens.surfaceHigh)
            : null,
        borderRadius: BorderRadius.circular(FilamentRadius.control),
      ),
      alignment: Alignment.center,
      child: widget.busy
          ? MeshSpinner(size: widget.size * 0.6, color: color)
          : MeshIcon(
              widget.glyph,
              size: widget.size * 0.65,
              color: color,
              turns: widget.turns,
            ),
    );

    body = CustomPaint(
      foregroundPainter: _focused && _enabled
          ? _FocusRingPainter(tokens.signal)
          : null,
      child: body,
    );

    body = MeshPressScale(pressed: _pressed && _enabled, child: body);

    return MeshTooltip(
      message: widget.tooltip,
      child: FocusableActionDetector(
        enabled: _enabled,
        mouseCursor: _enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
          onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
          onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
          onTap: _enabled ? widget.onPressed : null,
          child: body,
        ),
      ),
    );
  }
}

/// Scales its child to `FilamentMotion.pressScale` while [pressed], on the
/// settle spring.
///
/// Transform only: pressing a button must not move anything around it, and the
/// release is where the system's one permitted overshoot lives.
class MeshPressScale extends StatelessWidget {
  const MeshPressScale({
    required this.pressed,
    required this.child,
    this.alignment = Alignment.center,
    super.key,
  });

  final bool pressed;
  final Widget child;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return MeshSpringBuilder(
      value: pressed ? FilamentMotion.pressScale : 1,
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, alignment: alignment, child: child),
      child: child,
    );
  }
}

/// The focus ring: 1.5px `signal` at 40%, offset 1px outside the control.
class _FocusRingPainter extends CustomPainter {
  _FocusRingPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      0,
      0,
      size.width,
      size.height,
    ).inflate(FilamentMetrics.focusRingOffset + FilamentMetrics.focusRing / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect,
        const Radius.circular(FilamentRadius.control + 2),
      ),
      Paint()
        ..color = color.withValues(alpha: FilamentMetrics.focusRingOpacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = FilamentMetrics.focusRing
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_FocusRingPainter old) => old.color != color;
}

/// A [MeshButton] that owns its own busy state.
///
/// Hand it the future-returning method itself — `daemon.refreshNow`,
/// `store.save` — and it stays busy until that future settles. For actions
/// whose busy flag already lives in a store (`store.loading`, `daemon.leaving`)
/// use [MeshButton] with `busy:` instead; two sources of truth for one spinner
/// is one too many.
class MeshAsyncButton extends StatefulWidget {
  const MeshAsyncButton({
    required this.label,
    required this.action,
    this.variant = MeshButtonVariant.secondary,
    this.glyph,
    this.expand = false,
    this.autofocus = false,
    this.tooltip,
    super.key,
  });

  final String label;

  /// Null disables the button.
  final Future<void> Function()? action;

  final MeshButtonVariant variant;
  final MeshGlyph? glyph;
  final bool expand;
  final bool autofocus;
  final String? tooltip;

  @override
  State<MeshAsyncButton> createState() => _MeshAsyncButtonState();
}

class _MeshAsyncButtonState extends State<MeshAsyncButton> {
  bool _busy = false;

  Future<void> _run() async {
    final action = widget.action;
    if (_busy || action == null) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      // The action reports its own failure through its store; all this cares
      // about is that the spinner stops either way.
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MeshButton(
      label: widget.label,
      variant: widget.variant,
      glyph: widget.glyph,
      busy: _busy,
      expand: widget.expand,
      autofocus: widget.autofocus,
      tooltip: widget.tooltip,
      onPressed: widget.action == null ? null : () => unawaited(_run()),
    );
  }
}

/// [MeshIconButton] with the same self-managed busy state as [MeshAsyncButton].
class MeshAsyncIconButton extends StatefulWidget {
  const MeshAsyncIconButton({
    required this.glyph,
    required this.action,
    required this.tooltip,
    this.tone,
    this.size = 26,
    super.key,
  });

  final MeshGlyph glyph;

  /// Null disables the button.
  final Future<void> Function()? action;

  final String tooltip;
  final MeshTone? tone;
  final double size;

  @override
  State<MeshAsyncIconButton> createState() => _MeshAsyncIconButtonState();
}

class _MeshAsyncIconButtonState extends State<MeshAsyncIconButton> {
  bool _busy = false;

  Future<void> _run() async {
    final action = widget.action;
    if (_busy || action == null) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MeshIconButton(
      glyph: widget.glyph,
      tooltip: widget.tooltip,
      tone: widget.tone,
      size: widget.size,
      busy: _busy,
      onPressed: widget.action == null ? null : () => unawaited(_run()),
    );
  }
}

/// Draws a focus ring around [child] when [focused]. For kit widgets that are
/// not buttons but still take focus.
class MeshFocusRing extends StatelessWidget {
  const MeshFocusRing({
    required this.focused,
    required this.child,
    this.radius = FilamentRadius.control,
    super.key,
  });

  final bool focused;
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    if (!focused) return child;
    return CustomPaint(
      foregroundPainter: _FocusRingPainter(
        FilamentTheme.tokensOf(context).signal,
      ),
      child: child,
    );
  }
}

/// A busy indicator: one arc, rotating, flat. No pulsing, no bouncing.
class MeshSpinner extends StatefulWidget {
  const MeshSpinner({this.size = 14, this.color, super.key});

  final double size;
  final Color? color;

  @override
  State<MeshSpinner> createState() => _MeshSpinnerState();
}

class _MeshSpinnerState extends State<MeshSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color =
        widget.color ??
        DefaultTextStyle.of(context).style.color ??
        FilamentTheme.tokensOf(context).textDim;
    return SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: _SpinnerPainter(color: color, turn: _controller.value),
        ),
      ),
    );
  }
}

class _SpinnerPainter extends CustomPainter {
  _SpinnerPainter({required this.color, required this.turn});

  final Color color;
  final double turn;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide * 0.14;
    final rect = Rect.fromLTWH(
      0,
      0,
      size.width,
      size.height,
    ).deflate(stroke / 2);
    canvas
      ..drawArc(
        rect,
        0,
        math.pi * 2,
        false,
        Paint()
          ..color = color.withValues(alpha: 0.2)
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke,
      )
      ..drawArc(
        rect,
        turn * math.pi * 2,
        math.pi * 0.65,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round,
      );
  }

  @override
  bool shouldRepaint(_SpinnerPainter old) =>
      old.turn != turn || old.color != color;
}
