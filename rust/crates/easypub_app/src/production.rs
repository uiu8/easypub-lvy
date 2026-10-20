//! Source-bound production settings, explicit field edits and reversible batch plans.
use crate::{
    project::Illustration,
    sessions::{ImportService, MAX_BATCH_TARGETS},
};
use easypub_core::{ApiError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::Path,
};

pub fn default_font_size_unit() -> String {
    "px".into()
}
pub fn valid_font_size(value: f64, unit: &str) -> bool {
    match unit {
        "%" => (50.0..=200.0).contains(&value),
        "px" => (14.0..=26.0).contains(&value),
        _ => false,
    }
}
pub fn default_margin_unit() -> String {
    "em".into()
}
fn valid_margin(value: f64, unit: &str) -> bool {
    match unit {
        "em" => (0.0..=6.0).contains(&value),
        "px" => (0.0..=1000.0).contains(&value),
        _ => false,
    }
}
pub fn default_text_alignment() -> String {
    "start".into()
}
pub fn default_writing_mode() -> String {
    "horizontal".into()
}
pub fn default_vertical_digits() -> u8 {
    2
}
/// 章节标题样式（V36，LAY-117）的可选值，与 publication_style::heading_rules 一一对应。
pub const HEADING_STYLES: [&str; 5] = ["classic", "amazon", "publisher", "two_line", "light_novel"];
pub fn default_heading_style() -> String {
    "classic".into()
}
/// 场景分隔样式（V46，LAY-118）：off 不识别；keep 居中保留原符号；stars ＊　＊　＊；diamonds ◇　◇　◇；line 细线。
pub const SCENE_BREAK_STYLES: [&str; 5] = ["off", "keep", "stars", "diamonds", "line"];
pub fn default_scene_break_style() -> String {
    "keep".into()
}
pub const NOTE_STYLES: [&str; 2] = ["off", "popup"];
pub fn default_note_style() -> String {
    "off".into()
}
pub fn note_style_is_off(style: &str) -> bool {
    style == "off"
}
/// 章首段落样式（V49，LAY-119）：normal 同正文；no_indent 首段不缩进；large_initial 首段不缩进且首字放大。
pub const FIRST_PARAGRAPH_STYLES: [&str; 3] = ["normal", "no_indent", "large_initial"];
pub fn default_first_paragraph_style() -> String {
    "normal".into()
}
/// 生僻字注音（V73，LAY-129）：off 不标；chapter 每章首次；book 全书首次；every 每次。
/// 旧项目缺少字段时为 off（输出不变）；新书出厂默认 chapter，见 layout_settings::factory。
pub const RARE_CHAR_RUBY_MODES: [&str; 4] = ["off", "chapter", "book", "every"];
pub fn default_rare_char_ruby() -> String {
    "off".into()
}
pub fn rare_char_ruby_is_off(mode: &str) -> bool {
    mode == "off"
}
/// 生僻字范围：outside 只有表外字；level3 三级字和表外字。
pub const RARE_CHAR_SCOPES: [&str; 2] = ["outside", "level3"];
pub fn default_rare_char_scope() -> String {
    "outside".into()
}
pub fn rare_char_scope_is_default(scope: &str) -> bool {
    scope == "outside"
}
/// 系统提示（V50，LAY-121）：off 不识别；box 加框；indent 缩进；
/// styled 按单行提示 / 多行面板分别套样式（V77，LAY-132，见 [crate::block_styles]）。
pub const SYSTEM_BLOCK_STYLES: [&str; 4] = ["off", "box", "indent", "styled"];
pub fn default_system_block_style() -> String {
    "box".into()
}
/// 场景样式（V81，LAY-135）：旧项目缺少字段时聊天记录不识别、书信原样（输出不变）；
/// 新书出厂默认 window / ruled，见 layout_settings::factory。
pub fn default_chat_block_style() -> String {
    "off".into()
}
pub fn chat_block_style_is_off(v: &str) -> bool {
    v == "off"
}
pub fn default_letter_block_style() -> String {
    "plain".into()
}
pub fn letter_block_style_is_plain(v: &str) -> bool {
    v == "plain"
}
pub fn default_inset_detect() -> String {
    "off".into()
}
pub fn inset_detect_is_off(v: &str) -> bool {
    v == "off"
}
pub fn default_inset_font() -> String {
    "kai".into()
}
pub fn inset_font_is_kai(v: &str) -> bool {
    v == "kai"
}
/// 诗词（V50，LAY-122）：off 不识别；center 居中；indent 缩进。
pub const VERSE_BLOCK_STYLES: [&str; 3] = ["off", "center", "indent"];
/// 插图版式（V54，RES-050）。
pub const ILLUSTRATION_LAYOUTS: [&str; 3] = ["inline", "full_page", "chapter_head"];
pub fn default_illustration_layout() -> String {
    "inline".into()
}
pub fn illustration_layout_is_inline(value: &str) -> bool {
    value == "inline"
}
/// 统一章首图用于哪些标题（V54，LAY-124）：chapter 每章；volume 每卷；both 卷和章。
pub const CHAPTER_HEAD_SCOPES: [&str; 3] = ["chapter", "volume", "both"];
pub fn default_chapter_head_scope() -> String {
    "chapter".into()
}
/// 章首图宽度（V54，LAY-124）：third 三分之一；half 一半；full 满宽。
pub const CHAPTER_HEAD_WIDTHS: [&str; 3] = ["third", "half", "full"];
pub fn default_chapter_head_width() -> String {
    "half".into()
}
pub fn default_verse_block_style() -> String {
    "center".into()
}
pub fn default_paragraph_indent() -> f64 {
    2.0
}
pub fn default_paragraph_spacing() -> f64 {
    0.5
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CoverDesign {
    pub title: String,
    pub author: String,
    pub series: String,
    pub color: u32,
    pub style: String,
    pub image_sha256: String,
}
impl CoverDesign {
    fn validate(&self) -> Result<(), ApiError> {
        if self.title.trim().is_empty()
            || !matches!(
                self.style.as_str(),
                "river-classic-v1" | "pack-background-v1"
            )
            || ![0xff23664f, 0xff82705a, 0xff5e6d7d, 0xff694c52].contains(&self.color)
            || [&self.title, &self.author, &self.series]
                .iter()
                .any(|v| v.chars().count() > 512 || v.contains('\0'))
            || self.image_sha256.len() != 64
            || !self.image_sha256.bytes().all(|b| b.is_ascii_hexdigit())
        {
            return Err(invalid());
        }
        Ok(())
    }
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Settings {
    /// Empty on legacy projects: never infer old editing intent from a value.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub metadata_origins: BTreeMap<String, MetadataOrigin>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub layout_origins: crate::layout_settings::Origins,
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

    pub cover_path: Option<String>,
    /// 统一章首图（V54，LAY-124）。与 cover_path 一样总是序列化：patch 按键修改，缺键会被拒绝。
    #[serde(default)]
    pub chapter_head_image: Option<String>,
    #[serde(default = "crate::production::default_chapter_head_scope")]
    pub chapter_head_scope: String,
    #[serde(default = "crate::production::default_chapter_head_width")]
    pub chapter_head_width: String,
    /// 章节样式包（V74，LAY-130）。与章首图一样总是序列化。
    #[serde(default)]
    pub chapter_style: Option<crate::style_packs::ChapterStyle>,
    pub cover_fit: String,
    #[serde(default)]
    pub cover_crop: Option<crate::assets::Crop>,
    #[serde(default)]
    pub cover_design: Option<CoverDesign>,
    pub font_family: String,
    #[serde(default)]
    pub font_resource: Option<crate::fonts::Selection>,
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
    /// 章节标题样式（V36，LAY-117）：classic、amazon、publisher、two_line、light_novel。
    #[serde(default = "crate::production::default_heading_style")]
    pub heading_style: String,
    /// 场景分隔样式（V46，LAY-118），见 [SCENE_BREAK_STYLES]。
    #[serde(default = "crate::production::default_scene_break_style")]
    pub scene_break_style: String,
    #[serde(default = "crate::production::default_note_style")]
    pub note_style: String,
    /// 章首段落样式（V49，LAY-119），见 [FIRST_PARAGRAPH_STYLES]。
    #[serde(default = "crate::production::default_first_paragraph_style")]
    pub first_paragraph_style: String,
    /// 生僻字注音（V73，LAY-129），见 [RARE_CHAR_RUBY_MODES]。
    #[serde(default = "crate::production::default_rare_char_ruby")]
    pub rare_char_ruby: String,
    /// 生僻字范围（V73，LAY-129），见 [RARE_CHAR_SCOPES]。
    #[serde(default = "crate::production::default_rare_char_scope")]
    pub rare_char_scope: String,
    /// 系统提示样式（V50，LAY-121），见 [SYSTEM_BLOCK_STYLES]。
    #[serde(default = "crate::production::default_system_block_style")]
    pub system_block_style: String,
    /// 分类样式的参数（V77，LAY-132）；为空时用内置默认。总是序列化。
    #[serde(default)]
    pub system_styles: Option<crate::block_styles::SystemStyles>,
    /// 诗词样式（V50，LAY-122），见 [VERSE_BLOCK_STYLES]。
    #[serde(default = "crate::production::default_verse_block_style")]
    pub verse_block_style: String,
    /// 场景样式（V81，LAY-135）：聊天记录自动识别与样式、书信样式、场景字体，见 [crate::insets]。
    #[serde(default = "crate::production::default_chat_block_style")]
    pub chat_block_style: String,
    #[serde(default = "crate::production::default_letter_block_style")]
    pub letter_block_style: String,
    #[serde(default = "crate::production::default_inset_font")]
    pub inset_font: String,
    /// 场景识别（V82，LAY-137），见 [crate::insets::INSET_DETECT]。
    #[serde(default = "crate::production::default_inset_detect")]
    pub inset_detect: String,
    /// 本书改过的场景样式（V82，LAY-136）：按场景编号；没改的用内置预设。总是序列化（补丁只能改已有字段）。
    #[serde(default)]
    pub inset_styles: Option<std::collections::BTreeMap<String, crate::inset_styles::InsetStyle>>,
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
    #[serde(default)]
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
    pub illustrations: Vec<Illustration>,
}
impl From<&crate::project::ProjectBook> for Settings {
    fn from(book: &crate::project::ProjectBook) -> Self {
        Self {
            metadata_origins: book.metadata_origins.clone(),
            layout_origins: book.layout_origins.clone(),
            title: book.title.clone(),
            author: book.author.clone(),
            description: book.description.clone(),
            translator: book.translator.clone(),
            isbn: book.isbn.clone(),
            publication_date: book.publication_date.clone(),
            publisher: book.publisher.clone(),
            category: book.category.clone(),
            series: book.series.clone(),
            series_index: book.series_index.clone(),
            subjects: book.subjects.clone(),
            language: book.language.clone(),

            cover_path: book.cover_path.clone(),
            chapter_head_image: book.chapter_head_image.clone(),
            chapter_head_scope: book.chapter_head_scope.clone(),
            chapter_head_width: book.chapter_head_width.clone(),
            chapter_style: book.chapter_style.clone(),
            cover_fit: book.cover_fit.clone(),
            cover_crop: book.cover_crop.clone(),
            cover_design: book.cover_design.clone(),
            font_family: book.font_family.clone(),
            font_resource: book.font_resource.clone(),
            font_size_unit: book.font_size_unit.clone(),
            fullwidth_indent: book.fullwidth_indent,
            remove_blank_lines: book.remove_blank_lines,
            font_size: book.font_size,
            line_height: book.line_height,
            text_alignment: book.text_alignment.clone(),
            additional_css: book.additional_css.clone(),
            additional_css_base: book.additional_css_base.clone(),
            additional_css_bundle: book.additional_css_bundle.clone(),
            css_font_permissions: book.css_font_permissions.clone(),
            paragraph_indent: book.paragraph_indent,
            paragraph_spacing: book.paragraph_spacing,
            margin_top: book.margin_top,
            margin_top_unit: book.margin_top_unit.clone(),
            margin_right: book.margin_right,
            margin_right_unit: book.margin_right_unit.clone(),
            margin_bottom: book.margin_bottom,
            margin_bottom_unit: book.margin_bottom_unit.clone(),
            margin_left: book.margin_left,
            margin_left_unit: book.margin_left_unit.clone(),
            include_toc: book.include_toc,
            visible_toc: book.visible_toc,
            chapter_navigation: book.chapter_navigation,
            writing_mode: book.writing_mode.clone(),
            vertical_digits: book.vertical_digits,
            heading_style: book.heading_style.clone(),
            scene_break_style: book.scene_break_style.clone(),
            note_style: book.note_style.clone(),
            first_paragraph_style: book.first_paragraph_style.clone(),
            rare_char_ruby: book.rare_char_ruby.clone(),
            rare_char_scope: book.rare_char_scope.clone(),
            system_block_style: book.system_block_style.clone(),
            system_styles: book.system_styles.clone(),
            verse_block_style: book.verse_block_style.clone(),
            chat_block_style: book.chat_block_style.clone(),
            letter_block_style: book.letter_block_style.clone(),
            inset_font: book.inset_font.clone(),
            inset_detect: book.inset_detect.clone(),
            inset_styles: book.inset_styles.clone(),
            rule_options: book.rule_options.clone(),
            block_annotations: book.block_annotations.clone(),
            manual_notes: book.manual_notes.clone(),
            supplemental_pages: book.supplemental_pages.clone(),
            illustrations: book.illustrations.clone(),
        }
    }
}
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "production_settings",
        "review_production_fields",
    )
}
fn stale() -> ApiError {
    ApiError::new(
        ErrorCode::StaleRevision,
        "production_settings",
        "preview_current_targets_again",
    )
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MetadataOrigin {
    pub source: MetadataSource,
    pub value: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub baseline: Option<MetadataBaseline>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rule_folder: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rule_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rule_version: Option<String>,
    #[serde(default, skip_serializing_if = "metadata_default_priority")]
    pub rule_priority: u8,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MetadataBaseline {
    pub source: Option<MetadataSource>,
    pub value: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layout_origin: Option<crate::layout_settings::Origin>,
}
fn metadata_default_priority(value: &u8) -> bool {
    *value == 0
}
fn metadata_baseline(current: &Settings, key: &str, value: Value) -> MetadataBaseline {
    current
        .metadata_origins
        .get(key)
        .and_then(|o| o.baseline.clone())
        .unwrap_or_else(|| MetadataBaseline {
            source: current.metadata_origins.get(key).map(|o| o.source.clone()),
            value,
            layout_origin: current.layout_origins.get(key).cloned(),
        })
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MetadataSource {
    Manual,
    FolderRule,
    Imported,
    Conversion,
    Unknown,
}
const METADATA_FIELDS: [&str; 16] = [
    "title",
    "author",
    "description",
    "translator",
    "isbn",
    "publication_date",
    "publisher",
    "category",
    "series",
    "series_index",
    "subjects",
    "language",
    "cover_path",
    "cover_fit",
    "cover_crop",
    "cover_design",
];
fn metadata_field(key: &str) -> bool {
    METADATA_FIELDS.contains(&key)
}
impl Settings {
    /// Missing provenance in an old project is unknown, including empty values.
    /// Preserve values and do not invent a baseline, author or rule identity.
    pub fn mark_unknown_metadata(&mut self) -> Result<(), ApiError> {
        let values = serde_json::to_value(&self).map_err(|_| invalid())?;
        for key in METADATA_FIELDS {
            self.metadata_origins
                .entry(key.to_owned())
                .or_insert_with(|| MetadataOrigin {
                    source: MetadataSource::Unknown,
                    value: values[key].clone(),
                    baseline: None,
                    rule_folder: None,
                    rule_id: None,
                    rule_version: None,
                    rule_priority: 0,
                });
        }
        Ok(())
    }
    pub fn validate(&self, lines: u32) -> Result<(), ApiError> {
        self.rule_options.validate()?;
        crate::block_annotations::validate(&self.block_annotations)?;
        crate::manual_notes::validate(&self.manual_notes)?;
        crate::supplemental_pages::validate(&self.supplemental_pages)?;
        let values = serde_json::to_value(self).map_err(|_| invalid())?;
        if self.metadata_origins.len() > 16
            || self
                .metadata_origins
                .iter()
                .any(|(key, origin)| !metadata_field(key) || values.get(key) != Some(&origin.value))
        {
            return Err(invalid());
        }
        crate::layout_settings::validate_origins(
            &self.layout_origins,
            &serde_json::to_value(self).map_err(|_| invalid())?,
        )?;
        if self.css_font_permissions.len() > 128
            || self
                .css_font_permissions
                .iter()
                .collect::<BTreeSet<_>>()
                .len()
                != self.css_font_permissions.len()
            || self.css_font_permissions.iter().any(|s| {
                s.len() != 64
                    || !s
                        .bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            })
        {
            return Err(invalid());
        }
        if let Some(bundle) = &self.additional_css_bundle {
            bundle.validate()?;
        }
        if let Some(design) = &self.cover_design {
            design.validate()?;
            if self.cover_path.is_none() {
                return Err(invalid());
            }
        }
        if let Some(crop) = &self.cover_crop {
            crop.validate()?;
        }
        if !self.series_index.is_empty()
            && (self.series.trim().is_empty()
                || self.series_index.split('.').any(|part| {
                    part.is_empty()
                        || !part.bytes().all(|b| b.is_ascii_digit())
                        || part.parse::<u32>().is_err()
                }))
        {
            return Err(invalid());
        }
        if [
            &self.translator,
            &self.isbn,
            &self.publication_date,
            &self.publisher,
            &self.category,
            &self.series,
            &self.series_index,
            &self.subjects,
            &self.language,
        ]
        .iter()
        .any(|v| v.len() > 4096 || v.contains('\0'))
            || self.title.len() > 4096
            || self.author.len() > 4096
            || self.additional_css_base.len() > 32768
            || self.additional_css_base.contains('\0')
            || (!self.additional_css_base.is_empty()
                && !Path::new(&self.additional_css_base).is_absolute())
            || self.additional_css.len() > 262144
            || self.additional_css.contains('\0')
            || self.description.len() > 65536
            || !valid_font_size(self.font_size, &self.font_size_unit)
            || self.fullwidth_indent > 8
            || !(1.0..=2.3).contains(&self.line_height)
            || !matches!(
                self.text_alignment.as_str(),
                "start" | "left" | "right" | "center" | "justify"
            )
            || !matches!(self.writing_mode.as_str(), "horizontal" | "vertical")
            || self.vertical_digits > 4
            || !HEADING_STYLES.contains(&self.heading_style.as_str())
            || !SCENE_BREAK_STYLES.contains(&self.scene_break_style.as_str())
            || !NOTE_STYLES.contains(&self.note_style.as_str())
            || !FIRST_PARAGRAPH_STYLES.contains(&self.first_paragraph_style.as_str())
            || !RARE_CHAR_RUBY_MODES.contains(&self.rare_char_ruby.as_str())
            || !RARE_CHAR_SCOPES.contains(&self.rare_char_scope.as_str())
            || !SYSTEM_BLOCK_STYLES.contains(&self.system_block_style.as_str())
            || !VERSE_BLOCK_STYLES.contains(&self.verse_block_style.as_str())
            || !crate::insets::CHAT_BLOCK_STYLES.contains(&self.chat_block_style.as_str())
            || !crate::insets::LETTER_BLOCK_STYLES.contains(&self.letter_block_style.as_str())
            || !crate::insets::INSET_FONTS.contains(&self.inset_font.as_str())
            || !crate::insets::INSET_DETECT.contains(&self.inset_detect.as_str())
            || !matches!(self.cover_fit.as_str(), "cover" | "contain" | "fill")
            || !matches!(
                self.font_family.as_str(),
                "Microsoft YaHei" | "SimSun" | "Segoe UI"
            )
            || !(0.0..=6.0).contains(&self.paragraph_indent)
            || !(0.0..=6.0).contains(&self.paragraph_spacing)
            || !valid_margin(self.margin_top, &self.margin_top_unit)
            || !valid_margin(self.margin_right, &self.margin_right_unit)
            || !valid_margin(self.margin_bottom, &self.margin_bottom_unit)
            || !valid_margin(self.margin_left, &self.margin_left_unit)
            || self.illustrations.len() > 512
            || !CHAPTER_HEAD_SCOPES.contains(&self.chapter_head_scope.as_str())
            || !CHAPTER_HEAD_WIDTHS.contains(&self.chapter_head_width.as_str())
            || self
                .illustrations
                .iter()
                .any(|i| !ILLUSTRATION_LAYOUTS.contains(&i.layout.as_str()))
        {
            return Err(invalid());
        }
        if let Some(font) = &self.font_resource {
            font.validate()?;
        }
        if let Some(path) = &self.cover_path {
            image_path(path)?;
        }
        if let Some(path) = &self.chapter_head_image {
            image_path(path)?;
        }
        if let Some(style) = &self.chapter_style {
            style.validate(image_path)?;
        }
        if let Some(styles) = &self.system_styles {
            styles.validate()?;
        }
        if let Some(styles) = &self.inset_styles {
            crate::inset_styles::validate_book(styles)?;
        }
        let mut paths = BTreeSet::new();
        for image in &self.illustrations {
            image_path(&image.path)?;
            if !paths.insert(image.path.to_lowercase())
                || image.caption.len() > 4096
                || image.alt.len() > 4096
                || image.caption.contains(['\r', '\n'])
                || image.alt.contains(['\r', '\n'])
                || image
                    .source_line
                    .is_some_and(|line| line == 0 || line > lines)
            {
                return Err(invalid());
            }
        }
        Ok(())
    }
    pub fn assets(&self) -> Result<Vec<crate::assets::ImageEvidence>, ApiError> {
        if let Some(font) = &self.font_resource {
            font.inspect_confirmed()?;
        }
        let mut bytes = 0u64;
        let mut assets = Vec::new();
        let mut seen = BTreeSet::new();
        for path in self
            .cover_path
            .iter()
            .chain(self.chapter_head_image.iter())
            .chain(self.chapter_style.iter().flat_map(|s| s.paths()))
            .map(String::as_str)
            .chain(self.illustrations.iter().map(|image| image.path.as_str()))
        {
            if !seen.insert(path.to_lowercase()) {
                continue;
            }
            let evidence = crate::assets::inspect(path)?;
            if self.cover_path.as_deref() == Some(path)
                && self
                    .cover_design
                    .as_ref()
                    .is_some_and(|design| design.image_sha256 != evidence.sha256)
            {
                return Err(invalid());
            }
            bytes += evidence.bytes;
            if bytes > 256 * 1024 * 1024 {
                return Err(invalid());
            }
            assets.push(evidence);
        }
        Ok(assets)
    }
}
fn image_path(value: &str) -> Result<(), ApiError> {
    let path = Path::new(value);
    if value.len() > 32768
        || !path.is_absolute()
        || !matches!(
            path.extension()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_ascii_lowercase()
                .as_str(),
            "png" | "jpg" | "jpeg" | "webp" | "gif" | "bmp"
        )
    {
        return Err(invalid());
    }
    Ok(())
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct History {
    pub source_id: String,
    pub revision: u32,
    pub states: Vec<Settings>,
    pub cursor: usize,
}
impl History {
    pub fn validate(&self, lines: u32) -> Result<(), ApiError> {
        if self.source_id.len() != 64
            || !self
                .source_id
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            || self.revision == 0
            || self.states.is_empty()
            || self.states.len() > 51
            || self.cursor >= self.states.len()
            // 51 snapshots of 20 pages × 20,000 Unicode characters fit this bound.
            || serde_json::to_vec(self).map_err(|_| invalid())?.len() > 96 * 1024 * 1024
        {
            return Err(invalid());
        }
        for state in &self.states {
            state.validate(lines)?;
        }
        Ok(())
    }
    pub fn current(&self) -> &Settings {
        &self.states[self.cursor]
    }
    fn push(&mut self, next: Settings) {
        if self.current() == &next {
            return;
        }
        self.states.truncate(self.cursor + 1);
        self.states.push(next);
        if self.states.len() > 51 {
            self.states.remove(0);
        }
        self.cursor = self.states.len() - 1;
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Edit {
    Keep {},
    Set { value: Value },
    FillEmpty { value: Value },
    Clear {},
}
#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Change {
    RestoreLayout {
        #[serde(default)]
        source: RestoreSource,
        defaults: BTreeMap<String, Value>,
        fields: Vec<String>,
    },
    ApplyLayoutLayers {
        layers: crate::layout_settings::Layers,
    },
    ApplyLayoutPreset {
        preset: crate::layout_presets::Preset,
    },
    FolderMapping {
        source_path: String,
        rules: Vec<crate::folder_mapping::Rule>,
        #[serde(default)]
        override_fields: BTreeSet<String>,
        #[serde(default)]
        restore_fields: BTreeSet<String>,
    },
    MoveIllustration {
        from_index: usize,
        to_index: usize,
    },
    Inspect {},
    Patch {
        fields: BTreeMap<String, Edit>,
    },
    /// Explicit field adoption from a refreshed container. Unselected fields,
    /// including manual empty values, keep both their value and provenance.
    SourceMetadata {
        fields: BTreeMap<String, Value>,
        #[serde(default)]
        illustrations: Option<Vec<Illustration>>,
    },
    Undo {},
    Redo {},
}
#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RestoreSource {
    #[default]
    Unspecified,
    Factory,
    Global,
}
#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Target {
    pub book_id: String,
    pub history: History,
    #[serde(default)]
    pub current: Option<Settings>,
    pub change: Change,
}
#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub targets: Vec<Target>,
}
#[derive(Serialize)]
struct Item {
    mapping: Option<crate::folder_mapping::Resolution>,
    book_id: String,
    before: Settings,
    after: Settings,
    changed_fields: Vec<String>,
    assets: Vec<crate::assets::ImageEvidence>,
    css_dependencies: crate::css_resources::Report,
    resource_issues: Vec<crate::project::ResourceIssue>,
    history: History,
}
fn edited(current: &Settings, fields: &BTreeMap<String, Edit>) -> Result<Settings, ApiError> {
    let mut value = serde_json::to_value(current).map_err(|_| invalid())?;
    let map = value.as_object_mut().ok_or_else(invalid)?;
    map.entry("additional_css_bundle").or_insert(Value::Null);
    map.entry("block_annotations").or_insert(json!([]));
    map.entry("manual_notes").or_insert(json!([]));
    map.entry("supplemental_pages").or_insert(json!([]));
    for (key, edit) in fields {
        if key == "layout_origins" || key == "metadata_origins" {
            return Err(invalid());
        }
        let old = map.get_mut(key).ok_or_else(invalid)?;
        let empty = old.is_null()
            || old.as_str().is_some_and(|s| s.trim().is_empty())
            || old.as_array().is_some_and(Vec::is_empty);
        match edit {
            Edit::Keep {} => {}
            Edit::Set { value } => *old = value.clone(),
            Edit::FillEmpty { value } if empty => *old = value.clone(),
            Edit::FillEmpty { .. } => {}
            Edit::Clear {} => {
                *old = match key.as_str() {
                    "title"
                    | "author"
                    | "description"
                    | "translator"
                    | "isbn"
                    | "publication_date"
                    | "publisher"
                    | "series"
                    | "series_index"
                    | "subjects"
                    | "category"
                    | "language"
                    | "additional_css"
                    | "additional_css_base" => json!(""),
                    "cover_path"
                    | "chapter_head_image"
                    | "chapter_style"
                    | "system_styles"
                    | "inset_styles"
                    | "cover_crop"
                    | "cover_design"
                    | "font_resource"
                    | "additional_css_bundle" => Value::Null,
                    "illustrations"
                    | "css_font_permissions"
                    | "block_annotations"
                    | "manual_notes"
                    | "supplemental_pages" => json!([]),
                    _ => return Err(invalid()),
                }
            }
        }
    }
    // Recipe and crop belong to the selected image, unless explicitly supplied.
    if value["cover_path"] != serde_json::to_value(&current.cover_path).map_err(|_| invalid())? {
        for key in ["cover_design", "cover_crop"] {
            if !fields.contains_key(key) {
                value[key] = Value::Null;
            }
        }
    }
    let mut next: Settings = serde_json::from_value(value).map_err(|_| invalid())?;
    let scalar = crate::layout_settings::factory();
    let values = serde_json::to_value(&next).map_err(|_| invalid())?;
    // Include implicit dependent changes (for example invalidating cover_design).
    let previous = serde_json::to_value(current).map_err(|_| invalid())?;
    for (key, value) in values.as_object().ok_or_else(invalid)? {
        let explicit = fields.get(key).is_some_and(|edit| match edit {
            Edit::Set { .. } | Edit::Clear {} => true,
            Edit::FillEmpty { .. } => previous[key] != *value,
            Edit::Keep {} => false,
        });
        if metadata_field(key) && (explicit || previous[key] != *value) {
            next.metadata_origins.insert(
                key.clone(),
                MetadataOrigin {
                    source: MetadataSource::Manual,
                    value: value.clone(),
                    baseline: Some(metadata_baseline(current, key, previous[key].clone())),
                    rule_folder: None,
                    rule_id: None,
                    rule_version: None,
                    rule_priority: 0,
                },
            );
        }
    }
    for (key, edit) in fields {
        if scalar.contains_key(key) && matches!(edit, Edit::Set { .. }) {
            next.layout_origins.insert(
                key.clone(),
                crate::layout_settings::Origin {
                    preset_name: None,
                    source: crate::layout_settings::OriginSource::Book,
                    value: values[key].clone(),
                },
            );
        }
    }
    if !fields.contains_key("additional_css_bundle")
        && (next.additional_css != current.additional_css
            || next.additional_css_base != current.additional_css_base)
    {
        next.additional_css_bundle = None;
    }
    if (next.additional_css_bundle != current.additional_css_bundle
        || matches!(fields.get("additional_css_bundle"), Some(Edit::Set { .. })))
        && let Some(reference) = &next.additional_css_bundle
    {
        reference.validate()?;
        let restored = crate::css_bundle::restore(
            Path::new(&reference.directory),
            &reference.manifest_sha256,
        )?;
        if restored.manifest.css != next.additional_css
            || restored.manifest.base != next.additional_css_base
        {
            return Err(invalid());
        }
    }
    Ok(next)
}

fn assign_origins(
    next: &mut Settings,
    fields: impl IntoIterator<Item = String>,
    source: crate::layout_settings::OriginSource,
) -> Result<(), ApiError> {
    let values = serde_json::to_value(&*next).map_err(|_| invalid())?;
    let scalar = crate::layout_settings::factory();
    for key in fields {
        if scalar.contains_key(&key) {
            next.layout_origins.insert(
                key.clone(),
                crate::layout_settings::Origin {
                    preset_name: None,
                    source: source.clone(),
                    value: values[&key].clone(),
                },
            );
        }
    }
    Ok(())
}
fn prepare(
    request: &Request,
    lookup: impl Fn(&str, u32) -> Result<u32, ApiError>,
) -> Result<(String, Vec<Item>), ApiError> {
    if request.targets.is_empty() || request.targets.len() > MAX_BATCH_TARGETS {
        return Err(invalid());
    }
    let mut ids = BTreeSet::new();
    let mut items = Vec::new();
    for target in &request.targets {
        if target.book_id.is_empty() || target.book_id.len() > 32768 || !ids.insert(&target.book_id)
        {
            return Err(invalid());
        }
        let mut history = target.history.clone();
        let lines = lookup(&history.source_id, history.revision)?;
        history.validate(lines)?;
        if let Some(current) = &target.current {
            current.validate(lines)?;
            history.push(current.clone());
        }
        let before = history.current().clone();
        let mut mapping = None;
        match &target.change {
            Change::RestoreLayout {
                defaults,
                fields,
                source,
            } => {
                if matches!(source, RestoreSource::Factory) {
                    let factory = crate::layout_settings::factory();
                    for field in fields {
                        let value = defaults.get(field).ok_or_else(invalid)?;
                        let expected = factory.get(field).ok_or_else(invalid)?;
                        if value != expected
                            && !(value.is_number()
                                && expected.is_number()
                                && value.as_f64() == expected.as_f64())
                        {
                            return Err(invalid());
                        }
                    }
                }
                let mut next = edited(
                    &before,
                    &crate::layout_settings::restore_fields(defaults, fields)?,
                )?;
                assign_origins(
                    &mut next,
                    fields.clone(),
                    match source {
                        RestoreSource::Unspecified => {
                            crate::layout_settings::OriginSource::RestoredDefault
                        }
                        RestoreSource::Factory => {
                            crate::layout_settings::OriginSource::RestoredFactory
                        }
                        RestoreSource::Global => {
                            crate::layout_settings::OriginSource::RestoredGlobal
                        }
                    },
                )?;
                next.validate(lines)?;
                history.push(next);
            }

            Change::ApplyLayoutLayers { layers } => {
                let resolved = layers.resolve()?;
                let preset = crate::layout_presets::Preset {
                    name: "resolved".into(),
                    values: resolved.values,
                };
                let mut next = edited(&before, &preset.edits()?)?;
                for (key, origin) in resolved.origins {
                    let source = match origin {
                        "factory" => crate::layout_settings::OriginSource::Factory,
                        "global" => crate::layout_settings::OriginSource::Global,
                        "preset" => crate::layout_settings::OriginSource::Preset,
                        _ => crate::layout_settings::OriginSource::Book,
                    };
                    assign_origins(&mut next, [key], source)?;
                }
                next.validate(lines)?;
                history.push(next);
            }

            Change::ApplyLayoutPreset { preset } => {
                let edits = preset.edits()?;
                let mut next = edited(&before, &edits)?;
                assign_origins(
                    &mut next,
                    edits.keys().cloned(),
                    crate::layout_settings::OriginSource::Preset,
                )?;
                for key in edits.keys() {
                    if let Some(origin) = next.layout_origins.get_mut(key) {
                        origin.preset_name = Some(preset.name.clone());
                    }
                }
                next.validate(lines)?;
                history.push(next);
            }
            Change::FolderMapping {
                source_path,
                rules,
                override_fields,
                restore_fields,
            } => {
                let mut restore_fields = restore_fields.clone();
                if restore_fields.contains("cover_path") {
                    let values = serde_json::to_value(&before).map_err(|_| invalid())?;
                    for key in ["cover_design", "cover_crop"] {
                        match before.metadata_origins.get(key) {
                            Some(origin)
                                if origin.source == MetadataSource::Manual
                                    && origin.baseline.is_some() =>
                            {
                                restore_fields.insert(key.to_owned());
                            }
                            Some(origin)
                                if origin.source == MetadataSource::Imported
                                    || origin.source == MetadataSource::FolderRule => {}
                            _ if values[key].is_null() => {}
                            _ => {
                                return Err(ApiError::new(
                                    ErrorCode::InvalidRule,
                                    "folder_mapping_cover_restore_unknown",
                                    "review_cover_recipe_and_crop_before_restoring",
                                ));
                            }
                        }
                    }
                }
                for key in &restore_fields {
                    if !metadata_field(key)
                        || override_fields.contains(key)
                        || !before.metadata_origins.get(key).is_some_and(|o| {
                            o.source == MetadataSource::Manual && o.baseline.is_some()
                        })
                    {
                        return Err(invalid());
                    }
                }
                if override_fields.iter().any(|key| !metadata_field(key)) {
                    return Err(invalid());
                }
                let resolved = crate::folder_mapping::resolve(source_path, rules)?;
                // Recompute inherited values from their original baseline. This also
                // handles removed fields, deleted rules and paths no longer matching.
                // Legacy origins with no baseline are preserved, never guessed.
                let mut base_value = serde_json::to_value(&before).map_err(|_| invalid())?;
                let mut origins = before.metadata_origins.clone();
                let mut layout_origins = before.layout_origins.clone();
                for (key, origin) in &before.metadata_origins {
                    if origin.source != MetadataSource::FolderRule && !restore_fields.contains(key)
                    {
                        continue;
                    }
                    if resolved.unavailable.iter().any(|index| {
                        let rule = &rules[*index];
                        origin.rule_id.as_ref().map_or_else(
                            || {
                                origin
                                    .rule_folder
                                    .as_ref()
                                    .is_some_and(|folder| rule.folder == *folder)
                            },
                            |id| rule.identity() == *id && rule.priority == origin.rule_priority,
                        )
                    }) {
                        return Err(ApiError::new(
                            ErrorCode::InvalidRule,
                            "folder_mapping_inherited_rule_offline",
                            "restore_rule_directory_or_explicitly_remove_rule",
                        ));
                    }
                    let Some(baseline) = &origin.baseline else {
                        continue;
                    };
                    base_value[key] = baseline.value.clone();
                    if let Some(origin) = &baseline.layout_origin {
                        layout_origins.insert(key.clone(), origin.clone());
                    } else {
                        layout_origins.remove(key);
                    }
                    if let Some(source) = &baseline.source {
                        origins.insert(
                            key.clone(),
                            MetadataOrigin {
                                source: source.clone(),
                                value: baseline.value.clone(),
                                baseline: None,
                                rule_folder: None,
                                rule_id: None,
                                rule_version: None,
                                rule_priority: 0,
                            },
                        );
                    } else {
                        origins.remove(key);
                    }
                }
                base_value["metadata_origins"] =
                    serde_json::to_value(origins).map_err(|_| invalid())?;
                base_value["layout_origins"] =
                    serde_json::to_value(layout_origins).map_err(|_| invalid())?;
                let base: Settings = serde_json::from_value(base_value).map_err(|_| invalid())?;
                let mut next = base.clone();
                if let Some(index) = resolved.winner {
                    let allowed: BTreeMap<_, _> = rules[index]
                        .fields
                        .iter()
                        .filter(|(key, _)| {
                            override_fields.contains(*key)
                                || restore_fields.contains(*key)
                                || !before.metadata_origins.get(*key).is_some_and(|origin| {
                                    matches!(
                                        origin.source,
                                        MetadataSource::Manual | MetadataSource::Unknown
                                    )
                                })
                        })
                        .map(|(key, edit)| (key.clone(), edit.clone()))
                        .collect();
                    next = edited(&base, &allowed)?;
                    for (key, origin) in &mut next.metadata_origins {
                        if base.metadata_origins.get(key) != Some(origin)
                            || allowed
                                .get(key)
                                .is_some_and(|e| matches!(e, Edit::Set { .. } | Edit::Clear {}))
                        {
                            origin.source = MetadataSource::FolderRule;
                            origin.rule_folder = Some(rules[index].folder.clone());
                            origin.rule_id = Some(rules[index].identity());
                            origin.rule_version = Some(rules[index].revision());
                            origin.rule_priority = rules[index].priority;
                        }
                    }
                    let fields = allowed
                        .iter()
                        .filter(|(_, edit)| matches!(edit, Edit::Set { .. }))
                        .map(|(key, _)| key.clone());
                    assign_origins(
                        &mut next,
                        fields,
                        crate::layout_settings::OriginSource::FolderRule,
                    )?;
                }
                next.validate(lines)?;
                history.push(next);
                mapping = Some(resolved);
            }
            Change::MoveIllustration {
                from_index,
                to_index,
            } => {
                let mut next = before.clone();
                if *from_index >= next.illustrations.len() || *to_index >= next.illustrations.len()
                {
                    return Err(invalid());
                }
                let item = next.illustrations.remove(*from_index);
                next.illustrations.insert(*to_index, item);
                history.push(next);
            }

            Change::Inspect {} => {}
            Change::Patch { fields } => {
                let next = edited(&before, fields)?;
                next.validate(lines)?;
                history.push(next);
            }
            Change::SourceMetadata {
                fields,
                illustrations,
            } => {
                if (fields.is_empty() && illustrations.is_none())
                    || fields.keys().any(|key| !metadata_field(key))
                {
                    return Err(invalid());
                }
                let mut edits: BTreeMap<String, Edit> = fields
                    .iter()
                    .map(|(key, value)| {
                        (
                            key.clone(),
                            Edit::Set {
                                value: value.clone(),
                            },
                        )
                    })
                    .collect();
                if let Some(images) = illustrations {
                    edits.insert(
                        "illustrations".into(),
                        Edit::Set {
                            value: serde_json::to_value(images).map_err(|_| invalid())?,
                        },
                    );
                }
                let mut next = edited(&before, &edits)?;
                let old_values = serde_json::to_value(&before).map_err(|_| invalid())?;
                let values = serde_json::to_value(&next).map_err(|_| invalid())?;
                // Covers may implicitly clear crop/recipe. These dependent
                // values describe the newly adopted image, not a manual edit.
                for key in METADATA_FIELDS {
                    if fields.contains_key(key) || old_values[key] != values[key] {
                        next.metadata_origins.insert(
                            key.into(),
                            MetadataOrigin {
                                source: MetadataSource::Imported,
                                value: values[key].clone(),
                                baseline: None,
                                rule_folder: None,
                                rule_id: None,
                                rule_version: None,
                                rule_priority: 0,
                            },
                        );
                    }
                }
                next.validate(lines)?;
                history.push(next);
            }
            Change::Undo {} if history.cursor > 0 => history.cursor -= 1,
            Change::Redo {} if history.cursor + 1 < history.states.len() => history.cursor += 1,
            _ => return Err(invalid()),
        }
        history.validate(lines)?;
        let after = history.current().clone();
        let (assets, resource_issues) = match after.assets() {
            Ok(assets) => (assets, Vec::new()),
            Err(_)
                if matches!(
                    target.change,
                    Change::Undo {} | Change::Redo {} | Change::Inspect {}
                ) =>
            {
                (
                    Vec::new(),
                    crate::project::resource_issues_for_settings(&target.book_id, &after),
                )
            }
            Err(error) => return Err(error),
        };
        let old = serde_json::to_value(&before).map_err(|_| invalid())?;
        let new = serde_json::to_value(&after).map_err(|_| invalid())?;
        let mut changed_fields: Vec<String> = old
            .as_object()
            .ok_or_else(invalid)?
            .keys()
            .chain(new.as_object().ok_or_else(invalid)?.keys())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .filter(|key| key.as_str() != "metadata_origins" && old[*key] != new[*key])
            .cloned()
            .collect();
        for key in before
            .metadata_origins
            .keys()
            .chain(after.metadata_origins.keys())
        {
            if before.metadata_origins.get(key) != after.metadata_origins.get(key)
                && !changed_fields.contains(key)
            {
                changed_fields.push(key.clone());
            }
        }
        changed_fields.sort();
        let css_dependencies = crate::css_bundle::for_settings(&after).report;
        items.push(Item {
            mapping,
            book_id: target.book_id.clone(),
            before,
            after,
            changed_fields,
            assets,
            css_dependencies,
            resource_issues,
            history,
        });
    }
    let mut hash = Sha256::new();
    hash.update(b"production-settings-v1");
    hash.update(serde_json::to_vec(request).map_err(|_| invalid())?);
    hash.update(serde_json::to_vec(&items).map_err(|_| invalid())?);
    Ok((format!("{:x}", hash.finalize()), items))
}
pub fn run(
    service: &ImportService,
    request_json: String,
    apply: bool,
    plan_id: String,
    confirmed: bool,
) -> Result<String, ApiError> {
    if request_json.len() > 128 * 1024 * 1024 {
        return Err(invalid());
    }
    let value: Value = serde_json::from_str(&request_json).map_err(|_| invalid())?;
    if value["op"] == "supplemental_pages" {
        return crate::supplemental_pages::run(service, value, apply, &plan_id, confirmed);
    }
    if value["op"] == "supplemental_templates" && !apply {
        return crate::supplemental_pages::templates(value);
    }
    // V77 系统提示块样式：只读列出内置预设（界面与 Rust 预设的一致性由测试核对）。
    if value["op"] == "block_styles" {
        if apply || confirmed || !plan_id.is_empty() {
            return Err(invalid());
        }
        let presets: Vec<Value> = crate::block_styles::presets()
            .into_iter()
            .map(|(id, name, kind, style)| json!({"id": id, "name": name, "kind": kind, "style": style}))
            .collect();
        return serde_json::to_string(&json!({"presets": presets})).map_err(|_| invalid());
    }
    // V82 场景样式：只读列出内置预设（界面与 Rust 预设的一致性由测试核对）。
    if value["op"] == "inset_styles" {
        if apply || confirmed || !plan_id.is_empty() {
            return Err(invalid());
        }
        let presets: Vec<Value> = crate::inset_styles::presets()
            .into_iter()
            .map(|(id, name, scene, style)| json!({"id": id, "name": name, "scene": scene, "style": style}))
            .collect();
        let scenes: Vec<Value> = crate::insets::TYPES
            .iter()
            .map(|(id, name)| json!({"id": id, "name": name}))
            .collect();
        return serde_json::to_string(&json!({"presets": presets, "scenes": scenes}))
            .map_err(|_| invalid());
    }
    // V74 章节样式包：生成内置包、导入与导出样式包文件，不涉及书稿。
    if value["op"] == "chapter_style" {
        if apply || confirmed || !plan_id.is_empty() {
            return Err(invalid());
        }
        return crate::style_packs::run(value);
    }
    // V68 自动更新：只读检查与下载，不涉及书稿，也不走制作事务。
    if value["op"] == "app_update" {
        if apply || confirmed || !plan_id.is_empty() {
            return Err(invalid());
        }
        return crate::app_update::run(value);
    }
    if value["op"] == "rule_catalog" {
        if matches!(
            value["action"].as_str(),
            Some("settings" | "preview_toggles" | "apply_toggles" | "restore_toggles")
        ) {
            return crate::rule_toggles::run(service, value);
        }
        if apply || confirmed || !plan_id.is_empty() {
            return Err(invalid());
        }
        return crate::rule_statistics::run(service, value);
    }
    if value["op"] == "manual_notes" {
        return crate::manual_notes::run(service, value, apply, &plan_id, confirmed);
    }
    if value["op"] == "block_annotations" {
        return crate::block_annotations::run(service, value, apply, &plan_id, confirmed);
    }
    if value["op"] == "conversion_dependencies" {
        return conversion_dependencies(&value, apply);
    }
    let request: Request = serde_json::from_value(value).map_err(|_| invalid())?;
    let (id, items) = prepare(&request, |id, revision| {
        Ok(service.source(id, revision)?.summary().line_count)
    })?;
    response(id, items, apply, &plan_id, confirmed)
}
// Read-only dependency identity for incremental conversion previews. This uses
// the same CSS graph and offline-bundle validation as publication preparation.
fn conversion_dependencies(value: &Value, apply: bool) -> Result<String, ApiError> {
    if apply {
        return Err(invalid());
    }
    let settings: Settings =
        serde_json::from_value(value["settings"].clone()).map_err(|_| invalid())?;
    serde_json::to_string(&crate::css_bundle::for_settings(&settings).report).map_err(|_| invalid())
}

fn response(
    id: String,
    items: Vec<Item>,
    apply: bool,
    plan_id: &str,
    confirmed: bool,
) -> Result<String, ApiError> {
    if apply && (!confirmed || plan_id != id) {
        return Err(stale());
    }
    // History is returned only after confirmation; previews contain actual field differences.
    let items: Vec<_> = items
        .into_iter()
        .map(|item| {
            json!({
                "book_id":item.book_id,"before":item.before,"after":item.after,"mapping":item.mapping,
                "changed_fields":item.changed_fields,"assets":item.assets,
                "resource_issues":item.resource_issues, "css_dependencies":item.css_dependencies,
                "history":if apply {Some(item.history)} else {None}
            })
        })
        .collect();
    let result =
        json!({"plan_id":id,"applied":apply,"items":items,"writes_source":false}).to_string();
    if result.len() > 128 * 1024 * 1024 {
        return Err(invalid());
    }
    Ok(result)
}

/// Read-only placement report against the same effective composition as text output.
pub fn illustration_positions(
    service: &ImportService,
    source_id: String,
    revision: u32,
    request_json: String,
) -> Result<String, ApiError> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Request {
        source_lines: Vec<Option<u32>>,
        structure: Option<easypub_core::structure::Structure>,
        manual: Option<Value>,
        cleanup: Option<Value>,
        catalog: Option<crate::catalog::CompositionSelection>,
        post_edits: Option<crate::edit_checkpoint::EditRequest>,
    }
    if request_json.len() > 2 * 1024 * 1024 {
        return Err(invalid());
    }
    let request: Request = serde_json::from_str(&request_json).map_err(|_| invalid())?;
    let source = service.source(&source_id, revision)?;
    if request.source_lines.len() > 512
        || request
            .source_lines
            .iter()
            .flatten()
            .any(|&n| n == 0 || n > source.summary().line_count)
    {
        return Err(invalid());
    }
    let structure = request
        .structure
        .unwrap_or_else(|| easypub_core::structure::Structure::new(&source));
    let manual = request.manual.map(|v| v.to_string());
    let cleanup = request.cleanup.map(|v| v.to_string());
    let book = crate::catalog::compose_selection(
        &source,
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
    let positions = request
        .source_lines
        .into_iter()
        .map(|line| illustration_location(&book, &source_id, line))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(json!({"source_id":source_id,"revision":revision,"positions":positions}).to_string())
}

fn illustration_location(
    book: &easypub_core::publication::EffectiveBook,
    source_id: &str,
    line: Option<u32>,
) -> Result<Value, ApiError> {
    use easypub_core::publication::IllustrationPosition;
    let position = book.illustration_position(source_id, line)?;
    let mut result = serde_json::to_value(&position).map_err(|_| invalid())?;
    if let IllustrationPosition::AfterLine { output_line, .. } = position {
        // Effective tree nodes follow physical output order, including moves.
        let end = book
            .tree
            .nodes
            .partition_point(|node| node.source_line <= output_line);
        if let Some(index) = end.checked_sub(1) {
            let node = &book.tree.nodes[index];
            result["entry_id"] = json!(node.entry_id);
            result["node_offset"] = json!(index);
            result["heading"] = json!(node.title);
        }
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn illustration_location_tracks_effective_moves_and_unplaced() {
        use easypub_core::{
            effective_edit, publication,
            source::{RULE_ID, SourceSnapshot},
            structure::Structure,
        };
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n甲正文\n第二章 乙\n乙正文\n".as_bytes().to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let id = source.summary().source_id;
        let book = publication::compose(&source, &Structure::new(&source), None).unwrap();
        let first = book.tree.nodes[0].entry_id.clone();
        let initial = illustration_location(&book, &id, Some(2)).unwrap();
        assert_eq!(initial["entry_id"], first);
        assert_eq!(initial["node_offset"], 0);
        let request = effective_edit::Request {
            base_id: effective_edit::base_id(&book),
            actions: vec![effective_edit::Action::MoveSubtree {
                entry_id: first.clone(),
                before_id: None,
            }],
        };
        let moved = effective_edit::apply(book, &request).unwrap().0;
        let position = illustration_location(&moved, &id, Some(2)).unwrap();
        assert_eq!(position["entry_id"], first);
        assert_eq!(position["node_offset"], 1);
        assert!(position["output_line"].as_u64().unwrap() > 2);
        assert!(
            illustration_location(&moved, &id, None)
                .unwrap()
                .get("entry_id")
                .is_none()
        );
    }
    fn settings() -> Settings {
        serde_json::from_value(
            json!({"title":"目标书", "author":"", "description":"保留简介",
            "cover_path":null,"cover_fit":"cover","font_family":"Microsoft YaHei",
            "font_size":18.0,"line_height":1.8,"include_toc":true,"illustrations":[]}),
        )
        .unwrap()
    }
    #[test]
    fn conversion_dependency_probe_tracks_css_bytes_without_applying_settings() {
        let root = std::env::temp_dir().join(format!(
            "easypub-deps47-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&root).unwrap();
        let file = root.join("theme.css");
        std::fs::write(&file, "p{color:red}").unwrap();
        let mut current = settings();
        current.additional_css = "@import url(theme.css);".into();
        current.additional_css_base = root.to_string_lossy().into_owned();
        let value = json!({"op":"conversion_dependencies","settings":current});
        let first: Value =
            serde_json::from_str(&conversion_dependencies(&value, false).unwrap()).unwrap();
        assert_eq!(first["issues"], json!([]));
        assert_eq!(first["files"].as_array().unwrap().len(), 1);
        std::fs::write(&file, "p{color:tan}").unwrap();
        let next: Value =
            serde_json::from_str(&conversion_dependencies(&value, false).unwrap()).unwrap();
        assert_ne!(first["files"][0]["sha256"], next["files"][0]["sha256"]);
        assert!(conversion_dependencies(&value, true).is_err());
        assert_eq!(std::fs::read_to_string(&file).unwrap(), "p{color:tan}");
        std::fs::remove_file(file).unwrap();
        std::fs::remove_dir(root).unwrap();
    }
    fn request(fields: Value) -> Request {
        serde_json::from_value(json!({"targets":[{"book_id":"book-a",
            "history":{"source_id":"a".repeat(64),"revision":1,"states":[settings()],"cursor":0},
            "change":{"op":"patch","fields":fields}}]}))
        .unwrap()
    }
    fn plan(r: &Request) -> Result<(String, Vec<Item>), ApiError> {
        prepare(r, |_, _| Ok(10))
    }
    #[test]
    fn source_metadata_adopts_only_selected_fields_and_retains_reversible_origins() {
        let (_, first) = plan(&request(json!({"author":{"op":"set","value":""},
            "publisher":{"op":"set","value":"手工出版社"}})))
        .unwrap();
        let mut r: Request = serde_json::from_value(json!({"targets":[{"book_id":"book-a",
            "history":first[0].history,"change":{"op":"source_metadata","fields":{"title":"新来源书名","description":"新来源简介"}}}]})).unwrap();
        let (id, changed) = plan(&r).unwrap();
        assert_eq!(changed[0].after.title, "新来源书名");
        assert_eq!(changed[0].after.author, "");
        assert_eq!(changed[0].after.publisher, "手工出版社");
        assert_eq!(
            changed[0].after.metadata_origins["author"].source,
            MetadataSource::Manual
        );
        assert_eq!(
            changed[0].after.metadata_origins["title"].source,
            MetadataSource::Imported
        );
        assert!(
            changed[0].after.metadata_origins["title"]
                .baseline
                .is_none()
        );
        let preview: Value = serde_json::from_str(
            &response(id.clone(), plan(&r).unwrap().1, false, "", false).unwrap(),
        )
        .unwrap();
        assert!(preview["items"][0]["history"].is_null());
        assert!(response(id.clone(), plan(&r).unwrap().1, true, &id, false).is_err());
        assert!(response(id.clone(), plan(&r).unwrap().1, true, "stale", true).is_err());
        let committed: Value =
            serde_json::from_str(&response(id.clone(), changed, true, &id, true).unwrap()).unwrap();
        r.targets[0].history =
            serde_json::from_value(committed["items"][0]["history"].clone()).unwrap();
        r.targets[0].change = Change::Undo {};
        let (_, undone) = plan(&r).unwrap();
        assert_eq!(undone[0].after, first[0].after);
        r.targets[0].history = undone[0].history.clone();
        r.targets[0].change = Change::Redo {};
        assert_eq!(plan(&r).unwrap().1[0].after.title, "新来源书名");
        r.targets[0].change =
            serde_json::from_value(json!({"op":"source_metadata","fields":{"illustrations":[]}}))
                .unwrap();
        assert!(plan(&r).is_err());
    }

    #[test]
    fn metadata_same_value_and_clear_preserve_manual_intent_in_history() {
        let (_, items) = plan(&request(json!({"author":{"op":"set","value":""}}))).unwrap();
        let first = &items[0];
        assert_eq!(first.after.author, "");
        assert_eq!(
            first.after.metadata_origins["author"].source,
            MetadataSource::Manual
        );
        assert_eq!(first.history.cursor, 1);
        let history: History =
            serde_json::from_str(&serde_json::to_string(&first.history).unwrap()).unwrap();
        assert_eq!(
            history.current().metadata_origins["author"].value,
            json!("")
        );
        let undo: Request = serde_json::from_value(
            json!({"targets":[{"book_id":"book-a","history":history,"change":{"op":"undo"}}]}),
        )
        .unwrap();
        let (_, undone) = plan(&undo).unwrap();
        assert!(undone[0].after.metadata_origins.is_empty());
        let (_, clear) = plan(&request(json!({"publisher":{"op":"clear"}}))).unwrap();
        assert_eq!(
            clear[0].after.metadata_origins["publisher"].source,
            MetadataSource::Manual
        );
        assert!(
            plan(&request(
                json!({"metadata_origins":{"op":"set","value":{}}})
            ))
            .is_err()
        );
    }
    #[test]
    fn cover_design_roundtrip_and_replacement_clear() {
        let mut current = settings();
        let design = CoverDesign {
            title: "独立标题".into(),
            author: "作者".into(),
            series: "系列".into(),
            color: 0xff23664f,
            style: "river-classic-v1".into(),
            image_sha256: "a".repeat(64),
        };
        design.validate().unwrap();
        current.cover_path = Some("D:/cover.png".into());
        current.cover_design = Some(design.clone());
        let restored: Settings =
            serde_json::from_value(serde_json::to_value(&current).unwrap()).unwrap();
        assert_eq!(restored.cover_design, Some(design.clone()));
        let fields =
            serde_json::from_value(json!({"cover_path":{"op":"set","value":"D:/other.png"}}))
                .unwrap();
        assert!(edited(&current, &fields).unwrap().cover_design.is_none());
        let fields =
            serde_json::from_value(json!({"title":{"op":"set","value":"元信息独立"}})).unwrap();
        assert_eq!(
            edited(&current, &fields).unwrap().cover_design,
            Some(design.clone())
        );
        for (field, value) in [
            ("style", json!("unknown")),
            ("color", json!(0)),
            ("title", json!("")),
            ("image_sha256", json!("bad")),
        ] {
            let mut value_json = serde_json::to_value(&design).unwrap();
            value_json[field] = value;
            assert!(
                serde_json::from_value::<CoverDesign>(value_json)
                    .unwrap()
                    .validate()
                    .is_err()
            );
        }
    }
    #[test]
    fn series_metadata_validates_positions_and_survives_history() {
        let fields = json!({"series":{"op":"set","value":"长河纪事"},
            "series_index":{"op":"set","value":"2.2.1"},"subjects":{"op":"set","value":"旅行、群像"}});
        let (_, items) = plan(&request(fields)).unwrap();
        let history: History =
            serde_json::from_value(serde_json::to_value(&items[0].history).unwrap()).unwrap();
        assert_eq!(history.current().series, "长河纪事");
        assert_eq!(history.current().series_index, "2.2.1");
        assert_eq!(history.current().subjects, "旅行、群像");
        for index in ["-1", "1..2", "1e2", "NaN", "4294967296", " 1"] {
            assert!(plan(&request(json!({"series":{"op":"set","value":"系列"},"series_index":{"op":"set","value":index}}))).is_err());
        }
        assert!(plan(&request(json!({"series_index":{"op":"set","value":"1"}}))).is_err());
        assert_eq!(settings().series, "");
    }
    #[test]
    fn folder_mapping_is_specific_component_bound_and_reversible() {
        let root = std::env::temp_dir().join(format!(
            "easypub-folder-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&root).unwrap();
        let sub = root.join("books");
        let child = sub.join("author");
        let sibling = root.join("books-other");
        std::fs::create_dir(&sub).unwrap();
        std::fs::create_dir(&child).unwrap();
        std::fs::create_dir(&sibling).unwrap();
        let file = child.join("book.txt");
        let outside = sibling.join("book.txt");
        std::fs::write(&file, b"body").unwrap();
        std::fs::write(&outside, b"body").unwrap();
        let rules = json!([
            {"folder":sub,"fields":{"author":{"op":"set","value":"parent"}}},
            {"folder":child,"fields":{"author":{"op":"fill_empty","value":"child"},"description":{"op":"clear"}}}
        ]);
        let mut r = request(json!({"author":{"op":"keep"}}));
        r.targets[0].change =
            serde_json::from_value(json!({"op":"folder_mapping","source_path":file,"rules":rules}))
                .unwrap();
        let (id, mut items) = plan(&r).unwrap();
        assert_eq!(items[0].after.author, "child");
        assert_eq!(items[0].after.description, "");
        assert_eq!(items[0].mapping.as_ref().unwrap().candidates, vec![1, 0]);
        r.targets[0].history = items.remove(0).history;
        r.targets[0].change = Change::Undo {};
        assert_eq!(plan(&r).unwrap().1[0].after.author, "");
        r.targets[0].change = serde_json::from_value(
            json!({"op":"folder_mapping","source_path":outside,"rules":rules}),
        )
        .unwrap();
        let (other, items) = plan(&r).unwrap();
        assert_ne!(id, other);
        assert!(items[0].mapping.as_ref().unwrap().winner.is_none());
        assert_eq!(items[0].after.author, "");
        assert_eq!(
            items[0].after.description,
            r.targets[0].history.states[0].description
        );
        assert!(items[0].changed_fields.contains(&"author".to_string()));
        r.targets[0].change =
            serde_json::from_value(json!({"op":"folder_mapping","source_path":file,"rules":[]}))
                .unwrap();
        let (_, removed) = plan(&r).unwrap();
        assert_eq!(removed[0].after.author, "");
        assert_eq!(
            removed[0].after.description,
            r.targets[0].history.states[0].description
        );
        let duplicate = json!([{"folder":sub,"fields":{"author":{"op":"clear"}}},{"folder":child.join(".."),"fields":{"author":{"op":"set","value":"ambiguous"}}}]);
        r.targets[0].change = serde_json::from_value(
            json!({"op":"folder_mapping","source_path":file,"rules":duplicate}),
        )
        .unwrap();
        assert!(plan(&r).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn explicit_empty_clear_keep_and_set_are_distinct() {
        let r = request(json!({
            "title":{"op":"fill_empty","value":"不能覆盖"},
            "author":{"op":"fill_empty","value":"作者"},
            "description":{"op":"clear"},
            "include_toc":{"op":"keep"},
            "font_size":{"op":"set","value":24.0}
        }));
        let (_, items) = plan(&r).unwrap();
        assert_eq!(items[0].after.title, "目标书");
        assert_eq!(items[0].after.author, "作者");
        assert_eq!(items[0].after.description, "");
        assert!(items[0].after.include_toc);
        assert_eq!(items[0].after.font_size, 24.0);
        assert_eq!(
            items[0].changed_fields,
            ["author", "description", "font_size", "layout_origins"]
        );
        assert_eq!(items[0].history.states.len(), 2);
    }
    #[test]
    fn confirmation_and_fingerprint_bind_full_before_values() {
        let mut r = request(json!({"title":{"op":"set","value":"新标题"}}));
        let (id, items) = plan(&r).unwrap();
        let preview: Value =
            serde_json::from_str(&response(id.clone(), items, false, "", false).unwrap()).unwrap();
        assert!(preview["items"][0]["history"].is_null());
        let (new_id, items) = plan(&r).unwrap();
        assert!(response(new_id, items, true, &id, false).is_err());
        r.targets[0].history.states[0].description = "外部编辑".into();
        let (new_id, items) = plan(&r).unwrap();
        assert_ne!(new_id, id);
        assert!(response(new_id, items, true, &id, true).is_err());
        let (id, items) = plan(&r).unwrap();
        let result: Value =
            serde_json::from_str(&response(id.clone(), items, true, &id, true).unwrap()).unwrap();
        assert_eq!(result["items"][0]["history"]["cursor"], 1);
    }
    #[test]
    fn undo_redo_and_new_branch_survive_serialization() {
        let mut r = request(json!({"title":{"op":"set","value":"新标题"}}));
        r.targets[0].history = plan(&r).unwrap().1.remove(0).history;
        r = serde_json::from_str(&serde_json::to_string(&r).unwrap()).unwrap();
        r.targets[0].change = Change::Undo {};
        let item = plan(&r).unwrap().1.remove(0);
        assert_eq!(item.after.title, "目标书");
        r.targets[0].history = item.history;
        r.targets[0].change = Change::Redo {};
        assert_eq!(plan(&r).unwrap().1[0].after.title, "新标题");
        r.targets[0].change = Change::Patch {
            fields: BTreeMap::from([(
                "title".into(),
                Edit::Set {
                    value: json!("另一分支"),
                },
            )]),
        };
        r.targets[0].history = plan(&r).unwrap().1.remove(0).history;
        assert_eq!(r.targets[0].history.states.len(), 2);
        r.targets[0].change = Change::Redo {};
        assert!(plan(&r).is_err());
    }
    #[test]
    fn bad_field_type_bounds_unknowns_and_empty_numeric_are_rejected() {
        for fields in [
            json!({"font_size":{"op":"clear"}}),
            json!({"font_size":{"op":"set","value":100}}),
            json!({"include_toc":{"op":"set","value":"true"}}),
            json!({"unknown":{"op":"keep"}}),
        ] {
            assert!(plan(&request(fields)).is_err());
        }
        assert!(serde_json::from_value::<Edit>(json!({"op":"keep","value":1})).is_err());
    }
    #[test]
    fn mixed_batch_invalid_target_or_resource_never_returns_partial_result() {
        let mut r = request(json!({"title":{"op":"set","value":"新标题"}}));
        let mut bad: Target =
            serde_json::from_value(serde_json::to_value(&r.targets[0]).unwrap()).unwrap();
        bad.book_id = "book-b".into();
        bad.change = Change::Patch {
            fields: BTreeMap::from([(
                "cover_path".into(),
                Edit::Set {
                    value: json!("relative.png"),
                },
            )]),
        };
        r.targets.push(bad);
        assert!(plan(&r).is_err());
        assert_eq!(r.targets[0].history.current().title, "目标书");
        r.targets[1].change = Change::Patch {
            fields: BTreeMap::new(),
        };
        r.targets[1].book_id = "book-a".into();
        assert!(plan(&r).is_err());
        assert!(prepare(&request(json!({})), |_, _| Err(stale())).is_err());
    }
    #[test]
    fn replacement_image_invalidates_confirmed_plan() {
        let path = std::env::temp_dir().join(format!(
            "easypub-production-image-{}.png",
            std::process::id()
        ));
        let write = |color: u8| {
            image::ImageBuffer::from_pixel(2, 2, image::Rgba([color, 0u8, 0, 255]))
                .save(&path)
                .unwrap()
        };
        write(1);
        let req = request(json!({"cover_path":{"op":"set","value":path.to_string_lossy()}}));
        let (id, _) = plan(&req).unwrap();
        write(2);
        let (new_id, items) = plan(&req).unwrap();
        assert_ne!(id, new_id);
        assert!(response(new_id, items, true, &id, true).is_err());
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn no_op_does_not_add_history_and_history_is_bounded() {
        let mut r = request(json!({"title":{"op":"keep"}}));
        assert_eq!(plan(&r).unwrap().1[0].history.states.len(), 1);
        assert!(plan(&r).unwrap().1[0].changed_fields.is_empty());
        for i in 0..60 {
            r.targets[0].change = Change::Patch {
                fields: BTreeMap::from([(
                    "title".into(),
                    Edit::Set {
                        value: json!(format!("标题{i}")),
                    },
                )]),
            };
            r.targets[0].history = plan(&r).unwrap().1.remove(0).history;
        }
        assert_eq!(r.targets[0].history.states.len(), 51);
        assert_eq!(r.targets[0].history.cursor, 50);
    }
}
