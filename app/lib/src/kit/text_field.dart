/// `MeshTextField` — `surfaceHigh` fill, hairline border, focus ring.
///
/// This is the one file in the UI allowed to reach for Flutter's text-editing
/// machinery, and it still does not import Material: [EditableText],
/// [TextSelectionGestureDetectorBuilder] and [emptyTextSelectionControls] all
/// live in `package:flutter/widgets.dart`. The context menu is explicitly
/// disabled (`contextMenuBuilder: null`) because the default one is Material's
/// adaptive toolbar, and selection handles are empty because this is a desktop
/// app driven by a mouse.
library;

import 'package:flutter/gestures.dart' show TapDragUpDetails;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../icons/mesh_icons.dart';
import '../theme/theme.dart';
import 'button.dart';

/// A single-line (or few-line) input.
class MeshTextField extends StatefulWidget {
  const MeshTextField({
    this.controller,
    this.focusNode,
    this.label,
    this.placeholder,
    this.helper,
    this.errorText,
    this.mono = false,
    this.secret = false,
    this.enabled = true,
    this.readOnly = false,
    this.autofocus = false,
    this.maxLines = 1,
    this.minLines,
    this.width,
    this.suffix,
    this.onChanged,
    this.onSubmitted,
    this.inputFormatters,
    this.keyboardType,
    super.key,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;

  /// 11px label above the field.
  final String? label;

  /// Shown in `textFaint` while the field is empty.
  final String? placeholder;

  /// Quiet note under the field. Hidden while [errorText] is set.
  final String? helper;

  /// Rendered in mono `alarm` under the field. Daemon and control plane errors
  /// go here verbatim.
  final String? errorText;

  /// Data face, for keys, addresses and subnets.
  final bool mono;

  /// Obscured by default, with an eye toggle. Never logged, never echoed.
  final bool secret;

  final bool enabled;
  final bool readOnly;
  final bool autofocus;

  /// >1 gives a multi-line box, for pasting long enrollment keys.
  final int maxLines;
  final int? minLines;

  final double? width;

  /// Extra affordance inside the field, before the eye toggle.
  final Widget? suffix;

  final ValueChanged<String>? onChanged;

  /// Enter submits.
  final ValueChanged<String>? onSubmitted;

  final List<TextInputFormatter>? inputFormatters;
  final TextInputType? keyboardType;

  @override
  State<MeshTextField> createState() => _MeshTextFieldState();
}

class _MeshTextFieldState extends State<MeshTextField>
    implements TextSelectionGestureDetectorBuilderDelegate {
  @override
  final GlobalKey<EditableTextState> editableTextKey =
      GlobalKey<EditableTextState>();

  @override
  bool get forcePressEnabled => false;

  @override
  bool get selectionEnabled => widget.enabled;

  late _MeshSelectionGestureDetectorBuilder _gestures;
  TextEditingController? _ownedController;
  FocusNode? _ownedFocusNode;
  bool _focused = false;
  bool _hovered = false;
  bool _revealed = false;

  TextEditingController get _controller =>
      widget.controller ?? (_ownedController ??= TextEditingController());
  FocusNode get _focusNode =>
      widget.focusNode ?? (_ownedFocusNode ??= FocusNode());

  bool get _obscured => widget.secret && !_revealed;

  @override
  void initState() {
    super.initState();
    _gestures = _MeshSelectionGestureDetectorBuilder(state: this);
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(MeshTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      oldWidget.focusNode?.removeListener(_onFocusChange);
      _focusNode.addListener(_onFocusChange);
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _ownedFocusNode?.dispose();
    _ownedController?.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!mounted) return;
    if (_focused != _focusNode.hasFocus) {
      setState(() => _focused = _focusNode.hasFocus);
    }
  }

  void _requestKeyboard() => editableTextKey.currentState?.requestKeyboard();

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;
    final hasError = widget.errorText != null && widget.errorText!.isNotEmpty;

    final textStyle = (widget.mono ? theme.type.mono : theme.type.body)
        .copyWith(color: widget.enabled ? tokens.text : tokens.textFaint);

    final editable = EditableText(
      key: editableTextKey,
      controller: _controller,
      focusNode: _focusNode,
      style: textStyle,
      strutStyle: StrutStyle.fromTextStyle(textStyle, forceStrutHeight: true),
      cursorColor: tokens.signal,
      backgroundCursorColor: tokens.textFaint,
      selectionColor: tokens.signal.withValues(alpha: 0.28),
      cursorWidth: 1.5,
      cursorOpacityAnimates: true,
      readOnly: widget.readOnly || !widget.enabled,
      autofocus: widget.autofocus,
      obscureText: _obscured,
      obscuringCharacter: '•',
      enableSuggestions: !widget.mono && !widget.secret,
      autocorrect: !widget.mono && !widget.secret,
      maxLines: widget.maxLines,
      minLines: widget.minLines,
      expands: false,
      keyboardType:
          widget.keyboardType ??
          (widget.maxLines > 1 ? TextInputType.multiline : TextInputType.text),
      textInputAction: widget.maxLines > 1
          ? TextInputAction.newline
          : TextInputAction.done,
      inputFormatters: widget.inputFormatters,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      // Handles belong to touch platforms; this is a desktop app.
      selectionControls: emptyTextSelectionControls,
      // The default builder is Material's adaptive toolbar. No thanks.
      contextMenuBuilder: null,
      rendererIgnoresPointer: true,
      scrollPadding: EdgeInsets.zero,
    );

    final borderColor = hasError
        ? tokens.alarm.withValues(alpha: 0.6)
        : (_focused || _hovered ? tokens.hairlineHigh : tokens.hairline);

    final touch = FilamentMotion.touch(context);
    Widget field = AnimatedContainer(
      duration: touch.duration,
      curve: touch.curve,
      constraints: BoxConstraints(
        minHeight: widget.maxLines > 1
            ? FilamentMetrics.controlHeight * 2
            : FilamentMetrics.controlHeight,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: FilamentSpace.x2 + 2,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: widget.enabled ? tokens.surfaceHigh : tokens.surface,
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(FilamentRadius.control),
      ),
      child: Row(
        crossAxisAlignment: widget.maxLines > 1
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Stack(
              children: [
                if (widget.placeholder != null)
                  Positioned.fill(
                    child: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _controller,
                      builder: (context, value, _) => value.text.isEmpty
                          ? Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                widget.placeholder!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textStyle.copyWith(
                                  color: tokens.textFaint,
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                editable,
              ],
            ),
          ),
          if (widget.suffix != null) ...[
            const SizedBox(width: FilamentSpace.x1),
            widget.suffix!,
          ],
          if (widget.secret) ...[
            const SizedBox(width: FilamentSpace.x1),
            MeshIconButton(
              glyph: _revealed ? MeshGlyph.eyeOff : MeshGlyph.eye,
              size: 22,
              tooltip: _revealed ? 'Hide' : 'Show',
              onPressed: widget.enabled
                  ? () => setState(() => _revealed = !_revealed)
                  : null,
            ),
          ],
        ],
      ),
    );

    field = MeshFocusRing(focused: _focused, child: field);

    field = MouseRegion(
      cursor: widget.enabled
          ? SystemMouseCursors.text
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: _gestures.buildGestureDetector(
        behavior: HitTestBehavior.translucent,
        child: field,
      ),
    );

    if (widget.width != null) {
      field = SizedBox(width: widget.width, child: field);
    }

    if (widget.label == null && widget.helper == null && !hasError) {
      return field;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.label != null) ...[
          Text(widget.label!, style: theme.type.label),
          const SizedBox(height: FilamentSpace.x2 - 2),
        ],
        field,
        if (hasError) ...[
          const SizedBox(height: FilamentSpace.x2 - 2),
          Text(
            widget.errorText!,
            style: theme.type.error.copyWith(fontSize: 11),
          ),
        ] else if (widget.helper != null) ...[
          const SizedBox(height: FilamentSpace.x2 - 2),
          Text(widget.helper!, style: theme.type.small),
        ],
      ],
    );
  }
}

class _MeshSelectionGestureDetectorBuilder
    extends TextSelectionGestureDetectorBuilder {
  _MeshSelectionGestureDetectorBuilder({required _MeshTextFieldState state})
    : _state = state,
      super(delegate: state);

  final _MeshTextFieldState _state;

  @override
  void onSingleTapUp(TapDragUpDetails details) {
    super.onSingleTapUp(details);
    _state._requestKeyboard();
  }
}
