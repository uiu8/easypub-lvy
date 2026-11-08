//! 同章唯一配对的注释；只标记成品，不移动、删除或改写来源文字。
use crate::{inline_markup, navigation_documents::escaped};
use easypub_core::{ApiError, publication::EffectiveBook, structure::Role};
use regex::Regex;
use std::{collections::BTreeMap, sync::LazyLock};

static MARKER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[①-⑳]|\[(?:注)?[0-9]+\]|［(?:注)?[0-9]+］|〔[0-9]+〕").unwrap());
static DEFINITION: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"^(?:注\s*)?(?:[①-⑳]|\[(?:注)?[0-9]+\]|［(?:注)?[0-9]+］|〔[0-9]+〕)|^注[0-9]+\s*[:：]",
    )
    .unwrap()
});

/// 仅匹配本模块生成的注释外壳，保留其中的来源属性、标记和双向链接。
/// Bokai 把 aside 编为 sidebar ($280)，Calibre 不支持；div 仍会保留
/// footnote 分类、footer 位置和 noteref 的 yj.note，与官方 KFX 的写法一致。
/// Bokai 还会在展平 sup > a 时丢掉外层上移，把引用样式放在实际链接上。
pub(crate) fn bokai_input(page: &str) -> std::borrow::Cow<'_, str> {
    static NOTE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"(?s)<aside( epub:type="footnote" id="note-[0-9]+"(?: class="footnote")?>.*?)</aside>"#).unwrap()
    });
    static REFERENCE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"(?s)<sup class="note-ref"><a( epub:type="noteref"[^>]*)>(.*?)</a></sup>"#)
            .unwrap()
    });
    let notes = NOTE.replace_all(page, "<div$1</div>");
    match REFERENCE.replace_all(&notes, "<a class=\"note-ref\"$1>$2</a>") {
        std::borrow::Cow::Owned(page) => std::borrow::Cow::Owned(page),
        std::borrow::Cow::Borrowed(_) => notes,
    }
}

fn number(marker: &str) -> Option<u32> {
    if let Some(c) = marker.chars().find(|c| ('①'..='⑳').contains(c)) {
        return Some(c as u32 - '①' as u32 + 1);
    }
    let digits: String = marker.chars().filter(char::is_ascii_digit).collect();
    digits.parse().ok().filter(|n| *n > 0)
}

