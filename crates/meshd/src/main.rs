//! meshd: brings up both backhauls, races them, and answers meshctl.

use anyhow::{Context, Result, anyhow};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use mesh_core::cloudflare::{CloudflareBackhaul, DeviceIdentity, api, tunnel};
use mesh_core::cp::CloudflareConfig;
use mesh_core::cpclient::{CpClient, NodeIdentity};
use mesh_core::direct::DirectTransport;
use mesh_core::ipc::{
    BackhaulReport, Listener, PathReport, PeerReport, PingSample, Request, Response, StatusReport,
    default_endpoint,
};
use mesh_core::node::MeshNode;
use mesh_core::state::{
    Bootstrap, COMPILED_CP_URL, CloudflareState, ControlPlaneState, NodeState, default_state_dir,
    resolve_cp_url,
};
use mesh_core::tailscale::TailscaleBackhaul;
use std::net::{Ipv4Addr, SocketAddr};
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

/// Consecutive rejected roster fetches before we accept that we have been removed.
///
/// More than one, because a single 401 could be a control plane restarting mid-request and
/// evicting a healthy node over that would be worse than the delay.
const REVOCATION_TOLERANCE: u32 = 3;

/// Register with the control plane and persist what it gives back.
///
/// Used both for a first join and for rejoining after a revocation. The node keeps its Ed25519
/// identity either way; the control plane treats enrollment as idempotent by public key, so
/// this returns the existing record if one survives and mints a fresh one if it does not.
async fn enroll(
    state: &mut NodeState,
    state_dir: &Path,
    cp_url: &str,
    identity: &NodeIdentity,
    node_name: &str,
    enrollment_key: &str,
) -> Result<()> {
    let client = CpClient::new(cp_url)?;
    let resp = client.enroll(enrollment_key, identity, node_name).await?;
    tracing::info!(
        node_id = %resp.node_id, ip = %resp.virtual_ip, subnet = %resp.subnet,
        "enrolled with the control plane"
    );
    state.control_plane = Some(ControlPlaneState {
        url: cp_url.to_string(),
        node_id: resp.node_id,
        node_token: resp.node_token,
        virtual_ip: resp.virtual_ip,
        subnet: resp.subnet,
        peers: Vec::new(),
        // Filled in by the first roster fetch, moments from now.
        backhauls: Default::default(),
    });
    state.save(state_dir)?;
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("MESH_LOG")
                .unwrap_or_else(|_| "info,mesh_core=debug".into()),
        )
        .init();

    let state_dir = default_state_dir();
    std::fs::create_dir_all(&state_dir)
        .with_context(|| format!("creating state dir {}", state_dir.display()))?;

    let node_name = std::env::var("MESH_NODE_NAME")
        .or_else(|_| std::env::var("HOSTNAME"))
        .unwrap_or_else(|_| "mesh-node".to_string());
    let boot = Bootstrap::from_env();
    let mut state = NodeState::load(&state_dir)?;
    state.node_name = node_name.clone();

    tracing::info!(node = %node_name, state = %state_dir.display(), "meshd starting");

    let identity = NodeIdentity::load_or_generate(&state_dir.join("node-identity.key"))?;
    tracing::info!(public_key = %identity.public_b64(), "node identity");

    // --- control plane: enroll once, then fetch the roster ---
    let (cp_url, cp_url_source) = resolve_cp_url(
        boot.cp_url.as_deref(),
        state.control_plane.as_ref().map(|c| c.url.as_str()),
        COMPILED_CP_URL,
    )
    .ok_or_else(|| {
        anyhow!(
            "no control plane to talk to: set MESH_CP_URL, or build with it set to bake in a              default"
        )
    })?;
    tracing::info!(url = %cp_url, source = %cp_url_source, "control plane");

    if state.control_plane.is_none() {
        let key = boot.enrollment_key.clone().ok_or_else(|| {
            anyhow!("this node has not enrolled yet; set MESH_ENROLLMENT_KEY to join a network")
        })?;
        enroll(&mut state, &state_dir, &cp_url, &identity, &node_name, &key).await?;
    }

    let mut cp_state = state.control_plane.clone().expect("just enrolled");
    let mut cp = Arc::new(CpClient::new(&cp_url)?.with_token(cp_state.node_token.clone()));

    // A stale roster beats no mesh at all, so a control plane outage is survivable. A rejected
    // token is not the same thing and cached state cannot paper over it, so it is handled
    // separately below.
    let (roster, fresh) = match cp.roster().await {
        Ok(r) => (r, true),
        Err(e) if e.is_unauthorized() => {
            // Our registration is gone, most likely revoked. Rejoining is only legitimate
            // because it takes a currently-valid enrollment key, which is exactly the
            // credential an operator rotates when they mean the eviction to stick. Without one
            // this is fatal, and says so.
            let key = boot.enrollment_key.clone().ok_or_else(|| {
                anyhow!(
                    "the control plane no longer recognises this node; it was probably removed. Set MESH_ENROLLMENT_KEY to rejoin, or delete {} to start clean",
                    state_dir.display()
                )
            })?;
            tracing::warn!(
                old_node_id = %cp_state.node_id,
                "our registration was revoked; rejoining with the enrollment key"
            );
            enroll(&mut state, &state_dir, &cp_url, &identity, &node_name, &key).await?;
            cp_state = state.control_plane.clone().expect("just re-enrolled");
            cp = Arc::new(CpClient::new(&cp_url)?.with_token(cp_state.node_token.clone()));
            (cp.roster().await?, true)
        }
        Err(e) => {
            tracing::warn!(error = %e, "control plane unreachable; using the cached roster");
            (
                mesh_core::cp::Roster {
                    subnet: cp_state.subnet.clone(),
                    stun_servers: Vec::new(),
                    derp_region: None,
                    self_virtual_ip: cp_state.virtual_ip.clone(),
                    peers: cp_state.peers.clone(),
                    backhauls: cp_state.backhauls.clone(),
                },
                false,
            )
        }
    };
    if fresh {
        if let Some(c) = state.control_plane.as_mut() {
            c.peers = roster.peers.clone();
            c.backhauls = roster.backhauls.clone();
            c.virtual_ip = roster.self_virtual_ip.clone();
            c.subnet = roster.subnet.clone();
        }
        state.save(&state_dir)?;
    }
    let virtual_ip: Ipv4Addr = roster
        .self_virtual_ip
        .parse()
        .with_context(|| format!("control plane gave us {}", roster.self_virtual_ip))?;
    tracing::info!(%virtual_ip, subnet = %roster.subnet, peers = roster.peers.len(), "roster");

    // --- Cloudflare backhaul ---
    let mut cf_tunnel: Option<Arc<CloudflareBackhaul>> = None;
    match roster.backhauls.cloudflare.clone() {
        Some(cfg) => match bring_up_cloudflare(&state_dir, &mut state, &cfg, &node_name).await {
            Ok((t, ip)) => {
                cf_tunnel = Some(Arc::new(t));
                tracing::info!(%ip, "cloudflare backhaul up");
            }
            // A dead backhaul is a degraded mesh, not a dead one. That is the entire premise.
            Err(e) => tracing::error!(error = ?e, "cloudflare backhaul failed to come up"),
        },
        None => tracing::warn!("this network has no cloudflare credentials; skipping"),
    }

    // --- Tailscale backhaul ---
    let mut ts: Option<Arc<TailscaleBackhaul>> = None;
    if roster.backhauls.tailscale_available {
        // Minted per attempt rather than stored: ephemeral node records get reaped, and a fresh
        // key is what makes coming back from that self-healing.
        match cp.tailscale_auth_key().await {
            Ok(auth_key) => {
                match TailscaleBackhaul::connect_to_region(
                    &state_dir,
                    &node_name,
                    &auth_key,
                    roster.derp_region,
                )
                .await
                {
                    Ok(b) => {
                        tracing::info!(
                            addrs = ?b.self_addrs, region = %b.region, "tailscale backhaul up"
                        );
                        ts = Some(Arc::new(b));
                    }
                    Err(e) => tracing::error!(error = ?e, "tailscale backhaul failed to come up"),
                }
            }
            Err(e) => tracing::error!(error = %e, "could not get a tailscale auth key"),
        }
    } else {
        tracing::warn!("this network has no tailscale credentials; skipping");
    }

    // Deliberately not fatal any more. Exiting here meant a machine that rebooted while the
    // network was down stayed down until somebody logged in and started it by hand, which is the
    // one situation where unattended recovery matters most. A node with no relay is degraded,
    // not useless: it still serves peers on the same LAN over the direct path, using the roster
    // it cached, and the retry below adopts the relays the moment they come back.
    if cf_tunnel.is_none() && ts.is_none() {
        tracing::warn!("no backhaul came up; running on the direct path alone and retrying");
    }

    // The direct path is not a backhaul and does not gate startup: it either gets discovered
    // or it does not, and the relays carry traffic meanwhile.
    // Reuse the same port every time, because port preservation is what makes a peer's guess
    // work. Unless last run found it poisoned, in which case keeping it would inherit the
    // problem, so move.
    let configured = std::env::var("MESH_DIRECT_PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(mesh_core::direct::DEFAULT_PORT);
    let direct_port = if state.direct_port_poisoned {
        let moved = state
            .direct_port
            .map(|p| p.wrapping_add(1).max(1024))
            .unwrap_or(configured + 1);
        tracing::warn!(
            old = ?state.direct_port, new = moved,
            "last run's port stopped being preserved; binding a different one"
        );
        moved
    } else {
        state.direct_port.unwrap_or(configured)
    };
    // Exclude our own subnet, or we advertise the mesh0 address as a direct candidate and
    // discovery loops back through the overlay it is supposed to bypass.
    let excluded: Vec<ipnet::IpNet> = roster.subnet.parse().into_iter().collect();
    let direct = match DirectTransport::bind_excluding(direct_port, excluded).await {
        Ok(d) => {
            tracing::info!(port = d.local_port, candidates = ?d.local_candidates(), "direct transport up");
            Some(Arc::new(d))
        }
        Err(e) => {
            tracing::warn!(error = %e, "no direct transport; relays only");
            None
        }
    };
    state.save(&state_dir)?;

    let bound_port = direct.as_ref().map(|d| d.local_port);
    // Lets the roster refresh task stop the daemon when the control plane says we are no
    // longer a member.
    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);

    let node = MeshNode::new(
        node_name.clone(),
        identity.public_bytes(),
        cf_tunnel.clone(),
        ts.clone(),
        direct,
        Some(virtual_ip),
    );
    node.apply_roster(&roster.peers).await;

    // Bring up the kernel interface last, once we know our address and have paths to use.
    #[cfg(any(target_os = "linux", target_os = "macos", target_os = "windows"))]
    if std::env::var("MESH_TUN").map(|v| v != "0").unwrap_or(true) {
        // macOS will not let us name the interface; the kernel hands back a utunN. Asking for
        // "utun" here means "any free one" and keeps the default meaningful on both platforms.
        let default_name = if cfg!(target_os = "macos") {
            "utun"
        } else {
            "mesh0"
        };
        let name = std::env::var("MESH_TUN_NAME").unwrap_or_else(|_| default_name.into());
        match mesh_core::tun::TunDevice::open(&name, virtual_ip, &roster.subnet) {
            Ok(dev) => node.attach_tun(Arc::new(dev)).await,
            // Without CAP_NET_ADMIN or /dev/net/tun this is the only thing that fails, and the
            // mesh is still perfectly usable through meshctl.
            Err(e) => {
                tracing::warn!(error = %e, "no tun interface; mesh is reachable via meshctl only")
            }
        }
    }

    // One second. Probing is what every path decision is made from, and the round now fans out
    // rather than walking the paths in series, so the cost of asking more often is a packet per
    // path per peer rather than a longer round.
    let interval = std::env::var("MESH_PROBE_INTERVAL_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(1);
    node.start(Duration::from_secs(interval));

    // Keep this machine's binaries current. The daemon does the CLI as well as itself: they are
    // shipped as a pair and a user expects them to match, but only the daemon runs continuously
    // enough to notice a new build. Neither takes effect until the next start; swapping a
    // running daemon out from under a working mesh to apply an update nobody asked for would be
    // a poor trade.
    if mesh_core::update::enabled_from_env() {
        let cp_url = cp_url.clone();
        tokio::spawn(async move {
            // Clear a predecessor left by a previous Windows update, now that nothing runs it.
            if let Ok(exe) = std::env::current_exe() {
                mesh_core::update::sweep_replaced_binary(&exe);
            }
            let mut ticker = tokio::time::interval(Duration::from_secs(6 * 3600));
            loop {
                ticker.tick().await;
                let Ok(exe) = std::env::current_exe() else {
                    continue;
                };
                let mut targets = vec![("meshd", exe.clone())];
                if let Some(ctl) = mesh_core::update::sibling(&exe, "meshctl") {
                    targets.push(("meshctl", ctl));
                }
                for (name, path) in targets {
                    match mesh_core::update::update_binary(&cp_url, name, &path).await {
                        Ok(mesh_core::update::Outcome::Replaced { sha256 }) => tracing::info!(
                            binary = name, %sha256,
                            "updated on disk; takes effect on the next start"
                        ),
                        Ok(o) => tracing::debug!(binary = name, ?o, "update check"),
                        Err(e) => tracing::debug!(binary = name, error = %e, "update check failed"),
                    }
                }
            }
        });
    } else {
        tracing::debug!("automatic updates are switched off");
    }

    // Adopt whichever relays failed to come up, once they can. Without this a node that started
    // during an outage would run direct-only for the rest of its life, which is exactly the
    // "recovers on its own" property the reconnect logic exists to provide; the only difference
    // here is that there was never a connection to reconnect.
    if cf_tunnel.is_none()
        && let Some(cfg) = roster.backhauls.cloudflare.clone()
    {
        let (node, state_dir, node_name) = (node.clone(), state_dir.clone(), node_name.clone());
        tokio::spawn(async move {
            let mut backoff = Duration::from_secs(5);
            loop {
                tokio::time::sleep(backoff).await;
                backoff = (backoff * 2).min(Duration::from_secs(60));
                let Ok(mut st) = NodeState::load(&state_dir) else {
                    continue;
                };
                match bring_up_cloudflare(&state_dir, &mut st, &cfg, &node_name).await {
                    Ok((t, _)) => {
                        node.install_cloudflare(Arc::new(t));
                        return;
                    }
                    Err(e) => tracing::debug!(error = %e, "cloudflare still down; will retry"),
                }
            }
        });
    }

    if ts.is_none() && roster.backhauls.tailscale_available {
        let (node, state_dir, node_name, cp) = (
            node.clone(),
            state_dir.clone(),
            node_name.clone(),
            cp.clone(),
        );
        let region = roster.derp_region;
        tokio::spawn(async move {
            let mut backoff = Duration::from_secs(5);
            loop {
                tokio::time::sleep(backoff).await;
                backoff = (backoff * 2).min(Duration::from_secs(60));
                let Ok(auth_key) = cp.tailscale_auth_key().await else {
                    continue;
                };
                match TailscaleBackhaul::connect_to_region(
                    &state_dir, &node_name, &auth_key, region,
                )
                .await
                {
                    Ok(b) => {
                        node.install_tailscale(Arc::new(b));
                        return;
                    }
                    Err(e) => tracing::debug!(error = ?e, "tailscale still down; will retry"),
                }
            }
        });
    }

    // NAT traversal: keep our reflexive address current and punch at peers we cannot reach
    // directly yet. Harmless on a flat network, where the first candidate already works.
    let mut stun_servers: Vec<SocketAddr> = roster
        .stun_servers
        .iter()
        .filter_map(|s| s.parse().ok())
        .collect();
    if stun_servers.is_empty()
        && let Ok(extra) = std::env::var("MESH_STUN_SERVERS")
    {
        stun_servers = extra
            .split(',')
            .filter_map(|s| s.trim().parse().ok())
            .collect();
    }
    if !stun_servers.is_empty() {
        tracing::info!(servers = ?stun_servers, "nat traversal enabled");
    }
    node.start_nat_traversal(stun_servers);

    // Keep the roster fresh so joins and revocations take effect without a restart.
    {
        let node = node.clone();
        let cp = cp.clone();
        let state_dir = state_dir.clone();
        // Report our measured region so the first node to poll settles it for the network.
        let region = ts.as_ref().map(|t| t.region_id);
        // Tell the control plane which Cloudflare device is ours, so removing this node can
        // remove the registration too. Nothing else knows the mapping: the node registers with
        // Cloudflare directly and the control plane never sees the exchange.
        let cf_device = state
            .cloudflare
            .as_ref()
            .map(|c| c.device_id.clone())
            .unwrap_or_default();
        let shutdown_tx = shutdown_tx.clone();
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(Duration::from_secs(30));
            // One 401 could be a control plane blip; a run of them is an eviction.
            let mut rejected = 0u32;
            ticker.tick().await;
            loop {
                ticker.tick().await;
                match cp.roster_reporting(region, Some(cf_device.as_str())).await {
                    Ok(r) => {
                        rejected = 0;
                        node.apply_roster(&r.peers).await;
                        if let Ok(mut st) = NodeState::load(&state_dir) {
                            if let Some(c) = st.control_plane.as_mut() {
                                c.peers = r.peers.clone();
                            }
                            let _ = st.save(&state_dir);
                        }
                    }
                    Err(e) if e.is_unauthorized() => {
                        // Deliberately not re-enrolling here. Rejoining on our own while
                        // running would make `remove-node` meaningless: the operator would
                        // evict a node and watch it reappear. Shutting down is what makes the
                        // eviction real; rejoining stays a deliberate act on restart.
                        rejected += 1;
                        tracing::warn!(
                            rejected,
                            "the control plane rejected our token; this node may have been removed"
                        );
                        if rejected >= REVOCATION_TOLERANCE {
                            tracing::error!(
                                "removed from the network, shutting down. Restart with \
                                 MESH_ENROLLMENT_KEY set to rejoin."
                            );
                            let _ = shutdown_tx.send(true);
                            return;
                        }
                    }
                    Err(e) => {
                        rejected = 0;
                        tracing::debug!(error = %e, "roster refresh failed");
                    }
                }
            }
        });
    }

    // Record the port we settled on, and clear the poison flag now that we have moved.
    state.direct_port = bound_port;
    state.direct_port_poisoned = false;
    state.save(&state_dir)?;

    serve(node, Instant::now(), roster.subnet.clone(), shutdown_rx).await
}

