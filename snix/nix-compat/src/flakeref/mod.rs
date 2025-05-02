// Implements a parser and formatter for Nix flake references.
// It defines the `FlakeRef` struct which represents a flake with a directory path and fetch reference,
// and the `FetchRef` enum which represents different types of flake sources
// (such as Git repositories, GitHub repos, local paths, etc.), along with functionality
// to parse URLs into `FetchRef` instances and convert them back to URIs.
use std::{collections::HashMap, path::PathBuf};
use url::Url;

/// A flake reference that represents a directory path to a flake and how to fetch it
#[derive(Debug, Clone)]
pub struct FlakeRef {
    /// The optional path to the flake directory
    pub dir: Option<PathBuf>,
    /// The fetch reference for how to obtain the flake
    pub fetch_ref: FetchRef,
}

/// The type of fetch reference for a flake
#[derive(Debug, Clone)]
#[non_exhaustive]
pub enum FetchRef {
    File {
        last_modified: Option<u64>,
        nar_hash: Option<String>,
        rev: Option<String>,
        rev_count: Option<u64>,
        url: Url,
    },
    Git {
        all_refs: bool,
        export_ignore: bool,
        keytype: Option<String>,
        public_key: Option<String>,
        public_keys: Option<Vec<String>>,
        r#ref: Option<String>,
        rev: Option<String>,
        shallow: bool,
        submodules: bool,
        url: Url,
        verify_commit: bool,
    },
    GitHub {
        owner: String,
        repo: String,
        host: Option<String>,
        keytype: Option<String>,
        public_key: Option<String>,
        public_keys: Option<Vec<String>>,
        r#ref: Option<String>,
        rev: Option<String>,
    },
    GitLab {
        owner: String,
        repo: String,
        host: Option<String>,
        keytype: Option<String>,
        public_key: Option<String>,
        public_keys: Option<Vec<String>>,
        r#ref: Option<String>,
        rev: Option<String>,
    },
    Indirect {
        id: String,
        r#ref: Option<String>,
        rev: Option<String>,
    },
    Mercurial {
        r#ref: Option<String>,
        rev: Option<String>,
    },
    Path {
        last_modified: Option<u64>,
        nar_hash: Option<String>,
        path: PathBuf,
        rev: Option<String>,
        rev_count: Option<u64>,
    },
    SourceHut {
        owner: String,
        repo: String,
        host: Option<String>,
        keytype: Option<String>,
        public_key: Option<String>,
        public_keys: Option<Vec<String>>,
        r#ref: Option<String>,
        rev: Option<String>,
    },
    Tarball {
        last_modified: Option<u64>,
        nar_hash: Option<String>,
        rev: Option<String>,
        rev_count: Option<u64>,
        url: Url,
    },
}

#[derive(Debug, thiserror::Error)]
pub enum FlakeRefError {
    #[error("failed to parse URL: {0}")]
    UrlParseError(#[from] url::ParseError),
    #[error("unsupported input type: {0}")]
    UnsupportedType(String),
}

// Implement FromStr for FlakeRef to allow parsing from a string
impl std::str::FromStr for FlakeRef {
    type Err = FlakeRefError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        // Parse the fetch_ref
        let fetch_ref = s.parse::<FetchRef>()?;

        // Create a FlakeRef with the parsed fetch_ref and no dir
        Ok(FlakeRef {
            dir: None,
            fetch_ref,
        })
    }
}

// Implement FromStr for FetchRef to allow parsing from a string
impl std::str::FromStr for FetchRef {
    type Err = FlakeRefError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        // Parse initial URL
        let mut url = Url::parse(s)?;
        let mut new_protocol = None;

