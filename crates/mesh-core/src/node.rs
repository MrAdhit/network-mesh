//! The mesh node: owns both backhauls, races them, and picks a winner per peer.

use anyhow::{Result, anyhow, bail};
use futures_util::future::join_all;
use std::collections::BTreeMap;
use std::net::Ipv4Addr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};
use tokio::sync::{Mutex, RwLock, mpsc};

use crate::cloudflare::CloudflareBackhaul;
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

/// Most candidate addresses to keep for one peer.
///
/// The list only ever grew before. Every Hello appended whatever a peer advertised and nothing
/// removed it, so a peer that roams between networks accumulated its whole history, and since an
/// unconfirmed direct path sprays every candidate, the burst grew with it. The stale entries are
/// not merely useless: a packet aimed at a port nobody has opened is exactly the event that
/// makes a port-preserving NAT stop preserving, so spraying history actively damages the thing
/// it is trying to establish. Oldest go first, because the newest address is the one a peer is
/// most likely to be reachable at now.
const MAX_DIRECT_CANDIDATES: usize = 16;
/// Guesses are cheaper to be wrong about but more damaging to send, so fewer.
const MAX_PREDICTED_CANDIDATES: usize = 8;

/// How a peer is identified everywhere inside the node.
///
/// The public key, not the name. Names are labels a user chooses and nothing stops two machines
/// choosing the same one; the default is literally the same string on every install. Keying by
/// name meant the second `mesh-node` to enrol overwrote the first in the peer table, and every
/// frame from the loser was then dropped as coming from a key that is not in the roster. The
/// key is the only identifier the control plane guarantees to be unique, and it is already what
/// decides membership, so it is what the table is keyed by.
pub type PeerKey = [u8; 32];

/// Short stand-in for a key in log lines, where 44 characters of base64 would drown the message.
pub fn fingerprint(key: &PeerKey) -> String {
    use base64::{Engine, engine::general_purpose::STANDARD_NO_PAD as B64};
    B64.encode(&key[..6])
}

/// Identifies one outstanding probe: which peer, which path, which sequence number.
type ProbeKey = (PeerKey, PathKind, u64);

/// One probe we are still waiting on.
///
/// `counts_as_loss` is false for a punch burst, which is fired blind at every candidate a peer
/// advertised and is expected to go mostly unanswered. Charging that to the path would leave a
/// direct link looking hopeless for the first seconds of its life, which is exactly when it has
/// just started working.
#[derive(Debug, Clone, Copy)]
struct Outstanding {
    sent_at: Instant,
    counts_as_loss: bool,
}

impl Outstanding {
    fn probe() -> Self {
        Self {
            sent_at: Instant::now(),
            counts_as_loss: true,
        }
    }
    fn speculative() -> Self {
        Self {
            sent_at: Instant::now(),
            counts_as_loss: false,
        }
    }
}

/// How much weight a new sample gets in the smoothed RTT.
const EWMA_ALPHA: f64 = 0.3;
/// A path with no reply for this long is considered down.
const PATH_TIMEOUT: Duration = Duration::from_secs(15);
/// How long an unanswered probe waits before it counts as lost.
///
/// Much shorter than `PATH_TIMEOUT`, because the two answer different questions. That one asks
/// whether a path is a candidate at all and wants heavy hysteresis; this one asks how much of
/// what a path carries actually arrives, and a single lost probe is a real data point even
/// though it says nothing about liveness. It matches the reply timeout `meshd` gives `ping`, so
/// a sample the CLI prints as a timeout is exactly one that counts against the path here.
const PROBE_LOST_AFTER: Duration = Duration::from_secs(5);
/// Longest one path's send may take before we give up on it and move on.
///
/// Every operation here that touches more than one path walks them from a single task, so a send
/// with no bound does not merely fail its own path, it stops the others. That is how one broken
/// backhaul used to take the whole mesh down: a relay send parked waiting for a reconnect, the
/// probe loop parked behind it, every path's `last_reply` aged past `PATH_TIMEOUT` with no probe
/// going out, and `ranked_paths` then reported a node with two healthy backhauls as unreachable.
/// A backhaul that cannot accept a packet within this long is not carrying it anyway.
const SEND_TIMEOUT: Duration = Duration::from_secs(2);

/// Hold one path's send to `SEND_TIMEOUT`.
///
/// Free-standing so the bound itself can be tested without a live backhaul underneath it.
async fn bounded_send(
    fut: impl std::future::Future<Output = Result<()>>,
    path: PathKind,
) -> Result<()> {
    tokio::time::timeout(SEND_TIMEOUT, fut)
        .await
        .unwrap_or_else(|_| {
            Err(anyhow!(
                "sending on {path} got no answer in {SEND_TIMEOUT:?}"
            ))
        })
}

#[derive(Debug, Clone, Default)]
pub struct PathStats {
    pub last_rtt_ms: Option<f64>,
    pub ewma_ms: Option<f64>,
    /// Smoothed share of probes that went unanswered, 0.0 to 1.0.
    ///
    /// Kept apart from the `sent` and `received` counters, which are lifetime totals. A path
    /// that had a bad minute an hour ago is not a lossy path now, and ranking has to answer for
    /// the present.
    pub loss_ewma: Option<f64>,
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

    /// Smoothed recent loss as a fraction. Zero until something has actually been observed.
    pub fn recent_loss(&self) -> f64 {
        self.loss_ewma.unwrap_or(0.0)
    }

    /// The same number as a percentage, which is what gets reported.
    pub fn loss_pct(&self) -> f64 {
        100.0 * self.recent_loss()
    }

    /// What this path is worth, lower being better.
    ///
    /// Smoothed RTT divided by the share of packets that survive the trip. Loss has to enter the
    /// comparison somewhere and `ewma_ms` cannot carry it: `record` only ever runs on a reply, so
    /// a path dropping half of what it carries reports exactly the latency of one dropping none,
    /// and ranking on latency alone would keep choosing it forever. Dividing by the delivery rate
    /// is the expected cost of getting a packet through, since at half loss it takes two tries on
    /// average. A 2ms LAN path at 40% loss then scores 3.3ms and still beats a clean 16ms relay,
    /// which is right, and at 90% it scores 20ms and loses, which is also right.
    pub fn score(&self) -> Option<f64> {
        // Floored, so a path that answers nothing still sorts against its peers instead of
        // producing an infinity that compares equal to every other hopeless path.
        let delivered = (1.0 - self.recent_loss()).max(0.05);
        self.ewma_ms.map(|ms| ms / delivered)
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
        self.record_loss(0.0);
    }

