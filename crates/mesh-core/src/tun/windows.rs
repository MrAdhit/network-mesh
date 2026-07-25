//! Windows, via Wintun.
//!
//! Windows has no TUN device of its own. Wintun is WireGuard's NDIS miniport driver, driven
//! through `wintun.dll`, which has to sit next to the binary or somewhere on the search path.
//! Creating an adapter needs Administrator, and the driver is signed by WireGuard, so nothing
//! here needs signing of its own.
//!
//! The shape is different from both unix platforms. There is no file descriptor: Wintun moves
//! packets through shared ring buffers and signals with an event handle, so `AsyncFd` has
//! nothing to watch. Receiving is therefore a blocking call on a dedicated thread feeding a
//! channel, which is what turns it back into something async code can await. Sending writes
//! straight into the ring and does not block, so it needs no thread.
//!
//! Framing matches Linux: bare IP packets, no address family header.

use anyhow::{Context, Result, anyhow};
use std::sync::Arc;
use tokio::sync::{Mutex, mpsc};

use super::{MTU, run};

/// Ring buffer size. Wintun requires a power of two between 128KiB and 64MiB; this is its own
/// documented default and is far more than our MTU-limited traffic needs.
const RING_CAPACITY: u32 = 0x40_0000;

pub struct TunDevice {
    /// Kept alive: dropping the adapter removes the interface.
    _adapter: Arc<wintun::Adapter>,
    session: Arc<wintun::Session>,
    incoming: Mutex<mpsc::Receiver<Vec<u8>>>,
    pub name: String,
}

impl TunDevice {
    /// Create the adapter and configure it with the node's address and the mesh subnet route.
    pub fn open(name: &str, address: std::net::Ipv4Addr, subnet: &str) -> Result<Self> {
        let wintun = unsafe { wintun::load() }.context(
            "loading wintun.dll; put it next to meshd.exe. It ships with WireGuard for Windows \
             and is downloadable from wintun.net",
        )?;

        // Reuse an adapter we left behind rather than accumulating one per start.
        let adapter = match wintun::Adapter::open(&wintun, name) {
            Ok(existing) => existing,
            Err(_) => wintun::Adapter::create(&wintun, name, "mesh", None).map_err(|e| {
                anyhow!(
                    "creating the Wintun adapter {name}: {e}. This needs Administrator; \
                     run meshd from an elevated prompt"
                )
            })?,
        };

        let session = Arc::new(
            adapter
                .start_session(RING_CAPACITY)
                .map_err(|e| anyhow!("starting the Wintun session: {e}"))?,
        );

        // netsh rather than the crate's helpers: the same three commands as the unix platforms,
        // and a failure names the command rather than an HRESULT.
        let addr = address.to_string();
        run(
            "netsh",
            &[
                "interface",
                "ipv4",
                "set",
                "address",
                &format!("name={name}"),
                "source=static",
                &format!("address={addr}"),
                "mask=255.255.255.255",
            ],
        )?;
        run(
            "netsh",
            &[
                "interface",
                "ipv4",
                "set",
                "subinterface",
                name,
                &format!("mtu={MTU}"),
                "store=active",
            ],
        )?;
        // Adding a route that already exists is an error, so clear it first and ignore that.
        let _ = run(
            "netsh",
            &["interface", "ipv4", "delete", "route", subnet, name],
        );
        run(
            "netsh",
            &["interface", "ipv4", "add", "route", subnet, name],
        )?;

        // Wintun blocks to receive and has no pollable handle, so a thread does the waiting and
        // the channel is what async code awaits. Bounded, so a stalled reader applies back
        // pressure instead of growing without limit.
        let (tx, rx) = mpsc::channel(256);
        let reader = session.clone();
        std::thread::Builder::new()
            .name(format!("wintun-{name}"))
            .spawn(move || {
                loop {
                    match reader.receive_blocking() {
                        Ok(packet) => {
                            if tx.blocking_send(packet.bytes().to_vec()).is_err() {
                                break; // the device was dropped
                            }
                        }
                        Err(e) => {
                            tracing::debug!(error = %e, "wintun receive stopped");
                            break;
                        }
                    }
                }
            })
            .context("spawning the wintun reader thread")?;

        tracing::info!(name, %address, subnet, mtu = MTU, "wintun interface up");
        Ok(Self {
            _adapter: adapter,
            session,
            incoming: Mutex::new(rx),
            name: name.to_string(),
        })
    }

    /// Read one IP packet.
    pub async fn recv(&self) -> Result<Vec<u8>> {
        self.incoming
            .lock()
            .await
            .recv()
            .await
            .ok_or_else(|| anyhow!("the wintun reader thread stopped"))
    }

    /// Hand one IP packet to the stack.
    pub async fn send(&self, packet: &[u8]) -> Result<()> {
        let len: u16 = packet
            .len()
            .try_into()
            .map_err(|_| anyhow!("packet of {} bytes is too large for wintun", packet.len()))?;
        let mut out = self
            .session
            .allocate_send_packet(len)
            .map_err(|e| anyhow!("allocating a wintun send packet: {e}"))?;
        out.bytes_mut().copy_from_slice(packet);
        // Writes into the ring and returns; nothing blocks, so no spawn_blocking needed.
        self.session.send_packet(out);
        Ok(())
    }
}

impl Drop for TunDevice {
    fn drop(&mut self) {
        // Unblocks the reader thread so it can exit rather than leaking.
        let _ = self.session.shutdown();
    }
}