struct Occurrence {
    line: usize,
    from: usize,
    marker: String,
}
#[derive(Default)]
struct Candidates {
    references: Vec<Occurrence>,
    definitions: Vec<Occurrence>,
}
struct Link {
    id: usize,
    from: usize,
    to: usize,
    label: Option<String>,
    definition: bool,
    automatic: bool,
}
struct GeneratedNote {
    id: usize,
    number: u32,
    text: String,
}
#[derive(Default)]
pub(crate) struct Notes {
    lines: BTreeMap<usize, Vec<Link>>,
    generated: BTreeMap<usize, Vec<GeneratedNote>>,
    automatic: Vec<(Occurrence, Occurrence)>,
}
impl Notes {
    pub(crate) fn with_manual(
        book: &EffectiveBook,
        manual: &[crate::manual_notes::Note],
        automatic: bool,
    ) -> Self {
        Self::with_options(book, manual, automatic, &Default::default())
    }
    pub(crate) fn with_options(
        book: &EffectiveBook,
        manual: &[crate::manual_notes::Note],
        automatic: bool,
        options: &crate::rule_options::Options,
    ) -> Self {
        use crate::manual_notes::{Body, invalid_reason};
        let mut result = Self::default();
        let mut reserved = BTreeMap::<usize, Vec<(usize, usize)>>::new();
        let mut definitions = std::collections::BTreeSet::new();
        let mut ordered: Vec<_> = manual
            .iter()
            .filter(|n| invalid_reason(n, book).is_none())
            .collect();
        ordered.sort_by_key(|n| (n.reference.start, n.reference.from));
        let mut last_chapter = None;
        let mut ordinal = 0;
        for (i, n) in ordered.iter().enumerate() {
            let a = &n.reference;
            reserved.entry(a.start).or_default().push((a.from, a.to));
            let (id, label) = match &n.body {
                Body::Pair { definition: d } => {
                    definitions.insert(d.start);
                    let text = book.text[d.start..d.end].trim_end_matches(['\r', '\n']);
                    let from = text.len() - text.trim_start_matches([' ', '　', '\t']).len();
                    let marker = &book.text[a.start + a.from..a.start + a.to];
                    let (to, label) = if text[from..].starts_with(marker) {
                        (from + marker.len(), None)
                    } else {
                        (text.len(), Some(marker.to_owned()))
                    };
                    result.lines.entry(d.start).or_default().push(Link {
                        id: d.start,
                        from,
                        to,
                        label,
                        definition: true,
                        automatic: false,
                    });
                    (d.start, None)
                }
                Body::New { text } => {
                    let chapter = book
                        .tree
                        .nodes
                        .iter()
                        .rfind(|node| {
                            node.start <= a.start
                                && matches!(node.role, Role::Chapter | Role::Volume | Role::Front)
                        })
                        .map(|node| node.start);
                    if chapter != last_chapter {
                        ordinal = 0;
                        last_chapter = chapter;
                    }
                    ordinal += 1;
                    let id = book.text.len() + i + 1;
                    let chapter_end = book
                        .tree
                        .nodes
                        .iter()
                        .find(|node| {
                            node.start > a.start
                                && matches!(node.role, Role::Chapter | Role::Volume | Role::Front)
                        })
                        .map_or(book.text.len(), |node| node.start);
                    result
                        .generated
                        .entry(chapter_end)
                        .or_default()
                        .push(GeneratedNote {
                            id,
                            number: ordinal,
                            text: text.clone(),
                        });
                    (id, Some(ordinal.to_string()))
                }
            };
            result.lines.entry(a.start).or_default().push(Link {
                id,
                from: a.from,
                to: a.to,
                label,
                definition: false,
                automatic: false,
            });
        }
        if automatic {
            let mut candidates = BTreeMap::<u32, Candidates>::new();
            let mut headings = book.tree.nodes.iter().peekable();
            let mut offset = 0;
            while offset < book.text.len() {
                let rest = &book.text[offset..];
                let length = rest.find(['\r', '\n']).unwrap_or(rest.len());
                let line = &rest[..length];
                let tail = &rest[length..];
                let newline = if tail.starts_with("\r\n") {
                    2
                } else {
                    usize::from(!tail.is_empty())
                };
                let heading = headings.peek().filter(|n| n.start == offset).copied();
                if let Some(node) = heading {
                    if matches!(node.role, Role::Chapter | Role::Front | Role::Volume) {
                        result.finish(&mut candidates, options);
                    }
                    headings.next();
                }
                if heading.is_none_or(|node| node.role == Role::Body)
                    && !definitions.contains(&offset)
                {
                    let trimmed = line.trim_start();
                    let base = line.len() - trimmed.len();
                    let definition = DEFINITION.find(trimmed).filter(|m| {
                        !trimmed[m.end()..]
                            .trim_start_matches(|c: char| {
                                c.is_whitespace() || matches!(c, ':' | '：')
                            })
                            .is_empty()
                    });
                    if let Some(m) = definition {
                        if !reserved.contains_key(&offset) {
                            if let Some(n) = number(m.as_str()) {
                                candidates
                                    .entry(n)
                                    .or_default()
                                    .definitions
                                    .push(Occurrence {
                                        line: offset,
                                        from: base + m.start(),
                                        marker: m.as_str().to_owned(),
                                    });
                            }
                            for extra in MARKER.find_iter(&trimmed[m.end()..]) {
                                if let Some(n) = number(extra.as_str()) {
                                    candidates
                                        .entry(n)
                                        .or_default()
                                        .definitions
                                        .push(Occurrence {
                                            line: offset,
                                            from: 0,
                                            marker: String::new(),
                                        });
                                }
                            }
                        }
                    } else {
                        for m in MARKER.find_iter(line) {
                            let occupied = reserved.get(&offset).is_some_and(|ranges| {
                                ranges.iter().any(|&(a, b)| {
                                    a < m.end() && m.start() < b
                                        || a == b && m.start() < a && a < m.end()
                                })
                            });
                            if !occupied && let Some(n) = number(m.as_str()) {
                                candidates
                                    .entry(n)
                                    .or_default()
                                    .references
                                    .push(Occurrence {
                                        line: offset,
                                        from: m.start(),
                                        marker: m.as_str().to_owned(),
                                    });
                            }
                        }
                    }
                }
                offset += length + newline;
            }
            result.finish(&mut candidates, options);
        }
        for links in result.lines.values_mut() {
            links.sort_by_key(|l| (l.from, l.to));
        }
        result
    }
    fn finish(
        &mut self,
        candidates: &mut BTreeMap<u32, Candidates>,
        options: &crate::rule_options::Options,
    ) {
        for c in std::mem::take(candidates).into_values() {
            if c.references.len() != 1 || c.definitions.len() != 1 {
                continue;
            }
            let reference = c.references.into_iter().next().unwrap();
            let definition = c.definitions.into_iter().next().unwrap();
            if reference.line >= definition.line
                || definition.marker.is_empty()
                || !options.note(&reference.marker, &definition.marker)
            {
                continue;
            }
            for (o, is_definition) in [(&reference, false), (&definition, true)] {
                self.lines.entry(o.line).or_default().push(Link {
                    id: definition.line,
                    from: o.from,
                    to: o.from + o.marker.len(),
                    label: None,
                    definition: is_definition,
                    automatic: true,
                });
            }
            self.automatic.push((reference, definition));
        }
    }
    pub(crate) fn automatic_report(
        &self,
        book: &EffectiveBook,
        enabled: bool,
    ) -> Vec<serde_json::Value> {
        use serde_json::json;
        let locate = |o: &Occurrence| {
            let rest = &book.text[o.line..];
            let len = rest.find(['\r', '\n']).unwrap_or(rest.len());
            let eol = if rest[len..].starts_with("\r\n") {
                2
            } else {
                usize::from(len < rest.len())
            };
            let a = crate::manual_notes::Anchor {
                start: o.line,
                end: o.line + len + eol,
                from: o.from,
                to: o.from + o.marker.len(),
                fingerprint: String::new(),
            };
            crate::manual_notes::location(book, &a)
        };
        self.automatic.iter().map(|(r,d)| json!({"id":format!("auto-{}",d.line),"kind":"automatic","valid":true,"reason":null,"enabled":enabled,
            "location":locate(r),"definition_location":locate(d),"marker":r.marker,"definition_marker":d.marker,
            "reference_start":r.line,"reference_from":r.from,"reference_to":r.from+r.marker.len(),"definition_start":d.line,
            "text":book.text[d.line..].split(['\r','\n']).next().unwrap_or("")})).collect()
    }
    pub(crate) fn has_line(&self, line: usize) -> bool {
        self.lines.contains_key(&line)
    }
    pub(crate) fn preserve_indent(&self, line: usize, text: &str) -> bool {
        let prefix = text.len() - text.trim_start_matches([' ', '　', '\t']).len();
        self.lines
            .get(&line)
            .is_some_and(|ls| ls.iter().any(|l| l.from < prefix))
    }
    pub(crate) fn definition(&self, line: usize) -> Option<usize> {
        self.lines
            .get(&line)?
            .iter()
            .find(|link| link.definition)
            .map(|link| link.id)
    }
    pub(crate) fn render(
        &self,
        line: usize,
        original: &str,
        text: &str,
        digits: Option<u8>,
        styles: &[&crate::inline_styles::Annotation],
    ) -> Result<String, ApiError> {
        let Some(links) = self.lines.get(&line) else {
            return crate::inline_styles::render(text, 0, styles, digits);
        };
        let old_prefix = original.len() - original.trim_start_matches([' ', '　', '\t']).len();
        let new_prefix = text.len() - text.trim_start_matches([' ', '　', '\t']).len();
        let position = |at: usize| {
            if original == text {
                at
            } else {
                at - old_prefix + new_prefix
            }
        };
        let mut html = String::new();
        let mut cursor = 0;
        for link in links {
            let (from, to) = (position(link.from), position(link.to));
            html.push_str(&crate::inline_styles::render(
                &text[cursor..from],
                cursor,
                styles,
                digits,
            )?);
            let label = match &link.label {
                Some(label) => inline_markup::render(label, digits)?,
                None if link.automatic => escaped(&text[from..to])?,
                None => crate::inline_styles::render(&text[from..to], from, styles, digits)?,
            };
            html.push_str(&if link.definition {
                let mut backlink = format!(
                    "<a href=\"body.xhtml#noteref-{}\" class=\"note-backlink\">{label}</a>",
                    link.id
                );
                if link.label.is_some() {
                    backlink.push(' ');
                    backlink.push_str(&crate::inline_styles::render(&text[from..to], from, styles, digits)?);
                }
                backlink
            } else {
                format!("<sup class=\"note-ref\"><a epub:type=\"noteref\" href=\"body.xhtml#note-{}\" id=\"noteref-{}\">{label}</a></sup>", link.id, link.id)
            });
            cursor = to;
        }
        html.push_str(&crate::inline_styles::render(
            &text[cursor..],
            cursor,
            styles,
            digits,
        )?);
        Ok(html)
    }
    /// 新写注释集中放到本章末尾；已有来源注释行继续保留原顺序。
    pub(crate) fn chapter_end(&self, offset: usize) -> Result<String, ApiError> {
        let mut html = String::new();
        for note in self.generated.get(&offset).into_iter().flatten() {
            let id = note.id;
            html.push_str(&format!(
                "<aside epub:type=\"footnote\" id=\"note-{id}\" class=\"footnote\">"
            ));
            for (index, paragraph) in note
                .text
                .replace("\r\n", "\n")
                .replace('\r', "\n")
                .split('\n')
                .enumerate()
            {
                html.push_str("<p class=\"text-line\">");
                if index == 0 {
                    html.push_str(&format!(
                        "<a href=\"body.xhtml#noteref-{id}\" class=\"note-backlink\">{}.</a> ",
                        note.number
                    ));
                }
                html.push_str(&format!(
                    "{}</p>",
                    if paragraph.is_empty() {
                        "<br/>".into()
                    } else {
                        escaped(paragraph)?
                    }
                ));
            }
            html.push_str("</aside>");
        }
        Ok(html)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        publication_documents::Documents,
        publication_resources::{self, Request},
    };
    use easypub_core::source::{RULE_ID, SourceSnapshot};
    use serde_json::json;

