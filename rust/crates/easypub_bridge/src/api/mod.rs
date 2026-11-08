//! The only Rust-to-Dart application boundary for the R1 experiment.
use easypub_app::sessions::ImportService;
pub use easypub_core::ApiError;
use easypub_core::source::SourceCursor;
use std::sync::OnceLock;

use crate::frb_generated::StreamSink;

static SERVICE: OnceLock<Result<ImportService, ApiError>> = OnceLock::new();

fn service() -> Result<&'static ImportService, ApiError> {
    SERVICE
        .get_or_init(ImportService::new)
        .as_ref()
        .map_err(Clone::clone)
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

pub fn effective_structure_text(
    source_id: String,
    revision: u32,
    settings_json: String,
    selected_json: String,
    offset: u32,
) -> Result<String, ApiError> {
    service()?.effective_structure_text(source_id, revision, settings_json, selected_json, offset)
}

pub fn chapter_structure_text(
    source_id: String,
    revision: u32,
    settings_json: String,
    change_json: String,
    offset: u32,
) -> Result<String, ApiError> {
    service()?.structure_text(source_id, revision, settings_json, change_json, offset)
}

pub fn edit_manual_draft(
    source_id: String,
    revision: u32,
    draft_json: String,
    command_json: String,
) -> Result<String, ApiError> {
    easypub_app::manual_draft::edit(service()?, source_id, revision, draft_json, command_json)
}

pub fn edit_cleanup_draft(
    source_id: String,
    revision: u32,
    draft_json: String,
    command_json: String,
) -> Result<String, ApiError> {
    easypub_app::cleanup_draft::edit(service()?, source_id, revision, draft_json, command_json)
}

pub fn cleanup_batch_text(
    request_json: String,
    apply: bool,
    plan_id: String,
    confirmed: bool,
) -> Result<String, ApiError> {
    easypub_app::cleanup_batch::run(service()?, request_json, apply, plan_id, confirmed)
}

pub fn start_import(path: String, rule_id: String) -> Result<u32, ApiError> {
    service()?.start_import(path, rule_id)
}
pub fn start_cancellation_probe() -> Result<u32, ApiError> {
    service()?.start_cancellation_probe()
}
/// 导入任务阶段（桥接第 2 批：有类型的状态，界面不再拆分文字）。
pub enum ImportPhase {
    Reading,
    Indexing,
    CancellationProbe,
    Cancelling,
    Completed,
    Cancelled,
    Failed,
}

/// 导入完成后的书稿摘要。
pub struct ImportedSource {
    pub source_id: String,
    pub revision: u32,
    pub lines: u32,
    pub chapters: u32,
    pub encoding: String,
}

/// 失败原因：错误代码（如 `NotFound`、`TooLarge`）、出错的操作和建议的下一步。
pub struct JobFailure {
    pub code: String,
    pub operation: String,
    pub next_action: String,
}

pub struct ImportJobStatus {
    pub phase: ImportPhase,
    pub sequence: u32,
    pub processed_bytes: u32,
    pub source: Option<ImportedSource>,
    pub failure: Option<JobFailure>,
}

fn import_status(job: &easypub_app::sessions::JobSnapshot) -> ImportJobStatus {
    use easypub_app::sessions::JobPhase as P;
    ImportJobStatus {
        phase: match job.phase {
            P::Reading => ImportPhase::Reading,
            P::Indexing => ImportPhase::Indexing,
            P::CancellationProbe => ImportPhase::CancellationProbe,
            P::Cancelling => ImportPhase::Cancelling,
            P::Completed => ImportPhase::Completed,
            P::Cancelled => ImportPhase::Cancelled,
            P::Failed => ImportPhase::Failed,
        },
        sequence: job.sequence,
        processed_bytes: job.processed_bytes,
        source: job.book.as_ref().map(|book| ImportedSource {
            source_id: book.source_id.clone(),
            revision: book.revision,
            lines: book.line_count,
            chapters: book.chapter_count,
            encoding: book.encoding.clone(),
        }),
        failure: job.error.as_ref().map(|e| JobFailure {
            code: format!("{:?}", e.code),
            operation: e.operation.clone(),
            next_action: e.next_action.clone(),
        }),
    }
}

