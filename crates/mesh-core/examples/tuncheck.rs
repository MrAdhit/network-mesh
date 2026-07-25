//! Bring up the mesh interface on its own, without a control plane or any backhaul.
//!
//! Exists because the TUN layer is the one part that cannot be exercised by a unit test: it
//! needs a real kernel interface and, on both platforms, root. Running this is how you find out
//! whether the platform code works before wiring a whole daemon around it.
//!
//! Usage: sudo cargo run -p mesh-core --example tuncheck [name] [address] [subnet]

use anyhow::Result;
use mesh_core::tun::{MTU, TunDevice};

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::INFO)
        .init();

    let mut args = std::env::args().skip(1);
    let name = args.next().unwrap_or_else(|| default_name().to_string());
    let address: std::net::Ipv4Addr = args
        .next()
        .unwrap_or_else(|| "10.201.99.1".into())
        .parse()?;
    let subnet = args.next().unwrap_or_else(|| "10.201.99.0/24".into());

    println!("opening {name} with {address} in {subnet}, mtu {MTU}");
    let dev = TunDevice::open(&name, address, &subnet)?;
    println!("up as {}", dev.name);
    println!("try it from another terminal:  ping {address}");
    println!("reading packets, ctrl-c to stop");

    loop {
        let pkt = dev.recv().await?;
        let dst = mesh_core::tun::ipv4_destination(&pkt);
        println!(
            "{} bytes, version {}, dst {:?}",
            pkt.len(),
            pkt.first().map(|b| b >> 4).unwrap_or(0),
            dst
        );
        // Echo it straight back so the interface demonstrably carries traffic both ways.
        if let Some(reply) = swap_ipv4_endpoints(&pkt) {
            dev.send(&reply).await?;
        }
    }
}

fn default_name() -> &'static str {
    if cfg!(target_os = "macos") {
        "utun"
    } else {
        "mesh0"
    }
}

/// Swap source and destination so a reply goes back where the packet came from.
///
/// Enough to prove the write path works. The IPv4 header checksum is unchanged because
/// swapping two fields that both feed it leaves the sum identical.
fn swap_ipv4_endpoints(pkt: &[u8]) -> Option<Vec<u8>> {
    if pkt.len() < 20 || pkt[0] >> 4 != 4 {
        return None;
    }
    let mut out = pkt.to_vec();
    let (src, dst) = (out[12..16].to_vec(), out[16..20].to_vec());
    out[12..16].copy_from_slice(&dst);
    out[16..20].copy_from_slice(&src);
    Some(out)
}