        // Determine fetch type from scheme
        let fetch_type = if let Some((type_part, protocol)) = url.scheme().split_once('+') {
            new_protocol = Some(protocol.to_string());
            match type_part {
                "path" => FetchType::Path,
                "file" => FetchType::File,
                "tarball" => FetchType::Tarball,
                "git" => FetchType::Git,
                "github" => FetchType::GitHub,
                "gitlab" => FetchType::GitLab,
                "sourcehut" => FetchType::SourceHut,
                "indirect" => FetchType::Indirect,
                _ => return Err(FlakeRefError::UnsupportedType(type_part.to_string())),
            }
        } else {
            match url.scheme() {
                // Direct schemes
                "path" => FetchType::Path,
                "github" => FetchType::GitHub,
                "gitlab" => FetchType::GitLab,
                "sourcehut" => FetchType::SourceHut,
                "git" => FetchType::Git,
                // For file:// URLs, Nix defaults to tarball type
                "file" => FetchType::Tarball,
                // Check for tarball file extensions
                _ if is_tarball_extension(url.path()) => FetchType::Tarball,
                // Default to File for other schemes
                _ => FetchType::File,
            }
        };

        // We need to convert the URL to string, strip the prefix there, and then
        // parse it back as url, as Url::set_scheme() rejects some of the transitions we want to do.
        if let Some(protocol) = new_protocol {
            let mut url_str = url.to_string();
            url_str.replace_range(..url.scheme().len(), &protocol);
            url = Url::parse(&url_str)?;
        }

        // Process URL based on fetch type, extracting parameters and modifying the URL
        Ok(match fetch_type {
            FetchType::File => {
                let params = extract_common_file_params(&mut url);
                FetchRef::File {
                    url,
                    nar_hash: params.nar_hash,
                    rev: params.rev,
                    rev_count: params.rev_count,
                    last_modified: params.last_modified,
                }
            }
            FetchType::Tarball => {
                let params = extract_common_file_params(&mut url);
                FetchRef::Tarball {
                    url,
                    nar_hash: params.nar_hash,
                    rev: params.rev,
                    rev_count: params.rev_count,
                    last_modified: params.last_modified,
                }
            }
            FetchType::Indirect => {
                // For indirect type, extract specific parameters
                let keys = ["ref", "rev"];
                let params = extract_params(&mut url, &keys);

                FetchRef::Indirect {
                    id: url.path().to_string(),
                    r#ref: params.get("ref").cloned(),
                    rev: params.get("rev").cloned(),
                }
            }
            FetchType::Git => {
                let params = extract_git_params(&mut url);
                FetchRef::Git {
                    url,
                    r#ref: params.r#ref,
                    rev: params.rev,
                    keytype: params.keytype,
                    public_key: params.public_key,
                    public_keys: params.public_keys,
                    shallow: params.shallow,
                    submodules: params.submodules,
                    export_ignore: params.export_ignore,
                    all_refs: params.all_refs,
                    verify_commit: params.verify_commit,
                }
            }
            FetchType::Path => {
                let params = extract_common_file_params(&mut url);
                FetchRef::Path {
                    path: PathBuf::from(url.path()),
                    rev: params.rev,
                    nar_hash: params.nar_hash,
                    rev_count: params.rev_count,
                    last_modified: params.last_modified,
                }
            }
            FetchType::GitHub => create_repo_host_args(&mut url, |params| FetchRef::GitHub {
                owner: params.owner,
                repo: params.repo,
                r#ref: params.r#ref,
                rev: params.rev,
                host: params.host,
                keytype: params.keytype,
                public_key: params.public_key,
                public_keys: params.public_keys,
            })?,
            FetchType::GitLab => create_repo_host_args(&mut url, |params| FetchRef::GitLab {
                owner: params.owner,
                repo: params.repo,
                r#ref: params.r#ref,
                rev: params.rev,
                host: params.host,
                keytype: params.keytype,
                public_key: params.public_key,
                public_keys: params.public_keys,
            })?,
            FetchType::SourceHut => {
                create_repo_host_args(&mut url, |params| FetchRef::SourceHut {
                    owner: params.owner,
                    repo: params.repo,
                    r#ref: params.r#ref,
                    rev: params.rev,
                    host: params.host,
                    keytype: params.keytype,
                    public_key: params.public_key,
                    public_keys: params.public_keys,
                })?
            }
        })
    }
}

