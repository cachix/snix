use bstr::BString;
use futures::TryStreamExt;
use md5::{digest::DynDigest, Md5};
use nix_compat::{
    nixhash::{CAHash, HashAlgo, NixHash},
    store_path::{build_ca_path, BuildStorePathError, StorePathRef},
};
use sha1::Sha1;
use sha2::{digest::Output, Digest, Sha256, Sha512};
use snix_castore::{blobservice::BlobService, directoryservice::DirectoryService, Node};
use snix_store::{
    nar::{NarCalculationService, NarIngestionError},
    pathinfoservice::{PathInfo, PathInfoService},
};
use tokio::io::{AsyncBufRead, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio_util::io::{InspectReader, InspectWriter};
use tracing::{instrument, warn, Span};
use tracing_indicatif::span_ext::IndicatifSpanExt;
use url::Url;

use crate::builtins::{FetchGitResult, FetcherError};

mod decompression;
use decompression::DecompressedReader;

#[derive(Clone, Eq, PartialEq, Debug, Default)]
pub struct FetchGitArgs {
    /// The URL of the Git repository to fetch from
    pub url: BString,

    /// The name of the directory the repo should be exported to in the store.
    /// Defaults to basename of the URL if not specified.
    pub name: String,

    /// The Git revision to fetch, typically a commit hash.
    pub rev: Option<BString>,

    /// The Git reference under which to look for the requested revision.
    /// Often a branch or tag name. Defaults to HEAD.
    /// By default prefixed with refs/heads/ unless it starts with refs/.
    pub r#ref: BString,

    /// Whether to perform a shallow clone
    pub shallow: bool,

    /// Whether to fetch all references
    pub all_refs: bool,

    /// Whether to fetch Git submodules
    pub submodules: bool,
}

/// Representing options for doing a fetch.
#[derive(Clone, Eq, PartialEq)]
pub enum Fetch {
    /// Fetch a literal file from the given URL,
    /// with an optional expected hash.
    URL {
        /// The URL to fetch from.
        url: Url,
        /// The expected hash of the file.
        exp_hash: Option<NixHash>,
    },

    /// Fetch a tarball from the given URL and unpack.
    /// The file must be a tape archive (.tar), optionally compressed with gzip,
    /// bzip2 or xz.
    /// The top-level path component of the files in the tarball is removed,
    /// so it is best if the tarball contains a single directory at top level.
    /// Optionally, a sha256 digest can be provided to verify the unpacked
    /// contents against.
    Tarball {
        /// The URL to fetch from.
        url: Url,
        /// The expected hash of the contents, as NAR.
        exp_nar_sha256: Option<[u8; 32]>,
    },

    /// Fetch a NAR file from the given URL and unpack.
    /// The file can optionally be compressed.
    NAR {
        /// The URL to fetch from.
        url: Url,
        /// The expected hash of the NAR representation.
        /// This unfortunately supports more than sha256.
        hash: NixHash,
    },

    /// Fetches a file at a URL, makes it the store path root node,
    /// but executable.
    /// Used by <nix/fetchurl.nix>, with `executable = true;`.
    /// The expected hash is over the NAR representation, but can be not SHA256:
    /// ```nix
    /// (import <nix/fetchurl.nix> { url = "https://cache.nixos.org/nar/0r8nqa1klm5v17ifc6z96m9wywxkjvgbnqq9pmy0sgqj53wj3n12.nar.xz"; hash = "sha1-NKNeU1csW5YJ4lCeWH3Z/apppNU="; executable = true; })
    /// ```
    Executable {
        /// The URL to fetch from.
        url: Url,
        /// The expected hash of the NAR representation.
        /// This unfortunately supports more than sha256.
        hash: NixHash,
    },

    /// Fetch a Git repository from the given URL, and checkout the specified
    /// revision.
    Git {
        // TODO: flatten needed arguments into this struct.
        /// The arguments to pass to the Git fetch.
        args: FetchGitArgs,
        /// The expected hash of the resulting repository.
        hash: Option<NixHash>,
    },
}

// Drops potentially sensitive username and password from a URL.
fn redact_url(url: &Url) -> Url {
    let mut url = url.to_owned();
    if !url.username().is_empty() {
        let _ = url.set_username("redacted");
    }

    if url.password().is_some() {
        let _ = url.set_password(Some("redacted"));
    }

    url
}

impl std::fmt::Debug for Fetch {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Fetch::URL { url, exp_hash } => {
                let url = redact_url(url);
                if let Some(exp_hash) = exp_hash {
                    write!(f, "URL [url: {}, exp_hash: Some({})]", &url, exp_hash)
                } else {
                    write!(f, "URL [url: {}, exp_hash: None]", &url)
                }
            }
            Fetch::Tarball {
                url,
                exp_nar_sha256,
            } => {
                let url = redact_url(url);
                if let Some(exp_nar_sha256) = exp_nar_sha256 {
                    write!(
                        f,
                        "Tarball [url: {}, exp_nar_sha256: Some({})]",
                        url,
                        NixHash::Sha256(*exp_nar_sha256)
                    )
                } else {
                    write!(f, "Tarball [url: {}, exp_hash: None]", url)
                }
            }
            Fetch::NAR { url, hash } => {
                let url = redact_url(url);
                write!(f, "NAR [url: {}, hash: {}]", &url, hash)
            }
            Fetch::Executable { url, hash } => {
                let url = redact_url(url);
                write!(f, "Executable [url: {}, hash: {}]", &url, hash)
            }
            Fetch::Git { args, hash } => {
                write!(f, "Git [args: {:?}, hash: {:?}]", args, hash)
            }
        }
    }
}

