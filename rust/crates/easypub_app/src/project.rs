//! Versioned projects. Ordinary saves reference sources; recovery saves carry
//! immutable source bytes alongside the project without overwriting originals.
use crate::sessions::{ImportService, MAX_SESSION_BYTES, MAX_SOURCES, read_bounded};
use easypub_core::{ApiError, ErrorCode, encoding::EncodingMode, source::SourceSnapshot};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};
use tokio_util::sync::CancellationToken;

const MAX_PROJECT_BYTES: usize = 128 * 1024 * 1024;
static NEXT_STAGE: AtomicU64 = AtomicU64::new(1);
fn default_cover_fit() -> String {
    "cover".into()
}
fn default_font_family() -> String {
    "Microsoft YaHei".into()
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Project {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recognition_default_draft: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub recognition_presets: Vec<easypub_core::chapter_rules::Preset>,
    #[serde(default)]
    pub project_folder_rules_enabled: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub cleanup_presets: Vec<crate::cleanup_presets::Preset>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub layout_presets: Vec<crate::layout_presets::Preset>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub folder_rules: Vec<crate::folder_mapping::Rule>,
    pub schema: u32,
    pub rule_id: String,
    pub books: Vec<ProjectBook>,
    pub current_path: String,
    pub output: String,
    pub format: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProjectBook {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rule_toggle_history: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recognition_draft: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub layout_origins: crate::layout_settings::Origins,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub metadata_origins: BTreeMap<String, crate::production::MetadataOrigin>,
    pub path: String,
    /// Original user-selected container path when `path` is a generated
    /// UTF-8 working copy (for example an imported EPUB).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin_path: Option<String>,
    /// EPUB resource manifest and image placement proposals. The source text
    /// remains the canonical Rust snapshot; this value only restores the
    /// private extracted-resource review state on project reopen.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub epub_resources: Option<serde_json::Value>,
    pub source_id: String,
    pub revision: u32,
    pub title: String,
    pub author: String,
    pub description: String,
    #[serde(default)]
    pub translator: String,
    #[serde(default)]
    pub isbn: String,
    #[serde(default)]
    pub publication_date: String,
    #[serde(default)]
    pub publisher: String,
    #[serde(default)]
    pub category: String,
    #[serde(default)]
    pub series: String,
    #[serde(default)]
    pub series_index: String,
    #[serde(default)]
    pub subjects: String,
    #[serde(default)]
    pub language: String,

    #[serde(default = "crate::production::default_font_size_unit")]
    pub font_size_unit: String,
    #[serde(default)]
    pub fullwidth_indent: u8,
    #[serde(default)]
    pub remove_blank_lines: bool,
    pub font_size: f64,
    pub line_height: f64,
    #[serde(default = "crate::production::default_text_alignment")]
    pub text_alignment: String,
    /// 书写方向（V28，LAY-104）：horizontal 横排、vertical 竖排（从右往左翻页）。
    #[serde(default = "crate::production::default_writing_mode")]
    pub writing_mode: String,
    /// 竖排时连续不超过这么多位的半角数字横着排（纵中横）；0 关闭。
    #[serde(default = "crate::production::default_vertical_digits")]
    pub vertical_digits: u8,
    /// 章节标题样式（V36，LAY-117）。
    #[serde(default = "crate::production::default_heading_style")]
    pub heading_style: String,
    /// 场景分隔样式（V46，LAY-118）。
    #[serde(default = "crate::production::default_scene_break_style")]
    pub scene_break_style: String,
    #[serde(default = "crate::production::default_note_style")]
    pub note_style: String,
    /// 章首段落样式（V49，LAY-119）。
    #[serde(default = "crate::production::default_first_paragraph_style")]
    pub first_paragraph_style: String,
    /// 系统提示样式（V50，LAY-121）。
    #[serde(default = "crate::production::default_system_block_style")]
    pub system_block_style: String,
    /// 诗词样式（V50，LAY-122）。
    #[serde(default = "crate::production::default_verse_block_style")]
    pub verse_block_style: String,
    #[serde(default)]
    pub rule_options: crate::rule_options::Options,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub block_annotations: Vec<crate::block_annotations::Annotation>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub manual_notes: Vec<crate::manual_notes::Note>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub supplemental_pages: Vec<crate::supplemental_pages::Page>,
    #[serde(default)]
    pub additional_css: String,
    #[serde(default)]
    pub additional_css_base: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub additional_css_bundle: Option<crate::css_bundle::Reference>,
    #[serde(default)]
    pub css_font_permissions: Vec<String>,
    #[serde(default = "crate::production::default_paragraph_indent")]
    pub paragraph_indent: f64,
    #[serde(default = "crate::production::default_paragraph_spacing")]
    pub paragraph_spacing: f64,
    #[serde(default)]
    pub margin_top: f64,
    #[serde(default = "crate::production::default_margin_unit")]
    pub margin_top_unit: String,
    #[serde(default)]
    pub margin_right: f64,
    #[serde(default = "crate::production::default_margin_unit")]
    pub margin_right_unit: String,
    #[serde(default)]
    pub margin_bottom: f64,
    #[serde(default = "crate::production::default_margin_unit")]
    pub margin_bottom_unit: String,
    #[serde(default)]
    pub margin_left: f64,
    #[serde(default = "crate::production::default_margin_unit")]
    pub margin_left_unit: String,
    pub include_toc: bool,
    #[serde(default)]
    pub visible_toc: bool,
    #[serde(default)]
    pub chapter_navigation: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_path: Option<String>,
    /// 统一章首图（V54，LAY-124）：图片路径，与封面一样属于本书，不进排版预设。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chapter_head_image: Option<String>,
    #[serde(default = "crate::production::default_chapter_head_scope")]
    pub chapter_head_scope: String,
    #[serde(default = "crate::production::default_chapter_head_width")]
    pub chapter_head_width: String,
    #[serde(default = "default_cover_fit")]
    pub cover_fit: String,
    #[serde(default)]
    pub cover_crop: Option<crate::assets::Crop>,
    #[serde(default)]
    pub cover_design: Option<crate::production::CoverDesign>,
    #[serde(default = "default_font_family")]
    pub font_family: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub font_resource: Option<crate::fonts::Selection>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub illustrations: Vec<Illustration>,
    pub selected: bool,
    /// Immutable catalog metadata, no source body or credentials. Confirmation
    /// and repair plans are deliberately not persisted.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reference_catalog: Option<crate::catalog::Catalog>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub manual_draft: Option<crate::manual_draft::ManualDraft>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effective_history: Option<crate::effective_draft::History>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub structure: Option<easypub_core::structure::Structure>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub structure_history: Option<crate::structure_draft::StructureDraft>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cleanup: Option<easypub_core::cleanup::Request>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cleanup_history: Option<crate::cleanup_draft::CleanupDraft>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub production_history: Option<crate::production::History>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review: Option<easypub_core::review::Review>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Illustration {
    pub path: String,
    #[serde(default)]
    pub caption: String,
    #[serde(default)]
    pub alt: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_line: Option<u32>,
    /// 插图版式（V54，RES-050）：inline 随正文；full_page 整页；chapter_head 放在所在章的标题上方。
    #[serde(
        default = "crate::production::default_illustration_layout",
        skip_serializing_if = "crate::production::illustration_layout_is_inline"
    )]
    pub layout: String,
}
#[derive(Serialize)]
struct OpenedProject {
    project: Project,
    summaries: Vec<ImportedSummary>,
    resource_issues: Vec<ResourceIssue>,
}
#[derive(Serialize)]
pub(crate) struct ResourceIssue {
    book_path: String,
    kind: &'static str,
    index: Option<usize>,
    path: String,
    reason: String,
}
fn resource_issues(book: &ProjectBook) -> Vec<ResourceIssue> {
    resource_issues_for_settings(&book.path, &crate::production::Settings::from(book))
}
pub(crate) fn resource_issues_for_settings(
    book_path: &str,
    settings: &crate::production::Settings,
) -> Vec<ResourceIssue> {
    let mut issues = Vec::new();
    if let Some(bundle) = &settings.additional_css_bundle {
        for reason in crate::css_bundle::for_settings(settings).report.issues {
            issues.push(ResourceIssue {
                book_path: book_path.into(),
                kind: "css_bundle",
                index: None,
                path: bundle.directory.clone(),
                reason,
            });
        }
    }

    let mut seen = BTreeMap::<String, Result<u64, String>>::new();
    let mut check_image = |kind, index, path: &String| {
        let result = seen.entry(path.to_lowercase()).or_insert_with(|| {
            crate::assets::inspect(path)
                .map(|e| e.bytes)
                .map_err(|e| e.next_action)
        });
        if let Err(reason) = result {
            issues.push(ResourceIssue {
                book_path: book_path.to_owned(),
                kind,
                index,
                path: path.clone(),
                reason: reason.clone(),
            });
        }
    };
    if let Some(path) = &settings.cover_path {
        check_image("cover", None, path);
    }
    if let Some(path) = &settings.chapter_head_image {
        check_image("chapter_head", None, path);
    }
    for (index, image) in settings.illustrations.iter().enumerate() {
        check_image("illustration", Some(index), &image.path);
    }
    if seen.values().filter_map(|r| r.as_ref().ok()).sum::<u64>() > 256 * 1024 * 1024 {
        issues.push(ResourceIssue {
            book_path: book_path.to_owned(),
            kind: "budget",
            index: None,
            path: String::new(),
            reason: "reduce_resource_size".into(),
        });
    }
    if let Some(font) = &settings.font_resource
        && let Err(error) = font.inspect_confirmed()
    {
        issues.push(ResourceIssue {
            book_path: book_path.to_owned(),
            kind: "font",
            index: None,
            path: font.path.clone(),
            reason: error.next_action,
        });
    }
    issues
}
#[derive(Serialize)]
struct ImportedSummary {
    path: String,
    source_id: String,
    revision: u32,
    encoding: String,
    lines: u32,
    headings: u32,
}
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "project_schema",
        "choose_supported_project",
    )
}
fn io() -> ApiError {
    ApiError::new(ErrorCode::Io, "project_io", "check_path_permissions")
}

