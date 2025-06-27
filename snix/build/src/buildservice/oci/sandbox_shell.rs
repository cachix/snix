use std::path::PathBuf;

/// Compile-time path to sandbox shell (when embedded-sandbox-shell feature is disabled)
#[cfg(not(feature = "embedded-sandbox-shell"))]
const SNIX_BUILD_SANDBOX_SHELL: &str = env!("SNIX_BUILD_SANDBOX_SHELL");

/// Extract the embedded sandbox shell binary to a temporary location and return its path
fn get_embedded_sandbox_shell_path() -> Result<PathBuf, std::io::Error> {
    #[cfg(feature = "embedded-sandbox-shell")]
    {
        use std::fs;
        use std::os::unix::fs::PermissionsExt;
        use std::sync::{Mutex, OnceLock};

        static EXTRACTED_SANDBOX_SHELL_PATH: OnceLock<Result<PathBuf, String>> = OnceLock::new();
        static INIT_MUTEX: Mutex<()> = Mutex::new(());

        // The embedded sandbox shell binary (included at compile time)
        static EMBEDDED_SANDBOX_SHELL_BINARY: &[u8] =
            include_bytes!(env!("SNIX_BUILD_SANDBOX_SHELL"));

        let result = EXTRACTED_SANDBOX_SHELL_PATH.get_or_init(|| {
            let _guard = INIT_MUTEX.lock().expect("mutex lock failed");

            let temp_dir = std::env::temp_dir();
            let sandbox_shell_path =
                temp_dir.join(format!("snix-sandbox-shell-{}", std::process::id()));

            // Write the binary
            if let Err(e) = fs::write(&sandbox_shell_path, EMBEDDED_SANDBOX_SHELL_BINARY) {
                return Err(e.to_string());
            }

            // Make it executable
            match fs::metadata(&sandbox_shell_path) {
                Ok(metadata) => {
                    let mut perms = metadata.permissions();
                    perms.set_mode(0o755);
                    if let Err(e) = fs::set_permissions(&sandbox_shell_path, perms) {
                        return Err(e.to_string());
                    }
                }
                Err(e) => return Err(e.to_string()),
            }

            tracing::debug!(
                sandbox_shell.path = ?sandbox_shell_path,
                "extracted embedded sandbox shell binary"
            );

            Ok(sandbox_shell_path)
        });

        match result {
            Ok(path) => Ok(path.clone()),
            Err(e) => Err(std::io::Error::new(std::io::ErrorKind::Other, e.clone())),
        }
    }

    #[cfg(not(feature = "embedded-sandbox-shell"))]
    {
        unreachable!(
            "get_embedded_sandbox_shell_path called without embedded-sandbox-shell feature"
        )
    }
}

pub(crate) fn default_sandbox_shell() -> PathBuf {
    if cfg!(feature = "embedded-sandbox-shell") {
        // Extract and use the embedded binary
        match get_embedded_sandbox_shell_path() {
            Ok(path) => path,
            Err(e) => {
                panic!(
                    "Failed to extract embedded sandbox shell: {}\n\
                    \n\
                    The embedded sandbox shell could not be extracted to a temporary location.\n\
                    This might be due to insufficient permissions or disk space in the temp directory.",
                    e
                );
            }
        }
    } else {
        // Use the compile-time path
        PathBuf::from(SNIX_BUILD_SANDBOX_SHELL)
    }
}
