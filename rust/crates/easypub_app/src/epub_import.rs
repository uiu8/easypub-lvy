//! Read-only EPUB import into a bounded UTF-8 TXT working copy.
//!
//! The importer deliberately does not rewrite the source EPUB. It follows the
//! package spine, extracts block text from XHTML documents, and writes a new
//! TXT file that can enter the existing immutable-source pipeline.

use easypub_core::{ApiError, ErrorCode};
use roxmltree::{Document, Node};
use serde_json::json;
use std::{
    collections::HashMap,
    fs,
    io::{Cursor, Read},
    path::Path,
};
use zip::ZipArchive;

const MAX_EPUB_BYTES: u64 = 256 * 1024 * 1024;
const MAX_ENTRIES: usize = 4096;
const MAX_UNCOMPRESSED_BYTES: u64 = 512 * 1024 * 1024;
const MAX_TEXT_BYTES: usize = 256 * 1024 * 1024;

fn invalid(action: &'static str) -> ApiError {
    ApiError::new(ErrorCode::InvalidRule, "epub_import", action)
}

fn too_large(action: &'static str) -> ApiError {
    ApiError::new(ErrorCode::TooLarge, "epub_import", action)
}

fn safe_zip_path(value: &str) -> Option<String> {
    let normalized = value.replace('\\', "/");
    if normalized.is_empty() || normalized.starts_with('/') || normalized.contains(':') {
        return None;
    }
    let mut parts = Vec::new();
    for part in normalized.split('/') {
        match part {
            "" | "." => {}
            ".." => return None,
            value => parts.push(value),
        }
    }
    (!parts.is_empty()).then(|| parts.join("/"))
}

fn join_zip(base: &str, href: &str) -> Option<String> {
    let href = href.split(['#', '?']).next().unwrap_or("");
    let mut decoded = Vec::new();
    let mut bytes = href.as_bytes().iter();
    while let Some(&b) = bytes.next() {
        if b == b'%' {
            let h = (*bytes.next()? as char).to_digit(16)?;
            let l = (*bytes.next()? as char).to_digit(16)?;
            decoded.push((h * 16 + l) as u8);
        } else {
            decoded.push(b);
        }
    }
    let href = String::from_utf8(decoded).ok()?.replace('\\', "/");
    if href.starts_with('/') || href.contains(':') || href.contains('\0') {
        return None;
    }
    let mut parts: Vec<_> = base.split('/').filter(|s| !s.is_empty()).collect();
    for part in href.split('/') {
        match part {
            "" | "." => (),
            ".." => {
                parts.pop()?;
            }
            _ => parts.push(part),
        }
    }
    safe_zip_path(&parts.join("/"))
}

fn read_entry<R: Read + std::io::Seek>(
    archive: &mut ZipArchive<R>,
    name: &str,
    remaining: &mut u64,
) -> Result<Vec<u8>, ApiError> {
    let name = safe_zip_path(name).ok_or_else(|| invalid("reject_unsafe_epub_path"))?;
    let entry = archive
        .by_name(&name)
        .map_err(|_| invalid("choose_epub_with_container_and_content"))?;
    let size = entry.size();
    if size > *remaining || size as usize > MAX_TEXT_BYTES {
        return Err(too_large("reduce_epub_uncompressed_content"));
    }
    let mut bytes = Vec::with_capacity(size as usize);
    entry
        .take(size + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| invalid("read_epub_entry"))?;
    if bytes.len() as u64 != size {
        return Err(invalid("read_complete_epub_entry"));
    }
    *remaining -= size;
    Ok(bytes)
}

