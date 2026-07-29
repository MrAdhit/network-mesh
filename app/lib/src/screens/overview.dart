/// Overview — the glanceable answer.
///
/// Four pictures, one per state the daemon can be in:
///
/// * missing or stopped: the manager's front door. The socket is dead and the
///   app knows why — there is no meshd on this Mac, or there is one and
///   nothing is running it — so the screen offers the one action that fixes
///   that and shows the download as it happens;
/// * unreachable for some other reason: the OS error verbatim, and on EACCES
///   the explanation that the socket is root-only plus the chmod that unblocks
///   it today;
/// * up but not enrolled: the identity hero saying so, and the join card,
///   which mints a key inline when there is a control plane session to mint it
///   with;
/// * enrolled: the hero — triad, node name, the headline RTT — then this
///   node's facts as a row of stat tiles, then one panel per backhaul plane.
///
/// The composition is the one DESIGN.md fixes: the hero floats on the window
/// background with no panel around it, short facts are tiles rather than form
/// rows, and panels start below them.
///
/// Nothing here polls: [DaemonStore] does that, and this screen is a pure
/// reading of it.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../data/daemon_client.dart';
import '../data/ipc_protocol.dart';
import '../data/privileged.dart' show MeshdInstall;
import '../icons/mesh_icons.dart';
import '../kit/badge.dart';
import '../kit/button.dart';
import '../kit/copyable.dart';
import '../kit/panel.dart';
import '../kit/path_triad.dart';
import '../kit/scaffold.dart';
import '../kit/stat_tile.dart';
import '../kit/status_dot.dart';
import '../kit/text_field.dart';
import '../kit/toast.dart';
import '../state/app_state.dart';
import '../state/daemon_store.dart';
import '../state/manager_store.dart';
import '../theme/theme.dart';
import '../util/format.dart';
import 'manager.dart';

class OverviewScreen extends StatelessWidget {
  const OverviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    // The session matters here only because it decides whether the join card
    // can mint a key; the network store because minting is its call; the
    // manager because a dead socket is its screen.
    return ListenableBuilder(
      listenable: Listenable.merge([
        app.daemon,
        app.session,
        app.network,
        app.manager,
      ]),
      builder: (context, _) {
        final daemon = app.daemon;
        return MeshScreen(
          title: 'Overview',
          subtitle: 'Daemon at ${daemon.endpoint}',
          actions: [
            MeshAsyncIconButton(
              glyph: MeshGlyph.refresh,
              tooltip: 'Poll now',
              action: daemon.refreshNow,
            ),
          ],
          children: _blocks(context, daemon, app.manager),
        );
      },
    );
  }

  List<Widget> _blocks(
    BuildContext context,
    DaemonStore daemon,
    ManagerStore manager,
  ) {
    if (!daemon.firstPollComplete) {
      return const [_ConnectingPanel()];
    }
    if (!daemon.reachable) {
      // A root-only socket is not a story about installing anything: meshd is
      // there and answering somebody, and the chmod hint below is the fix.
      final denied = daemon.error is DaemonPermissionDenied;
      // Before the first look at the disk there is nothing the manager can
      // honestly say, so the socket's own account of itself stands alone.
      final manage = !denied && manager.inspected;
      return [
        if (manage) _ManagerPanel(manager: manager),
        // Nothing installed is the whole explanation; the socket failing to
        // connect to a daemon that does not exist adds a second panel saying
        // the same thing in a worse voice.
        if (!manage || !manager.supported || manager.installed)
          _UnreachablePanel(daemon: daemon),
        // Whatever we knew before the socket went away is still worth showing,
        // clearly marked as no longer current. Stale facts keep their panel:
        // the badge and the header are what say they are not live any more.
        if (daemon.status != null && daemon.status!.enrolled)
          _ThisNode(status: daemon.status!, daemon: daemon, stale: true),
      ];
    }

    final status = daemon.status;
    if (status == null) return const [_ConnectingPanel()];

    if (!status.enrolled) {
      return [_NotEnrolledHero(status: status), const _JoinCard()];
    }

    return [
      _Hero(status: status, peers: daemon.peers),
      _ThisNode(status: status, daemon: daemon, stale: false),
      _BackhaulRow(status: status),
    ];
  }
}

// ---------------------------------------------------------------------------
// the hero
// ---------------------------------------------------------------------------

