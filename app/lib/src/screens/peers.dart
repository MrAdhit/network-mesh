/// Peers — the table, and what one row says when you open it.
///
/// The row is the glance: name, address, triad, the winning path's ewma and
/// the last two minutes of it as a sparkline. Opening a row is the second
/// look: every path the engine reports, with its own history, and a ping that
/// probes all of them and prints what the CLI prints.
///
/// A primary surface, so it speaks outcomes: "the mesh engine", never the
/// program's name and never its socket. The one thing quoted verbatim is what
/// came off the wire, and it sits under a headline in our own words.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../data/ipc_protocol.dart';
import '../icons/mesh_icons.dart';
import '../kit/badge.dart';
import '../kit/button.dart';
import '../kit/copyable.dart';
import '../kit/panel.dart';
import '../kit/path_triad.dart';
import '../kit/scaffold.dart';
import '../kit/sparkline.dart';
import '../kit/status_dot.dart';
import '../kit/table.dart';
import '../state/app_state.dart';
import '../state/daemon_store.dart';
import '../theme/theme.dart';
import '../util/format.dart';

class PeersScreen extends StatelessWidget {
  const PeersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final daemon = AppScope.daemonOf(context);
    return ListenableBuilder(
      listenable: daemon,
      builder: (context, _) {
        final peers = daemon.peers;
        return MeshScreen(
          title: 'Peers',
          subtitle: daemon.reachable && daemon.enrolled
              ? '${countOf(peers.length, 'peer')} on your network'
              : 'Every machine this Mac can reach, and how',
          actions: [
            MeshAsyncIconButton(
              glyph: MeshGlyph.refresh,
              tooltip: 'Check now',
              action: daemon.refreshNow,
            ),
          ],
          children: [_PeerPanel(daemon: daemon)],
        );
      },
    );
  }
}

class _PeerPanel extends StatelessWidget {
  const _PeerPanel({required this.daemon});

  final DaemonStore daemon;

  static const List<MeshColumn> _columns = [
    MeshColumn('Peer', flex: 3),
    MeshColumn('Address', flex: 3),
    MeshColumn('Paths', width: 46),
    MeshColumn('RTT', width: 96, align: Alignment.centerRight),
    MeshColumn('History', width: 124, align: Alignment.centerRight),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final stale = !daemon.reachable;
    final peers = daemon.peers;

    return MeshPanel(
      title: 'Peer table',
      subtitle: stale
          ? null
          : 'Updated every ${formatSpan(daemon.effectiveInterval)}',
      actions: [if (stale) const MeshBadge('Not live', tone: MeshTone.caution)],
      padding: EdgeInsets.zero,
      footer: stale && daemon.error != null
          ? MeshWireError(
              headline: 'The mesh engine stopped',
              detail: daemon.error!.message,
            )
          : null,
      // The last good table stays on screen while the engine is away; the
      // badge and the footer are what say it is no longer current.
      child: Opacity(
        opacity: stale ? 0.55 : 1,
        child: MeshTable(
          columns: _columns,
          empty: Text(_emptyLine(daemon), style: theme.type.bodyDim),
          rows: [
            for (final peer in peers)
              MeshTableRow(
                key: peer.name,
                cells: _cells(context, peer),
                expanded: (context) =>
                    _PeerDetail(peerName: peer.name, daemon: daemon),
              ),
          ],
        ),
      ),
    );
  }

  static String _emptyLine(DaemonStore daemon) {
    if (!daemon.reachable) return 'The mesh engine is stopped';
    if (!daemon.enrolled) return 'This Mac is not on a network';
    // What the CLI says, in the app's voice.
    return 'No peers known yet.';
  }

  List<Widget> _cells(BuildContext context, PeerReport peer) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;
    final best = peer.best;
    final up = best != null && best.up;
    final lossy = best != null && best.lossPct >= MeshPathState.lossyThreshold;

