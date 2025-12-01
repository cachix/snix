use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::path::{Path, PathBuf};

use itertools::Itertools;
use snix_castore::{DirectoryError, Node, PathComponent};

mod grpc_buildservice_wrapper;

pub use grpc_buildservice_wrapper::GRPCBuildServiceWrapper;

use crate::buildservice::BuildResult;

tonic::include_proto!("snix.build.v1");

#[cfg(feature = "tonic-reflection")]
/// Compiled file descriptors for implementing [gRPC
/// reflection](https://github.com/grpc/grpc/blob/master/doc/server-reflection.md) with e.g.
/// [`tonic_reflection`](https://docs.rs/tonic-reflection).
pub const FILE_DESCRIPTOR_SET: &[u8] = tonic::include_file_descriptor_set!("snix.build.v1");

/// Errors that occur during the validation of [BuildRequest] messages.
#[derive(Debug, thiserror::Error)]
pub enum ValidateBuildRequestError {
    #[error("invalid input node at position {0}: {1}")]
    InvalidInputNode(usize, DirectoryError),

    #[error("input nodes are not sorted by name")]
    InputNodesNotSorted,

    #[error("invalid working_dir")]
    InvalidWorkingDir,

    #[error("scratch_paths not sorted")]
    ScratchPathsNotSorted,

    #[error("invalid scratch path at position {0}")]
    InvalidScratchPath(usize),

    #[error("invalid inputs_dir")]
    InvalidInputsDir,

    #[error("invalid output path at position {0}")]
    InvalidOutputPath(usize),

    #[error("outputs not sorted")]
    OutputsNotSorted,

    #[error("invalid environment variable at position {0}")]
    InvalidEnvVar(usize),

    #[error("EnvVar not sorted by their keys")]
    EnvVarNotSorted,

    #[error("invalid build constraints: {0}")]
    InvalidBuildConstraints(ValidateBuildConstraintsError),

    #[error("invalid additional file path at position: {0}")]
    InvalidAdditionalFilePath(usize),

    #[error("additional_files not sorted")]
    AdditionalFilesNotSorted,
}

/// Checks a path to be without any '..' components, and clean (no superfluous
/// slashes).
fn is_clean_path<P: AsRef<Path>>(p: P) -> bool {
    let p = p.as_ref();

    // Look at all components, bail in case of ".", ".." and empty normal
    // segments (superfluous slashes)
    // We still need to assemble a cleaned PathBuf, and compare the OsString
    // later, as .components() already does do some normalization before
    // yielding.
    let mut cleaned_p = PathBuf::new();
    for component in p.components() {
        match component {
            std::path::Component::Prefix(_) => {}
            std::path::Component::RootDir => {}
            std::path::Component::CurDir => return false,
            std::path::Component::ParentDir => return false,
            std::path::Component::Normal(a) => {
                if a.is_empty() {
                    return false;
                }
            }
        }
        cleaned_p.push(component);
    }

    // if cleaned_p looks like p, we're good.
    if cleaned_p.as_os_str() != p.as_os_str() {
        return false;
    }

    true
}

fn is_clean_relative_path<P: AsRef<Path>>(p: P) -> bool {
    if p.as_ref().is_absolute() {
        return false;
    }

    is_clean_path(p)
}

fn is_clean_absolute_path<P: AsRef<Path>>(p: P) -> bool {
    if !p.as_ref().is_absolute() {
        return false;
    }

    is_clean_path(p)
}

/// Checks if a given list is sorted.
fn is_sorted<I>(data: I) -> bool
where
    I: Iterator,
    I::Item: Ord + Clone,
{
    data.tuple_windows().all(|(a, b)| a <= b)
}

fn path_to_string(path: &Path) -> String {
    path.to_str()
        .expect("Snix Bug: unable to convert Path to String")
        .to_string()
}

