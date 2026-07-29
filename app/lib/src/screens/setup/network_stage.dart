/// Stage 2 — the network.
///
/// One decision on the whole screen: somebody sent you a key, or the network is
/// yours to run. Both cards are visible at once with the key first, because
/// pasting a key is what most people arriving here are holding; choosing one
/// opens it and the other recedes.
///
/// The operator's path is deliberately one button. The app has a session, the
/// control plane mints keys, and this Mac is standing right here — asking
/// somebody to mint a key, copy it, and paste it into the app that just minted
/// it would be theatre. "Join this Mac" mints and joins as one action.
///
/// Which control plane any of this talks to is not on this screen. Settings
/// owns that, along with everything else with a URL in it.
library;

import 'package:flutter/widgets.dart';

import '../../data/privileged.dart' show thisMachine;
import '../../kit/button.dart';
import '../../kit/stage.dart';
import '../../kit/text_field.dart';
import '../../state/app_state.dart';
import '../../state/daemon_store.dart';
import '../../state/session_store.dart';
import '../../theme/theme.dart';
import 'setup_parts.dart';

/// Which card is open. [none] is the decision itself.
enum _Path { none, key, operator }

/// Which form the operator's card is showing.
enum _AuthMode {
  login,
  signup;

  String get action => this == _AuthMode.login ? 'Sign in' : 'Create account';

  /// The button that swaps to the other one.
  String get swap =>
      this == _AuthMode.login ? 'Create an account' : 'Sign in instead';

  String get message => this == _AuthMode.login
      ? 'Sign in to the account that owns the network.'
      : 'A new account, and a network of your own.';

  String get failure => this == _AuthMode.login
      ? "Couldn't sign in"
      : "Couldn't create your account";

  _AuthMode get other =>
      this == _AuthMode.login ? _AuthMode.signup : _AuthMode.login;
}

class NetworkStage extends StatefulWidget {
  const NetworkStage({required this.indicator, super.key});

  /// The flow's step indicator zone. See `SetupFlow`.
  final Widget indicator;

  @override
  State<NetworkStage> createState() => _NetworkStageState();
}

class _NetworkStageState extends State<NetworkStage> {
  final TextEditingController _key = TextEditingController();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  final TextEditingController _subnet = TextEditingController();

  _Path _path = _Path.none;
  _AuthMode _mode = _AuthMode.login;

  /// Whatever we can say before bothering anything on the wire. Rendered under
  /// the field it is about, which is where a person is already looking.
  String? _keyProblem;
  String? _emailProblem;
  String? _passwordProblem;

  /// The last thing that came back from the wire and did not work. Held here
  /// rather than read off the stores so that a failure on one path is never
  /// still on screen when the other one is open.
  ({String headline, String detail})? _failure;

  @override
  void dispose() {
    _key.dispose();
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    _subnet.dispose();
    super.dispose();
  }

  void _open(_Path path) => setState(() {
    _path = path;
    _failure = null;
  });

  void _back() => setState(() {
    _path = _Path.none;
    _failure = null;
    _keyProblem = null;
    _emailProblem = null;
    _passwordProblem = null;
    // A password typed on the way past is not kept around.
    _password.clear();
    _confirm.clear();
  });

  void _swapMode() => setState(() {
    _mode = _mode.other;
    _failure = null;
    _emailProblem = null;
    _passwordProblem = null;
    _password.clear();
    _confirm.clear();
  });

  // -- the two ways in ------------------------------------------------------

  Future<void> _joinWithKey(DaemonStore daemon) async {
    final key = _key.text.trim();
    if (key.isEmpty) {
      setState(() => _keyProblem = 'Paste the key you were sent');
      return;
    }
    setState(() {
      _keyProblem = null;
      _failure = null;
    });
    final joined = await daemon.join(key);
    if (!mounted || joined != null) return;
    // Landing here means the daemon said no; the flow moves on by itself when
    // it says yes.
    setState(
      () => _failure = _wire(
        "Couldn't join your network",
        daemon.joinError?.message,
      ),
    );
  }

