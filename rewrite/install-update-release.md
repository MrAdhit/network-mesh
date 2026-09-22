# Install, update, release

## One-line install

`curl -fsSL https://<cp>/install.sh | sudo sh` (add `-s -- --key mkey_...` to join in the same
step). The control plane serves the script with its own URL substituted, and the script fetches
the binaries from that control plane's update endpoints and checks each against the published
SHA-256. So install and self-update pull the same bytes from the same place, and the downloads
can't come from the wrong control plane.

The installed daemon is another matter. On Linux the old script never passed its URL to the
daemon (`MESH_CP_URL` is commented out in the generated env file and the unit sets nothing), so
the daemon used the URL compiled into the binary, which CI set to `https://mesh.mradhit.net`. Only
the macOS plist set `MESH_CP_URL`. See known-problems.md.

What the old `install.sh` did (POSIX sh, shellcheck-clean):

- Options: `--cp-url`, `--key`, `--prefix` (default `/usr/local`), `--no-service`; env
  `MESH_CP_URL`, `MESH_PREFIX`, `MESH_STATE_DIR`.
- Refuse if the URL is empty or still the unsubstituted placeholder. It tested "starts with `@`"
  rather than spelling out `@CP_URL@`, because the server replaces every occurrence of the token and
  would have rewritten the guard itself.
- Must be root.
- Platform to target: Linux x86_64/amd64 → `x86_64-unknown-linux-gnu`, Linux aarch64/arm64 →
  `aarch64-unknown-linux-gnu`, Darwin arm64 → `aarch64-apple-darwin`, Darwin x86_64 → refuse (no
  Intel Macs), anything else → refuse. Windows isn't handled by the script.
- Needs curl or wget, and sha256sum, shasum or openssl. No way to hash → refuse rather than
  install unverified.
- Fetch the manifest, pull each binary's hash out of the JSON with sed, download `meshd` and
  `meshctl` into a temp dir, compare hashes, chmod 755.
- Install by moving to `<prefix>/bin/<name>.new` and renaming over the old one. Never write into a
  running binary; a rename leaves the running process on its old inode.
- `mkdir` the state dir, chmod 700. With `--key`, write it to `$STATE/enrollment-key` under umask 077.
  On a node that's already enrolled that file is never consumed and just stays there, which later
  lets a removed node rejoin itself (known-problems.md).
- Create `/etc/mesh/meshd.env` if missing, everything commented out (CP URL, node name, log level,
  autoupdate). Commented out means the CP URL doesn't reach the daemon.
- Linux with systemd: write `/etc/systemd/system/meshd.service`, daemon-reload, `enable --now`.
  macOS: write `/Library/LaunchDaemons/net.mesh.meshd.plist` (RunAtLoad, KeepAlive, log to
  `/var/log/meshd.log`, `MESH_CP_URL` in its environment), `launchctl bootout` first so a reinstall
  reloads, then `bootstrap system`. Else tell the user to start it themselves.
- Wait up to 20s for `meshctl status` to answer and print it, so the user sees whether it came up.
- Print the next step (`meshctl join`) if no key was given, and the uninstall one-liner.
- Re-running it on a node that's already running replaces the binaries but doesn't restart the
  daemon (`enable --now` on a running unit does nothing).

systemd unit (the package ships the same thing with `/usr/bin`):

```ini
[Unit]
Description=mesh node daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/meshd
EnvironmentFile=-/etc/mesh/meshd.env
StateDirectory=mesh
AmbientCapabilities=CAP_NET_ADMIN
DeviceAllow=/dev/net/tun rw
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## Uninstall

`curl -fsSL https://<cp>/uninstall.sh | sudo sh`. Options `--purge` (also delete a control
plane's database on this machine), `--keep-account` (don't deregister), `--prefix`.

Order matters: deregister first, because the node token that proves we may is about to be deleted.

1. Read the node id from `state.json` (so it can be named if deregistering fails).
2. Unless `--keep-account`: `meshctl leave`. If the daemon doesn't answer, say the record may
   survive.
3. Stop and disable the service, remove the unit or plist. Also stop and disable `meshcp` if its
   unit is in `/etc/systemd/system` (or wherever it is, with `--purge`). `pkill -x meshd` for
   anything left.
