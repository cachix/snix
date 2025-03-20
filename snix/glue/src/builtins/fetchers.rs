//! Contains builtins that fetch paths from the Internet, or local filesystem.

use super::utils::{git_find_remote_rev, select_string};
use crate::{
    fetchers::{url_basename, Fetch, FetchGitArgs},
    snix_store_io::SnixStoreIO,
};
use bstr::BString;
use nix_compat::nixhash;
use snix_eval::builtin_macros::builtins;
use snix_eval::generators::Gen;
use snix_eval::generators::GenCo;
use snix_eval::AddContext;
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

        Value::Attrs(Box::new(NixAttrs::from_iter(attrs_vec)))
    }
}

fn to_bstring(value: &Value) -> Result<BString, ErrorKind> {
    match value {
        Value::String(s) => Ok(BString::from(s.as_bytes())),
        Value::Thunk(thunk) => to_bstring(&thunk.value()),
        value => Err(ErrorKind::TypeError {
            expected: "string",
            actual: value.type_of(),
        }),
    }
}

fn to_string(value: &Value) -> Result<String, ErrorKind> {
    match value {
        Value::String(s) => Ok(s.as_bstr().to_string()),
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
        Value::String(url) => extract_fetch_git_args_from_string(BString::from(url.as_bytes())),
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

        let flake_ref: flakeref::FlakeRef = flake_ref_str
            .parse()
            .map_err(|err| ErrorKind::SnixError(Rc::new(err)))?;

        // Convert the FlakeRef to our Value format
        // Use a Vec instead of BTreeMap to preserve insertion order
        let mut attrs_vec = Vec::new();

        // Move the fetch_ref out of flake_ref to avoid cloning
        let fetch_ref = flake_ref.fetch_ref;
        let dir = flake_ref.dir;

        // Extract type and url based on the variant
        match fetch_ref {
            flakeref::FetchRef::Git {
                url,
                r#ref,
                rev,
                shallow,
                submodules,
                all_refs,
                ..
            } => {
                // Type always comes first
                attrs_vec.push(("type".to_string(), Value::from("git")));

                attrs_vec.push(("url".to_string(), Value::from(url.to_string())));

                // Add Git specific attributes in a specific order to match test expectations
                if let Some(ref_val) = r#ref {
                    attrs_vec.push(("ref".to_string(), Value::from(ref_val)));
                }
                if let Some(rev_val) = rev {
                    attrs_vec.push(("rev".to_string(), Value::from(rev_val)));
                }
                if shallow {
                    attrs_vec.push(("shallow".to_string(), Value::from(shallow)));
                }
                if submodules {
                    attrs_vec.push(("submodules".to_string(), Value::from(submodules)));
                }
                if all_refs {
                    attrs_vec.push(("allRefs".to_string(), Value::from(all_refs)));
                }
            }
            flakeref::FetchRef::GitHub {
                owner,
                repo,
                r#ref,
                host,
                rev,
                ..
            } => {
                attrs_vec.push(("type".to_string(), Value::from("github")));
                attrs_vec.push(("owner".to_string(), Value::from(owner)));
                attrs_vec.push(("repo".to_string(), Value::from(repo)));
                if let Some(ref_name) = r#ref {
                    attrs_vec.push(("ref".to_string(), Value::from(ref_name)));
                }
                if let Some(rev_val) = rev {
                    attrs_vec.push(("rev".to_string(), Value::from(rev_val)));
                }
                if let Some(host_name) = host {
                    attrs_vec.push(("host".to_string(), Value::from(host_name)));
                }
            }
            flakeref::FetchRef::GitLab {
                owner,
                repo,
                host,
                r#ref,
                rev,
                ..
            } => {
                attrs_vec.push(("type".to_string(), Value::from("gitlab")));
                attrs_vec.push(("owner".to_string(), Value::from(owner)));
                attrs_vec.push(("repo".to_string(), Value::from(repo)));
                if let Some(ref_name) = r#ref {
                    attrs_vec.push(("ref".to_string(), Value::from(ref_name)));
                }
                if let Some(rev_val) = rev {
                    attrs_vec.push(("rev".to_string(), Value::from(rev_val)));
                }
                if let Some(host_name) = host {
                    attrs_vec.push(("host".to_string(), Value::from(host_name)));
                }
            }
            flakeref::FetchRef::SourceHut {
                owner,
                repo,
                host,
                r#ref,
                rev,
                ..
            } => {
                attrs_vec.push(("type".to_string(), Value::from("sourcehut")));
                attrs_vec.push(("owner".to_string(), Value::from(owner)));
                attrs_vec.push(("repo".to_string(), Value::from(repo)));
                if let Some(ref_name) = r#ref {
                    attrs_vec.push(("ref".to_string(), Value::from(ref_name)));
                }
                if let Some(rev_val) = rev {
                    attrs_vec.push(("rev".to_string(), Value::from(rev_val)));
                }
                if let Some(host_name) = host {
                    attrs_vec.push(("host".to_string(), Value::from(host_name)));
                }
            }
            flakeref::FetchRef::File { url, nar_hash, .. } => {
                attrs_vec.push(("type".to_string(), Value::from("file")));
                attrs_vec.push(("url".to_string(), Value::from(url.to_string())));
                if let Some(hash) = nar_hash {
                    attrs_vec.push(("narHash".to_string(), Value::from(hash)));
                }
            }
            flakeref::FetchRef::Tarball { url, nar_hash, .. } => {
                attrs_vec.push(("type".to_string(), Value::from("tarball")));
                attrs_vec.push(("url".to_string(), Value::from(url.to_string())));
                if let Some(hash) = nar_hash {
                    attrs_vec.push(("narHash".to_string(), Value::from(hash)));
                }
            }
            flakeref::FetchRef::Path { path, nar_hash, .. } => {
                attrs_vec.push(("type".to_string(), Value::from("path")));
                attrs_vec.push((
                    "path".to_string(),
                    Value::from(path.to_string_lossy().into_owned()),
                ));
                if let Some(hash) = nar_hash {
                    attrs_vec.push(("narHash".to_string(), Value::from(hash)));
                }
            }
            _ => {
                // For all other ref types, return a simple type/url attributes
                attrs_vec.push(("type".to_string(), Value::from("indirect")));
                attrs_vec.push(("url".to_string(), Value::from(flake_ref_str)));
            }
        }

        // Add dir field if present
        if let Some(dir) = dir {
            attrs_vec.push((
                "dir".to_string(),
                Value::from(dir.to_string_lossy().into_owned()),
            ));
        }

        Ok(Value::Attrs(Box::new(NixAttrs::from_iter(attrs_vec))))
    }

    /// Helper function to handle common logic for different git hosting services
    fn handle_git_repo_ref(
        host_type: &str,
        owner: &str,
        repo: &str,
        rev: Option<String>,
        r#ref: Option<String>,
        host: Option<&str>,
        default_host: &str,
    ) -> Result<(String, String, Fetch), ErrorKind> {
        // Use provided host or default
        let host_name = host.unwrap_or(default_host);

        // If rev is provided, use it directly
        // If ref is provided but not rev, try to resolve it as a ref, otherwise treat it as a rev
        let rev = match rev {
            Some(r) => r,
            None => {
                // Construct repo URL based on host type
                let repo_url = match host_type {
                    "github" | "gitlab" => format!("https://{}/{}/{}.git", host_name, owner, repo),
                    "sourcehut" => format!("https://{}/{}/{}", host_name, owner, repo),
                    _ => {
                        return Err(ErrorKind::NotImplemented(format!(
                            "Unsupported git host type: {}",
                            host_type
                        )))
                    }
                };

                if let Some(ref_name) = &r#ref {
                    // First try to resolve as a ref
                    match git_find_remote_rev(&repo_url, Some(ref_name)) {
                        Ok(remote_ref) => remote_ref,
                        Err(_) => {
                            // If we can't resolve it as a ref, assume it's a rev
                            ref_name.clone()
                        }
                    }
                } else {
                    // No ref specified, get the default branch
                    match git_find_remote_rev(&repo_url, None) {
                        Ok(remote_ref) => remote_ref,
                        Err(e) => return Err(ErrorKind::CatchableError(e)), // Propagate the error as ErrorKind
                    }
                }
            }
        };

        // Create short revision
        let short_rev = rev.chars().take(7).collect::<String>();

        // Construct tarball URL based on the host type
        let url = match host_type {
            "github" => Url::parse(&format!(
                "https://{}/{}/{}/archive/{}.tar.gz",
                host_name, owner, repo, rev
            )),
            "gitlab" => Url::parse(&format!(
                "https://{}/{}/{}/-/archive/{}/{}-{}.tar.gz",
                host_name, owner, repo, rev, repo, rev
            )),
            "sourcehut" => Url::parse(&format!(
                "https://{}/{}/{}/archive/{}.tar.gz",
                host_name, owner, repo, rev
            )),
            _ => {
                return Err(ErrorKind::NotImplemented(format!(
                    "Unsupported git host type: {}",
                    host_type
                )))
            }
        }
        .map_err(|e| ErrorKind::SnixError(Rc::new(e)))?;

        // Create the Fetch::Tarball
        let fetch = Fetch::Tarball {
            url,
            exp_nar_sha256: None,
        };

        Ok((rev, short_rev, fetch))
    }

    /// Fetches a file tree from various sources.
    ///
    /// This builtin supports two forms of input:
    /// 1. String format (URI-like): e.g., "git+https://github.com/user/repo.git", "github:user/repo", etc.
    /// 2. Attribute set format:
    ///    - Git: `{ type = "git"; url = "https://..."; [rev = "..."]; [ref = "..."]; [submodules = true/false]; [shallow = true/false]; [allRefs = true/false] }`
    ///    - GitHub: `{ type = "github"; owner = "user"; repo = "repo"; [ref = "branch"]; [rev = "hash"]; [host = "custom.github.host"] }`
    ///    - GitLab: `{ type = "gitlab"; owner = "user"; repo = "repo"; [ref = "branch"]; [rev = "hash"]; [host = "custom.gitlab.host"] }`
    ///    - SourceHut: `{ type = "sourcehut"; owner = "~user"; repo = "repo"; [ref = "branch"]; [rev = "hash"] }`
    ///    - File: `{ type = "file"; url = "https://..."; [narHash = "sha256-..."] }`
    ///    - Tarball: `{ type = "tarball"; url = "https://..."; [narHash = "sha256-..."] }`
    ///    - Path: `{ type = "path"; path = "/path/to/dir"; [narHash = "sha256-..."] }`
    ///
    /// Returns an attribute set with a common set of attributes for all fetchers:
    /// - outPath: The path to the result in the Nix store
    /// - narHash: The hash of the NAR serialization of the result
    ///
    /// Additional attributes may be present depending on the type:
    /// - Git/GitHub/GitLab/SourceHut: rev, revCount, shortRev, submodules, lastModified, lastModifiedDate
    #[builtin("fetchTree")]
    async fn builtin_fetch_tree(
        state: Rc<SnixStoreIO>,
        co: GenCo,
        args: Value,
    ) -> Result<Value, ErrorKind> {
        let mut supports_rev_count = false;

        let fetch_ref = match args {
            Value::String(url) => {
                let url_str = url.as_bstr().to_str()?;
                let flake_ref = url_str.parse::<flakeref::FlakeRef>().map_err(|e| {
                    ErrorKind::SnixError(Rc::new(e)).context(format!(
                        "Failed to parse URI for builtins.fetchTree: '{}'. Expected format like 'git+https://github.com/user/repo.git', 'github:user/repo', etc.",
                        url_str
                    ))
                })?;

                // FIXME: This is an inconsistency in Nix behavior - revCount is included in very specific
                // cases but not others. See https://github.com/NixOS/nix/issues/12860 for upstream discussion
                if let flakeref::FetchRef::Git { shallow, .. } = &flake_ref.fetch_ref {
                    supports_rev_count = !shallow;
                }

                flake_ref.fetch_ref
            }

            Value::Attrs(attrs) => {
                // Extract the type attribute to determine what kind of fetch to perform
                let type_attr = select(attrs.as_ref(), "type")
                    .map_err(|_| ErrorKind::AttributeNotFound {
                        name: "'type' (must be one of: 'git', 'github', 'gitlab', 'sourcehut', 'file', 'tarball', 'path')".into()
                    })?;

                let fetch_type = to_string(type_attr)?;

                match fetch_type.as_str() {
                    "git" => {
                        // Convert attribute set to Git FetchRef
                        let url = to_string(select(attrs.as_ref(), "url")
                            .map_err(|_| ErrorKind::AttributeNotFound { name: "url".into() })?)?;

                        // Optional attributes
                        let rev = attrs.select("rev").map(to_string).transpose()?;
                        let r#ref = attrs.select("ref").map(to_string).transpose()?;
                        let shallow = attrs.select("shallow").map(|v| v.as_bool()).transpose()?.unwrap_or(false);
                        let all_refs = attrs.select("allRefs").map(|v| v.as_bool()).transpose()?.unwrap_or(false);
                        let submodules = attrs.select("submodules").map(|v| v.as_bool()).transpose()?.unwrap_or(false);

                        // Create and return the FetchRef
                        flakeref::FetchRef::Git {
                            url: url.parse()
                                .map_err(|e| ErrorKind::SnixError(Rc::new(e)))?,
                            r#ref,
                            rev,
                            shallow,
                            submodules,
                            all_refs,
                            export_ignore: false,
                            verify_commit: false,
                            keytype: None,
                            public_key: None,
                            public_keys: None,
                        }
                    },
                    "github" => {
                        // Convert attribute set to GitHub FetchRef
                        let owner = to_string(select(attrs.as_ref(), "owner")
                            .map_err(|_| ErrorKind::AttributeNotFound { name: "owner".into() })?)?;
                        let repo = to_string(select(attrs.as_ref(), "repo")
                            .map_err(|_| ErrorKind::AttributeNotFound { name: "repo".into() })?)?;

                        // Optional attributes
                        let rev = attrs.select("rev").map(to_string).transpose()?;
                        let r#ref = attrs.select("ref").map(to_string).transpose()?;
                        let host = attrs.select("host").map(to_string).transpose()?;

                        // Create and return the FetchRef
                        flakeref::FetchRef::GitHub {
                            owner,
                            repo,
                            host,
                            r#ref,
                            rev,
                            keytype: None,
                            public_key: None,
                            public_keys: None,
                        }
                    },
                    "gitlab" => {
                        // Convert attribute set to GitLab FetchRef
                        let owner = to_string(select(attrs.as_ref(), "owner")
                            .map_err(|_| ErrorKind::AttributeNotFound { name: "owner".into() })?)?;
                        let repo = to_string(select(attrs.as_ref(), "repo")
                            .map_err(|_| ErrorKind::AttributeNotFound { name: "repo".into() })?)?;

                        // Optional attributes
                        let rev = attrs.select("rev").map(to_string).transpose()?;
                        let r#ref = attrs.select("ref").map(to_string).transpose()?;
                        let host = attrs.select("host").map(to_string).transpose()?;

                        // Create and return the FetchRef
                        flakeref::FetchRef::GitLab {
                            owner,
                            repo,
                            host,
                            r#ref,
                            rev,
                            keytype: None,
                            public_key: None,
                            public_keys: None,
                        }
                    },
                    "path" => {
                        // Convert attribute set to Path FetchRef
                        let path_str = to_string(select(attrs.as_ref(), "path")
                            .map_err(|_| ErrorKind::AttributeNotFound { name: "path".into() })?)?;

                        let path = std::path::PathBuf::from(path_str);

                        // Optional attributes
                        let nar_hash = attrs.select("narHash").map(to_string).transpose()?;

                        // Create and return the FetchRef
                        flakeref::FetchRef::Path {
                            path,
                            nar_hash,
                            rev: None,
                            rev_count: None,
                            last_modified: None,
                        }
                    },
                    // Add support for tarball type
                    "tarball" => {
                        // Convert attribute set to Tarball FetchRef
                        let url_str = to_string(select(attrs.as_ref(), "url")
                            .map_err(|_| ErrorKind::AttributeNotFound { name: "url".into() })?)?;

                        let url = url_str.parse()
                            .map_err(|e| ErrorKind::SnixError(Rc::new(e)))?;

                        // Optional attributes
                        let nar_hash = attrs.select("narHash").map(to_string).transpose()?;

                        // Create and return the FetchRef
                        flakeref::FetchRef::Tarball {
                            url,
                            nar_hash,
                            rev: None,
                            rev_count: None,
                            last_modified: None,
                        }
                    },
                    // Add support for file type
                    "file" => {
                        // Convert attribute set to File FetchRef
                        let url_str = to_string(select(attrs.as_ref(), "url")
                            .map_err(|_| ErrorKind::AttributeNotFound { name: "url".into() })?)?;

                        let url = url_str.parse()
                            .map_err(|e| ErrorKind::SnixError(Rc::new(e)))?;

                        // Optional attributes
                        let nar_hash = attrs.select("narHash").map(to_string).transpose()?;

                        // Create and return the FetchRef
                        flakeref::FetchRef::File {
                            url,
                            nar_hash,
                            rev: None,
                            rev_count: None,
                            last_modified: None,
                        }
                    },
                    // Add support for sourcehut type
                    "sourcehut" => {
                        // Convert attribute set to SourceHut FetchRef
                        let owner = to_string(select(attrs.as_ref(), "owner")
                            .map_err(|_| ErrorKind::AttributeNotFound { name: "owner".into() })?)?;
                        let repo = to_string(select(attrs.as_ref(), "repo")
                            .map_err(|_| ErrorKind::AttributeNotFound { name: "repo".into() })?)?;

                        // Optional attributes
                        let rev = attrs.select("rev").map(to_string).transpose()?;
                        let r#ref = attrs.select("ref").map(to_string).transpose()?;
                        let host = attrs.select("host").map(to_string).transpose()?;

                        // Create and return the FetchRef
                        flakeref::FetchRef::SourceHut {
                            owner,
                            repo,
                            r#ref,
                            rev,
                            host,
                            keytype: None,
                            public_key: None,
                            public_keys: None,
                        }
                    },
                    _ => return Err(ErrorKind::NotImplemented(format!(
                        "fetchTree attribute set with type '{}' is not supported. Valid types are: 'git', 'github', 'gitlab', 'sourcehut', 'file', 'tarball', 'path'", fetch_type
                    ))),
                }
            }

            _ => {
                return Err(ErrorKind::TypeError {
                    expected: "a string or attribute set",
                    actual: args.type_of(),
                })
            }
        };

        // Extract submodules once before the match
        let submodules = if let flakeref::FetchRef::Git { submodules, .. } = &fetch_ref {
            Some(*submodules)
        } else {
            None
        };

        let mut external_rev = None;
        let mut external_short_rev = None;

        let fetch = match fetch_ref {
            flakeref::FetchRef::File { url, nar_hash, .. } => Fetch::URL {
                url,
                exp_hash: nar_hash.as_ref().and_then(|h| {
                    nixhash::from_str(h, None)
                        .map_err(|e| ErrorKind::InvalidHash(e.to_string()))
                        .ok()
                }),
            },
            flakeref::FetchRef::Tarball { url, nar_hash, .. } => Fetch::Tarball {
                url: url.clone(),
                exp_nar_sha256: nar_hash.as_ref().and_then(|hash_str| {
                    nixhash::from_str(hash_str, Some("sha256"))
                        .ok()
                        .and_then(|nh| nh.digest_as_bytes().try_into().ok())
                }),
            },
            flakeref::FetchRef::Git {
                url,
                r#ref,
                rev,
                shallow,
                submodules,
                all_refs,
                ..
            } => Fetch::Git {
                args: FetchGitArgs {
                    url: url.to_string().into_bytes().into(),
                    name: "source".to_string(),
                    rev: rev.map(|r| r.into_bytes().into()),
                    r#ref: r#ref
                        .unwrap_or_else(|| "HEAD".to_string())
                        .into_bytes()
                        .into(),
                    shallow,
                    all_refs,
                    submodules,
                },
                hash: None,
            },
            flakeref::FetchRef::GitLab {
                owner,
                repo,
                rev,
                r#ref,
                host,
                ..
            } => {
                let (resolved_rev, short_rev, fetch) = handle_git_repo_ref(
                    "gitlab",
                    &owner,
                    &repo,
                    rev,
                    r#ref.clone(),
                    host.as_deref(),
                    "gitlab.com",
                )?;
                external_rev = Some(resolved_rev);
                external_short_rev = Some(short_rev);
                fetch
            }
            flakeref::FetchRef::GitHub {
                owner,
                repo,
                rev,
                r#ref,
                host,
                ..
            } => {
                let (resolved_rev, short_rev, fetch) = handle_git_repo_ref(
                    "github",
                    &owner,
                    &repo,
                    rev,
                    r#ref.clone(),
                    host.as_deref(),
                    "github.com",
                )?;
                external_rev = Some(resolved_rev);
                external_short_rev = Some(short_rev);
                fetch
            }
            flakeref::FetchRef::SourceHut {
                owner,
                repo,
                r#ref,
                rev,
                host,
                ..
            } => {
                let (resolved_rev, short_rev, fetch) = handle_git_repo_ref(
                    "sourcehut",
                    &owner,
                    &repo,
                    rev,
                    r#ref.clone(),
                    host.as_deref(),
                    "git.sr.ht",
                )?;
                external_rev = Some(resolved_rev);
                external_short_rev = Some(short_rev);
                fetch
            }
            flakeref::FetchRef::Path { path, nar_hash, .. } => {
                // Convert the optional nar_hash to expected_sha256 format if present
                let expected_sha256 = nar_hash.as_ref().and_then(|hash_str| {
                    nixhash::from_str(hash_str, Some("sha256"))
                        .ok()
                        .and_then(|nh| nh.digest_as_bytes().try_into().ok())
                });

                // Use the import_helper function to import the path
                let name_value = Value::from("source");
                let result = crate::builtins::import_helper(
                    state.clone(),
                    co,
                    path.clone(),
                    Some(&name_value),
                    None, // no filter
                    true, // recursive ingestion
                    expected_sha256,
                )
                .await?;

                // Extract the path value and wrap it in the appropriate output type
                match result {
                    Value::String(path_box) => {
                        let output = FetchTreeOutput {
                            out_path: path_box.to_string(),
                            nar_hash: nar_hash.as_ref().map(|h| h.to_string()).unwrap_or_default(),
                            last_modified: None,
                            last_modified_date: None,
                            rev_count: None,
                            rev: None,
                            short_rev: None,
                            submodules: None,
                        };
                        return Ok(output.into());
                    }
                    _ => {
                        return Err(ErrorKind::TypeError {
                            expected: "string",
                            actual: result.type_of(),
                        })
                    }
                }
            }
            flakeref::FetchRef::Indirect { .. } => {
                return Err(ErrorKind::NotImplemented(format!(
                    "flake/indirect type is not supported, because it's too complex: {}",
                    fetch_ref
                )));
            }
            _ => {
                return Err(ErrorKind::NotImplemented(format!(
                    "fetchTree type not supported: {}",
                    fetch_ref
                )));
            }
        };

        // Start any fetch in the background immediately
        let fetcher = state.fetcher.clone();
        let handle = state.tokio_handle.clone();
        let fetch_background = fetch.clone();

        // Start the fetch in the background without waiting for completion
        handle.spawn(async move {
            // We don't wait for the result - when the thunk is evaluated, it will
            // either find the completed fetch or do it again if needed
            let _ = fetcher.ingest_and_persist("source", fetch_background).await;
        });

        // Create a thunk that will check for results or fetch when evaluated
        let state_clone = state.clone();
        let fetch_clone = fetch.clone();

        // This thunk returns the result when forced
        let thunk_fn = Box::new(move || {
            // Do the fetch (or use the cached result if the background task completed)
            let (sp, _root_node, nar_hash, metadata) = state_clone
                .tokio_handle
                .block_on(async {
                    state_clone
                        .fetcher
                        .ingest_and_persist("source", fetch_clone.clone())
                        .await
                })
                .map_err(|e| ErrorKind::SnixError(Rc::new(e)))?;

            // Extract metadata
            let (mod_time, mod_date, rev_count, rev_val, short_rev_val) = metadata.as_ref().map_or(
                (
                    None,
                    None,
                    None,
                    external_rev.clone(),
                    external_short_rev.clone(),
                ),
                |m| {
                    (
                        Some(m.last_modified as i64),
                        Some(m.last_modified_date.clone()),
                        Some(m.fetcher.rev_count),
                        Some(m.fetcher.rev.to_string()),
                        Some(BString::from(&m.fetcher.short_rev.as_bytes()[0..7]).to_string()),
                    )
                },
            );

            // Return the actual result
            Ok(FetchTreeOutput {
                out_path: sp.to_absolute_path().to_string(),
                nar_hash: nar_hash.to_string(),
                last_modified: mod_time,
                last_modified_date: mod_date,
                rev_count: if supports_rev_count { rev_count } else { None },
                rev: rev_val,
                short_rev: short_rev_val,
                submodules,
            }
            .into())
        });

        Ok(Value::suspended_native_thunk(thunk_fn))
    }
}

