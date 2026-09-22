# Known problems in the old code

Found by reading the code at `a324c0b` (me, then two independent review passes that checked each
item against the code). Nothing here was reproduced at runtime unless it says so. It's listed so
the rewrite doesn't inherit it. Whether and how to fix each one is the user's call.

## Security

1. **Mesh frames are neither authenticated nor encrypted.** A frame carries the sender's Ed25519
   public key and the receiver only checks that the key is in the roster. Public keys are in every
   roster and in every frame in plaintext. So anyone who can get a packet to a node can claim to be
   any member and:
   - inject arbitrary IP packets into the node's kernel with Tunnel frames
   - hijack all three paths to that member: a forged direct packet sets the member's confirmed
     direct address to the attacker; a forged Hello sets the member's Cloudflare IP; a forged frame
     sent over DERP from the attacker's own Tailscale node sets the member's DERP node key.
     Answering the probes keeps the hijacked path "up" and winning.
   The relays see plaintext as well: Cloudflare sees everything in the tunnel, DERP servers see
   every frame. The old docs admitted membership was "asserted, not proven" and planned signing.
   Signing alone would still leave traffic readable.
2. **Inner packets aren't checked.** A Tunnel frame's payload goes into the TUN as-is. Nothing
   checks that its source IP is the sending peer's mesh IP (a member can spoof another member), or
   that its destination is our own mesh IP (a peer can hand our kernel packets for other networks,
   which a host with forwarding on would route onward).
3. **The Cloudflare TLS pin can be bypassed.** The verifier checks that the enrolled SPKI bytes
   appear inside the server certificate, but reports every TLS 1.3 handshake signature as valid
   without checking it, so presenting a certificate that merely contains Cloudflare's public key is
   enough. It also fails open: if the saved endpoint key doesn't decode, or decodes to nothing, any
   certificate is accepted.
4. **IPC is unauthenticated** and the socket gets no explicit permissions. Anyone who can open it
   can drive the daemon, including `leave`. Whether that's root-only in practice is unclear.
5. **State files are written with default permissions** (likely 0644): the identity key, the node
   token and the Cloudflare private key. install.sh chmods the state dir to 700, but a package
   install relies on systemd's `StateDirectory` default of 0755, so they're probably
   world-readable there. Inferred, not tested.
6. **`MESH_CP_SECRET` isn't run through a KDF** (a homemade FNV-style mixer). If it's unset, a
   random key per process makes stored credentials unreadable after a restart. Then every roster
   fetch for an account with Cloudflare credentials returns 500 and Tailscale key requests fail. A
   node that enrolls during that state never gets any peers (its cached roster is empty and refresh
   errors are ignored).
7. **Enrollment keys** are reusable for 90 days and can't be listed or revoked. Sessions can't be
   revoked server-side; logout only deletes the local file.

## Eviction doesn't stick

The rule was: a removed node never rejoins by itself. The old code breaks it.

