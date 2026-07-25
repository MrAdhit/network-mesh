//! Connect-IP over QUIC against Cloudflare's WARP/Mesh endpoint.

use anyhow::{Context, Result, anyhow, bail};
use bytes::BytesMut;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::sync::Mutex;

use super::h3;

pub const SNI_ZERO_TRUST: &str = "zt-masque.cloudflareclient.com";
pub const SNI_CONSUMER: &str = "consumer-masque.cloudflareclient.com";
/// Cloudflare answers CONNECT on this authority. Not a real host we resolve.
pub const CONNECT_AUTHORITY: &str = "cloudflareaccess.com";

/// A P-256 keypair plus the self-signed certificate minted from it.
///
/// The public half is what we PATCH to `/reg`; the certificate is what authenticates us on
/// the data plane. The official client rotates the cert every 24h, which is cosmetic: holding
/// the key is what matters, so we mint one and keep it.
pub struct DeviceIdentity {
    key_pair: rcgen::KeyPair,
    pub cert_der: Vec<u8>,
    pub spki_der: Vec<u8>,
    pub pkcs8_der: Vec<u8>,
}

impl DeviceIdentity {
    pub fn generate() -> Result<Self> {
        let key_pair = rcgen::KeyPair::generate_for(&rcgen::PKCS_ECDSA_P256_SHA256)?;
        Self::from_key_pair(key_pair)
    }

    pub fn from_pkcs8(pkcs8_der: &[u8]) -> Result<Self> {
        let key_pair = rcgen::KeyPair::from_der_and_sign_algo(
            &rustls_pki_types::PrivateKeyDer::Pkcs8(rustls_pki_types::PrivatePkcs8KeyDer::from(
                pkcs8_der.to_vec(),
            )),
            &rcgen::PKCS_ECDSA_P256_SHA256,
        )?;
        Self::from_key_pair(key_pair)
    }

    fn from_key_pair(key_pair: rcgen::KeyPair) -> Result<Self> {
        // rcgen only hands out PEM for the public key; the API wants DER SPKI.
        let spki_der = parse_endpoint_pubkey(&key_pair.public_key_pem())
            .context("rcgen produced a public key PEM we could not decode")?;
        let pkcs8_der = key_pair.serialize_der();
        let params = rcgen::CertificateParams::new(vec!["mesh".to_string()])?;
        let cert = params.self_signed(&key_pair)?;
        Ok(Self {
            cert_der: cert.der().to_vec(),
            spki_der,
            pkcs8_der,
            key_pair,
        })
    }

    pub fn key_pair(&self) -> &rcgen::KeyPair {
        &self.key_pair
    }
}

/// Pins the endpoint by looking for its SPKI inside the presented certificate.
///
/// The SNI we send never matches the endpoint's certificate, so ordinary verification cannot
/// work at all. Cloudflare hands us the endpoint's public key at enrollment time, and a DER
/// SPKI appears verbatim inside the certificate that carries it, so a substring check is a
/// real pin without dragging in an X.509 parser.
#[derive(Debug)]
struct PinnedVerifier {
    spki: Option<Vec<u8>>,
}

impl rustls::client::danger::ServerCertVerifier for PinnedVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &rustls_pki_types::CertificateDer<'_>,
        _intermediates: &[rustls_pki_types::CertificateDer<'_>],
        _server_name: &rustls_pki_types::ServerName<'_>,
        _ocsp: &[u8],
        _now: rustls_pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        match &self.spki {
            None => Ok(rustls::client::danger::ServerCertVerified::assertion()),
            Some(spki) => {
                let cert = end_entity.as_ref();
                if spki.is_empty() || cert.windows(spki.len()).any(|w| w == spki.as_slice()) {
                    Ok(rustls::client::danger::ServerCertVerified::assertion())
                } else {
                    Err(rustls::Error::General(
                        "endpoint public key does not match the one enrolled".into(),
                    ))
                }
            }
        }
    }

    fn verify_tls12_signature(
        &self,
        _m: &[u8],
        _c: &rustls_pki_types::CertificateDer<'_>,
        _d: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _m: &[u8],
        _c: &rustls_pki_types::CertificateDer<'_>,
        _d: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        use rustls::SignatureScheme::*;
        vec![
            ECDSA_NISTP256_SHA256,
            ECDSA_NISTP384_SHA384,
            RSA_PSS_SHA256,
            RSA_PKCS1_SHA256,
            ED25519,
        ]
    }
}

