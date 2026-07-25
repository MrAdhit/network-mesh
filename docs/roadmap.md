# Roadmap: control plane, discovery, TUN

Written 2026-07-25, after the MVP landed. Supersedes the ordering notes in PLAN.md.

> **All three phases are built and demonstrated as of 2026-07-25.** What follows is the plan as
> written; the notes at the end record where reality differed.

## What changed

Two decisions narrow the design usefully:

**No interoperability with `tailscaled` peers.** It was never a target. Tailscale and Cloudflare
are backhauls and nothing more. So we implement our own discovery rather than Tailscale's disco
protocol, and we do not need their disco keys, their `TS💬` framing, or their control plane's
view of anything except our own node.

**Our mesh must only ever see our own nodes.** Membership is explicit. A machine is in the mesh
because it is in our roster, not because it happens to be reachable.

The second one is not the current behaviour and has to be fixed before anything else is built on
top. Today `MeshNode::handle_frame` adds any sender it has never heard of, and the Tailscale
backhaul resolves peers by scanning the whole netmap, which on this tailnet is twenty personal
devices. Neither is acceptable under the new rule.

A useful consequence: we can stop consuming the netmap altogether. We still need Tailscale
registration, because their DERP servers verify clients against the control plane before relaying,
and we need the DERP map, which is served unauthenticated at `/derpmap/default`. We do not need
the peer list. Dropping it removes the hostname-deduplication fragility that cost time during the
MVP and satisfies the isolation requirement structurally rather than by filtering.

---

## Phase 1: the control plane

A third service with its own database. It owns accounts, subnets, node identity, address
allocation, and the users' backhaul credentials. A static roster file was me dodging this; it is
not a registration process.

The shape mirrors what we reverse-engineered from both vendors, because they both solved this the
same way: one credential the human obtains once, a different credential the node holds forever.

### Registration

**Per network, by the human.** Sign up, get an account, choose the subnet, paste the backhaul
credentials, mint an enrollment key. The enrollment key is our `tskey-auth-...`: shareable,
reusable, expiring, and it grants only the right to join.

**Per machine, once.** `meshd` generates an Ed25519 keypair on first start and posts its public
key, a hostname and the enrollment key. The server validates, allocates the next free address in
the account's subnet, records the node, and returns the assigned IP, the subnet and a node token.
That address is stable for the life of the node record, which is exactly what the TUN interface
needs.

**Ongoing.** The node polls the roster with its node token: subnet, plus every sibling's name,
virtual IP and public key. Membership is whatever that list says. Online status falls out of poll
recency.

### Backhaul credentials

Users supply their own, so each mesh rides its owner's Tailscale and Cloudflare accounts. Stored
per account, never handed to nodes in raw form.

| Stored | Used for |
|---|---|
| Cloudflare API token + account id | provisioning the Zero Trust org, minting the service token |
| Cloudflare team name + service token | given to nodes so they can register and enroll MASQUE |
| Tailscale API token | minting a fresh auth key per node, on demand |

The important property is that the control plane holds the powerful credential and issues weak,
narrow, short-lived ones downward. Nodes never see either API token. That is the same split the
vendors use and it is worth copying rather than storing a long-lived auth key and shipping it
everywhere.

Two consequences worth naming. Tailscale auth keys expire and ephemeral node records get reaped,
so a node asks for a key when it needs one rather than being issued one at enrollment; that makes
a restart after reaping self-healing. And the Cloudflare org provisioning is exactly the sequence
already proven by hand in `cloudflare-auth.md` §7, so it is transcription rather than research.

Credentials get validated the moment they are pasted, with `/tokens/verify` on the Cloudflare side
and a cheap authenticated GET on the Tailscale side, so a typo surfaces immediately instead of as
a mysterious enrollment failure later.

### Endpoints

```
POST   /v1/accounts                      sign up
POST   /v1/sessions                      log in
GET    /v1/network                       subnet, node count, backhaul status
PATCH  /v1/network                       change the subnet
PUT    /v1/network/backhauls/cloudflare  api token + account id; provisions the org
PUT    /v1/network/backhauls/tailscale   api token
POST   /v1/enrollment-keys               mint one
GET    /v1/nodes                         node list, IPs, last seen
DELETE /v1/nodes/{id}                    revoke a node, free its address

POST   /v1/enroll                        node joins: returns ip, subnet, node token
GET    /v1/roster                        node pulls peers and backhaul config
POST   /v1/nodes/me/tailscale-auth-key   node asks for a fresh auth key
```

