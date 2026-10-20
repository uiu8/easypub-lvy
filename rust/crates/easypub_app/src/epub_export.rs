//! Explicit preview/commit protocol over the existing recoverable new-file transaction.
use crate::{
    publication_resources,
    sessions::ImportService,
    transaction::{self, InjectFault},
};
use easypub_core::{ApiError, ErrorCode, source::SourceSnapshot};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    io::{Cursor, Read},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock},
    time::{Duration, Instant},
};

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Operation {
    Preview,
    Commit,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    op: Operation,
    pub publication: publication_resources::Request,
    source_path: String,
    output_path: String,
    #[serde(default)]
    plan_id: Option<String>,
    #[serde(default)]
    confirmed: bool,
    /// 保持原格式（V27，OUT-079）：原 EPUB 的路径；给出时输出修补后的原 EPUB，不用软件排版。
    #[serde(default)]
    original_epub: Option<String>,
}
fn invalid(code: ErrorCode, action: &'static str) -> ApiError {
    ApiError::new(code, "epub_export", action)
}
pub(crate) fn source_matches(path: &Path, expected: &[u8]) -> Result<(), ApiError> {
    let mut file =
        File::open(path).map_err(|_| invalid(ErrorCode::SourceChanged, "reopen_preview"))?;
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 65536];
    let mut total = 0usize;
    loop {
        let len = file
            .read(&mut buffer)
            .map_err(|_| invalid(ErrorCode::Io, "retry_source_read"))?;
        if len == 0 {
            break;
        }
        total += len;
        if total > expected.len() {
            return Err(invalid(ErrorCode::SourceChanged, "reopen_preview"));
        }
        hash.update(&buffer[..len]);
    }
    if total != expected.len() || hash.finalize() != Sha256::digest(expected) {
        return Err(invalid(ErrorCode::SourceChanged, "reopen_preview"));
    }
    Ok(())
}
fn output_path(value: &str) -> Result<PathBuf, ApiError> {
    output_path_for(value, "epub")
}
pub(crate) fn output_path_for(value: &str, extension: &str) -> Result<PathBuf, ApiError> {
    let path = Path::new(value);
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| invalid(ErrorCode::OutputConflict, "choose_new_epub_path"))?;
    if !path.is_absolute()
        || path
            .extension()
            .and_then(|e| e.to_str())
            .is_none_or(|e| !e.eq_ignore_ascii_case(extension))
        || name.contains(':')
    {
        return Err(invalid(ErrorCode::OutputConflict, "choose_new_epub_path"));
    }
    let parent = path
        .parent()
        .ok_or_else(|| invalid(ErrorCode::OutputConflict, "choose_new_epub_path"))?
        .canonicalize()
        .map_err(|_| invalid(ErrorCode::Io, "choose_existing_output_directory"))?;
    let path = parent.join(name);
    if path.symlink_metadata().is_ok() {
        return Err(invalid(ErrorCode::OutputConflict, "choose_new_epub_path"));
    }
    Ok(path)
}
fn execute(
    source: &SourceSnapshot,
    request: Request,
    fault: InjectFault,
) -> Result<Value, ApiError> {
    execute_controlled(source, request, fault, &|_| Ok(()))
}