impl Fetch {
    /// If the [Fetch] contains an expected hash upfront, returns the resulting
    /// store path.
    /// This doesn't do any fetching.
    pub fn compute_store_path<'a>(
        &self,
        name: &'a str,
    ) -> Result<Option<StorePathRef<'a>>, BuildStorePathError> {
        let ca_hash = match self {
            Fetch::URL {
                exp_hash: Some(exp_hash),
                ..
            } => CAHash::Flat(exp_hash.clone()),

            Fetch::Tarball {
                exp_nar_sha256: Some(exp_nar_sha256),
                ..
            } => CAHash::Nar(NixHash::Sha256(*exp_nar_sha256)),

            Fetch::NAR { hash, .. } | Fetch::Executable { hash, .. } => {
                CAHash::Nar(hash.to_owned())
            }

            Fetch::Git {
                hash: Some(hash), ..
            } => CAHash::Nar(hash.to_owned()),

            // everything else
            Fetch::URL { exp_hash: None, .. }
            | Fetch::Tarball {
                exp_nar_sha256: None,
                ..
            }
            | Fetch::Git { hash: None, .. } => return Ok(None),
        };

        // calculate the store path of this fetch
        build_ca_path(name, &ca_hash, Vec::<String>::new(), false).map(Some)
    }
}

/// Knows how to fetch a given [Fetch].
#[derive(Clone)]
pub struct Fetcher<BS, DS, PS, NS> {
    http_client: reqwest::Client,
    blob_service: BS,
    directory_service: DS,
    path_info_service: PS,
    nar_calculation_service: NS,
}

impl<BS, DS, PS, NS> Fetcher<BS, DS, PS, NS> {
    pub fn new(
        blob_service: BS,
        directory_service: DS,
        path_info_service: PS,
        nar_calculation_service: NS,
    ) -> Self {
        Self {
            http_client: reqwest::Client::builder()
                .user_agent(crate::USER_AGENT)
                .build()
                .expect("Client::new()"),
            blob_service,
            directory_service,
            path_info_service,
            nar_calculation_service,
        }
    }

