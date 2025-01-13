use anyhow::bail;
use anyhow::Result;
use feed_rs::model::Entry;
use feed_rs::model::Feed;
use ron::ser::{to_string_pretty, PrettyConfig};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::convert::AsRef;
use std::fs;
use std::io::BufReader;
use std::path::PathBuf;
use ureq::http::HeaderMap;
use ureq::http::Response;
use ureq::Body;
use url::Url;

#[derive(Deserialize, Serialize, Default)]
pub struct FetchData {
    pub etag: String,
    pub last_modified: String,
}

pub struct FeedStore {
    pub dir: PathBuf,
}

impl FeedStore {
    pub fn new(dir: &str) -> Self {
        Self {
            dir: super::to_checked_pathbuf(dir),
        }
    }

    fn slugify_url(url: &Url) -> Result<String> {
        let Some(domain) = url.domain() else {
            bail!("Url has no domain: '{url}'.")
        };
        let query = url.query().unwrap_or("");
        Ok(slug::slugify(format!("{domain}{}{query}", url.path())))
    }

    fn generic_path(&self, url: &Url, ext: &str) -> Result<String> {
        Ok(format!(
            "{}/{}{ext}",
            self.dir.display(),
            Self::slugify_url(url)?
        ))
    }

    fn feed_path(&self, url: &Url) -> Result<String> {
        self.generic_path(url, "")
    }

    fn fetchdata_path(&self, url: &Url) -> Result<String> {
        self.generic_path(url, ".toml")
    }

    pub fn load_fetchdata(&self, url: &Url) -> Result<FetchData> {
        let path = self.fetchdata_path(url)?;
        if !fs::exists(path.clone())? {
            return Ok(FetchData::default());
        }
        Ok(toml::from_str(&fs::read_to_string(path)?)?)
    }

    fn has_changed(&self, url: &Url, new_feed: &Feed) -> Result<bool> {
        let Some(old_feed) = self.load_feed(url, false)? else {
            return Ok(true);
        };

        let mut old_iter = old_feed.entries.iter();
        for new in &new_feed.entries {
            let Some(old) = old_iter.next() else {
                return Ok(true);
            };
            if old != new {
                return Ok(true);
            }
        }
        // ignoring any entries left in old_iter
        Ok(false)
    }

    fn write<P: AsRef<std::path::Path> + std::fmt::Display, C: AsRef<[u8]>>(
        path: P,
        contents: C,
    ) -> std::io::Result<()> {
        if fs::exists(&path)? {
            fs::rename(&path, format!("{path}.backup"))?;
        }
        fs::write(path, contents)
    }

    pub fn store(&self, url: &Url, mut response: Response<Body>) -> Result<bool> {
        let headers = response.headers();
        let fetchdata = FetchData {
            etag: hv(headers, "etag"),
            last_modified: hv(headers, "last_modified"),
        };

        let body = response.body_mut().with_config().read_to_vec()?;
        let feed = match feed_rs::parser::parse(body.as_slice()) {
            Ok(f) => f,
            Err(e) => {
                warn!("Error when parsing feed for {url}: {e:?}");
                return Ok(false);
            }
        };
        if !self.has_changed(url, &feed)? {
            return Ok(false);
        }
        debug!("Storing feed for {url}.");
        // todo don't serialize to string but to writer
        Self::write(
            self.generic_path(url, ".ron")?,
            to_string_pretty(&feed, PrettyConfig::default())?,
        )?;
        Self::write(self.feed_path(url)?, body)?;
        Self::write(self.fetchdata_path(url)?, toml::to_string(&fetchdata)?)?;
        Ok(true)
    }

    fn load_feed(&self, url: &Url, sanitize: bool) -> Result<Option<Feed>> {
        let parser = feed_rs::parser::Builder::new()
            .sanitize_content(sanitize)
            .build();

        let path = self.feed_path(url)?;
        if !fs::exists(path.clone())? {
            return Ok(None);
        }
        let file = fs::File::open(path)?;
        Ok(Some(parser.parse(BufReader::new(file))?))
    }

    pub fn collect(
        &self,
        feed_configs: &Vec<super::FeedConfig>,
        max_entries: usize,
    ) -> (HashMap<String, Feed>, Vec<Entry>) {
        let mut feeds = HashMap::new();
        let mut entries = Vec::new();

        for feed_config in feed_configs {
            let mut feed = match (|| {
                let url = Url::parse(&feed_config.url)?;
                self.load_feed(&url, true)
            })() {
                Err(e) => {
                    warn!(
                        "Problem parsing feed file for feed {}: {e:?}",
                        feed_config.url
                    );
                    continue;
                }
                Ok(None) => continue,
                Ok(Some(f)) => f,
            };
            for entry in &mut feed.entries {
                entry.source = Some(feed_config.url.clone());
            }

            entries.append(&mut std::mem::take(&mut feed.entries));
            feeds.insert(feed_config.url.clone(), feed);
            // optimization to reduce memory usage
            if entries.len() > 4 * max_entries {
                entries = trim_entries(entries, max_entries);
            }
        }
        (feeds, trim_entries(entries, max_entries))
    }
}

fn trim_entries(mut entries: Vec<Entry>, max_entries: usize) -> Vec<Entry> {
    entries.sort_by_key(|e| std::cmp::Reverse(e.updated.or(e.published).unwrap_or_default()));
    entries.truncate(max_entries);
    entries
}

fn hv(headers: &HeaderMap, key: &str) -> String {
    match headers.get(key) {
        Some(hv) => hv.to_str().unwrap_or_default().to_string(),
        _ => "".to_string(),
    }
}
