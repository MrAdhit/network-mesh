/// `MeshDialog` — a centred panel over a dimmed backdrop.
///
/// The destructive action is styled destructive and is never the default focus;
/// the way out is always the thing your fingers land on first.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../theme/theme.dart';
import 'button.dart';
import 'panel.dart';
import 'text_field.dart';

/// The route a dialog rides on.
///
/// Arriving, the panel scales in from 0.96 on `settle` while the backdrop
/// fades on `drift` underneath it — the panel is still landing when the room
/// has already gone dark. Leaving is not a spring: 150ms, straight out, no
/// overshoot on a thing nobody is looking at any more.
class MeshDialogRoute<T> extends PopupRoute<T> {
  MeshDialogRoute({
    required this.builder,
    required this.scrimColor,
    required this.reducedMotion,
    this.dismissible = true,
  });

  final WidgetBuilder builder;
  final Color scrimColor;
  final bool dismissible;

  /// Resolved when the route is pushed, because a route's durations are read
  /// before its own context exists.
  final bool reducedMotion;

  FilamentTempo get _arrive =>
      reducedMotion ? FilamentMotion.reducedTempo : FilamentMotion.settleTempo;

  FilamentTempo get _leave =>
      reducedMotion ? FilamentMotion.reducedTempo : FilamentMotion.dismissTempo;

  FilamentTempo get _backdrop =>
      reducedMotion ? FilamentMotion.reducedTempo : FilamentMotion.driftTempo;

  @override
  Color get barrierColor => scrimColor;

  @override
  bool get barrierDismissible => dismissible;

  @override
  String get barrierLabel => 'Dismiss';

  @override
  Curve get barrierCurve => _backdrop.curve;

  /// Where the backdrop's 240ms sits inside the panel's longer settle. The
  /// panel is opaque well before it has finished landing.
  double get _backdropFraction {
    final total = _arrive.duration.inMicroseconds;
    if (total <= 0) return 1;
    return (_backdrop.duration.inMicroseconds / total).clamp(0.0, 1.0);
  }

  @override
  Duration get transitionDuration => _arrive.duration;

  @override
  Duration get reverseTransitionDuration => _leave.duration;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return SafeArea(
      child: Center(child: Builder(builder: builder)),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final leaving = animation.status == AnimationStatus.reverse;
    final shaped = animation.drive(
      CurveTween(curve: leaving ? _leave.curve : _arrive.curve),
    );
    return FadeTransition(
      // The panel's own fade is the backdrop's, so the two read as one arrival.
      opacity: leaving
          ? shaped
          : animation.drive(
              CurveTween(
                curve: Interval(0, _backdropFraction, curve: _backdrop.curve),
              ),
            ),
      child: AnimatedBuilder(
        animation: shaped,
        builder: (context, child) => Transform.scale(
          scale:
              FilamentMotion.dialogScale +
              (1 - FilamentMotion.dialogScale) * shaped.value,
          child: child,
        ),
        child: child,
      ),
    );
  }
}

/// A modal panel: title, body, actions.
class MeshDialog extends StatelessWidget {
  const MeshDialog({
    required this.title,
    this.message,
    this.child,
    this.actions = const <Widget>[],
    this.width = 420,
    super.key,
  });

  final String title;

  /// A sentence restating the consequence, in the daemon's own terms.
  final String? message;

  /// Extra body content under [message].
  final Widget? child;

  /// Right-aligned, in order. Put the way out first.
  final List<Widget> actions;

  final double width;

