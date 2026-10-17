//! Immutable export observations. A loaded record is not a new validation of
//! the output file, nor permission to resume a converter automatically.
use base64::Engine;
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

const MAX_BYTES: u64 = 64 * 1024;

/// A bounded display-only snapshot of the requested cover, not output acceptance.
pub fn cover_thumbnail(path: &str, crop: Option<&crate::assets::Crop>) -> Result<String, ApiError> {
    let source = crate::assets::display_snapshot(path)?;
    let source = if let Some(crop) = crop {
        crate::assets::cropped(&source, crop)?
    } else {
        source
    };
    let decoded = image::load_from_memory(&source.bytes).map_err(|_| invalid())?;
    for (width, height) in [(174, 252), (116, 168), (87, 126)] {
        let thumbnail = decoded.thumbnail(width, height).to_rgb8();
        let mut bytes = Vec::new();
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut bytes, 75)
            .encode_image(&thumbnail)
            .map_err(|_| invalid())?;
        if bytes.len() <= 12 * 1024 {
            return Ok(base64::engine::general_purpose::STANDARD.encode(bytes));
        }
    }
    Err(invalid())
}

/// Read-only comparison with the immutable export receipt. This does not
/// certify reader compatibility or publish a staged transaction.
pub fn verify(directory: &Path, task_id: &str) -> Result<Value, ApiError> {
    let record = load(directory)?
        .into_iter()
        .find(|r| r.task_id == task_id)
        .ok_or_else(invalid)?;
    let Some(receipt) = record.receipt.as_ref() else {
        return inspect_interrupted(&record);
    };
    let expected = receipt["transaction"]["output_sha256"]
        .as_str()
        .ok_or_else(invalid)?;
    if expected.len() != 64 || !expected.bytes().all(|c| c.is_ascii_hexdigit()) {
        return Err(invalid());
    }
    let path = receipt["output_path"].as_str().ok_or_else(invalid)?;
    let mut file = match File::open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Ok(serde_json::json!({"status":"missing"}));
        }
        Err(e) => return Err(io(e)),
    };
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 65536];
    loop {
        let count = file.read(&mut buffer).map_err(io)?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
    }
    let actual = format!("{:x}", hash.finalize());
    Ok(
        serde_json::json!({"status": if actual == expected {"matches"} else {"changed"}, "sha256": actual}),
    )
}

