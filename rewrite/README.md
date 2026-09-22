# Rewrite notes

Notes I (Claude) wrote after reading the whole old network-mesh codebase, for a future me with no
context who is rebuilding it from scratch with the user supervising. The user won't read these.

## Ground rules

The standing rules for working in this repository are in `AGENTS.md` at the repo root: working
with the user, writing style, documentation, and agent notes. Read it before anything else.

For the rewrite:

- The new code has the same functionality as the old implementation at `a324c0b`, built from
  scratch. The user directs the design and structure.
- Don't carry over the old structure.
- Don't carry over the old documentation, code comments included. Ported code gets new comments
  that follow the writing style and documentation rules in `AGENTS.md`.
- The old `README.md`, `PLAN.md` and `docs/` break those rules. Use them for facts only, never as a
  model. Commit messages are the exception: their format is the model (the "Commits" section of
  `AGENTS.md`).

About these notes:

- They're agent notes (the "Agent notes and memory" section of `AGENTS.md`), not project
  documentation. Besides what the old implementation did, they record why parts of it were built
  that way, its history, and what was learned building it. That's memory-type content. It belongs
  here and must not be copied into the rewrite's documentation (code comments included).
- They describe the old system. They're not a design or a plan.
- The user won't read or check them, so keep them accurate: verify against the old code before
  editing anything here, and mark anything inferred or unverified.
- When the old docs and the old code disagree, the code is what actually ran. Several doc claims
  were never built. They're listed in known-problems.md.
- The old code is at commit `a324c0b` (2026-07-28). If a detail needs checking:
  `git show a324c0b:<path>`, `git ls-tree -r --name-only a324c0b`. The old docs
  (`docs/cloudflare-auth.md`, `docs/tailscale-auth.md`, `docs/roadmap.md`) have the vendor research
  in long form. Read them for facts only. Their writing, and their mix of current state with
  rationale and history, is what AGENTS.md rules out.

## What it is

A mesh network client that owns its own addressing. Every node gets an IP in the network's own
private subnet (default `10.201.0.0/16`) on a real kernel TUN interface, so normal apps just use
it. Between any two nodes there are up to three paths:

- **direct**: our own UDP, hole-punched through NAT when needed
- **cloudflare**: Cloudflare Mesh, via MASQUE (Connect-IP over HTTP/3 over QUIC), always relayed
  through the nearest Cloudflare datacenter
- **tailscale-derp**: Tailscale's DERP relays

We don't run either vendor's client. We speak their control and data protocols ourselves and use
them only as dumb relays. Every path is probed every second with identical frames, and each packet
goes on whichever path currently scores best for that peer. Whole IP packets are encapsulated and
never rewritten, so switching paths mid-connection doesn't break TCP.

The reason: Cloudflare and Tailscale fail in unrelated ways, and a direct path beats both by two
orders of magnitude when it exists. Measuring continuously beats guessing.

## Files

- `overview.md` - the three programs, the credential model, the user-facing flows, measured numbers
- `mesh-protocol.md` - frame format, message types, membership, per-path wrapping, timers
- `path-selection.md` - stats, scoring, liveness, failover
- `direct-path-and-nat.md` - candidates, hole punching, STUN, NAT classification and prediction
- `cloudflare.md` - org provisioning, device enrollment, the MASQUE tunnel and its traps
- `tailscale.md` - auth keys, registration, DERP, region agreement, hostname mess
- `tun.md` - the kernel interface on Linux, macOS and Windows, MTU, ICMP unreachable
- `control-plane.md` - HTTP API, data model, rules, credential sealing, STUN responders
- `node-daemon-and-cli.md` - daemon lifecycle, local state, IPC, CLI commands and session storage
- `install-update-release.md` - install/uninstall scripts, packages, self-update, build targets
- `testing-and-environment.md` - how it was tested, the dev environment, sanity numbers
- `known-problems.md` - bugs and design flaws in the old code, docs that don't match it, unverified bits
- `config-reference.md` - env vars, defaults, ports, files, constants

The hardest-won knowledge is in `cloudflare.md` and `tailscale.md` (undocumented vendor behaviour
that took real debugging to find) and in `known-problems.md`. Everything in these notes was checked
against the code by two independent review passes; `known-problems.md` says which items are
inferred rather than observed.
