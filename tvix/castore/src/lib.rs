mod digests;
mod errors;
mod hashing_reader;

pub mod blobservice;
pub mod composition;
pub mod directoryservice;
pub mod fixtures;
pub mod refscan;
pub mod utils;

#[cfg(feature = "fs")]
pub mod fs;

mod nodes;
pub use nodes::*;

mod path;
pub use path::{Path, PathBuf, PathComponent, PathComponentError};

pub mod import;
pub mod proto;
pub mod tonic;

// Used as user agent in various HTTP Clients
const USER_AGENT: &str = concat!(env!("CARGO_PKG_NAME"), "/", env!("CARGO_PKG_VERSION"));

pub use digests::B3Digest;
pub use errors::{DirectoryError, Error, ValidateNodeError};
pub use hashing_reader::{B3HashingReader, HashingReader};

#[cfg(test)]
mod tests;

// That's what the rstest_reuse README asks us do, and fails about being unable
// to find rstest_reuse in crate root.
#[cfg(test)]
#[allow(clippy::single_component_path_imports)]
use rstest_reuse;
