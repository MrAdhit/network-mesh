//! meshcp: the mesh control plane.
//!
//! Owns accounts, subnets, node identity, address allocation and the users' backhaul
//! credentials. Nodes enroll here once and then poll for the roster.

mod crypto;
mod db;
mod installer;
mod provision;
mod updates;

use anyhow::Result;
use axum::{
    Json, Router,
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    routing::{delete, get, post, put},
};
use db::Db;
use mesh_core::cp::*;
use mesh_core::util::now_unix;
use std::sync::Arc;

const CRED_CLOUDFLARE: &str = "cloudflare";
const CRED_TAILSCALE: &str = "tailscale";
const SESSION_TTL_SECS: i64 = 30 * 24 * 3600;
const ENROLLMENT_KEY_TTL_SECS: i64 = 90 * 24 * 3600;

struct App {
    db: Db,
    sealer: crypto::Sealer,
}

type Ctx = State<Arc<App>>;

/// Errors carry a message meant for a human staring at a CLI, not a status code alone.
struct Fail(StatusCode, String);

impl axum::response::IntoResponse for Fail {
    fn into_response(self) -> axum::response::Response {
        (self.0, Json(ApiError { error: self.1 })).into_response()
    }
}

fn bad(msg: impl std::fmt::Display) -> Fail {
    Fail(StatusCode::BAD_REQUEST, msg.to_string())
}
fn unauthorized(msg: &str) -> Fail {
    Fail(StatusCode::UNAUTHORIZED, msg.to_string())
}
fn internal(e: impl std::fmt::Display) -> Fail {
    Fail(StatusCode::INTERNAL_SERVER_ERROR, e.to_string())
}

type Reply<T> = std::result::Result<Json<T>, Fail>;

fn header<'a>(h: &'a HeaderMap, name: &str) -> Option<&'a str> {
    h.get(name).and_then(|v| v.to_str().ok())
}

fn account_from_session(app: &App, h: &HeaderMap) -> std::result::Result<db::Account, Fail> {
    let token = header(h, SESSION_HEADER).ok_or_else(|| unauthorized("no session token"))?;
    app.db
        .account_for_session(token)
        .map_err(internal)?
        .ok_or_else(|| unauthorized("session is invalid or expired"))
}

fn node_from_token(app: &App, h: &HeaderMap) -> std::result::Result<db::Node, Fail> {
    let token = header(h, NODE_TOKEN_HEADER).ok_or_else(|| unauthorized("no node token"))?;
    app.db
        .node_by_token(token)
        .map_err(internal)?
        .ok_or_else(|| unauthorized("node token is not recognised"))
}

// ---- human facing ----

async fn signup(State(app): Ctx, Json(req): Json<SignupRequest>) -> Reply<SessionResponse> {
    if req.email.trim().is_empty() || !req.email.contains('@') {
        return Err(bad("that does not look like an email address"));
    }
    if req.password.len() < 8 {
        return Err(bad("password must be at least 8 characters"));
    }
    let subnet = req.subnet.unwrap_or_else(|| db::DEFAULT_SUBNET.to_string());
    db::validate_subnet(&subnet).map_err(bad)?;

    let hash = crypto::hash_password(&req.password).map_err(internal)?;
    let account = app
        .db
        .create_account(req.email.trim(), &hash, &subnet)
        .map_err(bad)?;
    let (session, expires_at) = app
        .db
        .create_session(&account.id, SESSION_TTL_SECS)
        .map_err(internal)?;
    tracing::info!(email = %account.email, subnet = %subnet, "account created");
    Ok(Json(SessionResponse {
        session_token: session,
        account_id: account.id,
        expires_at,
    }))
}

async fn login(State(app): Ctx, Json(req): Json<LoginRequest>) -> Reply<SessionResponse> {
    let account = app
        .db
        .account_by_email(req.email.trim())
        .map_err(internal)?
        .ok_or_else(|| unauthorized("no account with that email, or the password is wrong"))?;
    if !crypto::verify_password(&req.password, &account.password_hash) {
        return Err(unauthorized(
            "no account with that email, or the password is wrong",
        ));
    }
    let (session, expires_at) = app
        .db
        .create_session(&account.id, SESSION_TTL_SECS)
        .map_err(internal)?;
    Ok(Json(SessionResponse {
        session_token: session,
        account_id: account.id,
        expires_at,
    }))
}