/// 导入任务当前状态（有类型）。
pub fn import_job_status(job_id: u32) -> Result<ImportJobStatus, ApiError> {
    Ok(import_status(&service()?.get_job(job_id)?))
}

/// 推送导入任务状态（有类型，桥接第 2 批）：每次变化送出一条，到终态为止。
pub fn import_job_status_watch(
    job_id: u32,
    sink: StreamSink<ImportJobStatus>,
) -> Result<(), ApiError> {
    let service = service()?;
    service.get_job(job_id)?;
    std::thread::Builder::new()
        .name(format!("import-watch-{job_id}"))
        .spawn(move || {
            let outcome = service.watch_job(job_id, |job| sink.add(import_status(job)).is_ok());
            if let Err(e) = outcome {
                let _ = sink.add_error(e);
            }
        })
        .map_err(|_| ApiError::new(easypub_core::ErrorCode::Io, "import_watch", "retry_import"))?;
    Ok(())
}

/// 原文的一行（行号从 1 起）。
pub struct SourceLine {
    pub line_number: u32,
    pub text: String,
}

pub struct SourceLines {
    pub lines: Vec<SourceLine>,
    /// 下一页从哪一行（0 起）开始；没有了为空。
    pub next_line_index: Option<u32>,
}

/// 读原文若干行（有类型，桥接第 2 批）。
pub fn read_source_lines(
    source_id: String,
    revision: u32,
    line_index: u32,
    utf8_column: u32,
    limit: u32,
) -> Result<SourceLines, ApiError> {
    let page = service()?.read_page(
        source_id,
        revision,
        SourceCursor {
            line_index,
            utf8_column,
        },
        limit,
    )?;
    Ok(SourceLines {
        lines: page
            .items
            .into_iter()
            .map(|item| SourceLine {
                line_number: item.line_number,
                text: item.text,
            })
            .collect(),
        next_line_index: page.next_cursor.map(|c| c.line_index),
    })
}

/// 完整目录里的一个节点。`role` 为 volume / chapter / section / front / body。
pub struct OutlineNode {
    pub entry_id: String,
    pub title: String,
    pub role: String,
    pub depth: u8,
    pub source_line: u32,
    pub include_toc: bool,
}

pub struct EffectiveOutline {
    pub nodes: Vec<OutlineNode>,
    pub total: u32,
}

/// 完整目录（有类型，桥接第 2 批）：`composition_key` 来自 `effective_structure_text`。
/// 一万章的书原来要拼约 2.6 MB 的 JSON 再在界面线程解析；现在直接交结构体。
pub fn effective_outline(
    source_id: String,
    revision: u32,
    composition_key: String,
) -> Result<EffectiveOutline, ApiError> {
    use easypub_core::structure::Role;
    let (nodes, total) =
        service()?.effective_outline(&source_id, revision, &composition_key, |n| OutlineNode {
            entry_id: n.entry_id.clone(),
            title: n.title.clone(),
            role: match n.role {
                Role::Volume => "volume",
                Role::Chapter => "chapter",
                Role::Section => "section",
                Role::Front => "front",
                Role::Body => "body",
            }
            .to_owned(),
            depth: n.depth,
            source_line: n.source_line,
            include_toc: n.include_toc,
        })?;
    Ok(EffectiveOutline {
        nodes,
        total: total as u32,
    })
}

