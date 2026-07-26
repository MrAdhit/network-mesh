//! Serving node binaries so nodes can keep themselves current.
//!
//! The binaries are compiled into this one by `build.rs`, which also hashes them, so answering a
//! manifest request is a lookup rather than any file I/O. A control plane built without
//! artifacts staged simply has an empty table and tells every node there is nothing on offer,
//! which is what a development build should do.
//!
//! Deliberately unauthenticated. These are the same binaries a release page would hand to
//! anyone, they contain no account data, and requiring a token here would mean the CLI could not
//! update itself before its user has logged in.

use axum::{
    extract::Path,
    http::{StatusCode, header},
    response::{IntoResponse, Response},
};
use mesh_core::update::{BinaryInfo, UpdateManifest};

include!(concat!(env!("OUT_DIR"), "/embedded_binaries.rs"));

/// What this control plane holds for one target.
pub async fn manifest(Path(target): Path<String>) -> Response {
    let binaries: Vec<BinaryInfo> = EMBEDDED
        .iter()
        .filter(|e| e.target == target)
        .map(|e| BinaryInfo {
            name: e.name.to_string(),
            sha256: e.sha256.to_string(),
            size: e.bytes.len() as u64,
        })
        .collect();
    // An empty list rather than a 404: "I have nothing for you" is a perfectly good answer and
    // saves every caller from having to treat a missing target as an error.
    axum::Json(UpdateManifest { target, binaries }).into_response()
}

/// The bytes themselves.
pub async fn download(Path((target, name)): Path<(String, String)>) -> Response {
    let Some(found) = EMBEDDED
        .iter()
        .find(|e| e.target == target && e.name == name)
    else {
        return (StatusCode::NOT_FOUND, "no such binary for that target").into_response();
    };
    (
        [
            (header::CONTENT_TYPE, "application/octet-stream".to_string()),
            // The hash is what the client verifies against; sending it here too means a proxy
            // or a curious human can check without fetching the manifest separately.
            (header::ETAG, format!("\"{}\"", found.sha256)),
        ],
        found.bytes,
    )
        .into_response()
}

/// One line at startup, so an operator can see what this control plane will hand out.
pub fn describe() -> String {
    if EMBEDDED.is_empty() {
        return "no node binaries embedded; updates are not offered".into();
    }
    let mut targets: Vec<&str> = EMBEDDED.iter().map(|e| e.target).collect();
    targets.sort_unstable();
    targets.dedup();
    format!(
        "{} binaries embedded for {}",
        EMBEDDED.len(),
        targets.join(", ")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_embedded_table_is_self_consistent() {
        // Whatever happens to be staged, every entry must describe itself honestly: the hash in
        // the table is what nodes compare against, and a mismatch would have every node
        // downloading forever and rejecting what it got.
        for e in EMBEDDED {
            assert_eq!(
                mesh_core::update::sha256_hex(e.bytes),
                e.sha256,
                "{} for {} does not match its recorded hash",
                e.name,
                e.target
            );
            assert!(!e.bytes.is_empty(), "{} for {} is empty", e.name, e.target);
            assert!(
                e.name == "meshd" || e.name == "meshctl",
                "unexpected binary {} embedded",
                e.name
            );
        }
    }

    #[test]
    fn describe_says_something_either_way() {
        assert!(!describe().is_empty());
    }
}
