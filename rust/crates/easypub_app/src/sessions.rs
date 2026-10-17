//! Bounded immutable sources with one import worker.
//! Terminal cancellation is published only after the worker has stopped.
use crate::transaction::{InjectFault, apply_new_file_bytes_with_evidence};
use easypub_core::{
    ApiError, ErrorCode,
    encoding::EncodingMode,
    source::{BookSummary, ChapterPage, SourceCursor, SourcePage, SourceSnapshot},
};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs::File,
    io::Read,
    path::Path,
    sync::{Arc, Mutex, OnceLock, Weak},
    time::Duration,
};
use tokio::runtime::{Builder, Runtime};
use tokio_util::sync::CancellationToken;

pub const MAX_IMPORT_BYTES: usize = 128 * 1024 * 1024;
pub const MAX_SESSION_BYTES: usize = 512 * 1024 * 1024;
// Enumeration and persisted libraries can contain many small books. Resident
// source memory is still independently capped at 512 MiB; a batch size must
// not accidentally cap the lifetime of the entire library/project.
pub const MAX_SOURCES: usize = 10_000;
pub const MAX_BATCH_TARGETS: usize = 128;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum JobPhase {
    Reading,
    Indexing,
    CancellationProbe,
    Cancelling,
    Completed,
    Cancelled,
    Failed,
}

#[derive(Clone, Debug)]
pub struct JobSnapshot {
    pub job_id: u32,
    pub sequence: u32,
    pub phase: JobPhase,
    pub processed_bytes: u32,
    pub cancellable: bool,
    pub book: Option<BookSummary>,
    pub error: Option<ApiError>,
}

impl JobSnapshot {
    pub fn terminal(&self) -> bool {
        matches!(
            self.phase,
            JobPhase::Completed | JobPhase::Cancelled | JobPhase::Failed
        )
    }
}

/// 同时进行的导入任务上限（V38，LIB-115）：与设置“同时处理的书”的最大档位相同。
pub(crate) const MAX_ACTIVE_JOBS: usize = 8;

struct State {
    next_id: u32,
    /// 正在进行的任务及其取消令牌（V38 起可以有多个）。
    active: BTreeMap<u32, CancellationToken>,
    jobs: BTreeMap<u32, JobSnapshot>,
    sources: BTreeMap<String, Arc<SourceSnapshot>>,
}

pub struct ImportService {
    runtime: Runtime,
    state: Arc<Mutex<State>>,
    cleanup_preview: Mutex<Option<CleanupCache>>,
    effective_views: Mutex<Vec<Arc<EffectiveView>>>,
}

// At most two books; reserve text, diagnostic bytes/text, line map and nodes.
// The budget accommodates one 100 MiB manuscript without an unbounded cache.
const MAX_EFFECTIVE_CACHE_BYTES: usize = 512 * 1024 * 1024;
struct EffectiveView {
    source: Weak<SourceSnapshot>,
    key: String,
    book: easypub_core::publication::EffectiveBook,
    editing_base_id: String,
    replay_bytes: usize,
    estimated_bytes: usize,
    /// Present when `rebase_from` moved stored chapter edits onto this base.
    rebase: Option<serde_json::Value>,
    diagnostics: OnceLock<Result<SourceSnapshot, ApiError>>,
    evidence: OnceLock<Result<easypub_core::review::ReviewEvidence, ApiError>>,
    repairs: OnceLock<serde_json::Value>,
}

const MAX_CLEANUP_CACHE_BYTES: usize = 64 * 1024 * 1024;
struct CleanupCache {
    source: std::sync::Weak<SourceSnapshot>,
    request: String,
    plan: Arc<easypub_core::cleanup::Cleanup>,
}