#[derive(Debug, Default, Clone)]
pub struct FetchTreeOutput {
    pub out_path: String,
    pub nar_hash: String,
    pub last_modified: Option<i64>,
    pub last_modified_date: Option<String>,
    pub rev_count: Option<i64>,
    pub rev: Option<String>,
    pub short_rev: Option<String>,
    pub submodules: Option<bool>,
}

impl From<FetchTreeOutput> for Value {
    fn from(output: FetchTreeOutput) -> Self {
        // Define the attribute order and conditionally add attributes
        let mut attrs_vec = Vec::with_capacity(8); // Pre-allocate for potential max size

        // Core attributes that are always present (guaranteed order)
        attrs_vec.push(("outPath".to_string(), Value::from(output.out_path)));
        attrs_vec.push(("narHash".to_string(), Value::from(output.nar_hash)));

        // Git-specific attributes in guaranteed order with proper typing
        if let Some(rev) = output.rev {
            attrs_vec.push(("rev".to_string(), Value::from(rev)));
        }
        if let Some(rev_count) = output.rev_count {
            attrs_vec.push(("revCount".to_string(), Value::from(rev_count)));
        }
        if let Some(short_rev) = output.short_rev {
            attrs_vec.push(("shortRev".to_string(), Value::from(short_rev)));
        }
        if let Some(submodules) = output.submodules {
            attrs_vec.push(("submodules".to_string(), Value::from(submodules)));
        }

        // Timestamp attributes
        if let Some(lm) = output.last_modified {
            attrs_vec.push(("lastModified".to_string(), Value::from(lm)));
        }
        if let Some(lmd) = output.last_modified_date {
            attrs_vec.push(("lastModifiedDate".to_string(), Value::from(lmd)));
        }

        Value::Attrs(Box::new(NixAttrs::from_iter(attrs_vec)))
    }
}
