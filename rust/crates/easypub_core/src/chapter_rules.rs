//! One versioned rule snapshot drives recognition, numbering and re-recognition.
use crate::{
    ApiError, ErrorCode,
    recognition::{self, NumericRule},
    source::{SourceSnapshot, parse_number},
    structure::{Override, Role},
};
use regex::Regex;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct RuleSet {
    pub version: u32,
    pub origin: String,
    pub chapter_pattern: String,
    pub hierarchy: bool,
    pub volume_pattern: String,
    pub level_chapter_pattern: String,
    pub section_pattern: String,
    pub numeric: bool,
    pub numeric_pattern: String,
    pub numeric_minimum_body_lines: u16,
    pub normalize_numeric_titles: bool,
    pub number_corrections: String,
    /// 非标题词库（V12）：每行一条，命中的行永远不算标题；`re:` 开头为正则。
    /// 为空时不参与序列化，已有规则的指纹不变。
    #[serde(skip_serializing_if = "String::is_empty")]
    pub non_heading: String,
    /// 标题词库：命中的行按章节识别（非标题词库优先）。
    #[serde(skip_serializing_if = "String::is_empty")]
    pub force_heading: String,
    /// 允许重复的标题（V17，CH-258）：每行一条，命中的相邻同名标题不再报“连续重复标题”。
    #[serde(skip_serializing_if = "String::is_empty")]
    pub allowed_duplicate_titles: String,
    /// 允许的编号跳跃（CH-259）：章号或范围，如 9、101-104；跳过的章号全部在列表里时才不报。
    #[serde(skip_serializing_if = "String::is_empty")]
    pub allowed_number_gaps: String,
    /// 标题后缀清理（CH-260）：每行一条，标题以它结尾时去掉；只改标题，不动正文。
    #[serde(skip_serializing_if = "String::is_empty")]
    pub title_suffixes: String,
}
impl Default for RuleSet {
    fn default() -> Self {
        Self {
            version: 2,
            origin: "builtin".into(),
            chapter_pattern: String::new(),
            hierarchy: true,
            volume_pattern: String::new(),
            level_chapter_pattern: String::new(),
            section_pattern: String::new(),
            numeric: false,
            numeric_pattern: String::new(),
            numeric_minimum_body_lines: 5,
            normalize_numeric_titles: false,
            number_corrections: "久=九".into(),
            non_heading: String::new(),
            force_heading: String::new(),
            allowed_duplicate_titles: String::new(),
            allowed_number_gaps: String::new(),
            title_suffixes: String::new(),
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Preset {
    pub name: String,
    pub rules: RuleSet,
}
#[derive(Clone, Debug, Serialize)]
pub struct Match {
    /// Attribution only; excluded from persisted recognition data.
    #[serde(skip)]
    pub rule_id: &'static str,
    pub role: Role,
    pub number: Option<u32>,
    pub marker: Option<char>,
    pub title: String,
    pub numeric: bool,
}
#[derive(Debug)]
pub struct CompiledRules {
    pub rules: RuleSet,
    chapter: Option<Regex>,
    volume: Option<Regex>,
    level_chapter: Option<Regex>,
    section: Option<Regex>,
    pub numeric: NumericRule,
    non_heading: Vec<Phrase>,
    force_heading: Vec<Phrase>,
    allowed_duplicates: Vec<Phrase>,
    allowed_gaps: Vec<(u32, u32)>,
    suffixes: Vec<Suffix>,
}

/// 标题后缀清理的一条：普通文字须在标题末尾，`re:` 开头的正则须匹配到标题末尾。
#[derive(Debug)]
enum Suffix {
    Text(String),
    Pattern(Regex),
}

/// 词库中的一条：普通文字按“包含”匹配，`re:` 开头按正则匹配。
#[derive(Debug)]
enum Phrase {
    Contains(String),
    Pattern(Regex),
}
impl Phrase {
    fn matches(&self, text: &str) -> bool {
        match self {
            Self::Contains(v) => text.contains(v.as_str()),
            Self::Pattern(r) => r.is_match(text),
        }
    }
}

fn phrases(value: &str, field: &str) -> Result<Vec<Phrase>, ApiError> {
    if value.len() > 16384 || value.contains('\0') {
        return Err(invalid(field, "最多16384字节，不能包含空字符"));
    }
    let mut result = Vec::new();
    for line in value.lines().map(str::trim).filter(|v| !v.is_empty()) {
        if line.chars().count() > 256 {
            return Err(invalid(field, "每条最多256字"));
        }
        if result.len() >= 512 {
            return Err(invalid(field, "最多512条"));
        }
        result.push(match line.strip_prefix("re:") {
            Some(pattern) => {
                recognition::reject_unsupported_regex(pattern.trim())?;
                Phrase::Pattern(
                    Regex::new(pattern.trim())
                        .map_err(|e| invalid(field, &format!("{e}")))?,
                )
            }
            None => Phrase::Contains(line.to_owned()),
        });
    }
    Ok(result)
}
fn suffixes(value: &str) -> Result<Vec<Suffix>, ApiError> {
    phrases(value, "标题后缀清理")?
        .into_iter()
        .map(|p| match p {
            Phrase::Contains(text) => Ok(Suffix::Text(text)),
            Phrase::Pattern(r) => Regex::new(&format!("(?:{})\\s*$", r.as_str()))
                .map(Suffix::Pattern)
                .map_err(|e| invalid("标题后缀清理", &format!("{e}"))),
        })
        .collect()
}

/// 允许的编号跳跃：用逗号、顿号、空格或换行分隔的章号或“起-止”范围。
fn number_ranges(value: &str) -> Result<Vec<(u32, u32)>, ApiError> {
    const FIELD: &str = "允许的编号跳跃";
    if value.len() > 4096 || value.contains('\0') {
        return Err(invalid(FIELD, "最多4096字节，不能包含空字符"));
    }
    let mut result = Vec::new();
    for item in value
        .split([',', '，', '、', ';', '；', ' ', '\t', '\n', '\r', '　'])
        .map(str::trim)
        .filter(|v| !v.is_empty())
    {
        if result.len() >= 512 {
            return Err(invalid(FIELD, "最多512项"));
        }
        let (a, b) = item
            .split_once(['-', '－', '—', '–', '~', '～', '至'])
            .unwrap_or((item, item));
        match (parse_number(a.trim()), parse_number(b.trim())) {
            (Some(a), Some(b)) if a >= 1 && a <= b => result.push((a, b)),
            _ => {
                return Err(invalid(
                    FIELD,
                    &format!("“{item}”应为章号或范围，例如 9 或 101-104"),
                ));
            }
        }
    }
    result.sort_unstable();
    Ok(result)
}
fn invalid(field: &str, detail: &str) -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "chapter_rules",
        &format!("{field}: {detail}"),
    )
}
fn expression(value: &str, field: &str) -> Result<Option<Regex>, ApiError> {
    if value.trim().is_empty() {
        return Ok(None);
    }
    if value.len() > 4096 || value.contains('\0') {
        return Err(invalid(field, "表达式最多4096字节，不能包含空字符"));
    }
    Regex::new(value)
        .map(Some)
        .map_err(|e| invalid(field, &format!("{e}")))
}
impl RuleSet {
    pub fn compile(&self) -> Result<CompiledRules, ApiError> {
        if self.version != 2 {
            return Err(invalid("version", "识别规则版本不受支持"));
        }
        if self.numeric_minimum_body_lines > 1000 {
            return Err(invalid("numeric_minimum_body_lines", "正文行数应为0至1000"));
        }
        self.corrections()?;
        Ok(CompiledRules {
            rules: self.clone(),
            chapter: expression(&self.chapter_pattern, "常规标题")?,
            volume: expression(&self.volume_pattern, "卷标题")?,
            level_chapter: expression(&self.level_chapter_pattern, "章标题")?,
            section: expression(&self.section_pattern, "节标题")?,
            numeric: NumericRule::compile(Some(&self.numeric_pattern)).map_err(|_| {
                invalid(
                    "数字标题",
                    "表达式应含number与title命名组；环视和反向引用不受支持",
                )
            })?,
            non_heading: phrases(&self.non_heading, "非标题词库")?,
            force_heading: phrases(&self.force_heading, "标题词库")?,
            allowed_duplicates: phrases(&self.allowed_duplicate_titles, "允许重复的标题")?,
            allowed_gaps: number_ranges(&self.allowed_number_gaps)?,
            suffixes: suffixes(&self.title_suffixes)?,
        })
    }
    pub fn fingerprint(&self) -> String {
        format!(
            "{:x}",
            Sha256::digest(serde_json::to_vec(self).expect("rules"))
        )
    }
    pub fn corrections(&self) -> Result<Vec<(char, char)>, ApiError> {
        let mut result = Vec::new();
        if self.number_corrections.len() > 2048 {
            return Err(invalid("编号错字表", "最多2048字节"));
        }
        for line in self
            .number_corrections
            .lines()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            let Some((a, b)) = line.split_once('=') else {
                return Err(invalid("编号错字表", "每行填写原字=数字，例如久=九"));
            };
            let mut left = a.trim().chars();
            let mut right = b.trim().chars();
            let (Some(a), Some(b)) = (left.next(), right.next()) else {
                return Err(invalid("编号错字表", "每边恰好一个字"));
            };
            if left.next().is_some()
                || right.next().is_some()
                || parse_number(&a.to_string()).is_some()
                || parse_number(&b.to_string()).is_none()
                || result.iter().any(|(c, _)| *c == a)
            {
                return Err(invalid(
                    "编号错字表",
                    "原字不能是数字或重复；目标必须是数字",
                ));
            }
            result.push((a, b));
        }
        Ok(result)
    }
}
/// Read the number from the same capture that recognized a custom heading.
fn parse_match(regex: &Regex, text: &str, role: Role) -> Option<Match> {
    let captures = regex.captures(text)?;
    let number = captures
        .name("number")
        .or_else(|| captures.name("n"))
        .and_then(|m| parse_number(m.as_str()))
        .or_else(|| generic_number(text).map(|v| v.0));
    let title = captures
        .name("title")
        .map_or(text, |m| m.as_str())
        .trim()
        .to_owned();
    Some(Match {
        rule_id: "chapter",
        role,
        number,
        marker: generic_number(text).map(|v| v.1),
        title,
        numeric: false,
    })
}
pub fn generic_number(text: &str) -> Option<(u32, char)> {
    let text = text
        .trim()
        .trim_start_matches(['【', '[', '（', '('])
        .trim_start();
    let text = text.strip_prefix('第').unwrap_or(text).trim_start();
    for (offset, ch) in text.char_indices() {
        if !ch.is_whitespace() && parse_number(&ch.to_string()).is_none() {
            return parse_number(text[..offset].trim()).map(|n| (n, ch));
        }
    }
    None
}
impl CompiledRules {
    /// 非标题词库命中：这一行永远不算标题。
    pub fn is_non_heading(&self, text: &str) -> bool {
        let text = text.trim();
        self.non_heading.iter().any(|p| p.matches(text))
    }
    /// 标题词库命中（且不在非标题词库中）。
    pub fn is_forced_heading(&self, text: &str) -> bool {
        let text = text.trim();
        !self.is_non_heading(text) && self.force_heading.iter().any(|p| p.matches(text))
    }
    /// 用户允许重复的标题（CH-258）：相邻同名时不报“连续重复标题”。
    pub fn allows_duplicate_title(&self, title: &str) -> bool {
        let title = title.trim();
        self.allowed_duplicates.iter().any(|p| p.matches(title))
    }
    /// 跳过的章号 first..=last 全部在“允许的编号跳跃”里时为真（CH-259）。
    pub fn allows_number_gap(&self, first: u32, last: u32) -> bool {
        let mut next = first;
        loop {
            let Some(end) = self
                .allowed_gaps
                .iter()
                .filter(|(a, b)| *a <= next && next <= *b)
                .map(|(_, b)| *b)
                .max()
            else {
                return false;
            };
            if end >= last {
                return true;
            }
            next = end + 1;
        }
    }
    /// 按“标题后缀清理”去掉标题末尾的后缀（CH-260）；没有变化或会清空标题时返回 None。
    pub fn clean_title(&self, title: &str) -> Option<String> {
        if self.suffixes.is_empty() {
            return None;
        }
        let original = title.trim();
        let mut current = original.to_owned();
        // 多条后缀可能叠在一起（“（求月票）（加更）”），重复几轮直到不再变化。
        for _ in 0..8 {
            let before = current.len();
            for suffix in &self.suffixes {
                let cut = match suffix {
                    Suffix::Text(text) => current
                        .ends_with(text.as_str())
                        .then(|| current.len() - text.len()),
                    Suffix::Pattern(r) => r.find(&current).map(|m| m.start()),
                };
                if let Some(cut) = cut {
                    let next = current[..cut].trim_end();
                    if !next.is_empty() {
                        current = next.to_owned();
                    }
                }
            }
            if current.len() == before {
                break;
            }
        }
        (current != original).then_some(current)
    }
    pub fn explicitly_matches(&self, text: &str) -> bool {
        self.is_forced_heading(text) || self.chapter.as_ref().is_some_and(|r| r.is_match(text))
            || self.rules.hierarchy
                && [&self.volume, &self.level_chapter, &self.section]
                    .iter()
                    .any(|r| r.as_ref().is_some_and(|r| r.is_match(text)))
    }
    pub fn matched(&self, text: &str) -> Option<Match> {
        let text = text.trim();
        if text.is_empty() || text.chars().count() > 256 || self.is_non_heading(text) {
            return None;
        }
        if self.is_forced_heading(text) {
            let number = crate::source::numbered_heading(text).or_else(|| generic_number(text));
            return Some(Match {
                rule_id: "force_heading",
                role: Role::Chapter,
                number: number.map(|v| v.0),
                marker: number.map(|v| v.1),
                title: text.into(),
                numeric: false,
            });
        }
        if self.rules.hierarchy {
            for (regex, role, rule_id) in [
                (&self.volume, Role::Volume, "volume"),
                (&self.level_chapter, Role::Chapter, "level_chapter"),
                (&self.section, Role::Section, "section"),
            ] {
                if let Some(regex) = regex
                    && let Some(mut m) = parse_match(regex, text, role) {
                        m.rule_id = rule_id;
                        return Some(m);
                    }
            }
        }
        if let Some(regex) = &self.chapter {
            if let Some(m) = parse_match(regex, text, Role::Chapter) {
                return Some(m);
            }
        } else if recognition::is_default_heading(text)
            && !recognition::is_author_note_heading(text)
        {
            let number = crate::source::numbered_heading(text);
            let role = if self.rules.hierarchy {
                match number.map(|v| v.1) {
                    Some('卷' | '部' | '篇' | '集') => Role::Volume,
                    Some('节') => Role::Section,
                    _ => Role::Chapter,
                }
            } else {
                Role::Chapter
            };
            return Some(Match {
                rule_id: match role { Role::Volume => "volume", Role::Section => "section", _ => "chapter" },
                role,
                number: number.map(|v| v.0),
                marker: number.map(|v| v.1),
                title: text.into(),
                numeric: false,
            });
        }
        if self.rules.numeric
            && let Some(n) = self.numeric.matches(text) {
                return Some(Match {
                    rule_id: "numeric",
                    role: Role::Chapter,
                    number: Some(n.number),
                    marker: Some('章'),
                    title: n.title,
                    numeric: true,
                });
            }
        None
    }
    pub fn numbering(&self, text: &str) -> Option<(u32, char)> {
        self.matched(text)
            .and_then(|m| {
                m.number.map(|n| {
                    (
                        n,
                        match m.role {
                            Role::Volume => '卷',
                            Role::Section => '节',
                            _ => m.marker.unwrap_or('章'),
                        },
                    )
                })
            })
            .or_else(|| crate::source::numbered_heading(text))
            .or_else(|| self.numeric.matches(text).map(|n| (n.number, '章')))
    }
    pub fn recognize(&self, source: &SourceSnapshot) -> Vec<Override> {
        let lines = source.decoded_line_ranges();
        let text = source.decoded_text();
        let candidates: Vec<_> = lines
            .iter()
            .enumerate()
            .filter_map(|(i, &(a, b))| self.matched(&text[a..b]).map(|m| (i, m)))
            .collect();
        let dominant = recognition::dominant_marker(candidates.iter().map(|(i, _)| {
            let (a, b) = lines[*i];
            &text[a..b]
        }));
        let mut result = Vec::new();
        let mut in_volume = false;
        let mut in_chapter = false;
        for (index, (line, m)) in candidates.iter().enumerate() {
            let (a, b) = lines[*line];
            let custom = self
                .chapter
                .as_ref()
                .is_some_and(|r| r.is_match(&text[a..b]))
                || self.rules.hierarchy
                    && [&self.volume, &self.level_chapter, &self.section]
                        .iter()
                        .any(|r| r.as_ref().is_some_and(|r| r.is_match(&text[a..b])));
            if !m.numeric && !custom && recognition::is_prose_heading(&text[a..b], dominant) {
                continue;
            }
            if m.numeric {
                let end = candidates.get(index + 1).map_or(lines.len(), |v| v.0);
                let body = lines[line + 1..end]
                    .iter()
                    .filter(|&&(a, b)| !text[a..b].trim().is_empty())
                    .take(self.rules.numeric_minimum_body_lines as usize)
                    .count();
                if body < self.rules.numeric_minimum_body_lines as usize {
                    continue;
                }
            }
            let (role, depth) = match m.role {
                Role::Volume => {
                    in_volume = true;
                    in_chapter = false;
                    (Role::Volume, 0)
                }
                Role::Section if in_chapter => (Role::Section, if in_volume { 2 } else { 1 }),
                _ => {
                    in_chapter = true;
                    (Role::Chapter, if in_volume { 1 } else { 0 })
                }
            };
            result.push(Override {
                source_line: *line as u32 + 1,
                role,
                depth,
                include_toc: true,
            });
        }
        result
    }
}