impl std::fmt::Display for FlakeRef {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Display the fetch_ref as a URI
        write!(f, "{}", self.fetch_ref)
    }
}

impl std::fmt::Display for FetchRef {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let url = self.to_uri();
        write!(f, "{}", url)
    }
}

// Common parameter structs
#[derive(Debug, Default, Clone)]
struct FileParams {
    nar_hash: Option<String>,
    rev: Option<String>,
    rev_count: Option<u64>,
    last_modified: Option<u64>,
}

#[derive(Debug, Default)]
struct GitParams {
    r#ref: Option<String>,
    rev: Option<String>,
    keytype: Option<String>,
    public_key: Option<String>,
    public_keys: Option<Vec<String>>,
    submodules: bool,
    shallow: bool,
    export_ignore: bool,
    all_refs: bool,
    verify_commit: bool,
}

#[derive(Debug, Default)]
struct RepoHostParams {
    owner: String,
    repo: String,
    host: Option<String>,
    r#ref: Option<String>,
    rev: Option<String>,
    keytype: Option<String>,
    public_key: Option<String>,
    public_keys: Option<Vec<String>>,
}

// Helper enum for fetch types
enum FetchType {
    File,
    Git,
    GitHub,
    GitLab,
    Indirect,
    Path,
    SourceHut,
    Tarball,
}

// Helper functions for query parameters
/// Extract parameters from a URL and simultaneously remove them from the URL
/// Returns a HashMap with the extracted parameters and modifies the URL in-place
fn extract_params(url: &mut Url, keys: &[&str]) -> HashMap<String, String> {
    if url.query().is_none() {
        return HashMap::new();
    }

    // Parse all query pairs
    let all_pairs: Vec<(String, String)> = url
        .query_pairs()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();

    // Separate them into two groups: ones to extract and ones to keep
    let mut extracted = HashMap::new();
    let mut remaining = Vec::new();

    for (key, value) in all_pairs {
        if keys.contains(&key.as_str()) {
            extracted.insert(key, value);
        } else {
            remaining.push((key, value));
        }
    }

    // Update the URL with only the remaining parameters
    if remaining.is_empty() {
        url.set_query(None);
    } else {
        let new_query = url::form_urlencoded::Serializer::new(String::new())
            .extend_pairs(remaining.iter().map(|(k, v)| (k.as_str(), v.as_str())))
            .finish();
        url.set_query(Some(&new_query));
    }

    extracted
}

fn get_param(params: &HashMap<String, String>, key: &str) -> Option<u64> {
    params.get(key).and_then(|s| s.parse().ok())
}

fn get_bool_param(params: &HashMap<String, String>, key: &str) -> bool {
    params
        .get(key)
        .map(|v| v == "1" || v.to_lowercase() == "true")
        .unwrap_or(false)
}

// Parameter extractors
fn extract_common_file_params(url: &mut Url) -> FileParams {
    let keys = ["narHash", "rev", "revCount", "lastModified"];
    let params = extract_params(url, &keys);

    FileParams {
        nar_hash: params.get("narHash").cloned(),
        rev: params.get("rev").cloned(),
        rev_count: get_param(&params, "revCount"),
        last_modified: get_param(&params, "lastModified"),
    }
}

fn extract_git_params(url: &mut Url) -> GitParams {
    let keys = [
        "ref",
        "rev",
        "keytype",
        "publicKey",
        "publicKeys",
        "submodules",
        "shallow",
        "exportIgnore",
        "allRefs",
        "verifyCommit",
    ];
    let params = extract_params(url, &keys);

    GitParams {
        r#ref: params.get("ref").cloned(),
        rev: params.get("rev").cloned(),
        keytype: params.get("keytype").cloned(),
        public_key: params.get("publicKey").cloned(),
        public_keys: params
            .get("publicKeys")
            .map(|s| s.split(',').map(String::from).collect()),
        submodules: get_bool_param(&params, "submodules"),
        shallow: get_bool_param(&params, "shallow"),
        export_ignore: get_bool_param(&params, "exportIgnore"),
        all_refs: get_bool_param(&params, "allRefs"),
        verify_commit: get_bool_param(&params, "verifyCommit"),
    }
}