/// The identity block, floating directly on the window background.
///
/// No panel, no border, no fill: DESIGN.md's composition starts the screen with
/// the mark and the one number, and lets the panels begin underneath. The frame
/// is shared by the enrolled and not-enrolled pictures so the node's identity
/// sits in the same place whichever one is on screen.
class _HeroFrame extends StatelessWidget {
  const _HeroFrame({
    required this.triad,
    required this.name,
    required this.line,
    this.reading,
  });

  /// The mark, at hero scale.
  final Widget triad;

  /// This node's name, at section size.
  final String name;

  /// The state line under the name.
  final Widget line;

  /// The right-hand column: the headline number and what it measures.
  final Widget? reading;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    return Padding(
      // Only the bottom: the screen header already spaces the top, and the
      // panels below want a touch more air than the standard gap.
      padding: const EdgeInsets.only(bottom: FilamentSpace.x1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          triad,
          const SizedBox(width: FilamentSpace.x5),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: theme.type.section,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: FilamentSpace.x2 - 2),
                line,
              ],
            ),
          ),
          if (reading != null) ...[
            const SizedBox(width: FilamentSpace.x5),
            reading!,
          ],
        ],
      ),
    );
  }
}

/// The enrolled hero: this node's own triad at scale, its name, and the one
/// number that answers "how is the mesh doing" — the median RTT across peers on
/// the paths actually carrying their traffic.
class _Hero extends StatelessWidget {
  const _Hero({required this.status, required this.peers});

  final StatusReport status;
  final List<PeerReport> peers;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;
    final median = _medianBestRtt(peers);

    // The hero is allowed to bloom, and only while it is reading something:
    // a glow under a dash would be the app claiming a state it does not have.
    final headline = theme.type.headline.copyWith(
      shadows: median == null
          ? null
          : tokens.bloom(tokens.signal, intensity: 0.9, blurScale: 2),
    );

    return _HeroFrame(
      triad: MeshPathTriad(
        direct: MeshPathState.winning,
        cloudflare: _plane(status.cloudflare),
        tailscale: _plane(status.tailscale),
        height: 44,
        barWidth: 6,
        gap: 4,
      ),
      name: status.nodeName,
      line: const MeshStatusLine(
        tone: MeshTone.signal,
        label: 'Enrolled',
        glow: true,
      ),
      reading: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Rolls to its new reading like a meter; it never blinks.
          // A tighter gap than the default: one space of 20px mono is already
          // a wide one next to a 44px number.
          MeshTickingMeasure(
            value: median,
            format: msParts,
            style: headline,
            gap: 2,
          ),
          const SizedBox(height: FilamentSpace.x1),
          Text(
            median == null
                ? 'No RTT yet'
                : 'Median RTT over ${countOf(peers.length, 'peer')}',
            style: theme.type.label,
          ),
        ],
      ),
    );
  }

  static MeshPathState _plane(BackhaulReport? report) {
    if (report == null) return MeshPathState.unknown;
    return report.up ? MeshPathState.up : MeshPathState.down;
  }

  /// The median of every peer's winning-path ewma. Median rather than mean so
  /// one peer over a satellite link does not become the headline.
  static double? _medianBestRtt(List<PeerReport> peers) {
    final values = <double>[
      for (final peer in peers)
        if (peer.best case final path? when path.up && path.ewmaMs != null)
          path.ewmaMs!,
    ]..sort();
    if (values.isEmpty) return null;
    final mid = values.length ~/ 2;
    return values.length.isOdd
        ? values[mid]
        : (values[mid - 1] + values[mid]) / 2;
  }
}

// ---------------------------------------------------------------------------
// enrolled
// ---------------------------------------------------------------------------

/// Address, subnet, uptime, peers — the facts `meshctl status` prints, as a row
/// of tiles rather than a form.
///
/// While the daemon is answering these float on the page like the hero above
/// them. Once it stops, they go back inside a panel: a header, a badge and a
/// footer are what can say "these are the last numbers we were given", and a
/// bare tile has nowhere to say it.
class _ThisNode extends StatelessWidget {
  const _ThisNode({
    required this.status,
    required this.daemon,
    required this.stale,
  });

  final StatusReport status;
  final DaemonStore daemon;

  /// The daemon has stopped answering; these numbers are the last ones it gave.
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final uptime = formatUptimeSecs(status.uptimeSecs);