impl Project {
    pub(crate) fn validate(&self) -> Result<(), ApiError> {
        easypub_core::chapter_rules::validate_presets(&self.recognition_presets)?;
        crate::folder_mapping::validate_rules(&self.folder_rules)?;
        crate::layout_presets::validate(&self.layout_presets)?;
        crate::cleanup_presets::validate(&self.cleanup_presets)?;
        if self.rule_id != easypub_core::source::RULE_ID
            || self.schema != 1
            || self.books.len() > MAX_SOURCES
            || !["EPUB", "AZW3", "MOBI", "KFX"].contains(&self.format.as_str())
            || self.output.len() > 32768
        {
            return Err(invalid());
        }
        let mut paths = BTreeSet::new();
        for b in &self.books {
            if !Path::new(&b.path).is_absolute()
                || !b.path.to_lowercase().ends_with(".txt")
                || !paths.insert(b.path.to_lowercase())
                || b.revision != 1
                || b.source_id.len() != 64
                || !b
                    .source_id
                    .bytes()
                    .all(|v| v.is_ascii_hexdigit() && !v.is_ascii_uppercase())
                || b.title.len() > 4096
                || b.author.len() > 4096
                || b.description.len() > 65536
                || !crate::production::valid_font_size(b.font_size, &b.font_size_unit)
                || b.fullwidth_indent > 8
                || !(1.0..=2.3).contains(&b.line_height)
            {
                return Err(invalid());
            }
            if let Some(origin) = &b.origin_path
                && (!Path::new(origin).is_absolute()
                    || origin.len() > 32768
                    || origin.contains('\0')
                    || !matches!(
                        Path::new(origin)
                            .extension()
                            .and_then(|e| e.to_str())
                            .unwrap_or("")
                            .to_ascii_lowercase()
                            .as_str(),
                        "txt" | "epub"
                    ))
            {
                return Err(invalid());
            }
            if b.epub_resources.as_ref().is_some_and(|value| {
                serde_json::to_vec(value)
                    .map(|bytes| bytes.len() > 2 * 1024 * 1024)
                    .unwrap_or(true)
            }) {
                return Err(invalid());
            }
            if let Some(review) = &b.review {
                review.validate_shape()?;
            }
            if let Some(history) = &b.rule_toggle_history {
                crate::rule_toggles::validate_history(history)?;
            }
            if let Some(history) = &b.production_history {
                history.validate(u32::MAX)?;
                if history.source_id != b.source_id
                    || history.revision != b.revision
                    || history.current() != &crate::production::Settings::from(b)
                {
                    return Err(invalid());
                }
            }
            if let Some(draft) = &b.cleanup_history {
                draft.validate_shape()?;
                if draft.source_id != b.source_id
                    || draft.source_revision != b.revision
                    || draft.current() != &b.cleanup
                {
                    return Err(invalid());
                }
            }
            if let Some(history) = &b.structure_history {
                history.validate_shape()?;
                let current = history.current();
                if current.source_id != b.source_id
                    || current.revision != b.revision
                    || b.structure.as_ref() != Some(current)
                {
                    return Err(invalid());
                }
            }
            if let Some(structure) = &b.structure {
                structure.validate_shape()?;
                if structure.source_id != b.source_id || structure.revision != b.revision {
                    return Err(invalid());
                }
            }
            if let Some(catalog) = &b.reference_catalog {
                crate::catalog::validate_snapshot(catalog)?;
            }
            let settings = crate::production::Settings::from(b);
            settings.validate(u32::MAX)?;
            // External resources can be repaired after opening; source integrity remains mandatory.
            if let Some(history) = &b.effective_history {
                history.validate_shape()?;
                if history.source_id != b.source_id || history.revision != b.revision {
                    return Err(invalid());
                }
            }
            if let Some(draft) = &b.manual_draft {
                draft.validate_shape()?;
                if draft.source_id != b.source_id || draft.source_revision != b.revision {
                    return Err(invalid());
                }
            }
        }
        if if self.books.is_empty() {
            !self.current_path.is_empty()
        } else {
            !paths.contains(&self.current_path.to_lowercase())
        } {
            return Err(invalid());
        }
        Ok(())
    }
}
fn parse(text: &str) -> Result<Project, ApiError> {
    if text.len() > MAX_PROJECT_BYTES {
        return Err(invalid());
    }
    let project: Project = serde_json::from_str(text).map_err(|_| invalid())?;
    project.validate()?;
    Ok(project)
}
fn project_path(path: &str) -> Result<&Path, ApiError> {
    let p = Path::new(path);
    if !p.is_absolute() || !path.to_lowercase().ends_with(".easypub.json") {
        return Err(invalid());
    }
    Ok(p)
}

