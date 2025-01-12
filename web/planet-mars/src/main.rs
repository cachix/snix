//! Planet software to aggregate many feeds into one
//!
//! Input feeds are defined in a toml config file given as cmdline
//! argument. See the [`Config`] struct and the mars.toml.example file.
//!
//! The program iterates over all [feed urls], fetches them, stores them in
//! [feed_dir] and only rebuilds when at least one feed has updates. The
//! fetcher implements HTTP ETag and LastModified caching.
//!
//! During rebuild, all files in [templates_dir] are processed and written to
//! [out_dir].
//!
//! The software is supposed to be run like every 15 minutes.
//!
//! Use a reserved (sub)domain to publish the planet! Although this software
//! tries to sanitize input feeds, there could still be bugs that open the
//! planets domain to cross-site attacks.
//!
//! [templates_dir]: Config#structfield.templates_dir
//! [feed_dir]: Config#structfield.feed_dir
//! [out_dir]: Config#structfield.out_dir
//! [feed urls]: Config#structfield.feeds
#[macro_use]
extern crate log;

use crate::feed_store::FeedStore;
use crate::fetcher::Fetcher;
use anyhow::Result;
use clap::Parser;
use serde::Deserialize;
use std::fs;
use std::path::PathBuf;
use url::Url;

//mod atom_serializer;
mod feed_store;
mod fetcher;
mod template_engine;

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Args {
    /// config file in toml format
    #[arg(
        short,
        long,
        default_value_t = String::from("mars.toml")
    )]
    config: String,
    #[arg(long, default_value_t = false)]
    no_fetch: bool,
}

/// Config to be parsed from toml file given as cmdline option
#[derive(Deserialize)]
struct Config {
    /// to be used as part of the fetchers username header
    bot_name: String,
    /// where to store downloaded feeds and their metadata
    feed_dir: String,
    /// feeds to be agregated
    feeds: Vec<FeedConfig>,
    /// Email adress to use for the from header when fetching feeds
    from: String,
    /// where to build the output files
    out_dir: String,
    /// templates folder
    templates_dir: String,
    /// How many feed entries should be included in the planet
    max_entries: usize,
}

pub fn to_checked_pathbuf(dir: &str) -> PathBuf {
    let dir: PathBuf = PathBuf::from(dir);

    let m = dir
        .metadata()
        .unwrap_or_else(|_| panic!("Could not get metadata of dir: {}", dir.display()));
    assert!(m.is_dir(), "Not a dir: {}", dir.display());
    dir
}

/// Config for one individual input feed
///
/// This is a separate struct in case one wants to configure additional
/// information in the future.
#[derive(Deserialize)]
struct FeedConfig {
    /// url of an ATOM, RSS or Json feed
    url: String,
}

fn fetch(config: &Config, feed_store: &FeedStore) -> Result<bool> {
    let fetcher = Fetcher::new(&config.bot_name, &config.from);
    let mut rebuild = false;
    for feed in &config.feeds {
        let url = match Url::parse(&feed.url) {
            Ok(x) => x,
            Err(e) => {
                error!("Error parsing url '{}': {e:?}", feed.url);
                continue;
            }
        };
        rebuild |= fetcher.fetch(url, feed_store)?;
    }
    info!("Done fetching. Rebuild needed: {rebuild}");
    Ok(rebuild)
}

fn main() -> Result<()> {
    env_logger::init();
    info!("starting up");

    let args = Args::parse();
    let config_path = &args.config;
    if !fs::exists(config_path)? {
        panic!("Configuration file {config_path} does not exist!");
    }
    let config: Config = toml::from_str(&fs::read_to_string(config_path)?)?;
    // only check here to avoid fetching with broken config
    // todo: get a config lib that provides validation!
    let _ = to_checked_pathbuf(&config.templates_dir);
    let _ = to_checked_pathbuf(&config.out_dir);

    let feed_store = FeedStore::new(&config.feed_dir);
    let should_build = if args.no_fetch {
        true
    } else {
        fetch(&config, &feed_store)?
    };

    if should_build {
        template_engine::build(&config, &feed_store)?;
    }
    Ok(())
}
