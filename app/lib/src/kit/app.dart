/// `MeshApp` — the WidgetsApp root.
///
/// No MaterialApp, no CupertinoApp: this is where the theme, the default text
/// style and the app-wide shortcuts get installed, and nothing else.
library;

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';

import '../theme/theme.dart';
import 'copyable.dart';

class MeshApp extends StatelessWidget {
  const MeshApp({
    required this.themeMode,
    required this.home,
    this.title = 'Mesh',
    super.key,
  });

  /// Dark, light, or follow the OS. The prefs store replaces the notifier that
  /// backs this in a later phase; nothing here changes when it does.
  final ValueListenable<MeshThemeMode> themeMode;

  final Widget home;
  final String title;

  /// App-wide bindings on top of [WidgetsApp.defaultShortcuts]. A focused text
  /// field's own copy binding sits deeper in the tree and wins over this one.
  static const Map<ShortcutActivator, Intent> _shortcuts = {
    SingleActivator(LogicalKeyboardKey.keyC, meta: true): MeshCopyIntent(),
    SingleActivator(LogicalKeyboardKey.keyC, control: true): MeshCopyIntent(),
  };

  @override
  Widget build(BuildContext context) {
    return WidgetsApp(
      title: title,
      // Only used by the OS task switcher on some platforms.
      color: const FilamentTokens.dark().bg,
      debugShowCheckedModeBanner: false,
      shortcuts: {...WidgetsApp.defaultShortcuts, ..._shortcuts},
      pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
          PageRouteBuilder<T>(
            settings: settings,
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (context, _, _) => builder(context),
          ),
      home: home,
      builder: (context, child) => ValueListenableBuilder<MeshThemeMode>(
        valueListenable: themeMode,
        builder: (context, mode, _) {
          final tokens = FilamentTokens.of(
            mode.resolve(MediaQuery.platformBrightnessOf(context)),
          );
          final type = FilamentTypography(tokens);
          return FilamentTheme(
            tokens: tokens,
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: DefaultTextStyle(
                style: type.body,
                child: DefaultSelectionStyle(
                  cursorColor: tokens.signal,
                  selectionColor: tokens.signal.withValues(alpha: 0.28),
                  child: ColoredBox(
                    color: tokens.bg,
                    child: child ?? const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
