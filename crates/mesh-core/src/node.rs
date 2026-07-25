//! The mesh node: owns both backhauls, races them, and picks a winner per peer.

use anyhow::{Result, anyhow, bail};
use std::collections::BTreeMap;
use std::net::Ipv4Addr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};
use tokio::sync::{Mutex, RwLock, mpsc};

use crate::cloudflare::MasqueTunnel;
use crate::direct::{DirectTransport, HelloPayload};
use crate::ip;
use crate::proto::{Frame, MSG_MAX, MsgType, PathKind};
use crate::tailscale::TailscaleBackhaul;

/// Hello and Punch sequence numbers double as a flag: ask for a reply, or be one.
const HELLO_WANT_REPLY: u64 = 1;
const HELLO_REPLY: u64 = 0;

/// How many packets to send per candidate when punching.
///
/// A burst rather than one packet: the window where both sides are transmitting is short, and a
/// single loss wastes the whole attempt.
const PUNCH_BURST: usize = 5;
/// Gap between packets in a burst.
const PUNCH_SPACING: Duration = Duration::from_millis(30);
/// How many sequential ports to guess for an endpoint-dependent NAT.
///
/// Small deliberately. Every guess is a packet at a port nobody has opened, which is the event
/// that poisons a port-preserving mapping, so the cost of guessing wide is paid by whoever we
/// guessed at.
const PREDICTION_SPREAD: u16 = 4;

/// Identifies one outstanding probe: which peer, which path, which sequence number.
type ProbeKey = (String, PathKind, u64);

/// How much weight a new sample gets in the smoothed RTT.
const EWMA_ALPHA: f64 = 0.3;
/// A path with no reply for this long is considered down.
const PATH_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Debug, Clone, Default)]
pub struct PathStats {
    pub last_rtt_ms: Option<f64>,
    pub ewma_ms: Option<f64>,
    pub sent: u64,
    pub received: u64,
    pub last_reply: Option<Instant>,
}

impl PathStats {
    pub fn up(&self) -> bool {
        self.last_reply
            .map(|t| t.elapsed() < PATH_TIMEOUT)
            .unwrap_or(false)
    }
    pub fn loss_pct(&self) -> f64 {
        if self.sent == 0 {
            return 0.0;
        }
        100.0 * (1.0 - (self.received as f64 / self.sent as f64)).clamp(0.0, 1.0)
    }
    fn record(&mut self, rtt: Duration) {
        let ms = rtt.as_secs_f64() * 1000.0;
        self.last_rtt_ms = Some(ms);
        self.ewma_ms = Some(match self.ewma_ms {
            Some(prev) => prev * (1.0 - EWMA_ALPHA) + ms * EWMA_ALPHA,
            None => ms,
        });
        self.received += 1;
        self.last_reply = Some(Instant::now());
    }
}

#[derive(Debug, Clone, Default)]
pub struct PeerState {
    pub name: String,
    /// From the roster. Membership is decided by this and nothing else.
    pub public_key: [u8; 32],
    /// The address this peer owns in our own subnet, independent of any backhaul.
    pub virtual_ip: Option<Ipv4Addr>,
    /// Learned from traffic we have received. Authoritative over hostname lookup, which is
    /// only a bootstrap and is at the mercy of Tailscale's hostname deduplication.
    pub ts_node_key: Option<ts_keys::NodePublicKey>,
    /// Addresses this peer says it might be reachable at.
    pub direct_candidates: Vec<std::net::SocketAddr>,
    /// Guessed addresses for this peer. Only ever used while answering its `Punch`.
    pub predicted_candidates: Vec<std::net::SocketAddr>,
    /// The one that actually answered. Set on the first packet we receive directly from them,
    /// which is also the moment the direct path becomes usable.
    pub direct_confirmed: Option<std::net::SocketAddr>,
    /// Their address inside the Cloudflare Mesh range.
    pub cf_ip: Option<Ipv4Addr>,
    pub ts_hostname: Option<String>,
    pub paths: BTreeMap<PathKind, PathStats>,
}

impl PeerState {
    /// Lowest smoothed RTT among paths that are currently up.
    pub fn best_path(&self) -> Option<(PathKind, f64)> {
        self.paths
            .iter()
            .filter(|(_, s)| s.up())
            .filter_map(|(k, s)| s.ewma_ms.map(|ms| (*k, ms)))
            .min_by(|a, b| a.1.total_cmp(&b.1))
    }
}

