/// Overview — the answer to "is this Mac on the mesh?".
///
/// One picture, and the same picture dimmed: the hero — the triad, this Mac's
/// name, the headline RTT — then its facts as a row of tiles, then one panel per
/// backhaul plane. When the engine stops, those readings stay exactly where they
/// were, dimmed and labelled as the last ones we were given, and the shell wears
/// [MeshEngineBannerHost]'s one-line notice above them.
///
/// What is *not* here any more: the socket path under the title, the join card,
/// and the manager's front door. A Mac that has nothing installed, or has never
/// joined, never reaches this screen — it is in the setup flow — and the
/// mechanics behind all three (the endpoint, the binary, the control plane) are
/// filed in Settings. This screen speaks outcomes.
///
/// Nothing here polls: [DaemonStore] does that, and this screen is a pure
/// reading of it.
library;

import 'package:flutter/widgets.dart';

import '../data/ipc_protocol.dart';
import '../icons/mesh_icons.dart';
import '../kit/badge.dart';
import '../kit/banner.dart';
import '../kit/button.dart';
import '../kit/copyable.dart';
import '../kit/panel.dart';
import '../kit/path_triad.dart';
import '../kit/scaffold.dart';
import '../kit/stat_tile.dart';
import '../kit/status_dot.dart';
import '../state/app_state.dart';
import '../state/daemon_store.dart';
import '../state/manager_store.dart';
import '../theme/theme.dart';
import '../util/format.dart';

class OverviewScreen extends StatelessWidget {
  const OverviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    // The manager matters here only for what it can say about a failed restart;
    // everything else on the screen is the daemon's own account of itself.
    return ListenableBuilder(
      listenable: Listenable.merge([app.daemon, app.manager]),
      builder: (context, _) {
        final daemon = app.daemon;
        return MeshScreen(
          title: 'Overview',
          subtitle: 'This Mac on the mesh',
          actions: [
            MeshAsyncIconButton(
              glyph: MeshGlyph.refresh,
              tooltip: 'Check now',
              action: daemon.refreshNow,
            ),
          ],
          children: _blocks(daemon, app.manager),
        );
      },
    );
  }

  List<Widget> _blocks(DaemonStore daemon, ManagerStore manager) {
    final status = daemon.status;

    if (!daemon.firstPollComplete) return const [_ConnectingPanel()];

    if (!daemon.reachable) {
      // The banner above the shell is what says the engine stopped; down here
      // the job is to keep the last picture on screen and be honest that it is
      // the last one. Only a restart we were asked for and could not do gets a
      // sentence of its own.
      return [
        if (status != null && status.enrolled)
          _Stale(status: status, daemon: daemon)
        else
          const _WaitingPanel(),
        if (manager.error != null)
          MeshWireError(
            headline: "Couldn't start the mesh engine",
            detail: manager.error!,
          ),
      ];
    }

    if (status == null) return const [_ConnectingPanel()];

    // Routing keeps an unenrolled Mac in the setup flow, so this is the state
    // between leaving a network and the window changing shape. One quiet line,
    // never a form.
    if (!status.enrolled) return const [_LeftPanel()];

    return [
      _Hero(status: status, peers: daemon.peers, live: true),
      _Facts(status: status, daemon: daemon),
      _BackhaulRow(status: status),
    ];
  }
}

// ---------------------------------------------------------------------------
// the shell's banner
// ---------------------------------------------------------------------------

/// The calm notice about the mesh engine, above everything else in the window.
///
/// Wrap the shell in one and it takes care of itself: nothing at all while the
/// engine is answering, and one line with one button when it is not. It is
/// here rather than in the shell because what it says and what its button does
/// are Overview's business — the shell only has to hand it its child.
///
/// The child is passed through [ListenableBuilder] untouched, so a poll rebuilds
/// this wrapper and not the four screens under it.
class MeshEngineBannerHost extends StatelessWidget {
  const MeshEngineBannerHost({required this.child, super.key});

