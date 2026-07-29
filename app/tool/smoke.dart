/// End-to-end check of the daemon client against `tool/fake_meshd.dart`.
///
/// Starts the dev daemon on a scratch socket, drives `DaemonClient` through
/// status, peers, ping, join and leave, and checks the failure paths too: a
/// socket that is not there, a server that says nothing, a server that says
/// something that is not this protocol, and a request that outruns its
/// timeout. Prints what it found and exits nonzero the moment anything
/// disagrees.
///
///     dart run tool/smoke.dart
///
/// It is a smoke test, not a unit test: the point is that the wire format,
/// the transport and the error classification all agree with each other
/// outside the analyzer's imagination.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mesh_app/src/data/daemon_client.dart';
import 'package:mesh_app/src/data/ipc_protocol.dart';

int _failures = 0;
int _checks = 0;

void main(List<String> args) async {
  if (Platform.isWindows) {
    stderr.writeln('smoke needs a unix socket; run it on macOS or Linux');
    exit(1);
  }

  final scratch = await Directory.systemTemp.createTemp('mesh-smoke-');
  final socket = '${scratch.path}/meshd.sock';
  Process? daemon;

  try {
    daemon = await _startFakeDaemon(socket);
    final client = DaemonClient(endpoint: socket);

    await _endpointResolution();
    await _status(client);
    await _peers(client);
    await _ping(client);
    await _pingUnknownPeer(client);
    await _leaveAndJoin(client);
    await _missingSocket(scratch.path);
    await _silentServer(scratch.path);
    await _garbageServer(scratch.path);
    await _slowServer(scratch.path);
  } on Object catch (e, stack) {
    _fail('the run itself', '$e\n$stack');
  } finally {
    daemon?.kill(ProcessSignal.sigterm);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    daemon?.kill(ProcessSignal.sigkill);
    try {
      await scratch.delete(recursive: true);
    } on FileSystemException {
      // A scratch directory we could not clean up is not a failure.
    }
  }

  stdout.writeln('');
  if (_failures == 0) {
    stdout.writeln('$_checks checks, all good');
    exit(0);
  }
  stdout.writeln('$_checks checks, $_failures failed');
  exit(1);
}

// ---------------------------------------------------------------------------
// the checks
// ---------------------------------------------------------------------------

Future<void> _endpointResolution() async {
  _section('endpoint resolution');
  _expect(
    'MESH_SOCKET wins outright',
    resolveDaemonEndpoint(
      environment: {'MESH_SOCKET': '/tmp/x.sock', 'MESH_STATE_DIR': '/srv'},
    ),
    '/tmp/x.sock',
  );
  _expect(
    'MESH_STATE_DIR moves the socket',
    resolveDaemonEndpoint(environment: {'MESH_STATE_DIR': '/srv/mesh'}),
    '/srv/mesh/meshd.sock',
  );
  _expect(
    'and otherwise it is the state directory default',
    resolveDaemonEndpoint(environment: const {}),
    '/var/lib/mesh/meshd.sock',
  );
  _expect(
    'an empty MESH_SOCKET is not a value',
    resolveDaemonEndpoint(environment: {'MESH_SOCKET': ''}),
    '/var/lib/mesh/meshd.sock',
  );
}

Future<void> _status(DaemonClient client) async {
  _section('status');
  final s = await client.status();
  stdout.writeln(
    '  node ${s.nodeName}  ${s.virtualIp} in ${s.subnet}  '
    'up ${s.uptimeSecs}s  ${s.peerCount} peers',
  );
  for (final entry in s.backhauls.entries) {
    final b = entry.value;
    stdout.writeln(
      '  ${entry.key.padRight(10)} '
      '${b == null ? 'not configured' : '${b.up ? 'up  ' : 'down'} ${b.address}  (${b.detail})'}',
    );
  }
  _check('the daemon says it is enrolled', s.enrolled);
  _check('the node has a name', s.nodeName.isNotEmpty);
  _check('the node has an address', s.virtualIp.isNotEmpty);
  _check('the node has a subnet', s.subnet.isNotEmpty);
  _check(
    'peer_count is the three fake peers',
    s.peerCount == 3,
    'got ${s.peerCount}',
  );
  _check('cloudflare is reported', s.cloudflare != null);
  _check('tailscale is reported', s.tailscale != null);
}

