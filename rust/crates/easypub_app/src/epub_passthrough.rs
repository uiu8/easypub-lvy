//! EPUB 保持原格式：不重排正文，只对原 EPUB 做必要修补后交给 EPUB 输出、Kindling 或 Bokai。
//!
//! 修补只有三类，其余文件逐字节保留：
//! · 图片：Kindle 不支持的格式（WebP、GIF、BMP、TIFF、SVG）与超大、CMYK、渐进式 JPEG 按早先的规则转换；
//!   换了格式的文件名后加扩展名（如 cover.webp → cover.webp.jpg），并改写 OPF、XHTML、CSS、NCX 里的引用；
//! · 书目：书名、作者、语言改为书籍信息里的值（用户在本软件里改过的书目要生效）；
//! · 封面：Kindling 需要封面而原 EPUB 没有时，加入本书封面。
//! 原 EPUB 文件不变。
use crate::assets::{ImageEvidence, ImageSnapshot};
use crate::kindle_images::{self, Conversion};
use easypub_core::{ApiError, ErrorCode};
use roxmltree::Document;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    io::{Cursor, Read, Write},
    path::{Path, PathBuf},
};
use zip::{CompressionMethod, ZipArchive, ZipWriter, write::SimpleFileOptions};

const MAX_EPUB_BYTES: u64 = 256 * 1024 * 1024;
const MAX_ENTRIES: usize = 4096;
const MAX_UNCOMPRESSED: u64 = 512 * 1024 * 1024;

fn invalid(action: &'static str) -> ApiError {
    ApiError::new(ErrorCode::InvalidRule, "epub_passthrough", action)
}

/// 已读入的原 EPUB。
pub struct Original {
    pub path: PathBuf,
    pub bytes: Vec<u8>,
    pub sha256: String,
}

pub fn read_original(path: &str) -> Result<Original, ApiError> {
    let p = Path::new(path);
    if !p.is_absolute()
        || !p
            .extension()
            .and_then(|e| e.to_str())
            .is_some_and(|e| e.eq_ignore_ascii_case("epub"))
    {
        return Err(invalid("choose_original_epub"));
    }
    let path = p.canonicalize().map_err(|_| {
        ApiError::new(
            ErrorCode::NotFound,
            "epub_passthrough",
            "locate_original_epub",
        )
    })?;
    let meta = std::fs::metadata(&path).map_err(|_| invalid("locate_original_epub"))?;
    if meta.len() == 0 || meta.len() > MAX_EPUB_BYTES {
        return Err(ApiError::new(
            ErrorCode::TooLarge,
            "epub_passthrough",
            "reduce_epub_file_size",
        ));
    }
    let bytes = std::fs::read(&path).map_err(|_| invalid("locate_original_epub"))?;
    let sha256 = format!("{:x}", Sha256::digest(&bytes));
    Ok(Original {
        path,
        bytes,
        sha256,
    })
}

/// 书籍信息里要写进成品的值。
pub struct Overrides {
    pub title: String,
    pub author: String,
    pub language: String,
    /// 原 EPUB 没有封面且需要封面时加入：（字节，扩展名 png / jpg）。
    pub cover: Option<(Vec<u8>, String)>,
    pub need_cover: bool,
    /// Bokai（KFX）输入：只包一张图的 SVG（常见的封面写法）换成普通 &lt;img&gt;，
    /// 因为 Bokai 会丢掉 SVG 里的文字，校验不能通过。软件排版的 KFX 封面页也是这样做的。
    pub plain_svg_images: bool,
    /// 设置里关掉“自动转换 Kindle 不支持的图片”时为真，图片保留原样。
    pub keep_images: bool,
    pub image_options: kindle_images::Options,
    pub output_options: crate::edition_options::OutputOptions,
    pub navigation_options: crate::edition_options::NavigationOptions,
    pub title_sort: String,
    pub author_sort: String,
    pub book_producer: String,
    /// 去除原书字体、样式和附加 CSS。
    pub style: crate::epub_restyle::OriginalStyle,
}

/// 读 `bokai validate all` 的日志：正文、图片、外部链接、注音全部 100% 保留，书写方向与翻页方向保留时，
/// 返回没能保留的样式（如 `height`）；否则返回 None（内容有缺失）。
pub fn content_preserved(log: &str) -> Option<Vec<String>> {
    let score = |label: &str| {
        log.lines()
            .rev()
            .find(|l| l.trim_start().starts_with(label))
            .map(|l| l.to_owned())
    };
    for label in ["Ruby pairs:", "Text chars:", "External URLs:", "Images:"] {
        let line = score(label)?;
        let value = line
            .split(':')
            .nth(1)?
            .trim()
            .split('%')
            .next()?
            .trim()
            .parse::<f64>()
            .ok()?;
        if value < 100.0 {
            return None;
        }
    }
    for label in ["Writing mode:", "Page progression:"] {
        if !score(label)?.contains("preserved") || score(label)?.contains("not preserved") {
            return None;
        }
    }
    let mut dropped = Vec::new();
    let mut inside = false;
    for line in log.lines() {
        if line.starts_with("--- Dropped properties") {
            inside = true;
            continue;
        }
        if inside {
            let trimmed = line.trim();
            if trimmed.is_empty() || trimmed.starts_with("===") || trimmed.starts_with("---") {
                break;
            }
            if let Some(name) = trimmed.split_whitespace().nth(1) {
                dropped.push(name.to_owned());
            }
        }
    }
    Some(dropped)
}

/// 只包一张图的 SVG（可带 title / desc）换成 &lt;img&gt;；返回替换个数。其余 SVG 原样保留。
fn plain_svg_images(text: &str) -> (String, usize) {
    let href = regex::Regex::new(r#"(?:xlink:)?href\s*=\s*["']([^"']+)["']"#).expect("href");
    let title = regex::Regex::new(r"(?s)<title[^>]*>(.*?)</title>").expect("title");
    let strip = regex::Regex::new(r"(?s)<(title|desc)[^>]*>.*?</(title|desc)>").expect("strip");
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    let mut count = 0;
    while let Some(start) = rest.find("<svg") {
        let Some(end) = rest[start..].find("</svg>").map(|e| start + e + 6) else {
            break;
        };
        let element = &rest[start..end];
        let inner = element
            .find('>')
            .map(|i| &element[i + 1..element.len() - 6])
            .unwrap_or("");
        let bare = strip.replace_all(inner, "");
        let tags = bare.matches('<').count();
        let image = bare.trim_start().starts_with("<image") && tags == 1;
        match (image, href.captures(&bare)) {
            (true, Some(m)) => {
                let alt = title
                    .captures(inner)
                    .map(|c| c[1].trim().to_owned())
                    .unwrap_or_default();
                out.push_str(&rest[..start]);
                out.push_str(&format!(
                    "<img src=\"{}\" alt=\"{}\"/>",
                    &m[1],
                    alt.replace('"', "&quot;")
                ));
                count += 1;
            }
            _ => out.push_str(&rest[..end]),
        }
        rest = &rest[end..];
    }
    out.push_str(rest);
    (out, count)
}

#[derive(Debug, Default, Serialize)]
pub struct Report {
    pub images: Vec<Conversion>,
    pub unreadable_images: Vec<String>,
    /// Bokai 输入中换成 img 的 SVG 图片个数。
    pub svg_images_flattened: usize,
    pub cover_added: bool,
    pub metadata: Vec<&'static str>,
    /// 去掉的字体文件和它们的字节数。
    pub fonts_removed: usize,
    pub font_bytes_removed: u64,
    /// 去掉的样式声明条数，含 @font-face。
    pub css_removed: usize,
    /// 加了附加样式文件。
    pub css_added: bool,
}

fn escaped(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

fn decode_href(href: &str) -> String {
    let bytes = href.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && let Ok(v) = u8::from_str_radix(&href[i + 1..i + 3], 16)
        {
            out.push(v);
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

pub(crate) fn join(base: &str, href: &str) -> Option<String> {
    let href = decode_href(href.split(['#', '?']).next().unwrap_or(""));
    let mut parts: Vec<&str> = if base.is_empty() {
        Vec::new()
    } else {
        base.split('/').collect()
    };
    for part in href.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop()?;
            }
            p => parts.push(p),
        }
    }
    Some(parts.join("/"))
}

fn image_format(media: &str) -> Option<&'static str> {
    Some(match media.to_ascii_lowercase().as_str() {
        "image/png" => "png",
        "image/jpeg" | "image/jpg" => "jpg",
        "image/webp" => "webp",
        "image/gif" => "gif",
        "image/bmp" => "bmp",
        "image/tiff" => "tiff",
        "image/svg+xml" => "svg",
        _ => return None,
    })
}