/// Inspect only actual receipt-bound exports; no draft resources are used.
pub fn inspect_package(directory: &Path, task_id: &str) -> Result<Value, ApiError> {
    let record = load(directory)?
        .into_iter()
        .find(|r| r.task_id == task_id)
        .ok_or_else(invalid)?;
    let receipt = record.receipt.as_ref().ok_or_else(invalid)?;
    let path = receipt["output_path"].as_str().ok_or_else(invalid)?;
    let expected = receipt["transaction"]["output_sha256"]
        .as_str()
        .ok_or_else(invalid)?;
    let extension = Path::new(path)
        .extension()
        .and_then(|v| v.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    if extension == "azw3" || extension == "mobi" {
        return Ok(
            match inspect_kindle(
                Path::new(path),
                expected,
                extension == "mobi",
                receipt.get("expected_metadata"),
            ) {
                Ok(mut value) => {
                    compare_metadata(&mut value, receipt.get("expected_metadata"));
                    value
                }
                Err(detail) => serde_json::json!({"status":"failed", "detail":detail}),
            },
        );
    }
    if extension == "kfx" {
        let unchanged = verify(directory, task_id)?;
        if unchanged["status"] != "matches" {
            return Ok(unchanged);
        }
        let mut header = vec![0; 18];
        let mut file = File::open(path).map_err(io)?;
        let size = file.metadata().map_err(io)?.len();
        if size > 512 * 1024 * 1024 {
            return Err(invalid());
        }
        file.read_exact(&mut header).map_err(io)?;
        let valid = header.get(..4) == Some(b"CONT".as_slice());
        return Ok(
            serde_json::json!({"status":if valid { "kfx_container_checked" } else { "failed" },
            "format":"KFX", "detail":"回执哈希与KFX标识核对；导出时由Bokai校验与EPUB的一致性，不代表Kindle真机验收。",
            "byte_length":size, "sha256":expected}),
        );
    }
    if extension != "epub" {
        return Ok(serde_json::json!({"status":"unsupported", "detail":"该格式尚无独立成品检查"}));
    }
    Ok(
        match crate::output_package::inspect(Path::new(path), expected) {
            Ok(mut value) => {
                compare_metadata(&mut value, receipt.get("expected_metadata"));
                value
            }
            Err(detail) => serde_json::json!({"status":"failed", "detail":detail}),
        },
    )
}

fn inspect_kindle(
    path: &Path,
    expected: &str,
    dual: bool,
    _expected_metadata: Option<&Value>,
) -> Result<Value, String> {
    const LIMIT: u64 = 512 * 1024 * 1024;
    let file = File::open(path).map_err(|_| "无法读取成品文件")?;
    let metadata = file.metadata().map_err(|_| "无法读取成品大小")?;
    if !metadata.is_file() || metadata.len() > LIMIT {
        return Err("成品不是普通文件或超过512MiB检查上限".into());
    }
    let mut bytes = Vec::new();
    file.take(LIMIT + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "读取成品失败")?;
    if bytes.len() as u64 > LIMIT {
        return Err("成品超过512MiB检查上限".into());
    }
    let hash = format!("{:x}", Sha256::digest(&bytes));
    if hash != expected {
        return Err("成品与导出回执哈希不一致，请勿使用旧检查结果".into());
    }
    let records = crate::kindle_metadata::inspect_container(&bytes, dual)
        .map_err(|_| "Kindle容器记录边界或格式头无效")?;
    let details = crate::kindle_metadata::inspect_details(&bytes, dual)
        .map_err(|_| "Kindle EXTH 元信息无效")?;
    if file_hash(path).map_err(|_| "检查期间无法重新读取成品")? != hash {
        return Err("成品在检查期间发生变化，请重新检查".into());
    }
    let title = details.title.unwrap_or_default();
    let author = details.author.unwrap_or_default();
    let language = details.language.unwrap_or_default();
    Ok(serde_json::json!({
        "status":"kindle_container_checked", "record_count":records,
        "sha256":hash,
        "title":title, "author":author, "language":language,
        "cover_metadata_present":details.cover_metadata_present,
        "detail":format!("已核对回执哈希、{records}个Palm记录边界和{}格式头；章节、正文、元信息和封面内容仍待核验，不代表Kindle真机验收。", if dual {"KF6/KF8"} else {"KF8"})
    }))
}

// Compare only receipt-bound values, never the mutable current book settings.
fn compare_metadata(actual: &mut Value, expected: Option<&Value>) {
    let fields = ["title", "author", "language"];
    let Some(expected) = expected else {
        actual["metadata_status"] = serde_json::json!("unavailable");
        return;
    };
    if fields.iter().any(|key| expected[*key].as_str().is_none()) {
        actual["metadata_status"] = serde_json::json!("invalid");
        return;
    }
    let mismatched: Vec<_> = fields
        .iter()
        .filter(|key| actual[**key] != expected[**key])
        .copied()
        .collect();
    actual["metadata_status"] = serde_json::json!(if mismatched.is_empty() {
        "matches"
    } else {
        "mismatch"
    });
    actual["metadata_mismatches"] = serde_json::json!(mismatched);
    actual["expected_metadata"] = expected.clone();
}

fn file_hash(path: &Path) -> Result<String, ApiError> {
    let mut file = File::open(path).map_err(io)?;
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 65536];
    loop {
        let count = file.read(&mut buffer).map_err(io)?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
    }
    Ok(format!("{:x}", hash.finalize()))
}

