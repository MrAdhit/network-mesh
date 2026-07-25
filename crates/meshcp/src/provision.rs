//! Turning the users' vendor API tokens into the narrow credentials nodes actually use.
//!
//! This is the automated version of the sequence proven by hand in docs/cloudflare-auth.md §7.
//! The control plane holds the powerful token; nodes only ever see what they need.

use anyhow::{Context, Result, anyhow, bail};
use serde::Deserialize;

const CF_API: &str = "https://api.cloudflare.com/client/v4";
/// Name we give our own Access policy, so re-provisioning can find and replace it.
const POLICY_NAME: &str = "mesh-service-auth";
const TS_API: &str = "https://api.tailscale.com/api/v2";

#[derive(Debug, Clone)]
pub struct CloudflareProvisioned {
    pub team: String,
    pub service_client_id: String,
    pub service_client_secret: String,
}

#[derive(Deserialize)]
struct CfEnvelope<T> {
    success: bool,
    #[serde(default)]
    errors: Vec<serde_json::Value>,
    result: Option<T>,
}

impl<T> CfEnvelope<T> {
    fn into_result(self, what: &str) -> Result<T> {
        if !self.success {
            bail!("cloudflare rejected {what}: {:?}", self.errors);
        }
        self.result
            .ok_or_else(|| anyhow!("cloudflare returned no result for {what}"))
    }
}

#[derive(Deserialize)]
struct CfOrg {
    auth_domain: String,
}

#[derive(Deserialize)]
struct CfApp {
    id: String,
    #[serde(default, rename = "type")]
    kind: String,
}

#[derive(Deserialize)]
struct CfPolicy {
    id: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    precedence: i64,
}

#[derive(Deserialize)]
struct CfServiceToken {
    id: String,
    client_id: String,
    #[serde(default)]
    client_secret: String,
}

/// Verify the token, find the Zero Trust org, and make sure a Service Auth path into the WARP
/// enrollment app exists. Returns what a node needs to enroll itself.
pub async fn provision_cloudflare(
    api_token: &str,
    account_id: &str,
) -> Result<CloudflareProvisioned> {
    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .build()?;
    let auth = format!("Bearer {api_token}");

    // 1. Is the token usable at all? Fail here rather than at some node's enrollment later.
    let verify: CfEnvelope<serde_json::Value> = http
        .get(format!("{CF_API}/accounts/{account_id}/tokens/verify"))
        .header("Authorization", &auth)
        .send()
        .await
        .context("could not reach the Cloudflare API")?
        .json()
        .await
        .context("unexpected response verifying the Cloudflare token")?;
    verify.into_result("the API token")?;

    // 2. The team name is the auth domain's first label.
    let orgs: CfEnvelope<CfOrg> = http
        .get(format!(
            "{CF_API}/accounts/{account_id}/access/organizations"
        ))
        .header("Authorization", &auth)
        .send()
        .await?
        .json()
        .await?;
    let auth_domain = orgs
        .into_result("the Zero Trust organization")
        .context("this account has no Zero Trust organization; create one first")?
        .auth_domain;
    let team = auth_domain
        .split('.')
        .next()
        .ok_or_else(|| anyhow!("could not read a team name from {auth_domain}"))?
        .to_string();

    // 3. Find the WARP enrollment app.
    let apps: CfEnvelope<Vec<CfApp>> = http
        .get(format!("{CF_API}/accounts/{account_id}/access/apps"))
        .header("Authorization", &auth)
        .send()
        .await?
        .json()
        .await?;
    let warp_app = apps
        .into_result("the Access application list")?
        .into_iter()
        .find(|a| a.kind == "warp")
        .ok_or_else(|| {
            anyhow!("no WARP enrollment application found; enable WARP device enrollment first")
        })?;

    // 4. Mint a service token. The secret is only ever returned here.
    let token: CfEnvelope<CfServiceToken> = http
        .post(format!(
            "{CF_API}/accounts/{account_id}/access/service_tokens"
        ))
        .header("Authorization", &auth)
        .json(&serde_json::json!({ "name": "mesh-enrollment" }))
        .send()
        .await?
        .json()
        .await?;
    let token = token.into_result("the service token")?;
    if token.client_secret.is_empty() {
        bail!("cloudflare did not return a service token secret");
    }

    // 5. Attach it with a Service Auth policy.
    //
    // Idempotent on purpose. Re-running this must not fail, and Cloudflare enforces unique
    // precedences per app, so a fixed number breaks the second time. Drop any policy we
    // previously created, then take one past the highest precedence still in use. Policies
    // belonging to real users are left alone, so humans can still enroll through the browser.
    let existing: CfEnvelope<Vec<CfPolicy>> = http
        .get(format!(
            "{CF_API}/accounts/{account_id}/access/apps/{}/policies",
            warp_app.id
        ))
        .header("Authorization", &auth)
        .send()
        .await?
        .json()
        .await?;
    let existing = existing.into_result("the policy list")?;

    for stale in existing.iter().filter(|p| p.name == POLICY_NAME) {
        let _ = http
            .delete(format!(
                "{CF_API}/accounts/{account_id}/access/apps/{}/policies/{}",
                warp_app.id, stale.id
            ))
            .header("Authorization", &auth)
            .send()
            .await;
    }
    let precedence = existing
        .iter()
        .filter(|p| p.name != POLICY_NAME)
        .map(|p| p.precedence)
        .max()
        .unwrap_or(0)
        + 1;

    let policy: CfEnvelope<serde_json::Value> = http
        .post(format!(
            "{CF_API}/accounts/{account_id}/access/apps/{}/policies",
            warp_app.id
        ))
        .header("Authorization", &auth)
        .json(&serde_json::json!({
            "name": POLICY_NAME,
            "decision": "non_identity",
            "precedence": precedence,
            "include": [{ "service_token": { "token_id": token.id } }]
        }))
        .send()
        .await?
        .json()
        .await?;
    policy.into_result("the Service Auth policy")?;

    Ok(CloudflareProvisioned {
        team,
        service_client_id: token.client_id,
        service_client_secret: token.client_secret,
    })
}

