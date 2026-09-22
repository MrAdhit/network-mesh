# Testing and the dev environment

## Environment facts

- The user develops on an Apple Silicon Mac with OrbStack. Test nodes were Linux containers.
- Location: Singapore. Latencies in these notes are from there.
- **UDP 3478 outbound is blocked on the dev network**, from containers and from the host. So
  Tailscale's DERP STUN doesn't work there, and neither does STUN-based DERP latency measurement.
- The user's real control plane: `https://mesh.mradhit.net`.
- The test Cloudflare org used Mesh range `10.96.0.0/16`. The test tailnet had about 20 personal
  devices, and its ACL had a grant covering the token owner's untagged devices.
- Vendor tokens for local runs lived in `.env.secrets` (gitignored): `CF_API_TOKEN`,
  `CF_ACCOUNT_ID`, `TS_API_TOKEN`. Every `.env*` file except `.env.example` was gitignored because
  they all hold some credential.

## The old container harness

- Runtime image: `debian:trixie-slim` plus `ca-certificates iproute2 iputils-ping curl iptables
  netcat-openbsd`. Linux binaries were built into `target-linux/release` and bind-mounted as a
  directory at `/opt/mesh`. **Mount the directory, not individual files**: a rebuild replaces the
  file (new inode) and breaks a single-file mount.
- Nodes need `cap_add: [NET_ADMIN]` and `devices: [/dev/net/tun]`.
- Default topology: control plane + two nodes (`mesh-a`, `mesh-b`), each node on the control plane
  network plus its own LAN network. Node env: `MESH_NODE_NAME`, `MESH_STATE_DIR`, `MESH_CP_URL`,
  `MESH_ENROLLMENT_KEY` (from `.env`), `MESH_PROBE_INTERVAL_SECS=2`.
- **OrbStack routes between Docker bridge networks.** Two networks are not isolation: the nodes
  reached each other directly at 0.15 ms. Handy for testing the direct path, but it made the first
  "CGNAT test" a fake (the far node could reach the NAT'd node's private IP at 0.1 ms, so no
  punching ever happened while the output looked like success). Any NAT test has to block the
  shortcut and check it's really gone before believing a result.
- The flat compose advertised STUN as `meshcp:3478,meshcp:3479`. The nodes silently dropped
  hostnames (known-problems.md), so flat-network runs had no STUN at all; only the NAT compose,
  which used IPs, exercised it.
- Bootstrap script: start the control plane, wait for `/health`, sign up (or log in) inside the
  control plane container with `MESH_CONFIG` pointing into its volume, set both vendor
  credentials, mint an enrollment key into `.env`, start the nodes.
- Demo script: network and nodes from the control plane, node status, `ping mesh-b 4`, peers, the
  interface and route, real ICMP, 2 MB over TCP with `nc`, then the failover: start a 60-tick TCP
  stream, drop UDP 47778 in and out on one node with iptables, wait 20s, show the winner moved to
  cloudflare and the stream kept counting, remove the rules (direct comes back in about 20s).

## NAT simulation

- Networks: `cp` (10.98.0.0/16: control plane at .5, router at .2, far node at .20) and `private`
  (10.99.0.0/16: router at .2, NAT'd node at .10).
- Router container: `ip_forward=1`, `iptables -t nat -A POSTROUTING -s 10.99.0.0/16 -j MASQUERADE`
  for port-preserving, add `--random-fully` for symmetric (`NAT_MODE=random`).
- NAT'd node: only on `private`, reaches everything by IP through the router. Its default route
  (`ip route replace default via 10.99.0.2`) has to be set before the daemon starts or enrollment
  fails.
- Far node: `iptables -A OUTPUT -d 10.99.0.0/16 -j DROP` to kill the OrbStack shortcut, then prove
  `ping 10.99.0.10` fails.
- STUN advertise must be the control plane address reachable from behind the NAT
  (`10.98.0.5:3478,10.98.0.5:3479`).
- Wait about 40s after both nodes answer status, then check `meshctl peers` and the logs for the
  "nat profile" and "reflexive address" lines.

## Things verified end to end (old project)

- Cloudflare org provisioning, service-token enrollment, MASQUE tunnel, two Mesh devices exchanging
  UDP at about 30 ms.
- Tailscale registration with an untagged auth key, DERP between our own nodes at about 90 ms.
- All three paths racing; ICMP and TCP over the interface on Linux and macOS; ICMP on Windows.
- Path failover with a live TCP stream, no reconnect.
- NAT traversal, port-preserving and symmetric, simulated.
- Removal: a removed node shut itself down within 90s; restart with a key rejoined with a new
  record and the freed address. This was tested at an earlier commit (`63ff1bf`), before
  Cloudflare device deletion on removal, idle mode and staged keys existed, so it doesn't cover the
  removal/rejoin path as it stands at `a324c0b`.
- Offline boot: a node started with no internet came up on the direct path with its cached roster,
  then adopted both relays about a minute after the network came back.
- Internet loss with the LAN still up: 61 consecutive pings with no loss; all three paths returned
  unattended afterwards.
- Self-update: stale meshd and meshctl replaced in place with matching hashes, including meshctl
  replacing itself while running; a second pass reported both current.
- Windows ARM64 VM: Wintun adapter, netsh config, MTU enforcement, named pipe across repeated
  connections, full membership with a direct path to two Linux containers (one behind the simulated
  NAT).

## Verified only by unit tests

- The 2s send cap, loss charging on expiry, punch probes exempt from loss, and the loss-aware score.
  Never put in front of a real DERP outage.

## Unit tests worth having again

The old suite pinned these, and they caught real regressions:

- frame round trip; reject old version; reject garbage; empty payload fine
- IPv4/UDP build and parse with odd-length payloads; header checksum sums to zero
- ICMP unreachable: addressed from the unreachable host back to the sender, both checksums valid,
  quote is the header + 8 bytes; no reply to an ICMP error, multicast, unspecified source, IPv6
- STUN request/response round trip; response for another transaction rejected; XOR hides the address
- NAT classification for every case, including the ISP case (healthy vs poisoned) and port-range
  bounds on predictions
- ranking: fastest live wins; LAN survives the internet going away (only direct live); nothing live
  means empty; never-heard-from path isn't a path; lossy path crossover at both ends
- expired probe charged as loss; expired punch probe not charged
- send cap: a send that never returns fails at exactly the cap (paused clock); a quick one is left
  alone and its own error passes through
- direct pin: live confirmed address used; dead confirmed address unpinned; unprobed not pinned
- two peers with the same name both survive the roster; resolving by address picks one, by the
  shared name picks both; rename moves the label
- candidate list cap and eviction order; repeats ignored; nonsense addresses refused
- utun framing round trip and unit numbering (utun0 is unit 1); lo0 alias parsing never touches
  127.0.0.1 or addresses outside the subnet
- control plane: sequential allocation skipping taken and .0/.1; subnet validation; enrollment
  idempotent by key; subnet change blocked with nodes; password hash round trip; sealing round
  trip and tamper rejection
- CLI session only offered to its own control plane; blank values don't count for the control
  plane URL or the update toggle; URL precedence; autoupdate toggle precedence; download hash
  mismatch refused; atomic install leaves no temp file and keeps the exec bit
- install/uninstall script placeholder always replaced; public URL from Host / forwarded proto /
  localhost