fn inspect_interrupted(record: &Record) -> Result<Value, ApiError> {
    let output = Path::new(&record.output_path);
    let parent = output.parent().ok_or_else(invalid)?;
    let filename = output
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or_else(invalid)?;
    let directory = parent.join(format!(".{filename}.easypub-txn"));
    let manifest_path = directory.join("manifest.json");
    if !manifest_path.exists() {
        return Ok(serde_json::json!({"status":"no_receipt"}));
    }
    let mut bytes = Vec::new();
    File::open(&manifest_path)
        .map_err(io)?
        .take(MAX_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(io)?;
    if bytes.len() as u64 > MAX_BYTES {
        return Err(invalid());
    }
    let manifest: crate::transaction::TransactionManifest =
        serde_json::from_slice(&bytes).map_err(|_| invalid())?;
    let manifest_output = Path::new(&manifest.output_path);
    if manifest.schema != 1
        || manifest.source_sha256 != record.source_id
        || manifest_output.file_name() != output.file_name()
        || manifest_output
            .parent()
            .ok_or_else(invalid)?
            .canonicalize()
            .map_err(io)?
            != parent.canonicalize().map_err(io)?
    {
        return Err(invalid());
    }
    let expected = manifest.output_sha256.as_deref().ok_or_else(invalid)?;
    let evidence = manifest.evidence_sha256.as_deref().ok_or_else(invalid)?;
    if file_hash(&directory.join("source-backup.bin"))? != manifest.source_sha256
        || file_hash(&directory.join("edit-evidence.json"))? != evidence
    {
        return Ok(serde_json::json!({"status":"evidence_changed"}));
    }
    if file_hash(Path::new(&manifest.source_path))? != manifest.source_sha256 {
        return Ok(serde_json::json!({"status":"source_changed"}));
    }
    let (candidate, complete) = if output.exists() {
        (output.to_path_buf(), true)
    } else {
        (directory.join("staged").join(filename), false)
    };
    if !candidate.exists() {
        return Ok(serde_json::json!({"status":"missing"}));
    }
    if file_hash(&candidate)? != expected {
        return Ok(serde_json::json!({"status":"changed"}));
    }
    Ok(
        serde_json::json!({"status": if complete {"published_without_receipt"} else {"staged_verified"}}),
    )
}
const MAX_RECORDS: usize = 8192;

pub fn recovery_preview(directory: &Path, task_id: &str) -> Result<Value, ApiError> {
    let record = load(directory)?
        .into_iter()
        .find(|r| r.task_id == task_id)
        .ok_or_else(invalid)?;
    if record.finished_at.is_some() || record.receipt.is_some() {
        return Err(invalid());
    }
    let inspection = inspect_interrupted(&record)?;
    if !matches!(
        inspection["status"].as_str(),
        Some("staged_verified" | "published_without_receipt")
    ) {
        return Err(invalid());
    }
    let output = Path::new(&record.output_path);
    let transaction = output.parent().ok_or_else(invalid)?.join(format!(
        ".{}.easypub-txn",
        output
            .file_name()
            .and_then(|s| s.to_str())
            .ok_or_else(invalid)?
    ));
    let mut hash = Sha256::new();
    hash.update(serde_json::to_vec(&record).map_err(|_| invalid())?);
    hash.update(file_hash(&transaction.join("manifest.json"))?);
    hash.update(inspection.to_string());
    Ok(
        serde_json::json!({"token":format!("{:x}",hash.finalize()), "status":inspection["status"],
        "output_path":record.output_path, "transaction_dir":transaction}),
    )
}

pub fn recover_output(
    directory: &Path,
    task_id: &str,
    token: &str,
    confirmed: bool,
) -> Result<Value, ApiError> {
    if !confirmed {
        return Err(invalid());
    }
    let preview = recovery_preview(directory, task_id)?;
    if preview["token"].as_str() != Some(token) {
        return Err(invalid());
    }
    let transaction = Path::new(preview["transaction_dir"].as_str().ok_or_else(invalid)?);
    let report = crate::transaction::recover_checked(transaction, || {
        let checked = recovery_preview(directory, task_id)?;
        if checked["token"].as_str() != Some(token) {
            return Err(invalid());
        }
        Ok(())
    })?;
    Ok(
        serde_json::json!({"committed":true,"output_path":preview["output_path"],"transaction":report}),
    )
}
static NEXT: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Record {
    pub schema: u32,
    pub task_id: String,
    pub sequence: u64,
    pub book_id: String,
    pub title: String,
    pub source_id: String,
    pub source_revision: u64,
    pub format: String,
    pub output_path: String,
    pub started_at: String,
    pub finished_at: Option<String>,
    pub phase: String,
    pub detail: String,
    pub receipt: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub batch_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub batch_index: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub batch_total: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checks_enabled: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_thumbnail: Option<String>,
}
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "output_history",
        "inspect_output_history",
    )
}
fn io(_: std::io::Error) -> ApiError {
    ApiError::new(
        ErrorCode::Io,
        "output_history",
        "check_output_history_directory",
    )
}
fn validate(record: &Record) -> Result<(), ApiError> {
    if let Some(encoded) = &record.cover_thumbnail {
        if encoded.len() > 16 * 1024 {
            return Err(invalid());
        }
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .map_err(|_| invalid())?;
        let reader = image::ImageReader::new(std::io::Cursor::new(bytes))
            .with_guessed_format()
            .map_err(|_| invalid())?;
        if reader.format() != Some(image::ImageFormat::Jpeg) {
            return Err(invalid());
        }
        let (width, height) = reader.into_dimensions().map_err(|_| invalid())?;
        if width == 0 || height == 0 || width > 174 || height > 252 {
            return Err(invalid());
        }
    }
    let batch_fields_are_complete = match (
        record.batch_id.as_deref(),
        record.batch_index,
        record.batch_total,
    ) {
        (None, None, None) => true,
        (Some(id), Some(index), Some(total)) => {
            !id.is_empty()
                && id.len() <= 80
                && id.bytes().all(|c| c.is_ascii_hexdigit() || c == b'-')
                && total > 0
                && total <= 128
                && index < total
        }
        _ => false,
    };
    if record.schema != 1
        || record.sequence == 0
        || record.task_id.is_empty()
        || record.task_id.len() > 80
        || !record
            .task_id
            .bytes()
            .all(|c| c.is_ascii_hexdigit() || c == b'-')
        || !matches!(record.format.as_str(), "EPUB" | "AZW3" | "MOBI" | "KFX")
        || !matches!(
            record.phase.as_str(),
            "preparing"
                | "prepared"
                | "converting"
                | "checking"
                | "publishing"
                | "complete"
                | "failed"
                | "cancelled"
        )
        || !batch_fields_are_complete
        || record.finished_at.is_some()
            != matches!(record.phase.as_str(), "complete" | "failed" | "cancelled")
    {
        return Err(invalid());
    }
    Ok(())
}
fn name(record: &Record) -> String {
    format!("{}-{:020}.json", record.task_id, record.sequence)
}
fn read(path: &Path) -> Result<Record, ApiError> {
    let mut bytes = Vec::new();
    File::open(path)
        .map_err(io)?
        .take(MAX_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(io)?;
    if bytes.len() as u64 > MAX_BYTES {
        return Err(invalid());
    }
    let record: Record = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
    validate(&record)?;
    if path.file_name().and_then(|x| x.to_str()) != Some(name(&record).as_str()) {
        return Err(invalid());
    }
    Ok(record)
}
pub fn load(directory: &Path) -> Result<Vec<Record>, ApiError> {
    if !directory.is_absolute() {
        return Err(invalid());
    }
    let entries = match fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
        Err(e) => return Err(io(e)),
    };
    let mut latest: BTreeMap<String, Record> = BTreeMap::new();
    let mut count = 0;
    for entry in entries {
        let path = entry.map_err(io)?.path();
        if path.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }
        count += 1;
        if count > MAX_RECORDS {
            return Err(invalid());
        }
        let record = read(&path)?;
        if latest
            .get(&record.task_id)
            .is_none_or(|old| old.sequence < record.sequence)
        {
            latest.insert(record.task_id.clone(), record);
        }
    }
    Ok(latest.into_values().collect())
}
/// Only remove receipt-bound transaction artifacts after durable history and
/// output verification. Never enumerate or clean unrelated output directories.
pub fn clean_completed(directory: &Path, record: &Record) -> Result<(), ApiError> {
    if record.phase != "complete" || read(&directory.join(name(record)))? != *record {
        return Err(invalid());
    }
    if verify(directory, &record.task_id)?["status"] != "matches" {
        return Err(invalid());
    }
    let receipt = record.receipt.as_ref().ok_or_else(invalid)?;
    let output = Path::new(&record.output_path).canonicalize().map_err(io)?;
    let parent = output.parent().ok_or_else(invalid)?;
    let expected = parent.join(format!(
        ".{}.easypub-txn",
        output.file_name().ok_or_else(invalid)?.to_string_lossy()
    ));
    let recorded = Path::new(
        receipt["transaction"]["transaction_dir"]
            .as_str()
            .ok_or_else(invalid)?,
    );
    if !expected.exists() {
        return clean_conversion_work(receipt, &output, &record.format);
    }
    let metadata = fs::symlink_metadata(&expected).map_err(io)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(invalid());
    }
    let resolved = expected.canonicalize().map_err(io)?;
    if resolved.parent() != Some(parent) || recorded.canonicalize().map_err(io)? != resolved {
        return Err(invalid());
    }
    let bytes = fs::read(resolved.join("manifest.json")).map_err(io)?;
    let manifest: crate::transaction::TransactionManifest =
        serde_json::from_slice(&bytes).map_err(|_| invalid())?;
    if Path::new(&manifest.output_path)
        .canonicalize()
        .map_err(io)?
        != output
        || !matches!(
            manifest.stage,
            crate::transaction::TransactionStage::Published
        )
        || manifest.output_sha256.as_deref() != receipt["transaction"]["output_sha256"].as_str()
    {
        return Err(invalid());
    }
    clean_conversion_work(receipt, &output, &record.format)?;
    fs::remove_dir_all(resolved).map_err(io)
}

