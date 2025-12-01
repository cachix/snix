use futures::stream::BoxStream;

pub mod build_request;
pub use crate::buildservice::build_request::*;
mod dummy;
mod from_addr;
mod grpc;

#[cfg(target_os = "linux")]
mod oci;

pub use dummy::DummyBuildService;
pub use from_addr::from_addr;

/// A stream of build events.
pub type BuildEventStream = BoxStream<'static, Result<BuildEvent, std::io::Error>>;

/// Service for executing builds.
pub trait BuildService: Send + Sync {
    /// Execute a build and return a stream of events.
    ///
    /// The stream will emit events as the build progresses:
    /// - `BuildStarted` at the beginning
    /// - `Log` events for stdout/stderr output (line by line)
    /// - `RefscanResult` events for each output after ingestion
    /// - Either `Completed` or `Failed` at the end
    ///
    /// Dropping the stream signals cancellation - the build will be aborted.
    fn do_build(&self, request: BuildRequest) -> BuildEventStream;
}
