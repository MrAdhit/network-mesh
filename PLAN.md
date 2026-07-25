# Custom Multipath Client (Tailscale + Cloudflare Mesh replacement) — Notes & Gaps

> **Status, 2026-07-25.** An MVP of this now exists and works: see [README.md](README.md),
> [docs/cloudflare-auth.md](docs/cloudflare-auth.md) and
> [docs/tailscale-auth.md](docs/tailscale-auth.md). Two Linux containers race a Cloudflare
> Connect-IP path against a Tailscale DERP path and fail over between them. The notes below are
> the original design thinking; where the build disagreed with them, the docs are authoritative.
> Corrections so far: MASQUE data-plane auth is mutual TLS with a self-signed P-256 certificate,
> not an app-layer bearer token (§3); consumer WARP cannot reach peers at all, device-to-device
> needs Cloudflare Mesh with a Zero Trust org (§1); and `100.96.0.0/12` is only the default Mesh
> range, it is org-configurable.

Working notes on building a self-owned client that:
- Handles its own registration/auth (not wrapping `tailscaled` / `warp-svc` as external processes)
- Owns its own stable virtual IP per peer
- Races multiple backhauls (Tailscale, Cloudflare Mesh/WARP, maybe raw WireGuard) and picks the lowest-latency path per destination
- Runs the same core logic on Linux, Windows, and Android

---

## 1. Why build vs. wrap

Wrapping the official binaries (`tailscaled`, `warp-svc`) as subprocesses works, but:
- `warp-svc` is **closed-source** — no reference implementation to build against, and no way to add path-racing logic inside it.
- Both create a real OS-level TUN/Wintun device by default, which means real routes, real host-visible interfaces, and (on Linux) needed namespace tricks (`ip netns`, veth/ipvlan) to keep them from touching the host environment.
- Neither supports "same virtual IP, multiple race-able backhauls, live switch mid-session" — that logic doesn't exist in either product.

Building our own means embedding the protocol libraries directly and skipping the OS tun device entirely where possible (see §4).

---

## 2. Architecture layers

```
┌─────────────────────────────┐
│ App-facing virtual IP layer │  ← stable per-peer address, never changes
├─────────────────────────────┤
│ Path table + prober         │  ← RTT probes both backends every N sec, flips "current_best"
├─────────────────────────────┤
│ Transport A: boringtun (WG) │  Transport B: quiche (QUIC/MASQUE)
├─────────────────────────────┤
│ Platform packet shim        │  ← /dev/net/tun (Linux) | Wintun (Windows) | VpnService fd (Android)
└─────────────────────────────┘
```

Two implementation modes, worth deciding early:

| Mode | Description | Perf |
|---|---|---|
| **Packet-forwarding (TUN-based)** | Real virtual adapter, other apps on the box can use it transparently | Extra kernel↔userspace copy per packet (cheap, µs-level) |
| **In-process / library mode** | No TUN at all — your own app calls `Dial()`/`Listen()` against an embedded userspace stack (`smoltcp`) | Fastest — no device-file syscalls, one extra userspace hop |

Since the stated use case is "our own app connects out," in-process mode is the better fit and sidesteps the entire Windows/Android TUN problem below.

---

## 3. Auth model (recap)

Two separate layers — important because they explain why WireGuard vs MASQUE need different handling in your client:

### Layer 1 — Registration/enrollment (control plane, transport-agnostic)
- Generate an X25519 keypair locally.
- POST the public key to Cloudflare's API → get back `registration_id` + `api_token`/`secret_key`.
- **Consumer WARP**: anonymous, no login. A WARP+ license key can bind it to a subscription after the fact.
- **Zero Trust enrollment**: browser SSO against the org's IdP first → produces a JWT → JWT submitted to bind this device+keypair to the org. (Community docs mention the JWT auto-refreshing if the first submission fails — implies a session-duration-linked reauth cycle, not fully documented publicly.)

### Layer 2 — Data-plane auth (this is where the two transports diverge)
- **WireGuard mode**: no separate per-connection login. The registered keypair *is* the credential — standard Noise IK handshake succeeds because the pubkey is already whitelisted server-side against your `registration_id`.
- **MASQUE mode**: standard TLS 1.3 (server-authenticated, not mutual by default) establishes the QUIC connection; the account token from registration is then passed as an app-layer bearer credential over Connect-IP (RFC 9484) to authorize the tunnel. This is presumably also where periodic reauth/session-duration policy hooks in for Zero Trust orgs.

Practical implication for a custom client: keep "device identity" (keypair + registration, one-time) separate from "prove it this session" (Noise handshake for WG / bearer token over TLS for MASQUE) — mirrors how Cloudflare's own client can flip `tunnel protocol set WireGuard|MASQUE` without re-registering.

---

## 4. Platform packet injection

