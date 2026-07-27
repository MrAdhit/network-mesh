//! Tailscale backhaul: control plane registration plus a DERP relay path.
//!
//! Registration is `ts_control`, which implements TS2021 for us. Data movement is `ts_derp`,
//! whose `send_one`/`recv_one` are already a peer-addressed relay keyed by node public key.
//!
//! Direct paths are deliberately absent: `tailscale-rs` has no magicsock, so everything here
//! rides DERP. That is phase one on purpose. The prober treats this as one candidate path and
//! a direct path becomes a second candidate later without changing anything above.

use anyhow::{Context, Result, anyhow};
use std::collections::BTreeMap;
use std::net::IpAddr;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::RwLock;
use tokio_stream::StreamExt;

use ts_keys::{NodePublicKey, NodeState, PersistState};

#[derive(Debug, Clone)]
pub struct PeerNode {
    pub id: ts_control::NodeId,
    pub hostname: String,
    pub node_key: NodePublicKey,
    pub addrs: Vec<IpAddr>,
    pub online: bool,
}

pub struct TailscaleBackhaul {
    /// Swappable, because a DERP connection dies and has to be replaced.
    ///
    /// Without this a broken pipe left the relay permanently down: every send failed forever
    /// and the path never recovered, which quietly turns a three-path mesh into a two-path one.
    derp: RwLock<Arc<ts_derp::DefaultClient>>,
    /// What it takes to build a replacement.
    servers: Vec<ts_derp::ServerConnInfo>,
    node_keys: ts_keys::NodeKeyPair,
    /// Held across a reconnect so a dozen failing callers produce one new connection.
    reconnecting: tokio::sync::Mutex<()>,
    pub self_node_key: NodePublicKey,
    pub self_addrs: Vec<IpAddr>,
    pub region: String,
    /// Numeric id, reported to the control plane so every node agrees on one region.
    pub region_id: u32,
    peers: Arc<RwLock<BTreeMap<ts_control::NodeId, PeerNode>>>,
    _control: ts_control::AsyncControlClient,
}

fn load_or_generate_keys(path: &Path) -> Result<NodeState> {
    if path.exists() {
        let s = std::fs::read_to_string(path)?;
        let persist: PersistState = serde_json::from_str(&s)
            .with_context(|| format!("parsing tailscale keys at {}", path.display()))?;
        return Ok(NodeState::from(persist));
    }
    let ns = NodeState::generate();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    std::fs::write(path, serde_json::to_vec_pretty(&PersistState::from(&ns))?)?;
    Ok(ns)
}

/// Latency to a DERP server, measured with a real HTTPS request.
///
/// Three approaches were tried here and the first two do not work from inside a container:
/// a bare TCP connect gets answered by the local network stack (it reported 9ms to New York
/// from Singapore, which then picked an absurd region), and UDP STUN on 3478 is blocked
/// outright on this network. A full TLS handshake cannot be short-circuited by either, since
/// it has to reach the real server to produce a valid certificate, so it measures the path we
/// actually care about.
async fn derp_rtt(host: &str) -> Option<std::time::Duration> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(4))
        .build()
        .ok()?;
    let start = std::time::Instant::now();
    // Any response times the path; we do not care what it says.
    client
        .get(format!("https://{host}/derp/latency-check"))
        .send()
        .await
        .ok()?;
    Some(start.elapsed())
}

/// Does `candidate` name the host we asked for?
///
/// Tailscale deduplicates colliding hostnames by appending `-1`, `-2` and so on, so a restarted
/// container whose predecessor is still in the netmap comes back as `mesh-b-1`. Matching only
/// exact names means never finding the node that is actually alive.
fn hostname_matches(candidate: &str, wanted: &str) -> bool {
    if candidate == wanted {
        return true;
    }
    candidate
        .strip_prefix(wanted)
        .and_then(|rest| rest.strip_prefix('-'))
        .is_some_and(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()))
}

fn log_peers(map: &BTreeMap<ts_control::NodeId, PeerNode>) {
    let summary: Vec<String> = map
        .values()
        .map(|p| {
            format!(
                "{}({},{})",
                p.hostname,
                p.id,
                if p.online { "up" } else { "down" }
            )
        })
        .collect();
    tracing::debug!(peers = %summary.join(" "), "netmap peers");
}

fn node_to_peer(n: &ts_control::Node) -> PeerNode {
    let addrs = vec![
        IpAddr::V4(n.tailnet_address.ipv4.addr()),
        IpAddr::V6(n.tailnet_address.ipv6.addr()),
    ];
    PeerNode {
        id: n.id,
        hostname: n.hostname.clone(),
        node_key: n.node_key,
        addrs,
        online: matches!(n.status, ts_control::NodeStatus::Online),
    }
}

