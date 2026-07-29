/// The daemon's IPC protocol, mirrored from `crates/mesh-core/src/ipc.rs`.
///
/// Newline-delimited JSON over a unix socket: one request line in, one response
/// line out, one connection per exchange. Requests are internally tagged on
/// `cmd` in kebab-case; responses are serde's *externally* tagged form, which
/// means a one-key object whose key names the variant — with the unit variant
/// `Ok` serialising to the bare string `"ok"`.
///
/// Hand-written on purpose: no codegen, no build step, and the shapes are
/// small enough that reading this file next to `ipc.rs` shows they agree.
///
/// Deliberately free of any Flutter import so `tool/fake_meshd.dart` and
/// `tool/smoke.dart` can use it under a plain `dart run`.
library;

import 'dart:convert';

/// The paths, in the triad's fixed order. The daemon names them exactly this
/// way; anything else it reports is something new and is shown after these.
const List<String> meshPathNames = ['direct', 'cloudflare', 'tailscale'];

// ---------------------------------------------------------------------------
// requests
// ---------------------------------------------------------------------------

/// `Request` — `#[serde(tag = "cmd", rename_all = "kebab-case")]`.
sealed class MeshRequest {
  const MeshRequest();

  /// The value of the `cmd` tag.
  String get cmd;

  Map<String, Object?> toJson();

  /// One protocol line, newline included.
  String encodeLine() => '${jsonEncode(toJson())}\n';

  static MeshRequest fromJson(Map<String, Object?> json) {
    final cmd = _string(json, 'cmd');
    return switch (cmd) {
      'status' => const StatusRequest(),
      'peers' => const PeersRequest(),
      'ping' => PingRequest(
        peer: _string(json, 'peer'),
        count: _int(json, 'count'),
      ),
      'send' => SendRequest(
        peer: _string(json, 'peer'),
        data: _string(json, 'data'),
      ),
      'join' => JoinRequest(key: _string(json, 'key')),
      'leave' => const LeaveRequest(),
      _ => throw FormatException('unknown command "$cmd"'),
    };
  }

  static MeshRequest decodeLine(String line) {
    final wire = jsonDecode(line.trim());
    if (wire is! Map<String, Object?>) {
      throw FormatException(
        'a request must be a JSON object, got ${_kind(wire)}',
      );
    }
    return fromJson(wire);
  }
}

/// Node identity and backhaul health.
class StatusRequest extends MeshRequest {
  const StatusRequest();
  @override
  String get cmd => 'status';
  @override
  Map<String, Object?> toJson() => {'cmd': cmd};
}

/// Peer table with per-path statistics.
class PeersRequest extends MeshRequest {
  const PeersRequest();
  @override
  String get cmd => 'peers';
  @override
  Map<String, Object?> toJson() => {'cmd': cmd};
}

/// Probe a peer on every path and report each RTT separately.
class PingRequest extends MeshRequest {
  const PingRequest({required this.peer, this.count = 4});

  final String peer;
  final int count;

  @override
  String get cmd => 'ping';
  @override
  Map<String, Object?> toJson() => {'cmd': cmd, 'peer': peer, 'count': count};
}

/// Send application data over the winning path.
///
/// Part of the protocol, never surfaced in the UI: the app is an instrument,
/// not a chat client. It exists here so the wire types are complete and so
/// `fake_meshd` can answer it.
class SendRequest extends MeshRequest {
  const SendRequest({required this.peer, required this.data});

  final String peer;
  final String data;

  @override
  String get cmd => 'send';
  @override
  Map<String, Object?> toJson() => {'cmd': cmd, 'peer': peer, 'data': data};
}

/// Join a network with an enrollment key, or rejoin after being removed.
class JoinRequest extends MeshRequest {
  const JoinRequest({required this.key});

  final String key;

  @override
  String get cmd => 'join';
  @override
  Map<String, Object?> toJson() => {'cmd': cmd, 'key': key};
}

