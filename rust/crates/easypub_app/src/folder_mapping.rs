//! Explicit directory rules resolved by canonical path components, never filename prefixes.
use crate::production::Edit;
use easypub_core::{ApiError, ErrorCode};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::Path,
};
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Rule {
    #[serde(default, skip_serializing_if = "is_global")]
    pub priority: u8,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    pub folder: String,
    pub fields: BTreeMap<String, Edit>,
}
fn is_global(value: &u8) -> bool {
    *value == 0
}
impl Rule {
    pub fn identity(&self) -> String {
        self.id.clone().unwrap_or_else(|| {
            let folder = self.folder.replace('\\', "/");
            let folder = if cfg!(windows) {
                folder.to_lowercase()
            } else {
                folder
            };
            format!("legacy-{}", digest(serde_json::json!({"folder": folder})))
        })
    }
    pub fn revision(&self) -> String {
        digest(serde_json::json!({"folder":self.folder,"fields":self.fields}))
    }
}
fn digest(value: serde_json::Value) -> String {
    use sha2::{Digest, Sha256};
    format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(&value).expect("JSON value"))
    )
}
#[derive(Serialize)]
pub struct Resolution {
    pub winner: Option<usize>,
    pub candidates: Vec<usize>,
    pub canonical_source: String,
    pub unavailable: Vec<usize>,
}
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "folder_mapping",
        "review_unique_existing_folders_and_fields",
    )
}
fn canonical(path: &str, directory: bool) -> Result<(String, Vec<String>), ApiError> {
    let p = Path::new(path);
    if path.len() > 32768 || !p.is_absolute() {
        return Err(invalid());
    }
    let p = p.canonicalize().map_err(|_| invalid())?;
    if (directory && !p.is_dir()) || (!directory && !p.is_file()) {
        return Err(invalid());
    }
    let display = p.to_str().ok_or_else(invalid)?.to_owned();
    let parts = p
        .components()
        .map(|c| {
            c.as_os_str()
                .to_str()
                .map(|s| {
                    if cfg!(windows) {
                        s.to_lowercase()
                    } else {
                        s.to_owned()
                    }
                })
                .ok_or_else(invalid)
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok((display, parts))
}
/// Stored configuration is validated without requiring resources to be online.
pub fn validate_rules(rules: &[Rule]) -> Result<(), ApiError> {
    if rules.iter().filter(|r| r.priority == 0).count() > 128
        || rules.iter().filter(|r| r.priority == 1).count() > 128
    {
        return Err(invalid());
    }
    let mut identities = BTreeSet::new();
    for rule in rules {
        let id = rule.identity();
        if id.is_empty()
            || id.len() > 128
            || !id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
            || !identities.insert((rule.priority, id))
            || rule.priority > 1
            || rule.version.as_ref().is_some_and(|v| *v != rule.revision())
        {
            return Err(invalid());
        }
        if !Path::new(&rule.folder).is_absolute()
            || rule.folder.len() > 32768
            || rule.folder.contains('\0')
            || rule.fields.is_empty()
        {
            return Err(invalid());
        }
        for (key, edit) in &rule.fields {
            let limit = match key.as_str() {
                "title" | "author" | "translator" | "isbn" | "publication_date" | "publisher"
                | "category" | "language" | "series" | "series_index" | "subjects" => 4096,
                "description" => 65536,
                "cover_path" => 32768,
                "cover_fit" => 16,
                _ => return Err(invalid()),
            };
            match edit {
                Edit::Keep {} => {}
                Edit::Clear {} if key != "cover_fit" => {}
                Edit::Clear {} => return Err(invalid()),
                Edit::Set { value } | Edit::FillEmpty { value } => {
                    let text = value.as_str().ok_or_else(invalid)?;
                    if text.len() > limit || text.contains('\0') {
                        return Err(invalid());
                    }
                    if key == "cover_path" && !Path::new(text).is_absolute() {
                        return Err(invalid());
                    }
                    if key == "cover_fit" && !matches!(text, "cover" | "contain" | "fill") {
                        return Err(invalid());
                    }
                }
            }
        }
    }
    Ok(())
}
pub fn resolve(source_path: &str, rules: &[Rule]) -> Result<Resolution, ApiError> {
    validate_rules(rules)?;
    let (canonical_source, source) = canonical(source_path, false)?;
    let mut folders = BTreeSet::new();
    let mut candidates = Vec::new();
    let mut unavailable = Vec::new();
    for (index, rule) in rules.iter().enumerate() {
        let (_, folder) = match canonical(&rule.folder, true) {
            Ok(value) => value,
            Err(_) => {
                unavailable.push(index);
                continue;
            }
        };
        if !folders.insert((rule.priority, folder.clone())) {
            return Err(invalid());
        }
        if source.len() > folder.len() && source.starts_with(&folder) {
            candidates.push((index, folder.len(), rule.priority));
        }
    }
    candidates.sort_by_key(|(_, depth, priority)| std::cmp::Reverse((*priority, *depth)));
    Ok(Resolution {
        winner: candidates.first().map(|(i, _, _)| *i),
        candidates: candidates.into_iter().map(|(i, _, _)| i).collect(),
        canonical_source,
        unavailable,
    })
}

#[cfg(test)]
mod identity_tests {
    use super::*;
    #[test]
    fn identity_survives_changes_but_revision_must_match_content() {
        let folder = std::env::temp_dir().to_string_lossy().into_owned();
        let mut rule: Rule = serde_json::from_value(serde_json::json!({
            "id":"rule-fixture", "folder":folder, "fields":{"author":{"op":"set","value":"A"}}
        }))
        .unwrap();
        let original = rule.revision();
        rule.version = Some(original.clone());
        assert!(validate_rules(&[rule.clone()]).is_ok());
        rule.fields.insert(
            "author".into(),
            Edit::Set {
                value: serde_json::json!("B"),
            },
        );
        assert_eq!(rule.identity(), "rule-fixture");
        assert_ne!(rule.revision(), original);
        assert!(validate_rules(&[rule.clone()]).is_err());
        rule.version = Some(rule.revision());
        assert!(validate_rules(&[rule.clone()]).is_ok());
        assert!(validate_rules(&[rule.clone(), rule]).is_err());
    }
}