8. **A removed node can rejoin on its own.** A key is only consumed when an enrollment actually
   happens. So a key left in `MESH_ENROLLMENT_KEY` (the dev compose sets it permanently, and the
   daemon's own shutdown message tells operators to set it), or staged by re-running
   `install.sh --key` on an already-enrolled node, just stays. After `remove-node`: three 401s, the
   daemon shuts down, the service manager restarts it, the startup roster fetch gets 401, the daemon
   finds the key and re-enrolls. It only needs the key to still be valid, and keys last 90 days with
   no way to revoke them.
9. After `leave`, if `MESH_ENROLLMENT_KEY` is in the environment, the restart enrolls straight away
   as a brand-new node.
10. A bad staged or env key on an unenrolled node crash-loops the daemon: the enrollment error is
    fatal and happens before idle mode, so `meshctl join` can never be used to fix it.

## Bootstrap and discovery

11. **A Cloudflare-only mesh can't bootstrap.** A peer's CF mesh IP is only learned from a Hello,
    and sending a Hello over Cloudflare needs that IP. With DERP down and no direct path, two nodes
    never learn each other's CF address. Fix idea: nodes report their CF IP and their Tailscale node
    key to the control plane and the roster carries them. That would also remove the netmap
    hostname lookup and its dedup guessing entirely.
12. **STUN server hostnames are silently dropped.** The roster's `stun_servers` are parsed as
    literal `ip:port`, no DNS. `meshcp:3478` (the default dev compose) or `cp.example.net:3478` (the
    packaged env example) gives zero STUN servers, no error. `MESH_STUN_SERVERS` only kicks in if
    none of the entries parse. The flat dev network therefore ran without STUN; only the NAT test
    compose (which used IPs) had it.
13. The packaged control plane advertises no STUN servers (`MESH_CP_STUN_ADVERTISE` is commented
    out in its env file).
14. **Punching stops forever once a direct address is confirmed.** The confirmed address is never
    cleared, and the punch timer and the burst both skip confirmed peers. If a NAT mapping expires
    later, the path goes back to spraying candidates but nobody coordinates a punch again.
15. **Direct replies aren't explicitly sent to the source.** A reply goes through the normal direct
    send. Because the arriving packet has just overwritten the confirmed address with its source,
    the reply goes to the source when the direct path is up, and is sprayed to every candidate
    (source included) while it isn't, which is the situation during a punch. The source is also
    added to the candidate list with a plain push that skips the 16 cap and the plausibility filter.
    A peer whose direct path is down gets the whole spray on every probe, every second.
16. **One reflexive-address slot, last write wins.** Each STUN round overwrites it, and so does
    every Hello from any peer carrying `seen_you_at`. Only one reflexive candidate is ever
    advertised, and behind an endpoint-dependent NAT it flips between different peers' observations.
17. **The poisoned-port recovery never runs.** Nothing ever sets the "poisoned" flag; detection
    only logs a warning, and only on the first STUN round that got an answer.
18. Peers without Cloudflare get re-Hello'd every second forever (the "CF IP unknown" re-greet has
    no stop condition), and each one answers with a Hello on every path.
19. **The node name eats the packet budget.** Frames are capped at 1300 bytes and names can be 255
    bytes, so a full 1100-byte packet only fits if the name is at most 152 bytes; longer names get
    every full-size packet refused on all paths (answered with ICMP unreachable). The Cloudflare
    path adds a 28-byte IPv4/UDP wrapper inside a QUIC datagram, so it's tighter there; my inference
    is that names beyond roughly 20 bytes may push full-size packets over the datagram limit on
    Cloudflare. Unverified.

## Failure handling

20. **Failed sends aren't counted.** A probe is only tracked if its send succeeded. A send that
    errors or hits the 2s cap is logged and forgotten: not sent, not lost. So a path whose sends fail
    keeps a frozen loss figure and only goes down through the 15s timeout. The unpinned direct spray
    is the opposite: it reports success even if every packet failed, so those probes do get charged
    as losses. In `ping`, a failed send is shown as a timeout at once but never charged.
21. **A dead Cloudflare tunnel is noticed late.** After a network drop quinn keeps accepting
    datagrams until the connection's idle timeout (30s) declares it dead; until then they're silently
    lost. The reconnect only starts when the receive side errors.
22. **Plenty is still serial.** Each receive loop handles a frame, including sending its reply (up
    to 2s per path), before reading the next, so one slow reply stalls that backhaul's inbound
    traffic. The TUN reader handles one packet at a time and waits out the failover chain (up to 2s
    per failing path), stalling all outbound traffic. The 20s punch round goes peer by peer, STUN
    servers are asked one after another, DERP bootstrap sends and candidate sprays are sequential,
    and the burst and STUN sends bypass the 2s cap.
23. **Windows TUN reads die permanently.** The Wintun reader thread exits on its first error; after
    that every read fails immediately, the node logs it every 200 ms, and no inbound packet arrives
    until a restart.
24. **A Tailscale netmap stream that ends is only logged.** Nothing re-registers, so the peer table
    used for DERP bootstrap is frozen for the life of the backhaul.
25. **Fatal startup errors,** despite the "keep running on whatever it has" goal: a malformed
    `state.json`, an IPC bind failure, an unparseable own IP in the roster, any failure to save
    state, and an enrollment failure when a key is present (item 10).
26. **Idle mode handles IPC connections one at a time with no timeout.** A client that connects and
    sends nothing blocks `status` and `join` for everyone. Accept errors retry forever there.

## Lifecycle gaps

27. **The 30s roster refresh only updates peers.** Subnet, own IP, STUN servers, DERP region and
    backhaul config are read once from the startup roster. The startup fetch reports nothing
    (no `derp` or `cf_device`).
