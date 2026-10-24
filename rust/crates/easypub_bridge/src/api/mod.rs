//! The only Rust-to-Dart application boundary for the R1 experiment.
use easypub_app::repair_session::RepairSessionManager;
use easypub_app::sessions::ImportService;
pub use easypub_core::ApiError;
use easypub_core::source::SourceCursor;
use std::sync::OnceLock;

static SERVICE: OnceLock<Result<ImportService, ApiError>> = OnceLock::new();
static REPAIR_SESSIONS: OnceLock<RepairSessionManager> = OnceLock::new();

fn repair_sessions() -> &'static RepairSessionManager {
    REPAIR_SESSIONS.get_or_init(RepairSessionManager::new)
}

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

pub fn echo_text(text: String) -> String {
    text
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

pub fn open_repair_session(source_id: String, source_revision: u32) -> Result<u64, ApiError> {
    repair_sessions().open(source_id, source_revision)
}

pub fn repair_session_snapshot(handle: u64) -> Result<String, ApiError> {
    repair_sessions().snapshot(handle)
}

pub fn set_repair_mode(handle: u64, mode: String) -> Result<String, ApiError> {
    repair_sessions().set_mode(handle, mode)
}
pub fn set_repair_action(handle: u64, action_json: String) -> Result<String, ApiError> {
    repair_sessions().set_action(handle, action_json)
}

pub fn undo_repair_session(handle: u64) -> Result<String, ApiError> {
    repair_sessions().undo(handle)
}

pub fn redo_repair_session(handle: u64) -> Result<String, ApiError> {
    repair_sessions().redo(handle)
}

pub fn cancel_repair_session(handle: u64) -> Result<String, ApiError> {
    repair_sessions().cancel(handle)
}

pub fn close_repair_session(handle: u64) -> Result<(), ApiError> {
    repair_sessions().close(handle)
}
pub fn start_import(path: String, rule_id: String) -> Result<u32, ApiError> {
    service()?.start_import(path, rule_id)
}
pub fn start_cancellation_probe() -> Result<u32, ApiError> {
    service()?.start_cancellation_probe()
}
pub fn job_status_text(job_id: u32) -> Result<String, ApiError> {
    let job = service()?.get_job(job_id)?;
    let (source_id, revision, lines, chapters, encoding) = job
        .book
        .as_ref()
        .map(|book| {
            (
                book.source_id.clone(),
                book.revision.to_string(),
                book.line_count.to_string(),
                book.chapter_count.to_string(),
                book.encoding.clone(),
            )
        })
        .unwrap_or_else(|| {
            (
                String::new(),
                String::new(),
                String::new(),
                String::new(),
                String::new(),
            )
        });
    Ok(format!(
        "phase={:?};sequence={};bytes={};source_id={};revision={};lines={};chapters={};encoding={};error={:?}",
        job.phase,
        job.sequence,
        job.processed_bytes,
        source_id,
        revision,
        lines,
        chapters,
        encoding,
        job.error
    ))
}
pub fn cancel_job_text(job_id: u32) -> Result<String, ApiError> {
    service()?.cancel_job(job_id)?;
    job_status_text(job_id)
}
pub fn diagnose_source_text(source_id: String, revision: u32) -> Result<String, ApiError> {
    service()?.diagnose(source_id, revision)
}

pub fn duplicate_blocks_text(
    source_id: String,
    revision: u32,
    offset: u32,
) -> Result<String, ApiError> {
    service()?.duplicate_blocks(source_id, revision, offset)
}
/// Read a typed failure without exposing source text or filesystem contents.
pub fn describe_api_error(error: &ApiError) -> String {
    serde_json::json!({"error": format!("{:?}", error.code), "operation": error.operation,
        "next_action":error.next_action,"retryable":error.retryable})
    .to_string()
}
/// 同步版本：界面在 catch 里直接把错误换成具体原因，不必改成异步（V15 错误对照表）。
#[flutter_rust_bridge::frb(sync)]
pub fn describe_api_error_sync(error: &ApiError) -> String {
    describe_api_error(error)
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
pub fn read_source_page_text(
    source_id: String,
    revision: u32,
    line_index: u32,
    utf8_column: u32,
    limit: u32,
) -> Result<String, ApiError> {
    let page = service()?.read_page(
        source_id,
        revision,
        SourceCursor {
            line_index,
            utf8_column,
        },
        limit,
    )?;
    let mut text = format!(
        "source={} revision={} bytes={} next={:?}\n",
        page.source_id, page.revision, page.text_bytes, page.next_cursor
    );
    for item in page.items {
        text.push_str(&format!("{}: {}\n", item.line_number, item.text));
    }
    Ok(text)
}
pub fn read_chapter_page_text(
    source_id: String,
    revision: u32,
    offset: u32,
    limit: u32,
) -> Result<String, ApiError> {
    let page = service()?.chapter_page(source_id, revision, offset, limit)?;
    let mut text = format!(
        "source={} revision={} total={} next={:?}\n",
        page.source_id, page.revision, page.total, page.next_offset
    );
    for item in page.items {
        text.push_str(&format!("{}: {}\n", item.source_line, item.title));
    }
    Ok(text)
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

/// Decode a bounded image and return content identity plus dimensions.
pub fn inspect_image_text(path: String) -> Result<String, ApiError> {
    let evidence = easypub_app::assets::inspect(&path)?;
    serde_json::to_string(&evidence).map_err(|_| {
        ApiError::new(
            easypub_core::ErrorCode::InvalidRule,
            "image_resource",
            "choose_readable_supported_image",
        )
    })
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
pub fn import_epub_text(source_path: String, output_path: String) -> Result<String, ApiError> {
    easypub_app::epub_import::extract(&source_path, &output_path)
}

/// Extract EPUB cover, image, CSS and font resources into a private directory.
pub fn import_epub_resources(
    source_path: String,
    resource_dir: String,
) -> Result<String, ApiError> {
    easypub_app::epub_import::extract_resources(&source_path, &resource_dir)
}

pub fn kindling_job_text(request_json: String) -> Result<String, ApiError> {
    #[cfg(windows)]
    {
        static JOBS: OnceLock<easypub_app::kindling_jobs::Manager> = OnceLock::new();
        JOBS.get_or_init(Default::default)
            .handle(service()?, &request_json)
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

pub fn review_findings_text(
    source_id: String,
    revision: u32,
    request_json: String,
) -> Result<String, ApiError> {
    service()?.review_findings(source_id, revision, request_json)
}

/// Read-only font inspection. This does not select or embed the font.
pub fn inspect_font_text(
    path: String,
    face_index: u32,
    sample: String,
) -> Result<String, ApiError> {
    let report = easypub_app::fonts::inspect(&path, face_index, &sample)?;
    serde_json::to_string(&report).map_err(|_| {
        ApiError::new(
            easypub_core::ErrorCode::Internal,
            "font_report",
            "retry_font_check",
        )
    })
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

pub fn capture_cleanup_preset_text(name: String, request_json: String) -> Result<String, ApiError> {
    easypub_app::cleanup_presets::capture_text(name, &request_json)
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