struct ImageAnchor {
    href: String,
    after_line: usize,
    caption: String,
    alt: String,
}
#[derive(Default)]
struct SpineDocument {
    lines: Vec<String>,
    images: Vec<ImageAnchor>,
}
fn normalized_text(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}
fn flush_text(text: &mut String, lines: &mut Vec<String>) {
    let line = normalized_text(text);
    text.clear();
    if !line.is_empty() {
        // Repeated paragraphs are valid source content. Deduplication belongs
        // to a separately reviewed repair, never the read-only importer.
        lines.push(line);
    }
}
fn walk_content(node: Node<'_, '_>, result: &mut SpineDocument, text: &mut String) {
    if node.is_text() {
        text.push_str(node.text().unwrap_or(""));
        return;
    }
    if !node.is_element() {
        return;
    }
    let name = node.tag_name().name();
    if matches!(name, "head" | "script" | "style") {
        return;
    }
    if node
        .attributes()
        .any(|a| a.name() == "type" && a.value().split_whitespace().any(|v| v == "cover"))
    {
        return;
    }
    // A figure caption is retained on the image, rather than duplicated as
    // ordinary body text and as a generated figcaption on export.
    if name == "figcaption"
        && node.parent().is_some_and(|p| {
            p.descendants()
                .any(|n| n.has_tag_name("img") || n.has_tag_name("image"))
        })
    {
        return;
    }
    if name == "img" || name == "image" {
        let href = node
            .attribute("src")
            .or_else(|| node.attribute("href"))
            .or_else(|| node.attribute(("http://www.w3.org/1999/xlink", "href")));
        if let Some(href) = href {
            flush_text(text, &mut result.lines);
            // The publication API places illustrations after a source line.
            // A leading/image-only page therefore needs a stable blank line.
            if result.lines.is_empty() {
                result.lines.push(String::new());
            }
            let alt = node.attribute("alt").unwrap_or("").trim().to_owned();
            let figure = node.ancestors().find(|p| p.has_tag_name("figure"));
            let caption = figure
                .and_then(|p| p.descendants().find(|n| n.has_tag_name("figcaption")))
                .map(|n| {
                    normalized_text(
                        &n.descendants()
                            .filter(|&c| c.is_text())
                            .map(|c| c.text().unwrap_or(""))
                            .collect::<String>(),
                    )
                })
                .unwrap_or_else(|| node.attribute("title").unwrap_or("").trim().to_owned());
            result.images.push(ImageAnchor {
                href: href.to_owned(),
                after_line: result.lines.len(),
                caption,
                alt,
            });
        }
        return;
    }
    let block = matches!(
        name,
        "h1" | "h2"
            | "h3"
            | "h4"
            | "h5"
            | "h6"
            | "p"
            | "li"
            | "blockquote"
            | "pre"
            | "div"
            | "section"
            | "article"
            | "figure"
            | "tr"
    );
    if block || name == "br" {
        flush_text(text, &mut result.lines);
    }
    for child in node.children() {
        walk_content(child, result, text);
    }
    if block {
        flush_text(text, &mut result.lines);
    }
}
fn spine_document(
    xml: &str,
    path: &str,
    cover_image: Option<&str>,
) -> Result<SpineDocument, ApiError> {
    let document = Document::parse(xml).map_err(|_| invalid("choose_well_formed_epub_xhtml"))?;
    let root = document
        .descendants()
        .find(|n| n.has_tag_name("body"))
        .unwrap_or(document.root_element());
    let mut result = SpineDocument::default();
    let mut text = String::new();
    walk_content(root, &mut result, &mut text);
    flush_text(&mut text, &mut result.lines);
    let base = path.rsplit_once('/').map(|v| v.0).unwrap_or("");
    if !result.images.is_empty()
        && result.lines.iter().all(String::is_empty)
        && result
            .images
            .iter()
            .all(|i| cover_image.is_some() && join_zip(base, &i.href).as_deref() == cover_image)
    {
        return Ok(SpineDocument::default());
    }
    Ok(result)
}
fn cover_image_zip(opf: &Document<'_>, base: &str) -> Option<String> {
    let legacy_id = opf
        .descendants()
        .find(|n| n.has_tag_name("meta") && n.attribute("name") == Some("cover"))
        .and_then(|n| n.attribute("content"));
    opf.descendants()
        .filter(|n| n.has_tag_name("item"))
        .find(|n| {
            n.attribute("properties")
                .unwrap_or("")
                .split_whitespace()
                .any(|v| v == "cover-image")
                || legacy_id.is_some() && n.attribute("id") == legacy_id
        })
        .and_then(|n| n.attribute("href"))
        .and_then(|href| join_zip(base, href))
}