/// Deregister from the control plane and stop.
class LeaveRequest extends MeshRequest {
  const LeaveRequest();
  @override
  String get cmd => 'leave';
  @override
  Map<String, Object?> toJson() => {'cmd': cmd};
}

// ---------------------------------------------------------------------------
// responses
// ---------------------------------------------------------------------------

/// `Response` — `#[serde(rename_all = "kebab-case")]`, externally tagged.
sealed class MeshResponse {
  const MeshResponse();

  /// The variant tag, which is also this response's only JSON key.
  String get tag;

  /// The wire value: a one-key object for every variant except `ok`, which
  /// serde writes as the bare string `"ok"`.
  Object toWire();

  String encodeLine() => '${jsonEncode(toWire())}\n';

  static MeshResponse decodeLine(String line) =>
      fromWire(jsonDecode(line.trim()));

  static MeshResponse fromWire(Object? wire) {
    // The unit variant. Accepted in both the form serde emits and the
    // degenerate object form, because tolerating the latter costs one branch.
    if (wire == 'ok') return const OkResponse();
    if (wire is! Map) {
      throw FormatException(
        'a response must be an object or "ok", got ${_kind(wire)}',
      );
    }
    if (wire.length != 1) {
      throw FormatException(
        'a response carries exactly one tag, got ${wire.length}'
        '${wire.isEmpty ? '' : ': ${wire.keys.join(', ')}'}',
      );
    }
    final tag = wire.keys.first;
    final body = wire.values.first;
    return switch (tag) {
      'status' => StatusResponse(
        StatusReport.fromJson(_object(body, 'status')),
      ),
      'peers' => PeersResponse([
        for (final e in _array(body, 'peers'))
          PeerReport.fromJson(_object(e, 'peers[]')),
      ]),
      'ping' => PingResponse([
        for (final e in _array(body, 'ping'))
          PingSample.fromJson(_object(e, 'ping[]')),
      ]),
      'sent' => () {
        final o = _object(body, 'sent');
        return SentResponse(path: _string(o, 'path'), bytes: _int(o, 'bytes'));
      }(),
      'joined' => () {
        final o = _object(body, 'joined');
        return JoinedResponse(
          nodeId: _string(o, 'node_id'),
          virtualIp: _string(o, 'virtual_ip'),
          subnet: _string(o, 'subnet'),
        );
      }(),
      'left' => () {
        final o = _object(body, 'left');
        return LeftResponse(
          nodeId: _string(o, 'node_id'),
          detail: _string(o, 'detail'),
        );
      }(),
      'ok' => const OkResponse(),
      'error' => ErrorResponse(_asString(body, 'error')),
      _ => throw FormatException('unknown response tag "$tag"'),
    };
  }
}

class StatusResponse extends MeshResponse {
  const StatusResponse(this.report);

  final StatusReport report;

  @override
  String get tag => 'status';
  @override
  Object toWire() => {tag: report.toJson()};
}

class PeersResponse extends MeshResponse {
  const PeersResponse(this.peers);

  final List<PeerReport> peers;

  @override
  String get tag => 'peers';
  @override
  Object toWire() => {
    tag: [for (final p in peers) p.toJson()],
  };
}

class PingResponse extends MeshResponse {
  const PingResponse(this.samples);

  final List<PingSample> samples;

  @override
  String get tag => 'ping';
  @override
  Object toWire() => {
    tag: [for (final s in samples) s.toJson()],
  };
}

class SentResponse extends MeshResponse {
  const SentResponse({required this.path, required this.bytes});

  final String path;
  final int bytes;

  @override
  String get tag => 'sent';
  @override
  Object toWire() => {
    tag: {'path': path, 'bytes': bytes},
  };
}

class JoinedResponse extends MeshResponse {
  const JoinedResponse({
    required this.nodeId,
    required this.virtualIp,
    required this.subnet,
  });

  final String nodeId;
  final String virtualIp;
  final String subnet;

