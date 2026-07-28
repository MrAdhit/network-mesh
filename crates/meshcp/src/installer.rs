//! Serving the install and uninstall scripts.
//!
//! The control plane already hands out the binaries, so it is also the sensible place to hand
//! out the thing that fetches them: one URL is the whole install, and it cannot point at a
//! control plane other than itself.
//!
//! Unauthenticated, like the update endpoints and for the same reason. These scripts contain no
//! account data, and requiring a credential to download an installer would mean needing the CLI
//! before you can install the CLI.
//!
//! Served as `text/plain` deliberately. People pipe this into a shell, and anything that
//! encourages reading it first is worth the header.

use axum::http::{HeaderMap, header};
use axum::response::IntoResponse;

const INSTALL: &str = include_str!("../../../packaging/install.sh");
const UNINSTALL: &str = include_str!("../../../packaging/uninstall.sh");

/// Where a script downloaded from us should point back to.
///
/// The request's own `Host` is the best answer available: it is what the user typed, so it is
/// reachable from where they are, which a compiled-in default or a bind address need not be.
/// `MESH_CP_PUBLIC_URL` overrides for the case where this sits behind something that rewrites
/// the host.
fn public_url(h: &HeaderMap) -> String {
    if let Ok(v) = std::env::var("MESH_CP_PUBLIC_URL")
        && !v.trim().is_empty()
    {
        return v.trim().trim_end_matches('/').to_string();
    }
    let host = h
        .get(header::HOST)
        .and_then(|v| v.to_str().ok())
        .filter(|s| !s.is_empty());
    let Some(host) = host else {
        // Nothing to go on. The compiled-in URL is what the binaries themselves were built to
        // talk to, so it is the right fallback rather than a guess at our own address.
        return mesh_core::state::COMPILED_CP_URL
            .unwrap_or("http://127.0.0.1:8080")
            .trim_end_matches('/')
            .to_string();
    };
    // A proxy that terminated TLS is the only thing that knows the scheme the user used.
    let scheme = h
        .get("x-forwarded-proto")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.split(',').next().unwrap_or(s).trim().to_string())
        .unwrap_or_else(|| {
            if host.starts_with("localhost") || host.starts_with("127.") {
                "http".into()
            } else {
                "https".into()
            }
        });
    format!("{scheme}://{host}")
}

fn script(body: &str, headers: &HeaderMap) -> ([(header::HeaderName, &'static str); 1], String) {
    (
        [(header::CONTENT_TYPE, "text/plain; charset=utf-8")],
        body.replace("@CP_URL@", &public_url(headers)),
    )
}

pub async fn install(headers: HeaderMap) -> impl IntoResponse {
    script(INSTALL, &headers)
}

pub async fn uninstall(headers: HeaderMap) -> impl IntoResponse {
    script(UNINSTALL, &headers)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn headers(pairs: &[(&str, &str)]) -> HeaderMap {
        let mut h = HeaderMap::new();
        for (k, v) in pairs {
            h.insert(
                axum::http::HeaderName::from_bytes(k.as_bytes()).unwrap(),
                v.parse().unwrap(),
            );
        }
        h
    }

    #[test]
    fn the_placeholder_is_always_replaced() {
        // A script that reached a user still holding @CP_URL@ would refuse to run, which is the
        // right failure but a pointless one to ship.
        let h = headers(&[("host", "mesh.example.net")]);
        for body in [INSTALL, UNINSTALL] {
            let out = body.replace("@CP_URL@", &public_url(&h));
            assert!(!out.contains("@CP_URL@"));
        }
        assert!(
            INSTALL.contains("@CP_URL@"),
            "install.sh lost its placeholder"
        );
    }

    #[test]
    fn the_host_the_user_typed_is_what_the_script_points_at() {
        assert_eq!(
            public_url(&headers(&[("host", "mesh.example.net")])),
            "https://mesh.example.net"
        );
        // A local control plane is not reachable over TLS, and assuming otherwise breaks the
        // development loop for no benefit.
        assert_eq!(
            public_url(&headers(&[("host", "127.0.0.1:8080")])),
            "http://127.0.0.1:8080"
        );
        // Behind a proxy, only the proxy knows what the user actually used.
        assert_eq!(
            public_url(&headers(&[
                ("host", "mesh.example.net"),
                ("x-forwarded-proto", "http")
            ])),
            "http://mesh.example.net"
        );
    }
}
