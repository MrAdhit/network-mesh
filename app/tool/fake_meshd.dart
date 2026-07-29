/// A meshd that isn't.
///
/// Binds a unix socket, speaks the real IPC protocol, and serves data that
/// moves: three peers, per-path RTTs that drift and jitter, a direct path that
/// flaps every twenty seconds, one path that loses about an eighth of its
/// probes, and winners that change hands because of it. `join` and `leave`
/// toggle enrollment; `ping` answers after the delay a real probe would take.
///
/// This is how the app gets developed and demoed without root and without a
/// real mesh. Run it, point the app at it, and everything on screen is live:
///
///     dart run tool/fake_meshd.dart /tmp/meshd-fake.sock
///     MESH_SOCKET=/tmp/meshd-fake.sock flutter run -d macos
///
/// The path also comes from `MESH_SOCKET`, so exporting it once covers both.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mesh_app/src/data/ipc_protocol.dart';

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty && args.first.isNotEmpty
      ? args.first
      : (Platform.environment['MESH_SOCKET']?.isNotEmpty ?? false)
      ? Platform.environment['MESH_SOCKET']!
      : '${Directory.systemTemp.path}${Platform.pathSeparator}meshd-fake.sock';

  if (Platform.isWindows) {
    stderr.writeln('fake_meshd needs a unix socket; run it on macOS or Linux');
    exitCode = 1;
    return;
  }

  final daemon = FakeMeshd(socketPath: path);
  await daemon.start();
  stdout.writeln('listening on $path');
  stdout.writeln('point the app at it: MESH_SOCKET=$path flutter run -d macos');

  Future<void> bye(ProcessSignal _) async {
    stdout.writeln('\nstopping');
    await daemon.stop();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(bye);
  ProcessSignal.sigterm.watch().listen(bye);

  await daemon.done;
}

/// The dev daemon, as a thing you can also embed — `tool/smoke.dart` runs it
/// out of process, but a test could just as well hold one.
class FakeMeshd {
  FakeMeshd({required this.socketPath, int seed = 1979}) : _rng = Random(seed);

  final String socketPath;
  final Random _rng;

  ServerSocket? _server;
  Timer? _ticker;
  final Completer<void> _done = Completer<void>();

  /// Resolves when the daemon stops.
  Future<void> get done => _done.future;

  final DateTime _startedAt = DateTime.now();
  bool _enrolled = true;
  String _nodeId = 'nd_7f3c1a08d2b4';
  final String _nodeName = 'workshop';
  String _virtualIp = '10.201.0.4';
  String _subnet = '10.201.0.0/16';

  late final List<_Peer> _peers = _buildPeers();

  Future<void> start() async {
    // A stale socket from a previous run would make bind fail forever.
    final file = File(socketPath);
    if (await file.exists()) await file.delete();
    await Directory(File(socketPath).parent.path).create(recursive: true);

    _server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    _server!.listen(
      _serve,
      onError: (Object e) => stderr.writeln('accept: $e'),
    );

    // Twice a second: fast enough that a 1s poll sees movement, slow enough
    // that the numbers stay readable.
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }

  Future<void> stop() async {
    _ticker?.cancel();
    _ticker = null;
    await _server?.close();
    _server = null;
    final file = File(socketPath);
    if (await file.exists()) await file.delete();
    if (!_done.isCompleted) _done.complete();
  }

  // -- the world ----------------------------------------------------------

  double get _t =>
      DateTime.now().difference(_startedAt).inMilliseconds / 1000.0;

  List<_Peer> _buildPeers() => [
    // The interesting one: its direct path flaps, so the triad's bright bar
    // keeps moving to cloudflare and back.
    _Peer(
      name: 'aurora',
      virtualIp: '10.201.0.12',
      cfIp: '100.96.40.12',
      tsHostname: 'aurora.tail9c2f.ts.net',
      paths: [
        _Path('direct', base: 7.5, swing: 1.6, period: 37, phase: 0.3),
        _Path('cloudflare', base: 21.0, swing: 3.0, period: 53, phase: 1.1),
        _Path('tailscale', base: 34.0, swing: 4.0, period: 71, phase: 2.4),
      ],
      flapping: 'direct',
    ),
    // The lossy one: cloudflare drops about an eighth of its probes, which is
    // well past the 5% the triad calls lossy.
    _Peer(
      name: 'basalt',
      virtualIp: '10.201.0.31',
      cfIp: '100.96.40.31',
      tsHostname: 'basalt.tail9c2f.ts.net',
      paths: [
        // Direct and cloudflare cross every ~90s, so the winner changes hands
        // without anything going down.
        _Path('direct', base: 18.0, swing: 7.5, period: 89, phase: 0.0),
        _Path(
          'cloudflare',
          base: 18.0,
          swing: 7.5,
          period: 89,
          phase: pi,
          loss: 12,
        ),
        _Path('tailscale', base: 44.0, swing: 5.0, period: 61, phase: 0.8),
      ],
    ),
    // The dull one: no tailscale at all, direct comfortably ahead. Somebody
    // has to be fine.
    _Peer(
      name: 'cinder',
      virtualIp: '10.201.0.47',
      cfIp: '100.96.40.47',
      tsHostname: null,
      paths: [
        _Path('direct', base: 4.2, swing: 0.8, period: 29, phase: 1.7),
        _Path('cloudflare', base: 26.0, swing: 2.5, period: 47, phase: 0.4),
        _Path('tailscale', base: 0, swing: 0, period: 1, phase: 0, dead: true),
      ],
    ),
  ];

