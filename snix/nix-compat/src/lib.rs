extern crate self as nix_compat;

/// Hashes formatted string data with SHA-256, without an intermediate buffer.
/// Analogous to [`std::fmt::format`].
pub(crate) fn sha256_fmt(fmt: std::fmt::Arguments<'_>) -> [u8; 32] {
    use sha2::Digest;
    use std::io::Write;
    let mut w = sha2::Sha256::new();
    write!(&mut w, "{fmt}").unwrap();
    w.finalize().into()
}

/// Analogous to [`std::format`], but returning only the SHA-256 digest of the formatted string.
macro_rules! sha256 {
    ($($args:tt)*) => {
        $crate::sha256_fmt(format_args!($($args)*))
    };
}

pub(crate) mod aterm;
pub mod derivation;
pub mod log;
pub mod nar;
pub mod narinfo;
pub mod nix_http;
pub mod nixbase32;
pub mod nixcpp;
pub mod nixhash;
pub mod path_info;
pub mod store_path;

#[cfg(feature = "wire")]
pub mod wire;

#[cfg(feature = "daemon")]
pub mod nix_daemon;
#[cfg(feature = "daemon")]
pub use nix_daemon::worker_protocol;
#[cfg(feature = "flakeref")]
pub mod flakeref;
