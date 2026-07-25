# Tailscale authentication

How a client gets onto a tailnet without `tailscaled`. Unlike the Cloudflare side there is nothing
to reverse engineer here: the client is BSD-3 open source, the control protocol is documented by
its own implementation, and `headscale` is an independent server that speaks it. Everything below
is read out of `tailscale/tailscale`, `tailscale/tailscale-rs` or `juanfont/headscale`, or probed
directly against `controlplane.tailscale.com`.

Companion to [cloudflare-auth.md](cloudflare-auth.md). Last updated 2026-07-25.

---

## 1. The credentials, and how they mirror Cloudflare

The shape is the same as the Cloudflare side, which is convenient for the setup flow: one
credential from the human once, which mints a second credential that every device then uses
unattended.

| Layer | Cloudflare | Tailscale |
|---|---|---|
| human gives us this once | API token | API access token (`tskey-api-...`) or OAuth client (`tskey-client-...`) |
| we mint this from it | Access service token | auth key (`tskey-auth-...`) |
| device presents it to enroll | 60s enrollment JWT | the auth key directly |
| device's own crypto identity | P-256 keypair | machine key + node key |

Tailscale is the simpler of the two: the auth key is presented straight to the control server, so
there is no equivalent of Cloudflare's short-lived JWT hop in the middle.

The two top-row options are not equivalent. See §6: a personal API access token can mint
**untagged** keys, an OAuth client cannot.

Three keys the device generates for itself, none of which ever leave it:

- **machine key**, Curve25519. The device's permanent identity. It is the client static key in the
  Noise handshake, so it authenticates the control channel itself.
- **node key**, Curve25519, separate from the machine key. Tied to a login session, rotates on
  logout and re-login. This is the key that ends up in WireGuard peer config.
- **disco key**, separate again, used only for NAT traversal probing. Distributed to peers through
  the netmap.

There is also a network-lock (tailnet lock) key, `nl_key`, which `ts_control` generates and sends
even when tailnet lock is off.

---

## 2. Control plane endpoints

Verified against `controlplane.tailscale.com` on 2026-07-25.

**`GET /key?v=<capability version>`** — unauthenticated, returns the server's Noise public key:

```json
{
  "legacyPublicKey": "mkey:9e5156a4c65121306dd2d8ed8f92cb8d738e2533011344b522c5d28409bc4970",
  "publicKey": "mkey:7d2792f9c98d753d2042471536801949104c247f95eac770f8fb321595e2173b"
}
```

`legacyPublicKey` is the pre-2021 NaCl `crypto_box` key and is only populated for clients whose
advertised `v` is old enough. We use `publicKey` and ignore the other.

**`GET /derpmap/default`** — also unauthenticated, the full DERP relay map. 28 regions when
checked, each with 3 or 4 nodes. Useful before registering: we can measure DERP latency and pick a
home region without holding any credential at all.

**`/ts2021`** — the Noise transport, see below.

Everything else lives *inside* the Noise channel and is not reachable directly.

---

## 3. The TS2021 handshake

`controlbase` states it plainly: Noise IK, instantiated with Curve25519, ChaCha20Poly1305 and
BLAKE2s. Client static key is the machine key, server static key is the `publicKey` from `/key`,
so the server is authenticated by a key we fetched over TLS and the client is authenticated by
possession of its machine key. Maximum frame on the wire is 4096 bytes including the 3-byte
header.

The upgrade path is `/ts2021`. Two ways in:

- HTTP `Upgrade`, which is what the Go client does when it can hijack the connection
- WebSocket, which headscale supports for deployments behind reverse proxies that will not pass a
  raw upgrade through

Immediately after the handshake the server sends either an HTTP/2 preface or a short "early
noise" frame: a length prefix followed by that many bytes of JSON-encoded `EarlyNoise`. Headscale
uses this to reject unsupported capability versions before anything else happens, so a client has
to peek at the first 9 bytes and branch. After that it is ordinary HTTP/2, multiplexed, running
inside the Noise channel.

The capability version is the compatibility knob for the whole protocol. Headscale enforces a
minimum and will refuse an old client outright.

---

## 4. Registration

Inside the Noise channel:

```http
POST /machine/register
```

The body is a `RegisterRequest`. The fields that matter, as `ts_control` builds it:

```rust
RegisterRequest {
    version: CapabilityVersion::CURRENT,
    node_key: <node public key>,
    nl_key:   Some(<network lock public key>),
    hostinfo: HostInfo { hostname, app, ipn_version, .. },
    auth:     auth_key.map(RegisterAuth::from),   // None for interactive
    ..Default::default()
}
```

`auth` is `RegisterResponseAuth` in the Go types, and carries at most one of `AuthKey` or
`Oauth2Token`. The `Oauth2Token` variant is dead weight, used only by Android clients before 1.66.
For us it is always `AuthKey`.

Other fields worth knowing about even though the Rust client leaves them defaulted: `Expiry`
requests a key expiry (server policy may override, and setting it in the past expires the key),
`Followup` is the interactive-login poll described below, `OldNodeKey` is for key rotation, and
`Tailnet` optionally pins or suggests which tailnet to join.

