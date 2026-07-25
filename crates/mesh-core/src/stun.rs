//! Just enough STUN (RFC 5389) to learn our own reflexive address.
//!
//! Real STUN rather than something bespoke, for two reasons. The client can point at any public
//! STUN server when ours is unreachable, and the server side is small enough that our control
//! plane can answer them, which matters because UDP 3478 is blocked on some networks (including
//! the one this was developed on) so Tailscale's DERP STUN is not always an option.
//!
//! The query must go out of the *same socket* the direct path uses. A NAT maps per source
//! port, so a reflexive address learned on a different socket describes a mapping that does not
//! exist for our traffic.

use std::net::{IpAddr, Ipv4Addr, SocketAddr};

pub const MAGIC_COOKIE: u32 = 0x2112_A442;
const BINDING_REQUEST: u16 = 0x0001;
const BINDING_RESPONSE: u16 = 0x0101;
const ATTR_XOR_MAPPED_ADDRESS: u16 = 0x0020;
const ATTR_MAPPED_ADDRESS: u16 = 0x0001;

pub type TxId = [u8; 12];

pub fn binding_request(txid: &TxId) -> Vec<u8> {
    let mut out = Vec::with_capacity(20);
    out.extend_from_slice(&BINDING_REQUEST.to_be_bytes());
    out.extend_from_slice(&0u16.to_be_bytes()); // no attributes
    out.extend_from_slice(&MAGIC_COOKIE.to_be_bytes());
    out.extend_from_slice(txid);
    out
}

/// Parse a request, returning its transaction id. `None` if it is not one.
pub fn parse_binding_request(buf: &[u8]) -> Option<TxId> {
    if buf.len() < 20 {
        return None;
    }
    if u16::from_be_bytes([buf[0], buf[1]]) != BINDING_REQUEST {
        return None;
    }
    if u32::from_be_bytes([buf[4], buf[5], buf[6], buf[7]]) != MAGIC_COOKIE {
        return None;
    }
    buf[8..20].try_into().ok()
}

/// Build a response telling the client where we saw it.
pub fn binding_response(txid: &TxId, seen: SocketAddr) -> Vec<u8> {
    let mut attr = Vec::new();
    attr.push(0); // reserved
    match seen.ip() {
        IpAddr::V4(v4) => {
            attr.push(0x01);
            let xport = seen.port() ^ (MAGIC_COOKIE >> 16) as u16;
            attr.extend_from_slice(&xport.to_be_bytes());
            let xaddr = u32::from(v4) ^ MAGIC_COOKIE;
            attr.extend_from_slice(&xaddr.to_be_bytes());
        }
        IpAddr::V6(v6) => {
            attr.push(0x02);
            let xport = seen.port() ^ (MAGIC_COOKIE >> 16) as u16;
            attr.extend_from_slice(&xport.to_be_bytes());
            let mut key = [0u8; 16];
            key[..4].copy_from_slice(&MAGIC_COOKIE.to_be_bytes());
            key[4..].copy_from_slice(txid);
            let octets = v6.octets();
            for i in 0..16 {
                attr.push(octets[i] ^ key[i]);
            }
        }
    }

    let mut out = Vec::with_capacity(20 + 4 + attr.len());
    out.extend_from_slice(&BINDING_RESPONSE.to_be_bytes());
    out.extend_from_slice(&((attr.len() as u16) + 4).to_be_bytes());
    out.extend_from_slice(&MAGIC_COOKIE.to_be_bytes());
    out.extend_from_slice(txid);
    out.extend_from_slice(&ATTR_XOR_MAPPED_ADDRESS.to_be_bytes());
    out.extend_from_slice(&(attr.len() as u16).to_be_bytes());
    out.extend_from_slice(&attr);
    out
}

/// Pull our reflexive address out of a response, checking it answers `txid`.
pub fn parse_binding_response(buf: &[u8], txid: &TxId) -> Option<SocketAddr> {
    if buf.len() < 20 {
        return None;
    }
    if u16::from_be_bytes([buf[0], buf[1]]) != BINDING_RESPONSE {
        return None;
    }
    if u32::from_be_bytes([buf[4], buf[5], buf[6], buf[7]]) != MAGIC_COOKIE {
        return None;
    }
    if &buf[8..20] != txid.as_slice() {
        return None; // someone else's answer
    }

    let mut i = 20;
    while i + 4 <= buf.len() {
        let atype = u16::from_be_bytes([buf[i], buf[i + 1]]);
        let alen = u16::from_be_bytes([buf[i + 2], buf[i + 3]]) as usize;
        let body = buf.get(i + 4..i + 4 + alen)?;

        // Some servers still only send the non-XOR form; accept both.
        if (atype == ATTR_XOR_MAPPED_ADDRESS || atype == ATTR_MAPPED_ADDRESS) && body.len() >= 8 {
            let xor = atype == ATTR_XOR_MAPPED_ADDRESS;
            let family = body[1];
            let mut port = u16::from_be_bytes([body[2], body[3]]);
            if xor {
                port ^= (MAGIC_COOKIE >> 16) as u16;
            }
            if family == 0x01 {
                let mut raw = u32::from_be_bytes([body[4], body[5], body[6], body[7]]);
                if xor {
                    raw ^= MAGIC_COOKIE;
                }
                return Some(SocketAddr::new(IpAddr::V4(Ipv4Addr::from(raw)), port));
            }
        }
        // Attributes are padded to a 4-byte boundary.
        i += 4 + alen.div_ceil(4) * 4;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_and_response_round_trip() {
        let txid: TxId = [9u8; 12];
        let req = binding_request(&txid);
        assert_eq!(parse_binding_request(&req), Some(txid));

        let seen: SocketAddr = "203.0.113.7:51234".parse().unwrap();
        let resp = binding_response(&txid, seen);
        assert_eq!(parse_binding_response(&resp, &txid), Some(seen));
    }

    #[test]
    fn response_for_another_transaction_is_rejected() {
        let mine: TxId = [1u8; 12];
        let theirs: TxId = [2u8; 12];
        let resp = binding_response(&theirs, "198.51.100.4:1234".parse().unwrap());
        assert!(parse_binding_response(&resp, &mine).is_none());
    }

    #[test]
    fn garbage_is_not_mistaken_for_stun() {
        assert!(parse_binding_request(b"MESH not stun at all").is_none());
        assert!(parse_binding_response(b"short", &[0u8; 12]).is_none());
    }

    #[test]
    fn xor_actually_obscures_the_address() {
        // The point of XOR-MAPPED-ADDRESS is that the address does not appear literally, which
        // is what stops naive NATs from rewriting it in flight.
        let txid: TxId = [3u8; 12];
        let resp = binding_response(&txid, "192.168.1.10:4444".parse().unwrap());
        assert!(
            !resp.windows(4).any(|w| w == [192, 168, 1, 10]),
            "raw address leaked into the response"
        );
    }
}
