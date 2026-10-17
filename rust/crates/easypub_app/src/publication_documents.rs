//! Semantic XHTML pages built from the final composed book, not source guesses.
use crate::{navigation_documents::escaped, publication_resources::Prepared};
use easypub_core::{ApiError, ErrorCode, structure::Role};
use std::collections::BTreeMap;

pub struct Documents {
    pub pages: BTreeMap<String, String>,
    pub reading_order: Vec<String>,
}
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "publication_documents",
        "review_final_book_resources",
    )
}
fn page(prepared: &Prepared, title: &str, body: &str) -> Result<String, ApiError> {
    let m = prepared.manifest();
    let mut head = format!("<title>{}</title>", escaped(title)?);
    for id in &m.stylesheet_order {
        head.push_str(&format!(
            "<link rel=\"stylesheet\" type=\"text/css\" href=\"{}\"/>",
            escaped(id)?
        ));
    }
    Ok(format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" xml:lang=\"{}\"><head>{head}</head><body>{body}</body></html>",
        escaped(&m.language)?
    ))
}
/// 封面页（OUT-074）。`svg` 为 true 时用 SVG 包住封面图：viewBox 取图片的实际像素尺寸，
/// 按“封面适配方式”保持原图比例（contain 完整显示、cover 铺满并裁去多余部分、fill 拉伸），
/// 不依赖阅读器是否支持 `object-fit`。KFX（Bokai）仍用普通图片、高度随宽度。
pub(crate) fn cover_page(prepared: &Prepared, svg: bool) -> Result<Option<String>, ApiError> {
    let m = prepared.manifest();
    let Some(id) = &m.cover else {
        return Ok(None);
    };
    let body = if svg {
        let resource = m
            .resources
            .iter()
            .find(|r| &r.id == id)
            .filter(|r| r.width > 0 && r.height > 0)
            .ok_or_else(invalid)?;
        if prepared.image_bytes(id).is_none() {
            return Err(invalid());
        }
        let aspect = match m.cover_fit.as_str() {
            "cover" => "xMidYMid slice",
            "fill" => "none",
            _ => "xMidYMid meet",
        };
        format!(
            "<div class=\"cover\"><svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" version=\"1.1\" width=\"100%\" height=\"100%\" viewBox=\"0 0 {w} {h}\" preserveAspectRatio=\"{aspect}\"><title>{alt}</title><image width=\"{w}\" height=\"{h}\" xlink:href=\"{href}\"/></svg></div>",
            w = resource.width,
            h = resource.height,
            alt = escaped(&m.title)?,
            href = escaped(id)?,
        )
    } else {
        format!(
            "<div class=\"cover\">{}</div>",
            image(prepared, id, &m.title)?
        )
    };
    page(prepared, "封面", &body).map(Some)
}
/// 精排两行（V36，LAY-117）：标题开头的“第 N 章”（含后面的空白、冒号等分隔）在第几个字节结束。
/// 章名为空、或开头不是“第 N 章 / 回 / 节 / 卷 / 集 / 部 / 篇 / 话 / 幕”时返回 None，标题照常一行。
/// 只改结构不改文字：分隔符留在小字里，行末空白不显示；两行之间用 `<br/>`，与网文精排成品书相同
/// （Bokai 生成 KFX 时不保留行内元素的 display: block，换行元素三种格式都保留）。
pub(crate) fn chapter_label_end(text: &str) -> Option<usize> {
    let lead = text.len() - text.trim_start().len();
    let rest = text[lead..].strip_prefix('第')?;
    let count: usize = rest
        .chars()
        .take_while(|c| {
            c.is_ascii_digit()
                || ('０'..='９').contains(c)
                || "零〇一二三四五六七八九十百千万两".contains(*c)
        })
        .map(char::len_utf8)
        .sum();
    if count == 0 {
        return None;
    }
    let unit = rest[count..]
        .chars()
        .next()
        .filter(|c| "章回节卷集部篇话幕".contains(*c))?;
    let mut end = lead + '第'.len_utf8() + count + unit.len_utf8();
    end += text[end..]
        .chars()
        .take_while(|c| c.is_whitespace() || ":：、.．·-—".contains(*c))
        .map(char::len_utf8)
        .sum::<usize>();
    (!text[end..].trim().is_empty()).then_some(end)
}
/// Shared by the renderer and the read-only rule statistics. Manual blocks take precedence.
pub(crate) fn classify_block(
    line: &str,
    has_node: bool,
    annotation: Option<&crate::block_annotations::Annotation>,
    range: (usize, usize),
    previous_line: Option<&str>,
    system_style: &str,
    verse_style: &str,
) -> Option<(&'static str, &'static str)> {
    let (offset, end) = range;
    if let Some(a) = annotation {
        use crate::block_annotations::Kind;
        match a.kind {
            Kind::Letter => Some((
                "letter",
                if end == a.end
                    && offset > a.start
                    && !line.trim().is_empty()
                    && line.trim().chars().count() <= 40
                {
                    "letter-by"
                } else {
                    "letter-line"
                },
            )),
            Kind::Quote => Some(("quote", "quote-line")),
            Kind::Verse => Some((
                "verse",
                if end == a.end && is_verse_attribution(line) {
                    "verse-by"
                } else {
                    "verse-line"
                },
            )),
            Kind::System => Some(("system", "system-line")),
            Kind::None => None,
        }
    } else if has_node {
        None
    } else if system_style != "off" && is_system_line(line) {
        Some(("system", "system-line"))
    } else if verse_style != "off" && is_verse_line(line) {
        Some(("verse", "verse-line"))
    } else if previous_line == Some("verse-line") && is_verse_attribution(line) {
        Some(("verse", "verse-by"))
    } else {
        None
    }
}

/// 可作场景分隔的符号（V46，LAY-118）。“……”“——”“-”不在其中：单独成行时通常是对白或停顿。
pub(crate) const SCENE_SYMBOLS: &str = "*＊﹡※◇◆○●◎☆★♢♦✱✲✳✿❀❖⁂#＃=＝~～§";

