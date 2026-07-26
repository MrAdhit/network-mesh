//! Keeping binaries current from the control plane.
//!
//! The control plane carries a copy of the binaries it expects its nodes to be running, so a
//! node can ask "is what I am running what you have?" and fix it if not. Identity is a SHA-256
//! of the file, not a version string: a version is a claim, a hash is the thing itself, and it
//! cannot drift from what was actually shipped.
//!
//! Replacement is by rename, which is atomic. A half-written binary is the one outcome worth
//! going out of the way to avoid, since it is unrecoverable without another machine, so nothing
//! is ever written over the running file: the download lands beside it and is only moved into
//! place once its hash matches what the control plane promised.
//!
//! The new code takes effect on the next start rather than immediately. Restarting a daemon out
//! from under a working mesh to apply an update nobody asked for is worse than waiting.

use anyhow::{Context, Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

/// The target triple this binary was compiled for, stamped in by the build script.
///
/// A node has to ask for its own architecture's build, and it is the only thing that knows what
/// that is.
pub const TARGET: &str = env!("MESH_TARGET");

/// Whether updating was compiled in. See [`autoupdate_enabled`].
pub const COMPILED_AUTOUPDATE: Option<&str> = option_env!("MESH_AUTOUPDATE");

/// What the control plane knows about the binaries for one target.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct UpdateManifest {
    pub target: String,
    pub binaries: Vec<BinaryInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BinaryInfo {
    /// `meshd` or `meshctl`, without any platform extension.
    pub name: String,
    pub sha256: String,
    pub size: u64,
}

impl UpdateManifest {
    pub fn get(&self, name: &str) -> Option<&BinaryInfo> {
        self.binaries.iter().find(|b| b.name == name)
    }
}

/// Is updating switched on?
///
/// Compiled in by default, so a stock build keeps itself current without being asked. Set
/// `MESH_AUTOUPDATE=0` when building to ship a binary that never updates, and the same variable
/// at runtime to override whichever way it was built. An operator saying no now outranks a
/// decision taken at build time, and it is the only way to stop a node updating without
/// rebuilding it.
pub fn autoupdate_enabled(runtime: Option<&str>, compiled: Option<&str>) -> bool {
    let parse = |v: &str| {
        !matches!(
            v.trim().to_ascii_lowercase().as_str(),
            "0" | "false" | "off" | "no"
        )
    };
    runtime
        .filter(|v| !v.trim().is_empty())
        .map(parse)
        .or_else(|| compiled.filter(|v| !v.trim().is_empty()).map(parse))
        .unwrap_or(true)
}

/// Read the toggle from the process environment.
pub fn enabled_from_env() -> bool {
    autoupdate_enabled(
        std::env::var("MESH_AUTOUPDATE").ok().as_deref(),
        COMPILED_AUTOUPDATE,
    )
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(bytes);
    hex::encode(h.finalize())
}

pub fn sha256_file(path: &Path) -> Result<String> {
    let bytes =
        std::fs::read(path).with_context(|| format!("reading {} to hash it", path.display()))?;
    Ok(sha256_hex(&bytes))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// Switched off, so nothing was checked.
    Disabled,
    /// The control plane has no build for this target, which is normal for a control plane that
    /// was built without artifacts staged.
    NotOffered,
    UpToDate,
    /// Replaced on disk. Takes effect when the process next starts.
    Replaced {
        sha256: String,
    },
}

/// Fetch the manifest the control plane holds for this target.
pub async fn fetch_manifest(cp_url: &str, target: &str) -> Result<UpdateManifest> {
    let url = format!("{}/v1/updates/{target}", cp_url.trim_end_matches('/'));
    let resp = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .build()?
        .get(&url)
        .send()
        .await
        .with_context(|| format!("asking {url} for an update manifest"))?;
    if !resp.status().is_success() {
        bail!("{url} answered {}", resp.status());
    }
    Ok(resp.json().await?)
}

/// Bring one binary up to date, replacing `exe` if it differs from what the control plane holds.
///
/// `name` is the logical name (`meshd`, `meshctl`) rather than the file name, because Windows
/// adds an extension and the manifest should not have to care.
pub async fn update_binary(cp_url: &str, name: &str, exe: &Path) -> Result<Outcome> {
    let manifest = fetch_manifest(cp_url, TARGET).await?;
    let Some(want) = manifest.get(name) else {
        return Ok(Outcome::NotOffered);
    };
    let have = sha256_file(exe)?;
    if have == want.sha256 {
        return Ok(Outcome::UpToDate);
    }

    let url = format!(
        "{}/v1/updates/{TARGET}/{name}",
        cp_url.trim_end_matches('/')
    );
    let bytes = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(300))
        .build()?
        .get(&url)
        .send()
        .await
        .with_context(|| format!("downloading {url}"))?
        .error_for_status()?
        .bytes()
        .await?;

    let got = verified_hash(name, &bytes, &want.sha256)?;
    install(exe, &bytes)?;
    Ok(Outcome::Replaced { sha256: got })
}

/// Confirm a download is what was promised, returning its hash.
///
/// The whole point of publishing hashes. A truncated or tampered download must never reach a
/// path we are about to execute from, and this is the only thing standing between the two.
fn verified_hash(name: &str, bytes: &[u8], expected: &str) -> Result<String> {
    let got = sha256_hex(bytes);
    if got != expected {
        bail!("downloaded {name} hashes to {got}, control plane promised {expected}");
    }
    Ok(got)
}

