//! Minimal IPv4/UDP construction and parsing.
//!
//! Connect-IP is a raw IP tunnel: Cloudflare hands us datagrams that are whole IP packets and
//! expects the same back. So we build real headers, with real checksums. Both the IPv4 header
//! checksum and the UDP checksum cover fields we set per packet, so neither can be faked.

pub const PROTO_UDP: u8 = 17;
pub const PROTO_ICMP: u8 = 1;

pub const IPV4_HEADER_LEN: usize = 20;
pub const UDP_HEADER_LEN: usize = 8;

/// Ones' complement sum used by both IPv4 and UDP.
fn checksum(chunks: &[&[u8]]) -> u16 {
    let mut sum: u32 = 0;
    let mut leftover: Option<u8> = None;

    for chunk in chunks {
        let mut bytes = *chunk;
        if let Some(hi) = leftover.take() {
            let lo = bytes.first().copied().unwrap_or(0);
            sum += u16::from_be_bytes([hi, lo]) as u32;
            bytes = bytes.get(1..).unwrap_or(&[]);
        }
        let mut it = bytes.chunks_exact(2);
        for pair in it.by_ref() {
            sum += u16::from_be_bytes([pair[0], pair[1]]) as u32;
        }
        if let [odd] = it.remainder() {
            leftover = Some(*odd);
        }
    }
    if let Some(hi) = leftover {
        sum += u16::from_be_bytes([hi, 0]) as u32;
    }
    while sum >> 16 != 0 {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    !(sum as u16)
}

/// Build an IPv4/UDP packet carrying `payload`.
pub fn build_udp4(
    src: std::net::Ipv4Addr,
    dst: std::net::Ipv4Addr,
    src_port: u16,
    dst_port: u16,
    payload: &[u8],
    ident: u16,
) -> Vec<u8> {
    let udp_len = (UDP_HEADER_LEN + payload.len()) as u16;
    let total_len = IPV4_HEADER_LEN as u16 + udp_len;

    let mut pkt = Vec::with_capacity(total_len as usize);
    pkt.push(0x45); // IPv4, 5 words of header
    pkt.push(0x00); // DSCP/ECN
    pkt.extend_from_slice(&total_len.to_be_bytes());
    pkt.extend_from_slice(&ident.to_be_bytes());
    pkt.extend_from_slice(&0x4000u16.to_be_bytes()); // Don't Fragment
    pkt.push(64); // TTL
    pkt.push(PROTO_UDP);
    pkt.extend_from_slice(&[0, 0]); // checksum placeholder
    pkt.extend_from_slice(&src.octets());
    pkt.extend_from_slice(&dst.octets());

    let hdr_ck = checksum(&[&pkt[..IPV4_HEADER_LEN]]);
    pkt[10..12].copy_from_slice(&hdr_ck.to_be_bytes());

    let udp_start = pkt.len();
    pkt.extend_from_slice(&src_port.to_be_bytes());
    pkt.extend_from_slice(&dst_port.to_be_bytes());
    pkt.extend_from_slice(&udp_len.to_be_bytes());
    pkt.extend_from_slice(&[0, 0]); // checksum placeholder
    pkt.extend_from_slice(payload);

    // UDP checksum covers a pseudo-header built from the IP addresses.
    let pseudo = {
        let mut p = Vec::with_capacity(12);
        p.extend_from_slice(&src.octets());
        p.extend_from_slice(&dst.octets());
        p.push(0);
        p.push(PROTO_UDP);
        p.extend_from_slice(&udp_len.to_be_bytes());
        p
    };
    let udp_ck = checksum(&[&pseudo, &pkt[udp_start..]]);
    // 0 means "no checksum" in UDP over IPv4, so it is transmitted as all ones instead.
    let udp_ck = if udp_ck == 0 { 0xffff } else { udp_ck };
    pkt[udp_start + 6..udp_start + 8].copy_from_slice(&udp_ck.to_be_bytes());

    pkt
}

pub const ICMP_DEST_UNREACHABLE: u8 = 3;
pub const ICMP_HOST_UNREACHABLE: u8 = 1;

/// Build an ICMP "destination host unreachable" for a packet we could not deliver.
///
/// Without this a peer with no live path is a black hole: the sending application waits for a
/// timeout that never carries any information. A real router answers, so we answer too, and the
/// local stack fails the connection immediately with something the user can read.
///
/// RFC 792 puts the offending packet's IP header plus the first eight bytes of its payload in
/// the body. That quote is what lets the receiving stack match the error back to the socket that
/// sent it, so a bare header would be delivered and then ignored.
///
/// The error is sourced from the address that could not be reached, not from ours. Sourcing it
/// from our own mesh address is the intuitive choice and it does not work: the packet arrives at
/// the kernel from a device, and every stack drops an inbound packet whose source is one of the
/// host's own addresses as a martian. On Linux that check is separate from `rp_filter`, so it
/// bites even with filtering off. Verified the hard way, watching correctly formed errors reach
/// the interface and get discarded before the pinging socket ever saw them.
///
/// Returns `None` when answering would be wrong rather than merely unhelpful: a malformed
/// packet, one sent to a multicast or broadcast address, or an ICMP error, since answering an
/// error with an error is how you build a packet storm.
pub fn build_icmp4_unreachable(original: &[u8], ident: u16) -> Option<Vec<u8>> {
    if original.len() < IPV4_HEADER_LEN || original[0] >> 4 != 4 {
        return None;
    }
    let ihl = ((original[0] & 0x0f) as usize) * 4;
    if ihl < IPV4_HEADER_LEN || original.len() < ihl {
        return None;
    }

    // The sender of the undeliverable packet is who hears about it.
    let reply_to = std::net::Ipv4Addr::new(original[12], original[13], original[14], original[15]);
    if reply_to.is_unspecified() || reply_to.is_multicast() || reply_to.is_broadcast() {
        return None;
    }
    // The unreachable destination stands in as the sender of the error.
    let src = std::net::Ipv4Addr::new(original[16], original[17], original[18], original[19]);
    if src.is_multicast() || src.is_broadcast() {
        return None;
    }
    if original[9] == PROTO_ICMP
        && let Some(t) = original.get(ihl)
        && matches!(*t, 3 | 4 | 5 | 11 | 12)
    {
        return None;
    }

    let quote = &original[..(ihl + 8).min(original.len())];
    let icmp_len = 8 + quote.len();
    let total_len = (IPV4_HEADER_LEN + icmp_len) as u16;

    let mut pkt = Vec::with_capacity(total_len as usize);
    pkt.push(0x45);
    pkt.push(0x00);
    pkt.extend_from_slice(&total_len.to_be_bytes());
    pkt.extend_from_slice(&ident.to_be_bytes());
    pkt.extend_from_slice(&0x0000u16.to_be_bytes());
    pkt.push(64); // TTL
    pkt.push(PROTO_ICMP);
    pkt.extend_from_slice(&[0, 0]); // checksum placeholder
    pkt.extend_from_slice(&src.octets());
    pkt.extend_from_slice(&reply_to.octets());
    let hdr_ck = checksum(&[&pkt[..IPV4_HEADER_LEN]]);
    pkt[10..12].copy_from_slice(&hdr_ck.to_be_bytes());

    let icmp_start = pkt.len();
    pkt.push(ICMP_DEST_UNREACHABLE);
    pkt.push(ICMP_HOST_UNREACHABLE);
    pkt.extend_from_slice(&[0, 0]); // checksum placeholder
    pkt.extend_from_slice(&[0, 0, 0, 0]); // unused
    pkt.extend_from_slice(quote);
    // ICMP has no pseudo-header: the checksum covers the ICMP message alone.
    let icmp_ck = checksum(&[&pkt[icmp_start..]]);
    pkt[icmp_start + 2..icmp_start + 4].copy_from_slice(&icmp_ck.to_be_bytes());

    Some(pkt)
}

#[derive(Debug, Clone)]
pub struct Udp4Packet {
    pub src: std::net::Ipv4Addr,
    pub dst: std::net::Ipv4Addr,
    pub src_port: u16,
    pub dst_port: u16,
    pub payload: Vec<u8>,
}

/// Parse an IPv4/UDP packet. Returns None for anything that is not one, including IPv6 and
/// ICMP, which the tunnel also delivers.
pub fn parse_udp4(pkt: &[u8]) -> Option<Udp4Packet> {
    if pkt.len() < IPV4_HEADER_LEN || pkt[0] >> 4 != 4 {
        return None;
    }
    let ihl = ((pkt[0] & 0x0f) as usize) * 4;
    if ihl < IPV4_HEADER_LEN || pkt.len() < ihl {
        return None;
    }
    if pkt[9] != PROTO_UDP {
        return None;
    }
    let total_len = u16::from_be_bytes([pkt[2], pkt[3]]) as usize;
    let end = total_len.min(pkt.len());
    let src = std::net::Ipv4Addr::new(pkt[12], pkt[13], pkt[14], pkt[15]);
    let dst = std::net::Ipv4Addr::new(pkt[16], pkt[17], pkt[18], pkt[19]);

    let udp = pkt.get(ihl..end)?;
    if udp.len() < UDP_HEADER_LEN {
        return None;
    }
    let src_port = u16::from_be_bytes([udp[0], udp[1]]);
    let dst_port = u16::from_be_bytes([udp[2], udp[3]]);
    let udp_len = u16::from_be_bytes([udp[4], udp[5]]) as usize;
    let payload_end = udp_len.clamp(UDP_HEADER_LEN, udp.len());

    Some(Udp4Packet {
        src,
        dst,
        src_port,
        dst_port,
        payload: udp[UDP_HEADER_LEN..payload_end].to_vec(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;

    #[test]
    fn udp4_roundtrip() {
        let src = Ipv4Addr::new(10, 96, 0, 1);
        let dst = Ipv4Addr::new(10, 96, 0, 2);
        let pkt = build_udp4(src, dst, 4242, 4243, b"hello mesh", 7);
        let parsed = parse_udp4(&pkt).expect("should parse");
        assert_eq!(parsed.src, src);
        assert_eq!(parsed.dst, dst);
        assert_eq!(parsed.src_port, 4242);
        assert_eq!(parsed.dst_port, 4243);
        assert_eq!(parsed.payload, b"hello mesh");
    }

    #[test]
    fn ipv4_header_checksum_verifies() {
        let pkt = build_udp4(
            Ipv4Addr::new(1, 2, 3, 4),
            Ipv4Addr::new(5, 6, 7, 8),
            1,
            2,
            b"x",
            1,
        );
        // Summing a correct header including its checksum yields zero.
        assert_eq!(checksum(&[&pkt[..IPV4_HEADER_LEN]]), 0);
    }

    #[test]
    fn odd_length_payload_checksums() {
        let pkt = build_udp4(
            Ipv4Addr::new(10, 0, 0, 1),
            Ipv4Addr::new(10, 0, 0, 2),
            1,
            2,
            b"odd",
            1,
        );
        assert_eq!(parse_udp4(&pkt).unwrap().payload, b"odd");
    }

    /// A packet from the mesh peer we are pretending we cannot reach.
    fn undeliverable() -> Vec<u8> {
        build_udp4(
            std::net::Ipv4Addr::new(192, 168, 42, 2),
            std::net::Ipv4Addr::new(192, 168, 42, 3),
            4000,
            5000,
            b"hello",
            7,
        )
    }

    #[test]
    fn rejects_an_undeliverable_packet_back_to_its_sender() {
        let orig = undeliverable();
        let icmp = build_icmp4_unreachable(&orig, 1).unwrap();

        assert_eq!(icmp[9], PROTO_ICMP);
        // Sourced from the unreachable destination, never from us: our own address would be
        // dropped as a martian before the sending socket could see the error.
        assert_eq!(&icmp[12..16], &[192, 168, 42, 3]);
        // Straight back to whoever sent the packet we could not deliver.
        assert_eq!(&icmp[16..20], &[192, 168, 42, 2]);
        assert_eq!(icmp[IPV4_HEADER_LEN], ICMP_DEST_UNREACHABLE);
        assert_eq!(icmp[IPV4_HEADER_LEN + 1], ICMP_HOST_UNREACHABLE);

        // A correct checksum sums to zero over the data it covers; that is the whole trick, and
        // it is what the receiving stack will check before it believes any of this.
        assert_eq!(checksum(&[&icmp[..IPV4_HEADER_LEN]]), 0, "ipv4 header");
        assert_eq!(checksum(&[&icmp[IPV4_HEADER_LEN..]]), 0, "icmp message");

        // RFC 792: the original header plus eight bytes of its payload. Without that quote the
        // sender cannot tell which socket the error belongs to and ignores it.
        let quote = &icmp[IPV4_HEADER_LEN + 8..];
        assert_eq!(quote.len(), IPV4_HEADER_LEN + 8);
        assert_eq!(&quote[..IPV4_HEADER_LEN + 8], &orig[..IPV4_HEADER_LEN + 8]);
    }

    #[test]
    fn never_answers_an_error_with_an_error() {
        // Two nodes each rejecting the other's rejections is a packet storm.
        let orig = undeliverable();
        let icmp = build_icmp4_unreachable(&orig, 1).unwrap();
        assert!(build_icmp4_unreachable(&icmp, 2).is_none());
    }

    #[test]
    fn stays_quiet_when_answering_would_be_wrong() {
        assert!(build_icmp4_unreachable(&[], 1).is_none(), "empty");
        assert!(
            build_icmp4_unreachable(&[0x60; 40], 1).is_none(),
            "ipv6 is not ours to answer"
        );

        // Nobody is the sender of a multicast, so there is no one to tell.
        let mut mcast = undeliverable();
        mcast[16..20].copy_from_slice(&[224, 0, 0, 251]);
        assert!(build_icmp4_unreachable(&mcast, 1).is_none());

        let mut from_nowhere = undeliverable();
        from_nowhere[12..16].copy_from_slice(&[0, 0, 0, 0]);
        assert!(build_icmp4_unreachable(&from_nowhere, 1).is_none());
    }
}
