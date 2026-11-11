//! 保持原格式时改原书样式：去除原书字体、去除指定样式、附加 CSS 和页边距。
//!
//! 原 EPUB 不变，只改生成的成品。CSS 按语句扫描，不重新排版，没动到的部分逐字节保留。
use regex::{Captures, Regex};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::sync::LazyLock;

/// 新增样式文件的名字，放在 OPF 同一层。
pub const EXTRA_CSS_FILE: &str = "easypub-original-style.css";

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct OriginalStyle {
    /// 删掉书里的字体文件和 @font-face。
    pub remove_fonts: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub remove_first_image: bool,
    /// 要去掉的 CSS 属性。`background` 同时去掉 `background-color` 这些。
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub filter_css: Vec<String>,
    /// 接在原书样式最后。
    #[serde(skip_serializing_if = "String::is_empty")]
    pub extra_css: String,
    /// 页边距，空着不改。写法如 `1em`、`12px`、`5%`。
    #[serde(skip_serializing_if = "String::is_empty")]
    pub margin_top: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub margin_right: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub margin_bottom: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub margin_left: String,
}

static PROPERTY: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^-?[a-z][a-z-]{0,39}$").unwrap());
static LENGTH: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\d{1,3}(\.\d{1,2})?(em|px|pt|%)$").unwrap());
static STYLE_BLOCK: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?is)(<style\b[^>]*>)(.*?)(</style\s*>)").unwrap());
static STYLE_ATTRIBUTE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"(?i)(<[a-z][^<>]*?)\sstyle\s*=\s*(?:"([^"]*)"|'([^']*)')"#).unwrap()
});
static HEAD_CLOSE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)</head\s*>").unwrap());

impl OriginalStyle {
    pub fn is_default(&self) -> bool {
        *self == Self::default()
    }

    /// 附加 CSS 只有一个文件，不能再引用别的文件：成品里没有它们。
    pub fn valid(&self) -> bool {
        let lower = self.extra_css.to_ascii_lowercase();
        self.filter_css.len() <= 32
            && self.filter_css.iter().all(|p| PROPERTY.is_match(p))
            && self.extra_css.len() <= 262_144
            && !self.extra_css.contains('\0')
            && !lower.contains("url(")
            && !lower.contains("@import")
            && [
                &self.margin_top,
                &self.margin_right,
                &self.margin_bottom,
                &self.margin_left,
            ]
            .iter()
            .all(|m| m.is_empty() || LENGTH.is_match(m))
    }

    /// 要新增的样式；什么都没有时为空。
    pub fn extra_sheet(&self) -> String {
        let margins = [
            ("margin-top", &self.margin_top),
            ("margin-right", &self.margin_right),
            ("margin-bottom", &self.margin_bottom),
            ("margin-left", &self.margin_left),
        ]
        .iter()
        .filter(|(_, v)| !v.is_empty())
        .map(|(k, v)| format!("{k}: {v} !important;"))
        .collect::<Vec<_>>();
        let mut sheet = String::new();
        if !margins.is_empty() {
            sheet.push_str(&format!("body {{ {} }}\n", margins.join(" ")));
        }
        if !self.extra_css.trim().is_empty() {
            sheet.push_str(&self.extra_css);
            sheet.push('\n');
        }
        sheet
    }
}

/// 语句的结束位置和结束符；走到文件末尾时结束符是 0。跳过字符串、注释和括号。
fn statement_end(bytes: &[u8], mut at: usize) -> (usize, u8) {
    let mut parens = 0usize;
    while at < bytes.len() {
        match bytes[at] {
            b'/' if bytes.get(at + 1) == Some(&b'*') => {
                at = bytes[at + 2..]
                    .windows(2)
                    .position(|w| w == b"*/")
                    .map_or(bytes.len(), |p| at + 2 + p + 2);
                continue;
            }
            quote @ (b'"' | b'\'') => {
                at += 1;
                while at < bytes.len() && bytes[at] != quote {
                    at += if bytes[at] == b'\\' { 2 } else { 1 };
                }
            }
            b'(' => parens += 1,
            b')' => parens = parens.saturating_sub(1),
            c @ (b';' | b'{' | b'}') if parens == 0 => return (at, c),
            _ => {}
        }
        at += 1;
    }
    (bytes.len(), 0)
}

