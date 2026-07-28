//! meshctl: talks to meshd over its unix socket.

use anyhow::{Context, Result, bail};
use mesh_core::config::CliConfig;
use mesh_core::ipc::{Request, Response, call, default_endpoint};
use mesh_core::util::{now_unix, rfc3339};

const USAGE: &str = "\
meshctl - control the mesh daemon and its network

LOCAL NODE:
    meshctl status                      node identity, addresses, backhaul health
    meshctl peers                       peer table with per-path RTT
    meshctl ping <peer> [count]         probe every path separately
    meshctl send <peer> <message...>    send data over the winning path
    meshctl join <enrollment-key>       join a network, or rejoin after removal
    meshctl leave                       deregister from the network and stop

NETWORK (talks to the control plane):
    meshctl signup <email> [password] [subnet]
    meshctl login <email> [password]    stores the session; no exporting needed
    meshctl logout                      forget the stored session
    meshctl whoami                      which account this machine acts as
    meshctl network                     subnet, node count, backhaul status
    meshctl set-subnet <cidr>           only while no nodes are enrolled
    meshctl set-cloudflare <api-token> <account-id>
    meshctl set-tailscale <api-token>
    meshctl enrollment-key              mint a key for a new node
    meshctl nodes                       every node, its address and whether it is up
    meshctl remove-node <node-id>

SELF:
    meshctl update                      replace local binaries with the control plane's
    meshctl version                     version, build and target

ENVIRONMENT:
    MESH_SOCKET    daemon endpoint (unix: a socket path, windows: a named pipe)
    MESH_CP_URL    control plane base URL; overrides the stored and compiled-in ones
    MESH_SESSION   session token; overrides the stored one
    MESH_CONFIG    where the session is stored; defaults to the usual per-user place
    MESH_AUTOUPDATE  set to 0 to switch off update checks entirely