/// 把元素 [range] 换成 [replacement]。
fn splice(text: &str, range: std::ops::Range<usize>, replacement: &str) -> String {
    format!(
        "{}{}{}",
        &text[..range.start],
        replacement,
        &text[range.end..]
    )
}

/// 元素的开始标签与结束标签原文（保留原前缀，如 dc:title）。
fn tags(text: &str, range: &std::ops::Range<usize>) -> Option<(String, String)> {
    let slice = &text[range.clone()];
    let open_end = slice.find('>')? + 1;
    let close_start = slice.rfind("</")?;
    (close_start >= open_end).then(|| {
        (
            slice[..open_end].to_owned(),
            slice[close_start..].to_owned(),
        )
    })
}

/// 在元素结束标签之前插入 [insert]。
fn insert_before_close(text: &str, range: &std::ops::Range<usize>, insert: &str) -> Option<String> {
    let close = text[range.clone()].rfind("</")? + range.start;
    Some(format!("{}{}{}", &text[..close], insert, &text[close..]))
}

impl Overrides {
    /// [kindling] 需要封面；[bokai] 把只包一张图的 SVG 换成 img。
    pub fn from_prepared(
        prepared: &crate::publication_resources::Prepared,
        kindling: bool,
        bokai: bool,
    ) -> Self {
        let m = prepared.manifest();
        let cover = m.cover.as_ref().and_then(|id| {
            let ext = id.rsplit('.').next().unwrap_or("png");
            prepared.image_bytes(id).map(|b| {
                (
                    b.to_vec(),
                    if ext == "png" {
                        "png".into()
                    } else {
                        "jpg".into()
                    },
                )
            })
        });
        Self {
            title: m.title.clone(),
            author: m.author.clone(),
            language: m.language.clone(),
            cover,
            need_cover: kindling,
            plain_svg_images: bokai,
            keep_images: m.keep_original_images,
            image_options: m.image_options.clone(),
            output_options: m.output_options.clone(),
            navigation_options: m.navigation_options.clone(),
            title_sort: m.title_sort.clone(),
            author_sort: m.author_sort.clone(),
            book_producer: m.book_producer.clone(),
            style: m.original_style.clone(),
        }
    }
}

/// 去除字体、过滤样式、加附加样式。没有设置时什么都不动。
fn restyle(
    entries: &mut Vec<(String, Vec<u8>)>,
    opf: &mut String,
    base: &str,
    style: &crate::epub_restyle::OriginalStyle,
    report: &mut Report,
) -> Result<(), ApiError> {
    use crate::epub_restyle::{EXTRA_CSS_FILE, Filter, is_font, strip_font_faces};
    use std::collections::BTreeSet;
    if style.is_default() {
        return Ok(());
    }
    fn lower_name(name: &str) -> String {
        name.to_ascii_lowercase()
    }
    fn is_page(name: &str) -> bool {
        let lower = lower_name(name);
        [".xhtml", ".html", ".htm"]
            .iter()
            .any(|e| lower.ends_with(e))
    }

    // 字体：清单、文件、混淆声明、@font-face。
    let mut families = BTreeSet::new();
    if style.remove_fonts {
        let mut removed = BTreeSet::new();
        let doc = crate::epub_xml::parse(opf).map_err(|_| invalid("choose_valid_epub_package"))?;
        let mut ranges = doc
            .descendants()
            .filter(|n| {
                n.tag_name().name() == "item"
                    && is_font(
                        n.attribute("media-type").unwrap_or(""),
                        n.attribute("href").unwrap_or(""),
                    )
            })
            .inspect(|n| {
                if let Some(path) = join(base, n.attribute("href").unwrap_or("")) {
                    removed.insert(path);
                }
            })
            .map(|n| n.range())
            .collect::<Vec<_>>();
        drop(doc);
        ranges.reverse();
        for range in ranges {
            *opf = splice(opf, range, "");
        }
        entries.retain(|(name, bytes)| {
            let gone = removed.contains(name) || is_font("", name);
            if gone {
                report.fonts_removed += 1;
                report.font_bytes_removed += bytes.len() as u64;
                removed.insert(name.clone());
            }
            !gone
        });
        if let Some(index) = entries
            .iter()
            .position(|e| e.0 == "META-INF/encryption.xml")
            && let Ok(xml) = String::from_utf8(entries[index].1.clone())
        {
            let doc = crate::epub_xml::parse(&xml).map_err(|_| invalid("choose_valid_epub_zip"))?;
            let all = doc
                .descendants()
                .filter(|n| n.tag_name().name() == "EncryptedData")
                .collect::<Vec<_>>();
            let mut gone = all
                .iter()
                .filter(|n| {
                    n.descendants()
                        .find(|c| c.tag_name().name() == "CipherReference")
                        .and_then(|c| c.attribute("URI"))
                        .is_some_and(|uri| removed.contains(&decode_href(uri)))
                })
                .map(|n| n.range())
                .collect::<Vec<_>>();
            let every = gone.len() == all.len();
            gone.reverse();
            drop(all);
            drop(doc);
            if every {
                entries.remove(index);
            } else {
                let mut next = xml;
                for range in gone {
                    next = splice(&next, range, "");
                }
                entries[index].1 = next.into_bytes();
            }
        }
        for (name, bytes) in entries.iter_mut() {
            if lower_name(name).ends_with(".css") {
                if let Ok(text) = std::str::from_utf8(bytes) {
                    let (next, count) = strip_font_faces(text, &mut families);
                    if count > 0 {
                        report.css_removed += count;
                        *bytes = next.into_bytes();
                    }
                }
            } else if is_page(name)
                && let Ok(text) = std::str::from_utf8(bytes)
                && text.contains("<style")
            {
                let mut count = 0;
                let next = style_blocks(text, |css| {
                    let (out, n) = strip_font_faces(css, &mut families);
                    count += n;
                    out
                });
                if count > 0 {
                    report.css_removed += count;
                    *bytes = next.into_bytes();
                }
            }
        }
    }

    // 过滤样式。
    if !style.filter_css.is_empty() || !families.is_empty() {
        let filter = Filter {
            properties: &style.filter_css,
            families: &families,
        };
        for (name, bytes) in entries.iter_mut() {
            let css = lower_name(name).ends_with(".css");
            if !css && !is_page(name) {
                continue;
            }
            let Ok(text) = std::str::from_utf8(bytes) else {
                continue;
            };
            let before = report.css_removed;
            let next = if css {
                filter.sheet(text, &mut report.css_removed)
            } else {
                filter.markup(text, &mut report.css_removed)
            };
            if report.css_removed != before {
                *bytes = next.into_bytes();
            }
        }
    }

    // 附加样式：一个新文件，链接到清单里的每个页面。
    let sheet = style.extra_sheet();
    if !sheet.is_empty() {
        let doc = crate::epub_xml::parse(opf).map_err(|_| invalid("choose_valid_epub_package"))?;
        let pages = doc
            .descendants()
            .filter(|n| {
                n.tag_name().name() == "item"
                    && n.attribute("media-type").unwrap_or("").contains("html")
            })
            .filter_map(|n| n.attribute("href").map(decode_href))
            .collect::<Vec<_>>();
        let manifest = doc
            .descendants()
            .find(|n| n.tag_name().name() == "manifest")
            .ok_or_else(|| invalid("choose_valid_epub_package"))?
            .range();
        drop(doc);
        for href in pages {
            let Some(path) = join(base, &href) else {
                continue;
            };
            let Some(entry) = entries.iter_mut().find(|e| e.0 == path) else {
                continue;
            };
            let Ok(text) = std::str::from_utf8(&entry.1) else {
                continue;
            };
            let up = "../".repeat(href.matches('/').count());
            if let Some(next) =
                crate::epub_restyle::link_sheet(text, &format!("{up}{EXTRA_CSS_FILE}"))
            {
                entry.1 = next.into_bytes();
            }
        }
        *opf = insert_before_close(
            opf,
            &manifest,
            &format!(
                "<item id=\"easypub-original-style\" href=\"{EXTRA_CSS_FILE}\" media-type=\"text/css\"/>"
            ),
        )
        .ok_or_else(|| invalid("choose_valid_epub_package"))?;
        let path = if base.is_empty() {
            EXTRA_CSS_FILE.to_owned()
        } else {
            format!("{base}/{EXTRA_CSS_FILE}")
        };
        entries.push((path, sheet.into_bytes()));
        report.css_added = true;
    }
    Ok(())
}

