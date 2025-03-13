//! Implements builtins used to import paths in the store.

use crate::tvix_store_io::TvixStoreIO;
use std::path::Path;
use tvix_castore::import::ingest_entries;
use tvix_castore::Node;
use tvix_eval::{
    builtin_macros::builtins,
    generators::{self, GenCo},
    ErrorKind, EvalIO, Value,
};

use std::rc::Rc;

async fn filtered_ingest(
    state: Rc<TvixStoreIO>,
    co: GenCo,
    path: &Path,
    filter: Option<&Value>,
) -> Result<Node, ErrorKind> {
    let mut entries: Vec<walkdir::DirEntry> = vec![];
    let mut it = walkdir::WalkDir::new(path)
        .follow_links(false)
        .follow_root_links(false)
        .contents_first(false)
        .into_iter();

    // Skip root node.
    entries.push(
        it.next()
            .ok_or_else(|| ErrorKind::IO {
                path: Some(path.to_path_buf()),
                error: std::io::Error::new(std::io::ErrorKind::NotFound, "No root node emitted")
                    .into(),
            })?
            .map_err(|err| ErrorKind::IO {
                path: Some(path.to_path_buf()),
                error: std::io::Error::from(err).into(),
            })?,
    );

    while let Some(entry) = it.next() {
        // Entry could be a NotFound, if the root path specified does not exist.
        let entry = entry.map_err(|err| ErrorKind::IO {
            path: err.path().map(|p| p.to_path_buf()),
            error: std::io::Error::from(err).into(),
        })?;

        // As per Nix documentation `:doc builtins.filterSource`.
        let file_type = if entry.file_type().is_dir() {
            "directory"
        } else if entry.file_type().is_file() {
            "regular"
        } else if entry.file_type().is_symlink() {
            "symlink"
        } else {
            "unknown"
        };

        let should_keep: bool = if let Some(filter) = filter {
            generators::request_force(
                &co,
                generators::request_call_with(
                    &co,
                    filter.clone(),
                    [
                        Value::String(entry.path().as_os_str().as_encoded_bytes().into()),
                        Value::String(file_type.into()),
                    ],
                )
                .await,
            )
            .await
            .as_bool()?
        } else {
            true
        };

        if !should_keep {
            if file_type == "directory" {
                it.skip_current_dir();
            }
            continue;
        }

        entries.push(entry);
    }

    let dir_entries = entries.into_iter().rev().map(Ok);

    state.tokio_handle.block_on(async {
        let entries = tvix_castore::import::fs::dir_entries_to_ingestion_stream::<'_, _, _, &[u8]>(
            &state.blob_service,
            dir_entries,
            path,
            None, // TODO re-scan
        );
        ingest_entries(&state.directory_service, entries)
            .await
            .map_err(|e| ErrorKind::IO {
                path: Some(path.to_path_buf()),
                error: Rc::new(std::io::Error::new(std::io::ErrorKind::Other, e)),
            })
    })
}

#[builtins(state = "Rc<TvixStoreIO>")]
mod import_builtins {
    use super::*;

    use crate::builtins::ImportError;
    use crate::tvix_store_io::TvixStoreIO;
    use bstr::ByteSlice;
    use nix_compat::nixhash::{CAHash, NixHash};
    use nix_compat::store_path::{build_ca_path, StorePath, StorePathRef};
    use sha2::Digest;
    use std::rc::Rc;
    use tokio::io::AsyncWriteExt;
    use tvix_castore::blobservice::BlobService;
    use tvix_eval::builtins::coerce_value_to_path;
    use tvix_eval::generators::Gen;
    use tvix_eval::{generators::GenCo, ErrorKind, Value};
    use tvix_eval::{AddContext, FileType, NixContext, NixContextElement, NixString};
    use tvix_store::path_info::PathInfo;