impl From<crate::buildservice::BuildRequest> for BuildRequest {
    fn from(value: crate::buildservice::BuildRequest) -> Self {
        let constraints = if value.constraints.is_empty() {
            None
        } else {
            let mut constraints = build_request::BuildConstraints::default();
            for constraint in value.constraints {
                use crate::buildservice::BuildConstraints;
                match constraint {
                    BuildConstraints::System(system) => constraints.system = system,
                    BuildConstraints::MinMemory(min_memory) => constraints.min_memory = min_memory,
                    BuildConstraints::AvailableReadOnlyPath(path) => {
                        constraints.available_ro_paths.push(path_to_string(&path))
                    }
                    BuildConstraints::ProvideBinSh => constraints.provide_bin_sh = true,
                    BuildConstraints::NetworkAccess => constraints.network_access = true,
                }
            }
            Some(constraints)
        };
        Self {
            inputs: value
                .inputs
                .into_iter()
                .map(|(name, node)| {
                    snix_castore::proto::Entry::from_name_and_node(name.into(), node)
                })
                .collect(),
            command_args: value.command_args,
            working_dir: path_to_string(&value.working_dir),
            scratch_paths: value
                .scratch_paths
                .iter()
                .map(|p| path_to_string(p))
                .collect(),
            inputs_dir: path_to_string(&value.inputs_dir),
            outputs: value.outputs.iter().map(|p| path_to_string(p)).collect(),
            environment_vars: value.environment_vars.into_iter().map(Into::into).collect(),
            constraints,
            additional_files: value.additional_files.into_iter().map(Into::into).collect(),
            refscan_needles: value.refscan_needles,
        }
    }
}

impl TryFrom<BuildRequest> for crate::buildservice::BuildRequest {
    type Error = ValidateBuildRequestError;
    fn try_from(value: BuildRequest) -> Result<Self, Self::Error> {
        // validate input names. Make sure they're sorted

        let mut last_name: bytes::Bytes = "".into();
        let mut inputs: BTreeMap<PathComponent, Node> = BTreeMap::new();
        for (i, node) in value.inputs.iter().enumerate() {
            let (name, node) = node
                .clone()
                .try_into_name_and_node()
                .map_err(|e| ValidateBuildRequestError::InvalidInputNode(i, e))?;

            if name.as_ref() <= last_name.as_ref() {
                return Err(ValidateBuildRequestError::InputNodesNotSorted);
            } else {
                inputs.insert(name.clone(), node);
                last_name = name.into();
            }
        }

        // validate working_dir
        if !is_clean_relative_path(&value.working_dir) {
            Err(ValidateBuildRequestError::InvalidWorkingDir)?;
        }

        // validate scratch paths
        for (i, p) in value.scratch_paths.iter().enumerate() {
            if !is_clean_relative_path(p) {
                Err(ValidateBuildRequestError::InvalidScratchPath(i))?
            }
        }
        if !is_sorted(value.scratch_paths.iter().map(|e| e.as_bytes())) {
            Err(ValidateBuildRequestError::ScratchPathsNotSorted)?;
        }

        // validate inputs_dir
        if !is_clean_relative_path(&value.inputs_dir) {
            Err(ValidateBuildRequestError::InvalidInputsDir)?;
        }

        // validate outputs
        for (i, p) in value.outputs.iter().enumerate() {
            if !is_clean_relative_path(p) {
                Err(ValidateBuildRequestError::InvalidOutputPath(i))?
            }
        }
        if !is_sorted(value.outputs.iter().map(|e| e.as_bytes())) {
            Err(ValidateBuildRequestError::OutputsNotSorted)?;
        }

        // validate environment_vars.
        for (i, e) in value.environment_vars.iter().enumerate() {
            if e.key.is_empty() || e.key.contains('=') || e.key.contains('\0') {
                Err(ValidateBuildRequestError::InvalidEnvVar(i))?
            }
            if e.value.contains(&0) {
                Err(ValidateBuildRequestError::InvalidEnvVar(i))?
            }
        }
        if !is_sorted(value.environment_vars.iter().map(|e| e.key.as_bytes())) {
            Err(ValidateBuildRequestError::EnvVarNotSorted)?;
        }

        // validate build constraints
        let constraints = value
            .constraints
            .map_or(Ok(HashSet::new()), |constraints| {
                constraints
                    .try_into()
                    .map_err(ValidateBuildRequestError::InvalidBuildConstraints)
            })?;

        // validate additional_files
        for (i, additional_file) in value.additional_files.iter().enumerate() {
            if !is_clean_relative_path(&additional_file.path) {
                Err(ValidateBuildRequestError::InvalidAdditionalFilePath(i))?
            }
        }
        if !is_sorted(value.additional_files.iter().map(|e| e.path.as_bytes())) {
            Err(ValidateBuildRequestError::AdditionalFilesNotSorted)?;
        }

        Ok(Self {
            inputs,
            command_args: value.command_args,
            working_dir: PathBuf::from(value.working_dir),
            scratch_paths: value.scratch_paths.iter().map(PathBuf::from).collect(),
            inputs_dir: PathBuf::from(value.inputs_dir),
            outputs: value.outputs.iter().map(PathBuf::from).collect(),
            environment_vars: value.environment_vars.into_iter().map(Into::into).collect(),
            constraints,
            additional_files: value.additional_files.into_iter().map(Into::into).collect(),
            refscan_needles: value.refscan_needles,
        })
    }
}

