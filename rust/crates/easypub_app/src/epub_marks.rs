//! 导入 EPUB 时顺着正文读行内样式、脚注链接和表格（G-113）。
//!
//! 只认简单的 CSS 选择器（标签、类、标签.类），算出的结果按工作稿行号记下来，
//! 不写进工作稿文字。写进哪里、怎么用见 `source_marks`。
use crate::inline_styles::Style;
use crate::source_marks::{Cell, Data, Mark, MarkKind, Table, mark_id};
use roxmltree::Node;
use std::collections::{HashMap, HashSet};

/// 一条样式规则的效果：加上还是取消某种样式。
type Effects = Vec<(Style, bool)>;

/// 未标注语义的旧目录：去掉标题后，至少两条内部链接且占正文文字八成。
/// 有明确脚注语义的页面不做这个推断。
pub(crate) fn link_directory(root: Node<'_, '_>) -> bool {
    if root.descendants().any(|n| {
        has_type(n, &["noteref", "footnote", "endnote", "rearnote"])
            || has_class(n, "footnote")
            || has_class(n, "endnote")
    }) {
        return false;
    }
    let mut total = 0;
    let mut linked = 0;
    let mut links = HashSet::new();
    for node in root.descendants().filter(|n| n.is_text()) {
        if node.ancestors().any(|n| {
            matches!(
                n.tag_name().name(),
                "h1" | "h2" | "h3" | "h4" | "h5" | "h6" | "script" | "style"
            )
        }) {
            continue;
        }
        let count = node
            .text()
            .unwrap_or("")
            .chars()
            .filter(|c| !c.is_whitespace())
            .count();
        total += count;
        if let Some(anchor) = node
            .ancestors()
            .find(|n| n.has_tag_name("a") && n.attribute("href").is_some_and(|h| !h.contains(':')))
        {
            linked += count;
            links.insert(anchor.id());
        }
    }
    links.len() >= 2 && total > 0 && linked * 5 >= total * 4
}

fn declarations(body: &str) -> Effects {
    let mut effects = Vec::new();
    for declaration in body.split(';') {
        let Some((name, value)) = declaration.split_once(':') else {
            continue;
        };
        let name = name.trim().to_ascii_lowercase();
        let value = value.replace("!important", "").trim().to_ascii_lowercase();
        match name.as_str() {
            "font-weight" => effects.push((
                Style::Bold,
                value.contains("bold") || value.parse::<u32>().is_ok_and(|w| w >= 600),
            )),
            "font-style" => effects.push((
                Style::Italic,
                value.contains("italic") || value.contains("oblique"),
            )),
            "text-decoration" | "text-decoration-line" => {
                effects.push((Style::Underline, value.contains("underline")));
            }
            "text-emphasis"
            | "text-emphasis-style"
            | "-webkit-text-emphasis"
            | "-webkit-text-emphasis-style"
            | "-epub-text-emphasis"
            | "-epub-text-emphasis-style" => {
                effects.push((Style::EmDot, value != "none"));
            }
            "vertical-align" => {
                effects.push((Style::Sup, value == "super"));
                effects.push((Style::Sub, value == "sub"));
            }
            _ => {}
        }
    }
    effects
}

fn strip_comments(css: &str) -> String {
    let mut out = String::with_capacity(css.len());
    let mut rest = css;
    while let Some(at) = rest.find("/*") {
        out.push_str(&rest[..at]);
        match rest[at + 2..].find("*/") {
            Some(end) => rest = &rest[at + 2 + end + 2..],
            None => return out,
        }
    }
    out.push_str(rest);
    out
}

fn simple_selector(value: &str) -> bool {
    let (tag, class) = value.split_once('.').unwrap_or((value, ""));
    let word = |s: &str| {
        s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    };
    word(tag) && word(class) && (!tag.is_empty() || !class.is_empty())
}