fn clean_conversion_work(receipt: &Value, output: &Path, format: &str) -> Result<(), ApiError> {
    let workspace = std::env::var_os("LOCALAPPDATA")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join("EasyPubPlusPlus")
        .join("conversion-work");
    clean_conversion_work_in(receipt, output, format, &workspace)
}
fn clean_conversion_work_in(
    receipt: &Value,
    output: &Path,
    format: &str,
    workspace: &Path,
) -> Result<(), ApiError> {
    let Some(directory) = receipt.get("conversion_directory").and_then(Value::as_str) else {
        return Ok(());
    };
    let stage = Path::new(directory);
    if !stage.exists() {
        return Ok(());
    }
    if !matches!(format, "MOBI" | "AZW3" | "KFX")
        || !stage.is_absolute()
        || !stage
            .file_name()
            .and_then(|s| s.to_str())
            .is_some_and(|s| s.starts_with(".easypub-kindling-"))
    {
        return Err(invalid());
    }
    let meta = fs::symlink_metadata(stage).map_err(io)?;
    if meta.file_type().is_symlink() || !meta.is_dir() {
        return Err(invalid());
    }
    let resolved = stage.canonicalize().map_err(io)?;
    if resolved.parent() != Some(workspace.canonicalize().map_err(io)?.as_path()) {
        return Err(invalid());
    }
    let output_name = format!("output.{}", format.to_lowercase());
    // A completed engine owns exactly these regular files. Unexpected data is preserved.
    for entry in fs::read_dir(&resolved).map_err(io)? {
        let entry = entry.map_err(io)?;
        let metadata = fs::symlink_metadata(entry.path()).map_err(io)?;
        if !metadata.is_file()
            || metadata.file_type().is_symlink()
            || ![
                "input.epub",
                "engine.log",
                "validation.log",
                "plan.json",
                output_name.as_str(),
            ]
            .contains(&entry.file_name().to_str().unwrap_or(""))
        {
            return Err(invalid());
        }
    }
    let plan_bytes = fs::read(resolved.join("plan.json")).map_err(io)?;
    let plan: Value = serde_json::from_slice(&plan_bytes).map_err(|_| invalid())?;
    if Path::new(plan["output_path"].as_str().ok_or_else(invalid)?)
        .canonicalize()
        .map_err(io)?
        != output
        || plan["source_sha256"] != receipt["transaction"]["source_sha256"]
    {
        return Err(invalid());
    }
    let bytes = fs::read(resolved.join(&output_name)).map_err(io)?;
    if format!("{:x}", Sha256::digest(&bytes))
        != receipt["transaction"]["output_sha256"]
            .as_str()
            .ok_or_else(invalid)?
    {
        return Err(invalid());
    }
    // Delete only named files, then the empty owned directory; never recurse into extras.
    for name in [
        "input.epub",
        "engine.log",
        "validation.log",
        "plan.json",
        output_name.as_str(),
    ] {
        match fs::remove_file(resolved.join(name)) {
            Ok(()) => (),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
            Err(e) => return Err(io(e)),
        }
    }
    fs::remove_dir(resolved).map_err(io)
}

