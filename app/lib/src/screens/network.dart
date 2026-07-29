/// Network — everything the control plane owns.
///
/// Requires a control plane session and says so plainly when there is not one:
/// the sign-in form takes the screen over rather than greying panels out. With
/// a session it is the account, the subnet and its address budget, the two
/// backhaul credential forms, enrollment key minting, and the node roster.
///
/// Nothing here polls. The store fetches when this screen becomes visible and
/// every 30s while it stays visible; the shell drives that.
library;

import 'package:flutter/widgets.dart';

import '../data/cp_client.dart';
import '../data/cp_models.dart';
import '../icons/mesh_icons.dart';
import '../kit/badge.dart';
import '../kit/button.dart';
import '../kit/copyable.dart';
import '../kit/dialog.dart';
import '../kit/panel.dart';
import '../kit/scaffold.dart';
import '../kit/stat_tile.dart';
import '../kit/status_dot.dart';
import '../kit/table.dart';
import '../kit/text_field.dart';
import '../kit/toast.dart';
import '../state/app_state.dart';
import '../state/network_store.dart';
import '../state/session_store.dart';
import '../theme/theme.dart';
import '../util/format.dart';
import 'onboarding.dart';

class NetworkScreen extends StatelessWidget {
  const NetworkScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    return ListenableBuilder(
      listenable: Listenable.merge([app.session, app.network]),
      builder: (context, _) => _Body(session: app.session, store: app.network),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.session, required this.store});

  final SessionStore session;
  final NetworkStore store;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);

    // Before the config file has been read, saying "not logged in" would be a
    // guess. Say nothing instead; it lasts one frame or two.
    if (!session.loaded) {
      return MeshScreen(
        title: 'Network',
        subtitle: 'Control plane management',
        children: [
          MeshPanel(
            child: Row(
              children: [
                const MeshSpinner(size: 13),
                const SizedBox(width: FilamentSpace.x2),
                Text('Reading the stored session', style: theme.type.bodyDim),
              ],
            ),
          ),
        ],
      );
    }

    if (!session.hasSession) return _signedOut(context, theme);
    return _signedIn(context, theme);
  }

  // -- signed out ---------------------------------------------------------

  Widget _signedOut(BuildContext context, FilamentTheme theme) {
    return MeshScreen(
      title: 'Network',
      subtitle: 'Control plane management',
      children: [
        MeshAuthPanel(onAuthenticated: () => store.refresh()),
        MeshPanel(
          title: 'What a session is for',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'The control plane holds the subnet, the backhaul credentials '
                'and the enrollment keys. The daemon on this machine only ever '
                'needs a key, so a node can run perfectly well without anyone '
                'signing in here.',
                style: theme.type.bodyDim,
              ),
              const SizedBox(height: FilamentSpace.x4),
              Text(
                'This is the same session meshctl uses; signing in here signs '
                'in there.',
                style: theme.type.small,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // -- signed in ----------------------------------------------------------

  Widget _signedIn(BuildContext context, FilamentTheme theme) {
    final view = store.network;
    final fetched = store.fetchedAt;
    final failure = store.error;
    final stale = failure is CpApiException && failure.unauthorized;

    return MeshScreen(
      title: 'Network',
      subtitle: 'Control plane management',
      actions: [
        if (fetched != null)
          Padding(
            padding: const EdgeInsets.only(right: FilamentSpace.x1),
            child: Text(
              'Updated ${formatAgo(fetched)}',
              style: theme.type.small,
            ),
          ),
        MeshIconButton(
          glyph: MeshGlyph.refresh,
          tooltip: 'Fetch now',
          busy: store.loading,
          onPressed: () => store.refresh(),
        ),
      ],
      children: [
        if (failure != null)
          MeshPanel(
            title: 'The control plane did not answer',
            accent: theme.tokens.alarm,
            child: MeshErrorNote(
              failure.message,
              hint: stale
                  ? 'The session is no longer accepted; sign out on the '
                        'Settings screen and sign in again'
                  : null,
            ),
          ),
        if (view == null)
          MeshPanel(
            child: Row(
              children: [
                if (store.loading) ...[
                  const MeshSpinner(size: 13),
                  const SizedBox(width: FilamentSpace.x2),
                ],
                Text(
                  store.loading
                      ? 'Asking the control plane'
                      : 'Nothing fetched yet',
                  style: theme.type.bodyDim,
                ),
                const Spacer(),
                if (!store.loading)
                  MeshButton(
                    label: 'Try again',
                    onPressed: () => store.refresh(),
                  ),
              ],
            ),
          )
        else ...[
          _account(context, theme, view),
          _subnet(context, theme, view),
          // Two credential cards, one plane each: they are the same shape and
          // read as a pair, so they share a row while the window allows it.
          MeshPanelRow(
            children: [
              _backhaul(
                context,
                theme,
                title: 'Cloudflare',
                status: view.cloudflare,
                form: _CloudflareForm(
                  key: const ValueKey('cloudflare-form'),
                  store: store,
                ),
              ),
              _backhaul(
                context,
                theme,
                title: 'Tailscale',
                status: view.tailscale,
                form: _TailscaleForm(
                  key: const ValueKey('tailscale-form'),
                  store: store,
                ),
              ),
            ],
          ),
          _keys(context, theme),
          _nodes(context, theme),
        ],
      ],
    );
  }

  Widget _account(BuildContext context, FilamentTheme theme, NetworkView view) {
    return MeshPanel(
      title: 'Account',
      child: MeshFacts([
        MeshFact(
          label: 'Email',
          child: Text(view.email, style: theme.type.mono),
        ),
        MeshFact(
          label: 'Account',
          child: MeshCopyable(
            view.accountId,
            display: shortId(view.accountId, head: 8, tail: 6),
          ),
        ),
        MeshFact(
          label: 'Control plane',
          child: Row(
            children: [
              Flexible(child: MeshCopyable(session.cpUrl.url)),
              const SizedBox(width: FilamentSpace.x2),
              MeshBadge(session.cpUrl.source.label),
            ],
          ),
        ),
      ]),
    );
  }

  /// The address budget as instrument tiles, not a form: four short readings
  /// the eye lands on before it reads anything else on the screen.
  Widget _subnet(BuildContext context, FilamentTheme theme, NetworkView view) {
    final tiles = <Widget>[
      MeshStatTile(
        label: 'Range',
        // Resolves its own style, so it is told which step it sits on.
        child: MeshCopyable(view.subnet, style: theme.type.stat),
      ),
      MeshStatTile(
        label: 'Addresses used',
        child: MeshTickingMeasure(
          value: view.addressesUsed.toDouble(),
          format: countParts,
          style: theme.type.stat,
        ),
      ),
      MeshStatTile(
        label: 'Addresses free',
        child: MeshTickingMeasure(
          value: view.addressesAvailable.toDouble(),
          format: countParts,
          style: theme.type.stat,
        ),
      ),
      MeshStatTile(
        label: 'Nodes',
        child: MeshTickingMeasure(
          value: view.nodeCount.toDouble(),
          format: countParts,
          style: theme.type.stat,
        ),
      ),
    ];

    return MeshPanel(
      title: 'Subnet',
      subtitle: 'The address space the control plane hands out',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              // Four across while each tile can still hold its reading; below
              // that they fold into two rows of two rather than shrinking into
              // a row of ellipses.
              if (constraints.maxWidth >= 640) return MeshStatRow(tiles);
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  MeshStatRow(tiles.sublist(0, 2)),
                  const SizedBox(height: FilamentSpace.x3),
                  MeshStatRow(tiles.sublist(2)),
                ],
              );
            },
          ),
          const SizedBox(height: FilamentSpace.x5),
          const MeshDivider(),
          const SizedBox(height: FilamentSpace.x5),
          if (view.subnetChangeable)
            _SubnetForm(
              key: const ValueKey('subnet-form'),
              store: store,
              current: view.subnet,
            )
          else
            Text(
              'The subnet is fixed once a node is enrolled; the control plane '
              'refuses to move it out from under an address that is in use.',
              style: theme.type.small,
            ),
        ],
      ),
    );
  }

  Widget _backhaul(
    BuildContext context,
    FilamentTheme theme, {
    required String title,
    required BackhaulStatus status,
    required Widget form,
  }) {
    return MeshPanel(
      title: title,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The state is the card's reading, so it is set at emphasis rather
          // than repeated as a badge in the header next to it.
          MeshStatusLine(
            tone: status.configured ? MeshTone.signal : MeshTone.neutral,
            label: status.configured ? 'Ready' : 'Not configured',
            detail: status.configured && status.detail.isNotEmpty
                ? status.detail
                : null,
            glow: status.configured,
            hollow: !status.configured,
            style: theme.type.emphasis,
          ),
          const SizedBox(height: FilamentSpace.x5),
          const MeshDivider(),
          const SizedBox(height: FilamentSpace.x5),
          form,
        ],
      ),
    );
  }

  Widget _keys(BuildContext context, FilamentTheme theme) {
    final key = store.lastKey;
    final tokens = theme.tokens;

    return MeshPanel(
      title: 'Enrollment keys',
      subtitle: 'One key enrolls one node',
      actions: [
        MeshButton.primary(
          label: 'Mint a key',
          glyph: MeshGlyph.key,
          busy: store.mintingKey,
          onPressed: () => store.mintEnrollmentKey(),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (key == null)
            Text(
              'A key is shown here once, when it is minted. Hand it to a node '
              'with `meshctl join <key>`, or paste it on the Overview screen.',
              style: theme.type.bodyDim,
            )
          else ...[
            DecoratedBox(
              decoration: BoxDecoration(
                color: tokens.surfaceHigh,
                border: Border.all(color: tokens.hairline),
                borderRadius: BorderRadius.circular(FilamentRadius.control),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: FilamentSpace.x3 + 2,
                  vertical: FilamentSpace.x3,
                ),
                child: MeshCopyable(key.key, style: theme.type.monoEmphasis),
              ),
            ),
            const SizedBox(height: FilamentSpace.x4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: MeshField(
                    label: 'Expires',
                    child: _expiry(theme, key.expiresAt),
                  ),
                ),
                const SizedBox(width: FilamentSpace.x3),
                MeshButton.ghost(
                  label: 'Forget it',
                  tooltip: 'Clear the key from the screen',
                  onPressed: store.clearKey,
                ),
              ],
            ),
            const SizedBox(height: FilamentSpace.x3),
            Text(
              'This is the only time the control plane shows it.',
              style: theme.type.small,
            ),
          ],
          if (store.keyError != null) ...[
            const SizedBox(height: FilamentSpace.x3),
            MeshErrorNote(store.keyError!.message),
          ],
        ],
      ),
    );
  }

  /// The control plane's own RFC 3339 string, plus how long that is from now
  /// when it parses. The string is what it said; the badge is the useful part.
  Widget _expiry(FilamentTheme theme, String raw) {
    final at = DateTime.tryParse(raw);
    if (at == null) {
      return Text(
        raw.isEmpty ? 'Not stated' : raw,
        style: theme.type.monoSmall,
      );
    }
    final until = formatUntil(at);
    return Row(
      children: [
        Flexible(
          child: Text(
            formatDateTime(at),
            style: theme.type.mono,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: FilamentSpace.x2),
        MeshBadge(
          until,
          tone: until == 'expired' ? MeshTone.alarm : MeshTone.caution,
        ),
      ],
    );
  }

  Widget _nodes(BuildContext context, FilamentTheme theme) {
    final nodes = store.nodes ?? const <NodeView>[];

    return MeshPanel(
      title: 'Nodes',
      actions: [
        if (store.nodes != null)
          MeshBadge(countOf(nodes.length, 'node'), mono: true),
      ],
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MeshTable(
            columns: const [
              MeshColumn('State', width: 74),
              MeshColumn('Virtual IP', width: 116),
              MeshColumn('Name', flex: 3),
              MeshColumn('Last seen', width: 104),
              MeshColumn('Node ID', flex: 3),
              MeshColumn('', width: 28),
            ],
            empty: Text(
              'No nodes enrolled yet; mint a key and start a meshd.',
              style: theme.type.bodyDim,
            ),
            rows: [
              for (final node in nodes)
                MeshTableRow(
                  key: node.nodeId,
                  cells: [
                    MeshStatusLine(
                      tone: node.online ? MeshTone.signal : MeshTone.alarm,
                      label: node.online ? 'Up' : 'Down',
                      glow: node.online,
                      style: theme.type.body,
                    ),
                    Text(
                      node.virtualIp.isEmpty ? '—' : node.virtualIp,
                      style: theme.type.mono,
                    ),
                    Text(
                      node.name.isEmpty ? '—' : node.name,
                      style: theme.type.body,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(_lastSeen(node.lastSeen), style: theme.type.monoSmall),
                    MeshCopyable(
                      node.nodeId,
                      display: shortId(node.nodeId, head: 8, tail: 6),
                      style: theme.type.monoSmall,
                      showIcon: false,
                    ),
                    MeshIconButton(
                      glyph: MeshGlyph.close,
                      size: 22,
                      tone: MeshTone.alarm,
                      tooltip: 'Remove this node',
                      busy: store.isRemoving(node.nodeId),
                      onPressed: () => _remove(context, node),
                    ),
                  ],
                ),
            ],
          ),
          if (store.nodeError != null)
            Padding(
              padding: const EdgeInsets.all(FilamentSpace.panel),
              child: MeshErrorNote(store.nodeError!.message),
            ),
        ],
      ),
    );
  }

  /// meshctl prints the last-seen string exactly as the control plane sent it.
  /// We do the same when it does not parse, and say it in the app's own terms
  /// when it does.
  static String _lastSeen(String? raw) {
    if (raw == null || raw.isEmpty) return 'Never';
    final at = DateTime.tryParse(raw);
    return at == null ? raw : formatAgo(at);
  }

  Future<void> _remove(BuildContext context, NodeView node) async {
    final name = node.name.isEmpty ? shortId(node.nodeId) : node.name;
    final confirmed = await MeshConfirmDialog.ask(
      context,
      title: 'Remove $name?',
      message:
          'The node is deregistered and its address is free for the next '
          'node. It can rejoin with a new enrollment key.',
      confirmLabel: 'Remove',
      onConfirm: () async {
        final done = await store.removeNode(node.nodeId);
        if (!done) {
          throw store.nodeError ??
              const CpProtocolException('The node was not removed');
        }
      },
    );
    if (!confirmed || !context.mounted) return;
    MeshToast.show(
      context,
      'Removed; its address is free for the next node',
      tone: MeshTone.signal,
    );
  }
}