fn extract_repo_params(url: &mut Url) -> Result<RepoHostParams, FlakeRefError> {
    let (owner, repo, path_ref_or_rev) = parse_path_segments(url)?;

    // Check for branch/tag conflicts - need to do this before we modify the URL
    let has_ref_param = url.query_pairs().any(|(k, _)| k == "ref");
    if path_ref_or_rev.is_some() && has_ref_param {
        return Err(FlakeRefError::UnsupportedType(
            "URL contains multiple branch/tag names".to_string(),
        ));
    }

    // Extract the parameters
    let keys = ["ref", "rev", "host", "keytype", "publicKey", "publicKeys"];
    let params = extract_params(url, &keys);

    // Determine if path_ref_or_rev is a rev or ref
    let (r#ref, rev) = if let Some(path_val) = path_ref_or_rev {
        let appears_to_be_rev =
            path_val.chars().all(|c| c.is_ascii_hexdigit()) && path_val.len() == 40;

        if appears_to_be_rev {
            (params.get("ref").cloned(), Some(path_val))
        } else {
            (Some(path_val), params.get("rev").cloned())
        }
    } else {
        (params.get("ref").cloned(), params.get("rev").cloned())
    };

    Ok(RepoHostParams {
        owner,
        repo,
        r#ref,
        rev,
        host: params.get("host").cloned(),
        keytype: params.get("keytype").cloned(),
        public_key: params.get("publicKey").cloned(),
        public_keys: params
            .get("publicKeys")
            .map(|s| s.split(',').map(String::from).collect()),
    })
}

// URL parsing helpers
fn parse_path_segments(url: &Url) -> Result<(String, String, Option<String>), FlakeRefError> {
    let path_segments: Vec<&str> = url.path().trim_start_matches('/').splitn(3, '/').collect();

    if path_segments.len() < 2 {
        return Err(FlakeRefError::UnsupportedType(
            "URLs must contain owner and repo".to_string(),
        ));
    }

    Ok((
        path_segments[0].to_string(),
        path_segments[1].to_string(),
        path_segments.get(2).map(|&s| s.to_string()),
    ))
}

// Helper function for tarball detection
fn is_tarball_extension(path: &str) -> bool {
    const TARBALL_EXTENSIONS: [&str; 7] = [
        ".zip", ".tar", ".tgz", ".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst",
    ];

    TARBALL_EXTENSIONS.iter().any(|ext| path.ends_with(ext))
}

fn create_repo_host_args<F>(url: &mut Url, creator: F) -> Result<FetchRef, FlakeRefError>
where
    F: FnOnce(RepoHostParams) -> FetchRef,
{
    let params = extract_repo_params(url)?;
    Ok(creator(params))
}

// Helper functions for appending query parameters
fn append_param<T: ToString>(url: &mut Url, key: &str, value: &Option<T>) {
    if let Some(val) = value {
        url.query_pairs_mut().append_pair(key, &val.to_string());
    }
}

fn append_bool_param(url: &mut Url, key: &str, value: bool) {
    if value {
        url.query_pairs_mut().append_pair(key, "1");
    }
}

fn append_params(url: &mut Url, params: &[(&str, Option<String>)]) {
    for &(key, ref value) in params {
        append_param(url, key, value);
    }
}

fn append_public_keys_param(url: &mut Url, public_keys: &Option<Vec<String>>) {
    if let Some(keys) = public_keys {
        url.query_pairs_mut()
            .append_pair("publicKeys", &keys.join(","));
    }
}

fn append_common_file_params(url: &mut Url, params: &FileParams) {
    append_params(
        url,
        &[
            ("narHash", params.nar_hash.clone()),
            ("rev", params.rev.clone()),
        ],
    );
    append_param(url, "revCount", &params.rev_count);
    append_param(url, "lastModified", &params.last_modified);
}