/// Errors that occur during the validation of
/// [build_request::BuildConstraints] messages.
#[derive(Debug, thiserror::Error)]
pub enum ValidateBuildConstraintsError {
    #[error("invalid system")]
    InvalidSystem,

    #[error("invalid available_ro_paths at position {0}")]
    InvalidAvailableRoPaths(usize),

    #[error("available_ro_paths not sorted")]
    AvailableRoPathsNotSorted,
}

impl From<build_request::EnvVar> for crate::buildservice::EnvVar {
    fn from(value: build_request::EnvVar) -> Self {
        Self {
            key: value.key,
            value: value.value,
        }
    }
}

impl From<crate::buildservice::EnvVar> for build_request::EnvVar {
    fn from(value: crate::buildservice::EnvVar) -> Self {
        Self {
            key: value.key,
            value: value.value,
        }
    }
}

impl From<build_request::AdditionalFile> for crate::buildservice::AdditionalFile {
    fn from(value: build_request::AdditionalFile) -> Self {
        Self {
            path: PathBuf::from(value.path),
            contents: value.contents,
        }
    }
}

impl From<crate::buildservice::AdditionalFile> for build_request::AdditionalFile {
    fn from(value: crate::buildservice::AdditionalFile) -> Self {
        Self {
            path: value
                .path
                .to_str()
                .expect("Snix bug: expected a valid path")
                .to_string(),
            contents: value.contents,
        }
    }
}

impl TryFrom<build_request::BuildConstraints> for HashSet<crate::buildservice::BuildConstraints> {
    type Error = ValidateBuildConstraintsError;
    fn try_from(value: build_request::BuildConstraints) -> Result<Self, Self::Error> {
        use crate::buildservice::BuildConstraints;

        // validate system
        if value.system.is_empty() {
            Err(ValidateBuildConstraintsError::InvalidSystem)?;
        }

        let mut build_constraints = HashSet::from([
            BuildConstraints::System(value.system),
            BuildConstraints::MinMemory(value.min_memory),
        ]);

        // validate available_ro_paths
        for (i, p) in value.available_ro_paths.iter().enumerate() {
            if !is_clean_absolute_path(p) {
                Err(ValidateBuildConstraintsError::InvalidAvailableRoPaths(i))?
            } else {
                build_constraints.insert(BuildConstraints::AvailableReadOnlyPath(PathBuf::from(p)));
            }
        }
        if !is_sorted(value.available_ro_paths.iter().map(|e| e.as_bytes())) {
            Err(ValidateBuildConstraintsError::AvailableRoPathsNotSorted)?;
        }

        if value.network_access {
            build_constraints.insert(BuildConstraints::NetworkAccess);
        }
        if value.provide_bin_sh {
            build_constraints.insert(BuildConstraints::ProvideBinSh);
        }

        Ok(build_constraints)
    }
}

/// Errors that occur during the validation of [BuildEvent] messages.
#[derive(Debug, thiserror::Error)]
pub enum ValidateBuildEventError {
    #[error("event field is not set")]
    MissingEventField,
    #[error("invalid log stream")]
    InvalidLogStream,
    #[error("invalid build completed")]
    InvalidBuildCompleted(ValidateBuildCompletedError),
}

/// Errors that occur during the validation of [BuildCompleted] messages.
#[derive(Debug, thiserror::Error)]
pub enum ValidateBuildCompletedError {
    #[error("output entry {0} missing")]
    MissingOutputEntry(usize),
    #[error("output entry {0} invalid")]
    InvalidOutputEntry(usize),
}