/// 整行（可夹空白）都是分隔符号且至少 3 个时视为场景分隔（V46，LAY-118）。
pub(crate) fn is_scene_break(line: &str) -> bool {
    let mut count = 0;
    for c in line.chars() {
        if c.is_whitespace() {
            continue;
        }
        if !SCENE_SYMBOLS.contains(c) {
            return false;
        }
        count += 1;
        if count > 40 {
            return false;
        }
    }
    count >= 3
}

/// 系统提示（V50，LAY-121）：整行由一个或多个【……】组成（之间可有空白），括号内不为空。
pub(crate) fn is_system_line(line: &str) -> bool {
    let mut rest = line.trim();
    if rest.is_empty() || rest.chars().count() > 200 {
        return false;
    }
    while !rest.is_empty() {
        let Some(inner) = rest.strip_prefix('【') else {
            return false;
        };
        let Some(end) = inner.find('】') else {
            return false;
        };
        if inner[..end].trim().is_empty() || inner[..end].contains('【') {
            return false;
        }
        rest = inner[end + '】'.len_utf8()..].trim_start();
    }
    true
}

fn is_han(c: char) -> bool {
    matches!(c, '\u{4e00}'..='\u{9fff}' | '\u{3400}'..='\u{4dbf}' | '\u{f900}'..='\u{faff}')
}

/// 诗词（V50，LAY-122）：整行是五言或七言对句，前后两句等长，如“床前明月光，疑是地上霜。”。
pub(crate) fn is_verse_line(line: &str) -> bool {
    let t = line.trim();
    let t = t
        .strip_suffix(['。', '！', '？', '；', '!', '?', ';'])
        .unwrap_or(t);
    let Some((a, b)) = t.split_once(['，', ',']) else {
        return false;
    };
    let (na, nb) = (a.chars().count(), b.chars().count());
    na == nb && (na == 5 || na == 7) && a.chars().chain(b.chars()).all(is_han)
}

/// 诗词署名（V50，LAY-122）：紧跟诗句、以“——”开头的短行。
pub(crate) fn is_verse_attribution(line: &str) -> bool {
    let t = line.trim();
    t.strip_prefix("——")
        .is_some_and(|by| !by.trim().is_empty() && by.chars().count() <= 40)
}

/// 章首图（V54，RES-050 / LAY-124）：本章单独设的章首插图优先；没有时按统一章首图的适用范围插入。
fn chapter_head(
    prepared: &Prepared,
    role: &Role,
    own: &[&crate::publication_resources::Placement],
) -> Result<String, ApiError> {
    let m = prepared.manifest();
    let width = match m.chapter_head_width.as_str() {
        "third" => "chapter-head-third",
        "full" => "chapter-head-full",
        _ => "chapter-head-half",
    };
    let mut html = String::new();
    for p in own {
        html.push_str(&format!(
            "<figure class=\"chapter-head-image {width}\">{}",
            image(prepared, &p.resource_id, &p.alt)?
        ));
        if !p.caption.is_empty() {
            html.push_str(&format!(
                "<figcaption>{}</figcaption>",
                escaped(&p.caption)?
            ));
        }
        html.push_str("</figure>");
    }
    let applies = match m.chapter_head_scope.as_str() {
        "volume" => matches!(role, Role::Volume),
        "both" => matches!(role, Role::Volume | Role::Chapter),
        _ => matches!(role, Role::Chapter),
    };
    if own.is_empty()
        && applies
        && let Some(id) = &m.chapter_head_image_id
    {
        html.push_str(&format!(
            "<figure class=\"chapter-head-image {width}\">{}</figure>",
            image(prepared, id, "")?
        ));
    }
    Ok(html)
}

