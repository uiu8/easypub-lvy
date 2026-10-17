//! Compatibility NCX derived from the already split EPUB navigation document.
use crate::navigation_documents::escaped;
use easypub_core::{ApiError, ErrorCode};
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "kindling_navigation",
        "review_navigation",
    )
}
pub(crate) fn prepare(nav: &str, title: &str, id: &str) -> Result<String, ApiError> {
    let doc = roxmltree::Document::parse(nav).map_err(|_| invalid())?;
    let toc = doc
        .descendants()
        .find(|n| {
            n.has_tag_name("nav")
                && n.attribute(("http://www.idpf.org/2007/ops", "type"))
                    .is_some_and(|s| s.split_whitespace().any(|s| s == "toc"))
        })
        .ok_or_else(invalid)?;
    let ol = toc
        .children()
        .find(|n| n.has_tag_name("ol"))
        .ok_or_else(invalid)?;
    let mut map = String::new();
    let mut count = 0;
    let mut maximum = 0;
    append(ol, 1, &mut count, &mut maximum, &mut map)?;
    Ok(format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\"><head><meta name=\"dtb:uid\" content=\"urn:sha256:{}\"/><meta name=\"dtb:depth\" content=\"{maximum}\"/><meta name=\"dtb:totalPageCount\" content=\"0\"/><meta name=\"dtb:maxPageNumber\" content=\"0\"/></head><docTitle><text>{}</text></docTitle><navMap>{map}</navMap></ncx>",
        escaped(id)?,
        escaped(title)?
    ))
}
fn append(
    ol: roxmltree::Node<'_, '_>,
    depth: usize,
    count: &mut usize,
    maximum: &mut usize,
    out: &mut String,
) -> Result<(), ApiError> {
    if depth > 16 {
        return Err(invalid());
    }
    *maximum = (*maximum).max(depth);
    for li in ol.children().filter(|n| n.has_tag_name("li")) {
        let a = li
            .children()
            .find(|n| n.has_tag_name("a"))
            .ok_or_else(invalid)?;
        let href = a.attribute("href").ok_or_else(invalid)?;
        let label: String = a
            .descendants()
            .filter(|n| n.is_text())
            .filter_map(|n| n.text())
            .collect();
        *count += 1;
        if *count > 30000 {
            return Err(invalid());
        }
        out.push_str(&format!("<navPoint id=\"n{count}\" playOrder=\"{count}\"><navLabel><text>{}</text></navLabel><content src=\"{}\"/>", escaped(&label)?, escaped(href)?));
        if let Some(child) = li.children().find(|n| n.has_tag_name("ol")) {
            append(child, depth + 1, count, maximum, out)?;
        }
        out.push_str("</navPoint>");
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn hierarchy_and_split_targets_are_preserved() {
        let nav = "<html xmlns:epub=\"http://www.idpf.org/2007/ops\"><nav epub:type=\"toc\"><ol><li><a href=\"body.xhtml#node-0\">卷&lt;&amp;</a><ol><li><a href=\"body-0002.xhtml#node-1\">同名</a></li></ol></li><li><a href=\"body-0003.xhtml#node-2\">同名</a></li></ol></nav></html>";
        let value = prepare(nav, "书名<&>", "abc").unwrap();
        let doc = roxmltree::Document::parse(&value).unwrap();
        let points: Vec<_> = doc
            .descendants()
            .filter(|n| n.has_tag_name("navPoint"))
            .collect();
        assert_eq!(points.len(), 3);
        assert_eq!(points[1].parent(), Some(points[0]));
        assert_eq!(points[2].attribute("playOrder"), Some("3"));
        let targets: Vec<_> = doc
            .descendants()
            .filter(|n| n.has_tag_name("content"))
            .map(|n| n.attribute("src").unwrap())
            .collect();
        assert_eq!(
            targets,
            [
                "body.xhtml#node-0",
                "body-0002.xhtml#node-1",
                "body-0003.xhtml#node-2"
            ]
        );
    }
}
