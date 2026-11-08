//! Standalone XHTML navigation proof from final text. This is not an EPUB export.
use crate::publication_navigation::Navigation;
use easypub_core::{ApiError, ErrorCode, publication::EffectiveBook};
use std::collections::BTreeMap;

const MAX_BYTES: usize = 64 * 1024 * 1024;
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "navigation_documents",
        "review_final_structure_and_xml_text",
    )
}
pub(crate) fn escaped(text: &str) -> Result<String, ApiError> {
    let mut out = String::new();
    for c in text.chars() {
        if !matches!(c, '\t' | '\n' | '\r' | '\u{20}'..='\u{D7FF}' | '\u{E000}'..='\u{FFFD}' | '\u{10000}'..='\u{10FFFF}')
        {
            return Err(invalid());
        }
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            _ => out.push(c),
        }
        if out.len() > MAX_BYTES {
            return Err(invalid());
        }
    }
    Ok(out)
}
fn page(title: &str, body: &str) -> Result<String, ApiError> {
    Ok(format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>{}</title></head><body>{body}</body></html>",
        escaped(title)?
    ))
}
pub(crate) fn supplement(item: &crate::supplemental_pages::Page) -> Result<String, ApiError> {
    page(item.content.label(), &crate::supplemental_pages::body(item)?)
}
fn link(target: &str, label: &str) -> Result<String, ApiError> {
    Ok(format!(
        "<a href=\"{}\">{}</a>",
        escaped(target)?,
        escaped(label)?
    ))
}

/// Generates real targets and links together. Only final text and navigation are
/// included; fonts, illustrations, metadata pages and packaging belong elsewhere.
pub fn prepare(
    book: &EffectiveBook,
    navigation: &Navigation,
) -> Result<BTreeMap<String, String>, ApiError> {
    prepare_inner(book, navigation, true)
}
pub(crate) fn contents(
    book: &EffectiveBook,
    navigation: &Navigation,
) -> Result<BTreeMap<String, String>, ApiError> {
    prepare_inner(book, navigation, false)
}
fn prepare_inner(
    book: &EffectiveBook,
    navigation: &Navigation,
    include_body: bool,
) -> Result<BTreeMap<String, String>, ApiError> {
    if (include_body && book.text.len() > MAX_BYTES / 6) || book.tree.nodes.len() > 30000 {
        return Err(invalid());
    }
    let mut files = BTreeMap::new();
    let mut targets = BTreeMap::new();
    for (i, node) in book.tree.nodes.iter().enumerate() {
        if targets
            .insert(node.entry_id.as_str(), format!("body.xhtml#node-{i}"))
            .is_some()
        {
            return Err(invalid());
        }
    }
    for entry in &navigation.entries {
        if let Some(document) = &entry.document
            && targets.insert(&entry.entry_id, document.clone()).is_some() {
            return Err(invalid());
        }
    }
    let target = |id: &str| targets.get(id).ok_or_else(invalid);
    let mut toc = String::from("<nav epub:type=\"toc\" id=\"toc\" class=\"toc\"><h1>目录</h1>");
    let mut previous_depth = 0;
    for (index, entry) in navigation.entries.iter().enumerate() {
        let depth = usize::from(entry.depth);
        if (index == 0 && depth != 0) || depth > previous_depth + 1 {
            return Err(invalid());
        }
        if index == 0 || depth > previous_depth {
            toc.push_str("<ol><li>");
        } else {
            toc.push_str("</li>");
            for _ in depth..previous_depth {
                toc.push_str("</ol></li>");
            }
            toc.push_str("<li>");
        }
        toc.push_str(&link(target(&entry.entry_id)?, &entry.title)?);
        previous_depth = depth;
    }
    if !navigation.entries.is_empty() {
        toc.push_str("</li>");
        for _ in 0..previous_depth {
            toc.push_str("</ol></li>");
        }
        toc.push_str("</ol>");
    } else {
        toc.push_str("<ol><li><a href=\"body.xhtml\">正文</a></li></ol>");
    }
    toc.push_str("</nav>");
    if navigation.machine_toc {
        files.insert("nav.xhtml".into(), page("目录", &toc)?);
    }
    if navigation.visible_toc {
        // The reading-order TOC is a visible document. Keep EPUB navigation
        // semantics on nav.xhtml; Kindle's HTML reconstruction drops namespace
        // declarations while retaining epub:type on spine content.
        let visible = toc.replacen("epub:type=\"toc\"", "role=\"doc-toc\"", 1);
        files.insert("toc.xhtml".into(), page("目录", &visible)?);
    }
    if !include_body {
        if files.values().map(String::len).sum::<usize>() > MAX_BYTES {
            return Err(invalid());
        }
        return Ok(files);
    }
    let chapters: BTreeMap<_, _> = navigation
        .chapters
        .iter()
        .map(|c| (c.entry_id.as_str(), c))
        .collect();
    let mut body = String::new();
    let mut offset = 0;
    // A single exact text stream with anchors inserted at validated UTF-8 node
    // boundaries. Pre-wrap retains blank lines and indentation without guessing
    // paragraph boundaries. Production paragraph pagination is not claimed here.
    body.push_str("<div style=\"white-space:pre-wrap\">");
    for (i, node) in book.tree.nodes.iter().enumerate() {
        let segment = book.text.get(offset..node.start).ok_or_else(invalid)?;
        body.push_str(&escaped(segment)?);
        body.push_str(&format!("<span id=\"node-{i}\"></span>"));
        if let Some(chapter) = chapters.get(node.entry_id.as_str()) {
            body.push_str("<nav class=\"chapter-navigation\">");
            if let Some(id) = &chapter.previous {
                body.push_str(&link(target(id)?, "上一章")?);
            }
            if let Some(contents) = chapter.contents {
                let name = match contents {
                    "visible_toc" if navigation.visible_toc => "toc.xhtml#toc",
                    "machine_toc" if navigation.machine_toc => "nav.xhtml#toc",
                    _ => return Err(invalid()),
                };
                body.push_str(&link(name, "目录")?);
            }
            if let Some(id) = &chapter.next {
                body.push_str(&link(target(id)?, "下一章")?);
            }
            body.push_str("</nav>");
        }
        offset = node.start;
        if body.len() > MAX_BYTES {
            return Err(invalid());
        }
    }
    body.push_str(&escaped(book.text.get(offset..).ok_or_else(invalid)?)?);
    body.push_str("</div>");
    files.insert("body.xhtml".into(), page("正文导航验证", &body)?);
    if files.values().map(String::len).sum::<usize>() > MAX_BYTES {
        return Err(invalid());
    }
    Ok(files)
}

