# Node daemon and CLI

## Daemon startup, in order

1. `--version` / `-V` / `version` prints one line and exits before any logging:
   `meshd <crate version> (<12-char git sha, "-dirty" if the tree was dirty>) <target triple>`.
2. Logging from `MESH_LOG` (default `info,mesh_core=debug`).
3. State dir: `MESH_STATE_DIR`, else `/var/lib/mesh` (unix) or `%ProgramData%\mesh` (Windows).
4. Node name: `MESH_NODE_NAME`, else the `HOSTNAME` env var, else `mesh-node`. Services don't get
   `HOSTNAME`, so under systemd every node was called `mesh-node` (known-problems.md).
5. Identity: load `node-identity.key` (base64 of the 32-byte Ed25519 secret) or generate it. The
   same key is the node's control plane identity and its mesh membership key.
6. Control plane URL, first non-blank wins: `MESH_CP_URL` env; the URL stored from a previous
   enrollment; the URL compiled in at build time. None → exit with an error. The stored URL beats
   the compiled one so a rebuilt binary pointing elsewhere can't orphan a working node.
7. Not enrolled yet:
   - enrollment key from `MESH_ENROLLMENT_KEY`, else the file `$STATE/enrollment-key` → enroll. On
     success delete that file. On failure exit. Under `Restart=always` a bad key therefore
     crash-loops and never reaches idle mode, so `meshctl join` can't fix it (known-problems.md).
   - no key anywhere → **idle mode**: listen on the IPC socket and answer only `status` (with
     `enrolled: false`) and `join <key>` (enrolls; on success reply, drop the listener, continue
     startup). Anything else gets an error telling the user to run `meshctl join`.
8. Fetch the roster:
   - OK → save peers, backhaul config, own IP and subnet into the state file.
   - 401 → our registration is gone (probably removed). If an enrollment key is available, enroll
     again (the control plane returns the old record if it still exists by key, otherwise a new one)
     and consume the staged file. If not, drop the control plane state (in memory only; the dead
     record stays in `state.json` until a join succeeds) and go to idle mode. Then fetch the roster
     again (an error now is fatal).
   - any other error → use the cached roster from the state file.
   - The first 401 branch is how a removed node rejoins by itself when a key is still lying around
     in the environment or on disk (known-problems.md, "Eviction doesn't stick").
9. Cloudflare, if the roster has Cloudflare config: reuse the saved registration or enroll fresh
   (cloudflare.md), then connect. Failure is logged, not fatal.