// === BuildEvent conversions ===

impl From<crate::buildservice::BuildEvent> for build_event::Event {
    fn from(value: crate::buildservice::BuildEvent) -> Self {
        use crate::buildservice::BuildEvent as BE;
        match value {
            BE::Started(started) => build_event::Event::Started(started.into()),
            BE::Log(log) => build_event::Event::Log(log.into()),
            BE::RefscanResult(result) => build_event::Event::Refscan(result.into()),
            BE::Completed(result) => build_event::Event::Completed(result.into()),
            BE::Failed(error) => build_event::Event::Failed(error.into()),
        }
    }
}

impl From<crate::buildservice::BuildEvent> for BuildEvent {
    fn from(value: crate::buildservice::BuildEvent) -> Self {
        Self {
            event: Some(value.into()),
        }
    }
}

impl TryFrom<BuildEvent> for crate::buildservice::BuildEvent {
    type Error = ValidateBuildEventError;

    fn try_from(value: BuildEvent) -> Result<Self, Self::Error> {
        let event = value.event.ok_or(ValidateBuildEventError::MissingEventField)?;
        event.try_into()
    }
}

impl TryFrom<build_event::Event> for crate::buildservice::BuildEvent {
    type Error = ValidateBuildEventError;

    fn try_from(value: build_event::Event) -> Result<Self, Self::Error> {
        use crate::buildservice::BuildEvent as BE;
        Ok(match value {
            build_event::Event::Started(started) => BE::Started(started.into()),
            build_event::Event::Log(log) => BE::Log(log.try_into()?),
            build_event::Event::Refscan(result) => BE::RefscanResult(result.into()),
            build_event::Event::Completed(completed) => {
                BE::Completed(completed.try_into().map_err(ValidateBuildEventError::InvalidBuildCompleted)?)
            }
            build_event::Event::Failed(failed) => BE::Failed(failed.into()),
        })
    }
}

// === BuildStarted conversions ===

impl From<crate::buildservice::BuildStarted> for BuildStarted {
    fn from(value: crate::buildservice::BuildStarted) -> Self {
        Self {
            build_id: value.build_id,
        }
    }
}

impl From<BuildStarted> for crate::buildservice::BuildStarted {
    fn from(value: BuildStarted) -> Self {
        Self {
            build_id: value.build_id,
        }
    }
}

// === LogOutput conversions ===

impl From<crate::buildservice::LogStream> for log_output::Stream {
    fn from(value: crate::buildservice::LogStream) -> Self {
        use crate::buildservice::LogStream as LS;
        match value {
            LS::Stdout => log_output::Stream::Stdout,
            LS::Stderr => log_output::Stream::Stderr,
        }
    }
}

impl TryFrom<log_output::Stream> for crate::buildservice::LogStream {
    type Error = ValidateBuildEventError;

    fn try_from(value: log_output::Stream) -> Result<Self, Self::Error> {
        use crate::buildservice::LogStream as LS;
        match value {
            log_output::Stream::Unspecified => Err(ValidateBuildEventError::InvalidLogStream),
            log_output::Stream::Stdout => Ok(LS::Stdout),
            log_output::Stream::Stderr => Ok(LS::Stderr),
        }
    }
}

impl From<crate::buildservice::LogOutput> for LogOutput {
    fn from(value: crate::buildservice::LogOutput) -> Self {
        Self {
            stream: log_output::Stream::from(value.stream).into(),
            data: value.data,
        }
    }
}

impl TryFrom<LogOutput> for crate::buildservice::LogOutput {
    type Error = ValidateBuildEventError;

    fn try_from(value: LogOutput) -> Result<Self, Self::Error> {
        let stream = log_output::Stream::try_from(value.stream)
            .map_err(|_| ValidateBuildEventError::InvalidLogStream)?;
        Ok(Self {
            stream: stream.try_into()?,
            data: value.data,
        })
    }
}

// === RefscanResultEvent conversions ===

impl From<crate::buildservice::RefscanResultEvent> for RefscanResult {
    fn from(value: crate::buildservice::RefscanResultEvent) -> Self {
        Self {
            output_index: value.output_index as u32,
            found_needles: value.found_needles,
        }
    }
}

