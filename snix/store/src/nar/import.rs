use nix_compat::{
    nar::reader::r#async as nar_reader,
    nixhash::{CAHash, NixHash},
};
use sha2::Digest;
use snix_castore::{
    Node, PathBuf,
    blobservice::BlobService,
    directoryservice::DirectoryService,
    import::{
        IngestionEntry, IngestionError,
        blobs::{self, ConcurrentBlobUploader},
        ingest_entries,
    },
};
use tokio::{
    io::{AsyncBufRead, AsyncRead},
    sync::mpsc,
    try_join,
};

use super::hashing_reader::HashingReader;

/// Represents errors that can happen during nar ingestion.
#[derive(Debug, thiserror::Error)]
pub enum NarIngestionError {
    #[error("{0}")]
    IngestionError(#[from] IngestionError<Error>),

    #[error("Hash mismatch, expected: {expected}, got: {actual}.")]
    HashMismatch { expected: NixHash, actual: NixHash },

    #[error("Expected the nar to contain a single file.")]
    TypeMismatch,

    #[error("Ingestion failed: {0}")]
    Io(#[from] std::io::Error),
}

/// Ingests the contents from a [AsyncRead] providing NAR into the snix store,
/// interacting with a [BlobService] and [DirectoryService].
/// Returns the castore root node, as well as the sha256 and size of the NAR
/// contents ingested.
pub async fn ingest_nar_and_hash<R, BS, DS>(
    blob_service: BS,
    directory_service: DS,
    r: &mut R,
    expected_cahash: &Option<CAHash>,
) -> Result<(Node, [u8; 32], u64), NarIngestionError>
where
    R: AsyncRead + Unpin + Send,
    BS: BlobService + Clone + 'static,
    DS: DirectoryService,
{
    let mut nar_hash = sha2::Sha256::new();
    let mut nar_size = 0;

    // Assemble NarHash and NarSize as we read bytes.
    let mut r = tokio_util::io::InspectReader::new(r, |b| {
        nar_size += b.len() as u64;
        nar_hash.update(b);
    });

    match expected_cahash {
        Some(CAHash::Nar(expected_hash)) => {
            // We technically don't need the Sha256 hasher as we are already computing the nar hash with the reader above,
            // but it makes the control flow more uniform and easier to understand.
            let mut ca_reader = HashingReader::new_with_algo(expected_hash.algo(), &mut r);
            let mut r = tokio::io::BufReader::new(&mut ca_reader);
            let root_node = ingest_nar(blob_service, directory_service, &mut r).await?;
            let actual_hash = ca_reader.consume();

            if actual_hash != *expected_hash {
                return Err(NarIngestionError::HashMismatch {
                    expected: expected_hash.clone(),
                    actual: actual_hash,
                });
            }
            Ok((root_node, nar_hash.finalize().into(), nar_size))
        }
        Some(CAHash::Flat(expected_hash)) => {
            let mut r = tokio::io::BufReader::new(&mut r);
            let root_node = ingest_nar(blob_service.clone(), directory_service, &mut r).await?;
            match &root_node {
                Node::File { digest, .. } => match blob_service.open_read(digest).await? {
                    Some(blob_reader) => {
                        let mut ca_reader =
                            HashingReader::new_with_algo(expected_hash.algo(), blob_reader);
                        tokio::io::copy(&mut ca_reader, &mut tokio::io::empty()).await?;
                        let actual_hash = ca_reader.consume();

                        if actual_hash != *expected_hash {
                            return Err(NarIngestionError::HashMismatch {
                                expected: expected_hash.clone(),
                                actual: actual_hash,
                            });
                        }
                        Ok((root_node, nar_hash.finalize().into(), nar_size))
                    }
                    None => Err(NarIngestionError::Io(std::io::Error::other(
                        "Ingested data not found",
                    ))),
                },
                _ => Err(NarIngestionError::TypeMismatch),
            }
        }
        // We either got CAHash::Text, or no CAHash at all, so we just don't do any additional
        // hash calculation/validation.
        // FUTUREWORK: We should figure out what to do with CAHash::Text, according to nix-cpp
        // they don't handle it either:
        // https://github.com/NixOS/nix/blob/3e9cc78eb5e5c4f1e762e201856273809fd92e71/src/libstore/local-store.cc#L1099-L1133
        _ => {
            let mut r = tokio::io::BufReader::new(&mut r);
            let root_node = ingest_nar(blob_service, directory_service, &mut r).await?;
            Ok((root_node, nar_hash.finalize().into(), nar_size))
        }
    }
}

/// Ingests the contents from a [AsyncRead] providing NAR into the snix store,
/// interacting with a [BlobService] and [DirectoryService].
/// It returns the castore root node or an error.
pub async fn ingest_nar<R, BS, DS>(
    blob_service: BS,
    directory_service: DS,
    r: &mut R,
) -> Result<Node, IngestionError<Error>>
where
    R: AsyncBufRead + Unpin + Send,
    BS: BlobService + Clone + 'static,
    DS: DirectoryService,
{
    // open the NAR for reading.
    // The NAR reader emits nodes in DFS preorder.
    let root_node = nar_reader::open(r).await.map_err(Error::IO)?;

    let (tx, rx) = mpsc::channel(1);
    let rx = tokio_stream::wrappers::ReceiverStream::new(rx);

    let produce = async move {
        let mut blob_uploader = ConcurrentBlobUploader::new(blob_service);

        let res = produce_nar_inner(
            &mut blob_uploader,
            root_node,
            "root".parse().unwrap(), // HACK: the root node sent to ingest_entries may not be ROOT.
            tx.clone(),
        )
        .await;

        if let Err(err) = blob_uploader.join().await {
            tx.send(Err(err.into()))
                .await
                .map_err(|e| Error::IO(std::io::Error::new(std::io::ErrorKind::BrokenPipe, e)))?;
        }

        tx.send(res)
            .await
            .map_err(|e| Error::IO(std::io::Error::new(std::io::ErrorKind::BrokenPipe, e)))?;

        Ok(())
    };

    let consume = ingest_entries(directory_service, rx);

    let (_, node) = try_join!(produce, consume)?;

    Ok(node)
}

async fn produce_nar_inner<BS>(
    blob_uploader: &mut ConcurrentBlobUploader<BS>,
    node: nar_reader::Node<'_, '_>,
    path: PathBuf,
    tx: mpsc::Sender<Result<IngestionEntry, Error>>,
) -> Result<IngestionEntry, Error>
where
    BS: BlobService + Clone + 'static,
{
    Ok(match node {
        nar_reader::Node::Symlink { target } => IngestionEntry::Symlink { path, target },
        nar_reader::Node::File {
            executable,
            mut reader,
        } => {
            let size = reader.len();
            let digest = blob_uploader.upload(&path, size, &mut reader).await?;

            IngestionEntry::Regular {
                path,
                size,
                executable,
                digest,
            }
        }
        nar_reader::Node::Directory(mut dir_reader) => {
            while let Some(entry) = dir_reader.next().await? {
                let mut path = path.clone();

                // valid NAR names are valid castore names
                path.try_push(entry.name)
                    .expect("Snix bug: failed to join name");

                let entry = Box::pin(produce_nar_inner(
                    blob_uploader,
                    entry.node,
                    path,
                    tx.clone(),
                ))
                .await?;

                tx.send(Ok(entry)).await.map_err(|e| {
                    Error::IO(std::io::Error::new(std::io::ErrorKind::BrokenPipe, e))
                })?;
            }

            IngestionEntry::Dir { path }
        }
    })
}

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error(transparent)]
    IO(#[from] std::io::Error),

    #[error(transparent)]
    BlobUpload(#[from] blobs::Error),
}

#[cfg(test)]
mod test {
    use crate::fixtures::{
        NAR_CONTENTS_COMPLICATED, NAR_CONTENTS_HELLOWORLD, NAR_CONTENTS_SYMLINK,
    };
    use crate::nar::{NarIngestionError, ingest_nar, ingest_nar_and_hash};
    use std::io::Cursor;
    use std::sync::Arc;

    use hex_literal::hex;
    use nix_compat::nixhash::{CAHash, NixHash};
    use rstest::*;
    use snix_castore::blobservice::BlobService;
    use snix_castore::directoryservice::DirectoryService;
    use snix_castore::fixtures::{
        DIRECTORY_COMPLICATED, DIRECTORY_WITH_KEEP, EMPTY_BLOB_DIGEST, HELLOWORLD_BLOB_CONTENTS,
        HELLOWORLD_BLOB_DIGEST,
    };
    use snix_castore::{Directory, Node};
    use tokio_stream::StreamExt;

    use crate::tests::fixtures::{blob_service, directory_service};

    #[rstest]
    #[tokio::test]
    async fn single_symlink(
        blob_service: Arc<dyn BlobService>,
        directory_service: Arc<dyn DirectoryService>,
    ) {
        let root_node = ingest_nar(
            blob_service,
            directory_service,
            &mut Cursor::new(&NAR_CONTENTS_SYMLINK),
        )
        .await
        .expect("must parse");

        assert_eq!(
            Node::Symlink {
                target: "/nix/store/somewhereelse".try_into().unwrap()
            },
            root_node
        );
    }

    #[rstest]
    #[tokio::test]
    async fn single_file(
        blob_service: Arc<dyn BlobService>,
        directory_service: Arc<dyn DirectoryService>,
    ) {
        let root_node = ingest_nar(
            blob_service.clone(),
            directory_service,
            &mut Cursor::new(&NAR_CONTENTS_HELLOWORLD),
        )
        .await
        .expect("must parse");

        assert_eq!(
            Node::File {
                digest: HELLOWORLD_BLOB_DIGEST.clone(),
                size: HELLOWORLD_BLOB_CONTENTS.len() as u64,
                executable: false,
            },
            root_node
        );

        // blobservice must contain the blob
        assert!(blob_service.has(&HELLOWORLD_BLOB_DIGEST).await.unwrap());
    }

    #[rstest]
    #[tokio::test]
    async fn complicated(
        blob_service: Arc<dyn BlobService>,
        directory_service: Arc<dyn DirectoryService>,
    ) {
        let root_node = ingest_nar(
            blob_service.clone(),
            directory_service.clone(),
            &mut Cursor::new(&NAR_CONTENTS_COMPLICATED),
        )
        .await
        .expect("must parse");

        assert_eq!(
            Node::Directory {
                digest: DIRECTORY_COMPLICATED.digest(),
                size: DIRECTORY_COMPLICATED.size()
            },
            root_node,
        );

        // blobservice must contain the blob
        assert!(blob_service.has(&EMPTY_BLOB_DIGEST).await.unwrap());

        // directoryservice must contain the directories, at least with get_recursive.
        let resp: Result<Vec<Directory>, _> = directory_service
            .get_recursive(&DIRECTORY_COMPLICATED.digest())
            .collect()
            .await;

        let directories = resp.unwrap();

        assert_eq!(2, directories.len());
        assert_eq!(DIRECTORY_COMPLICATED.clone(), directories[0]);
        assert_eq!(DIRECTORY_WITH_KEEP.clone(), directories[1]);
    }

    #[rstest]
    #[case::nar_sha256(Some(CAHash::Nar(NixHash::Sha256(hex!("fbd52279a8df024c9fd5718de4103bf5e760dc7f2cf49044ee7dea87ab16911a")))), NAR_CONTENTS_COMPLICATED.as_slice())]
    #[case::nar_sha512(Some(CAHash::Nar(NixHash::Sha512(Box::new(hex!("ff5d43941411f35f09211f8596b426ee6e4dd3af1639e0ed2273cbe44b818fc4a59e3af02a057c5b18fbfcf435497de5f1994206c137f469b3df674966a922f0"))))), NAR_CONTENTS_COMPLICATED.as_slice())]
    #[case::flat_md5(Some(CAHash::Flat(NixHash::Md5(hex!("fd076287532e86365e841e92bfc50d8c")))), NAR_CONTENTS_HELLOWORLD.as_slice() )]
    #[case::nar_symlink_sha1(Some(CAHash::Nar(NixHash::Sha1(hex!("f24eeaaa9cc016bab030bf007cb1be6483e7ba9e")))), NAR_CONTENTS_SYMLINK.as_slice())]
    #[tokio::test]
    async fn ingest_with_cahash_mismatch(
        blob_service: Arc<dyn BlobService>,
        directory_service: Arc<dyn DirectoryService>,
        #[case] ca_hash: Option<CAHash>,
        #[case] nar_content: &[u8],
    ) {
        let err = ingest_nar_and_hash(
            blob_service.clone(),
            directory_service.clone(),
            &mut Cursor::new(nar_content),
            &ca_hash,
        )
        .await
        .expect_err("Ingestion should have failed");
        assert!(
            matches!(err, NarIngestionError::HashMismatch { .. }),
            "CAHash should have mismatched"
        );
    }

    #[rstest]
    #[case::nar_sha256(Some(CAHash::Nar(NixHash::Sha256(hex!("ebd52279a8df024c9fd5718de4103bf5e760dc7f2cf49044ee7dea87ab16911a")))), &NAR_CONTENTS_COMPLICATED.clone())]
    #[case::nar_sha512(Some(CAHash::Nar(NixHash::Sha512(Box::new(hex!("1f5d43941411f35f09211f8596b426ee6e4dd3af1639e0ed2273cbe44b818fc4a59e3af02a057c5b18fbfcf435497de5f1994206c137f469b3df674966a922f0"))))), &NAR_CONTENTS_COMPLICATED.clone())]
    #[case::flat_md5(Some(CAHash::Flat(NixHash::Md5(hex!("ed076287532e86365e841e92bfc50d8c")))), &NAR_CONTENTS_HELLOWORLD.clone())]
    #[case::nar_symlink_sha1(Some(CAHash::Nar(NixHash::Sha1(hex!("424eeaaa9cc016bab030bf007cb1be6483e7ba9e")))), &NAR_CONTENTS_SYMLINK.clone())]
    #[tokio::test]
    async fn ingest_with_cahash_correct(
        blob_service: Arc<dyn BlobService>,
        directory_service: Arc<dyn DirectoryService>,
        #[case] ca_hash: Option<CAHash>,
        #[case] nar_content: &[u8],
    ) {
        let _ = ingest_nar_and_hash(
            blob_service.clone(),
            directory_service,
            &mut Cursor::new(nar_content),
            &ca_hash,
        )
        .await
        .expect("CAHash should have matched");
    }

    #[rstest]
    #[case::nar_sha256(Some(CAHash::Flat(NixHash::Sha256(hex!("ebd52279a8df024c9fd5718de4103bf5e760dc7f2cf49044ee7dea87ab16911a")))), &NAR_CONTENTS_COMPLICATED.clone())]
    #[case::nar_symlink_sha1(Some(CAHash::Flat(NixHash::Sha1(hex!("424eeaaa9cc016bab030bf007cb1be6483e7ba9e")))), &NAR_CONTENTS_SYMLINK.clone())]
    #[tokio::test]
    async fn ingest_with_flat_non_file(
        blob_service: Arc<dyn BlobService>,
        directory_service: Arc<dyn DirectoryService>,
        #[case] ca_hash: Option<CAHash>,
        #[case] nar_content: &[u8],
    ) {
        let err = ingest_nar_and_hash(
            blob_service,
            directory_service,
            &mut Cursor::new(nar_content),
            &ca_hash,
        )
        .await
        .expect_err("Ingestion should have failed");

        assert!(
            matches!(err, NarIngestionError::TypeMismatch),
            "Flat cahash should only be allowed for single file nars"
        );
    }
}