/// Save-as only: a synced stage is published with a non-replacing hard link.
/// Existing project/source paths are never opened for writing.
pub fn save(service: &ImportService, path: &str, payload: &str) -> Result<(), ApiError> {
    let target = project_path(path)?;
    save_parsed(service, target, parse(payload)?, false)
}

/// Capture resident original bytes before a source refresh. This deliberately
/// does not reread paths that may already contain the replacement manuscript.
pub fn save_recovery(service: &ImportService, path: &str, payload: &str) -> Result<(), ApiError> {
    let target = project_path(path)?;
    let project = parse(payload)?;
    validate_sources(service, &project)?;
    if target.exists() {
        return Err(ApiError::new(
            ErrorCode::OutputConflict,
            "save_recovery",
            "choose_new_project_path",
        ));
    }
    let mut captured = project.clone();
    let bundle = crate::source_project::capture(service, &mut captured, target)?;
    let result = save_parsed(service, target, captured, true);
    if result.is_ok() {
        bundle.keep();
    }
    result
}

fn validate_sources(service: &ImportService, project: &Project) -> Result<(), ApiError> {
    for book in &project.books {
        let source = service.source(&book.source_id, book.revision)?;
        crate::production::Settings::from(book).validate(source.summary().line_count)?;
        if let Some(history) = &book.production_history {
            history.validate(source.summary().line_count)?;
        }
        if let Some(draft) = &book.cleanup_history {
            draft.validate(&source)?;
        } else if let Some(cleanup) = &book.cleanup {
            easypub_core::cleanup::prepare(
                &source,
                &serde_json::to_string(cleanup).map_err(|_| invalid())?,
            )?;
        }
        if let Some(history) = &book.structure_history {
            history.validate(&source)?;
        }
        if let Some(structure) = &book.structure {
            structure.tree(&source)?;
        }
        if let Some(history) = &book.effective_history {
            history.validate(&source)?;
        }
        if let Some(draft) = &book.manual_draft {
            draft.validate_with_structure(&source, book.structure.as_ref())?;
        }
    }
    Ok(())
}