async fn get_network(State(app): Ctx, headers: HeaderMap) -> Reply<NetworkView> {
    let account = account_from_session(&app, &headers)?;
    let nodes = app.db.nodes(&account.id).map_err(internal)?;
    let net: ipnet::Ipv4Net = account.subnet.parse().map_err(internal)?;
    // network address and .1 are never handed out
    let capacity = (u32::from(net.broadcast()) - u32::from(net.network())).saturating_sub(2);

    let cf = app
        .db
        .get_cred(&account.id, CRED_CLOUDFLARE)
        .map_err(internal)?;
    let ts = app
        .db
        .get_cred(&account.id, CRED_TAILSCALE)
        .map_err(internal)?;

    Ok(Json(NetworkView {
        account_id: account.id.clone(),
        email: account.email.clone(),
        subnet: account.subnet.clone(),
        node_count: nodes.len(),
        addresses_used: nodes.len(),
        addresses_available: capacity as usize - nodes.len().min(capacity as usize),
        cloudflare: BackhaulStatus {
            configured: cf.is_some(),
            detail: cf
                .map(|(_, m)| m)
                .unwrap_or_else(|| "not configured".into()),
        },
        tailscale: BackhaulStatus {
            configured: ts.is_some(),
            detail: ts
                .map(|(_, m)| m)
                .unwrap_or_else(|| "not configured".into()),
        },
    }))
}

async fn set_subnet(
    State(app): Ctx,
    headers: HeaderMap,
    Json(req): Json<SetSubnetRequest>,
) -> Reply<NetworkView> {
    let account = account_from_session(&app, &headers)?;
    db::validate_subnet(&req.subnet).map_err(bad)?;
    app.db.set_subnet(&account.id, &req.subnet).map_err(bad)?;
    get_network(State(app), headers).await
}

async fn set_cloudflare(
    State(app): Ctx,
    headers: HeaderMap,
    Json(req): Json<CloudflareCredsRequest>,
) -> Reply<BackhaulStatus> {
    let account = account_from_session(&app, &headers)?;
    // Provision immediately so a bad token surfaces now rather than at some node's enrollment.
    let provisioned = provision::provision_cloudflare(&req.api_token, &req.account_id)
        .await
        .map_err(bad)?;

    let payload = serde_json::json!({
        "api_token": req.api_token,
        "account_id": req.account_id,
        "team": provisioned.team,
        "service_client_id": provisioned.service_client_id,
        "service_client_secret": provisioned.service_client_secret,
    });
    let sealed = app.sealer.seal(&payload.to_string()).map_err(internal)?;
    let meta = format!("team {}, service token provisioned", provisioned.team);
    app.db
        .put_cred(&account.id, CRED_CLOUDFLARE, &sealed, &meta)
        .map_err(internal)?;
    tracing::info!(account = %account.id, team = %provisioned.team, "cloudflare provisioned");

    Ok(Json(BackhaulStatus {
        configured: true,
        detail: meta,
    }))
}

async fn set_tailscale(
    State(app): Ctx,
    headers: HeaderMap,
    Json(req): Json<TailscaleCredsRequest>,
) -> Reply<BackhaulStatus> {
    let account = account_from_session(&app, &headers)?;
    let detail = provision::verify_tailscale(&req.api_token)
        .await
        .map_err(bad)?;

    let payload = serde_json::json!({ "api_token": req.api_token });
    let sealed = app.sealer.seal(&payload.to_string()).map_err(internal)?;
    app.db
        .put_cred(&account.id, CRED_TAILSCALE, &sealed, &detail)
        .map_err(internal)?;
    tracing::info!(account = %account.id, "tailscale credentials stored");

    Ok(Json(BackhaulStatus {
        configured: true,
        detail,
    }))
}