/// Parse the `endpoint_pub_key` from enrollment. Zero Trust returns PEM, consumer returns
/// bare base64. Accept both, return DER SPKI.
pub fn parse_endpoint_pubkey(s: &str) -> Option<Vec<u8>> {
    use base64::{Engine, engine::general_purpose::STANDARD as B64};
    let body: String = if s.contains("-----BEGIN") {
        s.lines()
            .filter(|l| !l.starts_with("-----"))
            .collect::<Vec<_>>()
            .join("")
    } else {
        s.to_string()
    };
    B64.decode(body.trim()).ok()
}

pub struct MasqueTunnel {
    conn: quinn::Connection,
    stream_id: u64,
    /// Held open for the tunnel's lifetime: closing it tears down the CONNECT.
    _send: Mutex<quinn::SendStream>,
    /// The HTTP/3 control and QPACK streams. These are "critical streams": if any of them
    /// closes, the peer kills the whole connection with H3_CLOSED_CRITICAL_STREAM. Dropping
    /// the handles counts as closing them, so they are parked here for the tunnel's lifetime.
    _critical: Vec<quinn::SendStream>,
    pub assigned_v4: Option<std::net::Ipv4Addr>,
}

pub struct TunnelConfig {
    pub endpoint: SocketAddr,
    pub sni: String,
    pub endpoint_spki: Option<Vec<u8>>,
}

impl MasqueTunnel {
    pub async fn connect(identity: &DeviceIdentity, cfg: &TunnelConfig) -> Result<Self> {
        let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());

