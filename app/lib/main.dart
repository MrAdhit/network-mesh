/// Mesh — the desktop app for the mesh daemon.
///
/// The root, and the one decision above every screen in the app: **first run or
/// the dashboard**. There is no route table and no navigator behind it — the
/// app wears one of two faces, and which one is not something the user picks.
/// It is what is true about this Mac.
library;

import 'package:flutter/widgets.dart';

import 'src/icons/mesh_icons.dart';
import 'src/kit/app.dart';
import 'src/kit/rail.dart';
import 'src/kit/scaffold.dart';
import 'src/screens/network.dart';
import 'src/screens/overview.dart';
import 'src/screens/peers.dart';
import 'src/screens/settings.dart';
import 'src/screens/setup/setup_flow.dart';
import 'src/state/app_state.dart';
import 'src/theme/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MeshAppRoot());
}

class MeshAppRoot extends StatefulWidget {
  const MeshAppRoot({super.key});

  @override
  State<MeshAppRoot> createState() => _MeshAppRootState();
}

class _MeshAppRootState extends State<MeshAppRoot> with WidgetsBindingObserver {
  final AppState _app = AppState();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Fire and forget: every store renders a sensible resting state until its
    // first load lands, so there is nothing to wait for before the first frame.
    _app.boot();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Polling a daemon for a window nobody can see is just heat. The store
    // keeps what it had, so coming back shows the last picture until the next
    // poll replaces it.
    switch (state) {
      case AppLifecycleState.resumed:
        if (_app.booted) _app.daemon.start();
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _app.daemon.stop();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _app.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MeshApp(
      themeMode: _app.prefs.themeMode,
      home: AppScope(state: _app, child: const _Face()),
    );
  }
}

/// Which face the app is wearing.
///
/// Decided once, when boot has settled, and then latched: a wizard that
/// vanished the instant the daemon answered would skip its own last stage, and
/// a dashboard that turned back into a wizard because the engine stopped would
/// be the diagnosis this app is not.
///
/// * already on the mesh, or set up before → the shell, straight away;
/// * otherwise → first run, at the stage this Mac is actually at.
///
/// Anything that stops working afterwards is the shell's calm banner, never a
/// takeover and never a trip back through the wizard. The one exception is
/// leaving the network: Settings clears `setupComplete`, and a Mac that is not
/// on a network and has not been set up is, by this definition, a Mac at the
/// start of first run. It goes back — to the network stage, since the engine is
/// still running.
class _Face extends StatefulWidget {
  const _Face();

  @override
  State<_Face> createState() => _FaceState();
}

class _FaceState extends State<_Face> {
  AppState? _app;

  /// Null until the decision can be made honestly.
  bool? _wizard;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.read(context);
    if (identical(app, _app)) return;
    _app?.removeListener(_decide);
    _app = app..addListener(_decide);
    // Straight assignment rather than [_decide]: the first look happens during
    // a build, and there is nothing yet to rebuild.
    _wizard = _face(app);
  }

  void _decide() {
    final app = _app;
    if (app == null || !mounted) return;
    // Whatever face is on, a Mac that is on the mesh has finished first run.
    // Recording it here covers the machine that was set up by meshctl and has
    // never seen this app before.
    if (app.onTheMesh) app.markSetupComplete();
    // The wizard owns its own exit. It is the one thing on screen that is not
    // allowed to be replaced by a change of state, because its last stage is a
    // state change: enrolling is what arrival is *about*.
    if (_wizard == true) return;
    final face = _face(app);
    if (face != null && face != _wizard) setState(() => _wizard = face);
  }

  /// True for the wizard, false for the shell, null while it is too early to
  /// say. See the class comment for the rules.
  bool? _face(AppState app) {
    if (!app.prefs.loaded) return null;
    if (app.setupComplete || app.onTheMesh) return false;
    return app.bootSettled ? true : null;
  }

  void _finish() {
    if (_wizard == false) return;
    setState(() => _wizard = false);
  }

  @override
  void dispose() {
    _app?.removeListener(_decide);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final drift = FilamentMotion.drift(context);
    return AnimatedSwitcher(
      duration: drift.duration,
      switchInCurve: drift.curve,
      switchOutCurve: drift.curve,
      child: switch (_wizard) {
        null => const _Booting(),
        true => SetupFlow(onFinished: _finish),
        false => const _Shell(),
      },
    );
  }
}

/// The window between the first frame and the first honest answer: the room the
/// app happens in, with nothing in it yet. Usually one or two frames.
class _Booting extends StatelessWidget {
  const _Booting();

  @override
  Widget build(BuildContext context) {
    final tokens = FilamentTheme.tokensOf(context);
    return ColoredBox(
      color: tokens.bg,
      child: DecoratedBox(
        decoration: BoxDecoration(gradient: tokens.haze),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _Shell extends StatefulWidget {
  const _Shell();

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  static const List<MeshDestination> _destinations = [
    MeshDestination(glyph: MeshGlyph.pulse, label: 'Overview'),
    MeshDestination(glyph: MeshGlyph.nodes, label: 'Peers'),
    MeshDestination(glyph: MeshGlyph.globe, label: 'Network'),
    MeshDestination(glyph: MeshGlyph.gear, label: 'Settings'),
  ];

  /// The Network destination. Its store only refreshes while it is on screen.
  static const int _networkIndex = 2;

  int _index = 0;

  void _select(int i) {
    if (i == _index) return;
    setState(() => _index = i);
    _syncNetworkVisibility();
  }

  void _syncNetworkVisibility() {
    final network = AppScope.networkOf(context);
    network.setVisible(_index == _networkIndex);
    if (_index != _networkIndex) network.clearKey();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    // The banner is above the rail as well as the content, because the news is
    // about the app and not about the screen you happen to be on. What it says
    // and what its button does are Overview's business; the shell only hands it
    // a child, and the screens under it are const, so a poll that changes
    // nothing costs nothing here.
    return MeshEngineBannerHost(
      child: MeshScaffold(
        destinations: _destinations,
        selectedIndex: _index,
        onSelect: _select,
        railStatus: app.railStatus,
        children: const [
          OverviewScreen(),
          PeersScreen(),
          NetworkScreen(),
          SettingsScreen(),
        ],
      ),
    );
  }
}
