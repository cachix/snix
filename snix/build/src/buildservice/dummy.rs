use futures::stream;
use tracing::instrument;

use super::{BuildEventStream, BuildService};
use crate::buildservice::BuildRequest;

#[derive(Default)]
pub struct DummyBuildService {}

impl BuildService for DummyBuildService {
    #[instrument(skip(self))]
    fn do_build(&self, _request: BuildRequest) -> BuildEventStream {
        Box::pin(stream::once(async {
            Err(std::io::Error::other(
                "builds are not supported with DummyBuildService",
            ))
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures::StreamExt;
    use std::collections::BTreeMap;
    use std::path::PathBuf;

    fn make_dummy_request() -> BuildRequest {
        BuildRequest {
            inputs: BTreeMap::new(),
            command_args: vec!["echo".to_string(), "hello".to_string()],
            working_dir: PathBuf::from("build"),
            scratch_paths: vec![PathBuf::from("build")],
            inputs_dir: PathBuf::from("nix/store"),
            outputs: vec![PathBuf::from("build/out")],
            environment_vars: vec![],
            constraints: Default::default(),
            additional_files: vec![],
            refscan_needles: vec![],
        }
    }

    #[tokio::test]
    async fn test_dummy_build_service_returns_error_stream() {
        let service = DummyBuildService::default();
        let mut stream = service.do_build(make_dummy_request());

        // First item should be an error
        let first = stream.next().await;
        assert!(first.is_some(), "stream should yield at least one item");

        let result = first.unwrap();
        assert!(result.is_err(), "should be an error");

        let err = result.unwrap_err();
        assert!(
            err.to_string()
                .contains("builds are not supported with DummyBuildService"),
            "error message should explain builds are not supported"
        );

        // Stream should end after the error
        let second = stream.next().await;
        assert!(second.is_none(), "stream should end after the error");
    }
}
