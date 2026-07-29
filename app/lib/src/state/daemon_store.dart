/// The live picture of the local daemon.
///
/// Polls `status` and, when enrolled, `peers` on the configured interval and
/// backs off to five seconds while the daemon is unreachable — a dead socket
/// should not be dialled twice a second forever.
///
/// It also keeps what the daemon does not: a per-peer, per-path ring of ewma
/// RTTs, which is where the sparklines come from. The daemon reports an
/// instant; the history is ours to remember.
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../data/daemon_client.dart';
import '../data/ipc_protocol.dart';

/// A fixed-length window of samples. Null is a real value here: it means "no
/// reading this tick", and the sparkline breaks its line rather than drawing
/// through the gap.
class RttRing {
  RttRing({this.capacity = DaemonStore.historyLength});

  final int capacity;
  final Queue<double?> _samples = Queue<double?>();

  void add(double? value) {
    _samples.addLast(value);
    while (_samples.length > capacity) {
      _samples.removeFirst();
    }
  }

  /// Oldest first, which is the order a sparkline draws.
  List<double?> get samples => _samples.toList(growable: false);

  int get length => _samples.length;
  bool get isEmpty => _samples.isEmpty;

  /// True when every sample in the window is null: nothing to draw.
  bool get silent => _samples.every((s) => s == null);
}

/// One completed ping, with the summary meshctl would have printed.
class PingRun {
  const PingRun({
    required this.peer,
    required this.samples,
    required this.summary,
    required this.at,
  });

  final String peer;
  final List<PingSample> samples;
  final PingSummary summary;
  final DateTime at;
}

class DaemonStore extends ChangeNotifier {
  DaemonStore({DaemonClient? client, Duration? pollInterval})
    : client = client ?? DaemonClient(),
      _pollInterval = pollInterval ?? const Duration(seconds: 2);

  final DaemonClient client;

  /// Roughly four minutes at the default 2s tick, which is the span the
  /// sparkline is meant to cover.
  static const int historyLength = 120;

  /// What the poll loop slows to while the daemon is unreachable.
  static const Duration unreachableInterval = Duration(seconds: 5);

  // -- configuration ------------------------------------------------------

  Duration _pollInterval;

  Duration get pollInterval => _pollInterval;

  /// Takes effect on the next tick; an in-flight poll is left alone.
  set pollInterval(Duration value) {
    if (_pollInterval == value) return;
    _pollInterval = value;
    if (_running) _schedule(immediate: false);
    notifyListeners();
  }

  /// The interval actually in use, backoff included.
  Duration get effectiveInterval => reachable
      ? _pollInterval
      : (_pollInterval > unreachableInterval
            ? _pollInterval
            : unreachableInterval);

  /// Where we are talking to. Settings shows this, read-only.
  String get endpoint => client.endpoint;

  // -- state --------------------------------------------------------------

  StatusReport? _status;
  List<PeerReport> _peers = const [];
  DaemonException? _error;
  DateTime? _lastSuccess;
  bool _firstPollComplete = false;
  int _consecutiveFailures = 0;

  /// The last status the daemon gave us. Retained across a failed poll so a
  /// brief hiccup does not blank the screen; [reachable] is what says whether
  /// it is current.
  StatusReport? get status => _status;

  List<PeerReport> get peers => _peers;

  /// Null when the last poll succeeded.
  DaemonException? get error => _error;

  /// Null until the first poll lands, which is what the rail renders as
  /// "connecting" rather than guessing either way.
  bool? get reachableOrUnknown => _firstPollComplete ? _error == null : null;

  bool get reachable => _firstPollComplete && _error == null;

  /// The daemon answers but has not joined a network.
  bool get enrolled => _status?.enrolled ?? false;

  bool get firstPollComplete => _firstPollComplete;
  DateTime? get lastSuccess => _lastSuccess;
  int get consecutiveFailures => _consecutiveFailures;
  bool get running => _running;

  // -- history ------------------------------------------------------------

  /// peer name -> path name -> ring.
  final Map<String, Map<String, RttRing>> _pathHistory = {};

  /// peer name -> ring of the winning path's ewma, which is the series the
  /// peer table's sparkline draws.
  final Map<String, RttRing> _bestHistory = {};

  /// The winning path's ewma over the last [historyLength] polls.
  List<double?> historyFor(String peer) =>
      _bestHistory[peer]?.samples ?? const [];

  /// One path's ewma over the same window.
  List<double?> historyForPath(String peer, String path) =>
      _pathHistory[peer]?[path]?.samples ?? const [];

  /// Which paths we have any history for, in triad order first.
  List<String> historyPaths(String peer) {
    final known = _pathHistory[peer]?.keys.toSet() ?? const <String>{};
    return [
      for (final p in meshPathNames)
        if (known.contains(p)) p,
      ...known.where((p) => !meshPathNames.contains(p)),
    ];
  }

  // -- ping ---------------------------------------------------------------

  final Map<String, PingRun> _pingResults = {};
  final Map<String, DaemonException> _pingErrors = {};
  final Set<String> _pinging = {};

  PingRun? pingResult(String peer) => _pingResults[peer];
  DaemonException? pingError(String peer) => _pingErrors[peer];
  bool isPinging(String peer) => _pinging.contains(peer);