Top block is the human, bottom block is `meshd`. Same split as everywhere else here.

### Mesh-side effects

- `MESH_PEERS` disappears; the roster replaces it.
- The virtual IP comes from the server rather than being invented locally.
- The node's Ed25519 key is both its control-plane identity and its mesh membership key, so there
  is only one identity to manage.
- Frames carry the sender's public key, and anything not in the roster is dropped.
  `handle_frame` stops auto-adding peers.
- Peer identity stops depending on the Tailscale netmap. The mesh then sees exactly the nodes the
  roster lists, and the other twenty devices on the tailnet become invisible to it.

### Storage and failure

SQLite in a volume. Schema is account-scoped from the start even though there is one network per
account today, so multi-tenancy never needs a migration.

The control plane must be reachable over the ordinary internet rather than over the mesh, or
there is a bootstrap loop. In dev it is a third container on a network both nodes can reach. When
it is down, existing nodes keep running from their cached roster and only new joins fail, which
is the right way for this to degrade.

### Security, stated plainly

This database now holds credentials that grant real access to the user's Cloudflare and Tailscale
accounts. That is a different risk class from mesh node keys, and "security is out of scope"
should not quietly extend to it. Minimum bar before this is exposed to anyone but us: encrypt the
backhaul credentials at rest, scope the vendor tokens as tightly as each vendor allows, and never
send them to nodes.

Worth knowing on scoping: a Cloudflare API token can be limited to Account, Zero Trust, Edit. A
Tailscale personal API token cannot be narrowed much; an OAuth client with the `auth_keys` scope
is the tighter option, at the cost of requiring a tag in the user's ACL. API token for now, OAuth
as the production answer.

Not doing yet: signing mesh frames. Without it the roster check is advisory, since anyone able to
reach our DERP node key could assert a membership key they do not hold. Carrying the key in the
frame now makes real verification a small change later.

## Phase 2: discovery and direct paths

Our own protocol, over the bootstrap channel we already have.

- Bind a UDP socket per node.
- Extend `Hello` to carry endpoint candidates: local interface addresses, plus whatever address a
  peer reports having seen as our source. That second half is how this works behind NAT without
  STUN, which matters because UDP 3478 is blocked on this network.
- Probe every candidate, first reply wins, promote the result to a third entry in the path table
  that already exists.
- Trust timer, periodic re-probe, fall back to the relays when it goes quiet.

Testable in the containers immediately. They reach each other directly at about 0.15ms, against
35ms via Cloudflare and 95ms via DERP, so a working implementation is unmistakable.

Not tested by that: NAT traversal. There is no NAT between two OrbStack bridges, so the first
candidate will simply work and the hole-punching path stays cold. Proving that needs a second
real host. Nothing in this phase forecloses it.

## Phase 3: TUN

- Create the device, assign the node's virtual IP from the roster, route the subnet to it.
- Encapsulate whole guest packets inside the existing `Data` frame.
- Pin the MTU at 1280 and enforce the ceiling in code.
- Containers need `CAP_NET_ADMIN` and `/dev/net/tun`.

Encapsulating rather than rewriting kills two of the open problems in PLAN.md outright. The
guest's 5-tuple never changes when the path flips, so a path switch mid-connection does not break
TCP (gap 3), and we never touch the inner packet, so there are no checksums to recompute (gap 4).

MTU is the real hazard. A Connect-IP datagram leaves roughly 1200 usable bytes, less our frame
header and the IPv4/UDP wrapper inside the tunnel, and DERP has its own ceiling. Set it too high
and large packets disappear silently.

---

## Defaults being used

Unless overridden: subnet `10.201.0.0/16`, chosen to avoid Tailscale's `100.64/10`, Cloudflare's
default `100.96/12` and the `10.96/16` this org actually uses. Roster as a JSON file mounted into
each container. Node keys Ed25519.


---

## Outcome

All three phases landed. Measured between two containers, control plane in a third:

