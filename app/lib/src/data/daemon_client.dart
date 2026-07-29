/// Talking to `meshd` over its unix socket.
///
/// One connection per request, exactly like `meshctl`: dial, write one JSON
/// line, read one JSON line, hang up. There is no session, no multiplexing and
/// nothing to keep alive, so a long-lived socket would only be a thing that can
/// go stale between polls.
///
/// Windows is a named pipe in the Rust code and tokio's pipe API has no dart:io
/// equivalent, so the transport there fails with a clear sentence instead of a
/// misleading connection error.
///
/// Free of Flutter imports so the dev tools can drive it under `dart run`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ipc_protocol.dart';

/// Where the daemon listens, resolved exactly the way `default_endpoint()` in
/// `ipc.rs` resolves it.
///
/// `MESH_SOCKET` wins outright. Otherwise the socket sits in the state
/// directory, which is `/var/lib/mesh` unless `MESH_STATE_DIR` says otherwise.
String resolveDaemonEndpoint({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final explicit = env['MESH_SOCKET'];
  if (explicit != null && explicit.isNotEmpty) return explicit;
  if (Platform.isWindows) return r'\\.\pipe\meshd';
  final dir = env['MESH_STATE_DIR'];
  final base = (dir != null && dir.isNotEmpty) ? dir : '/var/lib/mesh';
  return base.endsWith(Platform.pathSeparator)
      ? '${base}meshd.sock'
      : '$base${Platform.pathSeparator}meshd.sock';
}

// ---------------------------------------------------------------------------
// errors
//
// Distinct types rather than one message, because the screens react
// differently: a missing socket means "start the daemon", EACCES means "the
// socket is root-only and here is the chmod", and a protocol error means the
// daemon and the app disagree about the wire format.
// ---------------------------------------------------------------------------

sealed class DaemonException implements Exception {
  const DaemonException(this.endpoint, this.message);

  /// The socket we were talking to. Useful in every one of these.
  final String endpoint;

  /// Shown verbatim, in mono, inside the panel that caused it.
  final String message;

  /// A second line the UI may show under the message. Null when there is
  /// nothing useful to add.
  String? get hint => null;

  @override
  String toString() => message;
}

/// There is no socket at that path: the daemon has never run, or is not
/// running and cleaned up after itself.
class DaemonSocketMissing extends DaemonException {
  const DaemonSocketMissing(super.endpoint, super.message);

  @override
  String? get hint => 'No socket at $endpoint — is meshd running?';
}

/// The socket is there but this user may not open it.
///
/// meshd chmods the socket 0666 at bind, so this is either an older daemon or
/// one whose bind-time chmod did not take. The suggestion mirrors the brief.
class DaemonPermissionDenied extends DaemonException {
  const DaemonPermissionDenied(super.endpoint, super.message);

  @override
  String? get hint =>
      'The socket is root-only; for now: sudo chmod 666 $endpoint';
}

/// The socket exists and we may open it, but nothing answered: a stale socket
/// file, a daemon mid-restart, or a request that outran its timeout.
class DaemonUnreachable extends DaemonException {
  const DaemonUnreachable(
    super.endpoint,
    super.message, {
    this.timedOut = false,
  });

  final bool timedOut;
}

/// The transport is not implemented on this platform.
class DaemonUnsupportedPlatform extends DaemonException {
  const DaemonUnsupportedPlatform(super.endpoint, super.message);
}

/// We talked to something, and it did not speak this protocol.
class DaemonProtocolError extends DaemonException {
  const DaemonProtocolError(super.endpoint, super.message);
}

/// The daemon answered `{"error": "..."}`. Not a transport failure: the daemon
/// is fine and is telling us no.
class DaemonRefused extends DaemonException {
  const DaemonRefused(super.endpoint, super.message);
}

// ---------------------------------------------------------------------------
// client
// ---------------------------------------------------------------------------

/// A stateless caller. Holding one is free; every method dials its own socket.
class DaemonClient {
  DaemonClient({String? endpoint, Map<String, String>? environment})
    : endpoint = endpoint ?? resolveDaemonEndpoint(environment: environment);

  final String endpoint;

  /// Long enough that a busy daemon still answers, short enough that a dead
  /// one does not stall a 2s poll cycle.
  static const Duration defaultTimeout = Duration(seconds: 5);

  /// A ping is four probes on every path with real round trips behind them.
  static const Duration pingTimeout = Duration(seconds: 30);

  Future<StatusReport> status() async => _expect<StatusResponse>(
    await call(const StatusRequest()),
    'status',
  ).report;

  Future<List<PeerReport>> peers() async =>
      _expect<PeersResponse>(await call(const PeersRequest()), 'peers').peers;

  Future<List<PingSample>> ping(String peer, {int count = 4}) async =>
      _expect<PingResponse>(
        await call(PingRequest(peer: peer, count: count)),
        'ping',
      ).samples;

  Future<JoinedResponse> join(String key) async =>
      _expect<JoinedResponse>(await call(JoinRequest(key: key)), 'joined');

  Future<LeftResponse> leave() async =>
      _expect<LeftResponse>(await call(const LeaveRequest()), 'left');

  /// One request, one response. Throws a [DaemonException] and nothing else.
  Future<MeshResponse> call(MeshRequest request, {Duration? timeout}) async {
    if (Platform.isWindows) {
      throw DaemonUnsupportedPlatform(
        endpoint,
        'the daemon speaks a named pipe on Windows and this app cannot open '
        'one yet; run the app on macOS or Linux for now',
      );
    }

    final deadline =
        timeout ?? (request is PingRequest ? pingTimeout : defaultTimeout);
    final holder = _Held();
    final work = _exchange(request, holder);
    // When the timeout wins the race nobody is listening to `work` any more,
    // and the socket destroyed under it in `finally` will make it fail. This
    // listener exists only so that failure is not reported as unhandled.
    work.then((_) {}, onError: (_, _) {});
    try {
      return await work.timeout(
        deadline,
        onTimeout: () => throw DaemonUnreachable(
          endpoint,
          'the daemon did not answer ${request.cmd} within '
          '${_readable(deadline)}',
          timedOut: true,
        ),
      );
    } on SocketException catch (e) {
      throw _classify(e);
    } on FileSystemException catch (e) {
      throw _classify(
        SocketException(e.message, osError: e.osError, address: null),
      );
    } on FormatException catch (e) {
      throw DaemonProtocolError(
        endpoint,
        'the daemon sent something this app could not read: ${e.message}',
      );
    } finally {
      holder.socket?.destroy();
    }
  }

  Future<MeshResponse> _exchange(MeshRequest request, _Held holder) async {
    final socket = await Socket.connect(
      InternetAddress(endpoint, type: InternetAddressType.unix),
      0,
    );
    holder.socket = socket;

    socket.add(utf8.encode(request.encodeLine()));
    await socket.flush();

    final lines = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    String line;
    try {
      // `firstWhere` rather than `first` so a daemon that writes a blank line
      // before its answer is not mistaken for one that never answered.
      line = await lines.firstWhere((l) => l.trim().isNotEmpty);
    } on StateError {
      throw DaemonProtocolError(
        endpoint,
        'the daemon closed the connection without replying',
      );
    }

    final response = MeshResponse.decodeLine(line);
    if (response is ErrorResponse) {
      throw DaemonRefused(endpoint, response.message);
    }
    return response;
  }

  T _expect<T extends MeshResponse>(MeshResponse response, String want) {
    if (response is T) return response;
    throw DaemonProtocolError(
      endpoint,
      'asked for $want and the daemon answered "${response.tag}"',
    );
  }

  DaemonException _classify(SocketException e) {
    final os = e.osError;
    final text = os == null ? e.message : '${e.message}: ${os.message}';
    return switch (os?.errorCode) {
      _enoent => DaemonSocketMissing(endpoint, text),
      _eacces || _eperm => DaemonPermissionDenied(endpoint, text),
      _ => DaemonUnreachable(endpoint, text),
    };
  }

  // errno values are stable across macOS and Linux for these three.
  static const int _eperm = 1;
  static const int _enoent = 2;
  static const int _eacces = 13;
}

/// Somewhere to put the socket so `finally` can destroy it even when the
/// failure was the connect itself.
class _Held {
  Socket? socket;
}

/// "5s", "300ms" — never "0s", which is what `inSeconds` gives for anything
/// under a second and reads as a bug in the timeout rather than in the daemon.
String _readable(Duration d) =>
    d.inMilliseconds < 1000 ? '${d.inMilliseconds}ms' : '${d.inSeconds}s';
