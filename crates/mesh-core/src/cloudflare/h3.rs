//! The bare minimum HTTP/3 needed to open a Connect-IP tunnel.
//!
//! We hand-roll this rather than use the `h3` crate because Cloudflare's WARP endpoint
//! deviates from RFC 9484 in ways a compliant library refuses to tolerate: the protocol
//! token is `cf-connect-ip` rather than `connect-ip`, and the server never advertises
//! ENABLE_CONNECT_PROTOCOL, so libraries bail before sending anything.
//!
//! Scope: encode one HEADERS frame, read one back, and frame datagrams. Nothing else.

use anyhow::{Result, bail};
use bytes::{BufMut, BytesMut};

pub const STREAM_TYPE_CONTROL: u64 = 0x00;
pub const STREAM_TYPE_QPACK_ENCODER: u64 = 0x02;
pub const STREAM_TYPE_QPACK_DECODER: u64 = 0x03;

pub const FRAME_HEADERS: u64 = 0x01;
pub const FRAME_SETTINGS: u64 = 0x04;

pub const SETTING_ENABLE_CONNECT_PROTOCOL: u64 = 0x08;
pub const SETTING_H3_DATAGRAM: u64 = 0x33;

// ---- QUIC varints (RFC 9000 §16) ----

pub fn put_varint(buf: &mut BytesMut, v: u64) {
    match v {
        0..=63 => buf.put_u8(v as u8),
        64..=16383 => buf.put_u16(0x4000 | v as u16),
        16384..=1_073_741_823 => buf.put_u32(0x8000_0000 | v as u32),
        _ => buf.put_u64(0xc000_0000_0000_0000 | v),
    }
}

pub fn varint_len(v: u64) -> usize {
    match v {
        0..=63 => 1,
        64..=16383 => 2,
        16384..=1_073_741_823 => 4,
        _ => 8,
    }
}

/// Returns (value, bytes consumed).
pub fn get_varint(buf: &[u8]) -> Option<(u64, usize)> {
    let first = *buf.first()?;
    let len = 1usize << (first >> 6);
    if buf.len() < len {
        return None;
    }
    let mut v = (first & 0x3f) as u64;
    for b in &buf[1..len] {
        v = (v << 8) | *b as u64;
    }
    Some((v, len))
}

// ---- QPACK (RFC 9204), encoder side only ----

/// Prefix-coded integer. `prefix_bits` is the number of low bits available in the first byte.
fn put_prefixed_int(buf: &mut BytesMut, first_byte_flags: u8, prefix_bits: u8, mut value: u64) {
    let max = (1u64 << prefix_bits) - 1;
    if value < max {
        buf.put_u8(first_byte_flags | value as u8);
        return;
    }
    buf.put_u8(first_byte_flags | max as u8);
    value -= max;
    while value >= 128 {
        buf.put_u8((value % 128) as u8 + 128);
        value /= 128;
    }
    buf.put_u8(value as u8);
}

/// "Literal Field Line With Literal Name", no Huffman, no dynamic table.
///
/// Always legal, never optimal. We send a handful of headers once per connection, so the
/// bytes we waste are irrelevant and the code we avoid writing is not.
fn put_literal_field(buf: &mut BytesMut, name: &str, value: &str) {
    // 001 N H + 3-bit name length prefix. N=0, H=0.
    put_prefixed_int(buf, 0b0010_0000, 3, name.len() as u64);
    buf.put_slice(name.as_bytes());
    // H + 7-bit value length prefix. H=0.
    put_prefixed_int(buf, 0b0000_0000, 7, value.len() as u64);
    buf.put_slice(value.as_bytes());
}

/// Encode a field section: 2-byte prefix (Required Insert Count 0, Delta Base 0) then fields.
pub fn encode_field_section(fields: &[(&str, &str)]) -> BytesMut {
    let mut buf = BytesMut::new();
    buf.put_u8(0x00); // Required Insert Count = 0
    buf.put_u8(0x00); // S=0, Delta Base = 0
    for (name, value) in fields {
        put_literal_field(&mut buf, name, value);
    }
    buf
}

