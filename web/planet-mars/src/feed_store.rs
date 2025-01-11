use feed_rs::model::Entry;
use feed_rs::model::Feed;
use serde::{Deserialize, Serialize};
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

    fn slugify_url(url: &Url) -> String {
        let domain = url.domain().unwrap();
        let query = url.query().unwrap_or("");
        slug::slugify(format!("{domain}{}{query}", url.path()))
    }

    fn feed_path(&self, url: &Url) -> String {
        format!("{}/{}", self.dir.display(), Self::slugify_url(url))
    }

    fn fetchdata_path(&self, url: &Url) -> String {
        format!("{}.toml", self.feed_path(url))
    }

    pub fn load_fetchdata(&self, url: &Url) -> FetchData {
        let path = self.fetchdata_path(url);
        if !fs::exists(path.clone()).unwrap() {
            return FetchData::default();
        }
        toml::from_str(&fs::read_to_string(path).unwrap()).unwrap()
    }

    fn has_changed(&self, url: &Url, new_feed: &Feed) -> bool {
        let Some(old_feed) = self.load_feed(url, false) else {
            return true;
        };

        let mut old_iter = old_feed.entries.iter();
        for new in &new_feed.entries {
            let Some(old) = old_iter.next() else {
                return true;
            };
            if old != new {
                return true;
            }
        }
        // ignoring any entries left in old_iter
        false
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

    pub fn store(&self, url: &Url, mut response: Response<Body>) -> bool {
        let headers = response.headers();
        let fetchdata = FetchData {
            etag: hv(headers, "etag"),
            last_modified: hv(headers, "last_modified"),
        };

        let body = response
            .body_mut()
            .with_config()
            //            .limit(MAX_BODY_SIZE)
            .read_to_vec()
            .unwrap();
        let feed = match feed_rs::parser::parse(body.as_slice()) {
            Ok(f) => f,
            Err(e) => {
                warn!("Error when parsing feed for {url}: {e:?}");
                return false;
            }
        };
        if !self.has_changed(url, &feed) {
            return false;
        }
        debug!("Storing feed for {url}.");
        let _ = Self::write(self.feed_path(url), body);
        let _ = Self::write(
            self.fetchdata_path(url),
            toml::to_string(&fetchdata).unwrap(),
        );
        true
    }

    fn load_feed(&self, url: &Url, sanitize: bool) -> Option<Feed> {
        let parser = feed_rs::parser::Builder::new()
            .sanitize_content(sanitize)
            .build();

        let path = self.feed_path(url);
        if !fs::exists(path.clone()).unwrap() {
            return None;
        }
        let file = fs::File::open(path).unwrap();
        Some(parser.parse(BufReader::new(file)).unwrap())
    }

    pub fn collect(&self, feed_configs: &Vec<super::FeedConfig>) -> Vec<Entry> {
        let mut entries = vec![];

        for feed_config in feed_configs {
            let url = Url::parse(&feed_config.url).unwrap();
            let Some(mut feed) = self.load_feed(&url, true) else {
                // todo error handling!
                warn!("Problem parsing feed file for feed {}", feed_config.url);
                continue;
            };
            entries.append(&mut feed.entries);
            // todo also trim mid-way when length > something, trading cpu for memory
        }
        trim_entries(entries)
    }
}

fn trim_entries(mut entries: Vec<Entry>) -> Vec<Entry> {
    entries.sort_by_key(|e| std::cmp::Reverse(e.updated.or(e.published).unwrap_or_default()));
    entries.truncate(10);
    entries
}

fn hv(headers: &HeaderMap, key: &str) -> String {
    match headers.get(key) {
        Some(hv) => hv.to_str().unwrap_or_default().to_string(),
        _ => "".to_string(),
    }
}
