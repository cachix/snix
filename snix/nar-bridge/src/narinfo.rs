use axum::{http::StatusCode, response::IntoResponse};
use bytes::Bytes;
use nix_compat::{
    narinfo::{NarInfo, Signature},
    nix_http, nixbase32,
    store_path::StorePath,
};
use snix_store::pathinfoservice::PathInfo;
use tracing::{instrument, warn, Span};

use crate::AppState;

/// The size limit for NARInfo uploads nar-bridge receives
const NARINFO_LIMIT: usize = 2 * 1024 * 1024;

#[instrument(skip_all, fields(path_info.name=%narinfo_str))]
pub async fn head(
    axum::extract::Path(narinfo_str): axum::extract::Path<String>,
    axum::extract::State(AppState {
        path_info_service, ..
    }): axum::extract::State<AppState>,
) -> Result<impl IntoResponse, StatusCode> {
    let digest = nix_http::parse_narinfo_str(&narinfo_str).ok_or(StatusCode::NOT_FOUND)?;
    Span::current().record("path_info.digest", &narinfo_str[0..32]);

    if path_info_service
        .get(digest)
        .await
        .map_err(|e| {
            warn!(err=%e, "failed to get PathInfo");
            StatusCode::INTERNAL_SERVER_ERROR
        })?
        .is_some()
    {
        Ok(([("content-type", nix_http::MIME_TYPE_NARINFO)], ""))
    } else {
        warn!("PathInfo not found");
        Err(StatusCode::NOT_FOUND)
    }
}

#[instrument(skip_all, fields(path_info.name=%narinfo_str))]
pub async fn get(
    axum::extract::Path(narinfo_str): axum::extract::Path<String>,
    axum::extract::State(AppState {
        path_info_service, ..
    }): axum::extract::State<AppState>,
) -> Result<impl IntoResponse, StatusCode> {
    let digest = nix_http::parse_narinfo_str(&narinfo_str).ok_or(StatusCode::NOT_FOUND)?;
    Span::current().record("path_info.digest", &narinfo_str[0..32]);

    // fetch the PathInfo
    let path_info = path_info_service
        .get(digest)
        .await
        .map_err(|e| {
            warn!(err=%e, "failed to get PathInfo");
            StatusCode::INTERNAL_SERVER_ERROR
        })?
        .ok_or(StatusCode::NOT_FOUND)?;

    Ok((
        [("content-type", nix_http::MIME_TYPE_NARINFO)],
        gen_narinfo_str(&path_info),
    ))
}

#[instrument(skip_all, fields(path_info.name=%narinfo_str))]
pub async fn put(
    axum::extract::Path(narinfo_str): axum::extract::Path<String>,
    axum::extract::State(AppState {
        path_info_service,
        root_nodes,
        ..
    }): axum::extract::State<AppState>,
    request: axum::extract::Request,
) -> Result<&'static str, StatusCode> {
    let _narinfo_digest = nix_http::parse_narinfo_str(&narinfo_str).ok_or(StatusCode::UNAUTHORIZED);
    Span::current().record("path_info.digest", &narinfo_str[0..32]);

    let narinfo_bytes: Bytes = axum::body::to_bytes(request.into_body(), NARINFO_LIMIT)
        .await
        .map_err(|e| {
            warn!(err=%e, "unable to fetch body");
            StatusCode::BAD_REQUEST
        })?;

    // Parse the narinfo from the body.
    let narinfo_str = std::str::from_utf8(narinfo_bytes.as_ref()).map_err(|e| {
        warn!(err=%e, "unable decode body as string");
        StatusCode::BAD_REQUEST
    })?;

    let narinfo = NarInfo::parse(narinfo_str).map_err(|e| {
        warn!(err=%e, "unable to parse narinfo");
        StatusCode::BAD_REQUEST
    })?;

    // Extract the NARHash from the PathInfo.
    Span::current().record("path_info.nar_info", nixbase32::encode(&narinfo.nar_hash));

    // Lookup root node with peek, as we don't want to update the LRU list.
    // We need to be careful to not hold the RwLock across the await point.
    let maybe_root_node: Option<snix_castore::Node> =
        root_nodes.read().peek(&narinfo.nar_hash).cloned();

    match maybe_root_node {
        Some(root_node) => {
            // Persist the PathInfo.
            path_info_service
                .put(PathInfo {
                    store_path: narinfo.store_path.to_owned(),
                    node: root_node,
                    references: narinfo.references.iter().map(StorePath::to_owned).collect(),
                    nar_sha256: narinfo.nar_hash,
                    nar_size: narinfo.nar_size,
                    signatures: narinfo
                        .signatures
                        .into_iter()
                        .map(|s| {
                            Signature::<String>::new(s.name().to_string(), s.bytes().to_owned())
                        })
                        .collect(),
                    deriver: narinfo.deriver.as_ref().map(StorePath::to_owned),
                    ca: narinfo.ca,
                })
                .await
                .map_err(|e| {
                    warn!(err=%e, "failed to persist the PathInfo");
                    StatusCode::INTERNAL_SERVER_ERROR
                })?;

            Ok("")
        }
        None => {
            warn!("received narinfo with unknown NARHash");
            Err(StatusCode::BAD_REQUEST)
        }
    }
}

