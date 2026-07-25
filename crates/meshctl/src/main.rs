//! meshctl: talks to meshd over its unix socket.

use anyhow::{Result, bail};
use mesh_core::ipc::{Request, Response, call, default_endpoint};

const USAGE: &str = "\
meshctl - control the mesh daemon and its network

LOCAL NODE:
    meshctl status                      node identity, addresses, backhaul health
    meshctl peers                       peer table with per-path RTT
    meshctl ping <peer> [count]         probe every path separately
    meshctl send <peer> <message...>    send data over the winning path

NETWORK (talks to the control plane):
    meshctl signup <email> <password> [subnet]
    meshctl login <email> <password>
    meshctl network                     subnet, node count, backhaul status
    meshctl set-subnet <cidr>           only while no nodes are enrolled
    meshctl set-cloudflare <api-token> <account-id>
    meshctl set-tailscale <api-token>
    meshctl enrollment-key              mint a key for a new node
    meshctl nodes                       every node, its address and whether it is up
    meshctl remove-node <node-id>

ENVIRONMENT:
    MESH_SOCKET    daemon endpoint (unix: a socket path, windows: a named pipe)
    MESH_CP_URL    control plane base URL
    MESH_SESSION   session token; `login` and `signup` print one to export
";

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() || args[0] == "-h" || args[0] == "--help" {
        print!("{USAGE}");
        return Ok(());
    }

    // Network commands talk to the control plane over HTTP; the rest talk to the local daemon.
    if matches!(
        args[0].as_str(),
        "signup"
            | "login"
            | "network"
            | "set-subnet"
            | "set-cloudflare"
            | "set-tailscale"
            | "enrollment-key"
            | "nodes"
            | "remove-node"
    ) {
        return control_plane(&args).await;
    }

    let endpoint = default_endpoint();
    let req = match args[0].as_str() {
        "status" => Request::Status,
        "peers" => Request::Peers,
        "ping" => {
            if args.len() < 2 {
                bail!("ping needs a peer name");
            }
            Request::Ping {
                peer: args[1].clone(),
                count: args.get(2).and_then(|s| s.parse().ok()).unwrap_or(4),
            }
        }
        "send" => {
            if args.len() < 3 {
                bail!("send needs a peer name and a message");
            }
            Request::Send {
                peer: args[1].clone(),
                data: args[2..].join(" "),
            }
        }
        other => bail!("unknown command {other:?}\n\n{USAGE}"),
    };

    match call(&endpoint, &req).await? {
        Response::Status(s) => {
            println!("node       {}", s.node_name);
            println!("address    {}  in {}", s.virtual_ip, s.subnet);
            println!("uptime     {}s", s.uptime_secs);
            println!("peers      {}", s.peer_count);
            for (label, b) in [("cloudflare", &s.cloudflare), ("tailscale", &s.tailscale)] {
                match b {
                    Some(b) => println!(
                        "{label:<10} {} {}  ({})",
                        if b.up { "up  " } else { "down" },
                        b.address,
                        b.detail
                    ),
                    None => println!("{label:<10} not configured"),
                }
            }
        }
        Response::Peers(peers) => {
            if peers.is_empty() {
                println!("no peers known yet");
            }
            for p in peers {
                println!(
                    "peer {} ({})  cf={}  best={}",
                    p.name,
                    p.virtual_ip.as_deref().unwrap_or("no address"),
                    p.cf_ip.as_deref().unwrap_or("-"),
                    p.best_path.as_deref().unwrap_or("none")
                );
                println!(
                    "  {:<16} {:>6} {:>10} {:>10} {:>7} {:>7} {:>7}",
                    "path", "state", "last ms", "ewma ms", "sent", "recv", "loss %"
                );
                for path in p.paths {
                    println!(
                        "  {:<16} {:>6} {:>10} {:>10} {:>7} {:>7} {:>6.0}%",
                        path.path,
                        if path.up { "up" } else { "down" },
                        fmt_ms(path.last_rtt_ms),
                        fmt_ms(path.ewma_ms),
                        path.sent,
                        path.received,
                        path.loss_pct
                    );
                }
            }
        }
        Response::Ping(samples) => {
            if samples.is_empty() {
                println!("no paths available to probe");
            }
            for s in &samples {
                match s.rtt_ms {
                    Some(ms) => println!("{:<16} seq={} {:>8.2} ms", s.path, s.seq, ms),
                    None => println!("{:<16} seq={}  timeout", s.path, s.seq),
                }
            }

            // Per-path summary, which is the number this whole project exists to produce.
            let mut paths: Vec<&str> = samples.iter().map(|s| s.path.as_str()).collect();
            paths.sort_unstable();
            paths.dedup();
            if !paths.is_empty() {
                println!();
            }
            let mut best: Option<(&str, f64)> = None;
            for p in paths {
                let rtts: Vec<f64> = samples
                    .iter()
                    .filter(|s| s.path == p)
                    .filter_map(|s| s.rtt_ms)
                    .collect();
                let total = samples.iter().filter(|s| s.path == p).count();
                if rtts.is_empty() {
                    println!("{p:<16} no replies ({total} sent)");
                    continue;
                }
                let avg = rtts.iter().sum::<f64>() / rtts.len() as f64;
                let min = rtts.iter().cloned().fold(f64::INFINITY, f64::min);
                let max = rtts.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
                println!(
                    "{p:<16} min {min:.2} avg {avg:.2} max {max:.2} ms  ({}/{} replied)",
                    rtts.len(),
                    total
                );
                if best.map(|(_, b)| avg < b).unwrap_or(true) {
                    best = Some((p, avg));
                }
            }
            if let Some((p, avg)) = best {
                println!("\nwinner: {p} at {avg:.2} ms average");
            }
        }
        Response::Sent { path, bytes } => println!("sent {bytes} bytes over {path}"),
        Response::Ok => println!("ok"),
        Response::Error(e) => {
            eprintln!("error: {e}");
            std::process::exit(1);
        }
    }
    Ok(())
}