fn save_parsed(
    service: &ImportService,
    target: &Path,
    mut project: Project,
    recovery: bool,
) -> Result<(), ApiError> {
    if target.exists() {
        return Err(ApiError::new(
            ErrorCode::OutputConflict,
            "save_project",
            "choose_new_project_path",
        ));
    }
    validate_sources(service, &project)?;
    crate::css_project::attach(&mut project, target)?;
    crate::checkpoint_project::attach(&mut project, target)?;
    project.validate()?;
    crate::checkpoint_project::relativize(&mut project, target)?;
    if recovery {
        crate::source_project::relativize(&mut project, target)?;
    }
    let data = serde_json::to_vec_pretty(&project).map_err(|_| invalid())?;
    if data.len() > MAX_PROJECT_BYTES {
        return Err(invalid());
    }
    let parent = target.parent().ok_or_else(invalid)?;
    let stage = parent.join(format!(
        ".easypub-stage-{}-{}",
        std::process::id(),
        NEXT_STAGE.fetch_add(1, Ordering::Relaxed)
    ));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&stage)
        .map_err(|_| io())?;
    let result = (|| {
        file.write_all(&data).map_err(|_| io())?;
        file.sync_all().map_err(|_| io())?;
        fs::hard_link(&stage, target).map_err(|e| {
            if e.kind() == std::io::ErrorKind::AlreadyExists {
                ApiError::new(
                    ErrorCode::OutputConflict,
                    "save_project",
                    "choose_new_project_path",
                )
            } else {
                io()
            }
        })?;
        Ok(())
    })();
    drop(file);
    let _ = fs::remove_file(stage);
    result
}

/// Read/decode/check every source before replacing the active source set.
pub fn open(service: &ImportService, path: &str) -> Result<String, ApiError> {
    let mut data = Vec::new();
    File::open(project_path(path)?)
        .map_err(|_| io())?
        .take((MAX_PROJECT_BYTES + 1) as u64)
        .read_to_end(&mut data)
        .map_err(|_| io())?;
    if data.len() > MAX_PROJECT_BYTES {
        return Err(invalid());
    }
    let mut project: Project = serde_json::from_slice(&data).map_err(|_| invalid())?;
    crate::source_project::resolve(&mut project, project_path(path)?)?;
    crate::checkpoint_project::resolve(&mut project, project_path(path)?)?;
    project.validate()?;
    crate::css_project::resolve(&mut project, project_path(path)?)?;
    for book in &mut project.books {
        let mut settings = crate::production::Settings::from(&*book);
        settings.mark_unknown_metadata()?;
        book.metadata_origins = settings.metadata_origins;
        if let Some(history) = &mut book.production_history {
            for state in &mut history.states {
                state.mark_unknown_metadata()?;
            }
        }
    }
    project.validate()?;
    let mut sources = BTreeMap::new();
    let mut summaries = Vec::new();
    let mut resident = 0usize;
    for book in &project.books {
        let bytes = read_bounded(Path::new(&book.path), &CancellationToken::new(), |_| {})?;
        let source = SourceSnapshot::from_bytes(
            bytes,
            EncodingMode::Auto,
            easypub_core::source::RULE_ID,
            || false,
        )?;
        let summary = source.summary();
        if summary.source_id != book.source_id {
            return Err(ApiError::new(
                ErrorCode::SourceChanged,
                "open_project",
                "reimport_changed_source",
            ));
        }
        crate::production::Settings::from(book).validate(source.summary().line_count)?;
        if let Some(history) = &book.production_history {
            history.validate(source.summary().line_count)?;
        }
        if let Some(draft) = &book.cleanup_history {
            draft.validate(&source)?;
        } else if let Some(cleanup) = &book.cleanup {
            easypub_core::cleanup::prepare(
                &source,
                &serde_json::to_string(cleanup).map_err(|_| invalid())?,
            )?;
        }
        if let Some(history) = &book.structure_history {
            history.validate(&source)?;
        }
        if let Some(structure) = &book.structure {
            structure.tree(&source)?;
        }
        if let Some(history) = &book.effective_history {
            history.validate(&source)?;
        }
        if let Some(draft) = &book.manual_draft {
            draft.validate_with_structure(&source, book.structure.as_ref())?;
        }
        summaries.push(ImportedSummary {
            path: book.path.clone(),
            source_id: summary.source_id.clone(),
            revision: summary.revision,
            encoding: summary.encoding,
            lines: summary.line_count,
            headings: summary.chapter_count,
        });
        if let std::collections::btree_map::Entry::Vacant(e) = sources.entry(summary.source_id) {
            resident += source.resident_bytes();
            if resident > MAX_SESSION_BYTES {
                return Err(ApiError::new(
                    ErrorCode::TooLarge,
                    "project_budget",
                    "reduce_project_size",
                ));
            }
            e.insert(Arc::new(source));
        }
    }
    let resource_issues = project.books.iter().flat_map(resource_issues).collect();
    let response = serde_json::to_string(&OpenedProject {
        project,
        summaries,
        resource_issues,
    })
    .map_err(|_| invalid())?;
    service.replace_sources(sources)?;
    Ok(response)
}