// Only the already validated container is retained. Every commit still prepares
// the current resources and verifies its content-derived plan before reuse.
type Artifact = (String, Arc<Vec<u8>>, Instant);
fn artifacts() -> &'static Mutex<Vec<Artifact>> {
    static CACHE: OnceLock<Mutex<Vec<Artifact>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(Vec::new()))
}
pub(crate) fn execute_controlled(source: &SourceSnapshot, request: Request,
    fault: InjectFault, checkpoint: &dyn Fn(&'static str) -> Result<(), ApiError>) -> Result<Value, ApiError> {
    checkpoint("preparing")?;
    if matches!(request.op, Operation::Commit) && (!request.confirmed || request.plan_id.is_none())
    {
        return Err(invalid(
            ErrorCode::InvalidRule,
            "preview_and_confirm_export",
        ));
    }
    let source_path = Path::new(&request.source_path)
        .canonicalize()
        .map_err(|_| invalid(ErrorCode::NotFound, "choose_readable_source"))?;
    let output = output_path(&request.output_path)?;
    source_matches(&source_path, source.original_bytes())?;
    let prepared = publication_resources::prepare(source, request.publication)?;
    let raw_hash = format!("{:x}", Sha256::digest(source.original_bytes()));
    let original = request
        .original_epub
        .as_deref()
        .map(crate::epub_passthrough::read_original)
        .transpose()?;
    let plan = json!({"schema":1,"format":if original.is_some() {"epub-original"} else {"epub3"},"publication_id":prepared.id(),"source_sha256":raw_hash,
        "source_path":source_path,"output_path":output,"original_epub_sha256":original.as_ref().map(|o|o.sha256.clone())});
    let plan_id = format!("{:x}", Sha256::digest(plan.to_string().as_bytes()));
    if matches!(request.op, Operation::Commit) && request.plan_id.as_deref() != Some(&plan_id) {
        return Err(invalid(ErrorCode::StaleRevision, "reopen_preview"));
    }
    checkpoint("converting")?;
    let cached = {
        let mut cache = artifacts().lock().expect("epub artifacts");
        cache.retain(|a| a.2.elapsed() < Duration::from_secs(600));
        cache.iter().find(|a| a.0 == plan_id).map(|a| a.1.clone())
    };
    let reused = cached.is_some();
    let mut passthrough = None;
    let bytes = if let Some(bytes) = cached { bytes } else {
        let bytes = Arc::new(if let Some(original) = &original {
            let (bytes, report) = crate::epub_passthrough::rebuild(
                &original.bytes,
                &crate::epub_passthrough::Overrides::from_prepared(&prepared, false, false),
            )?;
            passthrough = Some(report);
            bytes
        } else {
            crate::epub::write_controlled(&prepared, Cursor::new(Vec::new()), &|| checkpoint("converting"))?.into_inner()
        });
        if bytes.len() <= 128 * 1024 * 1024 {
            let mut cache = artifacts().lock().expect("epub artifacts");
            while !cache.is_empty() && (cache.len() >= 8 || cache.iter().map(|a| a.1.len()).sum::<usize>() + bytes.len() > 128 * 1024 * 1024) {
                cache.remove(0);
            }
            cache.push((plan_id.clone(), bytes.clone(), Instant::now()));
        }
        bytes
    };
    checkpoint("checking")?;
    source_matches(&source_path, source.original_bytes())?;
    match request.op {
        Operation::Preview => Ok(
            json!({"plan_id":plan_id,"publication_id":prepared.id(),"title":prepared.manifest().title,
            "output_path":output,"estimated_bytes":bytes.len(),"node_count":prepared.book().tree.nodes.len(),
            "writes_source":false,"committed":false,"artifact_reused":reused,"passthrough":passthrough}),
        ),
        Operation::Commit => {
            checkpoint("publishing")?;
            let evidence = serde_json::to_vec(
                &json!({"plan_id":plan_id,"plan":plan,"manifest":prepared.manifest()}),
            )
            .map_err(|_| invalid(ErrorCode::Internal, "retry_export"))?;
            let report = transaction::apply_new_file_bytes_with_evidence(
                &source_path,
                &output,
                bytes.as_slice(),
                &raw_hash,
                fault,
                Some(&evidence),
            )?;
            Ok(
                json!({"committed":true,"output_path":output,"byte_length":bytes.len(),"transaction":report,"artifact_reused":reused, "expected_metadata":{"title":prepared.manifest().title,"author":prepared.manifest().author,"language":prepared.manifest().language}}),
            )
        }
    }
}
pub fn handle(service: &ImportService, request_json: String) -> Result<String, ApiError> {
    if request_json.len() > 4 * 1024 * 1024 {
        return Err(invalid(ErrorCode::TooLarge, "reduce_export_request"));
    }
    if serde_json::from_str::<Value>(&request_json).ok().is_some_and(|v| v["op"] == "render_preview") {
        return render_preview(service, &request_json);
    }
    let request = parse(&request_json)?;
    let source = service.source(&request.publication.source_id, request.publication.revision)?;
    Ok(execute(&source, request, InjectFault::None)?.to_string())
}
pub fn parse(request: &str) -> Result<Request, ApiError> {
    if request.len() > 4 * 1024 * 1024 { return Err(invalid(ErrorCode::TooLarge,"reduce_export_request")); }
    serde_json::from_str(request).map_err(|_| invalid(ErrorCode::InvalidRule, "review_export_request"))
}

fn render_preview(service: &ImportService, request: &str) -> Result<String, ApiError> {
    #[derive(Deserialize)]
    struct Preview { publication: publication_resources::Request, entry_id: Option<String> }
    let req: Preview = serde_json::from_str(request).map_err(|_| invalid(ErrorCode::InvalidRule,"review_preview"))?;
    let source = service.source(&req.publication.source_id,req.publication.revision)?;
    let prepared = publication_resources::prepare(&source,req.publication)?;
    // 只打包不压缩：随后马上解开（V83）。
    let bytes = crate::epub::write_unpacked_preview(&prepared,Cursor::new(Vec::new()))?.into_inner();
    let root = std::env::temp_dir().join("EasyPub-content-preview");
    let directory = root.join(format!("{}-{}",std::process::id(),time::OffsetDateTime::now_utc().unix_timestamp_nanos()));
    fs::create_dir_all(&directory).map_err(|_| invalid(ErrorCode::Io,"retry_preview"))?;
    let focus = req.entry_id.as_deref().and_then(|id| prepared.book().tree.nodes.iter().position(|n|n.entry_id==id));
    let anchor = focus.map(|i|format!("node-{i}"));
    let mut selected = None;
    let mut documents = Vec::new();
    let mut archive = zip::ZipArchive::new(Cursor::new(bytes)).map_err(|_| invalid(ErrorCode::Internal,"retry_preview"))?;
    for i in 0..archive.len() {
        let mut item = archive.by_index(i).map_err(|_| invalid(ErrorCode::Internal,"retry_preview"))?;
        let Some(path) = item.enclosed_name() else {continue};
        let Ok(relative) = path.strip_prefix("EPUB") else {continue};
        let target = directory.join(relative);
        if let Some(parent) = target.parent() {fs::create_dir_all(parent).map_err(|_| invalid(ErrorCode::Io,"retry_preview"))?;}
        let mut file = File::create(&target).map_err(|_| invalid(ErrorCode::Io,"retry_preview"))?;
        if relative.extension().is_some_and(|s|s=="xhtml") {
            let mut text = String::new();
            item.read_to_string(&mut text).map_err(|_| invalid(ErrorCode::Io,"retry_preview"))?;
            use std::io::Write;
            file.write_all(text.as_bytes()).map_err(|_| invalid(ErrorCode::Io,"retry_preview"))?;
            if anchor.as_ref().is_some_and(|id|text.contains(&format!("id=\"{id}\""))) {selected=Some(target.clone());}
            documents.push(json!({"path":target,"title":relative.to_string_lossy()}));
        } else { std::io::copy(&mut item,&mut file).map_err(|_| invalid(ErrorCode::Io,"retry_preview"))?; }
    }
    let selected = selected.unwrap_or_else(|| {
        let body = directory.join("body.xhtml");
        if body.is_file() { body } else {
            documents.iter().find_map(|d| d["path"].as_str().map(std::path::PathBuf::from)).unwrap_or(body)
        }
    });
    let relative = selected.strip_prefix(&directory).map_err(|_| invalid(ErrorCode::Internal,"retry_preview"))?
        .to_string_lossy().replace('\\',"/");
    let destination = format!("{}{}",relative,anchor.as_ref().map(|s|format!("#{s}")).unwrap_or_default());
    let html = directory.join("preview.html");
    fs::write(&html, format!("<!doctype html><html lang=\"zh\"><meta charset=\"utf-8\"><title>{}</title><style>html,body,iframe{{margin:0;width:100%;height:100%;border:0;display:block}}</style><iframe title=\"生成内容预览\" src=\"{}\"></iframe></html>",
        crate::navigation_documents::escaped(&prepared.manifest().title)?,
        crate::navigation_documents::escaped(&destination)?)).map_err(|_|invalid(ErrorCode::Io,"retry_preview"))?;
    // Retain only previews created by this process; never enumerate or remove
    // another application's directory, or a user-supplied output path.
    static PREVIEWS: OnceLock<Mutex<Vec<std::path::PathBuf>>> = OnceLock::new();
    let mut previews = PREVIEWS.get_or_init(|| Mutex::new(Vec::new())).lock().expect("preview cache");
    previews.push(directory.clone());
    while previews.len() > 4 {
        let old = previews.remove(0);
        if old.parent() == Some(root.as_path()) && !old.is_symlink() {
            let _ = fs::remove_dir_all(old);
        }
    }
    Ok(json!({"publication_id":prepared.id(),"directory":directory,"selected_path":html,"content_path":selected,
        "anchor":anchor,"documents":documents}).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use easypub_core::source::RULE_ID;
    use std::fs;
    #[test]
    fn preview_consent_staleness_and_recoverable_epub_publication() {
        let dir = std::env::temp_dir().join(format!(
            "easypub-epub-export-{}-{}",
            std::process::id(),
            time::OffsetDateTime::now_utc().unix_timestamp_nanos()
        ));
        fs::create_dir(&dir).unwrap();
        let input = dir.join("source.txt");
        let output = dir.join("book.epub");
        let original = "第一章 开始\r\n正文<&>".as_bytes();
        fs::write(&input, original).unwrap();
        let source = SourceSnapshot::from_utf8(original.to_vec(), RULE_ID, || false).unwrap();
        let mut request = json!({"op":"preview","source_path":input,"output_path":output,
            "publication":{"source_id":source.summary().source_id,"revision":1,
              "settings":{"title":"样书", "author":"作者", "description":"", "cover_fit":"contain",
              "font_family":"SimSun", "font_size":18, "line_height":1.8, "include_toc":true,"illustrations":[]}}});
        let run = |value: &Value, fault| {
            execute(
                &source,
                serde_json::from_value(value.clone()).unwrap(),
                fault,
            )
        };
        for language in ["", "und", "UND"] {
            request["publication"]["settings"]["language"] = json!(language);
            assert_eq!(
                run(&request, InjectFault::None).unwrap_err().next_action,
                "choose_publication_language"
            );
            assert_eq!(fs::read_dir(&dir).unwrap().count(), 1);
        }
        request["publication"]["settings"]["language"] = json!("zh");
        let preview = run(&request, InjectFault::None).unwrap();
        assert!(!output.exists());
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 1);
        request["op"] = json!("commit");
        request["plan_id"] = preview["plan_id"].clone();
        assert!(run(&request, InjectFault::None).is_err());
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 1);
        request["confirmed"] = json!(true);
        let mut stale = request.clone();
        stale["publication"]["settings"]["title"] = json!("改变");
        assert_eq!(
            run(&stale, InjectFault::None).unwrap_err().code,
            ErrorCode::StaleRevision
        );
        stale = request.clone();
        stale["output_path"] = json!(dir.join("other.epub"));
        assert_eq!(
            run(&stale, InjectFault::None).unwrap_err().code,
            ErrorCode::StaleRevision
        );
        fs::write(&input, "变化").unwrap();
        assert_eq!(
            run(&request, InjectFault::None).unwrap_err().code,
            ErrorCode::SourceChanged
        );
        fs::write(&input, original).unwrap();
        assert!(run(&request, InjectFault::AfterStage).is_err());
        assert!(!output.exists());
        let txn = dir.join(".book.epub.easypub-txn");
        assert_eq!(fs::read(txn.join("source-backup.bin")).unwrap(), original);
        assert!(txn.join("edit-evidence.json").is_file());
        let report = transaction::recover(&txn).unwrap();
        assert!(report.output_exists && report.source_unchanged);
        let bytes = fs::read(&output).unwrap();
        let mut zip = zip::ZipArchive::new(Cursor::new(&bytes)).unwrap();
        assert_eq!(zip.by_index(0).unwrap().name(), "mimetype");
        assert_eq!(fs::read(&input).unwrap(), original);
        assert!(run(&request, InjectFault::None).is_err());
        assert_eq!(fs::read(&output).unwrap(), bytes);
        assert!(transaction::recover(&txn).unwrap().output_exists);
        let mut request2 = request.clone();
        request2["output_path"] = json!(dir.join("normal.epub"));
        request2["op"] = json!("preview");
        let preview2 = run(&request2, InjectFault::None).unwrap();
        request2["op"] = json!("commit");
        request2["plan_id"] = preview2["plan_id"].clone();
        let cancelled = execute_controlled(&source, serde_json::from_value(request2.clone()).unwrap(),
            InjectFault::None, &|phase| if phase == "checking" {
                Err(ApiError::new(ErrorCode::Cancelled,"epub_export","retry_export"))
            } else { Ok(()) });
        assert_eq!(cancelled.unwrap_err().code, ErrorCode::Cancelled);
        assert!(!dir.join("normal.epub").exists());
        let receipt = run(&request2, InjectFault::None).unwrap();
        assert_eq!(receipt["committed"], true);
        assert_eq!(receipt["artifact_reused"], true);
        assert_eq!(receipt["transaction"]["source_unchanged"], true);
        fs::remove_dir_all(dir).unwrap();
    }
}