impl TailscaleBackhaul {
    pub async fn connect(state_dir: &Path, hostname: &str, auth_key: &str) -> Result<Self> {
        Self::connect_to_region(state_dir, hostname, auth_key, None).await
    }

    /// `preferred_region` comes from the roster and overrides our own measurement.
    ///
    /// It has to: a DERP server relays only between clients connected to it, so two nodes that
    /// each picked their own nearest region simply cannot reach each other. Agreement beats
    /// proximity.
    pub async fn connect_to_region(
        state_dir: &Path,
        hostname: &str,
        auth_key: &str,
        preferred_region: Option<u32>,
    ) -> Result<Self> {
        let keys = load_or_generate_keys(&state_dir.join("tailscale-keys.json"))?;

        // Ephemerality is a property of the auth key in ts_control 0.4, not of Config.
        let mut cfg = ts_control::Config {
            hostname: Some(hostname.to_string()),
            client_name: Some("mesh".to_string()),
            ..Default::default()
        };
        if let Ok(url) = std::env::var("MESH_TS_CONTROL_URL")
            && let Ok(parsed) = url.parse()
        {
            cfg.server_url = parsed;
        }

        tracing::info!(hostname, "registering with tailscale control plane");
        let (control, stream) =
            ts_control::AsyncControlClient::connect(&cfg, &keys, Some(auth_key))
                .await
                .map_err(|e| anyhow!("tailscale registration failed: {e}"))?;

        let peers: Arc<RwLock<BTreeMap<ts_control::NodeId, PeerNode>>> = Default::default();
        let (self_tx, mut self_rx) = tokio::sync::mpsc::channel(4);
        let (derp_tx, mut derp_rx) = tokio::sync::mpsc::channel(4);

        tokio::spawn({
            let peers = peers.clone();
            async move {
                let mut stream = std::pin::pin!(stream);
                while let Some(update) = stream.next().await {
                    if let Some(node) = &update.node {
                        let _ = self_tx.try_send(node.clone());
                    }
                    if let Some(map) = &update.derp {
                        let _ = derp_tx.try_send(map.clone());
                    }
                    if let Some(url) = &update.pop_browser_url {
                        // Only reachable when the auth key was rejected or absent.
                        tracing::warn!(%url, "control plane wants interactive login");
                    }
                    match &update.peer_update {
                        Some(ts_control::PeerUpdate::Full(nodes)) => {
                            let mut w = peers.write().await;
                            w.clear();
                            for n in nodes {
                                w.insert(n.id, node_to_peer(n));
                            }
                            tracing::info!(count = w.len(), "netmap: full peer list");
                            log_peers(&w);
                        }
                        Some(ts_control::PeerUpdate::Delta { upsert, remove, .. }) => {
                            let mut w = peers.write().await;
                            for n in upsert {
                                w.insert(n.id, node_to_peer(n));
                            }
                            for id in remove {
                                w.remove(id);
                            }
                            log_peers(&w);
                        }
                        None => {}
                    }
                }
                tracing::warn!("tailscale netmap stream ended");
            }
        });

        let deadline = std::time::Duration::from_secs(30);
        let self_node = tokio::time::timeout(deadline, self_rx.recv())
            .await
            .map_err(|_| anyhow!("timed out waiting for our own node in the netmap"))?
            .ok_or_else(|| anyhow!("netmap stream closed before giving us our node"))?;
        let derp_map = tokio::time::timeout(deadline, derp_rx.recv())
            .await
            .map_err(|_| anyhow!("timed out waiting for the DERP map"))?
            .ok_or_else(|| anyhow!("netmap stream closed before giving us a DERP map"))?;

        let self_addrs = vec![
            IpAddr::V4(self_node.tailnet_address.ipv4.addr()),
            IpAddr::V6(self_node.tailnet_address.ipv6.addr()),
        ];

        let preferred = preferred_region
            .and_then(std::num::NonZeroU32::new)
            .map(ts_derp::RegionId);
        let (region_id, region) = pick_region(&derp_map, preferred, self_node.derp_region).await?;
        tracing::info!(region = %region.info.code, id = %region_id, "connecting to derp");

        let derp = ts_derp::DefaultClient::connect(region.servers.iter(), &keys.node_keys)
            .await
            .map_err(|e| anyhow!("derp connect to region {} failed: {e}", region.info.code))?;

        Ok(Self {
            derp: RwLock::new(Arc::new(derp)),
            servers: region.servers.clone(),
            node_keys: keys.node_keys.clone(),
            reconnecting: Default::default(),
            self_node_key: keys.node_keys.public,
            self_addrs,
            region: region.info.code.clone(),
            region_id: region_id.0.get(),
            peers,
            _control: control,
        })
    }

