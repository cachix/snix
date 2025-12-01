use std::sync::Arc;

use anyhow::Context;
use bytes::Bytes;
use snix_castore::{
    blobservice::BlobService,
    directoryservice::DirectoryService,
    fs::fuse::FuseDaemon,
    import::fs::ingest_path,
    refscan::{ReferencePattern, ReferenceScanner},
};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, Command};
use tracing::{Span, debug, instrument};
use uuid::Uuid;

use crate::buildservice::{
    BuildError, BuildEvent, BuildOutput, BuildRequest, BuildResult, BuildStarted, LogOutput,
    LogStream, RefscanResultEvent,
};
use crate::oci::{get_host_output_paths, make_bundle, make_spec};
use std::{ffi::OsStr, path::PathBuf, process::Stdio};

use super::{BuildEventStream, BuildService};

const SANDBOX_SHELL: &str = env!("SNIX_BUILD_SANDBOX_SHELL");
const MAX_CONCURRENT_BUILDS: usize = 2; // TODO: make configurable

pub struct OCIBuildService<BS, DS> {
    /// Root path in which all bundles are created in
    bundle_root: PathBuf,

    /// Handle to a [BlobService], used by filesystems spawned during builds.
    blob_service: BS,
    /// Handle to a [DirectoryService], used by filesystems spawned during builds.
    directory_service: DS,

    // semaphore to track number of concurrently running builds.
    // this is necessary, as otherwise we very quickly run out of open file handles.
    concurrent_builds: Arc<tokio::sync::Semaphore>,
}

impl<BS, DS> OCIBuildService<BS, DS> {
    pub fn new(bundle_root: PathBuf, blob_service: BS, directory_service: DS) -> Self {
        // We map root inside the container to the uid/gid this is running at,
        // and allocate one for uid 1000 into the container from the range we
        // got in /etc/sub{u,g}id.
        // FUTUREWORK: use different uids?
        Self {
            bundle_root,
            blob_service,
            directory_service,
            concurrent_builds: Arc::new(tokio::sync::Semaphore::new(MAX_CONCURRENT_BUILDS)),
        }
    }
}

