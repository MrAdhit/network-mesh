/// `MeshSelect` — a small popup list. Not a dropdown with a shadow; a panel.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../icons/mesh_icons.dart';
import '../theme/theme.dart';
import 'button.dart';

/// One choice.
class MeshSelectOption<T> {
  const MeshSelectOption(this.value, this.label, {this.detail});

  final T value;
  final String label;

  /// Mono, dim, right-aligned. For "2s" style annotations.
  final String? detail;
}

/// A value picker.
///
/// Opens on click, Enter or Space; arrows move the highlight; Enter commits;
/// Esc or a click outside closes without changing anything.
class MeshSelect<T> extends StatefulWidget {
  const MeshSelect({
    required this.value,
    required this.options,
    required this.onChanged,
    this.width,
    this.mono = false,
    this.placeholder = 'Select',
    super.key,
  });

  final T value;
  final List<MeshSelectOption<T>> options;

  /// Null disables the control.
  final ValueChanged<T>? onChanged;

  final double? width;
  final bool mono;
  final String placeholder;

  @override
  State<MeshSelect<T>> createState() => _MeshSelectState<T>();
}

class _MeshSelectState<T> extends State<MeshSelect<T>> {
  final LayerLink _link = LayerLink();
  final FocusNode _triggerFocus = FocusNode(debugLabel: 'MeshSelect');
  OverlayEntry? _entry;
  bool _hovered = false;
  bool _focused = false;
  int _highlighted = 0;

  bool get _enabled => widget.onChanged != null && widget.options.isNotEmpty;
  bool get _open => _entry != null;

  @override
  void dispose() {
    _removeEntry();
    _triggerFocus.dispose();
    super.dispose();
  }

  MeshSelectOption<T>? get _selected {
    for (final o in widget.options) {
      if (o.value == widget.value) return o;
    }
    return null;
  }

  void _toggleOpen() => _open ? _close() : _openMenu();

  void _openMenu() {
    if (!_enabled || _open) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    final box = context.findRenderObject() as RenderBox?;
    if (overlay == null || box == null) return;

    _highlighted = widget.options.indexWhere((o) => o.value == widget.value);
    if (_highlighted < 0) _highlighted = 0;

    final width = widget.width ?? box.size.width;
    _entry = OverlayEntry(
      builder: (context) => _MeshSelectMenu<T>(
        link: _link,
        width: width,
        anchorHeight: box.size.height,
        options: widget.options,
        selected: widget.value,
        mono: widget.mono,
        initialHighlight: _highlighted,
        onPick: (value) {
          _close();
          widget.onChanged?.call(value);
        },
        onDismiss: _close,
      ),
    );
    overlay.insert(_entry!);
    setState(() {});
  }

  void _close() {
    if (!_open) return;
    _removeEntry();
    if (mounted) {
      setState(() {});
      _triggerFocus.requestFocus();
    }
  }

  void _removeEntry() {
    _entry?.remove();
    _entry = null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;
    final selected = _selected;
    final touch = FilamentMotion.touch(context);
    final settle = FilamentMotion.settle(context);

    final label = selected?.label ?? widget.placeholder;
    final style = (widget.mono ? theme.type.mono : theme.type.body).copyWith(
      color: !_enabled
          ? tokens.textFaint
          : (selected == null ? tokens.textFaint : tokens.text),
    );

    Widget trigger = AnimatedContainer(
      duration: touch.duration,
      curve: touch.curve,
      height: FilamentMetrics.controlHeight,
      padding: const EdgeInsets.only(left: FilamentSpace.x2 + 2, right: 6),
      decoration: BoxDecoration(
        color: _enabled
            ? (_hovered
                  ? tokens.hovered(tokens.surfaceHigh)
                  : tokens.surfaceHigh)
            : tokens.surface,
        border: Border.all(
          color: _hovered || _focused || _open
              ? tokens.hairlineHigh
              : tokens.hairline,
        ),
        borderRadius: BorderRadius.circular(FilamentRadius.control),
      ),
      child: Row(
        mainAxisSize: widget.width == null
            ? MainAxisSize.min
            : MainAxisSize.max,
        children: [
          Flexible(
            child: Text(label, style: style, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: FilamentSpace.x2),
          AnimatedRotation(
            turns: _open ? 0.5 : 0,
            duration: settle.duration,
            curve: settle.curve,
            child: MeshIcon(
              MeshGlyph.chevron,
              size: 15,
              color: _enabled ? tokens.textDim : tokens.textFaint,
            ),
          ),
        ],
      ),
    );

    trigger = MeshFocusRing(focused: _focused, child: trigger);

    trigger = FocusableActionDetector(
      enabled: _enabled,
      focusNode: _triggerFocus,
      mouseCursor: _enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onShowHoverHighlight: (v) => setState(() => _hovered = v),
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _toggleOpen();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _enabled ? _toggleOpen : null,
        child: trigger,
      ),
    );

    final linked = CompositedTransformTarget(link: _link, child: trigger);
    return widget.width == null
        ? linked
        : SizedBox(width: widget.width, child: linked);
  }
}