/// Extract a bounded, read-only TXT working copy from an EPUB file.
pub fn extract(source_path: &str, output_path: &str) -> Result<String, ApiError> {
    let source = Path::new(source_path);
    let output = Path::new(output_path);
    if !source.is_absolute()
        || !output.is_absolute()
        || !source
            .extension()
            .and_then(|v| v.to_str())
            .unwrap_or("")
            .eq_ignore_ascii_case("epub")
        || !output
            .extension()
            .and_then(|v| v.to_str())
            .unwrap_or("")
            .eq_ignore_ascii_case("txt")
        || source_path.len() > 32768
        || output_path.len() > 32768
    {
        return Err(invalid("choose_absolute_epub_and_txt_paths"));
    }
    let bytes = fs::read(source).map_err(|_| invalid("choose_readable_epub"))?;
    if bytes.is_empty() || bytes.len() as u64 > MAX_EPUB_BYTES {
        return Err(too_large("reduce_epub_file_size"));
    }
    if output.exists() {
        return Err(invalid("choose_new_epub_import_output"));
    }
    let mut archive =
        ZipArchive::new(Cursor::new(bytes)).map_err(|_| invalid("choose_valid_epub_zip"))?;
    if archive.len() > MAX_ENTRIES {
        return Err(too_large("reduce_epub_entry_count"));
    }
    let mut remaining = MAX_UNCOMPRESSED_BYTES;
    let container = String::from_utf8(read_entry(
        &mut archive,
        "META-INF/container.xml",
        &mut remaining,
    )?)
    .map_err(|_| invalid("choose_utf8_epub_container"))?;
    let container_doc =
        Document::parse(&container).map_err(|_| invalid("choose_valid_epub_container"))?;
    let opf_path = container_doc
        .descendants()
        .find(|node| node.has_tag_name("rootfile"))
        .and_then(|node| node.attribute("full-path"))
        .and_then(safe_zip_path)
        .ok_or_else(|| invalid("choose_epub_with_package_document"))?;
    let opf = String::from_utf8(read_entry(&mut archive, &opf_path, &mut remaining)?)
        .map_err(|_| invalid("choose_utf8_epub_package"))?;
    let opf_doc = Document::parse(&opf).map_err(|_| invalid("choose_valid_epub_package"))?;
    let base = Path::new(&opf_path)
        .parent()
        .map(|p| p.to_string_lossy().replace('\\', "/"))
        .unwrap_or_default();
    let mut manifest = HashMap::new();
    for item in opf_doc
        .descendants()
        .filter(|node| node.has_tag_name("item"))
    {
        let id = item.attribute("id").unwrap_or("");
        let href = item.attribute("href").unwrap_or("");
        let media = item.attribute("media-type").unwrap_or("");
        if !id.is_empty() && !href.is_empty() {
            manifest.insert(id.to_owned(), (href.to_owned(), media.to_owned()));
        }
    }
    let mut lines = Vec::new();
    let mut documents = 0usize;
    let cover_image = cover_image_zip(&opf_doc, &base);
    for itemref in opf_doc
        .descendants()
        .filter(|node| node.has_tag_name("itemref"))
    {
        let idref = itemref.attribute("idref").unwrap_or("");
        let Some((href, media)) = manifest.get(idref) else {
            continue;
        };
        if !media.contains("xhtml") && !media.contains("html") {
            continue;
        }
        let path =
            join_zip(&base, href).ok_or_else(|| invalid("reject_unsafe_epub_content_path"))?;
        let content = String::from_utf8(read_entry(&mut archive, &path, &mut remaining)?)
            .map_err(|_| invalid("choose_utf8_epub_content"))?;
        let mut extracted = spine_document(&content, &path, cover_image.as_deref())?.lines;
        if !extracted.is_empty() {
            documents += 1;
            lines.append(&mut extracted);
            lines.push(String::new());
        }
    }
    // Remove the final document separator only. An image-only last document's
    // own blank anchor must remain addressable.
    if lines.last().is_some_and(String::is_empty) {
        lines.pop();
    }
    if lines.is_empty() || documents == 0 {
        return Err(invalid("choose_epub_with_readable_spine_text"));
    }
    let text = format!("{}\n", lines.join("\n"));
    if text.len() > MAX_TEXT_BYTES {
        return Err(too_large("reduce_epub_text_content"));
    }
    if output.parent().is_some_and(|parent| !parent.exists()) {
        fs::create_dir_all(output.parent().unwrap())
            .map_err(|_| invalid("choose_writable_epub_import_directory"))?;
    }
    fs::write(output, text.as_bytes()).map_err(|_| invalid("write_epub_import_copy"))?;
    Ok(json!({"source_path": source_path, "output_path": output_path, "documents": documents, "lines": lines.len()}).to_string())
}

fn resource_name(kind: &str, index: usize, zip_path: &str) -> String {
    let basename = zip_path.rsplit('/').next().unwrap_or("resource");
    let safe = basename
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_') {
                c
            } else {
                '_'
            }
        })
        .collect::<String>();
    format!("{kind}-{index:04}-{safe}")
}