async fn bring_up_cloudflare(
    state_dir: &Path,
    state: &mut NodeState,
    cfg: &CloudflareConfig,
    node_name: &str,
) -> Result<(CloudflareBackhaul, Ipv4Addr)> {
    let team = cfg.team.clone();
    let client_id = cfg.service_client_id.clone();
    let client_secret = cfg.service_client_secret.clone();

    let cf = match state.cloudflare.clone() {
        Some(existing) => {
            tracing::info!(device = %existing.device_id, "reusing cloudflare registration");
            existing
        }
        None => {
            tracing::info!(team, "enrolling with cloudflare");
            // The JWT is good for 60 seconds, so mint it immediately before use.
            let jwt = api::enrollment_jwt(&team, &client_id, &client_secret).await?;
            let reg = api::register(Some(&jwt)).await?;
            let token = reg
                .token
                .clone()
                .ok_or_else(|| anyhow!("/reg did not return a device token"))?;
            tracing::info!(
                device = %reg.id, org = %reg.account.organization,
                "registered, enrolling masque key"
            );

            let identity = DeviceIdentity::generate()?;
            let enrolled =
                api::enroll_masque(&reg.id, &token, &identity.spki_der, Some(node_name)).await?;
            let peer = enrolled
                .config
                .peers
                .first()
                .ok_or_else(|| anyhow!("enroll response had no peers"))?;

            let cf = CloudflareState {
                device_id: enrolled.id.clone(),
                device_token: token,
                private_key: B64.encode(&identity.pkcs8_der),
                endpoint_v4: peer.endpoint.v4.clone(),
                endpoint_v6: peer.endpoint.v6.clone(),
                endpoint_ports: peer.endpoint.ports.clone(),
                endpoint_pub_key: peer.public_key.clone(),
                ipv4: enrolled.config.interface.addresses.v4.clone(),
                ipv6: enrolled.config.interface.addresses.v6.clone(),
                mesh_routes: enrolled
                    .policy
                    .include
                    .iter()
                    .map(|r| r.address.clone())
                    .filter(|s| !s.is_empty())
                    .collect(),
            };
            state.cloudflare = Some(cf.clone());
            state.save(state_dir)?;
            cf
        }
    };

    let identity = DeviceIdentity::from_pkcs8(&B64.decode(&cf.private_key)?)?;
    let ip: Ipv4Addr = cf
        .ipv4
        .split('/')
        .next()
        .unwrap_or(&cf.ipv4)
        .parse()
        .with_context(|| format!("parsing our mesh address {}", cf.ipv4))?;

    let endpoint_ip: std::net::IpAddr = cf
        .endpoint_v4
        .rsplit_once(':')
        .map(|(h, _)| h)
        .unwrap_or(&cf.endpoint_v4)
        .parse()
        .with_context(|| format!("parsing endpoint {}", cf.endpoint_v4))?;
    let spki = tunnel::parse_endpoint_pubkey(&cf.endpoint_pub_key);

    // Ports come back in preference order, 443 first in practice. Zero Trust may use a
    // different SNI than consumer and it is not documented which, so try both.
    let ports: Vec<u16> = if cf.endpoint_ports.is_empty() {
        vec![443]
    } else {
        cf.endpoint_ports.clone()
    };
    // The backhaul owns the dialling from here, because it has to redo it on every reconnect.
    let cf = CloudflareBackhaul::connect(identity, ip, endpoint_ip, ports, spki).await?;
    Ok((cf, ip))
}

