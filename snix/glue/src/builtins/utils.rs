use bstr::ByteSlice;
use snix_eval::{
    CatchableErrorKind, CoercionKind, ErrorKind, NixAttrs, NixString, Value,
    generators::{self, GenCo},
    try_cek,
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
        let str = try_cek!(strong_importing_coerce_to_string(co, attr.clone()).await);
        return Ok(Ok(Some(str.to_str()?.to_owned())));
    }

    Ok(Ok(None))
}
