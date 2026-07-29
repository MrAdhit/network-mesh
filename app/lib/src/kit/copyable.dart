/// `MeshCopyable` — click to copy, with a brief confirmation in place.
///
/// Every address, key and id in the app is wrapped in one of these.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../icons/mesh_icons.dart';
import '../theme/theme.dart';
import 'button.dart';

/// Copy the focused copyable. Bound to Cmd/Ctrl+C by `MeshApp`; a focused
/// text field's own copy binding wins over it, because that binding is
/// installed deeper in the tree.
class MeshCopyIntent extends Intent {
  const MeshCopyIntent();
}

/// Text plus a click-to-copy affordance.
class MeshCopyable extends StatefulWidget {
  const MeshCopyable(
    this.text, {
    this.display,
    this.mono = true,
    this.style,
    this.showIcon = true,
    this.confirmation = 'Copied',
    super.key,
  });

  /// What lands on the clipboard.
  final String text;

  /// What the user sees, when that differs — a shortened id, for instance.
  final String? display;

  final bool mono;
  final TextStyle? style;

  /// The copy glyph, shown on hover and focus. Off for dense table cells that
  /// would get noisy.
  final bool showIcon;

  /// The word shown after a successful copy.
  final String confirmation;

  @override
  State<MeshCopyable> createState() => _MeshCopyableState();
}

class _MeshCopyableState extends State<MeshCopyable> {
  bool _hovered = false;
  bool _focused = false;
  bool _copied = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;
    final base =
        widget.style ?? (widget.mono ? theme.type.mono : theme.type.body);
    final active = _hovered || _focused;
    final touch = FilamentMotion.touch(context);

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            widget.display ?? widget.text,
            style: base.copyWith(color: _copied ? tokens.signal : base.color),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (widget.showIcon) ...[
          const SizedBox(width: FilamentSpace.x2 - 1),
          SizedBox(
            height: 15,
            child: AnimatedSwitcher(
              duration: touch.duration,
              switchInCurve: touch.curve,
              child: _copied
                  ? Text(
                      widget.confirmation,
                      key: const ValueKey('copied'),
                      style: theme.type.small.copyWith(color: tokens.signal),
                    )
                  : Opacity(
                      key: const ValueKey('icon'),
                      opacity: active ? 1 : 0,
                      child: MeshIcon(
                        MeshGlyph.copy,
                        size: 14,
                        color: tokens.textFaint,
                      ),
                    ),
            ),
          ),
        ],
      ],
    );

    return Actions(
      actions: <Type, Action<Intent>>{
        MeshCopyIntent: CallbackAction<MeshCopyIntent>(
          onInvoke: (_) {
            unawaited(_copy());
            return null;
          },
        ),
      },
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              unawaited(_copy());
              return null;
            },
          ),
        },
        child: MeshFocusRing(
          focused: _focused,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => unawaited(_copy()),
            child: content,
          ),
        ),
      ),
    );
  }
}
