//! Deterministic style resource from validated book settings; no implicit font embedding.
use crate::production::Settings;
use easypub_core::ApiError;
use serde::Serialize;
use sha2::{Digest, Sha256};

#[derive(Debug, Serialize)]
pub struct Stylesheet {
    pub id: String,
    pub media_type: &'static str,
    pub css: String,
    pub font_embedded: bool,
    pub additional_css_references: crate::css_references::Report,
    pub additional_css_resolutions: Vec<crate::css_references::Resolution>,
    #[serde(skip)]
    custom_offset: usize,
}
/// 封面页 SVG 的样式：取视口高度，阅读器按页面大小放下整张封面，
/// 比例由封面页的 preserveAspectRatio 决定。KFX 的封面页是普通图片，Bokai 也不支持 vh，
/// 因此 KFX 样式表去掉这一条（见 epub.rs）。
pub const COVER_SVG_RULE: &str = ".cover svg { display: block; width: 100%; height: 100vh; }\n";
/// 竖排：整本书从上到下、从右往左；图片按高度限制；纵中横。
pub const VERTICAL_RULES: &str = "/* EasyPub vertical writing */\n\
html { writing-mode: vertical-rl; -webkit-writing-mode: vertical-rl; -epub-writing-mode: vertical-rl; }\n\
figure img { max-height: 100%; }\n\
.tcy { text-combine-upright: all; -webkit-text-combine: horizontal; -epub-text-combine: horizontal; }\n";
/// 章节标题样式，按用户书库里的成品书复刻。
/// 序言等前置标题（front-heading）与章标题同样处理，与原版 EasyPub 一致。
/// - classic：原版 EasyPub v1.50 的 titlel2std（居中、x-large、点线下框、浅阴影）；
/// - amazon：亚马逊中国官方书的 kindle-cn-heading（居中、1.2em 粗黑体、灰色虚线下框）；
/// - publisher：上海译文、译林等出版社（居中、大字、上方留白宽）；
/// - two_line：网文精排（上行小字“第一章”、换行后章名，见 publication_documents）；
/// - light_novel：小学馆、角川等日系轻小说中文版（居中粗体、下方横线）。
pub fn heading_rules(style: &str) -> &'static str {
    match style {
        "amazon" => {
            ".chapter-heading, .front-heading { font-family: \"MYing Hei S\", Hei, \"黑体\", sans-serif; font-size: 1.2em; font-weight: bold; line-height: 1.2; text-align: center; margin: 0.67em 0 1em; border-bottom: 2px dashed #c7c7c7; }\n"
        }
        "publisher" => {
            ".chapter-heading, .front-heading { font-size: 1.6em; font-weight: bold; line-height: 1.2; text-align: center; margin: 2em 0 1em; }\n"
        }
        "two_line" => {
            ".chapter-heading, .front-heading { font-size: 1.2em; font-weight: bold; line-height: 1.3; text-align: center; margin: 0.5em 0 2em; }\n\
.chapter-label { font-size: 0.7em; }\n"
        }
        "light_novel" => {
            ".chapter-heading, .front-heading { font-size: 1.5em; font-weight: bold; line-height: 1.3; text-align: center; margin: 0 0 1em; padding-bottom: 0.4em; border-bottom: 1px solid #888888; }\n"
        }
        _ => CLASSIC_HEADING,
    }
}
/// 原版 EasyPub 的章节标题；阴影单列，KFX 输入去掉（Bokai 不支持 text-shadow，见 epub.rs）。
pub const CLASSIC_SHADOW: &str = " text-shadow: 1px 1px 1px #333333;";
const CLASSIC_HEADING: &str = ".chapter-heading, .front-heading { font-size: x-large; line-height: 125%; text-align: center; margin: 0 0 1.2em; padding: 10px 0; border-bottom: 1px dotted #c1ccc0; text-shadow: 1px 1px 1px #333333; }\n";
/// 注音与着重号；中文着重号横排在下、竖排在右。
pub const INLINE_MARKUP_RULES: &str = "/* EasyPub ruby and emphasis */\n\
rt { font-size: 0.5em; }\n\
.em-dot { text-emphasis-style: filled dot; -webkit-text-emphasis-style: filled dot; -epub-text-emphasis-style: filled dot; text-emphasis-position: under right; -webkit-text-emphasis-position: under right; -epub-text-emphasis-position: under right; }\n";
/// 正文用到注音或着重号时，把规则加在基础样式末尾（用户附加样式之前）。
pub fn add_inline_markup(style: Stylesheet) -> Stylesheet {
    add_rules(style, INLINE_MARKUP_RULES)
}
/// 上标、下标、链接：只有用到时才加，其余书的样式表不变。
pub const INLINE_SOURCE_RULES: &str = ".inline-sup { vertical-align: super; font-size: 0.75em; }\n\
.inline-sub { vertical-align: sub; font-size: 0.75em; }\n\
.inline-link { text-decoration: underline; }\n";
pub const TABLE_RULES: &str = ".book-table { border-collapse: collapse; margin: 1em auto; }\n\
.book-table caption { margin-bottom: 0.4em; }\n\
.book-table th, .book-table td { border: 1px solid #666; padding: 0.2em 0.5em; }\n\
.book-table th { font-weight: bold; }\n";
pub fn add_rules(mut style: Stylesheet, rules: &str) -> Stylesheet {
    style.css.insert_str(style.custom_offset, rules);
    style.custom_offset += rules.len();
    style.id = format!("{:x}.css", Sha256::digest(style.css.as_bytes()));
    style
}
/// Bokai 尚不支持波浪装饰，KFX 输入明确降级为下划线。
pub const INLINE_WAVY_RULE: &str =
    ".inline-wavy { text-decoration: underline; text-decoration-style: wavy; }\n";
