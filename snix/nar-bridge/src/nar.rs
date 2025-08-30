use axum::extract::Query;
use axum::http::{Response, StatusCode};
use axum::{body::Body, response::IntoResponse};
use axum_extra::{TypedHeader, headers::Range};
use axum_range::{KnownSize, Ranged};
use bytes::Bytes;
use data_encoding::BASE64URL_NOPAD;
use futures::TryStreamExt;
use nix_compat::{nix_http, nixbase32};
use serde::Deserialize;
use snix_store::nar::ingest_nar_and_hash;
use std::io;
use tokio_util::io::ReaderStream;
use tracing::{Span, instrument, warn};

use crate::AppState;

#[derive(Debug, Deserialize)]
pub(crate) struct GetNARParams {
    #[serde(rename = "narsize")]
    nar_size: Option<u64>,
}

#[instrument(skip_all)]
pub async fn get_head(
    method: axum::http::Method,
    ranges: Option<TypedHeader<Range>>,
    axum::extract::Path(root_node_enc): axum::extract::Path<String>,
    axum::extract::Query(GetNARParams { nar_size }): Query<GetNARParams>,
    axum::extract::State(AppState {
        blob_service,
        directory_service,
        ..
    }): axum::extract::State<AppState>,
) -> Result<impl axum::response::IntoResponse, StatusCode> {
    use prost::Message;
    // We insist on the nar_size field being set. If the client dropped it from
    // the NARInfo we sent, it's misbehaving and we reject it.
    let nar_size = nar_size.ok_or_else(|| {
        warn!("no nar_size parameter set");
        StatusCode::BAD_REQUEST
    })?;

    // b64decode the root node passed *by the user*
    let root_node_proto = BASE64URL_NOPAD
        .decode(root_node_enc.as_bytes())
        .map_err(|e| {
            warn!(err=%e, "unable to decode root node b64");
            StatusCode::NOT_FOUND
        })?;

    // check the proto size to be somewhat reasonable before parsing it.
    if root_node_proto.len() > 4096 {
        warn!("rejected too large root node");
        return Err(StatusCode::BAD_REQUEST);
    }

    // parse the proto
    let root_node: snix_castore::proto::Entry = Message::decode(Bytes::from(root_node_proto))
        .map_err(|e| {
            warn!(err=%e, "unable to decode root node proto");
            StatusCode::NOT_FOUND
        })?;

    let root_node = root_node.try_into_anonymous_node().map_err(|e| {
        warn!(err=%e, "root node validation failed");
        StatusCode::NOT_FOUND
    })?;

    Ok((
        // headers
        [
            ("cache-control", "max-age=31536000, immutable"),
            ("content-type", nix_http::MIME_TYPE_NAR),
        ],
        if method == axum::http::Method::HEAD {
            // If this is a HEAD request, construct a response returning back the
            // user-provided content-length, but don't actually talk to castore.
            // If the client lied about it, we will echo back a wrong `Content-Length`,
            // which is their problem.
            Response::builder()
                .header("content-length", nar_size)
                .body(Body::empty())
                .unwrap()
        } else if let Some(TypedHeader(ranges)) = ranges {
            // If this is a range request, construct a seekable NAR reader.
            let r =
                snix_store::nar::seekable::Reader::new(root_node, blob_service, directory_service)
                    .await
                    .map_err(|e| {
                        warn!(err=%e, "failed to construct seekable nar reader");
                        StatusCode::INTERNAL_SERVER_ERROR
                    })?;

            // ensure the user-supplied nar size was correct, no point returning data otherwise.
            if r.stream_len() != nar_size {
                warn!(
                    actual_nar_size = r.stream_len(),
                    supplied_nar_size = nar_size,
                    "wrong nar size supplied"
                );
                return Err(StatusCode::BAD_REQUEST);
            }
            Ranged::new(Some(ranges), KnownSize::sized(r, nar_size)).into_response()
        } else {
            // use the non-seekable codepath if there's no range(s) requested,
            // as it uses less memory.
            let (w, r) = tokio::io::duplex(1024 * 8);

            // spawn a task rendering the NAR to the client.
            tokio::spawn(async move {
                if let Err(e) =
                    snix_store::nar::write_nar(w, &root_node, blob_service, directory_service).await
                {
                    warn!(err=%e, "failed to write out NAR");
                }
            });

            Response::builder()
                // If the client lied about it, we will echo back a wrong `Content-Length`,
                // which is their problem.
                .header("content-length", nar_size)
                .body(Body::from_stream(ReaderStream::new(r)))
                .unwrap()
        },
    ))
}

