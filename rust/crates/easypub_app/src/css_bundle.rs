//! Portable, bounded CSS dependency storage; never serializes bytes into undo JSON.
use crate::css_resources::{Report, Snapshot};
use easypub_core::{ApiError, ErrorCode};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::Path,
};
const MAX_MANIFEST: usize = 2 * 1024 * 1024;
const MAX_TOTAL: usize = 256 * 1024 * 1024;
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Reference {
    pub directory: String,
    pub manifest_sha256: String,
}
impl Reference {
    pub fn validate(&self) -> Result<(), ApiError> {
        let path = Path::new(&self.directory);
        if self.directory.is_empty()
            || self.directory.len() > 32768
            || self.directory.contains('\0')
            || !valid_hash(&self.manifest_sha256)
            || (!path.is_absolute()
                && path
                    .components()
                    .any(|c| !matches!(c, std::path::Component::Normal(_))))
        {
            return Err(error());
        }
        Ok(())
    }
}
pub fn for_settings(settings: &crate::production::Settings) -> Snapshot {
    if let Some(reference) = &settings.additional_css_bundle {
        let result = restore(Path::new(&reference.directory), &reference.manifest_sha256);
        if let Ok(restored) = result
            && restored.manifest.css == settings.additional_css
                && restored.manifest.base == settings.additional_css_base
            {
                return Snapshot::from_restored(restored);
            }
        let mut failed = Snapshot::default();
        failed
            .report
            .issues
            .push("CSS 离线依赖包丢失、损坏或与当前样式不一致，请恢复依赖包。".into());
        return failed;
    }
    crate::css_resources::collect(&settings.additional_css, &settings.additional_css_base)
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub schema: u32,
    pub css: String,
    pub base: String,
    pub report: Report,
}
pub struct Restored {
    pub manifest: Manifest,
    pub originals: BTreeMap<String, Vec<u8>>,
    pub resources: BTreeMap<String, Vec<u8>>,
}
fn error() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "css_bundle",
        "restore_complete_css_bundle",
    )
}
fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn valid_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn resource_hash(id: &str) -> Option<&str> {
    let (hash, extension) = id.split_once('.')?;
    (valid_hash(hash)
        && matches!(
            extension,
            "css"
                | "png"
                | "jpg"
                | "jpeg"
                | "webp"
                | "svg"
                | "ttf"
                | "otf"
                | "woff"
                | "woff2"
                | "bin"
        ))
    .then_some(hash)
}
fn write_new(path: &Path, bytes: &[u8]) -> Result<(), ApiError> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|_| error())?;
    file.write_all(bytes).map_err(|_| error())?;
    file.sync_all().map_err(|_| error())
}
fn read_bound(path: &Path, limit: usize) -> Result<Vec<u8>, ApiError> {
    let file = File::open(path).map_err(|_| error())?;
    let meta = file.metadata().map_err(|_| error())?;
    if !meta.is_file() || meta.len() > limit as u64 {
        return Err(error());
    }
    let mut bytes = Vec::new();
    file.take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| error())?;
    if bytes.len() > limit {
        return Err(error());
    }
    Ok(bytes)
}
/// Publishes manifest last. Caller owns the new directory; existing paths are untouched.
pub fn persist(
    directory: &Path,
    css: &str,
    base: &str,
    snapshot: &Snapshot,
) -> Result<String, ApiError> {
    if !directory.is_absolute()
        || !snapshot.report.rewritten
        || !snapshot.report.issues.is_empty()
        || css.len() > 262144
        || css.contains('\0')
    {
        return Err(error());
    }
    let manifest = Manifest {
        schema: 1,
        css: css.into(),
        base: base.into(),
        report: snapshot.report.clone(),
    };
    let json = serde_json::to_vec(&manifest).map_err(|_| error())?;
    if json.len() > MAX_MANIFEST {
        return Err(error());
    }
    let total: usize = snapshot
        .bytes
        .values()
        .chain(snapshot.resources.values())
        .map(Vec::len)
        .sum();
    if total > MAX_TOTAL {
        return Err(error());
    }
    fs::create_dir(directory).map_err(|_| error())?;
    fs::create_dir(directory.join("originals")).map_err(|_| error())?;
    fs::create_dir(directory.join("resources")).map_err(|_| error())?;
    for (id, bytes) in &snapshot.bytes {
        if !valid_hash(id) || hash(bytes) != *id {
            return Err(error());
        }
        write_new(&directory.join("originals").join(id), bytes)?;
    }
    for (id, bytes) in &snapshot.resources {
        if resource_hash(id) != Some(hash(bytes).as_str()) {
            return Err(error());
        }
        write_new(&directory.join("resources").join(id), bytes)?;
    }
    write_new(&directory.join("manifest.stage"), &json)?;
    fs::hard_link(
        directory.join("manifest.stage"),
        directory.join("manifest.json"),
    )
    .map_err(|_| error())?;
    let _ = fs::remove_file(directory.join("manifest.stage"));
    Ok(hash(&json))
}
/// The caller supplies the manifest hash saved in the project. No original source paths are opened.
pub fn restore(directory: &Path, expected_manifest_hash: &str) -> Result<Restored, ApiError> {
    if !directory.is_absolute() || !valid_hash(expected_manifest_hash) {
        return Err(error());
    }
    let json = read_bound(&directory.join("manifest.json"), MAX_MANIFEST)?;
    if hash(&json) != expected_manifest_hash {
        return Err(error());
    }
    let manifest: Manifest = serde_json::from_slice(&json).map_err(|_| error())?;
    let report = &manifest.report;
    if manifest.schema != 1
        || manifest.css.len() > 262144
        || manifest.css.contains('\0')
        || !report.rewritten
        || !report.issues.is_empty()
        || report.files.len() > 128
        || report.resources.len() > 257
    {
        return Err(error());
    }
    let mut originals = BTreeMap::new();
    let mut resources = BTreeMap::new();
    let mut total = 0usize;
    for item in &report.files {
        if !valid_hash(&item.sha256) || item.byte_length > 32 * 1024 * 1024 {
            return Err(error());
        }
        if let Some(bytes) = originals.get(&item.sha256) {
            if Vec::<u8>::len(bytes) != item.byte_length {
                return Err(error());
            }
            continue;
        }
        total = total.checked_add(item.byte_length).ok_or_else(error)?;
        if total > MAX_TOTAL {
            return Err(error());
        }
        let bytes = read_bound(
            &directory.join("originals").join(&item.sha256),
            item.byte_length,
        )?;
        if bytes.len() != item.byte_length || hash(&bytes) != item.sha256 {
            return Err(error());
        }
        originals.insert(item.sha256.clone(), bytes);
    }
    for item in &report.resources {
        let expected = resource_hash(&item.id).ok_or_else(error)?;
        if item.byte_length > 32 * 1024 * 1024 || resources.contains_key(&item.id) {
            return Err(error());
        }
        total = total.checked_add(item.byte_length).ok_or_else(error)?;
        if total > MAX_TOTAL {
            return Err(error());
        }
        let bytes = read_bound(
            &directory.join("resources").join(&item.id),
            item.byte_length,
        )?;
        if bytes.len() != item.byte_length || hash(&bytes) != expected {
            return Err(error());
        }
        resources.insert(item.id.clone(), bytes);
    }
    let root = report.root_id.as_ref().ok_or_else(error)?;
    if !root.ends_with(".css") || !resources.contains_key(root) {
        return Err(error());
    }
    for (id, bytes) in &resources {
        if !id.ends_with(".css") {
            continue;
        }
        let css = std::str::from_utf8(bytes).map_err(|_| error())?;
        let references = crate::css_references::inspect(css);
        if references.incomplete {
            return Err(error());
        }
        for value in references.references {
            if value.starts_with('#') {
                continue;
            }
            if !resources.contains_key(value.split('#').next().ok_or_else(error)?) {
                return Err(error());
            }
        }
    }
    Ok(Restored {
        manifest,
        originals,
        resources,
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn offline_relocation_and_tampering() {
        let root = std::env::temp_dir().join(format!(
            "easypub-css-bundle-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(root.join("source")).unwrap();
        fs::write(root.join("source/theme"), "p{background:url(image.png)}").unwrap();
        fs::write(root.join("source/image.png"), b"immutable-resource").unwrap();
        let css = "@import 'theme';";
        let base = root.join("source");
        let snapshot = crate::css_resources::collect(css, base.to_str().unwrap());
        let bundle = root.join("bundle");
        let fingerprint = persist(&bundle, css, base.to_str().unwrap(), &snapshot).unwrap();
        assert!(persist(&bundle, css, base.to_str().unwrap(), &snapshot).is_err());
        fs::remove_dir_all(&base).unwrap();
        let moved = root.join("moved");
        fs::rename(&bundle, &moved).unwrap();
        let offline = restore(&moved, &fingerprint).unwrap();
        assert_eq!(offline.manifest.css, css);
        assert_eq!(offline.resources, snapshot.resources);
        assert_eq!(offline.originals, snapshot.bytes);
        let first = offline.resources.keys().next().unwrap();
        fs::write(moved.join("resources").join(first), b"tampered").unwrap();
        assert!(restore(&moved, &fingerprint).is_err());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn resource_identifiers_cannot_escape_bundle() {
        for value in [
            "../secret",
            "..\\secret",
            "/absolute",
            "C:/path",
            "a.css/../x",
        ] {
            assert!(resource_hash(value).is_none());
        }
        assert!(resource_hash(&format!("{}.css", "a".repeat(64))).is_some());
    }
}