  /// The shell: rail, content, everything.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    return ListenableBuilder(
      listenable: Listenable.merge([app.daemon, app.manager]),
      child: child,
      builder: (context, child) =>
          MeshBannerHost(banner: _banner(app), child: child!),
    );
  }

  /// Null whenever there is nothing to say, which is almost always.
  Widget? _banner(AppState app) {
    final daemon = app.daemon;
    // Before the first poll lands there is no news, only ignorance.
    if (!daemon.firstPollComplete || daemon.reachable) return null;

    final manager = app.manager;
    final restartable = manager.supported && manager.installed;

    return MeshBanner(
      message: 'The mesh engine stopped',
      action: !restartable
          ? null
          : MeshAsyncButton(
              label: 'Restart',
              // The honest line about what is about to happen lives in the
              // tooltip: a banner is one sentence, and this is not the
              // sentence.
              tooltip: manager.busy
                  ? 'Already working on it'
                  : 'macOS will ask for your administrator password',
              action: manager.busy ? null : () => manager.restart(),
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// the hero
// ---------------------------------------------------------------------------

/// The identity block, floating directly on the window background.
///
/// No panel, no border, no fill: DESIGN.md's composition starts the screen with
/// the mark and the one number, and lets the panels begin underneath.
class _Hero extends StatelessWidget {
  const _Hero({required this.status, required this.peers, required this.live});

  final StatusReport status;
  final List<PeerReport> peers;

  /// The engine is answering. A hero that is not live states no colour and
  /// casts no glow: the numbers are still true, they are just not now.
  final bool live;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;
    final median = _medianBestRtt(peers);

    // The hero is allowed to bloom, and only while it is reading something
    // live: a glow under a dash would be the app claiming a state it does not
    // have.
    final headline = theme.type.headline.copyWith(
      shadows: median == null || !live
          ? null
          : tokens.bloom(tokens.signal, intensity: 0.9, blurScale: 2),
    );

    return Padding(
      // Only the bottom: the screen header already spaces the top, and the
      // panels below want a touch more air than the standard gap.
      padding: const EdgeInsets.only(bottom: FilamentSpace.x1),
      child: Row(
        children: [
          MeshPathTriad(
            direct: live ? MeshPathState.winning : MeshPathState.unknown,
            cloudflare: _plane(status.cloudflare),
            tailscale: _plane(status.tailscale),
            height: 44,
            barWidth: 6,
            gap: 4,
          ),
          const SizedBox(width: FilamentSpace.x5),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status.nodeName,
                  style: theme.type.section,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: FilamentSpace.x2 - 2),
                live
                    ? const MeshStatusLine(
                        tone: MeshTone.signal,
                        label: 'On the mesh',
                        glow: true,
                      )
                    : const MeshStatusLine(
                        tone: MeshTone.neutral,
                        label: 'Was on the mesh',
                        hollow: true,
                      ),
              ],
            ),
          ),
          const SizedBox(width: FilamentSpace.x5),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Rolls to its new reading like a meter; it never blinks.
              // A tighter gap than the default: one space of 20px mono is
              // already a wide one next to a 44px number.
              MeshTickingMeasure(
                value: median,
                format: msParts,
                style: headline,
                gap: 2,
              ),
              const SizedBox(height: FilamentSpace.x1),
              Text(
                median == null
                    ? 'No round trip yet'
                    : 'Median round trip to ${countOf(peers.length, 'peer')}',
                style: theme.type.label,
              ),
            ],
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
// running
// ---------------------------------------------------------------------------

/// Address, subnet, uptime, peers — this Mac's short facts, as a row of tiles
/// rather than a form.
///
/// They float on the page like the hero above them: a tile row reads at a
/// glance, and a box around it would only say "these four things belong
/// together", which the row already says.
class _Facts extends StatelessWidget {
  const _Facts({required this.status, required this.daemon});

  final StatusReport status;
  final DaemonStore daemon;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _tiles(context, status),
        const SizedBox(height: FilamentSpace.x2),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            'Updated ${formatAgo(daemon.lastSuccess)}',
            style: theme.type.small,
          ),
        ),
      ],
    );
  }

  static Widget _tiles(BuildContext context, StatusReport status) {
    final theme = FilamentTheme.of(context);
    final uptime = formatUptimeSecs(status.uptimeSecs);
    return MeshStatRow([
      MeshStatTile(
        label: 'Address',
        child: MeshCopyable(status.virtualIp, style: theme.type.stat),
      ),
      MeshStatTile(
        label: 'Range',
        child: MeshCopyable(status.subnet, style: theme.type.stat),
      ),
      MeshStatTile(
        label: 'Running for',
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

/// One plane: up or down with its address and the engine's own detail string,
/// or the fact that your network has no credentials for it.
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
      actions: [if (report == null) const MeshBadge('Not set up')],
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
                    label: 'Not set up',
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
                  ? 'Your network has no ${_brand(name)} credentials yet'
                  : (report.detail.isEmpty ? '—' : report.detail),
              // The engine's own words, never rewritten.
              style: theme.type.mono.copyWith(color: tokens.textDim),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// stopped
// ---------------------------------------------------------------------------

/// The last picture we were given, dimmed and said to be the last one.
///
/// Everything the running screen shows, at 0.6 and inside a panel: a header, a
/// badge and a footer are what can say "these are not live any more", and a
/// tile floating on the page has nowhere to say it.
class _Stale extends StatelessWidget {
  const _Stale({required this.status, required this.daemon});

  final StatusReport status;
  final DaemonStore daemon;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    return MeshPanel(
      title: 'This Mac',
      subtitle: 'The last readings before the engine stopped',
      actions: const [MeshBadge('Not live', tone: MeshTone.caution)],
      footer: Text(
        'Last updated ${formatAgo(daemon.lastSuccess)}',
        style: theme.type.small,
      ),
      child: Opacity(
        opacity: 0.6,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Hero(status: status, peers: daemon.peers, live: false),
            const SizedBox(height: FilamentSpace.x5),
            _Facts._tiles(context, status),
          ],
        ),
      ),
    );
  }
}

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
          Text('Reaching the mesh engine', style: theme.type.bodyDim),
        ],
      ),
    );
  }
}

/// The engine is not answering and never told us anything worth keeping. The
/// banner above has the news and the button; this is only here so the screen is
/// not an empty column.
class _WaitingPanel extends StatelessWidget {
  const _WaitingPanel();

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    return MeshPanel(
      child: Text(
        'Nothing to show while the mesh engine is stopped.',
        style: theme.type.bodyDim,
      ),
    );
  }
}

/// Running, joined to nothing. The window is about to become the setup flow;
/// one line is the whole of it.
class _LeftPanel extends StatelessWidget {
  const _LeftPanel();

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    return MeshPanel(
      child: Text(
        'This Mac is not on a network any more.',
        style: theme.type.bodyDim,
      ),
    );
  }
}