/// 只收“标签”“.类”“标签.类”，@media 之类的整块跳过，后写的规则排在后面。
#[derive(Clone, Default)]
pub(crate) struct Rules(HashMap<String, Effects>);
impl Rules {
    pub(crate) fn add(&mut self, css: &str) {
        let css = strip_comments(css);
        let mut rest = css.as_str();
        while let Some(open) = rest.find('{') {
            let selectors = rest[..open].trim();
            let mut depth = 1usize;
            let mut close = None;
            for (at, c) in rest[open + 1..].char_indices() {
                match c {
                    '{' => depth += 1,
                    '}' => {
                        depth -= 1;
                        if depth == 0 {
                            close = Some(open + 1 + at);
                            break;
                        }
                    }
                    _ => {}
                }
            }
            let Some(close) = close else { return };
            if !selectors.starts_with('@') {
                let effects = declarations(&rest[open + 1..close]);
                if !effects.is_empty() {
                    for selector in selectors.split(',') {
                        let selector = selector.trim().to_ascii_lowercase();
                        if simple_selector(&selector) {
                            self.0.entry(selector).or_default().extend(effects.clone());
                        }
                    }
                }
            }
            rest = &rest[close + 1..];
        }
    }
    fn styles(&self, node: Node<'_, '_>) -> Vec<Style> {
        let tag = node.tag_name().name().to_ascii_lowercase();
        let mut styles: Vec<Style> = match tag.as_str() {
            "b" | "strong" => vec![Style::Bold],
            "i" | "em" | "cite" | "dfn" | "var" => vec![Style::Italic],
            "u" | "ins" => vec![Style::Underline],
            "sup" => vec![Style::Sup],
            "sub" => vec![Style::Sub],
            _ => Vec::new(),
        };
        let mut apply = |effects: &Effects| {
            for &(style, on) in effects {
                styles.retain(|s| *s != style);
                if on {
                    styles.push(style);
                }
            }
        };
        if let Some(effects) = self.0.get(&tag) {
            apply(effects);
        }
        let classes: Vec<String> = node
            .attribute("class")
            .unwrap_or("")
            .split_whitespace()
            .map(str::to_ascii_lowercase)
            .collect();
        for class in &classes {
            if let Some(effects) = self.0.get(&format!(".{class}")) {
                apply(effects);
            }
        }
        for class in &classes {
            if let Some(effects) = self.0.get(&format!("{tag}.{class}")) {
                apply(effects);
            }
        }
        if let Some(style) = node.attribute("style") {
            apply(&declarations(style));
        }
        styles
    }
}

#[derive(Clone, PartialEq)]
enum Open {
    Style(Style),
    Url(String),
    Jump { href: String, noteref: bool },
}
struct Run {
    line: usize,
    text: String,
    nth: u32,
    kind: Open,
}

fn has_type(node: Node<'_, '_>, values: &[&str]) -> bool {
    node.attributes().any(|a| {
        matches!(a.name(), "type" | "role")
            && a.value()
                .split_whitespace()
                .any(|v| values.contains(&v.trim_start_matches("doc-")))
    })
}
fn has_class(node: Node<'_, '_>, part: &str) -> bool {
    node.attribute("class")
        .is_some_and(|c| c.to_ascii_lowercase().contains(part))
}