pub fn validate_presets(presets: &[Preset]) -> Result<(), ApiError> {
    if presets.len() > 64 {
        return Err(invalid("预设", "最多64个识别规则预设"));
    }
    let mut names = std::collections::BTreeSet::new();
    for p in presets {
        if p.name.trim().is_empty() || p.name.len() > 256 || !names.insert(p.name.trim()) {
            return Err(invalid("预设名称", "名称不能为空或重复"));
        }
        p.rules.compile()?;
    }
    Ok(())
}

pub fn ordered_parts(before: &str, after: &str) -> bool {
    static PART: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    let pattern=PART.get_or_init(||Regex::new(r"^(.*?)\s*[（(]\s*(续\s*[,，、]?\s*)?([上中下]|[0-9]+)\s*(?:[,，][^()（）]*)?[）)]\s*$").expect("part pattern"));
    let (Some(a), Some(b)) = (pattern.captures(before), pattern.captures(after)) else {
        return false;
    };
    if a[1].trim().is_empty()
        || a[1].trim() != b[1].trim()
        || a.get(2).is_some() != b.get(2).is_some()
    {
        return false;
    }
    match (a[3].parse::<u32>(), b[3].parse::<u32>()) {
        (Ok(a), Ok(b)) => a > 0 && a.checked_add(1) == Some(b),
        _ => "上中下"
            .find(&a[3])
            .zip("上中下".find(&b[3]))
            .is_some_and(|(a, b)| a < b),
    }
}

