# Tailscale backhaul

Only DERP relaying is used. We register a node on the user's tailnet so Tailscale's DERP servers
will relay for us, then send our own frames to peers' node keys through DERP. No WireGuard, no
disco, no magicsock, and tailnet IPs aren't used for traffic.

## Credentials and auth keys

- The user gives the control plane a personal API access token (`tskey-api-...`). It's checked on
  `set-tailscale` with `GET https://api.tailscale.com/api/v2/tailnet/-/devices` (bearer); the status
  shown is "<n> devices visible". `-` means the token's own tailnet.
- A node asks the control plane for an auth key every time it registers. The control plane mints
  one:
  ```http
  POST https://api.tailscale.com/api/v2/tailnet/-/keys
  Authorization: Bearer tskey-api-...

  {"capabilities": {"devices": {"create": {
     "reusable": true, "ephemeral": true, "preauthorized": true, "tags": []}}},
   "expirySeconds": 3600, "description": "mesh node"}
  ```
  → `{"key": "tskey-auth-..."}`, returned once.
- **Untagged** keys are allowed with a personal API token and not with an OAuth client. OAuth-minted
  keys must carry tags, those tags must exist in the ACL's `tagOwners`, and leaving tags off gives
  the confusing error `exactly one capability scope must be populated`. Untagged devices belong to
  the token's owner, so ACL grants for that user already cover them (true on the test tailnet;
  worth checking on others).
- **Ephemeral**: offline node records get reaped. That's why nodes fetch a fresh key whenever they
  (re)register instead of keeping one; coming back after a long stop just works.
- OAuth clients (`tskey-client-...`, `auth_keys` scope, token exchange at
  `POST /api/v2/oauth/token` with `grant_type=client_credentials`, 1h access tokens) are the tighter
  production option. Not implemented.

## Registration and DERP, via tailscale-rs 0.4

- Crates `ts_control` (TS2021 control protocol, registration, netmap stream), `ts_derp` (DERP
  client), `ts_keys` (keys with serde persistence). Official Tailscale crates but experimental,
  unaudited, no stability promise before 1.0. The docs mention a
  `TS_RS_EXPERIMENT=this_is_unstable_software` gate; the old code never set it and worked with
  these three crates, so it's probably only on the umbrella crate (unverified).
- Keys are generated once and saved to `$STATE/tailscale-keys.json` (ts_keys `PersistState`,
  JSON). Reused across restarts.
- `ts_control::Config { hostname: <node name>, client_name: "mesh", .. }`. The server URL defaults
  to `https://controlplane.tailscale.com/`; `MESH_TS_CONTROL_URL` overrides it (headscale would
  work). In 0.4 ephemerality is a property of the auth key, not a Config field.
- `AsyncControlClient::connect(&cfg, &keys, Some(auth_key))` returns the client and the netmap
  stream. Keep the client alive as long as the backhaul exists.
- From the stream, wait up to 30s each for our own node (our tailnet addresses and a suggested
  home DERP region) and for the DERP map. Keep tracking peers in the background:
  `PeerUpdate::Full` replaces the table, `PeerUpdate::Delta { upsert, remove }` patches it, and
  removals come as node ids, so key the table by node id or removals never apply. A
  `pop_browser_url` update means the auth key was rejected and interactive login is wanted; log it.
- `TailnetAddress.ipv4` / `.ipv6` are ipnet types; use `.addr()`.
- DERP: `ts_derp::DefaultClient::connect(region.servers.iter(), &keys.node_keys)`, then
  `send_one(peer_node_key, bytes)` and `recv_one() -> (source node key, bytes)`.
- Measured: about 90 ms round trip between two of our nodes in one region.

## Picking the DERP region

- A DERP server only relays between clients connected to it. If two nodes pick different regions
  they can't reach each other at all, and the Tailscale path just shows 100% loss with no error.
  This worked by luck for a while because both test containers kept measuring the same region.
- So the whole network uses one region. The roster carries `derp_region`. It's set by the first
  node that reports a measurement (roster poll with `derp=<id>`), first writer wins, and it never
  changes after that. A slightly further relay everyone shares beats a closer one that isolates
  somebody.
- Node side: if the roster's region is in the DERP map and has servers, use it. Otherwise measure
  every region that has servers and isn't flagged `no_measure_no_home`: time a full HTTPS GET to
  `https://<first server hostname>/derp/latency-check` (4s timeout, any response counts), take the
  fastest, report it on roster polls. If nothing answers, use the first usable region.
