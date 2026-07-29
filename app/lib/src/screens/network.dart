/// Network — the machines on it, the addresses it hands out, the keys that let
/// a machine in.
///
/// Signed out, it is one quiet card offering to sign in: a node-only user never
/// needs this screen, so it does not open with a form in their face. The form
/// arrives when they ask for it. Signed in it is the account, the address
/// budget, the two backhaul credential forms, key minting, and the roster.
///
/// A primary surface, so it speaks in the words the person uses: "your
/// network", never the control plane, and never where a URL came from — that
/// badge, and the URL under it, live in Settings.
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
        subtitle: 'Your network',
        children: [
          MeshPanel(
            child: Row(
              children: [
                const MeshSpinner(size: 13),
                const SizedBox(width: FilamentSpace.x2),
                Text('Looking for a sign-in', style: theme.type.bodyDim),
              ],
            ),
          ),
        ],
      );
    }

    if (!session.hasSession) return _signedOut(context);
    return _signedIn(context, theme);
  }

  // -- signed out ---------------------------------------------------------

  /// One card, and the form only if it is asked for.
  ///
  /// This Mac is already on the mesh; managing the network it joined is
  /// somebody's job and not necessarily this person's. Opening with a password
  /// field would say they are in the wrong state, which they are not.
  Widget _signedOut(BuildContext context) {
    return MeshScreen(
      title: 'Network',
      subtitle: 'Your network',
      children: [_SignInReveal(store: store)],
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
      subtitle: 'Your network',
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
            accent: theme.tokens.alarm,
            child: MeshWireError(
              headline: stale
                  ? 'Your sign-in is no longer accepted'
                  : 'Your network did not answer',
              detail: failure.message,
              hint: stale ? 'Sign out in Settings and sign in again.' : null,
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
                  store.loading ? 'Asking your network' : 'Nothing yet',
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
      title: 'Addresses',
      subtitle: 'The range your network hands out, one address per machine',
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
              'The range is fixed once a machine has joined; it cannot move '
              'out from under an address that is in use.',
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
      subtitle: 'One key lets one machine join',
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
              'A key is shown here once, when it is minted. Hand it to the '
              'machine you want on your network; it asks for one while it is '
              'being set up.',
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
            Text('This is the only time it is shown.', style: theme.type.small),
          ],
          if (store.keyError != null) ...[
            const SizedBox(height: FilamentSpace.x3),
            MeshWireError(
              headline: "Couldn't mint a key",
              detail: store.keyError!.message,
            ),
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
      title: 'Machines',
      actions: [
        if (store.nodes != null)
          MeshBadge(countOf(nodes.length, 'machine'), mono: true),
      ],
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MeshTable(
            columns: const [
              MeshColumn('State', width: 74),
              MeshColumn('Address', width: 116),
              MeshColumn('Name', flex: 3),
              MeshColumn('Last seen', width: 104),
              MeshColumn('ID', flex: 3),
              MeshColumn('', width: 28),
            ],
            empty: Text(
              'No machines yet. Mint a key and hand it to one.',
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
                      tooltip: 'Remove this machine',
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
              child: MeshWireError(
                headline: "Couldn't remove that machine",
                detail: store.nodeError!.message,
              ),
            ),
        ],
      ),
    );
  }

  /// The last-seen string exactly as it arrived when it does not parse, and in
  /// the app's own terms when it does.
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
          'It leaves your network and its address is free for the next '
          'machine. It can come back with a new enrollment key.',
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
      'Removed; its address is free for the next machine',
      tone: MeshTone.signal,
    );
  }
}

// ---------------------------------------------------------------------------
// the quiet card
// ---------------------------------------------------------------------------

/// "Sign in to manage your network", and the form only once it is asked for.
///
/// Progressive disclosure, and the reason for it: this Mac is already on the
/// mesh. Whoever runs the network signs in; everybody else never needs to, and
/// a password field they did not ask for tells them they are missing something
/// when they are not. Choosing to sign in swaps the card for the form on
/// `drift` — the same travel every other change of content in the app makes —
/// and the way out is a ghost button, not a dismissal.
class _SignInReveal extends StatefulWidget {
  const _SignInReveal({required this.store});

  final NetworkStore store;

  @override
  State<_SignInReveal> createState() => _SignInRevealState();
}

class _SignInRevealState extends State<_SignInReveal> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final tempo = FilamentMotion.drift(context);
    return AnimatedSize(
      duration: tempo.duration,
      curve: tempo.curve,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: tempo.duration,
        switchInCurve: tempo.curve,
        switchOutCurve: tempo.curve,
        child: _open ? _form(context) : _card(context),
      ),
    );
  }

  Widget _card(BuildContext context) {
    final theme = FilamentTheme.of(context);
    return MeshPanel(
      key: const ValueKey('signed-out-card'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: FilamentSpace.x5),
        child: Align(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Sign in to manage your network',
                  style: theme.type.section,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: FilamentSpace.x3),
                Text(
                  'Managing it means adding machines, taking them off, and '
                  'setting up the paths they reach each other on. This Mac '
                  'stays on the mesh either way.',
                  style: theme.type.bodyDim,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: FilamentSpace.x6),
                // A Row, not a Center: a kit button fills any bounded width it
                // is offered, and a 460px primary action is a banner.
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    MeshButton.primary(
                      label: 'Sign in',
                      onPressed: () => setState(() => _open = true),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _form(BuildContext context) {
    return Column(
      key: const ValueKey('signed-out-form'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MeshAuthPanel(onAuthenticated: () => widget.store.refresh()),
        const SizedBox(height: FilamentSpace.x3),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            MeshButton.ghost(
              label: 'Not now',
              onPressed: () => setState(() => _open = false),
            ),
          ],
        ),
      ],
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
    MeshToast.show(context, 'The range is now $value', tone: MeshTone.signal);
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
                label: 'Change the range',
                placeholder: '10.201.0.0/16',
                mono: true,
                enabled: !store.savingSubnet,
                onSubmitted: (_) => _save(),
              ),
            ),
            const SizedBox(width: FilamentSpace.x3),
            MeshButton(
              label: 'Set range',
              busy: store.savingSubnet,
              onPressed: _save,
            ),
          ],
        ),
        const SizedBox(height: FilamentSpace.x3),
        Text(
          'Possible only until the first machine joins.',
          style: FilamentTheme.typeOf(context).small,
        ),
        if (store.subnetError != null) ...[
          const SizedBox(height: FilamentSpace.x3),
          MeshWireError(
            headline: "Couldn't change the range",
            detail: store.subnetError!.message,
          ),
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
        if (_localError != null) ...[
          const SizedBox(height: FilamentSpace.x3),
          MeshErrorNote(_localError!),
        ] else if (store.cloudflareError != null) ...[
          const SizedBox(height: FilamentSpace.x3),
          MeshWireError(
            headline: "Couldn't set Cloudflare up",
            detail: store.cloudflareError!.message,
          ),
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
        if (_localError != null) ...[
          const SizedBox(height: FilamentSpace.x3),
          MeshErrorNote(_localError!),
        ] else if (store.tailscaleError != null) ...[
          const SizedBox(height: FilamentSpace.x3),
          MeshWireError(
            headline: "Couldn't set Tailscale up",
            detail: store.tailscaleError!.message,
          ),
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
