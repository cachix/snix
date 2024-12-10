// SPDX-FileCopyrightText: Copyright © 2024 sterni
// SPDX-License-Identifier: GPL-3.0-only
use lol_html::html_content::ContentType;
use lol_html::{element, HtmlRewriter, Settings};
use mail_parser::{Message, MessageParser, MimeHeaders};
use memmap2::Mmap;

use std::collections::HashMap;
use std::env;
use std::error::Error;
use std::fmt;
use std::fs::File;
use std::io::Write;

type CidMap<'a> = HashMap<&'a str, &'a str>;

#[derive(Debug)]
enum Mn2htmlError {
    MimeParseFail,
    NoMailNote,
    MissingAttachment(String),
}

impl fmt::Display for Mn2htmlError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Mn2htmlError::MimeParseFail => {
                write!(f, "Could not parse given file as a MIME message")
            }
            Mn2htmlError::NoMailNote => {
                write!(f, "Given MIME message does not appear to be a Mail Note")
            }
            Mn2htmlError::MissingAttachment(cid) => write!(
                f,
                "Given object's Content-Id {} doesn't match any attachment",
                cid
            ),
        }
    }
}

impl Error for Mn2htmlError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        None
    }
}

fn warn(msg: &str) {
    eprintln!("mn2html: {}", msg);
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    for arg in env::args_os().skip(1) {
        // TODO(sterni): flags, --help and such
        let msg_file = File::open(arg)?;
        let msg_raw = unsafe { Mmap::map(&msg_file) }?;

        let msg_parsed = MessageParser::default()
            .parse(msg_raw.as_ref())
            .ok_or(Mn2htmlError::MimeParseFail)?;

        if !matches!(
            msg_parsed
                .header("X-Uniform-Type-Identifier")
                .and_then(|h| h.as_text()),
            Some("com.apple.mail-note")
        ) {
            return Err(Box::new(Mn2htmlError::NoMailNote));
        }

        let cid_map = index_attachments(&msg_parsed);
        let html_body = msg_parsed
            .html_bodies()
            .nth(0)
            .ok_or(Mn2htmlError::NoMailNote)?
            .contents();

        rewrite_html(html_body, &cid_map)?;
    }

    Ok(())
}

// At some point, it was a consideration to move this out of the Rust program.
// mn2html would have been a shell script with mblaze(7) tools finding the
// attachments and their content ideas passing the information to a Rust HTML
// rewriter via CLI args. It is unclear how much (if at all?) slower this would
// have been. In the end, it just seemed cleaner to do it in the Rust program,
// especially since the HTML rewriter would not really have been useful on its
// own.
fn index_attachments<'a>(msg: &'a Message) -> CidMap<'a> {
    let mut map = HashMap::new();
    for a in msg.attachments() {
        match (a.content_id(), a.attachment_name()) {
            (Some(cid), Some(filename)) => {
                if let Some(_) = map.insert(cid, filename) {
                    warn("multiple attachments share the same Content-Id");
                }
            }
            (_, _) => warn("attachment without Content-Id and/or filename in Content-Disposition"),
        }
    }

    map
}

fn rewrite_html(html_body: &[u8], cid_map: &CidMap) -> Result<(), Box<dyn std::error::Error>> {
    let mut stdout = std::io::stdout();
    let mut rewriter = HtmlRewriter::new(
        Settings {
            element_content_handlers: vec![
                element!("head", |el| {
                    el.remove();
                    Ok(())
                }),
                element!("body", |el| {
                    el.remove_and_keep_content();
                    Ok(())
                }),
                element!("html", |el| {
                    el.remove_and_keep_content();
                    Ok(())
                }),
                element!("object[type][data]", |el| {
                    if el
                        .get_attribute("type")
                        .expect("element! matched object[type] without type attribute")
                        != "application/x-apple-msg-attachment"
                    {
                        warn("encountered object with unknown type attribute, ignoring");
                        return Ok(());
                    }

                    match el
                        .get_attribute("data")
                        .expect("element! matched object[data] without data attribute")
                        .split_at_checked(4)
                    {
                        Some(("cid:", cid)) => match cid_map.get(cid) {
                            Some(filename) => el.replace(
                                &format!(r#"<img src="{}">"#, filename),
                                ContentType::Html,
                            ),
                            _ => {
                                return Err(Box::new(Mn2htmlError::MissingAttachment(
                                    cid.to_string(),
                                )))
                            }
                        },
                        _ => warn("encountered object with malformed data attribute, ignoring"),
                    };

                    Ok(())
                }),
            ],
            ..Settings::new()
        },
        |c: &[u8]| stdout.write_all(c).expect("Can't write to stdout"),
    );

    rewriter.write(html_body)?;
    rewriter.end()?;

    Ok(())
}