impl ImportService {
    pub fn effective_structure_text(
        &self,
        source_id: String,
        revision: u32,
        settings_json: String,
        selected_json: String,
        offset: u32,
    ) -> Result<String, ApiError> {
        if settings_json.len() > 2 * 1024 * 1024 || selected_json.len() > 1024 * 1024 {
            return Err(ApiError::new(
                ErrorCode::TooLarge,
                "publication",
                "reduce_edit_batch",
            ));
        }
        let source = self.source(&source_id, revision)?;
        let settings = if settings_json.is_empty() {
            easypub_core::structure::Structure::new(&source)
        } else {
            serde_json::from_str(&settings_json).map_err(|_| {
                ApiError::new(
                    ErrorCode::InvalidRule,
                    "publication",
                    "review_structure_settings",
                )
            })?
        };
        #[derive(serde::Deserialize)]
        #[serde(deny_unknown_fields)]
        struct BodyPreview {
            entry_id: Option<String>,
            offset: usize,
            char_offset: Option<usize>,
            #[serde(default)]
            select_page: bool,
            #[serde(default)]
            focus_page: bool,
        }
        #[derive(serde::Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Composition {
            kind: String,
            response_scope: Option<String>,
            composition_key: Option<String>,
            body_preview: Option<BodyPreview>,
            #[serde(default)]
            statistics: bool,
            #[serde(default)]
            outline: bool,
            volume_navigation: Option<VolumeNavigation>,
            effective_check: Option<EffectiveCheck>,
            cleanup_check: Option<CleanupCheck>,
            manual: Option<serde_json::Value>,
            cleanup: Option<serde_json::Value>,
            post_edits: Option<crate::edit_checkpoint::EditRequest>,
            /// The composition `post_edits` were made on; they are rebased
            /// onto this request's cleanup instead of being rejected.
            rebase_from: Option<RebaseFrom>,
            catalog: Option<crate::catalog::CompositionSelection>,
        }
        #[derive(serde::Deserialize)]
        #[serde(deny_unknown_fields)]
        struct RebaseFrom {
            cleanup: Option<serde_json::Value>,
            /// `post_edits` 基于检查点时，创建该检查点那一步保存的原始操作（CLEAN-105）。
            #[serde(default)]
            checkpoint_root: Option<crate::edit_checkpoint::EditRequest>,
        }
        #[derive(serde::Deserialize)]
        #[serde(deny_unknown_fields)]
        struct VolumeNavigation {
            volume_id: Option<String>,
        }
        #[derive(serde::Deserialize)]
        #[serde(deny_unknown_fields)]
        struct EffectiveCheck {
            offset: usize,
            line: Option<u32>,
            original_line: Option<u32>,
            category: Option<String>,
            severity: Option<String>,
            repair_focus: Option<String>,
            #[serde(default)]
            review: easypub_core::review::Review,
            review_change: Option<ReviewChange>,
            /// Several decisions in one request (CHK-052), validated against the same evidence.
            #[serde(default)]
            review_changes: Vec<ReviewChange>,
            positions: Option<Positions>,
        }
        /// Whole-book finding positions instead of a report page (read-only).
        #[derive(serde::Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Positions {
            #[serde(default)]
            summary: bool,
            entry_id: Option<String>,
        }
        #[derive(serde::Deserialize)]
        #[serde(deny_unknown_fields)]
        struct ReviewChange {
            id: String,
            evidence_id: String,
            decision: Option<easypub_core::review::Decision>,
        }
        #[derive(serde::Deserialize)]
        #[serde(deny_unknown_fields)]
        struct CleanupCheck {
            offset: usize,
            #[serde(default)]
            rules: Option<Vec<String>>,
            pipeline: Option<Vec<serde_json::Value>>,
        }
        let mut manual = if selected_json.is_empty() {
            None
        } else {
            Some(selected_json.clone())
        };
        let mut cleanup = None;
        let mut post_edits = None;
        let mut rebase_from = None;
        let mut catalog = None;
        let mut body_preview = None;
        let mut volume_navigation = None;
        let mut effective_check = None;
        let mut cleanup_check = None;
        let mut statistics = false;
        let mut outline = false;
        let mut response_scope = None;
        let mut composition_key = None;
        if let Ok(envelope) = serde_json::from_str::<Composition>(&selected_json) {
            match envelope.kind.as_str() {
                "publication" => {
                    response_scope = envelope.response_scope;
                    composition_key = envelope.composition_key;
                    manual = envelope.manual.map(|v| v.to_string());
                    cleanup = envelope.cleanup.map(|v| v.to_string());
                    post_edits = envelope.post_edits;
                    rebase_from = envelope.rebase_from;
                    catalog = envelope.catalog;
                    body_preview = envelope.body_preview;
                    volume_navigation = envelope.volume_navigation;
                    effective_check = envelope.effective_check;
                    cleanup_check = envelope.cleanup_check;
                    statistics = envelope.statistics;
                    outline = envelope.outline;
                }
                // The chapter editor sends its native manual batch directly.
                // Keep it as `manual` instead of treating it as a publication
                // envelope; this preserves the editor's preview contract.
                "manual_batch" => {}
                _ => {
                    return Err(ApiError::new(
                        ErrorCode::InvalidRule,
                        "publication",
                        "review_composition",
                    ));
                }
            }
        }
        // View requests (paging, focus, review and filters) do not participate
        // in the composition key. Only source and content-producing edits do.
        let recipe: Value = serde_json::from_str(&selected_json).unwrap_or(Value::Null);
        let mut identity = Sha256::new();
        identity.update(settings_json.as_bytes());
        if recipe["kind"] == "publication" {
            for key in ["manual", "cleanup", "catalog", "post_edits", "rebase_from"] {
                identity.update([0]);
                identity.update(recipe[key].to_string().as_bytes());
            }
        } else {
            identity.update(selected_json.as_bytes());
        }
        let key = composition_key.clone().unwrap_or_else(|| format!("{:x}", identity.finalize()));
        let cached = self.effective_views.lock().expect("effective cache").iter()
            .find(|v| v.key == key && v.source.ptr_eq(&Arc::downgrade(&source))).cloned();
        if composition_key.is_some() && (!settings_json.is_empty() || manual.is_some() || cleanup.is_some() || post_edits.is_some() || rebase_from.is_some() || catalog.is_some()) {
            return Err(ApiError::new(ErrorCode::InvalidRule,"publication","use_composition_or_edits"));
        }
        if composition_key.is_some() && cached.is_none() {
            return Err(ApiError::new(ErrorCode::StaleRevision,"publication","refresh_composition"));
        }
        let view = if let Some(view) = cached { view } else {
        let book = crate::catalog::compose_selection(
            &source,
            &settings,
            catalog,
            manual.as_deref(),
            cleanup.as_deref(),
        )?;
        let editing_base_id = easypub_core::effective_edit::base_id(&book);
        let (book, replay_bytes, rebase) = match (&post_edits, &rebase_from) {
            (Some(edits), Some(from)) if !edits.is_empty() => {
                // 检查点只存了结果：需要创建它那一步保存的原始操作才能换算（CLEAN-105）。
                if edits.checkpoint.is_some() && from.checkpoint_root.is_none() {
                    return Err(ApiError::new(ErrorCode::InvalidRule, "publication", "rebase_checkpoint"));
                }
                let old_catalog = match &recipe["catalog"] {
                    Value::Null => None,
                    v => Some(serde_json::from_value(v.clone()).map_err(|_| {
                        ApiError::new(ErrorCode::InvalidRule, "publication", "review_composition")
                    })?),
                };
                let old_cleanup = from.cleanup.as_ref().map(Value::to_string);
                let old = crate::catalog::compose_selection(
                    &source,
                    &settings,
                    old_catalog,
                    manual.as_deref(),
                    old_cleanup.as_deref(),
                )?;
                if let Some(root) = &from.checkpoint_root {
                    let moved = crate::effective_draft::rebase_across_checkpoint(old, book, root, edits)
                        .map_err(|_| ApiError::new(ErrorCode::InvalidRule, "publication", "rebase_checkpoint"))?;
                    let summary = serde_json::json!({"request": null, "kept": moved.kept,
                        "skipped": moved.skipped, "total": moved.total, "checkpoint": true});
                    (moved.book, 0, Some(summary))
                } else {
                    let moved = easypub_core::effective_edit::rebase(
                        old,
                        book,
                        &easypub_core::effective_edit::Request {
                            base_id: edits.base_id.clone(),
                            actions: edits.actions.clone(),
                        },
                    )?;
                    let summary = serde_json::json!({"request": moved.request, "kept": moved.kept,
                        "skipped": moved.skipped, "total": edits.actions.len()});
                    (moved.book, moved.work_bytes, Some(summary))
                }
            }
            (Some(edits), _) => {
                let (book, _, bytes) = crate::edit_checkpoint::apply_profiled(book, edits)?;
                (book, bytes, None)
            }
            (None, _) => (book, 0, None),
        };
        let estimated_bytes = book.text.len().saturating_mul(3)
            .saturating_add(book.tree.nodes.len().saturating_mul(1024))
            .saturating_add(book.source_to_output_lines.len().saturating_mul(64));
        let view = Arc::new(EffectiveView { source: Arc::downgrade(&source), key,
            book, editing_base_id, replay_bytes, estimated_bytes, rebase,
            diagnostics: OnceLock::new(), evidence: OnceLock::new(), repairs: OnceLock::new() });
        if estimated_bytes <= MAX_EFFECTIVE_CACHE_BYTES {
            let mut cache = self.effective_views.lock().expect("effective cache");
            cache.retain(|v| v.source.strong_count() > 0 && !v.source.ptr_eq(&view.source));
            while !cache.is_empty() && (cache.len() >= 2 ||
                cache.iter().map(|v| v.estimated_bytes).sum::<usize>() + estimated_bytes > MAX_EFFECTIVE_CACHE_BYTES) {
                cache.remove(0);
            }
            cache.push(view.clone());
        }
        view
        };
        let book = &view.book;
        let editing_base_id = &view.editing_base_id;
        let replay_bytes = view.replay_bytes;
        let edit_budget = serde_json::json!({
            "replay_bytes": replay_bytes,
            "next_action_bytes": book.text.len(),
            "limit_bytes": easypub_core::effective_edit::MAX_REPLAY_BYTES,
        });
        // Editing can move the selected chapter beyond its previous page.
        // Resolve its current page before choosing both the nodes and body.
        let offset = body_preview
            .as_ref()
            .filter(|view| view.focus_page && !outline)
            .and_then(|view| view.entry_id.as_deref())
            .and_then(|id| book.tree.nodes.iter().position(|node| node.entry_id == id))
            .map(|position| (position / 30 * 30) as u32)
            .unwrap_or(offset);
        let body = if let Some(view) = body_preview {
            let page = || book.tree.nodes.iter().skip(offset as usize).take(30);
            let id = if view.select_page {
                page()
                    .find(|n| Some(n.entry_id.as_str()) == view.entry_id.as_deref())
                    .or_else(|| page().find(|n| n.role == easypub_core::structure::Role::Chapter))
                    .or_else(|| page().next())
                    .map(|n| n.entry_id.as_str())
            } else {
                Some(view.entry_id.as_deref().ok_or_else(|| {
                    ApiError::new(ErrorCode::InvalidCursor, "publication", "select_body_node")
                })?)
            };
            id.map(|id| match view.char_offset {
                Some(chars) => book.body_line_chunk(id, view.offset, chars),
                None => book.body_preview(id, view.offset),
            })
                .transpose()?
        } else {
            None
        };
        let navigation = volume_navigation
            .map(|v| book.volume_navigation(v.volume_id.as_deref(), offset as usize))
            .transpose()?;
        let check = effective_check
            .map(|mut v| {
                let diagnostics = view.diagnostics.get_or_init(|| SourceSnapshot::for_effective_diagnostics(book))
                    .as_ref().map_err(Clone::clone)?;
                let repairs = view.repairs.get_or_init(|| easypub_core::effective_repair::candidates(book));
                let evidence = view.evidence.get_or_init(|| easypub_core::review::ReviewEvidence::new(diagnostics))
                    .as_ref().map_err(Clone::clone)?;
                if let Some(positions) = v.positions {
                    if v.review_change.is_some() || !v.review_changes.is_empty() {
                        return Err(ApiError::new(ErrorCode::InvalidRule, "publication", "review_or_positions"));
                    }
                    return Ok(serde_json::json!({"positions": book.issue_positions_using(
                        diagnostics,
                        evidence,
                        repairs,
                        &v.review,
                        positions.summary,
                        positions.entry_id.as_deref(),
                    )?}));
                }
                if let Some(change) = v.review_change {
                    v.review.set_using(
                        evidence,
                        &change.id,
                        &change.evidence_id,
                        change.decision,
                        String::new(),
                    )?;
                }
                if v.review_changes.len() > 1000 {
                    return Err(ApiError::new(ErrorCode::InvalidRule, "publication", "review_batch_limit"));
                }
                for change in std::mem::take(&mut v.review_changes) {
                    v.review.set_using(
                        evidence,
                        &change.id,
                        &change.evidence_id,
                        change.decision,
                        String::new(),
                    )?;
                }
                let mut result = book.check_page_using(
                    diagnostics,
                    evidence,
                    repairs,
                    v.offset,
                    v.line,
                    v.category.as_deref(),
                    v.severity.as_deref(),
                    &v.review,
                )?;
                let original_line = v.original_line.or_else(|| v.line.and_then(|line|
                    book.source_to_output_lines.iter().find_map(|(&original,&effective)|
                        (effective == line).then_some(original))));
                result["context_original_line"] = serde_json::json!(original_line);
                if let Some(line) = original_line {
                    let page = source.read_page(SourceCursor {line_index:line.saturating_sub(3),utf8_column:0},12)?;
                    result["original_excerpt"] = serde_json::json!(page.items.into_iter().map(|row|
                        serde_json::json!({"line":row.line_number,"text":row.text,"truncated":row.continues,
                            "anchor":format!("{}:{}",source_id,row.line_number),"original_line":row.line_number})
                    ).collect::<Vec<_>>());
                }
                result["review"] = serde_json::to_value(&v.review).expect("review serialization");
                if let Some(focus) = v.repair_focus {
                    result["repairs"] =
                        easypub_core::effective_repair::candidates_for(book, Some(&focus));
                }
                let stamp = result["report"]["evidence_id"]
                    .as_str()
                    .unwrap_or("")
                    .to_owned();
                for candidate in result["repairs"]["items"]
                    .as_array_mut()
                    .expect("repair candidates")
                {
                    let id = candidate["finding_id"].as_str().unwrap_or("");
                    let category = id.split(':').next().unwrap_or("");
                    if [id, category].iter().any(|key| {
                        v.review
                            .records
                            .get(*key)
                            .is_some_and(|r| r.evidence_id == stamp)
                    }) {
                        candidate["recommended"] = serde_json::json!(false);
                    }
                }
                Ok::<_, ApiError>(result)
            })
            .transpose()?;
        let cleanup_check = cleanup_check
            .map(|v| book.cleanup_check_pipeline(v.offset, v.rules, v.pipeline))
            .transpose()?;
        let statistics = statistics.then(|| {
            use easypub_core::structure::Role;
            let titles: usize = book.tree.nodes.iter().map(|n| book.text[n.start..n.body_start].chars().filter(|c| !c.is_whitespace()).count()).sum();
            serde_json::json!({"chapters":book.tree.nodes.iter().filter(|n| matches!(n.role,Role::Chapter)).count(),
                "volumes":book.tree.nodes.iter().filter(|n| matches!(n.role,Role::Volume)).count(),
                "characters":book.text.chars().filter(|c| !c.is_whitespace()).count().saturating_sub(titles)})
        });
        Ok(serde_json::json!({"composition_key":(view.estimated_bytes <= MAX_EFFECTIVE_CACHE_BYTES).then_some(&view.key),"recognition_rules":book.tree.recognition_rules,"recognition_decisions":book.tree.recognition_decisions,"edit_budget":edit_budget,"statistics":statistics,"cleanup_check":cleanup_check,"effective_check":check,"volume_navigation":navigation,"body_preview":body,"editing_base_id":editing_base_id,"post_edit_rebase":view.rebase,"nodes":book.tree.nodes.iter().skip(offset as usize).take(if response_scope.as_deref()==Some("context") {0} else if outline {30_000} else {30}).collect::<Vec<_>>(),"total":book.tree.nodes.len(),"offset":offset,
            "original_source_id":book.original_source_id,"effective_source_id":book.tree.source_id,"text_changed":book.text_changed,
            "removed_structure_lines":book.removed_structure_lines,"source_bytes_covered":book.tree.source_bytes_covered,"source_unchanged":true}).to_string())
    }
    pub fn structure_text(
        &self,
        source_id: String,
        revision: u32,
        settings_json: String,
        change_json: String,
        offset: u32,
    ) -> Result<String, ApiError> {
        let invalid = || {
            ApiError::new(
                ErrorCode::InvalidRule,
                "structure",
                "review_structure_settings",
            )
        };
        if settings_json.len() > 2 * 1024 * 1024 || change_json.len() > 16384 {
            return Err(invalid());
        }
        let source = self.source(&source_id, revision)?;
        let mut settings = if settings_json.is_empty() {
            easypub_core::structure::Structure::new(&source)
        } else {
            serde_json::from_str(&settings_json).map_err(|_| invalid())?
        };
        settings.tree(&source)?;
        if !change_json.is_empty() {
            let change = serde_json::from_str(&change_json).map_err(|_| invalid())?;
            settings.put(&source, change)?;
        }
        let tree = settings.tree(&source)?;
        Ok(serde_json::json!({"settings":settings,"nodes":tree.nodes.iter().skip(offset as usize).take(30).collect::<Vec<_>>(),"total":tree.nodes.len(),"offset":offset,"prefix_end":tree.prefix_end,"source_bytes_covered":tree.source_bytes_covered,"source_unchanged":true}).to_string())
    }
    pub fn new() -> Result<Self, ApiError> {
        // 导入在阻塞线程里进行；V38 起允许多本同时导入，阻塞线程数与任务上限相同。
        let runtime = Builder::new_multi_thread()
            .worker_threads(1)
            .max_blocking_threads(MAX_ACTIVE_JOBS)
            .enable_time()
            .build()
            .map_err(|_| ApiError::new(ErrorCode::Internal, "runtime", "restart_application"))?;
        Ok(Self {
            runtime,
            cleanup_preview: Mutex::new(None),
            effective_views: Mutex::new(Vec::new()),
            state: Arc::new(Mutex::new(State {
                next_id: 1,
                active: BTreeMap::new(),
                jobs: BTreeMap::new(),
                sources: BTreeMap::new(),
            })),
        })
    }

    fn begin(&self, phase: JobPhase) -> Result<(u32, CancellationToken), ApiError> {
        let mut state = self.state.lock().expect("service state");
        if state.active.len() >= MAX_ACTIVE_JOBS {
            return Err(ApiError::new(
                ErrorCode::Busy,
                "start_job",
                "wait_for_current_job",
            ));
        }
        let id = state.next_id;
        state.next_id = id.checked_add(1).ok_or_else(|| {
            ApiError::new(ErrorCode::Internal, "start_job", "restart_application")
        })?;
        while state.jobs.len() >= 16 {
            state.jobs.pop_first();
        }
        let token = CancellationToken::new();
        state.active.insert(id, token.clone());
        state.jobs.insert(
            id,
            JobSnapshot {
                job_id: id,
                sequence: 1,
                phase,
                processed_bytes: 0,
                cancellable: true,
                book: None,
                error: None,
            },
        );
        Ok((id, token))
    }

    pub fn start_import(&self, path: String, rule_id: String) -> Result<u32, ApiError> {
        if rule_id != easypub_core::source::RULE_ID {
            return Err(ApiError::new(
                ErrorCode::UnsupportedRule,
                "import",
                "select_explicit_rule",
            ));
        }
        let (id, token) = self.begin(JobPhase::Reading)?;
        let shared = self.state.clone();
        self.runtime.spawn_blocking(move || {
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let bytes = read_bounded(Path::new(&path), &token, |count| {
                    progress(&shared, id, JobPhase::Reading, count)
                })?;
                progress(&shared, id, JobPhase::Indexing, bytes.len() as u32);
                SourceSnapshot::from_bytes(bytes, EncodingMode::Auto, &rule_id, || {
                    token.is_cancelled()
                })
                .map(Some)
            }))
            .unwrap_or_else(|_| Err(ApiError::new(ErrorCode::Internal, "import", "retry_import")));
            finish(&shared, id, &token, result);
        });
        Ok(id)
    }

    /// Explicit synthetic worker for visible cancellation, not a performance test.
    pub fn start_cancellation_probe(&self) -> Result<u32, ApiError> {
        let (id, token) = self.begin(JobPhase::CancellationProbe)?;
        let shared = self.state.clone();
        self.runtime.spawn_blocking(move || {
            for step in 0..600 {
                if token.is_cancelled() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(5));
                if step % 20 == 0 {
                    progress(&shared, id, JobPhase::CancellationProbe, 0);
                }
            }
            finish(&shared, id, &token, Ok(None));
        });
        Ok(id)
    }

    pub fn get_job(&self, id: u32) -> Result<JobSnapshot, ApiError> {
        self.state
            .lock()
            .expect("service state")
            .jobs
            .get(&id)
            .cloned()
            .ok_or_else(|| ApiError::new(ErrorCode::NotFound, "get_job", "refresh_jobs"))
    }

    pub fn cancel_job(&self, id: u32) -> Result<JobSnapshot, ApiError> {
        let mut state = self.state.lock().expect("service state");
        if let Some(token) = state.active.get(&id) {
            token.cancel();
        }
        let job = state
            .jobs
            .get_mut(&id)
            .ok_or_else(|| ApiError::new(ErrorCode::NotFound, "cancel_job", "refresh_jobs"))?;
        if !job.terminal() {
            job.phase = JobPhase::Cancelling;
            job.sequence += 1;
            job.cancellable = false;
        }
        Ok(job.clone())
    }

    pub(crate) fn source(
        &self,
        source_id: &str,
        revision: u32,
    ) -> Result<Arc<SourceSnapshot>, ApiError> {
        let source = self
            .state
            .lock()
            .expect("service state")
            .sources
            .get(source_id)
            .cloned()
            .ok_or_else(|| ApiError::new(ErrorCode::NotFound, "read_source", "import_source"))?;
        let summary = source.summary();
        if summary.source_id != source_id || summary.revision != revision {
            return Err(ApiError::new(
                ErrorCode::StaleRevision,
                "read_source",
                "refresh_book",
            ));
        }
        Ok(source)
    }

    /// Publish a completely validated project; failed preparation never changes active sources.
    pub(crate) fn replace_sources(
        &self,
        sources: BTreeMap<String, Arc<SourceSnapshot>>,
    ) -> Result<(), ApiError> {
        let mut state = self.state.lock().expect("service state");
        if !state.active.is_empty() {
            return Err(ApiError::new(
                ErrorCode::Busy,
                "open_project",
                "wait_for_current_job",
            ));
        }
        if sources.len() > MAX_SOURCES
            || sources.values().map(|s| s.resident_bytes()).sum::<usize>() > MAX_SESSION_BYTES
        {
            return Err(ApiError::new(
                ErrorCode::TooLarge,
                "project_budget",
                "reduce_project_size",
            ));
        }
        state.sources = sources;
        drop(state);
        *self.cleanup_preview.lock().expect("cleanup preview") = None;
        Ok(())
    }

    pub fn review_findings(
        &self,
        source_id: String,
        revision: u32,
        request: String,
    ) -> Result<String, ApiError> {
        let source = self.source(&source_id, revision)?;
        easypub_core::review::execute(&source, &request)
    }
    pub fn diagnose(&self, source_id: String, revision: u32) -> Result<String, ApiError> {
        Ok(self.source(&source_id, revision)?.diagnostic_json())
    }
    pub fn duplicate_blocks(
        &self,
        source_id: String,
        revision: u32,
        offset: u32,
    ) -> Result<String, ApiError> {
        let source = self.source(&source_id, revision)?;
        let groups = easypub_core::duplicate_blocks::find(&source)?;
        let total = groups.len();
        let occurrences = groups.iter().map(|g| g.occurrences.len()).sum::<usize>();
        if offset as usize > occurrences {
            return Err(ApiError::new(
                ErrorCode::InvalidCursor,
                "duplicate_blocks",
                "refresh_candidates",
            ));
        }
        // Flatten occurrences so even a single enormous group has bounded pages.
        let rows =
            groups
                .iter()
                .flat_map(|g| {
                    g.occurrences.iter().map(move |o| serde_json::json!({
            "group_id":g.block_sha256,"title":g.title,"group_size":g.occurrences.len(),
            "entry_id":o.entry_id,"start_line":o.start_line,"end_line":o.end_line
        }))
                })
                .skip(offset as usize)
                .take(40)
                .collect::<Vec<_>>();
        Ok(
            serde_json::json!({"source_id":source_id,"revision":revision,"groups":total,
            "total":occurrences,"offset":offset,"rows":rows,"read_only":true})
            .to_string(),
        )
    }

    pub fn preview_repair_plan(
        &self,
        source_id: String,
        revision: u32,
        selected_json: String,
    ) -> Result<String, ApiError> {
        let source = self.source(&source_id, revision)?;
        let envelope: Value = serde_json::from_str(&selected_json).map_err(|_| {
            ApiError::new(
                ErrorCode::InvalidRule,
                "cleanup_context",
                "review_cleanup_request",
            )
        })?;
        if envelope["kind"] == "cleanup_context" {
            #[derive(serde::Deserialize)]
            #[serde(deny_unknown_fields)]
            struct ContextRequest {
                kind: String,
                request: Value,
                first: u32,
                last: u32,
                #[serde(default)]
                offset: usize,
                #[serde(default)]
                region_line: Option<u32>,
                #[serde(default)]
                step_index: Option<u32>,
                #[serde(default)]
                char_offset: usize,
            }
            let query: ContextRequest = serde_json::from_value(envelope).map_err(|_| {
                ApiError::new(
                    ErrorCode::InvalidRule,
                    "cleanup_context",
                    "review_cleanup_request",
                )
            })?;
            debug_assert_eq!(query.kind, "cleanup_context");
            let (plan, _) = self.cleanup_preview_plan(&source, query.request)?;
            if let Some(step) = query.step_index {
                return Ok(plan
                    .stage_region(&source, query.first, query.last, step, query.char_offset)?
                    .to_string());
            }
            if let Some(line) = query.region_line {
                return Ok(plan
                    .context_region(&source, query.first, query.last, line, query.char_offset)?
                    .to_string());
            }
            return Ok(plan
                .context(&source, query.first, query.last, query.offset)?
                .to_string());
        }
        if envelope["kind"] == "cleanup" {
            if selected_json.len() > 1024 * 1024 {
                return Err(ApiError::new(
                    ErrorCode::InvalidRule,
                    "cleanup",
                    "review_cleanup_request",
                ));
            }
            let (plan, offset) = self.cleanup_preview_plan(&source, envelope)?;
            return Ok(plan.preview_at(offset));
        }
        if let Some(plan) = crate::publication_output::try_prepare(&source, &selected_json)? {
            Ok(plan.preview())
        } else {
            source.repair_plan_json(&selected_json)
        }
    }

    fn cleanup_preview_plan(
        &self,
        source: &Arc<SourceSnapshot>,
        request: Value,
    ) -> Result<(Arc<easypub_core::cleanup::Cleanup>, usize), ApiError> {
        let request: easypub_core::cleanup::Request =
            serde_json::from_value(request).map_err(|_| {
                ApiError::new(ErrorCode::InvalidRule, "cleanup", "review_cleanup_request")
            })?;
        let (key, offset) = request.preview_identity();
        // One retained plan; serialize identical in-flight preparations without
        // holding the source registry lock or changing commit-time validation.
        let mut cache = self.cleanup_preview.lock().expect("cleanup preview");
        if let Some(c) = cache.as_ref()
            && c.request == key && c.source.upgrade().is_some_and(|s| Arc::ptr_eq(&s, source)) {
                return Ok((Arc::clone(&c.plan), offset));
            }
        *cache = None;
        let plan = Arc::new(easypub_core::cleanup::prepare(source, &key)?);
        if plan.cache_bytes().saturating_add(key.capacity()) <= MAX_CLEANUP_CACHE_BYTES {
            *cache = Some(CleanupCache {
                source: Arc::downgrade(source),
                request: key,
                plan: Arc::clone(&plan),
            });
        }
        Ok((plan, offset))
    }

    /// Commit the currently supported safe action to a new TXT path. The source
    /// path and immutable snapshot are both checked before the transaction; the
    /// original path is never an output target.
    #[allow(clippy::too_many_arguments)]
    pub fn commit_repair_output(
        &self,
        source_id: String,
        revision: u32,
        source_path: String,
        output_path: String,
        selected_json: String,
        plan_id: String,
        confirmed: bool,
    ) -> Result<String, ApiError> {
        if !confirmed {
            return Err(ApiError::new(
                ErrorCode::InvalidRule,
                "repair_commit",
                "confirm_repair_before_commit",
            ));
        }
        let source = self.source(&source_id, revision)?;
        let publication = crate::publication_output::try_prepare(&source, &selected_json)?;
        let preview = if let Some(plan) = &publication {
            plan.preview()
        } else {
            source.repair_plan_json(&selected_json)?
        };
        let plan: Value = serde_json::from_str(&preview)
            .map_err(|_| ApiError::new(ErrorCode::Internal, "repair_commit", "reopen_preview"))?;
        if plan["plan_id"].as_str() != Some(plan_id.as_str())
            || plan["writes"] != false
            || (if plan["kind"] == "publication" {
                plan["text_changed"] != true && plan["unchanged_copy_allowed"] != true
            } else if plan["kind"] == "cleanup" {
                plan["change_count"].as_u64().unwrap_or(0) == 0
            } else {
                plan["actions"].as_array().is_none_or(Vec::is_empty)
            })
        {
            return Err(ApiError::new(
                ErrorCode::StaleRevision,
                "repair_commit",
                "reopen_preview",
            ));
        }
        let selected: Value = serde_json::from_str(&selected_json).map_err(|_| {
            ApiError::new(
                ErrorCode::InvalidRule,
                "repair_commit",
                "confirm_known_actions",
            )
        })?;
        let is_manual_volume = matches!(
            selected.get("kind").and_then(|v| v.as_str()),
            Some("set_volume" | "rename_title" | "manual_batch" | "cleanup" | "publication")
        );
        if !is_manual_volume
            && plan["selected_findings"].as_array().is_none_or(|items| {
                items.is_empty()
                    || items
                        .iter()
                        .any(|item| item.as_str() != Some("duplicate-title"))
            })
        {
            return Err(ApiError::new(
                ErrorCode::InvalidRule,
                "repair_commit",
                "confirm_only_safe_actions",
            ));
        }
        let bytes = std::fs::read(&source_path).map_err(|_| {
            ApiError::new(ErrorCode::SourceChanged, "repair_source", "reopen_preview")
        })?;
        if format!("{:x}", Sha256::digest(&bytes)) != source_id {
            return Err(ApiError::new(
                ErrorCode::SourceChanged,
                "repair_source",
                "reopen_preview",
            ));
        }
        let output = if let Some(plan) = &publication {
            plan.output(&source)?
        } else {
            source.repair_output_json(&selected_json)?
        };
        let edit_evidence = if let Some(plan) = &publication {
            Some(plan.evidence())
        } else if selected["kind"] == "cleanup" {
            Some(easypub_core::cleanup::prepare(&source, &selected_json)?.evidence())
        } else if selected["kind"] == "manual_batch" {
            Some(easypub_core::manual_edit::prepare(&source, &selected_json)?.evidence(&source))
        } else {
            None
        };
        let report = apply_new_file_bytes_with_evidence(
            &source_path,
            &output_path,
            &output,
            &source_id,
            InjectFault::None,
            edit_evidence.as_deref(),
        )?;
        let actual = read_bounded(Path::new(&output_path), &CancellationToken::new(), |_| {})?;
        if actual != output {
            return Err(ApiError::new(
                ErrorCode::OutputConflict,
                "repair_recheck",
                "inspect_output",
            ));
        }
        let rechecked = SourceSnapshot::from_bytes(
            actual,
            EncodingMode::Auto,
            easypub_core::source::RULE_ID,
            || false,
        )?;
        let recheck: Value = serde_json::from_str(&rechecked.diagnostic_json())
            .map_err(|_| ApiError::new(ErrorCode::Internal, "repair_recheck", "inspect_output"))?;
        Ok(serde_json::json!({
            "committed": true,
            "transaction_dir": report.transaction_dir,
            "recheck": recheck,
            "operation_id": plan_id,
            "source_id": source_id,
            "revision": revision,
            "output_path": output_path,
            "source_unchanged": report.source_unchanged,
            "output_sha256": report.output_sha256,
            "stage": report.stage,
        })
        .to_string())
    }

    pub fn read_page(
        &self,
        source_id: String,
        revision: u32,
        cursor: SourceCursor,
        limit: u32,
    ) -> Result<SourcePage, ApiError> {
        self.source(&source_id, revision)?.read_page(cursor, limit)
    }

    pub fn chapter_page(
        &self,
        source_id: String,
        revision: u32,
        offset: u32,
        limit: u32,
    ) -> Result<ChapterPage, ApiError> {
        self.source(&source_id, revision)?
            .chapter_page(offset, limit)
    }
}