/// Handler to respond to GET/HEAD requests for recently uploaded NAR files.
/// Nix probes at {filehash}.nar[.compression_suffix] to determine whether a NAR
/// has already been uploaded, by responding to (some of) these requests we
/// avoid it unnecessarily uploading.
/// We don't keep a full K/V from NAR hash to root note around, only the
/// in-memory cache used to connect to the castore node when processing a PUT
/// for the NARInfo.
#[instrument(skip_all, fields(nar_str))]
pub async fn head_root_nodes(
    axum::extract::Path(nar_str): axum::extract::Path<String>,
    axum::extract::State(AppState { root_nodes, .. }): axum::extract::State<AppState>,
) -> Result<impl axum::response::IntoResponse, StatusCode> {
    let (nar_hash, compression_suffix) =
        nix_http::parse_nar_str(&nar_str).ok_or(StatusCode::UNAUTHORIZED)?;

    // No paths with compression suffix are supported.
    if !compression_suffix.is_empty() {
        warn!(%compression_suffix, "invalid compression suffix requested");
        return Err(StatusCode::UNAUTHORIZED);
    }

    // Check root_nodes, updating the moving it to the most recently used,
    // as it might be referred in a subsequent NARInfo upload.
    if root_nodes.write().get(&nar_hash).is_some() {
        Ok("")
    } else {
        Err(StatusCode::NOT_FOUND)
    }
}

#[instrument(skip_all)]
pub async fn put(
    axum::extract::Path(nar_str): axum::extract::Path<String>,
    axum::extract::State(AppState {
        blob_service,
        directory_service,
        root_nodes,
        ..
    }): axum::extract::State<AppState>,
    request: axum::extract::Request,
) -> Result<&'static str, StatusCode> {
    let (nar_hash_expected, compression_suffix) =
        nix_http::parse_nar_str(&nar_str).ok_or(StatusCode::UNAUTHORIZED)?;

    // No paths with compression suffix are supported.
    if !compression_suffix.is_empty() {
        warn!(%compression_suffix, "invalid compression suffix requested");
        return Err(StatusCode::UNAUTHORIZED);
    }

    let s = request.into_body().into_data_stream();

    let mut r = tokio_util::io::StreamReader::new(s.map_err(|e| {
        warn!(err=%e, "failed to read request body");
        io::Error::new(io::ErrorKind::BrokenPipe, e.to_string())
    }));

    // ingest the NAR
    let (root_node, nar_hash_actual, nar_size) = ingest_nar_and_hash(
        blob_service.clone(),
        directory_service.clone(),
        &mut r,
        &None,
    )
    .await
    .map_err(io::Error::other)
    .map_err(|e| {
        warn!(err=%e, "failed to ingest nar");
        StatusCode::INTERNAL_SERVER_ERROR
    })?;

    let s = Span::current();
    s.record("nar_hash.expected", nixbase32::encode(&nar_hash_expected));
    s.record("nar_size", nar_size);

    if nar_hash_expected != nar_hash_actual {
        warn!(
            nar_hash.expected = nixbase32::encode(&nar_hash_expected),
            nar_hash.actual = nixbase32::encode(&nar_hash_actual),
            "nar hash mismatch"
        );
        return Err(StatusCode::BAD_REQUEST);
    }

    // store mapping of narhash to root node into root_nodes.
    // we need it later to populate the root node when accepting the PathInfo.
    root_nodes.write().put(nar_hash_actual, root_node);

    Ok("")
}

#[cfg(test)]
mod tests {
    use std::{
        num::NonZero,
        sync::{Arc, LazyLock},
    };

