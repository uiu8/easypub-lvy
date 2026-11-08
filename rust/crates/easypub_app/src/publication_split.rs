//! Physical XHTML splits leave source paragraphs and logical node IDs intact.
//! 每卷、每章、每个前置部分从新文件开始（V36，OUT-081）：与市面成品书一致，阅读器在文件之间
//! 必然换页，不只依赖 CSS 分页规则；单章过长时再按大小在段落之间续排拆分。
use crate::publication_documents::Documents;
use easypub_core::{ApiError, ErrorCode};
use std::collections::BTreeMap;
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "publication_split",
        "review_publication_structure",
    )
}
fn filename(index: usize) -> String {
    if index == 0 {
        "body.xhtml".into()
    } else {
        format!("body-{index:04}.xhtml")
    }
}
pub(crate) fn split(documents: &mut Documents, target: usize) -> Result<(), ApiError> {
    let original = documents.pages.get("body.xhtml").ok_or_else(invalid)?;
    let xml = roxmltree::Document::parse(original).map_err(|_| invalid())?;
    let body = xml
        .descendants()
        .find(|n| n.has_tag_name("body"))
        .ok_or_else(invalid)?;
    let first = body
        .first_element_child()
        .ok_or_else(invalid)?
        .range()
        .start;
    let last = body.last_element_child().ok_or_else(invalid)?.range().end;
    let prefix = &original[..first];
    let suffix = &original[last..];
    let mut chunks = Vec::new();
    let mut current = String::new();
    for section in body.children().filter(|n| n.is_element()) {
        if !section.has_tag_name("section") {
            return Err(invalid());
        }
        if section
            .attribute("class")
            .unwrap_or("")
            .split(' ')
            .any(|c| matches!(c, "chapter-start" | "volume-start" | "front-start"))
            && !current.is_empty()
        {
            chunks.push(std::mem::take(&mut current));
        }
        let range = section.range();
        let whole = &original[range.clone()];
        if whole.len() <= target {
            if !current.is_empty() && current.len() + whole.len() > target {
                chunks.push(std::mem::take(&mut current));
            }
            current.push_str(whole);
            continue;
        }
        // A unit is one source paragraph/heading with its illustrations. Keep
        // chapter navigation attached to the heading; do not split inside text.
        let mut units = Vec::new();
        let mut unit_start = None;
        let mut unit_end = 0;
        let mut has_source = false;
        for child in section.children().filter(|n| n.is_element()) {
            let source = child.descendants().any(|n| n.attribute("data-source") == Some("true"));
            if source && has_source {
                units.push(unit_start.take().ok_or_else(invalid)?..unit_end);
                has_source = false;
            }
            unit_start.get_or_insert(child.range().start);
            unit_end = child.range().end;
            has_source |= source;
        }
        if let Some(start) = unit_start {
            units.push(start..unit_end);
        }
        let tag_end = whole.find('>').ok_or_else(invalid)? + 1;
        let first_tag = &whole[..tag_end];
        let continuation = format!(
            "<section class=\"{} content-continuation\" data-depth=\"{}\">",
            crate::navigation_documents::escaped(section.attribute("class").unwrap_or(""))?,
            section.attribute("data-depth").unwrap_or("0")
        );
        let mut part = String::new();
        let mut first_part = true;
        for unit in units {
            let text = &original[unit];
            if !part.is_empty() && part.len() + text.len() + 10 > target {
                part.push_str("</section>");
                if !current.is_empty() {
                    chunks.push(std::mem::take(&mut current));
                }
                chunks.push(std::mem::take(&mut part));
                first_part = false;
            }
            if part.is_empty() {
                part.push_str(if first_part { first_tag } else { &continuation });
            }
            part.push_str(text);
        }
        if !part.is_empty() {
            part.push_str("</section>");
            if !current.is_empty() {
                chunks.push(std::mem::take(&mut current));
            }
            current = part;
        }
    }
    if !current.is_empty() {
        chunks.push(current);
    }
    if chunks.len() <= 1 {
        return Ok(());
    }
    let mut pages = BTreeMap::new();
    let mut targets = BTreeMap::new();
    for (index, chunk) in chunks.into_iter().enumerate() {
        let name = filename(index);
        let content = format!("{prefix}{chunk}{suffix}");
        let parsed = roxmltree::Document::parse(&content).map_err(|_| invalid())?;
        for n in parsed.descendants() {
            if let Some(id) = n.attribute("id")
                && targets.insert(id.to_string(), name.clone()).is_some() {
                    return Err(invalid());
                }
        }
        pages.insert(name, content);
    }
    let position = documents
        .reading_order
        .iter()
        .position(|s| s == "body.xhtml")
        .ok_or_else(invalid)?;
    documents
        .reading_order
        .splice(position..=position, (0..pages.len()).map(filename));
    documents.pages.extend(pages);
    for content in documents.pages.values_mut() {
        let doc = roxmltree::Document::parse(content).map_err(|_| invalid())?;
        let mut edits = Vec::new();
        for node in doc.descendants() {
            for attr in node.attributes() {
                if attr.name() == "href"
                    && let Some(id) = attr.value().strip_prefix("body.xhtml#") {
                        let name = targets.get(id).ok_or_else(invalid)?;
                        edits.push((attr.range_value(), format!("{name}#{id}")));
                    }
            }
        }
        let mut result = String::with_capacity(content.len());
        let mut offset = 0;
        for (range, value) in edits {
            result.push_str(&content[offset..range.start]);
            result.push_str(&value);
            offset = range.end;
        }
        result.push_str(&content[offset..]);
        *content = result;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn every_volume_chapter_and_front_part_starts_a_new_file() {
        let html = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>样书</title></head><body>\
<section class=\"front-matter\"><p data-source=\"true\">引言</p></section>\
<section class=\"front-start\" data-depth=\"0\"><h1 id=\"node-0\" data-source=\"true\">序</h1></section>\
<section class=\"volume-start\" data-depth=\"0\"><h1 id=\"node-1\" data-source=\"true\">第一卷</h1></section>\
<section class=\"chapter-start\" data-depth=\"1\"><h2 id=\"node-2\" data-source=\"true\">第一章</h2>\
<p data-source=\"true\">甲</p></section>\
<section class=\"content-section\" data-depth=\"2\"><h3 id=\"node-3\" data-source=\"true\">一节</h3></section>\
<section class=\"chapter-start\" data-depth=\"1\"><h2 id=\"node-4\" data-source=\"true\">第二章</h2></section>\
</body></html>".to_string();
        let mut documents = Documents {
            pages: BTreeMap::from([
                ("body.xhtml".into(), html),
                (
                    "nav.xhtml".into(),
                    "<html><body><a href=\"body.xhtml#node-4\">二</a></body></html>".into(),
                ),
            ]),
            reading_order: vec!["title.xhtml".into(), "body.xhtml".into()],
        };
        split(&mut documents, 256 * 1024).unwrap();
        assert_eq!(
            documents.reading_order,
            [
                "title.xhtml",
                "body.xhtml",
                "body-0001.xhtml",
                "body-0002.xhtml",
                "body-0003.xhtml",
                "body-0004.xhtml"
            ]
        );
        let ids = |name: &str| -> Vec<String> {
            roxmltree::Document::parse(&documents.pages[name])
                .unwrap()
                .descendants()
                .filter_map(|n| n.attribute("id").map(str::to_string))
                .collect()
        };
        assert!(ids("body.xhtml").is_empty());
        assert_eq!(ids("body-0001.xhtml"), ["node-0"]);
        assert_eq!(ids("body-0002.xhtml"), ["node-1"]);
        assert_eq!(ids("body-0003.xhtml"), ["node-2", "node-3"]);
        assert_eq!(ids("body-0004.xhtml"), ["node-4"]);
        assert!(documents.pages["nav.xhtml"].contains("body-0004.xhtml#node-4"));
        // 只有一章的书仍是一个文件。
        let single = "<html><head><title>样书</title></head><body><section class=\"chapter-start\"><h2 id=\"node-0\">一</h2></section></body></html>";
        let mut documents = Documents {
            pages: BTreeMap::from([("body.xhtml".into(), single.into())]),
            reading_order: vec!["body.xhtml".into()],
        };
        split(&mut documents, 256 * 1024).unwrap();
        assert_eq!(documents.reading_order, ["body.xhtml"]);
        assert_eq!(documents.pages["body.xhtml"], single);
    }
    #[test]
    fn split_preserves_paragraphs_illustrations_and_rewrites_cross_file_links() {
        let long = "中文😀<&>".repeat(100);
        let escaped = crate::navigation_documents::escaped(&long).unwrap();
        let html = format!(
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>样书</title></head><body><section class=\"chapter-start\" data-depth=\"1\"><nav><a href=\"body.xhtml#node-1\">下一章</a></nav><h2 id=\"node-0\" data-source=\"true\">标题甲</h2><p data-source=\"true\">{escaped}</p><figure><img src=\"sample.png\"/><figcaption>图注</figcaption></figure><p data-source=\"true\">后文</p></section><section class=\"chapter-start\" data-depth=\"1\"><nav><a href=\"body.xhtml#node-0\">上一章</a></nav><h2 id=\"node-1\" data-source=\"true\">标题乙</h2><p data-source=\"true\">尾文</p></section></body></html>"
        );
        let mut documents = Documents {pages: BTreeMap::from([
            ("body.xhtml".into(), html),
            ("nav.xhtml".into(), "<html><body><a href=\"body.xhtml#node-0\">甲</a><a href=\"body.xhtml#node-1\">乙</a></body></html>".into())
        ]), reading_order:vec!["body.xhtml".into()]};
        split(&mut documents, 350).unwrap();
        assert!(documents.reading_order.len() >= 3);
        let mut sources = Vec::new();
        let mut anchors = BTreeMap::new();
        for name in &documents.reading_order {
            let doc = roxmltree::Document::parse(&documents.pages[name]).unwrap();
            for node in doc.descendants() {
                if let Some(id) = node.attribute("id") {
                    assert!(anchors.insert(id.to_string(), name.clone()).is_none());
                }
                if node.attribute("data-source") == Some("true") {
                    sources.push(node.text().unwrap_or("").to_string());
                }
                if node.has_tag_name("figure") {
                    assert_eq!(
                        node.prev_sibling_element().unwrap().text(),
                        Some(long.as_str())
                    );
                }
                if node.has_tag_name("nav") {
                    assert!(node.next_sibling_element().unwrap().has_tag_name("h2"));
                }
                if node
                    .attribute("class")
                    .is_some_and(|c| c.contains("content-continuation"))
                {
                    assert!(node.attribute("class").unwrap().contains("chapter-start"));
                    assert_eq!(node.attribute("data-depth"), Some("1"));
                }
            }
        }
        assert_eq!(
            sources,
            [
                "标题甲".to_string(),
                long,
                "后文".into(),
                "标题乙".into(),
                "尾文".into()
            ]
        );
        for content in documents.pages.values() {
            let doc = roxmltree::Document::parse(content).unwrap();
            for a in doc.descendants().filter(|n| n.has_tag_name("a")) {
                let (name, id) = a.attribute("href").unwrap().split_once('#').unwrap();
                assert_eq!(anchors[id], name);
            }
        }
        assert_ne!(anchors["node-1"], "body.xhtml");
    }
}