/// 一个 XHTML 文档的收集结果。行号是文档内的序号，`Gather` 再加上文档偏移。
pub(crate) struct Collector {
    pub(crate) navigation: bool,
    rules: Rules,
    active: Vec<(Open, usize)>,
    spans: Vec<(Open, usize, usize)>,
    heading: usize,
    pending: Vec<String>,
    ids: Vec<(String, usize)>,
    targets: Vec<String>,
    runs: Vec<Run>,
    tables: Vec<(usize, Table)>,
}
impl Collector {
    pub(crate) fn new(rules: Rules) -> Self {
        Self {
            navigation: false,
            rules,
            active: Vec::new(),
            spans: Vec::new(),
            heading: 0,
            pending: Vec::new(),
            ids: Vec::new(),
            targets: Vec::new(),
            runs: Vec::new(),
            tables: Vec::new(),
        }
    }
    pub(crate) fn enter_heading(&mut self) {
        self.heading += 1;
    }
    pub(crate) fn leave_heading(&mut self) {
        self.heading -= 1;
    }
    /// 进入元素：记下位置标识，打开样式。返回打开了几种，离开时原样传回 `close`。
    pub(crate) fn open(&mut self, node: Node<'_, '_>, at: usize) -> usize {
        let id = node.attribute("id").or_else(|| {
            node.has_tag_name("a")
                .then(|| node.attribute("name"))
                .flatten()
        });
        if let Some(id) = id {
            self.pending.push(id.to_owned());
            if has_type(node, &["footnote", "endnote", "rearnote"])
                || has_class(node, "footnote")
                || has_class(node, "endnote")
            {
                self.targets.push(id.to_owned());
            }
        }
        let mut kinds: Vec<Open> = self
            .rules
            .styles(node)
            .into_iter()
            .map(Open::Style)
            .collect();
        if node.has_tag_name("a")
            && let Some(href) = node
                .attribute("href")
                .or_else(|| node.attribute(("http://www.w3.org/1999/xlink", "href")))
        {
            let lower = href.to_ascii_lowercase();
            if lower.starts_with("http://")
                || lower.starts_with("https://")
                || lower.starts_with("mailto:")
            {
                kinds.push(Open::Url(href.trim().to_owned()));
            } else if !self.navigation
                && !node.ancestors().any(|n| {
                    has_type(n, &["toc", "landmarks", "page-list"])
                        || n.attribute("role")
                            .is_some_and(|r| r.split_whitespace().any(|v| v == "doc-toc"))
                })
            {
                kinds.push(Open::Jump {
                    href: href.to_owned(),
                    noteref: has_type(node, &["noteref"])
                        || has_class(node, "noteref")
                        || has_class(node, "footnote"),
                });
            }
        }
        let mut opened = 0;
        for kind in kinds {
            if !self.active.iter().any(|(k, _)| *k == kind) {
                self.active.push((kind, at));
                opened += 1;
            }
        }
        opened
    }
    pub(crate) fn close(&mut self, opened: usize, at: usize) {
        for _ in 0..opened {
            if let Some((kind, start)) = self.active.pop()
                && start < at
            {
                self.spans.push((kind, start, at));
            }
        }
    }
    /// 一行结束：把文字里的位置换算到归一后的行，跨行的样式在下一行接着算。
    pub(crate) fn flush(&mut self, raw: &str, line: Option<(usize, &str)>) {
        for (kind, start) in &mut self.active {
            if *start < raw.len() {
                self.spans.push((kind.clone(), *start, raw.len()));
            }
            *start = 0;
        }
        let spans = std::mem::take(&mut self.spans);
        let Some((index, line)) = line else { return };
        for id in self.pending.drain(..) {
            self.ids.push((id, index));
        }
        if self.heading > 0 || spans.is_empty() {
            return;
        }
        let words = word_map(raw);
        for (kind, start, end) in spans {
            let Some((from, to)) = normalized_range(&words, start, end) else {
                continue;
            };
            if matches!(kind, Open::Style(Style::Bold)) && from == 0 && to == line.len() {
                continue;
            }
            let text = line[from..to].to_owned();
            let nth = line[..from].match_indices(&text).count() as u32;
            self.runs.push(Run {
                line: index,
                text,
                nth,
                kind,
            });
        }
    }
    pub(crate) fn table(&mut self, index: usize, table: Table) {
        self.tables.push((index, table));
    }
}

/// 原文每个词的范围和它在归一行里的起点。
fn word_map(raw: &str) -> Vec<(usize, usize, usize)> {
    let base = raw.as_ptr() as usize;
    let mut position = 0;
    raw.split_whitespace()
        .map(|word| {
            let start = word.as_ptr() as usize - base;
            let row = (start, start + word.len(), position);
            position += word.len() + 1;
            row
        })
        .collect()
}
fn normalized_range(
    words: &[(usize, usize, usize)],
    start: usize,
    end: usize,
) -> Option<(usize, usize)> {
    let first = words.iter().find(|w| w.1 > start)?;
    let last = words.iter().rev().find(|w| w.0 < end)?;
    let from = first.2 + start.saturating_sub(first.0);
    let to = last.2 + end.min(last.1) - last.0;
    (from < to).then_some((from, to))
}

