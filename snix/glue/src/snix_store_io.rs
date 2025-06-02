//! This module provides an implementation of EvalIO talking to snix-store.
use futures::TryStreamExt;
use nix_compat::{nixhash::CAHash, store_path::StorePath};
use snix_build::buildservice::BuildService;
use snix_eval::{EvalIO, FileType, StdIO};
use snix_store::nar::NarCalculationService;
use std::{
    cell::RefCell,
    io,
    path::{Path, PathBuf},
    sync::Arc,
};
use tokio_util::io::SyncIoBridge;
use tracing::{Level, Span, error, instrument, warn};
use tracing_indicatif::span_ext::IndicatifSpanExt;

use snix_castore::{
    Node,
    blobservice::BlobService,
    directoryservice::{self, DirectoryService},
};
use snix_store::pathinfoservice::{PathInfo, PathInfoService};

use crate::fetchers::Fetcher;
use crate::known_paths::KnownPaths;
use crate::snix_build::derivation_to_build_request;

/// Implements [EvalIO], asking given [PathInfoService], [DirectoryService]
/// and [BlobService].
///
/// In case the given path does not exist in these stores, we ask StdIO.
/// This is to both cover cases of syntactically valid store paths, that exist
/// on the filesystem (still managed by Nix), as well as being able to read
/// files outside store paths.
///
/// This structure is also directly used by the derivation builtins
/// and tightly coupled to it.
///
/// In the future, we may revisit that coupling and figure out how to generalize this interface and
/// hide this implementation detail of the glue itself so that glue can be used with more than one
/// implementation of "Snix Store IO" which does not necessarily bring the concept of blob service,
/// directory service or path info service.
pub struct SnixStoreIO {
    // This is public so helper functions can interact with the stores directly.
    pub(crate) blob_service: Arc<dyn BlobService>,
    pub(crate) directory_service: Arc<dyn DirectoryService>,
    pub(crate) path_info_service: Arc<dyn PathInfoService>,
    pub(crate) nar_calculation_service: Arc<dyn NarCalculationService>,

    std_io: StdIO,
    #[allow(dead_code)]
    build_service: Arc<dyn BuildService>,
    pub(crate) tokio_handle: tokio::runtime::Handle,

    #[allow(clippy::type_complexity)]
    pub(crate) fetcher: Fetcher<
        Arc<dyn BlobService>,
        Arc<dyn DirectoryService>,
        Arc<dyn PathInfoService>,
        Arc<dyn NarCalculationService>,
    >,

    // Paths known how to produce, by building or fetching.
    pub known_paths: RefCell<KnownPaths>,
}

impl SnixStoreIO {
    pub fn new(
        blob_service: Arc<dyn BlobService>,
        directory_service: Arc<dyn DirectoryService>,
        path_info_service: Arc<dyn PathInfoService>,
        nar_calculation_service: Arc<dyn NarCalculationService>,
        build_service: Arc<dyn BuildService>,
        tokio_handle: tokio::runtime::Handle,
    ) -> Self {
        Self {
            blob_service: blob_service.clone(),
            directory_service: directory_service.clone(),
            path_info_service: path_info_service.clone(),
            nar_calculation_service: nar_calculation_service.clone(),
            std_io: StdIO {},
            build_service,
            tokio_handle,
            fetcher: Fetcher::new(
                blob_service,
                directory_service,
                path_info_service,
                nar_calculation_service,
            ),
            known_paths: Default::default(),
        }
    }

