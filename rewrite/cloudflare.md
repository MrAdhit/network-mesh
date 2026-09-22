# Cloudflare backhaul

Cloudflare Mesh lets devices enrolled in a Zero Trust org reach each other through Cloudflare's
edge. It always relays via the nearest datacenter, never peer to peer, which is fine: it's our
relayed path. Consumer WARP can't reach other devices at all; device-to-device needs a Zero Trust
org. We enroll as a WARP device over the API and speak MASQUE (Connect-IP over HTTP/3) ourselves.

What the old project learned from: `usque` (reverse-engineered WARP MASQUE client), `wgcf`,
`Boostport/setup-cloudflare-warp` (shows service-token MDM enrollment), Cloudflare's docs, and a
lot of testing against a real org. Everything below ran end to end against a real org unless it
says otherwise. It's undocumented and could change under us.

## Four credentials, don't mix them up

| credential | scope | who holds it | used for |
|---|---|---|---|
| API token (Account > Zero Trust > Edit) + account id | whole account | control plane only | provisioning the org, deleting devices |
| Access service token (client id ending `.access` + secret) | the org | every node, via the roster | minting enrollment JWTs with no browser |
| device registration (id + token) | one device | that node, forever | API calls about that device |
| P-256 key pair | one device | that node | data-plane mutual TLS |

## Org provisioning (control plane, on `set-cloudflare`)

Base `https://api.cloudflare.com/client/v4`, header `Authorization: Bearer <api token>`.
Responses are `{"success": bool, "errors": [...], "result": ...}`.

1. `GET /accounts/{acct}/tokens/verify`: fail early on a bad token. (This is the account-owned
   token endpoint. A user-owned token verifies at `/user/tokens/verify`; the old code didn't
   handle that. Unverified whether it matters.)
2. `GET /accounts/{acct}/access/organizations` → `result.auth_domain`, e.g.
   `team.cloudflareaccess.com`. Team name = first label. No org → tell the user to create one.
3. `GET /accounts/{acct}/access/apps` → the app with `"type": "warp"` (the WARP login app). None
   → WARP device enrollment isn't enabled on the org.
4. `POST /accounts/{acct}/access/service_tokens` with `{"name": "mesh-enrollment"}` → `id`
   (uuid), `client_id`, `client_secret`. The secret is only returned here.
5. `GET /accounts/{acct}/access/apps/{app_id}/policies`. Delete any policy named
   `mesh-service-auth` (ours from a previous run). New precedence = highest precedence among the
   remaining policies + 1. Cloudflare requires unique precedences per app, so a fixed number
   breaks on the second run.
6. `POST /accounts/{acct}/access/apps/{app_id}/policies`:
   ```json
   {"name": "mesh-service-auth", "decision": "non_identity", "precedence": N,
    "include": [{"service_token": {"token_id": "<service token id>"}}]}
   ```
   `non_identity` is the API's name for the "Service Auth" action. A service token on a normal
   Allow rule does not work. Leave the existing policies alone so humans can still enroll through
   the browser.

Stored sealed on the control plane: `api_token`, `account_id`, `team`, `service_client_id`,
`service_client_secret`. Nodes get only the last three.

Not done by the old code but in the docs: check `GET /accounts/{acct}/devices/settings` has
`use_zt_virtual_ip: true` (the Mesh prerequisite, a unique IP per device) and
`GET /accounts/{acct}/devices/policies` has `tunnel_protocol: "masque"`. Both were already true on
the test org. Also, re-provisioning never deleted the previous service token, so they pile up.

## Device enrollment (node, first start with Cloudflare configured)

Three calls, no browser.

**1. Enrollment JWT.**

```http
GET https://<team>.cloudflareaccess.com/warp
CF-Access-Client-Id: <client id>
CF-Access-Client-Secret: <client secret>
```