/// 表格能不能读成规整的文字：一列、嵌套表格、带图的都是版式用途，按普通文字走。
pub(crate) fn plain_table(node: Node<'_, '_>) -> Option<Table> {
    if node
        .descendants()
        .skip(1)
        .any(|n| n.has_tag_name("table") || n.has_tag_name("img") || n.has_tag_name("image"))
    {
        return None;
    }
    let span = |n: Node<'_, '_>, name: &str| {
        n.attribute(name)
            .and_then(|v| v.trim().parse::<u32>().ok())
            .unwrap_or(1)
            .clamp(1, 1000)
    };
    let text = |n: Node<'_, '_>| {
        n.descendants()
            .filter(|c| c.is_text())
            .map(|c| c.text().unwrap_or(""))
            .collect::<String>()
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
    };
    let mut rows = Vec::new();
    for row in node.descendants().filter(|n| n.has_tag_name("tr")) {
        let cells: Vec<Cell> = row
            .children()
            .filter(|n| n.has_tag_name("td") || n.has_tag_name("th"))
            .map(|n| Cell {
                text: text(n),
                head: n.has_tag_name("th"),
                columns: span(n, "colspan"),
                rows: span(n, "rowspan"),
            })
            .collect();
        if !cells.is_empty() {
            rows.push(cells);
        }
    }
    let columns = rows
        .iter()
        .map(|r| r.iter().map(|c| c.columns as usize).sum::<usize>())
        .max()?;
    // 一列的多半是用表格排版的正文，收走了就搜不到、清理不到。
    if columns < 2 || rows.iter().flatten().all(|c| c.text.is_empty()) {
        return None;
    }
    Some(Table {
        id: String::new(),
        line: 0,
        columns: columns as u32,
        caption: node
            .children()
            .find(|n| n.has_tag_name("caption"))
            .map(text)
            .unwrap_or_default(),
        rows,
    })
}

struct Jump {
    document: String,
    line: u32,
    text: String,
    nth: u32,
    href: String,
    noteref: bool,
}
/// 全书汇总：跳转链接要等所有文档读完才知道目标在哪一行。
#[derive(Default)]
pub(crate) struct Gather {
    data: Data,
    ids: HashMap<(String, String), u32>,
    targets: HashSet<(String, String)>,
    jumps: Vec<Jump>,
}
impl Gather {
    /// `offset`：这个文档之前的总行数。行号和图片位置一样从 1 开始。
    pub(crate) fn add(&mut self, document: &str, collector: Collector, offset: usize) {
        let line_of = |index: usize| (offset + index + 1) as u32;
        for (id, index) in collector.ids {
            self.ids
                .entry((document.to_owned(), id))
                .or_insert(line_of(index));
        }
        for id in collector.targets {
            self.targets.insert((document.to_owned(), id));
        }
        for run in collector.runs {
            let line = line_of(run.line);
            let kind = match run.kind {
                Open::Style(style) => MarkKind::Style { style },
                Open::Url(href) => MarkKind::Link { href },
                Open::Jump { href, noteref } => {
                    self.jumps.push(Jump {
                        document: document.to_owned(),
                        line,
                        text: run.text,
                        nth: run.nth,
                        href,
                        noteref,
                    });
                    continue;
                }
            };
            self.data.marks.push(Mark {
                id: mark_id(line, run.nth, &run.text, &kind),
                line,
                nth: run.nth,
                text: run.text,
                kind,
            });
        }
        for (index, mut table) in collector.tables {
            table.line = line_of(index);
            table.id = crate::source_marks::table_id(table.line);
            self.data.tables.push(table);
        }
    }
    pub(crate) fn finish(mut self) -> Data {
        let mut definitions = HashSet::new();
        let mut dropped = Vec::new();
        for jump in std::mem::take(&mut self.jumps) {
            let target = jump.href.split_once('#').and_then(|(file, fragment)| {
                let document = if file.is_empty() {
                    jump.document.clone()
                } else {
                    let base = jump.document.rsplit_once('/').map_or("", |v| v.0);
                    crate::epub_import::join_zip(base, file)?
                };
                Some((document, fragment.to_owned()))
            });
            let line = target.as_ref().and_then(|key| self.ids.get(key)).copied();
            let is_note = jump.noteref
                || target
                    .as_ref()
                    .is_some_and(|key| self.targets.contains(key));
            match line {
                Some(line) if is_note && line != jump.line => {
                    definitions.insert(line);
                    let kind = MarkKind::Note { target: line };
                    self.data.marks.push(Mark {
                        id: mark_id(jump.line, jump.nth, &jump.text, &kind),
                        line: jump.line,
                        nth: jump.nth,
                        text: jump.text,
                        kind,
                    });
                }
                _ => dropped.push(jump.line),
            }
        }
        // 注释正文里跳回原文的链接不算丢失。
        self.data.dropped_links = dropped
            .into_iter()
            .filter(|line| !definitions.contains(line))
            .count() as u32;
        self.data.marks.sort_by_key(|m| m.line);
        self.data
    }
}

