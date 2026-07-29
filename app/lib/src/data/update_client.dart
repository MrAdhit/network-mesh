/// The control plane as a distribution channel.
///
/// The same two endpoints `meshctl update` uses, and the same rule that decides
/// whether a download is allowed near a path we will later execute from: the
/// manifest publishes a SHA-256, and a file that hashes to anything else is
/// deleted rather than kept. See `crates/mesh-core/src/update.rs` — identity is
/// the hash, not a version string, because a version is a claim.
///
///   GET {cp}/v1/updates/{target}         -> {"target", "binaries":[…]}
///   GET {cp}/v1/updates/{target}/{name}  -> the bytes
///
/// The download is hashed as it streams to disk. A binary is tens of megabytes
/// and there is no reason to hold one in memory to find out it was wrong — so
/// the loop that does it waits for the disk at a byte cadence rather than
/// pouring the whole transfer into a sink that buffers without complaint.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, HttpException, Process, SocketException;

import 'package:http/http.dart' as http;

import '../util/sha256.dart';
import 'privileged.dart'
    show HostPlatform, InvalidCpUrl, ProcessRunner, validatedCpUrl;

// ---------------------------------------------------------------------------
// targets
// ---------------------------------------------------------------------------

/// The Rust triples the control plane publishes macOS builds under.
const String targetAppleSilicon = 'aarch64-apple-darwin';
const String targetIntelMac = 'x86_64-apple-darwin';

/// This machine's target triple, the way install.sh works it out.
///
/// `uname -m` rather than anything Dart knows, because Dart reports the
/// architecture of the running process and the answer we need is the one the
/// control plane files its builds under. Null when this is not a Mac or when
/// `uname` says something no build exists for; the caller says so rather than
/// guessing a triple and getting a 404 it cannot explain.
///
/// The platform check comes first and is a seam rather than `Platform.isMacOS`,
/// because `uname` is not a program Windows has: a caller that has been told it
/// is on Windows must not fork one to find that out.
Future<String?> detectTarget({
  ProcessRunner? runProcess,
  HostPlatform? platform,
}) async {
  if (!(platform ?? HostPlatform.current).managesDaemon) return null;
  final run = runProcess ?? Process.run;
  try {
    final result = await run('/usr/bin/uname', ['-m']);
    if (result.exitCode != 0) return null;
    return targetForMachine('${result.stdout}'.trim());
  } on Exception {
    return null;
  }
}

/// The triple for a `uname -m` answer, or null for one we have no build for.
String? targetForMachine(String machine) => switch (machine.trim()) {
  'arm64' || 'aarch64' => targetAppleSilicon,
  'x86_64' || 'amd64' => targetIntelMac,
  _ => null,
};

// ---------------------------------------------------------------------------
// the manifest
// ---------------------------------------------------------------------------

/// What the control plane holds for one target. Mirrors `UpdateManifest`.
class UpdateManifest {
  const UpdateManifest({required this.target, required this.binaries});

  final String target;
  final List<BinaryInfo> binaries;

  /// Null means "not offered", which is normal for a control plane built
  /// without artifacts staged.
  BinaryInfo? get(String name) {
    for (final b in binaries) {
      if (b.name == name) return b;
    }
    return null;
  }

  factory UpdateManifest.fromJson(Map<String, Object?> json) {
    final raw = json['binaries'];
    return UpdateManifest(
      target: json['target'] is String ? json['target'] as String : '',
      binaries: raw is List
          ? [
              for (final e in raw)
                if (e is Map)
                  BinaryInfo.fromJson(e.map((k, v) => MapEntry('$k', v))),
            ]
          : const [],
    );
  }
}

/// One binary, named without a platform extension. Mirrors `BinaryInfo`.
class BinaryInfo {
  const BinaryInfo({
    required this.name,
    required this.sha256,
    required this.size,
  });

  final String name;
  final String sha256;
  final int size;

  /// The first twelve, which is what install.sh prints and what a person can
  /// actually compare by eye.
  String get shortSha => sha256.length <= 12 ? sha256 : sha256.substring(0, 12);

