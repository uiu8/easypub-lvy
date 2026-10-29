//! Semantic XHTML pages built from the final composed book, not source guesses.
use crate::{navigation_documents::escaped, publication_resources::Prepared};
use easypub_core::{ApiError, ErrorCode, structure::Role};
use std::collections::{BTreeMap, HashSet};

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
#[allow(clippy::too_many_arguments)]
pub(crate) fn classify_block(
    line: &str,
    has_node: bool,
    annotation: Option<&crate::block_annotations::Annotation>,
    range: (usize, usize),
    previous_line: Option<&str>,
    next_line: Option<&str>,
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
            Kind::Inset => Some(("inset", "inset-line")),
            Kind::None => None,
        }
    } else if has_node {
        None
    } else if system_style != "off"
        && (is_system_line(line)
            || (system_style == "styled"
                && crate::block_styles::is_ding_line(line)
                && next_line.is_some_and(is_system_line)))
    {
        Some(("system", "system-line"))
    } else if verse_style != "off"
        && is_verse_line(line)
        // V92：只认成组的诗句——上一行已是诗句，或下一行仍是诗句 / 署名。
        // 夹在正文里的单句（“我点开图片一看，整个人不由一怔！”）按正文。
        && (previous_line == Some("verse-line")
            || next_line.is_some_and(|n| is_verse_line(n) || is_verse_attribution(n)))
    {
        Some(("verse", "verse-line"))
    } else if previous_line == Some("verse-line") && is_verse_attribution(line) {
        Some(("verse", "verse-by"))
    } else {
        None
    }
}

/// 分类样式（V77，LAY-132）：每段连续系统提示的行数，按段首行的字节偏移记录。
/// 与正文生成用同一个 [classify_block]；手工标注与自动识别各自成段。
fn system_runs(
    text: &str,
    nodes: &[easypub_core::structure::Node],
    annotations: &[crate::block_annotations::Annotation],
    system_style: &str,
    verse_style: &str,
    custom: Option<&regex::RegexSet>,
    insets: &BTreeMap<usize, crate::insets::Line>,
) -> BTreeMap<usize, (usize, Option<bool>)> {
    let mut runs = BTreeMap::new();
    let (mut offset, mut ni, mut ai) = (0usize, 0usize, 0usize);
    // (段首偏移, 标注 ID, 行数, 标注指定的样式：Some(true) 面板)
    let mut current: Option<(usize, Option<&str>, usize, Option<bool>)> = None;
    while offset < text.len() {
        let rest = &text[offset..];
        let length = rest.find(['\r', '\n']).unwrap_or(rest.len());
        let content_end = offset + length;
        let tail = &text[content_end..];
        let eol = if tail.starts_with("\r\n") {
            2
        } else if tail.starts_with(['\r', '\n']) {
            1
        } else {
            0
        };
        let end = content_end + eol;
        while nodes.get(ni).is_some_and(|n| n.start < offset) {
            ni += 1;
        }
        let node = nodes.get(ni).is_some_and(|n| n.start == offset);
        while annotations.get(ai).is_some_and(|a| a.end <= offset) {
            ai += 1;
        }
        let annotation = annotations.get(ai).filter(|a| a.start <= offset);
        let next = (end < text.len()).then(|| {
            let after = &text[end..];
            &after[..after.find(['\r', '\n']).unwrap_or(after.len())]
        });
        let line = &text[offset..content_end];
        let kind = custom_system(
            classify_block(
                line,
                node,
                annotation,
                (offset, end),
                None,
                next,
                system_style,
                verse_style,
            ),
            line,
            node || annotation.is_some(),
            system_style,
            custom,
        );
        // 场景块（V81）里的行不算系统提示：自动识别的聊天记录优先于系统提示。
        let kind = if insets.contains_key(&offset) {
            None
        } else {
            kind
        };
        let key = annotation.map(|a| a.id.as_str());
        let forced = annotation
            .and_then(|a| a.variant.as_deref())
            .map(|v| v == "panel");
        match (kind, &mut current) {
            (Some(("system", _)), Some((_, k, n, _))) if *k == key && !node => *n += 1,
            (Some(("system", _)), _) => {
                if let Some((start, _, n, f)) = current.take() {
                    runs.insert(start, (n, f));
                }
                current = Some((offset, key, 1, forced));
            }
            _ => {
                if let Some((start, _, n, f)) = current.take() {
                    runs.insert(start, (n, f));
                }
            }
        }
        offset = end.max(offset + 1);
    }
    if let Some((start, _, n, f)) = current {
        runs.insert(start, (n, f));
    }
    runs
}