// ---------------------------------------------------------------------------
// forms
//
// Each keeps its own controllers and its own busy/error from the store, so a
// failed backhaul save never blanks the panel next to it. All three are given
// a ValueKey by the caller: the panel list above changes length when an error
// panel appears, and an unkeyed form would lose what was typed into it.
// ---------------------------------------------------------------------------

class _SubnetForm extends StatefulWidget {
  const _SubnetForm({required this.store, required this.current, super.key});

  final NetworkStore store;
  final String current;

  @override
  State<_SubnetForm> createState() => _SubnetFormState();
}

class _SubnetFormState extends State<_SubnetForm> {
  late final TextEditingController _subnet = TextEditingController(
    text: widget.current,
  );

  @override
  void dispose() {
    _subnet.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final value = _subnet.text.trim();
    if (value.isEmpty || widget.store.savingSubnet) return;
    final ok = await widget.store.setSubnet(value);
    if (!ok || !mounted) return;
    MeshToast.show(context, 'Subnet is now $value', tone: MeshTone.signal);
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            SizedBox(
              width: 220,
              child: MeshTextField(
                controller: _subnet,
                label: 'Change the subnet',
                placeholder: '10.201.0.0/16',
                mono: true,
                enabled: !store.savingSubnet,
                onSubmitted: (_) => _save(),
              ),
            ),
            const SizedBox(width: FilamentSpace.x3),
            MeshButton(
              label: 'Set subnet',
              busy: store.savingSubnet,
              onPressed: _save,
            ),
          ],
        ),
        const SizedBox(height: FilamentSpace.x3),
        Text(
          'Possible only while no node is enrolled.',
          style: FilamentTheme.typeOf(context).small,
        ),
        if (store.subnetError != null) ...[
          const SizedBox(height: FilamentSpace.x3),
          MeshErrorNote(store.subnetError!.message),
        ],
      ],
    );
  }
}