    /// for a given [StorePath] and additional [Path] inside the store path,
    /// look up the [PathInfo], and if it exists, and then use
    /// [directoryservice::descend_to] to return the
    /// [Node] specified by `sub_path`.
    ///
    /// In case there is no PathInfo yet, this means we need to build it
    /// (which currently is stubbed out still).
    #[instrument(skip(self, store_path), fields(store_path=%store_path, indicatif.pb_show=tracing::field::Empty), ret(level = Level::TRACE), err(level = Level::TRACE))]
    async fn store_path_to_path_info(
        &self,
        store_path: &StorePath<String>,
        sub_path: &Path,
    ) -> io::Result<Option<PathInfo>> {
        // Find the root node for the store_path.
        // It asks the PathInfoService first, but in case there was a Derivation
        // produced that would build it, fall back to triggering the build.
        // To populate the input nodes, it might recursively trigger builds of
        // its dependencies too.
        let mut path_info = match self
            .path_info_service
            .as_ref()
            .get(*store_path.digest())
            .await?
        {
            Some(path_info) => path_info,
            // If there's no PathInfo found, this normally means we have to
            // trigger the build (and insert into PathInfoService, after
            // reference scanning).
            // However, as Snix is (currently) not managing /nix/store itself,
            // we return Ok(None) to let std_io take over.
            // While reading from store paths that are not known to Snix during
            // that evaluation clearly is an impurity, we still need to support
            // it for things like <nixpkgs> pointing to a store path.
            // In the future, these things will (need to) have PathInfo.
            None => {
                // The store path doesn't exist yet, so we need to fetch or build it.
                // We check for fetches first, as we might have both native
                // fetchers and FODs in KnownPaths, and prefer the former.
                // This will also find [Fetch] synthesized from
                // `builtin:fetchurl` Derivations.
                let maybe_fetch = self
                    .known_paths
                    .borrow()
                    .get_fetch_for_output_path(store_path);

                match maybe_fetch {
                    Some((name, fetch)) => {
                        let (sp, path_info) = self
                            .fetcher
                            .ingest_and_persist(&name, fetch)
                            .await
                            .map_err(|e| {
                            std::io::Error::new(std::io::ErrorKind::InvalidData, e)
                        })?;

                        debug_assert_eq!(
                            sp.to_absolute_path(),
                            store_path.as_ref().to_absolute_path(),
                            "store path returned from fetcher must match store path we have in fetchers"
                        );

                        path_info
                    }
                    None => {
                        // Look up the derivation for this output path.
                        let (drv_path, drv) = {
                            let known_paths = self.known_paths.borrow();
                            match known_paths.get_drv_path_for_output_path(store_path) {
                                Some(drv_path) => (
                                    drv_path.to_owned(),
                                    known_paths.get_drv_by_drvpath(drv_path).unwrap().to_owned(),
                                ),
                                None => {
                                    warn!(store_path=%store_path, "no drv found");
                                    // let StdIO take over
                                    return Ok(None);
                                }
                            }
                        };
                        let span = Span::current();
                        span.pb_start();
                        span.pb_set_style(&snix_tracing::PB_SPINNER_STYLE);
                        span.pb_set_message(&format!("⏳Waiting for inputs {}", &store_path));

                        // derivation_to_build_request needs castore nodes for all inputs.
                        // Provide them, which means, here is where we recursively build
                        // all dependencies.
                        let resolved_inputs = {
                            let known_paths = &self.known_paths.borrow();
                            crate::snix_build::get_all_inputs(&drv, known_paths, |path| {
                                Box::pin(async move {
                                    self.store_path_to_path_info(&path, Path::new("")).await
                                })
                            })
                        }
                        .try_collect()
                        .await?;

                        span.pb_set_message(&format!("🔨Building {}", &store_path));

                        // synthesize the build request.
                        let build_request = derivation_to_build_request(&drv, &resolved_inputs)?;

                        let build_request_outputs = build_request.outputs.clone();

                        // create a build
                        let build_result = self
                            .build_service
                            .as_ref()
                            .do_build(build_request)
                            .await
                            .map_err(|e| std::io::Error::new(io::ErrorKind::Other, e))?;

                        let mut out_path_info: Option<PathInfo> = None;

                        // For each output, insert a PathInfo.
                        for (output, output_path) in
                            build_result.outputs.into_iter().zip(build_request_outputs)
                        {
                            // convert output_path to StorePath
                            let output_store_path: StorePath<String> = {
                                use std::os::unix::ffi::OsStrExt;

                                StorePath::from_bytes(output_path.as_path().as_os_str().as_bytes())
                                    .map_err(|e| {
                                        std::io::Error::new(std::io::ErrorKind::InvalidData, e)
                                    })?
                            };

                            // calculate the nar representation
                            let (nar_size, nar_sha256) = self
                                .nar_calculation_service
                                .calculate_nar(&output.node)
                                .await?;

                            // assemble the PathInfo to persist
                            let path_info = PathInfo {
                                store_path: output_store_path.clone(),
                                node: output.node,
                                references: {
                                    let all_possible_refs: Vec<_> = drv
                                        .outputs
                                        .values()
                                        .filter_map(|output| output.path.as_ref())
                                        .chain(resolved_inputs.keys())
                                        .collect();
                                    let mut references: Vec<_> = output
                                        .output_needles
                                        .iter()
                                        // Map each output needle index back to the refscan_needle
                                        .map(|idx| {
                                            all_possible_refs
                                                .get(*idx as usize)
                                                .map(|it| (*it).clone())
                                                .ok_or(std::io::Error::new(
                                                    std::io::ErrorKind::Other,
                                                    "invalid build response",
                                                ))
                                        })
                                        .collect::<Result<_, std::io::Error>>()?;
                                    // Produce references sorted by name for consistency with nix narinfos
                                    references.sort();
                                    references
                                },
                                nar_size,
                                nar_sha256,
                                signatures: vec![],
                                deriver: Some(
                                    StorePath::from_name_and_digest_fixed(
                                        drv_path
                                            .name()
                                            .strip_suffix(".drv")
                                            .expect("missing .drv suffix"),
                                        *drv_path.digest(),
                                    )
                                    .expect(
                                        "Snix bug: StorePath without .drv suffix must be valid",
                                    ),
                                ),
                                ca: drv.fod_digest().map(|fod_digest| {
                                    CAHash::Nar(nix_compat::nixhash::NixHash::Sha256(fod_digest))
                                }),
                            };

                            self.path_info_service
                                .put(path_info.clone())
                                .await
                                .map_err(|e| std::io::Error::new(io::ErrorKind::Other, e))?;

                            if store_path == &output_store_path {
                                out_path_info = Some(path_info);
                            }
                        }

                        out_path_info.ok_or(io::Error::other("build didn't produce store path"))?
                    }
                }
            }
        };

        // now with the root_node and sub_path, descend to the node requested.
        // We convert sub_path to the castore model here.
        let sub_path = snix_castore::PathBuf::from_host_path(sub_path, true)?;

        Ok(
            directoryservice::descend_to(&self.directory_service, path_info.node.clone(), sub_path)
                .await
                .map_err(|e| std::io::Error::new(io::ErrorKind::Other, e))?
                .map(|node| {
                    path_info.node = node;
                    path_info
                }),
        )
    }
}