    /// Helper function dealing with uploading something from a std::io::Read to
    /// the passed [BlobService], returning the B3Digest and size.
    /// This function is sync (and uses the tokio handle to block).
    /// A sync closure getting a copy of all bytes read can be passed in,
    /// allowing to do other hashing where needed.
    fn copy_to_blobservice<F>(
        tokio_handle: tokio::runtime::Handle,
        blob_service: impl BlobService,
        mut r: impl std::io::Read,
        mut inspect_f: F,
    ) -> std::io::Result<(tvix_castore::B3Digest, u64)>
    where
        F: FnMut(&[u8]),
    {
        let mut blob_size = 0;

        let mut blob_writer = tokio_handle.block_on(async { blob_service.open_write().await });

        // read piece by piece and write to blob_writer.
        // This is a bit manual due to EvalIO being sync, while the blob writer being async.
        {
            let mut buf = [0u8; 4096];

            loop {
                // read bytes into buffer, break out if EOF
                let len = r.read(&mut buf)?;
                if len == 0 {
                    break;
                }
                blob_size += len as u64;

                let data = &buf[0..len];

                // write to blobwriter
                tokio_handle.block_on(async { blob_writer.write_all(data).await })?;

                // Call inspect_f
                inspect_f(data);
            }

            let blob_digest = tokio_handle.block_on(async { blob_writer.close().await })?;

            Ok((blob_digest, blob_size))
        }
    }

    // This is a helper used by both builtins.path and builtins.filterSource.
    async fn import_helper(
        state: Rc<TvixStoreIO>,
        co: GenCo,
        path: std::path::PathBuf,
        name: Option<&Value>,
        filter: Option<&Value>,
        recursive_ingestion: bool,
        expected_sha256: Option<[u8; 32]>,
    ) -> Result<Value, ErrorKind> {
        let name: String = match name {
            Some(name) => generators::request_force(&co, name.clone())
                .await
                .to_str()?
                .as_bstr()
                .to_string(),
            None => tvix_store::import::path_to_name(&path)
                .expect("Failed to derive the default name out of the path")
                .to_string(),
        };
        // As a first step, we ingest the contents, and get back a root node,
        // and optionally the sha256 a flat file.
        let (root_node, ca) = match std::fs::metadata(&path)?.file_type().into() {
            // Check if the path points to a regular file.
            // If it does, the filter function is never executed, and we copy to the blobservice directly.
            // If recursive is false, we need to calculate the sha256 digest of the raw contents,
            // as that affects the output path calculation.
            FileType::Regular => {
                let mut file = state.open(&path)?;
                let mut h = (!recursive_ingestion).then(sha2::Sha256::new);

                let (blob_digest, blob_size) = copy_to_blobservice(
                    state.tokio_handle.clone(),
                    &state.blob_service,
                    &mut file,
                    |data| {
                        // update blob_sha256 if needed.
                        if let Some(h) = h.as_mut() {
                            h.update(data)
                        }
                    },
                )?;

                (
                    Node::File {
                        digest: blob_digest,
                        size: blob_size,
                        executable: false,
                    },
                    h.map(|h| {
                        // If non-recursive ingestion was requested, we return that one.
                        let actual_sha256 = h.finalize().into();

                        // If an expected hash was provided upfront, compare and bail out.
                        if let Some(expected_sha256) = expected_sha256 {
                            if actual_sha256 != expected_sha256 {
                                return Err(ImportError::HashMismatch(
                                    path.clone(),
                                    NixHash::Sha256(expected_sha256),
                                    NixHash::Sha256(actual_sha256),
                                ));
                            }
                        }
                        Ok(CAHash::Flat(NixHash::Sha256(actual_sha256)))
                    })
                    .transpose()?,
                )
            }

            FileType::Directory if !recursive_ingestion => {
                return Err(ImportError::FlatImportOfNonFile(path))?
            }

            // do the filtered ingest
            FileType::Directory => (
                filtered_ingest(state.clone(), co, path.as_ref(), filter).await?,
                None,
            ),
            FileType::Symlink => {
                // FUTUREWORK: Nix follows a symlink if it's at the root,
                // except if it's not resolve-able (NixOS/nix#7761).i
                return Err(tvix_eval::ErrorKind::IO {
                    path: Some(path),
                    error: Rc::new(std::io::Error::new(
                        std::io::ErrorKind::Unsupported,
                        "builtins.path pointing to a symlink is ill-defined.",
                    )),
                });
            }
            FileType::Unknown => {
                return Err(tvix_eval::ErrorKind::IO {
                    path: Some(path),
                    error: Rc::new(std::io::Error::new(
                        std::io::ErrorKind::Unsupported,
                        "unsupported file type",
                    )),
                })
            }
        };

        // Calculate the NAR sha256.
        let (nar_size, nar_sha256) = state
            .tokio_handle
            .block_on(async {
                state
                    .nar_calculation_service
                    .as_ref()
                    .calculate_nar(&root_node)
                    .await
            })
            .map_err(|e| tvix_eval::ErrorKind::TvixError(Rc::new(e)))?;

        // Calculate the CA hash for the recursive cases, this is only already
        // `Some(_)` for flat ingestion.
        let ca = match ca {
            None => {
                // If an upfront-expected NAR hash was specified, compare.
                if let Some(expected_nar_sha256) = expected_sha256 {
                    if expected_nar_sha256 != nar_sha256 {
                        return Err(ImportError::HashMismatch(
                            path,
                            NixHash::Sha256(expected_nar_sha256),
                            NixHash::Sha256(nar_sha256),
                        )
                        .into());
                    }
                }
                CAHash::Nar(NixHash::Sha256(nar_sha256))
            }
            Some(ca) => ca,
        };

        let store_path = build_ca_path(&name, &ca, Vec::<&str>::new(), false)
            .map_err(|e| tvix_eval::ErrorKind::TvixError(Rc::new(e)))?;

        let path_info = state
            .tokio_handle
            .block_on(async {
                state
                    .path_info_service
                    .as_ref()
                    .put(PathInfo {
                        store_path,
                        node: root_node,
                        // There's no reference scanning on path contents ingested like this.
                        references: vec![],
                        nar_size,
                        nar_sha256,
                        signatures: vec![],
                        deriver: None,
                        ca: Some(ca),
                    })
                    .await
            })
            .map_err(|e| tvix_eval::ErrorKind::IO {
                path: Some(path),
                error: Rc::new(e.into()),
            })?;

        // We need to attach context to the final output path.
        let outpath = path_info.store_path.to_absolute_path();

        Ok(
            NixString::new_context_from(NixContextElement::Plain(outpath.clone()).into(), outpath)
                .into(),
        )
    }