    fn documents(text: &str, style: Option<&str>, vertical: bool) -> Documents {
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let mut request: Request = serde_json::from_value(json!({
            "source_id": source.summary().source_id, "revision": 1,
            "settings": {"title":"注释样书", "author":"作者", "description":"", "language":"zh-CN",
                "cover_fit":"contain", "font_family":"SimSun", "font_size":20,
                "fullwidth_indent":2, "line_height":1.8, "include_toc":true, "illustrations":[]}
        }))
        .unwrap();
        if let Some(style) = style {
            request.settings.note_style = style.into();
        }
        if vertical {
            request.settings.writing_mode = "vertical".into();
        }
        publication_resources::prepare(&source, request)
            .unwrap()
            .documents()
            .unwrap()
    }

    fn check_pairs(documents: &Documents) -> usize {
        let mut count = 0;
        for (name, page) in &documents.pages {
            let xml = roxmltree::Document::parse(page).unwrap();
            for link in xml.descendants().filter(|n| {
                n.attribute(("http://www.idpf.org/2007/ops", "type")) == Some("noteref")
            }) {
                let (file, id) = link.attribute("href").unwrap().split_once('#').unwrap();
                let target = roxmltree::Document::parse(&documents.pages[file]).unwrap();
                let note = target
                    .descendants()
                    .find(|n| n.attribute("id") == Some(id))
                    .unwrap();
                assert!(note.has_tag_name("aside"));
                assert_eq!(
                    note.attribute(("http://www.idpf.org/2007/ops", "type")),
                    Some("footnote")
                );
                let backlink = note.descendants().find(|n| n.has_tag_name("a")).unwrap();
                assert_eq!(
                    backlink.attribute("href").unwrap(),
                    format!("{name}#{}", link.attribute("id").unwrap())
                );
                count += 1;
            }
        }
        count
    }