  @override
  String get tag => 'joined';
  @override
  Object toWire() => {
    tag: {'node_id': nodeId, 'virtual_ip': virtualIp, 'subnet': subnet},
  };
}

class LeftResponse extends MeshResponse {
  const LeftResponse({required this.nodeId, required this.detail});

  final String nodeId;

  /// Anything the operator needs to know, such as the control plane being
  /// unreachable and the record therefore still existing. Empty when it all
  /// worked, which is why the UI only quotes it when it is not.
  final String detail;

  @override
  String get tag => 'left';
  @override
  Object toWire() => {
    tag: {'node_id': nodeId, 'detail': detail},
  };
}

class OkResponse extends MeshResponse {
  const OkResponse();
  @override
  String get tag => 'ok';
  @override
  Object toWire() => 'ok';
}

class ErrorResponse extends MeshResponse {
  const ErrorResponse(this.message);

  /// The daemon's own words. Rendered verbatim, never rewritten.
  final String message;

  @override
  String get tag => 'error';
  @override
  Object toWire() => {tag: message};
}

// ---------------------------------------------------------------------------
// reports
// ---------------------------------------------------------------------------

/// `StatusReport`.
class StatusReport {
  const StatusReport({
    required this.nodeName,
    this.enrolled = true,
    required this.virtualIp,
    required this.subnet,
    this.cloudflare,
    this.tailscale,
    required this.peerCount,
    required this.uptimeSecs,
  });

  final String nodeName;

  /// False while the daemon is up but has not joined a network. Everything
  /// below is meaningless in that state.
  ///
  /// Defaults to true when absent, matching `#[serde(default = "yes")]`: an
  /// older daemon only ever answered when it was enrolled, and reporting it as
  /// unenrolled would be a lie about a working node.
  final bool enrolled;

  final String virtualIp;
  final String subnet;

  /// Null means the plane is not configured at all, which is a different thing
  /// from configured and down.
  final BackhaulReport? cloudflare;
  final BackhaulReport? tailscale;

  final int peerCount;
  final int uptimeSecs;

  factory StatusReport.fromJson(Map<String, Object?> j) => StatusReport(
    nodeName: _string(j, 'node_name'),
    enrolled: _boolOr(j, 'enrolled', true),
    virtualIp: _string(j, 'virtual_ip'),
    subnet: _string(j, 'subnet'),
    cloudflare: _maybe(j['cloudflare'], 'cloudflare', BackhaulReport.fromJson),
    tailscale: _maybe(j['tailscale'], 'tailscale', BackhaulReport.fromJson),
    peerCount: _int(j, 'peer_count'),
    uptimeSecs: _int(j, 'uptime_secs'),
  );

  Map<String, Object?> toJson() => {
    'node_name': nodeName,
    'enrolled': enrolled,
    'virtual_ip': virtualIp,
    'subnet': subnet,
    'cloudflare': cloudflare?.toJson(),
    'tailscale': tailscale?.toJson(),
    'peer_count': peerCount,
    'uptime_secs': uptimeSecs,
  };

  /// The two backhaul planes in the triad's fixed order, minus the direct bar
  /// the daemon does not report on for itself.
  Map<String, BackhaulReport?> get backhauls => {
    'cloudflare': cloudflare,
    'tailscale': tailscale,
  };
}

/// `BackhaulReport`.
class BackhaulReport {
  const BackhaulReport({
    required this.up,
    required this.address,
    required this.detail,
  });

  final bool up;
  final String address;
  final String detail;

  factory BackhaulReport.fromJson(Map<String, Object?> j) => BackhaulReport(
    up: _bool(j, 'up'),
    address: _string(j, 'address'),
    detail: _string(j, 'detail'),
  );

  Map<String, Object?> toJson() => {
    'up': up,
    'address': address,
    'detail': detail,
  };
}