/// 系统提示自定义识别（V78，LAY-134）：自动识别没有归类、没有标题与手工标注的行，
/// 整行匹配自定义规则时算系统提示。
pub(crate) fn custom_system(
    kind: Option<(&'static str, &'static str)>,
    line: &str,
    excluded: bool,
    system_style: &str,
    custom: Option<&regex::RegexSet>,
) -> Option<(&'static str, &'static str)> {
    match (kind, custom) {
        (None, Some(set)) if !excluded && system_style != "off" && set.is_match(line.trim()) => {
            Some(("system", "system-line"))
        }
        _ => kind,
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

/// 生僻字注音（V73，LAY-129）：只处理标签外、已有 `<ruby>` 之外的文字。
/// `seen` 为 None 时每次都标；否则只标集合里还没有的字，并记入集合。返回是否改动。
pub(crate) fn rare_char_ruby(
    html: &str,
    scope: easypub_core::rare_chars::Scope,
    mut seen: Option<&mut HashSet<char>>,
) -> Option<String> {
    let mut out = String::with_capacity(html.len());
    let (mut in_tag, mut ruby_depth, mut changed) = (false, 0usize, false);
    let mut tag = String::new();
    for c in html.chars() {
        if in_tag {
            tag.push(c);
            if c == '>' {
                in_tag = false;
                let lower = tag.to_ascii_lowercase();
                if lower.starts_with("<ruby") {
                    ruby_depth += 1;
                } else if lower.starts_with("</ruby") {
                    ruby_depth = ruby_depth.saturating_sub(1);
                }
                out.push_str(&tag);
                tag.clear();
            }
            continue;
        }
        if c == '<' {
            in_tag = true;
            tag.push(c);
            continue;
        }
        let reading = (ruby_depth == 0)
            .then(|| easypub_core::rare_chars::reading(c, scope))
            .flatten()
            .filter(|_| seen.as_mut().is_none_or(|set| set.insert(c)));
        match reading {
            Some(py) => {
                changed = true;
                out.push_str(&format!(
                    "<ruby>{c}<rp>（</rp><rt>{py}</rt><rp>）</rp></ruby>"
                ));
            }
            None => out.push(c),
        }
    }
    out.push_str(&tag);
    changed.then_some(out)
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
    na == nb
        && (na == 5 || na == 7)
        && a.chars().chain(b.chars()).all(is_han)
        // V92：网文里“这份潜在的商机，是我不能忽视的！”这类 7+7 的白话句子很常见，
        // 含现代白话虚词、代词的不算诗句（古诗里几乎不用这些字）。
        && !a.chars().chain(b.chars()).any(|c| MODERN_PROSE.contains(&c))
}

const MODERN_PROSE: [char; 17] = [
    '的', '了', '们', '吗', '呢', '吧', '啊', '呀', '么', '很', '这', '那', '没', '她', '它', '您',
    '咱',
];

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
    rotation: &mut usize,
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
    // 已设的章首图优先；否则用样式包的章头图，按章轮换（V74，LAY-130）。
    let styled = m
        .chapter_style
        .as_ref()
        .filter(|s| !s.head_ids.is_empty())
        .map(|s| s.head_ids[*rotation % s.head_ids.len()].clone());
    if own.is_empty()
        && applies
        && let Some(id) = m.chapter_head_image_id.clone().or(styled)
    {
        *rotation += 1;
        html.push_str(&format!(
            "<figure class=\"chapter-head-image {width}\">{}</figure>",
            image(prepared, &id, "")?
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
        crate::publication_notes::Notes::with_options(
            book,
            &m.manual_notes,
            m.note_style == "popup",
            &m.rule_options,
        )
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
    // 章节样式包（V74，LAY-130）：章头图轮换计数；当前是否在章或前置部分里（用于章末装饰）。
    let mut head_rotation = 0usize;
    let mut in_chapter = false;
    let chapter_end = match m
        .chapter_style
        .as_ref()
        .and_then(|s| s.chapter_end_id.as_ref())
    {
        Some(id) => Some(format!(
            "<p class=\"chapter-end\">{}</p>",
            image(prepared, id, "")?
        )),
        None => None,
    };
    let title_rule = match m
        .chapter_style
        .as_ref()
        .and_then(|s| s.title_rule_id.as_ref())
    {
        Some(id) => Some(format!(
            "<p class=\"title-rule\">{}</p>",
            image(prepared, id, "")?
        )),
        None => None,
    };
    // 章首插图（V54）：挂到所在章（插图之前最近的标题）；书首无标题时按随正文输出。
    let mut heads: BTreeMap<usize, Vec<&crate::publication_resources::Placement>> = BTreeMap::new();
    for p in m.placements.iter().filter(|p| p.layout == "chapter_head") {
        if let Some(index) = book.tree.nodes.iter().rposition(|n| n.start < p.after_utf8) {
            heads.entry(index).or_default().push(p);
        }
    }
    // 章首段落（V49，LAY-119）：标题或场景分隔之后、尚未遇到非空正文段。
    let mut first_pending = false;
    // 生僻字注音（V73，LAY-129）：已标过的字；每章首次时遇到章、卷、前置部分标题清空。
    let rare_scope = easypub_core::rare_chars::Scope::parse(&m.rare_char_scope)
        .unwrap_or(easypub_core::rare_chars::Scope::Outside);
    let mut rare_seen: HashSet<char> = HashSet::new();
    // 系统提示与诗词（V50，LAY-121/122）：当前打开的块。
    // 标注 ID 区分手工块与相邻自动块、相邻同类手工块。
    let mut block: Option<(&str, Option<&str>)> = None;
    let mut annotation_index = 0;
    let mut previous_line: Option<&str> = None;
    // 系统提示分类样式（V77，LAY-132）：每段行数；当前段是否面板、段内第几行、有无标题。
    let styled = m
        .system_styles
        .as_ref()
        .filter(|_| m.system_block_style == "styled");
    let custom = m.rule_options.system_set();
    // 场景样式（V81，LAY-135）：手工标注的场景与自动识别的聊天记录，逐行角色。
    let inset_plan = crate::insets::plan(
        &book.text,
        &book.tree.nodes,
        &m.block_annotations,
        m.chat_block_style != "off",
        &crate::insets::Rules::from_settings(&m.inset_detect, &m.rule_options),
    );
    // 各场景实际使用的样式参数（V82，LAY-136）：饰纹、首字放大、卷轴杆、聊天名字位置。
    let inset_styles: BTreeMap<&str, crate::inset_styles::InsetStyle> = crate::insets::TYPES
        .iter()
        .map(|(scene, _)| {
            (
                *scene,
                crate::inset_styles::effective(m.inset_styles.as_ref(), scene, &m.chat_block_style),
            )
        })
        .collect();
    let rod = match m.inset_images.as_ref().and_then(|i| i.rod.as_ref()) {
        Some(id) => Some(format!(
            "<p class=\"inset-rod\">{}</p>",
            image(prepared, id, "")?
        )),
        None => None,
    };
    // 当前打开的场景块（场景编号），以及块里是否已遇到第一行正文（首字放大）。
    let mut open_inset: Option<&str> = None;
    let mut inset_dropped = false;
    let close_block = |body: &mut String, open: &mut Option<&str>| match open.take() {
        Some(kind) => {
            body.push_str("</div></div>");
            if inset_styles[kind].rods
                && let Some(html) = &rod
            {
                body.push_str(html);
            }
        }
        None => body.push_str("</div>"),
    };
    let runs = match styled {
        Some(_) => system_runs(
            &book.text,
            &book.tree.nodes,
            &m.block_annotations,
            &m.system_block_style,
            &m.verse_block_style,
            custom.as_ref(),
            &inset_plan,
        ),
        None => BTreeMap::new(),
    };
    let mut styled_block: Option<(bool, usize, bool)> = None;
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
        let next_line = {
            let after = &book.text[end..];
            (end < book.text.len())
                .then(|| &after[..after.find(['\r', '\n']).unwrap_or(after.len())])
        };
        let line_block = custom_system(
            classify_block(
                line,
                node.is_some(),
                annotation,
                (offset, end),
                previous_line,
                next_line,
                &m.system_block_style,
                &m.verse_block_style,
            ),
            line,
            node.is_some() || annotation.is_some(),
            &m.system_block_style,
            custom.as_ref(),
        );
        let line_block = if annotation.is_none() {
            m.rule_options.verse(line, line_block)
        } else {
            line_block
        };
        let inset = inset_plan.get(&offset).copied();
        // 自动识别的块：聊天按 chat 统计，规则识别的按 inset（V82）；手工标注沿用 classify_block。
        let line_block = match inset {
            Some(l) if l.source == "chat" => Some(("chat", "inset-line")),
            Some(l) if l.automatic() => Some(("inset", "inset-line")),
            _ => line_block,
        };
        previous_line = if annotation.is_none() {
            line_block.map(|(_, class)| class)
        } else {
            None
        };
        let next_block = line_block.map(|(kind, _)| (kind, annotation.map(|a| a.id.as_str())));
        // 相邻的两段场景（例如两份诏书）各自成块。
        let inset_start = inset.is_some_and(|l| l.block == offset);
        if block != next_block || node.is_some() || inset_start {
            if block.is_some() {
                close_block(&mut body, &mut open_inset);
            }
            block = None;
        }
        if let Some(node) = node {
            if m.rare_char_ruby == "chapter"
                && matches!(node.role, Role::Volume | Role::Chapter | Role::Front)
            {
                rare_seen.clear();
            }
            if matches!(node.role, Role::Volume | Role::Chapter | Role::Front) {
                if in_chapter && let Some(html) = &chapter_end {
                    body.push_str(html);
                }
                in_chapter = matches!(node.role, Role::Chapter | Role::Front);
            }
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
                &mut head_rotation,
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
                Some("system") if styled.is_some() => {
                    let styles = styled.expect("styled");
                    let (count, forced) = runs.get(&offset).copied().unwrap_or((1, None));
                    let panel = forced.unwrap_or(count > 1);
                    let title = panel
                        && styles.panel.title != "none"
                        && crate::block_styles::is_title(line);
                    styled_block = Some((panel, 0, title));
                    body.push_str(&format!(
                        "<div class=\"blk blk-{}{}\">",
                        if panel { "panel" } else { "note" },
                        if title { " blk-has-title" } else { "" }
                    ));
                }
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
                Some("letter") => body.push_str(if m.letter_block_style == "ruled" {
                    "<div class=\"letter-block letter-ruled\">"
                } else {
                    "<div class=\"letter-block\">"
                }),
                Some("inset" | "chat") => {
                    let kind = inset.map_or("chat", |l| l.kind);
                    if inset_styles[kind].rods
                        && let Some(html) = &rod
                    {
                        body.push_str(html);
                    }
                    body.push_str(&format!(
                        "<div class=\"inset inset-{kind}{}\"><div class=\"inset-inner\">",
                        if kind == "chat" {
                            format!(" inset-names-{}", inset_styles[kind].names)
                        } else {
                            String::new()
                        }
                    ));
                    open_inset = Some(kind);
                    inset_dropped = false;
                }
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
        let line_styles: Vec<_> = m
            .inline_styles
            .iter()
            .filter(|a| a.anchor.start == offset)
            .collect();
        let has_note = notes.as_ref().is_some_and(|notes| notes.has_line(offset));
        // 章节分隔线（V116）：整行横线（如“----------”）紧挨下一个标题或在全文末尾时不输出，
        // 正文中间的按场景分隔处理。
        let rule_line = node.is_none()
            && annotation.is_none()
            && line_styles.is_empty()
            && !has_note
            && easypub_core::is_rule_line(original);
        let rule_at_boundary = rule_line && {
            let upcoming = book.tree.nodes[node_index.min(book.tree.nodes.len())..]
                .iter()
                .find(|n| n.start >= end);
            match upcoming {
                Some(n) => n.role != Role::Body && book.text[end..n.start].trim().is_empty(),
                None => book.text[end..].trim().is_empty(),
            }
        };
        let scene = line_styles.is_empty()
            && !has_note
            && annotation.is_none()
            && node.is_none()
            && m.scene_break_style != "off"
            && (m.rule_options.scene(original) || (rule_line && !rule_at_boundary));
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
        } else if !(!has_note
            && tag == "p"
            && (rule_at_boundary || m.remove_blank_lines && original.trim().is_empty()))
        {
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
            if let Some(l) = inset {
                attrs = attrs.replace("inset-line", &format!("inset-line inset-{}", l.role));
            }
            let content = if line_styles
                .iter()
                .any(|a| a.anchor.from < original.len() - unindented.len())
                || notes
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
            let old_prefix = original.len() - unindented.len();
            let new_prefix = content.len() - content.trim_start_matches([' ', '　', '\t']).len();
            let adjusted: Vec<_> = line_styles
                .iter()
                .map(|a| {
                    let mut a = (*a).clone();
                    if content != original {
                        a.anchor.from = a.anchor.from - old_prefix + new_prefix;
                        a.anchor.to = a.anchor.to - old_prefix + new_prefix;
                    }
                    a
                })
                .collect();
            let styles: Vec<_> = adjusted.iter().collect();
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
                    Some(notes) => notes.render(offset, original, &content, digits, &styles)?,
                    None => crate::inline_styles::render(&content, 0, &styles, digits)?,
                },
            };
            if !styles.is_empty() && !attrs.contains(" data-original=") {
                attrs.push_str(&format!(
                    " data-original=\"{}\"",
                    escaped(original)?.replace('\t', "&#9;")
                ));
            }
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
            // 场景样式（V81）：聊天行拆出名字；古籍、羊皮纸标题加饰纹；羊皮纸首段首字放大。原文存于 data-original。
            let mut who = None;
            let inner = match inset {
                Some(l) if l.role == "say" && !has_note => {
                    match crate::insets::chat_line(&content) {
                        Some(((ns, ne), (ss, se))) => {
                            let name = crate::inline_styles::render(
                                &content[ns..ne],
                                ns,
                                &styles,
                                digits,
                            )?;
                            let say = crate::inline_styles::render(
                                &content[ss..se],
                                ss,
                                &styles,
                                digits,
                            )?;
                            if inset_styles[l.kind].names == "inline" {
                                format!("<span class=\"inset-who\">{name}</span> ▷ {say}")
                            } else {
                                who = Some(format!("<p class=\"inset-line inset-who\">{name}</p>"));
                                say
                            }
                        }
                        None => inner,
                    }
                }
                Some(l)
                    if l.role == "head"
                        && let (Some(open), Some(close)) = (
                            inset_styles[l.kind].ornament_char(),
                            inset_styles[l.kind].ornament_close(),
                        ) =>
                {
                    format!(
                        "<span class=\"inset-orn\">{open}</span> {inner} <span class=\"inset-orn\">{close}</span>"
                    )
                }
                Some(l) if l.role == "body" && inset_styles[l.kind].drop && !inset_dropped => {
                    inset_dropped = true;
                    match inner.chars().next() {
                        Some(c) if c.is_alphanumeric() => format!(
                            "<span class=\"inset-drop\">{c}</span>{}",
                            &inner[c.len_utf8()..]
                        ),
                        _ => inner,
                    }
                }
                _ => inner,
            };
            if inset.is_some() && !attrs.contains(" data-original=") {
                attrs.push_str(&format!(
                    " data-original=\"{}\"",
                    escaped(original)?.replace('\t', "&#9;")
                ));
            }
            // 系统提示分类样式（V77）：按单行提示 / 面板的参数去括号、标标题、键名加粗；原文存于 data-original。
            let inner = match (styled, styled_block.as_mut(), line_block) {
                (Some(styles), Some((panel, index, title)), Some(("system", _))) => {
                    let params = if *panel { &styles.panel } else { &styles.note };
                    let mut next = if params.brackets == "remove" {
                        crate::block_styles::strip_brackets(&inner)
                    } else {
                        inner.clone()
                    };
                    if *index == 0 && *title {
                        attrs = attrs.replace("system-line", "system-line blk-panel-title");
                    } else if params.key_bold {
                        next = crate::block_styles::mark_key(&next);
                    }
                    *index += 1;
                    if next != inner && !attrs.contains(" data-original=") {
                        attrs.push_str(&format!(
                            " data-original=\"{}\"",
                            escaped(original)?.replace('\t', "&#9;")
                        ));
                    }
                    next
                }
                _ => inner,
            };
            // 生僻字注音：只标正文段，不标标题；原文存于 data-original。
            let inner = match (heading, m.rare_char_ruby.as_str()) {
                (false, mode @ ("chapter" | "book" | "every")) => {
                    let seen = (mode != "every").then_some(&mut rare_seen);
                    match rare_char_ruby(&inner, rare_scope, seen) {
                        Some(marked) => {
                            if !attrs.contains(" data-original=") {
                                attrs.push_str(&format!(
                                    " data-original=\"{}\"",
                                    escaped(original)?.replace('\t', "&#9;")
                                ));
                            }
                            marked
                        }
                        None => inner,
                    }
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
            if let Some(html) = who {
                body.push_str(&html);
            }
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
            if node.is_some_and(|n| matches!(n.role, Role::Chapter | Role::Front))
                && let Some(html) = &title_rule
            {
                body.push_str(html);
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
        close_block(&mut body, &mut open_inset);
    }
    if in_chapter && let Some(html) = &chapter_end {
        body.push_str(html);
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

    /// V116：章末紧挨下一个标题的横线分隔线不输出；正文中间的横线按场景分隔。
    #[test]
    fn rule_lines_vanish_at_chapter_boundaries_and_split_scenes_inside() {
        let dash = "-".repeat(40);
        let text = format!(
            "第一章 开始\n　　正文甲\n{dash}\n　　正文乙\n\n{dash}\n\n第二章 继续\n　　正文丙\n{dash}\n"
        );
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let mut req = request(&source);
        req.settings.scene_break_style = "diamonds".into();
        let prepared = publication_resources::prepare(&source, req).unwrap();
        let pages = prepared.documents().unwrap().pages;
        let all: String = pages.values().cloned().collect();
        // 正文中的一条变成场景分隔；章末与全文末尾的两条不输出。
        assert_eq!(all.matches("scene-break").count(), 1, "{all}");
        assert_eq!(
            all.matches(dash.as_str()).count(),
            1,
            "原符号只留在场景分隔的 data-original 里"
        );
        assert!(all.contains("正文丙"));
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
                            "first-para\" data-source=\"true\" data-eol=\"lf\"><span class=\"nb\">“对</span><span class=\"nb\">白”</span></p>"
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
    fn system_styles_note_panel_ding_title_keys_and_lossless() {
        let text = "第一章 开始\n妖兽倒地。\n【叮！击杀成功，经验+120】\n他收剑入鞘。\n叮！\n【苍白的正义】\n【攻击力：20-25】\n【终极圣炎：附带30点伤害】\n正文。\n【力量：10】 【敏捷：8】\n【体质：12】\n结尾。\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let mut req = request(&source);
        req.settings.system_block_style = "styled".into();
        let prepared = publication_resources::prepare(&source, req).unwrap();
        let page = prepared.documents().unwrap().pages["body.xhtml"].clone();
        // 单行：提示条，保留括号。
        assert!(page.contains("<div class=\"blk blk-note\"><p class=\"text-line system-line\""));
        assert!(page.contains(">【叮！击杀成功，经验+120】</p></div>"));
        // “叮！”并入面板并作标题；其余去括号、键名加粗。
        assert!(page.contains("<div class=\"blk blk-panel blk-has-title\"><p class=\"text-line system-line blk-panel-title\""));
        assert!(page.contains(">叮！</p>"));
        assert!(
            page.contains(">苍白的正义</p>"),
            "第二行不是标题，但去掉括号"
        );
        assert!(page.contains("><span class=\"blk-key\">攻击力</span>：20-25</p>"));
        // 首行带冒号：不作标题；多段【】换成全角空格。
        assert!(page.contains("<div class=\"blk blk-panel\"><p class=\"text-line system-line\""));
        assert!(page.contains("><span class=\"blk-key\">力量</span>：10　敏捷：8</p>"));
        assert_eq!(page.matches("class=\"blk ").count(), 3);
        let css = &prepared.manifest().stylesheet.css;
        assert!(css.contains(".blk-note {") && css.contains(".blk-panel .blk-panel-title {"));
        // 原文可还原。
        let doc = roxmltree::Document::parse(&page).unwrap();
        let mut restored = String::new();
        for n in doc
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
        assert!(restored.contains("叮！\n【苍白的正义】\n【攻击力：20-25】\n"));
        assert!(restored.contains("【力量：10】 【敏捷：8】\n【体质：12】\n"));
        // 旧书的“加框”：输出不变，“叮！”不并入，成品参数里没有分类样式。
        let mut req = request(&source);
        req.settings.system_block_style = "box".into();
        let prepared = publication_resources::prepare(&source, req).unwrap();
        let page = prepared.documents().unwrap().pages["body.xhtml"].clone();
        assert!(!page.contains("blk"));
        assert_eq!(page.matches("<div class=\"system-block\">").count(), 3);
        assert!(page.contains(">叮！</p>") && !page.contains("<div class=\"system-block\"><p class=\"text-line system-line\" data-source=\"true\" data-eol=\"lf\">叮！"));
        let value = serde_json::to_value(prepared.manifest()).unwrap();
        assert!(value.get("system_styles").is_none());
    }

    #[test]
    fn insets_chat_detection_manual_scenes_letter_ruled_and_lossless() {
        use sha2::{Digest, Sha256};
        let text = "第一章 开始\n正文。\n九州一号群\n— 22:01 —\n【四：以雕像作为封印阵法。】\n\n【一：眉心开裂？】\n【四：有可能。】\n后文。\n奉天承运 皇帝诏曰\n着即晋封国公。\n钦此\n契约\n立约人以血为誓。\n——灰塔之印\n吾儿见字如面：\n勿念家中。\n母字\n九州一号群\n四：甲\n一：乙\n结尾。\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let mark = |piece: &str, kind: &str, variant: Option<&str>| {
            let start = text.find(piece).unwrap();
            let end = start + piece.len();
            let mut v = json!({"id": format!("{:x}", Sha256::digest(piece.as_bytes())), "start": start, "end": end,
                   "kind": kind,
                   "fingerprint": format!("{:x}", Sha256::digest(&text.as_bytes()[start..end]))});
            if let Some(variant) = variant {
                v["variant"] = json!(variant);
            }
            v
        };
        let restore = |page: &str| {
            let body = roxmltree::Document::parse(page).unwrap();
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
            restored
        };
        let annotations = json!([
            mark(
                "奉天承运 皇帝诏曰\n着即晋封国公。\n钦此\n",
                "inset",
                Some("edict")
            ),
            mark(
                "契约\n立约人以血为誓。\n——灰塔之印\n",
                "inset",
                Some("scroll")
            ),
            mark("吾儿见字如面：\n勿念家中。\n母字\n", "letter", None),
            mark("九州一号群\n四：甲\n一：乙\n", "inset", Some("chat")),
        ]);
        for look in ["window", "script", "channel"] {
            let mut req = request(&source);
            req.settings.system_block_style = "styled".into();
            req.settings.chat_block_style = look.into();
            req.settings.letter_block_style = "ruled".into();
            req.settings.block_annotations = serde_json::from_value(annotations.clone()).unwrap();
            let prepared = publication_resources::prepare(&source, req).unwrap();
            let page = prepared.documents().unwrap().pages["body.xhtml"].clone();
            // 自动识别：【】聊天行优先于系统提示，空行与时间行留在块里；前一行群名不在自动块里。
            assert!(
                page.contains(&format!(
                    "<div class=\"inset inset-chat inset-names-{}\"><div class=\"inset-inner\">",
                    match look {
                        "window" => "block",
                        "script" => "center",
                        _ => "inline",
                    }
                )),
                "{look}"
            );
            assert_eq!(page.matches("inset-chat").count(), 2, "{look}");
            assert!(!page.contains("blk blk-"), "聊天行不再算系统提示");
            assert!(page.contains("inset-line inset-time"));
            if look == "channel" {
                assert!(
                    page.contains("<span class=\"inset-who\">四</span> ▷ 以雕像作为封印阵法。</p>")
                );
                assert!(!page.contains("<p class=\"inset-line inset-who\">"));
            } else {
                assert!(page.contains("<p class=\"inset-line inset-who\">四</p><p class=\"text-line inset-line inset-say\""));
                assert!(page.contains(">以雕像作为封印阵法。</p>"));
            }
            // 手工聊天：首行群名为标题。
            assert!(page.contains("inset-line inset-head\" data-original=\"九州一号群\""));
            // 诏书：标题、落款；羊皮纸：卷轴杆、饰纹、首字放大、落款。
            assert!(page.contains("<div class=\"inset inset-edict\"><div class=\"inset-inner\">"));
            assert!(page.contains("inset-line inset-end\" data-original=\"钦此\""));
            let images = prepared.manifest().inset_images.clone().unwrap();
            let (rod, paper) = (images.rod.unwrap(), images.paper.unwrap());
            assert!(page.contains(&format!("<p class=\"inset-rod\"><img src=\"{}\" alt=\"\"/></p><div class=\"inset inset-scroll\">", rod)));
            assert!(page.contains(&format!(
                "灰塔之印</p></div></div><p class=\"inset-rod\"><img src=\"{}\"",
                rod
            )));
            assert!(page.contains(
                "<span class=\"inset-orn\">※</span> 契约 <span class=\"inset-orn\">※</span>"
            ));
            assert!(page.contains("<span class=\"inset-drop\">立</span>约人以血为誓。"));
            assert!(prepared.image_bytes(&paper).is_some());
            assert!(prepared.image_bytes(&rod).is_some());
            // 书信格线。
            assert!(page.contains("<div class=\"letter-block letter-ruled\">"));
            let css = &prepared.manifest().stylesheet.css;
            assert!(css.contains(&format!(
                ".inset-scroll .inset-inner {{ padding: 0.4em 0.9em; background-image: url(\"{}\"); }}",
                paper
            )));
            assert!(css.contains("\"STKai\", \"楷体\""));
            assert_eq!(restore(&page), text, "{look}");
            let value = serde_json::to_value(prepared.manifest()).unwrap();
            assert_eq!(value["chat_block_style"], look);
            assert_eq!(value["letter_block_style"], "ruled");
            assert!(value.get("inset_font").is_none(), "默认楷体不写入");
            // 通用与 Bokai 输入 EPUB 都能写出（含程序生成的图片资源）；Kindling 输入需要封面，由 Flutter 端真实转换覆盖。
            for (name, result) in [
                (
                    "epub",
                    crate::epub::write(&prepared, std::io::Cursor::new(Vec::new())).map(|_| ()),
                ),
                (
                    "bokai",
                    crate::epub::write_bokai_input(&prepared, std::io::Cursor::new(Vec::new()))
                        .map(|_| ()),
                ),
            ] {
                if let Err(e) = result {
                    panic!("{look} {name}: {e:?}");
                }
            }
        }
        // V82a：本书改过的样式——古籍换〖〗饰纹并首字放大，羊皮纸去掉卷轴杆与纸纹、改浅灰底。
        let mut req = request(&source);
        req.settings.chat_block_style = "window".into();
        req.settings.block_annotations = serde_json::from_value(annotations.clone()).unwrap();
        let mut styles = std::collections::BTreeMap::new();
        let mut classic = crate::inset_styles::default_for("edict", "off");
        classic.ornament = "lenticular".into();
        classic.drop = true;
        classic.names = "inline".into();
        styles.insert("edict".to_owned(), classic);
        let mut scroll = crate::inset_styles::default_for("scroll", "off");
        scroll.rods = false;
        scroll.shade = "light".into();
        styles.insert("scroll".to_owned(), scroll);
        let mut chat = crate::inset_styles::default_for("chat", "window");
        chat.names = "inline".into();
        styles.insert("chat".to_owned(), chat);
        req.settings.inset_styles = Some(styles);
        let prepared = publication_resources::prepare(&source, req).unwrap();
        let page = prepared.documents().unwrap().pages["body.xhtml"].clone();
        assert!(page.contains("<span class=\"inset-orn\">〖</span> 奉天承运 皇帝诏曰 <span class=\"inset-orn\">〗</span>"));
        assert!(page.contains("<span class=\"inset-drop\">着</span>即晋封国公。"));
        assert!(!page.contains("inset-rod"), "去掉卷轴杆");
        assert!(prepared.manifest().inset_images.is_none(), "不再生成图片");
        assert!(page.contains("inset-names-inline"));
        assert!(page.contains("<span class=\"inset-who\">四</span> ▷ "));
        let css = &prepared.manifest().stylesheet.css;
        assert!(css.contains(
            ".inset-scroll .inset-inner { padding: 0.4em 0.9em; background-color: #ececec; }"
        ));
        assert!(!css.contains("background-image"));
        assert_eq!(restore(&page), text);
        let value = serde_json::to_value(prepared.manifest()).unwrap();
        assert_eq!(value["inset_styles"]["scroll"]["shade"], "light");
        // 非法参数被拒绝。
        let mut req = request(&source);
        let mut bad = crate::inset_styles::default_for("news", "off");
        bad.border = "wavy".into();
        req.settings.inset_styles = Some([("news".to_owned(), bad)].into());
        assert!(publication_resources::prepare(&source, req).is_err());
        // 旧书（默认值、无场景标注）：成品参数与样式表不含场景样式。
        let mut req = request(&source);
        req.settings.system_block_style = "styled".into();
        let prepared = publication_resources::prepare(&source, req).unwrap();
        let page = prepared.documents().unwrap().pages["body.xhtml"].clone();
        assert!(!page.contains("inset"));
        assert!(
            page.contains("blk blk-panel"),
            "不识别聊天时【】行仍是系统提示"
        );
        assert!(!prepared.manifest().stylesheet.css.contains("inset"));
        let value = serde_json::to_value(prepared.manifest()).unwrap();
        for key in [
            "chat_block_style",
            "letter_block_style",
            "inset_font",
            "inset_images",
        ] {
            assert!(value.get(key).is_none(), "{key}");
        }
        assert_eq!(restore(&page), text);
        // 场景标注必须带合法场景；其他类不带。
        for bad in [
            json!({"kind":"inset"}),
            json!({"kind":"inset","variant":"panel"}),
            json!({"kind":"letter","variant":"chat"}),
        ] {
            let mut a = mark("正文。\n", "x", None);
            for (k, v) in bad.as_object().unwrap() {
                a[k] = v.clone();
            }
            let list: Vec<crate::block_annotations::Annotation> =
                serde_json::from_value(json!([a])).unwrap();
            assert!(crate::block_annotations::validate(&list).is_err(), "{bad}");
        }
        // 非法设置值被拒绝。
        let mut req = request(&source);
        req.settings.chat_block_style = "bubble".into();
        assert!(publication_resources::prepare(&source, req).is_err());
    }

    #[test]
    fn inset_rules_detect_adjacent_blocks_and_stay_off_for_old_books() {
        let text = "第一章 开始\n正文。\n奉天承运 皇帝诏曰\n着即晋封国公。\n钦此\n圣旨\n赏银百两。\n钦此\n1楼 楼主\n有人吗？\n2楼 路过\n元婴渡劫。\n结尾。\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let mut req = request(&source);
        req.settings.inset_detect = "on".into();
        let prepared = publication_resources::prepare(&source, req).unwrap();
        let page = prepared.documents().unwrap().pages["body.xhtml"].clone();
        assert_eq!(
            page.matches("<div class=\"inset inset-edict\">").count(),
            2,
            "两份诏书各成一块"
        );
        assert_eq!(page.matches("<div class=\"inset inset-forum\">").count(), 1);
        assert!(page.contains("inset-line inset-floor"));
        let css = &prepared.manifest().stylesheet.css;
        assert!(css.contains(".inset-edict {"));
        let body = roxmltree::Document::parse(&page).unwrap();
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
        assert_eq!(restored, text);
        assert_eq!(
            serde_json::to_value(prepared.manifest()).unwrap()["inset_detect"],
            "on"
        );
        // 旧书（不识别）：成品不变，参数不写入。
        let prepared = publication_resources::prepare(&source, request(&source)).unwrap();
        let page = prepared.documents().unwrap().pages["body.xhtml"].clone();
        assert!(!page.contains("inset"));
        assert!(
            serde_json::to_value(prepared.manifest())
                .unwrap()
                .get("inset_detect")
                .is_none()
        );
    }

    #[test]
    fn inset_manual_roles_override_and_are_validated() {
        use sha2::{Digest, Sha256};
        let text = "第一章 开始\n林小满 @xiaoman\n今天的江面。\n沈舟：拍得真好\n转发 12 评论 34 赞 560\n\n结尾。\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let piece = "林小满 @xiaoman\n今天的江面。\n沈舟：拍得真好\n转发 12 评论 34 赞 560\n\n";
        let start = text.find(piece).unwrap();
        let mark = |roles: serde_json::Value| {
            json!([{"id": format!("{:x}", Sha256::digest(piece.as_bytes())), "start": start, "end": start + piece.len(),
                    "kind": "inset", "variant": "post", "roles": roles,
                    "fingerprint": format!("{:x}", Sha256::digest(piece.as_bytes()))}])
        };
        // 自动：第三行“沈舟：……”在转评赞之前，不算回复；指定为回复，空行指定无效。
        let mut req = request(&source);
        req.settings.block_annotations =
            serde_json::from_value(mark(json!({"2": "reply", "4": "head"}))).unwrap();
        let prepared = publication_resources::prepare(&source, req).unwrap();
        let page = prepared.documents().unwrap().pages["body.xhtml"].clone();
        assert!(page.contains("inset-line inset-reply\" data-original=\"沈舟：拍得真好\""));
        assert!(page.contains("inset-line inset-count"));
        assert!(page.contains("inset-line inset-blank"), "空行保持空行");
        let mut req = request(&source);
        req.settings.block_annotations = serde_json::from_value(mark(json!({}))).unwrap();
        let page = publication_resources::prepare(&source, req)
            .unwrap()
            .documents()
            .unwrap()
            .pages["body.xhtml"]
            .clone();
        assert!(page.contains("inset-line inset-body\" data-original=\"沈舟：拍得真好\""));
        // 角色必须是该场景能用的；只有场景能带；行号上限。
        for roles in [json!({"0": "floor"}), json!({"300": "head"})] {
            let list: Vec<crate::block_annotations::Annotation> =
                serde_json::from_value(mark(roles.clone())).unwrap();
            assert!(
                crate::block_annotations::validate(&list).is_err(),
                "{roles}"
            );
        }
        let mut letter = mark(json!({"0": "head"}));
        letter[0]["kind"] = json!("letter");
        letter[0].as_object_mut().unwrap().remove("variant");
        let list: Vec<crate::block_annotations::Annotation> =
            serde_json::from_value(letter).unwrap();
        assert!(crate::block_annotations::validate(&list).is_err());
        // 列表带上各行文字与自动判断的角色。
        let list: Vec<crate::block_annotations::Annotation> =
            serde_json::from_value(mark(json!({}))).unwrap();
        let (book, _) = publication_resources::compose(&source, request(&source)).unwrap();
        let report = crate::block_annotations::report(&list, &book);
        let a = &report["annotations"][0];
        assert_eq!(a["lines"][0], "林小满 @xiaoman");
        assert_eq!(
            a["auto_roles"],
            json!(["head", "body", "body", "count", "blank"])
        );
    }

    #[test]
    fn system_custom_patterns_and_manual_variants() {
        use sha2::{Digest, Sha256};
        let text = "第一章 开始\n≮任务：清剿妖兽≯\n≮奖励：100灵币≯\n正文。\n【单行却要面板】\n正文二。\n【甲：一】\n【乙：二】\n结尾。\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let mark = |piece: &str, variant: &str| {
            let start = text.find(piece).unwrap();
            let end = start + piece.len();
            json!({"id": format!("{:x}", Sha256::digest(piece.as_bytes())), "start": start, "end": end,
                   "kind": "system", "variant": variant,
                   "fingerprint": format!("{:x}", Sha256::digest(&text.as_bytes()[start..end]))})
        };
        let mut req = request(&source);
        req.settings.system_block_style = "styled".into();
        req.settings.rule_options.system_patterns = vec!["≮.+≯".into()];
        req.settings.block_annotations = serde_json::from_value(json!([
            mark("【单行却要面板】\n", "panel"),
            mark("【甲：一】\n【乙：二】\n", "note"),
        ]))
        .unwrap();
        let prepared = publication_resources::prepare(&source, req).unwrap();
        let page = prepared.documents().unwrap().pages["body.xhtml"].clone();
        // 自定义规则：两行 ≮≯ 合成面板。
        assert!(page.contains("<div class=\"blk blk-panel\"><p class=\"text-line system-line\""));
        assert!(page.contains("≮任务：清剿妖兽≯"));
        // 手工指定：单行也成面板（有标题），两行也按单行提示。
        assert!(page.contains("<div class=\"blk blk-panel blk-has-title\"><p class=\"text-line system-line blk-panel-title\""));
        assert!(page.contains(">单行却要面板</p>"));
        assert!(page.contains("<div class=\"blk blk-note\"><p class=\"text-line system-line\""));
        assert!(page.contains(">【甲：一】</p>"), "单行提示保留括号");
        assert_eq!(page.matches("class=\"blk ").count(), 3);
        // 没有自定义规则时 ≮≯ 是普通正文。
        let mut req = request(&source);
        req.settings.system_block_style = "styled".into();
        let page = publication_resources::prepare(&source, req)
            .unwrap()
            .documents()
            .unwrap()
            .pages["body.xhtml"]
            .clone();
        assert!(!page.contains("blk") || !page.contains("≮任务：清剿妖兽≯</p></div>"));
        assert!(page.contains("class=\"text-line\" data-source=\"true\" data-eol=\"lf\">≮任务"));
        // 规则校验：非法正则、空规则、手工标注的非法样式。
        let mut options = crate::rule_options::Options {
            system_patterns: vec!["(".into()],
            ..Default::default()
        };
        assert!(options.validate().is_err());
        options.system_patterns = vec![" ".into()];
        assert!(options.validate().is_err());
        options.system_patterns = vec!["≮.+≯".into()];
        options.validate().unwrap();
        let bad: Vec<crate::block_annotations::Annotation> =
            serde_json::from_value(json!([{"id":"1","start":0,"end":1,"kind":"letter","fingerprint":"x","variant":"panel"}])).unwrap();
        assert!(crate::block_annotations::validate(&bad).is_err());
    }

    #[test]
    fn chapter_style_pack_heads_rules_ends_and_volume_frame() {
        let dir = std::env::temp_dir().join(format!(
            "easypub-v74-render-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let built: serde_json::Value = serde_json::from_str(
            &crate::style_packs::run(
                json!({"action":"builtin","id":"classic","dir":dir.to_str().unwrap()}),
            )
            .unwrap(),
        )
        .unwrap();
        let text = "第一章 远行\n正文甲。\n第二章 归来\n正文乙。\n第三章 雾港\n正文丙。\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let mut req = request(&source);
        req.settings.chapter_style = serde_json::from_value(built["style"].clone()).unwrap();
        let prepared = publication_resources::prepare(&source, req).unwrap();
        let ids = prepared.manifest().chapter_style.clone().unwrap();
        assert_eq!(ids.head_ids.len(), 2);
        let page = prepared.documents().unwrap().pages["body.xhtml"].clone();
        // 章头图按章轮换：甲、乙、甲。
        let heads: Vec<_> = page
            .match_indices("<figure class=\"chapter-head-image chapter-head-half\"><img src=\"")
            .map(|(i, m)| &page[i + m.len()..i + m.len() + 64])
            .collect();
        assert_eq!(heads.len(), 3);
        assert_eq!(heads[0], &ids.head_ids[0][..64]);
        assert_eq!(heads[1], &ids.head_ids[1][..64]);
        assert_eq!(heads[2], &ids.head_ids[0][..64]);
        // 标题下装饰线紧跟每章标题；章末装饰在每章正文之后。
        assert_eq!(page.matches("<p class=\"title-rule\">").count(), 3);
        assert!(page.contains("第一章 远行</h1><p class=\"title-rule\">"));
        assert_eq!(page.matches("<p class=\"chapter-end\">").count(), 3);
        assert!(page.contains("正文甲。</p><p class=\"chapter-end\">"));
        assert!(page.contains("正文丙。</p><p class=\"chapter-end\">"));
        let css = &prepared.manifest().stylesheet.css;
        assert!(css.contains(".volume-heading { border: 3px double;"));
        assert!(css.contains(".title-rule img { width: 40%;"));
        roxmltree::Document::parse(&page).unwrap();
        // 已设的章首图优先。
        let mut req = request(&source);
        req.settings.chapter_style = serde_json::from_value(built["style"].clone()).unwrap();
        let own = req
            .settings
            .chapter_style
            .as_ref()
            .unwrap()
            .title_rule
            .clone();
        req.settings.chapter_head_image = own;
        let prepared = publication_resources::prepare(&source, req).unwrap();
        let first = prepared.manifest().chapter_head_image_id.clone().unwrap();
        let page = prepared.documents().unwrap().pages["body.xhtml"].clone();
        assert_eq!(
            page.matches(&format!("chapter-head-half\"><img src=\"{first}\""))
                .count(),
            3
        );
        // 不用样式包：成品参数里没有这一项。
        let prepared = publication_resources::prepare(&source, request(&source)).unwrap();
        let value = serde_json::to_value(prepared.manifest()).unwrap();
        assert!(value.get("chapter_style").is_none());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn rare_char_ruby_modes_scope_and_lossless() {
        let text = "第一章 龘山\n城外有座龘山，叫喆。\n他望着龘山，表情囧。\n｜龘《lóng》字已有注音。\n第二章 归来\n再回到龘山。\n這裏很靜。\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let ruby =
            |c: &str, py: &str| format!("<ruby>{c}<rp>（</rp><rt>{py}</rt><rp>）</rp></ruby>");
        let dragon = ruby("龘", "dá");
        for (mode, scope, count) in [
            ("off", "outside", 0),
            ("chapter", "outside", 2),
            ("book", "outside", 1),
            ("every", "outside", 3),
            ("chapter", "level3", 2),
        ] {
            let mut req = request(&source);
            req.settings.rare_char_ruby = mode.into();
            req.settings.rare_char_scope = scope.into();
            let prepared = publication_resources::prepare(&source, req).unwrap();
            let page = prepared.documents().unwrap().pages["body.xhtml"].clone();
            assert_eq!(page.matches(&dragon).count(), count, "{mode} {scope}");
            // 标题不标；已有注音不重复标；繁体字按简体判断不标。
            assert!(!page.contains(&format!("第一章 {dragon}")), "{mode}");
            assert!(page.contains(&ruby("龘", "lóng")), "{mode}");
            assert!(!page.contains("<rt>zhè</rt>") && !page.contains("<rt>lǐ</rt>"));
            assert_eq!(page.contains(&ruby("囧", "jiǒng")), mode != "off", "{mode}");
            // 三级字“喆”只在 level3 时标。
            assert_eq!(
                page.contains(&ruby("喆", "zhé")),
                mode != "off" && scope == "level3",
                "{mode} {scope}"
            );
            let body = roxmltree::Document::parse(&page).unwrap();
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
            assert!(
                restored.contains("城外有座龘山，叫喆。\n他望着龘山，表情囧。\n"),
                "{mode}"
            );
        }
        // 关闭时不写入成品参数，旧书输出不变。
        let mut req = request(&source);
        req.settings.rare_char_ruby = "off".into();
        let off = serde_json::to_value(
            publication_resources::prepare(&source, req)
                .unwrap()
                .manifest(),
        )
        .unwrap();
        assert!(off.get("rare_char_ruby").is_none() && off.get("rare_char_scope").is_none());
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
            "独在异乡为异客，每逢佳节倍思亲。",
            "白发三千丈，缘愁似个长。",
            "春眠不觉晓，处处闻啼鸟。",
        ] {
            assert!(verse(yes), "{yes}");
        }
        // V92：Kindle 上被误当诗句居中的网文句子（7+7 白话）。
        for no in [
            "这份潜在的商机，是我不能忽视的！",
            "察觉到我的迟疑，倪妮并没有勉强。",
            "我心里咯噔一下，这可真是个难题。",
            "她笑着摇摇头，没有再说什么。",
        ] {
            assert!(!verse(no), "{no}");
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
