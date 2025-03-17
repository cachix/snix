//! Contains builtins that fetch paths from the Internet, or local filesystem.

use super::utils::select_string;
use crate::{
    fetchers::{url_basename, Fetch, FetchGitArgs},
    snix_store_io::SnixStoreIO,
};
use bstr::{BString, ByteSlice};
use nix_compat::nixhash;
use snix_eval::builtin_macros::builtins;
use snix_eval::generators::Gen;
use snix_eval::generators::GenCo;
use snix_eval::NixAttrs;
use snix_eval::{CatchableErrorKind, ErrorKind, Value};
use std::rc::Rc;
use url::Url;

/// Metadata returned by fetchers
#[derive(Debug, Clone)]
pub struct FetcherMetadata {
    /// Unix timestamp of the last modification in seconds
    pub last_modified: u64,
    /// Date of the last modification in YYYYMMDDHHmmss format
    pub last_modified_date: String,
    /// Fetcher specific metadata
    pub fetcher: FetchGitResult,
}

#[derive(Debug, Clone)]
pub struct FetchGitResult {
    /// The path to the output in the Nix store
    pub out_path: String,
    /// The full Git revision hash
    pub rev: BString,
    /// The number of commits in the repository
    pub rev_count: i64,
    /// The abbreviated Git revision hash (typically first 7 characters)
    pub short_rev: BString,
    /// Whether submodules are included in the fetch
    pub submodules: bool,
    /// The NAR hash of the output
    pub nar_hash: Option<String>,
}

impl From<FetchGitResult> for Value {
    fn from(value: FetchGitResult) -> Self {
        // Create a vector with the order preserved
        let mut attrs_vec: Vec<(String, Value)> = Vec::new();

        // Add attributes in the expected order
        // IMPORTANT: This matches the order in the test .exp file
        attrs_vec.push(("outPath".to_string(), Value::from(value.out_path)));

        if let Some(nar_hash) = value.nar_hash {
            attrs_vec.push(("narHash".to_string(), Value::from(nar_hash)));
        }

        attrs_vec.push(("rev".to_string(), Value::from(value.rev.clone())));
        attrs_vec.push(("revCount".to_string(), Value::from(value.rev_count)));
        attrs_vec.push(("shortRev".to_string(), Value::from(value.short_rev)));
        attrs_vec.push(("submodules".to_string(), Value::from(value.submodules)));

        // Convert to NixAttrs - the order is preserved
        Value::Attrs(Box::new(NixAttrs::from_iter(attrs_vec)))
    }
}

fn to_bstring(value: &Value) -> Result<BString, ErrorKind> {
    match value {
        Value::String(s) => Ok(s.clone().into_bstring()),
        Value::Thunk(thunk) => to_bstring(&thunk.value()),
        value => Err(ErrorKind::TypeError {
            expected: "string",
            actual: value.type_of(),
        }),
    }
}

fn to_string(value: &Value) -> Result<String, ErrorKind> {
    match value {
        Value::String(s) => Ok(s.clone().into_bstring().as_bstr().to_string()),
        Value::Thunk(thunk) => to_string(&thunk.value()),
        value => Err(ErrorKind::TypeError {
            expected: "string",
            actual: value.type_of(),
        }),
    }
}

fn select<'a>(attrs: &'a NixAttrs, key: &str) -> Result<&'a Value, ErrorKind> {
    attrs
        .select(key)
        .ok_or_else(|| ErrorKind::AttributeNotFound { name: key.into() })
}

fn extract_fetch_git_args_from_attrs(attrs: &NixAttrs) -> Result<FetchGitArgs, ErrorKind> {
    Ok(FetchGitArgs {
        url: to_bstring(select(attrs, "url")?)?,
        name: attrs
            .select("name")
            .map(to_string)
            .transpose()?
            .unwrap_or("source".to_string()),
        rev: attrs.select("rev").map(to_bstring).transpose()?,
        r#ref: attrs
            .select("ref")
            .map(to_bstring)
            .transpose()?
            .unwrap_or("HEAD".into()),
        shallow: attrs
            .select("shallow")
            .map(|v| v.as_bool())
            .transpose()?
            .unwrap_or(false),
        all_refs: attrs
            .select("allRefs")
            .map(|v| v.as_bool())
            .transpose()?
            .unwrap_or(false),
        submodules: attrs
            .select("submodules")
            .map(|v| v.as_bool())
            .transpose()?
            .unwrap_or(false),
    })
}