    return [
      Row(
        children: [
          MeshStatusDot(
            tone: up
                ? (lossy ? MeshTone.caution : MeshTone.signal)
                : MeshTone.alarm,
            size: 6,
            glow: up && !lossy,
          ),
          const SizedBox(width: FilamentSpace.x2),
          Flexible(
            child: Text(
              peer.name,
              style: theme.type.body,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      peer.virtualIp == null
          ? Text(
              'No address',
              style: theme.type.mono.copyWith(color: tokens.textFaint),
            )
          : MeshCopyable(peer.virtualIp!, showIcon: false),
      _triadFor(peer),
      // The reading outranks its 11px header by two steps, and rolls to its
      // next value rather than swapping.
      MeshTickingMeasure(
        value: up ? best.ewmaMs : null,
        format: msParts,
        style: theme.type.monoEmphasis,
        color: up ? (lossy ? tokens.caution : tokens.text) : tokens.textFaint,
      ),
      MeshSparkline(
        values: daemon.historyFor(peer.name),
        width: 112,
        height: 20,
      ),
    ];
  }

  static MeshPathTriad _triadFor(PeerReport peer) {
    MeshPathState state(String name) {
      final report = peer.path(name);
      if (report == null) return MeshPathState.unknown;
      return MeshPathState.from(
        up: report.up,
        winning: peer.bestPath == name,
        lossPct: report.lossPct,
      );
    }

    return MeshPathTriad(
      direct: state('direct'),
      cloudflare: state('cloudflare'),
      tailscale: state('tailscale'),
    );
  }
}

// ---------------------------------------------------------------------------
// the open row
// ---------------------------------------------------------------------------

/// Per-path statistics and the ping flow, for one peer.
///
/// Takes the peer's *name*, not its report: the row stays open across polls
/// and every one of them replaces the report object.
class _PeerDetail extends StatelessWidget {
  const _PeerDetail({required this.peerName, required this.daemon});

  final String peerName;
  final DaemonStore daemon;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    PeerReport? peer;
    for (final candidate in daemon.peers) {
      if (candidate.name == peerName) peer = candidate;
    }

    if (peer == null) {
      return Text(
        '$peerName is gone from the peer table',
        style: theme.type.bodyDim,
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PathTable(peer: peer, daemon: daemon),
        const SizedBox(height: FilamentSpace.x5),
        _PingSection(peerName: peerName, daemon: daemon),
      ],
    );
  }
}

/// One row per path the daemon reports, in triad order.
class _PathTable extends StatelessWidget {
  const _PathTable({required this.peer, required this.daemon});

  final PeerReport peer;
  final DaemonStore daemon;

  static const List<MeshColumn> _columns = [
    MeshColumn('Path', width: 92),
    MeshColumn('State', width: 58),
    MeshColumn('Last ms', width: 78, align: Alignment.centerRight),
    MeshColumn('EWMA ms', width: 78, align: Alignment.centerRight),
    MeshColumn('Sent', width: 54, align: Alignment.centerRight),
    MeshColumn('Recv', width: 54, align: Alignment.centerRight),
    MeshColumn('Loss %', width: 58, align: Alignment.centerRight),
    MeshColumn('History', flex: 1, align: Alignment.centerRight),
  ];

  /// Triad order first; anything the daemon invented after it.
  List<PathReport> get _ordered {
    final byName = {for (final p in peer.paths) p.path: p};
    return [
      for (final name in meshPathNames) ?byName[name],
      for (final report in peer.paths)
        if (!meshPathNames.contains(report.path)) report,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;

    // A nested box, not a panel: the same lit fill and hairline, no shade —
    // it is inside the page, not floating above it.
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: tokens.panelFill,
        border: Border.all(color: tokens.hairline),
        borderRadius: BorderRadius.circular(FilamentRadius.control),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(FilamentRadius.control - 1),
        child: MeshTable(
          columns: _columns,
          rowHeight: 32,
          empty: Text('No paths yet', style: theme.type.bodyDim),
          rows: [
            for (final path in _ordered)
              MeshTableRow(key: path.path, cells: _cells(context, path)),
          ],
        ),
      ),
    );
  }

  List<Widget> _cells(BuildContext context, PathReport path) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;
    final winning = peer.bestPath == path.path;
    final lossy = path.lossPct >= MeshPathState.lossyThreshold;

    return [
      Row(
        children: [
          Flexible(
            child: Text(
              path.path,
              style: theme.type.mono.copyWith(
                color: winning ? tokens.signal : tokens.text,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (winning) ...[
            const SizedBox(width: FilamentSpace.x1),
            Text('•', style: theme.type.mono.copyWith(color: tokens.signal)),
          ],
        ],
      ),
      MeshStatusLine(
        tone: path.up ? MeshTone.signal : MeshTone.alarm,
        label: path.up ? 'Up' : 'Down',
        glow: path.up && winning,
        style: theme.type.body,
      ),
      MeshTickingMeasure(
        value: path.lastRttMs,
        format: msParts,
        style: theme.type.mono,
      ),
      MeshTickingMeasure(
        value: path.ewmaMs,
        format: msParts,
        style: theme.type.mono,
      ),
      Text('${path.sent}', style: theme.type.mono),
      Text('${path.received}', style: theme.type.mono),
      MeshMeasure(
        percentParts(path.lossPct, decimals: 0),
        style: theme.type.mono,
        color: lossy ? tokens.caution : null,
      ),
      MeshSparkline(
        values: daemon.historyForPath(peer.name, path.path),
        width: 96,
        height: 18,
        color: path.up
            ? (lossy
                  ? tokens.caution
                  : (winning ? tokens.signal : tokens.signalDim))
            : tokens.alarm,
      ),
    ];
  }
}

// ---------------------------------------------------------------------------
// ping
// ---------------------------------------------------------------------------

/// Fire `ping {peer, count: 4}` and show what came back, the way the CLI shows
/// it: a line per probe, then min/avg/max per path, then the winner.
class _PingSection extends StatelessWidget {
  const _PingSection({required this.peerName, required this.daemon});

  final String peerName;
  final DaemonStore daemon;

  static const int _count = 4;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final busy = daemon.isPinging(peerName);
    final run = daemon.pingResult(peerName);
    final error = daemon.pingError(peerName);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            MeshButton(
              label: 'Ping',
              glyph: MeshGlyph.radar,
              busy: busy,
              onPressed: () => unawaited(daemon.ping(peerName, count: _count)),
            ),
            const SizedBox(width: FilamentSpace.x3),
            Expanded(
              child: Text(
                busy
                    ? 'Probing every path, $_count times each'
                    : '$_count probes on every path, separately',
                style: theme.type.small,
              ),
            ),
            if (run != null) ...[
              Text(formatAgo(run.at), style: theme.type.small),
              const SizedBox(width: FilamentSpace.x2),
              MeshButton.ghost(
                label: 'Clear',
                onPressed: () => daemon.clearPing(peerName),
              ),
            ],
          ],
        ),
        if (error != null) ...[
          const SizedBox(height: FilamentSpace.x4),
          MeshWireError(
            headline: "Couldn't ping $peerName",
            detail: error.message,
          ),
        ],
        if (run != null) ...[
          const SizedBox(height: FilamentSpace.x4),
          _PingResult(run: run),
        ],
      ],
    );
  }
}