  void _tick() {
    if (!_enrolled) return;
    final t = _t;
    for (final peer in _peers) {
      peer.tick(t, _rng);
    }
  }

  // -- serving ------------------------------------------------------------

  void _serve(Socket socket) {
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) async {
            if (line.trim().isEmpty) return;
            MeshResponse response;
            try {
              response = await _handle(MeshRequest.decodeLine(line));
            } on FormatException catch (e) {
              response = ErrorResponse('bad request: ${e.message}');
            }
            socket.add(utf8.encode(response.encodeLine()));
            await socket.flush();
          },
          onError: (Object _) {},
          onDone: () => socket.destroy(),
          cancelOnError: true,
        );
  }

  Future<MeshResponse> _handle(MeshRequest request) async {
    switch (request) {
      case StatusRequest():
        return StatusResponse(_status());

      case PeersRequest():
        if (!_enrolled) return const PeersResponse([]);
        return PeersResponse([for (final p in _peers) p.report()]);

      case PingRequest(:final peer, :final count):
        if (!_enrolled) {
          return const ErrorResponse(
            'not enrolled; run join with an enrollment key first',
          );
        }
        final target = _find(peer);
        if (target == null) return ErrorResponse('no peer named "$peer"');
        return PingResponse(await _probe(target, count));

      case SendRequest(:final peer, :final data):
        if (!_enrolled) return const ErrorResponse('not enrolled');
        final target = _find(peer);
        if (target == null) return ErrorResponse('no peer named "$peer"');
        final best = target.bestPath();
        if (best == null) return ErrorResponse('no path to $peer is up');
        return SentResponse(path: best, bytes: utf8.encode(data).length);

      case JoinRequest(:final key):
        if (key.trim().isEmpty) {
          return const ErrorResponse('an enrollment key is required');
        }
        if (key.trim().length < 8) {
          return ErrorResponse(
            'the control plane rejected that key: '
            'no such enrollment key "${key.trim()}"',
          );
        }
        // A realistic enrollment is a round trip to the control plane.
        await Future<void>.delayed(const Duration(milliseconds: 700));
        _enrolled = true;
        _nodeId = 'nd_${_hex(12)}';
        _virtualIp = '10.201.0.4';
        _subnet = '10.201.0.0/16';
        for (final p in _peers) {
          p.reset();
        }
        return JoinedResponse(
          nodeId: _nodeId,
          virtualIp: _virtualIp,
          subnet: _subnet,
        );

      case LeaveRequest():
        if (!_enrolled) return const ErrorResponse('not enrolled');
        await Future<void>.delayed(const Duration(milliseconds: 400));
        _enrolled = false;
        final id = _nodeId;
        for (final p in _peers) {
          p.reset();
        }
        // Every third leave pretends the control plane was unreachable, which
        // is the case the confirm dialog has to quote.
        final unlucky = _rng.nextInt(3) == 0;
        return LeftResponse(
          nodeId: id,
          detail: unlucky
              ? 'the control plane was unreachable, so the node record still '
                    'exists; remove it with `meshctl remove-node $id`'
              : '',
        );
    }
  }

  StatusReport _status() {
    if (!_enrolled) {
      return StatusReport(
        nodeName: _nodeName,
        enrolled: false,
        virtualIp: '',
        subnet: '',
        peerCount: 0,
        uptimeSecs: _t.floor(),
      );
    }
    final t = _t;
    return StatusReport(
      nodeName: _nodeName,
      enrolled: true,
      virtualIp: _virtualIp,
      subnet: _subnet,
      // The cloudflare plane drops for ten seconds out of every two minutes,
      // so the Overview's backhaul panel is not permanently green.
      cloudflare: BackhaulReport(
        up: t % 120 > 10,
        address: '100.96.40.4',
        detail: t % 120 > 10
            ? 'warp registered, endpoint 162.159.193.5:2408'
            : 're-registering with the zero trust org',
      ),
      tailscale: BackhaulReport(
        up: true,
        address: '100.115.7.4',
        detail: 'derp region 9, direct to 3 of 3',
      ),
      peerCount: _peers.length,
      uptimeSecs: t.floor(),
    );
  }

  _Peer? _find(String name) {
    for (final p in _peers) {
      if (p.name == name) return p;
    }
    return null;
  }

  /// One probe per path per sequence number, paced like real round trips.
  Future<List<PingSample>> _probe(_Peer peer, int count) async {
    final n = count.clamp(1, 32);
    final samples = <PingSample>[];
    for (var seq = 0; seq < n; seq++) {
      await Future<void>.delayed(
        Duration(milliseconds: 140 + _rng.nextInt(90)),
      );
      for (final path in peer.paths) {
        if (path.dead) continue;
        samples.add(
          PingSample(path: path.name, seq: seq, rttMs: path.probe(_t, _rng)),
        );
      }
    }
    return samples;
  }

  String _hex(int n) {
    const digits = '0123456789abcdef';
    return String.fromCharCodes([
      for (var i = 0; i < n; i++) digits.codeUnitAt(_rng.nextInt(16)),
    ]);
  }
}