fn without_comments(text: &str) -> String {
    static COMMENT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?s)/\*.*?\*/").unwrap());
    COMMENT.replace_all(text, "").into_owned()
}

/// 从块的 `{` 之后走到配对的 `}` 之后。
fn block_end(bytes: &[u8], mut at: usize) -> usize {
    let mut depth = 1usize;
    while at < bytes.len() {
        let (end, mark) = statement_end(bytes, at);
        match mark {
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    return end + 1;
                }
            }
            0 => return bytes.len(),
            _ => {}
        }
        at = end + 1;
    }
    bytes.len()
}

fn unquoted(name: &str) -> String {
    name.trim()
        .trim_matches(['"', '\''])
        .trim()
        .to_ascii_lowercase()
}

/// 删掉 @font-face，记下它们声明的字体名。
pub fn strip_font_faces(css: &str, families: &mut BTreeSet<String>) -> (String, usize) {
    let bytes = css.as_bytes();
    let mut out = String::with_capacity(css.len());
    let (mut at, mut removed) = (0, 0);
    while at < bytes.len() {
        let (end, mark) = statement_end(bytes, at);
        if mark == b'{'
            && without_comments(&css[at..end])
                .trim_start()
                .to_ascii_lowercase()
                .starts_with("@font-face")
        {
            let close = block_end(bytes, end + 1);
            let body = without_comments(&css[end + 1..close.saturating_sub(1)]);
            for part in body.split(';') {
                if let Some((key, value)) = part.split_once(':')
                    && key.trim().eq_ignore_ascii_case("font-family")
                {
                    families.insert(unquoted(value));
                }
            }
            removed += 1;
            at = close;
            continue;
        }
        let stop = if mark == 0 { bytes.len() } else { end + 1 };
        out.push_str(&css[at..stop]);
        at = stop;
    }
    (out, removed)
}

/// 去哪些属性、哪些字体名。
pub struct Filter<'a> {
    pub properties: &'a [String],
    pub families: &'a BTreeSet<String>,
}

