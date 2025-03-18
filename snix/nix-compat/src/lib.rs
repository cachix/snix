extern crate self as nix_compat;

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
