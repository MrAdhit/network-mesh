/// The control plane's view of the account: subnet, backhaul credentials,
/// enrollment keys, and the node roster.
///
/// Fetched on demand rather than polled. The control plane is a database, not
/// a live signal, and hitting it twice a second from a desktop app would be
/// rude. It refreshes itself every 30 seconds only while the Network screen is
/// actually on screen; the moment it is not, the timer stops.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/cp_client.dart';
import '../data/cp_models.dart';
import 'session_store.dart';

class NetworkStore extends ChangeNotifier {
  NetworkStore({required SessionStore session}) : _session = session {
    _session.addListener(_onSession);
    _sessionKey = _keyOf(_session);
  }

  final SessionStore _session;

  /// How often the screen refreshes itself while it is visible.
  static const Duration visibleRefreshInterval = Duration(seconds: 30);

  // -- state --------------------------------------------------------------

  NetworkView? _network;
  List<NodeView>? _nodes;
  CpException? _error;
  bool _loading = false;
  DateTime? _fetchedAt;

  /// Null until the first successful fetch.
  NetworkView? get network => _network;

  /// Null until the first successful fetch; empty is a real answer.
  List<NodeView>? get nodes => _nodes;

  /// The last failure of [refresh]. Per-action failures live in their own
  /// fields so a failed subnet change does not blank the whole screen.
  CpException? get error => _error;

  bool get loading => _loading;
  DateTime? get fetchedAt => _fetchedAt;
  bool get hasData => _network != null;

  // Per-action busy flags and errors. Every async button gets a busy state,
  // and every error renders in the panel that caused it.
  bool _savingSubnet = false;
  bool _savingCloudflare = false;
  bool _savingTailscale = false;
  bool _mintingKey = false;
  final Set<String> _removingNodes = {};

  CpException? subnetError;
  CpException? cloudflareError;
  CpException? tailscaleError;
  CpException? keyError;
  CpException? nodeError;

  bool get savingSubnet => _savingSubnet;
  bool get savingCloudflare => _savingCloudflare;
  bool get savingTailscale => _savingTailscale;
  bool get mintingKey => _mintingKey;
  bool isRemoving(String nodeId) => _removingNodes.contains(nodeId);

  /// The last key minted in this session, shown until the screen is left.
  /// Never written anywhere: it is a credential and the clipboard is enough.
  NewEnrollmentKey? lastKey;

  // -- visibility ---------------------------------------------------------

  bool _visible = false;
  Timer? _timer;

  bool get visible => _visible;

  /// The Network screen calls this as it comes and goes. Becoming visible
  /// fetches once if there is nothing (or nothing recent) and starts the 30s
  /// timer; becoming invisible stops it.
  void setVisible(bool value) {
    if (_visible == value) return;
    _visible = value;
    if (value) {
      final age = _fetchedAt == null
          ? null
          : DateTime.now().difference(_fetchedAt!);
      if (age == null || age >= visibleRefreshInterval) {
        unawaited(refresh());
      }
      _startTimer();
    } else {
      _timer?.cancel();
      _timer = null;
    }
    notifyListeners();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(visibleRefreshInterval, (_) {
      if (!_visible || _disposed) return;
      unawaited(refresh(quiet: true));
    });
  }

  // -- session changes ----------------------------------------------------

  String _sessionKey = '';

  static String _keyOf(SessionStore s) =>
      '${s.cpUrl.url}|${s.hasSession}|${s.accountId ?? ''}';

  /// Logging in, logging out or pointing at a different control plane
  /// invalidates everything here.
  void _onSession() {
    final key = _keyOf(_session);
    if (key == _sessionKey) return;
    _sessionKey = key;
    _network = null;
    _nodes = null;
    _error = null;
    _fetchedAt = null;
    lastKey = null;
    subnetError = null;
    cloudflareError = null;
    tailscaleError = null;
    keyError = null;
    nodeError = null;
    notifyListeners();
    if (_visible && _session.hasSession) unawaited(refresh());
  }

  // -- reads --------------------------------------------------------------

  /// GET /v1/network and GET /v1/nodes together: the screen shows both and
  /// two spinners for one refresh would be noise.
  ///
  /// [quiet] skips the loading flag, so the 30s tick does not flicker the
  /// screen every half minute.
  Future<void> refresh({bool quiet = false}) async {
    final client = _session.client;
    if (client == null) {
      _error = const CpNotAuthenticated();
      notifyListeners();
      return;
    }
    if (_loading) return;
    _loading = !quiet;
    if (!quiet) notifyListeners();
    // Each half is applied as it lands. A broken node roster should not also
    // blank the subnet and the backhaul panels, which came back fine.
    CpException? failure;
    try {
      _network = await client.network();
    } on CpException catch (e) {
      failure = e;
    }
    try {
      _nodes = await client.nodes();
    } on CpException catch (e) {
      failure ??= e;
    }
    _error = failure;
    if (failure == null) _fetchedAt = DateTime.now();
    _loading = false;
    _notify();
  }