#[derive(Deserialize)]
struct TsKeyResponse {
    key: String,
}

/// Confirm a Tailscale API token works, and report the tailnet it belongs to.
pub async fn verify_tailscale(api_token: &str) -> Result<String> {
    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .build()?;
    let resp = http
        .get(format!("{TS_API}/tailnet/-/devices"))
        .bearer_auth(api_token)
        .send()
        .await
        .context("could not reach the Tailscale API")?;
    if !resp.status().is_success() {
        bail!("Tailscale rejected the API token ({})", resp.status());
    }
    let body: serde_json::Value = resp.json().await?;
    let count = body
        .get("devices")
        .and_then(|d| d.as_array())
        .map(|a| a.len())
        .unwrap_or(0);
    Ok(format!("{count} devices visible"))
}

/// Mint a short-lived, reusable, ephemeral, pre-authorized auth key.
///
/// Minted on demand rather than issued at enrollment: Tailscale reaps ephemeral node records
/// when they go offline, so a node coming back after a long stop needs a fresh key. Asking for
/// one when it is needed makes that self-healing.
///
/// Untagged, which a personal API token is allowed to do and an OAuth client is not.
pub async fn mint_tailscale_auth_key(api_token: &str) -> Result<String> {
    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .build()?;
    let resp = http
        .post(format!("{TS_API}/tailnet/-/keys"))
        .bearer_auth(api_token)
        .json(&serde_json::json!({
            "capabilities": { "devices": { "create": {
                "reusable": true,
                "ephemeral": true,
                "preauthorized": true,
                "tags": []
            }}},
            "expirySeconds": 3600,
            "description": "mesh node"
        }))
        .send()
        .await
        .context("could not reach the Tailscale API")?;
    let status = resp.status();
    let text = resp.text().await?;
    if !status.is_success() {
        bail!("minting a Tailscale auth key failed ({status}): {text}");
    }
    let parsed: TsKeyResponse =
        serde_json::from_str(&text).with_context(|| format!("unexpected key response: {text}"))?;
    Ok(parsed.key)
}