pub fn duplicate_blocks_text(
    source_id: String,
    revision: u32,
    offset: u32,
) -> Result<String, ApiError> {
    service()?.duplicate_blocks(source_id, revision, offset)
}
pub fn cleanup_presets_text() -> String {
    easypub_core::cleanup_rules::presets().to_string()
}
pub fn preview_repair_plan_text(
    source_id: String,
    revision: u32,
    selected_json: String,
) -> Result<String, ApiError> {
    service()?.preview_repair_plan(source_id, revision, selected_json)
}
pub fn commit_repair_output_text(
    source_id: String,
    revision: u32,
    source_path: String,
    output_path: String,
    selected_json: String,
    plan_id: String,
    confirmed: bool,
) -> Result<String, ApiError> {
    service()?.commit_repair_output(
        source_id,
        revision,
        source_path,
        output_path,
        selected_json,
        plan_id,
        confirmed,
    )
}
fn project_error(error: ApiError) -> String {
    serde_json::json!({"error": format!("{:?}", error.code), "operation": error.operation})
        .to_string()
}
/// One request boundary; credential is transient and omitted from all reports.
pub fn catalog_request_text(request: String, cookie: String) -> String {
    match service().and_then(|s| easypub_app::catalog::execute(s, &request, &cookie)) {
        Ok(value) => value.to_string(),
        Err(error) => {
            serde_json::json!({"error": format!("{:?}", error.code), "reason":error.next_action})
                .to_string()
        }
    }
}
pub fn save_project_text(path: String, payload: String) -> String {
    match service().and_then(|s| easypub_app::project::save(s, &path, &payload)) {
        Ok(()) => "{\"ok\":true}".into(),
        Err(error) => project_error(error),
    }
}
pub fn open_project_text(path: String) -> String {
    service()
        .and_then(|s| easypub_app::project::open(s, &path))
        .unwrap_or_else(project_error)
}

pub fn save_recovery_project_text(path: String, payload: String) -> String {
    match service().and_then(|s| easypub_app::project::save_recovery(s, &path, &payload)) {
        Ok(()) => "{\"ok\":true}".into(),
        Err(error) => project_error(error),
    }
}

pub fn clear_workspace_text(output: String, format: String) -> Result<String, ApiError> {
    easypub_app::project::clear_workspace(service()?, output, format)
}

/// Preview or confirm a source-bound production settings batch.
pub fn production_batch_text(
    request_json: String,
    apply: bool,
    plan_id: String,
    confirmed: bool,
) -> Result<String, ApiError> {
    easypub_app::production::run(service()?, request_json, apply, plan_id, confirmed)
}

pub fn illustration_positions_text(
    source_id: String,
    revision: u32,
    request_json: String,
) -> Result<String, ApiError> {
    easypub_app::production::illustration_positions(service()?, source_id, revision, request_json)
}

pub fn publication_resources_text(request_json: String) -> Result<String, ApiError> {
    easypub_app::publication_resources::preview(service()?, request_json)
}

pub fn epub_export_text(request_json: String) -> Result<String, ApiError> {
    easypub_app::epub_export::handle(service()?, request_json)
}

/// Chapter rule defaults, validation and source-bound recognition previews.
pub fn chapter_rules_text(request_json: String) -> Result<String, ApiError> {
    easypub_app::chapter_rule_service::request(service()?, &request_json)
}

/// Extract an EPUB into a new UTF-8 TXT working copy without modifying the source.
pub fn import_epub_text(
    source_path: String,
    output_path: String,
    keep_marks: bool,
) -> Result<String, ApiError> {
    easypub_app::epub_import::extract(&source_path, &output_path, keep_marks)
}

/// Extract EPUB cover, image, CSS and font resources into a private directory.
pub fn import_epub_resources(
    source_path: String,
    resource_dir: String,
    keep_marks: bool,
) -> Result<String, ApiError> {
    easypub_app::epub_import::extract_resources(&source_path, &resource_dir, keep_marks)
}

/// 选编码窗口的数据：每种编码解不解得开、前 30 行（G-114）。
pub fn probe_text_encoding(path: String) -> Result<String, ApiError> {
    easypub_app::text_encoding::probe(&path)
}