impl Filter<'_> {
    fn has(&self, name: &str) -> bool {
        self.properties.iter().any(|p| p == name)
    }

    fn drops(&self, property: &str) -> bool {
        self.properties.iter().any(|p| {
            property == p
                || property
                    .strip_prefix(p.as_str())
                    .is_some_and(|tail| tail.starts_with('-'))
        }) || (property == "font"
            && (self.has("font-family") || self.has("font-size") || self.has("line-height")))
    }

    /// 处理一条声明。None 是整条去掉；返回原文说明没动。
    fn declaration(&self, text: &str, removed: &mut usize) -> Option<String> {
        let Some((key, value)) = text.split_once(':') else {
            return Some(text.to_owned());
        };
        let property = without_comments(key).trim().to_ascii_lowercase();
        if self.drops(&property) {
            *removed += 1;
            return None;
        }
        if property == "margin" && (self.has("margin-top") || self.has("margin-bottom")) {
            let parts = value.split_whitespace().collect::<Vec<_>>();
            let (top, right, bottom, left) = match parts.as_slice() {
                [a] => (*a, *a, *a, *a),
                [a, b] => (*a, *b, *a, *b),
                [a, b, c] => (*a, *b, *c, *b),
                [a, b, c, d] => (*a, *b, *c, *d),
                _ => return Some(text.to_owned()),
            };
            *removed += 1;
            let sides = [
                ("margin-top", top),
                ("margin-right", right),
                ("margin-bottom", bottom),
                ("margin-left", left),
            ]
            .iter()
            .filter(|(name, _)| !self.has(name))
            .map(|(name, side)| format!("{name}: {side}"))
            .collect::<Vec<_>>();
            return (!sides.is_empty()).then(|| sides.join("; "));
        }
        if property == "font-family" && !self.families.is_empty() {
            let names = value.split(',').collect::<Vec<_>>();
            let kept = names
                .iter()
                .filter(|name| !self.families.contains(&unquoted(name)))
                .copied()
                .collect::<Vec<_>>();
            if kept.len() != names.len() {
                *removed += 1;
                return (!kept.is_empty()).then(|| format!("{key}:{}", kept.join(",")));
            }
        }
        Some(text.to_owned())
    }

    /// `depth` 为 0 是样式表，为 1 是 `style` 属性里的声明。
    fn rewrite(&self, css: &str, start_depth: usize, removed: &mut usize) -> String {
        let bytes = css.as_bytes();
        let mut out = String::with_capacity(css.len());
        let (mut at, mut depth) = (0, start_depth);
        while at < bytes.len() {
            let (end, mark) = statement_end(bytes, at);
            let text = &css[at..end];
            match mark {
                b'{' => {
                    out.push_str(&css[at..=end]);
                    depth += 1;
                }
                _ if depth == 0 => {
                    out.push_str(text);
                    if mark != 0 {
                        out.push(mark as char);
                    }
                }
                _ => {
                    let before = *removed;
                    let next = if text.trim().is_empty() {
                        Some(text.to_owned())
                    } else {
                        self.declaration(text, removed)
                    };
                    if let Some(next) = next {
                        out.push_str(&next);
                        if mark == b';' {
                            out.push(';');
                        }
                    } else if *removed == before {
                        out.push_str(text);
                    }
                    if mark == b'}' {
                        out.push('}');
                        depth -= 1;
                    }
                }
            }
            if mark == 0 {
                break;
            }
            at = end + 1;
        }
        out
    }

    pub fn sheet(&self, css: &str, removed: &mut usize) -> String {
        self.rewrite(css, 0, removed)
    }

    /// 页面里的 `<style>` 和 `style` 属性。声明都去掉时属性也去掉。
    pub fn markup(&self, page: &str, removed: &mut usize) -> String {
        let count = std::cell::Cell::new(*removed);
        let blocks = STYLE_BLOCK.replace_all(page, |c: &Captures| {
            let mut n = count.get();
            let body = self.sheet(&c[2], &mut n);
            count.set(n);
            format!("{}{body}{}", &c[1], &c[3])
        });
        let attributes = STYLE_ATTRIBUTE.replace_all(&blocks, |c: &Captures| {
            let (value, quote) = match (c.get(2), c.get(3)) {
                (Some(v), _) => (v.as_str(), '"'),
                (_, Some(v)) => (v.as_str(), '\''),
                _ => return c[0].to_owned(),
            };
            let mut n = count.get();
            let next = self.rewrite(value, 1, &mut n);
            count.set(n);
            if next.trim().trim_matches(';').trim().is_empty() {
                c[1].to_owned()
            } else {
                format!("{} style={quote}{next}{quote}", &c[1])
            }
        });
        *removed = count.get();
        attributes.into_owned()
    }
}

/// 在页面的 `</head>` 前面加样式链接；没有 head 时不改。
pub fn link_sheet(page: &str, href: &str) -> Option<String> {
    let close = HEAD_CLOSE.find(page)?;
    Some(format!(
        "{}<link rel=\"stylesheet\" type=\"text/css\" href=\"{href}\"/>{}",
        &page[..close.start()],
        &page[close.start()..]
    ))
}