    /// Constructs a HTTP request to the passed URL, and returns a AsyncReadBuf to it.
    /// In case the URI uses the file:// scheme, use tokio::fs to open it.
    #[instrument(skip_all, fields(url, indicatif.pb_show=tracing::field::Empty), err)]
    async fn download(
        &self,
        url: Url,
    ) -> Result<Box<dyn AsyncBufRead + Unpin + Send>, FetcherError> {
        let span = Span::current();
        span.pb_set_message(&format!(
            "📡Fetching {}",
            // TOOD: maybe shorten
            redact_url(&url)
        ));

        match url.scheme() {
            "file" => {
                let f = tokio::fs::File::open(url.to_file_path().map_err(|_| {
                    // "Returns Err if the host is neither empty nor "localhost"
                    // (except on Windows, where file: URLs may have a non-local host)"
                    FetcherError::Io(std::io::Error::new(
                        std::io::ErrorKind::Other,
                        "invalid host for file:// scheme",
                    ))
                })?)
                .await?;

                span.pb_set_length(f.metadata().await?.len());
                span.pb_set_style(&snix_tracing::PB_TRANSFER_STYLE);
                span.pb_start();
                Ok(Box::new(tokio::io::BufReader::new(InspectReader::new(
                    f,
                    move |d| {
                        span.pb_inc(d.len() as u64);
                    },
                ))))
            }
            _ => {
                let resp = self.http_client.get(url).send().await?;

                if let Some(content_length) = resp.content_length() {
                    span.pb_set_length(content_length);
                    span.pb_set_style(&snix_tracing::PB_TRANSFER_STYLE);
                } else {
                    span.pb_set_style(&snix_tracing::PB_TRANSFER_STYLE);
                }
                span.pb_start();

                Ok(Box::new(tokio_util::io::StreamReader::new(
                    resp.bytes_stream()
                        .inspect_ok(move |d| {
                            span.pb_inc(d.len() as u64);
                        })
                        .map_err(|e| {
                            let e = e.without_url();
                            warn!(%e, "failed to get response body");
                            std::io::Error::new(std::io::ErrorKind::BrokenPipe, e)
                        }),
                )))
            }
        }
    }
}

/// Copies all data from the passed reader to the passed writer.
/// Afterwards, it also returns the resulting [Digest], as well as the number of
/// bytes copied.
/// The exact hash function used is left generic over all [Digest].
async fn hash<D: Digest + std::io::Write>(
    mut r: impl AsyncRead + Unpin,
    mut w: impl AsyncWrite + Unpin,
) -> std::io::Result<(Output<D>, u64)> {
    let mut hasher = D::new();
    let bytes_copied = tokio::io::copy(
        &mut InspectReader::new(&mut r, |d| hasher.write_all(d).unwrap()),
        &mut w,
    )
    .await?;
    Ok((hasher.finalize(), bytes_copied))
}