    pub async fn peers(&self) -> Vec<PeerNode> {
        self.peers.read().await.values().cloned().collect()
    }

    /// Every node currently claiming this hostname, best guess first.
    ///
    /// More than one is normal: an ephemeral node lingers after it stops, and Tailscale gives
    /// the replacement a `-1` suffix, so a restarted peer has two entries and both may still
    /// report online. Rather than guess which is live, callers send to all of them until traffic
    /// teaches us the right key. A packet to a dead key is dropped by the relay and costs
    /// nothing; picking wrong silently costs the whole path.
    pub async fn peer_node_keys(&self, hostname: &str) -> Vec<NodePublicKey> {
        let peers = self.peers.read().await;
        let mut matches: Vec<&PeerNode> = peers
            .values()
            .filter(|p| hostname_matches(&p.hostname, hostname))
            .collect();
        // Most recently seen first: after a restart the live node is the one with fresh traffic,
        // and it is often the one holding the deduplicated name rather than the original.
        matches.sort_by_key(|p| (!p.online, std::cmp::Reverse(p.id)));
        matches.iter().map(|p| p.node_key).collect()
    }

    /// Resolve a hostname to a node, preferring one that is online.
    ///
    /// Hostnames are not unique in a tailnet. Ephemeral nodes linger in the netmap for a while
    /// after they stop, so restarting a container leaves two nodes with the same name, and the
    /// dead one's node key routes DERP traffic into a black hole. Sorting online first avoids
    /// spending a minute talking to a ghost.
    pub async fn peer_by_hostname(&self, hostname: &str) -> Option<PeerNode> {
        let peers = self.peers.read().await;
        let mut matches: Vec<&PeerNode> = peers
            .values()
            .filter(|p| hostname_matches(&p.hostname, hostname))
            .collect();
        // Exact names before deduplicated ones, live nodes before dead ones.
        matches.sort_by_key(|p| (!p.online, p.hostname != hostname));
        tracing::debug!(
            hostname,
            candidates = ?matches.iter().map(|p| (p.id, p.online)).collect::<Vec<_>>(),
            "resolving peer"
        );
        matches.first().map(|p| (*p).clone())
    }

    /// Relay one message, failing rather than waiting when the connection is broken.
    ///
    /// This used to retry across a fresh connection, which meant awaiting `reconnect`, which
    /// retries until it succeeds. So a send during an outage did not fail, it parked for the
    /// length of the outage. That is the wrong trade for these callers: the probe loop and the
    /// TUN reader each walk every path from a single task, so a send that parks takes the paths
    /// behind it with it. Probing then stops altogether, every path ages past `PATH_TIMEOUT`,
    /// and a node whose other backhauls were healthy throughout starts rejecting traffic as
    /// unreachable. Handing the replacement to a background task keeps the failure to this one
    /// path, and the caller comes back on its own timer once the relay is up.
    pub async fn send_to(self: &Arc<Self>, peer: &NodePublicKey, msg: &[u8]) -> Result<()> {
        let client = self.derp.read().await.clone();
        match client.send_one(*peer, msg).await {
            Ok(()) => Ok(()),
            Err(e) => {
                self.replace_in_background(&client);
                Err(anyhow!("derp send failed: {e}; replacing the connection"))
            }
        }
    }

    /// Start replacing a broken connection without making the caller wait for the result.
    ///
    /// `reconnect` still does the work and still deduplicates, so a burst of failed sends
    /// produces one replacement rather than one per send.
    fn replace_in_background(self: &Arc<Self>, stale: &Arc<ts_derp::DefaultClient>) {
        let me = self.clone();
        let stale = stale.clone();
        tokio::spawn(async move { me.reconnect(&stale).await });
    }

    /// Blocks until a peer relays us something, reconnecting as needed.
    pub async fn recv(&self) -> Result<(NodePublicKey, Vec<u8>)> {
        loop {
            let client = self.derp.read().await.clone();
            match client.recv_one().await {
                Ok((src, pkt)) => return Ok((src, pkt.to_vec())),
                Err(e) => {
                    tracing::warn!(error = %e, "derp receive failed; reconnecting");
                    self.reconnect(&client).await;
                }
            }
        }
    }