    /// Feed one probe outcome into the loss average: 0.0 answered, 1.0 lost.
    fn record_loss(&mut self, lost: f64) {
        self.loss_ewma = Some(match self.loss_ewma {
            Some(prev) => prev * (1.0 - EWMA_ALPHA) + lost * EWMA_ALPHA,
            None => lost,
        });
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

/// Could a mesh packet sent here plausibly reach the peer that advertised it?
///
/// Peers advertise their own candidates and nothing checks that the addresses are theirs, so an
/// unbounded list of arbitrary addresses is a list of places this node can be made to send
/// packets. Refusing the obviously bogus ones costs nothing and stops a buggy or hostile member
/// pointing the spray somewhere it has no business going.
pub fn plausible_candidate(a: &std::net::SocketAddr) -> bool {
    if a.port() == 0 {
        return false;
    }
    match a.ip() {
        std::net::IpAddr::V4(v4) => {
            !(v4.is_unspecified() || v4.is_loopback() || v4.is_multicast() || v4.is_broadcast())
        }
        // A link-local v6 address needs a scope id to be routable and we have none, so sending
        // there could only ever fail.
        std::net::IpAddr::V6(v6) => {
            !(v6.is_unspecified() || v6.is_loopback() || v6.is_multicast())
                && (v6.segments()[0] & 0xffc0) != 0xfe80
        }
    }
}

/// Record a candidate address, keeping the list bounded and free of nonsense.
///
/// Reports whether it was new, so a caller can log a genuinely new address rather than every
/// repeat of one it already had.
pub fn remember_candidate(
    list: &mut Vec<std::net::SocketAddr>,
    addr: std::net::SocketAddr,
    cap: usize,
) -> bool {
    if !plausible_candidate(&addr) || list.contains(&addr) {
        return false;
    }
    if list.len() >= cap {
        list.remove(0);
    }
    list.push(addr);
    true
}

/// Paths that are actually carrying traffic to a peer, best first.
///
/// Best is `PathStats::score`, not raw latency. Ranking on latency alone meant a path never paid
/// for what it dropped: losses never reach `ewma_ms`, and a path that answers even some of its
/// probes never trips the liveness timeout either, so a LAN link losing half of everything sat
/// at the top of the list indefinitely reporting two milliseconds.
///
/// Only live paths. A path with no recent reply is not a worse option, it is not an option: we
/// have no evidence it goes anywhere, and sending into one is guessing. When nothing is live
/// the peer is unreachable and the packet is rejected as such, which is the honest answer and
/// the one an application can act on.
///
/// This is what the old fallback got wrong. It picked the first configured path whenever
/// nothing was known to be up, which is Cloudflare, and Cloudflare is exactly the path that is
/// down when the internet is. A node whose LAN still worked would pour every packet into a dead
/// QUIC tunnel and never touch the direct path that was carrying traffic a second earlier.
///
/// Probing is what brings a path back, and it runs against every path regardless of liveness,
/// so restricting data to live paths cannot stop one recovering.
pub fn rank_paths(paths: Vec<PathKind>, stats: &BTreeMap<PathKind, PathStats>) -> Vec<PathKind> {
    let mut live: Vec<PathKind> = paths
        .into_iter()
        .filter(|k| stats.get(k).map(|s| s.up()).unwrap_or(false))
        .collect();
    live.sort_by(|a, b| {
        let score = |k: &PathKind| stats.get(k).and_then(|s| s.score()).unwrap_or(f64::MAX);
        score(a).total_cmp(&score(b))
    });
    live
}

impl PeerState {
    /// Where to send a direct packet, or `None` to go back to trying every candidate.
    ///
    /// A confirmed address is only worth using while it is still answering. A peer advertises
    /// several candidates and we pin to whichever replied first, which may well be its address
    /// on some other overlay rather than the one on the LAN we share. If the internet then goes
    /// away, that address stops working while the LAN candidate would have carried traffic
    /// perfectly, and since probes go to the confirmed address too, nothing would ever discover
    /// that. Unpinning when the path goes down puts every candidate back in play, so the next
    /// probe round finds whichever one still works.
    pub fn direct_target(&self) -> Option<std::net::SocketAddr> {
        self.paths
            .get(&PathKind::Direct)
            .map(|s| s.up())
            .unwrap_or(false)
            .then_some(self.direct_confirmed)
            .flatten()
    }

    /// Best path currently up, scored the same way `rank_paths` scores them so the two agree.
    pub fn best_path(&self) -> Option<(PathKind, f64)> {
        self.paths
            .iter()
            .filter(|(_, s)| s.up())
            .filter_map(|(k, s)| s.score().map(|v| (*k, v)))
            .min_by(|a, b| a.1.total_cmp(&b.1))
    }
}

pub struct MeshNode {
    pub name: String,
    /// Our own identity, stamped into every frame we send.
    pub self_key: [u8; 32],
    /// Our address in our own subnet. This is what the TUN interface will own.
    pub virtual_ip: Option<Ipv4Addr>,
    /// Both backhauls are swappable, because neither is guaranteed to exist when the daemon
    /// starts. A node booting while the network is down used to exit outright; it now comes up
    /// on whatever it has, and these are filled in by a retry once the network returns.
    /// A std lock rather than tokio's: these are only ever swapped or cloned, never held
    /// across an await, and keeping them sync stops the change rippling `async` through every
    /// caller that just wants to know whether a backhaul exists.
    cf: std::sync::RwLock<Option<Arc<CloudflareBackhaul>>>,
    ts: std::sync::RwLock<Option<Arc<TailscaleBackhaul>>>,
    direct: Option<Arc<DirectTransport>>,
    #[cfg(any(target_os = "linux", target_os = "macos", target_os = "windows"))]
    tun: Arc<RwLock<Option<Arc<crate::tun::TunDevice>>>>,
    /// What peers report seeing as our source address. Our reflexive candidate, learned
    /// without a STUN server.
    reflexive: Arc<RwLock<Option<std::net::SocketAddr>>>,
    /// What the NAT in front of us does to our port, once we have measured it.
    nat: Arc<RwLock<Option<crate::nat::NatProfile>>>,
    peers: Arc<RwLock<BTreeMap<PeerKey, PeerState>>>,
    /// Probes we are still waiting on, keyed by (peer, path, seq).
    inflight: Arc<Mutex<BTreeMap<ProbeKey, Outstanding>>>,
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
        cf: Option<Arc<CloudflareBackhaul>>,
        ts: Option<Arc<TailscaleBackhaul>>,
        direct: Option<Arc<DirectTransport>>,
        virtual_ip: Option<Ipv4Addr>,
    ) -> Arc<Self> {
        let (data_tx, data_rx) = mpsc::channel(256);
        Arc::new(Self {
            name,
            self_key,
            virtual_ip,
            cf: std::sync::RwLock::new(cf),
            ts: std::sync::RwLock::new(ts),
            direct,
            #[cfg(any(target_os = "linux", target_os = "macos", target_os = "windows"))]
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

    pub fn cf(&self) -> Option<Arc<CloudflareBackhaul>> {
        // A poisoned lock means some other task panicked mid-swap. The value itself is an
        // Option<Arc> and cannot be torn, so recovering is strictly better than propagating.
        self.cf.read().unwrap_or_else(|e| e.into_inner()).clone()
    }

    pub fn ts(&self) -> Option<Arc<TailscaleBackhaul>> {
        self.ts.read().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Our address inside the Cloudflare Mesh range, if that backhaul is up.
    pub fn cf_ip(&self) -> Option<Ipv4Addr> {
        self.cf().map(|c| c.mesh_ip())
    }

    /// Adopt a Cloudflare backhaul that came up after startup, and start reading from it.
    pub fn install_cloudflare(self: &Arc<Self>, cf: Arc<CloudflareBackhaul>) {
        *self.cf.write().unwrap_or_else(|e| e.into_inner()) = Some(cf.clone());
        tracing::info!(ip = %cf.mesh_ip(), "cloudflare backhaul adopted");
        self.spawn_cloudflare_loop(cf);
    }

    /// Adopt a Tailscale backhaul that came up after startup, and start reading from it.
    pub fn install_tailscale(self: &Arc<Self>, ts: Arc<TailscaleBackhaul>) {
        *self.ts.write().unwrap_or_else(|e| e.into_inner()) = Some(ts.clone());
        tracing::info!("tailscale backhaul adopted");
        self.spawn_tailscale_loop(ts);
    }

    pub fn available_paths(&self) -> Vec<PathKind> {
        let mut v = Vec::new();
        if self.cf().is_some() {
            v.push(PathKind::CloudflareMesh);
        }
        if self.ts().is_some() {
            v.push(PathKind::TailscaleDerp);
        }
        // The direct path only exists once a peer has actually answered on it, so it is added
        // per peer rather than globally. See `paths_for`.
        v
    }

    /// Paths worth trying for one specific peer.
    async fn paths_for(&self, peer: &PeerKey) -> Vec<PathKind> {
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
            seen.insert(key);
            let e = w.entry(key).or_insert_with(|| PeerState {
                name: rp.name.clone(),
                ..Default::default()
            });
            // A node may be renamed on the control plane; the key it is filed under does not
            // change, so the label just follows.
            e.name = rp.name.clone();
            e.public_key = key;
            e.virtual_ip = rp.virtual_ip.parse().ok();
            // A node registers with Tailscale under its own name, so this follows the roster
            // rather than sticking at whatever it was first seen as. It is only a bootstrap for
            // finding the peer on DERP before traffic teaches us its real node key, which is
            // authoritative once known.
            e.ts_hostname = Some(rp.name.clone());
            for p in PathKind::ALL {
                e.paths.entry(p).or_default();
            }
        }

        let removed: Vec<PeerKey> = w.keys().filter(|k| !seen.contains(*k)).copied().collect();
        for key in removed {
            let name = w.remove(&key).map(|p| p.name).unwrap_or_default();
            tracing::info!(peer = %name, "peer removed from the roster");
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

    pub async fn peer(&self, key: &PeerKey) -> Option<PeerState> {
        self.peers.read().await.get(key).cloned()
    }

    /// Find peers a user meant by `needle`, which may be a name or a mesh address.
    ///
    /// Returns every match rather than a first one. Names are not unique, so a caller that
    /// silently took the first would talk to an arbitrary one of two machines; making the
    /// ambiguity visible is the caller's problem to report, not ours to paper over. An address
    /// is always unambiguous, which is what a user reaches for once names collide.
    pub async fn resolve(&self, needle: &str) -> Vec<PeerKey> {
        let want_ip: Option<Ipv4Addr> = needle.parse().ok();
        self.peers
            .read()
            .await
            .iter()
            .filter(|(_, p)| {
                p.name == needle
                    || (want_ip.is_some() && p.virtual_ip == want_ip)
                    || p.ts_hostname.as_deref() == Some(needle)
            })
            .map(|(k, _)| *k)
            .collect()
    }

    /// Send one frame to a peer over a specific path.
    async fn send_on(&self, peer: &PeerKey, path: PathKind, frame: &Frame) -> Result<()> {
        let bytes = frame.encode();
        if bytes.len() > MSG_MAX {
            bail!("frame of {} bytes exceeds the {MSG_MAX} limit", bytes.len());
        }
        match path {
            PathKind::CloudflareMesh => {
                let tunnel = self
                    .cf()
                    .ok_or_else(|| anyhow!("cloudflare backhaul is not up"))?;
                let src = tunnel.mesh_ip();
                let dst = self
                    .peers
                    .read()
                    .await
                    .get(peer)
                    .and_then(|p| p.cf_ip)
                    .ok_or_else(|| {
                        anyhow!("no cloudflare address known for peer {}", fingerprint(peer))
                    })?;
                let ident = self.ident.fetch_add(1, Ordering::Relaxed) as u16;
                let pkt = ip::build_udp4(
                    src,
                    dst,
                    crate::proto::MESH_PORT,
                    crate::proto::MESH_PORT,
                    &bytes,
                    ident,
                );
                tunnel.send_packet(&pkt).await?;
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
                        .ok_or_else(|| anyhow!("unknown peer {}", fingerprint(peer)))?;
                    (p.direct_target(), p.direct_candidates.clone())
                };
                match confirmed {
                    Some(addr) => transport.send_to(addr, &bytes).await?,
                    None => {
                        // Nothing is answering, so spray every candidate. Whichever one comes
                        // back becomes the confirmed address and this stops. Data never lands
                        // here, because a down path is not offered for data at all; this is the
                        // probe round re-exploring after the pinned address stopped working.
                        if candidates.is_empty() {
                            bail!("no direct candidates known for {}", fingerprint(peer));
                        }
                        for addr in candidates {
                            let _ = transport.send_to(addr, &bytes).await;
                        }
                    }
                }
            }
            PathKind::TailscaleDerp => {
                let ts = self
                    .ts()
                    .ok_or_else(|| anyhow!("tailscale backhaul is not up"))?;
                let hostname = self
                    .peers
                    .read()
                    .await
                    .get(peer)
                    .and_then(|p| p.ts_hostname.clone())
                    .unwrap_or_else(|| fingerprint(peer));
                let learned = self
                    .peers
                    .read()
                    .await
                    .get(peer)
                    .and_then(|p| p.ts_node_key);
                match learned {
                    // Once traffic has told us the real key, use it and nothing else.
                    Some(k) => ts.send_to(&k, &bytes).await?,
                    None => {
                        // Bootstrap: a hostname can match several nodes, and the live one is not
                        // reliably identifiable from the netmap. Send to all of them and let the
                        // reply tell us which was right.
                        let keys = ts.peer_node_keys(&hostname).await;
                        if keys.is_empty() {
                            bail!("peer {hostname} is not in the tailscale netmap");
                        }
                        let mut sent = false;
                        for k in keys {
                            if ts.send_to(&k, &bytes).await.is_ok() {
                                sent = true;
                            }
                        }
                        if !sent {
                            bail!("no reachable tailscale node for {hostname}");
                        }
                    }
                }
            }
        }
        Ok(())
    }

    /// `send_on` with a deadline. Every caller should use this rather than `send_on` directly.
    ///
    /// The bound is a guard, not the mechanism: a backhaul is expected to fail a send rather
    /// than block on one. It is here because a single blocking send is enough to disable paths
    /// that have nothing to do with it, and it does so silently.
    async fn send_bounded(&self, peer: &PeerKey, path: PathKind, frame: &Frame) -> Result<()> {
        bounded_send(self.send_on(peer, path, frame), path).await
    }

    /// Fire one probe per peer per available path and record it as in flight.
    pub async fn probe_round(self: &Arc<Self>) {
        let peers: Vec<PeerKey> = self.peers.read().await.keys().copied().collect();

        // Re-greet anyone whose Cloudflare address we still do not have. Without this a node
        // that started first greets an absent peer, then sits out the full announcement
        // interval before trying again, and the Cloudflare path reads as 100% loss meanwhile.
        let mut regreet = Vec::new();
        for peer in &peers {
            let unknown = self
                .peers
                .read()
                .await
                .get(peer)
                .map(|p| p.cf_ip.is_none())
                .unwrap_or(false);
            if unknown && self.cf().is_some() {
                regreet.push(*peer);
            }
        }
        join_all(regreet.iter().map(|p| self.hello_to(p, true))).await;

        // Every probe goes out concurrently, across peers and paths alike. In series each path
        // waited out the one before it, so a merely slow backhaul delayed the liveness of the
        // healthy ones, and a blocked one stopped the round outright.
        let mut work = Vec::new();
        for peer in &peers {
            for path in self.paths_for(peer).await {
                work.push(self.probe_one(*peer, path));
            }
        }
        join_all(work).await;
        self.expire_inflight().await;
    }

    /// One probe on one path, recorded as in flight if it actually went out.
    async fn probe_one(&self, peer: PeerKey, path: PathKind) {
        let seq = self.seq.fetch_add(1, Ordering::Relaxed);
        let frame = Frame::new(MsgType::Probe, path, seq, &self.name, self.self_key);
        match self.send_bounded(&peer, path, &frame).await {
            Ok(()) => {
                self.inflight
                    .lock()
                    .await
                    .insert((peer, path, seq), Outstanding::probe());
                if let Some(p) = self.peers.write().await.get_mut(&peer) {
                    p.paths.entry(path).or_default().sent += 1;
                }
            }
            Err(e) => {
                tracing::debug!(peer = %fingerprint(&peer), %path, error = %e, "probe not sent");
            }
        }
    }

    /// Retire probes that have waited long enough to count as lost, and charge each one to the
    /// path that swallowed it.
    ///
    /// This is the only place a loss is ever observed. Nothing else notices one: an unanswered
    /// probe simply sits in the table, so without this a path that drops traffic is
    /// indistinguishable from one that does not.
    async fn expire_inflight(&self) {
        let lost: Vec<ProbeKey> = {
            let mut w = self.inflight.lock().await;
            let expired: Vec<(ProbeKey, bool)> = w
                .iter()
                .filter(|(_, o)| o.sent_at.elapsed() >= PROBE_LOST_AFTER)
                .map(|(k, o)| (*k, o.counts_as_loss))
                .collect();
            for (k, _) in &expired {
                w.remove(k);
            }
            expired
                .into_iter()
                .filter(|(_, counts)| *counts)
                .map(|(k, _)| k)
                .collect()
        };
        if lost.is_empty() {
            return;
        }
        let mut w = self.peers.write().await;
        for (peer, path, _) in lost {
            if let Some(p) = w.get_mut(&peer) {
                p.paths.entry(path).or_default().record_loss(1.0);
            }
        }
    }

    /// Announce our own per-backhaul addresses so peers can reach us on paths they have not
    /// been told about. Bootstrapping: whichever path is up teaches the peer about the others.
    pub async fn send_hello(self: &Arc<Self>) {
        let peers: Vec<PeerKey> = self.peers.read().await.keys().copied().collect();
        join_all(peers.iter().map(|p| self.hello_to(p, true))).await;
    }

    /// Greet one peer. `want_reply` asks them to greet us back, which is what makes discovery
    /// converge in a round trip instead of waiting for their own announcement timer.
    async fn hello_to(self: &Arc<Self>, peer: &PeerKey, want_reply: bool) {
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
            cf_ip: self.cf_ip().map(|ip| ip.to_string()),
            direct,
            predicted: self.predicted_candidates().await,
            seen_you_at,
        }
        .encode();

        let seq = if want_reply {
            HELLO_WANT_REPLY
        } else {
            HELLO_REPLY
        };
        let frames: Vec<(PathKind, Frame)> = self
            .paths_for(peer)
            .await
            .into_iter()
            .map(|path| {
                let f = Frame::new(MsgType::Hello, path, seq, &self.name, self.self_key)
                    .with_payload(payload.clone());
                (path, f)
            })
            .collect();
        join_all(frames.iter().map(|(p, f)| self.send_bounded(peer, *p, f))).await;
    }

    async fn handle_frame(
        self: &Arc<Self>,
        frame: Frame,
        arrived_on: PathKind,
        via_node_key: Option<ts_keys::NodePublicKey>,
    ) {
        self.handle_frame_from(frame, arrived_on, via_node_key, None)
            .await
    }

    /// Fire a burst at every candidate a peer has advertised.
    ///
    /// Sent blind: we do not know which candidate is reachable, and the point is that our
    /// outbound packet opens a NAT binding even when it does not arrive. Whichever one does
    /// arrive gets confirmed by the reply.
    async fn punch_at(self: &Arc<Self>, peer: &PeerKey, include_predicted: bool) {
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
        tracing::debug!(peer = %fingerprint(peer), count = candidates.len(), "punching at candidates");
        for _ in 0..PUNCH_BURST {
            let seq = self.seq.fetch_add(1, Ordering::Relaxed);
            let frame = Frame::new(
                MsgType::Probe,
                PathKind::Direct,
                seq,
                &self.name,
                self.self_key,
            );
            let bytes = frame.encode();
            self.inflight
                .lock()
                .await
                .insert((*peer, PathKind::Direct, seq), Outstanding::speculative());
            for addr in &candidates {
                let _ = transport.send_to(*addr, &bytes).await;
            }
            tokio::time::sleep(PUNCH_SPACING).await;
        }
    }

    /// Ask a peer to punch at the same time we do, then do it.
    async fn coordinate_punch(self: &Arc<Self>, peer: &PeerKey, want_reply: bool) {
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
            cf_ip: self.cf_ip().map(|ip| ip.to_string()),
            direct: candidates,
            predicted: self.predicted_candidates().await,
            seen_you_at: None,
        }
        .encode();
        let seq = if want_reply {
            HELLO_WANT_REPLY
        } else {
            HELLO_REPLY
        };

        // Relays only. A punch request that needed the direct path would be circular.
        let frames: Vec<(PathKind, Frame)> = self
            .available_paths()
            .into_iter()
            .map(|path| {
                let f = Frame::new(MsgType::Punch, path, seq, &self.name, self.self_key)
                    .with_payload(payload.clone());
                (path, f)
            })
            .collect();
        join_all(frames.iter().map(|(p, f)| self.send_bounded(peer, *p, f))).await;
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

                let need: Vec<PeerKey> = me
                    .peers
                    .read()
                    .await
                    .iter()
                    .filter(|(_, p)| p.direct_confirmed.is_none())
                    .map(|(k, _)| *k)
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
            if let Some(e) = w.get_mut(&frame.sender_key)
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
            if let Some(e) = w.get_mut(&frame.sender_key)
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
                let reply = Frame::new(
                    MsgType::ProbeReply,
                    frame.path,
                    frame.seq,
                    &self.name,
                    self.self_key,
                );
                if let Err(e) = self
                    .send_bounded(&frame.sender_key, arrived_on, &reply)
                    .await
                {
                    tracing::debug!(peer = %frame.sender, error = %e, "probe reply failed");
                }
            }
            MsgType::ProbeReply => {
                let key = (frame.sender_key, frame.path, frame.seq);
                let outstanding = self.inflight.lock().await.remove(&key);
                if let Some(outstanding) = outstanding {
                    let rtt = outstanding.sent_at.elapsed();
                    if let Some(p) = self.peers.write().await.get_mut(&frame.sender_key) {
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
                    self.hello_to(&frame.sender_key, false).await;
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
                if let Some(p) = w.get_mut(&frame.sender_key) {
                    if let Some(ip) = cf_ip
                        && p.cf_ip != Some(ip)
                    {
                        tracing::info!(peer = %frame.sender, %ip, "learned cloudflare address");
                        p.cf_ip = Some(ip);
                    }
                    for c in candidates {
                        if remember_candidate(&mut p.direct_candidates, c, MAX_DIRECT_CANDIDATES) {
                            tracing::debug!(peer = %frame.sender, candidate = %c, "new direct candidate");
                        }
                    }
                    for c in hello.predicted_addrs() {
                        remember_candidate(
                            &mut p.predicted_candidates,
                            c,
                            MAX_PREDICTED_CANDIDATES,
                        );
                    }
                }
            }
            MsgType::Punch => {
                // Learn their candidates, then fire immediately: their burst is in flight now,
                // and ours has to overlap with it to be any use.
                if let Some(hello) = HelloPayload::decode(&frame.payload) {
                    let mut w = self.peers.write().await;
                    if let Some(p) = w.get_mut(&frame.sender_key) {
                        for c in hello.direct_addrs() {
                            remember_candidate(&mut p.direct_candidates, c, MAX_DIRECT_CANDIDATES);
                        }
                        for c in hello.predicted_addrs() {
                            remember_candidate(
                                &mut p.predicted_candidates,
                                c,
                                MAX_PREDICTED_CANDIDATES,
                            );
                        }
                    }
                }
                // A Punch means the sender is transmitting right now, so its socket is bound
                // and its mapping exists. This is the one moment a guessed port is safe.
                let me = self.clone();
                let peer = frame.sender_key;
                let reply = frame.seq == HELLO_WANT_REPLY;
                tokio::spawn(async move {
                    if reply {
                        me.coordinate_punch(&peer, false).await;
                    }
                    me.punch_at(&peer, true).await;
                });
            }
            MsgType::Tunnel => {
                #[cfg(any(target_os = "linux", target_os = "macos", target_os = "windows"))]
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
    pub async fn send_data(self: &Arc<Self>, peer: &PeerKey, payload: Vec<u8>) -> Result<PathKind> {
        let path = self
            .peer(peer)
            .await
            .and_then(|p| p.best_path())
            .map(|(k, _)| k)
            .or_else(|| self.available_paths().first().copied())
            .ok_or_else(|| anyhow!("no usable path to {}", fingerprint(peer)))?;
        let seq = self.seq.fetch_add(1, Ordering::Relaxed);
        let frame =
            Frame::new(MsgType::Data, path, seq, &self.name, self.self_key).with_payload(payload);
        self.send_bounded(peer, path, &frame).await?;
        Ok(path)
    }

    /// Probe a peer `count` times on every available path, reporting each sample.
    ///
    /// Deliberately sends the identical frame down every path so the numbers are comparable;
    /// the only difference between them is the backhaul underneath.
    pub async fn ping(
        self: &Arc<Self>,
        peer: &PeerKey,
        count: u32,
        timeout: Duration,
    ) -> Vec<(PathKind, u32, Option<Duration>)> {
        let mut out = Vec::new();
        for i in 0..count {
            for path in self.paths_for(peer).await {
                let seq = self.seq.fetch_add(1, Ordering::Relaxed);
                let key = (*peer, path, seq);
                let (tx, rx) = tokio::sync::oneshot::channel();
                self.waiters.lock().await.insert(key, tx);
                self.inflight.lock().await.insert(key, Outstanding::probe());

                let frame = Frame::new(MsgType::Probe, path, seq, &self.name, self.self_key);
                if self.send_bounded(peer, path, &frame).await.is_err() {
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
    #[cfg(any(target_os = "linux", target_os = "macos", target_os = "windows"))]
    pub async fn attach_tun(self: &Arc<Self>, tun: Arc<crate::tun::TunDevice>) {
        *self.tun.write().await = Some(tun.clone());
        let me = self.clone();
        tokio::spawn(async move {
            loop {
                let packet = match tun.recv().await {
                    Ok(p) => p,
                    Err(e) => {
                        // Breaking here left the daemon running and answering meshctl while
                        // moving no traffic whatsoever, because the only thing that reads
                        // packets had stopped. Far better to keep trying and stay noisy: a
                        // genuinely dead interface is then visible in the log rather than
                        // silent.
                        tracing::error!(error = %e, "tun read failed; retrying");
                        tokio::time::sleep(Duration::from_millis(200)).await;
                        continue;
                    }
                };
                let Some(dst) = crate::tun::ipv4_destination(&packet) else {
                    continue; // IPv6 and anything malformed are dropped for now
                };
                let found = me
                    .peers
                    .read()
                    .await
                    .iter()
                    .find(|(_, p)| p.virtual_ip == Some(dst))
                    .map(|(k, p)| (*k, p.name.clone()));
                let Some((peer, name)) = found else {
                    tracing::debug!(%dst, "no peer owns that address");
                    continue;
                };
                let len = packet.len();
                // Kept before the packet is moved, so an undeliverable one can be quoted back.
                // 128 bytes covers the largest IPv4 header plus the eight bytes RFC 792 wants.
                let quote: Vec<u8> = packet.iter().take(128).copied().collect();
                match me.send_tunnel(&peer, packet).await {
                    Ok(()) => tracing::debug!(peer = %name, %dst, len, "forwarded from tun"),
                    Err(e) => {
                        tracing::debug!(peer = %name, error = %e, "forwarding from tun failed");
                        me.reject_unreachable(&quote).await;
                    }
                }
            }
        });
    }

    /// Send one encapsulated IP packet over the winning path.
    pub async fn send_tunnel(self: &Arc<Self>, peer: &PeerKey, packet: Vec<u8>) -> Result<()> {
        let paths = self.ranked_paths(peer).await;
        let Some(&first) = paths.first() else {
            bail!("{} is unreachable: no path to it is up", fingerprint(peer));
        };
        let seq = self.seq.fetch_add(1, Ordering::Relaxed);
        let mut frame =
            Frame::new(MsgType::Tunnel, first, seq, &self.name, self.self_key).with_payload(packet);

        let mut last_err = None;
        for path in paths {
            // Only the label changes between attempts, so a failover re-labels the frame we
            // already built rather than copying the packet again.
            frame.path = path;
            match self.send_bounded(peer, path, &frame).await {
                Ok(()) => return Ok(()),
                Err(e) => {
                    tracing::debug!(peer = %fingerprint(peer), ?path, error = %e, "path send failed, trying the next");
                    last_err = Some(e);
                }
            }
        }
        Err(last_err
            .unwrap_or_else(|| anyhow!("{} is unreachable: every path failed", fingerprint(peer))))
    }

    /// Tell the local stack a packet could not be delivered.
    ///
    /// Dropping silently makes an unreachable peer indistinguishable from a slow one: the
    /// application sits in a timeout learning nothing. Quoting the packet back as ICMP host
    /// unreachable fails it immediately with a reason, which is what any router in the path
    /// would do.
    #[cfg(any(target_os = "linux", target_os = "macos", target_os = "windows"))]
    async fn reject_unreachable(self: &Arc<Self>, original: &[u8]) {
        let ident = self.ident.fetch_add(1, Ordering::Relaxed) as u16;
        let Some(icmp) = ip::build_icmp4_unreachable(original, ident) else {
            return;
        };
        let tun = self.tun.read().await.clone();
        if let Some(tun) = tun
            && let Err(e) = tun.send(&icmp).await
        {
            tracing::debug!(error = %e, "could not deliver the unreachable notice");
        }
    }

    /// Every path worth trying for a peer, best first.
    ///
    /// Live paths come first, ordered by smoothed RTT, then the rest as fallbacks. That tail
    /// matters: a path can be down without our having noticed yet, and when nothing is known to
    /// be up we would otherwise have to guess. The old guess was the first configured path,
    /// which is Cloudflare, and Cloudflare is precisely the path that is down when the internet
    /// is. On a LAN that still worked perfectly, that turned a momentary outage into a total
    /// one, and it never came back on its own because the direct path was never tried again.
    async fn ranked_paths(&self, peer: &PeerKey) -> Vec<PathKind> {
        let stats = self
            .peers
            .read()
            .await
            .get(peer)
            .map(|p| p.paths.clone())
            .unwrap_or_default();
        rank_paths(self.paths_for(peer).await, &stats)
    }

    pub async fn recv_data(&self) -> Option<(String, PathKind, Vec<u8>)> {
        self.data_rx.lock().await.recv().await
    }

    fn spawn_cloudflare_loop(self: &Arc<Self>, cf: Arc<CloudflareBackhaul>) {
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
                            Ok(f) => me.handle_frame(f, PathKind::CloudflareMesh, None).await,
                            Err(e) => tracing::trace!(error = %e, "non-mesh udp in tunnel"),
                        }
                    }
                    Err(e) => {
                        // Not fatal, and not a reason to stop: the backhaul has already rebuilt
                        // the tunnel underneath us by the time this returns. Breaking out here
                        // is what used to cost the path permanently.
                        tracing::warn!(error = %e, "cloudflare tunnel receive failed; reconnected");
                    }
                }
            }
        });
    }

    fn spawn_tailscale_loop(self: &Arc<Self>, ts: Arc<TailscaleBackhaul>) {
        let me = self.clone();
        tokio::spawn(async move {
            loop {
                match ts.recv().await {
                    Ok((src, bytes)) => match Frame::decode(&bytes) {
                        Ok(f) => me.handle_frame(f, PathKind::TailscaleDerp, Some(src)).await,
                        Err(e) => tracing::trace!(error = %e, "non-mesh packet over derp"),
                    },
                    Err(e) => {
                        // `recv` reconnects internally and only surfaces an error it could not
                        // recover from, so pause rather than spin, and keep the path alive.
                        tracing::warn!(error = %e, "derp receive failed");
                        tokio::time::sleep(Duration::from_millis(200)).await;
                    }
                }
            }
        });
    }

    /// Start receive loops for each backhaul plus the probe timer.
    pub fn start(self: &Arc<Self>, probe_interval: Duration) {
        if let Some(cf) = self.cf() {
            self.spawn_cloudflare_loop(cf);
        }
        if let Some(ts) = self.ts() {
            self.spawn_tailscale_loop(ts);
        }

        if let Some(direct) = self.direct.clone() {
            let me = self.clone();
            tokio::spawn(async move {
                loop {
                    match direct.recv().await {
                        Ok((from, bytes)) => match Frame::decode(&bytes) {
                            Ok(f) => {
                                me.handle_frame_from(f, PathKind::Direct, None, Some(from))
                                    .await
                            }
                            Err(e) => tracing::trace!(%from, error = %e, "non-mesh udp"),
                        },
                        Err(e) => {
                            // Not fatal. Giving up here cost the direct path until the daemon
                            // restarted, which is the same failure the Cloudflare loop used to
                            // have. The socket outlives a transient error, so pause briefly to
                            // avoid spinning on a persistent one and carry on reading.
                            tracing::warn!(error = %e, "direct socket receive failed");
                            tokio::time::sleep(Duration::from_millis(200)).await;
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

#[cfg(test)]
mod tests {
    use super::*;

    fn live(ms: f64) -> PathStats {
        PathStats {
            ewma_ms: Some(ms),
            last_reply: Some(Instant::now()),
            ..Default::default()
        }
    }

    /// Answered once, then stopped. `last_reply` long enough ago that `up()` is false.
    fn dead(ms: f64) -> PathStats {
        PathStats {
            ewma_ms: Some(ms),
            last_reply: Some(Instant::now() - PATH_TIMEOUT * 2),
            ..Default::default()
        }
    }

    /// Answering, and fast, but dropping `loss` of what it carries.
    fn lossy(ms: f64, loss: f64) -> PathStats {
        PathStats {
            loss_ewma: Some(loss),
            ..live(ms)
        }
    }

    #[test]
    fn the_fastest_live_path_wins() {
        let stats = BTreeMap::from([
            (PathKind::CloudflareMesh, live(30.0)),
            (PathKind::TailscaleDerp, live(80.0)),
            (PathKind::Direct, live(2.0)),
        ]);
        assert_eq!(
            rank_paths(
                vec![
                    PathKind::CloudflareMesh,
                    PathKind::TailscaleDerp,
                    PathKind::Direct
                ],
                &stats
            ),
            vec![
                PathKind::Direct,
                PathKind::CloudflareMesh,
                PathKind::TailscaleDerp
            ]
        );
    }

    #[test]
    fn a_working_lan_survives_the_internet_going_away() {
        // The regression. The internet drops, so both relayed paths are dead while the direct
        // path over the LAN still answers. Only the one that works may be offered, and it has
        // to be offered: this is precisely the case that used to send everything into a dead
        // QUIC tunnel and never recover.
        let stats = BTreeMap::from([
            (PathKind::CloudflareMesh, dead(24.0)),
            (PathKind::TailscaleDerp, dead(84.0)),
            (PathKind::Direct, live(14.0)),
        ]);
        assert_eq!(
            rank_paths(
                vec![
                    PathKind::CloudflareMesh,
                    PathKind::TailscaleDerp,
                    PathKind::Direct
                ],
                &stats
            ),
            vec![PathKind::Direct]
        );
    }

    #[test]
    fn nothing_live_means_unreachable_rather_than_a_guess() {
        // Every path timed out, which is what a total outage looks like. Having once worked is
        // not evidence a path works now, so there is nothing to return and the caller rejects
        // the packet instead of picking a favourite and hoping.
        let stats = BTreeMap::from([
            (PathKind::CloudflareMesh, dead(24.0)),
            (PathKind::Direct, dead(3.0)),
        ]);
        assert!(rank_paths(vec![PathKind::CloudflareMesh, PathKind::Direct], &stats).is_empty());
    }

    #[test]
    fn a_path_we_have_never_heard_from_is_not_a_path() {
        // A freshly confirmed direct path has no reply yet. Probing runs against it regardless,
        // so it becomes usable the moment it answers, but until then it carries no data.
        assert!(
            rank_paths(
                vec![PathKind::CloudflareMesh, PathKind::Direct],
                &BTreeMap::new()
            )
            .is_empty()
        );
    }

    #[test]
    fn a_lossy_path_has_to_be_much_faster_to_keep_winning() {
        // Loss never reaches `ewma_ms`, because `record` only runs on a reply, and a path that
        // answers some of its probes never trips `PATH_TIMEOUT` either. So on latency alone a
        // LAN link dropping most of what it carries reported 2ms and stayed the winner forever.
        let clean_relay_loses = BTreeMap::from([
            (PathKind::CloudflareMesh, live(16.0)),
            (PathKind::Direct, lossy(2.0, 0.4)),
        ]);
        assert_eq!(
            rank_paths(
                vec![PathKind::CloudflareMesh, PathKind::Direct],
                &clean_relay_loses
            ),
            vec![PathKind::Direct, PathKind::CloudflareMesh],
            "3.3ms of expected cost still beats a clean 16ms, and should"
        );

        let clean_relay_wins = BTreeMap::from([
            (PathKind::CloudflareMesh, live(16.0)),
            (PathKind::Direct, lossy(2.0, 0.9)),
        ]);
        assert_eq!(
            rank_paths(
                vec![PathKind::CloudflareMesh, PathKind::Direct],
                &clean_relay_wins
            ),
            vec![PathKind::CloudflareMesh, PathKind::Direct],
            "at 90% loss a packet costs 20ms and the relay has to take over"
        );
    }

    #[tokio::test]
    async fn a_probe_that_is_never_answered_is_charged_to_its_path() {
        let node = MeshNode::new("me".into(), [9u8; 32], None, None, None, None);
        node.apply_roster(&[roster_entry("peer", "192.168.42.2", 1)])
            .await;
        node.inflight.lock().await.insert(
            ([1u8; 32], PathKind::Direct, 1),
            Outstanding {
                sent_at: Instant::now() - PROBE_LOST_AFTER * 2,
                counts_as_loss: true,
            },
        );
        node.expire_inflight().await;

        assert!(
            node.inflight.lock().await.is_empty(),
            "an expired probe has to be retired"
        );
        let peer = node.peer(&[1u8; 32]).await.unwrap();
        assert!(
            peer.paths[&PathKind::Direct].recent_loss() > 0.0,
            "and has to reach the loss average, or nothing ever observes a drop"
        );
    }

    #[tokio::test]
    async fn a_punch_burst_going_unanswered_is_not_held_against_the_path() {
        // A punch is fired blind at every candidate a peer advertised, so most of it is expected
        // to land nowhere. Counting that would leave a direct path looking hopeless for its
        // first seconds, which is exactly when it has just started working.
        let node = MeshNode::new("me".into(), [9u8; 32], None, None, None, None);
        node.apply_roster(&[roster_entry("peer", "192.168.42.2", 1)])
            .await;
        node.inflight.lock().await.insert(
            ([1u8; 32], PathKind::Direct, 1),
            Outstanding {
                sent_at: Instant::now() - PROBE_LOST_AFTER * 2,
                counts_as_loss: false,
            },
        );
        node.expire_inflight().await;

        assert!(node.inflight.lock().await.is_empty(), "still retired");
        let peer = node.peer(&[1u8; 32]).await.unwrap();
        assert_eq!(peer.paths[&PathKind::Direct].recent_loss(), 0.0);
    }

    #[tokio::test(start_paused = true)]
    async fn a_send_that_never_returns_is_failed_rather_than_waited_on() {
        // The regression. A relay send used to await its own reconnect, so during an outage it
        // did not fail, it parked. The probe loop parked behind it, no probe went out on any
        // path, and fifteen seconds later a node with two healthy backhauls called every peer
        // unreachable. Nothing here may outlive SEND_TIMEOUT.
        let start = tokio::time::Instant::now();
        let r = bounded_send(
            std::future::pending::<Result<()>>(),
            PathKind::TailscaleDerp,
        )
        .await;
        assert!(r.is_err(), "a send that never answers has to fail");
        assert_eq!(start.elapsed(), SEND_TIMEOUT, "and fail on time");
    }

    #[tokio::test(start_paused = true)]
    async fn a_send_that_answers_in_time_is_left_alone() {
        assert!(
            bounded_send(async { Ok(()) }, PathKind::Direct)
                .await
                .is_ok(),
            "the bound must not interfere with a working path"
        );
        // A path's own failure is what the caller needs to see, not the deadline's.
        let e = bounded_send(async { Err(anyhow!("no route")) }, PathKind::Direct).await;
        assert_eq!(e.unwrap_err().to_string(), "no route");
    }

    fn addr(s: &str) -> std::net::SocketAddr {
        s.parse().unwrap()
    }

    #[test]
    fn a_live_direct_path_keeps_using_the_address_that_answered() {
        let peer = PeerState {
            direct_confirmed: Some(addr("192.168.1.204:47778")),
            paths: BTreeMap::from([(PathKind::Direct, live(2.0))]),
            ..Default::default()
        };
        assert_eq!(peer.direct_target(), Some(addr("192.168.1.204:47778")));
    }

    #[test]
    fn a_dead_address_stops_being_the_only_one_we_try() {
        // Pinned to the peer's address on another overlay, which dies with the internet while
        // the LAN candidate would still work. Unpinning is what lets the next probe round find
        // it; staying pinned means the direct path never comes back.
        let peer = PeerState {
            direct_confirmed: Some(addr("100.99.7.114:47778")),
            direct_candidates: vec![addr("100.99.7.114:47778"), addr("192.168.1.204:47778")],
            paths: BTreeMap::from([(PathKind::Direct, dead(14.0))]),
            ..Default::default()
        };
        assert_eq!(
            peer.direct_target(),
            None,
            "fall back to trying every candidate"
        );
    }

    #[test]
    fn an_unprobed_direct_path_is_not_pinned_either() {
        let peer = PeerState {
            direct_confirmed: Some(addr("192.168.1.204:47778")),
            ..Default::default()
        };
        assert_eq!(peer.direct_target(), None);
    }

    fn roster_entry(name: &str, ip: &str, key: u8) -> crate::cp::RosterPeer {
        use base64::{Engine, engine::general_purpose::STANDARD as B64};
        crate::cp::RosterPeer {
            node_id: format!("node_{key}"),
            name: name.to_string(),
            virtual_ip: ip.to_string(),
            public_key: B64.encode([key; 32]),
        }
    }

    #[tokio::test]
    async fn two_machines_sharing_a_name_are_two_peers() {
        // The default node name is the same string on every install, so this is the common case
        // rather than a corner one. Keyed by name, the second enrolment overwrote the first and
        // every frame from the loser was then dropped as coming from an unknown key, leaving one
        // of the two machines permanently unreachable.
        let node = MeshNode::new("me".into(), [9u8; 32], None, None, None, None);
        node.apply_roster(&[
            roster_entry("mesh-node", "192.168.42.2", 1),
            roster_entry("mesh-node", "192.168.42.3", 2),
        ])
        .await;

        assert_eq!(node.peers().await.len(), 2, "both must survive the roster");
        assert!(node.peer(&[1u8; 32]).await.is_some());
        assert!(node.peer(&[2u8; 32]).await.is_some());
    }

    #[tokio::test]
    async fn an_address_picks_one_of_them_and_the_shared_name_picks_neither() {
        let node = MeshNode::new("me".into(), [9u8; 32], None, None, None, None);
        node.apply_roster(&[
            roster_entry("mesh-node", "192.168.42.2", 1),
            roster_entry("mesh-node", "192.168.42.3", 2),
            roster_entry("laptop", "192.168.42.4", 3),
        ])
        .await;

        // An address is always exactly one node, which is what a user falls back to.
        assert_eq!(node.resolve("192.168.42.3").await, vec![[2u8; 32]]);
        // A unique name is still perfectly usable.
        assert_eq!(node.resolve("laptop").await, vec![[3u8; 32]]);
        // A shared one matches both, so the caller can report the ambiguity rather than
        // silently talking to whichever happened to sort first.
        assert_eq!(node.resolve("mesh-node").await.len(), 2);
        assert!(node.resolve("nobody").await.is_empty());
    }

    #[tokio::test]
    async fn renaming_a_node_moves_the_label_not_the_identity() {
        let node = MeshNode::new("me".into(), [9u8; 32], None, None, None, None);
        node.apply_roster(&[roster_entry("old", "192.168.42.2", 1)])
            .await;
        node.apply_roster(&[roster_entry("new", "192.168.42.2", 1)])
            .await;

        assert_eq!(node.peers().await.len(), 1, "same key, same peer");
        assert_eq!(node.peer(&[1u8; 32]).await.unwrap().name, "new");
        assert!(node.resolve("old").await.is_empty());
        assert_eq!(node.resolve("new").await, vec![[1u8; 32]]);
    }

    #[test]
    fn a_candidate_list_stays_bounded_and_prefers_the_newest() {
        let mut list = Vec::new();
        for i in 0..(MAX_DIRECT_CANDIDATES + 5) {
            let a: std::net::SocketAddr = format!("10.0.0.{i}:47778").parse().unwrap();
            remember_candidate(&mut list, a, MAX_DIRECT_CANDIDATES);
        }
        assert_eq!(list.len(), MAX_DIRECT_CANDIDATES, "the cap holds");
        // The oldest went first: a peer's newest address is the one it is reachable at now.
        assert!(!list.contains(&"10.0.0.0:47778".parse().unwrap()));
        assert!(list.contains(&"10.0.0.20:47778".parse().unwrap()));
    }

    #[test]
    fn a_repeat_is_not_a_new_candidate() {
        let mut list = Vec::new();
        let a: std::net::SocketAddr = "10.0.0.1:47778".parse().unwrap();
        assert!(remember_candidate(&mut list, a, 4), "first time is new");
        assert!(!remember_candidate(&mut list, a, 4), "second time is not");
        assert_eq!(list.len(), 1);
    }

    #[test]
    fn nonsense_addresses_are_refused() {
        // A peer advertises these; nothing verifies they are its own, so the obviously
        // unusable ones must never make it into a list we later spray packets at.
        let mut list = Vec::new();
        for bad in [
            "0.0.0.0:47778",
            "127.0.0.1:47778",
            "224.0.0.251:47778",
            "255.255.255.255:47778",
            "10.0.0.1:0",
            "[::1]:47778",
            "[::]:47778",
            "[fe80::1]:47778",
            "[ff02::1]:47778",
        ] {
            let a: std::net::SocketAddr = bad.parse().unwrap();
            assert!(
                !remember_candidate(&mut list, a, 8),
                "{bad} must be refused"
            );
        }
        assert!(list.is_empty());

        // Ordinary private, public and ULA addresses still get through.
        for good in ["192.168.1.4:47778", "100.99.7.114:47778", "[fd7a::1]:47778"] {
            let a: std::net::SocketAddr = good.parse().unwrap();
            assert!(remember_candidate(&mut list, a, 8), "{good} must be kept");
        }
        assert_eq!(list.len(), 3);
    }
}
