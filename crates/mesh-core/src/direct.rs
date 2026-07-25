//! Direct peer-to-peer paths: our own discovery, over our own UDP socket.
//!
//! Deliberately not Tailscale's disco. We have no interoperability target, we already have two
//! working bootstrap channels to exchange candidates over, and rolling our own means the direct
//! path does not depend on either vendor's control plane being reachable.
//!
//! The mechanism is the same idea though, because it is the idea that works: tell the peer every
//! address you might be reachable at, have them try all of them, and let the first reply win.
//!
//! Behind NAT it is hole punching, in the ordinary sense: STUN gives each side a reflexive
//! address, a relayed `Punch` gets both transmitting in the same window, and whichever packet
//! lands teaches the receiver where the sender really is. See `nat.rs` for how a port is
//! predicted when the reflexive address alone is not enough.

use anyhow::{Context, Result, anyhow};
use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::net::UdpSocket;
use tokio::sync::{Mutex, oneshot};

use crate::stun;

/// Default port for the direct path. Fixed rather than ephemeral so a restarted node is
/// reachable at an address its peers already know.
pub const DEFAULT_PORT: u16 = 47778;

pub struct DirectTransport {
    sock: Arc<UdpSocket>,
    pub local_port: u16,
    /// Addresses never offered as direct candidates.
    ///
    /// Our own mesh subnet lives here. Without it we advertise the address of the `mesh0`
    /// interface, the peer reaches it through the mesh, and that gets confirmed as a "direct"
    /// path. It then works, which is the trap: discovery traffic loops through the very overlay
    /// it is meant to bypass, and the path reads as direct while carrying relay latency.
    excluded: Vec<ipnet::IpNet>,
    /// STUN queries awaiting an answer, by transaction id.
    ///
    /// STUN shares this socket rather than using its own, and it has to: a NAT maps per source
    /// port, so a reflexive address discovered on a different socket describes a mapping our
    /// traffic does not have. `recv` therefore filters STUN responses out of the mesh stream.
    pending_stun: Mutex<BTreeMap<stun::TxId, oneshot::Sender<SocketAddr>>>,
}

impl DirectTransport {
    pub async fn bind(port: u16) -> Result<Self> {
        Self::bind_excluding(port, Vec::new()).await
    }

    pub async fn bind_excluding(port: u16, excluded: Vec<ipnet::IpNet>) -> Result<Self> {
        let sock = UdpSocket::bind(("0.0.0.0", port))
            .await
            .with_context(|| format!("binding udp/{port} for direct paths"))?;
        let local_port = sock.local_addr()?.port();
        Ok(Self {
            sock: Arc::new(sock),
            local_port,
            excluded,
            pending_stun: Mutex::new(BTreeMap::new()),
        })
    }

    /// Ask a STUN server where it sees us. This is the address peers behind other NATs need.
    pub async fn reflexive_address(&self, server: SocketAddr) -> Result<SocketAddr> {
        let txid: stun::TxId = rand::random();
        let (tx, rx) = oneshot::channel();
        self.pending_stun.lock().await.insert(txid, tx);

        let req = stun::binding_request(&txid);
        if let Err(e) = self.sock.send_to(&req, server).await {
            self.pending_stun.lock().await.remove(&txid);
            return Err(e.into());
        }
        match tokio::time::timeout(std::time::Duration::from_secs(3), rx).await {
            Ok(Ok(addr)) => Ok(addr),
            _ => {
                self.pending_stun.lock().await.remove(&txid);
                Err(anyhow!("STUN server {server} did not answer"))
            }
        }
    }

    /// Addresses a peer might be able to reach us on.
    ///
    /// Every non-loopback interface address paired with our port. On a normal host this is one
    /// or two entries; the peer tries all of them and we find out which works by which one
    /// answers.
    pub fn local_candidates(&self) -> Vec<SocketAddr> {
        let mut out = Vec::new();
        if let Ok(ifaces) = if_addrs::get_if_addrs() {
            for iface in ifaces {
                let ip = iface.ip();
                if ip.is_loopback() || ip.is_multicast() {
                    continue;
                }
                if self.excluded.iter().any(|net| net.contains(&ip)) {
                    continue;
                }
                // Link-local v6 needs a scope id to be useful; not worth the complexity here.
                if let std::net::IpAddr::V6(v6) = ip
                    && (v6.segments()[0] & 0xffc0) == 0xfe80
                {
                    continue;
                }
                out.push(SocketAddr::new(ip, self.local_port));
            }
        }
        out
    }

    pub async fn send_to(&self, addr: SocketAddr, bytes: &[u8]) -> Result<()> {
        self.sock.send_to(bytes, addr).await?;
        Ok(())
    }

