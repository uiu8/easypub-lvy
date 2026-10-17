//! Immutable settings generations. A non-overwriting hard link publishes each
//! complete generation; competing writers cannot replace the same next revision.
use crate::{
    layout_presets::{self, Preset},
    layout_settings::Layers,
};
use easypub_core::{ApiError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::Path,
    sync::atomic::{AtomicU64, Ordering},
};
const MAX_BYTES: u64 = 65536;
pub const MAX_EXPANDED_BYTES: usize = 4 * 1024 * 1024;
const MAX_GENERATIONS: usize = 1024;
static NEXT: AtomicU64 = AtomicU64::new(1);
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Configuration {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rule_defaults: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recognition_defaults: Option<easypub_core::chapter_rules::RuleSet>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub recognition_presets: Vec<easypub_core::chapter_rules::Preset>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub folder_rules: Vec<crate::folder_mapping::Rule>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub favorite_folders: Vec<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub favorite_folder_names: BTreeMap<String, String>,
    /// 自动入库的文件夹（V26，FOLD-080）：其中新出现的书自动导入书库。
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub auto_import_folders: Vec<String>,
    /// 用户从书库移除过的、位于自动入库文件夹中的文件：不再自动导入。
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub auto_import_ignored: Vec<String>,
    #[serde(default)]
    pub cleanup_presets: Vec<crate::cleanup_presets::Preset>,
    #[serde(default)]
    pub layout_defaults: BTreeMap<String, Value>,
    #[serde(default)]
    pub layout_presets: Vec<Preset>,
    #[serde(default)]
    pub output_batches: Vec<Value>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub supplemental_templates: Vec<crate::supplemental_pages::Template>,
    /// Storage-only reference, expanded and cleared before exposing Configuration.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    supplemental_templates_blob: Option<String>,
    // Frontend workspace preferences are persisted with the same immutable
    // generation and token as production defaults. Keep them explicit so
    // deny_unknown_fields still catches accidental schema drift.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ui_theme: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ui_scale: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ui_density: Option<String>,
    /// V69：主题色编号（ink / teal / blue / violet / ochre / rose）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ui_accent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ui_follow_system_scale: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reduced_motion: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub import_recursive: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub import_directory: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub import_skip_existing: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_format: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_directory: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_language: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub automatic_cleanup_rules: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub automatic_cleanup_pipeline: Option<Vec<easypub_core::cleanup_rules::Rule>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_collision_policy: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_naming: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub show_output_acceptance: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attach_conversion_report: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub check_after_import: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub check_before_conversion: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub restore_window: Option<bool>,
    /// V68：启动时检查更新（缺省为开）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub update_check_on_start: Option<bool>,
    /// V68：用户选择“跳过这个版本”的批次号。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub update_skipped_release: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generate_cover: Option<bool>,
    #[serde(default, skip_serializing)]
    pub check_chapters: Option<bool>,
    #[serde(default, skip_serializing)]
    pub check_duplicate_text: Option<bool>,
    #[serde(default, skip_serializing)]
    pub check_title_length: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub backup_before_change: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub backup_directory: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub diagnostic_logging: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kindle_converter: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kfx_converter: Option<String>,
    /// EPUB 原稿的默认转换路径（V27，OUT-080）：layout 使用软件排版，original 保持原格式。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub epub_conversion_mode: Option<String>,
    /// 同时处理的书（V38，SET-069）：auto 按逻辑处理器数决定，或 1 / 2 / 4 / 8 本。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parallel_books: Option<String>,
}
impl Configuration {
    fn retired_check_fields(&self) -> Vec<&'static str> {
        let mut fields = Vec::new();
        if self.check_chapters.is_some() {
            fields.push("check_chapters");
        }
        if self.check_duplicate_text.is_some() {
            fields.push("check_duplicate_text");
        }
        if self.check_title_length.is_some() {
            fields.push("check_title_length");
        }
        fields
    }
    fn validate(&self) -> Result<(), ApiError> {
        if self.supplemental_templates_blob.is_some() {
            return Err(invalid());
        }
        crate::supplemental_pages::validate_templates(&self.supplemental_templates)?;
        if let Some(defaults) = &self.rule_defaults {
            crate::rule_toggles::validate_defaults(defaults)?;
        }
        if let Some(rules) = &self.recognition_defaults {
            rules.compile()?;
        }
        easypub_core::chapter_rules::validate_presets(&self.recognition_presets)?;
        crate::folder_mapping::validate_rules(&self.folder_rules)?;
        if self
            .ui_scale
            .is_some_and(|v| !v.is_finite() || !(0.8..=1.5).contains(&v))
        {
            return Err(error(ErrorCode::InvalidRule, "check_ui_scale"));
        }
        if self
            .ui_density
            .as_deref()
            .is_some_and(|v| !matches!(v, "standard" | "compact"))
        {
            return Err(error(ErrorCode::InvalidRule, "check_ui_density"));
        }
        if self
            .epub_conversion_mode
            .as_deref()
            .is_some_and(|v| !matches!(v, "layout" | "original"))
        {
            return Err(error(ErrorCode::InvalidRule, "check_epub_conversion_mode"));
        }
        if self
            .parallel_books
            .as_deref()
            .is_some_and(|v| !matches!(v, "auto" | "1" | "2" | "4" | "8"))
        {
            return Err(error(ErrorCode::InvalidRule, "check_parallel_books"));
        }
        // Missing directories remain valid favorites so removable drives and
        // moved folders can be shown and repaired without losing their entries.
        if self.favorite_folders.len() > 256
            || self.favorite_folders.iter().any(|path| {
                path.len() > 4096 || path.contains('\0') || !Path::new(path).is_absolute()
            })
        {
            return Err(error(ErrorCode::InvalidRule, "check_favorite_folders"));
        }
        if self.favorite_folder_names.len() > 256
            || self.favorite_folder_names.iter().any(|(path, name)| {
                !Path::new(path).is_absolute()
                    || path.len() > 4096
                    || path.contains('\0')
                    || name.trim().is_empty()
                    || name.len() > 512
                    || name.contains('\0')
            })
        {
            return Err(error(ErrorCode::InvalidRule, "check_favorite_folder_names"));
        }
        let bad_path = |path: &String| {
            path.len() > 4096 || path.contains('\0') || !Path::new(path).is_absolute()
        };
        if self.auto_import_folders.len() > 64 || self.auto_import_folders.iter().any(bad_path) {
            return Err(error(ErrorCode::InvalidRule, "check_auto_import_folders"));
        }
        if self.auto_import_ignored.len() > 16384 || self.auto_import_ignored.iter().any(bad_path) {
            return Err(error(ErrorCode::InvalidRule, "check_auto_import_folders"));
        }
        Layers {
            global: self.layout_defaults.clone(),
            ..Default::default()
        }
        .resolve()?;
        if self
            .ui_theme
            .as_deref()
            .is_some_and(|theme| !matches!(theme, "paper" | "night" | "contrast"))
        {
            return Err(error(ErrorCode::InvalidRule, "check_ui_theme"));
        }
        if self
            .output_format
            .as_deref()
            .is_some_and(|format| !matches!(format, "EPUB" | "AZW3" | "MOBI" | "KFX"))
        {
            return Err(error(ErrorCode::InvalidRule, "check_output_format"));
        }
        if self
            .output_directory
            .as_deref()
            .is_some_and(|path| !path.trim().is_empty() && !Path::new(path).is_absolute())
        {
            return Err(error(ErrorCode::InvalidRule, "check_output_directory"));
        }
        if self
            .import_directory
            .as_deref()
            .is_some_and(|path| !path.trim().is_empty() && !Path::new(path).is_absolute())
        {
            return Err(error(ErrorCode::InvalidRule, "check_import_directory"));
        }
        if self
            .backup_directory
            .as_deref()
            .is_some_and(|path| !path.trim().is_empty() && !Path::new(path).is_absolute())
        {
            return Err(error(ErrorCode::InvalidRule, "check_backup_directory"));
        }
        if self
            .output_collision_policy
            .as_deref()
            .is_some_and(|value| !matches!(value, "preserve" | "ask"))
        {
            return Err(error(
                ErrorCode::InvalidRule,
                "check_output_collision_policy",
            ));
        }
        if self
            .output_naming
            .as_deref()
            .is_some_and(|value| !matches!(value, "title_author" | "title" | "filename"))
        {
            return Err(error(ErrorCode::InvalidRule, "check_output_naming"));
        }
        if self
            .kindle_converter
            .as_deref()
            .is_some_and(|path| !path.trim().is_empty() && !Path::new(path).is_absolute())
        {
            return Err(error(ErrorCode::InvalidRule, "check_kindle_converter"));
        }
        if self
            .kfx_converter
            .as_deref()
            .is_some_and(|path| !path.trim().is_empty() && !Path::new(path).is_absolute())
        {
            return Err(error(ErrorCode::InvalidRule, "check_kfx_converter"));
        }
        if let Some(pipeline) = &self.automatic_cleanup_pipeline
            && !pipeline.is_empty()
        {
            easypub_core::cleanup_rules::validate_pipeline(pipeline)?;
        }
        crate::cleanup_presets::validate(&self.cleanup_presets)?;
        layout_presets::validate(&self.layout_presets)
    }
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Record {
    schema: u32,
    revision: u64,
    parent: Option<String>,
    configuration: Configuration,
}
#[derive(Debug, Serialize)]
pub struct Snapshot {
    pub retired_check_fields: Vec<&'static str>,
    pub revision: u64,
    pub token: Option<String>,
    pub configuration: Configuration,
}
fn error(code: ErrorCode, action: &str) -> ApiError {
    ApiError::new(code, "settings_store", action)
}
fn io(_: std::io::Error) -> ApiError {
    error(ErrorCode::Io, "check_settings_directory")
}
fn invalid() -> ApiError {
    error(ErrorCode::InvalidRule, "inspect_settings_history")
}
fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn read(path: &Path) -> Result<Vec<u8>, ApiError> {
    let mut bytes = Vec::new();
    File::open(path)
        .map_err(io)?
        .take(MAX_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(io)?;
    if bytes.len() as u64 > MAX_BYTES {
        return Err(error(ErrorCode::TooLarge, "reduce_settings_size"));
    }
    Ok(bytes)
}
fn filename(revision: u64) -> String {
    format!("{revision:020}.json")
}
fn batch_bytes(path: &Path, expected: &str) -> Result<Vec<u8>, ApiError> {
    let mut bytes = Vec::new();
    File::open(path)
        .map_err(io)?
        .take(MAX_EXPANDED_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(io)?;
    if bytes.len() > MAX_EXPANDED_BYTES || hash(&bytes) != expected {
        return Err(invalid());
    }
    Ok(bytes)
}
fn expand_batches(directory: &Path, configuration: &mut Configuration) -> Result<(), ApiError> {
    if let Some(digest) = configuration.supplemental_templates_blob.take() {
        if !configuration.supplemental_templates.is_empty()
            || digest.len() != 64
            || !digest.bytes().all(|c| c.is_ascii_hexdigit())
        {
            return Err(invalid());
        }
        let bytes = batch_bytes(
            &directory
                .join("template-records")
                .join(format!("{digest}.json")),
            &digest,
        )?;
        configuration.supplemental_templates =
            serde_json::from_slice(&bytes).map_err(|_| invalid())?;
    }
    let mut total = 0usize;
    for batch in &mut configuration.output_batches {
        if let Some(reference) = batch.get("$batch_blob") {
            let digest = reference.as_str().ok_or_else(invalid)?;
            if batch.as_object().map(|m| m.len()) != Some(1)
                || digest.len() != 64
                || !digest.bytes().all(|c| c.is_ascii_hexdigit())
            {
                return Err(invalid());
            }
            let bytes = batch_bytes(
                &directory
                    .join("batch-records")
                    .join(format!("{digest}.json")),
                digest,
            )?;
            total = total.checked_add(bytes.len()).ok_or_else(invalid)?;
            if total > MAX_EXPANDED_BYTES {
                return Err(error(ErrorCode::TooLarge, "reduce_batch_history_size"));
            }
            *batch = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
            if batch.get("$batch_blob").is_some() {
                return Err(invalid());
            }
        }
    }
    if serde_json::to_vec(configuration)
        .map_err(|_| invalid())?
        .len()
        > MAX_EXPANDED_BYTES
    {
        return Err(error(ErrorCode::TooLarge, "reduce_batch_history_size"));
    }
    Ok(())
}
fn externalize_batches(
    directory: &Path,
    configuration: &mut Configuration,
) -> Result<(), ApiError> {
    if configuration.output_batches.len() > 128
        || serde_json::to_vec(configuration)
            .map_err(|_| invalid())?
            .len()
            > MAX_EXPANDED_BYTES
    {
        return Err(error(ErrorCode::TooLarge, "reduce_batch_history_size"));
    }
    for batch in &mut configuration.output_batches {
        if batch.get("$batch_blob").is_some() {
            return Err(invalid());
        }
        let bytes = serde_json::to_vec(batch).map_err(|_| invalid())?;
        let digest = store_blob(&directory.join("batch-records"), &bytes)?;
        *batch = serde_json::json!({"$batch_blob": digest});
    }
    if !configuration.supplemental_templates.is_empty() {
        let bytes =
            serde_json::to_vec(&configuration.supplemental_templates).map_err(|_| invalid())?;
        configuration.supplemental_templates_blob =
            Some(store_blob(&directory.join("template-records"), &bytes)?);
        configuration.supplemental_templates.clear();
    }
    Ok(())
}
fn store_blob(objects: &Path, bytes: &[u8]) -> Result<String, ApiError> {
    let digest = hash(bytes);
    fs::create_dir_all(objects).map_err(io)?;
    let destination = objects.join(format!("{digest}.json"));
    if destination.exists() {
        batch_bytes(&destination, &digest)?;
    } else {
        let temporary = objects.join(format!(
            ".batch-{}-{}.tmp",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let mut owned = false;
        let result = (|| {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temporary)
                .map_err(io)?;
            owned = true;
            file.write_all(bytes).map_err(io)?;
            file.sync_all().map_err(io)?;
            drop(file);
            match fs::hard_link(&temporary, &destination) {
                Ok(()) => Ok(()),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                    batch_bytes(&destination, &digest).map(|_| ())
                }
                Err(e) => Err(io(e)),
            }
        })();
        if owned {
            let _ = fs::remove_file(&temporary);
        }
        result?;
    }
    Ok(digest)
}
pub fn load(directory: &Path) -> Result<Snapshot, ApiError> {
    if !directory.is_absolute() {
        return Err(invalid());
    }
    let entries = match fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Ok(Snapshot {
                retired_check_fields: Vec::new(),
                revision: 0,
                token: None,
                configuration: Configuration::default(),
            });
        }
        Err(e) => return Err(io(e)),
    };
    let mut revisions = Vec::new();
    for entry in entries {
        let entry = entry.map_err(io)?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.len() == 25
            && name.ends_with(".json")
            && name.as_bytes()[..20].iter().all(u8::is_ascii_digit)
        {
            revisions.push(name[..20].parse::<u64>().map_err(|_| invalid())?);
            if revisions.len() > MAX_GENERATIONS {
                return Err(error(ErrorCode::TooLarge, "archive_settings_history"));
            }
        }
    }
    revisions.sort_unstable();
    for (index, revision) in revisions.iter().enumerate() {
        if *revision != index as u64 + 1 {
            return Err(invalid());
        }
    }
    let Some(&revision) = revisions.last() else {
        return Ok(Snapshot {
            retired_check_fields: Vec::new(),
            revision: 0,
            token: None,
            configuration: Configuration::default(),
        });
    };
    let bytes = read(&directory.join(filename(revision)))?;
    let mut record: Record = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
    if record.schema != 1 || record.revision != revision {
        return Err(invalid());
    }
    let expected_parent = if revision > 1 {
        Some(hash(&read(&directory.join(filename(revision - 1)))?))
    } else {
        None
    };
    if record.parent != expected_parent {
        return Err(invalid());
    }
    expand_batches(directory, &mut record.configuration)?;
    record.configuration.validate()?;
    Ok(Snapshot {
        retired_check_fields: record.configuration.retired_check_fields(),
        revision,
        token: Some(hash(&bytes)),
        configuration: record.configuration,
    })
}
pub fn save(
    directory: &Path,
    expected: Option<&str>,
    configuration: Configuration,
) -> Result<Snapshot, ApiError> {
    configuration.validate()?;
    let current = load(directory)?;
    if expected != current.token.as_deref() {
        return Err(error(
            ErrorCode::StaleRevision,
            "reload_settings_before_saving",
        ));
    }
    if current.revision >= MAX_GENERATIONS as u64 {
        return Err(error(ErrorCode::TooLarge, "archive_settings_history"));
    }
    let revision = current.revision + 1;
    let mut stored = configuration.clone();
    externalize_batches(directory, &mut stored)?;
    let record = Record {
        schema: 1,
        revision,
        parent: current.token,
        configuration: stored,
    };
    let bytes = serde_json::to_vec(&record).map_err(|_| invalid())?;
    if bytes.len() as u64 > MAX_BYTES {
        return Err(error(ErrorCode::TooLarge, "reduce_settings_size"));
    }
    fs::create_dir_all(directory).map_err(io)?;
    let (stage, mut file) = loop {
        let path = directory.join(format!(
            ".settings-{}-{}.tmp",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(file) => break (path, file),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(io(e)),
        }
    };
    let result = (|| {
        file.write_all(&bytes).map_err(io)?;
        file.sync_all().map_err(io)?;
        drop(file);
        fs::hard_link(&stage, directory.join(filename(revision))).map_err(|e| {
            if e.kind() == std::io::ErrorKind::AlreadyExists {
                error(ErrorCode::StaleRevision, "reload_settings_before_saving")
            } else {
                io(e)
            }
        })?;
        Ok(Snapshot {
            retired_check_fields: configuration.retired_check_fields(),
            revision,
            token: Some(hash(&bytes)),
            configuration,
        })
    })();
    // Only the temporary file created by this invocation is removed.
    let _ = fs::remove_file(stage);
    result
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Barrier};
    #[test]
    fn folder_rules_persist_offline_and_stale_or_invalid_writes_keep_previous() {
        let dir = directory();
        let mut configuration = config(18);
        configuration.folder_rules = serde_json::from_value(serde_json::json!([{
            "folder":dir.join("offline"),"fields":{"publisher":{"op":"set","value":"publisher"}}
        }]))
        .unwrap();
        let first = save(&dir, None, configuration.clone()).unwrap();
        assert_eq!(
            load(&dir).unwrap().configuration.folder_rules[0].folder,
            dir.join("offline").to_str().unwrap()
        );
        assert!(save(&dir, None, configuration.clone()).is_err());
        configuration.folder_rules[0].folder = "relative".into();
        assert!(save(&dir, first.token.as_deref(), configuration).is_err());
        assert_eq!(load(&dir).unwrap().token, first.token);
    }

    #[test]
    fn large_batch_history_is_deduplicated_and_verified_without_enlarging_settings() {
        let dir = directory();
        let mut configuration = config(20);
        configuration.output_batches = (0..128)
            .map(|i| serde_json::json!({"batch_id": i.to_string(), "detail": "x".repeat(1024)}))
            .collect();
        let first = save(&dir, None, configuration.clone()).unwrap();
        let original = fs::read(dir.join(filename(1))).unwrap();
        assert!(original.len() < MAX_BYTES as usize);
        assert_eq!(
            load(&dir).unwrap().configuration.output_batches,
            configuration.output_batches
        );
        let objects = dir.join("batch-records");
        assert_eq!(fs::read_dir(&objects).unwrap().count(), 128);
        let second = save(&dir, first.token.as_deref(), configuration.clone()).unwrap();
        assert_eq!(fs::read_dir(&objects).unwrap().count(), 128);
        assert_eq!(fs::read(dir.join(filename(1))).unwrap(), original);
        assert!(save(&dir, first.token.as_deref(), configuration.clone()).is_err());
        let mut oversized = configuration.clone();
        oversized.output_batches = vec![Value::String("x".repeat(MAX_EXPANDED_BYTES))];
        assert!(save(&dir, second.token.as_deref(), oversized).is_err());
        assert_eq!(load(&dir).unwrap().token, second.token);
        let object = fs::read_dir(objects)
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        fs::write(object, b"corrupt").unwrap();
        assert!(load(&dir).is_err());
    }

    #[test]
    fn inline_legacy_batches_survive_first_externalized_save() {
        let dir = directory();
        fs::create_dir_all(&dir).unwrap();
        let mut configuration = config(18);
        configuration.output_batches =
            vec![serde_json::json!({"batch_id":"legacy", "state":"complete"})];
        let bytes = serde_json::to_vec(&Record {
            schema: 1,
            revision: 1,
            parent: None,
            configuration: configuration.clone(),
        })
        .unwrap();
        fs::write(dir.join(filename(1)), &bytes).unwrap();
        let old = load(&dir).unwrap();
        let new = save(&dir, old.token.as_deref(), old.configuration).unwrap();
        assert_eq!(
            new.configuration.output_batches,
            configuration.output_batches
        );
        assert_eq!(
            load(&dir).unwrap().configuration.output_batches,
            configuration.output_batches
        );
        assert_eq!(fs::read(dir.join(filename(1))).unwrap(), bytes);
    }
    /// V26（FOLD-080）：自动入库文件夹与忽略列表可往返；相对路径被拒绝；旧设置没有这两项也能读。
    #[test]
    fn auto_import_folders_roundtrip_and_reject_relative_paths() {
        let dir = directory();
        let folder = dir.join("自动入库").to_string_lossy().into_owned();
        let removed = dir
            .join("自动入库")
            .join("甲.txt")
            .to_string_lossy()
            .into_owned();
        let first = save(
            &dir,
            None,
            Configuration {
                auto_import_folders: vec![folder.clone()],
                auto_import_ignored: vec![removed.clone()],
                ..Default::default()
            },
        )
        .unwrap();
        let loaded = load(&dir).unwrap().configuration;
        assert_eq!(loaded.auto_import_folders, vec![folder]);
        assert_eq!(loaded.auto_import_ignored, vec![removed]);
        let relative = Configuration {
            auto_import_folders: vec!["相对/路径".into()],
            ..Default::default()
        };
        assert!(save(&dir, first.token.as_deref(), relative).is_err());
        let empty = serde_json::to_value(Configuration::default()).unwrap();
        assert!(empty.get("auto_import_folders").is_none());
        // V27：EPUB 默认转换路径只接受 layout / original。
        let mode = Configuration {
            epub_conversion_mode: Some("original".into()),
            ..Default::default()
        };
        let saved = save(&dir, load(&dir).unwrap().token.as_deref(), mode).unwrap();
        assert_eq!(
            load(&dir)
                .unwrap()
                .configuration
                .epub_conversion_mode
                .as_deref(),
            Some("original")
        );
        let bad = Configuration {
            epub_conversion_mode: Some("其他".into()),
            ..Default::default()
        };
        assert!(save(&dir, saved.token.as_deref(), bad).is_err());
        // V38：同时处理的书只接受 auto / 1 / 2 / 4 / 8。
        let books = Configuration {
            parallel_books: Some("4".into()),
            ..Default::default()
        };
        let saved = save(&dir, load(&dir).unwrap().token.as_deref(), books).unwrap();
        assert_eq!(
            load(&dir).unwrap().configuration.parallel_books.as_deref(),
            Some("4")
        );
        for value in ["3", "16", "0", "自动"] {
            let bad = Configuration {
                parallel_books: Some(value.into()),
                ..Default::default()
            };
            assert!(save(&dir, saved.token.as_deref(), bad).is_err(), "{value}");
        }
    }

    #[test]
    fn favorites_roundtrip_preserves_missing_paths_and_rejects_invalid_save() {
        let dir = directory();
        let folder = dir
            .join("missing-book-folder")
            .to_string_lossy()
            .into_owned();
        let first = save(
            &dir,
            None,
            Configuration {
                favorite_folders: vec![folder.clone()],
                favorite_folder_names: BTreeMap::from([(folder.clone(), "待制作书稿".into())]),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(
            load(&dir).unwrap().configuration.favorite_folders,
            vec![folder.clone()]
        );
        assert_eq!(
            load(&dir).unwrap().configuration.favorite_folder_names[&folder],
            "待制作书稿"
        );
        let invalid_name = Configuration {
            favorite_folder_names: BTreeMap::from([(folder, " ".into())]),
            ..Default::default()
        };
        assert!(save(&dir, first.token.as_deref(), invalid_name).is_err());
        assert!(
            save(
                &dir,
                first.token.as_deref(),
                Configuration {
                    favorite_folders: vec!["relative-folder".into()],
                    ..Default::default()
                }
            )
            .is_err()
        );
        assert_eq!(load(&dir).unwrap().token, first.token);
        let empty = save(&dir, first.token.as_deref(), Configuration::default()).unwrap();
        assert!(
            load(&dir)
                .unwrap()
                .configuration
                .favorite_folders
                .is_empty()
        );
        assert_eq!(load(&dir).unwrap().token, empty.token);
        fs::remove_dir_all(dir).unwrap();
    }
    fn directory() -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "easypub-settings-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }
    fn config(size: u32) -> Configuration {
        Configuration {
            favorite_folders: vec![],
            favorite_folder_names: BTreeMap::new(),
            layout_defaults: BTreeMap::from([("font_size".into(), Value::from(size))]),
            layout_presets: vec![],
            cleanup_presets: vec![],
            output_batches: vec![],
            ..Default::default()
        }
    }
    #[test]
    fn frontend_preferences_roundtrip_with_immutable_generation() {
        let dir = directory();
        let mut configuration = config(20);
        configuration.ui_theme = Some("night".into());
        configuration.reduced_motion = Some(true);
        configuration.import_recursive = Some(true);
        configuration.import_directory = Some(r"D:\书稿\待制作".into());
        configuration.output_format = Some("AZW3".into());
        configuration.output_directory = Some(r"D:\书稿\成品".into());
        configuration.diagnostic_logging = Some(true);
        configuration.output_collision_policy = Some("ask".into());
        configuration.output_naming = Some("title_author".into());
        configuration.show_output_acceptance = Some(true);
        configuration.attach_conversion_report = Some(true);
        let saved = save(&dir, None, configuration).unwrap();
        let loaded = load(&dir).unwrap();
        assert_eq!(loaded.token, saved.token);
        assert_eq!(loaded.configuration.ui_theme.as_deref(), Some("night"));
        assert_eq!(loaded.configuration.reduced_motion, Some(true));
        assert_eq!(loaded.configuration.import_recursive, Some(true));
        assert_eq!(
            loaded.configuration.import_directory.as_deref(),
            Some(r"D:\书稿\待制作")
        );
        assert_eq!(loaded.configuration.output_format.as_deref(), Some("AZW3"));
        assert_eq!(
            loaded.configuration.output_directory.as_deref(),
            Some(r"D:\书稿\成品")
        );
        assert_eq!(loaded.configuration.diagnostic_logging, Some(true));
        assert_eq!(
            loaded.configuration.output_collision_policy.as_deref(),
            Some("ask")
        );
        assert_eq!(
            loaded.configuration.output_naming.as_deref(),
            Some("title_author")
        );
        assert_eq!(loaded.configuration.show_output_acceptance, Some(true));
        assert_eq!(loaded.configuration.attach_conversion_report, Some(true));
        let mut invalid = config(20);
        invalid.output_format = Some("PDF".into());
        assert_eq!(
            save(&dir, saved.token.as_deref(), invalid)
                .unwrap_err()
                .code,
            ErrorCode::InvalidRule
        );
        let mut invalid_policy = config(20);
        invalid_policy.output_collision_policy = Some("delete".into());
        assert_eq!(
            save(&dir, saved.token.as_deref(), invalid_policy)
                .unwrap_err()
                .code,
            ErrorCode::InvalidRule
        );
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn stale_writers_and_incomplete_stages_do_not_overwrite_history() {
        let dir = directory();
        assert_eq!(load(&dir).unwrap().revision, 0);
        let first = save(&dir, None, config(20)).unwrap();
        let original = fs::read(dir.join(filename(1))).unwrap();
        fs::write(dir.join(".settings-crashed.tmp"), b"half written").unwrap();
        assert_eq!(load(&dir).unwrap().token, first.token);
        let second = save(&dir, first.token.as_deref(), config(22)).unwrap();
        assert_eq!(
            save(&dir, first.token.as_deref(), config(24))
                .unwrap_err()
                .code,
            ErrorCode::StaleRevision
        );
        assert_eq!(fs::read(dir.join(filename(1))).unwrap(), original);
        assert_eq!(load(&dir).unwrap().token, second.token);
        // Recovery is a new revision, never destructive replacement.
        let recovered = save(&dir, second.token.as_deref(), first.configuration).unwrap();
        assert_eq!(recovered.revision, 3);
        assert_eq!(recovered.configuration.layout_defaults["font_size"], 20);
        fs::write(dir.join(filename(3)), b"broken").unwrap();
        assert!(load(&dir).is_err());
    }
    #[test]
    fn concurrent_first_save_has_exactly_one_winner() {
        let dir = directory();
        let barrier = Arc::new(Barrier::new(2));
        let threads: Vec<_> = [20, 24]
            .into_iter()
            .map(|size| {
                let dir = dir.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    save(&dir, None, config(size))
                })
            })
            .collect();
        let results: Vec<_> = threads.into_iter().map(|t| t.join().unwrap()).collect();
        assert_eq!(results.iter().filter(|r| r.is_ok()).count(), 1);
        assert_eq!(load(&dir).unwrap().revision, 1);
    }
}

#[cfg(test)]
mod retired_check_fields_tests {
    use super::*;
    #[test]
    fn old_checks_load_without_rewriting_history_and_disappear_on_next_save() {
        let dir = std::env::temp_dir().join(format!(
            "easypub-retired-checks-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&dir).unwrap();
        let old = serde_json::json!({"schema":1,"revision":1,"parent":null,"configuration":{
            "check_chapters":false,"check_duplicate_text":true,"check_title_length":false,
            "check_after_import":true,"automatic_cleanup_pipeline":[],"ui_theme":"night"
        }});
        let bytes = serde_json::to_vec(&old).unwrap();
        fs::write(dir.join(filename(1)), &bytes).unwrap();
        let loaded = load(&dir).unwrap();
        assert_eq!(loaded.retired_check_fields.len(), 3);
        let exposed = serde_json::to_value(&loaded).unwrap();
        for key in &loaded.retired_check_fields {
            assert!(exposed["configuration"].get(key).is_none());
        }
        let next = save(&dir, loaded.token.as_deref(), loaded.configuration).unwrap();
        assert_eq!(fs::read(dir.join(filename(1))).unwrap(), bytes);
        let reopened = load(&dir).unwrap();
        assert_eq!(reopened.token, next.token);
        assert!(reopened.retired_check_fields.is_empty());
        assert_eq!(reopened.configuration.ui_theme.as_deref(), Some("night"));
        assert_eq!(reopened.configuration.check_after_import, Some(true));
        assert_eq!(
            reopened.configuration.automatic_cleanup_pipeline,
            Some(vec![])
        );
    }
}
