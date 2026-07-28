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
  config.rs            the operator's stored session, and which control plane it belongs to
crates/meshcp        the control plane: accounts, subnets, roster, backhaul credentials
crates/meshd         the daemon
crates/meshctl       the CLI, for both the local node and the network
packaging/           install.sh and uninstall.sh, service units, deb and rpm definitions
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

## Installing it

On a machine that is joining someone's mesh, one line:

```bash
curl -fsSL https://mesh.mradhit.net/install.sh | sudo sh
```

That detects the platform, fetches `meshd` and `meshctl` from the control plane, checks each
against the SHA-256 that control plane publishes, installs a systemd unit or a launchd job, and
starts the daemon. Add `-s -- --key mkey_...` to join a network in the same step; without one the
daemon comes up idle and waits, and `meshctl join <enrollment-key>` finishes it whenever you have
a key.

The installer comes from the control plane rather than a release page on purpose. It is already
the thing that holds the build a network expects its nodes to be running, and it already serves
those binaries hashed and unauthenticated for self-updates, so the install path and the update
path fetch the same bytes from the same place. It also cannot point at the wrong control plane:
whichever host you fetched the script from is the one written into it.

Debian and RPM packages are attached to each release, as are archives for every target.

Nothing needs to be exported. `meshctl login` stores its session under your home directory,
`meshctl join` hands the enrollment key straight to the running daemon, and both are read back
without any variables set. `MESH_SESSION` and `MESH_ENROLLMENT_KEY` still work and still win,
because scripts and CI want them to.

### Removing it

```bash
curl -fsSL https://mesh.mradhit.net/uninstall.sh | sudo sh
```

Deregistering happens first, because a node whose files are gone still holds a roster entry and
an allocated address, and the credential that proves it may remove itself is one of the things
about to be deleted. Then the service, the binaries, `/var/lib/mesh`, `/etc/mesh`, and the stored
session of whoever ran it. Sessions belonging to other users on the machine are listed rather
than deleted, since those are theirs.

If this machine is also a control plane, `/var/lib/meshcp` is kept unless you pass `--purge`.
Removing the software from a server is not the same statement as destroying the network it runs,
and nothing else holds a copy of the accounts or the sealed backhaul credentials.

The packages route their removal hooks through the same script. Debian semantics apply, and the
difference matters: `apt remove` keeps the state and this node's registration, so reinstalling
comes back as the same node at the same address, while `apt purge` gives the address back.

## Running it from source

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

`meshctl` also manages the network: `login`, `logout`, `whoami`, `network`, `nodes`,
`enrollment-key`, `set-subnet`, `set-cloudflare`, `set-tailscale`, `remove-node`. And the local
node: `join`, `leave`, `update`, `version`.

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

## Updating itself

The control plane carries the binaries it expects its nodes to be running, and nodes replace
themselves when what they are running does not match. Identity is a SHA-256 of the file rather
than a version string: a version is a claim, a hash is the thing itself, and it cannot drift from
what was actually shipped.

`build.rs` compiles the binaries into `meshcp` from `dist/<target triple>/<binary>`, hashing each
one at build time, and serves them:

```
GET /v1/updates/<target>          what this control plane holds, with hashes
GET /v1/updates/<target>/<name>   the bytes
```

Both are unauthenticated. They are the same binaries a release page would hand to anyone, they
contain no account data, and requiring a token would stop the CLI updating itself before its user
has logged in. A control plane built with nothing staged answers with an empty list, which is what
a development build should do; CI stages the whole build matrix and compiles it in afterwards,
which is why `meshcp` is built in its own job rather than alongside the node binaries.

The daemon checks at startup and every six hours, and updates the CLI beside it as well, because
the two are shipped as a pair and only the daemon runs continuously enough to notice. The CLI has
`meshctl update` for doing it on demand, and otherwise only looks at the manifest, at most once
every six hours, and prints a line if it is behind. Downloading fifteen megabytes because somebody
ran `meshctl peers` would be rude.

Nothing is ever written over a running binary. The download lands beside it and is renamed into
place only once its hash matches, so an interrupted update leaves the old binary untouched rather
than a half-written one that no longer starts. The new code takes effect on the next start:
restarting a daemon out from under a working mesh to apply an update nobody asked for is worse
than waiting.

It is compiled in by default. Build with `MESH_AUTOUPDATE=0` to ship binaries that never update,
and set the same variable at runtime to override whichever way they were built, in either
direction. An operator saying no now outranks a decision taken at build time, and it is the only
way to stop a node updating without rebuilding it.

```bash
MESH_AUTOUPDATE=0 cargo build --release -p meshd -p meshctl
```

## Platforms

`meshd` and `meshctl` run on Linux (x86_64 and aarch64), Apple Silicon macOS, and Windows
(x86_64). `meshcp` is Linux only, deliberately: it is a server and there is no reason to run it
on a laptop. Intel Macs are not a target.

Two things differ by platform, and both differ more than they look.