        let mut tls = rustls::ClientConfig::builder_with_provider(provider.clone())
            .with_protocol_versions(&[&rustls::version::TLS13])?
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(PinnedVerifier {
                spki: cfg.endpoint_spki.clone(),
            }))
            .with_client_auth_cert(
                vec![rustls_pki_types::CertificateDer::from(
                    identity.cert_der.clone(),
                )],
                rustls_pki_types::PrivateKeyDer::Pkcs8(rustls_pki_types::PrivatePkcs8KeyDer::from(
                    identity.pkcs8_der.clone(),
                )),
            )?;
        tls.alpn_protocols = vec![b"h3".to_vec()];
        tls.enable_early_data = false;

        let quic_tls = quinn::crypto::rustls::QuicClientConfig::try_from(tls)
            .context("rustls config is not usable for QUIC")?;
        let mut client_cfg = quinn::ClientConfig::new(Arc::new(quic_tls));

        let mut transport = quinn::TransportConfig::default();
        // Matches the initial packet size the official client uses.
        transport.initial_mtu(1242);
        transport.max_idle_timeout(Some(std::time::Duration::from_secs(30).try_into()?));
        transport.keep_alive_interval(Some(std::time::Duration::from_secs(10)));
        transport.datagram_receive_buffer_size(Some(4 * 1024 * 1024));
        transport.datagram_send_buffer_size(4 * 1024 * 1024);
        client_cfg.transport_config(Arc::new(transport));

        let bind: SocketAddr = if cfg.endpoint.is_ipv4() {
            "0.0.0.0:0".parse()?
        } else {
            "[::]:0".parse()?
        };
        let mut ep = quinn::Endpoint::client(bind)?;
        ep.set_default_client_config(client_cfg);

        tracing::info!(endpoint = %cfg.endpoint, sni = %cfg.sni, "dialing masque endpoint");
        let conn = tokio::time::timeout(
            std::time::Duration::from_secs(8),
            ep.connect(cfg.endpoint, &cfg.sni)?,
        )
        .await
        .map_err(|_| anyhow!("QUIC handshake to {} timed out", cfg.endpoint))?
        .context("QUIC handshake failed")?;

        if conn.max_datagram_size().is_none() {
            bail!("peer did not enable QUIC datagrams; Connect-IP cannot work");
        }

        // HTTP/3 control stream: type byte then SETTINGS. Cloudflare does not advertise
        // ENABLE_CONNECT_PROTOCOL back at us, which we deliberately do not check.
        let mut critical = Vec::new();
        let mut ctrl = conn.open_uni().await?;
        let mut buf = BytesMut::new();
        h3::put_varint(&mut buf, h3::STREAM_TYPE_CONTROL);
        buf.extend_from_slice(&h3::settings_frame());
        ctrl.write_all(&buf).await?;
        critical.push(ctrl);

        // QPACK streams must exist even though we never use the dynamic table.
        for st in [h3::STREAM_TYPE_QPACK_ENCODER, h3::STREAM_TYPE_QPACK_DECODER] {
            let mut s = conn.open_uni().await?;
            let mut b = BytesMut::new();
            h3::put_varint(&mut b, st);
            s.write_all(&b).await?;
            critical.push(s);
        }

        // Wait for the server's control stream and its SETTINGS before issuing CONNECT.
        // connect-ip-go blocks on the same thing, and Cloudflare silently ignores a request
        // that arrives before it has told us its settings.
        wait_for_server_settings(&conn).await?;

        let (mut send, mut recv) = conn.open_bi().await?;
        let stream_id = send.id().index() * 4; // quinn exposes the index, not the wire id

        let fields = h3::encode_field_section(&[
            (":method", "CONNECT"),
            (":protocol", "cf-connect-ip"),
            (":scheme", "https"),
            (":authority", CONNECT_AUTHORITY),
            (":path", "/"),
            // RFC 9297. connect-ip-go always sends this; without it Cloudflare never
            // answers the CONNECT at all.
            ("capsule-protocol", "?1"),
            ("user-agent", ""),
        ]);
        send.write_all(&h3::frame(h3::FRAME_HEADERS, &fields))
            .await?;

        // Response HEADERS. Cloudflare sends no body and no routes, so this is all we wait for.
        let mut acc = Vec::new();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(8);
        let status = loop {
            let remaining = deadline
                .checked_duration_since(std::time::Instant::now())
                .ok_or_else(|| anyhow!("endpoint never answered CONNECT"))?;
            let chunk = tokio::time::timeout(remaining, recv.read_chunk(4096, true))
                .await
                .map_err(|_| anyhow!("endpoint never answered CONNECT"))??
                .ok_or_else(|| anyhow!("endpoint closed the stream before answering CONNECT"))?;
            acc.extend_from_slice(&chunk.bytes);
            if let Some(status) = h3::take_response_status(&mut acc)? {
                break status;
            }
            if acc.len() > 64 * 1024 {
                bail!("CONNECT response never produced a HEADERS frame");
            }
        };

        if status != 200 {
            bail!(
                "CONNECT rejected with status {status}. 401/403 usually means the P-256 key was \
                 never enrolled, or was enrolled against a different device"
            );
        }
        tracing::info!(stream_id, "connect-ip tunnel established");

        Ok(Self {
            conn,
            stream_id,
            _send: Mutex::new(send),
            _critical: critical,
            assigned_v4: None,
        })
    }

    /// Send one raw IP packet.
    pub fn send_packet(&self, packet: &[u8]) -> Result<()> {
        let dg = h3::encode_datagram(self.stream_id, 0, packet);
        self.conn.send_datagram(dg.freeze())?;
        Ok(())
    }

    /// Receive one raw IP packet. Datagrams for other contexts are skipped.
    pub async fn recv_packet(&self) -> Result<Vec<u8>> {
        loop {
            let dg = self.conn.read_datagram().await?;
            let Some((qsid, ctx, pkt)) = h3::decode_datagram(&dg) else {
                continue;
            };
            if qsid == self.stream_id / 4 && ctx == 0 {
                return Ok(pkt.to_vec());
            }
        }
    }

    pub fn max_packet_size(&self) -> usize {
        self.conn
            .max_datagram_size()
            .unwrap_or(1200)
            .saturating_sub(16)
    }

    pub fn close(&self) {
        self.conn.close(0u32.into(), b"bye");
    }
}

/// Read the peer's unidirectional streams until its control stream yields SETTINGS.
///
/// Note we do not inspect the settings themselves. Cloudflare does not advertise
/// ENABLE_CONNECT_PROTOCOL even though extended CONNECT demonstrably works, so checking
/// would only reproduce the bug that stops off-the-shelf clients from talking to it.
async fn wait_for_server_settings(conn: &quinn::Connection) -> Result<()> {
    let work = async {
        loop {
            let mut recv = conn.accept_uni().await?;
            let mut acc = Vec::new();
            // Stream type, then frames.
            loop {
                match recv.read_chunk(4096, true).await? {
                    Some(chunk) => acc.extend_from_slice(&chunk.bytes),
                    None => break,
                }
                let Some((stype, n)) = h3::get_varint(&acc) else {
                    continue;
                };
                if stype != h3::STREAM_TYPE_CONTROL {
                    break; // qpack stream, not interesting
                }
                if let Some((ftype, _, _)) = h3::parse_frame(&acc[n..])?
                    && ftype == h3::FRAME_SETTINGS
                {
                    tracing::debug!("server settings received");
                    return Ok::<(), anyhow::Error>(());
                }
            }
        }
    };
    tokio::time::timeout(std::time::Duration::from_secs(5), work)
        .await
        .map_err(|_| anyhow!("server never sent HTTP/3 SETTINGS"))?
}
