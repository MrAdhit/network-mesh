# Mesh protocol

The same frame, byte for byte, rides every path. That's what makes RTTs comparable across
Cloudflare, DERP and direct. Only the wrapping underneath differs per path.

## Frame (version 2)

Integers are big-endian.

| offset | size | field |
|---|---|---|
| 0 | 4 | magic `MESH` |
| 4 | 1 | version, `2` (version 1 had no sender key) |
| 5 | 1 | message type |
| 6 | 1 | path id: 1 = cloudflare, 2 = tailscale-derp, 3 = direct |
| 7 | 1 | sender name length (name truncated to 255 bytes) |
| 8 | 8 | seq, u64 |
| 16 | 32 | sender's Ed25519 public key |
| 48 | n | sender name, UTF-8 |
| 48+n | rest | payload |

- Decode rejects: under 48 bytes, wrong magic, other version, unknown type or path id, name
  running past the end.
- An encoded frame over 1300 bytes is refused at send time.
- The receiver ignores the name and uses the roster's name for that key. It's a label only and
  could be dropped. It also costs MTU: with the 1300 cap, a full 1100-byte packet only fits if the
  name is at most 152 bytes (tun.md).
- Path names used in CLI and IPC output: `cloudflare`, `tailscale-derp`, `direct`.

## Message types

| type | name | payload | what the receiver does |
|---|---|---|---|
| 1 | Probe | empty | send ProbeReply with the same seq and the same path id, on the path the probe arrived on |
| 2 | ProbeReply | empty | look up in-flight probe (peer key, path id, seq); if found, record the RTT for that path and wake any `ping` waiting on it |
| 3 | Hello | HelloPayload JSON | learn the peer's details (below). If seq = 1, answer immediately with a Hello of seq = 0 |
| 4 | Data | bytes | debug message from `meshctl send`; the daemon logs it |
| 5 | Tunnel | one whole IP packet | write it to the TUN unchanged |
| 6 | Punch | HelloPayload JSON | hole-punch request, see direct-path-and-nat.md |

- The path id says which path the sender used. The reply echoes the probe's path id so the RTT is
  credited correctly even if routing were asymmetric.
- Seq is one counter per node starting at 1, shared by probes (normal, ping and punch-burst),
  Data and Tunnel frames. Hello and Punch messages instead use seq as a flag: 1 = "please
  answer", 0 = "this is an answer". Answers carry 0 so they can't ping-pong.

## HelloPayload

JSON, used by both Hello and Punch. Empty fields are omitted, missing fields default, and unknown
fields must be ignored. JSON was chosen so fields can be added without a frame version bump.

```json
{
  "cf_ip": "10.96.0.7",
  "direct": ["192.168.1.5:47778", "203.0.113.9:47778"],
  "predicted": ["203.0.113.9:47778"],
  "seen_you_at": "203.0.113.9:41000"
}
```

- `cf_ip`: the sender's own address inside the Cloudflare Mesh range. This is the only way a
  peer learns it (which is a design flaw, see known-problems.md).
- `direct`: the sender's direct-path candidates: interface addresses plus its reflexive address.
- `predicted`: port guesses from the sender's NAT profile. Kept apart on purpose; they're only
  used while answering a Punch.
- `seen_you_at`: the source address the sender saw the receiver's direct traffic come from. The
  receiver takes it as its own reflexive address. It only exists after a direct packet already
  arrived, so it confirms rather than bootstraps. (The old node had a single reflexive slot that
  STUN and every peer's `seen_you_at` kept overwriting; see known-problems.md.)
- Empty or unparseable payload: ignore it. Unparseable addresses inside: skip them.

## Membership and the peer table

- The peer table is exactly the roster, keyed by the peer's Ed25519 public key (base64 in the
  roster, 32 bytes decoded; entries with a bad key are skipped with a warning). Nothing else can
  create a peer.
- Keyed by key and not by name because names aren't unique. The default name was the same string
  on every systemd install, and keying by name made the second `mesh-node` overwrite the first,
  so every frame from the loser got dropped as "not in roster".
- On each roster refresh: add new peers, update name and virtual IP (a rename moves the label, not
  the identity), drop peers no longer listed. Facts learned from traffic (CF IP, DERP node key,
  candidates, path stats) survive refreshes.
- Inbound frame from a key not in the roster: drop. This is how the mesh stays isolated from the
  other devices on the shared tailnet and Cloudflare org.
- Nothing is signed or encrypted. The key in a frame is an assertion anyone can copy. This is the
  biggest gap in the old design; see known-problems.md item 1.
- CLI peer lookup matches name, mesh IP, or Tailscale hostname and returns every match. If a name
  matches several peers, error out and list their mesh IPs so the user can pick one.

## Wrapping per path

**cloudflare.** The tunnel carries raw IP packets, so each frame goes inside a real IPv4/UDP
packet:

- IPv4: `0x45`, TOS 0, total length, ident from a per-node u16 counter, flags DF (`0x4000`),
  TTL 64, protocol 17, correct header checksum. Source = our CF mesh IPv4, destination = the
  peer's CF mesh IPv4.
- UDP: source and destination port 47777, length, checksum over the pseudo-header (a computed 0 is
  sent as `0xffff`).
- Both checksums have to be real. Cloudflare routes these as normal packets.
- Receiving: parse IPv4/UDP, keep only destination port 47777, decode the frame. The tunnel also
  delivers ICMP, IPv6 and other traffic; ignore all of it.

**tailscale-derp.** Frame bytes as-is to the peer's Tailscale node public key through DERP.
Inbound packets come with the sender's node key, which becomes that peer's DERP address.

**direct.** Frame bytes as-is in a UDP datagram, default port 47778. One socket per node, also
used for STUN.

## Timers and who sends what

- At start: Hello (seq 1) to every peer on every path.
- Every probe interval (1s default, `MESH_PROBE_INTERVAL_SECS`):
  1. if our Cloudflare backhaul is up, re-Hello every peer whose CF IP is still unknown (otherwise
     the CF path sits at 100% loss until the next scheduled Hello)
  2. one Probe per peer per path, all at once
  3. expire old in-flight probes (path-selection.md)
- Every 10th probe round: Hello to everyone (catches peers that joined since).
- Every 20s: NAT traversal round (STUN, then Punch to peers without a confirmed direct address).
- Every 30s: roster refresh from the control plane, first one 30s after start. In the old code it
  only updated the peer list; everything else in the roster was read once at startup.
- Which paths a peer gets probed and greeted on: cloudflare if our CF backhaul exists, tailscale-derp
  if our TS backhaul exists, direct if the peer has a confirmed direct address or any candidates.
- Every path send goes through a 2s cap (the raw punch-burst and STUN sends don't). The probe
  round, Hellos and Punch requests fan out concurrently across peers and paths. An earlier version
  walked every path in series with unbounded awaits, and one blocked DERP send stalled the whole
  probe loop until every path, healthy ones included, aged out.
- Still serial at `a324c0b`: each receive loop handles a frame, including sending its reply, before
  reading the next; the TUN reader waits out the whole failover chain per packet; the punch round
  goes peer by peer; STUN servers are asked one at a time. See known-problems.md.

## Learning from inbound frames

After the roster check passes:

- arrived on direct from address A: A becomes the peer's confirmed direct address (log when it
  changes) and is added to its candidate list
- arrived on DERP from node key K: K is that peer's DERP node key from now on
- Hello: store `cf_ip`, merge `direct` and `predicted` into the capped candidate lists, and take
  `seen_you_at` as our own reflexive address