/// 自动判断成 GBK 的文件像不像乱码。
pub fn text_encoding_suspect(path: String) -> Result<bool, ApiError> {
    easypub_app::text_encoding::suspect(&path)
}

/// 按选定的编码转成 UTF-8 工作稿，原文件不动。
pub fn transcode_text(
    source_path: String,
    encoding: String,
    output_path: String,
) -> Result<(), ApiError> {
    easypub_app::text_encoding::transcode(&source_path, &encoding, &output_path)
}

/// Read inline styles of a book already in the library; the extracted text must
/// match its working copy exactly.
pub fn reread_epub_marks(
    source_path: String,
    text_path: String,
    resource_dir: String,
) -> Result<String, ApiError> {
    easypub_app::epub_import::reread_marks(&source_path, &text_path, &resource_dir)
}

#[cfg(windows)]
fn kindling_jobs() -> &'static easypub_app::kindling_jobs::Manager {
    static JOBS: OnceLock<easypub_app::kindling_jobs::Manager> = OnceLock::new();
    JOBS.get_or_init(Default::default)
}

pub fn kindling_job_text(request_json: String) -> Result<String, ApiError> {
    #[cfg(windows)]
    {
        kindling_jobs().handle(service()?, &request_json)
    }
    #[cfg(not(windows))]
    {
        let _ = request_json;
        Err(ApiError::new(
            easypub_core::ErrorCode::UnsupportedRule,
            "kindling_jobs",
            "windows_required",
        ))
    }
}

/// 转换任务状态（有类型，桥接第 2 批）。`phase` 为 preparing / converting / publishing /
/// completed / failed / cancelled 等阶段名；完成时 `result_json` 是转换结果，失败或取消时有 `failure`。
pub struct KindlingJobStatus {
    pub phase: String,
    pub terminal: bool,
    pub cancellable: bool,
    pub cancel_requested: bool,
    pub result_json: Option<String>,
    pub failure: Option<JobFailure>,
}

#[cfg(windows)]
fn kindling_status(snapshot: &serde_json::Value) -> KindlingJobStatus {
    let text = |key: &str| snapshot[key].as_str().unwrap_or_default().to_owned();
    KindlingJobStatus {
        phase: text("phase"),
        terminal: snapshot["terminal"] == true,
        cancellable: snapshot["cancellable"] == true,
        cancel_requested: snapshot["cancel_requested"] == true,
        result_json: snapshot.get("result").map(|v| v.to_string()),
        failure: snapshot.get("error").map(|e| JobFailure {
            code: e["code"].as_str().unwrap_or_default().to_owned(),
            operation: e["operation"].as_str().unwrap_or_default().to_owned(),
            next_action: e["next_action"].as_str().unwrap_or_default().to_owned(),
        }),
    }
}

/// 推送转换任务状态（桥接第 1 批起；第 2 批改为有类型）：每次变化送出一条，到终态为止。
/// 任务仍需由界面 `forget` 释放。
pub fn kindling_job_watch(
    job_id: i64,
    sink: StreamSink<KindlingJobStatus>,
) -> Result<(), ApiError> {
    #[cfg(windows)]
    {
        let id = u64::try_from(job_id).map_err(|_| {
            ApiError::new(
                easypub_core::ErrorCode::NotFound,
                "kindling_jobs",
                "refresh_export_jobs",
            )
        })?;
        let jobs = kindling_jobs();
        jobs.status(id)?;
        std::thread::Builder::new()
            .name(format!("kindling-watch-{id}"))
            .spawn(move || {
                let outcome = jobs.watch(id, |snapshot| sink.add(kindling_status(snapshot)).is_ok());
                if let Err(e) = outcome {
                    let _ = sink.add_error(e);
                }
            })
            .map_err(|_| {
                ApiError::new(
                    easypub_core::ErrorCode::Io,
                    "kindling_jobs",
                    "retry_export_worker",
                )
            })?;
        Ok(())
    }
    #[cfg(not(windows))]
    {
        let _ = (job_id, sink);
        Err(ApiError::new(
            easypub_core::ErrorCode::UnsupportedRule,
            "kindling_jobs",
            "windows_required",
        ))
    }
}