    #[test]
    fn paired_markers_keep_their_spelling_and_work_in_vertical_text() {
        let mut markers: Vec<_> = ('①'..='⑳')
            .map(|c| (c.to_string(), format!("注{c}：")))
            .collect();
        markers.extend([
            ("[1]".into(), "[1] ".into()),
            ("［1］".into(), "注1：".into()),
            ("〔1〕".into(), "〔1〕".into()),
            ("[注1]".into(), "注1：".into()),
            ("［注1］".into(), "［注1］".into()),
            ("①".into(), "①".into()),
        ]);
        for (reference, definition) in markers {
            let text = format!(
                "第一章 开始\n注释标记{reference}在这里。\n　　{definition}注释正文<&>。\n"
            );
            for vertical in [false, true] {
                let docs = documents(&text, Some("popup"), vertical);
                assert_eq!(check_pairs(&docs), 1, "{text}");
                assert!(
                    docs.pages
                        .values()
                        .any(|p| p.contains(&format!(">{reference}</a>")))
                );
            }
        }
    }

    #[test]
    fn ambiguous_unpaired_and_cross_chapter_notes_are_left_as_text() {
        for text in [
            "第一章 开始\n正文①没有注释。\n",
            "第一章 开始\n①只有注释行。\n",
            "第一章 开始\n正文①又有①。\n①注释。\n",
            "第一章 开始\n正文[1]。\n[1]注释甲。\n注1：注释乙。\n",
            "第一章 开始\n①注释先出现。\n正文①。\n",
            "第一章 开始\n正文①。\n第二章 后来\n①跨章不能配对。\n",
            "第一章 开始\n正文（注：行内括注）。\n",
            "第一章 开始\n正文①。\n① ： \n",
        ] {
            let docs = documents(text, Some("popup"), false);
            assert_eq!(check_pairs(&docs), 0, "{text}");
            assert!(docs.pages.values().all(|p| !p.contains("<aside")));
        }
        let docs = documents(
            "第一章 开始\n正文①。\n①第一条。\n第二章 后来\n正文①。\n①第二条。\n",
            Some("popup"),
            false,
        );
        assert_eq!(check_pairs(&docs), 2);
        // 没有章标题的书首行是 Body 节点，仍然属于正文。
        assert_eq!(
            check_pairs(&documents("正文①。\n①解释。\n", Some("popup"), false)),
            1
        );
    }

