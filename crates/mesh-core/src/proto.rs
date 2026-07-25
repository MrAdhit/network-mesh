//! The wire format that rides every backhaul.
//!
//! One format for all paths, deliberately. The whole point of the project is comparing a
//! Connect-IP path against a DERP path, and that comparison is only honest if both carry
//! byte-identical probes and are timed the same way. Framing below this differs per backhaul;
//! everything from `MAGIC` onward does not.

use anyhow::{Result, bail};

pub const MAGIC: &[u8; 4] = b"MESH";
pub const VERSION: u8 = 2;
/// UDP port our packets use inside the Cloudflare Connect-IP tunnel.
pub const MESH_PORT: u16 = 47777;
/// Ceiling on one encoded frame.
///
/// Sized so a full-MTU tunnelled packet still fits inside a QUIC datagram once the Connect-IP
/// framing and the IPv4/UDP wrapper are added. See `tun::MTU` for the other half of this sum.
pub const MSG_MAX: usize = 1300;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum MsgType {
    /// Latency probe. Echoed back as `ProbeReply` with the same seq.
    Probe = 1,
    ProbeReply = 2,
    /// Identity announcement, so peers learn each other's per-backhaul addresses.
    Hello = 3,
    /// Application payload, from the CLI.
    Data = 4,
    /// A whole IP packet from the TUN interface, carried untouched.
    Tunnel = 5,
    /// "I am about to punch, start punching too." Relayed, never sent directly.
    ///
    /// Hole punching needs both sides transmitting inside the same window: each side's outbound
    /// packet is what opens the NAT binding the other side's inbound packet needs. Independent
    /// timers do not reliably overlap, so one side asks and both fire.
    Punch = 6,
}

impl MsgType {
    fn from_u8(v: u8) -> Option<Self> {
        Some(match v {
            1 => Self::Probe,
            2 => Self::ProbeReply,
            3 => Self::Hello,
            4 => Self::Data,
            5 => Self::Tunnel,
            6 => Self::Punch,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(u8)]
pub enum PathKind {
    CloudflareMesh = 1,
    TailscaleDerp = 2,
    /// Peer to peer, no relay. Discovered rather than configured, so it is absent until it
    /// is proven to work.
    Direct = 3,
}

impl PathKind {
    pub fn from_u8(v: u8) -> Option<Self> {
        Some(match v {
            1 => Self::CloudflareMesh,
            2 => Self::TailscaleDerp,
            3 => Self::Direct,
            _ => return None,
        })
    }
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::CloudflareMesh => "cloudflare",
            Self::TailscaleDerp => "tailscale-derp",
            Self::Direct => "direct",
        }
    }
    pub const ALL: [PathKind; 3] = [
        PathKind::CloudflareMesh,
        PathKind::TailscaleDerp,
        PathKind::Direct,
    ];

    /// Paths that carry traffic through someone else's infrastructure.
    pub fn is_relay(&self) -> bool {
        !matches!(self, PathKind::Direct)
    }
}

impl std::fmt::Display for PathKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Header length before the variable-length sender name.
const HEADER_LEN: usize = 4 + 1 + 1 + 1 + 1 + 8 + 32;

#[derive(Debug, Clone)]
pub struct Frame {
    pub msg_type: MsgType,
    /// The sender's Ed25519 public key. The roster decides membership by this, so a frame
    /// whose key we do not recognise is dropped rather than being allowed to create a peer.
    pub sender_key: [u8; 32],
    /// Which path the sender used. Echoed in replies so an RTT is attributed correctly even
    /// when the reply comes back a different way.
    pub path: PathKind,
    pub seq: u64,
    pub sender: String,
    pub payload: Vec<u8>,
}

impl Frame {
    pub fn new(
        msg_type: MsgType,
        path: PathKind,
        seq: u64,
        sender: &str,
        sender_key: [u8; 32],
    ) -> Self {
        Self {
            msg_type,
            sender_key,
            path,
            seq,
            sender: sender.to_string(),
            payload: Vec::new(),
        }
    }

    pub fn with_payload(mut self, payload: Vec<u8>) -> Self {
        self.payload = payload;
        self
    }

    pub fn encode(&self) -> Vec<u8> {
        let name = self.sender.as_bytes();
        let name_len = name.len().min(255);
        let mut out = Vec::with_capacity(HEADER_LEN + name_len + self.payload.len());
        out.extend_from_slice(MAGIC);
        out.push(VERSION);
        out.push(self.msg_type as u8);
        out.push(self.path as u8);
        out.push(name_len as u8);
        out.extend_from_slice(&self.seq.to_be_bytes());
        out.extend_from_slice(&self.sender_key);
        out.extend_from_slice(&name[..name_len]);
        out.extend_from_slice(&self.payload);
        out
    }

    pub fn decode(buf: &[u8]) -> Result<Self> {
        if buf.len() < HEADER_LEN {
            bail!("frame too short: {} bytes", buf.len());
        }
        if &buf[..4] != MAGIC {
            bail!("bad magic");
        }
        if buf[4] != VERSION {
            bail!("unsupported frame version {}", buf[4]);
        }
        let msg_type =
            MsgType::from_u8(buf[5]).ok_or_else(|| anyhow::anyhow!("bad msg type {}", buf[5]))?;
        let path =
            PathKind::from_u8(buf[6]).ok_or_else(|| anyhow::anyhow!("bad path id {}", buf[6]))?;
        let name_len = buf[7] as usize;
        let seq = u64::from_be_bytes(buf[8..16].try_into()?);
        let sender_key: [u8; 32] = buf[16..48].try_into()?;
        let name_end = HEADER_LEN + name_len;
        if buf.len() < name_end {
            bail!("frame truncated in sender name");
        }
        Ok(Self {
            msg_type,
            sender_key,
            path,
            seq,
            sender: String::from_utf8_lossy(&buf[HEADER_LEN..name_end]).into_owned(),
            payload: buf[name_end..].to_vec(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_roundtrip() {
        let key = [7u8; 32];
        let f = Frame::new(MsgType::Probe, PathKind::CloudflareMesh, 42, "node-a", key)
            .with_payload(b"payload".to_vec());
        let d = Frame::decode(&f.encode()).unwrap();
        assert_eq!(d.sender_key, key);
        assert_eq!(d.msg_type, MsgType::Probe);
        assert_eq!(d.path, PathKind::CloudflareMesh);
        assert_eq!(d.seq, 42);
        assert_eq!(d.sender, "node-a");
        assert_eq!(d.payload, b"payload");
    }

    #[test]
    fn rejects_an_older_frame_version() {
        let mut raw = Frame::new(MsgType::Probe, PathKind::CloudflareMesh, 1, "a", [1u8; 32]).encode();
        raw[4] = 1;
        assert!(Frame::decode(&raw).is_err());
    }

    #[test]
    fn rejects_foreign_traffic() {
        assert!(Frame::decode(b"not a mesh frame at all really").is_err());
        assert!(Frame::decode(b"MESH").is_err());
    }

    #[test]
    fn empty_payload_is_fine() {
        let f = Frame::new(MsgType::Hello, PathKind::TailscaleDerp, 0, "n", [0u8; 32]);
        let d = Frame::decode(&f.encode()).unwrap();
        assert!(d.payload.is_empty());
        assert_eq!(d.sender, "n");
    }
}
