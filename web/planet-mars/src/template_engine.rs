use crate::feed_store::FeedStore;
use crate::to_checked_pathbuf;
use crate::Config;
use anyhow::Result;
use feed_rs::model::Feed;
use std::collections::HashMap;
use std::fs::File;
use tera::{from_value, Tera};

pub fn build(config: &Config, feed_store: &FeedStore) -> Result<()> {
    let mut tera = create_tera(&config.templates_dir)?;
    let out_dir = to_checked_pathbuf(&config.out_dir);

    let mut context = tera::Context::new();
    let (feeds, entries): (HashMap<String, Feed>, _) =
        feed_store.collect(&config.feeds, config.max_entries);
    context.insert("feeds", &feeds);
    context.insert("entries", &entries);
    context.insert("PKG_AUTHORS", env!("CARGO_PKG_AUTHORS"));
    context.insert("PKG_HOMEPAGE", env!("CARGO_PKG_HOMEPAGE"));
    context.insert("PKG_NAME", env!("CARGO_PKG_NAME"));
    context.insert("PKG_VERSION", env!("CARGO_PKG_VERSION"));
    tera.register_function("get_author", GetAuthorFunction { feeds });

    for name in tera.get_template_names() {
        debug!("Processing template {name}");
        let file = File::create(format!("{}/{name}", out_dir.display()))?;
        tera.render_to(name, &context, file)?;
    }
    Ok(())
}

fn create_tera(templates_dir: &str) -> Result<Tera> {
    let dir = to_checked_pathbuf(templates_dir);
    let mut tera = tera::Tera::new(&format!("{}/*", &dir.display()))?;
    // disable autoescape as this would corrupt urls or the entriy contents. todo check this!
    tera.autoescape_on(vec![]);
    Ok(tera)
}

struct GetAuthorFunction {
    feeds: HashMap<String, Feed>,
}

impl tera::Function for GetAuthorFunction {
    fn call(&self, args: &HashMap<String, tera::Value>) -> Result<tera::Value, tera::Error> {
        let entry_val: tera::Map<_, _> = match args.get("entry") {
            None => {
                return Err(tera::Error::msg(
                    "No argument of name 'entry' given to function.",
                ))
            }
            Some(val) => from_value(val.clone())?,
        };

        let feed_url: String = from_value(entry_val.get("source").unwrap().clone())?;
        let authors_val: Vec<tera::Map<_, _>> =
            from_value(entry_val.get("authors").unwrap().clone())?;

        let mut authors: Vec<String> = Vec::new();
        for author_val in authors_val {
            let name: String = from_value(author_val.get("name").unwrap().clone())?;
            if is_valid_name(&name) {
                authors.push(name.clone());
            }
        }

        if authors.is_empty() {
            authors.append(&mut self.find_authors_from_feed(&feed_url));
        }
        Ok(tera::Value::String(authors.join(", ")))
    }
}

impl GetAuthorFunction {
    fn find_authors_from_feed(&self, feed_url: &str) -> Vec<String> {
        let feed = self.feeds.get(feed_url).unwrap();

        feed.authors
            .clone()
            .into_iter()
            .map(|x| x.name)
            .filter(is_valid_name)
            .collect()
    }
}

fn is_valid_name(n: &String) -> bool {
    !n.is_empty() && n != "unknown" && n != "author"
}