impl<BS, DS> BuildService for OCIBuildService<BS, DS>
where
    BS: BlobService + Clone + 'static,
    DS: DirectoryService + Clone + 'static,
{
    #[instrument(skip_all)]
    fn do_build(&self, request: BuildRequest) -> BuildEventStream {
        let bundle_root = self.bundle_root.clone();
        let blob_service = self.blob_service.clone();
        let directory_service = self.directory_service.clone();
        let concurrent_builds = self.concurrent_builds.clone();

        let stream = async_stream::try_stream! {
            let _permit = concurrent_builds.acquire().await.unwrap();

            let bundle_name = Uuid::new_v4();
            let bundle_path = bundle_root.join(bundle_name.to_string());

            let span = Span::current();
            span.record("bundle_name", bundle_name.to_string());

            // Yield BuildStarted event
            yield BuildEvent::Started(BuildStarted {
                build_id: bundle_name.to_string(),
            });

            let mut runtime_spec = make_spec(&request, true, SANDBOX_SHELL)
                .context("failed to create spec")
                .map_err(std::io::Error::other)?;

            let linux = runtime_spec.linux().clone().unwrap();

            runtime_spec.set_linux(Some(linux));

            make_bundle(&request, &runtime_spec, &bundle_path)
                .context("failed to produce bundle")
                .map_err(std::io::Error::other)?;

            // pre-calculate the locations we want to later ingest, in the order of
            // the original outputs.
            // If we can't find calculate that path, don't start the build in first place.
            let host_output_paths = get_host_output_paths(&request, &bundle_path)
                .context("failed to calculate host output paths")
                .map_err(std::io::Error::other)?;

            // assemble a BTreeMap of Nodes to pass into SnixStoreFs.
            let patterns = ReferencePattern::new(request.refscan_needles);
            // NOTE: impl Drop for FuseDaemon unmounts, so if the call is cancelled, umount.
            let _fuse_daemon = tokio::task::spawn_blocking({
                let blob_service = blob_service.clone();
                let directory_service = directory_service.clone();

                let dest = bundle_path.join("inputs");

                let root_nodes = Box::new(request.inputs);
                move || {
                    let fs = snix_castore::fs::SnixStoreFs::new(
                        blob_service,
                        directory_service,
                        root_nodes,
                        true,
                        false,
                    );
                    // mount the filesystem and wait for it to be unmounted.
                    // FUTUREWORK: make fuse daemon threads configurable?
                    FuseDaemon::new(fs, dest, 4, true).context("failed to start fuse daemon")
                }
            })
            .await?
            .context("mounting")
            .map_err(std::io::Error::other)?;

            debug!(bundle.path=?bundle_path, bundle.name=%bundle_name, "about to spawn bundle");

            // start the bundle as another process.
            let mut child = spawn_bundle(&bundle_path, &bundle_name.to_string())?;

            // Take stdout/stderr for streaming
            let stdout = child.stdout.take().expect("stdout should be piped");
            let stderr = child.stderr.take().expect("stderr should be piped");

            let mut stdout_reader = BufReader::new(stdout).lines();
            let mut stderr_reader = BufReader::new(stderr).lines();

            let mut stdout_done = false;
            let mut stderr_done = false;
            let mut io_error: Option<std::io::Error> = None;

            // Stream logs line-by-line using select
            loop {
                if stdout_done && stderr_done {
                    break;
                }

                tokio::select! {
                    result = stdout_reader.next_line(), if !stdout_done => {
                        match result {
                            Ok(Some(line)) => {
                                yield BuildEvent::Log(LogOutput {
                                    stream: LogStream::Stdout,
                                    data: Bytes::from(line + "\n"),
                                });
                            }
                            Ok(None) => {
                                stdout_done = true;
                            }
                            Err(e) => {
                                io_error = Some(e);
                                break;
                            }
                        }
                    }
                    result = stderr_reader.next_line(), if !stderr_done => {
                        match result {
                            Ok(Some(line)) => {
                                yield BuildEvent::Log(LogOutput {
                                    stream: LogStream::Stderr,
                                    data: Bytes::from(line + "\n"),
                                });
                            }
                            Ok(None) => {
                                stderr_done = true;
                            }
                            Err(e) => {
                                io_error = Some(e);
                                break;
                            }
                        }
                    }
                }
            }

            // Check for IO errors during log streaming
            if let Some(e) = io_error {
                Err(e)?;
            }

            // Wait for the process to exit
            let status = child.wait().await
                .context("failed to wait for process")
                .map_err(std::io::Error::other)?;

            // Check the exit code
            if !status.success() {
                let exit_code = status.code();
                yield BuildEvent::Failed(BuildError {
                    message: "build process exited with non-zero status".to_string(),
                    exit_code,
                });
                return;
            }

            // Ingest build outputs into the castore.
            let mut outputs = Vec::with_capacity(host_output_paths.len());

            for (i, host_output_path) in host_output_paths.into_iter().enumerate() {
                let output_path = &request.outputs[i];
                debug!(host.path=?host_output_path, output.path=?output_path, "ingesting path");

                let scanner = ReferenceScanner::new(patterns.clone());

                let node = ingest_path(
                    blob_service.clone(),
                    &directory_service,
                    host_output_path,
                    Some(&scanner),
                )
                .await
                .map_err(|e| {
                    std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        format!("Unable to ingest output: {e}"),
                    )
                })?;

                let found_needles: Vec<u64> = scanner
                    .matches()
                    .into_iter()
                    .enumerate()
                    .filter(|(_, val)| *val)
                    .map(|(idx, _)| idx as u64)
                    .collect();

                // Yield RefscanResult event
                yield BuildEvent::RefscanResult(RefscanResultEvent {
                    output_index: i,
                    found_needles: found_needles.clone(),
                });

                outputs.push(BuildOutput {
                    node,
                    output_needles: found_needles.into_iter().collect(),
                });
            }

            yield BuildEvent::Completed(BuildResult { outputs });
        };

        Box::pin(stream)
    }
}

/// Spawns runc with the bundle at bundle_path.
/// On success, returns the child.
#[instrument(err)]
fn spawn_bundle(
    bundle_path: impl AsRef<OsStr> + std::fmt::Debug,
    bundle_name: &str,
) -> std::io::Result<Child> {
    let mut command = Command::new("runc");

    command
        .args(&[
            "run".into(),
            "--bundle".into(),
            bundle_path.as_ref().to_os_string(),
            bundle_name.into(),
        ])
        .stderr(Stdio::piped())
        .stdout(Stdio::piped())
        .stdin(Stdio::null());

    command.spawn()
}