pub fn prepare(settings: &Settings) -> Result<Stylesheet, ApiError> {
    prepare_with(
        settings,
        !settings.inline_styles.is_empty(),
        !settings.manual_notes.is_empty(),
    )
}
/// 两个开关含原书标记：它们不在设置里，也不走设置校验。
pub fn prepare_with(
    settings: &Settings,
    inline_styles: bool,
    notes: bool,
) -> Result<Stylesheet, ApiError> {
    settings.validate(u32::MAX)?;
    let fallback = if settings.font_family == "SimSun" {
        "serif"
    } else {
        "sans-serif"
    };
    // 封面页：SVG 规则见 COVER_SVG_RULE；KFX 的封面页仍是普通图片、高度随宽度。
    let mut css = format!(
        "/* EasyPub publication styles v3 */\n\
         @page {{ margin: {} {} {} {}; }}\n\
         body {{ margin: 0; font-family: \"{}\", {}; font-size: {}; line-height: {}; }}\n\
         p {{ margin: 0 0 {}; text-indent: {}; }}\n\
         h1, h2, h3 {{ text-indent: 0; break-after: avoid; }}\n\
         figure {{ margin: 1em 0; text-indent: 0; text-align: center; break-inside: avoid; }}\n\
         figure img {{ max-width: 100%; height: auto; }}\n\
         figcaption {{ font-size: 0.9em; text-indent: 0; }}\n\
         .cover {{ width: 100%; height: 100%; margin: 0; padding: 0; text-indent: 0; }}\n\
         .cover img {{ width: 100%; height: auto; }}\n\
         .nb {{ white-space: nowrap; }}\n",
        if settings.layout_units_version == 0 && settings.margin_top_unit == "em" {
            format!(
                "{}px",
                settings.margin_top
                    * crate::layout_units::font_px(settings.font_size, &settings.font_size_unit)
            )
        } else {
            crate::layout_units::css(settings.margin_top, &settings.margin_top_unit)
        },
        if settings.layout_units_version == 0 && settings.margin_right_unit == "em" {
            format!(
                "{}px",
                settings.margin_right
                    * crate::layout_units::font_px(settings.font_size, &settings.font_size_unit)
            )
        } else {
            crate::layout_units::css(settings.margin_right, &settings.margin_right_unit)
        },
        if settings.layout_units_version == 0 && settings.margin_bottom_unit == "em" {
            format!(
                "{}px",
                settings.margin_bottom
                    * crate::layout_units::font_px(settings.font_size, &settings.font_size_unit)
            )
        } else {
            crate::layout_units::css(settings.margin_bottom, &settings.margin_bottom_unit)
        },
        if settings.layout_units_version == 0 && settings.margin_left_unit == "em" {
            format!(
                "{}px",
                settings.margin_left
                    * crate::layout_units::font_px(settings.font_size, &settings.font_size_unit)
            )
        } else {
            crate::layout_units::css(settings.margin_left, &settings.margin_left_unit)
        },
        settings.font_family,
        fallback,
        crate::layout_units::css(settings.font_size, &settings.font_size_unit),
        crate::layout_units::css(settings.line_height, &settings.line_height_unit),
        crate::layout_units::css(settings.paragraph_spacing, &settings.paragraph_spacing_unit),
        crate::layout_units::css(settings.paragraph_indent, &settings.paragraph_indent_unit),
    );
    if settings.layout_units_version == 1 {
        css.push_str(&format!(
            "@page {{ font-size: {}; }}\n",
            crate::layout_units::css(settings.font_size, &settings.font_size_unit)
        ));
    }
    css.push_str(COVER_SVG_RULE);
    css.push_str(&format!(
        "p {{ text-align: {}; }}\n",
        settings.text_alignment
    ));
    css.push_str(concat!(
        ".text-line { white-space: pre-wrap; }\n",
        ".heading, h1, h2, h3, h4, h5, h6 { text-indent: 0; break-after: avoid; page-break-after: avoid; line-height: 1.3; }\n",
        ".title-page { break-after: page; page-break-after: always; text-align: center; padding-top: 20%; }\n",
        ".title-page p { text-align: center; text-indent: 0; }\n",
        ".book-title { font-size: 2em; margin: 0 0 1em; }\n",
        ".book-author, .book-translator { font-size: 1em; margin: 0.5em 0; }\n",
        ".front-matter { break-after: page; page-break-after: always; }\n",
        ".volume-heading { font-size: 1.8em; text-align: center; margin: 2em 0; }\n",
        ".section-heading { font-size: 1.2em; margin: 1em 0 0.5em; }\n",
        ".chapter-start, .volume-start, .front-start { break-before: page; page-break-before: always; }\n",
        ".content-continuation { break-before: auto; page-break-before: auto; }\n",
        ".toc { break-after: page; page-break-after: always; }\n",
        ".toc ol { list-style: none; padding-left: 1.5em; }\n",
        ".toc a { color: inherit; text-decoration: none; }\n",
        ".toc li { margin: 0.4em 0; text-indent: 0; }\n",
        ".chapter-navigation { text-align: center; text-indent: 0; margin: 1em 0; font-size: 0.9em; }\n",
        ".chapter-navigation a { color: inherit; margin: 0 0.5em; }\n",
        ".scene-break { text-align: center; text-indent: 0; margin: 1em 0; letter-spacing: 0.2em; }\n",
        ".scene-break-line { width: 30%; height: 0; margin: 1.2em auto; border-top: 1px solid; font-size: 0; line-height: 0; }\n",
        ".first-para { text-indent: 0; }\n",
        ".first-char { font-size: 1.6em; font-weight: bold; line-height: 1; }\n",
        ".chapter-head-image { margin: 0 0 0.8em; text-indent: 0; text-align: center; }\n",
        ".chapter-head-third img { width: 33%; height: auto; }\n",
        ".chapter-head-half img { width: 50%; height: auto; }\n",
        ".chapter-head-full img { width: 100%; height: auto; }\n",
        ".full-page-image { margin: 0; text-indent: 0; text-align: center; break-before: page; page-break-before: always; break-after: page; page-break-after: always; }\n",
        ".full-page-image img { width: 100%; height: auto; }\n",
        ".system-block { margin: 0.8em 0; padding: 0.4em 0.8em; border: 1px solid; }\n",
        ".system-block-indent { margin: 0.8em 2em; padding: 0; border: 0; }\n",
        ".verse-block { margin: 0.8em 0; text-align: center; }\n",
        ".verse-block-indent { margin: 0.8em 0 0.8em 2em; text-align: start; }\n",
        ".system-line, .verse-line, .verse-by { text-indent: 0; margin: 0; }\n",
        ".verse-block .verse-by { text-align: right; }\n",
    ));
    if inline_styles {
        css.push_str(INLINE_WAVY_RULE);
        css.push_str(".inline-bold { font-weight: bold; }\n.inline-italic { font-style: italic; }\n.inline-underline { text-decoration: underline; }\n.inline-kai { font-family: STKai, \"楷体\", KaiTi, serif; }\n.inline-fang-song { font-family: STFangsong, \"仿宋\", FangSong, serif; }\n");
    }
    if settings.note_style == "popup" || notes {
        // 亚马逊示例使用 sup > a；显式相对字号补齐 Bokai 缺少的 sup 默认缩小。
        // 0.75em 与本机 Previewer 3.107.0 的 sup 读回一致，不是规范固定值。
        css.push_str(".note-ref { font-size: 0.75em; vertical-align: super; line-height: 0; }\n.footnote { margin: 1em 0; }\n.footnote p { text-indent: 0; }\n");
    }
    css.push_str(heading_rules(&settings.heading_style));
    // 系统提示分类样式。
    if settings.system_block_style == "styled" {
        css.push_str(
            &settings
                .system_styles
                .clone()
                .unwrap_or_else(crate::block_styles::default_styles)
                .css(),
        );
    }
    // 场景样式：用到时才写入，旧书的样式表不变。
    if crate::insets::used(settings) {
        let paper = crate::insets::image_needs(settings)
            .1
            .then(|| crate::insets::image_id(&crate::insets::paper_png()));
        css.push_str(&crate::inset_styles::css(
            settings.inset_styles.as_ref(),
            &settings.chat_block_style,
            paper.as_deref(),
            settings.inset_font == "kai",
        ));
    }
    // 章节样式包：标题下装饰线、章末装饰、卷页边框。
    if let Some(style) = &settings.chapter_style {
        if style.title_rule.is_some() {
            css.push_str(".title-rule { margin: -0.4em 0 1em; text-indent: 0; text-align: center; }\n.title-rule img { width: 40%; height: auto; }\n");
        }
        if style.chapter_end.is_some() {
            css.push_str(".chapter-end { margin: 1.5em 0 0; text-indent: 0; text-align: center; }\n.chapter-end img { width: 16%; height: auto; }\n");
        }
        match style.volume_frame.as_str() {
            // 两侧外边距由 15% 收窄到 5%，卷名稍长（如“第一卷　远行”）时不再被拆成两行。
            "single" => css.push_str(
                ".volume-heading { border: 1px solid; padding: 1em 0.4em; margin: 2em 5%; }\n",
            ),
            "double" => css.push_str(
                ".volume-heading { border: 3px double; padding: 1em 0.4em; margin: 2em 5%; }\n",
            ),
            _ => {}
        }
    }
    if !settings.supplemental_pages.is_empty() {
        css.push_str(concat!(
            ".supplement-title { text-align: center; text-indent: 0; font-size: 1.5em; margin: 1em 0; }\n",
            ".supplement-compact { font-size: 0.9em; }\n",
            ".supplement-compact p { text-align: center; text-indent: 0; }\n",
        ));
    }
    if settings.block_annotations.iter().any(|a| {
        matches!(
            a.kind,
            crate::block_annotations::Kind::Letter | crate::block_annotations::Kind::Quote
        )
    }) {
        css.push_str(concat!(
            ".letter-block, .quote-block { margin: 0.8em 2em; }\n",
            ".quote-block { font-size: 0.95em; }\n",
            ".letter-line, .letter-by, .quote-line { text-indent: 0; margin: 0; }\n",
            ".letter-block .letter-by { text-align: right; }\n",
        ));
    }
    if settings.writing_mode == "vertical" {
        css.push_str(VERTICAL_RULES);
    }
    let custom_offset = css.len();
    if !settings.additional_css.is_empty() {
        css.push_str("/* User additional CSS */\n");
        css.push_str(&settings.additional_css);
        css.push('\n');
    }
    let references = crate::css_references::inspect(&settings.additional_css);
    let resolutions = references
        .references
        .iter()
        .map(|value| crate::css_references::resolve(value, &settings.additional_css_base))
        .collect();
    Ok(Stylesheet {
        id: format!("{:x}.css", Sha256::digest(css.as_bytes())),
        media_type: "text/css",
        css,
        font_embedded: false,
        additional_css_references: references,
        additional_css_resolutions: resolutions,
        custom_offset,
    })
}
/// Publication XHTML links the independent user stylesheet after this base.
/// Must run before bind_font, whose generated rules belong to the base.
pub fn separate_additional(mut style: Stylesheet) -> Stylesheet {
    style.css.truncate(style.custom_offset);
    style.id = format!("{:x}.css", Sha256::digest(style.css.as_bytes()));
    style
}
/// CSS and fonts share the publication resource directory. Accept only content IDs.
pub fn bind_font(mut style: Stylesheet, id: &str) -> Result<Stylesheet, ApiError> {
    let valid = id
        .strip_suffix(".ttf")
        .or_else(|| id.strip_suffix(".otf"))
        .is_some_and(|hash| {
            hash.len() == 64
                && hash
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        });
    if !valid {
        return Err(ApiError::new(
            easypub_core::ErrorCode::InvalidRule,
            "font_resource",
            "review_font_resource",
        ));
    }
    style.css.insert_str(style.custom_offset, &format!("@font-face {{ font-family: \"EasyPubEmbedded\"; src: url(\"{id}\"); }}\nbody {{ font-family: \"EasyPubEmbedded\", serif; }}\n"));
    style.id = format!("{:x}.css", Sha256::digest(style.css.as_bytes()));
    style.font_embedded = true;
    Ok(style)
}
#[cfg(test)]
mod tests {
    use super::*;
    fn settings() -> Settings {
        serde_json::from_value(
            serde_json::json!({"title":"甲","author":"乙","description":"",
            "cover_path":null,"cover_fit":"contain","font_family":"SimSun","font_size":20.0,
            "line_height":2.0,"include_toc":true,"illustrations":[]}),
        )
        .unwrap()
    }
    #[test]
    fn units_roundtrip_and_export_preserve_relative_semantics() {
        let mut s = settings();
        s.layout_units_version = 1;
        s.font_size = 12.0;
        s.font_size_unit = "pt".into();
        s.line_height = 120.0;
        s.line_height_unit = "%".into();
        s.paragraph_indent = 5.0;
        s.paragraph_indent_unit = "%".into();
        s.paragraph_spacing = 6.0;
        s.paragraph_spacing_unit = "pt".into();
        s.margin_top = 5.0;
        s.margin_top_unit = "%".into();
        s.margin_right = 2.0;
        s.margin_right_unit = "em".into();
        let encoded = serde_json::to_value(&s).unwrap();
        let decoded: Settings = serde_json::from_value(encoded).unwrap();
        let a = prepare(&decoded).unwrap().css;
        assert!(a.contains("font-size: 16px; line-height: 120%;"));
        assert!(a.contains("p { margin: 0 0 8px; text-indent: 5%; }"));
        assert!(a.contains("@page { margin: 5% 2em"));
        s.font_size = 16.0;
        s.font_size_unit = "px".into();
        assert_eq!(a, prepare(&s).unwrap().css);
        s.line_height = 1.2;
        s.line_height_unit = "number".into();
        assert!(prepare(&s).unwrap().css.contains("line-height: 1.2;"));
    }
    #[test]
    fn fixed_pixel_margins_do_not_scale_with_body_font() {
        let mut s = settings();
        s.margin_top = 3.0;
        s.margin_top_unit = "px".into();
        s.margin_right = 1.0;
        s.margin_bottom = 120.0;
        s.margin_bottom_unit = "px".into();
        s.margin_left = 0.5;
        assert!(
            prepare(&s)
                .unwrap()
                .css
                .contains("@page { margin: 3px 20px 120px 10px; }")
        );
        s.font_size = 26.0;
        assert!(
            prepare(&s)
                .unwrap()
                .css
                .contains("@page { margin: 3px 26px 120px 13px; }")
        );
        s.margin_bottom_unit = "em".into();
        assert!(prepare(&s).is_err());
        s.margin_bottom_unit = "unknown".into();
        assert!(prepare(&s).is_err());
    }