/// 改页面里每个 `<style>` 块的内容。
fn style_blocks(page: &str, mut change: impl FnMut(&str) -> String) -> String {
    let lower = page.to_ascii_lowercase();
    let mut out = String::with_capacity(page.len());
    let mut at = 0;
    while let Some(open) = lower[at..].find("<style") {
        let open = at + open;
        let Some(body) = lower[open..].find('>').map(|p| open + p + 1) else {
            break;
        };
        let Some(close) = lower[body..].find("</style").map(|p| body + p) else {
            break;
        };
        out.push_str(&page[at..body]);
        out.push_str(&change(&page[body..close]));
        at = close;
    }
    out.push_str(&page[at..]);
    out
}

pub fn rebuild(original: &[u8], overrides: &Overrides) -> Result<(Vec<u8>, Report), ApiError> {
    let mut archive =
        ZipArchive::new(Cursor::new(original)).map_err(|_| invalid("choose_valid_epub_zip"))?;
    if archive.len() > MAX_ENTRIES {
        return Err(ApiError::new(
            ErrorCode::TooLarge,
            "epub_passthrough",
            "reduce_epub_entry_count",
        ));
    }
    let mut entries: Vec<(String, Vec<u8>)> = Vec::new();
    let mut total = 0u64;
    for i in 0..archive.len() {
        let mut item = archive
            .by_index(i)
            .map_err(|_| invalid("choose_valid_epub_zip"))?;
        if item.is_dir() {
            continue;
        }
        let name = item.name().to_owned();
        if name.starts_with('/') || name.split('/').any(|p| p == "..") || name.contains('\\') {
            return Err(invalid("reject_unsafe_epub_resource_path"));
        }
        total += item.size();
        if total > MAX_UNCOMPRESSED {
            return Err(ApiError::new(
                ErrorCode::TooLarge,
                "epub_passthrough",
                "reduce_epub_file_size",
            ));
        }
        let mut bytes = Vec::new();
        item.read_to_end(&mut bytes)
            .map_err(|_| invalid("choose_valid_epub_zip"))?;
        entries.push((name, bytes));
    }
    let find = |entries: &[(String, Vec<u8>)], name: &str| entries.iter().position(|e| e.0 == name);
    let container = find(&entries, "META-INF/container.xml")
        .ok_or_else(|| invalid("choose_epub_with_package_document"))?;
    let container = String::from_utf8(entries[container].1.clone())
        .map_err(|_| invalid("choose_utf8_epub_container"))?;
    let opf_path = crate::epub_xml::parse(&container)
        .map_err(|_| invalid("choose_valid_epub_container"))?
        .descendants()
        .find(|n| {
            n.has_tag_name((
                "urn:oasis:names:tc:opendocument:xmlns:container",
                "rootfile",
            )) || n.tag_name().name() == "rootfile"
        })
        .and_then(|n| n.attribute("full-path"))
        .map(str::to_owned)
        .ok_or_else(|| invalid("choose_epub_with_package_document"))?;
    let opf_index =
        find(&entries, &opf_path).ok_or_else(|| invalid("choose_epub_with_package_document"))?;
    let mut opf = String::from_utf8(entries[opf_index].1.clone())
        .map_err(|_| invalid("choose_utf8_epub_package"))?;
    let base = opf_path
        .rsplit_once('/')
        .map(|(b, _)| b.to_owned())
        .unwrap_or_default();
    let mut report = Report::default();

    if overrides.style.remove_first_image {
        let doc = crate::epub_xml::parse(&opf).map_err(|_| invalid("choose_valid_epub_package"))?;
        let cover_id = doc
            .descendants()
            .find(|n| n.tag_name().name() == "meta" && n.attribute("name") == Some("cover"))
            .and_then(|n| n.attribute("content"));
        let cover = doc
            .descendants()
            .find(|n| {
                n.tag_name().name() == "item"
                    && (n.attribute("id").is_some_and(|id| Some(id) == cover_id)
                        || n.attribute("properties")
                            .unwrap_or("")
                            .split_whitespace()
                            .any(|v| v == "cover-image"))
            })
            .and_then(|n| n.attribute("href"))
            .and_then(|href| join(&base, href));
        'first: for itemref in doc
            .descendants()
            .filter(|n| n.tag_name().name() == "itemref")
        {
            let id = itemref.attribute("idref");
            let Some(path) = doc
                .descendants()
                .find(|n| n.tag_name().name() == "item" && n.attribute("id") == id)
                .and_then(|n| n.attribute("href"))
                .and_then(|href| join(&base, href))
            else {
                continue;
            };
            let Some(index) = find(&entries, &path) else {
                continue;
            };
            let Ok(text) = std::str::from_utf8(&entries[index].1) else {
                continue;
            };
            let text = crate::epub_xml::named_entities(text);
            let Ok(page) = crate::epub_xml::parse(&text) else {
                continue;
            };
            for image in page
                .descendants()
                .filter(|n| matches!(n.tag_name().name(), "img" | "image"))
            {
                let href = image
                    .attribute("src")
                    .or_else(|| image.attribute(("http://www.w3.org/1999/xlink", "href")))
                    .or_else(|| image.attribute("href"));
                let image_path = href
                    .and_then(|href| join(path.rsplit_once('/').map(|v| v.0).unwrap_or(""), href));
                if cover.is_some() && image_path == cover {
                    let next = splice(&text, image.range(), "");
                    entries[index].1 = next.into_bytes();
                }
                break 'first;
            }
        }
    }
    // 1. 图片
    struct Item {
        id: String,
        href: String,
        media: String,
        properties: String,
    }
    let (items, has_cover, epub3) = {
        let doc = crate::epub_xml::parse(&opf).map_err(|_| invalid("choose_valid_epub_package"))?;
        let items: Vec<Item> = doc
            .descendants()
            .filter(|n| n.tag_name().name() == "item")
            .map(|n| Item {
                id: n.attribute("id").unwrap_or("").to_owned(),
                href: n.attribute("href").unwrap_or("").to_owned(),
                media: n.attribute("media-type").unwrap_or("").to_owned(),
                properties: n.attribute("properties").unwrap_or("").to_owned(),
            })
            .collect();
        let meta_cover = doc
            .descendants()
            .any(|n| n.tag_name().name() == "meta" && n.attribute("name") == Some("cover"));
        let has_cover = meta_cover
            || items
                .iter()
                .any(|i| i.properties.split_whitespace().any(|p| p == "cover-image"));
        let epub3 = doc
            .root_element()
            .attribute("version")
            .is_some_and(|v| v.starts_with('3'));
        (items, has_cover, epub3)
    };
    let cover_item = crate::epub_xml::parse(&opf).ok().and_then(|doc| {
        doc.descendants()
            .find(|n| n.tag_name().name() == "meta" && n.attribute("name") == Some("cover"))
            .and_then(|n| n.attribute("content").map(str::to_owned))
    });
    let mut renames: Vec<(String, String, String)> = Vec::new(); // (id, 旧文件名, 新文件名)
    for item in &items {
        // 关掉自动转换时图片保留原样。
        if overrides.keep_images {
            break;
        }
        let Some(format) = image_format(&item.media) else {
            continue;
        };
        let Some(zip_path) = join(&base, &item.href) else {
            continue;
        };
        let Some(index) = find(&entries, &zip_path) else {
            continue;
        };
        let data = entries[index].1.clone();
        let converted = if format == "svg" || format == "tiff" {
            match kindle_images::import_ready(&data, &item.media) {
                Ok(Some((bytes, ext, _))) => {
                    let (w, h) = image::load_from_memory(&bytes)
                        .map(|i| (i.width(), i.height()))
                        .unwrap_or((0, 0));
                    Some((
                        bytes,
                        ext,
                        Conversion {
                            path: zip_path.clone(),
                            from_format: format.into(),
                            from_width: 0,
                            from_height: 0,
                            from_bytes: data.len() as u64,
                            to_format: ext.into(),
                            to_width: w,
                            to_height: h,
                            to_bytes: 0,
                            reasons: vec!["format"],
                        },
                    ))
                }
                _ => None,
            }
        } else {
            let dims = image::ImageReader::new(Cursor::new(&data))
                .with_guessed_format()
                .ok()
                .and_then(|r| r.into_dimensions().ok());
            match dims {
                None => None,
                Some((width, height)) => {
                    let snapshot = ImageSnapshot {
                        evidence: ImageEvidence {
                            path: zip_path.clone(),
                            sha256: String::new(),
                            bytes: data.len() as u64,
                            width,
                            height,
                            format: format.into(),
                        },
                        bytes: data.clone(),
                    };
                    match kindle_images::kindle_ready_with(
                        snapshot,
                        &overrides.image_options,
                        cover_item.as_ref() == Some(&item.id)
                            || item
                                .properties
                                .split_whitespace()
                                .any(|p| p == "cover-image"),
                    ) {
                        Ok((_, None)) => continue,
                        Ok((out, Some(c))) => {
                            let ext: &'static str = if out.evidence.format == "png" {
                                "png"
                            } else {
                                "jpg"
                            };
                            Some((out.bytes, ext, c))
                        }
                        Err(_) => None,
                    }
                }
            }
        };
        let Some((mut bytes, mut ext, mut conversion)) = converted else {
            report.unreadable_images.push(zip_path);
            continue;
        };
        if matches!(format, "svg" | "tiff") {
            let source = ImageSnapshot {
                evidence: ImageEvidence {
                    path: zip_path.clone(),
                    sha256: String::new(),
                    bytes: bytes.len() as u64,
                    width: conversion.to_width,
                    height: conversion.to_height,
                    format: ext.into(),
                },
                bytes,
            };
            let (out, changed) = kindle_images::kindle_ready_with(
                source,
                &overrides.image_options,
                cover_item.as_ref() == Some(&item.id)
                    || item
                        .properties
                        .split_whitespace()
                        .any(|p| p == "cover-image"),
            )?;
            if let Some(changed) = changed {
                conversion.to_width = changed.to_width;
                conversion.to_height = changed.to_height;
                conversion.reasons.extend(changed.reasons);
            }
            ext = if out.evidence.format == "png" {
                "png"
            } else {
                "jpg"
            };
            conversion.to_format = ext.into();
            bytes = out.bytes;
        }
        conversion.to_bytes = bytes.len() as u64;
        let same_format = (format == "jpg" && ext == "jpg") || (format == "png" && ext == "png");
        if same_format {
            entries[index].1 = bytes;
        } else {
            let file = zip_path.rsplit('/').next().unwrap_or(&zip_path).to_owned();
            let new_file = format!("{file}.{ext}");
            entries[index] = (format!("{zip_path}.{ext}"), bytes);
            renames.push((item.id.clone(), file, new_file));
        }
        report.images.push(conversion);
    }
    // 引用改写：文件名后面紧跟引号、括号、#、? 或空白时才替换，避免误改相似文字。
    let rewrite = |text: &str| -> Option<String> {
        let mut out = text.to_owned();
        let mut changed = false;
        for (_, old, new) in &renames {
            for tail in ['"', '\'', ')', '#', '?', ' ', '\n'] {
                let from = format!("{old}{tail}");
                if out.contains(&from) {
                    out = out.replace(&from, &format!("{new}{tail}"));
                    changed = true;
                }
            }
        }
        changed.then_some(out)
    };
    if !renames.is_empty() {
        for (name, bytes) in entries.iter_mut() {
            let lower = name.to_ascii_lowercase();
            if *name == opf_path
                || ![".xhtml", ".html", ".htm", ".css", ".ncx", ".svg", ".xml"]
                    .iter()
                    .any(|e| lower.ends_with(e))
            {
                continue;
            }
            if let Ok(text) = std::str::from_utf8(bytes)
                && let Some(next) = rewrite(text)
            {
                *bytes = next.into_bytes();
            }
        }
        if let Some(next) = rewrite(&opf) {
            opf = next;
        }
        // 清单里改名项的媒体类型。
        for (id, _, new) in &renames {
            let media = if new.ends_with(".png") {
                "image/png"
            } else {
                "image/jpeg"
            };
            let doc =
                crate::epub_xml::parse(&opf).map_err(|_| invalid("choose_valid_epub_package"))?;
            let Some(node) = doc
                .descendants()
                .find(|n| n.tag_name().name() == "item" && n.attribute("id") == Some(id.as_str()))
            else {
                continue;
            };
            let range = node.range();
            let element = &opf[range.clone()];
            let Some(at) = element.find("media-type=") else {
                continue;
            };
            let quote = element[at + 11..].chars().next().unwrap_or('"');
            let start = at + 12;
            let Some(len) = element[start..].find(quote) else {
                continue;
            };
            let replaced = format!("{}{}{}", &element[..start], media, &element[start + len..]);
            opf = splice(&opf, range, &replaced);
        }
    }

    // 1b. Bokai：只包一张图的 SVG 换成 img
    if overrides.plain_svg_images {
        for (name, bytes) in entries.iter_mut() {
            let lower = name.to_ascii_lowercase();
            if !(lower.ends_with(".xhtml") || lower.ends_with(".html") || lower.ends_with(".htm")) {
                continue;
            }
            if let Ok(text) = std::str::from_utf8(bytes)
                && text.contains("<svg")
            {
                let (next, count) = plain_svg_images(text);
                if count > 0 {
                    report.svg_images_flattened += count;
                    *bytes = next.into_bytes();
                }
            }
        }
    }

    // 1c. 原书样式
    restyle(&mut entries, &mut opf, &base, &overrides.style, &mut report)?;
    let opf_index =
        find(&entries, &opf_path).ok_or_else(|| invalid("choose_epub_with_package_document"))?;

    // 2. 书目
    for (local, value, label) in [
        ("title", overrides.title.trim(), "title"),
        ("creator", overrides.author.trim(), "author"),
        ("language", overrides.language.trim(), "language"),
    ] {
        if value.is_empty() {
            continue;
        }
        let doc = crate::epub_xml::parse(&opf).map_err(|_| invalid("choose_valid_epub_package"))?;
        let dc = "http://purl.org/dc/elements/1.1/";
        let found = doc.descendants().find(|n| n.has_tag_name((dc, local)));
        match found {
            Some(node) if node.text().map(str::trim) == Some(value) => {}
            Some(node) => {
                let range = node.range();
                if let Some((open, close)) = tags(&opf, &range) {
                    opf = splice(&opf, range, &format!("{open}{}{close}", escaped(value)));
                    report.metadata.push(label);
                }
            }
            None => {
                let Some(metadata) = doc
                    .descendants()
                    .find(|n| n.tag_name().name() == "metadata")
                else {
                    continue;
                };
                let range = metadata.range();
                let prefix =
                    if opf[range.clone()].contains("xmlns:dc=") || opf.contains("xmlns:dc=") {
                        ""
                    } else {
                        " xmlns:dc=\"http://purl.org/dc/elements/1.1/\""
                    };
                if let Some(next) = insert_before_close(
                    &opf,
                    &range,
                    &format!("<dc:{local}{prefix}>{}</dc:{local}>", escaped(value)),
                ) {
                    opf = next;
                    report.metadata.push(label);
                }
            }
        }
    }

    // 3. 封面
    if overrides.need_cover && !has_cover {
        let Some((bytes, ext)) = &overrides.cover else {
            return Err(ApiError::new(
                ErrorCode::InvalidRule,
                "kindling_input",
                "choose_cover_before_kindling_export",
            ));
        };
        let file = format!("easypub-cover.{ext}");
        let zip_path = if base.is_empty() {
            file.clone()
        } else {
            format!("{base}/{file}")
        };
        let media = if ext == "png" {
            "image/png"
        } else {
            "image/jpeg"
        };
        let properties = if epub3 {
            " properties=\"cover-image\""
        } else {
            ""
        };
        let doc = crate::epub_xml::parse(&opf).map_err(|_| invalid("choose_valid_epub_package"))?;
        let manifest = doc
            .descendants()
            .find(|n| n.tag_name().name() == "manifest")
            .ok_or_else(|| invalid("choose_valid_epub_package"))?
            .range();
        let metadata = doc
            .descendants()
            .find(|n| n.tag_name().name() == "metadata")
            .ok_or_else(|| invalid("choose_valid_epub_package"))?
            .range();
        drop(doc);
        // 先改靠后的元素，前面的位置不受影响。
        let item = format!(
            "<item id=\"easypub-cover\" href=\"{file}\" media-type=\"{media}\"{properties}/>"
        );
        let meta = "<meta name=\"cover\" content=\"easypub-cover\"/>";
        let (first, second) = if manifest.start > metadata.start {
            ((manifest, item), (metadata, meta.to_owned()))
        } else {
            ((metadata, meta.to_owned()), (manifest, item))
        };
        opf = insert_before_close(&opf, &first.0, &first.1)
            .ok_or_else(|| invalid("choose_valid_epub_package"))?;
        opf = insert_before_close(&opf, &second.0, &second.1)
            .ok_or_else(|| invalid("choose_valid_epub_package"))?;
        entries.push((zip_path, bytes.clone()));
        report.cover_added = true;
    }
    // Keep an existing authored sort key; generate pinyin only when absent.
    let sort_doc =
        crate::epub_xml::parse(&opf).map_err(|_| invalid("choose_valid_epub_package"))?;
    let sort_value = |tag: &str, name: &str, explicit: &str| {
        if !explicit.is_empty() {
            return explicit.to_owned();
        }
        // A bare resource-only rebuild must not invent bibliographic overrides.
        if overrides.title.is_empty() && overrides.author.is_empty() {
            return String::new();
        }
        let node = sort_doc.descendants().find(|n| n.tag_name().name() == tag);
        let existing = sort_doc
            .descendants()
            .any(|n| n.tag_name().name() == "meta" && n.attribute("name") == Some(name))
            || node.is_some_and(|n| {
                n.attributes().any(|a| a.name() == "file-as")
                    || n.attribute("id").is_some_and(|id| {
                        sort_doc.descendants().any(|m| {
                            m.attribute("property") == Some("file-as")
                                && m.attribute("refines") == Some(format!("#{id}").as_str())
                        })
                    })
            });
        if existing {
            String::new()
        } else {
            easypub_core::rare_chars::sort_key(node.and_then(|n| n.text()).unwrap_or(""))
        }
    };
    let title_sort = sort_value("title", "calibre:title_sort", &overrides.title_sort);
    let author_sort = sort_value("creator", "calibre:author_sort", &overrides.author_sort);
    drop(sort_doc);
    // Explicit sort keys must also reach engines which read OPF file-as.
    for (tag, value) in [("title", &title_sort), ("creator", &author_sort)] {
        if value.is_empty() {
            continue;
        }
        let doc = crate::epub_xml::parse(&opf).map_err(|_| invalid("choose_valid_epub_package"))?;
        let mut edits = Vec::new();
        for node in doc.descendants().filter(|n| n.tag_name().name() == tag) {
            if let Some(attr) = node.attributes().find(|a| a.name() == "file-as") {
                edits.push((attr.range(), format!("opf:file-as=\"{}\"", escaped(value))));
            } else {
                let start = node.range().start;
                if let Some(end) = opf[start..].find('>') {
                    let pos = start + end;
                    let namespace = if node.lookup_namespace_uri(Some("opf")).is_some() {
                        ""
                    } else {
                        " xmlns:opf=\"http://www.idpf.org/2007/opf\""
                    };
                    edits.push((
                        pos..pos,
                        format!("{namespace} opf:file-as=\"{}\"", escaped(value)),
                    ));
                }
            }
        }
        edits.sort_by_key(|(range, _)| std::cmp::Reverse(range.start));
        for (range, value) in edits {
            opf.replace_range(range, &value);
        }
    }
    let mut extra = String::new();
    for (name, value) in [
        ("calibre:title_sort", &title_sort),
        ("calibre:author_sort", &author_sort),
    ] {
        if !value.is_empty() {
            let doc =
                crate::epub_xml::parse(&opf).map_err(|_| invalid("choose_valid_epub_package"))?;
            let mut ranges: Vec<_> = doc
                .descendants()
                .filter(|n| n.tag_name().name() == "meta" && n.attribute("name") == Some(name))
                .map(|n| n.range())
                .collect();
            ranges.sort_by_key(|r| std::cmp::Reverse(r.start));
            for range in ranges {
                opf.replace_range(range, "");
            }
            extra.push_str(&format!(
                "<meta name=\"{name}\" content=\"{}\"/>",
                escaped(value)
            ));
        }
    }
    if !overrides.book_producer.is_empty() {
        extra.push_str(&format!(
            "<dc:contributor xmlns:dc=\"http://purl.org/dc/elements/1.1/\">{}</dc:contributor>",
            escaped(&overrides.book_producer)
        ));
    }
    if overrides.plain_svg_images && overrides.output_options.document_type != "default" {
        extra.push_str(&format!(
            "<meta name=\"easypub:document-type\" content=\"{}\"/>",
            overrides.output_options.document_type
        ));
    }
    if !extra.is_empty() {
        let doc = crate::epub_xml::parse(&opf).map_err(|_| invalid("choose_valid_epub_package"))?;
        let range = doc
            .descendants()
            .find(|n| n.tag_name().name() == "metadata")
            .ok_or_else(|| invalid("choose_valid_epub_package"))?
            .range();
        opf = insert_before_close(&opf, &range, &extra)
            .ok_or_else(|| invalid("choose_valid_epub_package"))?;
    }
    if overrides.navigation_options.apply_to_original {
        crate::original_navigation::rewrite(
            &mut entries,
            &mut opf,
            &base,
            &overrides.navigation_options,
        )?;
    }
    if overrides.output_options.epub_version == 2
        && !overrides.need_cover
        && !overrides.plain_svg_images
    {
        let doc = crate::epub_xml::parse(&opf).map_err(|_| invalid("choose_valid_epub_package"))?;
        let existing_ncx = doc
            .descendants()
            .find(|n| {
                n.tag_name().name() == "item"
                    && n.attribute("media-type") == Some("application/x-dtbncx+xml")
            })
            .and_then(|n| n.attribute("id"))
            .map(str::to_owned);
        let mut edits = Vec::new();
        let ncx_id = existing_ncx.clone().unwrap_or_else(|| "easypub-ncx".into());
        if existing_ncx.is_none() {
            let nav_path = doc
                .descendants()
                .find(|n| {
                    n.tag_name().name() == "item"
                        && n.attribute("properties")
                            .unwrap_or("")
                            .split_whitespace()
                            .any(|p| p == "nav")
                })
                .and_then(|n| n.attribute("href"))
                .and_then(|h| join(&base, h))
                .ok_or_else(|| invalid("choose_epub_with_navigation"))?;
            let index =
                find(&entries, &nav_path).ok_or_else(|| invalid("choose_epub_with_navigation"))?;
            let nav = std::str::from_utf8(&entries[index].1)
                .map_err(|_| invalid("choose_epub_with_navigation"))?;
            let ncx =
                crate::kindling_navigation::prepare(nav, &overrides.title, "easypub-original")?;
            // NCX beside the source nav preserves relative link targets.
            let ncx_path = format!("{}.ncx", nav_path);
            let href = ncx_path
                .strip_prefix(&format!("{base}/"))
                .unwrap_or(&ncx_path);
            let manifest = doc
                .descendants()
                .find(|n| n.tag_name().name() == "manifest")
                .unwrap();
            let close = manifest.range().start + opf[manifest.range()].rfind("</").unwrap();
            edits.push((close..close, format!("<item id=\"easypub-ncx\" href=\"{}\" media-type=\"application/x-dtbncx+xml\"/>", escaped(href))));
            entries.push((ncx_path, ncx.into_bytes()));
        }
        for node in doc.descendants().filter(|n| n.is_element()) {
            if node.tag_name().name() == "meta" && node.attribute("property").is_some() {
                edits.push((node.range(), String::new()));
                continue;
            }
            for attr in node.attributes() {
                if attr.name() == "properties" || attr.name() == "page-progression-direction" {
                    edits.push((attr.range(), String::new()));
                }
                if node.tag_name().name() == "package" && attr.name() == "version" {
                    edits.push((attr.range(), "version=\"2.0\"".into()));
                }
            }
            if node.tag_name().name() == "spine" && node.attribute("toc").is_none() {
                let at = node.range().start + opf[node.range()].find('>').unwrap();
                edits.push((at..at, format!(" toc=\"{ncx_id}\"")));
            }
        }
        edits.sort_by_key(|(range, _)| std::cmp::Reverse(range.start));
        for (range, replacement) in edits {
            opf.replace_range(range, &replacement);
        }
    }
    if !overrides.need_cover && !overrides.plain_svg_images {
        let epub2 = crate::epub_xml::parse(&opf)
            .map_err(|_| invalid("choose_valid_epub_package"))?
            .root_element()
            .attribute("version")
            == Some("2.0");
        opf = crate::edition_options::standard_sort_metadata(&opf, epub2)?;
    }
    crate::epub_xml::parse(&opf).map_err(|_| invalid("choose_valid_epub_package"))?;
    entries[opf_index].1 = opf.into_bytes();

    // 4. 重新打包：mimetype 不压缩且在最前。
    let mut zip = ZipWriter::new(Cursor::new(Vec::new()));
    zip.start_file(
        "mimetype",
        SimpleFileOptions::default().compression_method(CompressionMethod::Stored),
    )
    .map_err(|_| invalid("retry_export"))?;
    zip.write_all(b"application/epub+zip")
        .map_err(|_| invalid("retry_export"))?;
    let options = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
    for (name, bytes) in &entries {
        if name == "mimetype" {
            continue;
        }
        zip.start_file(name, options)
            .map_err(|_| invalid("retry_export"))?;
        let compatible;
        let bytes = if overrides.output_options.epub_version == 2
            && !overrides.need_cover
            && !overrides.plain_svg_images
            && (name.ends_with(".xhtml") || name.ends_with(".html"))
        {
            compatible = crate::edition_options::epub2_page(
                std::str::from_utf8(bytes).map_err(|_| invalid("choose_valid_epub_package"))?,
            )
            .into_bytes();
            compatible.as_slice()
        } else {
            bytes.as_slice()
        };
        zip.write_all(bytes).map_err(|_| invalid("retry_export"))?;
    }
    let bytes = zip
        .finish()
        .map_err(|_| invalid("retry_export"))?
        .into_inner();
    Ok((bytes, report))
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{DynamicImage, ImageBuffer, ImageFormat, Rgb};

    fn encoded(format: ImageFormat, w: u32, h: u32) -> Vec<u8> {
        let mut out = Cursor::new(Vec::new());
        DynamicImage::ImageRgb8(ImageBuffer::from_pixel(w, h, Rgb([90, 60, 30])))
            .write_to(&mut out, format)
            .unwrap();
        out.into_inner()
    }

    fn epub(opf: &str, files: &[(&str, Vec<u8>)]) -> Vec<u8> {
        let mut zip = ZipWriter::new(Cursor::new(Vec::new()));
        let opts = SimpleFileOptions::default();
        zip.start_file("mimetype", opts).unwrap();
        zip.write_all(b"application/epub+zip").unwrap();
        zip.start_file("META-INF/container.xml", opts).unwrap();
        zip.write_all(br#"<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#).unwrap();
        zip.start_file("OEBPS/content.opf", opts).unwrap();
        zip.write_all(opf.as_bytes()).unwrap();
        for (name, bytes) in files {
            zip.start_file(*name, opts).unwrap();
            zip.write_all(bytes).unwrap();
        }
        zip.finish().unwrap().into_inner()
    }

    fn read(bytes: &[u8]) -> Vec<(String, Vec<u8>)> {
        let mut archive = ZipArchive::new(Cursor::new(bytes)).unwrap();
        (0..archive.len())
            .map(|i| {
                let mut f = archive.by_index(i).unwrap();
                let mut b = Vec::new();
                f.read_to_end(&mut b).unwrap();
                (f.name().to_owned(), b)
            })
            .collect()
    }

    const OPF: &str = r#"<?xml version="1.0" encoding="UTF-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">x</dc:identifier><dc:title>原书名</dc:title><dc:language>zh</dc:language></metadata><manifest><item id="c1" href="text/c1.xhtml" media-type="application/xhtml+xml"/><item id="pic" href="images/plate.webp" media-type="image/webp"/><item id="big" href="images/big.jpg" media-type="image/jpeg"/><item id="css" href="style.css" media-type="text/css"/></manifest><spine><itemref idref="c1"/></spine></package>"#;

    const STYLED: &str = r#"<?xml version="1.0" encoding="UTF-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>甲</dc:title><dc:identifier id="id">urn:x</dc:identifier><dc:language>zh</dc:language></metadata><manifest><item id="c1" href="text/c1.xhtml" media-type="application/xhtml+xml"/><item id="css" href="style.css" media-type="text/css"/><item id="f1" href="fonts/a.ttf" media-type="font/ttf"/><item id="f2" href="fonts/b.woff" media-type="application/font-woff"/></manifest><spine><itemref idref="c1"/></spine></package>"#;

    fn styled() -> Vec<u8> {
        epub(
            STYLED,
            &[
                (
                    "OEBPS/text/c1.xhtml",
                    "<html><head><title>甲</title><style>@font-face{font-family:C;src:url(c.ttf)}</style></head><body><p style=\"color:red;font-family:'Song A',serif\">原文段落。</p></body></html>".as_bytes().to_vec(),
                ),
                (
                    "OEBPS/style.css",
                    b"@font-face{font-family:'Song A';src:url(fonts/a.ttf)}p{color:red;font-family:'Song A',serif;text-indent:2em}".to_vec(),
                ),
                ("OEBPS/fonts/a.ttf", vec![1; 1000]),
                ("OEBPS/fonts/b.woff", vec![2; 500]),
                (
                    "META-INF/encryption.xml",
                    b"<encryption xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\" xmlns:enc=\"http://www.w3.org/2001/04/xmlenc#\"><enc:EncryptedData><enc:CipherData><enc:CipherReference URI=\"OEBPS/fonts/a.ttf\"/></enc:CipherData></enc:EncryptedData></encryption>".to_vec(),
                ),
            ],
        )
    }

    fn with_style(style: crate::epub_restyle::OriginalStyle) -> Overrides {
        Overrides {
            title: String::new(),
            author: String::new(),
            language: String::new(),
            cover: None,
            need_cover: false,
            plain_svg_images: false,
            keep_images: false,
            image_options: Default::default(),
            output_options: Default::default(),
            navigation_options: Default::default(),
            title_sort: String::new(),
            author_sort: String::new(),
            book_producer: String::new(),
            style,
        }
    }

    fn text_of(files: &[(String, Vec<u8>)], name: &str) -> String {
        String::from_utf8(files.iter().find(|f| f.0 == name).unwrap().1.clone()).unwrap()
    }

    #[test]
    fn nothing_changes_without_settings() {
        let original = styled();
        let (bytes, report) = rebuild(&original, &with_style(Default::default())).unwrap();
        let (a, b) = (read(&original), read(&bytes));
        for (name, data) in &a {
            assert_eq!(b.iter().find(|f| f.0 == *name).unwrap().1, *data, "{name}");
        }
        assert_eq!(report.fonts_removed, 0);
        assert!(!report.css_added);
    }

    #[test]
    fn removing_fonts_cleans_files_manifest_declarations_and_obfuscation() {
        let (bytes, report) = rebuild(
            &styled(),
            &with_style(crate::epub_restyle::OriginalStyle {
                remove_fonts: true,
                ..Default::default()
            }),
        )
        .unwrap();
        let files = read(&bytes);
        assert!(!files.iter().any(|f| f.0.contains("fonts/")));
        assert!(!files.iter().any(|f| f.0 == "META-INF/encryption.xml"));
        assert_eq!(report.fonts_removed, 2);
        assert_eq!(report.font_bytes_removed, 1500);
        let opf = text_of(&files, "OEBPS/content.opf");
        assert!(!opf.contains("font") && opf.contains("style.css"), "{opf}");
        let css = text_of(&files, "OEBPS/style.css");
        assert_eq!(css, "p{color:red;font-family:serif;text-indent:2em}");
        let page = text_of(&files, "OEBPS/text/c1.xhtml");
        assert!(!page.contains("font-face"), "{page}");
        assert!(
            page.contains("font-family:serif") && page.contains("原文段落。"),
            "{page}"
        );
    }

    #[test]
    fn filters_and_extra_sheet_reach_every_page_from_the_right_folder() {
        let (bytes, report) = rebuild(
            &styled(),
            &with_style(crate::epub_restyle::OriginalStyle {
                filter_css: vec!["color".into(), "text-indent".into()],
                extra_css: "p { line-height: 1.5; }".into(),
                margin_left: "2em".into(),
                ..Default::default()
            }),
        )
        .unwrap();
        let files = read(&bytes);
        assert!(
            files.iter().any(|f| f.0 == "OEBPS/fonts/a.ttf"),
            "没要求去字体"
        );
        assert_eq!(report.css_removed, 3);
        assert!(report.css_added);
        let css = text_of(&files, "OEBPS/style.css");
        assert!(
            !css.contains("color") && !css.contains("text-indent"),
            "{css}"
        );
        let page = text_of(&files, "OEBPS/text/c1.xhtml");
        assert!(
            page.contains("href=\"../easypub-original-style.css\"/></head>"),
            "{page}"
        );
        let added = text_of(&files, "OEBPS/easypub-original-style.css");
        assert_eq!(
            added,
            "body { margin-left: 2em !important; }\np { line-height: 1.5; }\n"
        );
        let opf = text_of(&files, "OEBPS/content.opf");
        assert!(opf.contains("href=\"easypub-original-style.css\""), "{opf}");
    }

    #[test]
    fn webp_is_renamed_and_references_follow_metadata_and_cover_are_written() {
        let xhtml = r#"<html><body><p class="正文">原文段落保持不变。</p><img src="../images/plate.webp" alt="图"/><img src="../images/big.jpg"/></body></html>"#;
        let css = "body{background:url(images/plate.webp)} .plate.webpx{}";
        let original = epub(
            OPF,
            &[
                ("OEBPS/text/c1.xhtml", xhtml.as_bytes().to_vec()),
                (
                    "OEBPS/images/plate.webp",
                    encoded(ImageFormat::WebP, 10, 10),
                ),
                (
                    "OEBPS/images/big.jpg",
                    encoded(ImageFormat::Jpeg, 3000, 1000),
                ),
                ("OEBPS/style.css", css.as_bytes().to_vec()),
            ],
        );
        let (bytes, report) = rebuild(
            &original,
            &Overrides {
                title: "新书名 & 副题".into(),
                author: "作者甲".into(),
                language: "zh".into(),
                cover: Some((encoded(ImageFormat::Png, 4, 6), "png".into())),
                need_cover: true,
                plain_svg_images: false,
                keep_images: false,
                image_options: Default::default(),
                output_options: Default::default(),
                navigation_options: Default::default(),
                title_sort: String::new(),
                author_sort: String::new(),
                book_producer: String::new(),
                style: Default::default(),
            },
        )
        .unwrap();
        let files = read(&bytes);
        assert_eq!(files[0].0, "mimetype");
        let get = |name: &str| files.iter().find(|f| f.0 == name).map(|f| f.1.clone());
        // WebP 改名为 .webp.jpg 并转成 JPEG；超大 JPEG 原名保留、缩小。
        assert!(get("OEBPS/images/plate.webp").is_none());
        let jpg = get("OEBPS/images/plate.webp.jpg").unwrap();
        assert_eq!(image::guess_format(&jpg).unwrap(), ImageFormat::Jpeg);
        let big = image::load_from_memory(&get("OEBPS/images/big.jpg").unwrap()).unwrap();
        assert_eq!((big.width(), big.height()), (2560, 853));
        assert_eq!(report.images.len(), 2);
        // 引用随之改写；相似的文字不误改；正文其余字节不变。
        let page = String::from_utf8(get("OEBPS/text/c1.xhtml").unwrap()).unwrap();
        assert_eq!(page, xhtml.replace("plate.webp\"", "plate.webp.jpg\""));
        let style = String::from_utf8(get("OEBPS/style.css").unwrap()).unwrap();
        assert_eq!(
            style,
            "body{background:url(images/plate.webp.jpg)} .plate.webpx{}"
        );
        let opf = String::from_utf8(get("OEBPS/content.opf").unwrap()).unwrap();
        assert!(
            opf.contains(
                r#"<item id="pic" href="images/plate.webp.jpg" media-type="image/jpeg"/>"#
            ),
            "{opf}"
        );
        // 书目与封面。
        let metadata = Document::parse(&opf).unwrap();
        assert_eq!(
            metadata
                .descendants()
                .find(|n| n.tag_name().name() == "title")
                .unwrap()
                .text(),
            Some("新书名 & 副题")
        );
        assert_eq!(
            metadata
                .descendants()
                .find(|n| n.tag_name().name() == "creator")
                .unwrap()
                .text(),
            Some("作者甲")
        );
        assert!(opf.contains("calibre:title_sort") && opf.contains("calibre:author_sort"));
        assert!(opf.contains(r#"<item id="easypub-cover" href="easypub-cover.png" media-type="image/png" properties="cover-image"/>"#));
        assert!(opf.contains(r#"<meta name="cover" content="easypub-cover"/>"#));
        assert!(get("OEBPS/easypub-cover.png").is_some());
        assert!(report.cover_added);
        assert_eq!(report.metadata, vec!["title", "author"]);
        Document::parse(&opf).unwrap();
    }

    #[test]
    fn existing_cover_is_kept_and_missing_cover_without_fallback_is_an_error() {
        let with_cover = OPF.replace(
            r#"media-type="image/webp"/>"#,
            r#"media-type="image/webp" properties="cover-image"/>"#,
        );
        let original = epub(
            &with_cover,
            &[("OEBPS/images/plate.webp", encoded(ImageFormat::WebP, 4, 4))],
        );
        let overrides = Overrides {
            title: String::new(),
            author: String::new(),
            language: String::new(),
            cover: None,
            need_cover: true,
            plain_svg_images: false,
            keep_images: false,
            image_options: Default::default(),
            output_options: Default::default(),
            navigation_options: Default::default(),
            title_sort: String::new(),
            author_sort: String::new(),
            book_producer: String::new(),
            style: Default::default(),
        };
        let (_, report) = rebuild(&original, &overrides).unwrap();
        assert!(!report.cover_added);
        let plain = epub(OPF, &[]);
        assert_eq!(
            rebuild(&plain, &overrides).unwrap_err().next_action,
            "choose_cover_before_kindling_export"
        );
        // EPUB 输出不需要封面。
        let epub_out = Overrides {
            need_cover: false,
            ..overrides
        };
        assert!(rebuild(&plain, &epub_out).is_ok());
    }

    #[test]
    fn svg_wrapped_cover_becomes_img_only_for_bokai() {
        let page = r#"<body><div class="cover"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 12 16"><title>样书</title><image width="12" height="16" xlink:href="cover.png"/></svg></div><svg><rect width="1" height="1"/></svg></body>"#;
        let (out, count) = plain_svg_images(page);
        assert_eq!(count, 1);
        assert_eq!(
            out,
            r#"<body><div class="cover"><img src="cover.png" alt="样书"/></div><svg><rect width="1" height="1"/></svg></body>"#
        );
        let original = epub(OPF, &[("OEBPS/text/c1.xhtml", page.as_bytes().to_vec())]);
        let base = Overrides {
            title: String::new(),
            author: String::new(),
            language: String::new(),
            cover: None,
            need_cover: false,
            plain_svg_images: false,
            keep_images: false,
            image_options: Default::default(),
            output_options: Default::default(),
            navigation_options: Default::default(),
            title_sort: String::new(),
            author_sort: String::new(),
            book_producer: String::new(),
            style: Default::default(),
        };
        let (bytes, report) = rebuild(&original, &base).unwrap();
        assert_eq!(report.svg_images_flattened, 0);
        assert!(
            String::from_utf8(
                read(&bytes)
                    .into_iter()
                    .find(|f| f.0 == "OEBPS/text/c1.xhtml")
                    .unwrap()
                    .1
            )
            .unwrap()
            .contains("<svg")
        );
        let bokai = Overrides {
            plain_svg_images: true,
            keep_images: false,
            image_options: Default::default(),
            output_options: Default::default(),
            navigation_options: Default::default(),
            title_sort: String::new(),
            author_sort: String::new(),
            book_producer: String::new(),
            style: Default::default(),
            ..base
        };
        let (bytes, report) = rebuild(&original, &bokai).unwrap();
        assert_eq!(report.svg_images_flattened, 1);
        let text = String::from_utf8(
            read(&bytes)
                .into_iter()
                .find(|f| f.0 == "OEBPS/text/c1.xhtml")
                .unwrap()
                .1,
        )
        .unwrap();
        assert!(text.contains(r#"<img src="cover.png" alt="样书"/>"#));
    }

    /// 摘自真实的 `bokai validate all` 输出（测试中的 KFX 转换）。
    const LOG: &str = "--- Dropped properties [first 10] (sorted by frequency) ---\n      1×  height                            e.g. \"100vh\"\n\n=== Tags ===\n=== Scorecard ===\n  Ruby pairs:   100.00% preserved\n  Text chars:   100.0000% preserved\n  CSS props:    98.61% covered\n  HTML tags:    22.22% semantic\n  External URLs:100.00% preserved\n  Images:       100.00% preserved\n  Writing mode: preserved\n  Page progression: preserved (ltr on KFX side)\nerror: one or more checks failed\n";

    #[test]
    fn style_only_failures_are_accepted_but_content_loss_is_not() {
        assert_eq!(content_preserved(LOG), Some(vec!["height".to_owned()]));
        assert_eq!(
            content_preserved(&LOG.replace("Text chars:   100.0000%", "Text chars:   92.3077%")),
            None
        );
        assert_eq!(
            content_preserved(&LOG.replace("Images:       100.00%", "Images:       50.00%")),
            None
        );
        assert_eq!(
            content_preserved(&LOG.replace("Writing mode: preserved", "Writing mode: changed")),
            None
        );
        assert_eq!(content_preserved("error: crashed"), None);
    }

    #[test]
    fn unsafe_paths_are_rejected() {
        let mut zip = ZipWriter::new(Cursor::new(Vec::new()));
        zip.start_file("../evil.txt", SimpleFileOptions::default())
            .unwrap();
        zip.write_all(b"x").unwrap();
        let bytes = zip.finish().unwrap().into_inner();
        let overrides = Overrides {
            title: String::new(),
            author: String::new(),
            language: String::new(),
            cover: None,
            need_cover: false,
            plain_svg_images: false,
            keep_images: false,
            image_options: Default::default(),
            output_options: Default::default(),
            navigation_options: Default::default(),
            title_sort: String::new(),
            author_sort: String::new(),
            book_producer: String::new(),
            style: Default::default(),
        };
        assert!(rebuild(&bytes, &overrides).is_err());
        assert_eq!(
            join("OEBPS/text", "../images/a%20b.png#x").unwrap(),
            "OEBPS/images/a b.png"
        );
    }
}

/// Count declared image resources, including images with nonstandard extensions.
pub(crate) fn image_sizes(bytes: &[u8]) -> Result<(usize, u64), ApiError> {
    let mut archive =
        ZipArchive::new(Cursor::new(bytes)).map_err(|_| invalid("choose_valid_epub_package"))?;
    let mut container = String::new();
    archive
        .by_name("META-INF/container.xml")
        .map_err(|_| invalid("choose_valid_epub_package"))?
        .read_to_string(&mut container)
        .map_err(|_| invalid("choose_valid_epub_package"))?;
    let doc = Document::parse(&container).map_err(|_| invalid("choose_valid_epub_package"))?;
    let path = doc
        .descendants()
        .find(|n| n.tag_name().name() == "rootfile")
        .and_then(|n| n.attribute("full-path"))
        .ok_or_else(|| invalid("choose_valid_epub_package"))?;
    let base = path.rsplit_once('/').map(|(b, _)| b).unwrap_or("");
    let mut opf = String::new();
    archive
        .by_name(path)
        .map_err(|_| invalid("choose_valid_epub_package"))?
        .read_to_string(&mut opf)
        .map_err(|_| invalid("choose_valid_epub_package"))?;
    let doc = Document::parse(&opf).map_err(|_| invalid("choose_valid_epub_package"))?;
    let paths: std::collections::BTreeSet<_> = doc
        .descendants()
        .filter(|n| {
            n.tag_name().name() == "item"
                && n.attribute("media-type")
                    .is_some_and(|m| m.starts_with("image/"))
        })
        .filter_map(|n| n.attribute("href").and_then(|h| join(base, h)))
        .collect();
    let mut total = 0;
    for path in &paths {
        total += archive
            .by_name(path)
            .map_err(|_| invalid("choose_valid_epub_package"))?
            .size();
    }
    Ok((paths.len(), total))
}