  /// Probe every path to [peer]. Uses the client's 30s ping timeout, because
  /// four probes on three paths with real round trips behind them is not a 5s
  /// operation.
  Future<PingRun?> ping(String peer, {int count = 4}) async {
    if (_pinging.contains(peer)) return _pingResults[peer];
    _pinging.add(peer);
    _pingErrors.remove(peer);
    notifyListeners();
    try {
      final samples = await client.ping(peer, count: count);
      final run = PingRun(
        peer: peer,
        samples: samples,
        summary: PingSummary.of(samples),
        at: DateTime.now(),
      );
      _pingResults[peer] = run;
      return run;
    } on DaemonException catch (e) {
      _pingErrors[peer] = e;
      return null;
    } finally {
      _pinging.remove(peer);
      notifyListeners();
    }
  }

  /// Drop a peer's last ping, so closing and reopening a row starts clean.
  void clearPing(String peer) {
    if (_pingResults.remove(peer) == null && _pingErrors.remove(peer) == null) {
      return;
    }
    _pingErrors.remove(peer);
    notifyListeners();
  }

  // -- join / leave -------------------------------------------------------

  bool _joining = false;
  bool _leaving = false;
  DaemonException? _joinError;
  DaemonException? _leaveError;
  JoinedResponse? _lastJoin;
  LeftResponse? _lastLeave;

  bool get joining => _joining;
  bool get leaving => _leaving;
  DaemonException? get joinError => _joinError;
  DaemonException? get leaveError => _leaveError;
  JoinedResponse? get lastJoin => _lastJoin;

  /// Kept so the confirm dialog can quote `Left.detail` after the fact, which
  /// is the only place the daemon says why the record may still exist.
  LeftResponse? get lastLeave => _lastLeave;

  Future<JoinedResponse?> join(String key) async {
    if (_joining) return null;
    _joining = true;
    _joinError = null;
    notifyListeners();
    try {
      final joined = await client.join(key);
      _lastJoin = joined;
      // Joining changes everything the screen shows; do not wait for the tick.
      unawaited(refreshNow());
      return joined;
    } on DaemonException catch (e) {
      _joinError = e;
      return null;
    } finally {
      _joining = false;
      notifyListeners();
    }
  }

  Future<LeftResponse?> leave() async {
    if (_leaving) return null;
    _leaving = true;
    _leaveError = null;
    notifyListeners();
    try {
      final left = await client.leave();
      _lastLeave = left;
      _resetHistory();
      unawaited(refreshNow());
      return left;
    } on DaemonException catch (e) {
      _leaveError = e;
      return null;
    } finally {
      _leaving = false;
      notifyListeners();
    }
  }

  // -- the loop -----------------------------------------------------------

  Timer? _timer;
  bool _running = false;
  bool _polling = false;
  bool _disposed = false;

  /// Begin polling. Idempotent; the first poll runs immediately.
  void start() {
    if (_running || _disposed) return;
    _running = true;
    _schedule(immediate: true);
  }

  /// Stop polling and cancel the pending tick. An in-flight poll finishes and
  /// its result is applied; stopping is not a reason to throw data away.
  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  /// Poll now, outside the schedule. Used after join/leave and by the manual
  /// refresh button.
  Future<void> refreshNow() => _poll();

  void _schedule({required bool immediate}) {
    _timer?.cancel();
    _timer = null;
    if (!_running || _disposed) return;
    if (immediate) {
      // Unawaited on purpose: the loop reschedules itself from inside _poll.
      unawaited(_poll());
      return;
    }
    _timer = Timer(effectiveInterval, () {
      if (!_running || _disposed) return;
      unawaited(_poll());
    });
  }

  Future<void> _poll() async {
    if (_polling || _disposed) return;
    _polling = true;
    try {
      final status = await client.status();
      // meshctl stops reading a status once `enrolled` is false, and so do we:
      // there is no peer table to fetch and asking for one is a wasted dial.
      final peers = status.enrolled
          ? await client.peers()
          : const <PeerReport>[];
      _applySuccess(status, peers);
    } on DaemonException catch (e) {
      _applyFailure(e);
    } finally {
      _polling = false;
      if (!_disposed) _schedule(immediate: false);
    }
  }

  void _applySuccess(StatusReport status, List<PeerReport> peers) {
    _status = status;
    _peers = peers;
    _error = null;
    _consecutiveFailures = 0;
    _lastSuccess = DateTime.now();
    _firstPollComplete = true;
    _record(peers);
    _notify();
  }

  void _applyFailure(DaemonException e) {
    _error = e;
    _consecutiveFailures++;
    _firstPollComplete = true;
    _notify();
  }

  /// One sample per peer per path per poll, whether or not there was a
  /// reading. A gap in the line is information: it says the path was down.
  void _record(List<PeerReport> peers) {
    final seen = <String>{};
    for (final peer in peers) {
      seen.add(peer.name);
      final rings = _pathHistory.putIfAbsent(peer.name, () => {});
      final names = {...meshPathNames, ...peer.paths.map((p) => p.path)};
      for (final name in names) {
        final report = peer.path(name);
        final value = (report != null && report.up) ? report.ewmaMs : null;
        rings.putIfAbsent(name, RttRing.new).add(value);
      }
      final best = peer.best;
      _bestHistory
          .putIfAbsent(peer.name, RttRing.new)
          .add(best != null && best.up ? best.ewmaMs : null);
    }
    // A peer that left takes its history with it; keeping it would make a
    // returning peer look like it never went away.
    _pathHistory.removeWhere((name, _) => !seen.contains(name));
    _bestHistory.removeWhere((name, _) => !seen.contains(name));
  }

  void _resetHistory() {
    _pathHistory.clear();
    _bestHistory.clear();
    _pingResults.clear();
    _pingErrors.clear();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
