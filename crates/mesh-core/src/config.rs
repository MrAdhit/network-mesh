//! The CLI's own configuration: which control plane, and the session proving who we are.
//!
//! This is a *user's* file, not a machine's, which is why it does not live in the state
//! directory beside the node's credentials. The state directory belongs to root because the
//! daemon needs it to; `meshctl` is normally run by a person, and a person's session token
//! belongs in their home directory where only they can read it.
//!
//! The session and the control plane URL are stored as one record rather than two settings. A
//! session is only meaningful to the control plane that minted it, and storing them apart is how
//! an account token eventually gets sent to whatever host `MESH_CP_URL` happened to name.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

use crate::util::restrict;

/// Where the CLI keeps its configuration.
///
/// `MESH_CONFIG` overrides, which is what a test or a service account wants. Otherwise the
/// platform's usual place for per-user configuration.
pub fn default_config_path() -> Option<PathBuf> {
    if let Ok(v) = std::env::var("MESH_CONFIG")
        && !v.is_empty()
    {
        return Some(PathBuf::from(v));
    }
    #[cfg(windows)]
    {
        let base = std::env::var("APPDATA").ok().filter(|v| !v.is_empty())?;
        Some(PathBuf::from(base).join("mesh").join("config.json"))
    }
    #[cfg(target_os = "macos")]
    {
        let home = std::env::var("HOME").ok().filter(|v| !v.is_empty())?;
        Some(
            PathBuf::from(home)
                .join("Library")
                .join("Application Support")
                .join("mesh")
                .join("config.json"),
        )
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        if let Ok(x) = std::env::var("XDG_CONFIG_HOME")
            && !x.is_empty()
        {
            return Some(PathBuf::from(x).join("mesh").join("config.json"));
        }
        let home = std::env::var("HOME").ok().filter(|v| !v.is_empty())?;
        Some(
            PathBuf::from(home)
                .join(".config")
                .join("mesh")
                .join("config.json"),
        )
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct CliConfig {
    /// The control plane this session belongs to. Never used on its own; see [`CliConfig::session_for`].
    #[serde(default)]
    pub cp_url: String,
    #[serde(default)]
    pub session_token: String,
    #[serde(default)]
    pub account_id: String,
    #[serde(default)]
    pub email: Option<String>,
    /// Unix seconds. Lets the CLI say "expired" instead of passing on a bare 401.
    #[serde(default)]
    pub expires_at: Option<i64>,
}

impl CliConfig {
    /// Read the config, or `None` if there is not one.
    ///
    /// A malformed file is an error rather than a silent default: it holds the only copy of a
    /// credential, so quietly ignoring it would look exactly like being logged out and send the
    /// user off to log in again for no reason.
    pub fn load() -> Result<Option<Self>> {
        let Some(path) = default_config_path() else {
            return Ok(None);
        };
        if !path.exists() {
            return Ok(None);
        }
        let s = std::fs::read_to_string(&path)
            .with_context(|| format!("reading {}", path.display()))?;
        let cfg: Self =
            serde_json::from_str(&s).with_context(|| format!("parsing {}", path.display()))?;
        Ok(Some(cfg))
    }

    pub fn save(&self) -> Result<PathBuf> {
        let path = default_config_path()
            .context("no home directory to store the session in; set MESH_CONFIG")?;
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
        }
        // Written beside the target and renamed, so an interrupted write cannot leave a
        // truncated file where a working session used to be.
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_vec_pretty(self)?)
            .with_context(|| format!("writing {}", tmp.display()))?;
        restrict(&tmp)?;
        std::fs::rename(&tmp, &path).with_context(|| format!("writing {}", path.display()))?;
        Ok(path)
    }

    /// Remove the stored session. Returns the path if there was one to remove.
    pub fn clear() -> Result<Option<PathBuf>> {
        let Some(path) = default_config_path() else {
            return Ok(None);
        };
        if !path.exists() {
            return Ok(None);
        }
        std::fs::remove_file(&path).with_context(|| format!("removing {}", path.display()))?;
        Ok(Some(path))
    }

    /// The session token, but only for the control plane it was minted against.
    ///
    /// Returning `None` for a mismatch rather than the token is the whole point of storing the
    /// two together: pointing `MESH_CP_URL` somewhere else must not hand that host an account
    /// credential for a different one.
    pub fn session_for(&self, cp_url: &str) -> Option<&str> {
        (!self.session_token.is_empty() && same_cp(&self.cp_url, cp_url))
            .then_some(self.session_token.as_str())
    }

    pub fn expired(&self, now: i64) -> bool {
        self.expires_at.is_some_and(|e| e <= now)
    }
}

/// Two control plane URLs naming the same control plane.
///
/// Only trailing slashes and case are normalised. Anything cleverer would be guessing: a
/// different port or host is a different control plane even when it looks like a typo.
pub fn same_cp(a: &str, b: &str) -> bool {
    a.trim()
        .trim_end_matches('/')
        .eq_ignore_ascii_case(b.trim().trim_end_matches('/'))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg(url: &str) -> CliConfig {
        CliConfig {
            cp_url: url.into(),
            session_token: "sess_abc".into(),
            account_id: "acct".into(),
            email: None,
            expires_at: None,
        }
    }

    #[test]
    fn a_session_is_only_offered_to_the_control_plane_that_minted_it() {
        let c = cfg("https://mesh.example.net");
        assert_eq!(c.session_for("https://mesh.example.net"), Some("sess_abc"));
        // Trailing slashes and case are the same address.
        assert_eq!(c.session_for("https://MESH.example.net/"), Some("sess_abc"));
        // A different host is a different control plane, typo or not.
        assert_eq!(c.session_for("https://mesh.example.com"), None);
        assert_eq!(c.session_for("http://127.0.0.1:8080"), None);
    }

    #[test]
    fn an_empty_token_is_not_a_session() {
        let mut c = cfg("https://mesh.example.net");
        c.session_token.clear();
        assert_eq!(c.session_for("https://mesh.example.net"), None);
    }

    #[test]
    fn expiry_is_only_claimed_when_it_is_known() {
        let mut c = cfg("https://mesh.example.net");
        assert!(!c.expired(i64::MAX));
        c.expires_at = Some(100);
        assert!(c.expired(100));
        assert!(c.expired(101));
        assert!(!c.expired(99));
    }
}
