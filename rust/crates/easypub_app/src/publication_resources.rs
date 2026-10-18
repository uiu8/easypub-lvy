//! Immutable production input: effective text plus ordered, content-addressed images.
use crate::{assets, production::Settings};
use easypub_core::{
    ApiError, ErrorCode,
    publication::{EffectiveBook, IllustrationPosition},
    source::SourceSnapshot,
    structure::Structure,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub source_id: String,
    pub revision: u32,
    pub settings: Settings,
    pub structure: Option<Structure>,
    pub manual: Option<Value>,
    pub cleanup: Option<Value>,
    pub catalog: Option<crate::catalog::CompositionSelection>,
    pub post_edits: Option<crate::edit_checkpoint::EditRequest>,
}
#[derive(Serialize)]
pub struct Resource {
    pub id: String,
    pub media_type: String,
    pub byte_length: usize,
    pub width: u32,
    pub height: u32,
}
#[derive(Serialize)]
pub struct Placement {
    pub list_index: usize,
    pub resource_id: String,
    pub original_line: u32,
    pub output_line: u32,
    pub after_utf8: usize,
    pub caption: String,
    pub alt: String,
    /// 插图版式（V54，RES-050）。
    pub layout: String,
}
#[derive(Serialize)]
pub struct FontResource {
    pub id: String,
    pub media_type: &'static str,
    pub original: crate::fonts::FontReport,
    pub output: crate::fonts::FontReport,
    pub mode: crate::fonts::Mode,
}
#[derive(Serialize)]
pub struct Manifest {
    pub schema: u32,
    pub source_id: String,
    pub revision: u32,
    pub text_sha256: String,
    pub title: String,
    pub author: String,
    pub description: String,
    pub translator: String,
    pub isbn: String,
    pub publication_date: String,
    pub publisher: String,
    pub category: String,
    pub series: String,
    pub series_index: String,
    pub subjects: String,
    pub language: String,

    pub cover: Option<String>,
    pub cover_fit: String,
    pub font_family: String,
    #[serde(default = "crate::production::default_font_size_unit")]
    pub font_size_unit: String,
    #[serde(default)]
    pub fullwidth_indent: u8,
    #[serde(default)]
    pub remove_blank_lines: bool,
    pub font_size: f64,
    pub line_height: f64,
    pub text_alignment: String,
    pub additional_css: String,
    pub additional_css_base: String,
    pub paragraph_indent: f64,
    pub paragraph_spacing: f64,
    pub margin_top: f64,
    pub margin_right: f64,
    pub margin_bottom: f64,
    pub margin_left: f64,
    pub include_toc: bool,
    pub visible_toc: bool,
    pub chapter_navigation: bool,
    /// 竖排（V28）与纵中横位数。
    pub writing_mode: String,
    pub vertical_digits: u8,
    /// 章节标题样式（V36，LAY-117）：精排两行要在标题里分出“第 N 章”。
    pub heading_style: String,
    /// 场景分隔样式（V46，LAY-118）。
    pub scene_break_style: String,
    /// 成对注释（V48，LAY-120）：默认关闭，仅改变成品结构。
    #[serde(skip_serializing_if = "crate::production::note_style_is_off")]
    pub note_style: String,
    /// 章首段落样式（V49，LAY-119）。
    pub first_paragraph_style: String,
    /// 生僻字注音（V73，LAY-129）：关闭时不写入，旧书的成品参数不变。
    #[serde(skip_serializing_if = "crate::production::rare_char_ruby_is_off")]
    pub rare_char_ruby: String,
    #[serde(skip_serializing_if = "crate::production::rare_char_scope_is_default")]
    pub rare_char_scope: String,
    /// 系统提示样式（V50，LAY-121）。
    pub system_block_style: String,
    /// 分类样式参数（V77）：只在 styled 时写入，旧书的成品参数不变。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub system_styles: Option<crate::block_styles::SystemStyles>,
    /// 诗词样式（V50，LAY-122）。
    pub verse_block_style: String,
    #[serde(default)]
    pub rule_options: crate::rule_options::Options,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub block_annotations: Vec<crate::block_annotations::Annotation>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub manual_notes: Vec<crate::manual_notes::Note>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub supplemental_pages: Vec<crate::supplemental_pages::Page>,
    pub navigation: crate::publication_navigation::Navigation,
    pub stylesheet: crate::publication_style::Stylesheet,
    pub stylesheet_order: Vec<String>,
    pub css_dependencies: crate::css_resources::Report,
    pub css_media: Vec<crate::css_media::Audit>,
    pub css_font_permissions: Vec<String>,
    pub font: Option<FontResource>,
    pub resources: Vec<Resource>,
    pub placements: Vec<Placement>,
    /// 统一章首图资源（V54，LAY-124）；未设置时为空。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chapter_head_image_id: Option<String>,
    pub chapter_head_scope: String,
    pub chapter_head_width: String,
    /// 章节样式包（V74，LAY-130）；未使用时为空，旧书的成品参数不变。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chapter_style: Option<crate::style_packs::StyleIds>,
    /// 为 Kindle 转换过的封面与插图（V24，OUT-078）；没有转换时为空。
    pub image_conversions: Vec<crate::kindle_images::Conversion>,
}
pub struct Prepared {
    book: EffectiveBook,
    manifest: Manifest,
    images: BTreeMap<String, Vec<u8>>,
    fonts: BTreeMap<String, Vec<u8>>,
    css_dependencies: BTreeMap<String, Vec<u8>>,
    css_resources: BTreeMap<String, Vec<u8>>,
    id: String,
}
impl Prepared {
    /// Semantic pages and reading order from this exact prepared book snapshot.
    pub fn documents(&self) -> Result<crate::publication_documents::Documents, ApiError> {
        crate::publication_documents::prepare(self)
    }