    use axum::{Router, http::Method};
    use bytes::Bytes;
    use data_encoding::BASE64URL_NOPAD;
    use nix_compat::nixbase32;
    use sha2::Digest;
    use snix_castore::{
        blobservice::{BlobService, MemoryBlobService},
        directoryservice::{DirectoryService, MemoryDirectoryService},
        fixtures::HELLOWORLD_BLOB_DIGEST,
    };
    use snix_store::{
        fixtures::{
            CASTORE_NODE_COMPLICATED, CASTORE_NODE_SYMLINK, NAR_CONTENTS_COMPLICATED,
            NAR_CONTENTS_HELLOWORLD, NAR_CONTENTS_SYMLINK,
        },
        pathinfoservice::{MemoryPathInfoService, PathInfoService},
    };
    use tracing_test::traced_test;

    use crate::AppState;

    pub static NAR_STR_SYMLINK: LazyLock<String> = LazyLock::new(|| {
        use prost::Message;
        BASE64URL_NOPAD.encode(
            &snix_castore::proto::Entry::from_name_and_node(
                "".into(),
                CASTORE_NODE_SYMLINK.clone(),
            )
            .encode_to_vec(),
        )
    });

    /// Accepts a router without state, and returns a [axum_test::TestServer].
    fn gen_server(
        router: axum::Router<AppState>,
    ) -> (
        axum_test::TestServer,
        impl BlobService,
        impl DirectoryService,
        impl PathInfoService,
    ) {
        let blob_service = Arc::new(MemoryBlobService::default());
        let directory_service = Arc::new(MemoryDirectoryService::default());
        let path_info_service = Arc::new(MemoryPathInfoService::default());

        let app = router.with_state(AppState::new(
            blob_service.clone(),
            directory_service.clone(),
            path_info_service.clone(),
            NonZero::new(100).unwrap(),
        ));

        (
            axum_test::TestServer::new(app).unwrap(),
            blob_service,
            directory_service,
            path_info_service,
        )
    }

    #[traced_test]
    #[tokio::test]
    async fn test_get_head() {
        let (server, _blob_service, _directory_service, _path_info_service) =
            gen_server(Router::new().route(
                "/nar/snix-castore/:root_node_enc",
                axum::routing::get(super::get_head),
            ));

        // Empty nar_str should be NotFound
        server
            .method(Method::HEAD, "/nar/snix-castore/")
            .expect_failure()
            .await
            .assert_status_not_found();

        let valid_url = &format!("/nar/snix-castore/{}", &*NAR_STR_SYMLINK);
        let qps = &[("narsize", &NAR_CONTENTS_SYMLINK.len().to_string())];

        // Missing narsize should be BadRequest
        server
            .method(Method::HEAD, valid_url)
            .expect_failure()
            .await
            .assert_status_bad_request();

        let invalid_url = {
            use prost::Message;
            let n = snix_castore::proto::Entry {
                entry: Some(snix_castore::proto::entry::Entry::Directory(
                    snix_castore::proto::DirectoryEntry {
                        name: "".into(),
                        digest: "invalid b64".into(),
                        size: 1,
                    },
                )),
            };
            &format!(
                "/nar/snix-castore/{}",
                BASE64URL_NOPAD.encode(&n.encode_to_vec())
            )
        };

        // Invalid node proto should return NotFound
        server
            .method(Method::HEAD, invalid_url)
            .add_query_params(qps)
            .expect_failure()
            .await
            .assert_status_not_found();

        // success, HEAD
        server
            .method(Method::HEAD, valid_url)
            .add_query_params(qps)
            .expect_success()
            .await;

        // success, GET
        assert_eq!(
            NAR_CONTENTS_SYMLINK.as_slice(),
            server
                .get(valid_url)
                .add_query_params(qps)
                .expect_success()
                .await
                .into_bytes(),
            "Expected to get back NAR_CONTENTS_SYMLINK"
        )
    }