/// Extract non-text EPUB resources to a private working directory. The source
/// EPUB is never rewritten and fonts are only reported as pending review.
pub fn extract_resources(source_path: &str, resource_dir: &str) -> Result<String, ApiError> {
    let source = Path::new(source_path);
    let root = Path::new(resource_dir);
    if !source.is_absolute()
        || !root.is_absolute()
        || !source
            .extension()
            .and_then(|v| v.to_str())
            .unwrap_or("")
            .eq_ignore_ascii_case("epub")
    {
        return Err(invalid("choose_absolute_epub_and_resource_directory"));
    }
    let bytes = fs::read(source).map_err(|_| invalid("choose_readable_epub"))?;
    if bytes.is_empty() || bytes.len() as u64 > MAX_EPUB_BYTES {
        return Err(too_large("reduce_epub_file_size"));
    }
    let mut archive =
        ZipArchive::new(Cursor::new(bytes)).map_err(|_| invalid("choose_valid_epub_zip"))?;
    if archive.len() > MAX_ENTRIES {
        return Err(too_large("reduce_epub_entry_count"));
    }
    let mut remaining = MAX_UNCOMPRESSED_BYTES;
    let container = String::from_utf8(read_entry(
        &mut archive,
        "META-INF/container.xml",
        &mut remaining,
    )?)
    .map_err(|_| invalid("choose_utf8_epub_container"))?;
    let container_doc =
        Document::parse(&container).map_err(|_| invalid("choose_valid_epub_container"))?;
    let opf_path = container_doc
        .descendants()
        .find(|node| node.has_tag_name("rootfile"))
        .and_then(|node| node.attribute("full-path"))
        .and_then(safe_zip_path)
        .ok_or_else(|| invalid("choose_epub_with_package_document"))?;
    let opf = String::from_utf8(read_entry(&mut archive, &opf_path, &mut remaining)?)
        .map_err(|_| invalid("choose_utf8_epub_package"))?;
    let opf_doc = Document::parse(&opf).map_err(|_| invalid("choose_valid_epub_package"))?;
    let base = Path::new(&opf_path)
        .parent()
        .map(|p| p.to_string_lossy().replace('\\', "/"))
        .unwrap_or_default();
    let mut manifest = Vec::new();
    for item in opf_doc
        .descendants()
        .filter(|node| node.has_tag_name("item"))
    {
        let id = item.attribute("id").unwrap_or("");
        let href = item.attribute("href").unwrap_or("");
        let media = item.attribute("media-type").unwrap_or("");
        let properties = item.attribute("properties").unwrap_or("");
        if !id.is_empty() && !href.is_empty() {
            manifest.push((
                id.to_owned(),
                href.to_owned(),
                media.to_owned(),
                properties.to_owned(),
            ));
        }
    }
    let cover_id = opf_doc
        .descendants()
        .find(|node| node.has_tag_name("meta") && node.attribute("name") == Some("cover"))
        .and_then(|node| node.attribute("content"))
        .map(str::to_owned);
    let metadata_value = |local: &str| {
        opf_doc
            .descendants()
            .find(|node| {
                node.is_element() && node.tag_name().name().rsplit(':').next() == Some(local)
            })
            .and_then(|node| node.text())
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .unwrap_or("")
            .to_owned()
    };
    let title = metadata_value("title");
    let author = metadata_value("creator");
    let description = metadata_value("description");
    let language = metadata_value("language");
    let publisher = metadata_value("publisher");
    let date = metadata_value("date");
    fs::create_dir_all(root).map_err(|_| invalid("choose_writable_epub_resource_directory"))?;
    // 原书字体的混淆声明与标识（V123，LAY-179）：提取时还原成可检查、可嵌入的字体。
    let obfuscated = if archive.by_name("META-INF/encryption.xml").is_ok() {
        String::from_utf8(read_entry(
            &mut archive,
            "META-INF/encryption.xml",
            &mut remaining,
        )?)
        .map(|xml| crate::epub_fonts::obfuscated(&xml))
        .unwrap_or_default()
    } else {
        HashMap::new()
    };
    let identifier = crate::epub_fonts::package_identifier(&opf_doc);
    let mut images = Vec::new();
    let mut css = Vec::new();
    let mut fonts = Vec::new();
    let mut font_notes = HashMap::new();
    let mut cover_path = None;
    let mut pending_images = Vec::new();
    let mut image_paths = HashMap::new();
    let mut resource_index = 0usize;
    for (id, href, media, properties) in manifest {
        let is_image = media.starts_with("image/");
        let is_css = media.eq_ignore_ascii_case("text/css");
        let is_font = media.contains("font")
            || media.contains("opentype")
            || media.contains("truetype")
            || [".ttf", ".otf", ".woff", ".woff2"]
                .iter()
                .any(|ext| href.to_ascii_lowercase().ends_with(ext));
        if !is_image && !is_css && !is_font {
            continue;
        }
        if resource_index >= 512 {
            return Err(too_large("reduce_epub_resource_count"));
        }
        let zip_path =
            join_zip(&base, &href).ok_or_else(|| invalid("reject_unsafe_epub_resource_path"))?;
        let data = read_entry(&mut archive, &zip_path, &mut remaining)?;
        if data.len() > 64 * 1024 * 1024 {
            return Err(too_large("reduce_epub_resource_size"));
        }
        let kind = if is_image {
            "images"
        } else if is_css {
            "css"
        } else {
            "fonts"
        };
        let target_dir = root.join(kind);
        fs::create_dir_all(&target_dir)
            .map_err(|_| invalid("choose_writable_epub_resource_directory"))?;
        let mut name = resource_name(kind, resource_index, &zip_path);
        // V24（RES-048）：TIFF、SVG 转成 PNG / JPEG 工作副本，界面能预览，输出也能用；
        // 转换失败的保留原文件，列为待确认。原 EPUB 不变。
        let (data, media, converted_from, conversion_failed) = if is_image {
            match crate::kindle_images::import_ready(&data, &media) {
                Ok(Some((bytes, ext, to))) => {
                    name = format!("{name}.{ext}");
                    (bytes, to.to_owned(), Some(media.clone()), false)
                }
                Ok(None) => (data, media.clone(), None, false),
                Err(_) => (data, media.clone(), None, true),
            }
        } else if is_css {
            (data, media.clone(), None, false)
        } else {
            let mut data = data;
            let mut note = None;
            if let Some(&kind) = obfuscated.get(&zip_path) {
                match crate::epub_fonts::deobfuscate(&data, kind, &identifier) {
                    Some(plain) => {
                        data = plain;
                        note = Some(kind.name());
                    }
                    None => note = Some("unrecoverable"),
                }
            }
            let mut from = None;
            if crate::epub_fonts::format(&data) == "woff"
                && let Some(sfnt) = crate::woff::decode(&data)
            {
                data = sfnt;
                from = Some("font/woff".to_owned());
            }
            let format = crate::epub_fonts::format(&data);
            if (from.is_some() || note.is_some_and(|n| n != "unrecoverable"))
                && matches!(format, "ttf" | "otf")
            {
                name = format!("{name}.{format}");
            }
            font_notes.insert(name.clone(), (note, format));
            let media = match format {
                "ttf" => "font/ttf".to_owned(),
                "otf" => "font/otf".to_owned(),
                _ => media.clone(),
            };
            (data, media, from, false)
        };
        let target = target_dir.join(name.clone());
        fs::write(&target, &data).map_err(|_| invalid("write_epub_resource"))?;
        let path = target.to_string_lossy().to_string();
        let mut entry =
            json!({"id": id, "href": href, "path": path, "media_type": media, "bytes": data.len()});
        if let Some(from) = &converted_from {
            entry["converted_from"] = json!(from);
        }
        if conversion_failed {
            pending_images.push(json!({
                "path": path,
                "href": href,
                "reason": "unconvertible_image",
                "media_type": media,
            }));
        }
        if is_image {
            let cover = properties.split_whitespace().any(|p| p == "cover-image")
                || cover_id.as_deref() == Some(id.as_str());
            if cover && cover_path.is_none() {
                if crate::kindle_images::usable_media_type(&media) {
                    cover_path = Some(path.clone());
                } else {
                    pending_images.push(json!({
                        "path": path,
                        "href": href,
                        "reason": "unsupported_cover_format",
                        "media_type": media,
                    }));
                }
            }
            images.push(entry);
            image_paths.insert(zip_path, path.clone());
        } else if is_css {
            css.push(entry);
        } else {
            // 字体格式与还原情况（V123）：format 为 ttf / otf / ttc 的可直接嵌入。
            if let Some((note, format)) = font_notes.get(&name) {
                entry["format"] = json!(format);
                if let Some(note) = note {
                    entry["obfuscation"] = json!(note);
                }
            }
            fonts.push(entry);
        }
        resource_index += 1;
    }
    // Use the exact same text/image walk as the working-copy extractor. Image
    // positions follow the preceding paragraph, including leading images and
    // image-only documents, rather than guessing at document starts.
    let mut image_placements = Vec::new();
    let mut source_line_offset = 0usize;
    let cover_image = cover_image_zip(&opf_doc, &base);
    for itemref in opf_doc
        .descendants()
        .filter(|node| node.has_tag_name("itemref"))
    {
        let idref = itemref.attribute("idref").unwrap_or("");
        let Some((href, media)) = opf_doc
            .descendants()
            .filter(|node| node.has_tag_name("item"))
            .find(|node| node.attribute("id") == Some(idref))
            .map(|node| {
                (
                    node.attribute("href").unwrap_or(""),
                    node.attribute("media-type").unwrap_or(""),
                )
            })
        else {
            continue;
        };
        if !media.contains("xhtml") && !media.contains("html") {
            continue;
        }
        let path =
            join_zip(&base, href).ok_or_else(|| invalid("reject_unsafe_epub_content_path"))?;
        let content = String::from_utf8(read_entry(&mut archive, &path, &mut remaining)?)
            .map_err(|_| invalid("choose_utf8_epub_content"))?;
        let document = spine_document(&content, &path, cover_image.as_deref())?;
        let lines_in_document = document.lines.len();
        for image in document.images {
            let zip_image = join_zip(
                path.rsplit_once('/').map(|v| v.0).unwrap_or(""),
                &image.href,
            );
            if zip_image.as_deref() == cover_image.as_deref() {
                continue;
            }
            let resource_path = zip_image.as_ref().and_then(|p| image_paths.get(p));
            let Some(resource_path) = resource_path else {
                pending_images.push(json!({"document":path,"href":image.href,
                    "reason":"missing_or_external_image","source_line":source_line_offset+image.after_line}));
                continue;
            };
            let supported = images.iter().any(|entry| {
                entry["path"] == resource_path.as_str()
                    && entry["media_type"]
                        .as_str()
                        .is_some_and(crate::kindle_images::usable_media_type)
            });
            if !supported {
                pending_images.push(json!({"document":path,"href":image.href,"path":resource_path,
                    "reason":"unsupported_reflow_image_format","source_line":source_line_offset+image.after_line}));
                continue;
            }
            image_placements.push(json!({
                "path": resource_path,
                "source_line": source_line_offset + image.after_line,
                "document": path,
                "caption": image.caption,
                "alt": image.alt,
            }));
        }
        if lines_in_document > 0 {
            source_line_offset = source_line_offset.saturating_add(lines_in_document + 1);
        }
    }
    Ok(json!({
        "schema": 3,
        "source_path": source_path,
        "resource_root": resource_dir,
        "cover_path": cover_path,
        "images": images,
        "image_placements": image_placements,
        "pending_images": pending_images,
        "css": css,
        "fonts": fonts,
        "requires_license_confirmation": !fonts.is_empty(),
        "requires_resource_review": true,
        "metadata": {"title": title, "author": author, "description": description,
            "language": language, "publisher": publisher, "publication_date": date},
    })
    .to_string())
}