  // -- writes -------------------------------------------------------------

  /// PATCH /v1/network. The control plane rejects this once any node is
  /// enrolled, which is why the form is only offered while node_count is 0.
  Future<bool> setSubnet(String subnet) async {
    final client = _session.client;
    if (client == null) {
      subnetError = const CpNotAuthenticated();
      notifyListeners();
      return false;
    }
    if (_savingSubnet) return false;
    _savingSubnet = true;
    subnetError = null;
    notifyListeners();
    try {
      _network = await client.setSubnet(subnet);
      _fetchedAt = DateTime.now();
      return true;
    } on CpException catch (e) {
      subnetError = e;
      return false;
    } finally {
      _savingSubnet = false;
      _notify();
    }
  }

  /// PUT /v1/network/backhauls/cloudflare. Slow: it provisions a Zero Trust
  /// org, which is why the button's busy state matters here more than
  /// anywhere else in the app.
  Future<bool> setCloudflare({
    required String apiToken,
    required String accountId,
  }) async {
    final client = _session.client;
    if (client == null) {
      cloudflareError = const CpNotAuthenticated();
      notifyListeners();
      return false;
    }
    if (_savingCloudflare) return false;
    _savingCloudflare = true;
    cloudflareError = null;
    notifyListeners();
    try {
      final status = await client.setCloudflare(
        apiToken: apiToken,
        accountId: accountId,
      );
      _mergeBackhaul(cloudflare: status);
      return true;
    } on CpException catch (e) {
      cloudflareError = e;
      return false;
    } finally {
      _savingCloudflare = false;
      _notify();
    }
  }

  /// PUT /v1/network/backhauls/tailscale.
  Future<bool> setTailscale({required String apiToken}) async {
    final client = _session.client;
    if (client == null) {
      tailscaleError = const CpNotAuthenticated();
      notifyListeners();
      return false;
    }
    if (_savingTailscale) return false;
    _savingTailscale = true;
    tailscaleError = null;
    notifyListeners();
    try {
      final status = await client.setTailscale(apiToken: apiToken);
      _mergeBackhaul(tailscale: status);
      return true;
    } on CpException catch (e) {
      tailscaleError = e;
      return false;
    } finally {
      _savingTailscale = false;
      _notify();
    }
  }

  /// POST /v1/enrollment-keys.
  Future<NewEnrollmentKey?> mintEnrollmentKey() async {
    final client = _session.client;
    if (client == null) {
      keyError = const CpNotAuthenticated();
      notifyListeners();
      return null;
    }
    if (_mintingKey) return null;
    _mintingKey = true;
    keyError = null;
    notifyListeners();
    try {
      final key = await client.mintEnrollmentKey();
      lastKey = key;
      return key;
    } on CpException catch (e) {
      keyError = e;
      return null;
    } finally {
      _mintingKey = false;
      _notify();
    }
  }

  /// Forget the key on screen. Called when the Network screen is left, so a
  /// credential is not sitting in the window when someone walks past.
  void clearKey() {
    if (lastKey == null) return;
    lastKey = null;
    notifyListeners();
  }

  /// DELETE /v1/nodes/{id}. Confirmed by the caller, never here.
  Future<bool> removeNode(String nodeId) async {
    final client = _session.client;
    if (client == null) {
      nodeError = const CpNotAuthenticated();
      notifyListeners();
      return false;
    }
    if (_removingNodes.contains(nodeId)) return false;
    _removingNodes.add(nodeId);
    nodeError = null;
    notifyListeners();
    try {
      await client.removeNode(nodeId);
      _nodes = _nodes?.where((n) => n.nodeId != nodeId).toList();
      // The count and the free-address tally both moved; ask rather than do
      // arithmetic on a number the control plane owns.
      unawaited(refresh(quiet: true));
      return true;
    } on CpException catch (e) {
      nodeError = e;
      return false;
    } finally {
      _removingNodes.remove(nodeId);
      _notify();
    }
  }

  /// Fold a single backhaul answer into the view we already hold, so the
  /// panel updates without a round trip.
  void _mergeBackhaul({BackhaulStatus? cloudflare, BackhaulStatus? tailscale}) {
    final current = _network;
    if (current == null) {
      unawaited(refresh(quiet: true));
      return;
    }
    _network = NetworkView(
      accountId: current.accountId,
      email: current.email,
      subnet: current.subnet,
      nodeCount: current.nodeCount,
      addressesUsed: current.addressesUsed,
      addressesAvailable: current.addressesAvailable,
      cloudflare: cloudflare ?? current.cloudflare,
      tailscale: tailscale ?? current.tailscale,
    );
  }

  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _session.removeListener(_onSession);
    super.dispose();
  }
}
