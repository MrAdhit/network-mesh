/// `MeshToggle` — a 28x16 track with a 12px knob.
library;

import 'package:flutter/widgets.dart';

import '../theme/theme.dart';
import 'button.dart';

/// An on/off switch. Flat: the knob slides, nothing bounces.
class MeshToggle extends StatefulWidget {
  const MeshToggle({
    required this.value,
    required this.onChanged,
    this.label,
    this.description,
    super.key,
  });

  final bool value;

  /// Null disables the toggle.
  final ValueChanged<bool>? onChanged;

  /// Optional text to the right, which is also a click target.
  final String? label;

  /// A quiet second line under the label.
  final String? description;

  @override
  State<MeshToggle> createState() => _MeshToggleState();
}

class _MeshToggleState extends State<MeshToggle> {
  bool _hovered = false;
  bool _focused = false;

  bool get _enabled => widget.onChanged != null;

  void _toggle() {
    if (_enabled) widget.onChanged!(!widget.value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;

    final trackColor = !_enabled
        ? tokens.surfaceHigh
        : widget.value
        ? (_hovered ? tokens.hovered(tokens.signal) : tokens.signal)
        : (_hovered ? tokens.hovered(tokens.surfaceHigh) : tokens.surfaceHigh);

    final knobColor = !_enabled
        ? tokens.textFaint
        : widget.value
        ? tokens.bg
        : tokens.textDim;

    final touch = FilamentMotion.touch(context);
    final settle = FilamentMotion.settle(context);

    Widget track = AnimatedContainer(
      duration: touch.duration,
      curve: touch.curve,
      width: 28,
      height: 16,
      decoration: BoxDecoration(
        color: trackColor,
        borderRadius: BorderRadius.circular(FilamentRadius.pill),
        border: Border.all(
          color: widget.value
              ? trackColor
              : (_hovered || _focused ? tokens.hairlineHigh : tokens.hairline),
        ),
      ),
      child: AnimatedAlign(
        duration: settle.duration,
        curve: settle.curve,
        alignment: widget.value ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: SizedBox.square(
            dimension: 12,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: knobColor,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );

    track = MeshFocusRing(
      focused: _focused,
      radius: FilamentRadius.pill,
      child: track,
    );

    Widget content = track;
    if (widget.label != null) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: track),
          const SizedBox(width: FilamentSpace.x3),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.label!,
                  style: theme.type.body.copyWith(
                    color: _enabled ? tokens.text : tokens.textFaint,
                  ),
                ),
                if (widget.description != null) ...[
                  const SizedBox(height: 3),
                  Text(widget.description!, style: theme.type.small),
                ],
              ],
            ),
          ),
        ],
      );
    }

    return FocusableActionDetector(
      enabled: _enabled,
      mouseCursor: _enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onShowHoverHighlight: (v) => setState(() => _hovered = v),
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _toggle();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _enabled ? _toggle : null,
        child: content,
      ),
    );
  }
}
