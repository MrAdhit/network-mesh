fn main() {
    // `option_env!("MESH_CP_URL")` is read at compile time, and cargo does not otherwise know
    // that the value participates in the build. Without this, changing it and rebuilding would
    // silently reuse the previously baked URL, which is exactly the kind of thing you only
    // discover after shipping binaries pointing at the wrong control plane.
    println!("cargo:rerun-if-env-changed=MESH_CP_URL");
}
