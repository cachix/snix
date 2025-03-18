// Implements a parser and formatter for Nix flake references.
// It defines the `FlakeRef` enum which represents different types of flake sources
// (such as Git repositories, GitHub repos, local paths, etc.), along with functionality
// to parse URLs into `FlakeRef` instances and convert them back to URIs.
use std::{collections::HashMap, path::PathBuf};
use url::Url;

#[derive(Debug)]
#[non_exhaustive]
pub enum FlakeRef {
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

#[derive(Debug, Default)]
pub struct FlakeRefOutput {
    pub out_path: String,
    pub nar_hash: String,
    pub last_modified: Option<i64>,
    pub last_modified_date: Option<String>,
    pub rev_count: Option<i64>,
    pub rev: Option<String>,
    pub short_rev: Option<String>,
    pub submodules: Option<bool>,
}

impl FlakeRefOutput {
    pub fn into_kv_tuples(self) -> Vec<(String, String)> {
        let mut vec = vec![
            ("outPath".into(), self.out_path),
            ("narHash".into(), self.nar_hash),
        ];

        if let Some(lm) = self.last_modified {
            vec.push(("lastModified".into(), lm.to_string()));
        }
        if let Some(lmd) = self.last_modified_date {
            vec.push(("lastModifiedDate".into(), lmd));
        }
        if let Some(rc) = self.rev_count {
            vec.push(("revCount".into(), rc.to_string()));
        }
        if let Some(rev) = self.rev {
            vec.push(("rev".into(), rev));
        }
        if let Some(sr) = self.short_rev {
            vec.push(("shortRev".into(), sr));
        }
        if let Some(sub) = self.submodules {
            vec.push(("submodules".into(), sub.to_string()));
        }

        vec
    }
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

        // Extract query parameters
        let query_pairs = extract_query_pairs(&url);