4. Remove binaries `meshd`, `meshctl`, `meshcp`, `tuncheck` from the prefix.
5. Remove the state dir, `/etc/mesh/meshd.env` (and `/etc/mesh` if now empty), the CLI's update
   throttle marker, `/var/log/meshd.log`.
6. Remove the stored CLI session for the invoking user and for `$SUDO_USER` (home looked up via
   `getent`, falling back to `/Users/<u>` or `/home/<u>`). It deletes the whole `~/.config/mesh`
   and `~/Library/Application Support/mesh` directories and ignores `XDG_CONFIG_HOME` and
   `MESH_CONFIG`. Other users' sessions are listed, not deleted; they're theirs.
7. If `/var/lib/meshcp` exists: delete it (and `/etc/meshcp/meshcp.env`) only with `--purge`.
   Otherwise keep it and say why: it holds every account and the sealed vendor credentials, and
   nothing else has a copy. Removing the software isn't the same as destroying the network.
8. If deregistration didn't happen, print `meshctl remove-node <id>` for the operator. In the old
   script "didn't happen" only meant `meshctl leave` exited non-zero. `leave` exits 0 even when the
   daemon couldn't reach the control plane (the failure is only in the printed detail), so in that
   case the script still ended with "done; nothing of ours is left".

## Packages (deb and rpm, built with nfpm)

- `mesh`: `/usr/bin/meshd`, `/usr/bin/meshctl`, `/lib/systemd/system/meshd.service`,
  `/etc/mesh/meshd.env` (config, never replaced on upgrade), `/usr/lib/mesh/uninstall.sh`.
  - postinstall: daemon-reload; on `configure` / rpm `2` try-restart if enabled (dpkg passes
    `configure` on fresh installs too, which is harmless); then, if not enabled, enable + start and
    print the `meshctl join` hint. That second part also runs on upgrades, so an upgrade re-enables
    and starts a service the admin had disabled.
  - preremove: nothing on upgrade; otherwise stop + disable. (Deregistering belongs to removal,
    never to an upgrade.)
  - postremove: Debian semantics intended. `remove` keeps `/var/lib/mesh` so a reinstall comes back
    as the same node at the same address (and prints that it kept it). `purge` was meant to
    deregister via uninstall.sh and give the address back. It can't: by then the daemon is stopped
    and the script is deleted, so it just wipes the state (known-problems.md). rpm passes `0` on
    every erase, which lands in the purge branch, so on rpm systems a plain remove wipes the state
    too. On `apt purge`, `postrm remove` runs first and prints "kept /var/lib/mesh" right before the
    purge step deletes it.
- `meshcp`: `/usr/bin/meshcp`, its unit, `/etc/meshcp/meshcp.env` (mode 0600, never replaced).
  - postinstall: if `MESH_CP_SECRET=` is empty, generate 32 random bytes as hex into it (from
    `/dev/urandom`, else `openssl rand -hex 32`), then enable/start (try-restart on upgrade). Same
    re-enable-on-upgrade behaviour as the node package.
  - preremove: stop/disable unless upgrading. Never touches the database, even on purge. But
    `apt purge` deletes the env file (a conffile) that holds the secret, so a later reinstall gets a
    new secret and can't read the stored credentials. (rpm saves the modified file as
    `.rpmsave`, but a reinstall still starts from a fresh one unless someone restores it.)
  - Unit hardening: `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict`, `ProtectHome`,
    `StateDirectory=meshcp`, `AmbientCapabilities=CAP_NET_BIND_SERVICE` (only needed if bound below
    1024), `EnvironmentFile=/etc/meshcp/meshcp.env` (required), `Restart=always`.

## Self-update

- A build is identified by the SHA-256 of the file, not a version string. A version is a claim that
  can be stale or forgotten; the hash can't drift from what shipped. "Am I current" becomes an
  equality check, with no ordering question if a node is somehow ahead.