/// `PeerReport`.
class PeerReport {
  const PeerReport({
    required this.name,
    this.virtualIp,
    this.cfIp,
    this.tsHostname,
    this.bestPath,
    this.paths = const [],
  });

  final String name;
  final String? virtualIp;
  final String? cfIp;
  final String? tsHostname;

  /// The path currently carrying traffic, or null when none is up.
  final String? bestPath;

  final List<PathReport> paths;

  factory PeerReport.fromJson(Map<String, Object?> j) => PeerReport(
    name: _string(j, 'name'),
    virtualIp: _stringOrNull(j, 'virtual_ip'),
    cfIp: _stringOrNull(j, 'cf_ip'),
    tsHostname: _stringOrNull(j, 'ts_hostname'),
    bestPath: _stringOrNull(j, 'best_path'),
    paths: [
      for (final e in _array(j['paths'], 'paths'))
        PathReport.fromJson(_object(e, 'paths[]')),
    ],
  );

  Map<String, Object?> toJson() => {
    'name': name,
    'virtual_ip': virtualIp,
    'cf_ip': cfIp,
    'ts_hostname': tsHostname,
    'best_path': bestPath,
    'paths': [for (final p in paths) p.toJson()],
  };

  /// The report for one named path, or null when the daemon has none.
  PathReport? path(String name) {
    for (final p in paths) {
      if (p.path == name) return p;
    }
    return null;
  }

  /// The winning path's report, when there is one.
  PathReport? get best => bestPath == null ? null : path(bestPath!);
}

/// `PathReport`.
class PathReport {
  const PathReport({
    required this.path,
    required this.up,
    this.lastRttMs,
    this.ewmaMs,
    this.sent = 0,
    this.received = 0,
    this.lossPct = 0,
  });

  /// `direct`, `cloudflare` or `tailscale`.
  final String path;

  final bool up;
  final double? lastRttMs;
  final double? ewmaMs;
  final int sent;
  final int received;

  /// Already a percentage, 0..100 — not a fraction.
  final double lossPct;

  factory PathReport.fromJson(Map<String, Object?> j) => PathReport(
    path: _string(j, 'path'),
    up: _bool(j, 'up'),
    lastRttMs: _doubleOrNull(j, 'last_rtt_ms'),
    ewmaMs: _doubleOrNull(j, 'ewma_ms'),
    sent: _intOr(j, 'sent', 0),
    received: _intOr(j, 'received', 0),
    lossPct: _doubleOr(j, 'loss_pct', 0),
  );

  Map<String, Object?> toJson() => {
    'path': path,
    'up': up,
    'last_rtt_ms': lastRttMs,
    'ewma_ms': ewmaMs,
    'sent': sent,
    'received': received,
    'loss_pct': lossPct,
  };
}

/// `PingSample`.
class PingSample {
  const PingSample({required this.path, required this.seq, this.rttMs});

  final String path;
  final int seq;

  /// Null is a timeout, which is a result and not a missing value.
  final double? rttMs;

  factory PingSample.fromJson(Map<String, Object?> j) => PingSample(
    path: _string(j, 'path'),
    seq: _int(j, 'seq'),
    rttMs: _doubleOrNull(j, 'rtt_ms'),
  );

  Map<String, Object?> toJson() => {'path': path, 'seq': seq, 'rtt_ms': rttMs};
}

// ---------------------------------------------------------------------------
// ping summary
// ---------------------------------------------------------------------------

/// What meshctl prints under a ping: per-path min/avg/max and the winner.
///
/// Computed here rather than in a screen so the numbers on screen are the same
/// numbers the CLI would have printed, arrived at the same way.
class PingSummary {
  const PingSummary({required this.paths, this.winner});

  final List<PingPathSummary> paths;

  /// Lowest average across the paths that replied at all. Null when nothing
  /// replied, which the UI reports rather than hiding.
  final PingPathSummary? winner;

  bool get isEmpty => paths.isEmpty;