    #[test]
    fn notes_survive_physical_splits_and_restore_source_in_original_order() {
        let text = "第一章 开始\r\n\t　读｜汉字《hàn zì》①与[注2]。\r空行前\n\n\t　①：解释汉字。\r\n注2：另一个解释。\n结尾";
        let mut docs = documents(text, Some("popup"), false);
        crate::publication_split::split(&mut docs, 350).unwrap();
        assert!(
            docs.reading_order
                .iter()
                .filter(|s| s.starts_with("body"))
                .count()
                > 1
        );
        assert_eq!(check_pairs(&docs), 2);
        let mut restored = String::new();
        for file in &docs.reading_order {
            let xml = roxmltree::Document::parse(&docs.pages[file]).unwrap();
            for node in xml
                .descendants()
                .filter(|n| n.attribute("data-source") == Some("true"))
            {
                restored.push_str(node.attribute("data-original").unwrap());
                restored.push_str(match node.attribute("data-eol").unwrap() {
                    "lf" => "\n",
                    "crlf" => "\r\n",
                    "cr" => "\r",
                    _ => "",
                });
            }
        }
        assert_eq!(restored, text);
        let off = documents(text, Some("off"), false);
        assert_eq!(off.pages, documents(text, None, false).pages);
        assert_eq!(check_pairs(&off), 0);
    }

    #[test]
    fn note_settings_default_off_and_presets_validate_the_full_layout() {
        assert_eq!(crate::layout_settings::factory()["note_style"], "off");
        for style in ["off", "popup"] {
            let mut values = crate::layout_settings::factory();
            values.insert("note_style".into(), json!(style));
            assert!(
                crate::layout_presets::Preset {
                    name: "完整排版".into(),
                    values
                }
                .validate()
                .is_ok()
            );
        }
        for invalid in [json!("guess"), json!(true), json!(null)] {
            let values = BTreeMap::from([("note_style".into(), invalid)]);
            assert!(
                crate::layout_presets::Preset {
                    name: "错误值".into(),
                    values
                }
                .validate()
                .is_err()
            );
        }
    }
}