  /// Opens [builder] as a modal. Returns whatever the dialog pops with.
  static Future<T?> show<T>(
    BuildContext context, {
    required WidgetBuilder builder,
    bool dismissible = true,
  }) {
    final tokens = FilamentTheme.tokensOf(context);
    return Navigator.of(context, rootNavigator: true).push<T>(
      MeshDialogRoute<T>(
        builder: builder,
        dismissible: dismissible,
        scrimColor: tokens.bg.withValues(alpha: 0.6),
        reducedMotion: FilamentMotion.reducedIn(context),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              Navigator.of(context).maybePop();
              return null;
            },
          ),
        },
        child: FocusScope(
          autofocus: true,
          child: SizedBox(
            width: width,
            child: DecoratedBox(
              // A panel that happens to be floating: same fill, same ring —
              // one step brighter, because a dialog is nearer the light — and
              // the shade doubled up because this one really is above the page.
              decoration: BoxDecoration(
                gradient: tokens.panelFill,
                border: MeshRingBorder(tokens, base: tokens.hairlineHigh),
                borderRadius: BorderRadius.circular(FilamentRadius.panel),
                boxShadow: <BoxShadow>[...tokens.shade, ...tokens.shade],
              ),
              child: Padding(
                padding: const EdgeInsets.all(FilamentSpace.panel),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(title, style: theme.type.section),
                    if (message != null) ...[
                      const SizedBox(height: FilamentSpace.x2 + 2),
                      Text(message!, style: theme.type.bodyDim),
                    ],
                    if (child != null) ...[
                      const SizedBox(height: FilamentSpace.x4),
                      child!,
                    ],
                    if (actions.isNotEmpty) ...[
                      const SizedBox(height: FilamentSpace.x5),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          for (var i = 0; i < actions.length; i++) ...[
                            if (i > 0) const SizedBox(width: FilamentSpace.x2),
                            actions[i],
                          ],
                        ],
                      ),
                    ],
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

/// A confirm dialog for destructive actions.
///
/// With [confirmPhrase] set, the action stays disabled until the operator types
/// that exact word — the pattern the danger zone in Settings uses.
class MeshConfirmDialog extends StatefulWidget {
  const MeshConfirmDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.cancelLabel = 'Cancel',
    this.confirmPhrase,
    this.destructive = true,
    this.onConfirm,
    super.key,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;

  /// Type-to-confirm phrase. Null for a plain confirm.
  final String? confirmPhrase;

  final bool destructive;

  /// Runs before the dialog closes, with the confirm button busy while it does.
  /// The dialog pops `true` when it completes without throwing; on a throw it
  /// stays open and shows the error verbatim.
  final Future<void> Function()? onConfirm;

  /// Convenience: opens the dialog and resolves true when confirmed.
  static Future<bool> ask(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
    String cancelLabel = 'Cancel',
    String? confirmPhrase,
    bool destructive = true,
    Future<void> Function()? onConfirm,
  }) async {
    final result = await MeshDialog.show<bool>(
      context,
      builder: (_) => MeshConfirmDialog(
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        confirmPhrase: confirmPhrase,
        destructive: destructive,
        onConfirm: onConfirm,
      ),
    );
    return result ?? false;
  }

  @override
  State<MeshConfirmDialog> createState() => _MeshConfirmDialogState();
}

class _MeshConfirmDialogState extends State<MeshConfirmDialog> {
  final TextEditingController _phrase = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _phrase.dispose();
    super.dispose();
  }

  bool get _armed =>
      widget.confirmPhrase == null ||
      _phrase.text.trim() == widget.confirmPhrase;

  Future<void> _confirm() async {
    if (!_armed || _busy) return;
    if (widget.onConfirm == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onConfirm!();
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);

    final body = widget.confirmPhrase == null && _error == null
        ? null
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.confirmPhrase != null)
                MeshTextField(
                  controller: _phrase,
                  label: 'Type ${widget.confirmPhrase} to confirm',
                  mono: true,
                  autofocus: true,
                  enabled: !_busy,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _confirm(),
                ),
              if (_error != null) ...[
                const SizedBox(height: FilamentSpace.x3),
                Text(_error!, style: theme.type.error),
              ],
            ],
          );

    return MeshDialog(
      title: widget.title,
      message: widget.message,
      actions: [
        // Autofocused: the way out is what your fingers land on.
        MeshButton(
          label: widget.cancelLabel,
          autofocus: widget.confirmPhrase == null,
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
        ),
        if (widget.destructive)
          MeshButton.destructive(
            label: widget.confirmLabel,
            busy: _busy,
            onPressed: _armed ? _confirm : null,
          )
        else
          MeshButton.primary(
            label: widget.confirmLabel,
            busy: _busy,
            onPressed: _armed ? _confirm : null,
          ),
      ],
      child: body,
    );
  }
}