Don't follow redirects. Success is a 302 with
`Location: com.cloudflare.warp://<team>.cloudflareaccess.com/auth?token=<JWT>`; take everything
after `token=`. A rejected service token is *also* a 302, to the Access login page (its `meta`
JWT says `service_token_status: false`), so test the Location scheme, not the status code. The
JWT lives exactly 60s (claims include `"warp": true`, email `non_identity@<team>...`). Mint it
right before step 2 and never cache it.

**2. Register.**

```http
POST https://api.cloudflareclient.com/v0a4471/reg
User-Agent: WARP for Android
CF-Client-Version: a-6.35-4471
Content-Type: application/json; charset=UTF-8
CF-Access-Jwt-Assertion: <JWT>

{"key": "<base64 of 32 random bytes>", "install_id": "", "fcm_token": "",
 "tos": "2026-07-25T13:33:25.000+00:00", "model": "PC", "serial_number": "<16 hex chars>",
 "os_version": "", "key_type": "curve25519", "tunnel_type": "wireguard", "locale": "en_US"}
```

- The curve25519 key is a throwaway; the Android app sends one so we do too.
- The `tos` format is exactly `YYYY-MM-DDTHH:MM:SS.000+00:00`, current UTC.
- The build number in the path (`v0a4471`) must match the one in `CF-Client-Version`. This pinning
  is the most fragile part of the whole integration; Cloudflare retires old versions. Keep it
  configurable. The `a-` prefix means Android and devices show up as `android` in the org's list
  (`l-` would show Linux).
- Response (`AccountData`), fields that matter: `id` (`t.<uuid>` for Zero Trust; keep the prefix in
  `/reg` paths), `token` (bearer for this device, only ever returned by this call), `account`
  (`account_type: "team"`, `organization`), `config.client_id`,
  `config.peers[0].public_key`, `config.peers[0].endpoint.{v4,v6,host,ports}`,
  `config.interface.addresses.{v4,v6}`, `policy.tunnel_protocol` (`"masque"`),
  `policy.include[].address`. It also carries `policy.post_quantum`, which the old code didn't parse.
- The old parser treated `config.client_id`, `config.peers`, `config.interface.addresses.v4/.v6`
  and each peer's `endpoint.v4/.v6` as required, so a response missing any of them failed
  enrollment. Everything else was optional.

**3. Switch to MASQUE.**

```http
PATCH https://api.cloudflareclient.com/v0a4471/reg/{id}
(same three client headers)
Authorization: Bearer <device token>

{"key": "<base64 DER SPKI of a new P-256 public key>", "key_type": "secp256r1",
 "tunnel_type": "masque", "name": "<node name>"}
```

This response is the one to persist; IPs and endpoints can differ from step 2. The assigned IPv4
survived the switch in testing; `client_id` didn't.

Persist: device id, device token, the P-256 private key (PKCS#8 DER, base64), endpoint v4 and v6,
endpoint ports, endpoint public key, our v4 and v6 addresses, the `policy.include` ranges. Reuse
them on every start. Only enroll when there's nothing saved.

Two traps in how the old code did this:

- Nothing was saved until the PATCH succeeded and returned a peer. If `POST /reg` worked and the
  PATCH failed, that device was abandoned, and the startup retry loop registered a fresh one on
  every attempt (about once a minute at full backoff), none of them ever deleted. Save the
  registration as soon as step 2 returns, then resume at step 3.
- A saved registration was reused forever with no fallback to re-enrolling. After `remove-node`
  deletes the device on Cloudflare's side, a node that rejoins still uses its saved one, so its
  Cloudflare path is probably dead from then on (unverified).

Facts about the response:

- Endpoints look like `162.159.197.2:0` and `[2606:4700:102::2]:0`. The port is meaningless; use
  `ports` (seen: `[443, 500, 1701, 4500, 4443, 8443, 8095]`). Zero Trust endpoints differ from the
  consumer anycast `162.159.198.1`. Always take them from the response.
- The endpoint public key is a PEM `BEGIN PUBLIC KEY` block for Zero Trust MASQUE and bare base64
  for consumer WireGuard. Accept both, end up with DER SPKI.
- The Mesh address range is org-configurable. The documented default is `100.96.0.0/12`; the test
  org used `10.96.0.0/16` and assigned `10.96.0.1`. Read it off `policy.include`, never assume.
- Registering straight as `masque` in step 2 (skipping the WireGuard step) is untested.

## Data plane: Connect-IP over QUIC

Auth is mutual TLS and nothing else. The client certificate is self-signed over the enrolled P-256
key. The subject doesn't matter: the old code saved only the key, minted a cert from it (SAN
`mesh`) at each bring-up, and reused that cert across reconnects. The official client mints a 24h
cert per connection, which is cosmetic. Cloudflare matches the certificate's key against the
enrolled one. There's no bearer token on the tunnel. Wrong key: CONNECT fails with 401/403 or
`tls: access denied`.

