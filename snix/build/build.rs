use std::io::Result;

fn main() -> Result<()> {
    // SNIX_BUILD_SANDBOX_SHELL is required at compile time for Linux builds
    #[cfg(target_os = "linux")]
    {
        if let Ok(shell_path) = std::env::var("SNIX_BUILD_SANDBOX_SHELL") {
            // Tell cargo to rerun if the sandbox shell binary changes
            println!("cargo:rerun-if-changed={}", shell_path);

            // When embedded-sandbox-shell feature is enabled, verify the file exists
            #[cfg(feature = "embedded-sandbox-shell")]
            {
                if !std::path::Path::new(&shell_path).exists() {
                    panic!(
                        "SNIX_BUILD_SANDBOX_SHELL points to non-existent file: {}",
                        shell_path
                    );
                }
            }
        } else {
            panic!(
                "SNIX_BUILD_SANDBOX_SHELL environment variable must be set at compile time for Linux builds"
            );
        }
    }
    #[allow(unused_mut)]
    let mut builder = tonic_build::configure();

    #[cfg(feature = "tonic-reflection")]
    {
        let out_dir = std::path::PathBuf::from(std::env::var("OUT_DIR").unwrap());
        let descriptor_path = out_dir.join("snix.build.v1.bin");

        builder = builder.file_descriptor_set_path(descriptor_path);
    };

    builder
        .build_server(true)
        .build_client(true)
        .emit_rerun_if_changed(false)
        .bytes(["."])
        .extern_path(".snix.castore.v1", "::snix_castore::proto")
        .compile_protos(
            &[
                "snix/build/protos/build.proto",
                "snix/build/protos/rpc_build.proto",
            ],
            // If we are in running `cargo build` manually, using `../..` works fine,
            // but in case we run inside a nix build, we need to instead point PROTO_ROOT
            // to a custom tree containing that structure.
            &[match std::env::var_os("PROTO_ROOT") {
                Some(proto_root) => proto_root.to_str().unwrap().to_owned(),
                None => "../..".to_string(),
            }],
        )?;

    Ok(())
}