  factory BinaryInfo.fromJson(Map<String, Object?> json) => BinaryInfo(
    name: json['name'] is String ? json['name'] as String : '',
    sha256: json['sha256'] is String
        ? (json['sha256'] as String).toLowerCase()
        : '',
    size: json['size'] is num ? (json['size'] as num).toInt() : 0,
  );
}

// ---------------------------------------------------------------------------
// errors
// ---------------------------------------------------------------------------

sealed class UpdateException implements Exception {
  const UpdateException(this.message);

  /// Rendered verbatim, in mono, inside the panel that caused it.
  final String message;

  @override
  String toString() => message;
}

/// Could not get there at all: DNS, connection refused, TLS, timeout.
class UpdateUnreachable extends UpdateException {
  const UpdateUnreachable(super.message);
}

/// The control plane answered, and not with a 2xx.
class UpdateApiException extends UpdateException {
  const UpdateApiException(super.message, this.statusCode);

  final int statusCode;

  /// No build for this target. install.sh calls this out by name and so do we.
  bool get notOffered => statusCode == 404;
}

/// A 2xx whose body was not a manifest.
class UpdateProtocolException extends UpdateException {
  const UpdateProtocolException(super.message);
}

/// A download that is not what was promised. The file is already gone by the
/// time this is thrown.
class UpdateHashMismatch extends UpdateException {
  const UpdateHashMismatch(
    super.message, {
    required this.got,
    required this.want,
  });

  final String got;
  final String want;
}

/// Plain http to somewhere that is not this machine.
///
/// The manifest's hashes are the only thing vouching for a binary we are about
/// to run as root, and an unauthenticated plaintext fetch hands whoever is in
/// the middle the hashes as well as the bytes. Loopback is exempt because
/// development runs a control plane on 127.0.0.1 and there is no middle.
class UpdateInsecure extends UpdateException {
  const UpdateInsecure(super.message);
}

/// The effective control plane URL is not one we can fetch from at all.
class UpdateBadCpUrl extends UpdateException {
  const UpdateBadCpUrl(super.message);
}

// ---------------------------------------------------------------------------
// the client
// ---------------------------------------------------------------------------

/// Called as bytes land. [total] is null only when the response declares no
/// length and the manifest had no size either.
typedef DownloadProgress = void Function(int received, int? total);

/// How many bytes may sit in the file sink before something waits for the disk.
///
/// [IOSink.add] is a queue with no bottom: it takes what it is given, returns
/// immediately, and buffers in memory until the file consumer gets round to it.
/// A loop that only ever adds therefore holds the whole download in RAM, and a
/// loop that never awaits also never lets the file writes it queued run — which
/// is how a download of tens of megabytes became gigabytes of process.
///
/// Waiting on [IOSink.flush] every [_flushEvery] bytes fixes both halves with
/// one await. The flush does not complete until those bytes are on disk, which
/// caps the buffer; `await for` pauses the response while it is pending, so the
/// socket stops reading too; and the pause is a turn of the event loop, which
/// is when the window gets to paint. A quarter of a megabyte is small enough
/// that neither the buffer nor the stall is noticeable and large enough that a
/// binary costs a few hundred flushes rather than one per chunk.
const int _flushEvery = 256 * 1024;

/// A download that verified.
class VerifiedBinary {
  const VerifiedBinary({
    required this.file,
    required this.sha256,
    required this.size,
  });

  final File file;
  final String sha256;
  final int size;
}

class UpdateClient {
  UpdateClient({
    required String baseUrl,
    http.Client? httpClient,
    this.manifestTimeout = const Duration(seconds: 20),
    this.downloadTimeout = const Duration(minutes: 5),
  }) : baseUrl = requireFetchableCpUrl(baseUrl),
       _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  /// Trailing slashes off, so `$baseUrl/v1/...` never doubles up. Already
  /// checked by [requireFetchableCpUrl].
  final String baseUrl;

  /// update.rs gives the manifest 20s and the download 300s. So do we.
  final Duration manifestTimeout;
  final Duration downloadTimeout;

  final http.Client _http;
  final bool _ownsClient;

  void close() {
    if (_ownsClient) _http.close();
  }