28. **Offline start:** the cached roster has no STUN servers or DERP region, and Tailscale can't
    come up at all until the control plane is back (auth keys come from it).
29. **Backhauls configured after a node started never come up** without a restart. The retry tasks
    only exist for backhauls that had config at startup.
30. **One DERP region was never actually enforced.** The node reads `derp_region` only from the
    startup roster, reports its own region only on refreshes and only if Tailscale came up at
    startup, and DERP reconnects reuse the first region's servers. A node stays on its own measured
    region until restart if: it started within about 30s of another node on a fresh network and lost
    the first-writer race, it booted during a control plane outage, or its Tailscale came up through
    the retry task. Its DERP path to everyone else then shows 100% loss.
31. The first-writer DERP region can never change. If it disappears from the DERP map, each node
    falls back to measuring on its own and they can split.
32. **Late-adopted backhauls never report** (until the next restart): no DERP region from a
    Tailscale backhaul adopted later, and no device id from a Cloudflare device enrolled later, so
    removing that node leaks the device.
33. **Orphan Cloudflare devices on retry.** Nothing is saved until the MASQUE PATCH succeeds. If
    `POST /reg` works but the PATCH fails (a retired client version, say), that registration is
    abandoned and the 5s-to-60s retry registers a new device on every attempt, roughly one a minute,
    never deleted.
34. **A saved Cloudflare registration is reused forever,** with no re-enroll fallback. `remove-node`
    deletes the node's Cloudflare device, but a node that rejoins keeps its saved registration, so
    its Cloudflare path is probably broken for good after a rejoin. Effect unverified.
35. **Deregistering needs a running daemon.** `leave` goes through the daemon. The node token is
    also in `state.json`, but the CLI never reads it, so uninstalling with the daemon dead leaves a
    ghost node holding an address.
36. **`leave` reports `left` even when deregistration failed** (the failure is only in `detail`),
    and uninstall.sh only checks the exit code, so it prints "done; nothing of ours is left" while
    the control plane still has the record.