class _CloudflareForm extends StatefulWidget {
  const _CloudflareForm({required this.store, super.key});

  final NetworkStore store;

  @override
  State<_CloudflareForm> createState() => _CloudflareFormState();
}

class _CloudflareFormState extends State<_CloudflareForm> {
  final TextEditingController _token = TextEditingController();
  final TextEditingController _account = TextEditingController();
  String? _localError;

  @override
  void dispose() {
    _token.dispose();
    _account.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (widget.store.savingCloudflare) return;
    if (_token.text.trim().isEmpty || _account.text.trim().isEmpty) {
      setState(
        () => _localError = 'Both the API token and the account ID are needed',
      );
      return;
    }
    setState(() => _localError = null);
    final ok = await widget.store.setCloudflare(
      apiToken: _token.text.trim(),
      accountId: _account.text.trim(),
    );
    if (!mounted) return;
    if (!ok) return;
    // Credentials do not linger in a controller once the control plane has
    // them; it never gives them back and we never need them again.
    _token.clear();
    _account.clear();
    MeshToast.show(context, 'Cloudflare is ready', tone: MeshTone.signal);
  }

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final store = widget.store;
    final busy = store.savingCloudflare;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MeshTextField(
                  controller: _token,
                  label: 'API token',
                  secret: true,
                  mono: true,
                  enabled: !busy,
                  onSubmitted: (_) => _save(),
                ),
                const SizedBox(height: FilamentSpace.x4),
                MeshTextField(
                  controller: _account,
                  label: 'Account ID',
                  secret: true,
                  mono: true,
                  enabled: !busy,
                  onSubmitted: (_) => _save(),
                ),
              ],
            ),
          ),
        ),
        if (_localError != null || store.cloudflareError != null) ...[
          const SizedBox(height: FilamentSpace.x3),
          MeshErrorNote(_localError ?? store.cloudflareError!.message),
        ],
        const SizedBox(height: FilamentSpace.x5),
        Row(
          children: [
            MeshButton(label: 'Save credentials', busy: busy, onPressed: _save),
            const SizedBox(width: FilamentSpace.x3),
            Flexible(
              child: Text(
                busy
                    ? 'Provisioning the Zero Trust org, this takes a few '
                          'seconds'
                    : 'Provisioning the Zero Trust org takes a few seconds',
                style: theme.type.small,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _TailscaleForm extends StatefulWidget {
  const _TailscaleForm({required this.store, super.key});

  final NetworkStore store;

  @override
  State<_TailscaleForm> createState() => _TailscaleFormState();
}

class _TailscaleFormState extends State<_TailscaleForm> {
  final TextEditingController _token = TextEditingController();
  String? _localError;

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (widget.store.savingTailscale) return;
    if (_token.text.trim().isEmpty) {
      setState(() => _localError = 'An API token is needed');
      return;
    }
    setState(() => _localError = null);
    final ok = await widget.store.setTailscale(apiToken: _token.text.trim());
    if (!mounted) return;
    if (!ok) return;
    _token.clear();
    MeshToast.show(context, 'Tailscale is ready', tone: MeshTone.signal);
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final busy = store.savingTailscale;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: MeshTextField(
              controller: _token,
              label: 'API token',
              secret: true,
              mono: true,
              enabled: !busy,
              onSubmitted: (_) => _save(),
            ),
          ),
        ),
        if (_localError != null || store.tailscaleError != null) ...[
          const SizedBox(height: FilamentSpace.x3),
          MeshErrorNote(_localError ?? store.tailscaleError!.message),
        ],
        const SizedBox(height: FilamentSpace.x5),
        Row(
          children: [
            MeshButton(label: 'Save credentials', busy: busy, onPressed: _save),
          ],
        ),
      ],
    );
  }
}
