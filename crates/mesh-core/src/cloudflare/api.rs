//! Cloudflare WARP / Mesh enrollment.
//!
//! Three calls, no browser, as documented in docs/cloudflare-auth.md:
//!   1. swap an Access service token for a 60s enrollment JWT
//!   2. POST /reg to register the device into the org
//!   3. PATCH /reg/{id} to switch it to MASQUE with our P-256 key

use anyhow::{Context, Result, bail};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use serde::{Deserialize, Serialize};

pub const API_BASE: &str = "https://api.cloudflareclient.com";
pub const API_VERSION: &str = "v0a4471";
pub const CLIENT_VERSION: &str = "a-6.35-4471";

fn client_headers(rb: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
    rb.header("User-Agent", "WARP for Android")
        .header("CF-Client-Version", CLIENT_VERSION)
        .header("Content-Type", "application/json; charset=UTF-8")
}

/// Exchange an Access service token for a WARP enrollment JWT.
///
/// Access replies 302 with `Location: com.cloudflare.warp://<team>/auth?token=<jwt>`.
/// A bad token instead redirects to the login page, so we detect success by scheme.
/// The JWT lives 60 seconds: call this immediately before `register`, never cache it.
pub async fn enrollment_jwt(team: &str, client_id: &str, client_secret: &str) -> Result<String> {
    let http = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()?;
    let url = format!("https://{team}.cloudflareaccess.com/warp");
    let resp = http
        .get(&url)
        .header("CF-Access-Client-Id", client_id)
        .header("CF-Access-Client-Secret", client_secret)
        .send()
        .await
        .context("service token exchange failed")?;

    let loc = resp
        .headers()
        .get(reqwest::header::LOCATION)
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default()
        .to_string();

    if !loc.starts_with("com.cloudflare.warp://") {
        bail!(
            "service token rejected: Access redirected to {} (check the Service Auth policy)",
            if loc.is_empty() {
                "<no location>"
            } else {
                &loc
            }
        );
    }
    loc.split_once("token=")
        .map(|(_, t)| t.to_string())
        .context("no token in enrollment redirect")
}

#[derive(Serialize)]
struct RegisterBody<'a> {
    key: &'a str,
    install_id: &'a str,
    fcm_token: &'a str,
    tos: &'a str,
    model: &'a str,
    serial_number: &'a str,
    os_version: &'a str,
    key_type: &'a str,
    tunnel_type: &'a str,
    locale: &'a str,
}

#[derive(Serialize)]
struct EnrollBody<'a> {
    key: &'a str,
    key_type: &'a str,
    tunnel_type: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<&'a str>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AccountData {
    pub id: String,
    #[serde(default)]
    pub name: String,
    /// Only ever returned by POST /reg. Persist it on first sight.
    #[serde(default)]
    pub token: Option<String>,
    #[serde(default)]
    pub account: Account,
    pub config: Config,
    #[serde(default)]
    pub policy: Policy,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Account {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub account_type: String,
    #[serde(default)]
    pub organization: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    pub client_id: String,
    pub peers: Vec<Peer>,
    pub interface: Interface,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Interface {
    pub addresses: Addresses,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Addresses {
    pub v4: String,
    pub v6: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Peer {
    /// Raw base64 for consumer WireGuard, PEM for Zero Trust MASQUE. Both occur.
    pub public_key: String,
    pub endpoint: Endpoint,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Endpoint {
    pub v4: String,
    pub v6: String,
    #[serde(default)]
    pub host: String,
    #[serde(default)]
    pub ports: Vec<u16>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Policy {
    #[serde(default)]
    pub tunnel_protocol: String,
    /// The org's Mesh ranges. Never assume 100.96.0.0/12: it is org-configurable.
    #[serde(default)]
    pub include: Vec<IncludeRoute>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct IncludeRoute {
    #[serde(default)]
    pub address: String,
}

/// Register a device. `jwt` is `None` for consumer WARP, `Some` to join a Zero Trust org.
///
/// The curve25519 key here is deliberately throwaway: the Android client sends one, so we
/// send one, and the private half is discarded. Real key material is enrolled by `enroll_masque`.
pub async fn register(jwt: Option<&str>) -> Result<AccountData> {
    let throwaway: [u8; 32] = rand::random();
    let serial: [u8; 8] = rand::random();
    let tos = crate::util::cf_timestamp();

    let body = RegisterBody {
        key: &B64.encode(throwaway),
        install_id: "",
        fcm_token: "",
        tos: &tos,
        model: "PC",
        serial_number: &hex::encode(serial),
        os_version: "",
        key_type: "curve25519",
        tunnel_type: "wireguard",
        locale: "en_US",
    };

    let http = reqwest::Client::new();
    let mut rb = client_headers(http.post(format!("{API_BASE}/{API_VERSION}/reg"))).json(&body);
    if let Some(jwt) = jwt {
        rb = rb.header("CF-Access-Jwt-Assertion", jwt);
    }
    let resp = rb.send().await.context("POST /reg failed")?;
    let status = resp.status();
    let text = resp.text().await?;
    if !status.is_success() {
        bail!("POST /reg returned {status}: {text}");
    }
    serde_json::from_str(&text).with_context(|| format!("could not parse /reg response: {text}"))
}

/// Switch a registered device to MASQUE by enrolling a P-256 public key (DER SPKI).
pub async fn enroll_masque(
    device_id: &str,
    device_token: &str,
    spki_der: &[u8],
    name: Option<&str>,
) -> Result<AccountData> {
    let body = EnrollBody {
        key: &B64.encode(spki_der),
        key_type: "secp256r1",
        tunnel_type: "masque",
        name,
    };
    let http = reqwest::Client::new();
    let resp = client_headers(http.patch(format!("{API_BASE}/{API_VERSION}/reg/{device_id}")))
        .header("Authorization", format!("Bearer {device_token}"))
        .json(&body)
        .send()
        .await
        .context("PATCH /reg failed")?;
    let status = resp.status();
    let text = resp.text().await?;
    if !status.is_success() {
        bail!("PATCH /reg returned {status}: {text}");
    }
    serde_json::from_str(&text).with_context(|| format!("could not parse enroll response: {text}"))
}

impl Endpoint {
    /// Endpoints arrive as `1.2.3.4:0` and `[::1]:0`; the port is a lie, use `ports`.
    pub fn v4_ip(&self) -> Option<std::net::Ipv4Addr> {
        self.v4.rsplit_once(':')?.0.parse().ok()
    }
    pub fn v6_ip(&self) -> Option<std::net::Ipv6Addr> {
        let s = self.v6.rsplit_once(':')?.0;
        s.trim_start_matches('[').trim_end_matches(']').parse().ok()
    }
}
