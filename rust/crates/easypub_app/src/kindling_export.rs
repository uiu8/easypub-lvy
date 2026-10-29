//! Confirmed AZW3, dual MOBI or KFX export. Engine output is private until the recoverable transaction.
use crate::{
    epub_export::{output_path_for, source_matches},
    managed_process::{self, Outcome},
    publication_resources,
    transaction::{self, InjectFault},
};
use easypub_core::{ApiError, ErrorCode, source::SourceSnapshot};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    ffi::OsStr,
    fs::{self, File},
    io::{Cursor, Read, Write},
    path::{Path, PathBuf},
    sync::Mutex,
    time::Duration,
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
    engine_path: String,
    #[serde(default)]
    format: KindleFormat,
    #[serde(default)]
    plan_id: Option<String>,
    #[serde(default)]
    confirmed: bool,
    /// 保持原格式（V27，OUT-079）：原 EPUB 的路径；给出时用修补后的原 EPUB 作转换器输入。
    #[serde(default)]
    original_epub: Option<String>,
}
#[derive(Clone, Copy, Default, Deserialize)]
#[serde(rename_all = "lowercase")]
enum KindleFormat {
    #[default]
    Azw3,
    Mobi,
    Kfx,
}
impl KindleFormat {
    fn extension(self) -> &'static str {
        match self {
            Self::Azw3 => "azw3",
            Self::Mobi => "mobi",
            Self::Kfx => "kfx",
        }
    }
}
struct State {
    phase: &'static str,
    cancel: bool,
    directory: Option<PathBuf>,
}
pub struct Control {
    state: Mutex<State>,
}
impl Default for Control {
    fn default() -> Self {
        Self {
            state: Mutex::new(State {
                phase: "preparing",
                cancel: false,
                directory: None,
            }),
        }
    }
}
impl Control {
    pub fn snapshot(&self) -> Value {
        let state = self.state.lock().unwrap();
        json!({"phase":state.phase,"cancel_requested":state.cancel,"conversion_directory":state.directory,"cancellable":!matches!(state.phase,"publishing"|"completed"|"failed"|"cancelled")})
    }
    pub fn cancel(&self) -> bool {
        let mut state = self.state.lock().unwrap();
        if matches!(
            state.phase,
            "publishing" | "completed" | "failed" | "cancelled"
        ) {
            return false;
        }
        state.cancel = true;
        true
    }
    fn cancelled(&self) -> bool {
        self.state.lock().unwrap().cancel
    }
    pub(crate) fn enter(&self, phase: &'static str) -> Result<(), ApiError> {
        let mut state = self.state.lock().unwrap();
        if state.cancel {
            return Err(error(ErrorCode::Cancelled, "export_cancelled"));
        }
        state.phase = phase;
        Ok(())
    }
}
/// 转换引擎的工作线程数（V37，OUT-082）：Kindling 用 `--threads`，Bokai 用 `--max-workers`。
pub(crate) const KINDLING_THREADS: &str = "4";
const BOKAI_WORKERS: &str = "4";
fn error(code: ErrorCode, action: &str) -> ApiError {
    ApiError::new(code, "kindling_export", action)
}
/// `build --help` 的说明里是否有 `--threads`（V37）与 `--no-embed-source`（V117）：用户在设置里自选的
/// 旧版 Kindling 或其他程序没有这些参数，传了会直接失败。按引擎哈希缓存，同一个程序只问一次；
/// 问不出来（超时、退出码非 0）按不支持处理。
fn kindling_flags(
    engine: &Path,
    engine_hash: &str,
    stage: &Path,
    cancelled: impl Fn() -> bool,
) -> Result<(bool, bool), ApiError> {
    static KNOWN: std::sync::OnceLock<Mutex<std::collections::HashMap<String, (bool, bool)>>> =
        std::sync::OnceLock::new();
    let known = KNOWN.get_or_init(Default::default);
    if let Some(&answer) = known.lock().unwrap().get(engine_hash) {
        return Ok(answer);
    }
    let log = stage.join("engine-help.log");
    let outcome = managed_process::run(
        engine,
        &[OsStr::new("build"), OsStr::new("--help")],
        stage,
        &log,
        Duration::from_secs(20),
        cancelled,
    )
    .map_err(io_error)?;
    if matches!(outcome, Outcome::Cancelled) {
        return Err(error(ErrorCode::Cancelled, "export_cancelled"));
    }
    let help = match outcome {
        Outcome::Exited(0) => fs::read_to_string(&log).unwrap_or_default(),
        _ => String::new(),
    };
    let answer = (
        help.contains("--threads"),
        help.contains("--no-embed-source"),
    );
    let _ = fs::remove_file(&log);
    known
        .lock()
        .unwrap()
        .insert(engine_hash.to_string(), answer);
    Ok(answer)
}
fn io_error(_: std::io::Error) -> ApiError {
    error(ErrorCode::Io, "review_export_files_and_log")
}
fn fingerprint(path: &Path) -> Result<String, ApiError> {
    let mut file = File::open(path).map_err(io_error)?;
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 65536];
    let mut total = 0usize;
    loop {
        let size = file.read(&mut buffer).map_err(io_error)?;
        if size == 0 {
            break;
        }
        total += size;
        if total > 256 * 1024 * 1024 {
            return Err(error(ErrorCode::TooLarge, "choose_supported_engine"));
        }
        hash.update(&buffer[..size]);
    }
    Ok(format!("{:x}", hash.finalize()))
}
pub fn parse(request: &str) -> Result<Request, ApiError> {
    if request.len() > 4 * 1024 * 1024 {
        return Err(error(ErrorCode::TooLarge, "reduce_export_request"));
    }
    serde_json::from_str(request)
        .map_err(|_| error(ErrorCode::InvalidRule, "review_export_request"))
}
pub fn execute(
    source: &SourceSnapshot,
    request: Request,
    control: &Control,
) -> Result<Value, ApiError> {
    let result = execute_inner(source, request, control);
    control.state.lock().unwrap().phase = match &result {
        Ok(_) => "completed",
        Err(e) if e.code == ErrorCode::Cancelled => "cancelled",
        Err(_) => "failed",
    };
    result
}
fn execute_inner(
    source: &SourceSnapshot,
    request: Request,
    control: &Control,
) -> Result<Value, ApiError> {
    control.enter("preparing")?;
    if matches!(request.op, Operation::Commit) && (!request.confirmed || request.plan_id.is_none())
    {
        return Err(error(ErrorCode::InvalidRule, "preview_and_confirm_export"));
    }
    let source_path = Path::new(&request.source_path)
        .canonicalize()
        .map_err(io_error)?;
    let output = output_path_for(&request.output_path, request.format.extension())?;
    let engine = Path::new(&request.engine_path)
        .canonicalize()
        .map_err(io_error)?;
    if !engine.is_file()
        || engine
            .extension()
            .is_none_or(|e| !e.eq_ignore_ascii_case("exe"))
    {
        return Err(error(ErrorCode::InvalidRule, "choose_kindling_executable"));
    }
    let engine_hash = fingerprint(&engine)?;
    source_matches(&source_path, source.original_bytes())?;
    let prepared = publication_resources::prepare(source, request.publication)?;
    let source_hash = format!("{:x}", Sha256::digest(source.original_bytes()));
    let is_kfx = matches!(request.format, KindleFormat::Kfx);
    let is_azw3 = matches!(request.format, KindleFormat::Azw3);
    let engine_name = if is_kfx { "bokai" } else { "kindling" };
    let original = request
        .original_epub
        .as_deref()
        .map(crate::epub_passthrough::read_original)
        .transpose()?;
    let mut plan = json!({"schema":1,"format":format!("{}-{}", request.format.extension(), engine_name),"publication_id":prepared.id(),"source_sha256":source_hash,
        "source_path":source_path,"output_path":output,"engine_path":engine,"engine_sha256":engine_hash,
        "original_epub_sha256":original.as_ref().map(|o|o.sha256.clone())});
    if is_azw3 {
        plan["document_type"] = json!("EBOK");
    }
    let plan_id = format!("{:x}", Sha256::digest(plan.to_string().as_bytes()));
    if matches!(request.op, Operation::Commit) && request.plan_id.as_deref() != Some(&plan_id) {
        return Err(error(ErrorCode::StaleRevision, "reopen_preview"));
    }
    let mut passthrough = None;
    let input = if let Some(original) = &original {
        let (bytes, report) = crate::epub_passthrough::rebuild(
            &original.bytes,
            &crate::epub_passthrough::Overrides::from_prepared(&prepared, !is_kfx, is_kfx),
        )?;
        passthrough = Some(report);
        bytes
    } else if is_kfx {
        crate::epub::write_bokai_input(&prepared, Cursor::new(Vec::new()))?.into_inner()
    } else {
        crate::epub::write_kindling_input(&prepared, Cursor::new(Vec::new()))?.into_inner()
    };
    source_matches(&source_path, source.original_bytes())?;
    control.enter("prepared")?;
    if matches!(request.op, Operation::Preview) {
        return Ok(
            json!({"plan_id":plan_id,"title":prepared.manifest().title,"node_count":prepared.book().tree.nodes.len(),
            "input_bytes":input.len(),"output_path":output,"engine_path":engine,"engine_sha256":engine_hash,"committed":false,"conversion_checked":false,
            "passthrough":passthrough}),
        );
    }
    let workspace = crate::storage::retain_cache("conversion_work").map_err(io_error)?;
    fs::create_dir_all(&workspace).map_err(io_error)?;
    let stage = workspace.join(format!(
        ".easypub-kindling-{}-{}",
        std::process::id(),
        time::OffsetDateTime::now_utc().unix_timestamp_nanos()
    ));
    fs::create_dir(&stage).map_err(io_error)?;
    control.state.lock().unwrap().directory = Some(stage.clone());
    let input_path = stage.join("input.epub");
    let mut file = File::create_new(&input_path).map_err(io_error)?;
    file.write_all(&input).map_err(io_error)?;
    file.sync_all().map_err(io_error)?;
    drop(file);
    drop(input);
    let staged_output = stage.join(format!("output.{}", request.format.extension()));
    let log = stage.join("engine.log");
    fs::write(
        stage.join("plan.json"),
        serde_json::to_vec_pretty(&plan).unwrap(),
    )
    .map_err(io_error)?;
    control.enter("converting")?;
    if fingerprint(&engine)? != engine_hash {
        return Err(error(ErrorCode::StaleRevision, "reopen_preview"));
    }
    let mut arguments = if is_kfx {
        vec![
            OsStr::new("convert"),
            input_path.as_os_str(),
            staged_output.as_os_str(),
            OsStr::new("--max-workers"),
            OsStr::new(BOKAI_WORKERS),
        ]
    } else {
        vec![
            OsStr::new("build"),
            input_path.as_os_str(),
            OsStr::new("-o"),
            staged_output.as_os_str(),
        ]
    };
    // 固定 4 个工作线程（V37，OUT-082）：本地 Kindling 的逐文件步骤可并行，输出与单线程逐字节相同；
    // 实测 4 与 8 线程耗时相近，不占满全部核心，转换时电脑仍能流畅使用。只对支持的版本传。
    let (threads, no_embed) = if is_kfx {
        (false, false)
    } else {
        kindling_flags(&engine, &engine_hash, &stage, || control.cancelled())?
    };
    // 不把中间 EPUB 嵌进 AZW3/MOBI（V117，用户决定一律不嵌）：Kindling 默认把整个 EPUB 存成一条
    // SRCS 记录，只供 Kindle Previewer 使用。书大时这条记录超过 16 MB，会被 Kindling 自己的回读检查
    // 判为 Kindle 打不开而拒绝输出（实测 39 MB 的书，SRCS 60 MB）；不嵌时同一本书 102 MB 降到 39 MB。
    let skip_source = no_embed;
    if skip_source {
        arguments.push(OsStr::new("--no-embed-source"));
    }
    if threads {
        arguments.extend([OsStr::new("--threads"), OsStr::new(KINDLING_THREADS)]);
    }
    // 记入证据：KFX 为 Bokai 的工作线程数；Kindling 不支持时为 null（按引擎默认）。
    let engine_threads = if is_kfx {
        Some(BOKAI_WORKERS)
    } else {
        threads.then_some(KINDLING_THREADS)
    };
    if matches!(request.format, KindleFormat::Mobi) {
        arguments.push(OsStr::new("--legacy-mobi"));
    }
    if is_azw3 {
        // OUT-087：类型和配套 EXTH 113 由引擎一起写入，Calibre 用两者关联设备封面。
        // Kindling 从 EPUB 标识确定性生成 UUID，同一出版快照重复转换不会更换标识。
        arguments.extend([OsStr::new("--doc-type"), OsStr::new("ebok")]);
    }
    let outcome = managed_process::run(
        &engine,
        &arguments,
        &stage,
        &log,
        Duration::from_secs(600),
        || control.cancelled(),
    )
    .map_err(io_error)?;
    match outcome {
        Outcome::Exited(0) => (),
        Outcome::Cancelled => return Err(error(ErrorCode::Cancelled, "export_cancelled")),
        Outcome::TimedOut => return Err(error(ErrorCode::Io, "engine_timed_out_review_log")),
        Outcome::LogLimit => return Err(error(ErrorCode::TooLarge, "engine_log_limit_review_log")),
        Outcome::Exited(_) => return Err(error(ErrorCode::Io, "engine_failed_review_log")),
    }
    control.enter("checking")?;
    if fingerprint(&engine)? != engine_hash {
        return Err(error(ErrorCode::StaleRevision, "reopen_preview"));
    }
    let metadata = fs::symlink_metadata(&staged_output).map_err(io_error)?;
    if !metadata.is_file() || metadata.len() > 512 * 1024 * 1024 {
        return Err(error(ErrorCode::TooLarge, "review_engine_output"));
    }
    let mut bytes = Vec::new();
    File::open(&staged_output)
        .map_err(io_error)?
        .take(512 * 1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(io_error)?;
    if bytes.len() > 512 * 1024 * 1024
        || if is_kfx {
            !crate::kfx_package::valid_header(&bytes)
        } else {
            bytes.get(60..68) != Some(b"BOOKMOBI".as_slice())
        }
    {
        return Err(error(ErrorCode::InvalidRule, "review_engine_output"));
    }
    let m = prepared.manifest();
    let metadata_checked = if is_kfx {
        let validation_log = stage.join("validation.log");
        match managed_process::run(
            &engine,
            &[
                OsStr::new("validate"),
                OsStr::new("all"),
                input_path.as_os_str(),
                staged_output.as_os_str(),
            ],
            &stage,
            &validation_log,
            Duration::from_secs(600),
            || control.cancelled(),
        )
        .map_err(io_error)?
        {
            Outcome::Exited(0) => {
                json!({"format":"KFX", "validator":"bokai validate all", "passed":true,
                "log":validation_log,"log_sha256":fingerprint(&validation_log)?})
            }
            Outcome::Cancelled => return Err(error(ErrorCode::Cancelled, "export_cancelled")),
            // 保持原格式（V27）：原 EPUB 的样式不一定都被 Bokai 支持。正文、图片、链接、注音、
            // 书写方向都完整保留时接受，并记下没能保留的样式；内容有缺失仍然拒绝。
            _ if original.is_some() => {
                let text = fs::read_to_string(&validation_log).unwrap_or_default();
                let Some(dropped) = crate::epub_passthrough::content_preserved(&text) else {
                    return Err(error(
                        ErrorCode::InvalidRule,
                        "kfx_validation_failed_review_log",
                    ));
                };
                json!({"format":"KFX", "validator":"bokai validate all", "passed":true,
                    "content_only":true, "dropped_styles":dropped,
                    "log":validation_log,"log_sha256":fingerprint(&validation_log)?})
            }
            _ => {
                return Err(error(
                    ErrorCode::InvalidRule,
                    "kfx_validation_failed_review_log",
                ));
            }
        }
    } else {
        json!(crate::kindle_metadata::verify_format(
            &bytes,
            matches!(request.format, KindleFormat::Mobi),
            &[
                (503, "title", &m.title),
                (100, "author", &m.author),
                (101, "publisher", &m.publisher),
                (103, "description", &m.description),
                (104, "isbn", &m.isbn),
                (108, "translator_contributor", &m.translator),
                (105, "category", &m.category),
                (106, "publication_date", &m.publication_date),
                (524, "language", &m.language),
            ],
        )?)
    };
    let kindle_identity = if is_azw3 {
        let details = crate::kindle_metadata::inspect_details(&bytes, false)?;
        if details.content_type.as_deref() != Some("EBOK") || details.content_id.is_none() {
            return Err(ApiError::new(
                ErrorCode::InvalidRule,
                "kindle_metadata",
                "engine_metadata_mismatch",
            ));
        }
        Some(json!({"content_type":details.content_type,"content_id":details.content_id}))
    } else {
        None
    };
    source_matches(&source_path, source.original_bytes())?;
    let evidence = serde_json::to_vec(
        &json!({"plan_id":plan_id,"plan":plan,"manifest":prepared.manifest(),
        "engine_log":log,"engine_log_sha256":fingerprint(&log)?,"engine_threads":engine_threads,"embedded_source":!is_kfx && !skip_source,"conversion_directory":stage,"metadata_checked":metadata_checked,"kindle_identity":kindle_identity}),
    )
    .unwrap();
    // Cancellation and the start of non-interruptible publication share one lock.
    control.enter("publishing")?;
    let transaction = transaction::apply_new_file_bytes_with_evidence(
        &source_path,
        &output,
        &bytes,
        &source_hash,
        InjectFault::None,
        Some(&evidence),
    )?;
    Ok(
        json!({"committed":true,"output_path":output,"byte_length":bytes.len(),"transaction":transaction,"engine_log":log,"engine_threads":engine_threads,"conversion_directory":stage,"kindle_identity":kindle_identity,"expected_metadata":{"title":m.title,"author":m.author,"language":m.language}}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn threads_flag_only_for_engines_that_list_it() {
        let stage = std::env::temp_dir().join(format!(
            "easypub-threads-probe-{}-{}",
            std::process::id(),
            time::OffsetDateTime::now_utc().unix_timestamp_nanos()
        ));
        fs::create_dir_all(&stage).unwrap();
        // 不认识 build --help 的程序：按不支持处理，不报错；同一哈希的答案被缓存，不再运行。
        let other = Path::new(r"C:\Windows\System32\hostname.exe");
        if other.is_file() {
            assert_eq!(
                kindling_flags(other, "probe-hostname", &stage, || false).unwrap(),
                (false, false)
            );
            assert_eq!(
                kindling_flags(Path::new("missing.exe"), "probe-hostname", &stage, || false)
                    .unwrap(),
                (false, false)
            );
        }
        // 本地优化版 Kindling：说明里有 --threads（V37）与 --no-embed-source（V117）。
        let kindling = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../third_party/kindling/target/release/kindling-cli.exe");
        if kindling.is_file() {
            assert_eq!(
                kindling_flags(&kindling, "probe-kindling", &stage, || false).unwrap(),
                (true, true)
            );
        }
        assert!(matches!(
            kindling_flags(other, "probe-cancel", &stage, || true),
            Err(e) if e.code == ErrorCode::Cancelled
        ));
        let _ = fs::remove_dir_all(&stage);
    }
}