  /// GET /v1/updates/{target}.
  Future<UpdateManifest> manifest(String target) async {
    final url = '$baseUrl/v1/updates/${Uri.encodeComponent(target)}';
    final response = await _get(url, manifestTimeout);
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _apiException(
        url,
        response.statusCode,
        response.reasonPhrase,
        text,
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw UpdateProtocolException('$url did not answer with JSON');
    }
    if (decoded is! Map) {
      throw UpdateProtocolException('$url did not answer with a manifest');
    }
    return UpdateManifest.fromJson(decoded.map((k, v) => MapEntry('$k', v)));
  }

  /// GET /v1/updates/{target}/{name}, straight to [into], hashed on the way.
  ///
  /// A mismatch deletes the file before throwing, exactly as update.rs refuses
  /// to leave one lying about: a binary nobody vouches for must not be sitting
  /// somewhere a later, less careful step could pick it up.
  ///
  /// The manifest's size is enforced as the bytes land rather than checked at
  /// the end, because the end is a promise the sender makes. The hash cannot be
  /// computed until the last byte arrives, so a control plane that is broken or
  /// dishonest can simply keep sending: the disk fills, and the check that
  /// would have caught it never runs. The first byte past what the manifest
  /// promised is therefore refused on arrival, and the partial file leaves the
  /// same way a bad hash sends it. A manifest with no size to enforce
  /// ([BinaryInfo.size] zero) is left as it was, with the hash as the backstop.
  Future<VerifiedBinary> download({
    required String target,
    required BinaryInfo want,
    required File into,
    DownloadProgress? onProgress,
  }) async {
    final url =
        '$baseUrl/v1/updates/${Uri.encodeComponent(target)}'
        '/${Uri.encodeComponent(want.name)}';

    final request = http.Request('GET', Uri.parse(url));
    final http.StreamedResponse response;
    try {
      response = await _http.send(request).timeout(downloadTimeout);
    } on TimeoutException {
      throw UpdateUnreachable(
        '$url did not answer within ${downloadTimeout.inSeconds}s',
      );
    } on SocketException catch (e) {
      throw UpdateUnreachable(_socketMessage(url, e));
    } on HttpException catch (e) {
      throw UpdateUnreachable('cannot reach $url: ${e.message}');
    } on http.ClientException catch (e) {
      throw UpdateUnreachable('cannot reach $url: ${e.message}');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      String body;
      try {
        body = await response.stream.bytesToString();
      } on Exception {
        body = '';
      }
      throw _apiException(
        url,
        response.statusCode,
        response.reasonPhrase,
        body,
      );
    }

    // A declared length that disagrees with the manifest is a refusal we can
    // make for free, before a single byte or a single file exists. It is not
    // the guard — a sender willing to lie about the body will declare whatever
    // gets it past this, and a response with no length at all is perfectly
    // legitimate — but an honestly broken control plane is caught here, at zero
    // cost and with a sentence that names the disagreement rather than the
    // symptom.
    final declared = response.contentLength;
    if (declared != null && want.size > 0 && declared != want.size) {
      await _hangUp(response);
      throw UpdateProtocolException(
        '$url offers $declared bytes for ${want.name}, '
        'and the manifest promised ${want.size}',
      );
    }

    await into.parent.create(recursive: true);
    final total = declared ?? (want.size > 0 ? want.size : null);
    // What the manifest promised, which is the only number worth enforcing:
    // [total] can come from a header, and a header is the sender's word about
    // the sender. Null means the manifest did not say.
    final cap = want.size > 0 ? want.size : null;
    final hasher = Sha256();
    var received = 0;

    final sink = into.openWrite();
    try {
      var unflushed = 0;
      await for (final chunk in response.stream.timeout(downloadTimeout)) {
        if (cap != null && received + chunk.length > cap) {
          // Refused before it is written or hashed: nothing past the promised
          // size reaches the disk at all.
          throw UpdateProtocolException(
            'the control plane sent ${received + chunk.length} bytes for '
            '${want.name} but promised $cap',
          );
        }
        hasher.add(chunk);
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
        unflushed += chunk.length;
        if (unflushed >= _flushEvery) {
          unflushed = 0;
          // See [_flushEvery]: the one await in this loop is the backpressure
          // and the breath the event loop needs, and it is deliberately after
          // the progress call so the frame it allows is one that has the new
          // number in it.
          await sink.flush();
        }
      }
      await sink.flush();
    } catch (_) {
      // A half-written download is worse than none: it is the thing an
      // interrupted install would find and trust.
      try {
        await sink.close();
      } catch (_) {
        // Already broken; the original failure is the one worth reporting.
      }
      await _discard(into);
      rethrow;
    }
    await sink.close();

    final got = hasher.close();
    if (got != want.sha256) {
      await _discard(into);
      throw UpdateHashMismatch(
        'downloaded ${want.name} hashes to $got, '
        'control plane promised ${want.sha256}',
        got: got,
        want: want.sha256,
      );
    }
    return VerifiedBinary(file: into, sha256: got, size: received);
  }