impl Drop for ImportService {
    fn drop(&mut self) {
        for token in self.state.lock().expect("service state").active.values() {
            token.cancel();
        }
        // Runtime drops after this method and waits for its cooperative worker.
    }
}

fn progress(shared: &Arc<Mutex<State>>, id: u32, phase: JobPhase, processed_bytes: u32) {
    let mut state = shared.lock().expect("service state");
    if let Some(job) = state.jobs.get_mut(&id)
        && job.phase != JobPhase::Cancelling
    {
        job.phase = phase;
        job.processed_bytes = processed_bytes;
        job.sequence += 1;
    }
}

fn finish(
    shared: &Arc<Mutex<State>>,
    id: u32,
    token: &CancellationToken,
    result: Result<Option<SourceSnapshot>, ApiError>,
) {
    let mut state = shared.lock().expect("service state");
    // The same lock linearizes cancellation vs publishing a successful import.
    let result = if token.is_cancelled() {
        Err(ApiError::new(ErrorCode::Cancelled, "job", "retry_job"))
    } else {
        result
    };
    let result = result.and_then(|source| {
        if let Some(ref new) = source {
            let id = new.summary().source_id;
            if !state.sources.contains_key(&id)
                && (state.sources.len() >= MAX_SOURCES
                    || state
                        .sources
                        .values()
                        .map(|s| s.resident_bytes())
                        .sum::<usize>()
                        + new.resident_bytes()
                        > MAX_SESSION_BYTES)
            {
                return Err(ApiError::new(
                    ErrorCode::TooLarge,
                    "session_budget",
                    "save_project_and_restart",
                ));
            }
        }
        Ok(source)
    });
    let (phase, book, error) = match result {
        Ok(source) => {
            let book = source.as_ref().map(SourceSnapshot::summary);
            if let Some(source) = source {
                let key = source.summary().source_id;
                state.sources.entry(key).or_insert_with(|| Arc::new(source));
            }
            (JobPhase::Completed, book, None)
        }
        Err(error) if error.code == ErrorCode::Cancelled => {
            (JobPhase::Cancelled, None, Some(error))
        }
        Err(error) => (JobPhase::Failed, None, Some(error)),
    };
    if let Some(job) = state.jobs.get_mut(&id) {
        job.phase = phase;
        job.book = book;
        job.error = error;
        job.cancellable = false;
        job.sequence += 1;
    }
    state.active.remove(&id);
}

