//! Rewrite navigation without reflowing the original publication's content.
use crate::{edition_options::NavigationOptions, navigation_documents::escaped};
use easypub_core::{ApiError, ErrorCode};
use roxmltree::Node;
use serde::Serialize;
use std::io::{Cursor, Read};
type Files = Vec<(String, Vec<u8>)>;
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "original_navigation",
        "review_original_navigation",
    )
}
fn text(node: Node<'_, '_>) -> String {
    node.descendants()
        .filter(|n| n.is_text())
        .filter_map(|n| n.text())
        .collect()
}
fn base(path: &str) -> &str {
    path.rsplit_once('/').map(|(b, _)| b).unwrap_or("")
}
fn uri(path: &str) -> String {
    path.replace('%', "%25")
        .replace(' ', "%20")
        .replace('#', "%23")
        .replace('?', "%3F")
}
fn resolve(dir: &str, href: &str) -> Result<String, ApiError> {
    if href.contains(':') || href.starts_with('/') {
        return Err(invalid());
    }
    let path = crate::epub_passthrough::join(dir, href).ok_or_else(invalid)?;
    Ok(format!(
        "{}{}",
        uri(&path),
        href.split_once('#')
            .map(|(_, f)| format!("#{f}"))
            .unwrap_or_default()
    ))
}
fn resolve_document(path: &str, href: &str) -> Result<String, ApiError> {
    if href.starts_with('#') {
        Ok(format!("{}{href}", uri(path)))
    } else {
        resolve(base(path), href)
    }
}
fn no_start() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "original_navigation",
        "choose_start_position",
    )
}
fn contains_body_content(files: &Files, path: &str) -> Result<bool, ApiError> {
    let text = crate::epub_xml::named_entities(file(files, path)?);
    let doc = crate::epub_xml::parse(&text).map_err(|_| invalid())?;
    Ok(doc.descendants().any(|n| {
        n.ancestors().any(|a| a.has_tag_name("body"))
            && !n.ancestors().any(|a| a.has_tag_name("nav"))
            && (matches!(
                n.tag_name().name(),
                "img" | "svg" | "audio" | "video" | "table"
            ) || (n.is_text()
                && !n.text().unwrap_or("").trim().is_empty()
                && !n.ancestors().any(|a| {
                    matches!(
                        a.tag_name().name(),
                        "a" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6"
                    )
                })))
    }))
}
fn relative(dir: &str, target: &str) -> String {
    let from: Vec<_> = dir.split('/').filter(|s| !s.is_empty()).collect();
    let encoded = uri(dir);
    let from_encoded: Vec<_> = encoded.split('/').filter(|s| !s.is_empty()).collect();
    let to: Vec<_> = target.split('/').collect();
    let same = from_encoded
        .iter()
        .zip(&to)
        .take_while(|(a, b)| a == b)
        .count();
    format!(
        "{}{}",
        "../".repeat(from.len() - same),
        to[same..].join("/")
    )
}
fn file<'a>(files: &'a Files, path: &str) -> Result<&'a str, ApiError> {
    std::str::from_utf8(&files.iter().find(|f| f.0 == path).ok_or_else(invalid)?.1)
        .map_err(|_| invalid())
}
#[derive(Clone, Serialize)]
struct Entry {
    title: String,
    href: String,
    children: Vec<Entry>,
}
fn html_entries(list: Node<'_, '_>, dir: &str, depth: usize) -> Result<Vec<Entry>, ApiError> {
    if depth > 32 {
        return Err(invalid());
    }
    let mut out = Vec::new();
    for li in list.children().filter(|n| n.has_tag_name("li")) {
        let label = li
            .children()
            .find(|n| n.has_tag_name("a") || n.has_tag_name("span"));
        let children = li
            .children()
            .find(|n| n.has_tag_name("ol"))
            .map(|n| html_entries(n, dir, depth + 1))
            .transpose()?
            .unwrap_or_default();
        if let Some(label) = label {
            if let Some(href) = label.attribute("href") {
                out.push(Entry {
                    title: text(label),
                    href: resolve_document(dir, href)?,
                    children,
                });
            } else {
                out.extend(children);
            }
        } else {
            out.extend(children);
        }
    }
    Ok(out)
}
fn ncx_entries(list: Node<'_, '_>, dir: &str, depth: usize) -> Result<Vec<Entry>, ApiError> {
    if depth > 32 {
        return Err(invalid());
    }
    list.children()
        .filter(|n| n.has_tag_name("navPoint"))
        .map(|n| {
            let title = n
                .children()
                .find(|n| n.has_tag_name("navLabel"))
                .map(text)
                .unwrap_or_default();
            let href = n
                .children()
                .find(|n| n.has_tag_name("content"))
                .and_then(|n| n.attribute("src"))
                .ok_or_else(invalid)?;
            Ok(Entry {
                title,
                href: resolve_document(dir, href)?,
                children: ncx_entries(n, dir, depth + 1)?,
            })
        })
        .collect()
}
struct Navigation {
    entries: Vec<Entry>,
    nav: Option<(String, String)>,
    ncx: Option<(String, String)>,
    cover: Option<String>,
    old_toc: Option<String>,
    uid: String,
}
fn navigation(files: &Files, opf: &str, dir: &str) -> Result<Navigation, ApiError> {
    let doc = crate::epub_xml::parse(opf).map_err(|_| invalid())?;
    let item =
        |predicate: &dyn Fn(Node<'_, '_>) -> bool| -> Result<Option<(String, String)>, ApiError> {
            doc.descendants()
                .find(|n| n.has_tag_name("item") && predicate(*n))
                .map(|n| {
                    Ok((
                        n.attribute("id").ok_or_else(invalid)?.into(),
                        crate::epub_passthrough::join(
                            dir,
                            n.attribute("href").ok_or_else(invalid)?,
                        )
                        .ok_or_else(invalid)?,
                    ))
                })
                .transpose()
        };
    let nav = item(&|n| {
        n.attribute("properties")
            .unwrap_or("")
            .split_whitespace()
            .any(|p| p == "nav")
    })?;
    let ncx = item(&|n| n.attribute("media-type") == Some("application/x-dtbncx+xml"))?;
    let guide = |kind| {
        doc.descendants()
            .find(|n| n.has_tag_name("reference") && n.attribute("type") == Some(kind))
            .and_then(|n| n.attribute("href"))
            .map(|h| resolve(dir, h))
            .transpose()
    };
    let mut cover = guide("cover")?;
    let old_toc = guide("toc")?;
    let entries = if let Some((_, path)) = &nav {
        let text = crate::epub_xml::named_entities(file(files, path)?);
        let navdoc = crate::epub_xml::parse(&text).map_err(|_| invalid())?;
        let toc = navdoc
            .descendants()
            .find(|n| {
                n.has_tag_name("nav")
                    && n.attribute(("http://www.idpf.org/2007/ops", "type"))
                        .unwrap_or("")
                        .split_whitespace()
                        .any(|t| t == "toc")
            })
            .ok_or_else(invalid)?;
        if cover.is_none() {
            cover = navdoc
                .descendants()
                .find(|n| {
                    n.has_tag_name("a")
                        && n.attribute(("http://www.idpf.org/2007/ops", "type")) == Some("cover")
                })
                .and_then(|n| n.attribute("href"))
                .map(|h| resolve_document(path, h))
                .transpose()?;
        }
        html_entries(
            toc.children()
                .find(|n| n.has_tag_name("ol"))
                .ok_or_else(invalid)?,
            path,
            0,
        )?
    } else if let Some((_, path)) = &ncx {
        let ncxdoc = crate::epub_xml::parse(file(files, path)?).map_err(|_| invalid())?;
        ncx_entries(
            ncxdoc
                .descendants()
                .find(|n| n.has_tag_name("navMap"))
                .ok_or_else(invalid)?,
            path,
            0,
        )?
    } else {
        return Err(invalid());
    };
    let unique = doc.root_element().attribute("unique-identifier");
    let uid = doc
        .descendants()
        .find(|n| n.has_tag_name("identifier") && n.attribute("id") == unique)
        .and_then(|n| n.text())
        .ok_or_else(invalid)?
        .into();
    Ok(Navigation {
        entries,
        nav,
        ncx,
        cover,
        old_toc,
        uid,
    })
}
fn flatten(entries: &[Entry], out: &mut Vec<serde_json::Value>) {
    for e in entries {
        if !out.iter().any(|v| v["id"] == e.href) {
            out.push(serde_json::json!({"id":e.href,"title":e.title}));
        }
        flatten(&e.children, out);
    }
}
pub fn inspect(path: &str) -> Result<String, ApiError> {
    let original = crate::epub_passthrough::read_original(path)?;
    let mut zip = zip::ZipArchive::new(Cursor::new(original.bytes)).map_err(|_| invalid())?;
    if zip.len() > 4096 {
        return Err(invalid());
    }
    let mut files = Vec::new();
    let mut total = 0;
    for i in 0..zip.len() {
        let mut f = zip.by_index(i).map_err(|_| invalid())?;
        total += f.size();
        if total > 512 * 1024 * 1024 {
            return Err(invalid());
        }
        let mut bytes = Vec::new();
        f.read_to_end(&mut bytes).map_err(|_| invalid())?;
        files.push((f.name().into(), bytes));
    }
    let container =
        crate::epub_xml::parse(file(&files, "META-INF/container.xml")?).map_err(|_| invalid())?;
    let path = container
        .descendants()
        .find(|n| n.has_tag_name("rootfile"))
        .and_then(|n| n.attribute("full-path"))
        .ok_or_else(invalid)?;
    let nav = navigation(&files, file(&files, path)?, base(path))?;
    let mut entries = Vec::new();
    flatten(&nav.entries, &mut entries);
    Ok(serde_json::json!({"entries":entries,"has_cover":nav.cover.is_some()}).to_string())
}
fn filtered(entries: &[Entry], options: &NavigationOptions) -> Vec<Entry> {
    let mut out = Vec::new();
    for e in entries {
        let children = filtered(&e.children, options);
        if options.excludes(&e.title) {
            out.extend(children)
        } else {
            out.push(Entry {
                title: e.title.clone(),
                href: e.href.clone(),
                children,
            });
        }
    }
    out
}
fn list(entries: &[Entry], dir: &str) -> Result<String, ApiError> {
    let mut out = String::from("<ol>");
    for e in entries {
        out.push_str(&format!(
            "<li><a href=\"{}\">{}</a>",
            escaped(&relative(dir, &e.href))?,
            escaped(&e.title)?
        ));
        if !e.children.is_empty() {
            out.push_str(&list(&e.children, dir)?);
        }
        out.push_str("</li>");
    }
    out.push_str("</ol>");
    Ok(out)
}
fn page(
    entries: &[Entry],
    dir: &str,
    title: &str,
    start: &str,
    cover: Option<&str>,
    own: &str,
) -> Result<String, ApiError> {
    let cover = cover
        .map(|c| {
            Ok::<_, ApiError>(format!(
                "<li><a epub:type=\"cover\" href=\"{}\">封面</a></li>",
                escaped(&relative(dir, c))?
            ))
        })
        .transpose()?
        .unwrap_or_default();
    Ok(format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>{0}</title></head><body><nav epub:type=\"toc\" id=\"toc\"><h1>{0}</h1>{1}</nav><nav epub:type=\"landmarks\" hidden=\"hidden\"><h2>阅读位置</h2><ol>{cover}<li><a epub:type=\"toc\" href=\"{2}\">{0}</a></li><li><a epub:type=\"bodymatter\" href=\"{3}\">正文</a></li></ol></nav></body></html>",
        escaped(title)?,
        list(entries, dir)?,
        escaped(&relative(dir, own))?,
        escaped(&relative(dir, start))?
    ))
}
fn put(files: &mut Files, path: String, bytes: Vec<u8>) {
    if let Some(f) = files.iter_mut().find(|f| f.0 == path) {
        f.1 = bytes
    } else {
        files.push((path, bytes))
    }
}
fn valid_target(files: &Files, target: &str) -> Result<(), ApiError> {
    let path = crate::epub_passthrough::join("", target).ok_or_else(invalid)?;
    let text = crate::epub_xml::named_entities(file(files, &path)?);
    let doc = crate::epub_xml::parse(&text).map_err(|_| invalid())?;
    if let Some((_, fragment)) = target.split_once('#') {
        let decoded = crate::epub_passthrough::join("", fragment).ok_or_else(invalid)?;
        if !doc.descendants().any(|n| {
            n.attribute("id") == Some(decoded.as_str())
                || n.attribute(("http://www.w3.org/XML/1998/namespace", "id"))
                    == Some(decoded.as_str())
        }) {
            return Err(invalid());
        }
    }
    Ok(())
}
pub(crate) fn rewrite(
    files: &mut Files,
    opf: &mut String,
    dir: &str,
    options: &NavigationOptions,
) -> Result<(), ApiError> {
    if !options.valid() {
        return Err(invalid());
    }
    let original = navigation(files, opf, dir)?;
    let embedded_nav = original
        .nav
        .as_ref()
        .map(|(_, p)| contains_body_content(files, p))
        .transpose()?
        .unwrap_or(false);
    let doc = crate::epub_xml::parse(opf).map_err(|_| invalid())?;
    let mut suffix = 0;
    let (id, navpath) = loop {
        let id = format!("easypub-navigation-{suffix}");
        let path = if dir.is_empty() {
            format!("{id}.xhtml")
        } else {
            format!("{dir}/{id}.xhtml")
        };
        if !files
            .iter()
            .any(|f| f.0 == path || f.0 == format!("{path}.ncx"))
            && !doc.descendants().any(|n| {
                n.attribute("id") == Some(id.as_str())
                    || n.attribute("id") == Some(format!("{id}-ncx").as_str())
            })
        {
            break (id, path);
        }
        suffix += 1;
    };
    let own = uri(&navpath);
    let first = original.entries.first().ok_or_else(invalid)?.href.clone();
    let start = match options.start.as_str() {
        "toc" => own.clone(),
        "cover" => original.cover.clone().ok_or_else(no_start)?,
        "specific" => {
            let mut flat = Vec::new();
            flatten(&original.entries, &mut flat);
            if !flat.iter().any(|v| v["id"] == options.original_start) {
                return Err(no_start());
            }
            options.original_start.clone()
        }
        _ => first,
    };
    if options.start != "toc" {
        valid_target(files, &start)?;
    }
    let mut entries = filtered(&original.entries, options);
    // Navigation must remain usable even when the filter removes every entry.
    if entries.is_empty() {
        entries.push(Entry {
            title: "正文".into(),
            href: original.entries[0].href.clone(),
            children: Vec::new(),
        });
    }
    let nav = page(
        &entries,
        dir,
        &options.toc_title,
        &start,
        original.cover.as_deref(),
        &own,
    )?;
    let (ncxid, ncxpath) = original
        .ncx
        .clone()
        .unwrap_or((format!("{id}-ncx"), format!("{navpath}.ncx")));
    let ncxnav = page(
        &entries,
        base(&ncxpath),
        &options.toc_title,
        &start,
        original.cover.as_deref(),
        &own,
    )?;
    let ncx = crate::kindling_navigation::prepare(&ncxnav, &options.toc_title, &original.uid)?
        .replace(
            &format!("urn:sha256:{}", escaped(&original.uid)?),
            &escaped(&original.uid)?,
        );
    let epub3 = doc
        .root_element()
        .attribute("version")
        .unwrap_or("2.0")
        .starts_with('3');
    let manifest = doc
        .descendants()
        .find(|n| n.has_tag_name("manifest"))
        .ok_or_else(invalid)?;
    let spine = doc
        .descendants()
        .find(|n| n.has_tag_name("spine"))
        .ok_or_else(invalid)?;
    let guide = doc.descendants().find(|n| n.has_tag_name("guide"));
    let mut edits = Vec::new();
    for n in doc.descendants().filter(|n| n.has_tag_name("item")) {
        if let Some(a) = n.attributes().find(|a| a.name() == "properties") {
            let p: Vec<_> = a
                .value()
                .split_whitespace()
                .filter(|p| *p != "nav")
                .collect();
            if p.len() != a.value().split_whitespace().count() {
                edits.push((
                    a.range(),
                    if p.is_empty() {
                        String::new()
                    } else {
                        format!("properties=\"{}\"", escaped(&p.join(" "))?)
                    },
                ));
            }
        }
    }
    let mut items = format!(
        "<item id=\"{id}\" href=\"{}\" media-type=\"application/xhtml+xml\"{}/>",
        escaped(&relative(dir, &own))?,
        if epub3 { " properties=\"nav\"" } else { "" }
    );
    if original.ncx.is_none() {
        items.push_str(&format!(
            "<item id=\"{ncxid}\" href=\"{}\" media-type=\"application/x-dtbncx+xml\"/>",
            escaped(&relative(dir, &uri(&ncxpath)))?
        ));
    }
    let pos = manifest.range().start + opf[manifest.range()].rfind("</").ok_or_else(invalid)?;
    edits.push((pos..pos, items));
    let mut reading = Vec::new();
    for n in spine.children().filter(|n| n.has_tag_name("itemref")) {
        let rid = n.attribute("idref").unwrap_or("");
        let is_nav = original.nav.as_ref().is_some_and(|(i, _)| i == rid) && !embedded_nav;
        let target = doc
            .descendants()
            .find(|n| n.has_tag_name("item") && n.attribute("id") == Some(rid))
            .and_then(|n| n.attribute("href"))
            .map(|h| resolve(dir, h))
            .transpose()?;
        let is_toc = if let (Some(t), Some(h)) = (&original.old_toc, target) {
            if !t.contains('#') && *t == h {
                let path = crate::epub_passthrough::join("", t).ok_or_else(invalid)?;
                !contains_body_content(files, &path)?
            } else {
                false
            }
        } else {
            false
        };
        if !is_nav && !is_toc {
            reading.push(opf[n.range()].to_owned());
        }
    }
    let toc = format!("<itemref idref=\"{id}\"/>");
    if options.toc_position == "back" {
        reading.push(toc)
    } else {
        reading.insert(0, toc)
    }
    let attrs = spine
        .attributes()
        .filter(|a| a.name() != "toc")
        .map(|a| Ok(format!(" {}=\"{}\"", a.name(), escaped(a.value())?)))
        .collect::<Result<Vec<_>, ApiError>>()?
        .join("");
    edits.push((
        spine.range(),
        format!("<spine{attrs} toc=\"{ncxid}\">{}</spine>", reading.join("")),
    ));
    let mut refs = String::new();
    if let Some(g) = guide {
        for n in g.children().filter(|n| n.is_element()) {
            if !matches!(n.attribute("type"), Some("toc" | "text" | "bodymatter")) {
                refs.push_str(&opf[n.range()]);
            }
        }
    }
    refs.push_str(&format!("<reference type=\"toc\" title=\"{}\" href=\"{}\"/><reference type=\"text\" title=\"起始位置\" href=\"{}\"/>",escaped(&options.toc_title)?,escaped(&relative(dir,&own))?,escaped(&relative(dir,&start))?));
    let guide_text = format!("<guide>{refs}</guide>");
    if let Some(g) = guide {
        edits.push((g.range(), guide_text))
    } else {
        let pos = opf.rfind("</").ok_or_else(invalid)?;
        edits.push((pos..pos, guide_text));
    }
    edits.sort_by_key(|(r, _)| std::cmp::Reverse(r.start));
    for (r, v) in edits {
        opf.replace_range(r, &v);
    }
    put(
        files,
        navpath,
        if epub3 {
            nav
        } else {
            crate::edition_options::epub2_page(&nav)
        }
        .into_bytes(),
    );
    put(files, ncxpath, ncx.into_bytes());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn nested_relative_links_promote_children_and_keep_embedded_body() {
        let mut opf=r#"<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">book-id</dc:identifier></metadata><manifest><item id="nav" href="nav/toc.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="body" href="text/a%20b.xhtml" media-type="application/xhtml+xml"/><item id="ncx" href="legacy/nav.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine toc="ncx"><itemref idref="nav"/><itemref idref="body"/></spine></package>"#.to_owned();
        let nav = r##"<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head><body><p id="inline">正文也在目录文件中。</p><nav epub:type="toc"><ol><li><a href="../text/a%20b.xhtml#first">排除父项</a><ol><li><a href="../text/a%20b.xhtml#second">保留子项</a></li></ol></li><li><a href="#inline">内嵌章节</a></li></ol></nav></body></html>"##;
        let body = r#"<html xmlns="http://www.w3.org/1999/xhtml"><head><title>正文</title></head><body><p id="first"><b>粗体</b></p><table id="second"><tr><td>表格</td></tr></table></body></html>"#;
        let mut files = vec![
            ("OPS/nav/toc.xhtml".into(), nav.as_bytes().to_vec()),
            ("OPS/text/a b.xhtml".into(), body.as_bytes().to_vec()),
            ("OPS/legacy/nav.ncx".into(), Vec::new()),
        ];
        let options = NavigationOptions {
            apply_to_original: true,
            toc_filter: "排除".into(),
            start: "specific".into(),
            original_start: "OPS/nav/toc.xhtml#inline".into(),
            ..Default::default()
        };
        rewrite(&mut files, &mut opf, "OPS", &options).unwrap();
        assert_eq!(file(&files, "OPS/text/a b.xhtml").unwrap(), body);
        assert_eq!(file(&files, "OPS/nav/toc.xhtml").unwrap(), nav);
        assert!(opf.contains("<itemref idref=\"nav\"/>"));
        let newnav = file(&files, "OPS/easypub-navigation-0.xhtml").unwrap();
        assert!(!newnav.contains("排除父项") && newnav.contains("保留子项"));
        let ncx = file(&files, "OPS/legacy/nav.ncx").unwrap();
        assert!(ncx.contains("../text/a%20b.xhtml#second"));
        assert!(ncx.contains("../nav/toc.xhtml#inline"));
        assert!(ncx.contains("content=\"book-id\""));
    }
}