fn append_git_params(url: &mut Url, params: &GitParams) {
    append_params(
        url,
        &[
            ("ref", params.r#ref.clone()),
            ("rev", params.rev.clone()),
            ("keytype", params.keytype.clone()),
            ("publicKey", params.public_key.clone()),
        ],
    );
    append_public_keys_param(url, &params.public_keys);
    append_bool_param(url, "shallow", params.shallow);
    append_bool_param(url, "submodules", params.submodules);
    append_bool_param(url, "exportIgnore", params.export_ignore);
    append_bool_param(url, "allRefs", params.all_refs);
    append_bool_param(url, "verifyCommit", params.verify_commit);
}

fn append_repo_host_params(url: &mut Url, params: &RepoHostParams) {
    append_params(
        url,
        &[
            ("ref", params.r#ref.clone()),
            ("rev", params.rev.clone()),
            ("keytype", params.keytype.clone()),
            ("publicKey", params.public_key.clone()),
        ],
    );
    append_public_keys_param(url, &params.public_keys);
}

// Implementation of to_uri method for FlakeRef
impl FlakeRef {
    pub fn to_uri(&self) -> Url {
        self.fetch_ref.to_uri()
    }
}

// Implementation of to_uri method for FetchRef
impl FetchRef {
    pub fn to_uri(&self) -> Url {
        match self {
            FetchRef::File {
                url,
                nar_hash,
                rev,
                rev_count,
                last_modified,
            } => {
                let mut url = url.clone();
                let params = FileParams {
                    nar_hash: nar_hash.clone(),
                    rev: rev.clone(),
                    rev_count: *rev_count,
                    last_modified: *last_modified,
                };
                append_common_file_params(&mut url, &params);
                url
            }
            FetchRef::Git {
                url,
                r#ref,
                rev,
                keytype,
                public_key,
                public_keys,
                shallow,
                submodules,
                export_ignore,
                all_refs,
                verify_commit,
            } => {
                let mut url = url.clone();
                let params = GitParams {
                    r#ref: r#ref.clone(),
                    rev: rev.clone(),
                    keytype: keytype.clone(),
                    public_key: public_key.clone(),
                    public_keys: public_keys.clone(),
                    shallow: *shallow,
                    submodules: *submodules,
                    export_ignore: *export_ignore,
                    all_refs: *all_refs,
                    verify_commit: *verify_commit,
                };
                append_git_params(&mut url, &params);
                Url::parse(&format!("git+{}", url.as_str())).unwrap()
            }
            FetchRef::GitHub {
                owner,
                repo,
                host,
                keytype,
                public_key,
                public_keys,
                r#ref,
                rev,
            }
            | FetchRef::GitLab {
                owner,
                repo,
                host,
                keytype,
                public_key,
                public_keys,
                r#ref,
                rev,
            }
            | FetchRef::SourceHut {
                owner,
                repo,
                host,
                keytype,
                public_key,
                public_keys,
                r#ref,
                rev,
            } => {
                let scheme = match self {
                    FetchRef::GitHub { .. } => "github",
                    FetchRef::GitLab { .. } => "gitlab",
                    FetchRef::SourceHut { .. } => "sourcehut",
                    _ => unreachable!(),
                };

                let mut url = Url::parse(&format!("{}://{}/{}", scheme, owner, repo)).unwrap();
                if let Some(h) = host {
                    url.set_host(Some(h)).unwrap();
                }

                let params = RepoHostParams {
                    owner: owner.clone(),
                    repo: repo.clone(),
                    host: host.clone(),
                    r#ref: r#ref.clone(),
                    rev: rev.clone(),
                    keytype: keytype.clone(),
                    public_key: public_key.clone(),
                    public_keys: public_keys.clone(),
                };
                append_repo_host_params(&mut url, &params);
                url
            }
            FetchRef::Indirect { id, r#ref, rev } => {
                let mut url = Url::parse(&format!("indirect://{}", id)).unwrap();
                append_params(&mut url, &[("ref", r#ref.clone()), ("rev", rev.clone())]);
                url
            }
            FetchRef::Path {
                path,
                rev,
                nar_hash,
                rev_count,
                last_modified,
            } => {
                let mut url = Url::parse(&format!("path://{}", path.display())).unwrap();
                let params = FileParams {
                    nar_hash: nar_hash.clone(),
                    rev: rev.clone(),
                    rev_count: *rev_count,
                    last_modified: *last_modified,
                };
                append_common_file_params(&mut url, &params);
                url
            }
            FetchRef::Tarball {
                url,
                nar_hash,
                rev,
                rev_count,
                last_modified,
            } => {
                let mut url = url.clone();
                let params = FileParams {
                    nar_hash: nar_hash.clone(),
                    rev: rev.clone(),
                    rev_count: *rev_count,
                    last_modified: *last_modified,
                };
                append_common_file_params(&mut url, &params);
                url
            }
            FetchRef::Mercurial { r#ref, rev } => {
                let mut url = Url::parse("hg://").unwrap();
                append_params(&mut url, &[("ref", r#ref.clone()), ("rev", rev.clone())]);
                url
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn test_git_urls() {
        let input = "git+https://github.com/lichess-org/fishnet?submodules=1";
        let flake_ref = input.parse::<FlakeRef>().unwrap();
        match &flake_ref.fetch_ref {
            FetchRef::Git {
                url,
                submodules,
                shallow,
                export_ignore,
                all_refs,
                verify_commit,
                ..
            } => {
                // Verify that the parameter was extracted
                assert_eq!(*submodules, true);
                // Verify that the parameter was removed from the URL
                assert_eq!(url.query(), None);
                assert_eq!(*shallow, false);
                assert_eq!(*export_ignore, false);
                assert_eq!(*all_refs, false);
                assert_eq!(*verify_commit, false);
            }
            _ => panic!("Expected Git input type"),
        }

        let input = "git+file:///home/user/project?ref=fa1e2d23a22";
        let flake_ref = input.parse::<FlakeRef>().unwrap();
        match &flake_ref.fetch_ref {
            FetchRef::Git {
                url, r#ref, rev, ..
            } => {
                assert_eq!(r#ref, &Some("fa1e2d23a22".to_string()));
                assert_eq!(rev, &None);
                // Verify that the parameter was removed from the URL
                assert_eq!(url.query(), None);
            }
            _ => panic!("Expected Git input type"),
        }

        let input = "git+git://github.com/someuser/my-repo?rev=v1.2.3";
        let flake_ref = input.parse::<FlakeRef>().unwrap();
        match &flake_ref.fetch_ref {
            FetchRef::Git { url, rev, .. } => {
                assert_eq!(rev, &Some("v1.2.3".to_string()));
                // Verify that the parameter was removed from the URL
                assert_eq!(url.query(), None);
            }
            _ => panic!("Expected Git input type"),
        }
    }

    #[test]
    fn test_url_with_mixed_params() {
        // Test that unrecognized parameters are preserved
        let input = "git+https://example.com/repo?rev=123&custom=value&ref=main";
        let flake_ref = input.parse::<FlakeRef>().unwrap();
        match &flake_ref.fetch_ref {
            FetchRef::Git {
                url, rev, r#ref, ..
            } => {
                // Verify the parameters were extracted correctly
                assert_eq!(rev, &Some("123".to_string()));
                assert_eq!(r#ref, &Some("main".to_string()));

                // Verify that only recognized parameters were removed, unrecognized ones remain
                assert_eq!(url.query(), Some("custom=value"));
            }
            _ => panic!("Expected Git input type"),
        }

        // Test with multiple unrecognized parameters
        let input = "github:user/repo?rev=abc&foo=1&bar=2&ref=main";
        let flake_ref = input.parse::<FlakeRef>().unwrap();
        match &flake_ref.fetch_ref {
            FetchRef::GitHub { rev, r#ref, .. } => {
                // Verify parameters were extracted correctly
                assert_eq!(rev, &Some("abc".to_string()));
                assert_eq!(r#ref, &Some("main".to_string()));

                // The FetchRef doesn't contain the URL for GitHub type,
                // so we need to convert it to a URI and check that
                let uri = flake_ref.to_uri();

                // Verify that the remaining query has only unrecognized parameters
                let query = uri.query().unwrap();
                assert!(query.contains("foo=1"));
                assert!(query.contains("bar=2"));
                assert!(!query.contains("rev="));
                assert!(!query.contains("ref="));
            }
            _ => panic!("Expected GitHub input type"),
        }
    }

    #[test]
    fn test_github_urls() {
        let input = "github:snowfallorg/lib?ref=v2.1.1";
        let flake_ref = input.parse::<FlakeRef>().unwrap();
        match &flake_ref.fetch_ref {
            FetchRef::GitHub { r#ref, rev, .. } => {
                assert_eq!(r#ref, &Some("v2.1.1".to_string()));
                assert_eq!(rev, &None);
            }
            _ => panic!("Expected GitHub input type"),
        }

        let input = "github:aarowill/base16-alacritty";
        let flake_ref = input.parse::<FlakeRef>().unwrap();
        match &flake_ref.fetch_ref {
            FetchRef::GitHub { r#ref, rev, .. } => {
                assert_eq!(r#ref, &None);
                assert_eq!(rev, &None);
            }
            _ => panic!("Expected GitHub input type"),
        }

        let input = "github:a/b/c?ref=yyy";
        match input.parse::<FlakeRef>() {
            Ok(_) => panic!("Expected error for multiple identifiers"),
            Err(FlakeRefError::UnsupportedType(_)) => (),
            _ => panic!("Expected UnsupportedType error"),
        }

        let input = "github:a";
        match input.parse::<FlakeRef>() {
            Ok(_) => panic!("Expected error for missing repo"),
            Err(FlakeRefError::UnsupportedType(_)) => (),
            _ => panic!("Expected UnsupportedType error"),
        }

        let input = "github:a/b/master/extra";
        let flake_ref = input.parse::<FlakeRef>().unwrap();
        match &flake_ref.fetch_ref {
            FetchRef::GitHub { r#ref, rev, .. } => {
                assert_eq!(r#ref, &Some("master/extra".to_string()));
                assert_eq!(rev, &None);
            }
            _ => panic!("Expected GitHub input type"),
        }

        let input = "github:a/b";
        let flake_ref = input.parse::<FlakeRef>().unwrap();
        match &flake_ref.fetch_ref {
            FetchRef::GitHub { r#ref, .. } => {
                assert_eq!(r#ref, &None);
            }
            _ => panic!("Expected GitHub input type"),
        }
    }

    #[test]
    fn test_file_urls() {
        let input = "https://www.shutterstock.com/image-photo/young-potato-isolated-on-white-260nw-630239534.jpg";
        let flake_ref = input.parse::<FlakeRef>().unwrap();
        match &flake_ref.fetch_ref {
            FetchRef::File {
                url,
                nar_hash,
                rev,
                rev_count,
                last_modified,
            } => {
                assert_eq!(url.to_string(), input);
                assert_eq!(nar_hash, &None);
                assert_eq!(rev, &None);
                assert_eq!(rev_count, &None);
                assert_eq!(last_modified, &None);
            }
            _ => panic!("Expected File input type"),
        }
    }

    #[test]
    fn test_path_urls() {
        let input = "path:./go";
        let flake_ref = input.parse::<FlakeRef>().unwrap();
        match &flake_ref.fetch_ref {
            FetchRef::Path {
                path,
                rev,
                nar_hash,
                rev_count,
                last_modified,
            } => {
                assert_eq!(path.to_str().unwrap(), "./go");
                assert_eq!(rev, &None);
                assert_eq!(nar_hash, &None);
                assert_eq!(rev_count, &None);
                assert_eq!(last_modified, &None);
            }
            _ => panic!("Expected Path input type"),
        }

        let input = "~/Downloads/a.zip";
        match input.parse::<FlakeRef>() {
            Ok(_) => panic!("Expected error for invalid URL format"),
            Err(FlakeRefError::UrlParseError(_)) => (),
            _ => panic!("Expected UrlParseError error"),
        }
    }
}