QUIC and TLS:

- UDP to endpoint IP and port. Try SNI `zt-masque.cloudflareclient.com` first (verified correct
  for org devices; usque has it as an "unused" constant), then `consumer-masque.cloudflareclient.com`.
  For each SNI, the first 3 ports from the list (default `[443]` if empty). The old code only ever
  dialled the IPv4 endpoint; the v6 one was saved and never used.
- The server certificate never matches the SNI, so normal verification can't work. Pin it
  instead: the DER SPKI of the enrolled endpoint key must appear inside the server's end-entity
  certificate (a byte substring check; the SPKI appears verbatim in the DER). You also need to
  verify the TLS 1.3 handshake signature against that key. The old code skipped that, and also
  accepted any certificate when the saved key didn't decode, so the pin was bypassable
  (known-problems.md). A successful pin was confirmed against the real endpoint: the SPKI from
  enrollment does appear in the certificate it presents.
- TLS 1.3 only, ALPN `h3`, no early data.
- QUIC datagrams (RFC 9221) must be negotiated; fail if the server doesn't enable them.
- Initial MTU 1242 (what the official client uses), idle timeout 30s, keepalive 10s, datagram send
  and receive buffers 4 MiB, handshake timeout 8s.

HTTP/3, only what's needed. Hand-rolled because Cloudflare breaks RFC 9484 in three ways that make
compliant libraries refuse: the protocol token is `cf-connect-ip` not `connect-ip`, the server
never advertises `ENABLE_CONNECT_PROTOCOL`, and it never sends routes.

1. Open three unidirectional streams and **keep all three open for the connection's lifetime**:
   control (stream type `0x00`, then a SETTINGS frame), QPACK encoder (`0x02`), QPACK decoder
   (`0x03`). They're critical streams; if one closes the server kills the connection with
   `H3_CLOSED_CRITICAL_STREAM` (260). In Rust, dropping a quinn `SendStream` closes it, so the
   handles have to be stored somewhere that lives as long as the tunnel.
2. SETTINGS (frame type `0x04`): `H3_DATAGRAM` (`0x33`) = 1, `ENABLE_CONNECT_PROTOCOL` (`0x08`) = 1.
3. **Wait for the server's control stream and its SETTINGS** (5s cap) before sending CONNECT.
   Cloudflare silently ignores a request that arrives earlier. Don't check what the settings say.
4. Open a bidirectional stream and send one HEADERS frame (`0x01`). QPACK field section: two zero
   bytes (required insert count 0, delta base 0), then each field as "literal field line with
   literal name" with no Huffman: first byte `0b0010_0000` | name length (3-bit prefix integer),
   the name, then the value length (7-bit prefix integer, H bit 0), the value.
   ```
   :method      CONNECT
   :protocol    cf-connect-ip
   :scheme      https
   :authority   cloudflareaccess.com
   :path        /
   capsule-protocol  ?1
   user-agent   (empty string)
   ```
   `capsule-protocol: ?1` is required (RFC 9297; connect-ip-go adds it automatically, which is why
   usque never mentions it). Without it Cloudflare never answers at all.