impl From<RefscanResult> for crate::buildservice::RefscanResultEvent {
    fn from(value: RefscanResult) -> Self {
        Self {
            output_index: value.output_index as usize,
            found_needles: value.found_needles,
        }
    }
}

// === BuildCompleted conversions ===

impl From<BuildResult> for BuildCompleted {
    fn from(value: BuildResult) -> Self {
        Self {
            outputs: value
                .outputs
                .into_iter()
                .map(|output| build_completed::Output {
                    output: Some(snix_castore::proto::Entry::from_name_and_node(
                        "".into(),
                        output.node,
                    )),
                    needles: output.output_needles.into_iter().collect(),
                })
                .collect(),
        }
    }
}

impl TryFrom<BuildCompleted> for BuildResult {
    type Error = ValidateBuildCompletedError;

    fn try_from(value: BuildCompleted) -> Result<Self, Self::Error> {
        Ok(Self {
            outputs: value
                .outputs
                .into_iter()
                .enumerate()
                .map(|(i, output)| {
                    let node = output
                        .output
                        .ok_or(ValidateBuildCompletedError::MissingOutputEntry(i))?
                        .try_into_anonymous_node()
                        .map_err(|_| ValidateBuildCompletedError::InvalidOutputEntry(i))?;

                    Ok::<_, ValidateBuildCompletedError>(crate::buildservice::BuildOutput {
                        node,
                        output_needles: BTreeSet::from_iter(output.needles),
                    })
                })
                .try_collect()?,
        })
    }
}

// === BuildError conversions ===

impl From<crate::buildservice::BuildError> for BuildFailed {
    fn from(value: crate::buildservice::BuildError) -> Self {
        Self {
            message: value.message,
            exit_code: value.exit_code,
        }
    }
}

impl From<BuildFailed> for crate::buildservice::BuildError {
    fn from(value: BuildFailed) -> Self {
        Self {
            message: value.message,
            exit_code: value.exit_code,
        }
    }
}

#[cfg(test)]
// TODO: add testcases for constraints special cases. The default cases in the protos
// should result in the constraints not being added. For example min_memory 0 can be omitted.
// Also interesting testcases are "merging semantics". MimMemory(1) and MinMemory(100) will
// result in mim_memory 100, multiple AvailableReadOnlyPaths need to be merged. Contradicting
// system constraints need to fail somewhere (maybe an assertion, as only buggy code can construct it)
mod tests {
    use super::{is_clean_path, is_clean_relative_path};
    use rstest::rstest;

    #[rstest]
    #[case::fail_trailing_slash("foo/bar/", false)]
    #[case::fail_dotdot("foo/../bar", false)]
    #[case::fail_singledot("foo/./bar", false)]
    #[case::fail_unnecessary_slashes("foo//bar", false)]
    #[case::fail_absolute_unnecessary_slashes("//foo/bar", false)]
    #[case::ok_empty("", true)]
    #[case::ok_relative("foo/bar", true)]
    #[case::ok_absolute("/", true)]
    #[case::ok_absolute2("/foo/bar", true)]
    fn test_is_clean_path(#[case] s: &str, #[case] expected: bool) {
        assert_eq!(is_clean_path(s), expected);
    }

    #[rstest]
    #[case::fail_absolute("/", false)]
    #[case::ok_relative("foo/bar", true)]
    fn test_is_clean_relative_path(#[case] s: &str, #[case] expected: bool) {
        assert_eq!(is_clean_relative_path(s), expected);
    }

    // TODO: add tests for BuildRequest validation itself

    mod build_event_conversions {
        use super::super::*;
        use crate::buildservice::{
            BuildError, BuildEvent as BE, BuildOutput, BuildResult, BuildStarted, LogOutput,
            LogStream, RefscanResultEvent,
        };
        use bytes::Bytes;
        use std::collections::BTreeSet;

        #[test]
        fn test_build_started_roundtrip() {
            let started = BE::Started(BuildStarted {
                build_id: "test-build-123".to_string(),
            });

            let proto: BuildEvent = started.clone().into();
            let back: BE = proto.try_into().expect("conversion should succeed");

            match back {
                BE::Started(s) => assert_eq!(s.build_id, "test-build-123"),
                _ => panic!("expected Started variant"),
            }
        }