    /// Receive the next mesh packet. STUN responses are handled here and never surface.
    pub async fn recv(&self) -> Result<(SocketAddr, Vec<u8>)> {
        loop {
            let mut buf = vec![0u8; 2048];
            let (n, from) = self.sock.recv_from(&mut buf).await?;
            buf.truncate(n);

            let mut delivered = false;
            {
                let mut pending = self.pending_stun.lock().await;
                if !pending.is_empty() {
                    let matched = pending
                        .keys()
                        .copied()
                        .find(|tx| stun::parse_binding_response(&buf, tx).is_some());
                    if let Some(tx) = matched
                        && let Some(waiter) = pending.remove(&tx)
                    {
                        let addr = stun::parse_binding_response(&buf, &tx).expect("just matched");
                        let _ = waiter.send(addr);
                        delivered = true;
                    }
                }
            }
            if !delivered {
                return Ok((from, buf));
            }
        }
    }
}

/// What a node tells its peers about itself, carried in `Hello`.
///
/// JSON rather than a packed struct: it rides an already-working relay, it is sent rarely, and
/// being able to add a field without a version bump is worth more than the bytes.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct HelloPayload {
    /// Our address inside the Cloudflare Mesh range.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cf_ip: Option<String>,
    /// Addresses we might be reachable at directly.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub direct: Vec<String>,
    /// Guessed addresses, kept apart from `direct` on purpose.
    ///
    /// A guess aimed at a port the sender has not opened is precisely the inbound-before-bind
    /// event that makes a port-preserving NAT start allocating randomly instead. So these are
    /// only ever fired at in reply to a `Punch`, when we know the sender's socket is bound and
    /// its outbound packet has already left. Never on a timer, never speculatively.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub predicted: Vec<String>,
    /// The source address we saw this peer's traffic arrive from.
    ///
    /// Only meaningful once a direct packet has arrived, so it confirms rather than bootstraps.
    /// It is what carries endpoint-dependent NATs, where the reflexive address is for the wrong
    /// destination and only the peer's observation of our punch is correct.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seen_you_at: Option<String>,
}

impl HelloPayload {
    pub fn encode(&self) -> Vec<u8> {
        serde_json::to_vec(self).unwrap_or_default()
    }

    pub fn decode(bytes: &[u8]) -> Option<Self> {
        if bytes.is_empty() {
            return None;
        }
        serde_json::from_slice(bytes).ok()
    }

    pub fn direct_addrs(&self) -> Vec<SocketAddr> {
        self.direct.iter().filter_map(|s| s.parse().ok()).collect()
    }

    pub fn predicted_addrs(&self) -> Vec<SocketAddr> {
        self.predicted
            .iter()
            .filter_map(|s| s.parse().ok())
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn excludes_our_own_overlay_addresses() {
        // Whatever this host's interfaces are, nothing inside an excluded range may be offered
        // as a candidate. This is the guard against discovery looping through the mesh.
        let all: ipnet::IpNet = "0.0.0.0/0".parse().unwrap();
        let t = DirectTransport::bind_excluding(0, vec![all]).await.unwrap();
        let v4: Vec<_> = t
            .local_candidates()
            .into_iter()
            .filter(|a| a.is_ipv4())
            .collect();
        assert!(v4.is_empty(), "excluded range still produced {v4:?}");
    }

    #[test]
    fn hello_payload_round_trips() {
        let h = HelloPayload {
            cf_ip: Some("10.96.0.8".into()),
            direct: vec!["192.168.1.5:47778".into(), "[2001:db8::1]:47778".into()],
            predicted: vec!["203.0.113.9:47778".into()],
            seen_you_at: Some("203.0.113.9:41000".into()),
        };
        let back = HelloPayload::decode(&h.encode()).unwrap();
        assert_eq!(back.cf_ip.as_deref(), Some("10.96.0.8"));
        assert_eq!(back.direct_addrs().len(), 2);
        assert_eq!(back.predicted_addrs().len(), 1);
        assert_eq!(back.seen_you_at.as_deref(), Some("203.0.113.9:41000"));
    }

    #[test]
    fn empty_and_garbage_payloads_are_not_fatal() {
        assert!(HelloPayload::decode(&[]).is_none());
        assert!(HelloPayload::decode(b"not json").is_none());
    }

    #[test]
    fn unparseable_candidates_are_skipped_not_fatal() {
        let h = HelloPayload {
            direct: vec!["garbage".into(), "10.0.0.1:1".into()],
            ..Default::default()
        };
        assert_eq!(h.direct_addrs().len(), 1);
    }
}