/// Pull `:status` out of a response field section.
///
/// Handles the encodings a server actually uses for a status line: an indexed reference into
/// the static table, or a literal. Values we do not care about are skipped, including Huffman
/// ones, so we never need a Huffman decoding table.
pub fn decode_status(mut buf: &[u8]) -> Option<u16> {
    // Skip the 2-byte field section prefix.
    if buf.len() < 2 {
        return None;
    }
    buf = &buf[2..];

    while !buf.is_empty() {
        let first = buf[0];
        if first & 0b1000_0000 != 0 {
            // Indexed Field Line. T bit says static (1) or dynamic (0).
            let is_static = first & 0b0100_0000 != 0;
            let (idx, n) = read_prefixed_int(buf, 6)?;
            buf = &buf[n..];
            if is_static && let Some(s) = static_status(idx) {
                return Some(s);
            }
        } else if first & 0b1100_0000 == 0b0100_0000 {
            // Literal Field Line With Name Reference.
            let is_static = first & 0b0001_0000 != 0;
            let (idx, n) = read_prefixed_int(buf, 4)?;
            buf = &buf[n..];
            let (val, n) = read_string(buf)?;
            buf = &buf[n..];
            if is_static && (63..=71).contains(&idx) {
                // static entries 63..=71 are the :status family
                if let Ok(s) = val.parse::<u16>() {
                    return Some(s);
                }
            }
        } else if first & 0b1110_0000 == 0b0010_0000 {
            // Literal Field Line With Literal Name.
            let (name_len, n) = read_prefixed_int(buf, 3)?;
            let huff_name = first & 0b0000_1000 != 0;
            buf = &buf[n..];
            let name = buf.get(..name_len as usize)?;
            buf = &buf[name_len as usize..];
            let (val, n) = read_string(buf)?;
            buf = &buf[n..];
            if !huff_name && name == b":status" && let Ok(s) = val.parse::<u16>() {
                return Some(s);
            }
        } else {
            // Post-base indexed forms. We never insert into the dynamic table, so a server
            // has no reason to use them; treat as undecodable rather than guess.
            return None;
        }
    }
    None
}

fn read_prefixed_int(buf: &[u8], prefix_bits: u8) -> Option<(u64, usize)> {
    let max = (1u64 << prefix_bits) - 1;
    let mut value = (*buf.first()? as u64) & max;
    if value < max {
        return Some((value, 1));
    }
    let mut i = 1;
    let mut shift = 0;
    loop {
        let b = *buf.get(i)? as u64;
        i += 1;
        value += (b & 127) << shift;
        shift += 7;
        if b & 128 == 0 {
            break;
        }
    }
    Some((value, i))
}

/// Returns (value as lossy utf8, bytes consumed). Huffman-coded values come back empty.
fn read_string(buf: &[u8]) -> Option<(String, usize)> {
    let huffman = buf.first()? & 0b1000_0000 != 0;
    let (len, n) = read_prefixed_int(buf, 7)?;
    let end = n + len as usize;
    let raw = buf.get(n..end)?;
    if huffman {
        Some((String::new(), end))
    } else {
        Some((String::from_utf8_lossy(raw).into_owned(), end))
    }
}

fn static_status(idx: u64) -> Option<u16> {
    // RFC 9204 Appendix A, the :status entries.
    Some(match idx {
        24 => 103,
        25 => 200,
        26 => 304,
        27 => 404,
        28 => 503,
        63 => 100,
        64 => 204,
        65 => 206,
        66 => 302,
        67 => 400,
        68 => 403,
        69 => 421,
        70 => 425,
        71 => 500,
        _ => return None,
    })
}

// ---- framing ----

pub fn frame(frame_type: u64, payload: &[u8]) -> BytesMut {
    let mut buf = BytesMut::with_capacity(payload.len() + 16);
    put_varint(&mut buf, frame_type);
    put_varint(&mut buf, payload.len() as u64);
    buf.put_slice(payload);
    buf
}

pub fn settings_frame() -> BytesMut {
    let mut payload = BytesMut::new();
    put_varint(&mut payload, SETTING_H3_DATAGRAM);
    put_varint(&mut payload, 1);
    put_varint(&mut payload, SETTING_ENABLE_CONNECT_PROTOCOL);
    put_varint(&mut payload, 1);
    frame(FRAME_SETTINGS, &payload)
}