async fn mint_enrollment_key(State(app): Ctx, headers: HeaderMap) -> Reply<NewEnrollmentKey> {
    let account = account_from_session(&app, &headers)?;
    let (key, expires) = app
        .db
        .create_enrollment_key(&account.id, ENROLLMENT_KEY_TTL_SECS)
        .map_err(internal)?;
    Ok(Json(NewEnrollmentKey {
        key,
        expires_at: db::timestamp_string(expires),
    }))
}

async fn list_nodes(State(app): Ctx, headers: HeaderMap) -> Reply<Vec<NodeView>> {
    let account = account_from_session(&app, &headers)?;
    let nodes = app.db.nodes(&account.id).map_err(internal)?;
    Ok(Json(nodes.into_iter().map(node_view).collect()))
}

async fn remove_node(
    State(app): Ctx,
    headers: HeaderMap,
    Path(node_id): Path<String>,
) -> Reply<serde_json::Value> {
    let account = account_from_session(&app, &headers)?;
    forget_node(&app, &account.id, &node_id).await
}

/// A node removing itself, authenticated by its own node token.
///
/// Separate from `remove_node` because the credentials differ, and the difference is the point:
/// uninstalling happens on the machine, which holds a node token and not an account session.
/// Without this a wiped machine would leave a roster entry holding an address forever.
///
/// A node can only ever remove itself, so there is nothing to authorise beyond recognising the
/// token.
async fn remove_self(State(app): Ctx, headers: HeaderMap) -> Reply<serde_json::Value> {
    let me = node_from_token(&app, &headers)?;
    tracing::info!(node = %me.id, name = %me.name, "node is deregistering itself");
    forget_node(&app, &me.account_id, &me.id).await
}

async fn forget_node(app: &App, account_id: &str, node_id: &str) -> Reply<serde_json::Value> {
    // Read the device before the row goes, since afterwards there is nothing left to ask.
    let device = app.db.cf_device_of(account_id, node_id).map_err(internal)?;
    let removed = app.db.delete_node(account_id, node_id).map_err(internal)?;
    if !removed {
        return Err(bad("no such node"));
    }
    // Best effort, and deliberately after the removal has already succeeded. The node is gone
    // from the mesh either way; a Cloudflare API that is slow or unhappy should not turn a
    // successful removal into an error the operator has to retry.
    let mut device_removed = false;
    if let Some(device) = device
        && let Ok(Some((sealed, _))) = app.db.get_cred(account_id, CRED_CLOUDFLARE)
        && let Ok(json) = app.sealer.open(&sealed)
        && let Ok(v) = serde_json::from_str::<serde_json::Value>(&json)
    {
        let token = v["api_token"].as_str().unwrap_or_default();
        let cf_account = v["account_id"].as_str().unwrap_or_default();
        match provision::delete_cloudflare_device(token, cf_account, &device).await {
            Ok(()) => {
                tracing::info!(node = %node_id, %device, "cloudflare device removed");
                device_removed = true;
            }
            Err(e) => {
                tracing::warn!(node = %node_id, %device, error = %e, "could not remove the cloudflare device")
            }
        }
    }
    Ok(Json(
        serde_json::json!({ "removed": node_id, "cloudflare_device_removed": device_removed }),
    ))
}

fn node_view(n: db::Node) -> NodeView {
    let online = n.online();
    NodeView {
        node_id: n.id,
        name: n.name,
        virtual_ip: n.virtual_ip,
        public_key: n.public_key,
        created_at: n.created_at,
        last_seen: n.last_seen.map(db::timestamp_string),
        online,
    }
}

// ---- node facing ----

async fn enroll(State(app): Ctx, Json(req): Json<EnrollRequest>) -> Reply<EnrollResponse> {
    let account_id = app
        .db
        .account_for_enrollment_key(&req.enrollment_key)
        .map_err(internal)?
        .ok_or_else(|| unauthorized("enrollment key is unknown or expired"))?;

    if req.public_key.trim().is_empty() {
        return Err(bad("a node must present a public key"));
    }
    let (node, token) = app
        .db
        .enroll_node(&account_id, &req.name, &req.public_key)
        .map_err(internal)?;
    let account = app
        .db
        .account_by_id(&account_id)
        .map_err(internal)?
        .ok_or_else(|| internal("account vanished"))?;

    tracing::info!(node = %node.id, name = %node.name, ip = %node.virtual_ip, "node enrolled");
    Ok(Json(EnrollResponse {
        node_id: node.id,
        node_token: token,
        virtual_ip: node.virtual_ip,
        subnet: account.subnet,
    }))
}