10. Tailscale, if `tailscale_available`: ask the control plane for an auth key, register, pick the
    DERP region (roster's region preferred), connect DERP. Failure is logged, not fatal.
11. Both failed: warn and carry on with the direct path only (it still reaches LAN peers from the
    cached roster). An earlier version exited here, which meant a machine that booted during an
    outage stayed down until someone logged in.
12. Direct socket: port from state, else `MESH_DIRECT_PORT`, else 47778. If the saved state says the
    port was poisoned, move to saved port + 1 (min 1024). Exclude the mesh subnet from candidates.
13. Build the node, apply the roster.
14. TUN (unless `MESH_TUN=0`), with the roster IP and subnet. Failure is a warning.
15. Start the probe loop (interval `MESH_PROBE_INTERVAL_SECS`, default 1).
16. Update task, if updates are enabled: check at start and every 6h (install-update-release.md).
17. For each backhaul that failed but is configured: a background retry with backoff 5s doubling to
    60s; on success, adopt it into the running node and start its receive loop. Status must read the
    live backhaul, not what existed at startup.
18. NAT traversal loop with the roster's STUN servers (or `MESH_STUN_SERVERS`).
19. Roster refresh every 30s (first one 30s in): report `derp=<region>` and
    `cf_device=<our device id>`, apply peers and save them. The region is whichever one the startup
    Tailscale connection used (the agreed one, else measured, else the first usable), and both
    values are captured once at startup; the startup fetch in step 8 reports neither. On 401, count;
    three in a row → log "removed from the network" and shut down. Any success or non-401 error
    resets the count. It does **not** re-enroll while running: rejoining by itself would make
    `remove-node` meaningless. Rejoining is meant to be a deliberate act on restart, gated on an
    enrollment key the operator can rotate.
20. Save the settled direct port and clear the poisoned flag.
21. Serve IPC until told to shut down.

The goal was that any backhaul, the TUN, the direct socket or the control plane can be missing and
the daemon keeps running on whatever it has. That held for those, but these were still fatal at
startup: a malformed `state.json`, failing to bind the IPC endpoint, an unparseable own IP in the
roster, any failure to save state, and an enrollment failure when a key was supplied.

The two "no key" outcomes behave the same way on purpose: a machine started by systemd at boot has
nobody there to export a variable, so exiting would mean every install needs a shell.

## State files (`$STATE`)

| file | contents |
|---|---|
| `node-identity.key` | base64 Ed25519 secret (32 bytes) |
| `state.json` | node name; Cloudflare registration (device id, device token, P-256 PKCS#8 base64, endpoints, ports, endpoint public key, our v4/v6, mesh routes); control plane (url, node id, node token, virtual ip, subnet, cached peers, cached backhaul config); direct port; poisoned flag. Written to a temp file and renamed |
| `tailscale-keys.json` | Tailscale machine/node keys (ts_keys format) |
| `enrollment-key` | a key staged by an unattended installer; deleted after a successful enroll |
| `meshd.sock` | the IPC socket (unix) |

Plaintext. The old threat model was "none yet", kept in one directory so it's easy to fix later. A
staged enrollment key must never persist after use: a leftover key lets a removed node rejoin itself
on reboot.

## IPC

- Unix: a socket at `$STATE/meshd.sock` (`MESH_SOCKET` overrides). Remove a stale socket file before
  binding. Windows: named pipe `\\.\pipe\meshd`. tokio has no unix sockets on Windows, even where
  AF_UNIX exists. A pipe instance serves one client, so always have the next instance created
  before handing one out, or a client connecting between accepts gets ERROR_FILE_NOT_FOUND. First
  instance created with `first_pipe_instance(true)`.
- Protocol: one JSON line request, one JSON line response, per connection.
- Unauthenticated: whoever can open the socket can drive the daemon.
- A failed accept is logged and retried after 200 ms; only 10 in a row ends the daemon (the endpoint
  itself is gone). One client dying mid-handshake used to kill the whole daemon. Each connection is
  handled in its own task.
- Idle mode (not enrolled) is different: it handles connections one at a time, inline, with no
  timeout, and retries accept errors forever. A client that connects and sends nothing blocks
  `status` and `join` for everyone.
- Requests (internally tagged by `cmd`, kebab-case):
  - `{"cmd":"status"}`
  - `{"cmd":"peers"}`
  - `{"cmd":"ping","peer":"<name or ip>","count":4}`
  - `{"cmd":"send","peer":"...","data":"text"}`
  - `{"cmd":"join","key":"mkey_..."}`
  - `{"cmd":"leave"}`
- Responses (externally tagged, kebab-case): `{"status":{...}}`, `{"peers":[...]}`,
  `{"ping":[{path, seq, rtt_ms|null}]}`, `{"sent":{path, bytes}}`,
  `{"joined":{node_id, virtual_ip, subnet}}`, `{"left":{node_id, detail}}`, `"ok"`,
  `{"error":"..."}`.
- Status: `node_name, enrolled (defaults to true when missing), virtual_ip, subnet,
  cloudflare {up, address, detail}?, tailscale {up, address, detail}?, peer_count, uptime_secs`.
  In the old code a backhaul was either reported with `up: true` (it existed) or left out; a
  configured backhaul that failed to come up was simply omitted, so the CLI printed "not
  configured" for it and never printed "down". Cloudflare's address was our CF mesh IP with detail
  "connect-ip over quic"; Tailscale's was our tailnet addresses with detail "derp region <code>".
- Peers: `[{name, virtual_ip, cf_ip, ts_hostname, best_path, paths: [{path, up, last_rtt_ms,
  ewma_ms, sent, received, loss_pct}]}]`.
- `join` on an enrolled daemon: error "already a member as <node id>; run `meshctl leave` first".
- `leave`: call `DELETE /v1/nodes/me`. A 401 there means already removed; it isn't treated as a
  failure, but `detail` still says "the control plane had already forgotten this node" and the CLI
  prints it. Any other failure goes into `detail`, telling the user to run
  `meshctl remove-node <id>`. Either way the reply is `left` (so a script can't tell from the exit
  code; known-problems.md). Then delete `state.json`, `node-identity.key` and `enrollment-key` (a
  node that leaves and joins again is a new node), reply, and only then shut down (signalling first
  races the reply). Deregistering happens first because the node token that proves we may is one of
  the things being deleted. The daemon does this rather than the CLI because the machine being
  uninstalled usually has no account session. The node token is also in plaintext in `state.json`,
  but the old CLI never read it.
- After `leave` under systemd (`Restart=always`) the daemon comes back up unenrolled with a new
  identity and waits in idle mode, unless `MESH_ENROLLMENT_KEY` is in its environment, in which
  case it enrolls straight away as a new node.
- Data frames received are only logged ("data received" with sender, path, text).

## CLI

Local node commands (via IPC):

| command | notes |
|---|---|
| `status` | node name; if not enrolled, say so and suggest `join`; else address and subnet, uptime, peer count, and per backhaul either "up <address> (<detail>)" or "not configured" (a backhaul that failed also showed as "not configured", see above) |
| `peers` | per peer: `peer <name> (<ip>)  cf=<cf ip>  best=<path>`, then a table: path, state, last ms, ewma ms, sent, recv, loss % |
| `ping <peer> [count]` | samples, per-path min/avg/max, winner (path-selection.md) |
| `send <peer> <message...>` | "sent N bytes over <path>" |
| `join <enrollment-key>` | "joined as <node id>", address and subnet |
| `leave` | "left the network; <id> is gone and its address is free", plus any detail |

Network commands (HTTP to the control plane):

| command | notes |
|---|---|
| `signup <email> [password] [subnet]` | prompts for the password twice without echo if not given (there's no password reset). Stores the session |
| `login <email> [password]` | prompts without echo if not given. Stores the session |
| `logout` | deletes the stored session file (local only). Warns if `MESH_SESSION` is still set |
| `whoami` | account, email, control plane URL, session validity; notes if commands are aimed at a different control plane |
| `network` | account, subnet, nodes used and addresses free, each backhaul's detail or "not configured" |
| `set-subnet <cidr>` | |
| `set-cloudflare <api-token> <account-id>` | prints a "this takes a few seconds" line first |
| `set-tailscale <api-token>` | |
| `enrollment-key` | prints the key on its own first line (scripts use `head -1`), then its expiry |
| `nodes` | per node: up/down, ip, name, last seen, then the node id on the next line |
| `remove-node <node-id>` | |

Other: `update` (replace itself and a sibling `meshd`, install-update-release.md), `version`
(same line format as the daemon), `-h` / `--help` / no args for usage. Errors from the daemon go to
stderr with exit code 1. The control plane's `{"error"}` text is what gets shown.

Passwords as arguments end up in shell history and `ps`, so prompting is the default.

### Which control plane, which session

- URL, first non-blank wins: `MESH_CP_URL`; the URL stored with the login; the compiled-in URL;
  `http://127.0.0.1:8080`.
- Session: `MESH_SESSION` wins (scripts and CI rely on it). Otherwise the stored one, but only if it
  was issued by the control plane being addressed. URLs compare equal after trimming whitespace and
  trailing slashes, case-insensitively; anything else (other host, other port) is a different
  control plane. A stored session for another control plane gives an error naming both, never the
  token. An expired stored session gives "expired on <date>, log in again" instead of a raw 401.
- The session and its URL are stored as one record so an account token can never be sent to
  whatever host `MESH_CP_URL` happens to name.
- Stored at `MESH_CONFIG` if set, else `$XDG_CONFIG_HOME/mesh/config.json` or
  `~/.config/mesh/config.json` (Linux), `~/Library/Application Support/mesh/config.json` (macOS),
  `%APPDATA%\mesh\config.json` (Windows). It's a person's credential, so it lives in their home, not
  in the root-owned state dir. Mode 0600, written via temp file + rename. Contents: `cp_url,
  session_token, account_id, email, expires_at`.
- A malformed config file is an error, not "logged out" (it holds the only copy of the session).
  The update paths ignore a broken config and fall back to other URL sources.
- The CLI never needs exporting anything on the normal path: login stores the session, join hands
  the key to the daemon.