`ts_control` also sets a load-balancer hint header carrying the node public key on this POST.

### Response

```go
type RegisterResponse struct {
    User              User
    Login             Login
    NodeKeyExpired    bool
    MachineAuthorized bool
    AuthURL           string   // set if authorization is pending
    // ...
}
```

Two outcomes:

- **`MachineAuthorized: true`** — done, we are on the tailnet. This is what a valid auth key gets
  you immediately.
- **`MachineAuthorized: false` with a non-empty `AuthURL`** — the human has to visit that URL and
  approve. This is the interactive path.

`ts_control` surfaces the second case as `RegistrationError::MachineNotAuthorized(Some(url))`.

---

## 5. The two ways in

### Auth key, headless

Put `tskey-auth-...` in `RegisterRequest.auth.AuthKey` and registration completes in one round
trip. This is what we want for containers and for any machine after the first.

Key properties, set at mint time:

- **reusable** — one key enrolls many devices. Needed if we mint once and bake it into an image.
- **ephemeral** — the node record is deleted automatically when it goes offline. Right choice for
  throwaway test containers, wrong for real peers we expect to persist.
- **preauthorized** — skips manual device approval if the tailnet has approval turned on.
- **tags** — applies ACL tags at provisioning time. Mandatory for keys minted via OAuth.

### Interactive, browser

Send `RegisterRequest` with `auth: None`, get back `AuthURL`, open it in the user's browser. This
is exactly what `tailscale up` does and it is the flow to use for the very first machine, since it
needs nothing from the admin console.

The Go client then re-sends the request with `Followup` set to the auth URL, and the server holds
that request open until the human finishes. **`ts_control` does not implement `Followup`.** It just
returns the error with the URL in it. So on the Rust side we either add `Followup` support or poll
by re-calling `register` on a timer until `machine_authorized` flips. Polling is fine for an MVP
and is maybe ten lines.

---

## 6. Getting an auth key

Two credentials can mint one, and the difference between them is tags.

### 6a. Personal API access token (`tskey-api-...`)

**VERIFIED against a real tailnet on 2026-07-25.** Simplest path by a distance. Pass it as a
bearer token and mint directly:

```http
POST https://api.tailscale.com/api/v2/tailnet/-/keys
Authorization: Bearer tskey-api-...
```
```json
{
  "capabilities": {"devices": {"create": {
    "reusable": true, "ephemeral": true, "preauthorized": true, "tags": []
  }}},
  "expirySeconds": 86400,
  "description": "mesh mvp"
}
```

`200` with the key in `key`, returned once only. **Empty `tags` is accepted**, which is the whole
reason to prefer this over OAuth: no tag has to exist, so no ACL edit is needed to get started.

Devices enrolled with an untagged key are owned by the user who owns the API token, so tailnet
grants that reference that user's email already cover them. Worth checking that is true of the
target tailnet before assuming reachability: on the one we tested the existing grant
`{"src": ["tag:home", "you@example.com"], "dst": ["*"]}` covers it, so new containers can
reach everything without touching the policy file.

Same token also reads `GET /tailnet/-/acl`, `GET /tailnet/-/devices` and `GET /tailnet/-/keys`.
Write access to the ACL was not tested, because nothing needed it.

`-` is shorthand for the tailnet the token belongs to.

### 6b. OAuth client (`tskey-client-...`)

Created in the admin console under Trust credentials, Credential, OAuth. Needs the `auth_keys`
scope, and at creation time you must attach one or more tags. Keys minted with it must carry a
subset of those tags, and devices enrolled with those keys get tagged automatically.

Only worth the extra setup if we want the enrolled devices tagged, or want a credential scoped
more narrowly than a personal token. For the MVP, 6a.

**Exchange the client for an access token.** Standard OAuth 2.0 client credentials:

```http
POST https://api.tailscale.com/api/v2/oauth/token
grant_type=client_credentials&client_id=...&client_secret=...
```
```json
{"access_token":"tskey-...","token_type":"Bearer","expires_in":3600,"scope":"devices"}
```

One hour, not adjustable. Mint on demand rather than caching, same discipline as the Cloudflare
JWT.

Then mint exactly as in 6a, except `tags` must be non-empty and a subset of the client's tags.

Gotcha worth knowing in advance: omitting tags on an OAuth-minted key produces
`exactly one capability scope must be populated`, which is a confusing way of saying the key has
no tags and OAuth clients cannot mint untagged keys. The tag also has to exist in the tailnet's
ACL policy, so `tag:mesh` would need a `tagOwners` entry before any of this works. None of that
applies to 6a, which is why we are not doing it.

---

## 7. What `ts_control` gives us

Version 0.4.0, on crates.io, BSD-3, last updated this month. Part of `tailscale/tailscale-rs`,
which is officially Tailscale's but is explicitly experimental and gated behind
`TS_RS_EXPERIMENT=this_is_unstable_software`. Unaudited crypto, no stability guarantees before
1.0.