pub fn review_findings_text(
    source_id: String,
    revision: u32,
    request_json: String,
) -> Result<String, ApiError> {
    service()?.review_findings(source_id, revision, request_json)
}

pub fn edit_structure_draft(
    source_id: String,
    revision: u32,
    draft_json: String,
    command_json: String,
) -> Result<String, ApiError> {
    easypub_app::structure_draft::edit(service()?, source_id, revision, draft_json, command_json)
}

pub fn edit_effective_draft(
    source_id: String,
    revision: u32,
    base_json: String,
    draft_json: String,
    command_json: String,
) -> Result<String, ApiError> {
    easypub_app::effective_draft::edit(
        service()?,
        source_id,
        revision,
        base_json,
        draft_json,
        command_json,
    )
}

/// Explicitly located versioned configuration, independent of book projects.
pub fn load_settings_text(directory: String) -> Result<String, ApiError> {
    let snapshot = easypub_app::settings_store::load(std::path::Path::new(&directory))?;
    serde_json::to_string(&snapshot).map_err(|_| {
        ApiError::new(
            easypub_core::ErrorCode::Internal,
            "settings_store",
            "retry_settings_read",
        )
    })
}
pub fn save_settings_text(
    directory: String,
    expected_token: Option<String>,
    configuration_json: String,
) -> Result<String, ApiError> {
    if configuration_json.len() > easypub_app::settings_store::MAX_EXPANDED_BYTES {
        return Err(ApiError::new(
            easypub_core::ErrorCode::TooLarge,
            "settings_store",
            "reduce_settings_size",
        ));
    }
    let configuration = serde_json::from_str(&configuration_json).map_err(|_| {
        ApiError::new(
            easypub_core::ErrorCode::InvalidRule,
            "settings_store",
            "review_settings",
        )
    })?;
    let snapshot = easypub_app::settings_store::save(
        std::path::Path::new(&directory),
        expected_token.as_deref(),
        configuration,
    )?;
    serde_json::to_string(&snapshot).map_err(|_| {
        ApiError::new(
            easypub_core::ErrorCode::Internal,
            "settings_store",
            "reload_settings",
        )
    })
}
pub fn resolve_layout_settings_text(layers_json: String) -> Result<String, ApiError> {
    easypub_app::layout_settings::resolve_text(&layers_json)
}

pub fn layout_preset_file_text(request_json: String) -> Result<String, ApiError> {
    easypub_app::layout_preset_file::request_text(&request_json)
}

pub fn inspect_legacy_settings_text(path: String) -> Result<String, ApiError> {
    let report = easypub_app::legacy_settings::inspect_file(std::path::Path::new(&path))?;
    serde_json::to_string(&report).map_err(|_| {
        ApiError::new(
            easypub_core::ErrorCode::Internal,
            "legacy_settings",
            "retry_legacy_read",
        )
    })
}

/// V104 存储位置与受控迁移接口。
pub fn storage_text(request_json: String) -> String {
    easypub_app::storage::request(request_json)
}

/// 错误的代码、操作与下一步（桥接第 3 批：有类型，不含原文或文件内容）。
pub struct ApiErrorInfo {
    pub code: String,
    pub operation: String,
    pub next_action: String,
    pub retryable: bool,
}

/// 读出错误详情；同步调用，界面可以在 catch 里直接用。
#[flutter_rust_bridge::frb(sync)]
pub fn api_error_info(error: &ApiError) -> ApiErrorInfo {
    ApiErrorInfo {
        code: format!("{:?}", error.code),
        operation: error.operation.clone(),
        next_action: error.next_action.clone(),
        retryable: error.retryable,
    }
}

