/// Getting a session for the account that owns a network.
///
/// The sign-in and sign-up forms live here rather than inside `network.dart`
/// because they are not really part of that screen: they are what stands in
/// front of it until there is a session. [MeshAuthPanel] drops into any column
/// of panels, and the Network screen's quiet card reveals one.
///
/// First run does not use this. The setup flow asks the same two questions in
/// its own shape — one card among two ways onto a network, chained straight
/// into joining — and this panel is what Network shows afterwards, to somebody
/// who is already on the mesh and now wants to run it.
///
/// Nothing here says which control plane any of it talks to. That is Settings
/// vocabulary, and this is a primary surface.
library;

import 'package:flutter/widgets.dart';

import '../data/cli_config.dart' show SessionProblem;
import '../kit/button.dart';
import '../kit/panel.dart';
import '../kit/text_field.dart';
import '../kit/toast.dart';
import '../state/app_state.dart';
import '../state/session_store.dart';
import '../theme/theme.dart';

// ---------------------------------------------------------------------------
// the auth panel
// ---------------------------------------------------------------------------

/// How wide the sign-in form column is. The same width the confirm dialog
/// uses: both are one thing asking one question.
const double _formWidth = 420;

/// Which form the panel is showing.
enum MeshAuthMode {
  login,
  signup;

  String get action =>
      this == MeshAuthMode.login ? 'Sign in' : 'Create account';
  String get title =>
      this == MeshAuthMode.login ? 'Sign in' : 'Create an account';

  /// The headline over whatever the control plane said when it said no.
  String get failure => this == MeshAuthMode.login
      ? "Couldn't sign in"
      : "Couldn't create your account";

  /// The label on the button that swaps to the other one.
  String get swapLabel =>
      this == MeshAuthMode.login ? 'Create an account' : 'Sign in instead';

  MeshAuthMode get other =>
      this == MeshAuthMode.login ? MeshAuthMode.signup : MeshAuthMode.login;
}

/// Email and password against the control plane, and the account it makes.
///
/// Signing up returns a session too, so both paths end in the same place: the
/// shared `config.json` gets a token and every CP-backed screen wakes up.
class MeshAuthPanel extends StatefulWidget {
  const MeshAuthPanel({
    this.initialMode = MeshAuthMode.login,
    this.onAuthenticated,
    super.key,
  });

  final MeshAuthMode initialMode;

  /// Fired after a session lands. The Network screen uses it to fetch.
  final VoidCallback? onAuthenticated;

  @override
  State<MeshAuthPanel> createState() => _MeshAuthPanelState();
}

class _MeshAuthPanelState extends State<MeshAuthPanel> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  final TextEditingController _subnet = TextEditingController();

  late MeshAuthMode _mode = widget.initialMode;

  /// Whatever we can tell the operator before bothering the control plane.
  String? _localError;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    _subnet.dispose();
    super.dispose();
  }

  void _swap() {
    setState(() {
      _mode = _mode.other;
      _localError = null;
      // A password typed into the wrong form is not carried to the other one.
      _password.clear();
      _confirm.clear();
    });
  }

  String? _validate() {
    final email = _email.text.trim();
    if (email.isEmpty) return 'An email address is needed';
    if (!email.contains('@') || email.endsWith('@')) {
      return '"$email" does not look like an email address';
    }
    if (_password.text.isEmpty) return 'A password is needed';
    if (_mode == MeshAuthMode.signup && _password.text != _confirm.text) {
      return 'The two passwords do not match';
    }
    return null;
  }

  Future<void> _submit(SessionStore session) async {
    if (session.busy) return;
    final problem = _validate();
    if (problem != null) {
      setState(() => _localError = problem);
      return;
    }
    setState(() => _localError = null);

    final email = _email.text.trim();
    final password = _password.text;
    final subnet = _subnet.text.trim();

    final ok = _mode == MeshAuthMode.login
        ? await session.login(email: email, password: password)
        : await session.signup(
            email: email,
            password: password,
            subnet: subnet.isEmpty ? null : subnet,
          );

    if (!mounted) return;
    if (!ok) return;

    // The password has done its job; it does not sit in a controller after.
    _password.clear();
    _confirm.clear();
    MeshToast.show(context, 'Signed in as $email', tone: MeshTone.signal);
    widget.onAuthenticated?.call();
  }

  @override
  Widget build(BuildContext context) {
    final session = AppScope.sessionOf(context);
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => _panel(context, session),
    );
  }

  Widget _panel(BuildContext context, SessionStore session) {
    final theme = FilamentTheme.of(context);
    final signup = _mode == MeshAuthMode.signup;
    final busy = session.busy;

    // Only worth showing when the stored session exists but cannot be used —
    // "not logged in" is already obvious from the form being here.
    final problem = session.session.problem;
    final standing = problem == SessionProblem.notLoggedIn
        ? null
        : session.session.message;

    // Ours about our own form, or the control plane's about the attempt. The
    // two are different shapes because they are different registers: a typo in
    // the email box is not news from a wire.
    final wire = session.authError?.message;

    return MeshPanel(
      title: _mode.title,
      subtitle: signup
          ? 'A new account, and a network of your own'
          : 'The account that owns your network',
      actions: [
        MeshButton.ghost(
          label: _mode.swapLabel,
          onPressed: busy ? null : _swap,
        ),
      ],
      child: Padding(
        // This is the one panel that is the whole screen, so it stands taller
        // than a panel that shares the column with five others.
        padding: const EdgeInsets.symmetric(vertical: FilamentSpace.x2),
        child: Align(
          // Centred rather than hugging the left edge: at 960px a form pinned
          // to one side of a wide card reads as an accident.
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _formWidth),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (standing != null) ...[
                  Text(standing, style: theme.type.bodyDim),
                  const SizedBox(height: FilamentSpace.x5),
                ],
                MeshTextField(
                  controller: _email,
                  label: 'Email',
                  placeholder: 'you@example.com',
                  enabled: !busy,
                  keyboardType: TextInputType.emailAddress,
                  onSubmitted: (_) => _submit(session),
                ),
                const SizedBox(height: FilamentSpace.x4),
                MeshTextField(
                  controller: _password,
                  label: 'Password',
                  secret: true,
                  enabled: !busy,
                  onSubmitted: (_) => _submit(session),
                ),
                if (signup) ...[
                  const SizedBox(height: FilamentSpace.x4),
                  MeshTextField(
                    controller: _confirm,
                    label: 'Password again',
                    secret: true,
                    enabled: !busy,
                    onSubmitted: (_) => _submit(session),
                  ),
                  const SizedBox(height: FilamentSpace.x4),
                  MeshTextField(
                    controller: _subnet,
                    label: 'Addresses',
                    placeholder: '10.201.0.0/16',
                    helper: 'Optional. Left empty, you get 10.201.0.0/16.',
                    mono: true,
                    enabled: !busy,
                    onSubmitted: (_) => _submit(session),
                  ),
                ],
                if (_localError != null) ...[
                  const SizedBox(height: FilamentSpace.x4),
                  MeshErrorNote(_localError!),
                ] else if (wire != null) ...[
                  const SizedBox(height: FilamentSpace.x4),
                  MeshWireError(headline: _mode.failure, detail: wire),
                ],
                const SizedBox(height: FilamentSpace.x5),
                // The one primary action on the screen, and the width of the
                // form it finishes.
                MeshButton.primary(
                  label: _mode.action,
                  expand: true,
                  busy: busy,
                  onPressed: () => _submit(session),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