pub struct MeshNode {
    pub name: String,
    /// Our own identity, stamped into every frame we send.
    pub self_key: [u8; 32],
    /// Our address in our own subnet. This is what the TUN interface will own.
    pub virtual_ip: Option<Ipv4Addr>,
    pub cf_ip: Option<Ipv4Addr>,
    cf: Option<Arc<MasqueTunnel>>,
    ts: Option<Arc<TailscaleBackhaul>>,
    direct: Option<Arc<DirectTransport>>,
    #[cfg(target_os = "linux")]
    tun: Arc<RwLock<Option<Arc<crate::tun::TunDevice>>>>,
    /// What peers report seeing as our source address. Our reflexive candidate, learned
    /// without a STUN server.
    reflexive: Arc<RwLock<Option<std::net::SocketAddr>>>,
    /// What the NAT in front of us does to our port, once we have measured it.
    nat: Arc<RwLock<Option<crate::nat::NatProfile>>>,
    peers: Arc<RwLock<BTreeMap<String, PeerState>>>,
    /// Probes we are still waiting on, keyed by (peer, path, seq).
    inflight: Arc<Mutex<BTreeMap<ProbeKey, Instant>>>,
    /// One-shot channels for `ping`, which needs individual samples rather than an average.
    waiters: Arc<Mutex<BTreeMap<ProbeKey, tokio::sync::oneshot::Sender<Duration>>>>,
    seq: AtomicU64,
    ident: AtomicU64,
    data_tx: mpsc::Sender<(String, PathKind, Vec<u8>)>,
    data_rx: Mutex<mpsc::Receiver<(String, PathKind, Vec<u8>)>>,
}

impl MeshNode {
    pub fn new(
        name: String,
        self_key: [u8; 32],
        cf: Option<Arc<MasqueTunnel>>,
        cf_ip: Option<Ipv4Addr>,
        ts: Option<Arc<TailscaleBackhaul>>,
        direct: Option<Arc<DirectTransport>>,
        virtual_ip: Option<Ipv4Addr>,
    ) -> Arc<Self> {
        let (data_tx, data_rx) = mpsc::channel(256);
        Arc::new(Self {
            name,
            self_key,
            virtual_ip,
            cf_ip,
            cf,
            ts,
            direct,
            #[cfg(target_os = "linux")]
            tun: Default::default(),
            reflexive: Default::default(),
            nat: Default::default(),
            peers: Default::default(),
            inflight: Default::default(),
            waiters: Default::default(),
            seq: AtomicU64::new(1),
            ident: AtomicU64::new(1),
            data_tx,
            data_rx: Mutex::new(data_rx),
        })
    }

    pub fn available_paths(&self) -> Vec<PathKind> {
        let mut v = Vec::new();
        if self.cf.is_some() && self.cf_ip.is_some() {
            v.push(PathKind::CloudflareMesh);
        }
        if self.ts.is_some() {
            v.push(PathKind::TailscaleDerp);
        }
        // The direct path only exists once a peer has actually answered on it, so it is added
        // per peer rather than globally. See `paths_for`.
        v
    }

    /// Paths worth trying for one specific peer.
    async fn paths_for(&self, peer: &str) -> Vec<PathKind> {
        let mut v = self.available_paths();
        if self.direct.is_some()
            && let Some(p) = self.peers.read().await.get(peer)
            && (p.direct_confirmed.is_some() || !p.direct_candidates.is_empty())
        {
            v.push(PathKind::Direct);
        }
        v
    }

    /// Replace the peer table from the control plane's roster.
    ///
    /// This is the only way a peer comes into existence. Learned facts (a peer's Cloudflare
    /// address, its DERP node key, its measured path stats) survive across refreshes; anything
    /// the roster no longer lists is dropped, so revoking a node on the control plane removes
    /// it from the mesh at the next poll.
    pub async fn apply_roster(&self, peers: &[crate::cp::RosterPeer]) {
        use base64::{Engine, engine::general_purpose::STANDARD as B64};
        let mut w = self.peers.write().await;
        let mut seen = std::collections::BTreeSet::new();

        for rp in peers {
            let Some(key) = B64
                .decode(&rp.public_key)
                .ok()
                .and_then(|b| <[u8; 32]>::try_from(b.as_slice()).ok())
            else {
                tracing::warn!(peer = %rp.name, "roster entry has an unusable public key");
                continue;
            };
            seen.insert(rp.name.clone());
            let e = w.entry(rp.name.clone()).or_insert_with(|| PeerState {
                name: rp.name.clone(),
                ..Default::default()
            });
            e.public_key = key;
            e.virtual_ip = rp.virtual_ip.parse().ok();
            if e.ts_hostname.is_none() {
                e.ts_hostname = Some(rp.name.clone());
            }
            for p in PathKind::ALL {
                e.paths.entry(p).or_default();
            }
        }

        let removed: Vec<String> = w.keys().filter(|k| !seen.contains(*k)).cloned().collect();
        for name in removed {
            tracing::info!(peer = %name, "peer removed from the roster");
            w.remove(&name);
        }
    }