class _MeshSelectMenu<T> extends StatefulWidget {
  const _MeshSelectMenu({
    required this.link,
    required this.width,
    required this.anchorHeight,
    required this.options,
    required this.selected,
    required this.mono,
    required this.initialHighlight,
    required this.onPick,
    required this.onDismiss,
  });

  final LayerLink link;
  final double width;
  final double anchorHeight;
  final List<MeshSelectOption<T>> options;
  final T selected;
  final bool mono;
  final int initialHighlight;
  final ValueChanged<T> onPick;
  final VoidCallback onDismiss;

  @override
  State<_MeshSelectMenu<T>> createState() => _MeshSelectMenuState<T>();
}

class _MeshSelectMenuState<T> extends State<_MeshSelectMenu<T>> {
  late int _highlighted = widget.initialHighlight;
  final FocusNode _focus = FocusNode(debugLabel: 'MeshSelect menu');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      widget.onDismiss();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _highlighted = (_highlighted + 1) % widget.options.length);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(
        () => _highlighted =
            (_highlighted - 1 + widget.options.length) % widget.options.length,
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      widget.onPick(widget.options[_highlighted].value);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;

    return Stack(
      children: [
        // Anything outside the menu dismisses it.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onDismiss,
          ),
        ),
        Positioned(
          left: 0,
          top: 0,
          child: CompositedTransformFollower(
            link: widget.link,
            showWhenUnlinked: false,
            targetAnchor: Alignment.bottomLeft,
            followerAnchor: Alignment.topLeft,
            offset: const Offset(0, FilamentSpace.x1 + 2),
            child: Focus(
              focusNode: _focus,
              onKeyEvent: _onKey,
              child: SizedBox(
                width: widget.width,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: tokens.surface,
                    border: Border.all(color: tokens.hairlineHigh),
                    borderRadius: BorderRadius.circular(FilamentRadius.control),
                    boxShadow: tokens.shade,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(
                      FilamentRadius.control - 1,
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 260),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var i = 0; i < widget.options.length; i++)
                              _MeshSelectItem<T>(
                                option: widget.options[i],
                                mono: widget.mono,
                                selected:
                                    widget.options[i].value == widget.selected,
                                highlighted: i == _highlighted,
                                onHover: () => setState(() => _highlighted = i),
                                onTap: () =>
                                    widget.onPick(widget.options[i].value),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MeshSelectItem<T> extends StatelessWidget {
  const _MeshSelectItem({
    required this.option,
    required this.mono,
    required this.selected,
    required this.highlighted,
    required this.onHover,
    required this.onTap,
  });

  final MeshSelectOption<T> option;
  final bool mono;
  final bool selected;
  final bool highlighted;
  final VoidCallback onHover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHover(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: FilamentMetrics.controlHeight,
          color: highlighted ? tokens.surfaceHigh : null,
          padding: const EdgeInsets.symmetric(horizontal: FilamentSpace.x2 + 2),
          child: Row(
            children: [
              SizedBox(
                width: 9,
                child: selected
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: SizedBox(
                          width: 3,
                          height: 3,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: tokens.signal,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      )
                    : null,
              ),
              Expanded(
                child: Text(
                  option.label,
                  style: (mono ? theme.type.mono : theme.type.body).copyWith(
                    color: selected ? tokens.signal : tokens.text,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (option.detail != null) ...[
                const SizedBox(width: FilamentSpace.x2),
                Text(option.detail!, style: theme.type.monoSmall),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