- That was the intent. The old node never actually enforced it: it read `derp_region` only from
  the startup roster, reported its own region only on the 30s refreshes and only if Tailscale came
  up at startup, and DERP reconnects reused the servers of whatever region it first connected to.
  So a node kept its own measured region until restart if it started within about 30s of another
  node on a fresh network and lost the first-writer race, booted while the control plane was down,
  or got Tailscale through the retry task. Its DERP path to the others then read 100% loss. A
  rewrite should re-read the agreed region and move to it.
- Don't trust the home region the control plane suggests. It only means something once a client
  reports latencies to it (`set_home_region`, never implemented). Trusting it put a Singapore node
  on New York and added half a second per packet.
- Latency methods that failed: TCP connect time (inside a container something local completes the
  handshake; it said 9 ms to New York from Singapore) and UDP STUN on 3478 (blocked on the dev
  network). A full TLS request can't be faked locally and worked: Singapore 69 ms vs New York 576 ms.
- The DERP map is also served unauthenticated at `https://controlplane.tailscale.com/derpmap/default`
  (28 regions when checked).

## Addressing a peer on DERP

- Authoritative: the node key a peer's traffic arrived from. Once learned, use only that.
- Bootstrap, before any traffic: find the peer's name in the netmap. Tailscale dedupes colliding
  hostnames with a numeric suffix (`mesh-b-1`), and a restarted ephemeral node leaves its dead
  predecessor in the netmap, still looking online for a while and holding the original name.
  Preferring the exact name reliably picks the corpse. So match `name` or `name-<digits>` and send
  to every match (online first, newest node id first). A packet to a dead key is just dropped by the
  relay. Measured: loss to a restarted Windows peer went from 79% to 0%.
- The name looked up is the peer's roster name. That's fixed when the node first enrolls (a
  re-enroll keeps the old record and there's no rename), while the hostname a node registers with
  Tailscale is its local name at each start. They drift apart if the local name changes after
  enrollment (a recreated container with a new `HOSTNAME`, say), and then the bootstrap lookup
  misses.
- Hazard, unverified: Tailscale may normalise hostnames (case, invalid characters), which would break
  the bootstrap match for names like `DESKTOP-ABC`.
- A cleaner option exists: have each node report its Tailscale node key to our control plane and
  put it in the roster, so the netmap isn't needed at all. See known-problems.md.

## Keeping it up

- A broken DERP connection stays broken ("Broken pipe" forever) unless replaced.
- What `a324c0b` does: the receive loop reconnects inline (retry until success, backoff 1s
  doubling to 30s, never gives up; single-flight plus an "already replaced?" check). A failed
  *send* returns its error right away and starts the reconnect in a background task. The send must
  not wait for the reconnect. An earlier version did, which parked the probe loop for the whole
  outage and aged out every path, healthy ones included.
- If Tailscale fails at startup, the daemon carries on and a background task retries (fresh auth
  key each time) with backoff 5s doubling to 60s, then adopts it.
- If the ts_control netmap stream ends, the old code only logged it. Nothing re-registered, so the
  peer table used for DERP bootstrap stayed frozen for the life of the backhaul (DERP reconnects
  only replace the DERP client).

## The control protocol, if ts_control ever has to be replaced

Read from tailscale/tailscale, tailscale-rs and headscale; the probes were run against
`controlplane.tailscale.com`.

- `GET /key?v=<capability version>` (unauthenticated) → `{"publicKey": "mkey:...",
  "legacyPublicKey": "mkey:..."}`. Use `publicKey`; the legacy one is for old clients.
- `/ts2021`: upgrade via HTTP Upgrade (or WebSocket, which headscale supports behind proxies).
  Noise IK with Curve25519, ChaCha20-Poly1305, BLAKE2s. Client static key = machine key, server
  static key = `publicKey` from `/key`. Max 4096 bytes per frame including the 3-byte header.
- Right after the handshake the server sends either an HTTP/2 preface or an "early noise" frame
  (length prefix + JSON `EarlyNoise`); peek at the first bytes and branch. Headscale uses it to
  reject old capability versions. Then it's ordinary HTTP/2 inside the Noise channel.
- `POST /machine/register` inside it: `RegisterRequest { version, node_key, nl_key, hostinfo {
  hostname, .. }, auth { AuthKey } }`. `MachineAuthorized: true` means done. `false` with an
  `AuthURL` means a human has to approve (interactive; ts_control doesn't implement `Followup`, so
  that would mean polling).
- Keys a device owns: machine key (permanent identity, authenticates the control channel), node key
  (tied to a login; it's what DERP addresses), disco key (NAT traversal, unused by us), and a
  tailnet-lock key `nl_key` that ts_control sends even with tailnet lock off.