/// Read one frame off a stream buffer. Returns (type, payload, total bytes consumed).
pub fn parse_frame(buf: &[u8]) -> Result<Option<(u64, &[u8], usize)>> {
    let Some((ftype, n1)) = get_varint(buf) else {
        return Ok(None);
    };
    let Some((len, n2)) = get_varint(&buf[n1..]) else {
        return Ok(None);
    };
    let start = n1 + n2;
    let end = start + len as usize;
    if buf.len() < end {
        return Ok(None);
    }
    if len > 1 << 20 {
        bail!("implausible h3 frame length {len}");
    }
    Ok(Some((ftype, &buf[start..end], end)))
}

/// Consume whole frames off the front of `buf`, returning the `:status` from the first
/// HEADERS frame.
///
/// Unknown frame types must be skipped, not treated as an error: HTTP/3 reserves a family of
/// GREASE frame types precisely to catch parsers that assume otherwise, and Cloudflare sends
/// them. Getting this wrong looks exactly like the server never answering.
pub fn take_response_status(buf: &mut Vec<u8>) -> Result<Option<u16>> {
    loop {
        let Some((ftype, payload, consumed)) = parse_frame(buf)? else {
            return Ok(None); // need more bytes
        };
        if ftype == FRAME_HEADERS {
            let status = decode_status(payload);
            buf.drain(..consumed);
            return Ok(status);
        }
        tracing_skip(ftype, payload.len());
        buf.drain(..consumed);
    }
}

fn tracing_skip(ftype: u64, len: usize) {
    tracing::trace!(frame_type = ftype, len, "skipping non-HEADERS h3 frame");
}

/// HTTP/3 datagram payload for Connect-IP: quarter stream id, context id, then the IP packet.
pub fn encode_datagram(stream_id: u64, context_id: u64, packet: &[u8]) -> BytesMut {
    let mut buf = BytesMut::with_capacity(packet.len() + 16);
    put_varint(&mut buf, stream_id / 4);
    put_varint(&mut buf, context_id);
    buf.put_slice(packet);
    buf
}

/// Inverse of `encode_datagram`. Returns (quarter stream id, context id, ip packet).
pub fn decode_datagram(buf: &[u8]) -> Option<(u64, u64, &[u8])> {
    let (qsid, n1) = get_varint(buf)?;
    let (ctx, n2) = get_varint(&buf[n1..])?;
    Some((qsid, ctx, &buf[n1 + n2..]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn varint_roundtrip() {
        for v in [0u64, 63, 64, 16383, 16384, 1 << 30, u64::MAX >> 2] {
            let mut b = BytesMut::new();
            put_varint(&mut b, v);
            assert_eq!(varint_len(v), b.len());
            assert_eq!(get_varint(&b).unwrap(), (v, b.len()));
        }
    }

    #[test]
    fn datagram_roundtrip() {
        let pkt = b"\x45\x00\x00\x1c";
        let d = encode_datagram(12, 0, pkt);
        let (qsid, ctx, out) = decode_datagram(&d).unwrap();
        assert_eq!((qsid, ctx, out), (3, 0, &pkt[..]));
    }

    #[test]
    fn status_from_literal_field() {
        let block = encode_field_section(&[(":status", "200"), ("cf-team", "abc")]);
        assert_eq!(decode_status(&block), Some(200));
    }

    #[test]
    fn skips_grease_frames_before_headers() {
        // A GREASE frame carrying a payload, then a real HEADERS frame. A parser that does not
        // advance past the first frame hangs here forever, which is the bug this guards.
        let mut buf = Vec::new();
        buf.extend_from_slice(&frame(0x2c90_b41f_3d88_9b3e, b"GREASE is the word"));
        let fields = encode_field_section(&[(":status", "200")]);
        buf.extend_from_slice(&frame(FRAME_HEADERS, &fields));
        assert_eq!(take_response_status(&mut buf).unwrap(), Some(200));
    }

    #[test]
    fn partial_frame_asks_for_more() {
        let fields = encode_field_section(&[(":status", "200")]);
        let full = frame(FRAME_HEADERS, &fields);
        let mut buf = full[..full.len() - 3].to_vec();
        assert_eq!(take_response_status(&mut buf).unwrap(), None);
    }

    #[test]
    fn status_from_static_index() {
        // 2-byte prefix, then indexed static entry 25 == :status 200
        let mut b = BytesMut::new();
        b.put_u8(0);
        b.put_u8(0);
        put_prefixed_int(&mut b, 0b1100_0000, 6, 25);
        assert_eq!(decode_status(&b), Some(200));
    }
}
