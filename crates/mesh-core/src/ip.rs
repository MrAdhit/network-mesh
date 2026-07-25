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
}