/// Turn what the user typed into exactly one peer.
///
/// Node names are not unique and the default is the same string on every install, so a name can
/// genuinely match two machines. Picking one silently would send traffic to an arbitrary member
/// of the pair, which is worse than refusing: the mesh address always identifies exactly one
/// node, so the answer is to say which ones matched and let the user pick.
async fn resolve_one(
    node: &Arc<MeshNode>,
    needle: &str,
) -> Result<mesh_core::node::PeerKey, String> {
    let keys = node.resolve(needle).await;
    match keys.as_slice() {
        [one] => Ok(*one),
        [] => Err(format!("no peer called {needle}")),
        many => {
            let mut addrs = Vec::new();
            for k in many {
                if let Some(p) = node.peer(k).await {
                    addrs.push(
                        p.virtual_ip
                            .map(|i| i.to_string())
                            .unwrap_or_else(|| mesh_core::node::fingerprint(k)),
                    );
                }
            }
            Err(format!(
                "{} nodes are called {needle}; address one of them directly: {}",
                many.len(),
                addrs.join(", ")
            ))
        }
    }
}

async fn serve(
    node: Arc<MeshNode>,
    started: Instant,
    subnet: String,
    mut shutdown: tokio::sync::watch::Receiver<bool>,
) -> Result<()> {
    let endpoint = default_endpoint();
    let mut listener = Listener::bind(&endpoint).await?;
    tracing::info!(endpoint, "listening for meshctl");

    // Surface incoming application data in the daemon log too, so the demo is visible
    // without a CLI attached.
    {
        let node = node.clone();
        tokio::spawn(async move {
            while let Some((from, path, data)) = node.recv_data().await {
                tracing::info!(from, %path, msg = %String::from_utf8_lossy(&data), "data received");
            }
        });
    }

    let mut consecutive_failures = 0u32;
    loop {
        // One bad accept must not take the daemon down with it. A client that dies mid-handshake
        // is ordinary, and losing the whole node over it would also lose both backhauls and every
        // measured path. Only a persistent failure, which means the endpoint itself is gone, is
        // worth giving up on.
        let accepted = tokio::select! {
            biased;
            _ = shutdown.changed() => {
                if *shutdown.borrow() {
                    tracing::info!("shutting down");
                    return Ok(());
                }
                continue;
            }
            r = listener.accept() => r,
        };
        let stream = match accepted {
            Ok(s) => {
                consecutive_failures = 0;
                s
            }
            Err(e) => {
                consecutive_failures += 1;
                tracing::warn!(error = %e, consecutive_failures, "accepting a meshctl connection failed");
                if consecutive_failures >= 10 {
                    return Err(e).context("the control endpoint is no longer usable");
                }
                tokio::time::sleep(Duration::from_millis(200)).await;
                continue;
            }
        };
        let node = node.clone();
        let subnet = subnet.clone();
        tokio::spawn(async move {
            let (r, mut w) = tokio::io::split(stream);
            let mut reader = BufReader::new(r);
            let mut line = String::new();
            if reader.read_line(&mut line).await.is_err() || line.trim().is_empty() {
                return;
            }
            let resp = match serde_json::from_str::<Request>(line.trim()) {
                Ok(req) => handle(&node, started, &subnet, req).await,
                Err(e) => Response::Error(format!("bad request: {e}")),
            };
            let mut out = serde_json::to_string(&resp)
                .unwrap_or_else(|e| format!("{{\"Error\":\"could not serialise: {e}\"}}"));
            out.push('\n');
            let _ = w.write_all(out.as_bytes()).await;
            let _ = w.flush().await;
        });
    }
}

