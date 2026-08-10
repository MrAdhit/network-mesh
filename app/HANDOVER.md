# Handover

You are about to rewrite this app yourself. This document is the engineering memory of
the version you are replacing: every decision that is not obvious from reading the code,
every protocol fact the app depends on, and every trap that cost real debugging time.
[DESIGN.md](DESIGN.md) is the design contract — visual language, motion, voice, UX
doctrine — and stays authoritative for whatever you build. This file is everything else.

## What the app is

The sole mesh manager for a desktop machine. It does four jobs: onboard a fresh machine
(fetch meshd from the control plane, install it under launchd, join a network), show the
live state (peers, paths, RTTs), manage the network (operator features behind a control
plane session), and keep the daemon current. It shares its session and its daemon with
meshctl — same config file, same socket, same launchd job, same install paths as
packaging/install.sh. Neither side ever gets a private variant of anything.

## Protocols — mirror these exactly, the Rust is the truth

**Daemon IPC** (`crates/mesh-core/src/ipc.rs`): newline-delimited JSON over a unix
socket. One connection per request: write one line, read one line. Requests are
serde-tagged `{"cmd": "status"}`, kebab-case: `status`, `peers`,
`ping {peer, count}`, `join {key}`, `leave` (`send` exists; the UI never exposes it).
Responses are externally tagged kebab-case: `{"status": {...}}`, `{"peers": [...]}`,
`{"ping": [...]}`, `{"joined": {...}}`, `{"left": {...}}`, `"ok"`, `{"error": "..."}`.
`StatusReport.enrolled` defaults to **true** when absent — an older daemon that only
answered when enrolled must not read as unenrolled. Socket path: `MESH_SOCKET` env,
else `$MESH_STATE_DIR/meshd.sock`, else `/var/lib/mesh/meshd.sock`. The daemon chmods
the socket 0666 at bind (that was our ipc.rs change; the trust model was already
"anyone who can open it can drive it"). Client timeouts: 5s, except ping at 30s —
the daemon probes every path serially before answering.

**Control plane** (`crates/mesh-core/src/cp.rs`, usage in `crates/meshctl/src/main.rs`):
HTTP JSON, session header `x-mesh-session`. `POST /v1/accounts` (signup),
`POST /v1/sessions` (login), `GET|PATCH /v1/network`, `PUT
/v1/network/backhauls/{cloudflare,tailscale}`, `POST /v1/enrollment-keys`,
`GET /v1/nodes`, `DELETE /v1/nodes/{id}`. Error bodies decode to `ApiError {error}` —
prefer that text over the status code, verbatim.

**Updates** (`crates/mesh-core/src/update.rs`): `GET /v1/updates/{target}` returns
`{target, binaries: [{name, sha256, size}]}`; the bytes at
`GET /v1/updates/{target}/{name}`. `{target}` is the Rust triple from `uname -m`
(arm64 → `aarch64-apple-darwin`). Two hard rules learned the hard way: verify the
sha256 **streaming, before install, delete on mismatch**, and cap received bytes at the
manifest's declared size mid-stream — the hash check only runs after the stream ends,
which on a runaway stream is after the disk fills. Refuse plain http to non-loopback.

**Session file**: `~/Library/Application Support/mesh/config.json` (macOS),
`$XDG_CONFIG_HOME|~/.config/mesh/config.json` (Linux), `%APPDATA%\mesh\config.json`
(Windows); `MESH_CONFIG` overrides. Shape: `{cp_url, session_token, account_id, email?,
expires_at?}`. The session only means something against the cp_url it was minted for.
Write atomically (tmp + rename), chmod 0600 — dart:io cannot set modes, shell out to
`/bin/chmod` and fail loudly. CP URL precedence everywhere, including what gets baked
into the launchd plist: `MESH_CP_URL` env → stored cp_url → compile-time default
(`String.fromEnvironment('MESH_CP_URL')`, the option_env mirror; CI passes
`--dart-define=MESH_CP_URL=https://mesh.mradhit.net`, same default as build.yml) →
`http://127.0.0.1:8080`. App prefs (`theme`, `poll_interval_ms`, `setup_complete`) live
in `ui.json` beside config.json — never add app keys to the CLI's file.

## The privileged model (macOS)