/// Constructs a String in NARInfo format for the given [PathInfo].
fn gen_narinfo_str(path_info: &PathInfo) -> String {
    use prost::Message;

    let mut narinfo = path_info.to_narinfo();
    let url = format!(
        "nar/snix-castore/{}?narsize={}",
        data_encoding::BASE64URL_NOPAD.encode(
            &snix_castore::proto::Entry::from_name_and_node("".into(), path_info.node.to_owned())
                .encode_to_vec()
        ),
        path_info.nar_size,
    );
    narinfo.url = &url;

    // Set FileSize to NarSize, as otherwise progress reporting in Nix looks very broken
    narinfo.file_size = Some(narinfo.nar_size);

    narinfo.to_string()
}

#[cfg(test)]
mod tests {
    use std::{num::NonZero, sync::Arc};

    use axum::http::Method;
    use nix_compat::nixbase32;
    use snix_castore::{
        blobservice::{BlobService, MemoryBlobService},
        directoryservice::{DirectoryService, MemoryDirectoryService},
    };
    use snix_store::{
        fixtures::{DUMMY_PATH_DIGEST, NAR_CONTENTS_SYMLINK, PATH_INFO, PATH_INFO_SYMLINK},
        path_info::PathInfo,
        pathinfoservice::{MemoryPathInfoService, PathInfoService},
    };
    use tracing_test::traced_test;

    use crate::AppState;

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

    fn gen_nix_like_narinfo(path_info: &PathInfo) -> String {
        let mut narinfo = path_info.to_narinfo();

        let url = format!("nar/{}.nar", nixbase32::encode(&path_info.nar_sha256));
        narinfo.url = &url;
        narinfo.to_string()
    }

    /// HEAD and GET for a NARInfo for which there's no PathInfo should fail.
    #[traced_test]
    #[tokio::test]
    async fn test_get_head_not_found() {
        let (server, _blob_service, _directory_service, _path_info_service) =
            gen_server(crate::gen_router(100));

        let url = &format!("{}.narinfo", nixbase32::encode(&DUMMY_PATH_DIGEST));

        // HEAD
        server
            .method(Method::HEAD, url)
            .expect_failure()
            .await
            .assert_status_not_found();

        // GET
        server
            .get(url)
            .expect_failure()
            .await
            .assert_status_not_found();
    }

    /// HEAD and GET for a NARInfo for which there's a PathInfo stored succeeds.
    #[traced_test]
    #[tokio::test]
    async fn test_get_head_found() {
        let (server, _blob_service, _directory_service, path_info_service) =
            gen_server(crate::gen_router(100));

        let url = &format!("{}.narinfo", nixbase32::encode(&DUMMY_PATH_DIGEST));

        path_info_service
            .put(PATH_INFO.clone())
            .await
            .expect("put pathinfo");

        server
            .method(Method::HEAD, url)
            .expect_success()
            .await
            .assert_status_ok();

        // GET
        let narinfo_bytes = server.get(url).expect_success().await.into_bytes();

        assert_eq!(crate::narinfo::gen_narinfo_str(&PATH_INFO), narinfo_bytes);
    }

    /// Uploading a NARInfo without the NAR previously uploaded should fail.
    #[traced_test]
    #[tokio::test]
    async fn test_put_without_prev_nar_fail() {
        let (server, _blob_service, _directory_service, _path_info_service) =
            gen_server(crate::gen_router(100));

        // Produce a NARInfo the same way nix does.
        // FUTUREWORK: add tests for NARInfo with unsupported formats
        // (again referring with compression for example)
        let narinfo_str = gen_nix_like_narinfo(&PATH_INFO_SYMLINK);

        server
            .put(&format!(
                "{}.narinfo",
                nixbase32::encode(&PATH_INFO_SYMLINK.nar_sha256)
            ))
            .text(narinfo_str)
            .content_type(nix_compat::nix_http::MIME_TYPE_NARINFO)
            .expect_failure()
            .await;
    }

    // Upload a NAR, then a PathInfo referring to that upload.
    #[traced_test]
    #[tokio::test]
    async fn test_upload_nar_then_narinfo() {
        let (server, _blob_service, _directory_service, _path_info_service) =
            gen_server(crate::gen_router(100));

        // upload NAR
        server
            .put(&format!(
                "/nar/{}.nar",
                nixbase32::encode(&PATH_INFO_SYMLINK.nar_sha256)
            ))
            .bytes(NAR_CONTENTS_SYMLINK[..].into())
            .expect_success()
            .await;

        let narinfo_str = gen_nix_like_narinfo(&PATH_INFO_SYMLINK);

        // upload NARInfo
        server
            .put(&format!(
                "/{}.narinfo",
                nixbase32::encode(PATH_INFO_SYMLINK.store_path.digest())
            ))
            .text(narinfo_str)
            .content_type(nix_compat::nix_http::MIME_TYPE_NARINFO)
            .expect_success()
            .await;
    }
}