  /// Mint and join, chained. Two calls, one button, one outcome.
  Future<void> _joinAsOperator(AppState app) async {
    setState(() => _failure = null);
    final key = await app.network.mintEnrollmentKey();
    if (!mounted) return;
    if (key == null) {
      setState(
        () => _failure = _wire(
          "Couldn't add $thisMachine to your network",
          app.network.keyError?.message,
        ),
      );
      return;
    }
    final joined = await app.daemon.join(key.key);
    // The key has done its job. It is a credential, and nothing keeps one
    // sitting in a store for the rest of the session.
    app.network.clearKey();
    if (!mounted || joined != null) return;
    setState(
      () => _failure = _wire(
        "Couldn't join your network",
        app.daemon.joinError?.message,
      ),
    );
  }

  Future<void> _submitAuth(SessionStore session) async {
    final email = _email.text.trim();
    String? emailProblem;
    String? passwordProblem;
    if (email.isEmpty) {
      emailProblem = 'An email address is needed';
    } else if (!email.contains('@') || email.endsWith('@')) {
      emailProblem = '"$email" does not look like an email address';
    }
    if (_password.text.isEmpty) {
      passwordProblem = 'A password is needed';
    } else if (_mode == _AuthMode.signup && _password.text != _confirm.text) {
      passwordProblem = 'The two passwords do not match';
    }
    if (emailProblem != null || passwordProblem != null) {
      setState(() {
        _emailProblem = emailProblem;
        _passwordProblem = passwordProblem;
      });
      return;
    }

    setState(() {
      _emailProblem = null;
      _passwordProblem = null;
      _failure = null;
    });

    final subnet = _subnet.text.trim();
    final ok = _mode == _AuthMode.login
        ? await session.login(email: email, password: _password.text)
        : await session.signup(
            email: email,
            password: _password.text,
            subnet: subnet.isEmpty ? null : subnet,
          );
    if (!mounted) return;
    // The password has done its job; it does not sit in a controller after.
    _password.clear();
    _confirm.clear();
    setState(() {
      if (!ok) _failure = _wire(_mode.failure, session.authError?.message);
    });
  }

  Future<void> _signOut(SessionStore session) async {
    await session.logout();
    if (!mounted) return;
    setState(() {
      _mode = _AuthMode.login;
      _failure = null;
    });
  }

  static ({String headline, String detail}) _wire(
    String headline,
    String? detail,
  ) => (
    headline: headline,
    // Every one of these paths sets its error before it returns false. The
    // fallback exists so a future one that does not still says something.
    detail: detail ?? 'No reason was given.',
  );

