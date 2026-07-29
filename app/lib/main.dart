/// Mesh — the desktop app for the mesh daemon.
///
/// The shell: a WidgetsApp root, the three stores under one scope, the four
/// rail destinations, and an IndexedStack of screens. Everything the screens
/// show comes through `AppScope`.
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
import 'src/state/app_state.dart';

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
      home: AppScope(state: _app, child: const _Shell()),
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
    return MeshScaffold(
      destinations: _destinations,
      selectedIndex: _index,
      onSelect: _select,
      railStatus: AppScope.read(context).railStatus,
      children: const [
        OverviewScreen(),
        PeersScreen(),
        NetworkScreen(),
        SettingsScreen(),
      ],
    );
  }
}