The app runs unprivileged forever. Everything that needs root is packed into **one
compound sh command per user action** and run through
`osascript -e 'do shell script "…" with administrator privileges'` — one password
prompt per intent, never two. Root destinations are compile-time constants
(`/usr/local/bin/meshd`, `/Library/LaunchDaemons/net.mesh.meshd.plist`, label
`net.mesh.meshd`, log `/var/log/meshd.log`) — byte-compatible with install.sh's
`start_launchd()`, and our test proved it by executing install.sh's actual heredoc and
comparing bytes. Keep that test. Only two variables ever enter the command: staged file
paths the app chose (single-quote for sh: `'\''`) and the CP URL (validated as a URL,
rejected outright if it contains quotes, backslashes, angle brackets, whitespace, or
control chars — then it goes into the plist, not the shell). The whole command is then
AppleScript-escaped (backslash first, then quote). Compose in that order.

Flow shapes: install = download+verify as user → `mkdir -p` + `install -m 0755` binary +
`install -m 0644` plist + `{ bootout || true; }` + `bootstrap` (brace the bootout so its
`|| true` cannot excuse a failed install; bootstrap of an already-loaded label is an
error, which is why bootout comes first). Update = swap binary + `kickstart -k` (the job
definition didn't change; a kickstart is a shorter outage than bootout/bootstrap). Stop =
`bootout`. Start = `bootstrap`. A dismissed prompt is exit -128 / "User canceled" — it is
a cancellation, not an error; show nothing. Known gap: update does not rewrite the plist,
so a changed CP URL only lands on reinstall.

`launchctl print system/net.mesh.meshd` works unprivileged (exit 0 loaded, 113 absent) —
that is how Settings knows the service state without root. The staleness recheck marker
must not be shared with meshctl's (`mesh-app-update-check`, not `mesh-update-check`) or
the app silently suppresses the CLI's update notice for six hours.

## The state model that survived contact

Stores are plain ChangeNotifiers behind one InheritedNotifier scope; no framework, no
codegen; `http` is the only dependency. The socket is the truth, disk is a hint:
`reachable` comes from polling (2s, backing off 5s while down), `installed` from the
binary existing, `serviceLoaded` from launchctl — and precedence in the manager state is
busy > updateAvailable > running > notInstalled > installedStopped, with the booleans
exposed separately because updateAvailable masks running. Keep the last good
status/peers across failed polls and mark them stale — flapping must not empty the peer
table. Nothing may animate on an identical poll: give every spring/tween a no-op path
when the target is unchanged, and keep RTT history in ring buffers (120 deep) fed only
by real polls. Poll only while the window is visible (lifecycle hidden/paused stops it).
Coalesce download-progress notifications to ~30ms or a fast transfer becomes a rebuild
storm the moment frames actually paint.

**The 14GB lesson**, in full: `IOSink.add()` is a queue with no bottom, and an
`await for` loop that hashes and adds without ever awaiting starves the event loop —
no frames paint (progress freezes at 0) and the file writes never drain (bytes pile up
in memory to the size of the transfer; a leftover fixture run reached ~14GB and hung
the laptop). The fix is one awaited `sink.flush()` every 256KiB: it is real disk
backpressure, it pauses the socket subscription through the stream chain, and the pause
is the event-loop turn where the window paints. One await, three jobs. Any rewrite of
the download loop must keep all three.

## Routing and the wizard

One derived decision at boot, latched once `bootSettled` (prefs loaded + first poll
answered + disk inspected): on the mesh or previously set up → dashboard; else wizard at
the derived stage. `setup_complete` in ui.json flips true at arrival and false on leave
(the danger zone must reset it or a left machine lands on an empty dashboard). The latch
is one-directional in-session — the wizard is never yanked out from under the user by a
state change; the dashboard can become the wizard again only through the leave path.
Stage derivation: no daemon platform → engine (says so, stops); socket answers →
enrolled ? arrival : network; else installed ? engine : welcome. Welcome appears only
when nothing at all is set up. Stages complete themselves by watching the daemon —
the socket answering finishes the engine stage, enrolled finishes the network stage;
no "continue" buttons. Forward-only: an engine dying mid-join does not yank the screen
back; the join button says so in the daemon's words if pressed.

Engine stage: the download starts on entry, not under a button — but "entry" is the
first time the stage is *seen* (TickerMode enabled), because the switcher builds all
stages up front with hidden ones muted. The one button does only what macOS forces
(the password), labeled with exactly that. Two traps here: the entry hook fires its
store call in a post-frame callback (notifying mid-build marks the ancestor dirty while
building), and **post-frame callbacks never run in a window macOS is not painting** —
an unfocused/hidden window gets no frames, so headless tests must schedule frames by
hand. That one cost hours twice.

Network stage: two cards, one decision. Key path: paste, join, done. Operator path:
sign in (or an already-stored session skips the form), then one button mints the key
and joins in a single chained action. The signup subnet field survives for a reason:
drop it and an operator who onboards through the wizard can never choose their range —
the control plane refuses subnet changes once any node is enrolled.

## Cross-platform

One seam answers every platform question (`HostPlatform`, assignable static for tests,
plus `managesDaemon` / `runsDaemon` / `hasUnixSocket` and the copy noun `thisMachine`).
Rules that came out of the audit: gate at the fork that spawns the process, not at the
caller (launchctl was reachable one level too deep); derive unsupported-copy from the
injected platform, not `Platform.isX`, or tests lie; Windows routes straight to the
engine stage's not-yet sentence and **never polls** (it was re-dialing a doomed named
pipe every 5s forever — one settle call, then stop); Linux gets the install.sh
one-liner and the stage advances itself when the socket appears. "this Mac" is copy —
it ships through `thisMachine` so Linux says "this machine". Verified only at
widget/store level: no Linux or Windows toolchain has ever built this, no real named
pipe has ever been dialed, nobody has watched install.sh land while the Linux stage
waits. Budget real machine time for that.