- The daemon checks at startup and every 6h, for itself and for a `meshctl` sitting next to it
  (they ship as a pair; only the daemon runs continuously enough to notice). The CLI's
  `meshctl update` does itself and a sibling `meshd` on demand. Otherwise the CLI only fetches the
  manifest, at most once per 6h (throttled by the mtime of a marker file `mesh-update-check` in the
  temp dir, since the state dir is root's), and prints "a newer meshctl is available; run `meshctl
  update`" to stderr. It never downloads a binary on its own. That check only runs for daemon
  commands, not for control plane commands or `update`.
- Procedure: fetch manifest for our compiled-in target; no entry for this binary → "not offered";
  hash our file; equal → up to date; else download (5 min timeout), check the hash, and only then
  install.
- Install: write to `.<file name>.new` in the same directory (same filesystem, so the rename is
  atomic), chmod 755 on unix, rename over the target. Unix happily renames over a running binary.
  Windows refuses: move the running exe to `<name>.old`, rename the new one in, and if that fails
  move the old one back. Leftover `.old` files get deleted later; in the old code only by the
  daemon's update task at startup (so only with updates on) or by `meshctl update`. An interrupted
  update must leave the old binary working, since a half-written one can't be recovered without
  another machine.
- New code takes effect at the next start. Restarting a working daemon to apply an update nobody
  asked for was judged worse than waiting.
- On by default. Build with `MESH_AUTOUPDATE=0` to ship binaries that never update. The same
  variable at runtime overrides the build either way. Values `0`, `false`, `off`, `no` (any case,
  trimmed) mean off; anything else means on; blank means "not set".
- In the old CLI, `MESH_AUTOUPDATE=0` also blocked the explicit `meshctl update`.
- `meshctl update` prints per binary: "updated to <sha prefix>" (plus "restart the daemon to run it"
  for meshd), "already current", or "the control plane has no build for <target>".

## Build-time knobs

- `MESH_CP_URL` at build time bakes in a default control plane (the build script has to tell cargo
  to rerun when it changes, or a rebuild silently keeps the old value). The release builds baked in
  `https://mesh.mradhit.net`, the user's deployment. The test job left it unset on purpose so tests
  cover the unset case.
- `MESH_AUTOUPDATE` at build time, same rerun caveat.
- `MESH_GIT_SHA` overrides the commit stamped into `--version` (for builds from a tarball); else
  `git rev-parse --short=12 HEAD`, plus `-dirty` if tracked files are modified; else `unknown`.
  The old build script only declared env-var rerun triggers, which turns off cargo's default rerun,
  and nothing watched `.git`, so incremental builds kept a stale commit and dirty flag.
- The target triple is stamped in at build time; a node asks for its own target's build.
- `MESH_EMBED_DIR` pointed the control plane's build at the staged node binaries (default `dist/`).

## Targets and CI facts

- Node and CLI: `x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu`, `aarch64-apple-darwin`,
  `x86_64-pc-windows-msvc`, `aarch64-pc-windows-msvc`. Control plane: the two Linux targets only.
- Cross-compiling aarch64 Linux needs a real C cross toolchain plus cmake, because aws-lc-rs (via
  rustls) and bundled SQLite compile C: `gcc-aarch64-linux-gnu g++-aarch64-linux-gnu cmake` and the
  `CARGO_TARGET_..._LINKER`, `CC_...`, `CXX_...`, `AR_...` env vars. Cross-compiling Windows from
  macOS failed in the C build scripts of ring and aws-lc-sys, so Windows was only ever built on
  Windows runners.
- Tests ran on the Linux check job and on the Windows build legs (mesh-core only); clippy ran only
  on Linux. So macOS-only code was compiled but never tested or linted in CI, and Windows-only code
  was tested but never linted. Helpers that only macOS calls had to live outside the platform
  module to get tested at all, with a dead-code allowance for the other platforms.
- Old CI gates: rustfmt check, clippy with warnings as errors, tests, `sh -n` and shellcheck on the
  shell scripts (they're piped into shells by users, so a syntax error is a broken install).
- Release on a `v*` tag: the same build workflow as CI, then per-target archives
  (`mesh-<v>-<target>.tar.gz`, zip for Windows, `meshcp-<v>-<target>.tar.gz`), deb and rpm for
  amd64 and arm64, a `SHA256SUMS` over everything, and a GitHub release with install
  instructions. Warn if the tag and the workspace version disagree. The `tuncheck` example shipped
  inside the node archives.
- Repo: `https://github.com/MrAdhit/network-mesh`.
