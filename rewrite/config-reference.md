# Config reference

An exported-but-empty variable is a common accident. The old code treated blank as unset for
`MESH_STATE_DIR`, `MESH_CP_URL`, `MESH_ENROLLMENT_KEY`, `MESH_SOCKET`, `MESH_CONFIG`,
`MESH_SESSION`, `MESH_AUTOUPDATE` and `MESH_CP_PUBLIC_URL`; numeric and URL-parsed ones fell back to
their defaults. Everything else took the blank literally and broke: `MESH_NODE_NAME` gave an empty
name, blank `MESH_TUN_NAME` broke the `ip` commands, blank `MESH_LOG` logged nothing, blank
`MESH_CP_DB` made SQLite open a temporary database (all data silently lost), blank bind addresses
failed, blank `MESH_EMBED_DIR` embedded nothing, and blank `MESH_CP_SECRET` meant a random key.

## Node daemon

| env | default | meaning |
|---|---|---|
| `MESH_STATE_DIR` | `/var/lib/mesh`, Windows `%ProgramData%\mesh` | keys, registration, socket |
| `MESH_CP_URL` | stored enrollment URL, then compiled-in | control plane; runtime env beats everything |
| `MESH_ENROLLMENT_KEY` | `$STATE/enrollment-key` file | key for first join or rejoin at startup |
| `MESH_NODE_NAME` | `HOSTNAME` env, then `mesh-node` | node name (not unique; the mesh IP is) |
| `MESH_LOG` | `info,mesh_core=debug` | tracing filter |
| `MESH_TUN` | on | `0` disables the interface |
| `MESH_TUN_NAME` | `mesh0` on Linux and Windows, `utun` (any free) on macOS | interface name |
| `MESH_PROBE_INTERVAL_SECS` | 1 | probe round interval; `0` panicked the old daemon |
| `MESH_DIRECT_PORT` | 47778 | direct UDP port (a saved port wins) |
| `MESH_STUN_SERVERS` | none | comma-separated `ip:port`, used only if none of the roster's entries parse |
| `MESH_TS_CONTROL_URL` | `https://controlplane.tailscale.com/` | Tailscale control server |
| `MESH_AUTOUPDATE` | on | `0`/`false`/`off`/`no` disables |
| `MESH_SOCKET` | `$STATE/meshd.sock`, Windows `\\.\pipe\meshd` | IPC endpoint |

## CLI

| env | meaning |
|---|---|
| `MESH_SOCKET` | daemon endpoint |
| `MESH_CP_URL` | control plane; beats the stored login's URL and the compiled-in one; last resort `http://127.0.0.1:8080` |
| `MESH_SESSION` | session token; beats the stored one |
| `MESH_CONFIG` | where the session is stored |
| `MESH_AUTOUPDATE` | `0` turns off update checks (and, in the old code, `meshctl update` too) |
| `MESH_STATE_DIR` | used to find the default socket path |

## Control plane

| env | default | meaning |
|---|---|---|
| `MESH_CP_BIND` | `0.0.0.0:8080` | HTTP |
| `MESH_CP_DB` | `/var/lib/meshcp/meshcp.db` | SQLite |
| `MESH_CP_SECRET` | random per process (bad) | key for sealing vendor credentials |
| `MESH_CP_STUN_BIND` | `0.0.0.0:3478` | first STUN responder |
| `MESH_CP_STUN_BIND2` | `0.0.0.0:3479` | second STUN responder |
| `MESH_CP_STUN_ADVERTISE` | empty | STUN servers told to nodes, comma-separated, reachable from nodes |
| `MESH_CP_PUBLIC_URL` | from the Host header | URL written into served scripts |
| `MESH_LOG` | `info,meshcp=debug` | tracing filter |

## Build time

| env | meaning |
|---|---|
| `MESH_CP_URL` | default control plane baked into node and CLI binaries |
| `MESH_AUTOUPDATE` | default update setting baked in |
| `MESH_GIT_SHA` | commit for `--version`, else from git, else `unknown` |
| `MESH_EMBED_DIR` | where the control plane build finds node binaries (`dist/<target>/<name>`) |

## Scripts

- install.sh: `--cp-url`, `--key`, `--prefix` (`/usr/local`), `--no-service`; env `MESH_CP_URL`,
  `MESH_PREFIX`, `MESH_STATE_DIR`.
- uninstall.sh: `--purge`, `--keep-account`, `--prefix`; env `MESH_PREFIX`, `MESH_STATE_DIR`.

## Ports

| port | what |
|---|---|
| UDP 47777 | our port inside the Cloudflare tunnel (source and destination) |
| UDP 47778 | direct path |
| TCP 8080 | control plane HTTP |
| UDP 3478, 3479 | control plane STUN |
| UDP 443 (+ 500, 1701, 4500, 4443, 8443, 8095) | Cloudflare MASQUE endpoint |

## Files

| path | what |
|---|---|
| `$STATE/node-identity.key` | Ed25519 secret, base64 |
| `$STATE/state.json` | registration, cached roster, direct port |
| `$STATE/tailscale-keys.json` | Tailscale keys |
| `$STATE/enrollment-key` | staged key, deleted after use |
| `$STATE/meshd.sock` | IPC socket |
| `~/.config/mesh/config.json` (Linux), `~/Library/Application Support/mesh/config.json` (macOS), `%APPDATA%\mesh\config.json` (Windows) | CLI session, 0600 |
| `$TMPDIR/mesh-update-check` | CLI update-notice throttle marker |
| `/etc/mesh/meshd.env` | daemon env for systemd |
| `/etc/systemd/system/meshd.service` or `/lib/systemd/system/meshd.service` | daemon unit |
| `/Library/LaunchDaemons/net.mesh.meshd.plist` | macOS daemon, logs to `/var/log/meshd.log` |
| `/etc/meshcp/meshcp.env` | control plane env incl. the secret, 0600 |
| `/var/lib/meshcp/meshcp.db` | control plane database |

## Constants

| what | value |
|---|---|
| default subnet | `10.201.0.0/16` |
| frame magic / version | `MESH` / 2 |
| frame header | 48 bytes + name |
| max encoded frame | 1300 bytes |
| TUN MTU | 1100 |
| probe interval | 1s |
| path timeout | 15s |
| probe lost after | 5s |
| per-path send cap | 2s |
| EWMA alpha | 0.3 |
| Hello | at start and every 10 probe rounds |
| NAT traversal round | 20s |
| STUN query timeout | 3s |
| punch burst | 5 rounds, 30 ms apart |
| prediction spread | 4 ports |
| candidate caps | 16 direct, 8 predicted (the old code let observed source addresses bypass the cap) |
| roster refresh | 30s |
| revocation tolerance | 3 consecutive 401s |
| backhaul retry at startup | 5s doubling to 60s |
| tunnel / DERP reconnect | 1s doubling to 30s, forever |
| update check | startup + every 6h |
| session TTL | 30 days |
| enrollment key TTL | 90 days |
| online window | 90s |
| Tailscale auth key expiry | 3600s |
| Cloudflare enrollment JWT | 60s |
| MASQUE: QUIC initial MTU / idle / keepalive | 1242 / 30s / 10s |
| MASQUE: handshake / settings wait / CONNECT answer | 8s / 5s / 8s |
| DERP region probe timeout | 4s |
| Tailscale self node + DERP map wait | 30s each |
| Wintun ring | 0x400000 |
| IPC accept failures before giving up | 10 in a row |
| control plane HTTP client timeout (node side) | 20s |
| control plane HTTP client timeout (CLI) | 60s |
| binary download timeout | 300s |