Future<void> _peers(DaemonClient client) async {
  _section('peers');
  // Let the daemon tick a few times so the ewmas are populated.
  await Future<void>.delayed(const Duration(milliseconds: 1600));
  final peers = await client.peers();

  for (final p in peers) {
    stdout.writeln(
      '  ${p.name.padRight(8)} ${(p.virtualIp ?? '-').padRight(14)} '
      'best=${p.bestPath ?? 'none'}',
    );
    for (final path in p.paths) {
      stdout.writeln(
        '    ${path.path.padRight(12)} ${path.up ? 'up  ' : 'down'} '
        'last=${_ms(path.lastRttMs)} ewma=${_ms(path.ewmaMs)} '
        'sent=${path.sent} recv=${path.received} '
        'loss=${path.lossPct.toStringAsFixed(1)}%',
      );
    }
  }

  _check('three peers', peers.length == 3, 'got ${peers.length}');
  _check(
    'the peers are the ones fake_meshd defines',
    peers.map((p) => p.name).toSet().containsAll({
      'aurora',
      'basalt',
      'cinder',
    }),
    peers.map((p) => p.name).join(', '),
  );
  for (final p in peers) {
    _check(
      '${p.name} reports all three paths',
      p.paths.map((x) => x.path).toSet().containsAll(meshPathNames.toSet()),
      p.paths.map((x) => x.path).join(', '),
    );
    _check('${p.name} has an address', (p.virtualIp ?? '').isNotEmpty);
  }
  _check(
    'at least one peer has a winning path with an ewma',
    peers.any((p) => p.best != null && p.best!.ewmaMs != null),
  );
  final lossy = peers
      .expand((p) => p.paths)
      .where((path) => path.lossPct > 0)
      .toList();
  _check(
    'one path is losing probes, as designed',
    lossy.isNotEmpty,
    'no path reported loss',
  );
  _check(
    'loss_pct is a percentage, not a fraction',
    lossy.every((path) => path.lossPct <= 100),
  );
  _check(
    'cinder has a path that is down',
    peers.firstWhere((p) => p.name == 'cinder').paths.any((path) => !path.up),
  );
}

Future<void> _ping(DaemonClient client) async {
  _section('ping aurora');
  final started = DateTime.now();
  final samples = await client.ping('aurora', count: 3);
  final took = DateTime.now().difference(started);

  final summary = PingSummary.of(samples);
  for (final s in samples) {
    stdout.writeln(
      '  ${s.path.padRight(12)} seq=${s.seq} '
      '${s.rttMs == null ? 'timeout' : '${s.rttMs!.toStringAsFixed(2)} ms'}',
    );
  }
  stdout.writeln('');
  for (final p in summary.paths) {
    stdout.writeln(
      p.silent
          ? '  ${p.path.padRight(12)} no replies (${p.sent} sent)'
          : '  ${p.path.padRight(12)} min ${p.minMs!.toStringAsFixed(2)} '
                'avg ${p.avgMs!.toStringAsFixed(2)} '
                'max ${p.maxMs!.toStringAsFixed(2)} ms  '
                '(${p.replied}/${p.sent} replied)',
    );
  }
  if (summary.winner != null) {
    stdout.writeln(
      '  winner: ${summary.winner!.path} at '
      '${summary.winner!.avgMs!.toStringAsFixed(2)} ms average',
    );
  }

  _check('ping returned samples', samples.isNotEmpty);
  _check(
    'every sample names a known path',
    samples.every((s) => meshPathNames.contains(s.path)),
  );
  _check(
    'sequence numbers cover the requested count',
    samples.map((s) => s.seq).toSet().length == 3,
    samples.map((s) => s.seq).toSet().join(', '),
  );
  _check(
    'the summary has one row per probed path',
    summary.paths.length == samples.map((s) => s.path).toSet().length,
  );
  _check(
    'a slow ping still fits inside the 30s ping timeout',
    took < DaemonClient.pingTimeout,
    'took $took',
  );
  _check(
    'and it took long enough to be a real probe',
    took > const Duration(milliseconds: 200),
    'took $took',
  );
}

Future<void> _pingUnknownPeer(DaemonClient client) async {
  _section('ping a peer that is not there');
  try {
    await client.ping('nobody', count: 1);
    _fail('an unknown peer is refused', 'the call succeeded');
  } on DaemonRefused catch (e) {
    stdout.writeln('  ${e.message}');
    _check('an unknown peer is refused', true);
    _check('the daemon\'s own words come back', e.message.contains('nobody'));
  }
}

Future<void> _leaveAndJoin(DaemonClient client) async {
  _section('leave and join');

  final left = await client.leave();
  stdout.writeln('  left as ${left.nodeId}');
  if (left.detail.isNotEmpty) stdout.writeln('  ${left.detail}');
  _check('leave names the node it removed', left.nodeId.isNotEmpty);

  final after = await client.status();
  _check('the daemon is no longer enrolled', !after.enrolled);
  _check('an unenrolled daemon has no peers', (await client.peers()).isEmpty);

  try {
    await client.join('   ');
    _fail('an empty key is refused', 'the call succeeded');
  } on DaemonRefused catch (e) {
    stdout.writeln('  ${e.message}');
    _check('an empty key is refused', true);
  }

  final joined = await client.join('mek_live_9f2c11ab77d0');
  stdout.writeln(
    '  joined as ${joined.nodeId}, ${joined.virtualIp} in ${joined.subnet}',
  );
  _check('join returns a node id', joined.nodeId.isNotEmpty);
  _check('join returns an address', joined.virtualIp.isNotEmpty);
  _check('join returns a subnet', joined.subnet.isNotEmpty);

  final back = await client.status();
  _check('the daemon is enrolled again', back.enrolled);
  _check('and it kept its address', back.virtualIp == joined.virtualIp);
}