#[derive(serde::Deserialize)]
struct RosterQuery {
    /// The DERP region this node measured as closest. Only used if nothing is agreed yet.
    #[serde(default)]
    derp: Option<u32>,
    /// The Cloudflare device this node registered for itself. A node registers directly with
    /// Cloudflare, so this is the only way the control plane learns which device is whose, and
    /// without it removing a node would leak the registration forever.
    #[serde(default)]
    cf_device: Option<String>,
}

async fn roster(
    State(app): Ctx,
    headers: HeaderMap,
    axum::extract::Query(q): axum::extract::Query<RosterQuery>,
) -> Reply<Roster> {
    let me = node_from_token(&app, &headers)?;
    app.db.touch_node(&me.id).map_err(internal)?;
    if let Some(region) = q.derp {
        app.db
            .set_derp_region_if_unset(&me.account_id, region)
            .map_err(internal)?;
    }
    if let Some(device) = q.cf_device.as_deref().filter(|d| !d.is_empty()) {
        app.db.set_cf_device(&me.id, device).map_err(internal)?;
    }

    let account = app
        .db
        .account_by_id(&me.account_id)
        .map_err(internal)?
        .ok_or_else(|| internal("account vanished"))?;

    let peers = app
        .db
        .nodes(&me.account_id)
        .map_err(internal)?
        .into_iter()
        .filter(|n| n.id != me.id)
        .map(|n| RosterPeer {
            node_id: n.id,
            name: n.name,
            virtual_ip: n.virtual_ip,
            public_key: n.public_key,
        })
        .collect();

    let cloudflare = match app
        .db
        .get_cred(&me.account_id, CRED_CLOUDFLARE)
        .map_err(internal)?
    {
        Some((sealed, _)) => {
            let json = app.sealer.open(&sealed).map_err(internal)?;
            let v: serde_json::Value = serde_json::from_str(&json).map_err(internal)?;
            // Deliberately excludes api_token: a node never needs account-level access.
            Some(CloudflareConfig {
                team: v["team"].as_str().unwrap_or_default().to_string(),
                service_client_id: v["service_client_id"]
                    .as_str()
                    .unwrap_or_default()
                    .to_string(),
                service_client_secret: v["service_client_secret"]
                    .as_str()
                    .unwrap_or_default()
                    .to_string(),
            })
        }
        None => None,
    };

    let tailscale_available = app
        .db
        .get_cred(&me.account_id, CRED_TAILSCALE)
        .map_err(internal)?
        .is_some();

    Ok(Json(Roster {
        subnet: account.subnet,
        derp_region: account.derp_region,
        stun_servers: std::env::var("MESH_CP_STUN_ADVERTISE")
            .unwrap_or_default()
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .collect(),
        self_virtual_ip: me.virtual_ip,
        peers,
        backhauls: BackhaulConfig {
            cloudflare,
            tailscale_available,
        },
    }))
}

async fn tailscale_auth_key(State(app): Ctx, headers: HeaderMap) -> Reply<TailscaleAuthKey> {
    let me = node_from_token(&app, &headers)?;
    let (sealed, _) = app
        .db
        .get_cred(&me.account_id, CRED_TAILSCALE)
        .map_err(internal)?
        .ok_or_else(|| bad("this network has no Tailscale credentials configured"))?;
    let json = app.sealer.open(&sealed).map_err(internal)?;
    let v: serde_json::Value = serde_json::from_str(&json).map_err(internal)?;
    let api_token = v["api_token"].as_str().unwrap_or_default();

    let key = provision::mint_tailscale_auth_key(api_token)
        .await
        .map_err(internal)?;
    tracing::info!(node = %me.id, "minted a tailscale auth key");
    Ok(Json(TailscaleAuthKey { auth_key: key }))
}

