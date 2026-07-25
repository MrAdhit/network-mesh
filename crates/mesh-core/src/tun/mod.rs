//! A real kernel interface carrying the mesh's own subnet.
//!
//! Packets are encapsulated whole rather than rewritten. That is what makes a mid-connection
//! path flip safe: the guest's 5-tuple never changes, so TCP does not notice, and we never
//! touch an inner checksum.
//!
//! The two supported platforms differ more than they look. Linux has a single `/dev/net/tun`
//! that is configured by ioctl and carries bare IP packets. macOS has no such device: a utun is
//! a socket opened against a kernel control, the kernel picks the interface number rather than
//! taking one, and every packet carries a four-byte address family header. `TunDevice` hides
//! all of that, so `node.rs` never learns which platform it is on.

use anyhow::{Context, Result, bail};

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub use linux::TunDevice;

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
pub use macos::TunDevice;

/// MTU for the mesh interface.
///
/// Bounded by the tightest path, which is Cloudflare: a QUIC datagram gives about 1200 usable
/// bytes, and we spend some on the Connect-IP framing, the IPv4/UDP wrapper we put inside the
/// tunnel, and our own frame header. Since the path can flip mid-connection, every path has to
/// be able to carry any packet, so the smallest one sets the number for all of them. Too high
/// and oversized packets vanish silently rather than erroring.
pub const MTU: u32 = 1100;

/// Run a configuration command, surfacing its stderr when it fails.
///
/// Interface setup goes through `ip` and `ifconfig` rather than a pile of further ioctls. Both
/// are present wherever the daemon runs, and a failure reads as the command that failed rather
/// than as an errno.
pub(crate) fn run(cmd: &str, args: &[&str]) -> Result<()> {
    let out = std::process::Command::new(cmd)
        .args(args)
        .output()
        .with_context(|| format!("running {cmd} {}", args.join(" ")))?;
    if !out.status.success() {
        bail!(
            "{cmd} {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(())
}

/// utun framing and unit numbering.
///
/// Only macOS calls any of this, but it lives outside the platform module so it is compiled and
/// tested everywhere. These are the two parts of the utun path most likely to be subtly wrong
/// and the only parts a test can reach without a kernel interface, so having them covered on
/// every CI leg is worth more than the dead-code allowance it costs elsewhere.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) mod utun {
    /// The four-byte header on every utun packet: an address family in network byte order.
    pub const AF_INET_HEADER: [u8; 4] = [0, 0, 0, 2];
    pub const HEADER_LEN: usize = 4;

    /// Prefix a packet with the address family header.
    pub fn frame(packet: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(HEADER_LEN + packet.len());
        out.extend_from_slice(&AF_INET_HEADER);
        out.extend_from_slice(packet);
        out
    }

    /// Strip that header. `None` when there is nothing behind it.
    pub fn strip(buf: &[u8]) -> Option<&[u8]> {
        if buf.len() <= HEADER_LEN {
            return None;
        }
        Some(&buf[HEADER_LEN..])
    }

    /// Turn a requested interface name into a utun unit number.
    ///
    /// `sc_unit` is 1-based, so utun0 is unit 1. Zero asks the kernel for whatever is free,
    /// which is what any name that is not `utunN` means, including the `mesh0` used on Linux.
    pub fn unit(requested: &str) -> u32 {
        requested
            .strip_prefix("utun")
            .and_then(|n| n.parse::<u32>().ok())
            .map(|n| n + 1)
            .unwrap_or(0)
    }
}

/// Destination address of an IPv4 packet, if it is one.
pub fn ipv4_destination(packet: &[u8]) -> Option<std::net::Ipv4Addr> {
    if packet.len() < 20 || packet[0] >> 4 != 4 {
        return None;
    }
    Some(std::net::Ipv4Addr::new(
        packet[16], packet[17], packet[18], packet[19],
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_destination_from_an_ipv4_header() {
        let pkt = crate::ip::build_udp4(
            std::net::Ipv4Addr::new(10, 201, 0, 2),
            std::net::Ipv4Addr::new(10, 201, 0, 3),
            1000,
            2000,
            b"x",
            1,
        );
        assert_eq!(
            ipv4_destination(&pkt),
            Some(std::net::Ipv4Addr::new(10, 201, 0, 3))
        );
    }

    #[test]
    fn ignores_short_and_non_ipv4_packets() {
        assert!(ipv4_destination(&[]).is_none());
        assert!(ipv4_destination(&[0x60; 40]).is_none(), "ipv6 is not ipv4");
        assert!(ipv4_destination(&[0x45; 4]).is_none(), "too short");
    }

    #[test]
    fn utun_framing_round_trips() {
        let pkt = crate::ip::build_udp4(
            std::net::Ipv4Addr::new(10, 201, 0, 2),
            std::net::Ipv4Addr::new(10, 201, 0, 3),
            1000,
            2000,
            b"payload",
            1,
        );
        let framed = utun::frame(&pkt);
        assert_eq!(
            &framed[..4],
            &utun::AF_INET_HEADER,
            "AF_INET, network order"
        );
        assert_eq!(framed.len(), pkt.len() + 4);
        assert_eq!(utun::strip(&framed), Some(pkt.as_slice()));
        // The whole point: what comes back out is a packet the rest of the stack understands.
        assert_eq!(
            ipv4_destination(utun::strip(&framed).unwrap()),
            Some(std::net::Ipv4Addr::new(10, 201, 0, 3))
        );
    }

    #[test]
    fn a_header_with_nothing_behind_it_is_not_a_packet() {
        assert!(utun::strip(&[]).is_none());
        assert!(utun::strip(&utun::AF_INET_HEADER).is_none());
        assert!(utun::strip(&[0, 0, 0, 2, 0x45]).is_some());
    }

    #[test]
    fn utun_unit_numbers_are_one_based() {
        // utun0 is unit 1; the off-by-one here would silently open the wrong interface.
        assert_eq!(utun::unit("utun0"), 1);
        assert_eq!(utun::unit("utun7"), 8);
        // Anything else means "kernel picks".
        assert_eq!(utun::unit("utun"), 0);
        assert_eq!(utun::unit("mesh0"), 0);
        assert_eq!(utun::unit("utunX"), 0);
        assert_eq!(utun::unit(""), 0);
    }
}
