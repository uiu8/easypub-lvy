//! 从原书读到的行内样式、脚注和表格（G-113）。
//!
//! 手工样式按有效稿字节位置定位，前面的文字一动就失效；导入的标记数量多，用户
//! 又常在导入后清理、改章节，不能这样存。这里按工作稿行号存成一个单独的文件，
//! 设置里只放路径和校验值。每次生成时经 `source_to_output_lines` 找到当前的行，
//! 再按原文字找到位置：行删了或那段文字改了，这一条就不生效，其余不受影响。
use crate::{
    inline_styles::{Annotation, Style},
    manual_notes::{self, Anchor, Body, Note},
    production::Settings,
};
use easypub_core::{ApiError, ErrorCode, publication::EffectiveBook, structure::Role};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet, HashMap, HashSet},
    fs,
    path::Path,
    sync::{Arc, Mutex},
};

pub const FILE_NAME: &str = "source-marks.json";
const MAX_FILE_BYTES: u64 = 256 * 1024 * 1024;
const MAX_REMOVED: usize = 200_000;

fn error(reason: &'static str) -> ApiError {
    ApiError::new(ErrorCode::InvalidRule, "source_marks", reason)
}
fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn hash_shape(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn is_zero(value: &u32) -> bool {
    *value == 0
}

/// 写进书籍设置的部分：哪个文件，用户去掉了哪些。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Selection {
    pub path: String,
    pub sha256: String,
    /// 读到的样式、链接、脚注一共几处，界面显示用。
    #[serde(default, skip_serializing_if = "is_zero")]
    pub marks: u32,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub tables: u32,
    /// 一键全部移除：样式、链接、脚注都不用，表格还在。
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub styles_off: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub removed: Vec<String>,
}
impl Selection {
    pub fn validate(&self) -> Result<(), ApiError> {
        if !Path::new(&self.path).is_absolute()
            || self.path.len() > 32768
            || !hash_shape(&self.sha256)
            || self.removed.len() > MAX_REMOVED
            || !self.removed.iter().all(|id| hash_shape(id))
        {
            return Err(error("source_marks_invalid"));
        }
        Ok(())
    }
    /// 文件还在且内容没变。缺了就和缺图片一样提示，不悄悄丢样式。
    pub fn inspect(&self) -> Result<(), ApiError> {
        load(self).map(|_| ())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum MarkKind {
    Style { style: Style },
    Link { href: String },
    Note { target: u32 },
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Mark {
    pub id: String,
    pub line: u32,
    /// 这段文字是行内第几次出现，从 0 数起。
    pub nth: u32,
    pub text: String,
    pub kind: MarkKind,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Cell {
    pub text: String,
    pub head: bool,
    pub columns: u32,
    pub rows: u32,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Table {
    pub id: String,
    pub line: u32,
    pub columns: u32,
    pub caption: String,
    pub rows: Vec<Vec<Cell>>,
}
impl Table {
    /// 工作稿里占位的那一行。
    pub fn placeholder(&self) -> String {
        format!("〔表格：{} 行 {} 列〕", self.rows.len(), self.columns)
    }
    pub fn html(&self, original: &str, eol: &str) -> Result<String, ApiError> {
        use crate::navigation_documents::escaped;
        let mut html = format!(
            "<table class=\"book-table\" data-source=\"true\" data-original=\"{}\" data-eol=\"{eol}\">",
            escaped(original)?
        );
        if !self.caption.is_empty() {
            html.push_str(&format!("<caption>{}</caption>", escaped(&self.caption)?));
        }
        for row in &self.rows {
            html.push_str("<tr>");
            for cell in row {
                let tag = if cell.head { "th" } else { "td" };
                html.push_str(&format!("<{tag}"));
                if cell.columns > 1 {
                    html.push_str(&format!(" colspan=\"{}\"", cell.columns));
                }
                if cell.rows > 1 {
                    html.push_str(&format!(" rowspan=\"{}\"", cell.rows));
                }
                html.push_str(&format!(">{}</{tag}>", escaped(&cell.text)?));
            }
            html.push_str("</tr>");
        }
        html.push_str("</table>");
        Ok(html)
    }
    pub fn characters(&self) -> impl Iterator<Item = &str> {
        std::iter::once(self.caption.as_str())
            .chain(self.rows.iter().flatten().map(|c| c.text.as_str()))
    }
}
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Data {
    pub marks: Vec<Mark>,
    pub tables: Vec<Table>,
    /// 书内其他跳转链接：不保留，导入结果里写明数量。
    pub dropped_links: u32,
}
impl Data {
    pub fn is_empty(&self) -> bool {
        self.marks.is_empty() && self.tables.is_empty()
    }
    /// 写进资源目录，返回给界面的概要；什么都没有时不写文件。
    pub fn write(&self, directory: &Path) -> Result<Value, ApiError> {
        let count =
            |test: fn(&MarkKind) -> bool| self.marks.iter().filter(|m| test(&m.kind)).count();
        let mut report = json!({
            "styles": count(|k| matches!(k, MarkKind::Style { .. })),
            "links": count(|k| matches!(k, MarkKind::Link { .. })),
            "notes": count(|k| matches!(k, MarkKind::Note { .. })),
            "tables": self.tables.len(),
            "dropped_links": self.dropped_links,
        });
        if self.is_empty() {
            return Ok(report);
        }
        let bytes = serde_json::to_vec(self).map_err(|_| error("source_marks_invalid"))?;
        fs::create_dir_all(directory).map_err(|_| error("write_source_marks"))?;
        let path = directory.join(FILE_NAME);
        fs::write(&path, &bytes).map_err(|_| error("write_source_marks"))?;
        report["path"] = json!(path.to_string_lossy());
        report["sha256"] = json!(digest(&bytes));
        Ok(report)
    }
}
pub fn mark_id(line: u32, nth: u32, text: &str, kind: &MarkKind) -> String {
    let kind = serde_json::to_string(kind).unwrap_or_default();
    digest(format!("{line}:{nth}:{kind}:{text}").as_bytes())
}

pub fn table_id(line: u32) -> String {
    digest(format!("table:{line}").as_bytes())
}

static LOADED: Mutex<Vec<(String, Arc<Data>)>> = Mutex::new(Vec::new());
fn load(selection: &Selection) -> Result<Arc<Data>, ApiError> {
    let key = format!("{}\n{}", selection.sha256, selection.path);
    if let Some((_, data)) = LOADED.lock().unwrap().iter().find(|(k, _)| *k == key) {
        return Ok(data.clone());
    }
    let missing = || error("restore_source_marks");
    let size = fs::metadata(&selection.path).map_err(|_| missing())?.len();
    if size > MAX_FILE_BYTES {
        return Err(missing());
    }
    let bytes = fs::read(&selection.path).map_err(|_| missing())?;
    if digest(&bytes) != selection.sha256 {
        return Err(missing());
    }
    let data: Arc<Data> = Arc::new(serde_json::from_slice(&bytes).map_err(|_| missing())?);
    let mut loaded = LOADED.lock().unwrap();
    if loaded.len() >= 4 {
        loaded.remove(0);
    }
    loaded.push((key, data.clone()));
    Ok(data)
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlacedTable {
    pub start: usize,
    pub end: usize,
    pub table: Table,
    /// 用户整张删了：成品里不出现，占位行也不显示。
    pub removed: bool,
}
impl PlacedTable {
    pub fn html(&self, original: &str, eol: &str) -> Result<String, ApiError> {
        if self.removed {
            return Ok(format!(
                "<div data-source=\"true\" data-original=\"{}\" data-eol=\"{eol}\"></div>",
                crate::navigation_documents::escaped(original)?
            ));
        }
        self.table.html(original, eol)
    }
}
/// 对着当前稿子算出来的结果，能直接并进手工样式和注释。
#[derive(Default)]
pub(crate) struct Resolved {
    pub styles: Vec<Annotation>,
    pub notes: Vec<Note>,
    pub tables: Vec<PlacedTable>,
}

/// 行首字节位置。下标是行号减一。
fn line_starts(text: &str) -> Vec<usize> {
    let bytes = text.as_bytes();
    let mut starts = vec![0];
    for (at, &b) in bytes.iter().enumerate() {
        if b == b'\n' || (b == b'\r' && bytes.get(at + 1) != Some(&b'\n')) {
            starts.push(at + 1);
        }
    }
    starts
}
fn find_nth(line: &str, text: &str, nth: u32) -> Option<usize> {
    let mut last = None;
    for (i, (at, _)) in line.match_indices(text).enumerate() {
        last = Some(at);
        if i as u32 == nth {
            return last;
        }
    }
    // 行里别处改过，次数对不上时只有一处还能认。
    (line.matches(text).count() == 1).then_some(last).flatten()
}

struct Lines<'a> {
    book: &'a EffectiveBook,
    starts: Vec<usize>,
    headings: HashSet<usize>,
    prints: HashMap<usize, String>,
}
impl<'a> Lines<'a> {
    /// 原行号对应的当前行：起点、含换行的终点、不含换行的文字。
    fn at(&self, source: u32) -> Option<(usize, usize, &'a str)> {
        let output = *self.book.source_to_output_lines.get(&source)? as usize;
        let start = *self.starts.get(output.checked_sub(1)?)?;
        let end = self
            .starts
            .get(output)
            .copied()
            .unwrap_or(self.book.text.len());
        let line = self.book.text[start..end].trim_end_matches(['\r', '\n']);
        (start < end).then_some((start, end, line))
    }
    fn anchor(&mut self, start: usize, end: usize, from: usize, to: usize) -> Anchor {
        let text = &self.book.text;
        let fingerprint = self
            .prints
            .entry(start)
            .or_insert_with(|| digest(&text.as_bytes()[start..end]))
            .clone();
        Anchor {
            start,
            end,
            from,
            to,
            fingerprint,
        }
    }
}

pub(crate) fn resolve(settings: &Settings, book: &EffectiveBook) -> Result<Resolved, ApiError> {
    let mut resolved = Resolved::default();
    let Some(selection) = &settings.source_marks else {
        return Ok(resolved);
    };
    let data = load(selection)?;
    let mut lines = Lines {
        book,
        starts: line_starts(&book.text),
        headings: book
            .tree
            .nodes
            .iter()
            .filter(|n| n.role != Role::Body)
            .map(|n| n.start)
            .collect(),
        prints: HashMap::new(),
    };
    let removed: HashSet<&str> = selection.removed.iter().map(String::as_str).collect();
    for table in &data.tables {
        // 占位行被改过就不是表格了，按用户改的文字走。
        if let Some((start, end, line)) = lines.at(table.line)
            && line.trim() == table.placeholder()
            && !lines.headings.contains(&start)
        {
            resolved.tables.push(PlacedTable {
                start,
                end,
                table: table.clone(),
                removed: removed.contains(table.id.as_str()),
            });
        }
    }
    if selection.styles_off {
        return Ok(resolved);
    }
    let mut definitions = BTreeSet::new();
    let mut ranges = BTreeMap::<usize, Vec<(usize, usize)>>::new();
    for note in &settings.manual_notes {
        let a = &note.reference;
        ranges.entry(a.start).or_default().push((a.from, a.to));
        if let Body::Pair { definition } = &note.body {
            definitions.insert(definition.start);
        }
    }
    // 先定脚注，网址链接不能套在注释链接里。
    for mark in &data.marks {
        let MarkKind::Note { target } = mark.kind else {
            continue;
        };
        if removed.contains(mark.id.as_str()) {
            continue;
        }
        let Some((start, end, line)) = lines.at(mark.line) else {
            continue;
        };
        let Some((d_start, d_end, _)) = lines.at(target) else {
            continue;
        };
        let Some(from) = find_nth(line, &mark.text, mark.nth) else {
            continue;
        };
        let to = from + mark.text.len();
        if lines.headings.contains(&start)
            || lines.headings.contains(&d_start)
            || definitions.contains(&d_start)
            || definitions.contains(&start)
            || ranges.contains_key(&d_start)
            || ranges
                .get(&start)
                .is_some_and(|r| r.iter().any(|&(f, t)| from < t && f < to || f == from))
        {
            continue;
        }
        let note = Note {
            id: mark.id.clone(),
            reference: lines.anchor(start, end, from, to),
            body: Body::Pair {
                definition: lines.anchor(d_start, d_end, 0, 0),
            },
        };
        if manual_notes::invalid_reason(&note, book).is_some() {
            continue;
        }
        definitions.insert(d_start);
        ranges.entry(start).or_default().push((from, to));
        resolved.notes.push(note);
    }
    for mark in &data.marks {
        let (style, href) = match &mark.kind {
            MarkKind::Style { style } => (*style, None),
            MarkKind::Link { href } => (Style::Link, Some(href.clone())),
            MarkKind::Note { .. } => continue,
        };
        if removed.contains(mark.id.as_str()) {
            continue;
        }
        let Some((start, end, line)) = lines.at(mark.line) else {
            continue;
        };
        if lines.headings.contains(&start) {
            continue;
        }
        let Some(from) = find_nth(line, &mark.text, mark.nth) else {
            continue;
        };
        let to = from + mark.text.len();
        if crate::inline_markup::splits_markup(line, from)
            || crate::inline_markup::splits_markup(line, to)
            || style == Style::Link
                && ranges
                    .get(&start)
                    .is_some_and(|r| r.iter().any(|&(f, t)| from < t && f < to))
        {
            continue;
        }
        resolved.styles.push(Annotation {
            id: mark.id.clone(),
            anchor: lines.anchor(start, end, from, to),
            style,
            href,
        });
    }
    Ok(resolved)
}

#[cfg(test)]
#[path = "source_marks_tests.rs"]
mod tests;
