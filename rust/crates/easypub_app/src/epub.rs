//! EPUB serialization from one immutable snapshot. Caller owns staging and publication.
use crate::{navigation_documents::escaped, publication_resources::Prepared};
use easypub_core::{ApiError, ErrorCode};
use std::{
    borrow::Cow,
    collections::BTreeMap,
    io::{Seek, Write},
};
use zip::{CompressionMethod, ZipWriter, write::SimpleFileOptions};
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "epub",
        "review_publication_and_output",
    )
}
fn mime(id: &str) -> Result<&'static str, ApiError> {
    Ok(match id.rsplit('.').next().unwrap_or("") {
        "xhtml" => "application/xhtml+xml",
        "css" => "text/css",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "webp" => "image/webp",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "woff" => "font/woff",
        "ncx" => "application/x-dtbncx+xml",
        _ => return Err(invalid()),
    })
}
pub fn write<W: Write + Seek>(prepared: &Prepared, writer: W) -> Result<W, ApiError> {
    write_controlled(prepared, writer, &|| Ok(()))
}
pub fn write_controlled<W: Write + Seek>(
    prepared: &Prepared,
    writer: W,
    checkpoint: &dyn Fn() -> Result<(), ApiError>,
) -> Result<W, ApiError> {
    write_profile(prepared, writer, false, false, checkpoint)
}
/// Engine-specific input only; does not run Kindling or change generic EPUB output.
pub fn write_kindling_input<W: Write + Seek>(
    prepared: &Prepared,
    writer: W,
) -> Result<W, ApiError> {
    if prepared.manifest().cover.is_none() {
        return Err(ApiError::new(
            ErrorCode::InvalidRule,
            "kindling_input",
            "choose_cover_before_kindling_export",
        ));
    }
    write_profile(prepared, writer, true, false, &|| Ok(()))
}
/// KFX renders its cover as a native image; preserve its aspect ratio.
pub fn write_bokai_input<W: Write + Seek>(prepared: &Prepared, writer: W) -> Result<W, ApiError> {
    write_profile(prepared, writer, false, true, &|| Ok(()))
}
fn write_profile<W: Write + Seek>(
    prepared: &Prepared,
    writer: W,
    kindling: bool,
    bokai: bool,
    checkpoint: &dyn Fn() -> Result<(), ApiError>,
) -> Result<W, ApiError> {
    checkpoint()?;
    let m = prepared.manifest();
    if m.title.trim().is_empty() {
        return Err(invalid());
    }
    let language = m.language.trim();
    if language.is_empty() || language.eq_ignore_ascii_case("und") {
        return Err(ApiError::new(
            ErrorCode::InvalidRule,
            "epub",
            "choose_publication_language",
        ));
    }
    let mut docs = prepared.documents()?;
    checkpoint()?;
    // EPUB requires navigation; hiding the full TOC leaves only a body-start entry.
    if !docs.pages.contains_key("nav.xhtml") || m.navigation.entries.is_empty() {
        docs.pages.insert("nav.xhtml".into(), "<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>目录</title></head><body><nav epub:type=\"toc\" id=\"toc\"><h1>目录</h1><ol><li><a href=\"body.xhtml\">正文</a></li></ol></nav></body></html>".into());
    }
    crate::publication_split::split(&mut docs, 256 * 1024)?;
    if bokai && (m.note_style == "popup" || !m.manual_notes.is_empty()) {
        for page in docs.pages.values_mut() {
            if let Cow::Owned(adapted) = crate::publication_notes::bokai_input(page) {
                *page = adapted;
            }
        }
    }
    // KFX（Bokai）的封面页用普通图片、高度随宽度，保持原图比例（OUT-074）。
    if bokai && let Some(cover) = crate::publication_documents::cover_page(prepared, false)? {
        docs.pages.insert("cover.xhtml".into(), cover);
    }
    if kindling {
        // Kindle 封面只由元数据提供，HTML 封面页不进阅读顺序（Kindling 封面检查与 KDP 要求）。
        docs.reading_order.retain(|name| name != "cover.xhtml");
    }
    if kindling || !m.supplemental_pages.is_empty() {
        let ncx =
            crate::kindling_navigation::prepare(&docs.pages["nav.xhtml"], &m.title, prepared.id())?;
        docs.pages.insert("kindling.ncx".into(), ncx);
    }
    // 导航地标（V46，OUT-084）：封面、目录、正文开头；在生成 Kindling 的 NCX 之后加入，不影响其目录。
    // 在调整阅读顺序之后计算，Kindling 输入因此不含封面地标，不会把封面页带回正文流。
    let landmarks = landmarks(&docs);
    if let Some(nav) = docs.pages.get_mut("nav.xhtml") {
        let mut items = String::new();
        // KFX（Bokai）：nav 里的 bodymatter 会写成 Calibre KFX Input 不认识的 landmark_type $406，
        // 导致 Calibre 无法读取成品；正文开头仍由 OPF guide 的 text 提供。
        for (kind, label, href) in landmarks
            .iter()
            .filter(|(kind, _, _)| !(bokai && *kind == "bodymatter"))
        {
            items.push_str(&format!(
                "<li><a epub:type=\"{kind}\" href=\"{}\">{label}</a></li>",
                escaped(href)?
            ));
        }
        if !items.is_empty() {
            let block = format!(
                "<nav epub:type=\"landmarks\" id=\"landmarks\" hidden=\"hidden\"><h2>导航</h2><ol>{items}</ol></nav>"
            );
            let at = nav.rfind("</body>").ok_or_else(invalid)?;
            nav.insert_str(at, &block);
        }
    }
    let mut files: BTreeMap<String, Cow<'_, [u8]>> = docs
        .pages
        .into_iter()
        .map(|(name, value)| (name, Cow::Owned(value.into_bytes())))
        .collect();
    files.insert(
        m.stylesheet.id.clone(),
        if bokai {
            // KFX 的封面页是普通图片；Bokai 不支持 vh，去掉 SVG 封面规则（OUT-074）。
            // Bokai 也不支持 text-shadow：经典章节标题的阴影只留给 EPUB 与 Kindling（V36，LAY-117）。
            Cow::Owned(
                m.stylesheet
                    .css
                    .replacen(crate::publication_style::COVER_SVG_RULE, "", 1)
                    .replacen(crate::publication_style::CLASSIC_SHADOW, "", 1)
                    .into_bytes(),
            )
        } else {
            Cow::Borrowed(m.stylesheet.css.as_bytes())
        },
    );
    for r in &m.resources {
        files.insert(
            r.id.clone(),
            Cow::Borrowed(prepared.image_bytes(&r.id).ok_or_else(invalid)?),
        );
    }
    for r in &m.css_dependencies.resources {
        files.insert(
            r.id.clone(),
            Cow::Borrowed(prepared.css_resource_bytes(&r.id).ok_or_else(invalid)?),
        );
    }
    if let Some(font) = &m.font {
        files.insert(
            font.id.clone(),
            Cow::Borrowed(prepared.font_bytes(&font.id).ok_or_else(invalid)?),
        );
    }
    // 每章一个文件（V36，OUT-081）：三千章的长篇加上插图也在上限之内。
    if files.len() > 16384 || files.values().map(|b| b.len()).sum::<usize>() > 384 * 1024 * 1024 {
        return Err(invalid());
    }
    let now = time::OffsetDateTime::now_utc();
    let modified = format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        now.year(),
        u8::from(now.month()),
        now.day(),
        now.hour(),
        now.minute(),
        now.second()
    );
    let mut opf = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"pub-id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"pub-id\">urn:sha256:{}</dc:identifier><dc:title>{}</dc:title><dc:language>{}</dc:language><meta property=\"dcterms:modified\">{modified}</meta>",
        prepared.id(),
        escaped(&m.title)?,
        escaped(language)?
    );
    for (tag, value) in [
        ("creator", &m.author),
        ("description", &m.description),
        ("publisher", &m.publisher),
        ("subject", &m.category),
        ("date", &m.publication_date),
    ] {
        if !value.trim().is_empty() {
            opf.push_str(&format!("<dc:{tag}>{}</dc:{tag}>", escaped(value)?));
        }
    }
    if !m.series.trim().is_empty() {
        opf.push_str(&format!(r##"<meta property="belongs-to-collection" id="series">{}</meta><meta refines="#series" property="collection-type">series</meta>"##, escaped(&m.series)?));
        if !m.series_index.is_empty() {
            opf.push_str(&format!(
                r##"<meta refines="#series" property="group-position">{}</meta>"##,
                escaped(&m.series_index)?
            ));
        }
    }
    for subject in m
        .subjects
        .split(['、', ',', '，', ';', '；', '\n'])
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .collect::<std::collections::BTreeSet<_>>()
    {
        if subject != m.category.trim() {
            opf.push_str(&format!("<dc:subject>{}</dc:subject>", escaped(subject)?));
        }
    }
    if !m.translator.is_empty() {
        opf.push_str(&format!("<dc:contributor id=\"translator\">{}</dc:contributor><meta refines=\"#translator\" property=\"role\" scheme=\"marc:relators\">trl</meta>", escaped(&m.translator)?));
    }
    if !m.isbn.is_empty() {
        opf.push_str(&format!(
            "<dc:identifier>urn:isbn:{}</dc:identifier>",
            escaped(&m.isbn)?
        ));
    }
    // 竖排（V28，LAY-104）：Kindle 与 Bokai 从这里读取主书写方向。
    if m.writing_mode == "vertical" {
        opf.push_str("<meta name=\"primary-writing-mode\" content=\"vertical-rl\"/>");
    }
    opf.push_str("</metadata><manifest>");
    let mut ids = BTreeMap::new();
    for (index, name) in files.keys().enumerate() {
        if name.contains(['/', '\\', ':']) || name.starts_with('.') {
            return Err(invalid());
        }
        let id = format!("r{index}");
        let properties = if name == "nav.xhtml" {
            " properties=\"nav\""
        } else if name == "cover.xhtml" && !bokai {
            // 封面页里有 SVG，EPUB 3 要求在清单中声明（OUT-074）。
            " properties=\"svg\""
        } else if m.cover.as_ref() == Some(name) {
            " properties=\"cover-image\""
        } else {
            ""
        };
        opf.push_str(&format!(
            "<item id=\"{id}\" href=\"{}\" media-type=\"{}\"{properties}/>",
            escaped(name)?,
            mime(name)?
        ));
        ids.insert(name.as_str(), id);
    }
    let direction = if m.writing_mode == "vertical" {
        " page-progression-direction=\"rtl\""
    } else {
        ""
    };
    if ids.contains_key("kindling.ncx") {
        opf.push_str(&format!(
            "</manifest><spine toc=\"{}\"{direction}>",
            ids.get("kindling.ncx").ok_or_else(invalid)?
        ));
    } else {
        opf.push_str(&format!("</manifest><spine{direction}>"));
    }
    for name in &docs.reading_order {
        opf.push_str(&format!(
            "<itemref idref=\"{}\"/>",
            ids.get(name.as_str()).ok_or_else(invalid)?
        ));
    }
    opf.push_str("</spine>");
    if !landmarks.is_empty() {
        opf.push_str("<guide>");
        for (kind, label, href) in &landmarks {
            let kind = if *kind == "bodymatter" { "text" } else { kind };
            opf.push_str(&format!(
                "<reference type=\"{kind}\" title=\"{label}\" href=\"{}\"/>",
                escaped(href)?
            ));
        }
        opf.push_str("</guide>");
    }
    opf.push_str("</package>");
    let mut zip = ZipWriter::new(writer);
    let options = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
    zip.start_file(
        "mimetype",
        SimpleFileOptions::default().compression_method(CompressionMethod::Stored),
    )
    .map_err(|_| invalid())?;
    zip.write_all(b"application/epub+zip")
        .map_err(|_| invalid())?;
    zip.start_file("META-INF/container.xml", options)
        .map_err(|_| invalid())?;
    zip.write_all(b"<?xml version=\"1.0\"?><container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\" version=\"1.0\"><rootfiles><rootfile full-path=\"EPUB/package.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>").map_err(|_| invalid())?;
    zip.start_file("EPUB/package.opf", options)
        .map_err(|_| invalid())?;
    zip.write_all(opf.as_bytes()).map_err(|_| invalid())?;
    for (name, bytes) in files {
        checkpoint()?;
        zip.start_file(format!("EPUB/{name}"), options)
            .map_err(|_| invalid())?;
        for chunk in bytes.chunks(256 * 1024) {
            checkpoint()?;
            zip.write_all(chunk).map_err(|_| invalid())?;
        }
    }
    zip.finish().map_err(|_| invalid())
}

/// 导航地标目标（V46，OUT-084）：(epub:type, 名称, 链接)。封面页与可见目录在阅读顺序中才列出；
/// 正文开头取第一个卷或章所在的文件，没有卷章时取第一个正文文件。
fn landmarks(
    docs: &crate::publication_documents::Documents,
) -> Vec<(&'static str, &'static str, String)> {
    let mut out = Vec::new();
    let in_order = |name: &str| docs.reading_order.iter().any(|n| n == name);
    if in_order("cover.xhtml") {
        out.push(("cover", "封面", "cover.xhtml".to_string()));
    }
    if in_order("toc.xhtml") {
        out.push(("toc", "目录", "toc.xhtml".to_string()));
    }
    let body = docs.reading_order.iter().filter(|n| n.starts_with("body"));
    let start = body
        .clone()
        .find(|n| {
            docs.pages.get(n.as_str()).is_some_and(|page| {
                page.contains("class=\"volume-start\"") || page.contains("class=\"chapter-start\"")
            })
        })
        .or_else(|| body.clone().next());
    if let Some(start) = start {
        out.push(("bodymatter", "正文", start.clone()));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use easypub_core::source::{RULE_ID, SourceSnapshot};
    use serde_json::json;
    use std::io::{Cursor, Read};
    #[test]
    fn bokai_note_container_preserves_links_and_source_without_changing_other_profiles() {
        let text = "第一章 雾港\r\n正文①<&>。\r\n① 注释 <aside> 原样保留。\r\n第二章 归来\n正文①。\n① 第二章注释。\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        for style in ["off", "popup"] {
            let request = serde_json::from_value(json!({"source_id": source.summary().source_id, "revision": 1,
                "settings": {"title":"注释样书", "author":"作者", "description":"", "language":"zh-CN",
                    "cover_fit":"contain", "font_family":"SimSun", "font_size":18, "line_height":1.8,
                    "include_toc":true, "fullwidth_indent":2, "note_style":style, "illustrations":[]}})).unwrap();
            let prepared = crate::publication_resources::prepare(&source, request).unwrap();
            for (kindling, bokai) in [(false, false), (true, false), (false, true)] {
                let bytes =
                    write_profile(&prepared, Cursor::new(Vec::new()), kindling, bokai, &|| {
                        Ok(())
                    })
                    .unwrap()
                    .into_inner();
                let mut zip = zip::ZipArchive::new(Cursor::new(bytes)).unwrap();
                let mut restored = String::new();
                let mut notes = 0;
                let mut references = 0;
                let mut opf = String::new();
                zip.by_name("EPUB/package.opf")
                    .unwrap()
                    .read_to_string(&mut opf)
                    .unwrap();
                let package = roxmltree::Document::parse(&opf).unwrap();
                let items: BTreeMap<_, _> = package
                    .descendants()
                    .filter(|n| n.has_tag_name("item"))
                    .map(|n| (n.attribute("id").unwrap(), n.attribute("href").unwrap()))
                    .collect();
                // ZIP 存储顺序不是阅读顺序；原文恢复必须按 OPF spine。
                for name in package
                    .descendants()
                    .filter(|n| n.has_tag_name("itemref"))
                    .map(|n| items[n.attribute("idref").unwrap()])
                    .filter(|name| name.starts_with("body"))
                {
                    let mut file = zip.by_name(&format!("EPUB/{name}")).unwrap();
                    let mut page = String::new();
                    file.read_to_string(&mut page).unwrap();
                    let xml = roxmltree::Document::parse(&page).unwrap();
                    for node in xml.descendants() {
                        let semantic = node.attribute(("http://www.idpf.org/2007/ops", "type"));
                        if semantic == Some("footnote") {
                            notes += 1;
                            assert!(node.has_tag_name(if bokai { "div" } else { "aside" }));
                            let back = node.descendants().find(|n| n.has_tag_name("a")).unwrap();
                            let href = back.attribute("href").unwrap();
                            let reference = xml
                                .descendants()
                                .find(|n| n.attribute("id") == href.split_once('#').map(|v| v.1))
                                .unwrap();
                            assert!(
                                reference
                                    .attribute("href")
                                    .unwrap()
                                    .ends_with(&format!("#{}", node.attribute("id").unwrap()))
                            );
                        }
                        if semantic == Some("noteref") {
                            references += 1;
                            if bokai {
                                assert_eq!(node.attribute("class"), Some("note-ref"));
                            } else {
                                assert!(node.parent().unwrap().has_tag_name("sup"));
                            }
                        }
                        if style == "popup" && node.attribute("data-source") == Some("true") {
                            restored.push_str(node.attribute("data-original").unwrap());
                            restored.push_str(match node.attribute("data-eol").unwrap() {
                                "crlf" => "\r\n",
                                "lf" => "\n",
                                "cr" => "\r",
                                "none" => "",
                                _ => unreachable!(),
                            });
                        }
                    }
                }
                assert_eq!(notes, if style == "popup" { 2 } else { 0 });
                assert_eq!(references, notes);
                if style == "popup" {
                    assert_eq!(restored, text);
                }
            }
        }
    }
    #[test]
    fn exported_series_and_subjects_are_xml_metadata() {
        let source =
            SourceSnapshot::from_utf8("第一章 夜渡\n正文".as_bytes().to_vec(), RULE_ID, || false)
                .unwrap();
        let request = serde_json::from_value(json!({"source_id":source.summary().source_id,"revision":1,
          "settings":{"title":"样书","author":"作者","description":"","cover_fit":"contain",
          "font_family":"SimSun","font_size":18,"line_height":1.8,"include_toc":true,"illustrations":[],
          "language":"zh-CN","series":"长河<&纪事","series_index":"2.2.1","category":"小说","subjects":"旅行、群像,旅行;小说"}})).unwrap();
        let prepared = crate::publication_resources::prepare(&source, request).unwrap();
        let bytes = write(&prepared, Cursor::new(Vec::new()))
            .unwrap()
            .into_inner();
        let mut zip = zip::ZipArchive::new(Cursor::new(bytes)).unwrap();
        let mut xml = String::new();
        zip.by_name("EPUB/package.opf")
            .unwrap()
            .read_to_string(&mut xml)
            .unwrap();
        let doc = roxmltree::Document::parse(&xml).unwrap();
        let property = |name| {
            doc.descendants()
                .find(|n| n.attribute("property") == Some(name))
                .unwrap()
        };
        assert_eq!(property("belongs-to-collection").text(), Some("长河<&纪事"));
        assert_eq!(property("collection-type").text(), Some("series"));
        assert_eq!(property("group-position").text(), Some("2.2.1"));
        assert_eq!(
            property("group-position").attribute("refines"),
            Some("#series")
        );
        let subjects: std::collections::BTreeSet<_> = doc
            .descendants()
            .filter(|n| n.has_tag_name("subject"))
            .map(|n| n.text().unwrap())
            .collect();
        assert_eq!(subjects, ["小说", "旅行", "群像"].into_iter().collect());
    }
    #[test]
    fn bokai_input_keeps_text_guide_but_omits_bodymatter_landmark() {
        // Calibre KFX Input 不认识 Bokai 由 nav bodymatter 生成的 landmark_type $406。
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n正文\n第二章 乙\n正文\n".as_bytes().to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let request = serde_json::from_value(json!({"source_id":source.summary().source_id,"revision":1,
            "settings":{"title":"样书", "author":"作者", "description":"", "language":"zh", "cover_fit":"contain",
            "font_family":"SimSun", "font_size":18, "line_height":1.8, "include_toc":true,
            "visible_toc":true, "chapter_navigation":false, "illustrations":[]}})).unwrap();
        let prepared = crate::publication_resources::prepare(&source, request).unwrap();
        let read = |bytes: Vec<u8>| {
            let mut zip = zip::ZipArchive::new(Cursor::new(bytes)).unwrap();
            let mut text = |name: &str| {
                let mut value = String::new();
                zip.by_name(name)
                    .unwrap()
                    .read_to_string(&mut value)
                    .unwrap();
                value
            };
            (text("EPUB/nav.xhtml"), text("EPUB/package.opf"))
        };
        let (nav, opf) = read(
            write(&prepared, Cursor::new(Vec::new()))
                .unwrap()
                .into_inner(),
        );
        assert!(nav.contains("epub:type=\"bodymatter\""));
        assert!(opf.contains("<reference type=\"text\""));
        let (nav, opf) = read(
            write_bokai_input(&prepared, Cursor::new(Vec::new()))
                .unwrap()
                .into_inner(),
        );
        assert!(nav.contains("epub:type=\"landmarks\""));
        assert!(nav.contains("epub:type=\"toc\" href=\"toc.xhtml\""));
        assert!(!nav.contains("epub:type=\"bodymatter\""));
        assert!(opf.contains("<reference type=\"text\""));
    }
    #[test]
    fn containers_have_required_navigation_and_exact_manifest_spine() {
        for text in ["普通正文<&>\n下一行", "第一卷 甲\n第一章 乙\n正文"] {
            for machine in [false, true] {
                for visible in [false, true] {
                    for top in [false, true] {
                        let source =
                            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false)
                                .unwrap();
                        let request = serde_json::from_value(json!({"source_id":source.summary().source_id,"revision":1,
                  "settings":{"title":"样书", "author":"作者", "description":"", "language":"zh", "cover_fit":"contain",
                  "font_family":"SimSun", "font_size":18, "line_height":1.8, "include_toc":machine,
                  "visible_toc":visible, "chapter_navigation":top, "illustrations":[]}})).unwrap();
                        let prepared =
                            crate::publication_resources::prepare(&source, request).unwrap();
                        // Missing cover must fail before touching the caller's writer.
                        let mut untouched = Cursor::new(Vec::new());
                        assert!(write_kindling_input(&prepared, &mut untouched).is_err());
                        assert!(untouched.into_inner().is_empty());
                        let bytes = write(&prepared, Cursor::new(Vec::new()))
                            .unwrap()
                            .into_inner();
                        assert_eq!(&bytes[..4], b"PK\x03\x04");
                        assert_eq!(&bytes[8..10], &[0, 0]); // stored mimetype
                        assert_eq!(&bytes[28..30], &[0, 0]); // no local extra field
                        assert_eq!(&bytes[30..38], b"mimetype");
                        let mut zip = zip::ZipArchive::new(Cursor::new(bytes)).unwrap();
                        let mut files = BTreeMap::new();
                        for i in 0..zip.len() {
                            let mut entry = zip.by_index(i).unwrap();
                            if i == 0 {
                                assert_eq!(entry.name(), "mimetype");
                            }
                            let mut value = String::new();
                            entry.read_to_string(&mut value).unwrap();
                            assert!(files.insert(entry.name().to_string(), value).is_none());
                        }
                        assert_eq!(files["mimetype"], "application/epub+zip");
                        let opf = roxmltree::Document::parse(&files["EPUB/package.opf"]).unwrap();
                        let items: BTreeMap<_, _> = opf
                            .descendants()
                            .filter(|n| n.has_tag_name("item"))
                            .map(|n| (n.attribute("id").unwrap(), n.attribute("href").unwrap()))
                            .collect();
                        assert_eq!(items.len() + 3, files.len());
                        assert_eq!(
                            opf.descendants()
                                .filter(|n| n.attribute("properties") == Some("nav"))
                                .count(),
                            1
                        );
                        for file in items.values() {
                            assert!(files.contains_key(&format!("EPUB/{file}")));
                        }
                        for spine in opf.descendants().filter(|n| n.has_tag_name("itemref")) {
                            assert!(items.contains_key(spine.attribute("idref").unwrap()));
                        }
                        let nav = roxmltree::Document::parse(&files["EPUB/nav.xhtml"]).unwrap();
                        assert!(nav.descendants().any(|n| n.has_tag_name("ol")));
                        const OPS: &str = "http://www.idpf.org/2007/ops";
                        let nav_of = |kind: &str| {
                            nav.descendants()
                                .find(|n| {
                                    n.has_tag_name("nav")
                                        && n.attribute((OPS, "type")) == Some(kind)
                                })
                                .unwrap()
                        };
                        if !machine {
                            assert_eq!(
                                nav_of("toc")
                                    .descendants()
                                    .filter(|n| n.has_tag_name("a"))
                                    .count(),
                                1
                            );
                        }
                        // 导航地标与 guide（V46，OUT-084）：正文开头必有，且都指向阅读顺序中的文件。
                        let spine_files: Vec<&str> = opf
                            .descendants()
                            .filter(|n| n.has_tag_name("itemref"))
                            .map(|n| items[n.attribute("idref").unwrap()])
                            .collect();
                        let landmarks: Vec<(String, String)> = nav_of("landmarks")
                            .descendants()
                            .filter(|n| n.has_tag_name("a"))
                            .map(|a| {
                                (
                                    a.attribute((OPS, "type")).unwrap().to_owned(),
                                    a.attribute("href").unwrap().to_owned(),
                                )
                            })
                            .collect();
                        assert!(landmarks.iter().any(|(kind, _)| kind == "bodymatter"));
                        for (_, href) in &landmarks {
                            assert!(
                                spine_files.contains(&href.split('#').next().unwrap()),
                                "{href}"
                            );
                        }
                        let guide: Vec<String> = opf
                            .descendants()
                            .filter(|n| n.has_tag_name("reference"))
                            .map(|n| n.attribute("type").unwrap().to_owned())
                            .collect();
                        assert!(guide.contains(&"text".to_owned()));
                        assert_eq!(guide.len(), landmarks.len());
                        // 每章一个文件（V36，OUT-081）：按 spine 顺序读全部正文文件。
                        let docs: Vec<_> = opf
                            .descendants()
                            .filter(|n| n.has_tag_name("itemref"))
                            .map(|n| {
                                &files[&format!("EPUB/{}", items[n.attribute("idref").unwrap()])]
                            })
                            .collect();
                        let docs: Vec<_> = docs
                            .iter()
                            .map(|s| roxmltree::Document::parse(s).unwrap())
                            .collect();
                        let restored: String = docs
                            .iter()
                            .flat_map(|doc| doc.descendants())
                            .filter(|n| n.attribute("data-source") == Some("true"))
                            .map(|n| {
                                format!(
                                    "{}{}",
                                    n.attribute("data-original")
                                        .or_else(|| n.text())
                                        .unwrap_or(""),
                                    if n.attribute("data-eol") == Some("lf") {
                                        "\n"
                                    } else {
                                        ""
                                    }
                                )
                            })
                            .collect();
                        assert_eq!(restored, text);
                    }
                }
            }
        }
    }
}
