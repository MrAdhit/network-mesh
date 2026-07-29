/// The control plane's HTTP API.
///
/// Endpoints and their exact use are lifted from `crates/meshctl/src/main.rs`
/// so the app and the CLI cannot drift: same paths, same bodies, same
/// `x-mesh-session` header, and the same rule that the control plane's own
/// error sentence beats the status code.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpException, SocketException;

import 'package:http/http.dart' as http;

import 'cp_models.dart';

// ---------------------------------------------------------------------------
// errors
// ---------------------------------------------------------------------------

sealed class CpException implements Exception {
  const CpException(this.message);

  /// Rendered verbatim, in mono, inside the panel that caused it.
  final String message;

  @override
  String toString() => message;
}

/// The control plane answered and said no. [message] is its own text whenever
/// it sent an `ApiError`, which is the case for everything it means to reject.
class CpApiException extends CpException {
  const CpApiException(super.message, this.statusCode);

  final int statusCode;

  /// The session is gone or was never good. The UI treats this as "log in
  /// again" rather than as a transport failure.
  bool get unauthorized => statusCode == 401 || statusCode == 403;
}

/// Could not get there at all: DNS, connection refused, TLS, timeout.
class CpUnreachable extends CpException {
  const CpUnreachable(super.message, {this.timedOut = false});

  final bool timedOut;
}

/// A 2xx whose body was not the shape this app expects.
class CpProtocolException extends CpException {
  const CpProtocolException(super.message);
}

/// The call needs a session and there is not one. Raised before any request,
/// so a logged-out app never puts a bare header on the wire.
class CpNotAuthenticated extends CpException {
  const CpNotAuthenticated([
    super.message = 'not logged in: sign in on the network screen',
  ]);
}

// ---------------------------------------------------------------------------
// client
// ---------------------------------------------------------------------------

class CpClient {
  CpClient({
    required String baseUrl,
    this.sessionToken,
    http.Client? httpClient,
    this.timeout = defaultTimeout,
  }) : baseUrl = normaliseBaseUrl(baseUrl),
       _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  /// meshctl gives the control plane 60 seconds, because provisioning a
  /// Cloudflare Zero Trust org genuinely takes that long sometimes.
  static const Duration defaultTimeout = Duration(seconds: 60);

  final String baseUrl;
  final String? sessionToken;
  final Duration timeout;

  final http.Client _http;
  final bool _ownsClient;

  /// Trailing slashes off, so `$baseUrl/v1/...` never doubles up.
  static String normaliseBaseUrl(String url) {
    var v = url.trim();
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v.isEmpty ? defaultCpUrl : v;
  }

  /// The same client pointed at a different session. Cheap: the underlying
  /// http client is shared.
  CpClient withSession(String? token) => CpClient(
    baseUrl: baseUrl,
    sessionToken: token,
    httpClient: _http,
    timeout: timeout,
  );

  bool get hasSession => sessionToken != null && sessionToken!.isNotEmpty;

  void close() {
    if (_ownsClient) _http.close();
  }

  // -- account ------------------------------------------------------------

  /// POST /v1/accounts. Returns a session, so signing up logs you in.
  Future<SessionResponse> signup({
    required String email,
    required String password,
    String? subnet,
  }) async => SessionResponse.fromJson(
    await _send(
      'POST',
      '/v1/accounts',
      body: SignupRequest(
        email: email,
        password: password,
        subnet: subnet,
      ).toJson(),
      authenticated: false,
    ),
  );

  /// POST /v1/sessions.
  Future<SessionResponse> login({
    required String email,
    required String password,
  }) async => SessionResponse.fromJson(
    await _send(
      'POST',
      '/v1/sessions',
      body: LoginRequest(email: email, password: password).toJson(),
      authenticated: false,
    ),
  );

  // -- network ------------------------------------------------------------

  /// GET /v1/network.
  Future<NetworkView> network() async =>
      NetworkView.fromJson(await _send('GET', '/v1/network'));

  /// PATCH /v1/network. The control plane rejects this once a node exists.
  Future<NetworkView> setSubnet(String subnet) async => NetworkView.fromJson(
    await _send(
      'PATCH',
      '/v1/network',
      body: SetSubnetRequest(subnet).toJson(),
    ),
  );

