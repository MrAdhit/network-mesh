# Overview

## The three programs

**Control plane** (old name `meshcp`). An HTTP server with a SQLite database. Linux only, by the
user's choice (it's a server). It owns:

- accounts (email + password), sessions, enrollment keys
- the network's subnet, the node list, IP allocation, the roster nodes poll
- the user's vendor credentials, encrypted at rest
- provisioning the Cloudflare Zero Trust org, minting Tailscale auth keys on demand
- two STUN responders (UDP 3478 and 3479) so nodes can learn their public address
- serving `install.sh` / `uninstall.sh` and the node binaries for self-update

**Node daemon** (old name `meshd`). Runs on every machine in the mesh. It holds the node's
identity, enrolls, brings up the backhauls, runs the probing and path selection, owns the TUN
interface, answers the CLI over a local socket, and replaces its own binaries when the control
plane has a different build. Targets: Linux x86_64 and aarch64, macOS Apple Silicon, Windows
x86_64 and ARM64. No Intel Mac.

**CLI** (old name `meshctl`). Two halves: local node commands go to the daemon's socket; network
and account commands go straight to the control plane's HTTP API. Also self-update.

## Credential model

Copied from how both vendors do it: a human hands over one powerful credential once, and machines
only ever get narrow, short-lived ones derived from it.

| human gives the control plane | nodes get |
|---|---|
| Cloudflare API token (Account > Zero Trust > Edit) + account id | an Access service token (client id + secret) to mint 60s enrollment JWTs |
| Tailscale personal API token | a fresh auth key (1h, reusable, ephemeral, preauthorized, untagged) each time they register |

Nodes never see either API token. The control plane validates each credential the moment it's
pasted (Cloudflare: token verify + full org provisioning; Tailscale: list devices), so a typo fails
right away rather than at some node's enrollment later.

## Membership

The mesh only ever talks to its own nodes. A node is a member because the control plane's roster
lists its Ed25519 public key, not because it's reachable. This matters because the tailnet and the
Cloudflare org are shared with other devices (the test tailnet had about 20 personal devices).
Frames from keys not in the roster are dropped. No interop with real `tailscaled` or WARP peers,
ever; it was never a goal.

## User-facing flows

1. **Set up a network**: `signup <email>` (optional subnet), `set-cloudflare <api-token>
   <account-id>` (provisions the org right then, takes a few seconds), `set-tailscale <api-token>`,
   `enrollment-key`.
2. **Add a node**: `curl -fsSL https://<cp>/install.sh | sudo sh -s -- --key mkey_...`, or install
   and later `meshctl join <key>`. The daemon enrolls, gets its IP, pulls the roster, brings up
   whatever backhauls the network has credentials for, and brings up the TUN.
3. **Use it**: ping or TCP to a peer's mesh IP. `meshctl peers` shows every path's state, RTT and
   loss. `meshctl ping <peer>` probes each path separately and reports a winner.
4. **Remove a node**: from anywhere with the account, `meshctl remove-node <node-id>`; the running
   node notices within about 90s (three rejected roster polls) and shuts down. From the machine
   itself, `meshctl leave` or the uninstall script deregisters it.
5. **Updates**: the control plane carries the node binaries. Nodes check at startup and every 6h,
   swap the file on disk when the hash differs, and run the new code at the next start.

Joining is meant to be a deliberate act gated on an enrollment key. A removed node must never
rejoin by itself, or `remove-node` means nothing. That rule shapes a lot of the daemon's
behaviour, and the old code still broke it in a few ways (known-problems.md, "Eviction doesn't
stick").

## Measured numbers

Two Linux containers on one host in Singapore, control plane in a third:

```
peer mesh-b (10.201.0.3)  cf=10.96.0.7  best=direct
  path              state    last ms    ewma ms    sent    recv  loss %
  cloudflare           up      33.91      32.77      74      73      1%
  tailscale-derp       up      83.03      89.45      75      74      1%
  direct               up       0.37       0.27      58      57      2%
```

- TCP over the mesh interface: about 350 Mbit/s (671 Mbit/s in the NAT test).
- Behind a simulated NAT the direct path still formed: 0.2 ms port-preserving, 0.57 ms symmetric
  (0.4 ms in the first NAT run, whose default masquerade turned out to map per destination).
- A Windows ARM64 VM: direct about 1 ms, Cloudflare 33 ms, DERP 99 ms.
- A live TCP stream survived dropping UDP 47778: the winner moved from direct to cloudflare,
  latency went 0.2 ms to 35 ms, no gap, no reconnect.
- Cloudflare beat DERP there only because it hairpins through the Singapore datacenter while DERP
  adds a relay hop. It's not a general result; that's why the client measures instead of assuming.