    #[builtin("path")]
    async fn builtin_path(
        state: Rc<TvixStoreIO>,
        co: GenCo,
        args: Value,
    ) -> Result<Value, ErrorKind> {
        let args = args.to_attrs()?;

        let path = match coerce_value_to_path(
            &co,
            generators::request_force(&co, args.select_required("path")?.clone()).await,
        )
        .await?
        {
            Ok(path) => path,
            Err(cek) => return Ok(cek.into()),
        };

        let filter = args.select("filter");

        // Construct a sha256 hasher, which is needed for flat ingestion.
        let recursive_ingestion = args
            .select("recursive")
            .map(|r| r.as_bool())
            .transpose()?
            .unwrap_or(true); // Yes, yes, Nix, by default, puts `recursive = true;`.

        let expected_sha256 = args
            .select("sha256")
            .map(|h| {
                h.to_str().and_then(|expected| {
                    match nix_compat::nixhash::from_str(expected.to_str()?, Some("sha256")) {
                        Ok(NixHash::Sha256(digest)) => Ok(digest),
                        Ok(_) => unreachable!(),
                        Err(e) => Err(ErrorKind::InvalidHash(e.to_string())),
                    }
                })
            })
            .transpose()?;

        import_helper(
            state,
            co,
            path,
            args.select("name"),
            filter,
            recursive_ingestion,
            expected_sha256,
        )
        .await
    }

    #[builtin("filterSource")]
    async fn builtin_filter_source(
        state: Rc<TvixStoreIO>,
        co: GenCo,
        #[lazy] filter: Value,
        path: Value,
    ) -> Result<Value, ErrorKind> {
        let path =
            match coerce_value_to_path(&co, generators::request_force(&co, path).await).await? {
                Ok(path) => path,
                Err(cek) => return Ok(cek.into()),
            };

        import_helper(state, co, path, None, Some(&filter), true, None).await
    }

