use super::{Entry, SymlinkEntry, entry};
use crate::DirectoryError;

mod directory;

/// Create an entry with an empty symlink target, and ensure it fails validation.
#[test]
fn convert_symlink_empty_target_invalid() {
    Entry {
        entry: Some(entry::Entry::Symlink(SymlinkEntry {
            name: "foo".into(),
            target: "".into(),
        })),
    }
    .try_into_name_and_node()
    .expect_err("must fail validation");
}

/// Create a node with a symlink target including null bytes, and ensure it
/// fails validation.
#[test]
fn convert_symlink_target_null_byte_invalid() {
    Entry {
        entry: Some(entry::Entry::Symlink(SymlinkEntry {
            name: "foo".into(),
            target: "foo\0".into(),
        })),
    }
    .try_into_name_and_node()
    .expect_err("must fail validation");
}

/// Create a node with a name, and ensure our ano
#[test]
fn convert_anonymous_with_name_fail() {
    assert_eq!(
        DirectoryError::NameInAnonymousNode,
        Entry {
            entry: Some(entry::Entry::Symlink(SymlinkEntry {
                name: "foo".into(),
                target: "somewhereelse".into(),
            })),
        }
        .try_into_anonymous_node()
        .expect_err("must fail")
    )
}