/// Put `bytes` at `exe`, atomically, without ever writing over the running file.
///
/// The temporary lands in the same directory so the rename cannot cross a filesystem boundary,
/// which is the one case where rename stops being atomic and turns into a copy.
fn install(exe: &Path, bytes: &[u8]) -> Result<()> {
    let dir = exe
        .parent()
        .ok_or_else(|| anyhow!("{} has no parent directory", exe.display()))?;
    let tmp = dir.join(format!(
        ".{}.new",
        exe.file_name().and_then(|n| n.to_str()).unwrap_or("mesh")
    ));
    std::fs::write(&tmp, bytes).with_context(|| format!("writing {}", tmp.display()))?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755))
            .with_context(|| format!("making {} executable", tmp.display()))?;
    }

    // Unix lets a running executable be renamed over: the process keeps the inode it started
    // from and the new file takes the name. Windows refuses, so the running file is moved aside
    // first and swept up on a later start, once nothing is executing it.
    #[cfg(windows)]
    {
        let old = exe.with_extension("old");
        let _ = std::fs::remove_file(&old);
        std::fs::rename(exe, &old).with_context(|| format!("moving {} aside", exe.display()))?;
        if let Err(e) = std::fs::rename(&tmp, exe) {
            // Put it back rather than leaving the machine with no binary at all.
            let _ = std::fs::rename(&old, exe);
            return Err(e).with_context(|| format!("installing {}", exe.display()));
        }
    }
    #[cfg(not(windows))]
    std::fs::rename(&tmp, exe).with_context(|| format!("installing {}", exe.display()))?;

    Ok(())
}

/// Remove a predecessor left behind by a Windows update. Does nothing anywhere else.
pub fn sweep_replaced_binary(exe: &Path) {
    if cfg!(windows) {
        let _ = std::fs::remove_file(exe.with_extension("old"));
    }
}

/// Where a sibling binary would be, if it is installed next to this one.
///
/// Lets the daemon keep the CLI current too. They are shipped together and a user who updates
/// one expects the other to match, but only the daemon is running continuously enough to notice.
pub fn sibling(exe: &Path, name: &str) -> Option<PathBuf> {
    let file = if cfg!(windows) {
        format!("{name}.exe")
    } else {
        name.to_string()
    };
    let p = exe.parent()?.join(file);
    p.exists().then_some(p)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn updating_is_on_unless_something_says_otherwise() {
        assert!(autoupdate_enabled(None, None), "the default is on");
        assert!(autoupdate_enabled(None, Some("1")));
        assert!(autoupdate_enabled(Some("yes"), None));
    }

    #[test]
    fn a_build_can_ship_it_switched_off() {
        for v in ["0", "false", "off", "no", "OFF", " false "] {
            assert!(!autoupdate_enabled(None, Some(v)), "compiled {v:?}");
        }
    }

    #[test]
    fn the_operator_outranks_the_build() {
        // Both directions: a binary built without updating can be told to update, and one built
        // with it can be stopped without rebuilding, which is the only lever during an incident.
        assert!(!autoupdate_enabled(Some("0"), Some("1")));
        assert!(autoupdate_enabled(Some("1"), Some("0")));
        // An exported-but-empty variable is a common accident and must not count as a decision.
        assert!(!autoupdate_enabled(Some(""), Some("0")));
        assert!(autoupdate_enabled(Some("  "), None));
    }

    #[test]
    fn a_manifest_only_answers_for_what_it_carries() {
        let m = UpdateManifest {
            target: "x86_64-unknown-linux-gnu".into(),
            binaries: vec![BinaryInfo {
                name: "meshd".into(),
                sha256: "abc".into(),
                size: 3,
            }],
        };
        assert_eq!(m.get("meshd").unwrap().sha256, "abc");
        assert!(m.get("meshctl").is_none(), "absent means not offered");
    }

    #[test]
    fn hashing_matches_the_known_answer() {
        // The empty SHA-256, so a wrong hasher is caught rather than merely a changed one.
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            sha256_hex(b"mesh"),
            sha256_hex(b"mesh"),
            "and it is deterministic"
        );
        assert_ne!(sha256_hex(b"mesh"), sha256_hex(b"mesj"));
    }

    #[test]
    fn a_download_that_does_not_match_is_refused() {
        let bytes = b"a binary, allegedly";
        let real = sha256_hex(bytes);
        assert_eq!(verified_hash("meshd", bytes, &real).unwrap(), real);

        // Truncated, tampered with, or simply the wrong file: all the same to us, and all
        // refused before anything is written to a path we would later execute.
        let err = verified_hash("meshd", b"something else", &real)
            .unwrap_err()
            .to_string();
        assert!(err.contains("promised"), "unhelpful error: {err}");
        assert!(verified_hash("meshd", b"", &real).is_err());
    }

    #[test]
    fn installing_replaces_the_file_atomically() {
        let dir = std::env::temp_dir().join(format!("meshupd{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let exe = dir.join("meshd");
        std::fs::write(&exe, b"old").unwrap();

        install(&exe, b"new and longer").unwrap();
        assert_eq!(std::fs::read(&exe).unwrap(), b"new and longer");
        // No debris beside it: a leftover temp would be installed by a later run.
        let stray: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.ends_with(".new"))
            .collect();
        assert!(stray.is_empty(), "left behind {stray:?}");

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&exe).unwrap().permissions().mode();
            assert_eq!(mode & 0o111, 0o111, "must still be executable");
        }
        std::fs::remove_dir_all(&dir).ok();
    }
}
