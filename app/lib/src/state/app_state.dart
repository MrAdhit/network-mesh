/// The three stores, one scope, and the rail status folded out of them.
///
/// `AppScope` is the only inherited widget in the app. It carries [AppState],
/// which owns the stores and forwards their notifications so a widget that
/// wants everything can just depend on the scope; a widget that wants one
/// store reads it through [AppScope.read] and listens to that store alone.
library;

import 'package:flutter/widgets.dart';

import '../data/ipc_protocol.dart';
import '../data/prefs.dart';
import '../kit/path_triad.dart';
import '../kit/rail.dart';
import 'daemon_store.dart';
import 'network_store.dart';
import 'session_store.dart';

class AppState extends ChangeNotifier {
  AppState({
    PrefsStore? prefs,
    SessionStore? session,
    DaemonStore? daemon,
    NetworkStore? network,
  }) : prefs = prefs ?? PrefsStore(),
       session = session ?? SessionStore(),
       daemon = daemon ?? DaemonStore() {
    this.network = network ?? NetworkStore(session: this.session);

    this.daemon.pollInterval = this.prefs.pollInterval.value;
    this.prefs.pollInterval.addListener(_onPollInterval);

    this.prefs.addListener(_onChild);
    this.session.addListener(_onChild);
    this.daemon.addListener(_onChild);
    this.network.addListener(_onChild);

    _updateRail();
  }

  final PrefsStore prefs;
  final SessionStore session;
  final DaemonStore daemon;
  late final NetworkStore network;

  /// What the rail's bottom block renders. A `ValueNotifier` rather than a
  /// getter so the rail only rebuilds when the value actually changes —
  /// `MeshRailStatus` implements `==` for exactly this reason, and most polls
  /// produce an identical one.
  final ValueNotifier<MeshRailStatus> railStatus = ValueNotifier(
    const MeshRailStatus.unknown(),
  );

  bool _booted = false;
  bool get booted => _booted;

  /// Read the preferences and the shared session, then start polling.
  ///
  /// Ordered: prefs first so the window does not repaint from the default
  /// theme into the stored one, session next so the Network screen knows
  /// whether it has one, daemon last because it is the only thing that runs
  /// forever.
  Future<void> boot() async {
    if (_booted) return;
    _booted = true;
    await prefs.load();
    daemon.pollInterval = prefs.pollInterval.value;
    await session.load();
    daemon.start();
  }

  void _onPollInterval() => daemon.pollInterval = prefs.pollInterval.value;

  void _onChild() {
    _updateRail();
    if (!_disposed) notifyListeners();
  }

  void _updateRail() {
    railStatus.value = _foldRail();
  }

  /// The rail's mini triad: direct is the daemon's own reachability, the other
  /// two bars are its backhaul planes. One bright bar when everything is well.
  MeshRailStatus _foldRail() {
    final reachable = daemon.reachableOrUnknown;
    final status = daemon.status;
    final enrolled = reachable == true && daemon.enrolled;

    final direct = switch (reachable) {
      null => MeshPathState.unknown,
      false => MeshPathState.down,
      true => enrolled ? MeshPathState.winning : MeshPathState.up,
    };

    MeshPathState plane(BackhaulReport? report) {
      if (!enrolled || report == null) return MeshPathState.unknown;
      return report.up ? MeshPathState.up : MeshPathState.down;
    }

    final expired = session.sessionExpired;
    final email = session.hasSession
        ? (session.email ?? session.accountId ?? 'Signed in')
        : (expired ? (session.email ?? 'Stored session') : null);

    return MeshRailStatus(
      daemonReachable: reachable,
      enrolled: enrolled,
      direct: direct,
      cloudflare: plane(status?.cloudflare),
      tailscale: plane(status?.tailscale),
      detail: switch (reachable) {
        null => null,
        // The daemon's own words, never rewritten.
        false => daemon.error?.message,
        true => status?.nodeName,
      },
      sessionEmail: email,
      sessionExpired: expired,
    );
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    prefs.pollInterval.removeListener(_onPollInterval);
    prefs.removeListener(_onChild);
    session.removeListener(_onChild);
    daemon.removeListener(_onChild);
    network.removeListener(_onChild);
    railStatus.dispose();
    network.dispose();
    daemon.dispose();
    session.dispose();
    prefs.dispose();
    super.dispose();
  }
}

/// The one inherited widget in the app.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({required AppState state, required super.child, super.key})
    : super(notifier: state);

  /// Subscribe: the caller rebuilds whenever any store changes.
  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'no AppScope above this widget');
    return scope!.notifier!;
  }

  /// Reach the stores without subscribing, for widgets that listen to one
  /// store themselves. Use this in callbacks and with `ListenableBuilder`.
  static AppState read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'no AppScope above this widget');
    return scope!.notifier!;
  }

  static DaemonStore daemonOf(BuildContext context) => read(context).daemon;
  static SessionStore sessionOf(BuildContext context) => read(context).session;
  static NetworkStore networkOf(BuildContext context) => read(context).network;
  static PrefsStore prefsOf(BuildContext context) => read(context).prefs;
}