    /// Which roster peer, if any, does this key belong to?
    async fn peer_name_for_key(&self, key: &[u8; 32]) -> Option<String> {
        self.peers
            .read()
            .await
            .values()
            .find(|p| &p.public_key == key)
            .map(|p| p.name.clone())
    }

    pub async fn peers(&self) -> Vec<PeerState> {
        self.peers.read().await.values().cloned().collect()
    }

    pub async fn peer(&self, name: &str) -> Option<PeerState> {
        self.peers.read().await.get(name).cloned()
    }

    /// Send one frame to a peer over a specific path.
    async fn send_on(&self, peer: &str, path: PathKind, frame: &Frame) -> Result<()> {
        let bytes = frame.encode();
        if bytes.len() > MSG_MAX {
            bail!("frame of {} bytes exceeds the {MSG_MAX} limit", bytes.len());
        }
        match path {
            PathKind::CloudflareMesh => {
                let tunnel = self
                    .cf
                    .as_ref()
                    .ok_or_else(|| anyhow!("cloudflare backhaul is not up"))?;
                let src = self
                    .cf_ip
                    .ok_or_else(|| anyhow!("we have no cloudflare mesh address"))?;
                let dst = self
                    .peers
                    .read()
                    .await
                    .get(peer)
                    .and_then(|p| p.cf_ip)
                    .ok_or_else(|| anyhow!("no cloudflare address known for peer {peer}"))?;
                let ident = self.ident.fetch_add(1, Ordering::Relaxed) as u16;
                let pkt = ip::build_udp4(
                    src,
                    dst,
                    crate::proto::MESH_PORT,
                    crate::proto::MESH_PORT,
                    &bytes,
                    ident,
                );
                tunnel.send_packet(&pkt)?;
            }
            PathKind::Direct => {
                let transport = self
                    .direct
                    .as_ref()
                    .ok_or_else(|| anyhow!("direct transport is not up"))?;
                let (confirmed, candidates) = {
                    let r = self.peers.read().await;
                    let p = r
                        .get(peer)
                        .ok_or_else(|| anyhow!("unknown peer {peer}"))?;
                    (p.direct_confirmed, p.direct_candidates.clone())
                };
                match confirmed {
                    Some(addr) => transport.send_to(addr, &bytes).await?,
                    None => {
                        // Nothing has answered yet, so spray every candidate. Whichever one
                        // comes back becomes the confirmed address and this stops.
                        if candidates.is_empty() {
                            bail!("no direct candidates known for {peer}");
                        }
                        for addr in candidates {
                            let _ = transport.send_to(addr, &bytes).await;
                        }
                    }
                }
            }
            PathKind::TailscaleDerp => {
                let ts = self
                    .ts
                    .as_ref()
                    .ok_or_else(|| anyhow!("tailscale backhaul is not up"))?;
                let hostname = self
                    .peers
                    .read()
                    .await
                    .get(peer)
                    .and_then(|p| p.ts_hostname.clone())
                    .unwrap_or_else(|| peer.to_string());
                let learned = self
                    .peers
                    .read()
                    .await
                    .get(peer)
                    .and_then(|p| p.ts_node_key);
                let key = match learned {
                    Some(k) => k,
                    None => {
                        ts.peer_by_hostname(&hostname)
                            .await
                            .ok_or_else(|| {
                                anyhow!("peer {hostname} is not in the tailscale netmap")
                            })?
                            .node_key
                    }
                };
                ts.send_to(&key, &bytes).await?;
            }
        }
        Ok(())
    }

