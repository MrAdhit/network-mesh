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
}
