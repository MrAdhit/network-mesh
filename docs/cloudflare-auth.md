# Cloudflare WARP / Mesh authentication

How a client gets onto Cloudflare's network without `warp-svc`. Everything here is either read
out of open-source clients (`usque`, `wgcf`, `Boostport/setup-cloudflare-warp`), taken from
Cloudflare's own docs, or observed directly against a real Zero Trust org, which appears
throughout as `example`. Anything still a guess is marked **UNVERIFIED** with the test that would
settle it.

Last updated 2026-07-25.

---

## 1. There are three separate credentials

People conflate these constantly. They are not interchangeable.

| Credential | Scope | Who holds it | Used for |
|---|---|---|---|
| **Cloudflare API token** | the whole account | the human, once | configuring the Zero Trust org: device profiles, enrollment policies, minting service tokens |
| **Access service token** (`auth_client_id` + `auth_client_secret`) | the org | every device, shared | proving "this machine may enroll" without a browser |
| **Device registration** (`id` + `token`) | one device | that device, forever | all subsequent API calls about this device |

The API token never touches device registration. It exists to set the org up so that device
registration can happen unattended. Getting this wrong was the original mistake in our plan.

Separately, and confusingly, the *data plane* has its own credential that is none of the above:
a P-256 keypair whose public half you enroll over the API and whose private half signs a TLS
client certificate. See §5.

---

## 2. The API surface

Base URL is `https://api.cloudflareclient.com/v0aNNNN`, where `NNNN` must agree with the build
number in the `CF-Client-Version` header. `usque` currently pins:

```
User-Agent:        WARP for Android
CF-Client-Version: a-6.35-4471
Content-Type:      application/json; charset=UTF-8
Connection:        Keep-Alive
```

against `/v0a4471`. The `a-` prefix is the platform (Android). This version pinning is the most
fragile part of the whole integration: Cloudflare moves it and old versions eventually stop being
accepted, so it needs to be a config value, not a constant baked into the binary.

---

## 3. Step one: register the device (anonymous)

```http
POST /v0a4471/reg
```
```json
{
  "key": "<base64 curve25519 pubkey>",
  "install_id": "",
  "fcm_token": "",
  "tos": "2026-07-25T00:00:00.000+00:00",
  "model": "PC",
  "serial_number": "<random android-looking serial>",
  "os_version": "",
  "key_type": "curve25519",
  "tunnel_type": "wireguard",
  "locale": "en_US"
}
```

No auth header. Consumer WARP registration is genuinely anonymous.

The WireGuard key here is throwaway. `usque` generates one, sends the public half, and discards
the private half immediately: it exists only so the request looks like the Android app's. We do
the same. The real key material comes in step two.

Response is an `AccountData` object. The fields that matter:

| Field | Meaning |
|---|---|
| `id` | device registration ID, used in every later path |
| `token` | bearer token for later calls about this device. **Only returned on this call** |
| `account.id` | the WARP account |
| `account.license` | WARP+ license key, if any |
| `config.client_id` | short client identifier |
| `config.interface.addresses.v4` / `.v6` | the IPs assigned to this device |
| `config.peers[0].public_key` | endpoint public key |
| `config.peers[0].endpoint.v4` / `.v6` / `.host` / `.ports` | where the tunnel lives |
| `policy.tunnel_protocol` | what mode the org wants |

Save `id` and `token` immediately. `token` is never shown again.

---

## 4. Step two: switch the device to MASQUE

Generate an ECDSA P-256 keypair. Serialise the public key as ASN.1 DER SPKI, base64 it, and
PATCH it onto the registration:

```http
PATCH /v0a4471/reg/{id}
Authorization: Bearer {token}
```
```json
{
  "key": "<base64 DER SPKI of P-256 pubkey>",
  "key_type": "secp256r1",
  "tunnel_type": "masque",
  "name": "<optional device name>"
}
```

The response is another `AccountData`, and *this* is the one to persist, because the assigned IPs
and endpoints can differ from step one. Map it to our own config like `usque` does:

| Ours | From |
|---|---|
| `private_key` | the P-256 private key we just generated (base64) |
| `endpoint_v4` / `endpoint_v6` | `config.peers[0].endpoint.v4` / `.v6`, port stripped |
| `endpoint_pub_key` | `config.peers[0].public_key` |
| `ipv4` / `ipv6` | `config.interface.addresses.v4` / `.v6` |
| `id` | `id` |
| `access_token` | `token` from step one |

Registering directly as `masque` in step one instead of doing the WG-then-switch dance is
plausible but untested. **UNVERIFIED** — worth trying, since it halves the setup, but the
two-step version is known to work so it is what we implement first.

`usque` also exposes this as a separate `enroll` command that re-runs only the PATCH against an
existing registration. Useful for rotating keys or refreshing assigned IPs without making a new
device.

---

## 5. The data plane: mutual TLS, not a token

This is where our original notes were wrong. There is no bearer token on the tunnel. The device's
identity on the data plane is a **TLS client certificate**, self-signed over the same P-256 key
whose public half we enrolled in §4. Cloudflare matches the certificate's public key against the
enrolled one. That is the entire authorisation check. Present the wrong key and the CONNECT fails
with `tls: access denied`.

Connection setup:

- QUIC to `endpoint_v4`/`endpoint_v6` on port 443. Historically the anycast address is
  `162.159.198.1`.
- `ServerName` = `consumer-masque.cloudflareclient.com`. This does **not** match the endpoint, so
  normal verification cannot work: disable it and instead pin the server cert's public key
  against `endpoint_pub_key` by hand.
- ALPN `h3`. Datagrams enabled. Initial packet size 1242 to match the real client.
- Client certificate = self-signed cert over our P-256 key.

Then an extended CONNECT:

```
:method    CONNECT
:protocol  cf-connect-ip
:scheme    https
:authority cloudflareaccess.com
:path      /
```

Three ways Cloudflare departs from RFC 9484, all of which break a compliant client:

1. The protocol token is `cf-connect-ip`, not `connect-ip`.
2. The server never advertises `ExtendedConnect`, so libraries that check will refuse to proceed.
3. The server never sends any routes. Do not wait for them. Once you have a 200, start sending.

After the 200, raw IP packets go across as QUIC datagrams per RFC 9221. A `Cf-Team` header comes
back on the response, which is a handy signal that the org side worked.

There is also a TCP/HTTP-2 fallback for networks that block QUIC: connect to `162.159.198.2`,
same TLS setup, and add `cf-connect-proto: cf-connect-ip` plus `pq-enabled: false` as headers.
Worth wiring up early since it is effectively a third path for free.

The official client mints a fresh 24-hour client certificate per connection. Cosmetic: whoever
holds the private key can mint their own, so we generate one and keep it.

### Zero Trust endpoints differ from consumer

The numbers above are the consumer anycast. A Zero Trust device gets different ones. Observed
after the MASQUE enroll:

```
endpoint.v4    162.159.197.2:0
endpoint.v6    [2606:4700:102::2]:0
endpoint.ports [443, 500, 1701, 4500, 4443, 8443, 8095]
```

versus the consumer `162.159.198.1`. Take the endpoint from the enroll response, never hardcode.
The multiple ports are alternatives to try when 443 is blocked, which gives us cheap extra paths.

The peer public key also comes back in a different encoding for Zero Trust MASQUE: a PEM
`-----BEGIN PUBLIC KEY-----` block, where consumer WireGuard returns raw base64. Handle both.

**VERIFIED.** The Zero Trust SNI is `zt-masque.cloudflareclient.com`, on port 443. `usque`
carries that constant labelled "unused for now"; it is in fact the right one for an org-enrolled
device. Our client tries it first and falls back to `consumer-masque`.

---

## 6. Zero Trust: the org-bound variant

Everything above is consumer WARP, which is an egress tunnel to Cloudflare's edge. It cannot
reach your other devices. Device-to-device is **Cloudflare Mesh** (shipped 2026-04-14, absorbed
the old WARP Connector / warp-to-warp), which needs the device enrolled into a Zero Trust org.
Mesh relays everything through the nearest Cloudflare datacenter and is never peer-to-peer,
which is fine: it is our relayed racer by design.