    #[builtin("storePath")]
    async fn builtin_store_path(
        state: Rc<TvixStoreIO>,
        co: GenCo,
        path: Value,
    ) -> Result<Value, ErrorKind> {
        let p = match &path {
            Value::String(s) => Path::new(s.as_bytes().to_os_str()?),
            Value::Path(p) => p.as_path(),
            _ => {
                return Err(ErrorKind::TypeError {
                    expected: "string or path",
                    actual: path.type_of(),
                })
            }
        };

        // For this builtin, the path needs to start with an absolute store path.
        let (store_path, _sub_path) = StorePathRef::from_absolute_path_full(p)
            .map_err(|_e| ImportError::PathNotAbsoluteOrInvalid(p.to_path_buf()))?;

        if state.path_exists(p)? {
            Ok(Value::String(NixString::new_context_from(
                [NixContextElement::Plain(store_path.to_absolute_path())].into(),
                p.as_os_str().as_encoded_bytes(),
            )))
        } else {
            Err(ErrorKind::IO {
                path: Some(p.to_path_buf()),
                error: Rc::new(std::io::ErrorKind::NotFound.into()),
            })
        }
    }

    #[builtin("toFile")]
    async fn builtin_to_file(
        state: Rc<TvixStoreIO>,
        co: GenCo,
        name: Value,
        content: Value,
    ) -> Result<Value, ErrorKind> {
        if name.is_catchable() {
            return Ok(name);
        }

        if content.is_catchable() {
            return Ok(content);
        }

        let name = name
            .to_str()
            .context("evaluating the `name` parameter of builtins.toFile")?;
        let content = content
            .to_contextful_str()
            .context("evaluating the `content` parameter of builtins.toFile")?;

        if content.iter_ctx_derivation().count() > 0
            || content.iter_ctx_single_outputs().count() > 0
        {
            return Err(ErrorKind::UnexpectedContext);
        }

        // upload contents to the blobservice and create a root node
        let mut h = sha2::Sha256::new();
        let (blob_digest, blob_size) = copy_to_blobservice(
            state.tokio_handle.clone(),
            &state.blob_service,
            std::io::Cursor::new(&content),
            |data| h.update(data),
        )?;

        let root_node = Node::File {
            digest: blob_digest,
            size: blob_size,
            executable: false,
        };

        // calculate the nar hash
        let (nar_size, nar_sha256) = state
            .nar_calculation_service
            .calculate_nar(&root_node)
            .await
            .map_err(|e| ErrorKind::TvixError(Rc::new(e)))?;

        let ca_hash = CAHash::Text(h.finalize().into());

        // persist via pathinfo service.
        let store_path = state
            .tokio_handle
            .block_on(
                state.path_info_service.put(PathInfo {
                    store_path: build_ca_path(
                        name.to_str()?,
                        &ca_hash,
                        content.iter_ctx_plain(),
                        false,
                    )
                    .map_err(|_e| {
                        nix_compat::derivation::DerivationError::InvalidOutputName(
                            name.to_str_lossy().into_owned(),
                        )
                    })
                    .map_err(crate::builtins::DerivationError::InvalidDerivation)?,
                    node: root_node,
                    // assemble references from plain context.
                    references: content
                        .iter_ctx_plain()
                        .map(|elem| StorePath::from_absolute_path(elem.as_bytes()))
                        .collect::<Result<_, _>>()
                        .map_err(|e| ErrorKind::TvixError(Rc::new(e)))?,
                    nar_size,
                    nar_sha256,
                    signatures: vec![],
                    deriver: None,
                    ca: Some(ca_hash),
                }),
            )
            .map_err(|e| ErrorKind::TvixError(Rc::new(e)))
            .map(|path_info| path_info.store_path)?;

        let abs_path = store_path.to_absolute_path();
        let context: NixContext = NixContextElement::Plain(abs_path.clone()).into();

        Ok(Value::from(NixString::new_context_from(context, abs_path)))
    }
}

pub use import_builtins::builtins as import_builtins;