/// Helper function peeking at a [snix_castore::Node] and returning its [FileType]
fn node_get_type(node: &Node) -> FileType {
    match node {
        Node::Directory { .. } => FileType::Directory,
        Node::File { .. } => FileType::Regular,
        Node::Symlink { .. } => FileType::Symlink,
    }
}

impl EvalIO for SnixStoreIO {
    #[instrument(skip(self), ret(level = Level::TRACE), err)]
    fn path_exists(&self, path: &Path) -> io::Result<bool> {
        if let Ok((store_path, sub_path)) = StorePath::from_absolute_path_full(path) {
            if self
                .tokio_handle
                .block_on(self.store_path_to_path_info(&store_path, sub_path))?
                .is_some()
            {
                Ok(true)
            } else {
                // As snix-store doesn't manage /nix/store on the filesystem,
                // we still need to also ask self.std_io here.
                self.std_io.path_exists(path)
            }
        } else {
            // The store path is no store path, so do regular StdIO.
            self.std_io.path_exists(path)
        }
    }

    #[instrument(skip(self), err)]
    fn open(&self, path: &Path) -> io::Result<Box<dyn io::Read>> {
        if let Ok((store_path, sub_path)) = StorePath::from_absolute_path_full(path) {
            if let Some(path_info) = self
                .tokio_handle
                .block_on(async { self.store_path_to_path_info(&store_path, sub_path).await })?
            {
                // depending on the node type, treat open differently
                match path_info.node {
                    Node::Directory { .. } => {
                        // This would normally be a io::ErrorKind::IsADirectory (still unstable)
                        Err(io::Error::new(
                            io::ErrorKind::Unsupported,
                            format!("tried to open directory at {:?}", path),
                        ))
                    }
                    Node::File { digest, .. } => {
                        self.tokio_handle.block_on(async {
                            let resp = self.blob_service.as_ref().open_read(&digest).await?;
                            match resp {
                                Some(blob_reader) => {
                                    // The VM Response needs a sync [std::io::Reader].
                                    Ok(Box::new(SyncIoBridge::new(blob_reader))
                                        as Box<dyn io::Read>)
                                }
                                None => {
                                    error!(
                                        blob.digest = %digest,
                                        "blob not found",
                                    );
                                    Err(io::Error::new(
                                        io::ErrorKind::NotFound,
                                        format!("blob {} not found", &digest),
                                    ))
                                }
                            }
                        })
                    }
                    Node::Symlink { .. } => Err(io::Error::new(
                        io::ErrorKind::Unsupported,
                        "open for symlinks is unsupported",
                    ))?,
                }
            } else {
                // As snix-store doesn't manage /nix/store on the filesystem,
                // we still need to also ask self.std_io here.
                self.std_io.open(path)
            }
        } else {
            // The store path is no store path, so do regular StdIO.
            self.std_io.open(path)
        }
    }