fn image(prepared: &Prepared, id: &str, alt: &str) -> Result<String, ApiError> {
    if prepared.image_bytes(id).is_none() {
        return Err(invalid());
    }
    Ok(format!(
        "<img src=\"{}\" alt=\"{}\"/>",
        escaped(id)?,
        escaped(alt)?
    ))
}
fn append_supplements(
    prepared: &Prepared,
    position: crate::supplemental_pages::Position,
    pages: &mut BTreeMap<String, String>,
    order: &mut Vec<String>,
) -> Result<(), ApiError> {
    for item in prepared
        .manifest()
        .supplemental_pages
        .iter()
        .filter(|p| p.content.position == position)
    {
        let name = item.filename();
        pages.insert(
            name.clone(),
            page(
                prepared,
                item.content.label(),
                &crate::supplemental_pages::body(item)?,
            )?,
        );
        order.push(name);
    }
    Ok(())
}
pub fn prepare(prepared: &Prepared) -> Result<Documents, ApiError> {
    let book = prepared.book();
    let m = prepared.manifest();
    let notes = (m.note_style == "popup" || !m.manual_notes.is_empty()).then(|| {
        crate::publication_notes::Notes::with_manual(book, &m.manual_notes, m.note_style == "popup")
    });
    if (!m.additional_css.is_empty() && !m.css_dependencies.rewritten)
        || m.css_media.iter().any(|r| {
            !r.id.ends_with(".css")
                && !matches!(r.status, "image_decoded" | "font_permission_confirmed")
        })
    {
        return Err(invalid());
    }
    // Reuse the same target IDs and TOC hierarchy as the navigation contract.
    let mut pages = crate::navigation_documents::contents(book, &m.navigation)?;
    for doc in pages.values_mut() {
        let start = doc.find("<body>").ok_or_else(invalid)? + 6;
        let end = doc.rfind("</body>").ok_or_else(invalid)?;
        *doc = page(prepared, "目录", &doc[start..end])?;
    }
    let mut reading_order = Vec::new();
    if let Some(cover) = cover_page(prepared, true)? {
        pages.insert("cover.xhtml".into(), cover);
        reading_order.push("cover.xhtml".into());
    }
    let mut title = format!(
        "<section class=\"title-page\"><h1 class=\"book-title\">{}</h1>",
        escaped(&m.title)?
    );
    for (class, value) in [
        ("book-author", &m.author),
        ("book-translator", &m.translator),
    ] {
        if !value.is_empty() {
            title.push_str(&format!("<p class=\"{class}\">{}</p>", escaped(value)?));
        }
    }
    title.push_str("</section>");
    if !m.description.is_empty() {
        title.push_str(&format!(
            "<section class=\"book-description\"><p class=\"text-line\">{}</p></section>",
            escaped(&m.description)?
        ));
    }
    pages.insert("title.xhtml".into(), page(prepared, &m.title, &title)?);
    reading_order.push("title.xhtml".into());
    append_supplements(
        prepared,
        crate::supplemental_pages::Position::Front,
        &mut pages,
        &mut reading_order,
    )?;
    if m.visible_toc {
        reading_order.push("toc.xhtml".into());
    }
    let ids: BTreeMap<_, _> = book
        .tree
        .nodes
        .iter()
        .enumerate()
        .map(|(i, n)| (n.entry_id.as_str(), i))
        .collect();
    let chapters: BTreeMap<_, _> = m
        .navigation
        .chapters
        .iter()
        .map(|c| (c.entry_id.as_str(), c))
        .collect();
    let mut body = String::new();
    let mut offset = 0;
    let mut node_index = 0;
    let mut placement_index = 0;
    let mut prefix = book.tree.prefix_end > 0;
    let mut section_open = false;
    // 章首插图（V54）：挂到所在章（插图之前最近的标题）；书首无标题时按随正文输出。
    let mut heads: BTreeMap<usize, Vec<&crate::publication_resources::Placement>> = BTreeMap::new();
    for p in m.placements.iter().filter(|p| p.layout == "chapter_head") {
        if let Some(index) = book.tree.nodes.iter().rposition(|n| n.start < p.after_utf8) {
            heads.entry(index).or_default().push(p);
        }
    }
    // 章首段落（V49，LAY-119）：标题或场景分隔之后、尚未遇到非空正文段。
    let mut first_pending = false;
    // 系统提示与诗词（V50，LAY-121/122）：当前打开的块。
    // 标注 ID 区分手工块与相邻自动块、相邻同类手工块。
    let mut block: Option<(&str, Option<&str>)> = None;
    let mut annotation_index = 0;
    let mut previous_line: Option<&str> = None;
    if prefix {
        body.push_str("<section class=\"front-matter\">");
    }
    while offset < book.text.len() {
        let rest = &book.text[offset..];
        let length = rest.find(['\r', '\n']).unwrap_or(rest.len());
        let content_end = offset + length;
        let tail = &book.text[content_end..];
        let (eol, eol_len) = if tail.starts_with("\r\n") {
            ("crlf", 2)
        } else if tail.starts_with('\r') {
            ("cr", 1)
        } else if tail.starts_with('\n') {
            ("lf", 1)
        } else {
            ("none", 0)
        };
        let end = content_end + eol_len;
        let node = book
            .tree
            .nodes
            .get(node_index)
            .filter(|n| n.start == offset);
        let mut tag = "p".to_string();
        let mut attrs = "class=\"text-line\"".to_string();
        // 连续的系统提示行、诗句（含紧跟的署名）各包成一个块；块在标题、分节之前关闭。
        let line = &book.text[offset..content_end];
        while m
            .block_annotations
            .get(annotation_index)
            .is_some_and(|a| a.end <= offset)
        {
            annotation_index += 1;
        }
        let annotation = m
            .block_annotations
            .get(annotation_index)
            .filter(|a| a.start <= offset);
        let line_block = classify_block(
            line,
            node.is_some(),
            annotation,
            (offset, end),
            previous_line,
            &m.system_block_style,
            &m.verse_block_style,
        );
        previous_line = if annotation.is_none() {
            line_block.map(|(_, class)| class)
        } else {
            None
        };
        let next_block = line_block.map(|(kind, _)| (kind, annotation.map(|a| a.id.as_str())));
        if block != next_block || node.is_some() {
            if block.is_some() {
                body.push_str("</div>");
            }
            block = None;
        }
        if let Some(node) = node {
            if let Some(notes) = &notes {
                body.push_str(&notes.chapter_end(offset)?);
            }
            if prefix {
                body.push_str("</section>");
                prefix = false;
            }
            if node.body_start != end || node.end < end {
                return Err(invalid());
            }
            if section_open {
                body.push_str("</section>");
            }
            let section_class = match node.role {
                Role::Volume => "volume-start",
                Role::Chapter => "chapter-start",
                // 序言、后记等前置部分与章同级，单独成页（V36，OUT-081）。
                Role::Front => "front-start",
                _ => "content-section",
            };
            body.push_str(&format!(
                "<section class=\"{section_class}\" data-depth=\"{}\">",
                node.depth
            ));
            section_open = true;
            if let Some(links) = chapters.get(node.entry_id.as_str()) {
                body.push_str("<nav class=\"chapter-navigation\">");
                for (target, label) in [(links.previous.as_ref(), "上一章")] {
                    if let Some(target) = target {
                        let i = ids.get(target.as_str()).ok_or_else(invalid)?;
                        body.push_str(&format!("<a href=\"body.xhtml#node-{i}\">{label}</a>"));
                    }
                }
                if let Some(contents) = links.contents {
                    let file = match contents {
                        "visible_toc" => "toc.xhtml",
                        "machine_toc" => "nav.xhtml",
                        _ => return Err(invalid()),
                    };
                    if !pages.contains_key(file) {
                        return Err(invalid());
                    }
                    body.push_str(&format!("<a href=\"{file}#toc\">目录</a>"));
                }
                if let Some(target) = &links.next {
                    let i = ids.get(target.as_str()).ok_or_else(invalid)?;
                    body.push_str(&format!("<a href=\"body.xhtml#node-{i}\">下一章</a>"));
                }
                body.push_str("</nav>");
            }
            body.push_str(&chapter_head(
                prepared,
                &node.role,
                heads
                    .get(&node_index)
                    .map(Vec::as_slice)
                    .unwrap_or_default(),
            )?);
            let class = match node.role {
                Role::Volume => "heading volume-heading",
                Role::Chapter => "heading chapter-heading",
                Role::Section => "heading section-heading",
                Role::Front => "heading front-heading",
                Role::Body => "text-line",
            };
            if node.role != Role::Body {
                tag = format!("h{}", (usize::from(node.depth) + 1).min(6));
            }
            attrs = format!(
                "id=\"node-{node_index}\" class=\"{class}\" data-depth=\"{}\"",
                node.depth
            );
            node_index += 1;
        }
        if block != next_block {
            block = next_block;
            match block.map(|(kind, _)| kind) {
                Some("system") => body.push_str(if m.system_block_style == "indent" {
                    "<div class=\"system-block system-block-indent\">"
                } else {
                    "<div class=\"system-block\">"
                }),
                Some("verse") => body.push_str(if m.verse_block_style == "indent" {
                    "<div class=\"verse-block verse-block-indent\">"
                } else {
                    "<div class=\"verse-block\">"
                }),
                Some("letter") => body.push_str("<div class=\"letter-block\">"),
                Some("quote") => body.push_str("<div class=\"quote-block\">"),
                _ => {}
            }
        }
        let original = &book.text[offset..content_end];
        let heading = node.is_some_and(|n| n.role != Role::Body);
        let blank = original.trim().is_empty();
        let first = !heading
            && tag == "p"
            && first_pending
            && !blank
            && m.first_paragraph_style != "normal"
            && line_block.is_none();
        // 场景分隔（V46，LAY-118）：原文留在 data-source 节点；换成装饰时原符号存于 data-original。
        let has_note = notes.as_ref().is_some_and(|notes| notes.has_line(offset));
        let scene = !has_note
            && annotation.is_none()
            && node.is_none()
            && m.scene_break_style != "off"
            && is_scene_break(original);
        if scene {
            first_pending = true;
            let vertical = m.writing_mode == "vertical";
            let (class, shown) = match m.scene_break_style.as_str() {
                "stars" => ("scene-break", Some("＊　＊　＊")),
                "diamonds" => ("scene-break", Some("◇　◇　◇")),
                "line" if vertical => ("scene-break", Some("―――")),
                "line" => ("scene-break scene-break-line", Some("\u{a0}")),
                _ => ("scene-break", None),
            };
            match shown {
                Some(text) => body.push_str(&format!(
                    "<p class=\"{class}\" data-source=\"true\" data-original=\"{}\" data-eol=\"{eol}\">{}</p>",
                    escaped(original)?,
                    escaped(text)?
                )),
                None => body.push_str(&format!(
                    "<p class=\"{class}\" data-source=\"true\" data-eol=\"{eol}\">{}</p>",
                    escaped(original)?
                )),
            }
        } else if !(!has_note && tag == "p" && m.remove_blank_lines && original.trim().is_empty()) {
            // 章首段落不缩进：去掉行首空白；设置了全角缩进时行首空白本来就会被替换，否则原文存于 data-original。
            let unindented = original.trim_start_matches([' ', '　', '\t']);
            let flush = first || line_block.is_some();
            if flush {
                attrs = attrs.replace(
                    "class=\"text-line\"",
                    &format!(
                        "class=\"text-line {}\"",
                        line_block.map_or("first-para", |(_, class)| class)
                    ),
                );
                if notes.is_none()
                    && m.block_annotations.is_empty()
                    && m.fullwidth_indent == 0
                    && unindented != original
                {
                    attrs.push_str(&format!(" data-original=\"{}\"", escaped(original)?));
                }
            }
            let content = if notes
                .as_ref()
                .is_some_and(|n| n.preserve_indent(offset, original))
            {
                original.to_owned()
            } else if flush {
                unindented.to_owned()
            } else if tag == "p" && m.fullwidth_indent > 0 && !original.trim().is_empty() {
                format!(
                    "{}{}",
                    "　".repeat(usize::from(m.fullwidth_indent)),
                    original.trim_start_matches([' ', '　', '\t'])
                )
            } else {
                original.to_owned()
            };
            // 注音、着重号与竖排的纵中横（V28）。
            let digits = (m.writing_mode == "vertical").then_some(m.vertical_digits);
            let label = node
                .filter(|n| {
                    m.heading_style == "two_line" && matches!(n.role, Role::Chapter | Role::Front)
                })
                .and_then(|_| chapter_label_end(&content));
            let inner = match label {
                Some(end) => format!(
                    "<span class=\"chapter-label\">{}</span><br/>{}",
                    crate::inline_markup::render(&content[..end], digits)?,
                    crate::inline_markup::render(&content[end..], digits)?
                ),
                None => match &notes {
                    Some(notes) => notes.render(offset, original, &content, digits)?,
                    None => crate::inline_markup::render(&content, digits)?,
                },
            };
            // 首字放大：只放大开头的文字；以标点、注音等标记开头时只取消缩进。
            let inner = match inner.chars().next() {
                Some(c)
                    if first
                        && m.first_paragraph_style == "large_initial"
                        && c.is_alphanumeric() =>
                {
                    format!(
                        "<span class=\"first-char\">{c}</span>{}",
                        &inner[c.len_utf8()..]
                    )
                }
                _ => inner,
            };
            // 注释、手工块和附页输出保留正文每行来源，包括排版替换前的文字。
            if (notes.is_some()
                || !m.block_annotations.is_empty()
                || !m.supplemental_pages.is_empty())
                && !attrs.contains(" data-original=")
            {
                attrs.push_str(&format!(
                    " data-original=\"{}\"",
                    escaped(original)?.replace('\t', "&#9;")
                ));
            }
            let definition = notes.as_ref().and_then(|notes| notes.definition(offset));
            if let Some(id) = definition {
                body.push_str(&format!(
                    "<aside epub:type=\"footnote\" id=\"note-{id}\" class=\"footnote\">"
                ));
            }
            body.push_str(&format!(
                "<{tag} {attrs} data-source=\"true\" data-eol=\"{eol}\">{inner}{}</{tag}>",
                if content.is_empty() { "<br/>" } else { "" }
            ));
            if definition.is_some() {
                body.push_str("</aside>");
            }
        }
        if heading {
            first_pending = true;
        } else if !blank && !scene {
            first_pending = false;
        }
        while let Some(p) = m
            .placements
            .get(placement_index)
            .filter(|p| p.after_utf8 == end)
        {
            let moved =
                p.layout == "chapter_head" && heads.values().flatten().any(|h| std::ptr::eq(*h, p));
            if !moved {
                body.push_str(&format!(
                    "<figure{}>{}<figcaption>{}</figcaption></figure>",
                    if p.layout == "full_page" {
                        " class=\"full-page-image\""
                    } else {
                        ""
                    },
                    image(prepared, &p.resource_id, &p.alt)?,
                    escaped(&p.caption)?
                ));
            }
            placement_index += 1;
        }
        offset = end;
        if body.len() > 64 * 1024 * 1024 {
            return Err(invalid());
        }
    }
    if block.is_some() {
        body.push_str("</div>");
    }
    if let Some(notes) = &notes {
        body.push_str(&notes.chapter_end(book.text.len())?);
    }
    if prefix {
        body.push_str("</section>");
    }
    if section_open {
        body.push_str("</section>");
    }
    if node_index != book.tree.nodes.len() || placement_index != m.placements.len() {
        return Err(invalid());
    }
    pages.insert("body.xhtml".into(), page(prepared, &m.title, &body)?);
    reading_order.push("body.xhtml".into());
    append_supplements(
        prepared,
        crate::supplemental_pages::Position::Back,
        &mut pages,
        &mut reading_order,
    )?;
    if pages.values().map(String::len).sum::<usize>() > 64 * 1024 * 1024 {
        return Err(invalid());
    }
    Ok(Documents {
        pages,
        reading_order,
    })
}