async fn handle(node: &Arc<MeshNode>, started: Instant, subnet: &str, req: Request) -> Response {
    match req {
        Request::Status => {
            let paths = node.available_paths();
            Response::Status(StatusReport {
                node_name: node.name.clone(),
                virtual_ip: node
                    .virtual_ip
                    .map(|i| i.to_string())
                    .unwrap_or_else(|| "-".into()),
                subnet: subnet.to_string(),
                cloudflare: paths
                    .contains(&mesh_core::PathKind::CloudflareMesh)
                    .then(|| BackhaulReport {
                        up: true,
                        address: node
                            .cf_ip()
                            .map(|i| i.to_string())
                            .unwrap_or_else(|| "-".into()),
                        detail: "connect-ip over quic".into(),
                    }),
                // Read from the node, not from whatever existed at startup: a backhaul adopted
                // later must show up here, or status quietly lies about a working path.
                tailscale: node.ts().map(|t| BackhaulReport {
                    up: true,
                    address: t
                        .self_addrs
                        .iter()
                        .map(|a| a.to_string())
                        .collect::<Vec<_>>()
                        .join(", "),
                    detail: format!("derp region {}", t.region),
                }),
                peer_count: node.peers().await.len(),
                uptime_secs: started.elapsed().as_secs(),
            })
        }
        Request::Peers => Response::Peers(
            node.peers()
                .await
                .into_iter()
                .map(|p| PeerReport {
                    name: p.name.clone(),
                    virtual_ip: p.virtual_ip.map(|i| i.to_string()),
                    cf_ip: p.cf_ip.map(|i| i.to_string()),
                    ts_hostname: p.ts_hostname.clone(),
                    best_path: p.best_path().map(|(k, _)| k.to_string()),
                    paths: p
                        .paths
                        .iter()
                        .map(|(k, s)| PathReport {
                            path: k.to_string(),
                            up: s.up(),
                            last_rtt_ms: s.last_rtt_ms,
                            ewma_ms: s.ewma_ms,
                            sent: s.sent,
                            received: s.received,
                            loss_pct: s.loss_pct(),
                        })
                        .collect(),
                })
                .collect(),
        ),
        Request::Ping { peer, count } => {
            let key = match resolve_one(node, &peer).await {
                Ok(k) => k,
                Err(e) => return Response::Error(e),
            };
            let samples = node
                .ping(&key, count.clamp(1, 100), Duration::from_secs(5))
                .await;
            Response::Ping(
                samples
                    .into_iter()
                    .map(|(path, seq, rtt)| PingSample {
                        path: path.to_string(),
                        seq,
                        rtt_ms: rtt.map(|d| d.as_secs_f64() * 1000.0),
                    })
                    .collect(),
            )
        }
        Request::Send { peer, data } => {
            let bytes = data.into_bytes();
            let n = bytes.len();
            let key = match resolve_one(node, &peer).await {
                Ok(k) => k,
                Err(e) => return Response::Error(e),
            };
            match node.send_data(&key, bytes).await {
                Ok(path) => Response::Sent {
                    path: path.to_string(),
                    bytes: n,
                },
                Err(e) => Response::Error(e.to_string()),
            }
        }
    }
}