        #[test]
        fn test_log_output_stdout_roundtrip() {
            let log = BE::Log(LogOutput {
                stream: LogStream::Stdout,
                data: Bytes::from("hello stdout\n"),
            });

            let proto: BuildEvent = log.into();
            let back: BE = proto.try_into().expect("conversion should succeed");

            match back {
                BE::Log(l) => {
                    assert!(matches!(l.stream, LogStream::Stdout));
                    assert_eq!(l.data, Bytes::from("hello stdout\n"));
                }
                _ => panic!("expected Log variant"),
            }
        }

        #[test]
        fn test_log_output_stderr_roundtrip() {
            let log = BE::Log(LogOutput {
                stream: LogStream::Stderr,
                data: Bytes::from("error message\n"),
            });

            let proto: BuildEvent = log.into();
            let back: BE = proto.try_into().expect("conversion should succeed");

            match back {
                BE::Log(l) => {
                    assert!(matches!(l.stream, LogStream::Stderr));
                    assert_eq!(l.data, Bytes::from("error message\n"));
                }
                _ => panic!("expected Log variant"),
            }
        }

        #[test]
        fn test_log_output_unspecified_fails() {
            let proto = BuildEvent {
                event: Some(build_event::Event::Log(super::super::LogOutput {
                    stream: log_output::Stream::Unspecified.into(),
                    data: Bytes::from("test"),
                })),
            };

            let result: Result<BE, _> = proto.try_into();
            assert!(result.is_err());
        }

        #[test]
        fn test_refscan_result_roundtrip() {
            let refscan = BE::RefscanResult(RefscanResultEvent {
                output_index: 2,
                found_needles: vec![0, 3, 5],
            });

            let proto: BuildEvent = refscan.into();
            let back: BE = proto.try_into().expect("conversion should succeed");

            match back {
                BE::RefscanResult(r) => {
                    assert_eq!(r.output_index, 2);
                    assert_eq!(r.found_needles, vec![0, 3, 5]);
                }
                _ => panic!("expected RefscanResult variant"),
            }
        }

        #[test]
        fn test_build_completed_roundtrip() {
            let digest = snix_castore::B3Digest::from(&[0u8; 32]);
            let result = BuildResult {
                outputs: vec![BuildOutput {
                    node: snix_castore::Node::File {
                        digest: digest.clone(),
                        size: 100,
                        executable: false,
                    },
                    output_needles: BTreeSet::from([1, 2, 3]),
                }],
            };

            let proto: BuildCompleted = result.clone().into();
            let back: BuildResult = proto.try_into().expect("conversion should succeed");

            assert_eq!(back.outputs.len(), 1);
            assert_eq!(back.outputs[0].output_needles, BTreeSet::from([1, 2, 3]));
            match &back.outputs[0].node {
                snix_castore::Node::File {
                    digest: d,
                    size,
                    executable,
                } => {
                    assert_eq!(d, &digest);
                    assert_eq!(*size, 100);
                    assert!(!executable);
                }
                _ => panic!("expected File node"),
            }
        }

        #[test]
        fn test_build_failed_roundtrip() {
            let failed = BE::Failed(BuildError {
                message: "build failed with error".to_string(),
                exit_code: Some(1),
            });

            let proto: BuildEvent = failed.into();
            let back: BE = proto.try_into().expect("conversion should succeed");

            match back {
                BE::Failed(f) => {
                    assert_eq!(f.message, "build failed with error");
                    assert_eq!(f.exit_code, Some(1));
                }
                _ => panic!("expected Failed variant"),
            }
        }

        #[test]
        fn test_build_failed_no_exit_code() {
            let failed = BE::Failed(BuildError {
                message: "signal terminated".to_string(),
                exit_code: None,
            });

            let proto: BuildEvent = failed.into();
            let back: BE = proto.try_into().expect("conversion should succeed");

            match back {
                BE::Failed(f) => {
                    assert_eq!(f.message, "signal terminated");
                    assert_eq!(f.exit_code, None);
                }
                _ => panic!("expected Failed variant"),
            }
        }

        #[test]
        fn test_missing_event_field_fails() {
            let proto = BuildEvent { event: None };
            let result: Result<BE, _> = proto.try_into();
            assert!(result.is_err());
        }
    }
}