    /// On-demand XHTML navigation proof; never retained in the normal UI report.
    /// Does not claim full production styling, images or an EPUB container.
    pub fn navigation_documents(&self) -> Result<BTreeMap<String, String>, ApiError> {
        let mut files =
            crate::navigation_documents::prepare(&self.book, &self.manifest.navigation)?;
        for supplement in &self.manifest.supplemental_pages {
            files.insert(
                supplement.filename(),
                crate::navigation_documents::supplement(supplement)?,
            );
        }
        Ok(files)
    }

    pub fn manifest(&self) -> &Manifest {
        &self.manifest
    }
    pub fn book(&self) -> &EffectiveBook {
        &self.book
    }
    pub fn id(&self) -> &str {
        &self.id
    }
    pub fn css_resource_bytes(&self, id: &str) -> Option<&[u8]> {
        self.css_resources.get(id).map(Vec::as_slice)
    }
    pub fn css_dependency_bytes(&self, hash: &str) -> Option<&[u8]> {
        self.css_dependencies.get(hash).map(Vec::as_slice)
    }
    pub fn font_bytes(&self, id: &str) -> Option<&[u8]> {
        self.fonts.get(id).map(Vec::as_slice)
    }
    pub fn image_bytes(&self, id: &str) -> Option<&[u8]> {
        self.images.get(id).map(Vec::as_slice)
    }
}
fn invalid(reason: &'static str) -> ApiError {
    ApiError::new(ErrorCode::InvalidRule, "publication_resources", reason)
}
pub(crate) fn compose(
    source: &SourceSnapshot,
    request: Request,
) -> Result<(EffectiveBook, Settings), ApiError> {
    let summary = source.summary();
    if request.source_id != summary.source_id || request.revision != summary.revision {
        return Err(ApiError::new(
            ErrorCode::StaleRevision,
            "publication_resources",
            "refresh_source",
        ));
    }
    request.settings.validate(summary.line_count)?;
    let structure = request.structure.unwrap_or_else(|| Structure::new(source));
    let manual = request.manual.map(|v| v.to_string());
    let cleanup = request.cleanup.map(|v| v.to_string());
    let book = crate::catalog::compose_selection(
        source,
        &structure,
        request.catalog,
        manual.as_deref(),
        cleanup.as_deref(),
    )?;
    let book = if let Some(edits) = &request.post_edits {
        crate::edit_checkpoint::apply(book, edits)?.0
    } else {
        book
    };
    Ok((book, request.settings))
}
pub fn prepare(source: &SourceSnapshot, request: Request) -> Result<Prepared, ApiError> {
    let summary = source.summary();
    let (book, mut settings) = compose(source, request)?;
    settings
        .block_annotations
        .retain(|a| crate::block_annotations::invalid_reason(a, &book).is_none());
    settings.block_annotations.sort_by_key(|a| a.start);
    settings
        .manual_notes
        .retain(|a| crate::manual_notes::invalid_reason(a, &book).is_none());
    // Reuse the source scanner for CR/LF/CRLF and UTF-8 byte boundaries.
    let output = SourceSnapshot::from_utf8(
        book.text.as_bytes().to_vec(),
        easypub_core::source::RULE_ID,
        || false,
    )?;
    let mut placements = Vec::new();
    for (index, item) in settings.illustrations.iter().enumerate() {
        match book.illustration_position(&summary.source_id, item.source_line)? {
            IllustrationPosition::AfterLine {
                source_line,
                output_line,
            } => {
                let end = output
                    .decoded_line_ranges()
                    .get(output_line as usize)
                    .map(|range| range.0)
                    .unwrap_or(book.text.len());
                placements.push(Placement {
                    list_index: index,
                    resource_id: String::new(),
                    original_line: source_line,
                    output_line,
                    after_utf8: end,
                    caption: item.caption.clone(),
                    alt: item.alt.clone(),
                    layout: item.layout.clone(),
                });
            }
            IllustrationPosition::Unplaced => return Err(invalid("locate_all_illustrations")),
            IllustrationPosition::NeedsRelocation { .. } => {
                return Err(invalid("relocate_illustrations_after_edits"));
            }
        }
    }
    let mut images = BTreeMap::new();
    let mut paths = BTreeMap::new();
    let mut resources = Vec::new();
    let mut total = 0usize;
    let mut image_conversions = Vec::new();
    for path in settings
        .cover_path
        .iter()
        .chain(settings.chapter_head_image.iter())
        .chain(settings.chapter_style.iter().flat_map(|s| {
            // 封面背景只用于文字封面，不放进成品。
            s.head_images
                .iter()
                .chain(s.title_rule.iter())
                .chain(s.chapter_end.iter())
        }))
        .chain(settings.illustrations.iter().map(|i| &i.path))
    {
        if paths.contains_key(path) {
            continue;
        }
        let (snapshot, conversion) =
            crate::kindle_images::kindle_ready(assets::display_snapshot(path)?)?;
        image_conversions.extend(conversion);
        let evidence = snapshot.evidence;
        let id = format!("{}.{}", evidence.sha256, evidence.format);
        paths.insert(path.clone(), id.clone());
        if images.contains_key(&id) {
            continue;
        }
        total = total
            .checked_add(snapshot.bytes.len())
            .ok_or_else(|| invalid("reduce_resource_size"))?;
        if total > 256 * 1024 * 1024 {
            return Err(invalid("reduce_resource_size"));
        }
        let media_type = match evidence.format.as_str() {
            "png" => "image/png",
            "jpg" | "jpeg" => "image/jpeg",
            "webp" => "image/webp",
            _ => return Err(invalid("choose_supported_image")),
        };
        resources.push(Resource {
            id: id.clone(),
            media_type: media_type.into(),
            byte_length: snapshot.bytes.len(),
            width: evidence.width,
            height: evidence.height,
        });
        images.insert(id, snapshot.bytes);
    }
    // Cover derivatives have separate identities; an illustration reusing the same file stays original.
    let mut cover_id = settings.cover_path.as_ref().map(|p| paths[p].clone());
    if let (Some(id), Some(crop)) = (&cover_id, &settings.cover_crop) {
        let resource = resources
            .iter()
            .find(|r| &r.id == id)
            .ok_or_else(|| invalid("missing_cover_resource"))?;
        let original = assets::ImageSnapshot {
            evidence: assets::ImageEvidence {
                path: settings.cover_path.clone().unwrap(),
                sha256: String::new(),
                bytes: resource.byte_length as u64,
                width: resource.width,
                height: resource.height,
                format: String::new(),
            },
            bytes: images[id].clone(),
        };
        // 裁切结果同样要符合 Kindle 的尺寸上限（裁切本身输出 PNG）。
        let (result, conversion) =
            crate::kindle_images::kindle_ready(assets::cropped(&original, crop)?)?;
        image_conversions.extend(conversion);
        let original_id = id.clone();
        let id = format!("{}.png", result.evidence.sha256);
        if id != original_id
            && !settings
                .illustrations
                .iter()
                .any(|i| paths[&i.path] == original_id)
        {
            if let Some(bytes) = images.remove(&original_id) {
                total -= bytes.len();
            }
            resources.retain(|r| r.id != original_id);
        }

        if !images.contains_key(&id) {
            total = total
                .checked_add(result.bytes.len())
                .ok_or_else(|| invalid("reduce_resource_size"))?;
            if total > 256 * 1024 * 1024 {
                return Err(invalid("reduce_resource_size"));
            }
            resources.push(Resource {
                id: id.clone(),
                media_type: "image/png".into(),
                byte_length: result.bytes.len(),
                width: result.evidence.width,
                height: result.evidence.height,
            });
            images.insert(id.clone(), result.bytes);
        }
        cover_id = Some(id);
    }
    for placement in &mut placements {
        placement.resource_id = paths[&settings.illustrations[placement.list_index].path].clone();
    }
    placements.sort_by_key(|p| (p.output_line, p.list_index));
    let chapter_head_image_id = settings
        .chapter_head_image
        .as_ref()
        .map(|p| paths[p].clone());
    let chapter_style = settings
        .chapter_style
        .as_ref()
        .map(|s| crate::style_packs::StyleIds {
            head_ids: s.head_images.iter().map(|p| paths[p].clone()).collect(),
            title_rule_id: s.title_rule.as_ref().map(|p| paths[p].clone()),
            chapter_end_id: s.chapter_end.as_ref().map(|p| paths[p].clone()),
            volume_frame: s.volume_frame.clone(),
        });
    let mut stylesheet = crate::publication_style::separate_additional(
        crate::publication_style::prepare(&settings)?,
    );
    if crate::inline_markup::has_markup(&book.text) {
        stylesheet = crate::publication_style::add_inline_markup(stylesheet);
    }
    let mut fonts = BTreeMap::new();
    let font = if let Some(selection) = &settings.font_resource {
        // Deduplicate before invoking the bounded font API: long novels must not
        // be rejected merely because their repeated body exceeds the sample limit.
        let characters: String = std::iter::once(book.text.as_str())
            .chain([
                settings.title.as_str(),
                settings.author.as_str(),
                settings.description.as_str(),
                settings.translator.as_str(),
                settings.isbn.as_str(),
                settings.publication_date.as_str(),
                settings.publisher.as_str(),
                settings.category.as_str(),
                settings.series.as_str(),
                settings.subjects.as_str(),
                settings.language.as_str(),
            ])
            .chain(
                settings
                    .illustrations
                    .iter()
                    .flat_map(|i| [i.caption.as_str(), i.alt.as_str()]),
            )
            .flat_map(str::chars)
            .filter(|c| !c.is_control())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect();
        let prepared = crate::fonts::prepare_selected(selection, &characters)?;
        let (extension, media_type) = if prepared.bytes.starts_with(b"OTTO") {
            ("otf", "font/otf")
        } else {
            ("ttf", "font/ttf")
        };
        let id = format!("{}.{}", prepared.subset.sha256, extension);
        stylesheet = crate::publication_style::bind_font(stylesheet, &id)?;
        fonts.insert(id.clone(), prepared.bytes);
        Some(FontResource {
            id,
            media_type,
            original: prepared.original,
            output: prepared.subset,
            mode: selection.mode,
        })
    } else {
        None
    };
    let css_snapshot = crate::css_bundle::for_settings(&settings);
    if total + css_snapshot.report.total_bytes > 256 * 1024 * 1024 {
        return Err(invalid("reduce_resource_bytes"));
    }
    let mut css_media = crate::css_media::inspect(&css_snapshot.resources);
    crate::css_media::apply_permissions(&mut css_media, &settings.css_font_permissions);
    let mut stylesheet_order = vec![stylesheet.id.clone()];
    if !settings.additional_css.is_empty()
        && let Some(id) = &css_snapshot.report.root_id
    {
        stylesheet_order.push(id.clone());
    }
    let manifest = Manifest {
        schema: 1,
        source_id: summary.source_id,
        revision: summary.revision,
        text_sha256: format!("{:x}", Sha256::digest(book.text.as_bytes())),
        title: settings.title,
        author: settings.author,
        description: settings.description,
        translator: settings.translator,
        isbn: settings.isbn,
        publication_date: settings.publication_date,
        publisher: settings.publisher,
        category: settings.category,
        series: settings.series,
        series_index: settings.series_index,
        subjects: settings.subjects,
        language: settings.language,

        cover: cover_id,
        cover_fit: settings.cover_fit,
        font_family: settings.font_family,
        font_size_unit: settings.font_size_unit.clone(),
        fullwidth_indent: settings.fullwidth_indent,
        remove_blank_lines: settings.remove_blank_lines,
        font_size: settings.font_size,
        line_height: settings.line_height,
        text_alignment: settings.text_alignment,
        additional_css: settings.additional_css,
        additional_css_base: settings.additional_css_base,
        paragraph_indent: settings.paragraph_indent,
        paragraph_spacing: settings.paragraph_spacing,
        margin_top: settings.margin_top,
        margin_right: settings.margin_right,
        margin_bottom: settings.margin_bottom,
        margin_left: settings.margin_left,
        include_toc: settings.include_toc,
        visible_toc: settings.visible_toc,
        chapter_navigation: settings.chapter_navigation,
        writing_mode: settings.writing_mode.clone(),
        vertical_digits: settings.vertical_digits,
        heading_style: settings.heading_style.clone(),
        scene_break_style: settings.scene_break_style.clone(),
        note_style: settings.note_style.clone(),
        first_paragraph_style: settings.first_paragraph_style.clone(),
        rare_char_ruby: settings.rare_char_ruby.clone(),
        rare_char_scope: settings.rare_char_scope.clone(),
        system_block_style: settings.system_block_style.clone(),
        system_styles: (settings.system_block_style == "styled").then(|| {
            settings
                .system_styles
                .clone()
                .unwrap_or_else(crate::block_styles::default_styles)
        }),
        verse_block_style: settings.verse_block_style.clone(),
        rule_options: settings.rule_options.clone(),
        block_annotations: settings.block_annotations.clone(),
        manual_notes: settings.manual_notes.clone(),
        supplemental_pages: settings.supplemental_pages.clone(),
        navigation: crate::publication_navigation::prepare(
            &book.tree,
            settings.include_toc,
            settings.visible_toc,
            settings.chapter_navigation,
        )
        .with_supplements(&settings.supplemental_pages),
        stylesheet,
        stylesheet_order,
        css_dependencies: css_snapshot.report,
        css_media,
        css_font_permissions: settings.css_font_permissions,
        font,
        resources,
        placements,
        chapter_head_image_id,
        chapter_head_scope: settings.chapter_head_scope.clone(),
        chapter_head_width: settings.chapter_head_width.clone(),
        chapter_style,
        image_conversions,
    };
    let mut hash = Sha256::new();
    hash.update(b"publication-resources-v1");
    hash.update(serde_json::to_vec(&manifest).map_err(|_| invalid("review_resources"))?);
    hash.update(serde_json::to_vec(&book.tree).map_err(|_| invalid("review_structure"))?);
    let id = format!("{:x}", hash.finalize());
    Ok(Prepared {
        book,
        manifest,
        images,
        fonts,
        css_dependencies: css_snapshot.bytes,
        css_resources: css_snapshot.resources,
        id,
    })
}