fn fmt_ms(v: Option<f64>) -> String {
    v.map(|x| format!("{x:.2}")).unwrap_or_else(|| "-".into())
}

// ---- control plane ----

fn cp_url() -> String {
    std::env::var("MESH_CP_URL").unwrap_or_else(|_| "http://127.0.0.1:8080".into())
}

fn session() -> Result<String> {
    std::env::var("MESH_SESSION")
        .ok()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            anyhow::anyhow!("not logged in: run `meshctl login` and export MESH_SESSION")
        })
}

/// Unwrap the control plane's reply, preferring its own error text over a status code.
async fn unwrap_cp<T: serde::de::DeserializeOwned>(resp: reqwest::Response) -> Result<T> {
    let status = resp.status();
    let text = resp.text().await?;
    if !status.is_success() {
        let msg = serde_json::from_str::<mesh_core::cp::ApiError>(&text)
            .map(|e| e.error)
            .unwrap_or(text);
        bail!("{msg}");
    }
    Ok(serde_json::from_str(&text)?)
}

async fn control_plane(args: &[String]) -> Result<()> {
    use mesh_core::cp::*;
    let base = cp_url();
    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        .build()?;

    match args[0].as_str() {
        "signup" | "login" => {
            if args.len() < 3 {
                bail!("{} needs an email and a password", args[0]);
            }
            let (path, body) = if args[0] == "signup" {
                (
                    "/v1/accounts",
                    serde_json::to_value(SignupRequest {
                        email: args[1].clone(),
                        password: args[2].clone(),
                        subnet: args.get(3).cloned(),
                    })?,
                )
            } else {
                (
                    "/v1/sessions",
                    serde_json::to_value(LoginRequest {
                        email: args[1].clone(),
                        password: args[2].clone(),
                    })?,
                )
            };
            let r: SessionResponse = unwrap_cp(
                http.post(format!("{base}{path}"))
                    .json(&body)
                    .send()
                    .await?,
            )
            .await?;
            println!("account {}", r.account_id);
            println!("\nexport MESH_SESSION={}", r.session_token);
        }
        "network" => {
            let r: NetworkView = unwrap_cp(
                http.get(format!("{base}/v1/network"))
                    .header(SESSION_HEADER, session()?)
                    .send()
                    .await?,
            )
            .await?;
            println!("account     {} ({})", r.account_id, r.email);
            println!("subnet      {}", r.subnet);
            println!(
                "nodes       {} used, {} addresses free",
                r.node_count, r.addresses_available
            );
            println!(
                "cloudflare  {}",
                if r.cloudflare.configured {
                    &r.cloudflare.detail
                } else {
                    "not configured"
                }
            );
            println!(
                "tailscale   {}",
                if r.tailscale.configured {
                    &r.tailscale.detail
                } else {
                    "not configured"
                }
            );
        }
        "set-subnet" => {
            if args.len() < 2 {
                bail!("set-subnet needs a CIDR, e.g. 10.201.0.0/16");
            }
            let r: NetworkView = unwrap_cp(
                http.patch(format!("{base}/v1/network"))
                    .header(SESSION_HEADER, session()?)
                    .json(&SetSubnetRequest {
                        subnet: args[1].clone(),
                    })
                    .send()
                    .await?,
            )
            .await?;
            println!("subnet is now {}", r.subnet);
        }
        "set-cloudflare" => {
            if args.len() < 3 {
                bail!("set-cloudflare needs an API token and an account id");
            }
            println!("provisioning the Zero Trust org, this takes a few seconds...");
            let r: BackhaulStatus = unwrap_cp(
                http.put(format!("{base}/v1/network/backhauls/cloudflare"))
                    .header(SESSION_HEADER, session()?)
                    .json(&CloudflareCredsRequest {
                        api_token: args[1].clone(),
                        account_id: args[2].clone(),
                    })
                    .send()
                    .await?,
            )
            .await?;
            println!("cloudflare ready: {}", r.detail);
        }
        "set-tailscale" => {
            if args.len() < 2 {
                bail!("set-tailscale needs an API token");
            }
            let r: BackhaulStatus = unwrap_cp(
                http.put(format!("{base}/v1/network/backhauls/tailscale"))
                    .header(SESSION_HEADER, session()?)
                    .json(&TailscaleCredsRequest {
                        api_token: args[1].clone(),
                    })
                    .send()
                    .await?,
            )
            .await?;
            println!("tailscale ready: {}", r.detail);
        }
        "enrollment-key" => {
            let r: NewEnrollmentKey = unwrap_cp(
                http.post(format!("{base}/v1/enrollment-keys"))
                    .header(SESSION_HEADER, session()?)
                    .send()
                    .await?,
            )
            .await?;
            println!("{}", r.key);
            println!("\nexpires {}", r.expires_at);
        }
        "nodes" => {
            let r: Vec<NodeView> = unwrap_cp(
                http.get(format!("{base}/v1/nodes"))
                    .header(SESSION_HEADER, session()?)
                    .send()
                    .await?,
            )
            .await?;
            if r.is_empty() {
                println!("no nodes enrolled yet; run `meshctl enrollment-key` and start a meshd");
            }
            for n in r {
                println!(
                    "{:<6} {:<16} {:<24} last seen {}",
                    if n.online { "up" } else { "down" },
                    n.virtual_ip,
                    n.name,
                    n.last_seen.as_deref().unwrap_or("never")
                );
                println!("       {}", n.node_id);
            }
        }
        "remove-node" => {
            if args.len() < 2 {
                bail!("remove-node needs a node id");
            }
            let _: serde_json::Value = unwrap_cp(
                http.delete(format!("{base}/v1/nodes/{}", args[1]))
                    .header(SESSION_HEADER, session()?)
                    .send()
                    .await?,
            )
            .await?;
            println!("removed; its address is free for the next node");
        }
        other => bail!("unknown command {other:?}"),
    }
    Ok(())
}
