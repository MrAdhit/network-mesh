/// A control plane that only knows how to hand out binaries.
///
/// Two endpoints, the same two `meshctl update` and the app use:
///
///     GET /v1/updates/{target}         the manifest
///     GET /v1/updates/{target}/{name}  the bytes
///
/// The payload is a small shell script rather than a real binary, so what comes
/// down is inspectable and the manifest's sha256 is computed from the exact
/// bytes served. That is the whole point: the app must accept this and reject
/// the same server run with `--corrupt`, which serves bytes that do not match
/// the hash it advertised, or with `--overrun`, which keeps sending after it
/// has sent everything it promised.
///
///     dart run tool/fake_update_cp.dart
///     dart run tool/fake_update_cp.dart --corrupt --port 8099
///     dart run tool/fake_update_cp.dart --overrun --port 8099
///
/// Point the app at it with MESH_CP_URL. Plain http is allowed to 127.0.0.1 and
/// nowhere else, which is why this binds loopback.
library;

import 'dart:convert';
import 'dart:io';

import 'package:mesh_app/src/data/update_client.dart';
import 'package:mesh_app/src/util/sha256.dart';

Future<void> main(List<String> args) async {
  var port = 8099;
  var corrupt = false;
  var overrun = false;
  var size = 64 * 1024;
  final targets = <String>{targetAppleSilicon, targetIntelMac};

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--port':
        port = int.parse(args[++i]);
      case '--size':
        size = int.parse(args[++i]);
      case '--target':
        targets
          ..clear()
          ..add(args[++i]);
      case '--corrupt':
        corrupt = true;
      case '--overrun':
        overrun = true;
      case '-h' || '--help':
        stdout.writeln(_usage);
        return;
      default:
        stderr.writeln('unknown option ${args[i]}');
        stderr.writeln(_usage);
        exitCode = 2;
        return;
    }
  }

  final server = FakeUpdateCp(
    corrupt: corrupt,
    overrun: overrun,
    payloadSize: size,
  )..targets.addAll(targets);
  final url = await server.start(port: port);
  stdout.writeln('serving updates at $url');
  for (final target in server.targets) {
    stdout.writeln('  $url/v1/updates/$target');
  }
  final lies = [
    if (corrupt) 'corrupt: the bytes served do not match',
    if (overrun)
      'overrun: ${server.served.length * 2} bytes go down the socket, '
          'and the response declares no length',
  ];
  stdout.writeln(
    '  meshd  ${server.advertisedSha256}  ${server.payload.length} bytes'
    '${lies.isEmpty ? '' : '  (${lies.join('; ')})'}',
  );
  stdout.writeln('point the app at it: MESH_CP_URL=$url flutter run -d macos');

  Future<void> bye(ProcessSignal _) async {
    stdout.writeln('\nstopping');
    await server.stop();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(bye);
  ProcessSignal.sigterm.watch().listen(bye);
}

const String _usage = '''
fake_update_cp - a control plane that serves nothing but update manifests

    --port <n>       port to bind on 127.0.0.1, default 8099
    --target <t>     serve this target only, default both macOS triples
    --size <bytes>   payload size, default 65536
    --corrupt        advertise one hash and serve different bytes
    --overrun        advertise one size and keep sending past it
    -h, --help
''';

/// The server, as a thing a test can also hold.
class FakeUpdateCp {
  FakeUpdateCp({
    this.corrupt = false,
    this.overrun = false,
    int payloadSize = 64 * 1024,
  }) : payload = _payload(payloadSize);

  /// Serve bytes that do not hash to what the manifest promised. The download
  /// must be refused and deleted rather than installed.
  final bool corrupt;

  /// Send the body twice and declare no length for it.
  ///
  /// The missing Content-Length is the point rather than an oversight: a
  /// response with no declared length is ordinary — anything behind a proxy may
  /// arrive chunked — so there is nothing in the headers a client could refuse.
  /// The only thing between it and a full disk is the count it keeps as the
  /// bytes land, which is what this mode exists to make it prove.
  final bool overrun;

  /// What the manifest describes. Also what is served, unless [corrupt].
  final List<int> payload;

  final Set<String> targets = <String>{};

  HttpServer? _server;

  /// The hash in the manifest: always the honest one for [payload], so a
  /// corrupt run is a server that lies about the bytes rather than the hash.
  late final String advertisedSha256 = sha256Hex(payload);

  /// The bytes actually served. One flipped byte is enough; a wholly different
  /// body would also fail the length check and prove less.
  late final List<int> served = corrupt
      ? (List<int>.of(payload)..[0] = payload[0] ^ 0xff)
      : payload;

  /// Binds loopback and returns the base URL.
  Future<String> start({int port = 8099}) async {
    if (targets.isEmpty) {
      targets.addAll({targetAppleSilicon, targetIntelMac});
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    server.listen(_serve, onError: (Object e) => stderr.writeln('accept: $e'));
    return 'http://127.0.0.1:${server.port}';
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _serve(HttpRequest request) async {
    try {
      await _route(request);
    } on Object catch (e) {
      // A client that hangs up mid-body is what --overrun is for, and the write
      // that was in flight fails. There is nobody left to tell, and an
      // unhandled error here would take the server down with it.
      stderr.writeln('serve: $e');
    }
  }

  Future<void> _route(HttpRequest request) async {
    final parts = request.uri.pathSegments;
    if (request.method != 'GET') {
      await _fail(request, HttpStatus.methodNotAllowed, 'GET only');
      return;
    }
    // /v1/updates/{target}[/{name}]
    if (parts.length < 3 || parts[0] != 'v1' || parts[1] != 'updates') {
      await _fail(request, HttpStatus.notFound, 'no such endpoint');
      return;
    }
    final target = parts[2];
    if (!targets.contains(target)) {
      await _fail(request, HttpStatus.notFound, 'no build for $target');
      return;
    }

    if (parts.length == 3) {
      request.response
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'target': target,
            'binaries': [
              for (final name in const ['meshd', 'meshctl'])
                {
                  'name': name,
                  'sha256': advertisedSha256,
                  'size': payload.length,
                },
            ],
          }),
        );
      await request.response.close();
      return;
    }

    if (parts.length == 4 && (parts[3] == 'meshd' || parts[3] == 'meshctl')) {
      request.response.headers.contentType = ContentType.binary;
      if (overrun) {
        request.response
          ..add(served)
          ..add(served);
      } else {
        request.response
          ..headers.contentLength = served.length
          ..add(served);
      }
      await request.response.close();
      return;
    }
    await _fail(request, HttpStatus.notFound, 'no such binary');
  }

  Future<void> _fail(HttpRequest request, int status, String message) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'error': message}));
    await request.response.close();
  }

  /// Something that looks like a program and is the same every run, so two
  /// runs of the server agree on the hash.
  static List<int> _payload(int size) {
    const head = '#!/bin/sh\n# not meshd, but the right shape\necho meshd\n';
    final bytes = <int>[...utf8.encode(head)];
    var x = 0x2545f491;
    while (bytes.length < size) {
      // xorshift, so the body is incompressible-looking and deterministic.
      x ^= (x << 13) & 0xffffffff;
      x ^= x >> 17;
      x ^= (x << 5) & 0xffffffff;
      bytes.add(x & 0xff);
    }
    return bytes;
  }
}