```
peer mesh-b (10.201.0.3)  cf=10.96.0.7  best=direct
  path              state    last ms    ewma ms    sent    recv  loss %
  cloudflare           up      33.91      32.77      74      73      1%
  tailscale-derp       up      83.03      89.45      75      74      1%
  direct               up       0.37       0.27      58      57      2%
```

Real ICMP and TCP ride the `mesh0` interface; 2MB over TCP moved at about 350 Mbit/s.

The claim worth checking was that a path flip cannot break an established connection. It holds.
With a TCP stream running over the direct path, dropping UDP 47778 moved the winner to
Cloudflare, latency went from 0.2ms to 35ms, and the stream kept counting without a gap or a
reconnect. That is gaps 3 and 4 from PLAN.md closed by construction rather than by handling.

### Where the plan was wrong

**Discovery needed no probe/promotion protocol of its own.** The design assumed a candidate
exchange followed by explicit probing and a promotion step. In practice the probing already
existed: the path table probes every path it knows about, so the direct path only needed
candidates and a way to confirm one. Confirmation turned out to be free, because a packet that
arrives directly proves the address it came from works. There is no separate handshake anywhere
in `direct.rs`.

**Reflexive address learning is present but circular, and does not work.** `seen_you_at` is
populated from `direct_confirmed`, which is only set once a packet has already arrived on the
direct socket. So we tell a peer their public address only after they have already reached us
directly, which is exactly the case where they no longer need it. On a flat network it is
harmless and unused. Behind NAT it can never bootstrap. This was written as though it were the
NAT half of the problem; it is not, and the claim has been corrected here.

**MTU is 1100, not 1280.** The plan guessed 1280. Working back from an actual QUIC datagram,
after Connect-IP framing, the IPv4/UDP wrapper inside the tunnel, and our own 48-byte header,
1100 is what survives on the tightest path. Since the path can flip mid-connection, every path
has to carry any packet, so the tightest one sets the number for all three.

**Frames grew a sender key rather than gaining signatures.** As planned, membership is asserted
rather than proven. The roster check does stop a stranger's traffic from creating a peer, which
was the requirement, but it would not stop someone who can forge a key they do not hold.

### One surprise worth repeating

A freshly enrolled Cloudflare Mesh device is not reachable by its peers for the first minute or
two, even with a healthy tunnel on both ends and correct addresses. It resolves itself. It looks
identical to a client bug, and it cost time twice before we recognised it. Recorded in
`cloudflare-auth.md` §8.

### Still open

- Signing frames, which turns the membership check from an assertion into a proof.
- Testing against a real CGNAT rather than a simulated one.
- IPv6 inside the tunnel. The TUN path is IPv4 only; v6 packets are dropped.
- Reporting measured latencies back to Tailscale with `set_home_region`.
- A web UI for the control plane; today it is API plus `meshctl`.


---

## Phase 4: NAT traversal

Added after the fact, once the question "is this actually hole punching?" got a truthful answer
of no. It is now.

Two pieces, both needed, and it turns out for different reasons.

**A STUN responder on the control plane.** Real RFC 5389 rather than something bespoke, so the
same client can point at any public STUN server as a fallback. The control plane is the natural
home: every node already talks to it and it sits outside whatever NAT the nodes are behind. It
also sidesteps UDP 3478 being blocked outbound on this network, which rules out Tailscale's DERP
STUN. The query goes out of the *same socket* the direct path uses, because a NAT maps per source
port and an address learned on another socket describes a mapping our traffic does not have.

**A `Punch` message relayed over the backhauls.** Hole punching needs both sides transmitting in
the same window: each side's outbound packet is what opens the binding the other's inbound packet
needs. Independent timers do not reliably overlap, so one side asks and both fire a burst. This
is the same job Tailscale gives call-me-maybe, and like Tailscale we send it over the relay we
already have.

### The result, and the part worth reading

Simulated CGNAT: `mesh-a` on a private segment behind a masquerading router, `mesh-b` on the far
side, no shared network, and `mesh-b` explicitly blocked from routing into the private range. A
direct path forms anyway, at 0.4ms with no loss, carrying ICMP and 671 Mbit/s of TCP.