  Future<http.Response> _get(String url, Duration timeout) async {
    try {
      return await _http.get(Uri.parse(url)).timeout(timeout);
    } on TimeoutException {
      throw UpdateUnreachable(
        '$url did not answer within ${timeout.inSeconds}s',
      );
    } on SocketException catch (e) {
      throw UpdateUnreachable(_socketMessage(url, e));
    } on HttpException catch (e) {
      throw UpdateUnreachable('cannot reach $url: ${e.message}');
    } on http.ClientException catch (e) {
      throw UpdateUnreachable('cannot reach $url: ${e.message}');
    }
  }

  /// The control plane's own words first, then whatever it sent, then the bare
  /// status. A status code alone is never the best available explanation.
  UpdateApiException _apiException(
    String url,
    int status,
    String? reason,
    String body,
  ) {
    var message = body.trim();
    try {
      final decoded = jsonDecode(message);
      if (decoded is Map && decoded['error'] is String) {
        message = decoded['error'] as String;
      }
    } on FormatException {
      // Not JSON, so the body itself is the best sentence available.
    }
    if (message.isEmpty) {
      message = '$url answered $status ${reason ?? ''}'.trimRight();
    }
    return UpdateApiException(message, status);
  }

  /// Hang up without reading the body. A refusal that downloads the thing it
  /// refused is not a refusal, and a response nobody listens to holds its
  /// connection open until something cancels it.
  static Future<void> _hangUp(http.StreamedResponse response) async {
    try {
      await response.stream.listen(null).cancel();
    } on Object {
      // The socket is being thrown away either way.
    }
  }

  static String _socketMessage(String url, SocketException e) {
    final os = e.osError;
    return 'cannot reach $url: ${e.message}'
        '${os == null ? '' : ': ${os.message}'}';
  }

  static Future<void> _discard(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on Object {
      // Nothing useful to do about a file we cannot remove; the hash failure
      // is the thing worth reporting.
    }
  }
}

// ---------------------------------------------------------------------------
// transport rules
// ---------------------------------------------------------------------------

/// The base URL to fetch binaries from, or an exception saying why not.
///
/// [validatedCpUrl] plus the one rule that only matters here: plain http is
/// fine to a control plane on this machine and nowhere else.
String requireFetchableCpUrl(String url) {
  final String v;
  try {
    v = validatedCpUrl(url);
  } on InvalidCpUrl catch (e) {
    throw UpdateBadCpUrl(e.message);
  }
  final parsed = Uri.parse(v);
  if (parsed.scheme == 'http' && !isLoopbackHost(parsed.host)) {
    throw UpdateInsecure(
      'refusing to fetch meshd over plain http from ${parsed.host}; '
      'use https',
    );
  }
  return v;
}

/// Whether a host is this machine. Names only — resolving would be guessing,
/// and a control plane whose DNS points at 127.0.0.1 today may not tomorrow.
bool isLoopbackHost(String host) {
  final h = host.toLowerCase();
  return h == 'localhost' ||
      h.endsWith('.localhost') ||
      h == '127.0.0.1' ||
      h == '::1' ||
      h == '[::1]' ||
      h.startsWith('127.');
}
