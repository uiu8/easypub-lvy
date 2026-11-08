//! Book collections (LIB-118–126): named groups of library books saved with the
//! project. A collection only records membership and an optional metadata
//! preset; applying the preset is an ordinary production patch that the user
//! previews, so membership itself never edits a book.
use crate::production::Edit;
use easypub_core::{ApiError, ErrorCode};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

pub const MAX_COLLECTIONS: usize = 256;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Collection {
    pub id: String,
    pub name: String,
    /// Library book ids (lower-cased source path), in the order they were added.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub books: Vec<String>,
    /// Metadata preset offered when books join, using the directory-rule field edits.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub template: BTreeMap<String, Edit>,
    /// Apply the preset as soon as books join instead of asking first.
    #[serde(default)]
    pub auto_apply: bool,
}

fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "book_collections",
        "review_collection_names_members_and_fields",
    )
}

pub fn validate(collections: &[Collection]) -> Result<(), ApiError> {
    if collections.len() > MAX_COLLECTIONS {
        return Err(invalid());
    }
    let mut ids = BTreeSet::new();
    let mut names = BTreeSet::new();
    for collection in collections {
        let name = collection.name.trim();
        if collection.id.is_empty()
            || collection.id.len() > 128
            || !collection
                .id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
            || !ids.insert(collection.id.as_str())
            || name.is_empty()
            || name != collection.name
            || name.chars().count() > 64
            || name.contains('\0')
            || !names.insert(name.to_lowercase())
            || collection.books.len() > crate::sessions::MAX_SOURCES
        {
            return Err(invalid());
        }
        let mut members = BTreeSet::new();
        for book in &collection.books {
            if book.is_empty() || book.len() > 32768 || book.contains('\0') || !members.insert(book)
            {
                return Err(invalid());
            }
        }
        crate::folder_mapping::validate_fields(&collection.template)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn parse(value: serde_json::Value) -> Vec<Collection> {
        serde_json::from_value(value).unwrap()
    }

    #[test]
    fn collections_validate_names_members_and_preset_fields() {
        let good = parse(json!([
            {"id":"c-1","name":"武侠","books":["d:/a.txt","d:/b.txt"],
             "template":{"category":{"op":"set","value":"武侠"},"author":{"op":"fill_empty","value":"佚名"}},
             "auto_apply":true},
            {"id":"c-2","name":"待读"}
        ]));
        assert!(validate(&good).is_ok());
        // Serialising an empty collection omits the optional parts.
        let text = serde_json::to_value(&good[1]).unwrap();
        assert_eq!(text, json!({"id":"c-2","name":"待读","auto_apply":false}));

        for bad in [
            json!([{"id":"c 1","name":"甲"}]),
            json!([{"id":"c-1","name":" 甲"}]),
            json!([{"id":"c-1","name":""}]),
            json!([{"id":"c-1","name":"甲"},{"id":"c-1","name":"乙"}]),
            json!([{"id":"c-1","name":"Ab"},{"id":"c-2","name":"aB"}]),
            json!([{"id":"c-1","name":"甲","books":["x","x"]}]),
            json!([{"id":"c-1","name":"甲","template":{"font_size":{"op":"set","value":"1"}}}]),
            json!([{"id":"c-1","name":"甲","template":{"cover_fit":{"op":"clear"}}}]),
        ] {
            assert!(validate(&parse(bad.clone())).is_err(), "{bad}");
        }
        assert!(
            serde_json::from_value::<Vec<Collection>>(
                json!([{"id":"c","name":"甲","color":"red"}])
            )
            .is_err()
        );
    }
}
