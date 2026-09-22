# The kernel interface (TUN)

## What it does

- One interface per node carrying the mesh subnet. The node's address is its roster IP; the
  whole subnet is routed at the interface.
- Outbound: read a packet, take its IPv4 destination, find the peer whose mesh IP that is, send
  the packet unchanged inside a Tunnel frame on the best live path. Not IPv4: drop (IPv6 was
  never supported). No peer owns the address: drop.
- Inbound: a Tunnel frame's payload is written to the interface unchanged.
- Packets are never rewritten, so there are no inner checksums to fix and a path switch doesn't
  change the connection's 5-tuple. That's what makes a live TCP stream survive a path flip.
- Needs privilege on every platform. If the interface can't be created, log it and keep running;
  the mesh is still usable through the CLI.
- A read error on the interface: log, sleep 200 ms, keep reading. An earlier version stopped on the
  first error, leaving a daemon that answered the CLI and reported healthy paths while moving no
  traffic at all. On Windows the old code still had this bug in another form (see Windows below).
- `MESH_TUN=0` disables it. `MESH_TUN_NAME` picks the name: default `mesh0` on Linux and Windows,
  `utun` on macOS, where only a `utunN` form asks for a specific unit and anything else means "any
  free one".

## MTU: 1100 everywhere

The tightest path sets it for all of them, because a path can flip mid-connection and every path
has to carry any packet. Cloudflare is the tightest: a QUIC datagram leaves about 1200 usable
bytes, minus Connect-IP framing, minus our inner IPv4/UDP wrapper (28), minus our 48-byte frame
header plus the name. The original plan guessed 1280, which is too high. Too high means big
packets vanish silently. Verified on all three platforms: a 1000-byte ping with DF passes, 1200
gets "Packet needs to be fragmented but DF set".

The node name is part of that budget. Frames are capped at 1300 bytes: 1100 + 48-byte header +
name, so a full-size packet only fits if the name is at most 152 bytes, and every full-size packet
fails on every path otherwise. Cloudflare adds its 28-byte IPv4/UDP wrapper inside a QUIC datagram,
so long names probably break full-size packets there first (unverified). Dropping the name from the
frame, or bounding it, avoids the whole question.

## Undeliverable packets: answer with ICMP

If a packet can't be delivered (no live path, or every path's send failed), write an ICMP
"destination host unreachable" (type 3, code 1) back into the interface instead of dropping it.
A silent drop looks like a slow network; the app sits in a timeout. With the ICMP a TCP connect to
an unreachable peer fails in about a millisecond and ping prints "Destination Host Unreachable".

- Source address of the ICMP = the unreachable destination, not our own mesh address. Every stack
  drops an inbound packet whose source is one of its own addresses as a martian (on Linux that's
  separate from rp_filter, so it happens even with filtering off). Found the hard way: correctly
  formed errors reached the interface and were discarded before the socket saw them.
- Destination = the original packet's source.
- Body: 4 unused bytes, then the original IP header plus the first 8 bytes of its payload (RFC
  792). Without that quote the stack can't match the error to a socket and ignores it. (Old code
  kept the first 128 bytes of each packet around for this.)
- IPv4 header checksum and ICMP checksum (ICMP has no pseudo-header).
- Stay silent for: malformed or non-IPv4 packets, source unspecified/multicast/broadcast,
  destination multicast/broadcast, and ICMP error types 3, 4, 5, 11, 12 (answering an error with an
  error between two nodes is a packet storm).

## Linux

- `open("/dev/net/tun", O_RDWR | O_CLOEXEC | O_NONBLOCK)`, then `ioctl(TUNSETIFF = 0x400454ca)`
  with an `ifreq` holding the name and flags `IFF_TUN (0x0001) | IFF_NO_PI (0x1000)`. Bare IP
  packets, no header. Name must be shorter than `IFNAMSIZ`.
- Configure with iproute2, which reads better in logs than more ioctls:
  ```
  ip link set dev mesh0 mtu 1100
  ip addr add <ip>/32 dev mesh0
  ip link set dev mesh0 up
  ip route replace <subnet> dev mesh0
  ```
- Drive the fd with tokio `AsyncFd`, read buffer MTU + 64.
- Needs `CAP_NET_ADMIN` and `/dev/net/tun` (containers: `--cap-add NET_ADMIN --device /dev/net/tun`).

## macOS

There's no `/dev/net/tun`. A utun is a socket connected to a kernel control.