/// Start an empty in-memory workspace without touching project/source files.
pub fn clear_workspace(
    service: &ImportService,
    output: String,
    format: String,
) -> Result<String, ApiError> {
    let project = Project {
        recognition_default_draft: None,
        recognition_presets: Vec::new(),
        project_folder_rules_enabled: false,
        cleanup_presets: Vec::new(),
        layout_presets: Vec::new(),
        folder_rules: Vec::new(),
        schema: 1,
        rule_id: easypub_core::source::RULE_ID.into(),
        books: Vec::new(),
        current_path: String::new(),
        output,
        format,
    };
    project.validate()?;
    let response = serde_json::to_string(&OpenedProject {
        project,
        summaries: Vec::new(),
        resource_issues: Vec::new(),
    })
    .map_err(|_| invalid())?;
    service.replace_sources(BTreeMap::new())?;
    Ok(response)
}

#[cfg(test)]
mod tests {
    use super::*;
    use easypub_core::source::{RULE_ID, SourceCursor};
    use std::time::{Duration, Instant};
    fn import(service: &ImportService, path: &Path) -> String {
        let id = service
            .start_import(path.to_string_lossy().into(), RULE_ID.into())
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let j = service.get_job(id).unwrap();
            if j.terminal() {
                return j.book.expect("successful import").source_id;
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(2));
        }
    }
    fn text(service: &ImportService, id: &str) -> String {
        service
            .read_page(id.into(), 1, SourceCursor::default(), 10)
            .unwrap()
            .items
            .iter()
            .map(|x| x.text.as_str())
            .collect::<Vec<_>>()
            .join("\n")
    }
    #[test]
    fn empty_project_roundtrip_clears_session_and_preserves_settings() {
        let dir = std::env::temp_dir().join(format!(
            "empty-project-{}-{}",
            std::process::id(),
            NEXT_STAGE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&dir).unwrap();
        let source = dir.join("book.txt");
        fs::write(&source, "第一章 标题\n正文").unwrap();
        let service = ImportService::new().unwrap();
        let id = import(&service, &source);
        let target = dir.join("empty.easypub.json");
        let payload = serde_json::json!({"schema":1,"rule_id":RULE_ID,"books":[],
            "current_path":"","format":"MOBI","output":dir.to_string_lossy(),
            "project_folder_rules_enabled":true});
        save(&service, target.to_str().unwrap(), &payload.to_string()).unwrap();
        let opened: serde_json::Value =
            serde_json::from_str(&open(&service, target.to_str().unwrap()).unwrap()).unwrap();
        assert_eq!(opened["project"]["books"], serde_json::json!([]));
        assert_eq!(opened["summaries"], serde_json::json!([]));
        assert_eq!(opened["project"]["format"], "MOBI");
        assert_eq!(opened["project"]["project_folder_rules_enabled"], true);
        assert!(
            service
                .read_page(id, 1, SourceCursor::default(), 10)
                .is_err()
        );
        assert_eq!(fs::read_to_string(&source).unwrap(), "第一章 标题\n正文");
        let mut malformed = payload.clone();
        malformed["current_path"] = serde_json::json!("missing.txt");
        assert!(parse(&malformed.to_string()).is_err());
        malformed = payload.clone();
        malformed["format"] = serde_json::json!("unknown");
        assert!(parse(&malformed.to_string()).is_err());
        assert!(save(&service, target.to_str().unwrap(), &payload.to_string()).is_err());
    }

    #[test]
    fn clear_workspace_validates_before_replacing_sources() {
        let dir = std::env::temp_dir().join(format!(
            "clear-workspace-{}-{}",
            std::process::id(),
            NEXT_STAGE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&dir).unwrap();
        let path = dir.join("book.txt");
        fs::write(&path, "第一章 开始\n原稿保持").unwrap();
        let service = ImportService::new().unwrap();
        let id = import(&service, &path);
        assert!(clear_workspace(&service, String::new(), "invalid".into()).is_err());
        assert_eq!(text(&service, &id), "第一章 开始\n原稿保持");
        let job = service.start_cancellation_probe().unwrap();
        assert_eq!(
            clear_workspace(&service, String::new(), "MOBI".into())
                .unwrap_err()
                .code,
            ErrorCode::Busy
        );
        service.cancel_job(job).unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while !service.get_job(job).unwrap().terminal() {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(2));
        }
        let result: serde_json::Value = serde_json::from_str(
            &clear_workspace(&service, dir.to_string_lossy().into_owned(), "MOBI".into()).unwrap(),
        )
        .unwrap();
        assert_eq!(result["project"]["books"], serde_json::json!([]));
        assert!(service.source(&id, 1).is_err());
        assert_eq!(fs::read_to_string(&path).unwrap(), "第一章 开始\n原稿保持");
        assert_eq!(import(&service, &path), id);
    }

    #[test]
    fn multi_book_project_roundtrip_rejects_conflicts_and_changed_sources() {
        let dir = std::env::temp_dir().join(format!(
            "easypub-project-{}-{}",
            std::process::id(),
            NEXT_STAGE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&dir).unwrap();
        let a = dir.join("甲.txt");
        let b = dir.join("乙.txt");
        let target = dir.join("样例.easypub.json");
        fs::write(&a, "第一章 甲\n甲正文😀").unwrap();
        fs::write(&b, "第一章 乙\n乙正文").unwrap();
        let service = ImportService::new().unwrap();
        let ai = import(&service, &a);
        let bi = import(&service, &b);
        assert!(text(&service, &ai).contains("甲正文😀"));
        assert!(text(&service, &bi).contains("乙正文"));
        assert_eq!(
            service
                .read_page(ai.clone(), 2, SourceCursor::default(), 1)
                .unwrap_err()
                .code,
            ErrorCode::StaleRevision
        );
        let make = |path: &Path, id: String, title: &str| ProjectBook {
            rule_toggle_history: None,
            recognition_draft: None,
            metadata_origins: BTreeMap::new(),
            layout_origins: BTreeMap::new(),
            path: path.to_string_lossy().into(),
            origin_path: None,
            epub_resources: None,
            source_id: id,
            revision: 1,
            title: title.into(),
            author: "作者".into(),
            description: "简介\n第二行".into(),
            translator: String::new(),
            isbn: String::new(),
            publication_date: String::new(),
            publisher: String::new(),
            category: String::new(),
            series: String::new(),
            series_index: String::new(),
            subjects: String::new(),
            language: String::new(),

            font_size_unit: "px".into(),
            fullwidth_indent: 0,
            remove_blank_lines: false,
            font_size: 22.0,
            line_height: 2.0,
            text_alignment: crate::production::default_text_alignment(),
            writing_mode: crate::production::default_writing_mode(),
            vertical_digits: crate::production::default_vertical_digits(),
            heading_style: crate::production::default_heading_style(),
            scene_break_style: crate::production::default_scene_break_style(),
            note_style: crate::production::default_note_style(),
            first_paragraph_style: crate::production::default_first_paragraph_style(),
            system_block_style: crate::production::default_system_block_style(),
            verse_block_style: crate::production::default_verse_block_style(),
            rule_options: Default::default(),
            block_annotations: Vec::new(),
            manual_notes: Vec::new(),
            supplemental_pages: Vec::new(),
            additional_css: String::new(),
            additional_css_base: String::new(),
            additional_css_bundle: None,
            css_font_permissions: Vec::new(),
            include_toc: false,
            visible_toc: false,
            chapter_navigation: false,
            cover_path: None,
            chapter_head_image: None,
            chapter_head_scope: crate::production::default_chapter_head_scope(),
            chapter_head_width: crate::production::default_chapter_head_width(),
            cover_fit: "cover".into(),
            cover_crop: None,
            cover_design: None,
            font_family: "Microsoft YaHei".into(),
            font_resource: None,
            paragraph_indent: 2.0,
            paragraph_spacing: 0.5,
            margin_top: 0.0,
            margin_top_unit: "em".into(),
            margin_right: 0.0,
            margin_right_unit: "em".into(),
            margin_bottom: 0.0,
            margin_bottom_unit: "em".into(),
            margin_left: 0.0,
            margin_left_unit: "em".into(),
            illustrations: Vec::new(),
            selected: true,
            manual_draft: None,
            effective_history: None,
            structure: None,
            structure_history: None,
            cleanup: None,
            cleanup_history: None,
            production_history: None,
            review: None,
            reference_catalog: Some(
                crate::catalog::parse_text(
                    "第一卷 起\n第一章 甲",
                    "参考书",
                    "作者",
                    "paste",
                    Some(1),
                )
                .unwrap(),
            ),
        };
        let mut project = Project {
            recognition_default_draft: None,
            recognition_presets: Vec::new(),
            project_folder_rules_enabled: false,
            folder_rules: Vec::new(),
            layout_presets: Vec::new(),
            cleanup_presets: Vec::new(),
            schema: 1,
            rule_id: RULE_ID.into(),
            books: vec![make(&a, ai.clone(), "改名甲"), make(&b, bi.clone(), "乙")],
            current_path: a.to_string_lossy().into(),
            output: dir.to_string_lossy().into(),
            format: "EPUB".into(),
        };
        let current = crate::production::Settings::from(&project.books[0]);
        let mut before = current.clone();
        before.title = "修改前标题".into();
        project.books[0].production_history = Some(crate::production::History {
            source_id: ai.clone(),
            revision: 1,
            states: vec![before, current],
            cursor: 1,
        });
        let payload = serde_json::to_string(&project).unwrap();
        save(&service, target.to_str().unwrap(), &payload).unwrap();
        let saved = fs::read(&target).unwrap();
        assert_eq!(
            save(&service, target.to_str().unwrap(), &payload)
                .unwrap_err()
                .code,
            ErrorCode::OutputConflict
        );
        assert_eq!(fs::read(&target).unwrap(), saved);
        assert_eq!(fs::read_to_string(&a).unwrap(), "第一章 甲\n甲正文😀");
        // A fresh service represents reopening after restart.
        let reopened = ImportService::new().unwrap();
        let result: serde_json::Value =
            serde_json::from_str(&open(&reopened, target.to_str().unwrap()).unwrap()).unwrap();
        assert_eq!(result["project"]["books"][0]["title"], "改名甲");
        assert_eq!(result["project"]["books"][0]["include_toc"], false);
        assert_eq!(
            result["project"]["books"][0]["reference_catalog"]["title"],
            "参考书"
        );
        assert_eq!(
            result["project"]["books"][0]["production_history"]["cursor"],
            1
        );
        assert_eq!(
            result["project"]["books"][0]["production_history"]["states"][0]["title"],
            "修改前标题"
        );
        let mut invalid_history: serde_json::Value = serde_json::from_str(&payload).unwrap();
        invalid_history["books"][0]["production_history"]["states"][1]["title"] =
            "不同当前值".into();
        assert!(parse(&invalid_history.to_string()).is_err());
        let mut tampered: serde_json::Value = serde_json::from_str(&payload).unwrap();
        tampered["books"][0]["reference_catalog"]["entries"][0]["title"] = "篡改".into();
        assert!(parse(&tampered.to_string()).is_err());
        assert!(text(&reopened, &ai).contains("甲正文😀"));
        assert!(text(&reopened, &bi).contains("乙正文"));
        fs::write(&b, "外部修改").unwrap();
        assert_eq!(
            open(&reopened, target.to_str().unwrap()).unwrap_err().code,
            ErrorCode::SourceChanged
        );
        assert!(text(&reopened, &bi).contains("乙正文"));
        fs::remove_file(&b).unwrap();
        assert_eq!(
            open(&reopened, target.to_str().unwrap()).unwrap_err().code,
            ErrorCode::NotFound
        );
        assert!(text(&reopened, &ai).contains("甲正文😀"));
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn recovery_captures_resident_bytes_and_history_after_external_replacement() {
        let dir = std::env::temp_dir().join(format!(
            "recovery79-{}-{}",
            std::process::id(),
            NEXT_STAGE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&dir).unwrap();
        let source_path = dir.join("原稿.txt");
        let other_path = dir.join("同内容另一本.txt");
        let original = "\u{feff}第一章 旧章\r\n旧正文😀\r\n".as_bytes();
        fs::write(&source_path, original).unwrap();
        fs::write(&other_path, original).unwrap();
        let service = ImportService::new().unwrap();
        let id = import(&service, &source_path);
        assert_eq!(import(&service, &other_path), id);
        let settings = serde_json::json!({"title":"保留手工书名","author":"","description":"",
            "cover_path":null,"cover_fit":"cover","font_family":"Microsoft YaHei",
            "font_size":18.0,"line_height":1.8,"include_toc":true,"illustrations":[],
            "metadata_origins":{"author":{"source":"manual","value":""}}});
        let mut before = settings.clone();
        before["title"] = "旧书名".into();
        let book = |path: &Path| {
            let mut value = settings.clone();
            let row = value.as_object_mut().unwrap();
            row.insert("path".into(), serde_json::json!(path));
            row.insert("source_id".into(), id.clone().into());
            row.insert("revision".into(), 1.into());
            row.insert("selected".into(), true.into());
            row.insert("production_history".into(), serde_json::json!({"source_id":id,"revision":1,"states":[before,settings],"cursor":1}));
            value
        };
        let payload = serde_json::json!({"schema":1,"rule_id":RULE_ID,"books":[book(&source_path),book(&other_path)],
            "current_path":source_path,"output":dir,"format":"MOBI"}).to_string();
        let old_project = dir.join("old.easypub.json");
        save(&service, old_project.to_str().unwrap(), &payload).unwrap();
        let old_project_bytes = fs::read(&old_project).unwrap();
        fs::write(&source_path, "第二章 外部新正文").unwrap();
        fs::remove_file(&other_path).unwrap();
        assert_eq!(
            open(&service, old_project.to_str().unwrap())
                .unwrap_err()
                .code,
            ErrorCode::SourceChanged
        );

        let target = dir.join("recover.easypub.json");
        let mut incomplete = parse(&payload).unwrap();
        incomplete.books[1].source_id = "f".repeat(64);
        let failed_target = dir.join("incomplete.easypub.json");
        assert!(crate::source_project::capture(&service, &mut incomplete, &failed_target).is_err());
        assert!(!dir.join("incomplete.easypub.json.sources").exists());
        assert!(!failed_target.exists());
        save_recovery(&service, target.to_str().unwrap(), &payload).unwrap();
        let saved: serde_json::Value = serde_json::from_slice(&fs::read(&target).unwrap()).unwrap();
        let rows = saved["books"].as_array().unwrap();
        assert_ne!(rows[0]["path"], rows[1]["path"]);
        assert_eq!(rows[0]["origin_path"], serde_json::json!(source_path));
        assert!(!Path::new(rows[0]["path"].as_str().unwrap()).is_absolute());
        for row in rows {
            assert_eq!(
                fs::read(dir.join(row["path"].as_str().unwrap())).unwrap(),
                original
            );
        }
        assert_eq!(fs::read(&old_project).unwrap(), old_project_bytes);
        assert_eq!(
            fs::read_to_string(&source_path).unwrap(),
            "第二章 外部新正文"
        );
        assert!(!other_path.exists());
        assert!(save_recovery(&service, target.to_str().unwrap(), &payload).is_err());

        let moved = dir.join("moved");
        fs::create_dir(&moved).unwrap();
        fs::rename(&target, moved.join("recover.easypub.json")).unwrap();
        fs::rename(
            dir.join("recover.easypub.json.sources"),
            moved.join("recover.easypub.json.sources"),
        )
        .unwrap();
        let reopened = ImportService::new().unwrap();
        let restored: serde_json::Value = serde_json::from_str(
            &open(
                &reopened,
                moved.join("recover.easypub.json").to_str().unwrap(),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(
            restored["project"]["books"][0]["production_history"]["cursor"],
            1
        );
        assert_eq!(
            restored["project"]["books"][0]["production_history"]["states"][0]["title"],
            "旧书名"
        );
        assert_eq!(
            restored["project"]["books"][0]["metadata_origins"]["author"]["source"],
            "manual"
        );
        assert_eq!(reopened.source(&id, 1).unwrap().original_bytes(), original);
        let mut escaping = saved.clone();
        escaping["books"][0]["path"] = "../escape.txt".into();
        escaping["current_path"] = "../escape.txt".into();
        let escaped_project = moved.join("escape.easypub.json");
        fs::write(&escaped_project, escaping.to_string()).unwrap();
        assert_eq!(
            open(&reopened, escaped_project.to_str().unwrap())
                .unwrap_err()
                .code,
            ErrorCode::InvalidRule
        );
        assert_eq!(reopened.source(&id, 1).unwrap().original_bytes(), original);
        let copied = moved.join(rows[0]["path"].as_str().unwrap());
        fs::write(&copied, "损坏的副本").unwrap();
        assert_eq!(
            open(
                &reopened,
                moved.join("recover.easypub.json").to_str().unwrap()
            )
            .unwrap_err()
            .code,
            ErrorCode::SourceChanged
        );
        assert_eq!(reopened.source(&id, 1).unwrap().original_bytes(), original);
        fs::remove_file(copied).unwrap();
        assert_eq!(
            open(
                &reopened,
                moved.join("recover.easypub.json").to_str().unwrap()
            )
            .unwrap_err()
            .code,
            ErrorCode::NotFound
        );
        assert_eq!(reopened.source(&id, 1).unwrap().original_bytes(), original);
    }

    #[test]
    fn recovery_rejects_invalid_payload_and_existing_bundle_without_mutation() {
        let dir = std::env::temp_dir().join(format!(
            "recovery-conflict79-{}-{}",
            std::process::id(),
            NEXT_STAGE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&dir).unwrap();
        let service = ImportService::new().unwrap();
        let target = dir.join("restore.easypub.json");
        let bundle = dir.join("restore.easypub.json.sources");
        assert!(save_recovery(&service, target.to_str().unwrap(), "{}").is_err());
        assert!(!target.exists() && !bundle.exists());
        fs::create_dir(&bundle).unwrap();
        let sentinel = bundle.join("retain.txt");
        fs::write(&sentinel, "保留既有目录").unwrap();
        let payload = serde_json::json!({"schema":1,"rule_id":RULE_ID,"books":[],"current_path":"","output":"","format":"EPUB"});
        assert_eq!(
            save_recovery(&service, target.to_str().unwrap(), &payload.to_string())
                .unwrap_err()
                .code,
            ErrorCode::OutputConflict
        );
        assert_eq!(fs::read_to_string(sentinel).unwrap(), "保留既有目录");
        assert!(!target.exists());
        let mut malformed = payload;
        malformed["books"] = serde_json::json!([{"path":"../escape.txt"}]);
        fs::write(&target, malformed.to_string()).unwrap();
        assert!(open(&service, target.to_str().unwrap()).is_err());
    }

    #[test]
    fn malformed_future_and_unknown_fields_are_rejected() {
        assert!(parse("{}").is_err());
        assert!(
            parse(r#"{"schema":2,"books":[],"current_path":"","output":"","format":"EPUB"}"#)
                .is_err()
        );
        assert!(parse(r#"{"schema":1,"books":[],"current_path":"","output":"","format":"EPUB","future":42}"#).is_err());
    }
}