pub fn save(directory: &Path, record: &Record) -> Result<(), ApiError> {
    if !directory.is_absolute() {
        return Err(invalid());
    }
    validate(record)?;
    let bytes = serde_json::to_vec(record).map_err(|_| invalid())?;
    if bytes.len() as u64 > MAX_BYTES {
        return Err(invalid());
    }
    fs::create_dir_all(directory).map_err(io)?;
    let target = directory.join(name(record));
    // Repeating the same observation is idempotent; conflicting data is never overwritten.
    if target.exists() {
        return if read(&target)? == *record {
            Ok(())
        } else {
            Err(invalid())
        };
    }
    let temp = directory.join(format!(
        ".pending-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temp)
        .map_err(io)?;
    let result = (|| {
        file.write_all(&bytes).map_err(io)?;
        file.sync_all().map_err(io)?;
        fs::hard_link(&temp, &target).map_err(io)
    })();
    drop(file);
    let _ = fs::remove_file(&temp);
    result
}

#[cfg(test)]
mod tests {
    #[test]
    fn completed_kindling_work_requires_owned_plan_hash_and_no_extra_files() {
        use super::*;
        let root = std::env::temp_dir().join(format!(
            "easypub-work-clean-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        let workspace = root.join("work");
        let stage = workspace.join(".easypub-kindling-test");
        fs::create_dir_all(&stage).unwrap();
        let output = root.join("book.mobi");
        fs::write(&output, b"result").unwrap();
        let output = output.canonicalize().unwrap();
        let hash = format!("{:x}", Sha256::digest(b"result"));
        let receipt = serde_json::json!({"conversion_directory":stage,"transaction":{"source_sha256":"source","output_sha256":hash}});
        fs::write(stage.join("input.epub"), b"input").unwrap();
        fs::write(stage.join("engine.log"), b"log").unwrap();
        fs::write(stage.join("output.mobi"), b"result").unwrap();
        fs::write(
            stage.join("plan.json"),
            serde_json::json!({"output_path":output,"source_sha256":"wrong"}).to_string(),
        )
        .unwrap();
        assert!(clean_conversion_work_in(&receipt, &output, "MOBI", &workspace).is_err());
        assert!(stage.join("input.epub").exists());
        fs::write(
            stage.join("plan.json"),
            serde_json::json!({"output_path":output,"source_sha256":"source"}).to_string(),
        )
        .unwrap();
        fs::write(stage.join("keep.txt"), b"user").unwrap();
        assert!(clean_conversion_work_in(&receipt, &output, "MOBI", &workspace).is_err());
        fs::remove_file(stage.join("keep.txt")).unwrap();
        assert!(clean_conversion_work_in(&receipt, &output, "MOBI", &root).is_err());
        clean_conversion_work_in(&receipt, &output, "MOBI", &workspace).unwrap();
        assert!(!stage.exists());
        assert_eq!(fs::read(&output).unwrap(), b"result");
        clean_conversion_work_in(&receipt, &output, "MOBI", &workspace).unwrap();
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn cover_snapshot_is_bounded_and_applies_the_selected_crop() {
        use base64::Engine;
        let dir = std::env::temp_dir().join(format!(
            "easypub-task-cover-{}-{}",
            std::process::id(),
            super::NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("cover.png");
        image::RgbImage::from_fn(400, 600, |x, _| {
            if x < 200 {
                image::Rgb([240u8, 10, 10])
            } else {
                image::Rgb([10u8, 10, 240])
            }
        })
        .save(&path)
        .unwrap();
        let crop = crate::assets::Crop {
            x: 0.5,
            y: 0.0,
            width: 0.5,
            height: 1.0,
        };
        let encoded = super::cover_thumbnail(path.to_str().unwrap(), Some(&crop)).unwrap();
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(&encoded)
            .unwrap();
        assert!(bytes.len() <= 12 * 1024);
        let decoded = image::load_from_memory(&bytes).unwrap().to_rgb8();
        assert!(decoded.width() <= 174 && decoded.height() <= 252);
        let pixel = decoded.get_pixel(decoded.width() / 2, decoded.height() / 2);
        assert!(pixel[2] > 200 && pixel[0] < 50);
        let invalid_crop = crate::assets::Crop { x: 1.0, ..crop };
        assert!(super::cover_thumbnail(path.to_str().unwrap(), Some(&invalid_crop)).is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn receipt_metadata_comparison_distinguishes_missing_invalid_and_mismatch() {
        let expected = serde_json::json!({"title":"书名", "author":"作者", "language":"en"});
        let mut actual = expected.clone();
        super::compare_metadata(&mut actual, Some(&expected));
        assert_eq!(actual["metadata_status"], "matches");
        actual["language"] = serde_json::json!("zh-CN");
        super::compare_metadata(&mut actual, Some(&expected));
        assert_eq!(actual["metadata_status"], "mismatch");
        assert_eq!(
            actual["metadata_mismatches"],
            serde_json::json!(["language"])
        );
        let mut old = serde_json::json!({});
        super::compare_metadata(&mut old, None);
        assert_eq!(old["metadata_status"], "unavailable");
        super::compare_metadata(&mut old, Some(&serde_json::json!({"title":"书名"})));
        assert_eq!(old["metadata_status"], "invalid");
    }
    use super::*;
    #[test]
    fn interrupted_inspection_checks_evidence_without_publishing() {
        let dir = std::env::temp_dir().join(format!(
            "easypub-inspect-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&dir).unwrap();
        let source = dir.join("source.txt");
        let output = dir.join("book.epub");
        fs::write(&source, "原始书稿").unwrap();
        let result = crate::transaction::apply_new_file_bytes_with_evidence(
            &source,
            &output,
            b"publication",
            &file_hash(&source).unwrap(),
            crate::transaction::InjectFault::AfterStage,
            Some(b"{}"),
        );
        assert!(result.is_err());
        let record = Record {
            schema: 1,
            task_id: "abc".into(),
            sequence: 1,
            book_id: "b".into(),
            title: "书".into(),
            source_id: file_hash(&source).unwrap(),
            source_revision: 1,
            format: "EPUB".into(),
            output_path: output.to_string_lossy().into(),
            started_at: "now".into(),
            finished_at: None,
            phase: "preparing".into(),
            detail: String::new(),
            receipt: None,
            batch_id: None,
            batch_index: None,
            batch_total: None,
            checks_enabled: None,
            cover_thumbnail: None,
        };
        let manifest = dir.join(".book.epub.easypub-txn/manifest.json");
        let before = fs::read(&manifest).unwrap();
        let history = dir.join("history");
        save(&history, &record).unwrap();
        let preview = recovery_preview(&history, &record.task_id).unwrap();
        let token = preview["token"].as_str().unwrap();
        assert!(recover_output(&history, &record.task_id, token, false).is_err());
        assert!(recover_output(&history, &record.task_id, "stale", true).is_err());
        assert_eq!(
            inspect_interrupted(&record).unwrap()["status"],
            "staged_verified"
        );
        assert!(!output.exists());
        assert_eq!(fs::read(&manifest).unwrap(), before);
        fs::write(&output, b"publication").unwrap();
        assert_eq!(
            inspect_interrupted(&record).unwrap()["status"],
            "published_without_receipt"
        );
        fs::write(&output, b"changed").unwrap();
        assert_eq!(inspect_interrupted(&record).unwrap()["status"], "changed");
        fs::write(&source, "变化").unwrap();
        assert!(recover_output(&history, &record.task_id, token, true).is_err());
        assert_eq!(
            inspect_interrupted(&record).unwrap()["status"],
            "source_changed"
        );
        fs::write(&source, "原始书稿").unwrap();
        fs::write(
            dir.join(".book.epub.easypub-txn/source-backup.bin"),
            b"bad backup",
        )
        .unwrap();
        assert_eq!(
            inspect_interrupted(&record).unwrap()["status"],
            "evidence_changed"
        );
        fs::write(
            dir.join(".book.epub.easypub-txn/source-backup.bin"),
            "原始书稿",
        )
        .unwrap();
        fs::remove_file(&output).unwrap();
        let recovery = recover_output(&history, &record.task_id, token, true).unwrap();
        assert_eq!(recovery["transaction"]["source_unchanged"], true);
        assert_eq!(fs::read(&output).unwrap(), b"publication");
        assert!(recover_output(&history, &record.task_id, token, true).is_err());
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn immutable_history_reopens_and_rejects_conflicts_and_corruption() {
        let dir = std::env::temp_dir().join(format!(
            "easypub-history-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let mut record = Record {
            schema: 1,
            task_id: "abc-123".into(),
            sequence: 1,
            book_id: "book".into(),
            title: "样书".into(),
            source_id: "source".into(),
            source_revision: 1,
            format: "AZW3".into(),
            output_path: "book.azw3".into(),
            started_at: "2026-09-28".into(),
            finished_at: None,
            phase: "converting".into(),
            detail: String::new(),
            receipt: None,
            batch_id: None,
            batch_index: None,
            batch_total: None,
            checks_enabled: None,
            cover_thumbnail: None,
        };
        save(&dir, &record).unwrap();
        save(&dir, &record).unwrap();
        assert_eq!(load(&dir).unwrap(), vec![record.clone()]);
        record.title = "冲突".into();
        assert!(save(&dir, &record).is_err());
        record.sequence = 2;
        record.phase = "cancelled".into();
        assert!(save(&dir, &record).is_err());
        record.finished_at = Some("2026-09-28".into());
        save(&dir, &record).unwrap();
        assert_eq!(load(&dir).unwrap(), vec![record.clone()]);
        let mut bad_thumbnail = record.clone();
        bad_thumbnail.task_id = "def-456".into();
        bad_thumbnail.cover_thumbnail = Some("not-base64".into());
        assert!(save(&dir, &bad_thumbnail).is_err());
        bad_thumbnail.cover_thumbnail = Some("A".repeat(16 * 1024 + 1));
        assert!(save(&dir, &bad_thumbnail).is_err());
        record.task_id = "../escape".into();
        assert!(save(&dir, &record).is_err());
        fs::write(dir.join("broken.json"), b"{").unwrap();
        assert!(load(&dir).is_err());
        fs::remove_dir_all(dir).unwrap();
    }
}