/// 页面链接的样式表和页内 `<style>`，按书里的先后合起来。
pub(crate) fn page_rules(xml: &str, path: &str, sheets: &HashMap<String, String>) -> Rules {
    let mut rules = Rules::default();
    let xml = crate::epub_xml::named_entities(xml);
    let Ok(document) = crate::epub_xml::parse(&xml) else {
        return rules;
    };
    let base = path.rsplit_once('/').map_or("", |v| v.0);
    for node in document.descendants() {
        if node.has_tag_name("style") {
            let css: String = node
                .descendants()
                .filter(|c| c.is_text())
                .map(|c| c.text().unwrap_or(""))
                .collect();
            rules.add(&css.replace("<!--", "").replace("-->", ""));
        } else if node.has_tag_name("link")
            && node
                .attribute("rel")
                .is_some_and(|r| r.eq_ignore_ascii_case("stylesheet"))
            && let Some(sheet) = node
                .attribute("href")
                .and_then(|href| crate::epub_import::join_zip(base, href))
                .and_then(|file| sheets.get(&file))
        {
            rules.add(sheet);
        }
    }
    rules
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rules_read_simple_selectors_only() {
        let mut rules = Rules::default();
        rules.add(
            "/* b { font-weight: normal } */\n.hei, em.x { font-weight: 700 }\n\
             p > b { font-style: italic }\n@media print { .hei { font-weight: normal } }\n\
             b.plain { font-weight: normal }",
        );
        let xml = "<r><b/><b class=\"plain\"/><span class=\"hei\"/><p class=\"z\"/>\
                   <em class=\"x\" style=\"font-style: normal\"/></r>";
        let doc = roxmltree::Document::parse(xml).unwrap();
        let styles: Vec<_> = doc
            .root_element()
            .children()
            .map(|n| rules.styles(n))
            .collect();
        assert_eq!(styles[0], vec![Style::Bold]);
        assert!(styles[1].is_empty());
        assert_eq!(styles[2], vec![Style::Bold]);
        assert!(styles[3].is_empty());
        assert_eq!(styles[4], vec![Style::Bold]);
    }

    #[test]
    fn link_only_pages_are_directories_but_prose_and_notes_are_not() {
        for (xml, expected) in [
            (
                "<body><h1>目录</h1><p><a href='a#x'>1</a></p><p><a href='b#y'>2</a></p></body>",
                true,
            ),
            (
                "<body><p>这是正文，不应当忽略其中的跳转链接。<a href='a#x'>1</a><a href='b#y'>2</a></p></body>",
                false,
            ),
            (
                "<body><p class='footnote'><a href='#a'>1</a><a href='#b'>2</a></p></body>",
                false,
            ),
        ] {
            let doc = roxmltree::Document::parse(xml).unwrap();
            assert_eq!(link_directory(doc.root_element()), expected);
        }
    }

    #[test]
    fn whitespace_is_mapped_to_the_normalized_line() {
        let raw = "  甲 \n  乙丙  丁 ";
        let words = word_map(raw);
        let at = raw.find("乙").unwrap();
        let end = raw.find("丁").unwrap() + "丁".len();
        assert_eq!(
            normalized_range(&words, at, end),
            Some(("甲 ".len(), "甲 乙丙 丁".len()))
        );
        assert_eq!(normalized_range(&words, 0, 2), None);
    }
}
