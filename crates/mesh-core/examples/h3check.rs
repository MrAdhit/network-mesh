//! Validate our hand-rolled HTTP/3 against a known-good server.
//!
//! If this prints a status, the QPACK encoder, frame writer and status decoder are correct
//! and any WARP failure is WARP-specific rather than a bug in our HTTP/3.
//!
//! Usage: cargo run -p mesh-core --example h3check -- cloudflare-quic.com

use anyhow::{Context, Result, anyhow, bail};
use bytes::BytesMut;
use mesh_core::cloudflare::h3;
use std::sync::Arc;
use tokio::io::AsyncWriteExt;

#[tokio::main]
async fn main() -> Result<()> {
    let host = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "cloudflare-quic.com".to_string());

    let addr = tokio::net::lookup_host((host.as_str(), 443))
        .await?
        .find(|a| a.is_ipv4())
        .ok_or_else(|| anyhow!("no A record for {host}"))?;
    println!("connecting to {host} at {addr}");

    let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let mut tls = rustls::ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .with_root_certificates(roots)
        .with_no_client_auth();
    tls.alpn_protocols = vec![b"h3".to_vec()];

    let quic_tls = quinn::crypto::rustls::QuicClientConfig::try_from(tls)?;
    let mut client_cfg = quinn::ClientConfig::new(Arc::new(quic_tls));
    let mut transport = quinn::TransportConfig::default();
    transport.datagram_receive_buffer_size(Some(1 << 20));
    client_cfg.transport_config(Arc::new(transport));

    let mut ep = quinn::Endpoint::client("0.0.0.0:0".parse()?)?;
    ep.set_default_client_config(client_cfg);
    let conn = ep.connect(addr, &host)?.await.context("handshake")?;
    println!("quic connected, alpn ok");

    // Control stream + SETTINGS, kept alive.
    let mut ctrl = conn.open_uni().await?;
    let mut buf = BytesMut::new();
    h3::put_varint(&mut buf, h3::STREAM_TYPE_CONTROL);
    buf.extend_from_slice(&h3::settings_frame());
    ctrl.write_all(&buf).await?;
    ctrl.flush().await?;

    let mut qpack = Vec::new();
    for st in [h3::STREAM_TYPE_QPACK_ENCODER, h3::STREAM_TYPE_QPACK_DECODER] {
        let mut s = conn.open_uni().await?;
        let mut b = BytesMut::new();
        h3::put_varint(&mut b, st);
        s.write_all(&b).await?;
        s.flush().await?;
        qpack.push(s);
    }

    let (mut send, mut recv) = conn.open_bi().await?;
    let fields = h3::encode_field_section(&[
        (":method", "GET"),
        (":scheme", "https"),
        (":authority", &host),
        (":path", "/"),
        ("user-agent", "mesh-h3check"),
    ]);
    send.write_all(&h3::frame(h3::FRAME_HEADERS, &fields))
        .await?;
    send.finish()?;
    println!("request sent, {} bytes of qpack", fields.len());

    let mut acc = Vec::new();
    let mut dumped = false;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    loop {
        let remaining = deadline
            .checked_duration_since(std::time::Instant::now())
            .ok_or_else(|| anyhow!("no response within 10s"))?;
        match tokio::time::timeout(remaining, recv.read_chunk(4096, true)).await {
            Ok(Ok(Some(chunk))) => acc.extend_from_slice(&chunk.bytes),
            Ok(Ok(None)) => bail!("stream ended after {} bytes", acc.len()),
            Ok(Err(e)) => bail!("read error: {e}"),
            Err(_) => bail!("timed out with {} bytes buffered", acc.len()),
        }
        if acc.len() >= 32 && !dumped {
            println!("first 32 bytes: {:02x?}", &acc[..32]);
            dumped = true;
        }
        if let Some(status) = h3::take_response_status(&mut acc)? {
            println!("HTTP status {status}");
            return Ok(());
        }
    }
}