  // -- the screen -----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        app.daemon,
        app.session,
        app.network,
      ]),
      builder: (context, _) => _stage(context, app),
    );
  }

  Widget _stage(BuildContext context, AppState app) {
    final drift = FilamentMotion.drift(context);
    return MeshStage(
      title: 'Join your network',
      message: _path == _Path.none
          ? 'Either somebody sent you a key, or the network is yours to run.'
          : null,
      body: AnimatedSwitcher(
        duration: drift.duration,
        switchInCurve: drift.curve,
        switchOutCurve: drift.curve,
        // The card that is leaving is a picture; it must not push the one
        // arriving around while it fades.
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topCenter,
          children: <Widget>[
            for (final old in previous) Positioned.fill(child: old),
            ?current,
          ],
        ),
        child: KeyedSubtree(key: ValueKey<_Path>(_path), child: _cards(app)),
      ),
      action: _path == _Path.none
          ? null
          : MeshButton.ghost(label: 'Back', onPressed: _back),
      indicator: widget.indicator,
    );
  }

  Widget _cards(AppState app) {
    final key = SetupCard(
      title: 'I have an enrollment key',
      message: _path == _Path.key
          ? 'Paste it and $thisMachine joins.'
          : 'Somebody who runs the network sent you one.',
      onOpen: _path == _Path.key ? null : () => _open(_Path.key),
      child: _path == _Path.key ? _keyForm(app.daemon) : null,
    );

    final operator = SetupCard(
      title: 'I run this network',
      message: _operatorMessage(app.session),
      onOpen: _path == _Path.operator ? null : () => _open(_Path.operator),
      child: _path == _Path.operator ? _operatorForm(app) : null,
    );

    return switch (_path) {
      _Path.key => key,
      _Path.operator => operator,
      _Path.none => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          key,
          const SizedBox(height: FilamentSpace.gap),
          operator,
        ],
      ),
    };
  }

  String _operatorMessage(SessionStore session) {
    if (_path != _Path.operator) {
      return 'Sign in, and $thisMachine joins with one click.';
    }
    return session.hasSession
        ? 'One click and $thisMachine is on it.'
        : _mode.message;
  }

  // -- the key card ---------------------------------------------------------

  Widget _keyForm(DaemonStore daemon) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MeshTextField(
          controller: _key,
          label: 'Enrollment key',
          placeholder: 'Paste it here',
          mono: true,
          autofocus: true,
          enabled: !daemon.joining,
          errorText: _keyProblem,
          onSubmitted: (_) => _joinWithKey(daemon),
        ),
        const SizedBox(height: FilamentSpace.x5),
        MeshButton.primary(
          label: 'Join',
          expand: true,
          busy: daemon.joining,
          onPressed: () => _joinWithKey(daemon),
        ),
        ?_failureNote,
      ],
    );
  }

  // -- the operator card ----------------------------------------------------

  Widget _operatorForm(AppState app) {
    final session = app.session;
    if (session.hasSession) {
      final who = session.email ?? session.accountId ?? 'this account';
      final busy = app.network.mintingKey || app.daemon.joining;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Signed in as $who', style: FilamentTheme.typeOf(context).body),
          const SizedBox(height: FilamentSpace.x5),
          MeshButton.primary(
            label: 'Join $thisMachine',
            expand: true,
            busy: busy,
            onPressed: () => _joinAsOperator(app),
          ),
          const SizedBox(height: FilamentSpace.x3),
          // A ghost in a stretched column would fill the card; a row hugs it.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              MeshButton.ghost(
                label: 'Use a different account',
                onPressed: busy || session.busy
                    ? null
                    : () => _signOut(session),
              ),
            ],
          ),
          ?_failureNote,
        ],
      );
    }

    final signup = _mode == _AuthMode.signup;
    final busy = session.busy;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MeshTextField(
          controller: _email,
          label: 'Email',
          placeholder: 'you@example.com',
          enabled: !busy,
          errorText: _emailProblem,
          keyboardType: TextInputType.emailAddress,
          onSubmitted: (_) => _submitAuth(session),
        ),
        const SizedBox(height: FilamentSpace.x4),
        MeshTextField(
          controller: _password,
          label: 'Password',
          secret: true,
          enabled: !busy,
          errorText: _passwordProblem,
          onSubmitted: (_) => _submitAuth(session),
        ),
        if (signup) ...[
          const SizedBox(height: FilamentSpace.x4),
          MeshTextField(
            controller: _confirm,
            label: 'Password again',
            secret: true,
            enabled: !busy,
            onSubmitted: (_) => _submitAuth(session),
          ),
          const SizedBox(height: FilamentSpace.x4),
          MeshTextField(
            controller: _subnet,
            label: 'Addresses',
            placeholder: '10.201.0.0/16',
            helper: 'Optional. Left empty, you get 10.201.0.0/16.',
            mono: true,
            enabled: !busy,
            onSubmitted: (_) => _submitAuth(session),
          ),
        ],
        const SizedBox(height: FilamentSpace.x5),
        MeshButton.primary(
          label: _mode.action,
          expand: true,
          busy: busy,
          onPressed: () => _submitAuth(session),
        ),
        const SizedBox(height: FilamentSpace.x3),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            MeshButton.ghost(
              label: _mode.swap,
              onPressed: busy ? null : _swapMode,
            ),
          ],
        ),
        ?_failureNote,
      ],
    );
  }

  /// The last wire failure, with the gap above it. Null when there is nothing
  /// to say, so a card carries no empty space waiting for bad news.
  Widget? get _failureNote {
    final failure = _failure;
    if (failure == null) return null;
    return Padding(
      padding: const EdgeInsets.only(top: FilamentSpace.x5),
      child: SetupFailure(headline: failure.headline, detail: failure.detail),
    );
  }
}
