//! Keeping the Cloudflare backhaul alive across network failures.
//!
//! A MASQUE tunnel is a QUIC connection, so unlike the direct path it does not ride out a break
//! in connectivity: the moment the network drops, the connection is gone for good and every
//! send on it reports `connection lost`. Rebuilding it is the whole job of this type.
//!
//! It exists because losing the network for a few seconds used to cost the tunnel permanently.
//! The receive loop saw a dead connection, stopped, and nothing rebuilt it, so the path stayed
//! down until the daemon was restarted even once connectivity was back. Worse, the node went on
//! advertising Cloudflare as an available path, so traffic kept being handed to a tunnel that
//! could never carry it again.

use anyhow::{Result, anyhow};
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{Mutex, RwLock};

use super::tunnel::{DeviceIdentity, MasqueTunnel, SNI_CONSUMER, SNI_ZERO_TRUST, TunnelConfig};

/// Longest gap between reconnect attempts.
///
/// Attempts never stop. An outage that outlasts a handful of tries is exactly the case that has
/// to recover unattended, and giving up permanently is indistinguishable to a user from the bug
/// this type was written to fix.
const MAX_BACKOFF: Duration = Duration::from_secs(30);

pub struct CloudflareBackhaul {
    identity: DeviceIdentity,
    endpoint: IpAddr,
    ports: Vec<u16>,
    spki: Option<Vec<u8>>,
    tunnel: RwLock<Arc<MasqueTunnel>>,
    /// Held for the length of a reconnect, so a burst of failures makes one new tunnel rather
    /// than one per failed packet.
    reconnecting: Mutex<()>,
}

impl CloudflareBackhaul {
    pub async fn connect(
        identity: DeviceIdentity,
        endpoint: IpAddr,
        ports: Vec<u16>,
        spki: Option<Vec<u8>>,
    ) -> Result<Self> {
        let first = Self::dial(&identity, endpoint, &ports, &spki).await?;
        Ok(Self {
            identity,
            endpoint,
            ports,
            spki,
            tunnel: RwLock::new(Arc::new(first)),
            reconnecting: Mutex::new(()),
        })
    }

    /// The address Cloudflare handed us, if it told us one.
    pub async fn assigned_v4(&self) -> Option<std::net::Ipv4Addr> {
        self.tunnel.read().await.assigned_v4
    }

    /// Try every SNI and port in preference order.
    ///
    /// Zero Trust may use a different SNI than consumer and it is not documented which, so both
    /// are tried. Ports come back from the API in preference order, 443 first in practice.
    async fn dial(
        identity: &DeviceIdentity,
        endpoint: IpAddr,
        ports: &[u16],
        spki: &Option<Vec<u8>>,
    ) -> Result<MasqueTunnel> {
        let mut last_err = None;
        for sni in [SNI_ZERO_TRUST, SNI_CONSUMER] {
            for port in ports.iter().take(3) {
                let cfg = TunnelConfig {
                    endpoint: SocketAddr::new(endpoint, *port),
                    sni: sni.to_string(),
                    endpoint_spki: spki.clone(),
                };
                match MasqueTunnel::connect(identity, &cfg).await {
                    Ok(t) => {
                        tracing::info!(sni, port, "masque connected");
                        return Ok(t);
                    }
                    Err(e) => {
                        tracing::warn!(sni, port, error = %e, "masque attempt failed");
                        last_err = Some(e);
                    }
                }
            }
        }
        Err(last_err.unwrap_or_else(|| anyhow!("no masque endpoint was reachable")))
    }

    pub async fn send_packet(&self, packet: &[u8]) -> Result<()> {
        self.tunnel.read().await.send_packet(packet)
    }

    /// Receive one packet, rebuilding the tunnel first if this one has died.
    ///
    /// The reconnect is awaited rather than spawned, which also paces the caller: a receive loop
    /// that would otherwise spin on a dead connection blocks here until there is a live one.
    pub async fn recv_packet(&self) -> Result<Vec<u8>> {
        let current = self.tunnel.read().await.clone();
        match current.recv_packet().await {
            Ok(pkt) => Ok(pkt),
            Err(e) => {
                self.reconnect(&current).await;
                Err(e)
            }
        }
    }

    /// Replace a tunnel the caller found broken.
    ///
    /// `stale` is the connection that failed. If the stored one is no longer it, someone else
    /// has already reconnected and there is nothing to do, which is what keeps a burst of
    /// failures from becoming a burst of tunnels.
    async fn reconnect(&self, stale: &Arc<MasqueTunnel>) {
        let _guard = self.reconnecting.lock().await;
        if !Arc::ptr_eq(&*self.tunnel.read().await, stale) {
            return;
        }
        stale.close();

        let mut backoff = Duration::from_secs(1);
        let mut attempt = 0u32;
        loop {
            attempt += 1;
            match Self::dial(&self.identity, self.endpoint, &self.ports, &self.spki).await {
                Ok(fresh) => {
                    *self.tunnel.write().await = Arc::new(fresh);
                    tracing::info!(attempt, "cloudflare tunnel reconnected");
                    return;
                }
                Err(e) => {
                    tracing::warn!(attempt, error = %e, "cloudflare reconnect failed");
                    tokio::time::sleep(backoff).await;
                    backoff = (backoff * 2).min(MAX_BACKOFF);
                }
            }
        }
    }
}
