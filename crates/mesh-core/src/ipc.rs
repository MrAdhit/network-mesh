//! Newline-delimited JSON over a unix socket, spoken between `meshd` and `meshctl`.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub fn default_socket_path() -> PathBuf {
    std::env::var("MESH_SOCKET")
        .map(PathBuf::from)
        .unwrap_or_else(|_| crate::state::default_state_dir().join("meshd.sock"))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "cmd", rename_all = "kebab-case")]
pub enum Request {
    /// Node identity and backhaul health.
    Status,
    /// Peer table with per-path statistics.
    Peers,
    /// Probe a peer on every path and report each RTT separately.
    Ping { peer: String, count: u32 },
    /// Send application data over the currently winning path.
    Send { peer: String, data: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Response {
    Status(StatusReport),
    Peers(Vec<PeerReport>),
    Ping(Vec<PingSample>),
    Sent { path: String, bytes: usize },
    Ok,
    Error(String),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusReport {
    pub node_name: String,
    pub virtual_ip: String,
    pub subnet: String,
    pub cloudflare: Option<BackhaulReport>,
    pub tailscale: Option<BackhaulReport>,
    pub peer_count: usize,
    pub uptime_secs: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BackhaulReport {
    pub up: bool,
    pub address: String,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PeerReport {
    pub name: String,
    pub virtual_ip: Option<String>,
    pub cf_ip: Option<String>,
    pub ts_hostname: Option<String>,
    pub best_path: Option<String>,
    pub paths: Vec<PathReport>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PathReport {
    pub path: String,
    pub up: bool,
    pub last_rtt_ms: Option<f64>,
    pub ewma_ms: Option<f64>,
    pub sent: u64,
    pub received: u64,
    pub loss_pct: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PingSample {
    pub path: String,
    pub seq: u32,
    pub rtt_ms: Option<f64>,
}

/// Send one request and read one response.
pub async fn call(socket: &Path, req: &Request) -> anyhow::Result<Response> {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let stream = tokio::net::UnixStream::connect(socket).await.map_err(|e| {
        anyhow::anyhow!(
            "cannot reach meshd at {}: {e}. Is the daemon running?",
            socket.display()
        )
    })?;
    let (r, mut w) = stream.into_split();
    let mut line = serde_json::to_string(req)?;
    line.push('\n');
    w.write_all(line.as_bytes()).await?;
    w.flush().await?;

    let mut reader = BufReader::new(r);
    let mut buf = String::new();
    reader.read_line(&mut buf).await?;
    if buf.trim().is_empty() {
        anyhow::bail!("daemon closed the connection without replying");
    }
    Ok(serde_json::from_str(buf.trim())?)
}
