/// Settings — where things are, who we are, and the one button that undoes
/// enrollment.
///
/// Everything above the danger zone is either a fact about this machine or a
/// two-value preference. The facts are read-only on purpose: the socket path
/// and the control plane URL come from the environment and the shared config,
/// and a text box here that silently disagreed with `meshctl` would be worse
/// than no text box at all.
library;

import 'package:flutter/widgets.dart';

import '../data/cli_config.dart';
import '../data/prefs.dart';
import '../data/privileged.dart' show MeshdInstall;
import '../icons/mesh_icons.dart';
import '../kit/badge.dart';
import '../kit/button.dart';
import '../kit/copyable.dart';
import '../kit/dialog.dart';
import '../kit/panel.dart';
import '../kit/scaffold.dart';
import '../kit/select.dart';
import '../kit/status_dot.dart';
import '../kit/toast.dart';
import '../state/app_state.dart';
import '../state/daemon_store.dart';
import '../state/manager_store.dart';
import '../state/session_store.dart';
import '../theme/theme.dart';
import '../util/format.dart';
import 'manager.dart';

/// Tracks `version:` in pubspec.yaml. There is no package_info plugin here —
/// the app takes one dependency and it is `http`.
const String meshAppVersion = '1.0.0';

/// The label column inside a panel that only gets half a row. The full-width
/// panels keep [MeshFact]'s own 120.
const double _pairedLabelWidth = 88;

/// What a confirm dialog throws when the action behind it failed. The dialog
/// prints `'$e'`, so this exists only to keep "Bad state:" off the screen.
class _Failed implements Exception {
  const _Failed(this.message);

  final String message;

  @override
  String toString() => message;
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    return ListenableBuilder(
      listenable: Listenable.merge([
        app.daemon,
        app.session,
        app.prefs,
        app.manager,
      ]),
      builder: (context, _) => _Body(
        daemon: app.daemon,
        session: app.session,
        prefs: app.prefs,
        manager: app.manager,
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.daemon,
    required this.session,
    required this.prefs,
    required this.manager,
  });

