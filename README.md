# network-mesh

A multipath mesh client that owns its own addressing and races two independent backhauls,
picking whichever is fastest to each peer right now.

Three paths per peer: a direct peer-to-peer path, Cloudflare Mesh (Connect-IP over QUIC), and
Tailscale (over DERP). Neither vendor's client is used; we speak both control planes and both
data planes ourselves. Nodes get an address on the mesh's own subnet and a real kernel
interface, so ordinary applications use it without knowing it exists.

## Why

Cloudflare Mesh always relays through the nearest Cloudflare datacenter. Tailscale goes direct
when NAT traversal succeeds and falls back to a DERP relay when it does not. Those failure modes
are uncorrelated, so running both and continuously measuring which one is winning gives better
latency and better availability than either alone.

## Layout

```
crates/mesh-core     the library: enrollment, tunnels, probing, path selection
  cp.rs / cpclient.rs  control plane wire types and the node-side client
  direct.rs            our own peer discovery: candidates, punching, confirmation
  stun.rs              RFC 5389, enough of it to learn a reflexive address
  nat.rs               classifying the NAT, and predicting a port without poisoning it
  tun/                 the kernel interface: Linux /dev/net/tun, macOS utun
  cloudflare/api.rs    service token -> enrollment JWT -> register -> MASQUE enroll
  cloudflare/h3.rs     hand-rolled HTTP/3: QUIC varints, QPACK, frames, datagram framing
  cloudflare/tunnel.rs Connect-IP over quinn, mutual TLS with a self-signed P-256 cert
  tailscale/mod.rs     ts_control for TS2021 registration, ts_derp for packet relay
  ip.rs                IPv4/UDP construction and parsing, with real checksums
  proto.rs             the frame format that rides every backhaul, identically
  node.rs              peer table, prober, EWMA path stats, winner selection
  ipc.rs               newline-delimited JSON over a unix socket
crates/meshcp        the control plane: accounts, subnets, roster, backhaul credentials
crates/meshd         the daemon
crates/meshctl       the CLI, for both the local node and the network
docs/                what we learned about both vendors' auth, and how we learned it
```

## Design notes

**One frame format on every path.** Comparing a Connect-IP path to a DERP path is only honest
if both carry byte-identical probes timed the same way. Framing below `proto::Frame` differs per
backhaul; nothing above it does.

**Hand-rolled HTTP/3 for Cloudflare.** Their WARP endpoint deviates from RFC 9484 in three ways
that make compliant libraries refuse to proceed: the protocol token is `cf-connect-ip` rather
than `connect-ip`, the server never advertises `ENABLE_CONNECT_PROTOCOL`, and it never sends
routes. `cloudflare/h3.rs` implements only what is needed and skips the checks that would fail.

**Real IP packets.** Connect-IP is a raw IP tunnel, so `ip.rs` builds genuine IPv4/UDP headers.
Both checksums cover per-packet fields, so neither can be faked.

**Degraded is not dead.** If one backhaul fails to come up, `meshd` logs it and runs on the
other. That is the entire premise of the project, so it would be strange to abort.

## Running it

Put your two vendor API tokens in `.env.secrets` (gitignored):

```
CF_API_TOKEN=<cloudflare api token, Account > Zero Trust > Edit>
CF_ACCOUNT_ID=<cloudflare account id>
TS_API_TOKEN=<tailscale api access token>
```

Then:

```bash
./bootstrap.sh
```

That starts the control plane, creates an account, hands it both tokens, provisions the
Cloudflare Zero Trust org for you (service token and Service Auth policy included), mints an
enrollment key, and starts two nodes. The nodes enroll themselves, get addresses out of
`10.201.0.0/16`, and bring up all three paths.

Nodes never see either API token. They get a Cloudflare service token and a Tailscale auth key
minted for them on demand. See [docs/cloudflare-auth.md](docs/cloudflare-auth.md) and
[docs/tailscale-auth.md](docs/tailscale-auth.md) for what those are and why the split matters.

Then:

```bash
docker exec mesh-a meshctl status          # addresses and backhaul health
docker exec mesh-a meshctl peers           # every path, with RTT and loss
docker exec mesh-a meshctl ping mesh-b 5   # race all three paths
docker exec mesh-a ping 10.201.0.3         # ordinary ICMP, over the mesh interface
docker exec mesh-a nc 10.201.0.3 9000      # ordinary TCP, over the mesh interface
```

`meshctl` also manages the network: `network`, `nodes`, `enrollment-key`, `set-subnet`,
`set-cloudflare`, `set-tailscale`, `remove-node`.

`ping` probes every path separately and prints a per-path summary plus the winner. `send` uses
whichever path is winning at that moment.

