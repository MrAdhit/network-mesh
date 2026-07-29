/// Control plane wire types, mirrored from `crates/mesh-core/src/cp.rs`.
///
/// Only the human-facing half: the app holds an account session, never a node
/// token, so enrollment and roster types have no business here.
///
/// Hand-written, like the IPC types, and for the same reason.
library;

/// The header the control plane authenticates an account session with.
const String sessionHeader = 'x-mesh-session';

/// Where the control plane lives when nothing has said otherwise.
const String defaultCpUrl = 'http://127.0.0.1:8080';

// ---------------------------------------------------------------------------
// requests
// ---------------------------------------------------------------------------

/// `SignupRequest` — POST /v1/accounts.
class SignupRequest {
  const SignupRequest({
    required this.email,
    required this.password,
    this.subnet,
  });

  final String email;
  final String password;

  /// Optional at signup; the control plane defaults it to 10.201.0.0/16.
  final String? subnet;

  Map<String, Object?> toJson() => {
    'email': email,
    'password': password,
    if (subnet != null && subnet!.isNotEmpty) 'subnet': subnet,
  };
}

/// `LoginRequest` — POST /v1/sessions.
class LoginRequest {
  const LoginRequest({required this.email, required this.password});

  final String email;
  final String password;

  Map<String, Object?> toJson() => {'email': email, 'password': password};
}

/// `SetSubnetRequest` — PATCH /v1/network.
class SetSubnetRequest {
  const SetSubnetRequest(this.subnet);

  final String subnet;

  Map<String, Object?> toJson() => {'subnet': subnet};
}

/// `CloudflareCredsRequest` — PUT /v1/network/backhauls/cloudflare.
class CloudflareCredsRequest {
  const CloudflareCredsRequest({
    required this.apiToken,
    required this.accountId,
  });

  final String apiToken;
  final String accountId;

  Map<String, Object?> toJson() => {
    'api_token': apiToken,
    'account_id': accountId,
  };

  /// Never let a token reach a log line by accident.
  @override
  String toString() => 'CloudflareCredsRequest(account_id: $accountId)';
}

/// `TailscaleCredsRequest` — PUT /v1/network/backhauls/tailscale.
class TailscaleCredsRequest {
  const TailscaleCredsRequest({required this.apiToken});

  final String apiToken;

  Map<String, Object?> toJson() => {'api_token': apiToken};

  @override
  String toString() => 'TailscaleCredsRequest(<redacted>)';
}

// ---------------------------------------------------------------------------
// responses
// ---------------------------------------------------------------------------

/// `SessionResponse` — what signup and login both return.
class SessionResponse {
  const SessionResponse({
    required this.sessionToken,
    required this.accountId,
    this.expiresAt = 0,
  });

  final String sessionToken;
  final String accountId;

  /// Unix seconds, or 0 from a control plane that predates the field.
  final int expiresAt;

  factory SessionResponse.fromJson(Map<String, Object?> j) => SessionResponse(
    sessionToken: _string(j, 'session_token'),
    accountId: _string(j, 'account_id'),
    expiresAt: _intOr(j, 'expires_at', 0),
  );

  Map<String, Object?> toJson() => {
    'session_token': sessionToken,
    'account_id': accountId,
    'expires_at': expiresAt,
  };

  @override
  String toString() => 'SessionResponse(account: $accountId, <token redacted>)';
}

/// `NetworkView` — GET /v1/network, and what PATCH /v1/network returns.
class NetworkView {
  const NetworkView({
    required this.accountId,
    required this.email,
    required this.subnet,
    required this.nodeCount,
    required this.addressesUsed,
    required this.addressesAvailable,
    required this.cloudflare,
    required this.tailscale,
  });

  final String accountId;
  final String email;
  final String subnet;
  final int nodeCount;
  final int addressesUsed;
  final int addressesAvailable;
  final BackhaulStatus cloudflare;
  final BackhaulStatus tailscale;

  factory NetworkView.fromJson(Map<String, Object?> j) => NetworkView(
    accountId: _string(j, 'account_id'),
    email: _string(j, 'email'),
    subnet: _string(j, 'subnet'),
    nodeCount: _intOr(j, 'node_count', 0),
    addressesUsed: _intOr(j, 'addresses_used', 0),
    addressesAvailable: _intOr(j, 'addresses_available', 0),
    cloudflare: BackhaulStatus.fromJson(_objectOr(j['cloudflare'])),
    tailscale: BackhaulStatus.fromJson(_objectOr(j['tailscale'])),
  );

