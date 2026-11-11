use crate::{
    ApiError, ErrorCode,
    encoding::{EncodingKind, EncodingMode, decode, encode},
    recognition::is_default_heading,
};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};

pub const RULE_ID: &str = "builtin-heading-v1";
pub const MAX_PAGE_LINES: u32 = 200;
pub const MAX_PAGE_BYTES: usize = 256 * 1024;

#[derive(Clone, Debug)]
pub struct BookSummary {
    pub source_id: String,
    pub revision: u32,
    pub byte_length: u32,
    pub line_count: u32,
    pub chapter_count: u32,
    pub has_utf8_bom: bool,
    pub encoding: String,
    pub bom_length: u32,
    pub rule_id: String,
}

#[derive(Clone, Debug)]
pub struct ChapterSummary {
    pub entry_id: String,
    pub title: String,
    pub source_line: u32,
}

/// 放错位置、原位确实空着的章：可以整章移回 [anchor] 之后（没有 anchor 时移到这一串的第一章之前）。
#[derive(Clone, Debug)]
pub struct MisplacedChapter {
    pub entry_id: String,
    pub title: String,
    pub source_line: u32,
    pub number: u32,
    pub unit: char,
    /// 移到这一章之后：(章 id, 标题, 源行)。
    pub anchor: Option<(String, String, u32)>,
    /// 没有 anchor 时移到这一章之前。
    pub first: (String, String, u32),
    /// 现在紧挨在它前面的章标题（说明用）。
    pub current_after: Option<String>,
    /// 全部归位后紧跟在它后面的章（这一串里章号比它大的最小一章，可能也是放错的章）。
    pub next: Option<String>,
    /// 这一串主体的最后一章：没有 next 时移到它（及其下级）之后。
    pub tail: String,
}

/// 编号写错的标题：前后两章编号连续（差 2），正好缺中间这一号，这一章写成了别的号。
#[derive(Clone, Debug)]
pub struct MisnumberedChapter {
    pub entry_id: String,
    pub title: String,
    pub source_line: u32,
    pub number: u32,
    pub expected: u32,
    pub unit: char,
    /// 写错的号在同一串里另有一章：一定是写错了。
    pub duplicated: bool,
    pub previous: ChapterSummary,
    pub next: ChapterSummary,
}

