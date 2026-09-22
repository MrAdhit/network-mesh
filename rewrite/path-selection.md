# Path selection

## Per-path stats (per peer)

| field | meaning |
|---|---|
| `last_rtt_ms` | RTT of the latest reply |
| `ewma_ms` | smoothed RTT, alpha 0.3, first sample seeds it |
| `loss_ewma` | smoothed loss: each answered probe feeds 0.0, each expired probe feeds 1.0, alpha 0.3, first observation seeds it |
| `sent`, `received` | lifetime counters, display only |
| `last_reply` | time of the latest reply |

`loss %` shown to users is `100 * loss_ewma` (recent), not received/sent (lifetime). The recent
figure is what decides routing, so that's the one to show.

## Rules

- **Up** means a reply arrived in the last 15s (`PATH_TIMEOUT`).
- **Lost probe**: in flight for 5s with no reply. Expiry runs at the end of every probe round and
  charges one loss to that path. This is the only place loss is ever observed; without it a path
  that drops traffic looks identical to one that doesn't. 5s matches the timeout `ping` uses, so a
  timeout in `meshctl ping` roughly equals a loss in the stats. Not exactly: a reply that arrives
  after 5s but before the next sweep still counts as a reply.
- **Only probes that were actually sent are tracked.** In the old code a probe entered the
  in-flight table (and `sent` went up) only if its send succeeded. A send that errored or hit the
  2s cap was logged and forgotten, counted neither as sent nor as lost. So a path whose sends fail
  kept a frozen loss figure and only went down through the 15s timeout. The unpinned direct spray
  did the opposite: it reported success even if every packet failed, so those probes were charged
  as losses. Decide deliberately how a failed send should count.
- **Punch-burst probes don't count as loss.** They're sprayed blind at every candidate and mostly
  go unanswered by design. Counting them would make a brand-new direct path look hopeless during
  exactly the seconds it starts working. They're still removed on expiry.
- **Score** = `ewma_ms / max(1 - loss_ewma, 0.05)`, lower is better. That's the expected cost of
  getting one packet through (at 50% loss it takes two tries on average). The floor keeps a path
  that answers nothing sortable instead of infinite.
  - 2 ms at 40% loss scores 3.3 ms and still beats a clean 16 ms relay.
  - 2 ms at 90% loss scores 20 ms and loses to it.
  - Before loss was in the score, a LAN link dropping half its packets kept reporting 2 ms and
    stayed the winner forever, since RTT only updates on replies and it never hit the 15s timeout.
- **Only live paths carry traffic.** Rank the up paths by score. If none are up, the peer is
  unreachable: reject the packet (ICMP host unreachable into the TUN, see tun.md). Never fall back
  to a path with no recent reply. An earlier version fell back to the "first configured path",
  which was Cloudflare. Cloudflare dies along with the internet, so the working LAN direct path sat
  unused and never got tried again.
- **Probing ignores liveness.** Every path gets probed every round whatever its state, so a dead
  path comes back by itself. That's why restricting traffic to live paths is safe.
- **Failover inside one send.** For a tunnel packet, try live paths best-first; if a send errors
  (the path can die between the last probe and now), try the next. All fail: unreachable.
- **Send cap.** Each path send is bounded at 2s (`SEND_TIMEOUT`). A backhaul should fail a send
  rather than block, and the cap is the guard for when one doesn't.
- `best_path` shown by `meshctl peers` uses the same score and the same "must be up" rule.

## The direct-path pin

- If the direct path is up and the peer has a confirmed address, direct packets go only there.
- Otherwise (never confirmed, or confirmed but the path went down) they go to every candidate.
- Why unpin on down: a peer advertises several candidates and we pin to whichever answered first.
  That can be its address on some other overlay (a Tailscale IP, say). When the internet goes away
  that address dies but the LAN candidate would still work. Probes to the pinned address alone
  would never discover that. Unpinning lets the next probe round find the surviving candidate.
  Tested: blackholing the pinned address on both nodes made them re-pin to the other candidate,
  riding Cloudflare meanwhile, with two packets lost in total.

## `meshctl ping`

- For each round, for each path: send one probe, wait up to 5s for its reply. Sequential, so a
  dead path adds 5s per round. 200 ms pause between rounds.
- Count defaults to 4 in the CLI and is clamped to 1..100 by the daemon.
- Ping probes count toward the path stats like normal probes. A ping probe whose send fails is
  printed as a timeout straight away and never charged as a loss.
- The CLI prints each sample, then per-path min/avg/max and replied/sent, then "winner: <path> at
  <avg> ms average" (lowest average among paths with replies).

## `meshctl send`

Sends a Data frame on the best live path. The old code fell back to the first available backhaul
(Cloudflare, else Tailscale, never direct) when none were live, which contradicts the tunnel rule.
It's only a debug feature.

## Constants

| name | value |
|---|---|
| probe interval | 1s (`MESH_PROBE_INTERVAL_SECS`; the dev compose used 2) |
| EWMA alpha (RTT and loss) | 0.3 |
| path timeout (up/down) | 15s |
| probe counted lost after | 5s |
| per-path send cap | 2s |
| loss floor in score | delivered share floored at 0.05 |
| Hello every | 10 probe rounds, plus at start |
| ping timeout per sample | 5s |