#[cfg(test)]
mod tests {
    use crate::publication_resources::{self, Request};
    use easypub_core::source::{RULE_ID, SourceSnapshot};
    use serde_json::json;

    fn request(source: &SourceSnapshot) -> Request {
        serde_json::from_value(json!({"source_id": source.summary().source_id, "revision": 1,
          "settings": {"title":"书名<&>", "author":"作者", "translator":"译者", "description":"简介\n第二行",
          "language":"zh-CN", "cover_fit":"contain", "font_family":"SimSun", "font_size":20,
          "line_height":1.8, "include_toc":true, "visible_toc":true, "chapter_navigation":true, "illustrations":[]}})).unwrap()
    }
    #[test]
    fn scene_breaks_are_recognised_styled_and_lossless() {
        use super::is_scene_break as sb;
        for yes in [
            "***",
            "＊＊＊",
            "* * *",
            "　◇　◇　◇",
            "※※※※",
            "＝＝＝＝＝",
            "~~~",
            "☆☆☆",
        ] {
            assert!(sb(yes), "{yes}");
        }
        for no in [
            "**",
            "……",
            "——",
            "------",
            "···",
            "",
            "***！",
            "第一章",
            "○",
            &"*".repeat(41),
        ] {
            assert!(!sb(no), "{no}");
        }
        let text = "第一章 开始\n正文甲\n＊＊＊\n正文乙\n……\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        for (style, shown, class) in [
            ("off", None, None),
            ("keep", Some("＊＊＊"), Some("scene-break")),
            ("stars", Some("＊　＊　＊"), Some("scene-break")),
            ("diamonds", Some("◇　◇　◇"), Some("scene-break")),
            ("line", Some("\u{a0}"), Some("scene-break scene-break-line")),
        ] {
            let mut req = request(&source);
            req.settings.scene_break_style = style.into();
            let prepared = publication_resources::prepare(&source, req).unwrap();
            let documents = prepared.documents().unwrap();
            let body = roxmltree::Document::parse(&documents.pages["body.xhtml"]).unwrap();
            let breaks: Vec<_> = body
                .descendants()
                .filter(|n| {
                    n.attribute("class")
                        .is_some_and(|c| c.contains("scene-break"))
                })
                .collect();
            assert_eq!(breaks.len(), usize::from(class.is_some()), "{style}");
            if let (Some(node), Some(shown), Some(class)) = (breaks.first(), shown, class) {
                assert_eq!(node.attribute("class"), Some(class));
                assert_eq!(node.text(), Some(shown));
                assert_eq!(node.attribute("data-original").is_some(), style != "keep");
            }
            // “……”单独成行仍是普通正文。
            assert!(
                body.descendants()
                    .any(|n| n.attribute("class") == Some("text-line") && n.text() == Some("……"))
            );
            let mut restored = String::new();
            for n in body
                .descendants()
                .filter(|n| n.attribute("data-source") == Some("true"))
            {
                restored.push_str(
                    n.attribute("data-original")
                        .or_else(|| n.text())
                        .unwrap_or(""),
                );
                restored.push('\n');
            }
            assert_eq!(restored, text, "{style}");
        }
        // 竖排时“细线”用竖向的横线字符，不用宽度画线。
        let mut req = request(&source);
        req.settings.scene_break_style = "line".into();
        req.settings.writing_mode = "vertical".into();
        let prepared = publication_resources::prepare(&source, req).unwrap();
        let page = &prepared.documents().unwrap().pages["body.xhtml"];
        assert!(page.contains("class=\"scene-break\" data-source=\"true\" data-original=\"＊＊＊\" data-eol=\"lf\">―――</p>"));
    }

    #[test]
    fn first_paragraph_after_heading_and_scene_break_is_styled_and_lossless() {
        let text = "第一章 开始\n\n　　正文甲\n　　正文乙\n＊＊＊\n“对白”\n　　正文丙\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        for style in ["normal", "no_indent", "large_initial"] {
            let mut req = request(&source);
            req.settings.first_paragraph_style = style.into();
            req.settings.fullwidth_indent = 0;
            let prepared = publication_resources::prepare(&source, req).unwrap();
            let page = prepared.documents().unwrap().pages["body.xhtml"].clone();
            let body = roxmltree::Document::parse(&page).unwrap();
            let firsts: Vec<_> = body
                .descendants()
                .filter(|n| n.attribute("class") == Some("text-line first-para"))
                .collect();
            if style == "normal" {
                assert!(firsts.is_empty());
                assert!(!page.contains("first-char"));
            } else {
                // 标题后第一段（跳过空行）与场景分隔后第一段；其后的段落不受影响。
                assert_eq!(firsts.len(), 2, "{style}");
                assert_eq!(firsts[0].attribute("data-original"), Some("　　正文甲"));
                assert_eq!(firsts[1].attribute("data-original"), None);
                assert!(page.contains(">　　正文乙</p>"));
                assert!(page.contains(">　　正文丙</p>"));
                if style == "large_initial" {
                    assert!(page.contains("<span class=\"first-char\">正</span>文甲</p>"));
                    // 以引号开头时不放大。
                    assert!(
                        page.contains(
                            "first-para\" data-source=\"true\" data-eol=\"lf\">“对白”</p>"
                        )
                    );
                } else {
                    assert!(!page.contains("first-char"));
                }
            }
            let mut restored = String::new();
            for n in body
                .descendants()
                .filter(|n| n.attribute("data-source") == Some("true"))
            {
                match n.attribute("data-original") {
                    Some(original) => restored.push_str(original),
                    None => n
                        .descendants()
                        .filter(|d| d.is_text())
                        .for_each(|d| restored.push_str(d.text().unwrap())),
                }
                restored.push('\n');
            }
            assert_eq!(restored, text, "{style}");
        }
    }

    #[test]
    fn system_and_verse_blocks_are_recognised_grouped_and_lossless() {
        use super::{is_system_line as sys, is_verse_attribution as by, is_verse_line as verse};
        for yes in [
            "【叮！新手礼包已发放。】",
            "　【当前修为：炼气一层】",
            "【力量：10】 【敏捷：8】",
        ] {
            assert!(sys(yes), "{yes}");
        }
        for no in [
            "【】",
            "【叮】他愣了一下",
            "他看到【提示】",
            "【未闭合",
            "【甲【乙】】",
            "",
        ] {
            assert!(!sys(no), "{no}");
        }
        for yes in [
            "床前明月光，疑是地上霜。",
            "　春风得意马蹄疾，一日看尽长安花",
            "白日依山尽，黄河入海流！",
        ] {
            assert!(verse(yes), "{yes}");
        }
        for no in [
            "他推门而出，雾散了。",
            "床前明月光，疑是霜。",
            "abcde，fghij。",
            "床前明月光。",
            "好好好好好，好好好好好，好好好好好。",
        ] {
            assert!(!verse(no), "{no}");
        }
        assert!(by("——李白《静夜思》"));
        assert!(!by("——"));
        assert!(!by("—李白"));
        let text = "第一章 开始\n　　他醒了。\n【叮！礼包已发放。】\n【修为：炼气一层】\n　　他念道：\n床前明月光，疑是地上霜。\n举头望明月，低头思故乡。\n——李白\n——他愣住了，说不出话。\n【提示：明日下山】\n第二章 下山\n【任务：下山】\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        for (system, verse_style) in [("off", "off"), ("box", "center"), ("indent", "indent")] {
            let mut req = request(&source);
            req.settings.system_block_style = system.into();
            req.settings.verse_block_style = verse_style.into();
            req.settings.fullwidth_indent = 0;
            let prepared = publication_resources::prepare(&source, req).unwrap();
            let page = prepared.documents().unwrap().pages["body.xhtml"].clone();
            let body = roxmltree::Document::parse(&page).unwrap();
            let blocks: Vec<_> = body
                .descendants()
                .filter(|n| n.has_tag_name("div"))
                .collect();
            if system == "off" {
                assert!(blocks.is_empty());
                assert!(!page.contains("system-line") && !page.contains("verse-line"));
            } else {
                let suffix = if system == "indent" {
                    " system-block-indent"
                } else {
                    ""
                };
                let verse_suffix = if verse_style == "indent" {
                    " verse-block-indent"
                } else {
                    ""
                };
                let classes: Vec<_> = blocks
                    .iter()
                    .map(|n| n.attribute("class").unwrap().to_owned())
                    .collect();
                // 两行系统提示一个框；两句诗加署名一组；章末与第二章开头的系统提示各自成框（块不跨章）。
                assert_eq!(
                    classes,
                    [
                        format!("system-block{suffix}"),
                        format!("verse-block{verse_suffix}"),
                        format!("system-block{suffix}"),
                        format!("system-block{suffix}"),
                    ]
                );
                let lines = |i: usize| -> Vec<String> {
                    blocks[i]
                        .children()
                        .filter(|n| n.is_element())
                        .map(|n| n.attribute("class").unwrap().to_owned())
                        .collect()
                };
                assert_eq!(lines(0), ["text-line system-line", "text-line system-line"]);
                assert_eq!(
                    lines(1),
                    [
                        "text-line verse-line",
                        "text-line verse-line",
                        "text-line verse-by"
                    ]
                );
                // 署名之后再出现的“——”对白不并入诗块。
                assert!(page.contains("<p class=\"text-line\" data-source=\"true\" data-eol=\"lf\">——他愣住了，说不出话。</p>"));
                // 块在下一章的分节之前关闭。
                assert!(page.contains("</div></section><section class=\"chapter-start\""));
            }
            let mut restored = String::new();
            for n in body
                .descendants()
                .filter(|n| n.attribute("data-source") == Some("true"))
            {
                match n.attribute("data-original") {
                    Some(original) => restored.push_str(original),
                    None => n
                        .descendants()
                        .filter(|d| d.is_text())
                        .for_each(|d| restored.push_str(d.text().unwrap())),
                }
                restored.push('\n');
            }
            assert_eq!(restored, text, "{system}");
        }
    }

    #[test]
    fn notes_first_paragraph_and_blocks_combine_without_losing_text() {
        // V48 注释、V49 首字放大、V50 系统提示与诗词同时开启。
        let text = "第一章 开始\n港口起雾①了。\n【叮！任务开启】\n床前明月光，疑是地上霜。\n——李白\n①雾：水汽。\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let mut req = request(&source);
        req.settings.note_style = "popup".into();
        req.settings.first_paragraph_style = "large_initial".into();
        req.settings.system_block_style = "box".into();
        req.settings.verse_block_style = "center".into();
        let prepared = publication_resources::prepare(&source, req).unwrap();
        let page = prepared.documents().unwrap().pages["body.xhtml"].clone();
        let body = roxmltree::Document::parse(&page).unwrap();
        assert!(page.contains("<span class=\"first-char\">港</span>"));
        assert!(page.contains("epub:type=\"noteref\""));
        assert!(page.contains("<aside epub:type=\"footnote\""));
        assert!(page.contains("<div class=\"system-block\">"));
        assert!(page.contains("<div class=\"verse-block\">"));
        let mut restored = String::new();
        for n in body
            .descendants()
            .filter(|n| n.attribute("data-source") == Some("true"))
        {
            restored.push_str(n.attribute("data-original").unwrap());
            restored.push('\n');
        }
        assert_eq!(restored, text);
    }

    #[test]
    fn two_line_headings_split_label_without_changing_text() {
        use super::chapter_label_end as end;
        assert_eq!(end("第一章 梦"), Some("第一章 ".len()));
        assert_eq!(end("  第12回：归来"), Some("  第12回：".len()));
        assert_eq!(end("第１０章梦"), Some("第１０章".len()));
        assert_eq!(end("第一章"), None);
        assert_eq!(end("第一章   "), None);
        assert_eq!(end("序章 开始"), None);
        assert_eq!(end("第章 无数字"), None);
        assert_eq!(end("第一个人"), None);
        let text = "第一章 梦\n正文\n第二章\n尾文";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        for style in crate::production::HEADING_STYLES {
            let mut req = request(&source);
            req.settings.heading_style = style.into();
            let prepared = publication_resources::prepare(&source, req).unwrap();
            let documents = prepared.documents().unwrap();
            let body = roxmltree::Document::parse(&documents.pages["body.xhtml"]).unwrap();
            let headings: Vec<_> = body
                .descendants()
                .filter(|n| n.attribute("class") == Some("heading chapter-heading"))
                .collect();
            assert_eq!(headings.len(), 2);
            let all: String = headings[0]
                .descendants()
                .filter(|n| n.is_text())
                .map(|n| n.text().unwrap())
                .collect();
            assert_eq!(all, "第一章 梦");
            let labels: Vec<_> = body
                .descendants()
                .filter(|n| n.attribute("class") == Some("chapter-label"))
                .map(|n| n.text().unwrap().to_string())
                .collect();
            if style == "two_line" {
                assert_eq!(labels, ["第一章 "]);
                let br = body.descendants().find(|n| n.has_tag_name("br")).unwrap();
                assert_eq!(
                    br.prev_sibling_element().unwrap().attribute("class"),
                    Some("chapter-label")
                );
                assert_eq!(headings[1].text(), Some("第二章"));
            } else {
                assert!(labels.is_empty());
            }
        }
    }
    #[test]
    fn deep_headings_keep_depth_and_missing_css_never_silently_disappears() {
        use easypub_core::structure::{Override, Role, Structure};
        let text = (0..9).map(|i| format!("层级 {i}\n")).collect::<String>();
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let mut req = request(&source);
        let mut structure = Structure::new(&source);
        structure.overrides = (0..9)
            .map(|depth| Override {
                source_line: u32::from(depth) + 1,
                role: Role::Section,
                depth,
                include_toc: true,
            })
            .collect();
        req.structure = Some(structure);
        let prepared = publication_resources::prepare(&source, req).unwrap();
        let documents = prepared.documents().unwrap();
        let doc = roxmltree::Document::parse(&documents.pages["body.xhtml"]).unwrap();
        assert_eq!(
            doc.descendants().filter(|n| n.has_tag_name("h6")).count(),
            4
        );
        assert!(
            doc.descendants()
                .any(|n| n.has_tag_name("h6") && n.attribute("data-depth") == Some("8"))
        );
        assert_eq!(
            doc.descendants()
                .filter(|n| n.attribute("data-source") == Some("true"))
                .count(),
            9
        );
        let mut req = request(&source);
        req.settings.additional_css = "p { background: url(missing.png); }".into();
        let prepared = publication_resources::prepare(&source, req).unwrap();
        assert!(prepared.documents().is_err());
    }
    #[test]
    fn semantic_pages_preserve_every_line_and_resolve_all_links() {
        let text = "前言 <script> &\r\n\r\n第一卷 开始\r卷首正文 \n第一章 重名\n  正文甲\t😀\n\n第二章 重名\n尾文  ";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        for machine in [false, true] {
            for visible in [false, true] {
                for top in [false, true] {
                    let mut req = request(&source);
                    let mut structure = easypub_core::structure::Structure::new(&source);
                    structure.overrides.push(easypub_core::structure::Override {
                        source_line: 1,
                        role: easypub_core::structure::Role::Body,
                        depth: 0,
                        include_toc: false,
                    });
                    req.structure = Some(structure);
                    req.settings.include_toc = machine;
                    req.settings.visible_toc = visible;
                    req.settings.chapter_navigation = top;
                    let prepared = publication_resources::prepare(&source, req).unwrap();
                    let documents = prepared.documents().unwrap();
                    let body = roxmltree::Document::parse(&documents.pages["body.xhtml"]).unwrap();
                    let mut reconstructed = String::new();
                    for n in body
                        .descendants()
                        .filter(|n| n.attribute("data-source") == Some("true"))
                    {
                        reconstructed.push_str(
                            n.attribute("data-original")
                                .or_else(|| n.text())
                                .unwrap_or(""),
                        );
                        reconstructed.push_str(match n.attribute("data-eol").unwrap() {
                            "crlf" => "\r\n",
                            "cr" => "\r",
                            "lf" => "\n",
                            "none" => "",
                            _ => panic!(),
                        });
                    }
                    assert_eq!(reconstructed, text);
                    assert!(!body.descendants().any(|n| n.has_tag_name("script")));
                    assert_eq!(
                        body.descendants()
                            .filter(|n| n.attribute("class") == Some("heading chapter-heading"))
                            .count(),
                        2
                    );
                    assert_eq!(documents.pages.contains_key("toc.xhtml"), visible);
                    assert_eq!(documents.pages.contains_key("nav.xhtml"), machine);
                    assert!(!documents.reading_order.contains(&"nav.xhtml".to_string()));
                    for page in documents.pages.values() {
                        let doc = roxmltree::Document::parse(page).unwrap();
                        for link in doc.descendants().filter(|n| n.has_tag_name("a")) {
                            let (file, id) =
                                link.attribute("href").unwrap().split_once('#').unwrap();
                            let target =
                                roxmltree::Document::parse(&documents.pages[file]).unwrap();
                            assert_eq!(
                                target
                                    .descendants()
                                    .filter(|n| n.attribute("id") == Some(id))
                                    .count(),
                                1
                            );
                        }
                        let styles: Vec<_> = doc
                            .descendants()
                            .filter(|n| n.has_tag_name("link"))
                            .map(|n| n.attribute("href").unwrap())
                            .collect();
                        assert_eq!(styles, prepared.manifest().stylesheet_order);
                    }
                }
            }
        }
    }
    #[test]
    fn illustrations_follow_exact_lines_including_heading_and_final_line() {
        let path =
            std::env::temp_dir().join(format!("easypub-documents-{}.png", std::process::id()));
        image::RgbaImage::from_pixel(2, 3, image::Rgba([1, 2, 3, 255]))
            .save(&path)
            .unwrap();
        let second = path.with_extension("second.png");
        let third = path.with_extension("third.png");
        std::fs::copy(&path, &second).unwrap();
        std::fs::copy(&path, &third).unwrap();
        let source =
            SourceSnapshot::from_utf8("第一章 甲\n正文".as_bytes().to_vec(), RULE_ID, || {
                false
            })
            .unwrap();
        let mut req = request(&source);
        req.settings.cover_path = Some(path.to_string_lossy().into());
        req.settings.illustrations = serde_json::from_value(json!([
          {"path":path, "source_line":1, "caption":"标题后<&>", "alt":"甲"},
          {"path":second, "source_line":2, "caption":"正文后", "alt":"乙"},
          {"path":third, "source_line":2, "caption":"第二张", "alt":"丙"}
        ]))
        .unwrap();
        let prepared = publication_resources::prepare(&source, req).unwrap();
        let documents = prepared.documents().unwrap();
        assert_eq!(
            documents.reading_order,
            ["cover.xhtml", "title.xhtml", "toc.xhtml", "body.xhtml"]
        );
        let body = roxmltree::Document::parse(&documents.pages["body.xhtml"]).unwrap();
        let figures: Vec<_> = body
            .descendants()
            .filter(|n| n.has_tag_name("figure"))
            .collect();
        assert_eq!(figures.len(), 3);
        assert_eq!(
            figures[0].prev_sibling_element().unwrap().text(),
            Some("第一章 甲")
        );
        assert_eq!(
            figures[1].prev_sibling_element().unwrap().text(),
            Some("正文")
        );
        assert_eq!(figures[2].prev_sibling_element().unwrap(), figures[1]);
        for page in documents.pages.values() {
            let doc = roxmltree::Document::parse(page).unwrap();
            for img in doc.descendants().filter(|n| n.has_tag_name("img")) {
                assert!(
                    prepared
                        .image_bytes(img.attribute("src").unwrap())
                        .is_some()
                );
            }
        }
        // 封面页（OUT-074）：SVG 的 viewBox 是封面图的实际尺寸，按“封面适配方式”保持比例。
        let m = prepared.manifest();
        let cover_id = m.cover.as_ref().unwrap();
        let resource = m.resources.iter().find(|r| &r.id == cover_id).unwrap();
        let cover = roxmltree::Document::parse(&documents.pages["cover.xhtml"]).unwrap();
        let svg = cover.descendants().find(|n| n.has_tag_name("svg")).unwrap();
        assert_eq!(
            svg.attribute("viewBox"),
            Some(format!("0 0 {} {}", resource.width, resource.height).as_str())
        );
        assert_eq!(svg.attribute("preserveAspectRatio"), Some("xMidYMid meet"));
        let image = svg.descendants().find(|n| n.has_tag_name("image")).unwrap();
        let href = image
            .attribute(("http://www.w3.org/1999/xlink", "href"))
            .unwrap();
        assert!(prepared.image_bytes(href).is_some());
        assert!(cover.descendants().all(|n| !n.has_tag_name("img")));
        // KFX 用普通图片的封面页。
        let plain = super::cover_page(&prepared, false).unwrap().unwrap();
        let plain = roxmltree::Document::parse(&plain).unwrap();
        assert!(plain.descendants().any(|n| n.has_tag_name("img")));
        assert!(plain.descendants().all(|n| !n.has_tag_name("svg")));
        std::fs::remove_file(path).unwrap();
        std::fs::remove_file(second).unwrap();
        std::fs::remove_file(third).unwrap();
    }
}
