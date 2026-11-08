use easypub_core::{ApiError, ErrorCode};
use serde::{Deserialize, Serialize};

fn is_false(value: &bool) -> bool {
    !*value
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct NavigationOptions {
    #[serde(skip_serializing_if = "is_false")]
    pub apply_to_original: bool,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub original_start: String,
    pub toc_title: String,
    pub toc_position: String,
    pub toc_filter: String,
    pub filter_regex: bool,
    pub start: String,
    pub start_chapter: String,
}
impl Default for NavigationOptions {
    fn default() -> Self {
        Self {
            apply_to_original: false,
            original_start: String::new(),
            toc_title: "目录".into(),
            toc_position: "front".into(),
            toc_filter: String::new(),
            filter_regex: false,
            start: "chapter".into(),
            start_chapter: String::new(),
        }
    }
}
impl NavigationOptions {
    pub fn is_default(&self) -> bool {
        self == &Self::default()
    }
    pub fn valid(&self) -> bool {
        matches!(self.toc_position.as_str(), "front" | "back")
            && matches!(
                self.start.as_str(),
                "cover" | "toc" | "chapter" | "specific"
            )
            && !self.toc_title.trim().is_empty()
            && self.toc_title.len() <= 600
            && crate::navigation_documents::escaped(&self.toc_title).is_ok()
            && self.toc_filter.len() <= 2000
            && (!self.filter_regex || regex::Regex::new(&self.toc_filter).is_ok())
    }
    pub fn excludes(&self, title: &str) -> bool {
        if self.toc_filter.is_empty() {
            return false;
        }
        if self.filter_regex {
            regex::Regex::new(&self.toc_filter).is_ok_and(|r| r.is_match(title))
        } else {
            title.contains(&self.toc_filter)
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct OutputOptions {
    pub document_type: String,
    pub epub_version: u8,
    pub txt_encoding: String,
    pub txt_newline: String,
}
impl Default for OutputOptions {
    fn default() -> Self {
        Self {
            document_type: "default".into(),
            epub_version: 3,
            txt_encoding: "utf-8".into(),
            txt_newline: "preserve".into(),
        }
    }
}
impl OutputOptions {
    pub fn is_default(&self) -> bool {
        self == &Self::default()
    }
    pub fn valid(&self) -> bool {
        matches!(self.document_type.as_str(), "default" | "EBOK" | "PDOC")
            && [2, 3].contains(&self.epub_version)
            && matches!(self.txt_encoding.as_str(), "utf-8" | "gbk" | "big5")
            && matches!(self.txt_newline.as_str(), "preserve" | "windows" | "system")
    }
    pub fn text(&self, text: String) -> Result<Vec<u8>, ApiError> {
        let text = if self.txt_newline == "preserve" {
            text
        } else {
            let lf = text.replace("\r\n", "\n").replace('\r', "\n");
            if self.txt_newline == "windows" || cfg!(windows) {
                lf.replace('\n', "\r\n")
            } else {
                lf
            }
        };
        if self.txt_encoding == "utf-8" {
            return Ok(text.into_bytes());
        }
        let encoder = if self.txt_encoding == "gbk" {
            encoding_rs::GBK
        } else {
            encoding_rs::BIG5
        };
        let (bytes, _, errors) = encoder.encode(&text);
        if errors {
            return Err(ApiError::new(
                ErrorCode::InvalidRule,
                "txt_output",
                "characters_not_representable_choose_utf8",
            ));
        }
        Ok(bytes.into_owned())
    }
}

/// EPUB 2 readers lack HTML5 semantic containers; preserve content and classes.
pub(crate) fn epub2_page(page: &str) -> String {
    let tags = regex::Regex::new(
        r"(?i)<(/?)(?:nav|section|article|aside|header|footer|main|figure|figcaption)([\s>])",
    )
    .unwrap();
    let page = tags.replace_all(page, "<${1}div${2}");
    let attrs = regex::Regex::new(
        r#"\s+(?:epub:type|epub:prefix|role|aria-[\w-]+|data-[\w-]+)\s*=\s*(?:"[^"]*"|'[^']*')"#,
    )
    .unwrap();
    let page = attrs.replace_all(&page, "");
    // EPUB 2 has no hidden attribute. Keep hidden navigation hidden.
    let Ok(doc) = roxmltree::Document::parse(&page) else {
        return page.into_owned();
    };
    let mut edits = Vec::new();
    for node in doc.descendants().filter(|n| n.is_element()) {
        if let Some(hidden) = node.attributes().find(|a| a.name() == "hidden") {
            if let Some(style) = node.attributes().find(|a| a.name() == "style") {
                let value = crate::navigation_documents::escaped(&format!(
                    "{};display:none",
                    style.value()
                ))
                .unwrap();
                edits.push((style.range(), format!("style=\"{value}\"")));
                edits.push((hidden.range(), String::new()));
            } else {
                edits.push((hidden.range(), "style=\"display:none\"".into()));
            }
        }
    }
    edits.sort_by_key(|(range, _)| std::cmp::Reverse(range.start));
    let mut out = page.into_owned();
    for (range, value) in edits {
        out.replace_range(range, &value);
    }
    out
}

/// Public EPUB metadata uses the version's standard sorting representation.
/// Engine input keeps its historical OPF attributes.
pub(crate) fn standard_sort_metadata(opf: &str, epub2: bool) -> Result<String, ApiError> {
    let doc = roxmltree::Document::parse(opf).map_err(|_| {
        ApiError::new(
            ErrorCode::InvalidRule,
            "epub",
            "review_publication_and_output",
        )
    })?;
    let mut edits = Vec::new();
    let mut refinements = String::new();
    for (index, node) in doc
        .descendants()
        .filter(|n| matches!(n.tag_name().name(), "title" | "creator"))
        .enumerate()
    {
        let Some(attr) = node.attributes().find(|a| a.name() == "file-as") else {
            continue;
        };
        if epub2 && node.tag_name().name() == "creator" {
            continue;
        }
        edits.push((attr.range(), String::new()));
        if !epub2 {
            let id = if let Some(id) = node.attribute("id") {
                id.to_owned()
            } else {
                let mut id = format!("easypub-sort-{index}");
                while doc
                    .descendants()
                    .any(|n| n.attribute("id") == Some(id.as_str()))
                {
                    id.push('_');
                }
                let pos = node.range().start + opf[node.range()].find('>').unwrap();
                edits.push((pos..pos, format!(" id=\"{id}\"")));
                id
            };
            let reference = format!("#{id}");
            for old in doc.descendants().filter(|n| {
                n.tag_name().name() == "meta"
                    && n.attribute("property") == Some("file-as")
                    && n.attribute("refines") == Some(reference.as_str())
            }) {
                edits.push((old.range(), String::new()));
            }
            refinements.push_str(&format!(
                "<meta refines=\"{}\" property=\"file-as\">{}</meta>",
                crate::navigation_documents::escaped(&reference)?,
                crate::navigation_documents::escaped(attr.value())?
            ));
        }
    }
    if !refinements.is_empty() {
        let node = doc
            .descendants()
            .find(|n| n.tag_name().name() == "metadata")
            .unwrap();
        let pos = node.range().start + opf[node.range()].rfind("</").unwrap();
        edits.push((pos..pos, refinements));
    }
    edits.sort_by_key(|(range, _)| std::cmp::Reverse(range.start));
    let mut out = opf.to_owned();
    for (range, value) in edits {
        out.replace_range(range, &value);
    }
    Ok(out)
}
