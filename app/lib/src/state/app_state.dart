/// The four stores, one scope, and the rail status folded out of them.
///
/// `AppScope` is the only inherited widget in the app. It carries [AppState],
/// which owns the stores and forwards their notifications so a widget that
/// wants everything can just depend on the scope; a widget that wants one
/// store reads it through [AppScope.read] and listens to that store alone.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../data/ipc_protocol.dart';
import '../data/prefs.dart';
import '../kit/path_triad.dart';
import '../kit/rail.dart';
import 'daemon_store.dart';
import 'manager_store.dart';
import 'network_store.dart';
import 'session_store.dart';

class AppState extends ChangeNotifier {
  AppState({
    PrefsStore? prefs,
    SessionStore? session,
    DaemonStore? daemon,
    NetworkStore? network,
    ManagerStore? manager,
  }) : prefs = prefs ?? PrefsStore(),
       session = session ?? SessionStore(),
       daemon = daemon ?? DaemonStore(),
       manager = manager ?? ManagerStore() {
    this.network = network ?? NetworkStore(session: this.session);

    this.daemon.pollInterval = this.prefs.pollInterval.value;
    this.prefs.pollInterval.addListener(_onPollInterval);

    this.prefs.addListener(_onChild);
    this.session.addListener(_onChild);
    this.daemon.addListener(_onChild);
    this.network.addListener(_onChild);
    this.manager.addListener(_onChild);

    // The two things the manager cannot work out for itself: which control
    // plane is in play, and whether the socket answers. Both are owned by
    // another store, and neither is worth a second copy of the logic.
    this.manager
      ..cpUrl = this.session.cpUrl
      ..daemonReachable = this.daemon.reachableOrUnknown
      ..onApplied = this.daemon.refreshNow;

    _updateRail();
  }

  final PrefsStore prefs;
  final SessionStore session;
  final DaemonStore daemon;
  final ManagerStore manager;
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

  // -- the one derived decision: wizard or dashboard ----------------------
  //
  // Three facts, folded here because they are read together and nowhere else.
  // The app wears exactly one of its two faces, and which one is not a route
  // the user picks: it is what is true about this Mac.

  /// This Mac is on the mesh right now: the socket answers and it is enrolled.
  bool get onTheMesh => daemon.reachable && daemon.enrolled;

  /// First run has finished at least once. See [UiPrefs.setupComplete].
  bool get setupComplete => prefs.setupComplete.value;

  /// True once boot has looked at everything the decision turns on: the
  /// preferences file, the socket, and the disk.
  ///
  /// Without this the window would show a stage for the two frames before the
  /// first poll lands and then replace it — first run is not something to
  /// flash at somebody who is already set up.
  bool get bootSettled =>
      prefs.loaded && daemon.firstPollComplete && manager.inspected;

  /// Remember that this Mac is set up. Idempotent; the arrival stage calls it
  /// once and the router calls it on any boot that finds [onTheMesh] true.
  void markSetupComplete() => prefs.setSetupComplete(true);

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
    manager.cpUrl = session.cpUrl;
    daemon.start();
    // Looking at the disk is fast and tells the Overview whether it is a
    // window or a front door. The control plane is asked afterwards, and only
    // if it has not been asked in the last six hours.
    await manager.refresh();
    unawaited(manager.checkForUpdates());
  }

  void _onPollInterval() => daemon.pollInterval = prefs.pollInterval.value;

  void _onChild() {
    // Setters, so a value that did not move notifies nobody and this cannot
    // become a loop through the manager's own listener.
    manager
      ..cpUrl = session.cpUrl
      ..daemonReachable = daemon.reachableOrUnknown;
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

    // Null is what makes the rail leave the chip out altogether, so this is
    // the line that decides who ever sees one. A session, or a session that
    // has run out — never "signed out", which is not news about anything.
    // An expired one stays: somebody signed in on this Mac once, and a login
    // that quietly stopped working is worth a caution-coloured word.
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
    manager.removeListener(_onChild);
    railStatus.dispose();
    network.dispose();
    manager.dispose();
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
  static ManagerStore managerOf(BuildContext context) => read(context).manager;
}
