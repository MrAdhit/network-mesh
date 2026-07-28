fn main() {
    // `option_env!("MESH_CP_URL")` is read at compile time, and cargo does not otherwise know
    // that the value participates in the build. Without this, changing it and rebuilding would
    // silently reuse the previously baked URL, which is exactly the kind of thing you only
    // discover after shipping binaries pointing at the wrong control plane.
    println!("cargo:rerun-if-env-changed=MESH_CP_URL");
    // Same reasoning for the update toggle: it is read with `option_env!`, so cargo has to be
    // told it takes part in the build or a rebuild would keep the previous answer.
    println!("cargo:rerun-if-env-changed=MESH_AUTOUPDATE");

    // A node asks the control plane for its own architecture's build, and this is the only
    // place that knows which that is. `TARGET` is set by cargo for build scripts and is not
    // otherwise visible to the crate being built.
    println!(
        "cargo:rustc-env=MESH_TARGET={}",
        std::env::var("TARGET").unwrap_or_else(|_| "unknown".into())
    );

    // The commit these binaries came from. Updates identify a build by its hash, which is the
    // honest answer for "is this the file you shipped", and a useless one for "which source is
    // this". A bug report needs the second.
    //
    // `MESH_GIT_SHA` from the environment wins, because a package built from a tarball has no
    // git directory and its builder knows the answer we cannot look up.
    println!("cargo:rerun-if-env-changed=MESH_GIT_SHA");
    let sha = std::env::var("MESH_GIT_SHA")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .or_else(git_sha)
        .unwrap_or_else(|| "unknown".into());
    println!("cargo:rustc-env=MESH_GIT_SHA={sha}");
}

fn git_sha() -> Option<String> {
    let out = std::process::Command::new("git")
        .args(["rev-parse", "--short=12", "HEAD"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let sha = String::from_utf8(out.stdout).ok()?.trim().to_string();
    // A dirty tree means the binary is not what the commit says it is, and hiding that costs
    // more than the ugly suffix does.
    let dirty = std::process::Command::new("git")
        .args(["status", "--porcelain", "--untracked-files=no"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .is_some_and(|o| !o.stdout.is_empty());
    (!sha.is_empty()).then(|| if dirty { format!("{sha}-dirty") } else { sha })
}