#[cfg(test)]
mod tests {
    use super::*;
    use easypub_core::{
        publication,
        source::{RULE_ID, SourceSnapshot},
        structure::Structure,
    };
    use scraper::{Html, Selector};
    #[test]
    fn generated_links_resolve_and_text_is_not_interpreted_as_markup() {
        let text = "卷前说明 <script> & \"引用\"\r\n第一卷 起点\r\n第一章 相同\n正文<&>\n第二章 相同\n结束";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let book = publication::compose(&source, &Structure::new(&source), None).unwrap();
        for machine in [false, true] {
            for visible in [false, true] {
                for top in [false, true] {
                    let nav =
                        crate::publication_navigation::prepare(&book.tree, machine, visible, top);
                    let files = prepare(&book, &nav).unwrap();
                    let mut count = 0;
                    for html in files.values() {
                        let parsed = Html::parse_document(html);
                        assert_eq!(
                            parsed.select(&Selector::parse("script").unwrap()).count(),
                            0
                        );
                        for anchor in parsed.select(&Selector::parse("a[href]").unwrap()) {
                            let (file, id) = anchor
                                .value()
                                .attr("href")
                                .unwrap()
                                .split_once('#')
                                .unwrap();
                            let destination = Html::parse_document(files.get(file).unwrap());
                            assert_eq!(
                                destination
                                    .select(&Selector::parse(&format!("[id='{id}']")).unwrap())
                                    .count(),
                                1
                            );
                            count += 1;
                        }
                    }
                    assert_eq!(files.contains_key("toc.xhtml"), visible);
                    assert_eq!(files.contains_key("nav.xhtml"), machine);
                    if visible {
                        assert!(files["toc.xhtml"].contains("role=\"doc-toc\""));
                        assert!(!files["toc.xhtml"].contains("epub:type="));
                    }
                    if machine {
                        assert!(files["nav.xhtml"].contains("epub:type=\"toc\""));
                    }
                    if machine || visible || top {
                        assert!(count > 0);
                    }
                    assert!(files["body.xhtml"].contains("&lt;script&gt; &amp; &quot;引用&quot;"));
                }
            }
        }
    }
    #[test]
    fn invalid_xml_characters_are_rejected_not_silently_deleted() {
        assert!(escaped("合法中文\u{1}正文").is_err());
        assert_eq!(escaped("😀 & < >").unwrap(), "😀 &amp; &lt; &gt;");
    }
}
