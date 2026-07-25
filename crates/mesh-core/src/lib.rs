//! Core of the multipath mesh client: backhaul enrollment, tunnels, path racing.

pub mod cloudflare;
pub mod cp;
pub mod cpclient;
pub mod direct;
pub mod ip;
pub mod ipc;
pub mod nat;
pub mod node;
pub mod proto;
pub mod state;
pub mod stun;
pub mod tailscale;
#[cfg(any(target_os = "linux", target_os = "macos", target_os = "windows"))]
pub mod tun;
pub mod util;

pub use node::{MeshNode, PathStats, PeerState};
pub use proto::PathKind;
pub use state::{Bootstrap, NodeState};
