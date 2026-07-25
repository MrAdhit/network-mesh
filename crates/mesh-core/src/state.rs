//! On-disk node state.
//!
//! Plaintext, deliberately: this is an MVP and the threat model is "none yet". Everything in
//! here is a credential, so it is one file that is easy to find and delete later when we do
//! care.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub fn default_state_dir() -> PathBuf {
    if let Ok(v) = std::env::var("MESH_STATE_DIR")
        && !v.is_empty()
    {
        return PathBuf::from(v);
    }
    #[cfg(windows)]
    {
        // ProgramData is the machine-wide equivalent, and meshd runs elevated anyway.
        let base = std::env::var("ProgramData").unwrap_or_else(|_| r"C:\ProgramData".to_string());
        PathBuf::from(base).join("mesh")
    }
    #[cfg(not(windows))]
    {
        PathBuf::from("/var/lib/mesh")
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct NodeState {
    #[serde(default)]
    pub node_name: String,
    #[serde(default)]
    pub cloudflare: Option<CloudflareState>,
    #[serde(default)]
    pub tailscale: Option<TailscaleState>,
    #[serde(default)]
    pub control_plane: Option<ControlPlaneState>,
    /// The UDP port the direct path last used, and whether the NAT stopped preserving it.
    ///
    /// A port-preserving NAT starts allocating randomly once something probes the port from
    /// outside before we have bound it, and that state outlives our process. Remembering which
    /// port went bad lets the next start pick a clean one instead of inheriting the problem.
    #[serde(default)]
    pub direct_port: Option<u16>,
    #[serde(default)]
    pub direct_port_poisoned: bool,
}

/// What the control plane told us about ourselves. Cached so a node keeps working while the
/// control plane is unreachable; only joining a network needs it to be up.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ControlPlaneState {
    pub url: String,
    pub node_id: String,
    pub node_token: String,
    pub virtual_ip: String,
    pub subnet: String,
    /// Last roster we successfully fetched.
    #[serde(default)]
    pub peers: Vec<crate::cp::RosterPeer>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CloudflareState {
    pub device_id: String,
    pub device_token: String,
    /// PKCS#8 DER, base64. The data-plane credential.
    pub private_key: String,
    pub endpoint_v4: String,
    pub endpoint_v6: String,
    pub endpoint_ports: Vec<u16>,
    pub endpoint_pub_key: String,
    pub ipv4: String,
    pub ipv6: String,
    /// The org's Mesh ranges, read off policy.include rather than assumed.
    #[serde(default)]
    pub mesh_routes: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TailscaleState {
    pub node_name: String,
    #[serde(default)]
    pub addresses: Vec<String>,
    /// Machine key, base64 PKCS#8-ish blob as persisted by ts_keys.
    #[serde(default)]
    pub keys: Option<String>,
}

impl NodeState {
    pub fn path(dir: &Path) -> PathBuf {
        dir.join("state.json")
    }

    pub fn load(dir: &Path) -> Result<Self> {
        let p = Self::path(dir);
        if !p.exists() {
            return Ok(Self::default());
        }
        let s = std::fs::read_to_string(&p).with_context(|| format!("reading {}", p.display()))?;
        serde_json::from_str(&s).with_context(|| format!("parsing {}", p.display()))
    }

    pub fn save(&self, dir: &Path) -> Result<()> {
        std::fs::create_dir_all(dir)?;
        let p = Self::path(dir);
        let tmp = p.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_vec_pretty(self)?)?;
        std::fs::rename(&tmp, &p)?;
        Ok(())
    }
}

/// Credentials supplied by the user, from env or the CLI.
/// What the operator supplies on the command line or in the environment.
///
/// Backhaul credentials used to live here. They now come from the control plane, so a node only
/// needs to know where that is and how to prove it may join.
#[derive(Debug, Clone, Default)]
pub struct Bootstrap {
    pub cp_url: Option<String>,
    pub enrollment_key: Option<String>,
}

impl Bootstrap {
    pub fn from_env() -> Self {
        let get = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
        Self {
            cp_url: get("MESH_CP_URL"),
            enrollment_key: get("MESH_ENROLLMENT_KEY"),
        }
    }
}