## Filament implementation traps (the code side of DESIGN.md)

- **No Material anywhere.** WidgetsApp root. Text editing needs no material import:
  `EditableText` + `TextSelectionGestureDetectorBuilder` + `emptyTextSelectionControls`,
  with `contextMenuBuilder: null` to dodge the Material toolbar.
- **MeshButton fills any bounded width** — its AnimatedContainer has
  `alignment: center`, and a childless Align expands into whatever bound it gets. In a
  Row it shrink-wraps (unbounded width); in a Wrap or stretch-Column it becomes a
  full-width bar — a Wrap hands children `maxWidth` bounds, so a Wrap of MeshButtons is
  four stacked bars. Fix at call sites with Row or IntrinsicWidth, or redesign the
  button in the rewrite; this footgun fired three separate times.
- **A childless painted box under loose constraints lays out at zero size.**
  `Align → FractionallySizedBox(widthFactor only) → DecoratedBox` renders your progress
  fill at the right width and **zero height**, invisible at every fraction — text
  readouts keep working, so it looks like "the bar doesn't move". Pixel-sample renders
  in widget tests (decode the PNG, count lit pixels); eyeball-only review missed this.
- **Screen switching**: IndexedStack keeps hidden screens ticking
  (`maintainAnimation: true`) and lets focus traverse into them. The replacement keeps
  every child alive but wraps each in the same-shaped
  ExcludeFocus→IgnorePointer→Offstage→Opacity→Transform→TickerMode chain every frame
  (changing the wrapper shape rebuilds the child from scratch — the one thing the
  widget exists to prevent). Direction falls out of a slot model: screen i wants
  `sign(i - index)`, springs retarget with position *and* velocity, and a screen parked
  off stage snaps to the far side instead of flying across the one you are reading.
- **Springs**: one retargetable primitive (value+velocity), colors ease on a curve
  instead (a spring overshooting a color token makes a color outside the palette).
  Flattening a spring to a duration+curve for widgets that need one: sample the real
  simulation and measure settle time at a tighter tolerance than the physics default,
  or the flattened form runs ~100ms of invisible tail.
- **The gradient ring**: paint borders as a BoxBorder subclass so every surface keeps
  its single BoxDecoration; blend the top toward `edgeLight` at a fraction of strength
  in light theme (white-at-90% over a pale hairline erases the border entirely).
- **Sparkline band**: it never was min/max data — the series normalizes to fill the
  box, so the band is pure ground. Per-theme alpha (0.18 dark / 0.07 light); at 0.10+
  on white it reads as a slab.
- **Reduced motion**: one resolver, everything collapses to a 90ms crossfade, the
  handoff pulse becomes a swap. Read the flag in one place only.

## Dev and review tooling (all of it kept, all of it earns its place)

- `tool/fake_meshd.dart` — the fake daemon, full IPC protocol, lively data (flapping
  path, lossy path, join/leave, delayed ping). The whole UI is developable against it.