impl<BS, DS, PS, NS> Fetcher<BS, DS, PS, NS>
where
    BS: BlobService + Clone + 'static,
    DS: DirectoryService + Clone,
    PS: PathInfoService,
    NS: NarCalculationService,
{
    /// Ingest the data from a specified [Fetch].
    /// On success, return the root node, a content digest and length.
    /// Returns an error if there was a failure during fetching, or the contents
    /// didn't match the previously communicated hash contained inside the FetchArgs.
    ///
    /// For Git fetches, can optionally return metadata from git like the revision count and short rev.
    pub async fn ingest(
        &self,
        fetch: Fetch,
    ) -> Result<(Node, CAHash, u64, Option<crate::builtins::FetcherMetadata>), FetcherError> {
        match fetch {
            Fetch::URL { url, exp_hash } => {
                // Construct a AsyncRead reading from the data as its downloaded.
                let mut r = self.download(url.clone()).await?;

                // Construct a AsyncWrite to write into the BlobService.
                let mut blob_writer = self.blob_service.open_write().await;

                // Copy the contents from the download reader to the blob writer.
                // Calculate the digest of the file received, depending on the
                // communicated expected hash algo (or sha256 if none provided).
                let (actual_hash, blob_size) = match exp_hash
                    .as_ref()
                    .map(NixHash::algo)
                    .unwrap_or_else(|| HashAlgo::Sha256)
                {
                    HashAlgo::Sha256 => hash::<Sha256>(&mut r, &mut blob_writer).await.map(
                        |(digest, bytes_written)| (NixHash::Sha256(digest.into()), bytes_written),
                    )?,
                    HashAlgo::Md5 => hash::<Md5>(&mut r, &mut blob_writer).await.map(
                        |(digest, bytes_written)| (NixHash::Md5(digest.into()), bytes_written),
                    )?,
                    HashAlgo::Sha1 => hash::<Sha1>(&mut r, &mut blob_writer).await.map(
                        |(digest, bytes_written)| (NixHash::Sha1(digest.into()), bytes_written),
                    )?,
                    HashAlgo::Sha512 => hash::<Sha512>(&mut r, &mut blob_writer).await.map(
                        |(digest, bytes_written)| {
                            (NixHash::Sha512(Box::new(digest.into())), bytes_written)
                        },
                    )?,
                };

                if let Some(exp_hash) = exp_hash {
                    if exp_hash != actual_hash {
                        return Err(FetcherError::HashMismatch {
                            url,
                            wanted: exp_hash,
                            got: actual_hash,
                        });
                    }
                }

                // Construct and return the FileNode describing the downloaded contents.
                Ok((
                    Node::File {
                        digest: blob_writer.close().await?,
                        size: blob_size,
                        executable: false,
                    },
                    CAHash::Flat(actual_hash),
                    blob_size,
                    None, // No metadata for URL fetches
                ))
            }
            Fetch::Tarball {
                url,
                exp_nar_sha256,
            } => {
                // Construct a AsyncRead reading from the data as its downloaded.
                let r = self.download(url.clone()).await?;

                // Pop compression.
                let r = DecompressedReader::new(r);
                // Open the archive.
                let archive = tokio_tar::Archive::new(r);

                // Ingest the archive, get the root node.
                let node = snix_castore::import::archive::ingest_archive(
                    self.blob_service.clone(),
                    self.directory_service.clone(),
                    archive,
                )
                .await?;

                // If an expected NAR sha256 was provided, compare with the one
                // calculated from our root node.
                // Even if no expected NAR sha256 has been provided, we need
                // the actual one to calculate the store path.
                let (nar_size, actual_nar_sha256) = self
                    .nar_calculation_service
                    .calculate_nar(&node)
                    .await
                    .map_err(|e| {
                        // convert the generic Store error to an IO error.
                        FetcherError::Io(e.into())
                    })?;

                if let Some(exp_nar_sha256) = exp_nar_sha256 {
                    if exp_nar_sha256 != actual_nar_sha256 {
                        return Err(FetcherError::HashMismatch {
                            url,
                            wanted: NixHash::Sha256(exp_nar_sha256),
                            got: NixHash::Sha256(actual_nar_sha256),
                        });
                    }
                }

                Ok((
                    node,
                    CAHash::Nar(NixHash::Sha256(actual_nar_sha256)),
                    nar_size,
                    None, // No metadata for Tarball fetches
                ))
            }
            Fetch::NAR {
                url,
                hash: exp_hash,
            } => {
                // Construct a AsyncRead reading from the data as its downloaded.
                let r = self.download(url.clone()).await?;

                // Pop compression.
                let mut r = DecompressedReader::new(r);

                // Ingest the NAR, get the root node.
                let (root_node, _actual_nar_sha256, actual_nar_size) =
                    snix_store::nar::ingest_nar_and_hash(
                        self.blob_service.clone(),
                        self.directory_service.clone(),
                        &mut r,
                        &Some(CAHash::Nar(exp_hash.clone())),
                    )
                    .await
                    .map_err(|e| match e {
                        NarIngestionError::HashMismatch { expected, actual } => {
                            FetcherError::HashMismatch {
                                url,
                                wanted: expected,
                                got: actual,
                            }
                        }
                        _ => FetcherError::Io(std::io::Error::other(e.to_string())),
                    })?;
                Ok((
                    root_node,
                    // use a CAHash::Nar with the algo from the input.
                    CAHash::Nar(exp_hash),
                    actual_nar_size,
                    None, // No metadata for NAR fetches
                ))
            }
            Fetch::Executable {
                url,
                hash: exp_hash,
            } => {
                // Construct a AsyncRead reading from the data as its downloaded.
                let mut r = self.download(url.clone()).await?;

                // Construct a AsyncWrite to write into the BlobService.
                let mut blob_writer = self.blob_service.open_write().await;

                // Copy the contents from the download reader to the blob writer.
                let file_size = tokio::io::copy(&mut r, &mut blob_writer).await?;
                let blob_digest = blob_writer.close().await?;

                // Render the NAR representation on-the-fly into a hash function with
                // the same algo as our expected hash.
                // We cannot do this upfront, as we don't know the actual size.
                // FUTUREWORK: make opportunistic use of Content-Length header?

                let w = tokio::io::sink();
                // Construct the hash function.
                let mut hasher: Box<dyn DynDigest + Send> = match exp_hash.algo() {
                    HashAlgo::Md5 => Box::new(Md5::new()),
                    HashAlgo::Sha1 => Box::new(Sha1::new()),
                    HashAlgo::Sha256 => Box::new(Sha256::new()),
                    HashAlgo::Sha512 => Box::new(Sha512::new()),
                };

                let mut nar_size: u64 = 0;
                let mut w = InspectWriter::new(w, |d| {
                    hasher.update(d);
                    nar_size += d.len() as u64;
                });

                {
                    let node = nix_compat::nar::writer::r#async::open(&mut w).await?;

                    let blob_reader = self
                        .blob_service
                        .open_read(&blob_digest)
                        .await?
                        .expect("Snix bug: just-uploaded blob not found");

                    node.file(true, file_size, &mut BufReader::new(blob_reader))
                        .await?;

                    w.flush().await?;
                }

                // finalize the hasher.
                let actual_hash = {
                    match exp_hash.algo() {
                        HashAlgo::Md5 => {
                            NixHash::Md5(hasher.finalize().to_vec().try_into().unwrap())
                        }
                        HashAlgo::Sha1 => {
                            NixHash::Sha1(hasher.finalize().to_vec().try_into().unwrap())
                        }
                        HashAlgo::Sha256 => {
                            NixHash::Sha256(hasher.finalize().to_vec().try_into().unwrap())
                        }
                        HashAlgo::Sha512 => {
                            NixHash::Sha512(hasher.finalize().to_vec().try_into().unwrap())
                        }
                    }
                };

                if exp_hash != actual_hash {
                    return Err(FetcherError::HashMismatch {
                        url,
                        wanted: exp_hash,
                        got: actual_hash,
                    });
                }

                // Construct and return the FileNode describing the downloaded contents,
                // make it executable.
                let root_node = Node::File {
                    digest: blob_digest,
                    size: file_size,
                    executable: true,
                };

                Ok((
                    root_node,
                    CAHash::Nar(actual_hash),
                    file_size,
                    None, /* No metadata for Executable fetches */
                ))
            }
            Fetch::Git {
                args,
                hash: _exp_hash,
            } => {
                let FetchGitArgs {
                    url,
                    r#ref,
                    rev,
                    name,
                    shallow,
                    all_refs,
                    submodules,
                } = args;
                let options = snix_castore::import::git::GitIngestOptions {
                    name,
                    url,
                    r#ref,
                    rev,
                    shallow,
                    all_refs,
                    submodules,
                };
                let (node, metadata) = snix_castore::import::git::ingest_git(
                    self.blob_service.clone(),
                    self.directory_service.clone(),
                    options,
                )
                .await?;

                // If an expected NAR sha256 was provided, compare with the one
                // calculated from our root node.
                // Even if no expected NAR sha256 has been provided, we need
                // the actual one to calculate the store path.
                let (nar_size, actual_nar_sha256) = self
                    .nar_calculation_service
                    .calculate_nar(&node)
                    .await
                    .map_err(|e| {
                        // convert the generic Store error to an IO error.
                        FetcherError::Io(e.into())
                    })?;

                // Convert git metadata to FetcherMetadata
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs();

                // Format date as YYYYMMDDHHmmss
                let datetime = chrono::Utc::now().format("%Y%m%d%H%M%S").to_string();

                let git_result = FetchGitResult {
                    out_path: String::new(), // This will be set by the caller
                    rev: BString::from(metadata.rev.to_string()),
                    rev_count: metadata.rev_count as i64,
                    short_rev: BString::from(metadata.short_id.to_string()),
                    submodules,
                    nar_hash: None, // This will be set by the caller
                };

                let fetcher_metadata = crate::builtins::FetcherMetadata {
                    last_modified: now,
                    last_modified_date: datetime,
                    fetcher: git_result,
                };

                Ok((
                    node,
                    CAHash::Nar(NixHash::Sha256(actual_nar_sha256)),
                    nar_size,
                    Some(fetcher_metadata),
                ))
            }
        }
    }

    /// Ingests the data from a specified [Fetch], persists the returned node
    /// in the PathInfoService, and returns the calculated StorePath, as well as
    /// the root node pointing to the contents, and optional metadata.
    /// The root node can be used to descend into the data without doing the
    /// lookup to the PathInfoService again.
    pub async fn ingest_and_persist<'a>(
        &self,
        name: &'a str,
        fetch: Fetch,
    ) -> Result<
        (
            StorePathRef<'a>,
            Node,
            NixHash,
            Option<crate::builtins::FetcherMetadata>,
        ),
        FetcherError,
    > {
        // Fetch file, return the (unnamed) (File)Node of its contents, ca hash, filesize and metadata.
        let (node, ca_hash, size, metadata) = self.ingest(fetch).await?;

        // Calculate the store path to return, by calculating from ca_hash.
        let store_path = build_ca_path(name, &ca_hash, Vec::<String>::new(), false)?;

        // If the resulting hash is not a CAHash::Nar, we also need to invoke
        // `calculate_nar` to calculate this representation, as it's required in
        // the [PathInfo].
        // FUTUREWORK: allow ingest() to return multiple hashes, or have it feed
        // nar_calculation_service too?
        let (nar_size, nar_sha256) = match &ca_hash {
            CAHash::Nar(NixHash::Sha256(nar_sha256)) => (size, *nar_sha256),
            CAHash::Nar(_) | CAHash::Flat(_) => self
                .nar_calculation_service
                .calculate_nar(&node)
                .await
                .map_err(|e| FetcherError::Io(e.into()))?,
            CAHash::Text(_) => unreachable!("Snix bug: fetch returned CAHash::Text"),
        };

        // Construct the PathInfo and persist it.
        let path_info = PathInfo {
            store_path: store_path.to_owned(),
            node: node.clone(),
            references: vec![],
            nar_size,
            nar_sha256,
            signatures: vec![],
            deriver: None,
            ca: Some(ca_hash),
        };

        self.path_info_service
            .put(path_info.clone())
            .await
            .map_err(|e| FetcherError::Io(e.into()))?;

        Ok((store_path, node, NixHash::Sha256(nar_sha256), metadata))
    }
}