| Platform | Real TUN available? | Notes |
|---|---|---|
| Linux | Yes — `/dev/net/tun`, not namespaced (mount-ns thing) | `ip netns` + veth/ipvlan gives free isolation if wrapping external daemons; irrelevant in library mode |
| Windows | Yes, but different model — **Wintun**, an NDIS miniport driver via DLL calls (`WintunOpenAdapter`, etc.), not a POSIX device | No unmodified-Linux-binary shortcut; WSL2 = real Linux kernel in a VM (adds a bridge hop to reach Wintun); WSL1 has no working tun/tap translation |
| Android | Real Linux kernel, but sandboxed — no `CAP_NET_ADMIN` without root | Only sanctioned path is **VpnService**: OS grants one app a TUN fd after a consent dialog; no netns-style multi-process split possible unrooted |

**Native cross-compile beats cross-OS execution.** The protocol/stack logic (boringtun, quiche, smoltcp, path-racing) is pure, portable source — compile it natively per target (`--target x86_64-pc-windows-msvc` vs `-unknown-linux-gnu`) with only a thin per-platform trait implementation swapped at the edge:

```rust
trait TunIo {
    fn recv(&mut self, buf: &mut [u8]) -> usize;
    fn send(&mut self, buf: &[u8]);
}
// LinuxTun{fd}, WintunIo{session}, AndroidVpnFd{fd} — three thin impls, one shared core
```

Running an actual Linux binary under WSL2/WSL1 to reach Wintun is strictly worse (VM boundary + bridge hop) than just recompiling — no reason to go that route.

---

## 5. Prior art / reference implementations

| Project | License/status | Useful for |
|---|---|---|
| [tailscale/tailscale](https://github.com/tailscale/tailscale) | Fully open (BSD-3) | Full reference: `wireguard-go`, `magicsock` (path racing/hot-swap — the exact mechanism we want), `netstack` embedding, `wgengine/router` |
| [cloudflare/boringtun](https://github.com/cloudflare/boringtun) | Open (BSD-3) | Userspace WireGuard in Rust, production-grade |
| [cloudflare/quiche](https://github.com/cloudflare/quiche) | Open | QUIC/HTTP3 — what MASQUE/Connect-IP rides on |
| [Diniboy1123/usque](https://github.com/Diniboy1123/usque) | Open (reverse-engineered) | Closest available reference for WARP's actual MASQUE/Connect-IP wire behavior, since Cloudflare's real client (`warp-svc`) is closed-source |
| wgcf / cloudflare-warp-wireguard-client | Open | Shows the registration API shape (`reg.json`: `registration_id`, `api_token`, `secret_key`, `public_key`) without needing the closed client |
| `smoltcp` | Open | Rust userspace TCP/IP stack, `no_std`-capable — Rust analogue of gVisor's `netstack` |

`warp-svc` itself: **closed source**, distributed as a binary via `pkg.cloudflareclient.com`. No official reference to read.

---

## 6. Known gaps / unsolved problems

Roughly ordered by how much they block a first working version:

1. **MASQUE/Connect-IP wire protocol isn't officially documented.** `usque` is the only real-world reference, and it's reverse-engineered — no guarantee it stays in sync with Cloudflare's actual server behavior long-term. Building against it means accepting some protocol-drift risk.
2. **Zero Trust JWT/SSO enrollment specifics are thin.** Exact refresh cadence, how it ties to session-duration policy, what a "server verification API" failure actually means — pieced together from community troubleshooting posts, not primary docs.
3. **Mid-flow path switching breaks TCP unless flows are pinned.** DNAT-style rewriting (dest IP swapped to whichever backend currently wins) changes the 5-tuple mid-connection → existing TCP sessions die unless the client tracks open flows and only lets *new* connections benefit from a path flip.
   - QUIC/MASQUE's native connection migration might sidestep this for that transport specifically — not yet validated in practice for our use case.
4. **Checksum/NAT correctness** for any packet-rewriting approach — IPv4 header checksum + L4 (TCP/UDP) checksum both cover a pseudo-header that includes the destination address, so both need recomputing on every rewrite, plus a return-path table so replies get rewritten back correctly.
5. **Wintun packaging** — driver install requires admin rights and (for wide distribution) driver signing; not yet scoped.
6. **Android VpnService exclusivity** — only one app can hold the VPN fd at a time on non-rooted devices. If a user also runs the official Tailscale or 1.1.1.1 app, there's a hard conflict, not just a performance one.
7. **Device posture / mTLS** — Zero Trust's device-posture checks (used for enterprise access policies) haven't been investigated at all; likely irrelevant for personal use but a gap if this ever needs to interoperate with an existing Zero Trust org's policies.
8. **`smoltcp` performance under real load** — no kernel offload (checksum/segmentation offload), so CPU cost per connection is higher than the kernel stack. Not measured yet; matters more at high connection count/throughput than for typical app traffic.
9. **ToS considerations** — building a from-scratch client against Cloudflare's registration API is worth a deliberate check against their terms of service before going further than personal/experimental use.

---

## 7. Suggested reading order

1. Tailscale's `magicsock` package — the actual "race paths, hot-swap winner under an active WireGuard session" logic, already solved and open.
2. `boringtun` source — cleanest real-world userspace WireGuard implementation to build the WG transport on.
3. `usque` source — closest thing to a MASQUE/Connect-IP reference given no official one exists.
4. `smoltcp` docs/examples — in-process TCP/IP stack, avoids the TUN/Wintun/VpnService problem entirely for the "our own app is the only consumer" case.