  /// PUT /v1/network/backhauls/cloudflare. Slow on purpose: it provisions.
  Future<BackhaulStatus> setCloudflare({
    required String apiToken,
    required String accountId,
  }) async => BackhaulStatus.fromJson(
    await _send(
      'PUT',
      '/v1/network/backhauls/cloudflare',
      body: CloudflareCredsRequest(
        apiToken: apiToken,
        accountId: accountId,
      ).toJson(),
    ),
  );

  /// PUT /v1/network/backhauls/tailscale.
  Future<BackhaulStatus> setTailscale({required String apiToken}) async =>
      BackhaulStatus.fromJson(
        await _send(
          'PUT',
          '/v1/network/backhauls/tailscale',
          body: TailscaleCredsRequest(apiToken: apiToken).toJson(),
        ),
      );

  // -- enrollment and nodes ----------------------------------------------

  /// POST /v1/enrollment-keys. No body; the session is the whole request.
  Future<NewEnrollmentKey> mintEnrollmentKey() async =>
      NewEnrollmentKey.fromJson(await _send('POST', '/v1/enrollment-keys'));

  /// GET /v1/nodes.
  Future<List<NodeView>> nodes() async {
    final decoded = await _sendRaw('GET', '/v1/nodes');
    if (decoded is! List) {
      throw CpProtocolException(
        'GET /v1/nodes should return a list, got ${_kind(decoded)}',
      );
    }
    try {
      return [
        for (final e in decoded)
          NodeView.fromJson(
            e is Map<String, Object?>
                ? e
                : (e as Map).map((k, v) => MapEntry('$k', v)),
          ),
      ];
    } on FormatException catch (e) {
      throw CpProtocolException('GET /v1/nodes: ${e.message}');
    } on TypeError {
      throw const CpProtocolException(
        'GET /v1/nodes returned entries this app could not read',
      );
    }
  }

  /// DELETE /v1/nodes/{id}. The body is not interesting; the status is.
  Future<void> removeNode(String nodeId) async {
    await _sendRaw('DELETE', '/v1/nodes/${Uri.encodeComponent(nodeId)}');
  }

  // -- plumbing -----------------------------------------------------------

  Future<Map<String, Object?>> _send(
    String method,
    String path, {
    Map<String, Object?>? body,
    bool authenticated = true,
  }) async {
    final decoded = await _sendRaw(
      method,
      path,
      body: body,
      authenticated: authenticated,
    );
    if (decoded is Map<String, Object?>) return decoded;
    if (decoded is Map) return decoded.map((k, v) => MapEntry('$k', v));
    throw CpProtocolException(
      '$method $path should return an object, got ${_kind(decoded)}',
    );
  }

  Future<Object?> _sendRaw(
    String method,
    String path, {
    Map<String, Object?>? body,
    bool authenticated = true,
  }) async {
    if (authenticated && !hasSession) throw const CpNotAuthenticated();

    final request = http.Request(method, Uri.parse('$baseUrl$path'));
    if (authenticated) request.headers[sessionHeader] = sessionToken!;
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    final http.Response response;
    try {
      final streamed = await _http.send(request).timeout(timeout);
      response = await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw CpUnreachable(
        '$baseUrl did not answer within ${timeout.inSeconds}s',
        timedOut: true,
      );
    } on SocketException catch (e) {
      final os = e.osError;
      throw CpUnreachable(
        'cannot reach $baseUrl: ${e.message}${os == null ? '' : ': ${os.message}'}',
      );
    } on HttpException catch (e) {
      throw CpUnreachable('cannot reach $baseUrl: ${e.message}');
    } on http.ClientException catch (e) {
      throw CpUnreachable('cannot reach $baseUrl: ${e.message}');
    }

    final text = response.body;
    Object? decoded;
    var decodable = true;
    try {
      decoded = text.trim().isEmpty ? null : jsonDecode(text);
    } on FormatException {
      decodable = false;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      // The control plane's own words first, then whatever it did send, then
      // the bare status. A status code alone is never the best available
      // explanation.
      final api = decodable ? ApiError.tryParse(decoded) : null;
      final message =
          api?.error ??
          (text.trim().isNotEmpty
              ? text.trim()
              : 'the control plane answered ${response.statusCode} '
                        '${response.reasonPhrase ?? ''}'
                    .trimRight());
      throw CpApiException(message, response.statusCode);
    }

    if (!decodable) {
      throw CpProtocolException(
        '$method $path returned a body that is not JSON',
      );
    }
    return decoded;
  }
}

String _kind(Object? v) => v == null ? 'nothing' : v.runtimeType.toString();
