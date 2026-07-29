/// The CLI's stored session — the same file, shared.
///
/// Mirrors `crates/mesh-core/src/config.rs`. The app deliberately reads and
/// writes the file `meshctl` uses rather than keeping its own: logging in on
/// one and having to log in again on the other would be a bug, not a feature.
/// Which means the same rules apply here, including the important one — a
/// session is only ever offered to the control plane that minted it.
///
/// UI preferences never go in this file. They live in `ui.json` beside it; see
/// `prefs.dart`.
library;

import 'dart:convert';
import 'dart:io';

import 'privileged.dart' show HostPlatform;

// ---------------------------------------------------------------------------
// the record
// ---------------------------------------------------------------------------

class CliConfig {
  const CliConfig({
    this.cpUrl = '',
    this.sessionToken = '',
    this.accountId = '',
    this.email,
    this.expiresAt,
  });

  /// The control plane this session belongs to. Never used on its own; see
  /// [sessionFor].
  final String cpUrl;

  final String sessionToken;
  final String accountId;
  final String? email;

  /// Unix seconds. Lets the app say "expired" instead of passing on a 401.
  final int? expiresAt;

  factory CliConfig.fromJson(Map<String, Object?> j) => CliConfig(
    cpUrl: j['cp_url'] is String ? j['cp_url'] as String : '',
    sessionToken: j['session_token'] is String
        ? j['session_token'] as String
        : '',
    accountId: j['account_id'] is String ? j['account_id'] as String : '',
    email: j['email'] is String ? j['email'] as String : null,
    expiresAt: j['expires_at'] is num ? (j['expires_at'] as num).toInt() : null,
  );

  /// Field order and names match what meshctl writes, so a file round-tripped
  /// through the app still looks like the file it read.
  Map<String, Object?> toJson() => {
    'cp_url': cpUrl,
    'session_token': sessionToken,
    'account_id': accountId,
    'email': email,
    'expires_at': expiresAt,
  };

  /// The session token, but only for the control plane it was minted against.
  ///
  /// Returning null on a mismatch is the whole point of storing the URL and
  /// the token as one record: pointing `MESH_CP_URL` somewhere else must not
  /// hand that host an account credential for a different one.
  String? sessionFor(String url) =>
      (sessionToken.isNotEmpty && sameCp(cpUrl, url)) ? sessionToken : null;

  bool expired(int nowUnix) => expiresAt != null && expiresAt! <= nowUnix;

  bool get hasToken => sessionToken.isNotEmpty;

  CliConfig copyWith({
    String? cpUrl,
    String? sessionToken,
    String? accountId,
    String? email,
    int? expiresAt,
  }) => CliConfig(
    cpUrl: cpUrl ?? this.cpUrl,
    sessionToken: sessionToken ?? this.sessionToken,
    accountId: accountId ?? this.accountId,
    email: email ?? this.email,
    expiresAt: expiresAt ?? this.expiresAt,
  );

  /// Never print the token.
  @override
  String toString() =>
      'CliConfig(cp_url: $cpUrl, account_id: $accountId, email: $email)';
}

/// Two control plane URLs naming the same control plane.
///
/// Only trailing slashes and case are normalised, exactly as in the Rust.
/// Anything cleverer would be guessing: a different port or host is a
/// different control plane even when it looks like a typo.
bool sameCp(String a, String b) {
  String norm(String v) {
    var s = v.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s.toLowerCase();
  }

  return norm(a) == norm(b);
}

// ---------------------------------------------------------------------------
// where it lives
// ---------------------------------------------------------------------------

