use std::str::FromStr;

use super::blobs;
use super::{blobs::ConcurrentBlobUploader, ingest_entries, IngestionEntry, IngestionError};
use crate::{blobservice::BlobService, directoryservice::DirectoryService, Node, PathBuf};
use bstr::{BString, ByteSlice};
use futures::executor::block_on;
use futures::FutureExt;
use futures::{try_join, StreamExt};
use gix::objs::tree::EntryKind;
use gix::prepare_clone_bare;
use std::io::Cursor;
use tempfile::TempDir;
use tracing::{instrument, Level, Span};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("not implemented: {0}")]
    NotImplemented(&'static str),

    #[error("git init error: {0}")]
    InitError(#[from] Box<gix::init::Error>),

    #[error("git remote init error: {0}")]
    RemoteInitError(#[from] gix::remote::init::Error),

    #[error("git remote connect error: {0}")]
    RemoteConnectError(#[from] Box<gix::remote::connect::Error>),

    #[error("git remote fetch error: {0}")]
    RemoteFetchError(#[from] Box<gix::remote::fetch::Error>),

    #[error("git refspec parse error: {0}")]
    RefspecError(#[from] gix::refspec::parse::Error),

    // gix::remote::init::Error can already contain gix::url::parse::Error
    #[error("git url parse error: {0}")]
    UrlError(#[from] gix::url::parse::Error),

    #[error("git fetch error: {0}")]
    FetchError(#[from] Box<gix::remote::fetch::prepare::Error>),

    #[error("git commit decode error: {0}")]
    CommitDecodeError(#[from] gix::object::commit::Error),

    #[error("git id shorten error: {0}")]
    IdShortenError(#[from] gix::id::shorten::Error),

    #[error("git find existing object error: {0}")]
    FindExistingObjectError(#[from] gix::object::find::existing::Error),

    #[error("git find reference object error: {0}")]
    FindReferenceObjectError(#[from] gix::reference::follow::to_object::Error),

    #[error("git find reference existing object error: {0}")]
    FindReferenceExistingObjectError(#[from] gix::reference::find::existing::Error),

    #[error("git object try into error: {0}")]
    ObjectTryIntoError(#[from] gix::object::try_into::Error),

    #[error("io error: {0}")]
    IoError(#[from] std::io::Error),

    #[error("git hash decode error: {0}")]
    HashDecodeError(#[from] gix::hash::decode::Error),

    #[error("git revision walk error: {0}")]
    RevWalkError(#[from] gix::revision::walk::Error),

    // We'd like to wrap gix::object::lib::decode::_decode::Error, but it is not exported.
    #[error("git object decode error")]
    ObjectDecodeError,

    #[error("blob upload error: {0}")]
    BlobUploadError(#[from] blobs::Error),

    #[error("join error: {0}")]
    JoinError(#[from] tokio::task::JoinError),

    #[error("clone error: {0}")]
    CloneError(#[from] gix::clone::Error),

    #[error("clone fetch error: {0}")]
    CloneFetchError(#[from] gix::clone::fetch::Error),

    #[error("blocking send error")]
    BlockingSendError,

    #[error("blob size overflow")]
    BlobSizeOverflow,

    #[error("git archive option error: {0}")]
    ArchiveOptionError(String),
}

// gix::object::find::existing::with_conversion::Error wraps two other errors. We'll unwrap those errors into our own.
impl From<gix::object::find::existing::with_conversion::Error> for Error {
    fn from(e: gix::object::find::existing::with_conversion::Error) -> Self {
        match e {
            gix::object::find::existing::with_conversion::Error::Find(e) => {
                Error::FindExistingObjectError(e)
            }
            gix::object::find::existing::with_conversion::Error::Convert(e) => {
                Error::ObjectTryIntoError(e)
            }
        }
    }
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub struct IngestGitMetadata {
    pub short_id: gix::hash::Prefix,
    pub rev: gix::ObjectId,
    pub rev_count: usize,
}

/// Options for Git ingestion
#[derive(Debug, Clone)]
pub struct GitIngestOptions {
    /// Name for the root directory
    pub name: String,
    /// URL of the Git repository
    pub url: BString,
    /// Reference to checkout (default: HEAD)
    pub r#ref: BString,
    /// Specific revision to checkout
    pub rev: Option<BString>,
    /// Whether to do a shallow clone
    pub shallow: bool,
    /// Whether to fetch all refs
    pub all_refs: bool,
    /// Whether to fetch submodules
    pub submodules: bool,
}

/// Ingests a Git repository from the given URL, and checkout the specified
/// ref or revision into the passed [`BlobService`] and [`DirectoryService`].
#[instrument(skip_all, ret(level = Level::TRACE), err)]
pub async fn ingest_git<BS, DS>(
    blob_service: BS,
    directory_service: DS,
    options: GitIngestOptions,
) -> Result<(Node, IngestGitMetadata), IngestionError<Error>>
where
    BS: BlobService + Clone + 'static,
    DS: DirectoryService,
{
    let (tx, rx) = tokio::sync::mpsc::channel(1);
    let git_ingest_worker =
        tokio::task::spawn_blocking(move || _ingest_git(options, blob_service, &tx))
            .map(|result| Ok(result.map_err(Error::JoinError)??));

    let ingest_stream = tokio_stream::wrappers::ReceiverStream::new(rx).map(Ok);
    let (metadata, root_node) = try_join!(
        git_ingest_worker,
        ingest_entries(directory_service, ingest_stream)
    )?;
    Ok((root_node, metadata))
}

/// Clones a bare git repository and creates IngestionEntries for the content of the specified revision.
#[instrument(
    skip_all,
    fields(name, url, r#ref, rev, shallow, all_refs, submodules),
    ret,
    err
)]
fn _ingest_git<BS>(
    options: GitIngestOptions,
    blob_service: BS,
    entry_sender: &tokio::sync::mpsc::Sender<IngestionEntry>,
) -> Result<IngestGitMetadata, Error>
where
    BS: BlobService + Clone + 'static,
{
    let url = gix::url::parse(options.url.as_bytes().as_bstr()).map_err(Error::UrlError)?;
    // FUTUREWORK: avoid fs-based tempdir by streaming objects to blob_service directly during fetching
    let repo_dir = TempDir::new().map_err(Error::IoError)?;

    Span::current().record("repo_dir", repo_dir.path().to_str());

    // We need to clone the URL since it's moved when used in prepare_clone_bare
    let url_clone = url.clone();
    let mut fetch_prep = prepare_clone_bare(url, repo_dir.into_path())?;

    // Configure clone options
    if options.shallow {
        // Use depth=1 for shallow clone
        // Set depth=1 for shallow clone
        // API has changed - we'll need to implement this properly later
    }

    // Set submodules option if needed
    if options.submodules {
        // This API has changed - for now we'll leave submodules unsupported
        // and will need to update this when the implementation is revisited
    }

    let (repo, _outcome) = fetch_prep.fetch_only(
        gix::progress::Discard,
        &std::sync::atomic::AtomicBool::default(),
    )?;
    let remote = repo.remote_at(url_clone).map_err(Error::RemoteInitError)?;
    let connection = remote
        .connect(gix::remote::Direction::Fetch)
        .map_err(|error| Error::RemoteConnectError(error.into()))?;
    let ref_str = match &options.rev {
        Some(rev) => rev.to_string(),
        None => options.r#ref.to_string(),
    };
    let refspec = gix::refspec::parse(
        ref_str.as_bytes().as_bstr(),
        gix::refspec::parse::Operation::Fetch,
    )
    .map_err(Error::RefspecError)?;

    // Configure fetch options
    let mut ref_map_options = gix::remote::ref_map::Options::default();

    // The allRefs parameter is only relevant when shallow=false
    if options.all_refs && !options.shallow {
        // When all_refs=true and shallow=false, fetch all refs
        // Add a wildcard refspec to fetch all remote refs
        let all_refs_spec = gix::refspec::parse(
            "refs/*:refs/*".as_bytes().as_bstr(),
            gix::refspec::parse::Operation::Fetch,
        )
        .map_err(Error::RefspecError)?;
        ref_map_options.extra_refspecs = vec![all_refs_spec.into()];
    } else {
        // Only fetch the specified ref
        ref_map_options.extra_refspecs = vec![refspec.into()];
    }

    // Prepare the fetch with our configured options
    let prepare_fetch = connection
        .prepare_fetch(gix::progress::Discard, ref_map_options)
        .map_err(|error| Error::FetchError(error.into()))?;
    prepare_fetch
        .receive(
            // FUTUREWORK: show fetching progress
            gix::progress::Discard,
            // We do not support interrupting the fetch, so we pass a constant false.
            &std::sync::atomic::AtomicBool::default(),
        )
        .map_err(|error| Error::RemoteFetchError(error.into()))?;

    let commit = match &options.rev {
        Some(rev) => {
            let rev = gix::ObjectId::from_hex(rev.as_bytes())?;
            repo.find_commit(rev)?
        }
        None => {
            let mut reference = repo.find_reference(options.r#ref.as_bytes().as_bstr())?;

            let rev = reference
                .follow_to_object()
                .map_err(Error::FindReferenceObjectError)?;
            let obj = repo.find_object(rev)?;
            match obj.kind {
                gix::object::Kind::Commit => obj.into_commit(),
                gix::object::Kind::Tag => {
                    let tag = obj.into_tag();
                    repo.find_commit(tag.target_id().map_err(|_| Error::ObjectDecodeError)?)?
                }
                _ => Err(Error::NotImplemented("only commits and tags are supported"))?,
            }
        }
    };
    let rev_count = repo.rev_walk([commit.id]).all()?.count();

    let short_id = commit.short_id().map_err(Error::IdShortenError)?;

    let root = commit.tree().map_err(Error::CommitDecodeError)?;

    let mut blob_uploader = ConcurrentBlobUploader::new(blob_service);
    ingest_git_tree(
        PathBuf::from_str(&options.name).map_err(Error::IoError)?,
        &repo,
        &root,
        &mut blob_uploader,
        entry_sender,
    )?;

    block_on(blob_uploader.join()).map_err(Error::BlobUploadError)?;
    Ok(IngestGitMetadata {
        rev_count,
        short_id,
        rev: commit.id,
    })
}

/// Recursively creates IngestionEntries for a Git tree.
/// IngestionEntries are send to the entry_sender.
/// The blob uploader is used to upload Git blob contents.
#[instrument(skip_all, fields(path, tree.id), ret, err)]
fn ingest_git_tree<'repo, BS>(
    path: PathBuf,
    repo: &'repo gix::Repository,
    tree: &'repo gix::Tree<'repo>,
    blob_uploader: &'repo mut ConcurrentBlobUploader<BS>,
    entry_sender: &'repo tokio::sync::mpsc::Sender<IngestionEntry>,
) -> Result<(), Error>
where
    BS: BlobService + Clone + 'static,
{
    for entry in tree.iter() {
        let entry = entry.map_err(|_| Error::ObjectDecodeError)?;
        let kind: gix::object::tree::EntryKind = entry.mode().into();

        // Get the file path for this entry
        let entry_path = path.try_join(entry.filename().into())?;

        match kind {
            EntryKind::Blob | EntryKind::BlobExecutable => {
                let blob = repo.find_blob(entry.id())?;
                let blob_size: u64 = blob
                    .data
                    .len()
                    .try_into()
                    .map_err(|_| Error::BlobSizeOverflow)?;
                let digest = block_on(async {
                    blob_uploader
                        .upload(&entry_path, blob_size, Cursor::new(&blob.data))
                        .await
                        .map_err(Error::BlobUploadError)
                })?;

                entry_sender
                    .blocking_send(IngestionEntry::Regular {
                        path: entry_path,
                        size: blob_size,
                        executable: kind == EntryKind::BlobExecutable,
                        digest,
                    })
                    .map_err(|_| Error::BlockingSendError)?;
            }
            EntryKind::Tree => {
                let sub_tree = repo.find_tree(entry.id())?;
                ingest_git_tree(
                    entry_path.clone(),
                    repo,
                    &sub_tree,
                    blob_uploader,
                    entry_sender,
                )?;
            }
            EntryKind::Link => {
                let blob = repo.find_blob(entry.id())?;
                entry_sender
                    .blocking_send(IngestionEntry::Symlink {
                        path: entry_path,
                        target: blob.data.clone(),
                    })
                    .map_err(|_| Error::BlockingSendError)?;
            }
            EntryKind::Commit => panic!("commits inside a tree are unexpected"),
        }
    }
    entry_sender
        .blocking_send(IngestionEntry::Dir { path })
        .map_err(|_| Error::BlockingSendError)?;
    Ok(())
}