/// Answer STUN binding requests so nodes can learn their own reflexive address.
///
/// The control plane is the natural place for this: every node already talks to it, and it sits
/// outside whatever NAT the nodes are behind. It also sidesteps UDP 3478 being blocked outbound
/// on some networks, which rules out Tailscale's DERP STUN as the only option.
async fn run_stun_server(bind: String) -> Result<()> {
    let sock = tokio::net::UdpSocket::bind(&bind).await?;
    tracing::info!(%bind, "stun responder listening");
    let mut buf = vec![0u8; 1024];
    loop {
        let (n, from) = match sock.recv_from(&mut buf).await {
            Ok(v) => v,
            Err(e) => {
                tracing::warn!(error = %e, "stun recv failed");
                continue;
            }
        };
        let Some(txid) = mesh_core::stun::parse_binding_request(&buf[..n]) else {
            continue; // not STUN, ignore rather than answer
        };
        let resp = mesh_core::stun::binding_response(&txid, from);
        if let Err(e) = sock.send_to(&resp, from).await {
            tracing::debug!(error = %e, %from, "stun reply failed");
        } else {
            tracing::debug!(%from, "told a node where we see it");
        }
    }
}

async fn health() -> Json<serde_json::Value> {
    Json(serde_json::json!({ "ok": true, "now": now_unix() }))
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("MESH_LOG")
                .unwrap_or_else(|_| "info,meshcp=debug".into()),
        )
        .init();

    let path = std::env::var("MESH_CP_DB").unwrap_or_else(|_| "/var/lib/meshcp/meshcp.db".into());
    if let Some(dir) = std::path::Path::new(&path).parent() {
        std::fs::create_dir_all(dir)?;
    }
    let app = Arc::new(App {
        db: Db::open(&path)?,
        sealer: crypto::Sealer::from_env(),
    });

    let router = Router::new()
        .route("/health", get(health))
        .route("/v1/accounts", post(signup))
        .route("/v1/sessions", post(login))
        .route("/v1/network", get(get_network).patch(set_subnet))
        .route("/v1/network/backhauls/cloudflare", put(set_cloudflare))
        .route("/v1/network/backhauls/tailscale", put(set_tailscale))
        .route("/v1/enrollment-keys", post(mint_enrollment_key))
        .route("/v1/nodes", get(list_nodes))
        .route("/v1/nodes/{node_id}", delete(remove_node))
        // Node facing, and above the parameterised route so `me` is not read as an id.
        .route("/v1/nodes/me", delete(remove_self))
        .route("/v1/enroll", post(enroll))
        .route("/v1/roster", get(roster))
        .route("/v1/nodes/me/tailscale-auth-key", post(tailscale_auth_key))
        // Unauthenticated on purpose; see the module comment.
        .route("/v1/updates/{target}", get(updates::manifest))
        .route("/v1/updates/{target}/{name}", get(updates::download))
        // The one-liner install, pointed at whichever host the user reached us on.
        .route("/install.sh", get(installer::install))
        .route("/uninstall.sh", get(installer::uninstall))
        .with_state(app);

    // Two responders on different ports. A node compares what each reports: same port from both
    // means the NAT assigns per source, different ports mean it assigns per destination, and
    // that difference is what makes prediction possible or pointless.
    for var in ["MESH_CP_STUN_BIND", "MESH_CP_STUN_BIND2"] {
        let default = if var.ends_with('2') {
            "0.0.0.0:3479"
        } else {
            "0.0.0.0:3478"
        };
        let bind = std::env::var(var).unwrap_or_else(|_| default.into());
        tokio::spawn(async move {
            if let Err(e) = run_stun_server(bind).await {
                tracing::error!(error = %e, "stun responder stopped");
            }
        });
    }

    let bind = std::env::var("MESH_CP_BIND").unwrap_or_else(|_| "0.0.0.0:8080".into());
    let listener = tokio::net::TcpListener::bind(&bind).await?;
    tracing::info!(%bind, db = %path, updates = %updates::describe(), "control plane listening");
    axum::serve(listener, router).await?;
    Ok(())
}
