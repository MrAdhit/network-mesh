# Control plane

HTTP JSON API plus SQLite. Must be reachable over the ordinary internet, not over the mesh
(otherwise there's a bootstrap loop). When it's down, running nodes carry on from their cached
roster and joins fail. A node that (re)starts during the outage is worse off: no Tailscale (auth
keys come from the control plane), and in the old code no STUN servers or DERP region either,
because those weren't cached.

## Auth and errors

- Human endpoints: header `x-mesh-session: <session token>`.
- Node endpoints: header `x-mesh-node-token: <node token>`.
- Errors are meant to be JSON `{"error": "<sentence for a human>"}` with 400 (bad input), 401
  (missing or unknown credential) or 500, and clients show the sentence, not the status code. In
  the old code the framework's own rejections bypassed that: plain text with 415 (wrong content
  type), 400 (bad JSON), 422 (missing field). The update download's 404 was plain text too.
  Deleting an unknown node gave 400 "no such node". Enroll failures that aren't the key's fault
  (subnet full, duplicate key in another account, allocation race) all came back as 500.
- Nodes treat 401 specially: it means "your registration is gone". Any other failure means "carry
  on with cached state". Keep those two distinct.
- Tokens are a prefix plus base64url (no padding) of 24 random bytes: `acc_` account id, `sess_`
  session, `mkey_` enrollment key, `node_` node id, `ntok_` node token.

## Human endpoints

| method, path | body | returns / does |
|---|---|---|
| `POST /v1/accounts` | `{email, password, subnet?}` | `{session_token, account_id, expires_at}`. Email must contain `@`; password at least 8 bytes; subnet defaults to `10.201.0.0/16` and is validated; duplicate email → 400 |
| `POST /v1/sessions` | `{email, password}` | same response. Wrong email or password → 401 with one generic message |
| `GET /v1/network` | | `{account_id, email, subnet, node_count, addresses_used, addresses_available, cloudflare: {configured, detail}, tailscale: {configured, detail}}` |
| `PATCH /v1/network` | `{subnet}` | the network view. Refused while any node is enrolled (every address would move) |
| `PUT /v1/network/backhauls/cloudflare` | `{api_token, account_id}` | provisions the org immediately (cloudflare.md), stores it sealed, returns `{configured: true, detail: "team <team>, service token provisioned"}` |
| `PUT /v1/network/backhauls/tailscale` | `{api_token}` | verifies it, stores it sealed, returns `{configured: true, detail: "<n> devices visible"}` |
| `POST /v1/enrollment-keys` | | `{key: "mkey_...", expires_at: "<RFC 3339>"}` |
| `GET /v1/nodes` | | `[{node_id, name, virtual_ip, public_key, created_at, last_seen?, online}]` |
| `DELETE /v1/nodes/{node_id}` | | `{removed: <id>, cloudflare_device_removed: bool}` |

`expires_at` in the session response is unix seconds; clients should default it to 0 if missing.
In `NodeView`, `created_at` and `last_seen` are RFC 3339 UTC strings (`2026-07-25T13:33:25Z`), and
`last_seen` is `null` for a node that never polled. The enrollment key's `expires_at` is RFC 3339
too.

## Node endpoints

| method, path | body / query | returns / does |
|---|---|---|
| `POST /v1/enroll` | `{enrollment_key, public_key, name}` (public key = base64 Ed25519) | `{node_id, node_token, virtual_ip, subnet}`. 401 if the key is unknown or expired. The old code only rejected a blank public key: a malformed one enrolled fine and every peer then skipped it. The name wasn't validated at all |
| `GET /v1/roster?derp=<u32>&cf_device=<id>` | both query params optional | the roster (below). Also bumps the node's `last_seen`, records `derp` as the network's region if none is set yet, and records `cf_device` as this node's Cloudflare device |
| `POST /v1/nodes/me/tailscale-auth-key` | | `{auth_key}`, minted fresh (tailscale.md). 400 if the network has no Tailscale credentials |
| `DELETE /v1/nodes/me` | | the node removing itself; same effect and response as the human delete |

`/v1/nodes/me` and `/v1/nodes/{node_id}` overlap. The old code's comment claimed registration
order mattered; with axum's router a static segment wins over a parameter regardless of order.
Whatever router is used, test that `me` is never read as a node id.

Roster:

```json
{
  "subnet": "10.201.0.0/16",
  "stun_servers": ["203.0.113.5:3478", "203.0.113.5:3479"],
  "derp_region": 12,
  "self_virtual_ip": "10.201.0.2",
  "peers": [{"node_id": "node_...", "name": "mesh-b", "virtual_ip": "10.201.0.3",
             "public_key": "<base64 ed25519>"}],
  "backhauls": {
    "cloudflare": {"team": "...", "service_client_id": "....access", "service_client_secret": "..."},
    "tailscale_available": true
  }
}
```

- `peers` is every other node in the account. The node itself is excluded.
- `cloudflare` is null when not configured. It never contains the API token.
- `tailscale_available` only says whether a key can be requested; the key itself comes from the
  separate endpoint so a reaped node can get a new one without re-enrolling.
- `stun_servers` comes from the `MESH_CP_STUN_ADVERTISE` env var (comma separated). It has to be
  addresses reachable from the nodes. The old nodes only accepted literal `ip:port` here and
  silently dropped hostnames (known-problems.md).
- `derp_region` and `stun_servers` default when missing (older control planes).