Future<void> _missingSocket(String scratch) async {
  _section('a socket that is not there');
  final client = DaemonClient(endpoint: '$scratch/nothing-here.sock');
  try {
    await client.status();
    _fail('a missing socket is a DaemonSocketMissing', 'the call succeeded');
  } on DaemonException catch (e) {
    stdout.writeln('  ${e.runtimeType}: ${e.message}');
    if (e.hint != null) stdout.writeln('  hint: ${e.hint}');
    _check(
      'a missing socket is a DaemonSocketMissing',
      e is DaemonSocketMissing,
      'got ${e.runtimeType}',
    );
    _check('and it names the endpoint in its hint', e.hint!.contains(scratch));
  }
}

Future<void> _silentServer(String scratch) async {
  _section('a server that answers nothing');
  final path = '$scratch/silent.sock';
  final server = await ServerSocket.bind(
    InternetAddress(path, type: InternetAddressType.unix),
    0,
  );
  // Read the request in full, then hang up without a word. Closing before the
  // request lands would be a broken pipe, which is a transport failure and a
  // different thing from a daemon that listened and said nothing.
  server.listen((s) {
    s
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((_) {
          s.destroy();
        });
  });
  try {
    await DaemonClient(endpoint: path).status();
    _fail('silence is a protocol error', 'the call succeeded');
  } on DaemonException catch (e) {
    stdout.writeln('  ${e.runtimeType}: ${e.message}');
    _check(
      'silence is a protocol error',
      e is DaemonProtocolError,
      'got ${e.runtimeType}',
    );
  } finally {
    await server.close();
  }
}

Future<void> _garbageServer(String scratch) async {
  _section('a server that answers something else');
  final path = '$scratch/garbage.sock';
  final server = await ServerSocket.bind(
    InternetAddress(path, type: InternetAddressType.unix),
    0,
  );
  server.listen((s) async {
    s.add(utf8.encode('{"weather":"fine"}\n'));
    await s.flush();
    await s.close();
  });
  try {
    await DaemonClient(endpoint: path).status();
    _fail('an unknown tag is a protocol error', 'the call succeeded');
  } on DaemonException catch (e) {
    stdout.writeln('  ${e.runtimeType}: ${e.message}');
    _check(
      'an unknown tag is a protocol error',
      e is DaemonProtocolError,
      'got ${e.runtimeType}',
    );
  } finally {
    await server.close();
  }
}

Future<void> _slowServer(String scratch) async {
  _section('a server that takes too long');
  final path = '$scratch/slow.sock';
  final server = await ServerSocket.bind(
    InternetAddress(path, type: InternetAddressType.unix),
    0,
  );
  final held = <Socket>[];
  server.listen(held.add);
  try {
    await DaemonClient(
      endpoint: path,
    ).call(const StatusRequest(), timeout: const Duration(milliseconds: 300));
    _fail('a stalled daemon times out', 'the call succeeded');
  } on DaemonException catch (e) {
    stdout.writeln('  ${e.runtimeType}: ${e.message}');
    _check(
      'a stalled daemon times out',
      e is DaemonUnreachable && e.timedOut,
      'got ${e.runtimeType}',
    );
  } finally {
    for (final s in held) {
      s.destroy();
    }
    await server.close();
  }
}

// ---------------------------------------------------------------------------
// harness
// ---------------------------------------------------------------------------

Future<Process> _startFakeDaemon(String socket) async {
  final root = _appRoot();
  final process = await Process.start(Platform.resolvedExecutable, [
    'run',
    'tool/fake_meshd.dart',
    socket,
  ], workingDirectory: root);

  final listening = Completer<void>();
  process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
    (line) {
      if (line.startsWith('listening on') && !listening.isCompleted) {
        listening.complete();
      }
    },
  );
  process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) => stderr.writeln('  fake_meshd: $line'));

  unawaited(
    process.exitCode.then((code) {
      if (!listening.isCompleted) {
        listening.completeError(
          StateError('fake_meshd exited with $code before it was listening'),
        );
      }
    }),
  );

  await listening.future.timeout(
    const Duration(seconds: 30),
    onTimeout: () => throw StateError('fake_meshd never came up on $socket'),
  );
  stdout.writeln('fake_meshd is listening on $socket');
  return process;
}

/// This file lives in `<app>/tool`, so the package root is one up. Resolved
/// from the script rather than the cwd so the tool works from anywhere.
String _appRoot() => File.fromUri(Platform.script).parent.parent.absolute.path;

void _section(String title) => stdout.writeln('\n$title');

void _check(String what, bool ok, [String? detail]) {
  _checks++;
  if (ok) {
    stdout.writeln('  ok    $what');
  } else {
    _failures++;
    stdout.writeln('  FAIL  $what${detail == null ? '' : ' — $detail'}');
  }
}

void _expect(String what, Object? got, Object? want) =>
    _check(what, got == want, 'got $got, wanted $want');

void _fail(String what, String detail) {
  _checks++;
  _failures++;
  stdout.writeln('  FAIL  $what — $detail');
}

String _ms(double? v) => v == null ? '-' : v.toStringAsFixed(2);