The TUN layer. Linux opens `/dev/net/tun`, configures it by ioctl, and carries bare IP packets.
macOS has no such device: a utun is a socket opened against the `com.apple.net.utun_control`
kernel control, the kernel chooses the interface number rather than accepting one, and every
packet carries a four-byte address family header added on write and stripped on read. Windows
has nothing native at all, so it borrows WireGuard's Wintun driver: no file descriptor, packets
move through shared ring buffers, so receiving is a blocking call on its own thread feeding a
channel rather than anything pollable. `tun/` hides all three behind one type.

And the control socket. Unix gets a socket in the state directory; Windows gets a named pipe,
because tokio has no unix-socket support there even on the builds that have `AF_UNIX`.

All three platforms need privilege for the interface: `CAP_NET_ADMIN` plus `/dev/net/tun` on
Linux, `sudo` on macOS, an elevated prompt on Windows. Everything else in the daemon runs
unprivileged, and if the interface cannot be created `meshd` logs it and carries on, still
reachable through `meshctl`.

Windows additionally needs `wintun.dll` beside `meshd.exe`. It ships with WireGuard for Windows
and is downloadable from wintun.net; the driver is signed by WireGuard, so nothing here needs
signing of its own. The Visual C++ runtime is linked statically, so no redistributable is
required: the binaries are self-contained apart from that one DLL.

**Windows Firewall blocks inbound traffic on the mesh interface by default.** Nothing arrives
until a rule permits it, and the failure is silent from the application's side: packets leave,
nothing comes back, and no error appears anywhere. `meshd` does not add rules to your firewall.
For ICMP, which is what the usual first test uses:

```
netsh advfirewall firewall add rule name="mesh-icmp" protocol=icmpv4:8,any dir=in action=allow
```

State lives in `/var/lib/mesh` on unix and `%ProgramData%\mesh` on Windows, both overridable
with `MESH_STATE_DIR`.

`MESH_TUN_NAME` picks the interface. On macOS only a `utunN` form requests a specific unit;
anything else, including the default `mesh0` used on Linux and Windows, means "whatever is free".

```bash
cargo run -p mesh-core --example tuncheck   # brings up just the interface, needs privilege
```

### Verification status by platform

Linux, macOS and Windows are all verified end to end: the interface comes up, carries traffic,
and the MTU is enforced (a 1000-byte payload with DF set passes, 1200 is refused). Linux and
macOS additionally carry TCP.

Windows was verified on ARM64 Windows 11, which is what an Apple Silicon VM runs. The x64 build
cannot stand in for it: `wintun.dll` embeds a kernel driver matching its own architecture, so an
emulated x64 process cannot install the ARM64 one it would need.

The Windows named pipe is verified too, with a real `meshd` and `meshctl` talking over
`\\.\pipe\meshd` across repeated connections, which is what exercises the per-connection pipe
instance the listener has to create each time.

That test also made a Windows machine a full member of the mesh: enrolled through the control
plane, both backhauls up, and a direct path punched to two Linux containers, one of them behind
a simulated CGNAT. The direct path won at about 1ms against 33ms via Cloudflare and 99ms via
DERP.

Windows is verified end to end too. A node there brings up a Wintun adapter with the right
address, mask, MTU and on-link route, and carries ICMP over the mesh to Linux containers at
around 1ms on the direct path with no loss. The 1100 MTU is enforced: 1000 bytes with DF passes,
1200 comes back as "Packet needs to be fragmented but DF set".

Traffic *into* a Windows node is dropped by Windows Firewall, which blocks inbound ICMP on an
unidentified network by default. The mesh delivers those packets to the interface correctly, so
this is a host firewall rule to add rather than anything to fix here.

Removing a node with `meshctl remove-node` takes effect while it is running: the daemon notices
its token is being rejected, and after three consecutive refusals it shuts down rather than
carrying on from cached state. Restarting it with a valid `MESH_ENROLLMENT_KEY` rejoins the
network with a fresh registration; restarting without one fails with an explanation rather than
a puzzle.

That split is deliberate. A node that rejoined by itself while running would make eviction
meaningless, so rejoining stays a deliberate act, gated on a credential an operator can rotate.

Still unverified: `meshcp` runs only on Linux by design.

## State

`meshd` keeps everything in `$MESH_STATE_DIR` (default `/var/lib/mesh`): the Cloudflare device
registration and its P-256 private key, the Tailscale machine and node keys, and the control
socket. It is plaintext. This is an MVP and the threat model is currently "none"; it is one
directory so that it is easy to fix later.

The operator's session is not in there. That directory belongs to root because the daemon needs
it to, and a session token belongs to a person, so `meshctl login` writes
`~/.config/mesh/config.json` at mode 0600 (`~/Library/Application Support/mesh` on macOS,
`%APPDATA%\mesh` on Windows, `MESH_CONFIG` anywhere). The control plane URL is stored in the same
record as the token rather than as a separate setting, and the token is only ever sent to that
URL. Keeping them apart is how an account credential eventually reaches whatever host
`MESH_CP_URL` happened to name.

An enrollment key never lands on disk on the normal path: `meshctl join` hands it to the running
daemon over the control socket. An installer doing an unattended setup can stage one at
`$MESH_STATE_DIR/enrollment-key` instead, and the daemon deletes it the moment it works. That
deletion is the point. A key left lying there would let a node an operator removed re-enroll
itself on the next reboot, which would make `remove-node` mean nothing.

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