#[cfg(test)]
mod tests {
    use super::{extract, extract_resources};
    use std::{fs, io::Write};
    use zip::{ZipWriter, write::SimpleFileOptions};

    #[test]
    fn extracts_spine_text_without_touching_epub() {
        let root = std::env::temp_dir().join(format!("easypub-epub-import-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("META-INF")).unwrap();
        let source = root.join("book.epub");
        let output = root.join("working.txt");
        let file = fs::File::create(&source).unwrap();
        let mut zip = ZipWriter::new(file);
        let opts = SimpleFileOptions::default();
        zip.start_file("META-INF/container.xml", opts).unwrap();
        zip.write_all(br#"<container><rootfiles><rootfile full-path="EPUB/package.opf"/></rootfiles></container>"#).unwrap();
        zip.start_file("EPUB/package.opf", opts).unwrap();
        zip.write_all(br#"<package><manifest><item id="c" href="text.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c"/></spine></package>"#).unwrap();
        zip.start_file("EPUB/text.xhtml", opts).unwrap();
        zip.write_all("<html><body><h1>第一章 开始</h1><p>正文内容</p></body></html>".as_bytes())
            .unwrap();
        zip.finish().unwrap();
        let before = fs::read(&source).unwrap();
        let result = extract(source.to_str().unwrap(), output.to_str().unwrap()).unwrap();
        assert!(result.contains("documents"));
        assert_eq!(fs::read(&source).unwrap(), before);
        assert_eq!(
            fs::read_to_string(output).unwrap(),
            "第一章 开始\n正文内容\n"
        );
        let _ = fs::remove_dir_all(root);
    }

    /// V123（LAY-179）：encryption.xml 声明 IDPF 混淆的字体提取时还原，WOFF2 原样列出并标明格式。
    #[test]
    fn obfuscated_fonts_are_restored_on_extraction() {
        let root = std::env::temp_dir().join(format!("easypub-epub-fonts-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let mut font = (0..4000u32)
            .map(|i| (i * 13 % 251) as u8)
            .collect::<Vec<_>>();
        font[..4].copy_from_slice(&[0, 1, 0, 0]);
        let id = "urn:uuid:12345678-1234-1234-1234-123456789abc";
        let hidden =
            crate::epub_fonts::deobfuscate(&font, crate::epub_fonts::Obfuscation::Idpf, id)
                .unwrap();
        let source = root.join("book.epub");
        let mut zip = ZipWriter::new(fs::File::create(&source).unwrap());
        let opts = SimpleFileOptions::default();
        zip.start_file("META-INF/container.xml", opts).unwrap();
        zip.write_all(br#"<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>"#).unwrap();
        zip.start_file("META-INF/encryption.xml", opts).unwrap();
        zip.write_all(br#"<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#"><enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/><enc:CipherData><enc:CipherReference URI="OEBPS/Fonts/song.ttf"/></enc:CipherData></enc:EncryptedData></encryption>"#).unwrap();
        zip.start_file("OEBPS/content.opf", opts).unwrap();
        zip.write_all(format!(r#"<package unique-identifier="bid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="bid">{id}</dc:identifier></metadata><manifest><item id="f" href="Fonts/song.ttf" media-type="application/x-font-ttf"/><item id="w" href="Fonts/b.woff2" media-type="font/woff2"/><item id="c" href="t.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c"/></spine></package>"#).as_bytes()).unwrap();
        zip.start_file("OEBPS/Fonts/song.ttf", opts).unwrap();
        zip.write_all(&hidden).unwrap();
        zip.start_file("OEBPS/Fonts/b.woff2", opts).unwrap();
        zip.write_all(b"wOF2rest").unwrap();
        zip.start_file("OEBPS/t.xhtml", opts).unwrap();
        zip.write_all("<html><body><p>正文</p></body></html>".as_bytes())
            .unwrap();
        zip.finish().unwrap();
        let result =
            extract_resources(source.to_str().unwrap(), root.join("res").to_str().unwrap())
                .unwrap();
        let value: serde_json::Value = serde_json::from_str(&result).unwrap();
        let fonts = value["fonts"].as_array().unwrap();
        assert_eq!(fonts.len(), 2);
        assert_eq!(fonts[0]["format"], "ttf");
        assert_eq!(fonts[0]["obfuscation"], "idpf");
        assert_eq!(fonts[0]["media_type"], "font/ttf");
        assert_eq!(fs::read(fonts[0]["path"].as_str().unwrap()).unwrap(), font);
        assert_eq!(fonts[1]["format"], "woff2");
        assert!(fonts[1].get("obfuscation").is_none());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn extracts_resources_with_font_review_flag() {
        let root =
            std::env::temp_dir().join(format!("easypub-epub-resources-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("META-INF")).unwrap();
        let source = root.join("book.epub");
        let file = fs::File::create(&source).unwrap();
        let mut zip = ZipWriter::new(file);
        let opts = SimpleFileOptions::default();
        zip.start_file("META-INF/container.xml", opts).unwrap();
        zip.write_all(br#"<container><rootfiles><rootfile full-path="EPUB/package.opf"/></rootfiles></container>"#).unwrap();
        zip.start_file("EPUB/package.opf", opts).unwrap();
        zip.write_all(br#"<package><metadata><meta name="cover" content="cover"/></metadata><manifest><item id="cover" href="cover.jpg" media-type="image/jpeg"/><item id="body-image" href="body.png" media-type="image/png"/><item id="style" href="style.css" media-type="text/css"/><item id="font" href="font.ttf" media-type="font/ttf"/><item id="c" href="text.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c"/></spine></package>"#).unwrap();
        zip.start_file("EPUB/cover.jpg", opts).unwrap();
        zip.write_all(b"image").unwrap();
        zip.start_file("EPUB/body.png", opts).unwrap();
        zip.write_all(b"body image").unwrap();
        zip.start_file("EPUB/style.css", opts).unwrap();
        zip.write_all(b"body{}").unwrap();
        zip.start_file("EPUB/font.ttf", opts).unwrap();
        zip.write_all(b"font").unwrap();
        zip.start_file("EPUB/text.xhtml", opts).unwrap();
        zip.write_all("<html><body><h1>章节</h1><p>正文</p><img src=\"cover.jpg\" alt=\"封面图\" title=\"图注\"/><img src=\"body.png\" alt=\"正文图\" title=\"正文图注\"/></body></html>".as_bytes()).unwrap();
        zip.finish().unwrap();
        let result = extract_resources(
            source.to_str().unwrap(),
            root.join("resources").to_str().unwrap(),
        )
        .unwrap();
        let value: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert!(value["cover_path"].as_str().unwrap().ends_with("cover.jpg"));
        assert_eq!(value["images"].as_array().unwrap().len(), 2);
        assert_eq!(value["css"].as_array().unwrap().len(), 1);
        assert_eq!(value["fonts"].as_array().unwrap().len(), 1);
        assert_eq!(value["requires_license_confirmation"], true);
        assert_eq!(value["image_placements"].as_array().unwrap().len(), 1);
        assert_eq!(value["image_placements"][0]["source_line"], 2);
        assert_eq!(value["image_placements"][0]["alt"], "正文图");
        let _ = fs::remove_dir_all(root);
    }

    /// V24（RES-048）：SVG 封面、TIFF 插图转成工作副本；GIF 原样保留；坏的 SVG 列为待确认。
    #[test]
    fn svg_cover_and_tiff_illustration_become_usable_copies() {
        use image::{DynamicImage, ImageBuffer, ImageFormat, Rgb};
        use std::io::Cursor;
        let root = std::env::temp_dir().join(format!("easypub-epub-v24-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let source = root.join("book.epub");
        let encoded = |format| {
            let mut out = Cursor::new(Vec::new());
            DynamicImage::ImageRgb8(ImageBuffer::from_pixel(12, 8, Rgb([40, 80, 120])))
                .write_to(&mut out, format)
                .unwrap();
            out.into_inner()
        };
        let mut zip = ZipWriter::new(fs::File::create(&source).unwrap());
        let opts = SimpleFileOptions::default();
        for (name, bytes) in [
            ("META-INF/container.xml", br#"<container><rootfiles><rootfile full-path="EPUB/package.opf"/></rootfiles></container>"#.to_vec()),
            ("EPUB/package.opf", br#"<package><metadata/><manifest><item id="cover" href="cover.svg" media-type="image/svg+xml" properties="cover-image"/><item id="t" href="plate.tif" media-type="image/tiff"/><item id="g" href="anim.gif" media-type="image/gif"/><item id="bad" href="bad.svg" media-type="image/svg+xml"/><item id="c" href="text.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c"/></spine></package>"#.to_vec()),
            ("EPUB/cover.svg", br##"<svg xmlns="http://www.w3.org/2000/svg" width="60" height="90"><rect width="60" height="90" fill="#333"/></svg>"##.to_vec()),
            ("EPUB/plate.tif", encoded(ImageFormat::Tiff)),
            ("EPUB/anim.gif", encoded(ImageFormat::Gif)),
            ("EPUB/bad.svg", b"<svg".to_vec()),
            ("EPUB/text.xhtml", "<html><body><p>甲</p><img src=\"plate.tif\" alt=\"图版\"/><p>乙</p><img src=\"anim.gif\"/><p>丙</p><img src=\"bad.svg\"/></body></html>".as_bytes().to_vec()),
        ] {
            zip.start_file(name, opts).unwrap();
            zip.write_all(&bytes).unwrap();
        }
        zip.finish().unwrap();
        let value: serde_json::Value = serde_json::from_str(
            &extract_resources(source.to_str().unwrap(), root.join("res").to_str().unwrap())
                .unwrap(),
        )
        .unwrap();
        let cover = value["cover_path"].as_str().unwrap();
        assert!(cover.ends_with("cover.svg.png"), "{cover}");
        assert_eq!(
            image::guess_format(&fs::read(cover).unwrap()).unwrap(),
            ImageFormat::Png
        );
        let images = value["images"].as_array().unwrap();
        let by_id = |id: &str| images.iter().find(|i| i["id"] == id).unwrap();
        assert_eq!(by_id("cover")["converted_from"], "image/svg+xml");
        assert_eq!(by_id("t")["media_type"], "image/jpeg");
        assert_eq!(by_id("t")["converted_from"], "image/tiff");
        assert_eq!(by_id("g")["media_type"], "image/gif");
        assert!(by_id("g").get("converted_from").is_none());
        // TIFF 与 GIF 插图都能放进正文；坏的 SVG 不能，列为待确认。
        let placed: Vec<_> = value["image_placements"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| {
                p["path"]
                    .as_str()
                    .unwrap()
                    .rsplit(['/', '\\'])
                    .next()
                    .unwrap()
                    .to_owned()
            })
            .collect();
        assert_eq!(placed.len(), 2, "{placed:?}");
        assert!(placed[0].ends_with("plate.tif.jpg") && placed[1].ends_with("anim.gif"));
        let pending = value["pending_images"].as_array().unwrap();
        assert!(pending.iter().any(|p| p["reason"] == "unconvertible_image"));
        let _ = fs::remove_dir_all(root);
    }
}