## Unauthenticated endpoints

| path | returns |
|---|---|
| `GET /health` | `{"ok": true, "now": <unix secs>}` |
| `GET /v1/updates/{target}` | `{target, binaries: [{name, sha256, size}]}`. An empty list, not a 404, when nothing is held for that target |
| `GET /v1/updates/{target}/{name}` | the binary bytes, `application/octet-stream`, `ETag: "<sha256>"`; 404 if none |
| `GET /install.sh`, `GET /uninstall.sh` | the scripts as `text/plain` with `@CP_URL@` replaced by this control plane's public URL |

`target` is a Rust target triple, `name` is `meshd` or `meshctl` without `.exe`. These are
unauthenticated on purpose: they're the same binaries a release page would hand out, they carry no
account data, and requiring a token would stop the CLI updating before its user has logged in.

Public URL for the scripts: `MESH_CP_PUBLIC_URL` if set; else `<scheme>://<Host header>`, where the
scheme is the first `X-Forwarded-Proto` value, else `http` for hosts starting `localhost` or `127.`,
else `https`; else the compiled-in control plane URL; else `http://127.0.0.1:8080`. Using the
request's Host means the script downloads from the control plane it was fetched from. (The old
Linux install then failed to hand that URL to the daemon; known-problems.md.)

The old control plane got its binaries by compiling them in at build time from
`dist/<target>/<binary>`, hashing each one then. A build with nothing staged just offers nothing.
That forces a build order: node binaries for every target first, the control plane after.

## Rules

- **Sessions** last 30 days. No server-side logout or revocation existed.
- **Enrollment keys** last 90 days, are reusable until then, and can't be listed or revoked.
- **Online** = polled the roster within the last 90s. Nodes poll every 30s.
- **Subnet validation**: must parse as IPv4 CIDR; network must be private (10/8, 172.16/12,
  192.168/16); prefix no longer than /29; must not overlap `100.64.0.0/10` (Tailscale) or
  `100.96.0.0/12` (Cloudflare's default Mesh range). The default `10.201.0.0/16` was also picked to
  miss the `10.96.0.0/16` the test Cloudflare org used, but nothing checks against the org's real
  range. Holes in the old check: only the network address was tested for being private, so
  `10.0.0.0/7` passed, and host bits were accepted and stored verbatim (`10.201.0.5/16`), then
  handed to nodes as their route. Normalise and check the whole range.
- **Address allocation**: lowest free address from network+2 up to broadcast-1. Network address and
  `.1` are never handed out (`.1` kept free for a possible gateway). Freed addresses get reused.
  Capacity shown = broadcast - network - 2.
- **Enrollment is idempotent by public key** within the account: the same key gets back the same
  node id, the same token and the same address (the name isn't updated). A node that loses its
  token but keeps its key keeps its address.
- **DERP region**: first reported value wins, stored per account, never changed afterwards.
- **Node removal** (by the account or by the node itself): read the node's Cloudflare device id,
  delete the row, then best-effort delete the Cloudflare device with the stored API token. The
  removal succeeds even if the Cloudflare call fails.

## Data model (old SQLite schema)

- `accounts(id, email UNIQUE, password_hash, subnet, created_at, derp_region)`
- `sessions(token, account_id, expires_at)`
- `enrollment_keys(key, account_id, expires_at, created_at)`
- `nodes(id, account_id, name, public_key UNIQUE, virtual_ip, node_token UNIQUE, created_at,
  last_seen, cf_device_id, UNIQUE(account_id, virtual_ip))`
- `backhaul_creds(account_id, kind, sealed BLOB, meta, updated_at, PK(account_id, kind))`, kind is
  `cloudflare` or `tailscale`, `meta` is the human-readable detail
- WAL mode, foreign keys on, everything cascades from accounts. One network per account: the
  network's settings (subnet, DERP region) are columns on the account row. The old roadmap called
  this "multi-tenant from the start", but more than one network per account would need a migration.

## Secrets

- Passwords: Argon2 (default params), PHC string.
- Vendor credentials: sealed with XChaCha20-Poly1305, stored as 24-byte random nonce + ciphertext.
  Cloudflare payload: `{api_token, account_id, team, service_client_id, service_client_secret}`;
  Tailscale: `{api_token}`.
- The key comes from `MESH_CP_SECRET`. The old code turned the string into 32 bytes with a
  homemade hash, not a KDF; use a real one. If the secret is unset it generated a random key per
  process, so stored credentials became unreadable after a restart. The package postinstall
  generated a secret into `/etc/meshcp/meshcp.env` to avoid that. It must be backed up with the
  database.
- Security minimum stated in the old roadmap: vendor credentials encrypted at rest, vendor tokens
  scoped as tightly as each vendor allows, never sent to nodes.

## STUN responders

Two UDP sockets, `MESH_CP_STUN_BIND` (default `0.0.0.0:3478`) and `MESH_CP_STUN_BIND2` (default
`0.0.0.0:3479`). Each answers a valid binding request with the source address it saw and ignores
anything else. Details in direct-path-and-nat.md.

## Other

- HTTP bind `MESH_CP_BIND` (default `0.0.0.0:8080`), database `MESH_CP_DB` (default
  `/var/lib/meshcp/meshcp.db`), logging `MESH_LOG` (default `info,meshcp=debug`).
- Linux only by the user's choice.
- Not built: a web UI; the API plus the CLI is the whole interface.