  final DaemonStore daemon;
  final SessionStore session;
  final PrefsStore prefs;
  final ManagerStore manager;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    return MeshScreen(
      title: 'Settings',
      subtitle: 'Endpoints, session, appearance',
      children: [
        _daemonPanel(context, theme),
        _controlPlanePanel(context, theme),
        _sessionPanel(context, theme),
        // Two short panels, neither of which earns a full-width box of its
        // own: they share a row until the window gets narrow.
        MeshPanelRow(
          children: [
            _appearancePanel(context, theme),
            _aboutPanel(context, theme),
          ],
        ),
        _dangerPanel(context, theme),
      ],
    );
  }

  // -- daemon -------------------------------------------------------------

  Widget _daemonPanel(BuildContext context, FilamentTheme theme) {
    final error = daemon.error;
    final reachable = daemon.reachableOrUnknown;
    final offered = manager.offered;

    return MeshPanel(
      title: 'Daemon',
      subtitle: 'The local meshd, over its Unix socket',
      accent: manager.updateAvailable ? theme.tokens.caution : null,
      actions: [
        if (manager.updateAvailable)
          const MeshBadge('Update available', tone: MeshTone.caution),
        MeshAsyncIconButton(
          glyph: MeshGlyph.refresh,
          tooltip: 'Poll now',
          action: daemon.refreshNow,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MeshFacts([
            // The socket and the state are what this panel is for; both are set a
            // step above the facts under them so the eye lands there first.
            MeshFact(
              label: 'Socket',
              child: MeshCopyable(
                daemon.endpoint,
                style: theme.type.monoEmphasis,
              ),
            ),
            MeshFact(
              label: 'State',
              child: MeshStatusLine(
                style: theme.type.emphasis,
                tone: switch (reachable) {
                  null => MeshTone.neutral,
                  false => MeshTone.alarm,
                  true => daemon.enrolled ? MeshTone.signal : MeshTone.caution,
                },
                label: switch (reachable) {
                  null => 'Connecting',
                  false => 'Unreachable',
                  true => daemon.enrolled ? 'Enrolled' : 'Not enrolled',
                },
                detail: daemon.lastSuccess == null
                    ? null
                    : 'Answered ${formatAgo(daemon.lastSuccess)}',
                glow: reachable == true && daemon.enrolled,
                hollow: reachable == null,
              ),
            ),
            if (error != null)
              MeshFact(
                label: 'Last error',
                child: MeshErrorNote(error.message, hint: error.hint),
              ),
            // What is on the disk, which the socket cannot answer for: a daemon
            // that is not running still has a binary, a hash and a launchd job,
            // and those are the three things the buttons below act on.
            if (manager.supported) ...[
              MeshFact(
                label: 'Binary',
                child: manager.installed
                    ? MeshCopyable(
                        MeshdInstall.binary,
                        style: theme.type.monoEmphasis,
                      )
                    : Text(
                        'Not installed. Install it from the Overview screen.',
                        style: theme.type.small,
                      ),
              ),
              if (manager.installed)
                MeshFact(
                  label: 'Build',
                  child: ManagerBuild(
                    sha256: manager.installedSha256,
                    size: manager.installedSize,
                  ),
                ),
              MeshFact(
                label: 'Service',
                child: ManagerServiceLine(
                  loaded: manager.serviceLoaded,
                  plistPresent: manager.plistPresent,
                ),
              ),
              if (manager.updateAvailable && offered != null)
                MeshFact(
                  label: 'Update',
                  child: MeshStatusLine(
                    tone: MeshTone.caution,
                    label: 'Available',
                    // What the control plane holds, in the terms the whole
                    // protocol is in: a hash and a size.
                    detail:
                        '${offered.shortSha} · ${formatBytes(offered.size)}',
                  ),
                ),
            ],
            MeshFact(
              label: 'Poll every',
              child: Row(
                children: [
                  MeshSelect<Duration>(
                    width: 96,
                    mono: true,
                    value: prefs.pollInterval.value,
                    options: [
                      for (final d in pollIntervalChoices)
                        MeshSelectOption<Duration>(d, '${d.inSeconds}s'),
                    ],
                    onChanged: prefs.setPollInterval,
                  ),
                  const SizedBox(width: FilamentSpace.x3),
                  Flexible(
                    child: Text(
                      'Backs off to ${DaemonStore.unreachableInterval.inSeconds}s '
                      'while the daemon is unreachable',
                      style: theme.type.small,
                    ),
                  ),
                ],
              ),
            ),
            MeshFact(
              label: '',
              child: Text(
                'Set MESH_SOCKET (or MESH_STATE_DIR) to point somewhere else; the '
                'app reads it at launch.',
                style: theme.type.small,
              ),
            ),
          ], gap: FilamentSpace.x4),
          const SizedBox(height: FilamentSpace.x5),
          const MeshDivider(),
          const SizedBox(height: FilamentSpace.x5),
          _managerActions(theme),
          ManagerActivity(manager: manager),
        ],
      ),
    );
  }

  /// The lifecycle buttons, and what the app can say about them.
  ///
  /// Each one is enabled or explains itself; there is no third state where a
  /// button is dead and silent. Only "Update" is primary, and only while there
  /// is one — the rest are maintenance, not the thing to do next.
  Widget _managerActions(FilamentTheme theme) {
    if (!manager.supported) return ManagerUnsupportedNote(manager: manager);

    final busy = manager.busy;
    final installed = manager.installed;
    final running = manager.daemonRunning;
    final loaded = manager.serviceLoaded;

    String? notInstalled() => installed ? null : 'meshd is not installed';

    String? why(String? reason) => busy ? 'Already working on it' : reason;

    final start = why(
      notInstalled() ?? (running ? 'The daemon is already running' : null),
    );
    final stop = why(
      notInstalled() ??
          (running || loaded ? null : 'The launchd job is not loaded'),
    );
    final restart = why(notInstalled());
    final check = busy ? 'Already working on it' : null;

    // One action, sized to its own label.
    //
    // The [IntrinsicWidth] is load-bearing, not decoration. A [MeshButton]
    // centres its content in a container, and a container with an alignment
    // fills whatever bounded width it is handed — which is why every button in
    // this app that hugs its label is sitting in a [Row], where children are
    // measured against unbounded width. A [Wrap] is not a [Row]: it hands each
    // child the full width of the line, so the buttons filled the panel and
    // each one landed on a run of its own, four stacked full-width bars. This
    // asks the button how wide it actually wants to be and gives the [Wrap]
    // that instead.
    Widget button(
      String label,
      String? blocked,
      Future<void> Function() action, {
      MeshButtonVariant variant = MeshButtonVariant.secondary,
      MeshGlyph? glyph,
    }) => IntrinsicWidth(
      child: MeshAsyncButton(
        label: label,
        variant: variant,
        glyph: glyph,
        tooltip: blocked,
        action: blocked == null ? action : null,
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: FilamentSpace.x2,
          runSpacing: FilamentSpace.x2,
          children: [
            button('Start', start, () => manager.start()),
            button('Stop', stop, () => manager.stop()),
            button('Restart', restart, () => manager.restart()),
            button(
              'Check for updates',
              check,
              () => manager.checkForUpdates(force: true),
              glyph: MeshGlyph.refresh,
            ),
            if (manager.updateAvailable)
              button(
                'Update',
                why(null),
                () => manager.update(),
                variant: MeshButtonVariant.primary,
              ),
          ],
        ),
        const SizedBox(height: FilamentSpace.x3),
        Text(
          'Start, stop, restart and update each ask for an administrator '
          'password once. Checked for updates ${formatAgo(manager.lastChecked)}'
          '; on its own the app asks at most every '
          '${formatSpan(updateCheckInterval)}.',
          style: theme.type.small,
        ),
      ],
    );
  }

  // -- control plane ------------------------------------------------------

  Widget _controlPlanePanel(BuildContext context, FilamentTheme theme) {
    final resolved = session.cpUrl;
    return MeshPanel(
      title: 'Control plane',
      child: MeshFacts([
        MeshFact(
          label: 'URL',
          child: Row(
            children: [
              Flexible(child: MeshCopyable(resolved.url)),
              const SizedBox(width: FilamentSpace.x2),
              MeshBadge(
                resolved.source.label,
                tone: resolved.source == CpUrlSource.environment
                    ? MeshTone.link
                    : MeshTone.neutral,
              ),
            ],
          ),
        ),
        MeshFact(
          label: 'Session file',
          child: session.configPath == null
              ? Text(
                  'No home directory to store one in; set MESH_CONFIG',
                  style: theme.type.small,
                )
              : MeshCopyable(session.configPath!, style: theme.type.monoSmall),
        ),
        if (session.configError != null)
          MeshFact(
            label: 'File error',
            child: MeshErrorNote(session.configError!),
          ),
        MeshFact(
          label: '',
          child: Text(
            'This is the file meshctl uses. MESH_CP_URL overrides the URL, '
            'MESH_SESSION overrides the token.',
            style: theme.type.small,
          ),
        ),
      ]),
    );
  }

  // -- session ------------------------------------------------------------

  Widget _sessionPanel(BuildContext context, FilamentTheme theme) {
    final fromEnv = session.sessionFromEnvironment;
    final expiresAt = session.expiresAt;
    final expiry = expiresAt == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000);

    if (!session.hasSession) {
      return MeshPanel(
        title: 'Session',
        actions: [
          MeshBadge(
            session.sessionExpired ? 'Expired' : 'Signed out',
            tone: session.sessionExpired ? MeshTone.caution : MeshTone.neutral,
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              session.session.message ?? 'Not logged in',
              style: theme.type.bodyDim,
            ),
            const SizedBox(height: FilamentSpace.x4),
            Text('Sign in on the Network screen.', style: theme.type.small),
          ],
        ),
      );
    }

    return MeshPanel(
      title: 'Session',
      actions: [
        MeshBadge(fromEnv ? 'MESH_SESSION' : 'Stored', mono: fromEnv),
        MeshButton.destructive(
          label: 'Sign out',
          busy: session.busy,
          tooltip: fromEnv
              ? 'MESH_SESSION is set in the environment; unset it to sign out'
              : null,
          onPressed: fromEnv ? null : () => _signOut(context),
        ),
      ],
      child: MeshFacts([
        MeshFact(
          label: 'Email',
          child: Text(
            session.email ?? 'Not recorded',
            style: session.email == null ? theme.type.small : theme.type.mono,
          ),
        ),
        MeshFact(
          label: 'Account',
          child: session.accountId == null
              ? Text('Not recorded', style: theme.type.small)
              : MeshCopyable(
                  session.accountId!,
                  display: shortId(session.accountId!, head: 8, tail: 6),
                ),
        ),
        MeshFact(
          label: 'Expires',
          child: expiry == null
              ? Text('Not stated', style: theme.type.small)
              : Row(
                  children: [
                    Flexible(
                      child: Text(
                        formatDateTime(expiry),
                        style: theme.type.mono,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: FilamentSpace.x2),
                    MeshBadge(
                      formatUntil(expiry),
                      tone: expiry.difference(DateTime.now()).inHours < 24
                          ? MeshTone.caution
                          : MeshTone.neutral,
                    ),
                  ],
                ),
        ),
        if (fromEnv)
          MeshFact(
            label: '',
            child: Text(
              'The token comes from MESH_SESSION, which carries no email or '
              'account ID.',
              style: theme.type.small,
            ),
          ),
      ]),
    );
  }

  Future<void> _signOut(BuildContext context) async {
    final confirmed = await MeshConfirmDialog.ask(
      context,
      title: 'Sign out?',
      message:
          'The shared session file is removed. meshctl on this machine will '
          'need to log in again too. The daemon keeps running and this node '
          'stays enrolled.',
      confirmLabel: 'Sign out',
      onConfirm: () async {
        final done = await session.logout();
        if (!done) {
          throw _Failed(session.configError ?? 'Could not remove the file');
        }
      },
    );
    if (!confirmed || !context.mounted) return;
    MeshToast.show(context, 'Signed out');
  }

  // -- appearance ---------------------------------------------------------

  Widget _appearancePanel(BuildContext context, FilamentTheme theme) {
    return MeshPanel(
      title: 'Appearance',
      // Half a row wide, so the label column narrows with it.
      child: MeshFacts([
        MeshFact(
          label: 'Theme',
          labelWidth: _pairedLabelWidth,
          child: MeshSelect<MeshThemeMode>(
            width: 120,
            value: prefs.themeMode.value,
            options: [
              for (final mode in MeshThemeMode.values)
                MeshSelectOption<MeshThemeMode>(mode, mode.label),
            ],
            onChanged: prefs.setThemeMode,
          ),
        ),
        MeshFact(
          label: '',
          labelWidth: _pairedLabelWidth,
          child: Text(
            'Dark is the primary theme; System follows the desktop.',
            style: theme.type.small,
          ),
        ),
      ]),
    );
  }

  // -- about --------------------------------------------------------------

  Widget _aboutPanel(BuildContext context, FilamentTheme theme) {
    final prefsPath = prefs.path;
    return MeshPanel(
      title: 'About',
      child: MeshFacts([
        MeshFact(
          label: 'Version',
          labelWidth: _pairedLabelWidth,
          child: Text(meshAppVersion, style: theme.type.mono),
        ),
        MeshFact(
          label: 'Preferences',
          labelWidth: _pairedLabelWidth,
          child: prefsPath == null
              ? Text('Kept in memory only', style: theme.type.small)
              : MeshCopyable(prefsPath, style: theme.type.monoSmall),
        ),
      ]),
    );
  }

  // -- danger zone --------------------------------------------------------

  Widget _dangerPanel(BuildContext context, FilamentTheme theme) {
    final left = daemon.lastLeave;
    final canLeave = daemon.reachable && daemon.enrolled;
    final why = !daemon.reachable
        ? 'The daemon is unreachable'
        : (!daemon.enrolled ? 'This node is not enrolled' : null);

    // Built first so `child` stays the last argument, the way the kit's other
    // call sites read.
    final Widget? footer = left == null
        ? null
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Left the network; ${left.nodeId} is gone and its address '
                'is free',
                style: theme.type.body,
              ),
              if (left.detail.isNotEmpty) ...[
                const SizedBox(height: FilamentSpace.x2),
                // The daemon's own caveat, verbatim: usually that the control
                // plane could not be reached and the record still exists.
                Text(left.detail, style: theme.type.mono),
              ],
            ],
          );

    return MeshPanel(
      title: 'Danger zone',
      accent: theme.tokens.alarm,
      footer: footer,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Leave the network', style: theme.type.emphasis),
                    const SizedBox(height: FilamentSpace.x2),
                    Text(
                      'The daemon deregisters this node and stops. Its address '
                      'is freed for the next node, and rejoining needs a fresh '
                      'enrollment key.',
                      style: theme.type.bodyDim,
                    ),
                    if (why != null) ...[
                      const SizedBox(height: FilamentSpace.x2),
                      Text(why, style: theme.type.small),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: FilamentSpace.x5),
              MeshButton.destructive(
                label: 'Leave network',
                glyph: MeshGlyph.power,
                busy: daemon.leaving,
                tooltip: why,
                onPressed: canLeave ? () => _leave(context) : null,
              ),
            ],
          ),
          if (daemon.leaveError != null) ...[
            const SizedBox(height: FilamentSpace.x3),
            MeshErrorNote(
              daemon.leaveError!.message,
              hint: daemon.leaveError!.hint,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _leave(BuildContext context) async {
    final confirmed = await MeshConfirmDialog.ask(
      context,
      title: 'Leave the network?',
      message:
          'The daemon deregisters this node and stops. Its address is free '
          'for the next node, and rejoining needs a fresh enrollment key.',
      confirmLabel: 'Leave network',
      confirmPhrase: 'leave',
      onConfirm: () async {
        final left = await daemon.leave();
        if (left == null) {
          throw _Failed(
            daemon.leaveError?.message ?? 'The daemon did not answer',
          );
        }
      },
    );
    if (!confirmed || !context.mounted) return;
    final left = daemon.lastLeave;
    MeshToast.show(
      context,
      left == null || left.detail.isEmpty
          ? 'Left the network'
          : 'Left the network — ${left.detail}',
      tone: left != null && left.detail.isNotEmpty
          ? MeshTone.caution
          : MeshTone.signal,
    );
  }
}