Present and usable:

- `AsyncControlClient::connect(config, control_url, auth_key, ...)` does the whole sequence:
  dial, Noise handshake, register, then start the netmap stream.
- `register()` on its own if we want to drive the steps separately.
- `Config { server_url, hostname, client_name, tags, ephemeral }`, defaulting `server_url` to
  `https://controlplane.tailscale.com/`, which also means pointing it at a self-hosted headscale
  is a one-line change.
- `netmap_stream()` yielding `StateUpdate`, plus `Node`, `PeerUpdate`, `DerpMap`, `DerpRegion`,
  `TailnetAddress`.
- `ControlDialer` and `DialPlan` for the control-plane dial candidates.

Sibling crates we will want: `ts_derp` (a complete DERP client, frame codec and all),
`ts_netcheck`, `ts_disco_protocol` (the disco message codec), `ts_netstack_smoltcp`, `ts_keys`.

Not present, and this is the real gap: **magicsock**. There is no endpoint state machine, so
nothing turns disco ping/pong into an established direct path. Everything rides DERP until we
write that. Which is the plan anyway, since our prober is the path selector and phase one of the
build only needs DERP.

---

## 8. Status

Verified by probe:

- `/key` returns the server Noise public key, unauthenticated
- `/derpmap/default` returns the full relay map, unauthenticated, 28 regions
- a `tskey-api-...` token reads `/tailnet/-/acl`, `/tailnet/-/devices`, `/tailnet/-/keys`
- and mints a reusable, ephemeral, preauthorized, **untagged** auth key, so no ACL change is
  needed to enroll devices into an existing tailnet

Verified by reading working code:

- Noise IK / Curve25519 / ChaCha20Poly1305 / BLAKE2s at `/ts2021`, 4096 byte frames
- the early-noise prefix and capability version gate
- `RegisterRequest` field set and both authorization outcomes
- `ts_control`'s API surface and the `Followup` gap

Verified by our own client, in two Linux containers, on 2026-07-25:

- `ts_control` 0.4.0 registers against the live control plane with an untagged auth key and
  interoperates fine. Both containers appeared on the tailnet and were assigned addresses.
- `ts_derp` carries real traffic between two of our own nodes, round trip around 90ms within
  one region.
- the netmap arrives, peers resolve by hostname, and node keys from it address DERP correctly.

Notes from doing it:

- `ts_control::Config` in 0.4.0 has no `ephemeral` field. Ephemerality is a property of the auth
  key, set when you mint it, not of the client.
- `TailnetAddress.ipv4`/`.ipv6` are `ipnet` network types, not `Option`. Call `.addr()`.
- `PeerUpdate::Delta` reports removals by node id while the obvious peer table is keyed by
  hostname, so keep the id around or removals silently never apply.
- `ts_control` does not implement `Followup`, so interactive login needs polling. Not exercised:
  we use auth keys.

### Choosing a DERP region is harder than it looks

The control plane assigns a home region, but that assignment only means something once a client
reports measured latency to it, which `ts_control` does not do and we do not either. Trusting it
put a Singapore container on the New York relay and added half a second to every packet.

Measuring it ourselves took three attempts:

- **TCP connect time**: useless from inside a container. It reported 9ms to New York from
  Singapore because something local completes the handshake. It picked nonsense regions.
- **UDP STUN on port 3478**: the correct approach, and what Tailscale's own netcheck uses, but
  blocked outright on this network. Nothing answered, from the container or the host.
- **A full HTTPS request** to `https://<derp host>/derp/latency-check`: works. TLS has to reach
  the real server to produce a valid certificate, so nothing local can fake it. Singapore
  measured 69ms against New York's 576ms, which is the discrimination we needed.

Still open:

- reporting our measured latencies back with `set_home_region`, so the control plane's own
  assignment becomes meaningful
- everything about direct paths, which still needs disco and an endpoint state machine

---

## References

- [tailscale/tailscale](https://github.com/tailscale/tailscale) — [tailcfg](https://pkg.go.dev/tailscale.com/tailcfg), [controlbase](https://github.com/tailscale/tailscale/blob/main/control/controlbase/conn.go), [controlhttp](https://github.com/tailscale/tailscale/blob/main/control/controlhttp/constants.go), [disco](https://github.com/tailscale/tailscale/blob/main/disco/disco.go), [magicsock](https://github.com/tailscale/tailscale/tree/main/wgengine/magicsock)
- [tailscale/tailscale-rs](https://github.com/tailscale/tailscale-rs) — [ts_control on docs.rs](https://docs.rs/ts_control/latest/ts_control/)
- [juanfont/headscale](https://github.com/juanfont/headscale) — [noise.go](https://github.com/juanfont/headscale/blob/main/hscontrol/noise.go)
- [Auth keys](https://tailscale.com/docs/features/access-control/auth-keys), [OAuth clients](https://tailscale.com/docs/features/oauth-clients), [API reference](https://tailscale.com/docs/reference/tailscale-api)