fn extract_fetch_git_args_from_string(url: BString) -> Result<FetchGitArgs, ErrorKind> {
    Ok(FetchGitArgs {
        url,
        name: "source".into(),
        rev: None,
        r#ref: "HEAD".into(),
        shallow: false,
        all_refs: false,
        submodules: false,
    })
}

async fn extract_fetch_git_args(co: &GenCo, value: Value) -> Result<FetchGitArgs, ErrorKind> {
    match snix_eval::generators::request_deep_force(co, value).await {
        Value::Attrs(attrs) => extract_fetch_git_args_from_attrs(attrs.as_ref()),
        Value::String(url) => extract_fetch_git_args_from_string(url.into_bstring()),
        value => Err(ErrorKind::TypeError {
            expected: "attribute set or contextless string",
            actual: value.type_of(),
        }),
    }
}

// Used as a return type for extract_fetch_args, which is sharing some
// parsing code between the fetchurl and fetchTarball builtins.
struct NixFetchArgs {
    url: Url,
    name: Option<String>,
    sha256: Option<[u8; 32]>,
}

// `fetchurl` and `fetchTarball` accept a single argument, which can either be the URL (as string),
// or an attrset, where `url`, `sha256` and `name` keys are allowed.
async fn extract_fetch_args(
    co: &GenCo,
    args: Value,
) -> Result<Result<NixFetchArgs, CatchableErrorKind>, ErrorKind> {
    if let Ok(url_str) = args.to_str() {
        // Get the raw bytes, not the ToString repr.
        let url_str =
            String::from_utf8(url_str.as_bytes().to_vec()).map_err(|_| ErrorKind::Utf8)?;

        // Parse the URL.
        let url = Url::parse(&url_str).map_err(|e| ErrorKind::SnixError(Rc::new(e)))?;

        return Ok(Ok(NixFetchArgs {
            url,
            name: None,
            sha256: None,
        }));
    }

    let attrs = args.to_attrs().map_err(|_| ErrorKind::TypeError {
        expected: "attribute set or contextless string",
        actual: args.type_of(),
    })?;

    let url_str = match select_string(co, &attrs, "url").await? {
        Ok(s) => s.ok_or_else(|| ErrorKind::AttributeNotFound { name: "url".into() })?,
        Err(cek) => return Ok(Err(cek)),
    };
    let name = match select_string(co, &attrs, "name").await? {
        Ok(s) => s,
        Err(cek) => return Ok(Err(cek)),
    };
    let sha256_str = match select_string(co, &attrs, "sha256").await? {
        Ok(s) => s,
        Err(cek) => return Ok(Err(cek)),
    };

    // Disallow other attrset keys, to match Nix' behaviour.
    // We complain about the first unexpected key we find in the list.
    const VALID_KEYS: [&[u8]; 3] = [b"url", b"name", b"sha256"];
    if let Some(first_invalid_key) = attrs.keys().find(|k| !&VALID_KEYS.contains(&k.as_bytes())) {
        return Err(ErrorKind::UnexpectedArgumentBuiltin(
            first_invalid_key.clone(),
        ));
    }

    // parse the sha256 string into a digest.
    let sha256 = match sha256_str {
        Some(sha256_str) => {
            let nixhash = nixhash::from_str(&sha256_str, Some("sha256"))
                .map_err(|e| ErrorKind::InvalidHash(e.to_string()))?;

            Some(nixhash.digest_as_bytes().try_into().expect("is sha256"))
        }
        None => None,
    };

    // Parse the URL.
    let url = Url::parse(&url_str).map_err(|e| ErrorKind::SnixError(Rc::new(e)))?;

    Ok(Ok(NixFetchArgs { url, name, sha256 }))
}