5. Read the response stream, parse frames, and **skip every frame that isn't HEADERS**. Cloudflare
   sends GREASE frames first (random reserved type, payload literally `GREASE is the word`). A
   parser that only looks at the first frame, or errors on unknown types, waits forever for a
   response that already arrived. Decode `:status` from the first HEADERS: it'll be an indexed
   static-table entry (index 25 = 200; the :status entries are 24-28 and 63-71) or a literal.
   Need 200 within 8s. A `Cf-Team` header comes back on success.
6. No routes, no body. Once you have the 200, start sending.

Datagrams: `varint(request stream id / 4)` (the "quarter stream id"), `varint(context id = 0)`,
then the raw IP packet. On receive, skip anything for another stream or context. QUIC varints use
the top 2 bits as the length (1, 2, 4 or 8 bytes).

All three of those failures (closed critical stream, missing capsule-protocol, not skipping GREASE)
look the same from the client: "the server accepted QUIC and then ignored me". To isolate them,
first check the HTTP/3 code against an ordinary server: a plain GET to `cloudflare-quic.com`
returning 200 proves QPACK, framing and status decoding. The old repo had an `h3check` example for
exactly that.

## Keeping it up

- A MASQUE tunnel is one QUIC connection. A network drop kills it for good, so it has to be
  rebuilt. An earlier version's receive loop broke out on the first error and the path stayed
  dead until the daemon restarted, while the node kept advertising Cloudflare as available.
- What `a324c0b` does: the receive side notices the dead connection and redials (same SNI and port
  sequence), backoff 1s doubling to 30s, never gives up. Single-flight: one reconnect at a time,
  and a caller that finds the tunnel already replaced does nothing.
- Detection is slow. After a network drop quinn keeps accepting datagrams until the connection's
  idle timeout (30s) declares it dead; until then they're silently lost and probes get charged as
  losses. The reconnect only starts once the receive side errors. After that, sends fail, and
  failed sends weren't counted at all (path-selection.md), so the path only dropped out when its
  last reply was 15s old.
- If Cloudflare fails at startup, the daemon carries on and a background task retries the whole
  bring-up (enroll if needed, then connect) with backoff 5s doubling to 60s, then adopts it.

## Cleaning up devices

- Cloudflare never ages our devices out. It does that from telemetry the real client sends, and
  we never send any, so each device reads as "seen once" forever. A test account had 20 devices,
  all ours.
- The node reports its device id to the control plane on roster refreshes (`cf_device=<id>`),
  since the control plane never sees the registration happen. When a node is removed the control
  plane calls `DELETE /accounts/{acct}/devices/{device_id}` with the API token. Best effort, after
  the node's row is already gone, so a slow Cloudflare API can't turn a removal into an error.
- In the old code the id was captured once at startup and not sent by the startup fetch, so a
  device enrolled later by the retry task was never reported until the next restart, and removing
  that node leaked it.
- Unverified: the docs say the account-level device API reports ids without the `t.` prefix, and
  the old code sent the prefixed id. The delete may have been failing quietly (failures were only
  logged).

## Quirks worth knowing

- **A freshly enrolled device isn't reachable by peers for the first minute or two**, even with
  healthy tunnels on both ends and correct addresses. It sorts itself out. It looks exactly like a
  client bug and cost debugging time twice. Ignore a new node's Cloudflare stats for the first
  minute.
- A few percent datagram loss is normal.
- Two Mesh devices exchanged UDP inside the tunnel at roughly 30 ms from Singapore.
- Documented in the old docs but never built: an HTTP/2 fallback for networks that block QUIC (TCP
  to `162.159.198.2`, same TLS, extra headers `cf-connect-proto: cf-connect-ip` and
  `pq-enabled: false`). It would be a free fourth path. Note the registration reports
  `post_quantum: "enabled_with_downgrades"`, which may matter for that `pq-enabled` header.
- The browser enrollment route, for reference only: `https://<team>.cloudflareaccess.com/warp` →
  SSO → redirect to `com.cloudflare.warp://<team>.cloudflareaccess.com/auth?token=<JWT>`.
- The original plan flagged checking Cloudflare's terms of service before using a custom client
  beyond personal use.
