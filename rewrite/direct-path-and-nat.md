# Direct path and NAT traversal

Our own scheme, not Tailscale's disco. Candidates travel over whichever relay works (Hello and
Punch), probing is just the normal probe loop, and confirmation is free: a valid frame arriving on
the direct socket proves its source address works. There's no handshake of its own.

## The socket

- One UDP socket on `0.0.0.0:<port>`. Default port 47778 (`MESH_DIRECT_PORT`). The port in use is
  saved in the node state and reused on restart, so peers' cached candidates stay valid and a
  port-preserving NAT keeps mapping it to the same outside port. The saved port beats the env var,
  so changing `MESH_DIRECT_PORT` after the first successful bind does nothing.
- STUN goes out of this same socket. It has to: NAT mappings are per source port, so an address
  learned from a different socket describes a mapping our mesh traffic doesn't have. The receive
  loop checks each datagram against pending STUN transaction ids and hands matches to the waiting
  query; everything else is mesh traffic.
- Receive errors: log, sleep 200 ms, keep reading. Never leave the loop. (An earlier version broke
  on its first error and the direct path stayed dead until restart.)
- If the bind fails, run relays-only.
- IPv4 bind only in the old code (IPv6 interface addresses were still advertised as candidates).

## Our own candidates

- Every interface address except loopback, multicast, IPv6 link-local (`fe80::/10`, needs a scope
  id we don't track), and anything inside our own mesh subnet. Each paired with our port.
- Plus our reflexive address, from STUN or from a peer's `seen_you_at`. The old node kept one slot
  and the last write won: every STUN round and every Hello with `seen_you_at` overwrote it, so
  behind an endpoint-dependent NAT it flipped between different peers' observations.
- The mesh-subnet exclusion is important. Without it a node advertised its own TUN address, the
  peer reached it *through the mesh*, and it got confirmed as a "direct" path. It even worked,
  with relay latency. The giveaway was a 118 ms "direct" RTT between two containers on one host.

## Candidates we store for a peer

- Two lists per peer: `direct` (cap 16) and `predicted` (cap 8). Append new ones, evict the oldest
  when full (the newest address is the likeliest to work now), ignore duplicates.
- Refuse addresses that can never work: port 0, unspecified, loopback, multicast, IPv4 broadcast,
  IPv6 link-local. Peers advertise these unverified, so the list is also a list of places a member
  can make us send packets.
- The source address of an arriving direct packet is also added to the list. The old code did that
  with a plain push that skipped both the cap and the filter, so the list could grow past 16.
- Earlier versions had unbounded lists, which was a bug: a roaming peer piled up its whole history
  and every unconfirmed probe sprayed all of it. Stale guesses at unopened ports are also exactly
  what poisons port-preserving NATs (below).

## Hole punching

Both sides need to be sending in the same window: each side's outbound packet opens the NAT
binding the other side's inbound packet needs. Independent timers don't reliably overlap, so one
side asks over a relay and both fire.

- **Timer**: every 20s (first run at start), for every peer with no confirmed direct address,
  provided we have at least one candidate of our own:
  1. send Punch with seq 1 and a HelloPayload of our candidates + predictions, over the relay
     paths only (cloudflare and tailscale-derp; needing direct for this would be circular)
  2. fire our own burst at the peer's *observed* candidates only (we have no evidence their socket
     is up yet, so a guess now could poison it)
- **Burst**: 5 rounds, 30 ms apart. Each round is one new Probe frame (path id direct) sent to
  every candidate. Each is recorded in flight as "doesn't count as loss". A reply to a burst
  probe is a normal reply: it gives an RTT sample and marks the direct path up, which is how a
  punch turns into a working path.
- **On receiving Punch**: store its candidates, then in the background:
  1. if seq was 1, answer with our own Punch (seq 0) and an observed-only burst
  2. fire a burst at the peer's observed + predicted candidates
- **Predicted candidates are only ever used while answering a Punch.** A Punch means the sender's
  socket is bound and its packets are already leaving, the one moment a guess can't poison
  anything. Never on a timer, never speculatively.
- Punching skips peers that already have a confirmed address. (In the old code a confirmed address
  is never cleared, so punching never resumes after that path dies. See known-problems.md.)

## Why both STUN and punching are needed

- Endpoint-independent NAT (same outside port for every destination): the STUN address is the
  real one. The peer can reach it once our outbound burst has opened the mapping.