pub fn rebuild(
    mut book: crate::publication::EffectiveBook,
    rules: &RuleSet,
    preserve_decisions: bool,
) -> Result<(crate::publication::EffectiveBook, serde_json::Value), ApiError> {
    let compiled = rules.compile()?;
    let source = SourceSnapshot::from_utf8(
        book.text.as_bytes().to_vec(),
        crate::source::RULE_ID,
        || false,
    )?;
    let mut structure = crate::structure::Structure::new(&source);
    structure.recognition_rules = Some(rules.clone());
    let mut proposed = compiled
        .recognize(&source)
        .into_iter()
        .map(|item| (item.source_line, item))
        .collect::<std::collections::BTreeMap<_, _>>();
    if preserve_decisions {
        for node in book
            .tree
            .nodes
            .iter()
            .filter(|n| n.entry_id.starts_with("inserted:"))
        {
            proposed.insert(
                node.source_line,
                Override {
                    source_line: node.source_line,
                    role: node.role.clone(),
                    depth: node.depth,
                    include_toc: node.include_toc,
                },
            );
        }
        for (original, heading) in &book.tree.recognition_decisions {
            if let Some(line) = book.source_to_output_lines.get(original) {
                let current = book.tree.nodes.iter().find(|n| n.source_line == *line);
                proposed.insert(
                    *line,
                    Override {
                        source_line: *line,
                        role: if *heading {
                            current.map_or(Role::Chapter, |n| n.role.clone())
                        } else {
                            Role::Body
                        },
                        depth: current.map_or(0, |n| n.depth),
                        include_toc: *heading && current.is_none_or(|n| n.include_toc),
                    },
                );
            }
        }
    }
    // Manual body decisions can remove a volume or chapter which the automatic
    // pass used as a parent. Derive depth from the final roles, not that old pass.
    let (mut in_volume, mut in_chapter) = (false, false);
    for item in proposed.values_mut() {
        item.depth = match item.role {
            Role::Body => 0,
            Role::Volume => {
                in_volume = true;
                in_chapter = false;
                0
            }
            Role::Front => {
                in_volume = false;
                in_chapter = false;
                0
            }
            Role::Section => u8::from(in_volume) + u8::from(in_chapter),
            Role::Chapter => {
                in_chapter = true;
                u8::from(in_volume)
            }
        };
    }
    structure.overrides = proposed.into_values().collect();
    let mut tree = structure.tree(&source)?;
    let old = book
        .tree
        .nodes
        .iter()
        .map(|n| (n.source_line, n.clone()))
        .collect::<std::collections::BTreeMap<_, _>>();
    let ids = tree
        .nodes
        .iter()
        .map(|n| {
            (
                n.entry_id.clone(),
                old.get(&n.source_line).map_or_else(
                    || format!("recognized:{}:{}", book.original_source_id, n.start),
                    |old| old.entry_id.clone(),
                ),
            )
        })
        .collect::<std::collections::BTreeMap<_, _>>();
    for node in &mut tree.nodes {
        node.entry_id = ids[&node.entry_id].clone();
        node.parent_id = node.parent_id.as_ref().map(|id| ids[id].clone());
    }
    let added = tree
        .nodes
        .iter()
        .filter(|n| !old.contains_key(&n.source_line))
        .count();
    let retained = tree
        .nodes
        .iter()
        .map(|n| n.source_line)
        .collect::<std::collections::BTreeSet<_>>();
    let removed = old.keys().filter(|line| !retained.contains(line)).count();
    if preserve_decisions {
        tree.recognition_decisions = book.tree.recognition_decisions.clone();
    }
    let before = book.tree.nodes.len();
    book.tree = tree;
    // 标题改写：规范数字标题，再按“标题后缀清理”去掉后缀（CH-260）。只改标题行。
    let renames = book
        .tree
        .nodes
        .iter()
        .filter_map(|n| {
            let normalized = (rules.numeric && rules.normalize_numeric_titles)
                .then(|| compiled.numeric.matches(&n.title))
                .flatten()
                .map(|m| {
                    format!(
                        "第{}章 {}",
                        crate::cleanup_numbers::chinese(m.number),
                        m.title
                    )
                });
            let title = normalized.as_deref().unwrap_or(&n.title);
            compiled
                .clean_title(title)
                .or(normalized)
                .map(|title| (n.source_line, title))
        })
        .collect::<std::collections::BTreeMap<_, _>>();
    // All replacements preserve line count and original newline bytes.
    if !renames.is_empty() {
        let lines = source.decoded_line_ranges();
        let mut text = String::with_capacity(book.text.len());
        for (i, &(a, b)) in lines.iter().enumerate() {
            text.push_str(
                renames
                    .get(&(i as u32 + 1))
                    .map_or(&book.text[a..b], String::as_str),
            );
            text.push_str(&book.text[b..lines.get(i + 1).map_or(book.text.len(), |v| v.0)]);
        }
        let updated = SourceSnapshot::from_utf8(
            text.as_bytes().to_vec(),
            crate::source::RULE_ID,
            || false,
        )?;
        let updated_lines = updated.decoded_line_ranges();
        for node in &mut book.tree.nodes {
            node.start = updated_lines[node.source_line as usize - 1].0;
            node.body_start = updated_lines
                .get(node.source_line as usize)
                .map_or(text.len(), |v| v.0);
            if let Some(title) = renames.get(&node.source_line) {
                node.title = title.clone();
            }
        }
        let starts = book.tree.nodes.iter().map(|n| n.start).collect::<Vec<_>>();
        for (i, node) in book.tree.nodes.iter_mut().enumerate() {
            node.end = starts.get(i + 1).copied().unwrap_or(text.len());
        }
        book.tree.prefix_end = starts.first().copied().unwrap_or(text.len());
        book.tree.source_bytes_covered = text.len();
        book.tree.source_id = updated.summary().source_id;
        book.text = text;
        book.text_changed = true;
    }
    let changed = book
        .tree
        .nodes
        .iter()
        .filter(|n| {
            old.get(&n.source_line).is_some_and(|v| {
                v.role != n.role
                    || v.depth != n.depth
                    || v.title != n.title
                    || v.include_toc != n.include_toc
            })
        })
        .count();
    Ok((
        book,
        serde_json::json!({"kind":"recognize","before_count":before,"added":added,"removed":removed,"changed":changed,"rule_version":rules.version,"rule_fingerprint":rules.fingerprint()}),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        effective_edit::{self, Action, Request},
        publication::compose,
        source::RULE_ID,
        structure::Structure,
    };

    #[test]
    fn phrase_lists_exclude_or_force_headings_and_keep_old_fingerprints() {
        let compiled = RuleSet {
            non_heading: "两章合一章\nre:^\\d+\\.请".into(),
            force_heading: "楔子\n两章合一章".into(),
            ..Default::default()
        }
        .compile()
        .unwrap();
        // 非标题词库优先于标题词库与内置规则。
        assert!(compiled.matched("两章合一章，更比两章强！").is_none());
        assert!(compiled.matched("1.请不要让前桌坐着其他人").is_none());
        let forced = compiled.matched("楔子").unwrap();
        assert_eq!(forced.role, Role::Chapter);
        assert!(compiled.explicitly_matches("楔子"));
        assert!(compiled.matched("第三章 正常的标题").is_some());
        assert!(
            RuleSet {
                non_heading: "re:(?=x)".into(),
                ..Default::default()
            }
            .compile()
            .is_err()
        );
        // 词库为空时不参与序列化：已有规则的指纹与快照不变。
        let value = serde_json::to_value(RuleSet::default()).unwrap();
        assert!(value.get("non_heading").is_none());
        assert!(value.get("force_heading").is_none());
        // 已识别为标题的行命中非标题词库时，检查列为“正文被当成标题”。
        let text = "第1章 甲\n正文\n两章合一章，更比两章强！\n感谢\n第2章 乙\n正文\n";
        let source = SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let mut structure = Structure::new(&source);
        structure
            .put(
                &source,
                crate::structure::Override {
                    source_line: 3,
                    role: Role::Chapter,
                    depth: 0,
                    include_toc: true,
                },
            )
            .unwrap();
        let mut book = compose(&source, &structure, None).unwrap();
        book.tree.recognition_rules = Some(RuleSet {
            non_heading: "两章合一章".into(),
            ..Default::default()
        });
        let view = SourceSnapshot::for_effective_diagnostics(&book).unwrap();
        assert!(
            view.prose_headings()
                .iter()
                .any(|c| c.title.starts_with("两章合一章"))
        );
        assert!(view.missing_prefix_chapters().is_empty());
    }

    #[test]
    fn author_quantity_notes_are_body_while_real_titles_and_ordered_parts_survive() {
        let compiled = RuleSet::default().compile().unwrap();
        for note in [
            "三章更新完毕！",
            "两章更新了6000字，求票！",
            "三章已更新三千字",
        ] {
            assert!(compiled.matched(note).is_none(), "{note}");
        }
        for title in ["第137章 更新了世界", "三章 更新了世界", "第三章 更新完毕！"]
        {
            assert!(compiled.matched(title).is_some(), "{title}");
        }
        let text = "第137章 风起\n正文\n两章合一章，更比两章强！\n（两章加起来5400多字，已经三更了！）\n第138章 两章合一的秘密\n正文\n第138章 同行（1）\n正文\n第138章 同行（2）\n正文\n第138章 另一段\n正文\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let book = compose(&source, &Structure::recognized(&source), None).unwrap();
        assert_eq!(book.tree.nodes.len(), 5);
        assert!(
            book.tree
                .nodes
                .iter()
                .all(|n| !n.title.starts_with("两章") && !n.title.starts_with("（两章"))
        );
        let report = book.check_page(0, None).unwrap();
        let items = report["report"]["diagnostic"]["review_items"]
            .as_array()
            .unwrap();
        let repeated = items
            .iter()
            .filter(|v| v["finding_id"] == "number-reset")
            .collect::<Vec<_>>();
        assert_eq!(repeated.len(), 2, "{report}");
        assert!(ordered_parts("第12章 风起（上）", "第12章 风起（下）"));
        assert!(!ordered_parts("第12章 风起（2）", "第12章 风起（1）"));
        assert!(!ordered_parts("第12章 风起（1）", "第12章 别处（2）"));
        assert_eq!(source.original_bytes(), text.as_bytes());
        // A remembered body decision must also remove its old parent level.
        let source = SourceSnapshot::from_utf8(
            "第一卷 卷\n第一章 章\n正文".as_bytes().to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let mut book = compose(&source, &Structure::recognized(&source), None).unwrap();
        book.tree.recognition_decisions.insert(1, false);
        let (book, _) = rebuild(book, &RuleSet::default(), true).unwrap();
        assert_eq!(book.tree.nodes.len(), 1);
        assert_eq!(book.tree.nodes[0].depth, 0);
    }

    #[test]
    fn custom_rules_replay_with_manual_classification_and_shared_numbering() {
        let text = "第1话 起点\n正文\n第3话 终点\n正文\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let original = compose(&source, &Structure::recognized(&source), None).unwrap();
        let rules = RuleSet {
            chapter_pattern: r"^第(?P<number>[0-9]+)话\s+(?P<title>.+)$".into(),
            ..RuleSet::default()
        };
        let mut request = Request {
            base_id: effective_edit::base_id(&original),
            actions: vec![Action::Recognize {
                rules: Box::new(rules.clone()),
                preserve_decisions: true,
            }],
        };
        let recognized = effective_edit::apply(original.clone(), &request).unwrap().0;
        assert_eq!(recognized.tree.nodes.len(), 2);
        assert!(
            recognized.check_page(0, None).unwrap()["report"]["diagnostic"]["review_items"]
                .as_array()
                .unwrap()
                .iter()
                .any(|i| i["finding_id"] == "number-gap")
        );
        let id = recognized.tree.nodes[1].entry_id.clone();
        request.actions.push(Action::Classify {
            entry_id: id,
            role: Role::Body,
            depth: 0,
            include_toc: false,
        });
        request.actions.push(Action::Recognize {
            rules: Box::new(rules.clone()),
            preserve_decisions: true,
        });
        let saved = serde_json::to_string(&request).unwrap();
        let restored: Request = serde_json::from_str(&saved).unwrap();
        let classified = effective_edit::apply(original.clone(), &restored)
            .unwrap()
            .0;
        assert_eq!(classified.tree.nodes.len(), 1);
        assert_eq!(classified.tree.recognition_decisions.get(&3), Some(&false));
        assert_eq!(classified.text, text);
        request.actions.push(Action::Recognize {
            rules: Box::new(rules),
            preserve_decisions: false,
        });
        let rebuilt = effective_edit::apply(original.clone(), &request).unwrap().0;
        assert_eq!(rebuilt.tree.nodes.len(), 2);
        assert_eq!(
            rebuilt.source_to_output_lines,
            original.source_to_output_lines
        );
        assert!(rebuilt.tree.recognition_decisions.is_empty());
        assert_eq!(source.original_bytes(), text.as_bytes());
        let mut toc_book = rebuilt;
        toc_book.tree.nodes[0].include_toc = false;
        toc_book.tree.recognition_decisions.insert(1, true);
        let active = toc_book.tree.recognition_rules.clone().unwrap();
        let (preserved, summary) = rebuild(toc_book.clone(), &active, true).unwrap();
        assert!(!preserved.tree.nodes[0].include_toc);
        assert_eq!(summary["changed"], 0);
        let (reset, summary) = rebuild(toc_book, &active, false).unwrap();
        assert!(reset.tree.nodes[0].include_toc);
        assert_eq!(summary["changed"], 1);
        let source =
            SourceSnapshot::from_utf8("手工标题\n正文".as_bytes().to_vec(), RULE_ID, || {
                false
            })
            .unwrap();
        let book = compose(&source, &Structure::recognized(&source), None).unwrap();
        let request = Request {
            base_id: effective_edit::base_id(&book),
            actions: vec![Action::CreateBoundary {
                entry_id: None,
                line_offset: 1,
                role: Role::Chapter,
                depth: 0,
                include_toc: true,
            }],
        };
        let manual = effective_edit::apply(book, &request).unwrap().0;
        let (preserved, _) = rebuild(manual.clone(), &RuleSet::default(), true).unwrap();
        assert_eq!(preserved.tree.nodes[0].title, "手工标题");
        let (reset, _) = rebuild(manual, &RuleSet::default(), false).unwrap();
        assert!(reset.tree.nodes.is_empty());
    }

    #[test]
    fn numeric_body_evidence_and_optional_normalization_preserve_source_mapping() {
        let text = "1：风起\r\n甲\r\n乙\r\n丙\r\n丁\r\n戊\r\n2：续篇\r\n甲\r\n乙\r\n丙\r\n丁\r\n戊\r\n3：一行广告\r\n短句\r\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let original = compose(&source, &Structure::recognized(&source), None).unwrap();
        let mut rules = RuleSet {
            numeric: true,
            ..RuleSet::default()
        };
        let (recognized, _) = rebuild(original.clone(), &rules, true).unwrap();
        assert_eq!(recognized.tree.nodes.len(), 2);
        assert_eq!(recognized.text, text);
        rules.normalize_numeric_titles = true;
        let (normalized, _) = rebuild(original.clone(), &rules, true).unwrap();
        assert!(normalized.text.starts_with("第一章 风起\r\n"));
        assert!(normalized.text.contains("第二章 续篇\r\n"));
        assert!(normalized.text.ends_with("3：一行广告\r\n短句\r\n"));
        assert_eq!(
            normalized.source_to_output_lines,
            original.source_to_output_lines
        );
        assert_eq!(source.original_bytes(), text.as_bytes());
        for n in normalized.tree.nodes {
            assert!(normalized.text[n.start..n.body_start].starts_with(&n.title));
        }
    }

    #[test]
    fn exceptions_quiet_allowed_findings_and_clean_title_suffixes_only() {
        // 三个例外留空时不参与序列化：已有规则的指纹不变。
        let value = serde_json::to_value(RuleSet::default()).unwrap();
        for key in ["allowed_duplicate_titles", "allowed_number_gaps", "title_suffixes"] {
            assert!(value.get(key).is_none(), "{key}");
        }
        for bad in [
            RuleSet { allowed_number_gaps: "九章".into(), ..Default::default() },
            RuleSet { allowed_number_gaps: "5-3".into(), ..Default::default() },
            RuleSet { title_suffixes: "re:(?=x)".into(), ..Default::default() },
        ] {
            assert!(bad.compile().is_err());
        }
        let rules = RuleSet {
            allowed_number_gaps: "9，101-102、103 104".into(),
            title_suffixes: "（求月票）\nre:[（(]第?[一二三四五六七八九十0-9]+更[）)]".into(),
            ..Default::default()
        };
        let compiled = rules.compile().unwrap();
        assert!(compiled.allows_number_gap(9, 9));
        assert!(compiled.allows_number_gap(101, 104));
        assert!(!compiled.allows_number_gap(8, 9));
        assert!(!compiled.allows_number_gap(100, 101));
        assert_eq!(
            compiled.clean_title("第一章 夜渡（第二更）（求月票）").as_deref(),
            Some("第一章 夜渡")
        );
        assert_eq!(compiled.clean_title("第二章 夜渡"), None);
        // 只剩后缀时不清空标题。
        assert_eq!(compiled.clean_title("（求月票）"), None);

        // 诊断：允许的重复标题与编号跳跃不再报，未允许的照常报。
        let text = "第一章 夜渡\n甲\n第二章 番外\n\n第二章 番外\n乙\n第五章 远行（求月票）\n丙\n第七章 归来\n丁\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let book = compose(&source, &Structure::new(&source), None).unwrap();
        let ids = |book: &crate::publication::EffectiveBook| {
            let view = SourceSnapshot::for_effective_diagnostics(book).unwrap();
            let report: serde_json::Value =
                serde_json::from_str(&view.diagnostic_json()).unwrap();
            report["findings"]
                .as_array()
                .unwrap()
                .iter()
                .map(|f| (f["id"].as_str().unwrap().to_owned(), f["count"].as_u64().unwrap()))
                .collect::<std::collections::BTreeMap<_, _>>()
        };
        let before = ids(&book);
        assert_eq!(before.get("duplicate-title"), Some(&1));
        assert_eq!(before.get("number-gap"), Some(&2));
        assert_eq!(crate::effective_repair::candidates(&book)["total"], 1);
        let mut allowed = book.clone();
        allowed.tree.recognition_rules = Some(RuleSet {
            allowed_duplicate_titles: "番外".into(),
            allowed_number_gaps: "3-4".into(),
            ..Default::default()
        });
        let after = ids(&allowed);
        assert_eq!(after.get("duplicate-title"), None);
        // 第三、四章允许跳过；第六章不在列表里，仍报。
        assert_eq!(after.get("number-gap"), Some(&1));
        assert_eq!(crate::effective_repair::candidates(&allowed)["total"], 0);

        // 后缀清理：重新识别时只改标题行，正文与行号映射不变。
        let (cleaned, summary) = rebuild(book.clone(), &rules, true).unwrap();
        assert_eq!(summary["changed"], 1);
        assert!(cleaned.text.contains("\n第五章 远行\n丙\n"));
        assert_eq!(
            cleaned.text.replace("第五章 远行\n", "第五章 远行（求月票）\n"),
            text
        );
        assert_eq!(cleaned.source_to_output_lines, book.source_to_output_lines);
        for n in &cleaned.tree.nodes {
            assert!(cleaned.text[n.start..n.body_start].starts_with(&n.title));
        }
        assert!(cleaned.tree.nodes.iter().any(|n| n.title == "第五章 远行"));
        assert_eq!(source.original_bytes(), text.as_bytes());
    }
}