    /// Replace the DERP connection, unless someone else already did.
    ///
    /// `stale` is the connection the caller found broken. If the stored one is no longer that
    /// connection, another task has already reconnected and this is a no-op, which is what
    /// stops a burst of failures becoming a burst of connections.
    async fn reconnect(&self, stale: &Arc<ts_derp::DefaultClient>) {
        let _guard = self.reconnecting.lock().await;
        if !Arc::ptr_eq(&*self.derp.read().await, stale) {
            return;
        }
        // No attempt limit. Giving up left the relay path down until the daemon was restarted,
        // which is worst exactly when it matters: an outage long enough to exhaust a handful of
        // tries is the one nobody is watching. Backoff is capped so a long outage costs a probe
        // every half minute rather than a tight loop.
        let mut backoff = Duration::from_secs(1);
        let mut attempt = 0u32;
        loop {
            attempt += 1;
            match ts_derp::DefaultClient::connect(self.servers.iter(), &self.node_keys).await {
                Ok(fresh) => {
                    *self.derp.write().await = Arc::new(fresh);
                    tracing::info!(attempt, "derp reconnected");
                    return;
                }
                Err(e) => {
                    tracing::warn!(attempt, error = %e, "derp reconnect failed");
                    tokio::time::sleep(backoff).await;
                    backoff = (backoff * 2).min(Duration::from_secs(30));
                }
            }
        }
    }
}

/// Choose a DERP region, preferring the home region the control plane assigned and otherwise
/// measuring.
///
/// Measuring matters more than it looks. A fresh node often has no home region yet, and simply
/// taking the first usable entry means region 1 (New York) regardless of where we actually are.
/// From Singapore that adds half a second to every packet, which would make the race against
/// Cloudflare a foregone conclusion for reasons that have nothing to do with the two networks.
async fn pick_region(
    map: &ts_control::DerpMap,
    preferred: Option<ts_derp::RegionId>,
    home: Option<ts_derp::RegionId>,
) -> Result<(ts_derp::RegionId, &ts_control::DerpRegion)> {
    // The network's agreed region wins outright when it is usable.
    if let Some(p) = preferred
        && let Some(r) = map.get(&p)
        && !r.servers.is_empty()
    {
        tracing::info!(region = %r.info.code, "using the network's agreed derp region");
        return Ok((p, r));
    }
    // The control plane's home region is only meaningful once a client reports latency to it,
    // which we do not do yet. Taking it on faith lands us in New York from Singapore, so treat
    // it as a hint to log and measure regardless.
    if let Some(h) = home
        && let Some(r) = map.get(&h)
    {
        tracing::debug!(region = %r.info.code, "control plane suggested a home region");
    }

    let candidates: Vec<(ts_derp::RegionId, &ts_control::DerpRegion)> = map
        .iter()
        .filter(|(_, r)| !r.servers.is_empty() && !r.info.no_measure_no_home)
        .map(|(id, r)| (*id, r))
        .collect();
    if candidates.is_empty() {
        return Err(anyhow!("derp map contained no usable region"));
    }

    let probes = candidates.iter().map(|(id, r)| {
        let host = r.servers[0].hostname.clone();
        let code = r.info.code.clone();
        async move { (*id, code, derp_rtt(&host).await) }
    });
    let mut results: Vec<_> = futures_util::future::join_all(probes).await;
    results.sort_by_key(|(_, _, rtt)| rtt.unwrap_or(std::time::Duration::MAX));

    if let Some((id, code, Some(rtt))) = results.first() {
        tracing::info!(region = %code, rtt_ms = rtt.as_secs_f64() * 1000.0, "measured closest derp");
        let region = map.get(id).expect("id came from the map");
        return Ok((*id, region));
    }
    // Nothing answered; fall back rather than refuse to start.
    tracing::warn!("no derp region answered a probe, using the first usable one");
    Ok(candidates[0])
}

#[cfg(test)]
mod tests {
    use super::hostname_matches;

    #[test]
    fn matches_exact_and_deduplicated_names() {
        assert!(hostname_matches("mesh-b", "mesh-b"));
        assert!(hostname_matches("mesh-b-1", "mesh-b"));
        assert!(hostname_matches("mesh-b-12", "mesh-b"));
    }

    #[test]
    fn does_not_match_unrelated_names() {
        assert!(!hostname_matches("mesh-b-other", "mesh-b"));
        assert!(!hostname_matches("mesh-bb", "mesh-b"));
        assert!(!hostname_matches("mesh-b-", "mesh-b"));
        assert!(!hostname_matches("other", "mesh-b"));
    }
}
