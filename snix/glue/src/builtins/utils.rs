use bstr::ByteSlice;
use snix_eval::{
    generators::{self, GenCo},
    CatchableErrorKind, CoercionKind, ErrorKind, NixAttrs, NixString, Value,
};

pub(super) async fn strong_importing_coerce_to_string(
    co: &GenCo,
    val: Value,
) -> Result<NixString, CatchableErrorKind> {
    let val = generators::request_force(co, val).await;
    generators::request_string_coerce(
        co,
        val,
        CoercionKind {
            strong: true,
            import_paths: true,
        },
    )
    .await
}

pub(super) async fn select_string(
    co: &GenCo,
    attrs: &NixAttrs,
    key: &str,
) -> Result<Result<Option<String>, CatchableErrorKind>, ErrorKind> {
    if let Some(attr) = attrs.select(key) {
        match strong_importing_coerce_to_string(co, attr.clone()).await {
            Err(cek) => return Ok(Err(cek)),
            Ok(str) => return Ok(Ok(Some(str.to_str()?.to_owned()))),
        }
    }

    Ok(Ok(None))
}

pub(super) fn git_find_remote_rev(
    url: &str,
    r#ref: Option<&str>,
) -> Result<String, CatchableErrorKind> {
    // Parse URL
    let parsed_url = gix::url::parse(url.as_ref()).map_err(|e| {
        CatchableErrorKind::Throw(format!("Failed to parse git URL '{}': {}", url, e).into())
    })?;

    // Connect directly to the remote without a repository
    let mut transport = gix_transport::client::connect(
        parsed_url,
        gix_transport::client::connect::Options {
            version: gix_transport::Protocol::V1, // V1 protocol includes refs in the handshake
            ssh: Default::default(),
            trace: false,
        },
    )
    .map_err(|e| {
        CatchableErrorKind::Throw(
            format!("Failed to connect to git repository '{}': {}", url, e).into(),
        )
    })?;

    // Make a Service Response
    let response = transport
        .handshake(gix_transport::Service::UploadPack, &[])
        .map_err(|e| {
            CatchableErrorKind::Throw(format!("Git handshake failed for '{}': {}", url, e).into())
        })?;

    // Make sure we have refs - with V1 protocol they should be provided in the handshake
    let Some(mut lines) = response.refs else {
        return Err(CatchableErrorKind::Throw(
            format!("No references found in '{}'", url).into(),
        ));
    };

    // Parse the refs
    let (refs, _) = gix::protocol::handshake::refs::from_v1_refs_received_as_part_of_handshake_and_capabilities(
        &mut lines,
        response.capabilities.iter()
    )
    .map_err(|e| CatchableErrorKind::Throw(format!("Failed to parse git refs for '{}': {}", url, e).into()))?;

    let mut head_rev = None;

    // Iterate once through refs
    for reference in refs.iter() {
        let (full_ref_name, object) = match reference {
            gix::protocol::handshake::Ref::Direct {
                full_ref_name,
                object,
            } => (full_ref_name, object),
            gix::protocol::handshake::Ref::Symbolic {
                full_ref_name,
                object,
                ..
            } => (full_ref_name, object),
            _ => continue,
        };

        let ref_name = full_ref_name.as_bstr();

        // If a specific ref was requested and we found it, return immediately
        if let Some(req_ref) = r#ref {
            if ref_name == req_ref || ref_name == format!("refs/heads/{}", req_ref).as_bytes() {
                return Ok(object.to_string());
            }
        }

        // Track the HEAD/master/main ref for fallback
        if head_rev.is_none()
            && (ref_name == "HEAD"
                || ref_name == "refs/heads/master"
                || ref_name == "refs/heads/main")
        {
            head_rev = Some(object.to_string());
        }
    }

    // If a specific ref was requested but not found, return an error
    if let Some(req_ref) = r#ref {
        return Err(CatchableErrorKind::Throw(
            format!(
                "Requested git reference '{}' not found in '{}'",
                req_ref, url
            )
            .into(),
        ));
    }

    // Return the HEAD/master/main ref if found
    head_rev.ok_or_else(|| {
        CatchableErrorKind::Throw(format!("No suitable reference found in '{}'", url).into())
    })
}