  static PingSummary of(List<PingSample> samples) {
    // Path order follows meshctl: sorted and deduplicated, so two runs of the
    // same ping list the paths the same way.
    final names = samples.map((s) => s.path).toSet().toList()..sort();
    final out = <PingPathSummary>[];
    PingPathSummary? winner;
    for (final name in names) {
      final all = samples.where((s) => s.path == name).toList();
      final rtts = [
        for (final s in all)
          if (s.rttMs != null) s.rttMs!,
      ];
      if (rtts.isEmpty) {
        out.add(PingPathSummary(path: name, sent: all.length, replied: 0));
        continue;
      }
      var min = rtts.first, max = rtts.first, sum = 0.0;
      for (final v in rtts) {
        if (v < min) min = v;
        if (v > max) max = v;
        sum += v;
      }
      final s = PingPathSummary(
        path: name,
        sent: all.length,
        replied: rtts.length,
        minMs: min,
        avgMs: sum / rtts.length,
        maxMs: max,
      );
      out.add(s);
      if (winner == null || s.avgMs! < winner.avgMs!) winner = s;
    }
    return PingSummary(paths: out, winner: winner);
  }
}

/// One path's line in a [PingSummary].
class PingPathSummary {
  const PingPathSummary({
    required this.path,
    required this.sent,
    required this.replied,
    this.minMs,
    this.avgMs,
    this.maxMs,
  });

  final String path;
  final int sent;
  final int replied;

  /// All null together when nothing came back.
  final double? minMs;
  final double? avgMs;
  final double? maxMs;

  bool get silent => replied == 0;
}

// ---------------------------------------------------------------------------
// decoding helpers
//
// Every one of these throws FormatException with the offending field named, so
// a protocol mismatch reads as a sentence rather than "type 'Null' is not a
// subtype of type 'String'".
// ---------------------------------------------------------------------------

String _kind(Object? v) => v == null ? 'null' : v.runtimeType.toString();

Never _bad(String field, String want, Object? got) =>
    throw FormatException('"$field" should be $want, got ${_kind(got)}');

Map<String, Object?> _object(Object? v, String field) {
  if (v is Map<String, Object?>) return v;
  if (v is Map) return v.map((k, value) => MapEntry('$k', value));
  _bad(field, 'an object', v);
}

List<Object?> _array(Object? v, String field) {
  if (v is List) return v;
  _bad(field, 'an array', v);
}

String _asString(Object? v, String field) {
  if (v is String) return v;
  _bad(field, 'a string', v);
}

String _string(Map<String, Object?> j, String k) => _asString(j[k], k);

String? _stringOrNull(Map<String, Object?> j, String k) {
  final v = j[k];
  if (v == null) return null;
  return _asString(v, k);
}

bool _bool(Map<String, Object?> j, String k) {
  final v = j[k];
  if (v is bool) return v;
  _bad(k, 'a boolean', v);
}

bool _boolOr(Map<String, Object?> j, String k, bool fallback) {
  final v = j[k];
  if (v == null) return fallback;
  if (v is bool) return v;
  _bad(k, 'a boolean', v);
}

int _int(Map<String, Object?> j, String k) {
  final v = j[k];
  if (v is int) return v;
  if (v is num) return v.toInt();
  _bad(k, 'a number', v);
}

int _intOr(Map<String, Object?> j, String k, int fallback) {
  final v = j[k];
  if (v == null) return fallback;
  return _int(j, k);
}

double _doubleOr(Map<String, Object?> j, String k, double fallback) {
  final v = j[k];
  if (v == null) return fallback;
  if (v is num) return v.toDouble();
  _bad(k, 'a number', v);
}

double? _doubleOrNull(Map<String, Object?> j, String k) {
  final v = j[k];
  if (v == null) return null;
  if (v is num) return v.toDouble();
  _bad(k, 'a number', v);
}

T? _maybe<T>(Object? v, String field, T Function(Map<String, Object?>) parse) =>
    v == null ? null : parse(_object(v, field));
