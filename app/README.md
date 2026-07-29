# Mesh (desktop app)

A desktop control panel for the mesh daemon: what `meshctl status`, `meshctl peers`,
`meshctl ping` and `meshctl network` print, rendered as an instrument you can leave open.

Four screens behind the rail:

- **overview**: is the daemon up, is this node enrolled, its address and subnet, uptime,
  peer count, and one panel per backhaul plane. When the daemon is up but not enrolled,
  the join card takes an enrollment key (and mints one inline if you have a control plane
  session). When the daemon is unreachable, the OS error verbatim plus what to do about it.
- **peers**: the peer table with the path triad, the winning path's RTT and its history.
  Open a row for per-path detail and a ping that prints what `meshctl ping` prints.
- **network**: the control plane. Sign in or sign up, subnet, backhaul credentials,
  enrollment keys, and the node list with per-node removal.
- **settings**: resolved daemon socket, control plane URL and where it came from, session,
  theme, poll interval, and a danger zone that leaves the network.

The app talks to the daemon over its unix socket (newline-delimited JSON, one connection
per request) and to the control plane over HTTP. It shares `meshctl`'s session file rather
than keeping its own, so signing in here signs you in there. Its own preferences live in
`ui.json` beside that file and never touch it.

Design language: `DESIGN.md`. The app is built on the Flutter widgets layer with no
Material or Cupertino; every widget is in `lib/src/kit/`.

## Running against the fake daemon

`tool/fake_meshd.dart` speaks the real IPC protocol and serves data that moves: three
peers, jittering per-path RTTs, a direct path that flaps, a lossy path, winners that change
hands. Join and leave toggle enrollment. No root, no real mesh.

```sh
dart run tool/fake_meshd.dart /tmp/meshd-fake.sock
MESH_SOCKET=/tmp/meshd-fake.sock flutter run -d macos
```

Two terminals, in that order. Use `-d linux` or `-d windows` for the other desktops.

Keep the socket path short. A unix socket path is capped near 100 bytes, so a deeply
nested scratch directory fails at `bind` with "The length of path exceeds the limit".

## Running against the real daemon

By default the app looks for the socket exactly where the CLI does: `MESH_SOCKET` if it is
set and non-empty, otherwise `meshd.sock` inside the state directory, which is
`/var/lib/mesh` unless `MESH_STATE_DIR` says otherwise.

```sh
flutter run -d macos                                  # /var/lib/mesh/meshd.sock
MESH_SOCKET=/run/mesh/meshd.sock flutter run -d macos  # somewhere else
```

**The root-only socket caveat.** A daemon built from this tree chmods its socket 0666 right
after binding, so any local user can talk to it. An already-installed daemon from before
that change leaves the socket root-owned and mode 0600, and the app gets `EACCES`. It says
so on the overview screen and offers the one-liner that unblocks it until you install a
newer daemon:

```sh
sudo chmod 666 /var/lib/mesh/meshd.sock
```

The mode does not survive a daemon restart, so this is a stopgap, not a fix.

Environment, all shared with `meshctl`:

| variable | effect |
|---|---|
| `MESH_SOCKET` | daemon socket path, wins over everything |
| `MESH_STATE_DIR` | directory holding `meshd.sock` when `MESH_SOCKET` is unset |
| `MESH_CONFIG` | path to the shared `config.json` (`ui.json` follows it) |
| `MESH_CP_URL` | control plane URL, wins over the stored one |
| `MESH_SESSION` | session token, wins over the stored one; disables sign-out |

Windows is not wired up: the daemon speaks over a unix socket and the named-pipe transport
is not implemented, so the app builds and runs there but reports the daemon as unsupported.

## Building for release

```sh
flutter build macos --release     # build/macos/Build/Products/Release/Mesh.app
flutter build linux --release     # build/linux/<arch>/release/bundle/
flutter build windows --release   # build/windows/x64/runner/Release/
```

On macOS the app sandbox is **off**, in both `macos/Runner/DebugProfile.entitlements` and
`Release.entitlements`. A sandboxed process cannot `connect()` to a unix socket outside its
container (it fails with `EPERM` before the socket's own mode is consulted) and cannot read
`meshctl`'s session file, and no entitlement buys either back. That makes this a
Developer-ID build, not a Mac App Store build. Sign and notarize it the usual way before
shipping it anywhere.

Linux needs the usual GTK toolchain (`libgtk-3-dev`, `ninja-build`, `cmake`,
`pkg-config`); Windows needs Visual Studio with the Desktop C++ workload.

## Checks

```sh
flutter analyze                 # must be clean
dart format lib tool
dart run tool/smoke.dart        # drives a fake daemon through the IPC client
```