class _PingResult extends StatelessWidget {
  const _PingResult({required this.run});

  final PingRun run;

  /// meshctl prints ping numbers at two decimals whatever their size, and this
  /// is the one place the app follows that rather than [formatMs].
  static String _fixed(double? ms) => ms == null ? '—' : ms.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;

    if (run.samples.isEmpty) {
      return _box(
        tokens,
        Text('No paths available to probe', style: theme.type.bodyDim),
      );
    }

    final winner = run.summary.winner;

    return _box(
      tokens,
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final sample in run.samples) _sampleLine(theme, sample),
          const SizedBox(height: FilamentSpace.x3),
          const MeshDivider(),
          const SizedBox(height: FilamentSpace.x3),
          for (final path in run.summary.paths) _summaryLine(theme, path),
          if (winner != null) ...[
            const SizedBox(height: FilamentSpace.x3),
            Text.rich(
              TextSpan(
                style: theme.type.mono,
                children: [
                  const TextSpan(text: 'Winner: '),
                  TextSpan(
                    text: winner.path,
                    style: theme.type.mono.copyWith(
                      color: tokens.signal,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  TextSpan(text: ' at ${_fixed(winner.avgMs)} '),
                  TextSpan(
                    text: 'ms',
                    style: theme.type.unitFor(theme.type.mono),
                  ),
                  const TextSpan(text: ' average'),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _box(FilamentTokens tokens, Widget child) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: tokens.panelFill,
      border: Border.all(color: tokens.hairline),
      borderRadius: BorderRadius.circular(FilamentRadius.control),
    ),
    child: Padding(
      padding: const EdgeInsets.all(FilamentSpace.x4),
      child: child,
    ),
  );

  Widget _sampleLine(FilamentTheme theme, PingSample sample) {
    final timedOut = sample.rttMs == null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(sample.path, style: theme.type.monoSmall),
          ),
          SizedBox(
            width: 56,
            child: Text('seq=${sample.seq}', style: theme.type.monoSmall),
          ),
          SizedBox(
            width: 88,
            child: Align(
              alignment: Alignment.centerRight,
              child: timedOut
                  ? Text(
                      'Timeout',
                      style: theme.type.monoSmall.copyWith(
                        color: theme.tokens.alarm,
                      ),
                    )
                  : MeshMeasure((
                      value: _fixed(sample.rttMs),
                      unit: 'ms',
                    ), style: theme.type.monoSmall),
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryLine(FilamentTheme theme, PingPathSummary path) {
    final tokens = theme.tokens;
    if (path.silent) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(width: 96, child: Text(path.path, style: theme.type.mono)),
            Text(
              'No replies (${path.sent} sent)',
              style: theme.type.mono.copyWith(color: tokens.alarm),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 96, child: Text(path.path, style: theme.type.mono)),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: theme.type.mono,
                children: [
                  TextSpan(text: 'min ${_fixed(path.minMs)} '),
                  TextSpan(text: 'avg ${_fixed(path.avgMs)} '),
                  TextSpan(text: 'max ${_fixed(path.maxMs)} '),
                  TextSpan(
                    text: 'ms',
                    style: theme.type.unitFor(theme.type.mono),
                  ),
                ],
              ),
            ),
          ),
          Text(
            '(${path.replied}/${path.sent} replied)',
            style: theme.type.small,
          ),
        ],
      ),
    );
  }
}