";

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() || args[0] == "-h" || args[0] == "--help" {
        print!("{USAGE}");
        return Ok(());
    }

    if matches!(args[0].as_str(), "version" | "--version" | "-V") {
        println!("{}", mesh_core::util::version_line("meshctl"));
        return Ok(());
    }

    // Network commands talk to the control plane over HTTP; the rest talk to the local daemon.
    if matches!(
        args[0].as_str(),
        "signup"
            | "login"
            | "logout"
            | "whoami"
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

    if args[0] == "update" {
        return self_update().await;
    }

    // A cheap look at what the control plane holds, throttled hard so it costs nothing on a
    // normal invocation. Only the manifest is fetched, never a binary: silently downloading
    // fifteen megabytes because somebody ran `meshctl peers` would be rude, and on a machine
    // with a daemon the daemon has already handled it.
    notice_if_stale().await;

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
        "join" => {
            if args.len() < 2 {
                bail!("join needs an enrollment key; mint one with `meshctl enrollment-key`");
            }
            Request::Join {
                key: args[1].clone(),
            }
        }
        "leave" => Request::Leave,
        other => bail!("unknown command {other:?}\n\n{USAGE}"),
    };

    match call(&endpoint, &req).await? {
        Response::Status(s) => {
            println!("node       {}", s.node_name);
            if !s.enrolled {
                println!("state      not enrolled; run `meshctl join <enrollment-key>`");
                return Ok(());
            }
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
        Response::Joined {
            node_id,
            virtual_ip,
            subnet,
        } => {
            println!("joined as {node_id}");
            println!("address   {virtual_ip} in {subnet}");
        }
        Response::Left { node_id, detail } => {
            println!("left the network; {node_id} is gone and its address is free");
            if !detail.is_empty() {
                println!("{detail}");
            }
        }
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

/// Same precedence as the daemon, with the stored login standing in for the enrollment the CLI
/// does not have: the runtime environment, then whichever control plane we logged in to, then
/// whatever was baked in, then a local one for development.
fn cp_url_with(cfg: Option<&CliConfig>) -> String {
    let runtime = std::env::var("MESH_CP_URL").ok();
    mesh_core::state::resolve_cp_url(
        runtime.as_deref(),
        cfg.map(|c| c.cp_url.as_str()),
        mesh_core::state::COMPILED_CP_URL,
    )
    .map(|(url, _)| url)
    .unwrap_or_else(|| "http://127.0.0.1:8080".into())
}

/// For the paths that only need a URL. A broken config file is ignored here rather than fatal:
/// updating should still work when the thing that is wrong is the session.
fn cp_url() -> String {
    cp_url_with(CliConfig::load().ok().flatten().as_ref())
}

/// The session to present, and a useful sentence when there is not one.
///
/// `MESH_SESSION` still wins, because an operator setting it means it now, and scripts and CI
/// depend on it. Everything else comes from the stored login, and only when it belongs to the
/// control plane being addressed.
fn session(cfg: Option<&CliConfig>, base: &str) -> Result<String> {
    if let Ok(v) = std::env::var("MESH_SESSION")
        && !v.is_empty()
    {
        return Ok(v);
    }
    let cfg = cfg.ok_or_else(|| anyhow::anyhow!("not logged in: run `meshctl login <email>`"))?;
    if let Some(token) = cfg.session_for(base) {
        if cfg.expired(now_unix()) {
            bail!(
                "the stored session expired on {}; run `meshctl login <email>`",
                rfc3339(cfg.expires_at.unwrap_or_default())
            );
        }
        return Ok(token.to_string());
    }
    if !cfg.session_token.is_empty() {
        bail!(
            "logged in to {}, but this command is aimed at {base}. Log in there, or clear \
             MESH_CP_URL to use the one you logged in to",
            cfg.cp_url
        );
    }
    bail!("not logged in: run `meshctl login <email>`")
}

/// Read a password without echoing it.
///
/// Prompting is the default and passing one as an argument is the fallback, because an argument
/// lands in shell history and is visible in `ps` to every other user on the machine.
fn ask_password(prompt: &str) -> Result<String> {
    let pw = rpassword::prompt_password(prompt).context("reading a password from the terminal")?;
    if pw.is_empty() {
        bail!("no password given");
    }
    Ok(pw)
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

/// Bring the local binaries up to date, on request.
///
/// Does the daemon too when it sits beside us and we can write to it, because they are shipped
/// as a pair and running mismatched halves is its own class of confusing.
async fn self_update() -> Result<()> {
    if !mesh_core::update::enabled_from_env() {
        println!("automatic updates are switched off (MESH_AUTOUPDATE)");
        return Ok(());
    }
    let url = cp_url();
    let exe = std::env::current_exe().context("finding our own path")?;
    mesh_core::update::sweep_replaced_binary(&exe);

    let mut work = vec![("meshctl", exe.clone())];
    if let Some(d) = mesh_core::update::sibling(&exe, "meshd") {
        work.push(("meshd", d));
    }
    for (name, path) in work {
        match mesh_core::update::update_binary(&url, name, &path).await {
            Ok(mesh_core::update::Outcome::Replaced { sha256 }) => {
                println!("{name}  updated to {}", &sha256[..12]);
                if name == "meshd" {
                    println!("        restart the daemon to run it");
                }
            }
            Ok(mesh_core::update::Outcome::UpToDate) => println!("{name}  already current"),
            Ok(mesh_core::update::Outcome::NotOffered) => {
                println!(
                    "{name}  the control plane has no build for {}",
                    mesh_core::update::TARGET
                )
            }
            Ok(mesh_core::update::Outcome::Disabled) => {}
            Err(e) => println!("{name}  {e}"),
        }
    }
    Ok(())
}

/// How long between the background checks that only print a notice.
const NOTICE_INTERVAL: std::time::Duration = std::time::Duration::from_secs(6 * 3600);

async fn notice_if_stale() {
    if !mesh_core::update::enabled_from_env() {
        return;
    }
    // The marker lives in the temp directory because it is worthless if lost and because the
    // state directory belongs to root, which the CLI usually is not.
    let marker = std::env::temp_dir().join("mesh-update-check");
    if let Ok(m) = std::fs::metadata(&marker)
        && let Ok(age) = m
            .modified()
            .and_then(|t| t.elapsed().map_err(std::io::Error::other))
        && age < NOTICE_INTERVAL
    {
        return;
    }
    let _ = std::fs::write(&marker, b"");

    let Ok(exe) = std::env::current_exe() else {
        return;
    };
    let Ok(manifest) =
        mesh_core::update::fetch_manifest(&cp_url(), mesh_core::update::TARGET).await
    else {
        return; // offline, or a control plane that serves no updates: not worth a word
    };
    let (Some(want), Ok(have)) = (
        manifest.get("meshctl"),
        mesh_core::update::sha256_file(&exe),
    ) else {
        return;
    };
    if want.sha256 != have {
        eprintln!("a newer meshctl is available; run `meshctl update`");
    }
}

async fn control_plane(args: &[String]) -> Result<()> {
    use mesh_core::cp::*;
    // Loaded once and shared: the URL and the session come from the same record on purpose.
    let cfg = CliConfig::load()?;
    let base = cp_url_with(cfg.as_ref());
    let auth = || session(cfg.as_ref(), &base);
    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        .build()?;

    match args[0].as_str() {
        "signup" | "login" => {
            if args.len() < 2 {
                bail!("{} needs an email address", args[0]);
            }
            let email = args[1].clone();
            let password = match args.get(2) {
                Some(p) => p.clone(),
                None => {
                    let pw = ask_password("password: ")?;
                    // A mistyped password at signup is unrecoverable: there is no reset, and the
                    // account it creates is one nobody can log in to.
                    if args[0] == "signup" && ask_password("password again: ")? != pw {
                        bail!("those did not match");
                    }
                    pw
                }
            };
            let (path, body) = if args[0] == "signup" {
                (
                    "/v1/accounts",
                    serde_json::to_value(SignupRequest {
                        email: email.clone(),
                        password,
                        subnet: args.get(3).cloned(),
                    })?,
                )
            } else {
                (
                    "/v1/sessions",
                    serde_json::to_value(LoginRequest {
                        email: email.clone(),
                        password,
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
            let stored = CliConfig {
                cp_url: base.clone(),
                session_token: r.session_token,
                account_id: r.account_id.clone(),
                email: Some(email),
                expires_at: (r.expires_at > 0).then_some(r.expires_at),
            }
            .save()?;
            println!("account {}", r.account_id);
            println!("session stored in {}", stored.display());
            if r.expires_at > 0 {
                println!("expires {}", rfc3339(r.expires_at));
            }
        }
        "logout" => match CliConfig::clear()? {
            Some(path) => {
                println!("removed {}", path.display());
                if std::env::var("MESH_SESSION").is_ok_and(|v| !v.is_empty()) {
                    println!("MESH_SESSION is still set in this shell and overrides the file");
                }
            }
            None => println!("no stored session"),
        },
        "whoami" => match cfg.as_ref().filter(|c| !c.session_token.is_empty()) {
            Some(c) => {
                println!("account       {}", c.account_id);
                if let Some(e) = &c.email {
                    println!("email         {e}");
                }
                println!("control plane {}", c.cp_url);
                match c.expires_at {
                    Some(e) if c.expired(now_unix()) => {
                        println!("session       expired {}", rfc3339(e))
                    }
                    Some(e) => println!("session       valid until {}", rfc3339(e)),
                    None => println!("session       stored"),
                }
                if !mesh_core::config::same_cp(&c.cp_url, &base) {
                    println!(
                        "\nnote: commands are aimed at {base}, which is not where this session is from"
                    );
                }
            }
            None if std::env::var("MESH_SESSION").is_ok_and(|v| !v.is_empty()) => {
                println!("using MESH_SESSION from the environment, against {base}");
            }
            None => println!("not logged in"),
        },
        "network" => {
            let r: NetworkView = unwrap_cp(
                http.get(format!("{base}/v1/network"))
                    .header(SESSION_HEADER, auth()?)
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
                    .header(SESSION_HEADER, auth()?)
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
                    .header(SESSION_HEADER, auth()?)
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
                    .header(SESSION_HEADER, auth()?)
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
                    .header(SESSION_HEADER, auth()?)
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
                    .header(SESSION_HEADER, auth()?)
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
                    .header(SESSION_HEADER, auth()?)
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
