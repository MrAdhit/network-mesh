//! meshd: brings up both backhauls, races them, and answers meshctl.

use anyhow::{Context, Result, anyhow};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use mesh_core::cloudflare::{DeviceIdentity, MasqueTunnel, TunnelConfig, api, tunnel};
use mesh_core::ipc::{
    BackhaulReport, PathReport, PeerReport, PingSample, Request, Response, StatusReport,
    default_socket_path,
};
use mesh_core::cp::CloudflareConfig;
use mesh_core::cpclient::{CpClient, NodeIdentity};
use mesh_core::direct::DirectTransport;
use mesh_core::node::MeshNode;
use mesh_core::state::{Bootstrap, CloudflareState, ControlPlaneState, NodeState, default_state_dir};
use mesh_core::tailscale::TailscaleBackhaul;
use std::net::{Ipv4Addr, SocketAddr};
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

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
    let cp_url = boot
        .cp_url
        .clone()
        .or_else(|| state.control_plane.as_ref().map(|c| c.url.clone()))
        .ok_or_else(|| anyhow!("MESH_CP_URL is not set and this node has never enrolled"))?;

    if state.control_plane.is_none() {
        let key = boot.enrollment_key.clone().ok_or_else(|| {
            anyhow!("this node has not enrolled yet; set MESH_ENROLLMENT_KEY to join a network")
        })?;
        let client = CpClient::new(&cp_url)?;
        let resp = client.enroll(&key, &identity, &node_name).await?;
        tracing::info!(
            node_id = %resp.node_id, ip = %resp.virtual_ip, subnet = %resp.subnet,
            "enrolled with the control plane"
        );
        state.control_plane = Some(ControlPlaneState {
            url: cp_url.clone(),
            node_id: resp.node_id,
            node_token: resp.node_token,
            virtual_ip: resp.virtual_ip,
            subnet: resp.subnet,
            peers: Vec::new(),
        });
        state.save(&state_dir)?;
    }

    let cp_state = state.control_plane.clone().expect("just enrolled");
    let cp = Arc::new(CpClient::new(&cp_url)?.with_token(cp_state.node_token.clone()));

    // A stale roster beats no mesh at all, so a control plane outage is survivable.
    let (roster, fresh) = match cp.roster().await {
        Ok(r) => (r, true),
        Err(e) => {
            tracing::warn!(error = %e, "control plane unreachable; using the cached roster");
            (
                mesh_core::cp::Roster {
                    subnet: cp_state.subnet.clone(),
                    stun_servers: Vec::new(),
                    derp_region: None,
                    self_virtual_ip: cp_state.virtual_ip.clone(),
                    peers: cp_state.peers.clone(),
                    backhauls: Default::default(),
                },
                false,
            )
        }
    };
    if fresh {
        if let Some(c) = state.control_plane.as_mut() {
            c.peers = roster.peers.clone();
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
    let mut cf_tunnel: Option<Arc<MasqueTunnel>> = None;
    let mut cf_ip: Option<Ipv4Addr> = None;
    match roster.backhauls.cloudflare.clone() {
        Some(cfg) => match bring_up_cloudflare(&state_dir, &mut state, &cfg, &node_name).await {
            Ok((t, ip)) => {
                cf_tunnel = Some(Arc::new(t));
                cf_ip = Some(ip);
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

    if cf_tunnel.is_none() && ts.is_none() {
        return Err(anyhow!("no backhaul came up; nothing to do"));
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
    let node = MeshNode::new(
        node_name.clone(),
        identity.public_bytes(),
        cf_tunnel,
        cf_ip,
        ts.clone(),
        direct,
        Some(virtual_ip),
    );
    node.apply_roster(&roster.peers).await;

    // Bring up the kernel interface last, once we know our address and have paths to use.
    #[cfg(target_os = "linux")]
    if std::env::var("MESH_TUN").map(|v| v != "0").unwrap_or(true) {
        let name = std::env::var("MESH_TUN_NAME").unwrap_or_else(|_| "mesh0".into());
        match mesh_core::tun::TunDevice::open(&name, virtual_ip, &roster.subnet) {
            Ok(dev) => node.attach_tun(Arc::new(dev)).await,
            // Without CAP_NET_ADMIN or /dev/net/tun this is the only thing that fails, and the
            // mesh is still perfectly usable through meshctl.
            Err(e) => tracing::warn!(error = %e, "no tun interface; mesh is reachable via meshctl only"),
        }
    }

    let interval = std::env::var("MESH_PROBE_INTERVAL_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(2);
    node.start(Duration::from_secs(interval));

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
        stun_servers = extra.split(',').filter_map(|s| s.trim().parse().ok()).collect();
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
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(Duration::from_secs(30));
            ticker.tick().await;
            loop {
                ticker.tick().await;
                match cp.roster_reporting(region).await {
                    Ok(r) => {
                        node.apply_roster(&r.peers).await;
                        if let Ok(mut st) = NodeState::load(&state_dir) {
                            if let Some(c) = st.control_plane.as_mut() {
                                c.peers = r.peers.clone();
                            }
                            let _ = st.save(&state_dir);
                        }
                    }
                    Err(e) => tracing::debug!(error = %e, "roster refresh failed"),
                }
            }
        });
    }

    // Record the port we settled on, and clear the poison flag now that we have moved.
    state.direct_port = bound_port;
    state.direct_port_poisoned = false;
    state.save(&state_dir)?;

    serve(node, ts, Instant::now(), roster.subnet.clone()).await
}

async fn bring_up_cloudflare(
    state_dir: &Path,
    state: &mut NodeState,
    cfg: &CloudflareConfig,
    node_name: &str,
) -> Result<(MasqueTunnel, Ipv4Addr)> {
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
    let mut last_err = None;
    for sni in [tunnel::SNI_ZERO_TRUST, tunnel::SNI_CONSUMER] {
        for port in ports.iter().take(3) {
            let cfg = TunnelConfig {
                endpoint: SocketAddr::new(endpoint_ip, *port),
                sni: sni.to_string(),
                endpoint_spki: spki.clone(),
            };
            match MasqueTunnel::connect(&identity, &cfg).await {
                Ok(t) => {
                    tracing::info!(sni, port, "masque connected");
                    return Ok((t, ip));
                }
                Err(e) => {
                    tracing::warn!(sni, port, error = %e, "masque attempt failed");
                    last_err = Some(e);
                }
            }
        }
    }
    Err(last_err.unwrap_or_else(|| anyhow!("no masque endpoint was reachable")))
}

async fn serve(
    node: Arc<MeshNode>,
    ts: Option<Arc<TailscaleBackhaul>>,
    started: Instant,
    subnet: String,
) -> Result<()> {
    let sock = default_socket_path();
    let _ = std::fs::remove_file(&sock);
    if let Some(dir) = sock.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let listener = tokio::net::UnixListener::bind(&sock)
        .with_context(|| format!("binding {}", sock.display()))?;
    tracing::info!(socket = %sock.display(), "listening for meshctl");

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

    loop {
        let (stream, _) = listener.accept().await?;
        let node = node.clone();
        let ts = ts.clone();
        let subnet = subnet.clone();
        tokio::spawn(async move {
            let (r, mut w) = stream.into_split();
            let mut reader = BufReader::new(r);
            let mut line = String::new();
            if reader.read_line(&mut line).await.is_err() || line.trim().is_empty() {
                return;
            }
            let resp = match serde_json::from_str::<Request>(line.trim()) {
                Ok(req) => handle(&node, ts.as_deref(), started, &subnet, req).await,
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

async fn handle(
    node: &Arc<MeshNode>,
    ts: Option<&TailscaleBackhaul>,
    started: Instant,
    subnet: &str,
    req: Request,
) -> Response {
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
                        address: node.cf_ip.map(|i| i.to_string()).unwrap_or_else(|| "-".into()),
                        detail: "connect-ip over quic".into(),
                    }),
                tailscale: ts.map(|t| BackhaulReport {
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
            let samples = node
                .ping(&peer, count.clamp(1, 100), Duration::from_secs(5))
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
            match node.send_data(&peer, bytes).await {
                Ok(path) => Response::Sent {
                    path: path.to_string(),
                    bytes: n,
                },
                Err(e) => Response::Error(e.to_string()),
            }
        }
    }
}
