/// Who this machine acts as, against which control plane.
///
/// Owns the shared CLI config file and the environment overrides on top of it.
/// Nothing else reads `MESH_CP_URL`, `MESH_SESSION` or `MESH_CONFIG`: they are
/// resolved once, here, so the Settings screen can say where the effective
/// value came from and the Network screen can just ask for a client.
library;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../data/cli_config.dart';
import '../data/cp_client.dart';
import '../data/cp_models.dart';

class SessionStore extends ChangeNotifier {
  SessionStore({
    Map<String, String>? environment,
    CliConfigStore? configStore,
    http.Client? httpClient,
  }) : _configs = configStore ?? CliConfigStore(environment: environment),
       _environment = environment,
       _http = httpClient ?? http.Client(),
       _ownsHttp = httpClient == null {
    _resolve();
  }

  final CliConfigStore _configs;
  final Map<String, String>? _environment;
  final http.Client _http;
  final bool _ownsHttp;

  // -- state --------------------------------------------------------------

  CliConfig? _config;
  ResolvedCpUrl _cpUrl = const ResolvedCpUrl(
    defaultCpUrl,
    CpUrlSource.fallback,
  );
  ResolvedSession _session = const ResolvedSession(
    source: SessionSource.none,
    problem: SessionProblem.notLoggedIn,
    message: 'Not logged in',
    cpUrl: defaultCpUrl,
  );

  /// Set when the config file exists but could not be read or parsed. Shown
  /// verbatim: a broken credential file must not look like being logged out.
  String? configError;

  /// The last failure from [login], [signup] or [logout]. Cleared when the
  /// next attempt starts.
  CpException? authError;

  bool _busy = false;
  bool _loaded = false;

  // -- what the screens read ---------------------------------------------

  /// The stored record, or null when there is not one.
  CliConfig? get config => _config;

  /// The effective control plane and where that value came from.
  ResolvedCpUrl get cpUrl => _cpUrl;

  /// The session in play, or the reason there is not one.
  ResolvedSession get session => _session;

  bool get hasSession => _session.usable;
  bool get busy => _busy;

  /// False until the first [load] finishes, so the UI can hold off on saying
  /// "not logged in" before it has looked.
  bool get loaded => _loaded;

  /// From the stored record. `MESH_SESSION` carries neither, so both can be
  /// null while a session is perfectly usable.
  String? get email => _config?.email;
  String? get accountId =>
      (_config?.accountId.isNotEmpty ?? false) ? _config!.accountId : null;
  int? get expiresAt => _config?.expiresAt;

  bool get sessionExpired => _session.problem == SessionProblem.expired;

  /// Where the shared session file is, for Settings to show.
  String? get configPath => _configs.path;

  /// True when `MESH_SESSION` is set, which changes what logging out means.
  bool get sessionFromEnvironment =>
      _session.source == SessionSource.environment;

  // -- clients ------------------------------------------------------------

  /// A client carrying the current session, or null when there is not one.
  ///
  /// Rebuilt on every call rather than cached: it is a value object over a
  /// shared http client, and caching one would only be a way to keep using a
  /// token after logout.
  CpClient? get client => hasSession
      ? CpClient(
          baseUrl: _cpUrl.url,
          sessionToken: _session.token,
          httpClient: _http,
        )
      : null;

  /// A client with no session, for signup and login.
  CpClient get anonymousClient =>
      CpClient(baseUrl: _cpUrl.url, httpClient: _http);

  // -- lifecycle ----------------------------------------------------------

  /// Read the config file and resolve everything on top of it.
  Future<void> load() async {
    try {
      _config = await _configs.load();
      configError = null;
    } on CliConfigException catch (e) {
      _config = null;
      configError = e.message;
    }
    _loaded = true;
    _resolve();
    notifyListeners();
  }

  /// Re-read from disk. Cheap, and the honest answer when `meshctl login` may
  /// have run in a terminal while the app was open.
  Future<void> refresh() => load();

  void _resolve() {
    _cpUrl = resolveCpUrl(config: _config, environment: _environment);
    _session = resolveSession(
      cpUrl: _cpUrl.url,
      config: _config,
      environment: _environment,
    );
  }

  // -- actions ------------------------------------------------------------

  /// POST /v1/sessions, then store the result where meshctl will find it.
  Future<bool> login({required String email, required String password}) =>
      _authenticate(
        email: email,
        run: (c) => c.login(email: email, password: password),
      );

  /// POST /v1/accounts. Signing up returns a session, so it logs you in too.
  Future<bool> signup({
    required String email,
    required String password,
    String? subnet,
  }) => _authenticate(
    email: email,
    run: (c) => c.signup(email: email, password: password, subnet: subnet),
  );

  Future<bool> _authenticate({
    required String email,
    required Future<SessionResponse> Function(CpClient) run,
  }) async {
    if (_busy) return false;
    _busy = true;
    authError = null;
    notifyListeners();

    final base = _cpUrl.url;
    try {
      final result = await run(anonymousClient);
      final stored = CliConfig(
        cpUrl: base,
        sessionToken: result.sessionToken,
        accountId: result.accountId,
        email: email,
        expiresAt: result.expiresAt > 0 ? result.expiresAt : null,
      );
      try {
        await _configs.save(stored);
        configError = null;
      } on CliConfigException catch (e) {
        // The session is good even if we could not write it down; say so
        // rather than pretending the login failed.
        configError = '${e.message} — signed in for this session only';
      }
      _config = stored;
      _resolve();
      return true;
    } on CpException catch (e) {
      authError = e;
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Forget the stored session. Does not tell the control plane: neither does
  /// meshctl, and the token expires on its own.
  Future<bool> logout() async {
    if (_busy) return false;
    _busy = true;
    authError = null;
    notifyListeners();
    try {
      await _configs.clear();
      _config = null;
      configError = null;
      _resolve();
      return true;
    } on CliConfigException catch (e) {
      configError = e.message;
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_ownsHttp) _http.close();
    super.dispose();
  }
}
