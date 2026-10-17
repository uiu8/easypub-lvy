//! Minimal, filesystem-backed output transaction for the R1 safety gate.
//!
//! It intentionally publishes a new file only.  The source is read and
//! fingerprinted before staging and checked again before the final rename;
//! recovery uses the manifest and is safe to run more than once.

use easypub_core::{ApiError, ErrorCode};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    io::Write,
    path::{Path, PathBuf},
};

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TransactionStage {
    Prepared,
    Staged,
    Published,
    Failed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InjectFault {
    None,
    AfterStage,
    AfterPublish,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct TransactionManifest {
    pub schema: u32,
    pub source_path: String,
    pub output_path: String,
    pub source_sha256: String,
    #[serde(default)]
    pub output_sha256: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub evidence_sha256: Option<String>,
    pub stage: TransactionStage,
    pub last_error: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct TransactionReport {
    pub transaction_dir: String,
    pub source_sha256: String,
    pub output_sha256: Option<String>,
    pub stage: TransactionStage,
    pub source_unchanged: bool,
    pub output_exists: bool,
    pub recovered: bool,
}

pub fn apply_new_file(
    source_path: impl AsRef<Path>,
    output_path: impl AsRef<Path>,
    fault: InjectFault,
) -> Result<TransactionReport, ApiError> {
    let source_path = source_path.as_ref();
    let output_path = output_path.as_ref();
    let source_canonical = source_path.canonicalize().map_err(|_| {
        ApiError::new(
            ErrorCode::NotFound,
            "transaction_source",
            "choose_readable_file",
        )
    })?;
    let output_absolute = absolute_output(output_path)?;
    if source_canonical == output_absolute {
        return Err(ApiError::new(
            ErrorCode::OutputConflict,
            "transaction_output",
            "choose_new_output_path",
        ));
    }
    if output_path.exists() {
        return Err(ApiError::new(
            ErrorCode::OutputConflict,
            "transaction_output",
            "choose_new_output_path",
        ));
    }

    let source_bytes = fs::read(&source_canonical)
        .map_err(|_| ApiError::new(ErrorCode::Io, "transaction_read", "choose_readable_file"))?;
    let source_sha256 = digest(&source_bytes);
    let transaction_dir = transaction_dir(&output_absolute);
    let staged_dir = transaction_dir.join("staged");
    // Never replace recovery evidence from an unfinished transaction.
    fs::create_dir(&transaction_dir).map_err(|_| {
        ApiError::new(
            ErrorCode::Transaction,
            "transaction_prepare",
            "recover_transaction",
        )
    })?;
    let _lock = lock_transaction(&transaction_dir)?;
    fs::create_dir_all(&staged_dir).map_err(|_| {
        ApiError::new(
            ErrorCode::Io,
            "transaction_prepare",
            "choose_writable_output",
        )
    })?;
    let staged_path = staged_dir.join(output_absolute.file_name().unwrap_or_default());
    let manifest_path = transaction_dir.join("manifest.json");
    let mut manifest = TransactionManifest {
        schema: 1,
        source_path: source_canonical.display().to_string(),
        output_path: output_absolute.display().to_string(),
        source_sha256: source_sha256.clone(),
        output_sha256: None,
        evidence_sha256: None,
        stage: TransactionStage::Prepared,
        last_error: None,
    };
    write_manifest(&manifest_path, &manifest)?;
    checkpoint("prepared", &transaction_dir);
    File::create(&staged_path)
        .and_then(|mut file| {
            file.write_all(&source_bytes)?;
            file.sync_all()
        })
        .map_err(|_| fail(&manifest_path, &mut manifest, "stage_write"))?;
    manifest.stage = TransactionStage::Staged;
    write_manifest(&manifest_path, &manifest)?;
    checkpoint("staged", &transaction_dir);
    if fault == InjectFault::AfterStage {
        return Err(fail(&manifest_path, &mut manifest, "injected_after_stage"));
    }
    check_source_unchanged(&source_canonical, &source_sha256)?;
    if output_path.exists() {
        return Err(fail(&manifest_path, &mut manifest, "output_appeared"));
    }
    publish_new(&staged_path, &output_absolute)
        .map_err(|_| fail(&manifest_path, &mut manifest, "publish_rename"))?;
    checkpoint("published_before_manifest", &transaction_dir);
    manifest.stage = TransactionStage::Published;
    write_manifest(&manifest_path, &manifest)?;
    let report = report(&manifest, &transaction_dir, &source_canonical, false)?;
    if fault == InjectFault::AfterPublish {
        return Err(fail(
            &manifest_path,
            &mut manifest,
            "injected_after_publish",
        ));
    }
    Ok(report)
}

/// Publish transformed bytes to a new path while keeping the source guarded by
/// its hash. The source is never replaced; recovery validates the transformed
/// output hash recorded in the manifest.
pub fn apply_new_file_bytes(
    source_path: impl AsRef<Path>,
    output_path: impl AsRef<Path>,
    output_bytes: &[u8],
    expected_source: &str,
    fault: InjectFault,
) -> Result<TransactionReport, ApiError> {
    apply_new_file_bytes_with_evidence(
        source_path,
        output_path,
        output_bytes,
        expected_source,
        fault,
        None,
    )
}

/// Persist and verify review evidence before publishing the output. Recovery
/// refuses to publish when evidence has disappeared or changed.
pub fn apply_new_file_bytes_with_evidence(
    source_path: impl AsRef<Path>,
    output_path: impl AsRef<Path>,
    output_bytes: &[u8],
    expected_source: &str,
    fault: InjectFault,
    evidence: Option<&[u8]>,
) -> Result<TransactionReport, ApiError> {
    let source_path = source_path.as_ref();
    let output_path = output_path.as_ref();
    let source_canonical = source_path.canonicalize().map_err(|_| {
        ApiError::new(
            ErrorCode::NotFound,
            "transaction_source",
            "choose_readable_file",
        )
    })?;
    let output_absolute = absolute_output(output_path)?;
    if source_canonical == output_absolute || output_path.exists() {
        return Err(ApiError::new(
            ErrorCode::OutputConflict,
            "transaction_output",
            "choose_new_output_path",
        ));
    }
    let source_bytes = fs::read(&source_canonical)
        .map_err(|_| ApiError::new(ErrorCode::Io, "transaction_read", "choose_readable_file"))?;
    let source_sha256 = digest(&source_bytes);
    if source_sha256 != expected_source {
        return Err(ApiError::new(
            ErrorCode::SourceChanged,
            "transaction_source",
            "reopen_preview",
        ));
    }
    let output_sha256 = digest(output_bytes);
    let transaction_dir = transaction_dir(&output_absolute);
    let staged_dir = transaction_dir.join("staged");
    fs::create_dir(&transaction_dir).map_err(|_| {
        ApiError::new(
            ErrorCode::Transaction,
            "transaction_prepare",
            "recover_transaction",
        )
    })?;
    let _lock = lock_transaction(&transaction_dir)?;
    fs::create_dir_all(&staged_dir).map_err(|_| {
        ApiError::new(
            ErrorCode::Io,
            "transaction_prepare",
            "choose_writable_output",
        )
    })?;
    let staged_path = staged_dir.join(output_absolute.file_name().unwrap_or_default());
    let manifest_path = transaction_dir.join("manifest.json");
    let mut manifest = TransactionManifest {
        schema: 1,
        source_path: source_canonical.display().to_string(),
        output_path: output_absolute.display().to_string(),
        source_sha256: source_sha256.clone(),
        output_sha256: Some(output_sha256),
        evidence_sha256: evidence.map(digest),
        stage: TransactionStage::Prepared,
        last_error: None,
    };
    write_manifest(&manifest_path, &manifest)?;
    File::create(transaction_dir.join("source-backup.bin"))
        .and_then(|mut file| {
            file.write_all(&source_bytes)?;
            file.sync_all()
        })
        .map_err(|_| fail(&manifest_path, &mut manifest, "backup_write"))?;
    if digest(
        &fs::read(transaction_dir.join("source-backup.bin"))
            .map_err(|_| fail(&manifest_path, &mut manifest, "backup_read"))?,
    ) != source_sha256
    {
        return Err(fail(&manifest_path, &mut manifest, "backup_verify"));
    }
    if let Some(bytes) = evidence {
        let path = transaction_dir.join("edit-evidence.json");
        File::create(&path)
            .and_then(|mut f| {
                f.write_all(bytes)?;
                f.sync_all()
            })
            .map_err(|_| fail(&manifest_path, &mut manifest, "evidence_write"))?;
        if digest(
            &fs::read(&path).map_err(|_| fail(&manifest_path, &mut manifest, "evidence_read"))?,
        ) != digest(bytes)
        {
            return Err(fail(&manifest_path, &mut manifest, "evidence_verify"));
        }
    }
    checkpoint("prepared", &transaction_dir);
    File::create(&staged_path)
        .and_then(|mut file| {
            file.write_all(output_bytes)?;
            file.sync_all()
        })
        .map_err(|_| fail(&manifest_path, &mut manifest, "stage_write"))?;
    manifest.stage = TransactionStage::Staged;
    write_manifest(&manifest_path, &manifest)?;
    checkpoint("staged", &transaction_dir);
    if fault == InjectFault::AfterStage {
        return Err(fail(&manifest_path, &mut manifest, "injected_after_stage"));
    }
    check_source_unchanged(&source_canonical, &source_sha256)?;
    if output_path.exists() {
        return Err(fail(&manifest_path, &mut manifest, "output_appeared"));
    }
    publish_new(&staged_path, &output_absolute)
        .map_err(|_| fail(&manifest_path, &mut manifest, "publish_rename"))?;
    checkpoint("published_before_manifest", &transaction_dir);
    manifest.stage = TransactionStage::Published;
    write_manifest(&manifest_path, &manifest)?;
    let report = report(&manifest, &transaction_dir, &source_canonical, false)?;
    if fault == InjectFault::AfterPublish {
        return Err(fail(
            &manifest_path,
            &mut manifest,
            "injected_after_publish",
        ));
    }
    Ok(report)
}

pub fn recover(transaction_dir: impl AsRef<Path>) -> Result<TransactionReport, ApiError> {
    recover_checked(transaction_dir.as_ref(), || Ok(()))
}

pub(crate) fn recover_checked(
    transaction_dir: &Path,
    check: impl FnOnce() -> Result<(), ApiError>,
) -> Result<TransactionReport, ApiError> {
    let _lock = lock_transaction(transaction_dir)?;
    check()?;
    let manifest_path = transaction_dir.join("manifest.json");
    let mut manifest = read_manifest(&manifest_path)?;
    if let Some(expected) = &manifest.evidence_sha256 {
        let bytes = fs::read(transaction_dir.join("edit-evidence.json")).map_err(|_| {
            ApiError::new(
                ErrorCode::Transaction,
                "transaction_recover",
                "restore_edit_evidence",
            )
        })?;
        if digest(&bytes) != *expected {
            return Err(ApiError::new(
                ErrorCode::Transaction,
                "transaction_recover",
                "restore_edit_evidence",
            ));
        }
    }
    let output_path = PathBuf::from(&manifest.output_path);
    let source_path = PathBuf::from(&manifest.source_path);
    let staged_path = transaction_dir
        .join("staged")
        .join(output_path.file_name().unwrap_or_default());
    if manifest.stage != TransactionStage::Published {
        if output_path.exists() {
            let expected_output = manifest
                .output_sha256
                .as_deref()
                .unwrap_or(&manifest.source_sha256);
            if digest(&fs::read(&output_path).map_err(|_| {
                ApiError::new(ErrorCode::Io, "transaction_recover", "inspect_output")
            })?) == expected_output
            {
                let _ = fs::remove_file(&staged_path);
                manifest.stage = TransactionStage::Published;
                manifest.last_error = None;
                write_manifest(&manifest_path, &manifest)?;
            } else {
                return Err(ApiError::new(
                    ErrorCode::OutputConflict,
                    "transaction_recover",
                    "inspect_output",
                ));
            }
        } else if staged_path.exists() {
            check_source_unchanged(&source_path, &manifest.source_sha256)?;
            let staged = fs::read(&staged_path).map_err(|_| {
                ApiError::new(
                    ErrorCode::Io,
                    "transaction_recover",
                    "inspect_staged_output",
                )
            })?;
            let expected_output = manifest
                .output_sha256
                .as_deref()
                .unwrap_or(&manifest.source_sha256);
            if digest(&staged) != expected_output {
                return Err(ApiError::new(
                    ErrorCode::Transaction,
                    "transaction_recover",
                    "inspect_staged_output",
                ));
            }
            publish_new(&staged_path, &output_path).map_err(|_| {
                ApiError::new(
                    ErrorCode::Io,
                    "transaction_recover",
                    "choose_writable_output",
                )
            })?;
            manifest.stage = TransactionStage::Published;
            manifest.last_error = None;
            write_manifest(&manifest_path, &manifest)?;
        } else {
            return Err(ApiError::new(
                ErrorCode::Transaction,
                "transaction_recover",
                "inspect_transaction_manifest",
            ));
        }
    }
    let result = report(&manifest, transaction_dir, &source_path, true)?;
    let expected_output = manifest
        .output_sha256
        .as_deref()
        .unwrap_or(&manifest.source_sha256);
    if result.output_sha256.as_deref() != Some(expected_output) {
        return Err(ApiError::new(
            ErrorCode::OutputConflict,
            "transaction_recover",
            "inspect_output",
        ));
    }
    Ok(result)
}

fn report(
    manifest: &TransactionManifest,
    transaction_dir: &Path,
    source_path: &Path,
    recovered: bool,
) -> Result<TransactionReport, ApiError> {
    let output_path = PathBuf::from(&manifest.output_path);
    let output_bytes = output_path
        .exists()
        .then(|| fs::read(&output_path))
        .transpose()
        .map_err(|_| ApiError::new(ErrorCode::Io, "transaction_report", "inspect_output"))?;
    let source_unchanged =
        source_path.exists()
            && digest(&fs::read(source_path).map_err(|_| {
                ApiError::new(ErrorCode::Io, "transaction_report", "inspect_source")
            })?) == manifest.source_sha256;
    Ok(TransactionReport {
        transaction_dir: transaction_dir.display().to_string(),
        source_sha256: manifest.source_sha256.clone(),
        output_sha256: output_bytes.as_deref().map(digest),
        stage: manifest.stage,
        source_unchanged,
        output_exists: output_path.exists(),
        recovered,
    })
}

fn check_source_unchanged(source_path: &Path, expected: &str) -> Result<(), ApiError> {
    let bytes = fs::read(source_path).map_err(|_| {
        ApiError::new(
            ErrorCode::SourceChanged,
            "transaction_source",
            "reopen_preview",
        )
    })?;
    if digest(&bytes) != expected {
        return Err(ApiError::new(
            ErrorCode::SourceChanged,
            "transaction_source",
            "reopen_preview",
        ));
    }
    Ok(())
}

fn absolute_output(path: &Path) -> Result<PathBuf, ApiError> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let parent = parent.canonicalize().map_err(|_| {
        ApiError::new(
            ErrorCode::Io,
            "transaction_output",
            "choose_writable_output",
        )
    })?;
    Ok(parent.join(path.file_name().ok_or_else(|| {
        ApiError::new(
            ErrorCode::OutputConflict,
            "transaction_output",
            "choose_new_output_path",
        )
    })?))
}

fn transaction_dir(output: &Path) -> PathBuf {
    output
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join(format!(
            ".{}.easypub-txn",
            output.file_name().unwrap_or_default().to_string_lossy()
        ))
}

fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn write_manifest(path: &Path, manifest: &TransactionManifest) -> Result<(), ApiError> {
    let data = serde_json::to_vec_pretty(manifest).map_err(|_| {
        ApiError::new(
            ErrorCode::Transaction,
            "transaction_manifest",
            "inspect_transaction_manifest",
        )
    })?;
    let temporary = path.with_extension("json.next");
    let mut file = File::create(&temporary).map_err(|_| {
        ApiError::new(
            ErrorCode::Io,
            "transaction_manifest",
            "choose_writable_output",
        )
    })?;
    if path.exists() {
        file.write_all(&data[..data.len() / 2]).map_err(|_| {
            ApiError::new(ErrorCode::Io, "transaction_manifest", "recover_transaction")
        })?;
        checkpoint("manifest_partial", path.parent().unwrap());
        file.write_all(&data[data.len() / 2..])
    } else {
        file.write_all(&data)
    }
    .and_then(|_| file.sync_all())
    .map_err(|_| {
        ApiError::new(
            ErrorCode::Io,
            "transaction_manifest",
            "choose_writable_output",
        )
    })?;
    drop(file);
    fs::rename(&temporary, path)
        .map_err(|_| ApiError::new(ErrorCode::Io, "transaction_manifest", "recover_transaction"))
}

fn lock_transaction(dir: &Path) -> Result<File, ApiError> {
    let lock = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(dir.join("owner.lock"))
        .map_err(|_| {
            ApiError::new(
                ErrorCode::Transaction,
                "transaction_lock",
                "inspect_transaction",
            )
        })?;
    lock.try_lock().map_err(|_| {
        ApiError::new(
            ErrorCode::Busy,
            "transaction_lock",
            "retry_after_owner_stops",
        )
    })?;
    Ok(lock)
}

// A same-volume hard link publishes only if the destination does not exist.
// This closes the exists/rename race without overwriting an external file.
fn publish_new(staged: &Path, output: &Path) -> std::io::Result<()> {
    fs::hard_link(staged, output)?;
    fs::remove_file(staged)
}

#[cfg(feature = "r1-faults")]
fn checkpoint(name: &str, dir: &Path) {
    if std::env::var("EASYPUB_R1_CRASH_POINT").ok().as_deref() == Some(name) {
        fs::write(dir.join("checkpoint"), name).unwrap();
        std::thread::sleep(std::time::Duration::from_secs(30));
        std::process::exit(86);
    }
}
#[cfg(not(feature = "r1-faults"))]
fn checkpoint(_: &str, _: &Path) {}

fn read_manifest(path: &Path) -> Result<TransactionManifest, ApiError> {
    let data = fs::read(path).map_err(|_| {
        ApiError::new(
            ErrorCode::Transaction,
            "transaction_recover",
            "inspect_transaction_manifest",
        )
    })?;
    serde_json::from_slice(&data).map_err(|_| {
        ApiError::new(
            ErrorCode::Transaction,
            "transaction_recover",
            "inspect_transaction_manifest",
        )
    })
}

fn fail(manifest_path: &Path, manifest: &mut TransactionManifest, reason: &str) -> ApiError {
    manifest.stage = TransactionStage::Failed;
    manifest.last_error = Some(reason.to_owned());
    let _ = write_manifest(manifest_path, manifest);
    ApiError::new(ErrorCode::Transaction, "transaction", "recover_transaction")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        time::{SystemTime, UNIX_EPOCH},
    };

    fn temp_dir() -> PathBuf {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let serial = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let id = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "easypub-r1-txn-{}-{id}-{serial}",
            std::process::id()
        ));
        fs::create_dir(&path).unwrap();
        path
    }

    #[test]
    fn injected_stage_failure_leaves_explainable_manifest_and_recovers_idempotently() {
        let root = temp_dir();
        let source = root.join("source.txt");
        let output = root.join("output.txt");
        let bytes = "第一章 开始\r\n正文".as_bytes();
        fs::write(&source, bytes).unwrap();
        let error = apply_new_file(&source, &output, InjectFault::AfterStage).unwrap_err();
        assert_eq!(error.code, ErrorCode::Transaction);
        assert!(!output.exists());
        let txn = transaction_dir(&output);
        let manifest: TransactionManifest =
            serde_json::from_slice(&fs::read(txn.join("manifest.json")).unwrap()).unwrap();
        assert_eq!(manifest.stage, TransactionStage::Failed);
        assert_eq!(fs::read(&source).unwrap(), bytes);
        let first = recover(&txn).unwrap();
        let second = recover(&txn).unwrap();
        assert!(first.output_exists && first.source_unchanged);
        assert_eq!(first.output_sha256, second.output_sha256);
        assert_eq!(fs::read(&output).unwrap(), bytes);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn refuses_to_overwrite_source_or_existing_output() {
        let root = temp_dir();
        let source = root.join("source.txt");
        fs::write(&source, b"source").unwrap();
        assert_eq!(
            apply_new_file(&source, &source, InjectFault::None)
                .unwrap_err()
                .code,
            ErrorCode::OutputConflict
        );
        let output = root.join("output.txt");
        fs::write(&output, b"existing").unwrap();
        assert_eq!(
            apply_new_file(&source, &output, InjectFault::None)
                .unwrap_err()
                .code,
            ErrorCode::OutputConflict
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn recovery_rejects_corrupted_staging_and_retry_preserves_evidence() {
        let root = temp_dir();
        let source = root.join("source.txt");
        let output = root.join("output.txt");
        fs::write(&source, b"original").unwrap();
        apply_new_file(&source, &output, InjectFault::AfterStage).unwrap_err();
        let txn = transaction_dir(&output);
        let before = fs::read(txn.join("manifest.json")).unwrap();
        apply_new_file(&source, &output, InjectFault::None).unwrap_err();
        assert_eq!(before, fs::read(txn.join("manifest.json")).unwrap());
        fs::write(txn.join("staged/output.txt"), b"corrupt").unwrap();
        assert_eq!(recover(&txn).unwrap_err().code, ErrorCode::Transaction);
        assert!(!output.exists());
        assert_eq!(fs::read(source).unwrap(), b"original");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn after_publish_recovery_is_idempotent_and_checks_published_bytes() {
        let root = temp_dir();
        let source = root.join("source.txt");
        let output = root.join("output.txt");
        fs::write(&source, b"original").unwrap();
        apply_new_file(&source, &output, InjectFault::AfterPublish).unwrap_err();
        let txn = transaction_dir(&output);
        assert!(recover(&txn).unwrap().output_exists);
        assert!(recover(&txn).unwrap().output_exists);
        fs::write(&output, b"external edit").unwrap();
        assert_eq!(recover(&txn).unwrap_err().code, ErrorCode::OutputConflict);
        assert_eq!(fs::read(output).unwrap(), b"external edit");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn transformed_output_is_published_without_changing_source() {
        let root = temp_dir();
        let source = root.join("source.txt");
        let output = root.join("output.txt");
        let original = b"first\nfirst\n";
        let transformed = b"first\n";
        fs::write(&source, original).unwrap();
        let report = apply_new_file_bytes(
            &source,
            &output,
            transformed,
            &digest(original),
            InjectFault::None,
        )
        .unwrap();
        assert!(report.source_unchanged);
        assert_eq!(fs::read(&source).unwrap(), original);
        assert_eq!(fs::read(&output).unwrap(), transformed);
        assert_eq!(
            report.output_sha256.as_deref(),
            Some(digest(transformed).as_str())
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn transformed_recovery_rejects_changed_staged_bytes() {
        let root = temp_dir();
        let source = root.join("source.txt");
        let output = root.join("output.txt");
        fs::write(&source, b"original").unwrap();
        apply_new_file_bytes(
            &source,
            &output,
            b"edited",
            &digest(b"original"),
            InjectFault::AfterStage,
        )
        .unwrap_err();
        let txn = transaction_dir(&output);
        fs::write(txn.join("staged/output.txt"), b"corrupt").unwrap();
        assert_eq!(recover(&txn).unwrap_err().code, ErrorCode::Transaction);
        assert!(!output.exists());
        assert_eq!(fs::read(&source).unwrap(), b"original");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn cleanup_evidence_must_survive_before_recovery_can_publish() {
        let root = temp_dir();
        let source = root.join("source.txt");
        let output = root.join("output.txt");
        fs::write(&source, b"original").unwrap();
        let evidence = br#"{"changes":[{"source_line":1,"before":"original","after":"edited"}]}"#;
        apply_new_file_bytes_with_evidence(
            &source,
            &output,
            b"edited",
            &digest(b"original"),
            InjectFault::AfterStage,
            Some(evidence),
        )
        .unwrap_err();
        let txn = transaction_dir(&output);
        assert_eq!(fs::read(txn.join("edit-evidence.json")).unwrap(), evidence);
        fs::write(txn.join("edit-evidence.json"), b"corrupt").unwrap();
        assert_eq!(recover(&txn).unwrap_err().code, ErrorCode::Transaction);
        assert!(!output.exists());
        fs::write(txn.join("edit-evidence.json"), evidence).unwrap();
        assert!(recover(&txn).unwrap().output_exists);
        assert!(recover(&txn).unwrap().output_exists);
        assert_eq!(fs::read(&source).unwrap(), b"original");
        assert_eq!(fs::read(&output).unwrap(), b"edited");
        let _ = fs::remove_dir_all(root);
    }
}