    #[instrument(skip(self), ret(level = Level::TRACE), err)]
    fn file_type(&self, path: &Path) -> io::Result<FileType> {
        if let Ok((store_path, sub_path)) = StorePath::from_absolute_path_full(path) {
            if let Some(path_info) = self
                .tokio_handle
                .block_on(async { self.store_path_to_path_info(&store_path, sub_path).await })?
            {
                Ok(node_get_type(&path_info.node))
            } else {
                self.std_io.file_type(path)
            }
        } else {
            self.std_io.file_type(path)
        }
    }

    #[instrument(skip(self), ret(level = Level::TRACE), err)]
    fn read_dir(&self, path: &Path) -> io::Result<Vec<(bytes::Bytes, FileType)>> {
        if let Ok((store_path, sub_path)) = StorePath::from_absolute_path_full(path) {
            if let Some(path_info) = self
                .tokio_handle
                .block_on(async { self.store_path_to_path_info(&store_path, sub_path).await })?
            {
                match path_info.node {
                    Node::Directory { digest, .. } => {
                        // fetch the Directory itself.
                        let directory = self
                            .tokio_handle
                            .block_on(async { self.directory_service.as_ref().get(&digest).await })?
                            .ok_or_else(|| {
                                // If we didn't get the directory node that's linked, that's a store inconsistency!
                                error!(
                                    directory.digest = %digest,
                                    path = ?path,
                                    "directory not found",
                                );
                                io::Error::new(
                                    io::ErrorKind::NotFound,
                                    format!("directory {digest} does not exist"),
                                )
                            })?;

                        // construct children from nodes
                        Ok(directory
                            .into_nodes()
                            .map(|(name, node)| (name.into(), node_get_type(&node)))
                            .collect())
                    }
                    Node::File { .. } => {
                        // This would normally be a io::ErrorKind::NotADirectory (still unstable)
                        Err(io::Error::new(
                            io::ErrorKind::Unsupported,
                            "tried to readdir path {:?}, which is a file",
                        ))?
                    }
                    Node::Symlink { .. } => Err(io::Error::new(
                        io::ErrorKind::Unsupported,
                        "read_dir for symlinks is unsupported",
                    ))?,
                }
            } else {
                self.std_io.read_dir(path)
            }
        } else {
            self.std_io.read_dir(path)
        }
    }

    #[instrument(skip(self), ret(level = Level::TRACE), err)]
    fn import_path(&self, path: &Path) -> io::Result<PathBuf> {
        let path_info = self.tokio_handle.block_on({
            snix_store::import::import_path_as_nar_ca(
                path,
                snix_store::import::path_to_name(path)?,
                &self.blob_service,
                &self.directory_service,
                &self.path_info_service,
                &self.nar_calculation_service,
            )
        })?;

        // From the returned PathInfo, extract the store path and return it.
        Ok(path_info.store_path.to_absolute_path().into())
    }

    #[instrument(skip(self), ret(level = Level::TRACE))]
    fn store_dir(&self) -> Option<String> {
        Some("/nix/store".to_string())
    }
}

#[cfg(test)]
mod tests {
    use std::{path::Path, rc::Rc, sync::Arc};

    use bstr::ByteSlice;
    use clap::Parser;
    use snix_build::buildservice::DummyBuildService;
    use snix_eval::{EvalIO, EvaluationResult};
    use snix_store::utils::{ServiceUrlsMemory, construct_services};
    use tempfile::TempDir;

    use super::SnixStoreIO;
    use crate::builtins::{add_derivation_builtins, add_fetcher_builtins, add_import_builtins};

