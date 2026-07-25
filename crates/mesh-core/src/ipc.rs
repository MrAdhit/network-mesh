//! Newline-delimited JSON between `meshd` and `meshctl`.
//!
//! The transport differs by platform and nothing above this module needs to know. Unix gets a
//! socket in the state directory; Windows gets a named pipe, because tokio has no unix-socket
//! support there even on the Windows builds that do have `AF_UNIX`.
//!
//! Both are local-only and unauthenticated, which is the same trust model either way: anyone
//! who can open the endpoint can drive the daemon.

use serde::{Deserialize, Serialize};

/// Where `meshctl` looks for the daemon.
///
/// A filesystem path on unix, a pipe name on Windows. Kept as a string so the two stay
/// interchangeable in config and log lines.
pub fn default_endpoint() -> String {
    if let Ok(v) = std::env::var("MESH_SOCKET")
        && !v.is_empty()
    {
        return v;
    }
    #[cfg(unix)]
    {
        crate::state::default_state_dir()
            .join("meshd.sock")
            .to_string_lossy()
            .into_owned()
    }
    #[cfg(windows)]
    {
        // The pipe namespace is flat and global; the name is the whole address.
        r"\\.\pipe\meshd".to_string()
    }
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

// ---- transport ----

/// One accepted or dialled connection, whatever it is underneath.
pub type Connection = Box<dyn Duplex>;

/// Everything the JSON framing needs from a transport.
pub trait Duplex: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send {}
impl<T: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send> Duplex for T {}

#[cfg(unix)]
mod transport {
    use super::Connection;
    use anyhow::{Context, Result};

    pub struct Listener {
        inner: tokio::net::UnixListener,
    }

    impl Listener {
        pub async fn bind(endpoint: &str) -> Result<Self> {
            // A stale socket from a crashed daemon would otherwise make bind fail forever.
            let _ = std::fs::remove_file(endpoint);
            if let Some(dir) = std::path::Path::new(endpoint).parent() {
                std::fs::create_dir_all(dir)?;
            }
            Ok(Self {
                inner: tokio::net::UnixListener::bind(endpoint)
                    .with_context(|| format!("binding {endpoint}"))?,
            })
        }

        pub async fn accept(&mut self) -> Result<Connection> {
            let (stream, _) = self.inner.accept().await?;
            Ok(Box::new(stream))
        }
    }

    pub async fn connect(endpoint: &str) -> Result<Connection> {
        let stream = tokio::net::UnixStream::connect(endpoint).await?;
        Ok(Box::new(stream))
    }
}

#[cfg(windows)]
mod transport {
    use super::Connection;
    use anyhow::{Context, Result};
    use tokio::net::windows::named_pipe::{ClientOptions, ServerOptions};

    /// A named pipe server handles one client per instance, so the listener always holds the
    /// next instance ready and creates a replacement as soon as one is handed out. Without
    /// that, a client connecting between accepts gets ERROR_FILE_NOT_FOUND.
    pub struct Listener {
        endpoint: String,
        next: Option<tokio::net::windows::named_pipe::NamedPipeServer>,
    }

    impl Listener {
        pub async fn bind(endpoint: &str) -> Result<Self> {
            let server = ServerOptions::new()
                .first_pipe_instance(true)
                .create(endpoint)
                .with_context(|| format!("creating the named pipe {endpoint}"))?;
            Ok(Self {
                endpoint: endpoint.to_string(),
                next: Some(server),
            })
        }

        pub async fn accept(&mut self) -> Result<Connection> {
            let server = match self.next.take() {
                Some(s) => s,
                None => ServerOptions::new().create(&self.endpoint)?,
            };
            server.connect().await?;
            self.next = Some(ServerOptions::new().create(&self.endpoint)?);
            Ok(Box::new(server))
        }
    }

    pub async fn connect(endpoint: &str) -> Result<Connection> {
        let client = ClientOptions::new().open(endpoint)?;
        Ok(Box::new(client))
    }
}

pub use transport::Listener;

/// Send one request and read one response.
pub async fn call(endpoint: &str, req: &Request) -> anyhow::Result<Response> {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    let stream = transport::connect(endpoint).await.map_err(|e| {
        anyhow::anyhow!("cannot reach meshd at {endpoint}: {e}. Is the daemon running?")
    })?;
    let (r, mut w) = tokio::io::split(stream);

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