// ---------------------------------------------------------------------------
// the model
// ---------------------------------------------------------------------------

class _Peer {
  _Peer({
    required this.name,
    required this.virtualIp,
    required this.cfIp,
    required this.tsHostname,
    required this.paths,
    this.flapping,
  });

  final String name;
  final String virtualIp;
  final String? cfIp;
  final String? tsHostname;
  final List<_Path> paths;

  /// The path that goes down and comes back every twenty seconds.
  final String? flapping;

  void tick(double t, Random rng) {
    for (final path in paths) {
      if (path.name == flapping) {
        // Twenty seconds up, twenty down, forever.
        path.up = (t ~/ 20).isEven;
      }
      path.tick(t, rng);
    }
  }

  void reset() {
    for (final path in paths) {
      path.reset();
    }
  }

  String? bestPath() {
    String? best;
    double? bestMs;
    for (final path in paths) {
      if (path.dead || !path.up || path.ewmaMs == null) continue;
      if (bestMs == null || path.ewmaMs! < bestMs) {
        bestMs = path.ewmaMs;
        best = path.name;
      }
    }
    return best;
  }

  PeerReport report() => PeerReport(
    name: name,
    virtualIp: virtualIp,
    cfIp: cfIp,
    tsHostname: tsHostname,
    bestPath: bestPath(),
    paths: [for (final p in paths) p.report()],
  );
}

class _Path {
  _Path(
    this.name, {
    required this.base,
    required this.swing,
    required this.period,
    required this.phase,
    this.loss = 0,
    this.dead = false,
  });

  final String name;

  /// A slow sine around [base] with amplitude [swing]: enough drift that two
  /// paths in antiphase trade the lead without anything failing.
  final double base;
  final double swing;
  final double period;
  final double phase;

  /// Percent of probes that never come back.
  final double loss;

  /// Configured-but-never-up, which is what "not configured" looks like on
  /// the wire: a path that is present and down.
  final bool dead;

  bool up = true;
  int sent = 0;
  int received = 0;
  double? lastRttMs;
  double? ewmaMs;

  /// The last 64 outcomes, so loss_pct reflects now rather than all of time.
  final List<bool> _window = [];

  double _target(double t) => base + swing * sin(2 * pi * t / period + phase);

  /// One probe's RTT, or null for a drop.
  double? probe(double t, Random rng) {
    if (dead || !up) return null;
    if (rng.nextDouble() * 100 < loss) return null;
    final jitter = (rng.nextDouble() - 0.5) * (1.5 + base * 0.08);
    return max(0.35, _target(t) + jitter);
  }

  void tick(double t, Random rng) {
    if (dead) {
      up = false;
      return;
    }
    sent++;
    final rtt = probe(t, rng);
    _window.add(rtt != null);
    while (_window.length > 64) {
      _window.removeAt(0);
    }
    if (rtt == null) {
      lastRttMs = null;
      return;
    }
    received++;
    lastRttMs = rtt;
    ewmaMs = ewmaMs == null ? rtt : ewmaMs! * 0.8 + rtt * 0.2;
  }

  void reset() {
    sent = 0;
    received = 0;
    lastRttMs = null;
    ewmaMs = null;
    _window.clear();
    up = !dead;
  }

  double get lossPct {
    if (_window.isEmpty) return dead ? 100 : 0;
    final lost = _window.where((ok) => !ok).length;
    return lost * 100 / _window.length;
  }

  PathReport report() => PathReport(
    path: name,
    up: !dead && up,
    lastRttMs: lastRttMs,
    ewmaMs: ewmaMs,
    sent: sent,
    received: received,
    lossPct: double.parse(lossPct.toStringAsFixed(1)),
  );
}