    /// evaluates a given nix expression and returns the result.
    /// Takes care of setting up the evaluator so it knows about the
    // `derivation` builtin.
    fn eval(str: &str) -> EvaluationResult {
        let tokio_runtime = tokio::runtime::Runtime::new().unwrap();
        let (blob_service, directory_service, path_info_service, nar_calculation_service) =
            tokio_runtime
                .block_on(async {
                    construct_services(ServiceUrlsMemory::parse_from(std::iter::empty::<&str>()))
                        .await
                })
                .unwrap();

        let io = Rc::new(SnixStoreIO::new(
            blob_service,
            directory_service,
            path_info_service,
            nar_calculation_service.into(),
            Arc::<DummyBuildService>::default(),
            tokio_runtime.handle().clone(),
        ));

        let mut eval_builder =
            snix_eval::Evaluation::builder(io.clone() as Rc<dyn EvalIO>).enable_import();
        eval_builder = add_derivation_builtins(eval_builder, Rc::clone(&io));
        eval_builder = add_fetcher_builtins(eval_builder, Rc::clone(&io));
        eval_builder = add_import_builtins(eval_builder, io);
        let eval = eval_builder.build();

        // run the evaluation itself.
        eval.evaluate(str, None)
    }

    /// Helper function that takes a &Path, and invokes a snix evaluator coercing that path to a string
    /// (via "${/this/path}"). The path can be both absolute or not.
    /// It returns Option<String>, depending on whether the evaluation succeeded or not.
    fn import_path_and_compare<P: AsRef<Path>>(p: P) -> Option<String> {
        // Try to import the path using "${/tmp/path/to/test}".
        // The format string looks funny, the {} passed to Nix needs to be
        // escaped.
        let code = format!(r#""${{{}}}""#, p.as_ref().display());
        let result = eval(&code);

        if !result.errors.is_empty() {
            return None;
        }

        let value = result.value.expect("must be some");
        match value {
            snix_eval::Value::String(s) => Some(s.to_str_lossy().into_owned()),
            _ => panic!("unexpected value type: {:?}", value),
        }
    }

    /// Import a directory with a zero-sized ".keep" regular file.
    /// Ensure it matches the (pre-recorded) store path that Nix would produce.
    #[test]
    fn import_directory() {
        let tmpdir = TempDir::new().unwrap();

        // create a directory named "test"
        let src_path = tmpdir.path().join("test");
        std::fs::create_dir(&src_path).unwrap();

        // write a regular file `.keep`.
        std::fs::write(src_path.join(".keep"), vec![]).unwrap();

        // importing the path with .../test at the end.
        assert_eq!(
            Some("/nix/store/gq3xcv4xrj4yr64dflyr38acbibv3rm9-test".to_string()),
            import_path_and_compare(&src_path)
        );

        // importing the path with .../test/. at the end.
        assert_eq!(
            Some("/nix/store/gq3xcv4xrj4yr64dflyr38acbibv3rm9-test".to_string()),
            import_path_and_compare(src_path.join("."))
        );
    }

    /// Import a file into the store. Nix uses the "recursive"/NAR-based hashing
    /// scheme for these.
    #[test]
    fn import_file() {
        let tmpdir = TempDir::new().unwrap();

        // write a regular file `empty`.
        std::fs::write(tmpdir.path().join("empty"), vec![]).unwrap();

        assert_eq!(
            Some("/nix/store/lx5i78a4izwk2qj1nq8rdc07y8zrwy90-empty".to_string()),
            import_path_and_compare(tmpdir.path().join("empty"))
        );

        // write a regular file `hello.txt`.
        std::fs::write(tmpdir.path().join("hello.txt"), b"Hello World!").unwrap();

        assert_eq!(
            Some("/nix/store/925f1jb1ajrypjbyq7rylwryqwizvhp0-hello.txt".to_string()),
            import_path_and_compare(tmpdir.path().join("hello.txt"))
        );
    }

    /// Invoke toString on a nonexisting file, and access the .file attribute.
    /// This should not cause an error, because it shouldn't trigger an import,
    /// and leave the path as-is.
    #[test]
    fn nonexisting_path_without_import() {
        let result = eval("toString ({ line = 42; col = 42; file = /deep/thought; }.file)");

        assert!(result.errors.is_empty(), "expect evaluation to succeed");
        let value = result.value.expect("must be some");

        match value {
            snix_eval::Value::String(s) => {
                assert_eq!(*s, "/deep/thought");
            }
            _ => panic!("unexpected value type: {:?}", value),
        }
    }
}