/// `MESH_CONFIG` overrides. Otherwise the platform's usual place for per-user
/// configuration — the same place `default_config_path()` picks.
///
/// Null when there is no home directory to derive one from, which the UI
/// reports rather than silently failing to save.
String? defaultConfigPath({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final explicit = env['MESH_CONFIG'];
  if (explicit != null && explicit.isNotEmpty) return explicit;

  final dir = _configDir(env);
  return dir == null ? null : _join([dir, 'config.json']);
}

/// The directory `config.json` and `ui.json` share.
///
/// Three branches for three platforms, in the same order and with the same
/// answers as the `#[cfg]` blocks in `default_config_path()`. The platform is
/// asked through [HostPlatform] rather than `Platform.isX` so all three can be
/// checked from one machine — a per-OS path that only its own OS can evaluate
/// is a path nobody ever looks at until a user is standing on it.
String? _configDir(Map<String, String> env) {
  if (HostPlatform.current == HostPlatform.windows) {
    final appData = env['APPDATA'];
    if (appData == null || appData.isEmpty) return null;
    return _join([appData, 'mesh']);
  }
  if (HostPlatform.current.isMacOS) {
    final home = env['HOME'];
    if (home == null || home.isEmpty) return null;
    return _join([home, 'Library', 'Application Support', 'mesh']);
  }
  final xdg = env['XDG_CONFIG_HOME'];
  if (xdg != null && xdg.isNotEmpty) return _join([xdg, 'mesh']);
  final home = env['HOME'];
  if (home == null || home.isEmpty) return null;
  return _join([home, '.config', 'mesh']);
}

/// The directory the app's own `ui.json` sits in: beside the CLI's file when
/// there is one, so the two travel together.
///
/// When `MESH_CONFIG` points somewhere, that file's directory wins — a test or
/// a service account that redirected the session expects the prefs to follow.
String? configDirectory({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final explicit = env['MESH_CONFIG'];
  if (explicit != null && explicit.isNotEmpty) {
    final parent = File(explicit).parent.path;
    return parent.isEmpty ? '.' : parent;
  }
  return _configDir(env);
}

String _join(List<String> parts) => parts.join(Platform.pathSeparator);

// ---------------------------------------------------------------------------
// reading and writing
// ---------------------------------------------------------------------------

/// A malformed config file. Not swallowed: it holds the only copy of a
/// credential, so quietly defaulting would look exactly like being logged out
/// and send the user off to log in again for no reason.
class CliConfigException implements Exception {
  const CliConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

class CliConfigStore {
  CliConfigStore({Map<String, String>? environment})
    : environment = environment ?? Platform.environment;

  final Map<String, String> environment;

  /// Null when there is no home directory to put it in.
  String? get path => defaultConfigPath(environment: environment);

  /// The stored record, or null when there is not one.
  Future<CliConfig?> load() async {
    final p = path;
    if (p == null) return null;
    final file = File(p);
    if (!await file.exists()) return null;
    String text;
    try {
      text = await file.readAsString();
    } on FileSystemException catch (e) {
      throw CliConfigException(
        'reading $p: ${e.osError?.message ?? e.message}',
      );
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw const FormatException('the file is not a JSON object');
      }
      return CliConfig.fromJson(
        decoded is Map<String, Object?>
            ? decoded
            : decoded.map((k, v) => MapEntry('$k', v)),
      );
    } on FormatException catch (e) {
      throw CliConfigException('parsing $p: ${e.message}');
    }
  }

  /// Write the record, atomically and readable only by this user.
  ///
  /// Written beside the target and renamed, so an interrupted write cannot
  /// leave a truncated file where a working session used to be. Restricted
  /// under the temporary name, so it never exists at the target path with
  /// anyone else able to read it.
  Future<String> save(CliConfig config) async {
    final p = path;
    if (p == null) {
      throw const CliConfigException(
        'no home directory to store the session in; set MESH_CONFIG',
      );
    }
    final file = File(p);
    await file.parent.create(recursive: true);

    final tmp = File('$p.tmp');
    try {
      // The pretty form, because meshctl writes it that way and a user who
      // opens the file after the app touched it should not see it reflowed.
      await tmp.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(config.toJson())}\n',
        flush: true,
      );
      await _restrict(tmp.path);
      await tmp.rename(p);
    } on FileSystemException catch (e) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } on FileSystemException {
        // Nothing useful to do about a leftover temp file.
      }
      throw CliConfigException(
        'writing $p: ${e.osError?.message ?? e.message}',
      );
    }
    return p;
  }

  /// Remove the stored session. Returns the path when there was one to remove.
  Future<String?> clear() async {
    final p = path;
    if (p == null) return null;
    final file = File(p);
    if (!await file.exists()) return null;
    try {
      await file.delete();
    } on FileSystemException catch (e) {
      throw CliConfigException(
        'removing $p: ${e.osError?.message ?? e.message}',
      );
    }
    return p;
  }
}

/// 0600, the way `util::restrict` does it.
///
/// dart:io cannot set a mode, so this shells out. A failure is fatal rather
/// than ignored: the alternative is leaving a credential at whatever the umask
/// happened to produce, which is precisely what the Rust refuses to do.
Future<void> _restrict(String path) async {
  if (HostPlatform.current == HostPlatform.windows) return;
  final result = await Process.run('/bin/chmod', ['600', path]);
  if (result.exitCode != 0) {
    throw CliConfigException(
      'restricting $path: ${result.stderr.toString().trim()}',
    );
  }
}

// ---------------------------------------------------------------------------
// precedence
// ---------------------------------------------------------------------------

/// Where the effective control plane URL came from. Settings shows this.
enum CpUrlSource {
  /// `MESH_CP_URL` in the environment.
  environment,

  /// The stored login.
  stored,