`./demo.sh` runs the whole sequence including a failover: it blackholes the Cloudflare endpoint
on one node, waits for the path to be declared down, and shows traffic continuing over Tailscale.

### What it looks like

From two containers in Singapore:

```
peer mesh-b (10.201.0.3)  cf=10.96.0.7  best=direct
  path              state    last ms    ewma ms    sent    recv  loss %
  cloudflare           up      33.91      32.77      74      73      1%
  tailscale-derp       up      83.03      89.45      75      74      1%
  direct               up       0.37       0.27      58      57      2%
```

The direct path wins by two orders of magnitude when it exists. When it does not, Cloudflare
beats DERP here because it hairpins through a Singapore datacenter while DERP adds a relay hop.
Neither is a general result: they are the answer for these two nodes right now, which is the
whole reason the client measures instead of assuming.

A live TCP connection survives losing its path. With a stream running over the direct path,
dropping UDP 47778 moves the winner to Cloudflare and latency from 0.2ms to 35ms, and the
stream keeps going with no gap and no reconnect. That is what encapsulating rather than
rewriting buys: the guest's 5-tuple never changes, so TCP never notices.

## Platforms

`meshd` and `meshctl` run on Linux and macOS. `meshcp` is Linux only, deliberately: it is a
server and there is no reason to run it on a laptop.

The TUN layer is the only part that differs, and it differs more than it looks. Linux opens
`/dev/net/tun`, configures it by ioctl, and carries bare IP packets. macOS has no such device: a
utun is a socket opened against the `com.apple.net.utun_control` kernel control, the kernel
chooses the interface number rather than accepting one, and every packet carries a four-byte
address family header that has to be added on write and stripped on read. `tun/` hides both
behind one type, so nothing above it knows which platform it is on.

Both platforms need root for the interface. On Linux that is `CAP_NET_ADMIN` plus
`/dev/net/tun`; on macOS it is plain `sudo`. Everything else in the daemon runs unprivileged, and
if the interface cannot be created `meshd` logs it and carries on, reachable through `meshctl`.

`MESH_TUN_NAME` picks the interface. On macOS only a `utunN` form requests a specific unit;
anything else, including the Linux default of `mesh0`, means "whatever is free".

```bash
cargo run -p mesh-core --example tuncheck   # brings up just the interface, needs sudo
```

## State

`meshd` keeps everything in `$MESH_STATE_DIR` (default `/var/lib/mesh`): the Cloudflare device
registration and its P-256 private key, the Tailscale machine and node keys, and the control
socket. It is plaintext. This is an MVP and the threat model is currently "none"; it is one
directory so that it is easy to fix later.

## Status

Working and demonstrated: a control plane with accounts, user-chosen subnets and automatic
Cloudflare provisioning; node enrollment and stable address allocation; roster-based membership
so the mesh only ever sees its own nodes; all three paths racing; a real kernel interface
carrying ICMP and TCP; failover between paths without breaking connections; and recovery.

NAT traversal works, on both kinds of NAT. `./cgnat-test.sh` puts one node behind a masquerading
router with the shortcut blocked and a direct path still forms; `NAT_MODE=random ./cgnat-test.sh`
makes that router symmetric and it still forms. Three mechanisms carry it between them: a STUN
responder on the control plane for reflexive addresses, port prediction from a measured NAT
profile, and a punch relayed over the backhauls so both sides transmit in the same window.

The measurements in [docs/roadmap.md](docs/roadmap.md) show why all three exist. Under a
symmetric NAT three different external ports were live at once, so no prediction could have
worked and only the peer's observation of the punch did.

Not done: signed frames, so membership is asserted rather than proven. IPv6 inside the tunnel is
dropped. Testing against a real CGNAT rather than a simulated one. See
[docs/roadmap.md](docs/roadmap.md) for the full list and PLAN.md for the original design notes.

### Things that bit us, recorded so they do not again

- HTTP/3 critical streams must be kept open, or the peer kills the connection with code 260.
- Cloudflare needs `Capsule-Protocol: ?1` and silently ignores CONNECT without it.
- Cloudflare sends HTTP/3 GREASE frames before HEADERS; a parser that does not skip unknown
  frame types hangs forever on a response that already arrived.
- TCP connect time is not a latency measurement inside a container. It reported 9ms to New York
  from Singapore. UDP STUN is blocked on some networks. A full HTTPS request works.
- Tailscale deduplicates colliding hostnames, so a restarted node comes back as `mesh-b-1` while
  its dead predecessor still holds `mesh-b`. Resolve tolerantly and prefer online nodes.
- Bind-mounting individual binaries breaks when you rebuild them; mount the directory.