    /// Fire one probe per peer per available path and record it as in flight.
    pub async fn probe_round(self: &Arc<Self>) {
        let peers: Vec<String> = self.peers.read().await.keys().cloned().collect();

        // Re-greet anyone whose Cloudflare address we still do not have. Without this a node
        // that started first greets an absent peer, then sits out the full announcement
        // interval before trying again, and the Cloudflare path reads as 100% loss meanwhile.
        for peer in &peers {
            let unknown = self
                .peers
                .read()
                .await
                .get(peer)
                .map(|p| p.cf_ip.is_none())
                .unwrap_or(false);
            if unknown && self.cf.is_some() {
                self.hello_to(peer, true).await;
            }
        }

        for peer in peers {
            for path in self.paths_for(&peer).await {
                let seq = self.seq.fetch_add(1, Ordering::Relaxed);
                let frame = Frame::new(MsgType::Probe, path, seq, &self.name, self.self_key);
                match self.send_on(&peer, path, &frame).await {
                    Ok(()) => {
                        self.inflight
                            .lock()
                            .await
                            .insert((peer.clone(), path, seq), Instant::now());
                        if let Some(p) = self.peers.write().await.get_mut(&peer) {
                            p.paths.entry(path).or_default().sent += 1;
                        }
                    }
                    Err(e) => {
                        tracing::debug!(peer, %path, error = %e, "probe not sent");
                    }
                }
            }
        }
        self.expire_inflight().await;
    }

    async fn expire_inflight(&self) {
        let mut w = self.inflight.lock().await;
        w.retain(|_, sent| sent.elapsed() < PATH_TIMEOUT);
    }

    /// Announce our own per-backhaul addresses so peers can reach us on paths they have not
    /// been told about. Bootstrapping: whichever path is up teaches the peer about the others.
    pub async fn send_hello(self: &Arc<Self>) {
        let peers: Vec<String> = self.peers.read().await.keys().cloned().collect();
        for peer in peers {
            self.hello_to(&peer, true).await;
        }
    }

    /// Greet one peer. `want_reply` asks them to greet us back, which is what makes discovery
    /// converge in a round trip instead of waiting for their own announcement timer.
    async fn hello_to(self: &Arc<Self>, peer: &str, want_reply: bool) {
        let direct: Vec<String> = self
            .direct_candidates_of_ours()
            .await
            .iter()
            .map(|a| a.to_string())
            .collect();
        let seen_you_at = self
            .peers
            .read()
            .await
            .get(peer)
            .and_then(|p| p.direct_confirmed)
            .map(|a| a.to_string());

        let payload = HelloPayload {
            cf_ip: self.cf_ip.map(|ip| ip.to_string()),
            direct,
            predicted: self.predicted_candidates().await,
            seen_you_at,
        }
        .encode();

        let seq = if want_reply { HELLO_WANT_REPLY } else { HELLO_REPLY };
        for path in self.paths_for(peer).await {
            let f = Frame::new(MsgType::Hello, path, seq, &self.name, self.self_key)
                .with_payload(payload.clone());
            let _ = self.send_on(peer, path, &f).await;
        }
    }

    async fn handle_frame(
        self: &Arc<Self>,
        frame: Frame,
        arrived_on: PathKind,
        via_node_key: Option<ts_keys::NodePublicKey>,
    ) {
        self.handle_frame_from(frame, arrived_on, via_node_key, None).await
    }

    /// Fire a burst at every candidate a peer has advertised.
    ///
    /// Sent blind: we do not know which candidate is reachable, and the point is that our
    /// outbound packet opens a NAT binding even when it does not arrive. Whichever one does
    /// arrive gets confirmed by the reply.
    async fn punch_at(self: &Arc<Self>, peer: &str, include_predicted: bool) {
        let Some(transport) = self.direct.clone() else {
            return;
        };
        let candidates = {
            let r = self.peers.read().await;
            match r.get(peer) {
                Some(p) if p.direct_confirmed.is_none() => {
                    let mut c = p.direct_candidates.clone();
                    if include_predicted {
                        // Only now. A guessed port that nobody has opened, hit from outside,
                        // is what makes a port-preserving NAT stop preserving.
                        c.extend(p.predicted_candidates.iter().copied());
                    }
                    c
                }
                _ => return, // already have a direct path, or no such peer
            }
        };
        if candidates.is_empty() {
            return;
        }
        tracing::debug!(peer, count = candidates.len(), "punching at candidates");
        for _ in 0..PUNCH_BURST {
            let seq = self.seq.fetch_add(1, Ordering::Relaxed);
            let frame =
                Frame::new(MsgType::Probe, PathKind::Direct, seq, &self.name, self.self_key);
            let bytes = frame.encode();
            self.inflight
                .lock()
                .await
                .insert((peer.to_string(), PathKind::Direct, seq), Instant::now());
            for addr in &candidates {
                let _ = transport.send_to(*addr, &bytes).await;
            }
            tokio::time::sleep(PUNCH_SPACING).await;
        }
    }