    final tiles = MeshStatRow([
      MeshStatTile(
        label: 'Address',
        child: MeshCopyable(status.virtualIp, style: theme.type.stat),
      ),
      MeshStatTile(
        label: 'Subnet',
        child: MeshCopyable(status.subnet, style: theme.type.stat),
      ),
      MeshStatTile(
        label: 'Uptime',
        // Not a rolling number: uptime is three units of text, so it
        // crossfades to its next reading instead.
        child: MeshLive(
          value: uptime,
          child: Text(uptime, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
      MeshStatTile(
        label: 'Peers',
        child: MeshTickingMeasure(
          value: status.peerCount.toDouble(),
          format: countParts,
          style: theme.type.stat,
        ),
      ),
    ]);

    if (!stale) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          tiles,
          const SizedBox(height: FilamentSpace.x2),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              'Polled ${formatAgo(daemon.lastSuccess)} · every '
              '${formatSpan(daemon.effectiveInterval)}',
              style: theme.type.small,
            ),
          ),
        ],
      );
    }

    return MeshPanel(
      title: 'This node',
      subtitle: 'Last known values',
      actions: const [MeshBadge('Stale', tone: MeshTone.caution)],
      footer: Text(
        'Last answered ${formatAgo(daemon.lastSuccess)}',
        style: theme.type.small,
      ),
      child: Opacity(opacity: 0.6, child: tiles),
    );
  }
}

/// The two backhaul planes, side by side while there is room for them.
class _BackhaulRow extends StatelessWidget {
  const _BackhaulRow({required this.status});

  final StatusReport status;

  @override
  Widget build(BuildContext context) {
    final panels = [
      for (final entry in status.backhauls.entries)
        _BackhaulPanel(name: entry.key, report: entry.value),
    ];

    // Two status cards are shorter than a credential form, so they stay a
    // pair further down than the kit's default.
    return MeshPanelRow(stackBelow: 560, children: panels);
  }
}

/// One plane: up/down with its address and the daemon's own detail string, or
/// the fact that nothing is configured for it.
class _BackhaulPanel extends StatelessWidget {
  const _BackhaulPanel({required this.name, required this.report});

  final String name;
  final BackhaulReport? report;

  /// The planes are lowercase on the wire; on screen they are brands.
  static String _brand(String name) => switch (name) {
    'cloudflare' => 'Cloudflare',
    'tailscale' => 'Tailscale',
    _ => name,
  };

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;
    final report = this.report;
    final down = report != null && !report.up;