/// 取消导入任务；结果看任务状态。
pub fn cancel_import_job(job_id: u32) -> Result<(), ApiError> {
    service()?.cancel_job(job_id).map(|_| ())
}

/// 章节列表里的一项。
pub struct ChapterEntry {
    pub source_line: u32,
    pub title: String,
}

pub struct ChapterEntries {
    pub entries: Vec<ChapterEntry>,
    pub next_offset: Option<u32>,
    pub total: u32,
}

/// 按原文识别的章节列表，分页读取（有类型，桥接第 3 批）。
pub fn read_chapter_entries(
    source_id: String,
    revision: u32,
    offset: u32,
    limit: u32,
) -> Result<ChapterEntries, ApiError> {
    let page = service()?.chapter_page(source_id, revision, offset, limit)?;
    Ok(ChapterEntries {
        entries: page
            .items
            .into_iter()
            .map(|item| ChapterEntry {
                source_line: item.source_line,
                title: item.title,
            })
            .collect(),
        next_offset: page.next_offset,
        total: page.total,
    })
}

/// 图片的内容标识与尺寸。
pub struct ImageReport {
    pub path: String,
    pub sha256: String,
    pub bytes: i64,
    pub width: u32,
    pub height: u32,
    pub format: String,
}

/// 解码图片并返回内容标识与尺寸（有上限）。
pub fn inspect_image(path: String) -> Result<ImageReport, ApiError> {
    let evidence = easypub_app::assets::inspect(&path)?;
    Ok(ImageReport {
        path: evidence.path,
        sha256: evidence.sha256,
        bytes: evidence.bytes as i64,
        width: evidence.width,
        height: evidence.height,
        format: evidence.format,
    })
}

/// 字体的嵌入许可。`permission` 为 installable / editable / preview_print / restricted / unknown 等。
pub struct FontEmbedding {
    pub permission: String,
    pub outline_allowed: bool,
    pub subset_allowed: bool,
}

pub struct FontReport {
    pub sha256: String,
    pub bytes: i64,
    pub face_index: u32,
    pub family: Option<String>,
    pub license_text: Option<String>,
    pub license_url: Option<String>,
    pub embedding: FontEmbedding,
    pub variable: bool,
    pub glyph_count: u32,
    pub requested_characters: u32,
    pub missing_count: u32,
    pub missing_sample: Vec<String>,
    pub license_confirmation_required: bool,
}

/// 检查字体（有类型，桥接第 3 批）：`sample` 里的字用来列出字体缺哪些字。
pub fn inspect_font(path: String, face_index: u32, sample: String) -> Result<FontReport, ApiError> {
    let report = easypub_app::fonts::inspect(&path, face_index, &sample)?;
    Ok(FontReport {
        sha256: report.sha256,
        bytes: report.bytes as i64,
        face_index: report.face_index,
        family: report.family,
        license_text: report.license_text,
        license_url: report.license_url,
        embedding: FontEmbedding {
            permission: report.embedding.permission.to_owned(),
            outline_allowed: report.embedding.outline_allowed,
            subset_allowed: report.embedding.subset_allowed,
        },
        variable: report.variable,
        glyph_count: u32::from(report.glyph_count),
        requested_characters: report.requested_characters as u32,
        missing_count: report.missing_count as u32,
        missing_sample: report.missing_sample,
        license_confirmation_required: report.license_confirmation_required,
    })
}

/// 把文件移到 Windows 回收站（V134）：返回实际移走的路径，不存在的跳过。
pub fn recycle_files(paths: Vec<String>) -> Result<Vec<String>, ApiError> {
    easypub_app::recycle::to_recycle_bin(&paths)
}

/// 把无 DRM 的 AZW3 / MOBI 转成新的 EPUB（V131），之后按 EPUB 导入。
pub fn import_kindle_epub(source_path: String, output_path: String) -> Result<(), ApiError> {
    easypub_app::kindle_import::to_epub(&source_path, &output_path).map(|_| ())
}