`100.96.0.0/12` is the Mesh default that a fresh Cloudflare account gets, and it is what the docs
quote. It is not universal: the range is org-configurable. The org we tested had `10.96.0.0/16`
set manually, and accordingly assigned us `10.96.0.1` and `2606:4700:cf1:1000::2`, matching the
ranges the registration response reports in its own `policy.include`:

```json
"include": [ {"address": "10.96.0.0/16"}, {"address": "2606:4700:cf1:1000::/64"} ]
```

So never hardcode either range. Read it off `policy.include` per org. Assuming the documented
`100.96.0.0/12` would have been wrong on the very first org we tried.

Enrolling into an org is the same `POST /reg` as §3 plus one header:

```
CF-Access-Jwt-Assertion: <enrollment JWT>
```

So the whole Zero Trust problem reduces to: how do we get that JWT?

### 6a. The browser route (works today, ugly)

The org's enrollment app is at `https://<team>.cloudflareaccess.com/warp`. Observed against a
real org:

```
GET https://example.cloudflareaccess.com/warp
→ 302 https://example.cloudflareaccess.com/cdn-cgi/access/login/example.cloudflareaccess.com
       ?kid=<app aud tag>&meta=<JWT>&redirect_url=%2Fwarp
```

The `meta` JWT in that redirect is unsigned-to-us metadata but readable, and useful for
debugging. Its payload carries `aud` (the app's AUD tag), `hostname`, `redirect_url`,
`auth_status`, and two fields that are direct test signals:

- `service_token_status` — `false` when no valid service token was presented
- `is_warp` — `false` when the request did not come from a WARP client

After the human finishes SSO, the success page hands over the token by redirecting to a custom
protocol handler:

```
com.cloudflare.warp://<team>.cloudflareaccess.com/auth?token=<JWT>
```

which is what `warp-cli registration token "<that whole URL>"` consumes. Reports put the token's
validity at roughly 30 seconds, so it is grab-and-use. Fine for a one-off spike, unacceptable as
our product flow.

### 6b. The service token route (documented, this is what we want)

Cloudflare documents `auth_client_id` / `auth_client_secret` as MDM parameters that let the
official client enroll with no user interaction at all. Confirmed by reading
`Boostport/setup-cloudflare-warp`, a GitHub Action that enrolls WARP in CI: it writes
`/var/lib/cloudflare-warp/mdm.xml` (Linux), a managed plist (macOS), or
`C:\ProgramData\Cloudflare\mdm.xml` (Windows) containing exactly:

```xml
<key>organization</key>        <string>example</string>
<key>auth_client_id</key>      <string>...access</string>
<key>auth_client_secret</key>  <string>...</string>
<key>service_mode</key>        <string>warp</string>
```

and then just runs `warp-cli connect`.

Those two values are an **Access service token**. The important constraint from the docs: the
device enrollment policy must use the **Service Auth** action, not a normal Allow rule. A service
token attached to an Allow rule does not work. Trade-off is that these devices have no
identity-based policy or logging, which we do not care about.

**VERIFIED against a real org on 2026-07-25.** The wire mechanism is one request:

```http
GET https://example.cloudflareaccess.com/warp
CF-Access-Client-Id:     <client_id>.access
CF-Access-Client-Secret: <client_secret>
```
```http
302 Found
location: com.cloudflare.warp://example.cloudflareaccess.com/auth?token=<JWT>
set-cookie: CF_Authorization=...
```

No browser, no SSO, no redirect to the login page. Access evaluates the Service Auth policy and
hands back the same `com.cloudflare.warp://` URL that a human would have got, with the enrollment
JWT already in it. Just parse the `token` query parameter off the `Location` header.

Decoded, the JWT is:

```json
{
  "aud": ["<warp login app aud tag>"],
  "iss": "https://example.cloudflareaccess.com",
  "type": "app",
  "warp": true,
  "email": "non_identity@example.cloudflareaccess.com",
  "sub": "5a4d1099-bdd4-5e78-940d-1b1a6785674b",
  "service_token_uuid": "<service token uuid>",
  "account_id": "<account id>",
  "ip": "<caller public IP>",
  "iat": ..., "nbf": ..., "exp": ...
}
```

`warp: true` is the claim that makes it usable for device enrollment. Lifetime is **60 seconds**
exactly, not the 30 that community posts claim. That is plenty as long as we mint it immediately
before `POST /reg` rather than caching it. `email` being `non_identity@...` is the visible cost of
service-token auth: these devices carry no user identity.

Failure mode for a bad or unauthorised token is a 302 to the normal Access login page with
`service_token_status: false` in the `meta` JWT, not a 401. So test success by whether the
`Location` header starts with `com.cloudflare.warp://`, not by status code.

### 6c. Full verified enrollment sequence

End to end, all three calls, no human:

1. `GET /warp` with the two service-token headers, take the JWT out of the `Location` header.
2. `POST /v0a4471/reg` with the §3 body plus `CF-Access-Jwt-Assertion: <JWT>`. Response comes back
   with `account.account_type: "team"`, `account.organization: "<team>"`, the assigned IPs, and
   `policy.tunnel_protocol: "masque"`.
3. `PATCH /v0a4471/reg/{id}` with the §4 MASQUE body and `Authorization: Bearer {token}`.

Notes from doing it for real:

- Zero Trust device IDs are prefixed `t.`, e.g. `t.<uuid>`. Keep the
  prefix for API paths. The account-level device list reports the same device without it.
- The assigned IP survives the WireGuard to MASQUE switch unchanged. `config.client_id` does not.
- `device_type` in the org's device list is derived from the platform letter in
  `CF-Client-Version`. We send `a-6.35-4471` so our devices show up as `android`. Send `l-` if we
  want them to read as Linux.
- The registration response also carries `policy.post_quantum: "enabled_with_downgrades"`, which
  matters later since we currently send `pq-enabled: false` on the H2 fallback path.

---

## 7. Org setup via the API token

What the app does once, with the user's API token, so that 6b works afterwards. Requires the
`Zero Trust: Write` permission on the account.

All of the following was exercised against the real account. Token needs Account, Zero Trust,
Edit.

**Read the org and find the enrollment app.** The app we need is the one with `type: "warp"`.

```
GET  /accounts/{account_id}/access/organizations     → auth_domain, e.g. example.cloudflareaccess.com
GET  /accounts/{account_id}/access/apps              → find type == "warp", keep its id and aud
GET  /accounts/{account_id}/devices/settings         → confirm use_zt_virtual_ip == true
GET  /accounts/{account_id}/devices/policies         → confirm tunnel_protocol == "masque"
```

`use_zt_virtual_ip: true` is the Mesh prerequisite, the unique-per-device IP. It was already on
for the org we tested and is the default for MASQUE orgs, so this is a check rather than a change.

**Mint the service token.**

```http
POST /accounts/{account_id}/access/service_tokens
{"name": "mesh-mvp-enrollment"}
```

Returns `id` (a UUID), `client_id` (ends in `.access`) and `client_secret`. The secret is only
ever returned here, so persist it immediately.

**Attach it to the enrollment app with a Service Auth policy.** In the API the Service Auth action
is spelled `non_identity`:

```http
POST /accounts/{account_id}/access/apps/{warp_app_id}/policies
{
  "name": "mesh-mvp-service-auth",
  "decision": "non_identity",
  "precedence": 2,
  "include": [{"service_token": {"token_id": "<service token uuid>"}}]
}
```

Make this additive. The app usually already has an Allow policy for the org's real users, and
overwriting it would lock humans out of enrollment. Give the new policy a lower precedence and
leave the existing ones alone.

That is the whole setup. From then on any machine holding the client ID and secret can enroll
itself with §6c and needs nothing else.

---

## 7a. Three things that will stop your Connect-IP client dead

All three cost real debugging time, none are documented, and each one presents as "the server
accepted the QUIC connection and then ignored me".

**Keep the HTTP/3 critical streams open.** The control stream and both QPACK streams must stay
open for the connection's lifetime. In Rust, dropping a `quinn::SendStream` closes it, so
writing SETTINGS to a local variable and letting it fall out of scope kills the connection with
`H3_CLOSED_CRITICAL_STREAM` (code 260) a moment later. Park the handles somewhere that lives as
long as the tunnel.

**Send `Capsule-Protocol: ?1`.** RFC 9297 requires it on a CONNECT that uses capsules, and
`connect-ip-go` sets it automatically, which is why `usque` never has to mention it. Without it
Cloudflare does not reject the request, it simply never answers.

**Skip unknown frames on the response stream.** Cloudflare sends HTTP/3 GREASE frames ahead of
the real HEADERS frame, with a random reserved type and a payload that literally reads
`GREASE is the word`. A parser that looks only at the frame at offset zero, or that treats an
unrecognised type as an error, waits forever for a response that already arrived. RFC 9114
requires unknown frame types to be skipped; GREASE exists to catch exactly this bug.

Worth knowing: the first two are silent, and the third looks identical to them. If CONNECT is
being ignored, validate the HTTP/3 layer against an ordinary HTTP/3 server first. A plain GET to
`cloudflare-quic.com` returning 200 proves the QPACK encoding, framing and status decoding are
right, and narrows the problem to something WARP-specific.

## 8. Status

Executed end to end against a real org on 2026-07-25, no browser at any point:

- org setup via API token: service token minted, Service Auth policy attached (§7)
- service token exchanged for a 60-second enrollment JWT in one GET (§6b)
- device registered into the org, `account_type: team`, assigned `10.96.0.1` (§6c)
- device switched to MASQUE with a P-256 key, IP preserved, ZT endpoint returned (§4, §6c)
- device visible in the account's device list

Verified by reading working code rather than by running it:

- mutual TLS with a self-signed P-256 cert as the only data-plane auth
- `cf-connect-ip`, the three RFC deviations, datagram framing, the H2 fallback

Verified by our own client, in two Linux containers, on 2026-07-25:

- the Connect-IP tunnel comes up against `zt-masque.cloudflareclient.com:443` and stays up
- two Mesh-enrolled devices reach each other over it. `10.96.0.5` and `10.96.0.6` exchanged
  UDP inside the tunnel at roughly 30ms round trip, which is the entire point of this backhaul
- the endpoint public key pin holds: the SPKI from enrollment does appear in the presented
  certificate
- datagram loss is real but low, a few percent, which is expected for unreliable QUIC datagrams
  and is why the path table tracks loss alongside latency

Still open:

- whether a device can register as `masque` directly, skipping the WireGuard step (§4)
- the HTTP/2 fallback path for networks that block QUIC, coded but never exercised
- IPv6 inside the tunnel; we only send IPv4 so far

### A freshly enrolled device is not immediately reachable

Two devices that have both just enrolled and both have healthy Connect-IP tunnels still cannot
reach each other for the first minute or two. Packets go in and nothing comes back, with no
error anywhere: the tunnels are up, the addresses are right, and Cloudflare simply has not
started routing between them yet.

It resolves on its own. Worth knowing because it looks exactly like a bug in your own client,
and because it makes the loss counter on a fresh node misleading for a while. Do not debug it,
and do not treat the first minute of a new device's statistics as meaningful.

### Artifacts from the verification run

Live in the session scratchpad, not the repo, since they contain secrets:
`svctoken.json`, `svc_id.txt`, `svc_secret.txt`, `svc_uuid.txt`, `reg_resp.json`,
`enroll_resp.json`, `ec.pem`, `ec_pub_b64.txt`, `ec_priv_b64.txt`.

Created in the Cloudflare account during that run and since deleted: a service token, an Access
policy on the Warp Login App, and one enrolled device. The control plane now creates and replaces
these itself, so nothing here needs to be done by hand. Identifiers are deliberately not recorded.

---

## References

- [usque](https://github.com/Diniboy1123/usque) and its [RESEARCH.md](https://github.com/Diniboy1123/usque/blob/main/RESEARCH.md)
- [wgcf](https://github.com/ViRb3/wgcf)
- [Boostport/setup-cloudflare-warp](https://github.com/Boostport/setup-cloudflare-warp)
- [MDM parameters](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/warp/deployment/mdm-deployment/parameters/)
- [Device enrollment permissions](https://developers.cloudflare.com/cloudflare-one/connections/connect-devices/warp/deployment/device-enrollment/)
- [Cloudflare Mesh](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-mesh/)
- [RFC 9484 (Connect-IP)](https://datatracker.ietf.org/doc/html/rfc9484), [RFC 9221 (QUIC datagrams)](https://datatracker.ietf.org/doc/html/rfc9221)