37. **Package removal can't deregister.** preremove stops the daemon, and by the time postremove
    runs, `/usr/bin/meshctl` and `/usr/lib/mesh/uninstall.sh` are already deleted (they're package
    files), so the purge branch falls back to `rm -rf /var/lib/mesh /etc/mesh` and the control plane
    keeps the record. rpm passes `0` on every erase, which takes the purge branch, so `dnf remove`
    always wipes local state. `apt purge` runs `postrm remove` first (which prints "kept
    /var/lib/mesh") and then wipes it.
38. **Package upgrades re-enable a disabled service.** The postinstall enables and starts the unit
    whenever it isn't enabled, upgrades included (both packages).
39. **`apt purge meshcp` deletes the env file holding `MESH_CP_SECRET`** (it's a conffile) but keeps
    the database. A reinstall generates a new secret and every stored credential becomes unreadable.
40. **The Linux install doesn't tell the daemon which control plane to use.** `MESH_CP_URL` is
    commented out in the generated `meshd.env` and the unit sets nothing, so the daemon uses the URL
    compiled into the binary; CI baked `https://mesh.mradhit.net` into every build. Only the macOS
    plist sets it. A self-hosted control plane serving CI-built binaries would have its nodes enroll
    somewhere else.
41. Re-running install.sh on a running node replaces the binaries but doesn't restart the daemon.
42. **Node names:** the default is `mesh-node` under systemd and launchd, because it reads the
    `HOSTNAME` env var, which services don't get (the packaged env file's comment says it defaults to
    the hostname, which is wrong). Also, the roster name is fixed at enrollment while the name
    registered with Tailscale is the local name at each start, so after a local rename the DERP
    bootstrap lookup can miss.
43. `MESH_PROBE_INTERVAL_SECS=0` panics (tokio's interval rejects zero). Several env vars break when
    set but blank; see config-reference.md.
44. `state.json` has a `tailscale` section that's never written.

## Control plane

45. `public_key` is unique across all accounts, but the enroll lookup is per account, so the same
    key enrolling into a second account hits the constraint and returns 500.
46. Address allocation reads the taken addresses and inserts in separate steps with no transaction.
    Concurrent enrollments can collide; the loser gets a 500.
47. **Subnet validation has holes.** Only the network address is checked for being private, so
    `10.0.0.0/7` (which covers public space) passes. Host bits are accepted and stored verbatim
    (`10.201.0.5/16`) and handed to nodes, which `ip route` on Linux will probably reject. It isn't
    checked against the Cloudflare org's actual Mesh range or the node's LAN.
48. Enrollment accepts any non-blank public key and any name. A garbage key enrolls fine and every
    peer then skips it with a warning.
49. Errors aren't uniformly JSON: the web framework's own rejections are plain text with other codes
    (415 wrong content type, 400 bad JSON, 422 missing field, 400 for a bad `derp=`), and the update
    download's 404 is plain text. Deleting an unknown node is a 400. A full subnet, a cross-account
    duplicate key and the allocation race all come back as 500 from enroll.
50. Re-running Cloudflare provisioning mints a new service token each time and never deletes the old
    ones.
51. Cloudflare token verification only tries the account-token endpoint; a user-owned token may fail
    there. Effect unclear.
52. Device deletion passes the `t.`-prefixed id, which the account-level API may not accept.
    Failures were only logged. Effect unclear.
53. Re-enrolling an existing key doesn't update the node's name, and there's no rename.

## Smaller things

54. `meshctl send` falls back to the first available path (Cloudflare, else Tailscale, never direct)
    when none is live, unlike tunnel traffic.
55. `meshctl ping` walks paths one at a time, so each dead path costs 5s per round.
56. `MESH_AUTOUPDATE=0` also blocks an explicit `meshctl update`.
57. `meshctl signup` can only take a subnet if the password is given as an argument too.
58. Status reports a backhaul as "up" whenever the object exists. A configured backhaul that failed
    is simply omitted, so the CLI prints "not configured" for it; "down" never appears.
59. uninstall.sh looks for the meshcp unit in `/etc/systemd/system` while the package installs it in
    `/lib/systemd/system` (small effect: `--purge` disables it by name anyway).
60. The sender name in the frame is redundant; the receiver uses the roster name.
61. Once every 6h, a daemon command in the CLI can hang up to 20s on the update-manifest fetch when
    the control plane is down.
62. Leftover `.old` binaries from a Windows update are only swept by the daemon's update task (so
    only with updates on) or by `meshctl update`.
63. The build script only emits `rerun-if-env-changed`, which disables cargo's default rerun and
    nothing watches `.git`, so incremental builds keep a stale commit and dirty flag in `--version`.
64. Uninstall deletes the whole `~/.config/mesh` and `~/Library/Application Support/mesh`
    directories and ignores `XDG_CONFIG_HOME` and `MESH_CONFIG`.

## Docs that don't match the code

- README: restarting a removed node without a key "fails with an explanation". The code idles and
  waits for `meshctl join`.
- README: the demo "blackholes the Cloudflare endpoint" and fails over to Tailscale. The demo script
  drops UDP 47778 and fails over from direct to Cloudflare.
- cloudflare-auth.md: the HTTP/2 fallback is "coded but never exercised". It isn't in the code.
- roadmap: poisoning "is detected and recovered from ... recorded in the node's state". Only a log
  line exists (item 17).
- roadmap: "we can stop consuming the netmap altogether". The code still uses it for DERP bootstrap.
- roadmap: schema "account-scoped so multi-tenancy never needs a migration". The network is the
  account row; several networks per account would need one.
- README and release notes: `apt purge` gives the address back. It doesn't (item 37).
- PLAN.md is the pre-build design (boringtun, smoltcp in-process mode, bearer tokens for MASQUE).
  Mostly superseded: MASQUE auth is mTLS, a real TUN was used, no WireGuard.

## Never built

- Frame authentication or encryption (item 1).
- IPv6 inside the tunnel (IPv6 packets from the TUN are dropped).
- The Cloudflare HTTP/2 fallback.
- Reporting DERP latencies to Tailscale (`set_home_region`).
- Tailscale OAuth clients; interactive Tailscale login.
- A web UI for the control plane.
- Android (VpnService), which the original plan mentioned.

## Never verified

- A real CGNAT (only simulated ones).
- A real DERP outage after the send-cap fix.
- Registering directly as MASQUE, skipping the WireGuard step.
- Whether the `TS_RS_EXPERIMENT` gate applies to the crates used.
- Tailscale hostname normalisation versus our bootstrap lookup.
- The removal/rejoin flow at `a324c0b`. It was tested at an earlier commit, before device
  deletion, idle mode and staged keys existed.