The interesting part is *which* address worked. STUN told `mesh-a` it was seen at
`10.98.0.2:47778`. The binding `mesh-b` actually used was `10.98.0.2:32910`. The router allocated
a different mapping for the peer flow than for the STUN flow, which is endpoint-dependent
mapping, and it means the STUN answer was useless for this NAT. What saved it was the punch:
`mesh-a`'s outbound burst created a binding, `mesh-b` observed the source address of the packet
that arrived, and replied there.

So the two mechanisms are not redundant. STUN carries endpoint-independent NATs; peer observation
of a punch carries endpoint-dependent ones. Tailscale implements both, and now it is obvious why.

### Two bugs this shook out

**Discovery looped through the mesh.** `local_candidates()` enumerated every interface, which
after phase 3 includes `mesh0`. So each node advertised its own overlay address as a direct
candidate, the peer reached it through the mesh, and it was confirmed as a "direct" path. It
worked, which is what made it dangerous: the path read as direct while carrying relay latency and
loss, and the fix only became obvious after noticing a "direct" RTT of 118ms between two
containers on one host. Direct candidates now exclude our own subnet.

**The first CGNAT test was not a NAT test.** OrbStack routes between bridge networks, so `mesh-b`
could reach `10.99.0.10` at 0.1ms and no punching was ever required, while the output looked like
success. The test now blocks the private range at `mesh-b` and asserts the shortcut is gone
before drawing any conclusion. Same lesson as the earlier isolation claim in `docker-compose.yml`:
on this host, two Docker networks are not a boundary unless you make one.


---

## Phase 5: port prediction

Driven by a description of a real ISP CGNAT, which turned out to change what the work was.

That NAT is 1:1 port preserving: bind 7777 and the outside sees 7777. Unless something probes
7777 from outside *before* you bind, in which case the same bind gets a random port instead.

Two things follow. Prediction itself is arithmetic and barely worth the name, since the answer is
usually "the port you already asked for". And the real engineering is not poisoning the mapping,
because a guess aimed at a port nobody has opened is exactly the event that destroys it.

### What was built

**Classification, in `nat.rs`.** The control plane now runs two STUN responders on different
ports, so a node can ask two distinct destinations and compare. Same external port from both and
equal to the local port is `PortPreserving`; same but different is `EndpointIndependent`;
different is `EndpointDependent`, carrying the delta between observations. One observation is
deliberately classified `Unknown`, because a single sample cannot tell the first case from the
last.

**Predicted candidates are kept apart from observed ones** in the `Hello` payload, and are only
ever fired at while answering a `Punch`. That message means the sender is transmitting right now,
so its socket is bound and its mapping exists, which is the one moment a guess cannot poison
anything. Never on a timer, never speculatively. The spread is four ports, small on purpose,
because the cost of guessing wide is paid by whoever we guessed at.

**Poisoning is detected and recovered from.** If every observation disagrees with the port we
asked for, the mapping is gone and no amount of retrying will bring it back. That fact is
recorded in the node's state, and the next start binds a different local port rather than
inheriting the problem. It has to persist, because the poisoned state outlives our process.

### Tested both ways

`./cgnat-test.sh` runs the port-preserving case; `NAT_MODE=random ./cgnat-test.sh` switches the
router to `MASQUERADE --random-fully`, which is a symmetric NAT.

Port preserving classified correctly, `observed=[10.98.0.2:47778, 10.98.0.2:47778]` against
`local_port=47778`, direct path at 0.2ms.

Symmetric also formed a direct path, at 0.57ms, and the numbers say why prediction had nothing to
do with it. Three different external ports were in play at once: STUN server one saw 36423,
server two saw 58696, and the peer observed us at 61397. No arithmetic connects those. What
worked was the peer replying to the source address of the punch that reached it.

So the two mechanisms divide the space cleanly. Prediction handles port-preserving NATs, which is
the common case and the one the user's ISP presents. Peer observation handles everything else.
Neither subsumes the other.

### A bug this uncovered

Nodes were choosing their own nearest DERP region independently. A DERP server only relays
between clients connected to *it*, so the moment two nodes measured different regions they could
not reach each other at all, and the Tailscale path read as 100% loss with no error anywhere. It
had been working purely because both containers kept measuring the same region.

The roster now carries one `derp_region` for the network, set by the first node to report a
measurement, and every node uses it. First-wins rather than best-wins: a slightly further relay
that everyone shares beats a nearer one that isolates somebody.
