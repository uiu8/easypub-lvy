//! Bounded, read-only inspection of the actual exported EPUB, bound to its receipt.
use base64::Engine;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::File,
    io::{Cursor, Read, Seek, SeekFrom},
    path::Path,
};
use zip::ZipArchive;

type Check<T> = Result<T, String>;
fn error<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}
fn hash(file: &mut File) -> Check<String> {
    file.seek(SeekFrom::Start(0)).map_err(error)?;
    let mut digest = Sha256::new();
    let mut buf = [0u8; 65536];
    let mut size = 0usize;
    loop {
        let n = file.read(&mut buf).map_err(error)?;
        if n == 0 {
            break;
        }
        size += n;
        if size > 256 * 1024 * 1024 {
            return Err("成品超过检查上限".into());
        }
        digest.update(&buf[..n]);
    }
    file.seek(SeekFrom::Start(0)).map_err(error)?;
    Ok(format!("{:x}", digest.finalize()))
}
fn decode(value: &str) -> Check<String> {
    let raw = value.as_bytes();
    let mut result = Vec::new();
    let mut i = 0;
    while i < raw.len() {
        if raw[i] == b'%' {
            if i + 2 >= raw.len() {
                return Err("无效转义路径".into());
            }
            let hex = std::str::from_utf8(&raw[i + 1..i + 3]).map_err(error)?;
            result.push(u8::from_str_radix(hex, 16).map_err(error)?);
            i += 3;
        } else {
            result.push(raw[i]);
            i += 1;
        }
    }
    String::from_utf8(result).map_err(error)
}
fn resolve(base: &str, href: &str) -> Check<(String, String)> {
    if base.len() + href.len() > 4096 {
        return Err("资源路径超长".into());
    }
    let (path, fragment) = href.split_once('#').unwrap_or((href, ""));
    let path = decode(path)?;
    if path.starts_with('/') || path.contains([':', '\\', '\0', '?']) {
        return Err("不安全的资源路径".into());
    }
    if path.is_empty() {
        return Ok((base.to_string(), decode(fragment)?));
    }
    let mut parts: Vec<&str> = base
        .rsplit_once('/')
        .map(|(dir, _)| dir.split('/').collect())
        .unwrap_or_default();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                if parts.pop().is_none() {
                    return Err("资源路径越界".into());
                }
            }
            _ => parts.push(part),
        }
    }
    Ok((parts.join("/"), decode(fragment)?))
}
fn read(zip: &mut ZipArchive<File>, path: &str, max: u64) -> Check<Vec<u8>> {
    let file = zip.by_name(path).map_err(error)?;
    if file.size() > max {
        return Err("资源超出检查上限".into());
    }
    let mut bytes = Vec::new();
    file.take(max + 1).read_to_end(&mut bytes).map_err(error)?;
    if bytes.len() as u64 > max {
        return Err("资源超出检查上限".into());
    }
    Ok(bytes)
}
fn text(zip: &mut ZipArchive<File>, path: &str) -> Check<String> {
    String::from_utf8(read(zip, path, 8 * 1024 * 1024)?).map_err(error)
}
fn parse_xml(text: &str) -> Result<roxmltree::Document<'_>, roxmltree::Error> {
    roxmltree::Document::parse_with_options(
        text,
        roxmltree::ParsingOptions {
            nodes_limit: 200_000,
            ..Default::default()
        },
    )
}
pub fn inspect(path: &Path, expected: &str) -> Check<Value> {
    let mut file = File::open(path).map_err(error)?;
    if file.metadata().map_err(error)?.len() > 256 * 1024 * 1024 {
        return Err("成品超出256MiB检查上限".into());
    }
    if hash(&mut file)? != expected {
        return Err("成品与导出回执不一致".into());
    }
    let mut zip = ZipArchive::new(file).map_err(error)?;
    if zip.len() > 4096 {
        return Err("资源数超出检查上限".into());
    }
    let mut names = BTreeSet::new();
    let mut total = 0u64;
    for i in 0..zip.len() {
        let entry = zip.by_index(i).map_err(error)?;
        total = total.checked_add(entry.size()).ok_or("资源体积溢出")?;
        if total > 512 * 1024 * 1024 || !names.insert(entry.name().to_string()) {
            return Err("资源重复或总量超限".into());
        }
    }
    if read(&mut zip, "mimetype", 64)? != b"application/epub+zip" {
        return Err("EPUB mimetype无效".into());
    }
    let container = text(&mut zip, "META-INF/container.xml")?;
    let doc = parse_xml(&container).map_err(error)?;
    let package = doc
        .descendants()
        .find(|n| n.has_tag_name("rootfile"))
        .and_then(|n| n.attribute("full-path"))
        .ok_or("缺少OPF路径")?;
    let package = resolve("", package)?.0;
    let opf = text(&mut zip, &package)?;
    let doc = parse_xml(&opf).map_err(error)?;
    let metadata = |name| {
        doc.descendants()
            .find(|n| n.has_tag_name(name))
            .and_then(|n| n.text())
            .unwrap_or("")
            .to_string()
    };
    let title = metadata("title");
    let author = metadata("creator");
    let language = metadata("language");
    let mut manifest = BTreeMap::new();
    let mut cover = None;
    let mut nav = None;
    for node in doc.descendants().filter(|n| n.has_tag_name("item")) {
        let id = node.attribute("id").ok_or("资源缺少ID")?;
        let href = node.attribute("href").ok_or("资源缺少路径")?;
        let path = resolve(&package, href)?.0;
        if !names.contains(&path) || manifest.insert(id.to_string(), path.clone()).is_some() {
            return Err("清单资源缺失或ID重复".into());
        }
        let properties = node.attribute("properties").unwrap_or("");
        if properties.split_whitespace().any(|p| p == "cover-image") {
            cover = Some(path.clone());
        }
        if properties.split_whitespace().any(|p| p == "nav") {
            nav = Some(path);
        }
    }
    let mut spine = Vec::new();
    for node in doc.descendants().filter(|n| n.has_tag_name("itemref")) {
        let id = node.attribute("idref").ok_or("阅读顺序缺少引用")?;
        spine.push(manifest.get(id).ok_or("阅读顺序指向不存在的资源")?.clone());
    }
    if spine.is_empty() {
        return Err("阅读顺序为空".into());
    }
    let mut pages = BTreeSet::from_iter(spine.iter().cloned());
    let nav = nav.ok_or("缺少EPUB导航文档")?;
    pages.insert(nav.clone());
    let mut ids = BTreeMap::new();
    let mut links = Vec::new();
    let mut text_bytes = 0usize;
    let mut reference_bytes = 0usize;
    let mut anchors = 0usize;
    let mut body_bytes = 0usize;
    let mut heading_count = 0usize;
    let mut image_references = 0usize;
    let mut image_resources = BTreeSet::new();
    for (id, resource) in &manifest {
        if doc
            .descendants()
            .find(|n| n.has_tag_name("item") && n.attribute("id") == Some(id))
            .and_then(|n| n.attribute("media-type"))
            .is_some_and(|media| media.starts_with("image/"))
        {
            image_resources.insert(resource.clone());
        }
    }
    let cover_in_spine = cover.as_ref().is_some_and(|path| spine.contains(path));
    for page in &pages {
        let xml = text(&mut zip, page)?;
        text_bytes += xml.len();
        if text_bytes > 256 * 1024 * 1024 {
            return Err("正文总量超出检查上限".into());
        }
        let doc = parse_xml(&xml).map_err(error)?;
        if spine.contains(page) {
            body_bytes = body_bytes.checked_add(xml.len()).ok_or("正文体积溢出")?;
        }
        if page == &nav {
            let toc = doc
                .descendants()
                .find(|n| {
                    n.has_tag_name("nav")
                        && n.attribute(("http://www.idpf.org/2007/ops", "type"))
                            .unwrap_or("")
                            .split_whitespace()
                            .any(|value| value == "toc")
                })
                .ok_or("导航文档缺少TOC结构")?;
            let targets: Vec<_> = toc
                .descendants()
                .filter(|n| n.has_tag_name("a"))
                .filter_map(|n| n.attribute("href"))
                .collect();
            if targets.is_empty() {
                return Err("目录链接为空".into());
            }
            for href in targets {
                let target = resolve(page, href)?.0;
                if !spine.contains(&target) {
                    return Err("目录目标不在阅读顺序中".into());
                }
            }
        }
        let mut page_ids = BTreeSet::new();
        for node in doc.descendants().filter(|n| n.is_element()) {
            if spine.contains(page)
                && matches!(
                    node.tag_name().name(),
                    "h1" | "h2" | "h3" | "h4" | "h5" | "h6"
                )
            {
                heading_count += 1;
            }
            if let Some(id) = node.attribute("id") {
                anchors += 1;
                reference_bytes += id.len();
                if anchors > 200_000 || reference_bytes > 32 * 1024 * 1024 {
                    return Err("锚点或链接超出检查预算".into());
                }
                if !page_ids.insert(id.to_string()) {
                    return Err("页面锚点重复".into());
                }
            }
            for attr in ["href", "src"] {
                if let Some(value) = node.attribute(attr) {
                    if value.starts_with("https://")
                        || value.starts_with("http://")
                        || value.starts_with("mailto:")
                    {
                        continue;
                    }
                    let target = resolve(page, value)?;
                    if attr == "src" && image_resources.contains(&target.0) {
                        image_references += 1;
                    }
                    reference_bytes += target.0.len() + target.1.len();
                    if links.len() >= 200_000 || reference_bytes > 32 * 1024 * 1024 {
                        return Err("锚点或链接超出检查预算".into());
                    }
                    links.push(target);
                }
            }
        }
        ids.insert(page.clone(), page_ids);
    }
    for (target, fragment) in &links {
        if !names.contains(target) {
            return Err(format!("链接资源不存在：{target}"));
        }
        if !fragment.is_empty() && !ids.get(target).is_some_and(|set| set.contains(fragment)) {
            return Err(format!(
                "链接锚点不存在或不在已核验正文：{target}#{fragment}"
            ));
        }
    }
    let cover_png = if let Some(path) = &cover {
        let raw = read(&mut zip, path, 32 * 1024 * 1024)?;
        let mut reader = image::ImageReader::new(Cursor::new(raw))
            .with_guessed_format()
            .map_err(error)?;
        let mut limits = image::Limits::default();
        limits.max_image_width = Some(16384);
        limits.max_image_height = Some(16384);
        limits.max_alloc = Some(128 * 1024 * 1024);
        reader.limits(limits);
        let decoded = reader.decode().map_err(error)?;
        let thumbnail = decoded.thumbnail(288, 384);
        let mut buffer = Cursor::new(Vec::new());
        thumbnail
            .write_to(&mut buffer, image::ImageFormat::Png)
            .map_err(error)?;
        Some(base64::engine::general_purpose::STANDARD.encode(buffer.into_inner()))
    } else {
        None
    };
    let mut file = zip.into_inner();
    if hash(&mut file)? != expected {
        return Err("检查期间成品发生变化".into());
    }
    Ok(
        json!({"status":"inspected", "spine_documents":spine.len(), "checked_links":links.len(),
      "title":title,"author":author,"language":language,"cover_png":cover_png,
      "body_bytes":body_bytes,"heading_count":heading_count,"image_references":image_references,
      "image_resources":image_resources.len(),"cover_in_spine":cover_in_spine,
      "scope":"EPUB manifest, spine, local document links, body summary, image references and actual metadata; not body equivalence or device acceptance"}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    fn sample(href: &str) -> (std::path::PathBuf, Vec<u8>, String) {
        use std::io::Write;
        let cursor = Cursor::new(Vec::new());
        let mut zip = zip::ZipWriter::new(cursor);
        let entries = [
            ("mimetype", "application/epub+zip".to_string()),
            ("META-INF/container.xml", "<container><rootfiles><rootfile full-path='OPS/book.opf'/></rootfiles></container>".to_string()),
            ("OPS/book.opf", "<package><metadata><title>样书</title><creator>作者</creator><language>zh-CN</language></metadata><manifest><item id='body' href='body.xhtml'/><item id='nav' href='nav.xhtml' properties='nav'/></manifest><spine><itemref idref='body'/></spine></package>".to_string()),
            ("OPS/body.xhtml", "<html><body><h1 id='chapter'>第一章</h1><p>正文</p></body></html>".to_string()),
            ("OPS/nav.xhtml", format!("<html xmlns:epub='http://www.idpf.org/2007/ops'><body><nav epub:type='toc'><a href='{href}'>第一章</a></nav></body></html>")),
        ];
        for (name, text) in entries {
            zip.start_file(name, zip::write::SimpleFileOptions::default())
                .unwrap();
            zip.write_all(text.as_bytes()).unwrap();
        }
        let bytes = zip.finish().unwrap().into_inner();
        let digest = format!("{:x}", Sha256::digest(&bytes));
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "easypub-output-audit-{}-{}-{}.epub",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .unwrap()
            .write_all(&bytes)
            .unwrap();
        (path, bytes, digest)
    }
    #[test]
    fn actual_package_links_metadata_and_receipt_are_checked_without_writes() {
        let (path, original, digest) = sample("body.xhtml#chapter");
        let result = inspect(&path, &digest).unwrap();
        assert_eq!(result["title"], "样书");
        assert_eq!(result["spine_documents"], 1);
        assert_eq!(result["checked_links"], 1);
        assert_eq!(result["heading_count"], 1);
        assert!(result["body_bytes"].as_u64().unwrap() > 0);
        assert_eq!(result["image_references"], 0);
        assert_eq!(result["image_resources"], 0);
        assert_eq!(result["cover_in_spine"], false);
        assert!(result["cover_png"].is_null());
        assert!(inspect(&path, &"0".repeat(64)).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), original);
        std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn broken_links_are_rejected_even_when_file_matches_receipt() {
        for href in ["body.xhtml#missing", "missing.xhtml", "../../outside.xhtml"] {
            let (path, original, digest) = sample(href);
            assert!(inspect(&path, &digest).is_err(), "{href}");
            assert_eq!(std::fs::read(&path).unwrap(), original);
            std::fs::remove_file(path).unwrap();
        }
    }
    #[test]
    fn paths_resolve_without_escaping_archive() {
        assert_eq!(
            resolve("OPS/book.opf", "text/a%20b.xhtml#one").unwrap(),
            ("OPS/text/a b.xhtml".into(), "one".into())
        );
        assert_eq!(
            resolve("OPS/text/a.xhtml", "../nav.xhtml").unwrap().0,
            "OPS/nav.xhtml"
        );
        assert!(resolve("OPS/a.xhtml", "../../escape").is_err());
        assert!(resolve("OPS/a.xhtml", "%2fabsolute").is_err());
        assert!(resolve("OPS/a.xhtml", "a%00b").is_err());
    }
}