  /// Baked in at build time with `--dart-define=MESH_CP_URL=...`.
  compiledIn,

  /// Nothing said otherwise, so the local development one.
  fallback;

  String get label => switch (this) {
    CpUrlSource.environment => 'MESH_CP_URL',
    CpUrlSource.stored => 'Stored login',
    CpUrlSource.compiledIn => 'Compiled in',
    CpUrlSource.fallback => 'Default',
  };
}

/// The analogue of `option_env!("MESH_CP_URL")`: a control plane baked into
/// this build, or empty when there is not one.
const String compiledCpUrl = String.fromEnvironment('MESH_CP_URL');

class ResolvedCpUrl {
  const ResolvedCpUrl(this.url, this.source);

  final String url;
  final CpUrlSource source;
}

/// The same order meshctl uses: the runtime environment, because an operator
/// overriding it means it now; then whichever control plane we logged in to,
/// because that is where the session actually lives; then whatever was baked
/// in; then a local one for development.
ResolvedCpUrl resolveCpUrl({
  CliConfig? config,
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  final candidates = <(String?, CpUrlSource)>[
    (env['MESH_CP_URL'], CpUrlSource.environment),
    (config?.cpUrl, CpUrlSource.stored),
    (compiledCpUrl, CpUrlSource.compiledIn),
  ];
  for (final (value, source) in candidates) {
    final v = value?.trim() ?? '';
    if (v.isNotEmpty) return ResolvedCpUrl(v, source);
  }
  return const ResolvedCpUrl(_fallbackCpUrl, CpUrlSource.fallback);
}

const String _fallbackCpUrl = 'http://127.0.0.1:8080';

/// Where the session in play came from.
enum SessionSource { environment, stored, none }

/// Why there is no usable session.
enum SessionProblem {
  /// Nothing stored and nothing in the environment.
  notLoggedIn,

  /// Stored, in date, but minted by a different control plane than the one
  /// commands are aimed at.
  otherControlPlane,

  /// Stored and for the right control plane, but past its expiry.
  expired,
}

/// The session to present, and a useful sentence when there is not one.
class ResolvedSession {
  const ResolvedSession({
    this.token,
    required this.source,
    this.problem,
    this.message,
    this.config,
    required this.cpUrl,
  });

  /// Null when [problem] says why.
  final String? token;

  final SessionSource source;
  final SessionProblem? problem;

  /// The sentence to show. Null when there is a token.
  final String? message;

  /// The record the token came from, when it came from one. `MESH_SESSION`
  /// carries no email or account id, which the UI has to cope with.
  final CliConfig? config;

  /// The control plane this was resolved against.
  final String cpUrl;

  bool get usable => token != null && token!.isNotEmpty;
}

/// Mirrors `session()` in meshctl, including the order.
///
/// `MESH_SESSION` still wins, because an operator setting it means it now.
/// Everything else comes from the stored login, and only when it belongs to
/// the control plane being addressed.
ResolvedSession resolveSession({
  required String cpUrl,
  CliConfig? config,
  Map<String, String>? environment,
  int? nowUnix,
}) {
  final env = environment ?? Platform.environment;
  final override = env['MESH_SESSION'];
  if (override != null && override.isNotEmpty) {
    return ResolvedSession(
      token: override,
      source: SessionSource.environment,
      config: config,
      cpUrl: cpUrl,
    );
  }

  const notLoggedIn = 'Not logged in';
  if (config == null) {
    return ResolvedSession(
      source: SessionSource.none,
      problem: SessionProblem.notLoggedIn,
      message: notLoggedIn,
      cpUrl: cpUrl,
    );
  }

  final token = config.sessionFor(cpUrl);
  if (token != null) {
    final now = nowUnix ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (config.expired(now)) {
      return ResolvedSession(
        source: SessionSource.stored,
        problem: SessionProblem.expired,
        message: 'The stored session expired; sign in again',
        config: config,
        cpUrl: cpUrl,
      );
    }
    return ResolvedSession(
      token: token,
      source: SessionSource.stored,
      config: config,
      cpUrl: cpUrl,
    );
  }

  if (config.hasToken) {
    return ResolvedSession(
      source: SessionSource.none,
      problem: SessionProblem.otherControlPlane,
      message:
          'Logged in to ${config.cpUrl}, but this app is aimed at $cpUrl. '
          'Sign in there, or clear MESH_CP_URL to use the one you logged in to',
      config: config,
      cpUrl: cpUrl,
    );
  }

  return ResolvedSession(
    source: SessionSource.none,
    problem: SessionProblem.notLoggedIn,
    message: notLoggedIn,
    config: config,
    cpUrl: cpUrl,
  );
}
