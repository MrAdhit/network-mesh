//! Wire types shared between the control plane and the nodes that talk to it.
//!
//! Lives in `mesh-core` so `meshcp` and `meshd` cannot drift apart.

use serde::{Deserialize, Serialize};

pub const NODE_TOKEN_HEADER: &str = "x-mesh-node-token";
pub const SESSION_HEADER: &str = "x-mesh-session";

// ---- node facing ----

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EnrollRequest {
    pub enrollment_key: String,
    /// Base64 Ed25519 public key. Doubles as the node's mesh membership identity.
    pub public_key: String,
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EnrollResponse {
    pub node_id: String,
    pub node_token: String,
    /// The address this node owns for the life of its record.
    pub virtual_ip: String,
    pub subnet: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Roster {
    pub subnet: String,
    /// Where to send STUN binding requests. Two or more distinct servers, because one
    /// observation cannot distinguish a NAT that assigns per destination from one that does not.
    #[serde(default)]
    pub stun_servers: Vec<String>,
    /// The DERP region every node in this network uses.
    ///
    /// It has to be the same one for all of them. A DERP server only relays between clients
    /// connected to it, so two nodes that each picked their own nearest region cannot reach
    /// each other at all. The first node to report a measurement sets it.
    #[serde(default)]
    pub derp_region: Option<u32>,
    pub self_virtual_ip: String,
    pub peers: Vec<RosterPeer>,
    /// What this node needs to bring its backhauls up. Never contains an account-level token.
    pub backhauls: BackhaulConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RosterPeer {
    pub node_id: String,
    pub name: String,
    pub virtual_ip: String,
    pub public_key: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BackhaulConfig {
    pub cloudflare: Option<CloudflareConfig>,
    /// Present when the account has a Tailscale token; the key itself is fetched separately so
    /// a node that gets reaped can ask for a fresh one without re-enrolling.
    pub tailscale_available: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CloudflareConfig {
    pub team: String,
    pub service_client_id: String,
    pub service_client_secret: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TailscaleAuthKey {
    pub auth_key: String,
}

// ---- human facing ----

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignupRequest {
    pub email: String,
    pub password: String,
    /// Optional at signup; defaults to 10.201.0.0/16.
    #[serde(default)]
    pub subnet: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoginRequest {
    pub email: String,
    pub password: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionResponse {
    pub session_token: String,
    pub account_id: String,
    /// Unix seconds. Lets the CLI report an expired session as expired rather than passing on
    /// the 401 it would otherwise get on the next command. Defaulted so a newer CLI still works
    /// against a control plane that predates the field.
    #[serde(default)]
    pub expires_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetworkView {
    pub account_id: String,
    pub email: String,
    pub subnet: String,
    pub node_count: usize,
    pub addresses_used: usize,
    pub addresses_available: usize,
    pub cloudflare: BackhaulStatus,
    pub tailscale: BackhaulStatus,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BackhaulStatus {
    pub configured: bool,
    /// Human-readable, never a secret.
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SetSubnetRequest {
    pub subnet: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CloudflareCredsRequest {
    pub api_token: String,
    pub account_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TailscaleCredsRequest {
    pub api_token: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NewEnrollmentKey {
    pub key: String,
    pub expires_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NodeView {
    pub node_id: String,
    pub name: String,
    pub virtual_ip: String,
    pub public_key: String,
    pub created_at: String,
    pub last_seen: Option<String>,
    pub online: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApiError {
    pub error: String,
}