    /// Uploading a NAR with a different file hash than what's specified in the URL
    /// is considered an error.
    #[traced_test]
    #[tokio::test]
    async fn test_put_wrong_narhash() {
        let (server, _blob_service, _directory_service, _path_info_service) =
            gen_server(Router::new().route("/nar/:nar_str", axum::routing::put(super::put)));

        server
            .put("/nar/0000000000000000000000000000000000000000000000000000.nar")
            .bytes(Bytes::from_static(&NAR_CONTENTS_SYMLINK))
            .expect_failure()
            .await;
    }

    /// Uploading a NAR with compression is not supported.
    #[traced_test]
    #[tokio::test]
    async fn test_put_with_compression_fail() {
        let (server, _blob_service, _directory_service, _path_info_service) =
            gen_server(Router::new().route("/nar/:nar_str", axum::routing::put(super::put)));

        let nar_sha256: [u8; 32] = sha2::Sha256::new_with_prefix(NAR_CONTENTS_SYMLINK.as_slice())
            .finalize()
            .into();

        let nar_url = format!("/nar/{}.nar.zst", nixbase32::encode(&nar_sha256));

        server
            .put(&nar_url)
            .bytes(Bytes::from_static(&NAR_CONTENTS_SYMLINK))
            .expect_failure()
            .await
            .assert_status_unauthorized();
    }

    /// Upload a NAR with a single file, ensure the blob exists later on.
    #[traced_test]
    #[tokio::test]
    async fn test_put_success() {
        let (server, blob_service, _directory_service, _path_info_service) =
            gen_server(Router::new().route("/nar/:nar_str", axum::routing::put(super::put)));

        let nar_sha256: [u8; 32] =
            sha2::Sha256::new_with_prefix(NAR_CONTENTS_HELLOWORLD.as_slice())
                .finalize()
                .into();

        let nar_url = format!("/nar/{}.nar", nixbase32::encode(&nar_sha256));

        server
            .put(&nar_url)
            .bytes(Bytes::from_static(&NAR_CONTENTS_HELLOWORLD))
            .expect_success()
            .await;

        assert!(
            blob_service
                .has(&HELLOWORLD_BLOB_DIGEST)
                .await
                .expect("blobservice")
        )
    }

    // Upload a NAR with blobs and directories, ensure blobs and directories
    // were uploaded, by rendering the NAR stream from the root node we know
    // describes these contents.
    #[traced_test]
    #[tokio::test]
    async fn test_put_success2() {
        let (server, blob_service, directory_service, _path_info_service) =
            gen_server(Router::new().route("/nar/:nar_str", axum::routing::put(super::put)));

        let nar_sha256: [u8; 32] =
            sha2::Sha256::new_with_prefix(NAR_CONTENTS_COMPLICATED.as_slice())
                .finalize()
                .into();

        let nar_url = format!("/nar/{}.nar", nixbase32::encode(&nar_sha256));

        server
            .put(&nar_url)
            .bytes(Bytes::from_static(&NAR_CONTENTS_COMPLICATED))
            .expect_success()
            .await;

        let mut buf = Vec::new();
        snix_store::nar::write_nar(
            &mut buf,
            &CASTORE_NODE_COMPLICATED,
            blob_service,
            directory_service,
        )
        .await
        .expect("write nar");

        assert_eq!(NAR_CONTENTS_COMPLICATED, buf[..]);
    }

    /// Upload a NAR, ensure a HEAD by NarHash returns a 2xx code.
    #[traced_test]
    #[tokio::test]
    async fn test_put_root_nodes() {
        let (server, _blob_service, _directory_servicee, _path_info_service) = gen_server(
            Router::new()
                .route("/nar/:nar_str", axum::routing::put(super::put))
                .route("/nar/:nar_str", axum::routing::get(super::head_root_nodes)),
        );

        let nar_sha256: [u8; 32] =
            sha2::Sha256::new_with_prefix(NAR_CONTENTS_COMPLICATED.as_slice())
                .finalize()
                .into();

        let nar_url = format!("/nar/{}.nar", nixbase32::encode(&nar_sha256));

        // upload NAR
        server
            .put(&nar_url)
            .bytes(Bytes::from_static(&NAR_CONTENTS_COMPLICATED))
            .expect_success()
            .await;

        // check HEAD by NarHash
        server.method(Method::HEAD, &nar_url).expect_success().await;
    }
}