pub(crate) fn read_bounded(
    path: &Path,
    token: &CancellationToken,
    on_progress: impl Fn(u32),
) -> Result<Vec<u8>, ApiError> {
    let mut file = File::open(path).map_err(|e| {
        ApiError::new(
            if e.kind() == std::io::ErrorKind::NotFound {
                ErrorCode::NotFound
            } else {
                ErrorCode::Io
            },
            "open_source",
            "choose_readable_file",
        )
    })?;
    let metadata = file
        .metadata()
        .map_err(|_| ApiError::new(ErrorCode::Io, "source_metadata", "choose_readable_file"))?;
    if !metadata.is_file() || metadata.len() > MAX_IMPORT_BYTES as u64 {
        return Err(ApiError::new(
            ErrorCode::TooLarge,
            "import",
            "choose_file_under_128_mib",
        ));
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    let mut block = [0_u8; 64 * 1024];
    loop {
        if token.is_cancelled() {
            return Err(ApiError::new(
                ErrorCode::Cancelled,
                "read_source",
                "retry_import",
            ));
        }
        let count = file
            .read(&mut block)
            .map_err(|_| ApiError::new(ErrorCode::Io, "read_source", "choose_readable_file"))?;
        if count == 0 {
            break;
        }
        if bytes.len() + count > MAX_IMPORT_BYTES {
            return Err(ApiError::new(
                ErrorCode::TooLarge,
                "import",
                "choose_file_under_128_mib",
            ));
        }
        bytes.extend_from_slice(&block[..count]);
        on_progress(bytes.len() as u32);
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    #[test]
    fn cleanup_cache_reuses_pages_and_context_and_invalidates_source_and_rules() {
        let service = ImportService::new().unwrap();
        let line = format!("{}  \n", "正文".repeat(170));
        let raw = format!("第一章 起\n{}", line.repeat(8192));
        let source = Arc::new(
            SourceSnapshot::from_utf8(
                raw.as_bytes().to_vec(),
                easypub_core::source::RULE_ID,
                || false,
            )
            .unwrap(),
        );
        let summary = source.summary();
        service
            .replace_sources(BTreeMap::from([(
                summary.source_id.clone(),
                Arc::clone(&source),
            )]))
            .unwrap();
        let request =
            serde_json::json!({"kind":"cleanup","pipeline":[{"kind":"trim_trailing_spaces"}]});
        let started = std::time::Instant::now();
        let first = service
            .preview_repair_plan(
                summary.source_id.clone(),
                summary.revision,
                request.to_string(),
            )
            .unwrap();
        let cold = started.elapsed();
        let retained = service
            .cleanup_preview
            .lock()
            .unwrap()
            .as_ref()
            .expect("large plan is cached")
            .plan
            .clone();
        let warm = std::time::Instant::now();
        for offset in [0, 40, 80, 120, 160] {
            let mut q = request.clone();
            q["preview_offset"] = serde_json::json!(offset);
            assert_eq!(
                service
                    .preview_repair_plan(summary.source_id.clone(), summary.revision, q.to_string())
                    .unwrap(),
                retained.preview_at(offset)
            );
            let query = serde_json::json!({"kind":"cleanup_context","request":q,"first":offset+2,"last":offset+2});
            let context: Value = serde_json::from_str(
                &service
                    .preview_repair_plan(
                        summary.source_id.clone(),
                        summary.revision,
                        query.to_string(),
                    )
                    .unwrap(),
            )
            .unwrap();
            assert_eq!(
                context["plan_id"],
                serde_json::from_str::<Value>(&first).unwrap()["plan_id"]
            );
            assert!(Arc::ptr_eq(
                &retained,
                &service
                    .cleanup_preview
                    .lock()
                    .unwrap()
                    .as_ref()
                    .unwrap()
                    .plan
            ));
        }
        eprintln!(
            "cleanup76 bytes={} cache_estimate={} cold_ms={} five_pages_and_context_ms={}",
            raw.len(),
            retained.cache_bytes(),
            cold.as_millis(),
            warm.elapsed().as_millis()
        );
        let changed = serde_json::json!({"kind":"cleanup","pipeline":[]});
        let (different, _) = service.cleanup_preview_plan(&source, changed).unwrap();
        assert!(!Arc::ptr_eq(&retained, &different));
        assert!(
            service
                .preview_repair_plan(
                    summary.source_id.clone(),
                    summary.revision + 1,
                    request.to_string()
                )
                .is_err()
        );
        let mut bad = request.clone();
        bad["unexpected"] = serde_json::json!(true);
        assert!(service.cleanup_preview_plan(&source, bad).is_err());
        service.replace_sources(BTreeMap::new()).unwrap();
        assert!(service.cleanup_preview.lock().unwrap().is_none());
        assert!(
            service
                .preview_repair_plan(summary.source_id, summary.revision, request.to_string())
                .is_err()
        );
        assert_eq!(source.decoded_text(), raw);
    }

    #[test]
    fn cleanup_cache_does_not_retain_oversized_plan() {
        let service = ImportService::new().unwrap();
        let source = Arc::new(
            SourceSnapshot::from_utf8(
                vec![b'x'; MAX_CLEANUP_CACHE_BYTES + 1],
                easypub_core::source::RULE_ID,
                || false,
            )
            .unwrap(),
        );
        let (plan, _) = service
            .cleanup_preview_plan(&source, serde_json::json!({"kind":"cleanup","pipeline":[]}))
            .unwrap();
        assert!(plan.cache_bytes() > MAX_CLEANUP_CACHE_BYTES);
        assert!(service.cleanup_preview.lock().unwrap().is_none());
        assert_eq!(
            plan.output(&source).unwrap().len(),
            MAX_CLEANUP_CACHE_BYTES + 1
        );
    }
    use super::*;
    use std::time::Instant;

    fn terminal(service: &ImportService, id: u32) -> JobSnapshot {
        let until = Instant::now() + Duration::from_secs(5);
        loop {
            let job = service.get_job(id).unwrap();
            if job.terminal() {
                return job;
            }
            assert!(Instant::now() < until, "worker did not stop");
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    #[test]
    fn cancellation_stops_worker_before_releasing_capacity() {
        // V38 起最多 MAX_ACTIVE_JOBS 个任务同时进行；名额满时，要等某个任务真正停下才腾出来。
        let service = ImportService::new().unwrap();
        let ids: Vec<u32> = (0..MAX_ACTIVE_JOBS)
            .map(|_| service.start_cancellation_probe().unwrap())
            .collect();
        let id = ids[0];
        assert_eq!(
            service.start_cancellation_probe().unwrap_err().code,
            ErrorCode::Busy
        );
        assert_eq!(service.cancel_job(id).unwrap().phase, JobPhase::Cancelling);
        assert_eq!(terminal(&service, id).phase, JobPhase::Cancelled);
        let next = service.start_cancellation_probe().unwrap();
        service.cancel_job(next).unwrap();
        assert_eq!(terminal(&service, next).phase, JobPhase::Cancelled);
        assert_eq!(service.cancel_job(id).unwrap().phase, JobPhase::Cancelled);
        for other in &ids[1..] {
            service.cancel_job(*other).unwrap();
            assert_eq!(terminal(&service, *other).phase, JobPhase::Cancelled);
        }
    }

    #[test]
    fn missing_file_is_structured_failure_not_empty_success() {
        let service = ImportService::new().unwrap();
        let id = service
            .start_import(
                "__easypub_fixture_does_not_exist__.txt".into(),
                easypub_core::source::RULE_ID.into(),
            )
            .unwrap();
        let job = terminal(&service, id);
        assert_eq!(job.phase, JobPhase::Failed);
        assert_eq!(job.error.unwrap().code, ErrorCode::NotFound);
        assert!(job.book.is_none());
    }

    #[test]
    fn composed_page_body_is_bounded_and_prefers_only_a_visible_node() {
        let service = ImportService::new().unwrap();
        let path =
            std::env::temp_dir().join(format!("easypub-combined-page-{}.txt", std::process::id()));
        let text = (1..=65)
            .map(|i| format!("第{i}章 标题\n正文{i}\n"))
            .collect::<String>();
        std::fs::write(&path, &text).unwrap();
        let job = terminal(
            &service,
            service
                .start_import(
                    path.to_string_lossy().into_owned(),
                    easypub_core::source::RULE_ID.into(),
                )
                .unwrap(),
        );
        let source = job.book.unwrap();
        let query = |offset, preferred: Option<&str>| -> serde_json::Value {
            serde_json::from_str(
                &service
                    .effective_structure_text(
                        source.source_id.clone(),
                        source.revision,
                        String::new(),
                        serde_json::json!({"kind":"publication", "body_preview":{
                    "entry_id":preferred,"select_page":true,"offset":0}})
                        .to_string(),
                        offset,
                    )
                    .unwrap(),
            )
            .unwrap()
        };
        let first = query(0, None);
        assert_eq!(first["nodes"].as_array().unwrap().len(), 30);
        assert_eq!(
            first["body_preview"]["entry_id"],
            first["nodes"][0]["entry_id"]
        );
        assert_eq!(first["body_preview"]["rows"][0]["text"], "正文1");
        let preferred = first["nodes"][2]["entry_id"].as_str().unwrap();
        let selected = query(0, Some(preferred));
        assert_eq!(selected["body_preview"]["entry_id"], preferred);
        assert_eq!(selected["body_preview"]["rows"][0]["text"], "正文3");
        let next = query(30, Some(preferred));
        assert_eq!(next["body_preview"]["rows"][0]["text"], "正文31");
        let focused: serde_json::Value = serde_json::from_str(
            &service
                .effective_structure_text(
                    source.source_id.clone(),
                    source.revision,
                    String::new(),
                    serde_json::json!({"kind":"publication","body_preview":{
                        "entry_id":preferred,"offset":0,"select_page":true,"focus_page":true
                    }})
                    .to_string(),
                    60,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(focused["offset"], 0);
        assert_eq!(focused["body_preview"]["entry_id"], preferred);
        assert_eq!(focused["body_preview"]["rows"][0]["text"], "正文3");
        assert_eq!(query(90, None)["body_preview"], serde_json::Value::Null);
        let handle_query = serde_json::json!({"kind":"publication", "composition_key":first["composition_key"],
            "response_scope":"context", "effective_check":{"offset":0,"line":5,"original_line":5}}).to_string();
        let cached: Value = serde_json::from_str(&service.effective_structure_text(
            source.source_id.clone(), source.revision, String::new(), handle_query.clone(), 0,
        ).unwrap()).unwrap();
        assert_eq!(cached["nodes"].as_array().unwrap().len(), 0);
        assert_eq!(cached["effective_check"]["context_original_line"], 5);
        assert!(!cached["effective_check"]["original_excerpt"][0]["anchor"].as_str().unwrap().is_empty());
        assert_eq!(service.effective_views.lock().unwrap().len(), 1);
        let positions_query = |positions: Value| serde_json::json!({"kind":"publication",
            "composition_key":first["composition_key"], "response_scope":"context",
            "effective_check":{"offset":0,"positions":positions}}).to_string();
        let positions: Value = serde_json::from_str(&service.effective_structure_text(
            source.source_id.clone(), source.revision, String::new(),
            positions_query(serde_json::json!({"summary":true,"entry_id":preferred})), 0,
        ).unwrap()).unwrap();
        let positions = &positions["effective_check"]["positions"];
        assert_eq!(positions["total"], cached["effective_check"]["report"]["diagnostic"]["review_total"]);
        assert!(positions["nodes"].is_array());
        assert_eq!(positions["chapter"]["entry_id"], preferred);
        assert_eq!(service.effective_views.lock().unwrap().len(), 1);
        assert!(service.effective_structure_text(source.source_id.clone(), source.revision,
            String::new(), positions_query(serde_json::json!({"entry_id":"missing"})), 0).is_err());
        service.effective_views.lock().unwrap().clear();
        assert_eq!(service.effective_structure_text(source.source_id.clone(), source.revision,
            String::new(), handle_query, 0).unwrap_err().next_action, "refresh_composition");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), text);
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn up_to_eight_jobs_run_at_once_and_each_cancels_alone() {
        let service = ImportService::new().unwrap();
        let ids: Vec<u32> = (0..MAX_ACTIVE_JOBS)
            .map(|_| service.start_cancellation_probe().unwrap())
            .collect();
        let busy = service.start_cancellation_probe().unwrap_err();
        assert_eq!(busy.code, ErrorCode::Busy);
        // 取消其中一个只影响它自己，其余继续进行。
        service.cancel_job(ids[0]).unwrap();
        for _ in 0..400 {
            if service.get_job(ids[0]).unwrap().terminal() {
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(service.get_job(ids[0]).unwrap().phase, JobPhase::Cancelled);
        assert!(!service.get_job(ids[1]).unwrap().terminal());
        // 有空位后又可以开始新任务。
        let next = service.start_cancellation_probe().unwrap();
        for id in ids.iter().skip(1).chain([&next]) {
            service.cancel_job(*id).unwrap();
        }
    }

    #[test]
    fn effective_structure_accepts_native_manual_batch_preview() {
        let service = ImportService::new().unwrap();
        let path = std::env::temp_dir().join(format!(
            "easypub-effective-manual-{}.txt",
            std::process::id()
        ));
        std::fs::write(
            &path,
            "卷前文字\n第一卷 起  \n卷首说明\n第一章 甲\n甲文\n第二章 误识别\n仍是甲文\n第三章 丙\n丙文",
        )
        .unwrap();
        let id = service
            .start_import(
                path.to_string_lossy().into_owned(),
                easypub_core::source::RULE_ID.into(),
            )
            .unwrap();
        let job = terminal(&service, id);
        let source = job.book.expect("import summary");
        let settings = serde_json::json!({
            "source_id": source.source_id,
            "revision": source.revision,
            "overrides": [
                {"source_line": 6, "role": "body", "depth": 0, "include_toc": false},
                {"source_line": 8, "role": "section", "depth": 2, "include_toc": false}
            ]
        });
        let result = service
            .effective_structure_text(
                source.source_id.clone(),
                source.revision,
                settings.to_string(),
                r#"{"kind":"manual_batch","actions":[{"kind":"rename_title","source_line":4,"title":"无编号的新章名"}]}"#.into(),
                0,
            )
            .unwrap();
        let value: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(value["text_changed"], true);
        assert_eq!(value["nodes"][1]["title"], "无编号的新章名");
        let _ = std::fs::remove_file(path);
    }
}

#[cfg(test)]
mod rebase_composition_tests {
    use easypub_core::{
        effective_edit::{self, Action, Request},
        publication,
        source::{RULE_ID, SourceSnapshot},
        structure::Structure,
    };
    use serde_json::{Value, json};
    use std::{collections::BTreeMap, sync::Arc};

    #[test]
    fn cleanup_preview_rebases_stored_chapter_edits_and_checkpoints_with_their_root() {
        let source = Arc::new(
            SourceSnapshot::from_utf8(
                "第一章 开始\n甲文\n\n\n甲续\n第二章 后续\n乙文\n"
                    .as_bytes()
                    .to_vec(),
                RULE_ID,
                || false,
            )
            .unwrap(),
        );
        let source_id = source.summary().source_id;
        let old = publication::compose_with_cleanup(&source, &Structure::new(&source), None, None)
            .unwrap();
        let edits = Request {
            base_id: effective_edit::base_id(&old),
            actions: vec![Action::Rename {
                entry_id: old.tree.nodes[1].entry_id.clone(),
                title: "第二章 改名".into(),
            }],
        };
        let service = crate::sessions::ImportService::new().unwrap();
        service
            .replace_sources(BTreeMap::from([(source_id.clone(), source.clone())]))
            .unwrap();
        let cleanup = json!({"kind":"cleanup","pipeline":[{"kind":"collapse_blank_lines"}]});
        let query = |extra: Value| {
            let mut request = json!({"kind":"publication","cleanup":cleanup,"post_edits":edits});
            for (k, v) in extra.as_object().unwrap() {
                request[k] = v.clone();
            }
            service.effective_structure_text(
                source_id.clone(),
                1,
                String::new(),
                request.to_string(),
                0,
            )
        };
        // Without rebasing, the edits made before cleanup are rejected as before.
        assert!(query(json!({})).is_err());
        let value: Value =
            serde_json::from_str(&query(json!({"rebase_from":{"cleanup":null}})).unwrap()).unwrap();
        let rebase = &value["post_edit_rebase"];
        assert_eq!(rebase["kept"], json!([0]));
        assert_eq!(rebase["skipped"], json!([]));
        assert_eq!(rebase["total"], 1);
        assert_eq!(value["nodes"][1]["title"], "第二章 改名");
        // The returned request is valid on the cleaned base without rebasing.
        let stored = rebase["request"].clone();
        assert_eq!(stored["base_id"], value["editing_base_id"]);
        let again: Value = serde_json::from_str(
            &service
                .effective_structure_text(
                    source_id.clone(),
                    1,
                    String::new(),
                    json!({"kind":"publication","cleanup":cleanup,"post_edits":stored}).to_string(),
                    0,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(again["nodes"][1]["title"], "第二章 改名");
        assert!(again["post_edit_rebase"].is_null());
        // A checkpoint keeps a finished book, not replayable actions.
        let dir = std::env::temp_dir().join(format!("easypub-rebase-{}", std::process::id()));
        let reference =
            crate::edit_checkpoint::save(&dir, &effective_edit::apply(old, &edits).unwrap().0)
                .unwrap();
        let checkpointed = json!({"base_id":reference.base_id,"actions":[],
            "checkpoint":{"directory":dir,"origin_base_id":edits.base_id,"reference":reference}});
        let error = service
            .effective_structure_text(
                source_id.clone(),
                1,
                String::new(),
                json!({"kind":"publication","cleanup":cleanup,"post_edits":checkpointed,
                    "rebase_from":{"cleanup":null}})
                .to_string(),
                0,
            )
            .unwrap_err();
        assert_eq!(error.next_action, "rebase_checkpoint");
        // 带上创建检查点那一步保存的原始操作，就能分两段换算（CLEAN-105）。
        let moved: serde_json::Value = serde_json::from_str(
            &service
                .effective_structure_text(
                    source_id,
                    1,
                    String::new(),
                    json!({"kind":"publication","cleanup":cleanup,"post_edits":checkpointed,
                        "rebase_from":{"cleanup":null,"checkpoint_root":edits}})
                    .to_string(),
                    0,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(moved["post_edit_rebase"]["checkpoint"], true);
        assert_eq!(moved["post_edit_rebase"]["skipped"], json!([]));
        assert_eq!(moved["nodes"][1]["title"], "第二章 改名");
        let _ = std::fs::remove_dir_all(dir);
    }
}