/// 最长不减子序列的下标（O(n log n)）。
fn longest_non_decreasing(values: &[u32]) -> Vec<bool> {
    let mut tails: Vec<usize> = Vec::new();
    let mut prev = vec![usize::MAX; values.len()];
    for (k, &v) in values.iter().enumerate() {
        let pos = tails.partition_point(|&t| values[t] <= v);
        if pos > 0 {
            prev[k] = tails[pos - 1];
        }
        if pos == tails.len() {
            tails.push(k);
        } else {
            tails[pos] = k;
        }
    }
    let mut keep = vec![false; values.len()];
    let mut k = tails.last().copied().unwrap_or(usize::MAX);
    while k != usize::MAX {
        keep[k] = true;
        k = prev[k];
    }
    keep
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SourceCursor {
    /// Zero-based source line; display line numbers are one-based.
    pub line_index: u32,
    /// UTF-8 byte offset within that decoded line, never a Dart UTF-16 offset.
    pub utf8_column: u32,
}

#[derive(Clone, Debug)]
pub struct TextFragment {
    pub line_number: u32,
    pub utf8_column: u32,
    pub text: String,
    pub continues: bool,
}

#[derive(Clone, Debug)]
pub struct SourcePage {
    pub source_id: String,
    pub revision: u32,
    pub items: Vec<TextFragment>,
    pub next_cursor: Option<SourceCursor>,
    pub text_bytes: u32,
}

#[derive(Clone, Debug)]
pub struct ChapterPage {
    pub source_id: String,
    pub revision: u32,
    pub items: Vec<ChapterSummary>,
    pub next_offset: Option<u32>,
    pub total: u32,
}

#[derive(Debug)]
pub struct SourceSnapshot {
    /// 文件原始字节。UTF-8 且没有 BOM 时和 `text` 完全相同，留空不存第二份，用 [`Self::raw`] 读。
    bytes: Vec<u8>,
    text: String,
    lines: Vec<(usize, usize)>,
    chapters: Vec<ChapterSummary>,
    summary: BookSummary,
    diagnostic_boundaries: Option<BTreeSet<u32>>,
    diagnostic_groups: BTreeMap<u32, (Option<String>, u8)>,
    rules: Option<crate::chapter_rules::CompiledRules>,
    diagnostic_decisions: BTreeMap<u32, bool>,
    /// 进程内唯一编号：每次构造递增，从不复用，供“按快照缓存”使用。
    instance: u64,
}

fn cancelled() -> ApiError {
    ApiError::new(ErrorCode::Cancelled, "import", "retry_import")
}

impl SourceSnapshot {
    /// Ephemeral diagnostic view of the composed book, never registered as an
    /// original source or used to authorize a file write. Logical headings and
    /// numbering boundaries come from the effective tree, not a fresh regex pass.
    pub fn for_effective_diagnostics(
        book: &crate::publication::EffectiveBook,
    ) -> Result<Self, ApiError> {
        let mut view = Self::from_text(book.text.clone(), RULE_ID)?;
        view.rules = book
            .tree
            .recognition_rules
            .as_ref()
            .map(|rules| rules.compile())
            .transpose()?;
        view.diagnostic_decisions = book
            .tree
            .recognition_decisions
            .iter()
            .filter_map(|(original, heading)| {
                book.source_to_output_lines
                    .get(original)
                    .map(|line| (*line, *heading))
            })
            .collect();
        view.chapters = book
            .tree
            .nodes
            .iter()
            .map(|n| ChapterSummary {
                entry_id: n.entry_id.clone(),
                title: n.title.clone(),
                source_line: n.source_line,
            })
            .collect();
        view.diagnostic_boundaries = Some(
            book.tree
                .nodes
                .iter()
                .filter(|n| {
                    matches!(
                        n.role,
                        crate::structure::Role::Volume | crate::structure::Role::Front
                    )
                })
                .map(|n| n.source_line)
                .collect(),
        );
        let by_id = book
            .tree
            .nodes
            .iter()
            .map(|n| (n.entry_id.as_str(), n))
            .collect::<BTreeMap<_, _>>();
        view.diagnostic_groups = book
            .tree
            .nodes
            .iter()
            .map(|n| {
                let group = if n.role == crate::structure::Role::Chapter {
                    let mut parent = n.parent_id.as_deref();
                    let mut volume = None;
                    while let Some(p) = parent.and_then(|id| by_id.get(id)) {
                        if p.role == crate::structure::Role::Volume {
                            volume = Some(p.entry_id.clone());
                            break;
                        }
                        parent = p.parent_id.as_deref();
                    }
                    (volume, 0)
                } else {
                    (n.parent_id.clone(), n.depth)
                };
                (n.source_line, group)
            })
            .collect();
        view.summary.chapter_count = view.chapters.len() as u32;
        view.summary.source_id = crate::effective_edit::base_id(book);
        Ok(view)
    }

    fn numbering_boundary(&self, chapter: &ChapterSummary) -> bool {
        self.diagnostic_boundaries.as_ref().map_or_else(
            || {
                numbered_heading(&chapter.title)
                    .is_some_and(|(_, marker)| matches!(marker, '卷' | '部' | '篇' | '集'))
            },
            |lines| lines.contains(&chapter.source_line),
        )
    }
    /// Borrow the immutable decoded source; callers must not derive new identities in Flutter.
    pub fn decoded_text(&self) -> &str {
        &self.text
    }
    /// Decoded UTF-8 ranges excluding CR/LF, shared by evidence and rendering.
    pub fn decoded_line_ranges(&self) -> &[(usize, usize)] {
        &self.lines
    }
    pub fn headings(&self) -> &[ChapterSummary] {
        &self.chapters
    }
    pub fn number_corrections(&self) -> Option<Vec<(char, char)>> {
        self.rules
            .as_ref()
            .map(|r| r.rules.corrections().expect("validated rules"))
    }
    pub fn encode_edited_text(&self, text: &str) -> Result<Vec<u8>, ApiError> {
        let kind = match self.summary.encoding.as_str() {
            "utf-8" => EncodingKind::Utf8,
            "utf-16le" => EncodingKind::Utf16Le,
            "utf-16be" => EncodingKind::Utf16Be,
            "utf-32le" => EncodingKind::Utf32Le,
            "utf-32be" => EncodingKind::Utf32Be,
            "cp936" => EncodingKind::Cp936,
            _ => {
                return Err(ApiError::new(
                    ErrorCode::InvalidEncoding,
                    "catalog",
                    "reimport_source",
                ));
            }
        };
        encode(text, kind, self.summary.bom_length > 0)
    }
    pub fn from_utf8(
        bytes: Vec<u8>,
        rule_id: &str,
        is_cancelled: impl Fn() -> bool,
    ) -> Result<Self, ApiError> {
        Self::from_bytes(bytes, EncodingMode::Utf8, rule_id, is_cancelled)
    }

    pub fn from_bytes(
        bytes: Vec<u8>,
        mode: EncodingMode,
        rule_id: &str,
        is_cancelled: impl Fn() -> bool,
    ) -> Result<Self, ApiError> {
        if rule_id != RULE_ID {
            return Err(ApiError::new(
                ErrorCode::UnsupportedRule,
                "recognize",
                "select_explicit_rule",
            ));
        }
        if is_cancelled() {
            return Err(cancelled());
        }
        let decoded = decode(&bytes, mode)?;
        let same = decoded.encoding == EncodingKind::Utf8 && decoded.bom.is_empty();
        Self::build(
            if same { Vec::new() } else { bytes },
            decoded.text,
            decoded.encoding,
            decoded.bom.len(),
            rule_id,
            is_cancelled,
        )
    }

    /// 书稿文本建索引，等同 [`Self::from_utf8`]：省掉校验和复制，文本直接收下，
    /// 用完可以用 [`Self::into_text`] 原样取回。
    pub fn from_text(text: String, rule_id: &str) -> Result<Self, ApiError> {
        if rule_id != RULE_ID {
            return Err(ApiError::new(
                ErrorCode::UnsupportedRule,
                "recognize",
                "select_explicit_rule",
            ));
        }
        if text.starts_with('\u{feff}') {
            return Self::from_utf8(text.into_bytes(), rule_id, || false);
        }
        Self::build(Vec::new(), text, EncodingKind::Utf8, 0, rule_id, || false)
    }

    /// 取回建索引时给的文本。
    pub fn into_text(self) -> String {
        if self.bytes.is_empty() {
            self.text
        } else {
            String::from_utf8_lossy(&self.bytes).into_owned()
        }
    }

    fn build(
        bytes: Vec<u8>,
        text: String,
        encoding: EncodingKind,
        bom_length: usize,
        rule_id: &str,
        is_cancelled: impl Fn() -> bool,
    ) -> Result<Self, ApiError> {
        let raw = if bytes.is_empty() {
            text.as_bytes()
        } else {
            bytes.as_slice()
        };
        let byte_length = raw.len();
        let mut hash = Sha256::new();
        for chunk in raw.chunks(64 * 1024) {
            if is_cancelled() {
                return Err(cancelled());
            }
            hash.update(chunk);
        }
        let source_id = format!("{:x}", hash.finalize());
        let mut lines = Vec::new();
        let mut chapters = Vec::new();
        let mut start = 0;
        let data = text.as_bytes();
        let mut ends = memchr::memchr2_iter(b'\r', b'\n', data);
        while let Some(position) = ends.next() {
            if lines.len() % 1024 == 0 && is_cancelled() {
                return Err(cancelled());
            }
            lines.push((start, position));
            start = position + 1;
            if data[position] == b'\r' && data.get(position + 1) == Some(&b'\n') {
                ends.next();
                start = position + 2;
            }
        }
        if start < data.len() {
            lines.push((start, data.len()));
        }
        for (index, &(start, end)) in lines.iter().enumerate() {
            if index % 128 == 0 && is_cancelled() {
                return Err(cancelled());
            }
            let title = &text[start..end];
            if is_default_heading(title) {
                chapters.push(ChapterSummary {
                    entry_id: format!("{source_id}:{start}"),
                    title: title.trim().to_owned(),
                    source_line: index as u32 + 1,
                });
            }
        }
        if is_cancelled() {
            return Err(cancelled());
        }
        let summary = BookSummary {
            source_id,
            revision: 1,
            byte_length: byte_length as u32,
            line_count: lines.len() as u32,
            chapter_count: chapters.len() as u32,
            has_utf8_bom: encoding == EncodingKind::Utf8 && bom_length > 0,
            encoding: encoding.label().into(),
            bom_length: bom_length as u32,
            rule_id: rule_id.into(),
        };
        Ok(Self {
            bytes,
            text,
            lines,
            chapters,
            summary,
            diagnostic_boundaries: None,
            diagnostic_groups: BTreeMap::new(),
            rules: None,
            diagnostic_decisions: BTreeMap::new(),
            instance: {
                static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
                NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            },
        })
    }

    /// 进程内唯一编号（桥接第 2 批）：同一个快照对象不变，任何两次构造都不同。
    pub fn instance(&self) -> u64 {
        self.instance
    }

    pub fn original_bytes(&self) -> &[u8] {
        self.raw()
    }

    fn raw(&self) -> &[u8] {
        if self.bytes.is_empty() {
            self.text.as_bytes()
        } else {
            &self.bytes
        }
    }
    /// Heap capacity owned by this immutable snapshot, for session budgeting.
    pub fn resident_bytes(&self) -> usize {
        self.bytes.capacity()
            + self.text.capacity()
            + self.lines.capacity() * std::mem::size_of::<(usize, usize)>()
            + self.chapters.capacity() * std::mem::size_of::<ChapterSummary>()
            + self
                .chapters
                .iter()
                .map(|c| c.title.capacity() + c.entry_id.capacity())
                .sum::<usize>()
    }

    fn duplicate_title_lines(&self) -> BTreeSet<u32> {
        self.chapters
            .windows(2)
            .filter_map(|pair| {
                let a = &pair[0];
                let b = &pair[1];
                (a.title == b.title
                    && self.lines[a.source_line as usize..b.source_line as usize - 1]
                        .iter()
                        .all(|&(start, end)| self.text[start..end].trim().is_empty())
                    // 用户在识别规则中允许重复的标题不报。
                    && !self
                        .rules
                        .as_ref()
                        .is_some_and(|r| r.allows_duplicate_title(&b.title)))
                .then_some(b.source_line)
            })
            .collect()
    }

    /// 识别规则例外影响的两项检查数量：连续重复标题、章节编号跳跃。
    pub fn exception_finding_counts(&self) -> (usize, usize) {
        (
            self.duplicate_title_lines().len(),
            self.numbering_gaps().len(),
        )
    }

    pub fn diagnostic_json(&self) -> String {
        let mut findings = Vec::new();
        let number_typos = crate::heading_typos::find(self).len();
        if number_typos > 0 {
            findings.push(serde_json::json!({"id":"heading-number-typo","title":"章节编号疑似错字","severity":"warning","count":number_typos}));
        }
        let missing_prefix = self.missing_prefix_chapters().len();
        if missing_prefix > 0 {
            findings.push(serde_json::json!({"id":"missing-heading-prefix","title":"未带“第”的编号标题（可保留）","severity":"info","count":missing_prefix}));
        }
        let duplicate = self.duplicate_title_lines().len() as u32;
        let repeated = crate::duplicate_blocks::find(self)
            .map(|g| g.iter().map(|g| g.occurrences.len() - 1).sum::<usize>())
            .unwrap_or(0);
        if repeated > 0 {
            findings.push(serde_json::json!({"id":"duplicate-content","title":"整章内容完全重复（需选择保留）","severity":"warning","count":repeated}));
        }

        let resets = self
            .numbering_pairs()
            .iter()
            .filter(|(a, b, old, new)| {
                (new < old
                    || (new == old
                        && (a.title.trim() != b.title.trim()
                            || self.lines[a.source_line as usize..b.source_line as usize - 1]
                                .iter()
                                .any(|&(start, end)| !self.text[start..end].trim().is_empty()))
                        && !crate::chapter_rules::ordered_parts(&a.title, &b.title)))
                    && self.check_enabled(
                        "number-reset",
                        Some(if new == old {
                            "repeated-number"
                        } else {
                            "number-reversal"
                        }),
                    )
            })
            .count();
        let prose = self.prose_headings().len();
        if prose > 0 {
            findings.push(serde_json::json!({"id":"prose-heading","title":"正文被当成章节标题","severity":"warning","count":prose}));
        }
        let missing = self.unrecognized_headings().len();
        if missing > 0 {
            findings.push(serde_json::json!({"id":"unrecognized-heading","title":"正文中有尚未收入目录的标题","severity":"warning","count":missing}));
        }
        if duplicate > 0 {
            findings.push(serde_json::json!({"id":"duplicate-title","title":"连续重复标题","severity":"warning","count":duplicate}));
        }
        if resets > 0 {
            findings.push(serde_json::json!({"id":"number-reset","title":"章节编号回退或重复","severity":"warning","count":resets}));
        }
        let misplaced = self.misplaced_chapters().len();
        if misplaced > 0 {
            findings.push(serde_json::json!({"id":"chapter-misplaced","title":"章节放错位置（原位空着，可移回）","severity":"warning","count":misplaced}));
        }
        let gaps = self.numbering_gaps().len();
        if gaps > 0 {
            findings.push(serde_json::json!({"id":"number-gap","title":"章节编号跳跃（正文是否缺失待核对）","severity":"warning","count":gaps}));
        }
        if self.chapters.is_empty() {
            findings.push(serde_json::json!({"id":"no-headings","title":"未识别章节标题","severity":"error","count":1}));
        }
        findings.retain(|v| self.check_enabled(v["id"].as_str().unwrap(), None));
        serde_json::json!({"source_id":self.summary.source_id,"revision":self.summary.revision,"line_count":self.summary.line_count,"chapter_count":self.summary.chapter_count,"findings":findings}).to_string()
    }

    fn check_enabled(&self, id: &str, subtype: Option<&str>) -> bool {
        self.rules
            .as_ref()
            .is_none_or(|r| r.rules.check_enabled(id, subtype))
    }

    /// Numbered titles without “第” that should be offered a prefix. Prose
    /// headings and author notes are excluded: they belong back in the body,
    /// and “第两章合一章” would be a nonsensical rename.
    pub fn missing_prefix_chapters(&self) -> Vec<&ChapterSummary> {
        let prose: std::collections::BTreeSet<u32> = self
            .prose_headings()
            .iter()
            .map(|c| c.source_line)
            .collect();
        self.chapters
            .iter()
            .filter(|c| {
                missing_heading_prefix(&c.title)
                    && !prose.contains(&c.source_line)
                    && !crate::recognition::is_author_note_heading(&c.title)
            })
            .collect()
    }

    pub fn prose_headings(&self) -> Vec<&ChapterSummary> {
        let dominant =
            crate::recognition::dominant_marker(self.chapters.iter().map(|c| c.title.as_str()));
        self.chapters
            .iter()
            .filter(|c| {
                self.diagnostic_decisions.get(&c.source_line) != Some(&true)
                    && !self
                        .rules
                        .as_ref()
                        .is_some_and(|rules| rules.explicitly_matches(&c.title))
                    && crate::recognition::is_prose_heading(&c.title, dominant)
                    || self.diagnostic_decisions.get(&c.source_line) != Some(&true)
                        && self.is_non_heading(&c.title)
            })
            .collect()
    }

    /// 非标题词库命中；没有识别规则时为 false。
    pub fn is_non_heading(&self, text: &str) -> bool {
        self.rules.as_ref().is_some_and(|r| r.is_non_heading(text))
    }

    pub fn unrecognized_headings(&self) -> Vec<(u32, String)> {
        let known = self
            .chapters
            .iter()
            .map(|c| c.source_line)
            .collect::<BTreeSet<_>>();
        let builtin = crate::recognition::NumericRule::Builtin;
        let numeric = self.rules.as_ref().map_or(&builtin, |rules| &rules.numeric);
        let minimum = self
            .rules
            .as_ref()
            .map_or(3, |r| r.rules.numeric_minimum_body_lines as usize);
        let matches = self
            .lines
            .iter()
            .enumerate()
            .filter_map(|(i, &(start, end))| {
                let line = i as u32 + 1;
                let text = self.text[start..end].trim();
                if text.chars().count() > 120 || self.is_non_heading(text) {
                    return None;
                }
                numeric
                    .matches(text)
                    .map(|parsed| (line, text, parsed.number))
            })
            .collect::<Vec<_>>();
        // Include already recognized numeric headings in the evidence. Otherwise
        // applying the first batch can strand the final one or two candidates.
        // Like the original converter, require three nonempty body lines so
        // short numbered lists do not grow into artificial chapters.
        let has_body = |line: u32, end: u32| {
            self.lines[line as usize..(end - 1) as usize]
                .iter()
                .filter(|&&(start, end)| !self.text[start..end].trim().is_empty())
                .take(minimum)
                .count()
                >= minimum
        };
        let connected = |a: &(u32, &str, u32), b: &(u32, &str, u32)| {
            b.2 == a.2 + 1
                && b.0 > a.0 + 1
                && !a.1.contains("://")
                && !b.1.contains("://")
                && has_body(a.0, b.0)
        };
        let mut runs = BTreeSet::new();
        let mut start = 0;
        while start < matches.len() {
            let mut end = start + 1;
            while end < matches.len() && connected(&matches[end - 1], &matches[end]) {
                end += 1;
            }
            if end - start >= 3 {
                runs.extend(matches[start..end].iter().map(|v| v.0));
            }
            start = end;
        }
        matches
            .iter()
            .enumerate()
            .filter_map(|(index, &(line, text, number))| {
                if known.contains(&line) || self.diagnostic_decisions.get(&line) == Some(&false) {
                    return None;
                }
                let next = self.chapters.partition_point(|c| c.source_line < line);
                let bounded = next > 0
                    && next < self.chapters.len()
                    && self
                        .chapter_number(&self.chapters[next - 1].title)
                        .zip(self.chapter_number(&self.chapters[next].title))
                        .is_some_and(|((a, am), (b, bm))| am == bm && a < number && number < b);
                let end = matches
                    .get(index + 1)
                    .map_or(self.lines.len() as u32 + 1, |v| v.0);
                (bounded
                    || (runs.contains(&line) || self.chapters.is_empty()) && has_body(line, end))
                .then(|| (line, text.to_owned()))
            })
            .collect()
    }

    fn chapter_number(&self, title: &str) -> Option<(u32, char)> {
        if let Some(rules) = &self.rules {
            return rules.numbering(title);
        }
        numbered_heading(title).or_else(|| {
            crate::recognition::NumericRule::Builtin
                .matches(title)
                .map(|n| (n.number, '章'))
        })
    }

    /// 按编号连贯的一串串章（分卷、上一级章与“节”的切分与原来的相邻比较相同）。
    fn numbering_segments(&self) -> Vec<Vec<(&ChapterSummary, u32, char)>> {
        let prose = self
            .prose_headings()
            .iter()
            .map(|c| c.source_line)
            .collect::<BTreeSet<_>>();
        let mut open =
            BTreeMap::<(Option<String>, u8, char), Vec<(&ChapterSummary, u32, char)>>::new();
        let mut done = Vec::new();
        for chapter in &self.chapters {
            if self.numbering_boundary(chapter) {
                done.extend(std::mem::take(&mut open).into_values());
                continue;
            }
            if prose.contains(&chapter.source_line) {
                continue;
            }
            if let Some((number, marker)) = self.chapter_number(&chapter.title) {
                if marker != '节' {
                    let keys: Vec<_> = open
                        .keys()
                        .filter(|(_, _, u)| *u == '节')
                        .cloned()
                        .collect();
                    for key in keys {
                        done.push(open.remove(&key).unwrap());
                    }
                }
                let (parent, depth) = self
                    .diagnostic_groups
                    .get(&chapter.source_line)
                    .cloned()
                    .unwrap_or_default();
                open.entry((parent, depth, marker))
                    .or_default()
                    .push((chapter, number, marker));
            }
        }
        done.extend(open.into_values());
        done
    }

    /// 一串编号的主体（最长不减子序列）；章太少、或错位超过两成时不判断，返回 None。
    fn numbering_body(segment: &[(&ChapterSummary, u32, char)]) -> Option<Vec<bool>> {
        if segment.len() < 10 || segment[0].2 == '节' {
            return None;
        }
        let keep = longest_non_decreasing(&segment.iter().map(|c| c.1).collect::<Vec<_>>());
        let off = keep.iter().filter(|k| !**k).count();
        (off > 0 && off * 5 <= segment.len()).then_some(keep)
    }

    /// 放错位置、原位确实空着的章。只在三种情形下认定：在这一串主体的第一章之前；
    /// 章号比主体里所有章都大；所在位置前后两章编号本来连续（它是插进来的）。另外都要求：
    /// 这一串里没有别的章用这个章号，作者的话类标题除外。
    pub fn misplaced_chapters(&self) -> Vec<MisplacedChapter> {
        let mut out = Vec::new();
        // 关掉这项检查时，这些章照旧按编号跳跃、回退报告。
        if !self.check_enabled("chapter-misplaced", None) {
            return out;
        }
        for segment in self.numbering_segments() {
            let Some(keep) = Self::numbering_body(&segment) else {
                continue;
            };
            let body: Vec<usize> = (0..segment.len()).filter(|&k| keep[k]).collect();
            let max_body = body.iter().map(|&k| segment[k].1).max().unwrap_or(0);
            let mut counts = BTreeMap::<u32, usize>::new();
            for c in &segment {
                *counts.entry(c.1).or_default() += 1;
            }
            let moved: Vec<usize> = (0..segment.len())
                .filter(|&k| !keep[k])
                .filter(|&k| {
                    let (chapter, number, _) = segment[k];
                    if counts[&number] != 1
                        || crate::recognition::is_author_note_heading(&chapter.title)
                    {
                        return false;
                    }
                    let before = body.iter().rev().find(|&&b| b < k).copied();
                    let after = body.iter().find(|&&b| b > k).copied();
                    let leading = before.is_none();
                    let beyond = number > max_body;
                    let inserted = matches!((before, after), (Some(a), Some(b))
                        if segment[b].1 == segment[a].1 + 1 || segment[b].1 == segment[a].1);
                    // 正好补上前后之间唯一空着的一号：更像编号写错，交给“改标题”。
                    let fills_gap = matches!((before, after), (Some(a), Some(b))
                        if segment[b].1 == segment[a].1 + 2
                            && !counts.contains_key(&(segment[a].1 + 1))
                            && (a + 1..b).all(|j| j == k));
                    (leading || beyond || inserted) && !fills_gap
                })
                .collect();
            for &k in &moved {
                let (chapter, number, unit) = segment[k];
                let anchor = body
                    .iter()
                    .filter(|&&b| segment[b].1 < number)
                    .max_by_key(|&&b| (segment[b].1, b))
                    .map(|&b| {
                        (
                            segment[b].0.entry_id.clone(),
                            segment[b].0.title.clone(),
                            segment[b].0.source_line,
                        )
                    });
                let first = segment[body[0]].0;
                let next = segment
                    .iter()
                    .enumerate()
                    .filter(|(j, c)| c.1 > number && (keep[*j] || moved.contains(j)))
                    .min_by_key(|(j, c)| (c.1, *j))
                    .map(|(_, c)| c.0.entry_id.clone());
                let tail = segment[*body.last().unwrap()].0.entry_id.clone();
                out.push(MisplacedChapter {
                    entry_id: chapter.entry_id.clone(),
                    title: chapter.title.clone(),
                    source_line: chapter.source_line,
                    number,
                    unit,
                    anchor,
                    first: (
                        first.entry_id.clone(),
                        first.title.clone(),
                        first.source_line,
                    ),
                    current_after: k.checked_sub(1).map(|p| segment[p].0.title.clone()),
                    next,
                    tail,
                });
            }
        }
        out.sort_by_key(|m| m.number);
        out
    }

    /// 编号写错的已识别标题：不算放错位置，前后相邻两章编号差 2，中间这一号在这一串里
    /// 一章都没有，这一章却写成了别的号（常见是和前一章重号）。上、下篇这类分段不算。
    pub fn misnumbered_chapters(&self) -> Vec<MisnumberedChapter> {
        let misplaced: BTreeSet<u32> = self
            .misplaced_chapters()
            .iter()
            .map(|m| m.source_line)
            .collect();
        let mut out = Vec::new();
        for segment in self.numbering_segments() {
            let segment: Vec<_> = segment
                .into_iter()
                .filter(|c| !misplaced.contains(&c.0.source_line))
                .collect();
            if segment.len() < 5 || segment[0].2 == '节' {
                continue;
            }
            let mut counts = BTreeMap::<u32, usize>::new();
            for c in &segment {
                *counts.entry(c.1).or_default() += 1;
            }
            for k in 1..segment.len() - 1 {
                let (chapter, number, unit) = segment[k];
                let (a, b) = (k - 1, k + 1);
                let expected = segment[a].1 + 1;
                if number == expected
                    || segment[b].1 != expected + 1
                    || counts.contains_key(&expected)
                    || crate::recognition::is_author_note_heading(&chapter.title)
                    || crate::chapter_rules::ordered_parts(&segment[a].0.title, &chapter.title)
                    || crate::chapter_rules::ordered_parts(&chapter.title, &segment[b].0.title)
                {
                    continue;
                }
                let same_title = segment.iter().any(|c| {
                    c.1 == number
                        && c.0.source_line != chapter.source_line
                        && c.0.title.trim() == chapter.title.trim()
                });
                if same_title {
                    continue;
                }
                out.push(MisnumberedChapter {
                    entry_id: chapter.entry_id.clone(),
                    title: chapter.title.clone(),
                    source_line: chapter.source_line,
                    number,
                    expected,
                    unit,
                    duplicated: counts[&number] > 1,
                    previous: segment[a].0.clone(),
                    next: segment[b].0.clone(),
                });
            }
        }
        out
    }

    fn numbering_pairs(&self) -> Vec<(&ChapterSummary, &ChapterSummary, u32, u32)> {
        // 放错位置、可以归位的章不参与相邻比较：它带出的跳跃与回退合并到“章节放错位置”一条里。
        let misplaced: BTreeSet<u32> = self
            .misplaced_chapters()
            .iter()
            .map(|m| m.source_line)
            .collect();
        let mut pairs = Vec::new();
        for segment in self.numbering_segments() {
            let kept: Vec<_> = segment
                .into_iter()
                .filter(|c| !misplaced.contains(&c.0.source_line))
                .collect();
            for w in kept.windows(2) {
                pairs.push((w[0].0, w[1].0, w[0].1, w[1].1));
            }
        }
        // 原来按出现顺序产生；保持按后一章的源行排序。
        pairs.sort_by_key(|p| p.1.source_line);
        pairs
    }

    fn numbering_gaps(&self) -> Vec<(&ChapterSummary, &ChapterSummary, u32, u32)> {
        self.numbering_pairs()
            .into_iter()
            .filter_map(|(a, b, old, new)| {
                (new > old.saturating_add(1)).then_some((a, b, old + 1, new - 1))
            })
            // 跳过的章号全部在“允许的编号跳跃”里时不报。
            .filter(|(_, _, first, last)| {
                !self
                    .rules
                    .as_ref()
                    .is_some_and(|r| r.allows_number_gap(*first, *last))
            })
            .collect()
    }

    /// Build a deterministic, read-only repair plan from the immutable source snapshot.
    ///
    /// The plan contains evidence and explicitly declares that it writes nothing. Any
    /// future commit operation must revalidate this source id and revision before touching
    /// bytes; this method deliberately has no write path.
    pub fn repair_plan_json(&self, selected_json: &str) -> Result<String, ApiError> {
        let value: serde_json::Value = serde_json::from_str(selected_json).map_err(|_| {
            ApiError::new(
                ErrorCode::InvalidRule,
                "repair_plan",
                "select_known_findings",
            )
        })?;
        if value.get("kind").and_then(|v| v.as_str()) == Some("publication") {
            return Ok(crate::publication::prepare_output(self, selected_json)?.preview());
        }
        if value.get("kind").and_then(|v| v.as_str()) == Some("cleanup") {
            let plan = crate::cleanup::prepare(self, selected_json)?;
            // Refuse an unencodable plan before the user is asked to confirm it.
            plan.output(self)?;
            return Ok(plan.preview());
        }
        if let Some(kind) = value.get("kind").and_then(|v| v.as_str()) {
            if kind == "manual_batch" {
                return Ok(crate::manual_edit::prepare(self, selected_json)?.preview());
            }
            if !matches!(kind, "set_volume" | "rename_title") {
                return Err(ApiError::new(
                    ErrorCode::InvalidRule,
                    "repair_plan",
                    "use_set_volume_action",
                ));
            }
            let line = value
                .get("source_line")
                .and_then(|v| v.as_u64())
                .and_then(|line| u32::try_from(line).ok())
                .unwrap_or(0);
            let title = value
                .get(if kind == "rename_title" {
                    "title"
                } else {
                    "volume_title"
                })
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .trim();
            if line == 0
                || line > self.summary.line_count
                || title.is_empty()
                || title.len() > 4096
                || title.contains(['\r', '\n'])
                || !self
                    .chapters
                    .iter()
                    .any(|chapter| chapter.source_line == line)
            {
                return Err(ApiError::new(
                    ErrorCode::InvalidRule,
                    "repair_plan",
                    "confirm_volume_line_and_title",
                ));
            }
            let mut hash = Sha256::new();
            hash.update(b"manual-heading-plan-v2");
            hash.update(self.summary.source_id.as_bytes());
            hash.update(self.summary.revision.to_le_bytes());
            hash.update(selected_json.as_bytes());
            return Ok(serde_json::json!({
                "plan_id": format!("{:x}", hash.finalize()),
                "source_id": self.summary.source_id,
                "revision": self.summary.revision,
                "stage": "preview",
                "writes": false,
                "requires_confirmation": true,
                "selected_findings": ["number-reset"],
                "actions": [{"id":"manual-heading","finding_id":if kind == "rename_title" {"manual-title"} else {"number-reset"},"kind":kind,"before":self.chapters.iter().find(|c|c.source_line==line).map(|c|c.title.as_str()),"title":title,"auto_applicable":false,"requires_confirmation":true,"source_lines":[line]}],
                "source_unchanged": true
            }).to_string());
        }
        let selected_value = value
            .as_array()
            .cloned()
            .or_else(|| value.get("finding_ids").and_then(|v| v.as_array()).cloned())
            .ok_or_else(|| {
                ApiError::new(
                    ErrorCode::InvalidRule,
                    "repair_plan",
                    "select_known_findings",
                )
            })?;
        let mut selected = selected_value
            .iter()
            .filter_map(|item| item.as_str().map(str::to_owned))
            .collect::<Vec<_>>();
        if selected_value.len() != selected.len() {
            return Err(ApiError::new(
                ErrorCode::InvalidRule,
                "repair_plan",
                "select_known_findings",
            ));
        }
        selected.sort();
        selected.dedup();
        for id in &selected {
            if !matches!(
                id.as_str(),
                "duplicate-title"
                    | "duplicate-content"
                    | "prose-heading"
                    | "unrecognized-heading"
                    | "number-reset"
                    | "number-gap"
                    | "chapter-misplaced"
                    | "no-headings"
                    | "missing-heading-prefix"
                    | "heading-number-typo"
            ) {
                return Err(ApiError::new(
                    ErrorCode::InvalidRule,
                    "repair_plan",
                    "select_known_findings",
                ));
            }
        }

        let review = value
            .get("review")
            .map(|v| serde_json::from_value::<crate::review::Review>(v.clone()))
            .transpose()
            .map_err(|_| {
                ApiError::new(
                    ErrorCode::InvalidRule,
                    "repair_plan",
                    "review_current_findings",
                )
            })?;
        let suppressed = review
            .as_ref()
            .map(|r| r.suppressed(self))
            .transpose()?
            .unwrap_or_default();
        selected.retain(|id| !suppressed.contains(id) && self.check_enabled(id, None));
        let wants_duplicate = selected.iter().any(|id| id == "duplicate-title");
        let wants_reset = selected.iter().any(|id| id == "number-reset");
        let wants_no_headings = selected.iter().any(|id| id == "no-headings");
        let mut actions = Vec::new();
        if selected.iter().any(|id| id == "duplicate-content") {
            for group in crate::duplicate_blocks::find(self)? {
                for item in group.occurrences.iter().skip(1) {
                    actions.push(serde_json::json!({"id":format!("duplicate-content:{}",item.entry_id),"finding_id":"duplicate-content",
                        "title":format!("两处章节内容完全相同：{}",group.title),"entry_id":item.entry_id,
                        "source_lines":[group.occurrences[0].start_line,item.start_line],"auto_applicable":false,"requires_confirmation":true,
                        "evidence":"已逐字比较标题和整章正文，内容相同。请对照后选择保留；不会默认删除后面的章节。"}));
                }
            }
        }
        if selected.iter().any(|id| id == "prose-heading") {
            for chapter in self.prose_headings() {
                actions.push(serde_json::json!({"id":format!("prose-heading:{}",chapter.entry_id),
                    "finding_id":"prose-heading","kind":"manual_review","title":format!("这句正文被收入目录：{}",chapter.title),
                    "entry_id":chapter.entry_id,"source_lines":[chapter.source_line],"auto_applicable":false,
                    "requires_confirmation":true,"evidence":"这行更像正文句子或作者说明。核对上下文后可还原为正文；整句文字保留，不删除。"}));
            }
        }
        if selected.iter().any(|id| id == "unrecognized-heading") {
            for (line, title) in self.unrecognized_headings() {
                actions.push(serde_json::json!({"id":format!("unrecognized-heading:{line}"),
                    "finding_id":"unrecognized-heading","kind":"manual_review","title":format!("这行可能是章节标题：{title}"),
                    "source_lines":[line],"suggested_title":title,"auto_applicable":false,"requires_confirmation":true,
                    "evidence":"在正文中找到数字标题，请核对前后文后从此行建立章节。不会补写正文。"}));
            }
        }
        if wants_reset {
            for (previous, chapter, old, number) in
                self.numbering_pairs()
                    .into_iter()
                    .filter(|(a, b, old, new)| {
                        new < old
                            || (new == old
                                && (a.title.trim() != b.title.trim()
                                    || self.lines
                                        [a.source_line as usize..b.source_line as usize - 1]
                                        .iter()
                                        .any(|&(start, end)| {
                                            !self.text[start..end].trim().is_empty()
                                        }))
                                && !crate::chapter_rules::ordered_parts(&a.title, &b.title))
                    })
            {
                let unit = self.chapter_number(&chapter.title).unwrap().1;
                actions.push(serde_json::json!({"id":format!("number-reset:{}",chapter.entry_id),
                    "finding_id":"number-reset","kind":"mark_manual_review",
                    "subtype":if old==number {"repeated-number"}else{"number-reversal"},
                    "title":if old==number {format!("第{number}{unit}出现了两次")}else{format!("第{old}{unit}后出现了第{number}{unit}")},"auto_applicable":false,"requires_confirmation":true,
                    "source_lines":[previous.source_line,chapter.source_line],"entry_id":chapter.entry_id,
                    "before_title":previous.title,"after_title":chapter.title,
                    "evidence":"请核对这两个标题与正文，区分编号笔误、正常分段或顺序调整。仅有编号回退不足以判断新卷。"}));
            }
        }
        if selected.iter().any(|id| id == "heading-number-typo") {
            for c in crate::heading_typos::find(self) {
                actions.push(serde_json::json!({"id":format!("heading-number-typo:{}", c.source_line),"finding_id":"heading-number-typo","kind":"manual_review","title":"章节编号疑似错字，核对相邻章节后修订","auto_applicable":false,"requires_confirmation":true,"source_lines":[c.source_line],"suggested_title":c.title,"evidence":format!("原文：{}；前后标题源行 {} / {}，中间编号候选为 {}。仅修订所选标题，不替换正文。",c.before,c.previous_line,c.next_line,c.number)}));
            }
        }
        if selected.iter().any(|id| id == "chapter-misplaced") {
            for m in self.misplaced_chapters() {
                let unit = m.unit;
                let (target, lines) = match &m.anchor {
                    Some((_, title, line)) => {
                        (format!("移回“{title}”之后"), vec![*line, m.source_line])
                    }
                    None => (
                        format!("移到“{}”之前", m.first.1),
                        vec![m.source_line, m.first.2],
                    ),
                };
                actions.push(serde_json::json!({
                    "id":format!("chapter-misplaced:{}",m.entry_id),
                    "finding_id":"chapter-misplaced","kind":"move_chapter",
                    "title":format!("第{}{unit}放错了位置，可{target}",m.number),
                    "entry_id":m.entry_id,"auto_applicable":false,"requires_confirmation":true,
                    "source_lines":lines,"after_title":m.anchor.as_ref().map(|a|a.1.clone()),
                    "evidence":format!("这一章现在在{}，前后章节编号连续、按编号应在的位置没有别的章，原位确实空着。整章连同正文一起移回，不改标题和正文。",
                        m.current_after.as_ref().map(|t|format!("“{t}”之后")).unwrap_or_else(||"最前面".to_owned()))
                }));
            }
        }
        if selected.iter().any(|id| id == "number-gap") {
            for (before, after, first, last) in self.numbering_gaps() {
                actions.push(serde_json::json!({
                    "id":format!("number-gap:{}",after.entry_id),
                    "finding_id":"number-gap", "kind":"mark_manual_review",
                    "title":format!("第{}{}后直接到了第{}{}",first-1,self.chapter_number(&before.title).unwrap().1,last+1,self.chapter_number(&after.title).unwrap().1),
                    "before_title":before.title,"after_title":after.title,
                    "auto_applicable":false,"requires_confirmation":true,
                    "source_lines":[before.source_line,after.source_line],
                    "entry_id":after.entry_id,"number_range":[first,last],
                    "evidence":format!("中间没有识别到{}的标题。请对照前章末尾和后章开头：若标题写法不同，可从实际标题行建立章节；若只是编号写错，可改标题；若原文缺少内容，需要补全原稿后重新导入；用书源插件下载的书，可在插件里重新下载或换书源补下这几章。",if first==last {format!("第{first}章")} else {format!("第{first}至{last}章")})
                }));
            }
        }
        let duplicate_lines = self.duplicate_title_lines();
        let missing_prefix: std::collections::BTreeSet<u32> = self
            .missing_prefix_chapters()
            .iter()
            .map(|c| c.source_line)
            .collect();
        for chapter in &self.chapters {
            let title = chapter.title.trim().to_owned();
            if selected.iter().any(|id| id == "missing-heading-prefix")
                && missing_prefix.contains(&chapter.source_line)
            {
                actions.push(serde_json::json!({
                    "id": format!("missing-heading-prefix:{}", chapter.entry_id),
                    "finding_id": "missing-heading-prefix", "kind": "manual_review",
                    "title": "编号标题未带“第”，核对后可保留或改名",
                    "auto_applicable": false, "requires_confirmation": true,
                    "source_lines": [chapter.source_line], "entry_id": chapter.entry_id,
                    "evidence": format!("当前规则已识别此标题：{}；这可能是作者的编号风格，不自动改写。", title),
                }));
            }
            if wants_duplicate && duplicate_lines.contains(&chapter.source_line) {
                actions.push(serde_json::json!({
                    "id": format!("duplicate-title:{}", chapter.entry_id),
                    "finding_id": "duplicate-title",
                    "kind": "remove_duplicate_title_line",
                    "title": "排除连续重复标题行",
                    "auto_applicable": true,
                    "requires_confirmation": true,
                    "source_lines": [chapter.source_line],
                    "entry_id": chapter.entry_id,
                    "evidence": format!("与上一条标题完全相同：{}", title),
                }));
            }
        }
        if wants_no_headings && self.chapters.is_empty() {
            actions.push(serde_json::json!({
                "id": "no-headings:source",
                "finding_id": "no-headings",
                "kind": "manual_review",
                "title": "未识别章节标题，转人工检查",
                "auto_applicable": false,
                "requires_confirmation": true,
                "source_lines": [],
                "evidence": "当前规则没有识别到任何章节标题；不会猜测或补写目录。",
            }));
        }
        actions.retain(|action| {
            self.check_enabled(
                action["finding_id"].as_str().unwrap_or(""),
                action["subtype"].as_str(),
            ) && !suppressed
                .iter()
                .any(|id| action["id"].as_str() == Some(id.as_str()))
        });
        let selected_text = selected.join(",");
        let mut plan_hash = Sha256::new();
        plan_hash.update(b"repair-plan-v2-byte-preserving");
        plan_hash.update(self.summary.source_id.as_bytes());
        plan_hash.update(self.summary.revision.to_le_bytes());
        plan_hash.update(selected_text.as_bytes());
        if let Some(review) = &review {
            plan_hash.update(serde_json::to_vec(review).expect("review"));
        }
        let plan_id = format!("{:x}", plan_hash.finalize());
        Ok(serde_json::json!({
            "plan_id": plan_id,
            "source_id": self.summary.source_id,
            "revision": self.summary.revision,
            "stage": "preview",
            "writes": false,
            "requires_confirmation": !actions.is_empty(),
            "selected_findings": selected,
            "suppressed_findings": suppressed,
            "actions": actions,
            "source_unchanged": true,
        })
        .to_string())
    }

    /// Prepare a new encoded byte sequence for the only currently safe automatic
    /// action. This does not touch the source and rejects manual-only findings.
    pub fn repair_output_json(&self, selected_json: &str) -> Result<Vec<u8>, ApiError> {
        let value: serde_json::Value = serde_json::from_str(selected_json).map_err(|_| {
            ApiError::new(
                ErrorCode::InvalidRule,
                "repair_output",
                "confirm_known_actions",
            )
        })?;
        let action_kind = value.get("kind").and_then(|v| v.as_str());
        if action_kind == Some("publication") {
            return crate::publication::prepare_output(self, selected_json)?.output(self);
        }
        if action_kind == Some("cleanup") {
            return crate::cleanup::prepare(self, selected_json)?.output(self);
        }
        if action_kind == Some("manual_batch") {
            return crate::manual_edit::prepare(self, selected_json)?.output(self);
        }
        if matches!(action_kind, Some("set_volume" | "rename_title")) {
            // Output must enforce exactly the same validation as preview.
            self.repair_plan_json(selected_json)?;
            let rename = action_kind == Some("rename_title");
            let line = value
                .get("source_line")
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as usize;
            let title = value
                .get(if rename { "title" } else { "volume_title" })
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .trim();
            let Some(&(start, end)) = self.lines.get(line.saturating_sub(1)) else {
                return Err(ApiError::new(
                    ErrorCode::InvalidRule,
                    "repair_output",
                    "confirm_volume_line_and_title",
                ));
            };
            if title.is_empty()
                || !self
                    .chapters
                    .iter()
                    .any(|chapter| chapter.source_line as usize == line)
            {
                return Err(ApiError::new(
                    ErrorCode::InvalidRule,
                    "repair_output",
                    "confirm_volume_line_and_title",
                ));
            }
            let newline = self
                .text
                .get(end..)
                .map(|tail| {
                    if tail.starts_with("\r\n") {
                        "\r\n"
                    } else if tail.starts_with('\n') {
                        "\n"
                    } else if tail.starts_with('\r') {
                        "\r"
                    } else {
                        "\n"
                    }
                })
                .unwrap_or("\n");
            let kind = match self.summary.encoding.as_str() {
                "utf-8" => EncodingKind::Utf8,
                "utf-16le" => EncodingKind::Utf16Le,
                "utf-16be" => EncodingKind::Utf16Be,
                "utf-32le" => EncodingKind::Utf32Le,
                "utf-32be" => EncodingKind::Utf32Be,
                "cp936" => EncodingKind::Cp936,
                _ => {
                    return Err(ApiError::new(
                        ErrorCode::InvalidEncoding,
                        "repair_output",
                        "reimport_source",
                    ));
                }
            };
            let mut edited = String::with_capacity(self.text.len() + title.len() + newline.len());
            edited.push_str(&self.text[..start]);
            edited.push_str(title);
            if rename {
                edited.push_str(&self.text[end..]);
            } else {
                edited.push_str(newline);
                edited.push_str(&self.text[start..]);
            }
            return encode(&edited, kind, self.summary.bom_length > 0);
        }
        let plan: serde_json::Value =
            serde_json::from_str(&self.repair_plan_json(selected_json)?).expect("internal plan");
        let selected = plan["selected_findings"]
            .as_array()
            .expect("selected findings");
        if selected
            .iter()
            .any(|item| item.as_str() != Some("duplicate-title"))
        {
            return Err(ApiError::new(
                ErrorCode::InvalidRule,
                "repair_output",
                "confirm_only_safe_actions",
            ));
        }
        if selected.is_empty() {
            return Ok(self.raw().to_vec());
        }
        let remove_lines = plan["actions"]
            .as_array()
            .expect("actions")
            .iter()
            .filter(|a| a["kind"] == "remove_duplicate_title_line")
            .filter_map(|a| a["source_lines"][0].as_u64().map(|n| n as u32))
            .collect::<std::collections::BTreeSet<_>>();
        if remove_lines.is_empty() {
            return Ok(self.raw().to_vec());
        }
        // Copy original byte spans instead of re-encoding retained content. This
        // preserves CP936 aliases, BOM, mixed line endings and the final newline.
        let width = match self.summary.encoding.as_str() {
            "utf-16le" | "utf-16be" => 2,
            "utf-32le" | "utf-32be" => 4,
            _ => 1,
        };
        let big = self.summary.encoding.ends_with("be");
        let unit = |offset: usize| -> u32 {
            let slice = &self.raw()[offset..offset + width];
            if big {
                slice.iter().fold(0, |v, b| (v << 8) | *b as u32)
            } else {
                slice.iter().rev().fold(0, |v, b| (v << 8) | *b as u32)
            }
        };
        let raw = self.raw();
        let mut output = raw[..self.summary.bom_length as usize].to_vec();
        let mut start = self.summary.bom_length as usize;
        let mut cursor = start;
        let mut line = 1;
        while cursor < raw.len() {
            let current = unit(cursor);
            cursor += width;
            if current == 13 || current == 10 {
                if current == 13 && cursor < raw.len() && unit(cursor) == 10 {
                    cursor += width;
                }
                if !remove_lines.contains(&line) {
                    output.extend_from_slice(&raw[start..cursor]);
                }
                start = cursor;
                line += 1;
            }
        }
        if !remove_lines.contains(&line) {
            output.extend_from_slice(&raw[start..]);
        }
        Ok(output)
    }

    pub fn summary(&self) -> BookSummary {
        self.summary.clone()
    }

    pub fn read_page(&self, cursor: SourceCursor, limit: u32) -> Result<SourcePage, ApiError> {
        if limit == 0 || limit > MAX_PAGE_LINES {
            return Err(ApiError::new(
                ErrorCode::InvalidLimit,
                "read_page",
                "use_1_to_200_lines",
            ));
        }
        let text = &self.text;
        let mut line_index = cursor.line_index as usize;
        let mut column = cursor.utf8_column as usize;
        if line_index > self.lines.len() || (line_index == self.lines.len() && column != 0) {
            return Err(ApiError::new(
                ErrorCode::InvalidCursor,
                "read_page",
                "refresh_page",
            ));
        }
        let mut items = Vec::new();
        let mut text_bytes = 0;
        while line_index < self.lines.len() && items.len() < limit as usize {
            let (start, end) = self.lines[line_index];
            let line = &text[start..end];
            if column > line.len() || !line.is_char_boundary(column) {
                return Err(ApiError::new(
                    ErrorCode::InvalidCursor,
                    "read_page",
                    "use_returned_cursor",
                ));
            }
            let mut take_end = line.len().min(column + MAX_PAGE_BYTES - text_bytes);
            while !line.is_char_boundary(take_end) {
                take_end -= 1;
            }
            if take_end == column && column < line.len() {
                break;
            }
            let continues = take_end < line.len();
            items.push(TextFragment {
                line_number: line_index as u32 + 1,
                utf8_column: column as u32,
                text: line[column..take_end].to_owned(),
                continues,
            });
            text_bytes += take_end - column;
            if continues {
                column = take_end;
                break;
            }
            line_index += 1;
            column = 0;
            if text_bytes == MAX_PAGE_BYTES {
                break;
            }
        }
        Ok(SourcePage {
            source_id: self.summary.source_id.clone(),
            revision: 1,
            items,
            next_cursor: (line_index < self.lines.len()).then_some(SourceCursor {
                line_index: line_index as u32,
                utf8_column: column as u32,
            }),
            text_bytes: text_bytes as u32,
        })
    }

    pub fn chapter_page(&self, offset: u32, limit: u32) -> Result<ChapterPage, ApiError> {
        if limit == 0 || limit > MAX_PAGE_LINES {
            return Err(ApiError::new(
                ErrorCode::InvalidLimit,
                "chapter_page",
                "use_1_to_200_items",
            ));
        }
        if offset as usize > self.chapters.len() {
            return Err(ApiError::new(
                ErrorCode::InvalidCursor,
                "chapter_page",
                "refresh_page",
            ));
        }
        let end = (offset as usize + limit as usize).min(self.chapters.len());
        Ok(ChapterPage {
            source_id: self.summary.source_id.clone(),
            revision: 1,
            items: self.chapters[offset as usize..end].to_vec(),
            total: self.chapters.len() as u32,
            next_offset: (end < self.chapters.len()).then_some(end as u32),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_snapshots_match_utf8_snapshots_exactly() {
        for text in [
            "",
            "\n",
            "\r",
            "\r\n",
            "第一章 甲\n正文\n",
            "第一章 甲\r\n正文\r\n第二章 乙",
            "第一章 甲\r正文\n\n\r\r\n第二章 乙\n",
            "没有换行也没有章节",
            "\u{feff}第一章 带标记\n正文\n",
            "\u{feff}\u{feff}第一章 两个标记\n",
            "中间的\u{feff}标记\n第一章 甲\n",
        ] {
            let old =
                SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
            let new = SourceSnapshot::from_text(text.to_owned(), RULE_ID).unwrap();
            assert_eq!(new.decoded_text(), old.decoded_text(), "{text:?}");
            assert_eq!(
                new.decoded_line_ranges(),
                old.decoded_line_ranges(),
                "{text:?}"
            );
            assert_eq!(new.original_bytes(), old.original_bytes(), "{text:?}");
            assert_eq!(new.original_bytes(), text.as_bytes(), "{text:?}");
            assert_eq!(new.summary().source_id, old.summary().source_id, "{text:?}");
            assert_eq!(
                new.summary().byte_length,
                old.summary().byte_length,
                "{text:?}"
            );
            assert_eq!(
                new.summary().line_count,
                old.summary().line_count,
                "{text:?}"
            );
            assert_eq!(
                new.summary().bom_length,
                old.summary().bom_length,
                "{text:?}"
            );
            assert_eq!(new.into_text(), text, "{text:?}");
        }
    }

    #[test]
    fn line_ranges_cover_every_line_ending() {
        let source =
            SourceSnapshot::from_utf8(b"a\r\nb\rc\n\nd".to_vec(), RULE_ID, || false).unwrap();
        assert_eq!(
            source.decoded_line_ranges(),
            [(0, 1), (3, 4), (5, 6), (7, 7), (8, 9)]
        );
    }

    #[test]
    fn utf8_text_is_kept_once_and_other_encodings_keep_their_bytes() {
        let text = "第一章 甲\n正文\n".repeat(100);
        let plain = SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        assert_eq!(plain.original_bytes(), text.as_bytes());
        assert!(plain.bytes.is_empty(), "不存第二份");
        let mut marked = vec![0xef, 0xbb, 0xbf];
        marked.extend_from_slice(text.as_bytes());
        let bom = SourceSnapshot::from_utf8(marked.clone(), RULE_ID, || false).unwrap();
        assert_eq!(bom.original_bytes(), marked, "带 BOM 的原文要原样留着");
        assert_eq!(bom.decoded_text(), text);
        let cp936 =
            crate::encoding::encode(&text, crate::encoding::EncodingKind::Cp936, false).unwrap();
        let wide = SourceSnapshot::from_bytes(
            cp936.clone(),
            crate::encoding::EncodingMode::Cp936,
            RULE_ID,
            || false,
        )
        .unwrap();
        assert_eq!(wide.original_bytes(), cp936);
        assert_eq!(wide.decoded_text(), text);
    }

    #[test]
    fn utf8_bom_mixed_endings_and_final_line_preserve_exact_bytes() {
        let original = "\u{feff}第一章 初见😀\r\n汉字𠮷e\u{301}\r\n\r第二章 再见\n尾行"
            .as_bytes()
            .to_vec();
        let source = SourceSnapshot::from_utf8(original.clone(), RULE_ID, || false).unwrap();
        assert_eq!(source.original_bytes(), original);
        assert_eq!(source.summary().line_count, 5);
        assert_eq!(source.summary().chapter_count, 2);
        let first = source.read_page(SourceCursor::default(), 2).unwrap();
        assert_eq!(first.items[1].text, "汉字𠮷e\u{301}");
        let second = source.read_page(first.next_cursor.unwrap(), 200).unwrap();
        assert_eq!(second.items.last().unwrap().text, "尾行");
        assert!(second.next_cursor.is_none());
    }

    #[test]
    fn huge_unicode_line_is_bounded_and_can_be_reassembled() {
        let original = "汉😀𠮷e\u{301}".repeat(50000);
        let source =
            SourceSnapshot::from_utf8(original.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let mut cursor = SourceCursor::default();
        let mut rebuilt = String::new();
        loop {
            let page = source.read_page(cursor, 200).unwrap();
            assert!(page.text_bytes as usize <= MAX_PAGE_BYTES);
            for fragment in page.items {
                rebuilt.push_str(&fragment.text);
            }
            match page.next_cursor {
                Some(next) => cursor = next,
                None => break,
            }
        }
        assert_eq!(rebuilt, original);
        assert_eq!(
            source
                .read_page(
                    SourceCursor {
                        line_index: 0,
                        utf8_column: 1
                    },
                    20
                )
                .unwrap_err()
                .code,
            ErrorCode::InvalidCursor
        );
    }

    #[test]
    fn malformed_encoding_missing_rules_and_cancellation_are_errors() {
        assert_eq!(
            SourceSnapshot::from_utf8(vec![0xff], RULE_ID, || false)
                .unwrap_err()
                .code,
            ErrorCode::InvalidUtf8
        );
        assert_eq!(
            SourceSnapshot::from_utf8(vec![], "", || false)
                .unwrap_err()
                .code,
            ErrorCode::UnsupportedRule
        );
        assert_eq!(
            SourceSnapshot::from_utf8(vec![], RULE_ID, || true)
                .unwrap_err()
                .code,
            ErrorCode::Cancelled
        );
        let empty = SourceSnapshot::from_utf8(vec![], RULE_ID, || false).unwrap();
        assert_eq!(empty.summary().line_count, 0);
        assert!(
            empty
                .read_page(SourceCursor::default(), 1)
                .unwrap()
                .items
                .is_empty()
        );
    }
}

#[cfg(test)]
mod diagnostic_tests {
    use super::*;
    #[test]
    fn diagnostic_is_bound_to_source_and_finds_duplicate_and_reset() {
        let source = SourceSnapshot::from_utf8(
            "第1章 甲\n正文\n第2章 乙\n第2章 乙\n第1章 丙\n"
                .as_bytes()
                .to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let value: serde_json::Value = serde_json::from_str(&source.diagnostic_json()).unwrap();
        assert_eq!(value["source_id"].as_str().unwrap().len(), 64);
        assert_eq!(value["revision"], 1);
        assert_eq!(value["findings"][0]["id"], "duplicate-title");
        assert_eq!(value["findings"][1]["id"], "number-reset");
    }
    #[test]
    fn diagnostic_marks_empty_heading_set_as_error() {
        let source =
            SourceSnapshot::from_utf8("只是正文\n没有章节".as_bytes().to_vec(), RULE_ID, || false)
                .unwrap();
        let value: serde_json::Value = serde_json::from_str(&source.diagnostic_json()).unwrap();
        assert_eq!(value["findings"][0]["severity"], "error");
    }

    #[test]
    fn repair_plan_is_read_only_and_contains_line_evidence() {
        let source = SourceSnapshot::from_utf8(
            "第一卷 起\n第十章 甲\n第九章 乙\n第二卷 续\n第一章 丙\n第一章 丙\n"
                .as_bytes()
                .to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let value: serde_json::Value = serde_json::from_str(
            &source
                .repair_plan_json(r#"["duplicate-title","number-reset"]"#)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(value["stage"], "preview");
        assert_eq!(value["writes"], false);
        assert_eq!(value["source_unchanged"], true);
        assert_eq!(value["actions"].as_array().unwrap().len(), 2);
        assert_eq!(value["actions"][0]["finding_id"], "number-reset");
        assert_eq!(value["actions"][0]["source_lines"][0], 2);
        assert_eq!(value["actions"][1]["finding_id"], "duplicate-title");
        assert_eq!(value["actions"][1]["source_lines"][0], 6);
    }

    #[test]
    fn repair_plan_rejects_unknown_selection() {
        let source =
            SourceSnapshot::from_utf8("第一章 甲".as_bytes().to_vec(), RULE_ID, || false).unwrap();
        assert_eq!(
            source.repair_plan_json(r#"["invented"]"#).unwrap_err().code,
            ErrorCode::InvalidRule
        );
    }

    #[test]
    fn duplicate_output_preserves_source_and_line_endings() {
        let original = "第一章 甲\r\n正文\n第二章 乙\n第三章 丙";
        let source =
            SourceSnapshot::from_utf8(original.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let output = source.repair_output_json(r#"["duplicate-title"]"#).unwrap();
        assert_eq!(String::from_utf8(output).unwrap(), original);

        let source = SourceSnapshot::from_utf8(
            "第一章 甲\r\n第一章 甲\n第二章 乙".as_bytes().to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let output = source.repair_output_json(r#"["duplicate-title"]"#).unwrap();
        assert_eq!(String::from_utf8(output).unwrap(), "第一章 甲\r\n第二章 乙");
        assert_eq!(
            source.original_bytes(),
            "第一章 甲\r\n第一章 甲\n第二章 乙".as_bytes()
        );
    }

    #[test]
    fn manual_only_findings_cannot_create_output() {
        let source =
            SourceSnapshot::from_utf8("第一章 甲".as_bytes().to_vec(), RULE_ID, || false).unwrap();
        assert_eq!(
            source
                .repair_output_json(r#"["number-reset"]"#)
                .unwrap_err()
                .code,
            ErrorCode::InvalidRule
        );
    }

    #[test]
    fn same_title_with_body_is_not_an_automatic_deletion() {
        let text = "第一章 甲\r\n独有正文\n第一章 甲\n另一段正文\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        assert!(source.duplicate_title_lines().is_empty());
        assert_eq!(
            source.repair_output_json(r#"["duplicate-title"]"#).unwrap(),
            text.as_bytes()
        );
    }

    #[test]
    fn duplicate_removal_preserves_retained_bytes_in_all_encodings() {
        use crate::encoding::encode;
        for kind in [
            EncodingKind::Utf8,
            EncodingKind::Utf16Le,
            EncodingKind::Utf16Be,
            EncodingKind::Utf32Le,
            EncodingKind::Utf32Be,
            EncodingKind::Cp936,
        ] {
            let bom = kind != EncodingKind::Cp936;
            let bytes = encode("第一章 甲\r\n \n第一章 甲\r正文\n", kind, bom).unwrap();
            let expected = encode("第一章 甲\r\n \n正文\n", kind, bom).unwrap();
            let source =
                SourceSnapshot::from_bytes(bytes.clone(), EncodingMode::Auto, RULE_ID, || false)
                    .unwrap();
            assert_eq!(source.repair_output_json("[]").unwrap(), bytes);
            assert_eq!(
                source.repair_output_json(r#"["duplicate-title"]"#).unwrap(),
                expected
            );
            assert_eq!(source.original_bytes(), bytes);
        }
    }

    #[test]
    fn manual_title_preview_and_output_reject_injection_and_preserve_body() {
        let source = SourceSnapshot::from_utf8(
            "第一章 旧名\r\n正文甲\n第二章 乙\r尾文".as_bytes().to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let request = r#"{"kind":"rename_title","source_line":1,"title":"第一章 新名"}"#;
        let plan: serde_json::Value =
            serde_json::from_str(&source.repair_plan_json(request).unwrap()).unwrap();
        assert_eq!(plan["actions"][0]["before"], "第一章 旧名");
        assert_eq!(plan["actions"][0]["kind"], "rename_title");
        assert_eq!(
            source.repair_output_json(request).unwrap(),
            "第一章 新名\r\n正文甲\n第二章 乙\r尾文".as_bytes()
        );
        for request in [
            r#"{"kind":"rename_title","source_line":2,"title":"侵入正文"}"#,
            r#"{"kind":"rename_title","source_line":1,"title":"一行\n两行"}"#,
            r#"{"kind":"set_volume","source_line":1,"volume_title":"一卷\n注入"}"#,
            r#"{"kind":"rename_title","source_line":4294967297,"title":"溢出"}"#,
        ] {
            assert!(source.repair_plan_json(request).is_err());
            assert!(source.repair_output_json(request).is_err());
        }
    }

    #[test]
    fn manual_volume_plan_inserts_only_user_named_boundary() {
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n第二章 乙\n".as_bytes().to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let action = r#"{"kind":"set_volume","source_line":2,"volume_title":"人工确认卷"}"#;
        let plan: serde_json::Value =
            serde_json::from_str(&source.repair_plan_json(action).unwrap()).unwrap();
        assert_eq!(plan["writes"], false);
        let output = String::from_utf8(source.repair_output_json(action).unwrap()).unwrap();
        assert_eq!(output, "第一章 甲\n人工确认卷\n第二章 乙\n");
        assert_eq!(source.original_bytes(), "第一章 甲\n第二章 乙\n".as_bytes());
    }
}

pub fn numbered_heading(title: &str) -> Option<(u32, char)> {
    let text = title
        .trim()
        .trim_start_matches(['【', '[', '（', '('])
        .trim();
    let text = text.strip_prefix('第').unwrap_or(text).trim_start();
    let end = text
        .char_indices()
        .find(|(_, c)| matches!(c, '章' | '回' | '节' | '卷' | '部' | '篇' | '集'))?
        .0;
    let number = parse_number(text[..end].trim())?;
    Some((number, text[end..].chars().next()?))
}

pub fn missing_heading_prefix(title: &str) -> bool {
    let text = title
        .trim()
        .trim_start_matches(['【', '[', '（', '('])
        .trim_start();
    !text.starts_with('第')
        && numbered_heading(text).is_some_and(|(_, marker)| matches!(marker, '章' | '回' | '节'))
}

// Reject unknown/malformed numeral sequences rather than inventing a number.
pub(crate) fn parse_number(text: &str) -> Option<u32> {
    let normalized: String = text
        .chars()
        .map(|ch| match ch {
            '壹' => '一',
            '贰' | '貳' => '二',
            '叁' | '參' => '三',
            '肆' => '四',
            '伍' => '五',
            '陆' | '陸' => '六',
            '柒' => '七',
            '捌' => '八',
            '玖' => '九',
            '拾' => '十',
            '佰' => '百',
            '仟' => '千',
            _ => ch,
        })
        .collect();
    let text = normalized.as_str();
    fn digit(c: char) -> Option<u32> {
        match c {
            '零' | '〇' => Some(0),
            '一' => Some(1),
            '二' | '两' | '兩' => Some(2),
            '三' => Some(3),
            '四' => Some(4),
            '五' => Some(5),
            '六' => Some(6),
            '七' => Some(7),
            '八' => Some(8),
            '九' => Some(9),
            '０'..='９' => Some(c as u32 - '０' as u32),
            _ => c.to_digit(10),
        }
    }
    if text.is_empty() || text.chars().count() > 16 {
        return None;
    }
    if text.chars().all(|c| digit(c).is_some()) {
        return text
            .chars()
            .try_fold(0u32, |n, c| n.checked_mul(10)?.checked_add(digit(c)?));
    }
    let (mut total, mut section, mut pending, mut last_unit) = (0u32, 0u32, None, 10000u32);
    let mut had_wan = false;
    for c in text.chars() {
        if let Some(n) = digit(c) {
            if pending.is_some_and(|v| v != 0) {
                return None;
            }
            pending = Some(n);
            continue;
        }
        let unit = match c {
            '十' => 10,
            '百' => 100,
            '千' => 1000,
            '万' | '萬' => 10000,
            _ => return None,
        };
        if unit == 10000 {
            if had_wan {
                return None;
            }
            section = section.checked_add(pending.take().unwrap_or(0))?;
            if section == 0 {
                return None;
            }
            total = section.checked_mul(10000)?;
            section = 0;
            last_unit = 10000;
            had_wan = true;
        } else {
            if unit >= last_unit {
                return None;
            }
            let n = match pending.take() {
                Some(n) if n > 0 => n,
                None if unit == 10 && section == 0 => 1,
                _ => return None,
            };
            section = section.checked_add(n.checked_mul(unit)?)?;
            last_unit = unit;
        }
    }
    total
        .checked_add(section)?
        .checked_add(pending.unwrap_or(0))
}

#[cfg(test)]
mod numeral_diagnostic_tests {
    use super::*;
    #[test]
    fn numbering_gap_is_evidence_only_and_respects_boundaries() {
        let source = SourceSnapshot::from_utf8(
            "第1卷 上\n第49章 前\n原文甲\n第61章 后\n原文乙\n第2卷 下\n第90章 起\n第一节 小节\n第91章 续\n".as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let diagnostic: serde_json::Value =
            serde_json::from_str(&source.diagnostic_json()).unwrap();
        let gap = diagnostic["findings"]
            .as_array()
            .unwrap()
            .iter()
            .find(|f| f["id"] == "number-gap")
            .unwrap();
        assert_eq!(gap["count"], 1);
        let plan: serde_json::Value =
            serde_json::from_str(&source.repair_plan_json(r#"["number-gap"]"#).unwrap()).unwrap();
        assert_eq!(plan["actions"].as_array().unwrap().len(), 1);
        let action = &plan["actions"][0];
        assert_eq!(action["kind"], "mark_manual_review");
        assert_eq!(action["auto_applicable"], false);
        assert_eq!(action["source_lines"], serde_json::json!([2, 4]));
        assert_eq!(action["number_range"], serde_json::json!([50, 60]));
        assert_eq!(plan["writes"], false);
        assert!(source.repair_output_json(r#"["number-gap"]"#).is_err());
    }
    #[test]
    fn chinese_and_fullwidth_numbers_are_checked_with_markers() {
        for (text, n) in [
            ("十", 10),
            ("十二", 12),
            ("一百零二", 102),
            ("一千二百三十四", 1234),
            ("一万零三", 10003),
            ("一〇二", 102),
            ("１２", 12),
        ] {
            assert_eq!(parse_number(text), Some(n), "{text}");
        }
        for text in ["", "十百", "一二十", "万", "十十", "一万万"] {
            assert_eq!(parse_number(text), None);
        }
        assert_eq!(numbered_heading("【第一百章 标题】"), Some((100, '章')));
        assert_eq!(numbered_heading("第12个苹果"), None);
    }
    #[test]
    fn volumes_reset_comparison_but_chinese_regression_is_reported() {
        let source = SourceSnapshot::from_utf8(
            "第一卷 起
第十章 甲
第二卷 续
第一章 乙
第三章 丙
第二章 丁"
                .as_bytes()
                .to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let value: serde_json::Value = serde_json::from_str(&source.diagnostic_json()).unwrap();
        assert_eq!(value["findings"][0]["id"], "number-reset");
        assert_eq!(value["findings"][0]["count"], 1);
    }

    #[test]
    fn missing_prefix_is_reviewable_style_not_automatic_repair() {
        let text = "第一章 正常\n正文\n二章 风格\n九节鞭、三节棍，随意变换\n【三回 夜雨】\n第一百一十久章 疑似错字\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let diagnostic: serde_json::Value =
            serde_json::from_str(&source.diagnostic_json()).unwrap();
        let finding = diagnostic["findings"]
            .as_array()
            .unwrap()
            .iter()
            .find(|f| f["id"] == "missing-heading-prefix")
            .unwrap();
        assert_eq!(finding["count"], 2);
        let request = r#"["missing-heading-prefix"]"#;
        let plan: serde_json::Value =
            serde_json::from_str(&source.repair_plan_json(request).unwrap()).unwrap();
        let actions = plan["actions"].as_array().unwrap();
        assert_eq!(actions.len(), 2);
        assert_eq!(actions[0]["source_lines"], serde_json::json!([3]));
        assert_eq!(actions[1]["source_lines"], serde_json::json!([5]));
        assert!(actions.iter().all(|a| a["auto_applicable"] == false));
        assert!(source.repair_output_json(request).is_err());
        let mut review = crate::review::Review::default();
        let report = review.report(&source).unwrap();
        review
            .set(
                &source,
                actions[0]["id"].as_str().unwrap(),
                report["evidence_id"].as_str().unwrap(),
                Some(crate::review::Decision::ConfirmedNormal),
                "作者风格".into(),
            )
            .unwrap();
        let reviewed: serde_json::Value = serde_json::from_str(
            &source
                .repair_plan_json(
                    &serde_json::json!({"finding_ids":["missing-heading-prefix"],"review":review})
                        .to_string(),
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(reviewed["actions"].as_array().unwrap().len(), 1);
        assert_eq!(source.original_bytes(), text.as_bytes());
    }
}