  Map<String, Object?> toJson() => {
    'account_id': accountId,
    'email': email,
    'subnet': subnet,
    'node_count': nodeCount,
    'addresses_used': addressesUsed,
    'addresses_available': addressesAvailable,
    'cloudflare': cloudflare.toJson(),
    'tailscale': tailscale.toJson(),
  };

  /// The control plane rejects a subnet change once anything is enrolled, so
  /// the form is only worth showing while this holds.
  bool get subnetChangeable => nodeCount == 0;
}

/// `BackhaulStatus` — also the body of both PUT .../backhauls/... calls.
class BackhaulStatus {
  const BackhaulStatus({this.configured = false, this.detail = ''});

  final bool configured;

  /// Human-readable, never a secret.
  final String detail;

  factory BackhaulStatus.fromJson(Map<String, Object?> j) => BackhaulStatus(
    configured: _boolOr(j, 'configured', false),
    detail: _stringOr(j, 'detail', ''),
  );

  Map<String, Object?> toJson() => {'configured': configured, 'detail': detail};

  /// What meshctl prints for this plane.
  String get label => configured ? detail : 'not configured';
}

/// `NewEnrollmentKey` — POST /v1/enrollment-keys.
class NewEnrollmentKey {
  const NewEnrollmentKey({required this.key, required this.expiresAt});

  final String key;

  /// An RFC 3339 string, straight from the control plane. Shown as given.
  final String expiresAt;

  factory NewEnrollmentKey.fromJson(Map<String, Object?> j) => NewEnrollmentKey(
    key: _string(j, 'key'),
    expiresAt: _stringOr(j, 'expires_at', ''),
  );

  Map<String, Object?> toJson() => {'key': key, 'expires_at': expiresAt};

  @override
  String toString() => 'NewEnrollmentKey(expires $expiresAt, <key redacted>)';
}

/// `NodeView` — GET /v1/nodes.
class NodeView {
  const NodeView({
    required this.nodeId,
    required this.name,
    required this.virtualIp,
    this.publicKey = '',
    this.createdAt = '',
    this.lastSeen,
    this.online = false,
  });

  final String nodeId;
  final String name;
  final String virtualIp;
  final String publicKey;
  final String createdAt;

  /// Null means never, which meshctl prints as exactly that.
  final String? lastSeen;

  final bool online;

  factory NodeView.fromJson(Map<String, Object?> j) => NodeView(
    nodeId: _string(j, 'node_id'),
    name: _stringOr(j, 'name', ''),
    virtualIp: _stringOr(j, 'virtual_ip', ''),
    publicKey: _stringOr(j, 'public_key', ''),
    createdAt: _stringOr(j, 'created_at', ''),
    lastSeen: j['last_seen'] is String ? j['last_seen'] as String : null,
    online: _boolOr(j, 'online', false),
  );

  Map<String, Object?> toJson() => {
    'node_id': nodeId,
    'name': name,
    'virtual_ip': virtualIp,
    'public_key': publicKey,
    'created_at': createdAt,
    'last_seen': lastSeen,
    'online': online,
  };
}

/// `ApiError` — the body of every non-2xx the control plane means to send.
///
/// Preferred over the status code everywhere: the control plane's sentence is
/// always more useful than "400".
class ApiError {
  const ApiError(this.error);

  final String error;

  /// Null when the body was not an ApiError, in which case the caller falls
  /// back to the raw body and then to the status line.
  static ApiError? tryParse(Object? decoded) {
    if (decoded is Map && decoded['error'] is String) {
      return ApiError(decoded['error'] as String);
    }
    return null;
  }

  Map<String, Object?> toJson() => {'error': error};
}

// ---------------------------------------------------------------------------
// decoding helpers
// ---------------------------------------------------------------------------

Map<String, Object?> _objectOr(Object? v) {
  if (v is Map<String, Object?>) return v;
  if (v is Map) return v.map((k, value) => MapEntry('$k', value));
  return const {};
}

String _string(Map<String, Object?> j, String k) {
  final v = j[k];
  if (v is String) return v;
  throw FormatException(
    '"$k" should be a string, got ${v == null ? 'null' : v.runtimeType}',
  );
}

String _stringOr(Map<String, Object?> j, String k, String fallback) {
  final v = j[k];
  return v is String ? v : fallback;
}

int _intOr(Map<String, Object?> j, String k, int fallback) {
  final v = j[k];
  return v is num ? v.toInt() : fallback;
}

bool _boolOr(Map<String, Object?> j, String k, bool fallback) {
  final v = j[k];
  return v is bool ? v : fallback;
}
