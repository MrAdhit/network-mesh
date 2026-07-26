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
}