#[allow(unused_variables)] // for the `state` arg, for now
#[builtins(state = "Rc<SnixStoreIO>")]
pub(crate) mod fetcher_builtins {
    use bstr::ByteSlice;
    use nix_compat::flakeref;
    use std::collections::BTreeMap;

    use super::*;

    /// Consumes a fetch.
    /// If there is enough info to calculate the store path without fetching,
    /// queue the fetch to be fetched lazily, and return the store path.
    /// If there's not enough info to calculate it, do the fetch now, and then
    /// return the store path.
    ///
    /// For Git fetches, also returns metadata about the repository.
    fn fetch_lazy(
        state: Rc<SnixStoreIO>,
        name: String,
        fetch: Fetch,
    ) -> Result<(Value, Option<FetcherMetadata>), ErrorKind> {
        match fetch
            .compute_store_path(&name)
            .map_err(|e| ErrorKind::SnixError(Rc::new(e)))?
        {
            Some(store_path) => {
                // Move the fetch to KnownPaths, so it can be actually fetched later.
                let sp = state
                    .known_paths
                    .borrow_mut()
                    .add_fetch(fetch, &name)
                    .expect("Snix bug: should only fail if the store path cannot be calculated");

                debug_assert_eq!(
                    sp, store_path,
                    "calculated store path by KnownPaths should match"
                );

                // Emit the calculated Store Path.
                Ok((
                    Value::Path(Box::new(store_path.to_absolute_path().into())),
                    None,
                ))
            }
            None => {
                // If we don't have enough info, do the fetch now.
                let (store_path, _root_node, _nar_hash, metadata) = state
                    .tokio_handle
                    .block_on(async { state.fetcher.ingest_and_persist(&name, fetch).await })
                    .map_err(|e| ErrorKind::SnixError(Rc::new(e)))?;

                Ok((
                    Value::Path(Box::new(store_path.to_absolute_path().into())),
                    metadata,
                ))
            }
        }
    }

    #[builtin("fetchurl")]
    async fn builtin_fetchurl(
        state: Rc<SnixStoreIO>,
        co: GenCo,
        args: Value,
    ) -> Result<Value, ErrorKind> {
        let args = match extract_fetch_args(&co, args).await? {
            Ok(args) => args,
            Err(cek) => return Ok(Value::from(cek)),
        };

        // Derive the name from the URL basename if not set explicitly.
        let name = args
            .name
            .unwrap_or_else(|| url_basename(&args.url).to_owned());

        let (path_value, _) = fetch_lazy(
            state,
            name,
            Fetch::URL {
                url: args.url,
                exp_hash: args.sha256.map(nixhash::NixHash::Sha256),
            },
        )?;

        Ok(path_value)
    }

    #[builtin("fetchTarball")]
    async fn builtin_fetch_tarball(
        state: Rc<SnixStoreIO>,
        co: GenCo,
        args: Value,
    ) -> Result<Value, ErrorKind> {
        let args = match extract_fetch_args(&co, args).await? {
            Ok(args) => args,
            Err(cek) => return Ok(Value::from(cek)),
        };

        // Name defaults to "source" if not set explicitly.
        const DEFAULT_NAME_FETCH_TARBALL: &str = "source";
        let name = args
            .name
            .unwrap_or_else(|| DEFAULT_NAME_FETCH_TARBALL.to_owned());

        let (path_value, _) = fetch_lazy(
            state,
            name,
            Fetch::Tarball {
                url: args.url,
                exp_nar_sha256: args.sha256,
            },
        )?;

        Ok(path_value)
    }