        // Process URL based on fetch type
        Ok(match fetch_type {
            FetchType::File => {
                let params = extract_common_file_params(&query_pairs);
                FlakeRef::File {
                    url,
                    nar_hash: params.nar_hash,
                    rev: params.rev,
                    rev_count: params.rev_count,
                    last_modified: params.last_modified,
                }
            }
            FetchType::Tarball => {
                let params = extract_common_file_params(&query_pairs);
                FlakeRef::Tarball {
                    url,
                    nar_hash: params.nar_hash,
                    rev: params.rev,
                    rev_count: params.rev_count,
                    last_modified: params.last_modified,
                }
            }
            FetchType::Indirect => FlakeRef::Indirect {
                id: url.path().to_string(),
                r#ref: query_pairs.get("ref").cloned(),
                rev: query_pairs.get("rev").cloned(),
            },
            FetchType::Git => {
                let params = extract_git_params(&query_pairs);
                FlakeRef::Git {
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
                let params = extract_common_file_params(&query_pairs);
                FlakeRef::Path {
                    path: PathBuf::from(url.path()),
                    rev: params.rev,
                    nar_hash: params.nar_hash,
                    rev_count: params.rev_count,
                    last_modified: params.last_modified,
                }
            }
            FetchType::GitHub => {
                create_repo_host_args(&url, &query_pairs, |params| FlakeRef::GitHub {
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
            FetchType::GitLab => {
                create_repo_host_args(&url, &query_pairs, |params| FlakeRef::GitLab {
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
            FetchType::SourceHut => {
                create_repo_host_args(&url, &query_pairs, |params| FlakeRef::SourceHut {
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
fn extract_query_pairs(url: &Url) -> HashMap<String, String> {
    url.query_pairs()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

fn get_param(query_pairs: &HashMap<String, String>, key: &str) -> Option<u64> {
    query_pairs.get(key).and_then(|s| s.parse().ok())
}

fn get_bool_param(query_pairs: &HashMap<String, String>, key: &str) -> bool {
    query_pairs
        .get(key)
        .map(|v| v == "1" || v.to_lowercase() == "true")
        .unwrap_or(false)
}

// Parameter extractors
fn extract_common_file_params(query_pairs: &HashMap<String, String>) -> FileParams {
    FileParams {
        nar_hash: query_pairs.get("narHash").cloned(),
        rev: query_pairs.get("rev").cloned(),
        rev_count: get_param(query_pairs, "revCount"),
        last_modified: get_param(query_pairs, "lastModified"),
    }
}

fn extract_git_params(query_pairs: &HashMap<String, String>) -> GitParams {
    GitParams {
        r#ref: query_pairs.get("ref").cloned(),
        rev: query_pairs.get("rev").cloned(),
        keytype: query_pairs.get("keytype").cloned(),
        public_key: query_pairs.get("publicKey").cloned(),
        public_keys: query_pairs
            .get("publicKeys")
            .map(|s| s.split(',').map(String::from).collect()),
        submodules: get_bool_param(query_pairs, "submodules"),
        shallow: get_bool_param(query_pairs, "shallow"),
        export_ignore: get_bool_param(query_pairs, "exportIgnore"),
        all_refs: get_bool_param(query_pairs, "allRefs"),
        verify_commit: get_bool_param(query_pairs, "verifyCommit"),
    }
}

fn extract_repo_params(
    url: &Url,
    query_pairs: &HashMap<String, String>,
) -> Result<RepoHostParams, FlakeRefError> {
    let (owner, repo, path_ref) = parse_path_segments(url)?;

    // Check for branch/tag conflicts
    if path_ref.is_some() && query_pairs.contains_key("ref") {
        return Err(FlakeRefError::UnsupportedType(
            "URL contains multiple branch/tag names".to_string(),
        ));
    }

    let r#ref = path_ref.or_else(|| query_pairs.get("ref").cloned());

    Ok(RepoHostParams {
        owner,
        repo,
        r#ref,
        rev: query_pairs.get("rev").cloned(),
        host: query_pairs.get("host").cloned(),
        keytype: query_pairs.get("keytype").cloned(),
        public_key: query_pairs.get("publicKey").cloned(),
        public_keys: query_pairs
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

fn create_repo_host_args<F>(
    url: &Url,
    query_pairs: &HashMap<String, String>,
    creator: F,
) -> Result<FlakeRef, FlakeRefError>
where
    F: FnOnce(RepoHostParams) -> FlakeRef,
{
    let params = extract_repo_params(url, query_pairs)?;
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
        match self {
            FlakeRef::File {
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
            FlakeRef::Git {
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
            FlakeRef::GitHub {
                owner,
                repo,
                host,
                keytype,
                public_key,
                public_keys,
                r#ref,
                rev,
            }
            | FlakeRef::GitLab {
                owner,
                repo,
                host,
                keytype,
                public_key,
                public_keys,
                r#ref,
                rev,
            }
            | FlakeRef::SourceHut {
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
                    FlakeRef::GitHub { .. } => "github",
                    FlakeRef::GitLab { .. } => "gitlab",
                    FlakeRef::SourceHut { .. } => "sourcehut",
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
            FlakeRef::Indirect { id, r#ref, rev } => {
                let mut url = Url::parse(&format!("indirect://{}", id)).unwrap();
                append_params(&mut url, &[("ref", r#ref.clone()), ("rev", rev.clone())]);
                url
            }
            FlakeRef::Path {
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
            FlakeRef::Tarball {
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
            FlakeRef::Mercurial { r#ref, rev } => {
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

    #[test]
    fn test_git_urls() {
        let input = "git+https://github.com/lichess-org/fishnet?submodules=1";
        pretty_assertions::assert_matches!(
            input.parse::<FlakeRef>(),
            Ok(FlakeRef::Git {
                submodules: true,
                shallow: false,
                export_ignore: false,
                all_refs: false,
                verify_commit: false,
                ..
            })
        );

        let input = "git+file:///home/user/project?ref=fa1e2d23a22";
        match input.parse::<FlakeRef>() {
            Ok(FlakeRef::Git { r#ref, rev, .. }) => {
                assert_eq!(r#ref, Some("fa1e2d23a22".to_string()));
                assert_eq!(rev, None);
            }
            _ => panic!("Expected Git input type"),
        }

        let input = "git+git://github.com/someuser/my-repo?rev=v1.2.3";
        match input.parse::<FlakeRef>() {
            Ok(FlakeRef::Git { rev, .. }) => {
                assert_eq!(rev, Some("v1.2.3".to_string()));
            }
            _ => panic!("Expected Git input type"),
        }
    }

    #[test]
    fn test_github_urls() {
        let input = "github:snowfallorg/lib?ref=v2.1.1";
        match input.parse::<FlakeRef>() {
            Ok(FlakeRef::GitHub { r#ref, rev, .. }) => {
                assert_eq!(r#ref, Some("v2.1.1".to_string()));
                assert_eq!(rev, None);
            }
            _ => panic!("Expected GitHub input type"),
        }

        let input = "github:aarowill/base16-alacritty";
        match input.parse::<FlakeRef>() {
            Ok(FlakeRef::GitHub { r#ref, rev, .. }) => {
                assert_eq!(r#ref, None);
                assert_eq!(rev, None);
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
        match input.parse::<FlakeRef>() {
            Ok(FlakeRef::GitHub { r#ref, rev, .. }) => {
                assert_eq!(r#ref, Some("master/extra".to_string()));
                assert_eq!(rev, None);
            }
            _ => panic!("Expected GitHub input type"),
        }

        let input = "github:a/b";
        match input.parse::<FlakeRef>() {
            Ok(FlakeRef::GitHub { r#ref, .. }) => {
                assert_eq!(r#ref, None);
            }
            _ => panic!("Expected GitHub input type"),
        }
    }

    #[test]
    fn test_file_urls() {
        let input = "https://www.shutterstock.com/image-photo/young-potato-isolated-on-white-260nw-630239534.jpg";
        pretty_assertions::assert_matches!(
            input.parse::<FlakeRef>(),
            Ok(FlakeRef::File {
                url,
                nar_hash: None,
                rev: None,
                rev_count: None,
                last_modified: None,
            }) if url.to_string() == input
        );
    }

    #[test]
    fn test_path_urls() {
        let input = "path:./go";
        pretty_assertions::assert_matches!(
            input.parse::<FlakeRef>(),
            Ok(FlakeRef::Path {
                path,
                rev: None,
                nar_hash: None,
                rev_count: None,
                last_modified: None,
            }) if path.to_str().unwrap() == "./go"
        );

        let input = "~/Downloads/a.zip";
        match input.parse::<FlakeRef>() {
            Ok(_) => panic!("Expected error for invalid URL format"),
            Err(FlakeRefError::UrlParseError(_)) => (),
            _ => panic!("Expected UrlParseError error"),
        }
    }
}