    return MeshPanel(
      title: _brand(name),
      accent: down ? tokens.alarm : null,
      actions: [if (report == null) const MeshBadge('Not configured')],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MeshLive(
            value: report == null ? 'unknown' : (report.up ? 'up' : 'down'),
            alignment: Alignment.centerLeft,
            child: report == null
                ? const MeshStatusLine(
                    tone: MeshTone.neutral,
                    label: 'Not configured',
                    hollow: true,
                  )
                : MeshStatusLine(
                    tone: report.up ? MeshTone.signal : MeshTone.alarm,
                    label: report.up ? 'Up' : 'Down',
                    glow: report.up,
                  ),
          ),
          const SizedBox(height: FilamentSpace.x4),
          MeshField(
            label: 'Address',
            child: report == null || report.address.isEmpty
                ? Text(
                    '—',
                    style: theme.type.monoEmphasis.copyWith(
                      color: tokens.textFaint,
                    ),
                  )
                : MeshCopyable(report.address, style: theme.type.monoEmphasis),
          ),
          const SizedBox(height: FilamentSpace.x4),
          MeshField(
            label: 'Detail',
            child: Text(
              report == null
                  ? 'No credentials for this plane'
                  : (report.detail.isEmpty ? '—' : report.detail),
              // The daemon's own words, never rewritten.
              style: theme.type.mono.copyWith(color: tokens.textDim),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// not enrolled
// ---------------------------------------------------------------------------

/// The daemon is up and has joined nothing. Same hero frame as the enrolled
/// picture — it is the same node — with the state line saying so and no
/// headline, because there is no mesh to have an RTT across yet.
class _NotEnrolledHero extends StatelessWidget {
  const _NotEnrolledHero({required this.status});

  final StatusReport status;

  @override
  Widget build(BuildContext context) {
    return _HeroFrame(
      triad: const MeshPathTriad(
        direct: MeshPathState.up,
        cloudflare: MeshPathState.unknown,
        tailscale: MeshPathState.unknown,
        height: 44,
        barWidth: 6,
        gap: 4,
      ),
      name: status.nodeName,
      line: const MeshStatusLine(
        tone: MeshTone.caution,
        label: 'Not enrolled',
        detail: 'The daemon is up but has not joined a network',
      ),
    );
  }
}

/// Paste a key and join. When there is a control plane session, the key can be
/// minted right here instead of in a terminal.
class _JoinCard extends StatefulWidget {
  const _JoinCard();

  @override
  State<_JoinCard> createState() => _JoinCardState();
}

class _JoinCardState extends State<_JoinCard> {
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    // The join button is dead until there is something to join with.
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _join() async {
    final key = _controller.text.trim();
    if (key.isEmpty) return;
    final joined = await AppScope.read(context).daemon.join(key);
    if (!mounted || joined == null) return;
    _controller.clear();
    MeshToast.show(
      context,
      'Joined as ${joined.nodeId}',
      tone: MeshTone.signal,
    );
  }

  Future<void> _mint() async {
    final minted = await AppScope.read(context).network.mintEnrollmentKey();
    if (!mounted || minted == null) return;
    _controller.text = minted.key;
    MeshToast.show(context, 'Key minted', tone: MeshTone.signal);
  }

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final app = AppScope.read(context);
    final daemon = app.daemon;
    final network = app.network;
    final canMint = app.session.hasSession;
    final key = network.lastKey;

    return MeshPanel(
      title: 'Join a network',
      subtitle: 'An enrollment key registers this node with the control plane',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MeshTextField(
            controller: _controller,
            label: 'Enrollment key',
            placeholder: 'Paste a key from `meshctl enrollment-key`',
            mono: true,
            maxLines: 3,
            minLines: 2,
            enabled: !daemon.joining,
            errorText: daemon.joinError?.message,
            onSubmitted: (_) => unawaited(_join()),
          ),
          if (key != null) ...[
            const SizedBox(height: FilamentSpace.x2),
            Text(
              key.expiresAt.isEmpty
                  ? 'Minted a key; it is in the field above'
                  : 'Minted a key, expires ${key.expiresAt}',
              style: theme.type.small,
            ),
          ],
          if (network.keyError != null) ...[
            const SizedBox(height: FilamentSpace.x2),
            Text(network.keyError!.message, style: theme.type.error),
          ],
          const SizedBox(height: FilamentSpace.x5),
          Row(
            children: [
              MeshButton.primary(
                label: 'Join',
                busy: daemon.joining,
                onPressed: _controller.text.trim().isEmpty
                    ? null
                    : () => unawaited(_join()),
              ),
              const SizedBox(width: FilamentSpace.x2),
              if (canMint)
                MeshButton(
                  label: 'Mint a key',
                  glyph: MeshGlyph.key,
                  busy: network.mintingKey,
                  onPressed: () => unawaited(_mint()),
                )
              else
                Flexible(
                  child: Text(
                    'Sign in on the Network screen to mint one here',
                    style: theme.type.small,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// the manager's front door
// ---------------------------------------------------------------------------

/// What to do about a daemon that is not there.
///
/// Three pictures, chosen off facts rather than off the derived state, so a
/// panel does not reshape itself half way through an install: this Mac has no
/// meshd, this Mac has one that nothing is running, or this is not a Mac.
///
/// The panel carries one primary action and the facts that action is about —
/// which control plane the binary comes from, which build, where it lands. The
/// progress of the download and the authorization step appear underneath it,
/// and so does whatever failed last, verbatim.
class _ManagerPanel extends StatelessWidget {
  const _ManagerPanel({required this.manager});

  final ManagerStore manager;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;

    if (!manager.supported) {
      return MeshPanel(
        title: 'meshd is not managed from here',
        child: ManagerUnsupportedNote(manager: manager),
      );
    }

    final installed = manager.installed;
    final target = manager.target;

    return MeshPanel(
      title: installed
          ? 'meshd is installed but not running'
          : 'meshd is not installed on this Mac',
      subtitle: installed
          ? 'The launchd job is what starts it'
          : 'The app fetches it from the control plane and runs it under '
                'launchd',
      accent: tokens.caution,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MeshFacts([
            MeshFact(
              label: 'Control plane',
              child: Row(
                children: [
                  Flexible(child: MeshCopyable(manager.cpUrl.url)),
                  const SizedBox(width: FilamentSpace.x2),
                  MeshBadge(manager.cpUrl.source.label),
                ],
              ),
            ),
            MeshFact(
              label: 'Target',
              child: target == null
                  ? Text(
                      'No meshd build for this Mac',
                      style: theme.type.bodyDim,
                    )
                  : Text(target, style: theme.type.mono),
            ),
            if (installed)
              MeshFact(
                label: 'Build',
                child: ManagerBuild(
                  sha256: manager.installedSha256,
                  size: manager.installedSize,
                ),
              ),
            if (installed)
              MeshFact(
                label: 'Service',
                child: ManagerServiceLine(
                  loaded: manager.serviceLoaded,
                  plistPresent: manager.plistPresent,
                ),
              )
            else
              MeshFact(
                label: 'Installs to',
                child: MeshCopyable(
                  MeshdInstall.binary,
                  style: theme.type.monoSmall,
                ),
              ),
          ], gap: FilamentSpace.x4),
          const SizedBox(height: FilamentSpace.x5),
          Row(
            children: [
              MeshAsyncButton(
                label: installed ? 'Start meshd' : 'Install meshd',
                variant: MeshButtonVariant.primary,
                autofocus: true,
                tooltip: _why(installed, target),
                action: _action(installed, target),
              ),
              const SizedBox(width: FilamentSpace.x3),
              Flexible(
                child: Text(
                  installed
                      ? 'Loading the job asks for an administrator password '
                            'once.'
                      : 'Downloading is unprivileged; installing asks for an '
                            'administrator password once.',
                  style: theme.type.small,
                ),
              ),
            ],
          ),
          ManagerActivity(manager: manager),
        ],
      ),
    );
  }

  /// Null when the button should work, and the reason it does not otherwise —
  /// the tooltip and the disabled state come from the same answer.
  String? _why(bool installed, String? target) {
    if (manager.busy) return 'Already working on it';
    if (!installed && target == null) {
      return 'The control plane publishes no build for this machine';
    }
    return null;
  }

  Future<void> Function()? _action(bool installed, String? target) {
    if (_why(installed, target) != null) return null;
    return installed ? () => manager.start() : () => manager.install();
  }
}

// ---------------------------------------------------------------------------
// unreachable
// ---------------------------------------------------------------------------

class _ConnectingPanel extends StatelessWidget {
  const _ConnectingPanel();

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    return MeshPanel(
      child: Row(
        children: [
          const MeshSpinner(size: 14),
          const SizedBox(width: FilamentSpace.x3),
          Text('Reaching the daemon', style: theme.type.bodyDim),
        ],
      ),
    );
  }
}

/// The socket did not answer. What went wrong, verbatim, and what to do next.
class _UnreachablePanel extends StatelessWidget {
  const _UnreachablePanel({required this.daemon});

  final DaemonStore daemon;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;
    final error = daemon.error;
    final denied = error is DaemonPermissionDenied;

    return MeshPanel(
      title: 'Daemon unreachable',
      accent: tokens.alarm,
      actions: [
        MeshAsyncButton(
          label: 'Retry',
          glyph: MeshGlyph.refresh,
          action: daemon.refreshNow,
        ),
      ],
      footer: Text(
        '${countOf(daemon.consecutiveFailures, 'failed poll')} · '
        'last answered ${formatAgo(daemon.lastSuccess)} · retrying every '
        '${formatSpan(daemon.effectiveInterval)}',
        style: theme.type.small,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (error != null)
            // The daemon's own words. The hint below is ours, and the
            // permission case says more than one line can carry.
            MeshErrorNote(error.message, hint: denied ? null : error.hint)
          else
            Text('The daemon did not answer', style: theme.type.bodyDim),
          if (denied) ...[
            const SizedBox(height: FilamentSpace.x4),
            Text(
              'meshd owns its socket as root, so this app cannot open it '
              'without help. Until the daemon relaxes the mode itself, open '
              'it by hand:',
              style: theme.type.bodyDim,
            ),
            const SizedBox(height: FilamentSpace.x3),
            // The socket the failure names, which is the one to relax.
            MeshCommandLine('sudo chmod 666 ${error.endpoint}'),
          ],
          const SizedBox(height: FilamentSpace.x5),
          MeshField(
            label: 'Endpoint',
            child: MeshCopyable(
              daemon.endpoint,
              style: theme.type.monoEmphasis,
            ),
          ),
        ],
      ),
    );
  }
}