    #[builtin("fetchGit")]
    async fn builtin_fetch_git(
        state: Rc<SnixStoreIO>,
        co: GenCo,
        args: Value,
    ) -> Result<Value, ErrorKind> {
        let fetch_git_args = extract_fetch_git_args(&co, args).await?;

        // Create the fetch object with a reference to the metadata
        let fetch = Fetch::Git {
            args: fetch_git_args.clone(),
            hash: None,
        };

        let Some(rev) = fetch_git_args.rev else {
            return Err(ErrorKind::NotImplemented(format!(
                "fetchGit: rev is currently required: {}",
                fetch_git_args.url
            )));
        };

        // Use the same approach as fetchTree - do the fetch up front
        let (store_path, _root_node, nar_hash, metadata) = state
            .tokio_handle
            .block_on(async {
                state
                    .fetcher
                    .ingest_and_persist(&fetch_git_args.name, fetch)
                    .await
            })
            .map_err(|e| ErrorKind::SnixError(Rc::new(e)))?;

        let out_path = store_path.to_absolute_path().to_string();

        // Extract metadata
        let rev_count = metadata.as_ref().map_or(0, |m| m.fetcher.rev_count);

        // Convert short_rev to BString if available, or use first 7 chars of rev
        let short_rev = metadata.as_ref().map_or_else(
            || BString::from(&rev.as_bytes()[0..7]),
            |m| BString::from(&m.fetcher.short_rev.as_bytes()[0..7]),
        );

        // We'll use the full rev from the metadata if available
        let actual_rev = metadata
            .as_ref()
            .map_or_else(|| rev.clone(), |m| m.fetcher.rev.clone());

        let submodules = metadata
            .as_ref()
            .map_or_else(|| fetch_git_args.submodules, |m| m.fetcher.submodules);

        Ok(FetchGitResult {
            out_path,
            rev: actual_rev,
            rev_count,
            submodules,
            short_rev,
            nar_hash: Some(nar_hash.to_string()),
        }
        .into())
    }

    // FUTUREWORK: make it a feature flag once #64 is implemented
    #[builtin("parseFlakeRef")]
    async fn builtin_parse_flake_ref(
        state: Rc<SnixStoreIO>,
        co: GenCo,
        value: Value,
    ) -> Result<Value, ErrorKind> {
        let flake_ref = value.to_str()?;
        let flake_ref_str = flake_ref.to_str()?;

        let fetch_args = flake_ref_str
            .parse()
            .map_err(|err| ErrorKind::SnixError(Rc::new(err)))?;

        // Convert the FlakeRef to our Value format
        let mut attrs = BTreeMap::new();

        // Extract type and url based on the variant
        match fetch_args {
            flakeref::FlakeRef::Git { url, .. } => {
                attrs.insert("type".into(), Value::from("git"));
                attrs.insert("url".into(), Value::from(url.to_string()));
            }
            flakeref::FlakeRef::GitHub {
                owner, repo, r#ref, ..
            } => {
                attrs.insert("type".into(), Value::from("github"));
                attrs.insert("owner".into(), Value::from(owner));
                attrs.insert("repo".into(), Value::from(repo));
                if let Some(ref_name) = r#ref {
                    attrs.insert("ref".into(), Value::from(ref_name));
                }
            }
            flakeref::FlakeRef::GitLab { owner, repo, .. } => {
                attrs.insert("type".into(), Value::from("gitlab"));
                attrs.insert("owner".into(), Value::from(owner));
                attrs.insert("repo".into(), Value::from(repo));
            }
            flakeref::FlakeRef::File { url, .. } => {
                attrs.insert("type".into(), Value::from("file"));
                attrs.insert("url".into(), Value::from(url.to_string()));
            }
            flakeref::FlakeRef::Tarball { url, .. } => {
                attrs.insert("type".into(), Value::from("tarball"));
                attrs.insert("url".into(), Value::from(url.to_string()));
            }
            flakeref::FlakeRef::Path { path, .. } => {
                attrs.insert("type".into(), Value::from("path"));
                attrs.insert(
                    "path".into(),
                    Value::from(path.to_string_lossy().into_owned()),
                );
            }
            _ => {
                // For all other ref types, return a simple type/url attributes
                attrs.insert("type".into(), Value::from("indirect"));
                attrs.insert("url".into(), Value::from(flake_ref_str));
            }
        }

        Ok(Value::Attrs(Box::new(attrs.into())))
    }
}