    /// Ask a peer to punch at the same time we do, then do it.
    async fn coordinate_punch(self: &Arc<Self>, peer: &str, want_reply: bool) {
        let candidates: Vec<String> = self
            .direct_candidates_of_ours()
            .await
            .iter()
            .map(|a| a.to_string())
            .collect();
        if candidates.is_empty() {
            return;
        }
        let payload = HelloPayload {
            cf_ip: self.cf_ip.map(|ip| ip.to_string()),
            direct: candidates,
            predicted: self.predicted_candidates().await,
            seen_you_at: None,
        }
        .encode();
        let seq = if want_reply { HELLO_WANT_REPLY } else { HELLO_REPLY };

        // Relays only. A punch request that needed the direct path would be circular.
        for path in self.available_paths() {
            let f = Frame::new(MsgType::Punch, path, seq, &self.name, self.self_key)
                .with_payload(payload.clone());
            let _ = self.send_on(peer, path, &f).await;
        }
        // Our own burst goes to observed addresses only: at this point we have no evidence the
        // peer's socket is up, so a guess here could poison it.
        self.punch_at(peer, false).await;
    }

    /// Ports a peer may guess at, derived from what we measured the NAT doing.
    async fn predicted_candidates(&self) -> Vec<String> {
        self.nat
            .read()
            .await
            .as_ref()
            .map(|p| {
                p.predicted_candidates(PREDICTION_SPREAD)
                    .iter()
                    .map(|a| a.to_string())
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Every address we might be reachable at, including our reflexive one.
    async fn direct_candidates_of_ours(&self) -> Vec<std::net::SocketAddr> {
        let mut out = self
            .direct
            .as_ref()
            .map(|d| d.local_candidates())
            .unwrap_or_default();
        if let Some(r) = *self.reflexive.read().await
            && !out.contains(&r)
        {
            out.push(r);
        }
        out
    }

    /// Keep our reflexive address current, and re-punch at peers we have no direct path to.
    pub fn start_nat_traversal(self: &Arc<Self>, stun_servers: Vec<std::net::SocketAddr>) {
        let me = self.clone();
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(Duration::from_secs(20));
            let mut announced = false;
            loop {
                ticker.tick().await;

                if let Some(transport) = me.direct.clone()
                    && !stun_servers.is_empty()
                {
                    // Ask every server. Two answers from two destinations are what separate a
                    // NAT that assigns per source from one that assigns per destination, and
                    // that distinction decides whether a port can be predicted at all.
                    let mut observed = Vec::new();
                    for server in &stun_servers {
                        match transport.reflexive_address(*server).await {
                            Ok(addr) => observed.push(addr),
                            Err(e) => tracing::debug!(error = %e, %server, "stun query failed"),
                        }
                    }
                    if !observed.is_empty() {
                        let profile = crate::nat::NatProfile::classify(
                            transport.local_port,
                            observed.clone(),
                        );
                        if !announced {
                            tracing::info!(
                                mapping = ?profile.mapping,
                                observed = ?profile.observed,
                                local_port = profile.local_port,
                                "nat profile"
                            );
                            if profile.looks_poisoned() {
                                tracing::warn!(
                                    local_port = profile.local_port,
                                    "this NAT is no longer preserving our port, which usually \
                                     means something probed it before we bound. Restarting on a \
                                     different port would recover it."
                                );
                            }
                            announced = true;
                        }
                        let mut w = me.reflexive.write().await;
                        if *w != observed.first().copied() {
                            tracing::info!(addr = ?observed.first(), "reflexive address");
                            *w = observed.first().copied();
                        }
                        drop(w);
                        *me.nat.write().await = Some(profile);
                    }
                }

                let need: Vec<String> = me
                    .peers
                    .read()
                    .await
                    .values()
                    .filter(|p| p.direct_confirmed.is_none())
                    .map(|p| p.name.clone())
                    .collect();
                for peer in need {
                    me.coordinate_punch(&peer, true).await;
                }
            }
        });
    }

    async fn handle_frame_from(
        self: &Arc<Self>,
        frame: Frame,
        arrived_on: PathKind,
        via_node_key: Option<ts_keys::NodePublicKey>,
        source: Option<std::net::SocketAddr>,
    ) {
        // Membership is the roster's decision. A frame from a key we were not told about is
        // dropped rather than being allowed to conjure a peer into the table, which is what
        // keeps the mesh to our own nodes even though we share a tailnet and a Cloudflare org
        // with plenty of machines that are not ours.
        let Some(peer_name) = self.peer_name_for_key(&frame.sender_key).await else {
            tracing::debug!(
                claimed = %frame.sender,
                "dropping frame from a key that is not in the roster"
            );
            return;
        };
        if peer_name != frame.sender {
            tracing::debug!(
                claimed = %frame.sender, actual = %peer_name,
                "frame's name disagrees with its key; trusting the key"
            );
        }
        let frame = Frame {
            sender: peer_name,
            ..frame
        };

        // A packet that arrived directly proves the address it came from works, which is the
        // whole confirmation step. No separate handshake needed.
        if let Some(src) = source {
            let mut w = self.peers.write().await;
            if let Some(e) = w.get_mut(&frame.sender)
                && e.direct_confirmed != Some(src)
            {
                tracing::info!(peer = %frame.sender, addr = %src, "direct path confirmed");
                e.direct_confirmed = Some(src);
                if !e.direct_candidates.contains(&src) {
                    e.direct_candidates.push(src);
                }
            }
        }

        if let Some(k) = via_node_key {
            let mut w = self.peers.write().await;
            if let Some(e) = w.get_mut(&frame.sender)
                && e.ts_node_key != Some(k)
            {
                tracing::info!(peer = %frame.sender, "learned tailscale node key from traffic");
                e.ts_node_key = Some(k);
            }
        }

        match frame.msg_type {
            MsgType::Probe => {
                // Reply on the path the probe arrived on, echoing its seq and path id, so the
                // sender can attribute the RTT even if routing is asymmetric.
                let reply =
                    Frame::new(MsgType::ProbeReply, frame.path, frame.seq, &self.name, self.self_key);
                if let Err(e) = self.send_on(&frame.sender, arrived_on, &reply).await {
                    tracing::debug!(peer = %frame.sender, error = %e, "probe reply failed");
                }
            }
            MsgType::ProbeReply => {
                let key = (frame.sender.clone(), frame.path, frame.seq);
                let sent_at = self.inflight.lock().await.remove(&key);
                if let Some(sent_at) = sent_at {
                    let rtt = sent_at.elapsed();
                    if let Some(p) = self.peers.write().await.get_mut(&frame.sender) {
                        p.paths.entry(frame.path).or_default().record(rtt);
                    }
                    if let Some(tx) = self.waiters.lock().await.remove(&key) {
                        let _ = tx.send(rtt);
                    }
                    tracing::trace!(
                        peer = %frame.sender, path = %frame.path,
                        rtt_ms = rtt.as_secs_f64() * 1000.0, "probe reply"
                    );
                }
            }
            MsgType::Hello => {
                if frame.seq == HELLO_WANT_REPLY {
                    // Answer directly rather than waiting for our own timer. Replies carry
                    // HELLO_REPLY so this cannot ping-pong.
                    self.hello_to(&frame.sender, false).await;
                }
                let Some(hello) = HelloPayload::decode(&frame.payload) else {
                    return;
                };
                if let Some(seen) = hello.seen_you_at.as_ref().and_then(|s| s.parse().ok()) {
                    let mut w = self.reflexive.write().await;
                    if *w != Some(seen) {
                        tracing::info!(%seen, "learned our own reflexive address from a peer");
                        *w = Some(seen);
                    }
                }
                let cf_ip: Option<Ipv4Addr> = hello.cf_ip.as_ref().and_then(|s| s.parse().ok());
                let candidates = hello.direct_addrs();

                let mut w = self.peers.write().await;
                if let Some(p) = w.get_mut(&frame.sender) {
                    if let Some(ip) = cf_ip
                        && p.cf_ip != Some(ip)
                    {
                        tracing::info!(peer = %frame.sender, %ip, "learned cloudflare address");
                        p.cf_ip = Some(ip);
                    }
                    for c in candidates {
                        if !p.direct_candidates.contains(&c) {
                            tracing::debug!(peer = %frame.sender, candidate = %c, "new direct candidate");
                            p.direct_candidates.push(c);
                        }
                    }
                    for c in hello.predicted_addrs() {
                        if !p.predicted_candidates.contains(&c) {
                            p.predicted_candidates.push(c);
                        }
                    }
                }
            }
            MsgType::Punch => {
                // Learn their candidates, then fire immediately: their burst is in flight now,
                // and ours has to overlap with it to be any use.
                if let Some(hello) = HelloPayload::decode(&frame.payload) {
                    let mut w = self.peers.write().await;
                    if let Some(p) = w.get_mut(&frame.sender) {
                        for c in hello.direct_addrs() {
                            if !p.direct_candidates.contains(&c) {
                                p.direct_candidates.push(c);
                            }
                        }
                        for c in hello.predicted_addrs() {
                            if !p.predicted_candidates.contains(&c) {
                                p.predicted_candidates.push(c);
                            }
                        }
                    }
                }
                // A Punch means the sender is transmitting right now, so its socket is bound
                // and its mapping exists. This is the one moment a guessed port is safe.
                let me = self.clone();
                let peer = frame.sender.clone();
                let reply = frame.seq == HELLO_WANT_REPLY;
                tokio::spawn(async move {
                    if reply {
                        me.coordinate_punch(&peer, false).await;
                    }
                    me.punch_at(&peer, true).await;
                });
            }
            MsgType::Tunnel => {
                #[cfg(target_os = "linux")]
                {
                    let tun = self.tun.read().await.clone();
                    match tun {
                        Some(tun) => match tun.send(&frame.payload).await {
                            Ok(()) => tracing::trace!(
                                from = %frame.sender, len = frame.payload.len(), "delivered to tun"
                            ),
                            Err(e) => tracing::debug!(error = %e, "writing to tun failed"),
                        },
                        None => tracing::debug!("tunnelled packet arrived but no tun is attached"),
                    }
                }
            }
            MsgType::Data => {
                let _ = self
                    .data_tx
                    .try_send((frame.sender.clone(), arrived_on, frame.payload));
            }
        }
    }

    /// Send application data over whichever path is currently winning.
    pub async fn send_data(self: &Arc<Self>, peer: &str, payload: Vec<u8>) -> Result<PathKind> {
        let path = self
            .peer(peer)
            .await
            .and_then(|p| p.best_path())
            .map(|(k, _)| k)
            .or_else(|| self.available_paths().first().copied())
            .ok_or_else(|| anyhow!("no usable path to {peer}"))?;
        let seq = self.seq.fetch_add(1, Ordering::Relaxed);
        let frame =
            Frame::new(MsgType::Data, path, seq, &self.name, self.self_key).with_payload(payload);
        self.send_on(peer, path, &frame).await?;
        Ok(path)
    }

    /// Probe a peer `count` times on every available path, reporting each sample.
    ///
    /// Deliberately sends the identical frame down every path so the numbers are comparable;
    /// the only difference between them is the backhaul underneath.
    pub async fn ping(self: &Arc<Self>, peer: &str, count: u32, timeout: Duration) -> Vec<(PathKind, u32, Option<Duration>)> {
        let mut out = Vec::new();
        for i in 0..count {
            for path in self.paths_for(peer).await {
                let seq = self.seq.fetch_add(1, Ordering::Relaxed);
                let key = (peer.to_string(), path, seq);
                let (tx, rx) = tokio::sync::oneshot::channel();
                self.waiters.lock().await.insert(key.clone(), tx);
                self.inflight.lock().await.insert(key.clone(), Instant::now());

                let frame = Frame::new(MsgType::Probe, path, seq, &self.name, self.self_key);
                if self.send_on(peer, path, &frame).await.is_err() {
                    self.waiters.lock().await.remove(&key);
                    self.inflight.lock().await.remove(&key);
                    out.push((path, i, None));
                    continue;
                }
                if let Some(p) = self.peers.write().await.get_mut(peer) {
                    p.paths.entry(path).or_default().sent += 1;
                }
                match tokio::time::timeout(timeout, rx).await {
                    Ok(Ok(rtt)) => out.push((path, i, Some(rtt))),
                    _ => {
                        self.waiters.lock().await.remove(&key);
                        out.push((path, i, None));
                    }
                }
            }
            if i + 1 < count {
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
        }
        out
    }

    /// Attach a TUN device and start moving packets between it and the mesh.
    ///
    /// Routing is by destination address alone: the roster gives every peer an address in our
    /// subnet, so a packet's destination names its peer. Nothing about the packet is modified,
    /// which is why a path flip cannot break an established connection.
    #[cfg(target_os = "linux")]
    pub async fn attach_tun(self: &Arc<Self>, tun: Arc<crate::tun::TunDevice>) {
        *self.tun.write().await = Some(tun.clone());
        let me = self.clone();
        tokio::spawn(async move {
            loop {
                let packet = match tun.recv().await {
                    Ok(p) => p,
                    Err(e) => {
                        tracing::error!(error = %e, "tun read failed");
                        break;
                    }
                };
                let Some(dst) = crate::tun::ipv4_destination(&packet) else {
                    continue; // IPv6 and anything malformed are dropped for now
                };
                let peer = me
                    .peers
                    .read()
                    .await
                    .values()
                    .find(|p| p.virtual_ip == Some(dst))
                    .map(|p| p.name.clone());
                let Some(peer) = peer else {
                    tracing::debug!(%dst, "no peer owns that address");
                    continue;
                };
                let len = packet.len();
                match me.send_tunnel(&peer, packet).await {
                    Ok(()) => tracing::trace!(peer, %dst, len, "forwarded from tun"),
                    Err(e) => tracing::debug!(peer, error = %e, "forwarding from tun failed"),
                }
            }
        });
    }

    /// Send one encapsulated IP packet over the winning path.
    pub async fn send_tunnel(self: &Arc<Self>, peer: &str, packet: Vec<u8>) -> Result<()> {
        let path = self
            .peer(peer)
            .await
            .and_then(|p| p.best_path())
            .map(|(k, _)| k)
            .or_else(|| self.available_paths().first().copied())
            .ok_or_else(|| anyhow!("no usable path to {peer}"))?;
        let seq = self.seq.fetch_add(1, Ordering::Relaxed);
        let frame =
            Frame::new(MsgType::Tunnel, path, seq, &self.name, self.self_key).with_payload(packet);
        self.send_on(peer, path, &frame).await
    }

    pub async fn recv_data(&self) -> Option<(String, PathKind, Vec<u8>)> {
        self.data_rx.lock().await.recv().await
    }

    /// Start receive loops for each backhaul plus the probe timer.
    pub fn start(self: &Arc<Self>, probe_interval: Duration) {
        if let Some(cf) = self.cf.clone() {
            let me = self.clone();
            tokio::spawn(async move {
                loop {
                    match cf.recv_packet().await {
                        Ok(pkt) => {
                            let Some(udp) = ip::parse_udp4(&pkt) else {
                                continue;
                            };
                            if udp.dst_port != crate::proto::MESH_PORT {
                                continue;
                            }
                            match Frame::decode(&udp.payload) {
                                Ok(f) => {
                                    me.handle_frame(f, PathKind::CloudflareMesh, None).await
                                }
                                Err(e) => tracing::trace!(error = %e, "non-mesh udp in tunnel"),
                            }
                        }
                        Err(e) => {
                            tracing::error!(error = %e, "cloudflare tunnel receive failed");
                            break;
                        }
                    }
                }
            });
        }

        if let Some(ts) = self.ts.clone() {
            let me = self.clone();
            tokio::spawn(async move {
                loop {
                    match ts.recv().await {
                        Ok((src, bytes)) => match Frame::decode(&bytes) {
                            Ok(f) => {
                                me.handle_frame(f, PathKind::TailscaleDerp, Some(src)).await
                            }
                            Err(e) => tracing::trace!(error = %e, "non-mesh packet over derp"),
                        },
                        Err(e) => {
                            tracing::error!(error = %e, "derp receive failed");
                            break;
                        }
                    }
                }
            });
        }

        if let Some(direct) = self.direct.clone() {
            let me = self.clone();
            tokio::spawn(async move {
                loop {
                    match direct.recv().await {
                        Ok((from, bytes)) => match Frame::decode(&bytes) {
                            Ok(f) => {
                                me.handle_frame_from(f, PathKind::Direct, None, Some(from)).await
                            }
                            Err(e) => tracing::trace!(%from, error = %e, "non-mesh udp"),
                        },
                        Err(e) => {
                            tracing::error!(error = %e, "direct socket receive failed");
                            break;
                        }
                    }
                }
            });
        }

        let me = self.clone();
        tokio::spawn(async move {
            // Hello first so peers can learn addresses before the first probe needs them.
            me.send_hello().await;
            let mut ticker = tokio::time::interval(probe_interval);
            let mut rounds = 0u64;
            loop {
                ticker.tick().await;
                me.probe_round().await;
                rounds += 1;
                // Re-announce periodically: peers may have joined since the last hello.
                if rounds.is_multiple_of(10) {
                    me.send_hello().await;
                }
            }
        });
    }
}