- `tool/fake_update_cp.dart` — update-manifest server; `--corrupt` (bytes ≠ advertised
  hash) and `--overrun` (streams double, declares no Content-Length — proves the
  mid-stream size cap alone protects the disk). Payloads capped at 80MB by convention:
  it builds the payload as a Dart List<int>, so the fixture itself sits at ~1.5GB when
  you ask for 80MB. Do not ask for more.
- `tool/smoke.dart` — protocol round-trip against fake_meshd; `tool/render_app_icon.dart`
  — regenerates the appiconset from the same geometry as the SVGs in `assets/brand/`
  (SVGs are canonical art; the 16/32px are hand-laid and cannot fall out of a vector).
- Headless review on macOS without screen-recording permission: the debug binary prints
  its VM service URI; `_flutter.screenshot` over that websocket needs no TCC. Serialize
  the RPC — overlapping screenshot requests wedge it. Synthetic input =
  `WidgetsBinding.instance.handlePointerEvent` via the VM service expression evaluator;
  find widgets by walking the element tree from `rootElement`. **An unfocused window is
  never asked for frames**: tickers stand still, post-frame callbacks never fire,
  screenshots serve the last painted frame — schedule frames by hand
  (`WidgetsBinding.instance.scheduleFrame()`) between every action and capture.
  Throttle a "network" by proxying the fixture through a rate-limited TCP forwarder;
  loopback is too fast to ever catch a progress bar otherwise.
- Every script that launches the app carries a deadman
  (`( sleep 120; kill $PID ) >/dev/null 2>&1 & disown` — redirect the subshell's fds or
  it holds the caller's pipe open for the full sleep). This exists because an orphaned
  fixture run once ate 14GB. Kill everything you start; verify with pgrep.

## CI and packaging

`.github/workflows/app.yml`: macOS job — analyze (fatal-infos), format check, release
build with the dart-define, then `packaging/macos-pkg.sh` → unsigned component pkg as
artifact. The pkg is `pkgbuild --component`, which emits a `<relocate>` block: if a
copy of Mesh.app exists anywhere (Downloads), Installer updates that copy instead of
/Applications. Pinning that off needs `--root` staging with `BundleIsRelocatable=false`.
Uninstall = drag Mesh.app out + `pkgutil --forget dev.mesh.app`; the app installs no
launch agents and its only leavings are ui.json (its own) and config.json (meshctl's —
leave it). ci.yml's script check covers packaging/*.sh with `sh -n` + shellcheck `-s sh`
— the pkg script is POSIX sh, `set -eu`, no pipefail (SC3040 under `-s sh`).

macOS entitlements: **app sandbox off, deliberately** — a sandboxed process cannot
connect to a unix socket outside its container (EPERM before the socket's mode is ever
consulted) or read meshctl's config. Developer-ID distribution, not App Store. Release
entitlements also need `network.client` or the control plane is unreachable in release
builds only.

## Rust-side changes that ride with the app

- `ipc.rs`: socket chmod 0666 after bind, failing the bind loudly if chmod fails
  (unlink first so a half-open socket is not left behind). install.sh's state dir went
  0700 → 0755 — 0700 silently defeats the socket mode by blocking traversal.
- `state.rs` / `cpclient.rs` / `tailscale/mod.rs`: every secret-bearing state file
  (state.json holds the node token) written 0600 via one shared `restrict()` in
  util.rs, chmod-before-rename so the file is never visible at its final path in an
  open mode.

## Open items you inherit

1. Linux/Windows: never built, never rendered, gating verified only under injection.
2. The plist's baked CP URL goes stale if the effective URL changes post-install
   (update doesn't rewrite it; reinstall does).
3. The pkg relocate quirk (above) if you ever hand the pkg to reviewers again.
4. The wizard's auth form and Network's signed-out `MeshAuthPanel` are two
   implementations of the same form, flagged for reconciliation and never merged.
5. The daemon exposes no version over IPC — Settings shows binary hashes, not
   versions. A `version` field in StatusReport would fix that properly.
6. `MeshToggle`, `MeshColorBuilder`, `MeshSpringOffsetBuilder` are built, tested, and
   unused — kit surface waiting for a caller, or dead weight for you to drop.
7. The real admin-prompt path has been exercised exactly once, by a human (you).
   Everything around it is harness-proven; the prompt itself stays manual forever.
