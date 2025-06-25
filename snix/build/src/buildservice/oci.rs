//! OCI (Open Container Initiative) build service implementation.
//!
//! This module provides a build service that uses libcontainer directly
//! to execute builds in isolated container environments.
//!
//! # Example URLs
//!
//! - `oci:///var/lib/snix/bundles` - Use libcontainer for container execution

use anyhow::Context;
use libcontainer::container::Container;
use libcontainer::container::builder::ContainerBuilder;
use libcontainer::syscall::syscall::SyscallType;
use snix_castore::{
    blobservice::BlobService,
    directoryservice::DirectoryService,
    fs::fuse::FuseDaemon,
    import::fs::ingest_path,
    refscan::{ReferencePattern, ReferenceScanner},
};
use tonic::async_trait;
use tracing::{Span, debug, instrument, warn};
use uuid::Uuid;

use crate::buildservice::{BuildOutput, BuildRequest, BuildResult};
use crate::oci::{get_host_output_paths, make_bundle, make_spec};
use std::path::PathBuf;

use super::BuildService;

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
    concurrent_builds: tokio::sync::Semaphore,
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
            concurrent_builds: tokio::sync::Semaphore::new(MAX_CONCURRENT_BUILDS),
        }
    }
}

#[async_trait]
impl<BS, DS> BuildService for OCIBuildService<BS, DS>
where
    BS: BlobService + Clone + 'static,
    DS: DirectoryService + Clone + 'static,
{
    #[instrument(skip_all, err)]
    async fn do_build(&self, request: BuildRequest) -> std::io::Result<BuildResult> {
        let _permit = self.concurrent_builds.acquire().await.unwrap();

        let bundle_name = Uuid::new_v4();
        let bundle_path = self.bundle_root.join(bundle_name.to_string());

        let span = Span::current();
        span.record("bundle_name", bundle_name.to_string());

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
            let blob_service = self.blob_service.clone();
            let directory_service = self.directory_service.clone();

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

        debug!(bundle.path=?bundle_path, bundle.name=%bundle_name, "about to create container");

        // Create and run the container using libcontainer
        let exit_code = run_container(&bundle_path, &bundle_name.to_string())
            .await
            .context("failed to run container")
            .map_err(std::io::Error::other)?;

        // Clean up the bundle directory regardless of build outcome
        if let Err(e) = tokio::fs::remove_dir_all(&bundle_path).await {
            warn!(error=?e, bundle_path=?bundle_path, "failed to clean up bundle directory");
        }

        // Check the exit code
        if exit_code != 0 {
            warn!(exit_code=%exit_code, "build failed");

            return Err(std::io::Error::new(
                std::io::ErrorKind::Other,
                format!("nonzero exit code: {}", exit_code),
            ));
        }

        // Ingest build outputs into the castore.
        // We use try_join_all here. No need to spawn new tasks, as this is
        // mostly IO bound.
        let outputs = futures::future::try_join_all(host_output_paths.into_iter().enumerate().map(
            |(i, host_output_path)| {
                let output_path = &request.outputs[i];
                let patterns = patterns.clone();
                async move {
                    debug!(host.path=?host_output_path, output.path=?output_path, "ingesting path");

                    let scanner = ReferenceScanner::new(patterns);

                    Ok::<_, std::io::Error>(BuildOutput {
                        node: ingest_path(
                            self.blob_service.clone(),
                            &self.directory_service,
                            host_output_path,
                            Some(&scanner),
                        )
                        .await
                        .map_err(|e| {
                            std::io::Error::new(
                                std::io::ErrorKind::InvalidData,
                                format!("Unable to ingest output: {}", e),
                            )
                        })?,

                        output_needles: scanner
                            .matches()
                            .into_iter()
                            .enumerate()
                            .filter(|(_, val)| *val)
                            .map(|(idx, _)| idx as u64)
                            .collect(),
                    })
                }
            },
        ))
        .await?;

        Ok(BuildResult { outputs })
    }
}

/// Runs a container using libcontainer and waits for it to complete.
/// Returns the exit code of the container.
#[instrument(err)]
async fn run_container(bundle_path: &PathBuf, container_id: &str) -> anyhow::Result<i32> {
    // Run the container operation in a blocking task since libcontainer is synchronous
    let bundle_path = bundle_path.clone();
    let container_id = container_id.to_string();

    tokio::task::spawn_blocking(move || {
        // Create the container
        let mut container = ContainerBuilder::new(container_id.clone(), SyscallType::default())
            .validate_id()?
            .as_init(&bundle_path)
            .with_systemd(false)
            .build()
            .context("failed to build container")?;

        // Verify container can be started
        if !container.can_start() {
            return Err(anyhow::anyhow!(
                "container {} cannot be started in current state: {:?}",
                container_id,
                container.status()
            ));
        }

        // Start the container
        container.start().context("failed to start container")?;

        // Wait for the container to complete and get exit status
        // Since we're not detached, the container will wait for the process to exit
        let exit_status = wait_for_container(&mut container)?;

        // Clean up the container
        if container.can_delete() {
            if let Err(e) = container.delete(true) {
                // Log but don't fail if cleanup fails
                tracing::warn!(error=?e, container_id=%container_id, "failed to delete container");
            }
        }

        Ok(exit_status)
    })
    .await
    .context("container task panicked")?
}

/// Wait for the container to complete and return its exit code
fn wait_for_container(container: &mut Container) -> anyhow::Result<i32> {
    use libcontainer::container::ContainerStatus;
    use std::{thread, time::Duration};

    // Poll container status until it stops
    loop {
        // Refresh the container's status from the actual process state
        container
            .refresh_status()
            .context("failed to refresh container status")?;

        match container.status() {
            ContainerStatus::Stopped => {
                // Container has stopped, now we need to get the exit code
                // Since libcontainer doesn't expose exit code directly, we still need waitpid
                use nix::sys::wait::{WaitPidFlag, WaitStatus, waitpid};

                if let Some(pid) = container.pid() {
                    let pid = nix::unistd::Pid::from_raw(pid.as_raw());

                    // Use WNOHANG to avoid blocking since process should already be done
                    match waitpid(pid, Some(WaitPidFlag::WNOHANG))? {
                        WaitStatus::Exited(_, code) => return Ok(code),
                        WaitStatus::Signaled(_, signal, _) => {
                            // Process was killed by a signal, return 128 + signal number
                            return Ok(128 + signal as i32);
                        }
                        WaitStatus::StillAlive => {
                            // Process marked as stopped but still alive, this shouldn't happen
                            return Err(anyhow::anyhow!(
                                "container stopped but process still alive"
                            ));
                        }
                        _ => return Err(anyhow::anyhow!("unexpected wait status")),
                    }
                } else {
                    // Container stopped but no PID available
                    return Ok(0); // Assume success if we can't determine otherwise
                }
            }
            ContainerStatus::Running => {
                // Container still running, wait a bit before checking again
                thread::sleep(Duration::from_millis(100));
            }
            ContainerStatus::Creating | ContainerStatus::Created => {
                // Container still being created or just created, wait
                thread::sleep(Duration::from_millis(100));
            }
            ContainerStatus::Paused => {
                return Err(anyhow::anyhow!(
                    "container unexpectedly paused during build"
                ));
            }
        }
    }
}
