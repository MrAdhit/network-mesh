//! Node-side client for the control plane, plus the node's own identity.

use anyhow::{Context, Result, anyhow};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use std::path::Path;

use crate::cp::*;

/// The node's Ed25519 keypair.
///
/// One identity for two jobs: it authenticates the node to the control plane, and its public
/// half is what the roster lists, which is what makes mesh membership decidable. Signing is not
/// wired up yet, so the membership check is currently an assertion rather than a proof; keeping
/// a real keypair here means turning that into a proof is a local change.
#[derive(Clone)]
pub struct NodeIdentity {
    signing: ed25519_dalek::SigningKey,
}

impl NodeIdentity {
    pub fn load_or_generate(path: &Path) -> Result<Self> {
        if path.exists() {
            let raw = std::fs::read_to_string(path)?;
            let bytes = B64
                .decode(raw.trim())
                .context("node identity file is not valid base64")?;
            let arr: [u8; 32] = bytes
                .as_slice()
                .try_into()
                .map_err(|_| anyhow!("node identity must be 32 bytes"))?;
            return Ok(Self {
                signing: ed25519_dalek::SigningKey::from_bytes(&arr),
            });
        }
        let signing = ed25519_dalek::SigningKey::generate(&mut rand::rng());
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        std::fs::write(path, B64.encode(signing.to_bytes()))?;
        Ok(Self { signing })
    }

    pub fn public_bytes(&self) -> [u8; 32] {
        self.signing.verifying_key().to_bytes()
    }

    pub fn public_b64(&self) -> String {
        B64.encode(self.public_bytes())
    }
}

/// Why a control plane call failed, to the extent the caller should care.
///
/// The distinction that matters is whether the control plane answered. A network error means
/// our cached state is still true and we should carry on with it. A rejected token means the
/// control plane is telling us our registration no longer exists, which cached state cannot
/// paper over.
#[derive(Debug)]
pub enum CpError {
    /// The control plane answered and refused our credentials.
    Unauthorized,
    /// Anything else: unreachable, malformed, or a server-side failure.
    Other(anyhow::Error),
}

impl CpError {
    pub fn is_unauthorized(&self) -> bool {
        matches!(self, CpError::Unauthorized)
    }
}

impl std::fmt::Display for CpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CpError::Unauthorized => write!(f, "the control plane rejected our node token"),
            CpError::Other(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for CpError {}

// anyhow supplies From<CpError> already, via its blanket impl over std::error::Error.

pub struct CpClient {
    base: String,
    http: reqwest::Client,
    node_token: Option<String>,
}

impl CpClient {
    pub fn new(base_url: &str) -> Result<Self> {
        Ok(Self {
            base: base_url.trim_end_matches('/').to_string(),
            http: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(20))
                .build()?,
            node_token: None,
        })
    }

    pub fn with_token(mut self, token: String) -> Self {
        self.node_token = Some(token);
        self
    }

    async fn parse<T: serde::de::DeserializeOwned>(
        resp: reqwest::Response,
        what: &str,
    ) -> std::result::Result<T, CpError> {
        let status = resp.status();
        let text = resp.text().await.map_err(|e| CpError::Other(e.into()))?;
        if status == reqwest::StatusCode::UNAUTHORIZED {
            return Err(CpError::Unauthorized);
        }
        if !status.is_success() {
            // The control plane sends a human-readable reason; surface it rather than a code.
            let msg = serde_json::from_str::<ApiError>(&text)
                .map(|e| e.error)
                .unwrap_or(text);
            return Err(CpError::Other(anyhow!("{what} failed ({status}): {msg}")));
        }
        serde_json::from_str(&text)
            .with_context(|| format!("unexpected {what} response: {text}"))
            .map_err(CpError::Other)
    }

    pub async fn enroll(
        &self,
        enrollment_key: &str,
        identity: &NodeIdentity,
        name: &str,
    ) -> Result<EnrollResponse> {
        let resp = self
            .http
            .post(format!("{}/v1/enroll", self.base))
            .json(&EnrollRequest {
                enrollment_key: enrollment_key.to_string(),
                public_key: identity.public_b64(),
                name: name.to_string(),
            })
            .send()
            .await
            .context("could not reach the control plane")?;
        // The credential being refused here is the enrollment key, not a node token, and the
        // generic message names the wrong one at the exact moment somebody is looking at a key
        // they just pasted.
        Self::parse(resp, "enrollment").await.map_err(|e| match e {
            CpError::Unauthorized => anyhow!("the enrollment key is unknown or expired"),
            other => other.into(),
        })
    }

    pub async fn roster(&self) -> std::result::Result<Roster, CpError> {
        self.roster_reporting(None, None).await
    }

    /// `derp_region` tells the control plane which relay we measured as closest. It is only
    /// used if the network has not agreed on one yet.
    /// `cf_device` is the Cloudflare device this node registered for itself. The control plane
    /// cannot discover it any other way, and needs it to clean the registration up when the node
    /// is removed.
    pub async fn roster_reporting(
        &self,
        derp_region: Option<u32>,
        cf_device: Option<&str>,
    ) -> std::result::Result<Roster, CpError> {
        let token = self
            .node_token
            .as_ref()
            .ok_or_else(|| CpError::Other(anyhow!("no node token; enroll first")))?;
        let mut q: Vec<String> = Vec::new();
        if let Some(r) = derp_region {
            q.push(format!("derp={r}"));
        }
        if let Some(d) = cf_device.filter(|d| !d.is_empty()) {
            q.push(format!("cf_device={d}"));
        }
        let url = match q.is_empty() {
            false => format!("{}/v1/roster?{}", self.base, q.join("&")),
            true => format!("{}/v1/roster", self.base),
        };
        let resp = self
            .http
            .get(url)
            .header(NODE_TOKEN_HEADER, token)
            .send()
            .await
            .map_err(|e| CpError::Other(anyhow!("could not reach the control plane: {e}")))?;
        Self::parse(resp, "roster fetch").await
    }

    /// Remove this node's registration, freeing its address.
    ///
    /// Called on the way out of an uninstall. A node that simply disappears leaves a roster
    /// entry and an allocated address behind forever, since nothing else knows it is gone.
    pub async fn deregister(&self) -> std::result::Result<(), CpError> {
        let token = self
            .node_token
            .as_ref()
            .ok_or_else(|| CpError::Other(anyhow!("no node token; nothing to deregister")))?;
        let resp = self
            .http
            .delete(format!("{}/v1/nodes/me", self.base))
            .header(NODE_TOKEN_HEADER, token)
            .send()
            .await
            .map_err(|e| CpError::Other(anyhow!("could not reach the control plane: {e}")))?;
        let _: serde_json::Value = Self::parse(resp, "deregistration").await?;
        Ok(())
    }

    /// Ask for a fresh Tailscale auth key.
    ///
    /// Called whenever we need to register rather than once at enrollment, because Tailscale
    /// reaps ephemeral node records and a node returning from a long stop needs a new key.
    pub async fn tailscale_auth_key(&self) -> Result<String> {
        let token = self
            .node_token
            .as_ref()
            .ok_or_else(|| anyhow!("no node token; enroll first"))?;
        let resp = self
            .http
            .post(format!("{}/v1/nodes/me/tailscale-auth-key", self.base))
            .header(NODE_TOKEN_HEADER, token)
            .send()
            .await
            .context("could not reach the control plane")?;
        let key: TailscaleAuthKey = Self::parse(resp, "auth key request").await?;
        Ok(key.auth_key)
    }
}