    #[test]
    fn alignment_and_semantic_templates_are_deterministic() {
        let mut s = settings();
        let base = prepare(&s).unwrap();
        for alignment in ["start", "left", "right", "center", "justify"] {
            s.text_alignment = alignment.into();
            let css = prepare(&s).unwrap();
            assert!(
                css.css
                    .contains(&format!("p {{ text-align: {alignment}; }}"))
            );
            for class in [
                ".title-page",
                ".book-translator",
                ".volume-heading",
                ".chapter-heading",
                ".section-heading",
                ".toc ol",
                ".chapter-navigation",
                ".scene-break",
            ] {
                assert!(css.css.contains(class));
            }
            if alignment != "start" {
                assert_ne!(css.id, base.id);
            }
        }
        s.text_alignment = "justify; color:red".into();
        assert!(prepare(&s).is_err());
    }
    #[test]
    fn heading_styles_follow_setting_and_change_identity() {
        let mut s = settings();
        assert_eq!(s.heading_style, "classic");
        let mut ids = std::collections::BTreeSet::new();
        for style in crate::production::HEADING_STYLES {
            s.heading_style = style.into();
            let css = prepare(&s).unwrap();
            assert!(css.css.contains(heading_rules(style)));
            assert!(css.css.contains(".chapter-heading, .front-heading {"));
            assert_eq!(css.css.matches(".chapter-heading").count(), 1);
            ids.insert(css.id);
        }
        assert_eq!(ids.len(), 5);
        assert!(CLASSIC_HEADING.contains(CLASSIC_SHADOW));
        for part in [
            "font-size: x-large",
            "text-align: center",
            "border-bottom: 1px dotted #c1ccc0",
            "margin: 0 0 1.2em",
        ] {
            assert!(heading_rules("classic").contains(part));
        }
        assert!(heading_rules("two_line").contains(".chapter-label { font-size: 0.7em; }"));
        s.heading_style = "fancy".into();
        assert!(prepare(&s).is_err());
    }
    #[test]
    fn custom_css_follows_generated_font_and_changes_identity() {
        let mut s = settings();
        let base = prepare(&s).unwrap();
        s.additional_css = "/* 中文 */\np { color: #123; }\nbody { font-family: serif; }".into();
        let custom = prepare(&s).unwrap();
        assert_ne!(custom.id, base.id);
        assert!(custom.css.ends_with(&format!("{}\n", s.additional_css)));
        let bound = bind_font(custom, &format!("{}.ttf", "a".repeat(64))).unwrap();
        assert!(bound.css.ends_with(&format!("{}\n", s.additional_css)));
        assert!(
            bound.css.find("@font-face").unwrap()
                < bound.css.find("/* User additional CSS */").unwrap()
        );
        assert_eq!(
            bound.id,
            format!("{:x}.css", Sha256::digest(bound.css.as_bytes()))
        );
        s.additional_css = "中".repeat(87382);
        assert!(prepare(&s).is_err());
        s.additional_css = "\0".into();
        assert!(prepare(&s).is_err());
    }
    #[test]
    fn parameters_change_css_identity_but_metadata_does_not() {
        let mut s = settings();
        let base = prepare(&s).unwrap();
        assert!(base.css.contains("font-size: 20px; line-height: 2;"));
        assert!(base.css.contains("\"SimSun\", serif"));
        // 封面适配方式不再写进样式，由封面页的 preserveAspectRatio 承担。
        assert!(!base.css.contains("object-fit"));
        assert!(base.css.contains(COVER_SVG_RULE));
        assert!(!base.font_embedded);
        s.title = "改书名".into();
        assert_eq!(prepare(&s).unwrap().id, base.id);
        s.font_size = 22.0;
        assert_ne!(prepare(&s).unwrap().id, base.id);
        s = settings();
        s.line_height = 1.5;
        assert_ne!(prepare(&s).unwrap().id, base.id);
        // 封面适配方式只影响封面页，不再改变样式表；成品身份仍随整个清单变化。
        s = settings();
        s.cover_fit = "fill".into();
        assert_eq!(prepare(&s).unwrap().id, base.id);
    }
    #[test]
    fn reject_nonfinite_numbers_and_arbitrary_css_values() {
        let mut s = settings();
        s.font_size = f64::NAN;
        assert!(prepare(&s).is_err());
        s = settings();
        s.line_height = f64::INFINITY;
        assert!(prepare(&s).is_err());
        s = settings();
        s.font_family = "x\";color:red".into();
        assert!(prepare(&s).is_err());
        s = settings();
        s.cover_fit = "contain;display:none".into();
        assert!(prepare(&s).is_err());
    }
}