- Endpoint-dependent (symmetric) NAT: the STUN answer is useless. Seen in testing: STUN said
  `10.98.0.2:47778` while the mapping the peer actually used was `:32910`. With `--random-fully`,
  STUN server one saw 36423, server two saw 58696 and the peer saw 61397, all at once. What works:
  our burst reaches the peer from the real mapping, the peer records that source address as
  confirmed and adds it to candidates, and its replies reach us through that mapping.
- The old code got the reply there indirectly. The reply went through the normal direct send; the
  arriving packet had just overwritten the confirmed address with its source and added the source
  to the candidates. While the direct path isn't up yet (no reply within 15s, which is the case
  during a punch) that send sprays every candidate, the source included; once it's up the reply
  goes to the confirmed address, which is the source. A rewrite should simply reply to the source
  address of the direct packet.
- So: STUN carries endpoint-independent NATs, observing the punch carries endpoint-dependent ones,
  and port prediction covers port-preserving NATs cheaply. None of them covers the others.

## STUN (RFC 5389 subset)

- Binding request: type `0x0001`, length 0, magic cookie `0x2112A442`, 12-byte random transaction
  id. No attributes.
- Binding response: type `0x0101`, same cookie and transaction id, attribute `XOR-MAPPED-ADDRESS`
  (`0x0020`): port XOR (cookie >> 16), IPv4 XOR cookie, IPv6 XOR (cookie || transaction id).
  Attributes pad to 4 bytes. Check the transaction id.
- The node's parser also accepts plain `MAPPED-ADDRESS` (`0x0001`), which some servers still send,
  but only decodes IPv4 (family 1); an IPv6 mapped address is skipped. Only the control plane's
  encoder handles IPv6.
- The control plane answers any valid binding request with the source address it saw and ignores
  everything else.
- The node asks every server in the roster's `stun_servers` list, one after another, 3s timeout
  each, every 20s. Reflexive address = first answer.
- The old node parsed those entries as literal `ip:port` with no DNS lookup and silently dropped
  anything else. `MESH_STUN_SERVERS` was only used if none of the entries parsed. The list was
  fixed at startup, and empty if the control plane was down at boot.
- The control plane runs two responders on different ports (3478 and 3479). Asking two distinct
  destinations is the only way to tell per-destination mapping from per-source mapping.
- Why our own STUN: UDP 3478 outbound was blocked on the dev network, so Tailscale's DERP STUN
  wasn't usable, and the control plane is outside every node's NAT anyway.

## NAT classification

From our local port L and the observations O, one per STUN server in order:

| observations | result |
|---|---|
| none | Unknown |
| one, port == L | PortPreserving |
| one, port != L | Unknown (one sample can't tell independent from dependent) |
| several, all the same port, == L | PortPreserving |
| several, all the same port, != L | EndpointIndependent |
| several, ports differ | EndpointDependent { delta = last.port - first.port } |

Predicted candidates (public IP = first observation's IP), spread 4:

- PortPreserving or Unknown: `ip:L`
- EndpointIndependent: none (the observed address already covers every destination)
- EndpointDependent: `ip:L` first (preservation may still hold for a fresh destination), then
  `last.port + step*k` for k = 1..4, step = delta (or 1 if delta is 0), kept inside 1..65535

The spread is small on purpose: each guess is a packet at a port nobody opened, and the cost lands
on whoever we guessed at.

## Poisoned ports

The motivating case was a real ISP CGNAT: 1:1 port-preserving (bind 7777, outside sees 7777),
until something probes that port from outside *before* you bind it. After that the same bind gets
a random port. Predicting is trivial; not poisoning it is the actual work.

- Detection: two or more observations and none of them equals L. The old node only checked this
  once, on the first STUN round that got any answer.
- Intended recovery: persist "poisoned" in the node state; next start binds a different port
  (old code: previous port + 1, at least 1024), then clears the flag.
- Reality in the old code: detection only logged a warning. Nothing ever set the flag, so the
  recovery never ran. See known-problems.md.

## What was actually tested

- Flat network (containers on bridges that OrbStack routes between): direct path found at once,
  from interface candidates alone. That compose advertised STUN by hostname, which the nodes
  dropped, so STUN wasn't exercised there.
- Simulated CGNAT, port-preserving masquerade: classified PortPreserving
  (`observed=[10.98.0.2:47778, 10.98.0.2:47778]`, local 47778), direct at 0.2 ms.
- Simulated symmetric NAT (`MASQUERADE --random-fully`): direct at 0.57 ms via punch observation.
- Never tested against a real CGNAT.