/// Attempts to mimic `nix::libutil::baseNameOf`
pub(crate) fn url_basename(url: &Url) -> &str {
    let s = url.path();
    if s.is_empty() {
        return "";
    }

    let mut last = s.len() - 1;
    if s.chars().nth(last).unwrap() == '/' && last > 0 {
        last -= 1;
    }

    if last == 0 {
        return "";
    }

    let pos = match s[..=last].rfind('/') {
        Some(pos) => {
            if pos == last - 1 {
                0
            } else {
                pos
            }
        }
        None => 0,
    };

    &s[(pos + 1)..=last]
}

#[cfg(test)]
mod tests {
    mod fetch {
        use super::super::*;
        use crate::fetchers::Fetch;
        use nix_compat::{nixbase32, nixhash};
        use rstest::rstest;

        #[rstest]
        #[case::url_no_hash(
            Fetch::URL{
                url: Url::parse("https://raw.githubusercontent.com/aaptel/notmuch-extract-patch/f732a53e12a7c91a06755ebfab2007adc9b3063b/notmuch-extract-patch").unwrap(),
                exp_hash: None,
            },
            None,
            "notmuch-extract-patch"
        )]
        #[case::url_sha256(
            Fetch::URL{
                url: Url::parse("https://raw.githubusercontent.com/aaptel/notmuch-extract-patch/f732a53e12a7c91a06755ebfab2007adc9b3063b/notmuch-extract-patch").unwrap(),
                exp_hash: Some(nixhash::from_sri_str("sha256-Xa1Jbl2Eq5+L0ww+Ph1osA3Z/Dxe/RkN1/dITQCdXFk=").unwrap()),
            },
            Some(StorePathRef::from_bytes(b"06qi00hylriyfm0nl827crgjvbax84mz-notmuch-extract-patch").unwrap()),
            "notmuch-extract-patch"
        )]
        #[case::url_custom_name(
            Fetch::URL{
                url: Url::parse("https://test.example/owo").unwrap(),
                exp_hash: Some(nixhash::from_sri_str("sha256-Xa1Jbl2Eq5+L0ww+Ph1osA3Z/Dxe/RkN1/dITQCdXFk=").unwrap()),
            },
            Some(StorePathRef::from_bytes(b"06qi00hylriyfm0nl827crgjvbax84mz-notmuch-extract-patch").unwrap()),
            "notmuch-extract-patch"
        )]
        #[case::nar_sha256(
            Fetch::NAR{
                url: Url::parse("https://cache.nixos.org/nar/0r8nqa1klm5v17ifc6z96m9wywxkjvgbnqq9pmy0sgqj53wj3n12.nar.xz").unwrap(),
                hash: nixhash::from_sri_str("sha256-oj6yfWKbcEerK8D9GdPJtIAOveNcsH1ztGeSARGypRA=").unwrap(),
            },
            Some(StorePathRef::from_bytes(b"b40vjphshq4fdgv8s3yrp0bdlafi4920-0r8nqa1klm5v17ifc6z96m9wywxkjvgbnqq9pmy0sgqj53wj3n12.nar.xz").unwrap()),
            "0r8nqa1klm5v17ifc6z96m9wywxkjvgbnqq9pmy0sgqj53wj3n12.nar.xz"
        )]
        #[case::nar_sha1(
            Fetch::NAR{
                url: Url::parse("https://cache.nixos.org/nar/0r8nqa1klm5v17ifc6z96m9wywxkjvgbnqq9pmy0sgqj53wj3n12.nar.xz").unwrap(),
                hash: nixhash::from_sri_str("sha1-F/fMsgwkXF8fPCg1v9zPZ4yOFIA=").unwrap(),
            },
            Some(StorePathRef::from_bytes(b"8kx7fdkdbzs4fkfb57xq0cbhs20ymq2n-0r8nqa1klm5v17ifc6z96m9wywxkjvgbnqq9pmy0sgqj53wj3n12.nar.xz").unwrap()),
            "0r8nqa1klm5v17ifc6z96m9wywxkjvgbnqq9pmy0sgqj53wj3n12.nar.xz"
        )]
        #[case::nar_sha1(
            Fetch::Executable{
                url: Url::parse("https://cache.nixos.org/nar/0r8nqa1klm5v17ifc6z96m9wywxkjvgbnqq9pmy0sgqj53wj3n12.nar.xz").unwrap(),
                hash: nixhash::from_sri_str("sha1-NKNeU1csW5YJ4lCeWH3Z/apppNU=").unwrap(),
            },
            Some(StorePathRef::from_bytes(b"y92hm2xfk1009hrq0ix80j4m5k4j4w21-0r8nqa1klm5v17ifc6z96m9wywxkjvgbnqq9pmy0sgqj53wj3n12.nar.xz").unwrap()),
            "0r8nqa1klm5v17ifc6z96m9wywxkjvgbnqq9pmy0sgqj53wj3n12.nar.xz"
        )]
        fn fetch_store_path(
            #[case] fetch: Fetch,
            #[case] exp_path: Option<StorePathRef>,
            #[case] name: &str,
        ) {
            assert_eq!(
                exp_path,
                fetch.compute_store_path(name).expect("invalid name"),
                "unexpected calculated store path"
            );
        }

        #[test]
        fn fetch_tarball_store_path() {
            let url = Url::parse("https://github.com/NixOS/nixpkgs/archive/91050ea1e57e50388fa87a3302ba12d188ef723a.tar.gz").unwrap();
            let exp_sha256 =
                nixbase32::decode_fixed("1hf6cgaci1n186kkkjq106ryf8mmlq9vnwgfwh625wa8hfgdn4dm")
                    .unwrap();
            let fetch = Fetch::Tarball {
                url,
                exp_nar_sha256: Some(exp_sha256),
            };

            assert_eq!(
                "7adgvk5zdfq4pwrhsm3n9lzypb12gw0g-source",
                &fetch
                    .compute_store_path("source")
                    .unwrap()
                    .unwrap()
                    .to_string(),
            )
        }
    }

    mod url_basename {
        use super::super::*;
        use rstest::rstest;

        #[rstest]
        #[case::empty_path("", "")]
        #[case::path_on_root("/dir", "dir")]
        #[case::relative_path("dir/foo", "foo")]
        #[case::root_with_trailing_slash("/", "")]
        #[case::trailing_slash("/dir/", "dir")]
        fn test_url_basename(#[case] url_path: &str, #[case] exp_basename: &str) {
            let mut url = Url::parse("http://localhost").expect("invalid url");
            url.set_path(url_path);
            assert_eq!(url_basename(&url), exp_basename);
        }
    }
}