- `socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)`.
- `ioctl(CTLIOCGINFO)` with `ctl_name = "com.apple.net.utun_control"` to get the control id.
- `connect()` with `sockaddr_ctl { sc_family: AF_SYSTEM, ss_sysaddr: AF_SYS_CONTROL, sc_id, sc_unit }`.
  `sc_unit` is 1-based: `utunN` is unit N+1; 0 means "any free one", which is what any other name
  means (including `mesh0`). EPERM means it needs root.
- The kernel picks the interface number, so read the name back with
  `getsockopt(SYSPROTO_CONTROL, UTUN_OPT_IFNAME)`.
- Set O_NONBLOCK, then drive with `AsyncFd`.
- Every packet has a 4-byte address family header in network order: `[0, 0, 0, 2]` for IPv4.
  Add it on write, strip it on read (a read with nothing after the header is skipped).
- Configure (address and MTU in separate calls; combining them isn't portable across releases):
  ```
  ifconfig utunN inet <ip> <ip> up        # point-to-point, pointed at itself
  ifconfig utunN mtu 1100
  route -n delete -net <subnet> -interface utunN   # ignore failure; add fails if it exists
  route -n add -net <subnet> -interface utunN
  ```
- **Self-reach needs a loopback alias.** macOS creates the LOCAL route (delivery to the local stack)
  only when an address is assigned to an interface, and on a point-to-point utun the destination
  route takes that slot. So the node could bind its mesh IP and peers could reach it, but
  `ping <own mesh ip>` went into the tunnel and got dropped (no peer owns it). No `route add` can
  fix that; both obvious attempts fail. Fix: `ifconfig lo0 alias <ip> 255.255.255.255`. Linux and
  Windows give this for free.
  - Before adding, remove stale mesh aliases left on lo0 by a killed daemon: parse
    `ifconfig lo0`, find `inet` addresses inside the mesh subnet, `ifconfig lo0 -alias <addr>` each.
    Never touch 127.x, whatever subnet the user picked; never touch addresses outside the subnet.
  - Remove the alias again on clean shutdown.
  - Failing to alias is a warning, not fatal.

## Windows

No native TUN. Use WireGuard's Wintun driver through `wintun.dll`.

- `wintun.dll` must sit next to the exe (it ships with WireGuard for Windows, or wintun.net). It
  embeds a kernel driver for its own architecture, so ARM64 Windows needs an ARM64 build of
  everything; an emulated x64 process can't install the ARM64 driver. The driver is signed by
  WireGuard, so nothing of ours needs signing. Creating the adapter needs Administrator.
- Open an existing adapter by name, else create it (`create(name, "mesh", None)`), so restarts
  don't pile up adapters. Start a session with ring capacity `0x400000` (power of two between
  128 KiB and 64 MiB; Wintun's documented default).
- No file descriptor to poll: receiving is a blocking call, so a dedicated thread calls
  `receive_blocking` and pushes into a bounded channel (256). Sending allocates a packet in the
  ring and submits it; it doesn't block. Shut the session down on drop so the thread exits.
- In the old code that thread exited on its first receive error, after which every read failed
  immediately and nothing inbound arrived until a restart. The reader needs to survive errors the
  same way the unix loops do.
- Bare IP packets, like Linux.
- Configure with netsh:
  ```
  netsh interface ipv4 set address name=<name> source=static address=<ip> mask=<subnet mask>
  netsh interface ipv4 set subinterface <name> mtu=1100 store=active
  netsh interface ipv4 add route prefix=<subnet> interface=<name>     # allowed to fail
  ```
  Use the subnet's real mask, not /32. With the real mask Windows adds the on-link route for the
  subnet itself; with /32 there's no route at all unless the separate route command lands.
- **Windows Firewall blocks inbound traffic on the mesh interface by default** (it's an
  unidentified network). Packets leave, nothing comes back, no error anywhere. It cost most of a
  debugging session. The daemon doesn't touch the firewall; document the rule instead, e.g. for
  ping: `netsh advfirewall firewall add rule name="mesh-icmp" protocol=icmpv4:8,any dir=in action=allow`.
  macOS passed the same test only because its firewall is off by default.
- Link the MSVC C runtime statically (`-C target-feature=+crt-static`). Otherwise a clean machine
  without the VC++ redistributable fails with `STATUS_DLL_NOT_FOUND` (0xC0000135) and no output at
  all. With that, the binaries only need `wintun.dll` beside them.

## Testing the TUN alone

The old repo had a `tuncheck` example (shipped with the release binaries): bring up just the
interface with a test address (default `10.201.99.1` in `10.201.99.0/24`), print every packet, and
echo each one back with source and destination swapped (the IPv4 checksum is unchanged by a swap).
It needs root and is the only way to exercise this layer without a control plane.
