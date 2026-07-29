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
    /// The backhaul configuration that came with it.
    ///
    /// Cached for the same reason the peers are: a node that restarts while the control plane is
    /// unreachable has to come up on what it already knows. Without this it would forget how to
    /// reach its backhauls at all, and could never retry them until someone restarted it at a
    /// moment the control plane happened to be up.
    #[serde(default)]
    pub backhauls: crate::cp::BackhaulConfig,
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
        // Restricted under the temporary name, so the file never exists at the target path
        // readable by anyone but us.
        crate::util::restrict(&tmp)?;
        std::fs::rename(&tmp, &p)?;
        Ok(())
    }
}

/// Credentials supplied by the user, from env or the CLI.
/// The control plane a binary was built to talk to, if it was built for a particular one.
///
/// Set `MESH_CP_URL` when compiling and it is baked in, so a downloaded binary knows where to
/// enrol with no configuration at all. Left unset it is `None`, which is what local development
/// builds want. Runtime environment still wins over it either way; see `resolve_cp_url`.
pub const COMPILED_CP_URL: Option<&str> = option_env!("MESH_CP_URL");

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

    /// The environment, then a key an installer left in the state directory.
    ///
    /// The file exists for unattended installs, where there is no shell to export a variable in
    /// and no operator to run `meshctl join`. It is read once and deleted on a successful join;
    /// see [`consume_enrollment_key`].
    pub fn load(state_dir: &Path) -> Self {
        let mut boot = Self::from_env();
        if boot.enrollment_key.is_none() {
            boot.enrollment_key = read_enrollment_key(state_dir);
        }
        boot
    }
}

/// Where an installer may leave an enrollment key for a node that has no operator watching.
pub fn enrollment_key_path(state_dir: &Path) -> PathBuf {
    state_dir.join("enrollment-key")
}

pub fn read_enrollment_key(state_dir: &Path) -> Option<String> {
    std::fs::read_to_string(enrollment_key_path(state_dir))
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Remove the staged key once it has been used.
///
/// Deliberate, and the reason the file is not simply read on every start: a key left on disk
/// would let a node that an operator removed re-enroll itself the next time it restarted, which
/// would make `remove-node` mean nothing. Rejoining should take a fresh, deliberate act.
pub fn consume_enrollment_key(state_dir: &Path) {
    let path = enrollment_key_path(state_dir);
    match std::fs::remove_file(&path) {
        Ok(()) => {
            tracing::info!(path = %path.display(), "used and removed the staged enrollment key")
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => {
            tracing::warn!(path = %path.display(), error = %e, "could not remove the staged enrollment key")
        }
    }
}

/// Where a node should look for its control plane, and why.
///
/// The order matters and is not arbitrary:
///
/// 1. the runtime environment, because an operator overriding it means it now
/// 2. what we already enrolled against, because that is where our registration actually lives
///    and a rebuilt binary pointing somewhere else must not silently orphan a working node
/// 3. whatever was baked in at build time, which is the answer for a fresh install
pub fn resolve_cp_url(
    runtime: Option<&str>,
    cached: Option<&str>,
    compiled: Option<&str>,
) -> Option<(String, CpUrlSource)> {
    let pick = |v: &str, src| {
        let v = v.trim();
        (!v.is_empty()).then(|| (v.to_string(), src))
    };
    runtime
        .and_then(|v| pick(v, CpUrlSource::Environment))
        .or_else(|| cached.and_then(|v| pick(v, CpUrlSource::Enrollment)))
        .or_else(|| compiled.and_then(|v| pick(v, CpUrlSource::CompiledIn)))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CpUrlSource {
    Environment,
    Enrollment,
    CompiledIn,
}

impl std::fmt::Display for CpUrlSource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Environment => "MESH_CP_URL",
            Self::Enrollment => "previous enrollment",
            Self::CompiledIn => "compiled in",
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn saved_state_is_readable_only_by_its_owner() {
        use std::os::unix::fs::PermissionsExt;

        let dir = std::env::temp_dir().join(format!("meshstate{}", std::process::id()));
        std::fs::remove_dir_all(&dir).ok();
        let st = NodeState {
            node_name: "a".into(),
            ..Default::default()
        };
        st.save(&dir).unwrap();
        // Saving over an existing file has to end up restricted too, not inherit its mode.
        st.save(&dir).unwrap();

        let mode = std::fs::metadata(NodeState::path(&dir))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600, "state.json holds the node token");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn runtime_beats_everything() {
        let got = resolve_cp_url(
            Some("http://run"),
            Some("http://cached"),
            Some("http://built"),
        );
        assert_eq!(got, Some(("http://run".into(), CpUrlSource::Environment)));
    }

    #[test]
    fn an_enrolled_node_ignores_a_rebuilt_default() {
        // A binary rebuilt against a different control plane must not orphan a node that is
        // already registered somewhere else.
        let got = resolve_cp_url(None, Some("http://cached"), Some("http://built"));
        assert_eq!(got, Some(("http://cached".into(), CpUrlSource::Enrollment)));
    }

    #[test]
    fn a_fresh_install_uses_what_was_baked_in() {
        let got = resolve_cp_url(None, None, Some("http://built"));
        assert_eq!(got, Some(("http://built".into(), CpUrlSource::CompiledIn)));
    }

    #[test]
    fn blank_values_do_not_count_as_set() {
        // An exported-but-empty variable is a common accident and must fall through rather
        // than resolve to an empty URL.
        assert_eq!(
            resolve_cp_url(Some("   "), None, Some("http://built")),
            Some(("http://built".into(), CpUrlSource::CompiledIn))
        );
        assert_eq!(resolve_cp_url(None, None, None), None);
        assert_eq!(resolve_cp_url(Some(""), Some(""), Some("")), None);
    }
}