/// Bounded resource readiness report. Does not retain a prepared export job.
pub fn preview(
    service: &crate::sessions::ImportService,
    request_json: String,
) -> Result<String, ApiError> {
    if request_json.len() > 4 * 1024 * 1024 {
        return Err(invalid("reduce_resource_request"));
    }
    let request: Request =
        serde_json::from_str(&request_json).map_err(|_| invalid("review_resource_request"))?;
    let source = service.source(&request.source_id, request.revision)?;
    let prepared = prepare(&source, request)?;
    let result = serde_json::json!({"plan_id":prepared.id(),"manifest":prepared.manifest(),
        "writes_source":false,"export_job_created":false})
    .to_string();
    if result.len() > 4 * 1024 * 1024 {
        return Err(invalid("reduce_resource_request"));
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn request(source: &SourceSnapshot, path: &str) -> Request {
        serde_json::from_value(json!({"source_id":source.summary().source_id,"revision":1,
          "settings":{"title":"书名","author":"作者","description":"简介","cover_path":path,
          "cover_fit":"contain","font_family":"SimSun","font_size":20.0,"line_height":1.8,
          "include_toc":true,"illustrations":[{"path":path,"caption":"图注","alt":"替代文字","source_line":2}]}})).unwrap()
    }
    /// V54（RES-050、LAY-124）：章首插图挂到所在章标题之前并代替统一章首图；统一章首图按范围插入、只存一份；整页插图前后分页。
    #[test]
    fn chapter_head_images_and_full_page_illustrations() {
        let dir = std::env::temp_dir().join(format!("easypub-v54-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let png = |name: &str, color: [u8; 3]| {
            let path = dir.join(name);
            image::DynamicImage::ImageRgb8(image::ImageBuffer::from_pixel(
                30,
                10,
                image::Rgb(color),
            ))
            .save(&path)
            .unwrap();
            path.to_string_lossy().into_owned()
        };
        let (ornament, own, page) = (
            png("o.png", [10, 10, 10]),
            png("a.png", [200, 0, 0]),
            png("p.png", [0, 0, 200]),
        );
        let text = "第一卷 上\n第一章 甲\n正文一\n正文二\n第二章 乙\n正文三\n";
        let source = SourceSnapshot::from_utf8(
            text.as_bytes().to_vec(),
            easypub_core::source::RULE_ID,
            || false,
        )
        .unwrap();
        let build = |scope: &str| {
            let request: Request = serde_json::from_value(json!({"source_id":source.summary().source_id,"revision":1,
              "settings":{"title":"书名","author":"作者","description":"","cover_fit":"contain","font_family":"SimSun",
              "font_size":20.0,"line_height":1.8,"include_toc":true,
              "chapter_head_image":ornament,"chapter_head_scope":scope,"chapter_head_width":"third",
              "illustrations":[
                {"path":own,"caption":"","alt":"本章图","source_line":3,"layout":"chapter_head"},
                {"path":page,"caption":"整页图注","alt":"整页","source_line":6,"layout":"full_page"}]}}))
            .unwrap();
            let prepared = prepare(&source, request).unwrap();
            let ornament_id = prepared.manifest().chapter_head_image_id.clone().unwrap();
            let own_id = prepared.manifest().placements[0].resource_id.clone();
            let body = prepared.documents().unwrap().pages["body.xhtml"].clone();
            (
                prepared.manifest().resources.len(),
                ornament_id,
                own_id,
                body,
            )
        };
        let (resources, ornament_id, own_id, body) = build("chapter");
        assert_eq!(resources, 3, "统一章首图只存一份");
        let first = body.find("第一章 甲").unwrap();
        let second = body.find("第二章 乙").unwrap();
        let volume = body.find("第一卷 上").unwrap();
        // 第一章：自己的章首图在标题之前，不再随正文，也不叠加统一章首图。
        let own_at = body.find(&format!("src=\"{own_id}\"")).unwrap();
        assert!(volume < own_at && own_at < first);
        assert_eq!(body.matches(&format!("src=\"{own_id}\"")).count(), 1);
        assert_eq!(
            body[volume..first]
                .matches(&format!("src=\"{ornament_id}\""))
                .count(),
            0
        );
        // 第二章：统一章首图，三分之一宽，在标题之前。
        let ornament_at = body.find(&format!("src=\"{ornament_id}\"")).unwrap();
        assert!(first < ornament_at && ornament_at < second);
        assert!(
            body[..ornament_at]
                .ends_with("<figure class=\"chapter-head-image chapter-head-third\"><img ")
        );
        assert_eq!(
            body.matches(&format!("src=\"{ornament_id}\"")).count(),
            1,
            "卷标题不加"
        );
        // 整页插图。
        assert!(body.contains("<figure class=\"full-page-image\"><img "));
        assert!(body.contains("<figcaption>整页图注</figcaption>"));
        // 卷和章：卷标题也加统一章首图。
        let (_, ornament_id, _, body) = build("both");
        assert_eq!(body.matches(&format!("src=\"{ornament_id}\"")).count(), 2);
        let _ = std::fs::remove_dir_all(&dir);
    }
    /// V24（OUT-078）：WebP 封面兼插图转成 JPEG 进入制作计划，只转一次并写进清单；原文件不变。
    #[test]
    fn webp_cover_is_converted_once_and_recorded() {
        let path = std::env::temp_dir().join(format!("easypub-v24-{}.webp", std::process::id()));
        image::DynamicImage::ImageRgb8(image::ImageBuffer::from_pixel(
            30,
            40,
            image::Rgb([200, 120, 40]),
        ))
        .save(&path)
        .unwrap();
        let original = std::fs::read(&path).unwrap();
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n正文".as_bytes().to_vec(),
            easypub_core::source::RULE_ID,
            || false,
        )
        .unwrap();
        let prepared = prepare(&source, request(&source, path.to_str().unwrap())).unwrap();
        let manifest = prepared.manifest();
        assert_eq!(manifest.resources.len(), 1);
        let resource = &manifest.resources[0];
        assert!(resource.id.ends_with(".jpg"), "{}", resource.id);
        assert_eq!(resource.media_type, "image/jpeg");
        assert_eq!(manifest.cover.as_ref(), Some(&resource.id));
        assert_eq!(manifest.placements[0].resource_id, resource.id);
        assert_eq!(manifest.image_conversions.len(), 1);
        let c = &manifest.image_conversions[0];
        assert_eq!(
            (c.from_format.as_str(), c.to_format.as_str()),
            ("webp", "jpg")
        );
        assert_eq!(c.reasons, vec!["format"]);
        assert_eq!(
            image::guess_format(prepared.image_bytes(&resource.id).unwrap()).unwrap(),
            image::ImageFormat::Jpeg
        );
        assert_eq!(std::fs::read(&path).unwrap(), original);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn crop_pixels_and_shared_illustration_remain_independent() {
        let path = std::env::temp_dir().join(format!("easypub-crop-{}.png", std::process::id()));
        let pixels =
            image::ImageBuffer::from_fn(4, 4, |x, y| image::Rgba([x as u8, y as u8, 9, 255]));
        pixels.save(&path).unwrap();
        let original = std::fs::read(&path).unwrap();
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n正文".as_bytes().to_vec(),
            easypub_core::source::RULE_ID,
            || false,
        )
        .unwrap();
        let mut r = request(&source, path.to_str().unwrap());
        r.settings.cover_crop = Some(assets::Crop {
            x: 0.25,
            y: 0.5,
            width: 0.5,
            height: 0.5,
        });
        let prepared = prepare(&source, r).unwrap();
        let manifest = prepared.manifest();
        assert_eq!(manifest.resources.len(), 2);
        let cover = manifest.cover.as_ref().unwrap();
        let illustration = &manifest.placements[0].resource_id;
        assert_ne!(cover, illustration);
        assert_eq!(prepared.image_bytes(illustration).unwrap(), original);
        let actual = image::load_from_memory(prepared.image_bytes(cover).unwrap())
            .unwrap()
            .to_rgba8();
        assert_eq!(actual.dimensions(), (2, 2));
        assert_eq!(actual.get_pixel(0, 0), pixels.get_pixel(1, 2));
        assert_eq!(actual.get_pixel(1, 1), pixels.get_pixel(2, 3));
        let mut r = request(&source, path.to_str().unwrap());
        r.settings.illustrations.clear();
        r.settings.cover_crop = Some(assets::Crop {
            x: 0.25,
            y: 0.5,
            width: 0.5,
            height: 0.5,
        });
        assert_eq!(prepare(&source, r).unwrap().manifest.resources.len(), 1);
        for crop in [
            assets::Crop {
                x: -0.1,
                y: 0.0,
                width: 1.0,
                height: 1.0,
            },
            assets::Crop {
                x: 0.5,
                y: 0.0,
                width: 0.6,
                height: 1.0,
            },
            assets::Crop {
                x: 0.0,
                y: 0.0,
                width: 0.0,
                height: 1.0,
            },
            assets::Crop {
                x: f64::NAN,
                y: 0.0,
                width: 1.0,
                height: 1.0,
            },
        ] {
            assert!(crop.validate().is_err());
        }
        assert_eq!(std::fs::read(&path).unwrap(), original);
        std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn immutable_bytes_deduplicate_and_positions_use_unicode_mixed_newlines() {
        let dir = std::env::temp_dir().join(format!("easypub-resources-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("甲.png");
        let q = dir.join("乙.png");
        image::ImageBuffer::from_pixel(2, 2, image::Rgb([1u8, 2, 3]))
            .save(&p)
            .unwrap();
        std::fs::copy(&p, &q).unwrap();
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\r\n正文😀\r第二章 乙\n这一段属于乙章的正文"
                .as_bytes()
                .to_vec(),
            easypub_core::source::RULE_ID,
            || false,
        )
        .unwrap();
        let mut r = request(&source, p.to_str().unwrap());
        let mut second = r.settings.illustrations[0].clone();
        second.path = q.to_string_lossy().into();
        second.caption = "第二图".into();
        r.settings.illustrations.push(second);
        let prepared = prepare(&source, r).unwrap();
        assert_eq!(prepared.manifest.resources.len(), 1);
        assert_eq!(
            prepared
                .manifest
                .placements
                .iter()
                .map(|p| p.list_index)
                .collect::<Vec<_>>(),
            [0, 1]
        );
        assert_eq!(
            &prepared.book.text[..prepared.manifest.placements[0].after_utf8],
            "第一章 甲\r\n正文😀\r"
        );
        let mut moved = request(&source, p.to_str().unwrap());
        moved.manual = Some(
            json!({"kind":"manual_batch","actions":[{"kind":"move_chapter","source_line":3,"before_line":1}]}),
        );
        let moved = prepare(&source, moved).unwrap();
        assert_eq!(
            moved.manifest.placements[0].output_line, 4,
            "text={:?} map={:?}",
            moved.book.text, moved.book.source_to_output_lines
        );
        assert_eq!(
            moved.manifest.placements[0].after_utf8,
            moved.book.text.len()
        );
        assert_ne!(moved.id(), prepared.id());
        let mut reordered = request(&source, p.to_str().unwrap());
        let mut second = reordered.settings.illustrations[0].clone();
        second.path = q.to_string_lossy().into();
        second.caption = "第二图".into();
        reordered.settings.illustrations.insert(0, second);
        let reordered = prepare(&source, reordered).unwrap();
        assert_eq!(reordered.manifest.placements[0].caption, "第二图");
        assert_ne!(reordered.id(), prepared.id());
        let id = prepared.manifest.cover.as_ref().unwrap();
        let original = std::fs::read(&p).unwrap();
        std::fs::write(&p, b"externally replaced").unwrap();
        assert_eq!(prepared.image_bytes(id).unwrap(), original);
        assert!(prepare(&source, request(&source, p.to_str().unwrap())).is_err());
        std::fs::remove_file(&p).unwrap();
        std::fs::remove_file(&q).unwrap();
        std::fs::remove_dir(dir).unwrap();
    }
    #[test]
    fn missing_or_ambiguous_position_blocks_preparation_before_resource_reads() {
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n正文\n尾声".as_bytes().to_vec(),
            easypub_core::source::RULE_ID,
            || false,
        )
        .unwrap();
        let path = std::env::temp_dir().join("unused-image.png");
        let mut r = request(&source, path.to_str().unwrap());
        r.settings.illustrations[0].source_line = None;
        assert_eq!(
            prepare(&source, r).err().unwrap().next_action,
            "locate_all_illustrations"
        );
        let mut r = request(&source, path.to_str().unwrap());
        r.manual = Some(
            json!({"kind":"manual_batch","actions":[{"kind":"exclude_lines","source_line":2,"end_line":2}]}),
        );
        assert_eq!(
            prepare(&source, r).err().unwrap().next_action,
            "relocate_illustrations_after_edits"
        );
    }
}