pub fn is_font(media: &str, href: &str) -> bool {
    let media = media.to_ascii_lowercase();
    let href = href.to_ascii_lowercase();
    media.contains("font")
        || media.contains("opentype")
        || media.contains("truetype")
        || [".ttf", ".otf", ".ttc", ".woff", ".woff2"]
            .iter()
            .any(|ext| href.ends_with(ext))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn filter<'a>(properties: &'a [String], families: &'a BTreeSet<String>) -> Filter<'a> {
        Filter {
            properties,
            families,
        }
    }

    #[test]
    fn font_faces_go_and_other_rules_stay_byte_for_byte() {
        let css = "@charset \"utf-8\";\n/* 注释 { */\n@font-face { font-family: \"Song A\"; src: url(a.ttf); }\n@FONT-FACE{font-family:B;src:url('b;}.ttf')}\np { color: red; }\n";
        let mut families = BTreeSet::new();
        let (out, removed) = strip_font_faces(css, &mut families);
        assert_eq!(removed, 2);
        assert_eq!(out, "@charset \"utf-8\";\np { color: red; }\n");
        assert_eq!(
            families.iter().map(String::as_str).collect::<Vec<_>>(),
            ["b", "song a"]
        );
    }

    #[test]
    fn filtered_properties_leave_the_rest_alone() {
        let props = vec!["color".to_owned(), "background".to_owned()];
        let none = BTreeSet::new();
        let mut removed = 0;
        let out = filter(&props, &none).sheet(
            "a{color:red;background-color:#fff;margin:0}\n@media print{b{color:blue;top:0}}",
            &mut removed,
        );
        assert_eq!(out, "a{margin:0}\n@media print{b{top:0}}");
        assert_eq!(removed, 3);
    }

    #[test]
    fn a_comment_or_string_cannot_end_a_statement_early() {
        let props = vec!["color".to_owned()];
        let none = BTreeSet::new();
        let mut removed = 0;
        let css = "a::before{content:\"color:red;}\"}/* b{color:red} */c{top:url(x;y.png)}";
        assert_eq!(filter(&props, &none).sheet(css, &mut removed), css);
        assert_eq!(removed, 0);
    }

    #[test]
    fn margin_shorthand_keeps_the_sides_not_asked_for() {
        let props = vec!["margin-top".to_owned(), "margin-bottom".to_owned()];
        let none = BTreeSet::new();
        let mut removed = 0;
        assert_eq!(
            filter(&props, &none).sheet("p{margin:1em 2em 3em}", &mut removed),
            "p{margin-right: 2em; margin-left: 2em}"
        );
    }

    #[test]
    fn removed_families_leave_font_family_lists() {
        let props = vec![];
        let families = BTreeSet::from(["song a".to_owned()]);
        let mut removed = 0;
        assert_eq!(
            filter(&props, &families).sheet(
                "a{font-family:\"Song A\",serif}b{font-family:'song a'}c{font-family:serif}",
                &mut removed
            ),
            "a{font-family:serif}b{}c{font-family:serif}"
        );
        assert_eq!(removed, 2);
    }

    #[test]
    fn pages_lose_style_blocks_and_attributes_as_asked() {
        let props = vec!["color".to_owned()];
        let none = BTreeSet::new();
        let mut removed = 0;
        let page = "<html><head><style type=\"text/css\">p{color:red;top:0}</style></head><body><p style=\"color:red\">甲 color:red</p><p class=\"x\" style='color:red;top:0'>乙</p></body></html>";
        let out = filter(&props, &none).markup(page, &mut removed);
        assert_eq!(
            out,
            "<html><head><style type=\"text/css\">p{top:0}</style></head><body><p>甲 color:red</p><p class=\"x\" style='top:0'>乙</p></body></html>"
        );
        assert_eq!(removed, 3);
    }

    #[test]
    fn settings_reject_what_the_output_cannot_carry() {
        let good = OriginalStyle {
            filter_css: vec!["font-size".into()],
            extra_css: "p { text-indent: 2em; }".into(),
            margin_top: "1.5em".into(),
            ..Default::default()
        };
        assert!(good.valid());
        assert_eq!(
            good.extra_sheet(),
            "body { margin-top: 1.5em !important; }\np { text-indent: 2em; }\n"
        );
        for bad in [
            OriginalStyle {
                extra_css: "p{background:URL(a.png)}".into(),
                ..Default::default()
            },
            OriginalStyle {
                extra_css: "@import 'a.css';".into(),
                ..Default::default()
            },
            OriginalStyle {
                margin_left: "1em;color:red".into(),
                ..Default::default()
            },
            OriginalStyle {
                filter_css: vec!["color; x".into()],
                ..Default::default()
            },
        ] {
            assert!(!bad.valid(), "{bad:?}");
        }
        assert!(OriginalStyle::default().is_default());
    }
}
