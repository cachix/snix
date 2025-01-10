use feed_rs::model::Entry;

/// Simplified Feed entry for easier value access in template
#[derive(serde::Serialize)]
pub struct SimpleEntry {
    pub date: String,
    pub content: String,
    pub author: String,
    pub link: String,
    pub title: String,
}

/// format for the entries timestamp
/// <https://docs.rs/chrono/latest/chrono/format/strftime>
const FMT: &str = "%c";

impl SimpleEntry {
    pub fn from_feed_entry(entry: Entry) -> Self {
        Self {
            date: entry
                .updated
                .or(entry.published)
                .unwrap_or_default()
                .format(FMT)
                .to_string(),
            content: entry
                .content
                .map(|x| x.body.unwrap_or_default())
                .unwrap_or_default(),
            author: if !entry.authors.is_empty() {
                entry.authors[0].name.clone()
            } else {
                "".to_string()
            },
            link: if !entry.links.is_empty() {
                entry.links[0].href.clone()
            } else {
                "".to_string()
            },
            title: entry.title.map(|x| x.content).unwrap_or_default(),
        }
    }
}
