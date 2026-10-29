//! Ordered, explicit text transformations. No guessed OCR corrections.
pub use crate::chinese_variant::{DICTIONARY_VERSION, Direction as ChineseVariantDirection};
pub use crate::cleanup_notice::{Options as NoticeOptions, Pattern as NoticePattern};
pub use crate::cleanup_numbers::Style as NumberStyle;
pub use crate::cleanup_punctuation::Options as PunctuationOptions;
use crate::{ApiError, ErrorCode};
use regex::{Regex, RegexBuilder};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Rule {
    Configured {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
        enabled: bool,
        scope: Scope,
        rule: Box<Rule>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        original: Option<Box<Rule>>,
    },
    TrimTrailingSpaces,
    CollapseBlankLines,
    RemoveAdLines,
    RemoveDuplicateTitles,
    NoticeLines {
        options: NoticeOptions,
    },
    NormalizeWidth,
    NormalizePunctuation,
    ChapterNumbers {
        style: NumberStyle,
        bare_titles: bool,
    },
    ChinesePunctuation {
        options: PunctuationOptions,
    },
    RemoveInvisible,
    OcrHanSpaces,
    OcrEllipsis,
    ChineseVariant {
        direction: ChineseVariantDirection,
        dictionary_version: String,
    },
    JoinHardWraps {
        min_chars: u32,
        mode: JoinMode,
    },
    LiteralReplace {
        find: String,
        replace: String,
    },
    RegexReplace {
        pattern: String,
        replace: String,
    },
    MultilineRegexReplace {
        pattern: String,
        replace: String,
    },
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Scope {
    All,
    Body,
    Headings,
}
impl Scope {
    pub(crate) fn includes(&self, heading: bool) -> bool {
        match self {
            Self::All => true,
            Self::Body => !heading,
            Self::Headings => heading,
        }
    }
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JoinMode {
    Chinese,
    Space,
}
impl JoinMode {
    pub(crate) fn separator(&self) -> &'static str {
        match self {
            Self::Chinese => "",
            Self::Space => " ",
        }
    }
    pub(crate) fn can_join(&self, left: &str, right: &str, min_chars: u32) -> bool {
        if left.chars().count() < min_chars as usize {
            return false;
        }
        let Some(end) = left.chars().last() else {
            return false;
        };
        let Some(start) = right.chars().next() else {
            return false;
        };
        let han = |c: char| matches!(c as u32, 0x3400..=0x4dbf | 0x4e00..=0x9fff | 0xf900..=0xfaff | 0x20000..=0x323af);
        match self {
            Self::Chinese => (han(end) || matches!(end, '，' | '、')) && han(start),
            Self::Space => {
                (end.is_ascii_alphanumeric() || end == ',') && start.is_ascii_alphanumeric()
            }
        }
    }
}
pub(crate) struct Compiled {
    pub rule: Rule,
    pub enabled: bool,
    pub scope: Scope,
    regex: Option<Regex>,
    replacement: Vec<Part>,
    converter: Option<&'static ferrous_opencc::OpenCC>,
    pub notices: Option<crate::cleanup_notice::Matcher>,
    punctuation: Option<crate::cleanup_punctuation::Matcher>,
}
pub(crate) struct RegexEdit {
    pub start: usize,
    pub end: usize,
    pub replacement: String,
}
fn multiline_replacement(text: &str) -> Result<String, ApiError> {
    let mut result = String::new();
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            result.push(c);
            continue;
        }
        result.push(match chars.next() {
            Some('n') => '\n',
            Some('r') => '\r',
            Some('t') => '\t',
            Some('\\') => '\\',
            _ => return Err(invalid()),
        });
    }
    Ok(result)
}
enum Part {
    Text(String),
    Capture(usize),
}
pub(crate) fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "cleanup_rules",
        "review_cleanup_rule",
    )
}
pub(crate) fn budget() -> ApiError {
    ApiError::new(
        ErrorCode::TooLarge,
        "cleanup_rules",
        "reduce_cleanup_scope_or_expansion",
    )
}
const MAX_LINE: usize = 1024 * 1024;
fn append(output: &mut String, text: &str) -> Result<(), ApiError> {
    if output.len().saturating_add(text.len()) > MAX_LINE {
        return Err(budget());
    }
    output.push_str(text);
    Ok(())
}
fn replacement_parts(text: &str, regex: &Regex) -> Result<Vec<Part>, ApiError> {
    let mut parts = Vec::new();
    let mut rest = text;
    while let Some(pos) = rest.find('$') {
        parts.push(Part::Text(rest[..pos].into()));
        rest = &rest[pos + 1..];
        if let Some(tail) = rest.strip_prefix('$') {
            parts.push(Part::Text("$".into()));
            rest = tail;
            continue;
        }
        let name;
        if let Some(tail) = rest.strip_prefix('{') {
            let end = tail.find('}').ok_or_else(invalid)?;
            name = &tail[..end];
            rest = &tail[end + 1..];
        } else {
            let end = rest
                .bytes()
                .take_while(|b| b.is_ascii_alphanumeric() || *b == b'_')
                .count();
            name = &rest[..end];
            rest = &rest[end..];
        }
        if name.is_empty() {
            return Err(invalid());
        }
        let index = name
            .parse::<usize>()
            .ok()
            .filter(|&i| i < regex.captures_len())
            .or_else(|| regex.capture_names().position(|n| n == Some(name)))
            .ok_or_else(invalid)?;
        parts.push(Part::Capture(index));
    }
    parts.push(Part::Text(rest.into()));
    Ok(parts)
}
impl Rule {
    pub(crate) fn base(&self) -> &Rule {
        match self {
            Self::Configured { rule, .. } => rule,
            _ => self,
        }
    }
    pub(crate) fn is_notice(&self) -> bool {
        matches!(self.base(), Self::RemoveAdLines | Self::NoticeLines { .. })
    }
    pub(crate) fn compile(&self) -> Result<Compiled, ApiError> {
        if let Self::Configured {
            enabled,
            scope,
            rule,
            original,
            name,
        } = self
        {
            if name.as_ref().is_some_and(|value| {
                value.trim().is_empty() || value.len() > 256 || value.chars().any(char::is_control)
            }) {
                return Err(invalid());
            }
            // Exactly one envelope; dormant defaults cannot contain nested plans.
            if matches!(rule.as_ref(), Self::Configured { .. })
                || original
                    .as_ref()
                    .is_some_and(|r| matches!(r.as_ref(), Self::Configured { .. }))
            {
                return Err(invalid());
            }
            if let Some(original) = original {
                original.compile()?;
            }
            if *scope == Scope::Headings
                && matches!(
                    rule.as_ref(),
                    Self::JoinHardWraps { .. } | Self::MultilineRegexReplace { .. }
                )
            {
                return Err(invalid());
            }
            if *scope != Scope::All && rule.is_notice() {
                return Err(invalid());
            }
            if *scope == Scope::Body && matches!(rule.as_ref(), Self::RemoveDuplicateTitles) {
                return Err(invalid());
            }
            let mut compiled = rule.compile()?;
            compiled.enabled = *enabled;
            compiled.scope = scope.clone();
            return Ok(compiled);
        }
        let mut compiled = Compiled {
            rule: self.clone(),
            enabled: true,
            scope: Scope::All,
            regex: None,
            replacement: Vec::new(),
            converter: None,
            notices: None,
            punctuation: None,
        };
        match self {
            Self::ChinesePunctuation { options } => {
                compiled.punctuation = Some(crate::cleanup_punctuation::Matcher::new(options)?);
            }
            Self::NoticeLines { options } => {
                compiled.notices = Some(crate::cleanup_notice::Matcher::new(options)?);
            }
            Self::ChineseVariant {
                direction,
                dictionary_version,
            } => {
                compiled.converter = Some(crate::chinese_variant::converter(
                    direction,
                    dictionary_version,
                )?);
            }
            Self::JoinHardWraps { min_chars, .. } if !(1..=4096).contains(min_chars) => {
                return Err(invalid());
            }
            Self::LiteralReplace { find, replace }
            | Self::RegexReplace {
                pattern: find,
                replace,
            }
            | Self::MultilineRegexReplace {
                pattern: find,
                replace,
            } => {
                let multiline = matches!(self, Self::MultilineRegexReplace { .. });
                if find.is_empty()
                    || find.len() > 4096
                    || replace.len() > 4096
                    || find.contains('\0')
                    || replace.contains('\0')
                    || (!multiline
                        && (find.contains(['\r', '\n']) || replace.contains(['\r', '\n'])))
                {
                    return Err(invalid());
                }
                if matches!(
                    self,
                    Self::RegexReplace { .. } | Self::MultilineRegexReplace { .. }
                ) {
                    let regex = RegexBuilder::new(find)
                        .multi_line(multiline)
                        .crlf(multiline)
                        .size_limit(1024 * 1024)
                        .dfa_size_limit(2 * 1024 * 1024)
                        .nest_limit(64)
                        .build()
                        .map_err(|_| invalid())?;
                    compiled.replacement = replacement_parts(
                        &if multiline {
                            multiline_replacement(replace)?
                        } else {
                            replace.clone()
                        },
                        &regex,
                    )?;
                    compiled.regex = Some(regex);
                }
            }
            _ => {}
        }
        Ok(compiled)
    }
}

/// Rust owns the actual preset rules; clients only choose and edit snapshots.
pub fn presets() -> serde_json::Value {
    let body = |rule| Rule::Configured {
        name: None,
        enabled: true,
        scope: Scope::Body,
        rule: Box::new(rule),
        original: None,
    };
    serde_json::json!([
        {"id":"blank-lines-v1","legacy_option":"CollapseBlankLines","name":"合并连续空行","description":"可应用修改：合并连续空行，保留段落间隔。","rules":[{"kind":"collapse_blank_lines"}]},
        {"id":"invisible-v1","legacy_option":"RemoveInvisibleCharacters","name":"删除不可见字符","description":"可应用修改：删除指定零宽和控制字符。","rules":[{"kind":"remove_invisible"}]},
        {"id":"chapter-numbers-v1","legacy_option":"NormalizeChapterNumbers","name":"标准化章节编号","description":"可应用修改：章节编号转中文；包含裸数字标题识别，请在预览中核对。","rules":[{"kind":"chapter_numbers","style":"chinese","bare_titles":true}]},
        {"id":"chinese-marks-v1","legacy_option":"NormalizePunctuation","name":"规范中文标点","description":"可应用修改：仅正文中文标点、省略号、破折号与引号；网址和数字标点保留。","rules":[{"kind":"configured","enabled":true,"scope":"body","rule":{"kind":"chinese_punctuation","options":{"marks":true,"ellipsis":true,"dashes":true,"quotes":true}}}]},
        {"id":"site-notices-v1","legacy_option":"RemoveSiteNotices","name":"网站广告与下载说明","description":"检测候选：逐项勾选后才排除；可编辑关键词、匹配及优先保留条件。","rules":[{"kind":"notice_lines","options":{"include_defaults":true,"include_headers":false,"ignore_case":true,"keywords":[],"preserve_keywords":[]}}]},
        {"id":"repeated-headers-v1","legacy_option":"RemoveRepeatedHeaders","name":"重复页眉与页码","description":"检测候选：查找独立页码与网址页眉，逐项勾选后才排除。","rules":[{"kind":"notice_lines","options":{"include_defaults":false,"include_headers":true,"ignore_case":true,"keywords":[],"preserve_keywords":[]}}]},
        {"id":"ocr-safe-v1","legacy_option":"ApplyOcrCorrections","name":"安全OCR排版修复","description":"可应用修改：仅正文汉字间空格与省略号，不猜测错别字。","rules":[{"kind":"configured","enabled":true,"scope":"body","rule":{"kind":"ocr_han_spaces"}},{"kind":"configured","enabled":true,"scope":"body","rule":{"kind":"ocr_ellipsis"}}]},

        {"id":"spaces-modern-v1","legacy_option":"NormalizeFullWidthSpaces","name":"统一全角空格","description":"不间断空格转普通空格；行首全角空格统一为两个，正文内全角空格转普通空格；清除行尾空白。","rules":[Rule::LiteralReplace{find:"\u{a0}".into(),replace:" ".into()},Rule::RegexReplace{pattern:"^　+".into(),replace:"　　".into()},Rule::RegexReplace{pattern:"([^　])　+".into(),replace:"${1} ".into()},Rule::TrimTrailingSpaces]},
        {"id":"hard-wrap-v1","legacy_option":"RepairHardWraps","name":"正文硬换行","description":"仅正文：合并至少 12 字、句子未结束的中文行；可编辑最短长度。","rules":[body(Rule::JoinHardWraps{min_chars:12,mode:JoinMode::Chinese})]},
        {"id":"ocr-v1","name":"OCR 排版痕迹","description":"汉字间空格/制表符、六连全角点/句号、指定不可见字符；仅正文。可能改变有意留空，请逐行复核，不猜测错别字。","rules":[body(Rule::RemoveInvisible),body(Rule::OcrHanSpaces),body(Rule::OcrEllipsis)]},
        {"id":"basic-v1","name":"基本空白与兼容字符","description":"行尾空白、连续空行、全角字母/数字/空格及兼容标点。","rules":[Rule::TrimTrailingSpaces,Rule::CollapseBlankLines,Rule::NormalizeWidth,Rule::NormalizePunctuation]},
        {"id":"paragraph-v1","legacy_option":"RepairParagraphBoundaries","name":"句末缩进分段","description":"仅正文：句末标点后两个或更多全角空格改为 LF 换行和两个全角缩进；原有行末保持。需核对是否确实应该分段。","rules":[body(Rule::MultilineRegexReplace{pattern:"([。！？!?])　{2,}".into(),replace:"$1\\n　　".into()})]},
        {"id":"notices-v1","name":"广告、章末提示与页眉候选","description":"查找常见提示、网站推广及独立页码/网址页眉。仅列出候选，逐项勾选才排除；可编辑匹配和保留条件。","rules":[Rule::NoticeLines{options:NoticeOptions{include_defaults:true,include_headers:true,ignore_case:true,pattern:None,preserve_pattern:None,keywords:vec![],preserve_keywords:vec![]}}]},
        {"id":"structure-v1","legacy_option":"RemoveDuplicateChapterTitles","name":"结构重复标题","description":"只处理相邻且中间只有空白行的完全重复章节标题；正文不同或无法证明连续时保留。","rules":[Rule::RemoveDuplicateTitles]},
        {"id":"variant-t2s-v1","name":"繁体转简体","description":"可应用修改：把繁体字转为简体（通用字形）。台湾、香港用词可在规则里改转换方向。","rules":[{"kind":"chinese_variant","direction":"t2s","dictionary_version":DICTIONARY_VERSION}]},
        {"id":"variant-s2t-v1","name":"简体转繁体","description":"可应用修改：把简体字转为繁体（通用字形）。台湾正体、香港繁体可在规则里改转换方向。","rules":[{"kind":"chinese_variant","direction":"s2t","dictionary_version":DICTIONARY_VERSION}]},
        {"id":"typography-v1","name":"标题编号与中文标点","description":"既有标题编号转中文、正文邻近中文的标点与配对重复弯引号。默认不识别裸数字标题；网址、邮箱和数字标点保留。","rules":[Rule::ChapterNumbers{style:NumberStyle::Chinese,bare_titles:false},body(Rule::ChinesePunctuation{options:PunctuationOptions{marks:true,ellipsis:true,dashes:true,quotes:true}})]}
    ])
}
impl Compiled {
    pub(crate) fn regex_edits(
        &self,
        input: &str,
        matches_left: &mut usize,
    ) -> Result<Vec<RegexEdit>, ApiError> {
        let limit = if matches!(self.rule, Rule::MultilineRegexReplace { .. }) {
            256 * 1024
        } else {
            65536
        };
        if input.len() > limit {
            return Err(budget());
        }
        let mut edits = Vec::new();
        let mut total = 0usize;
        for captures in self
            .regex
            .as_ref()
            .ok_or_else(invalid)?
            .captures_iter(input)
        {
            *matches_left = matches_left.checked_sub(1).ok_or_else(budget)?;
            let matched = captures.get(0).unwrap();
            let mut result = String::new();
            for part in &self.replacement {
                match part {
                    Part::Text(s) => append(&mut result, s)?,
                    Part::Capture(n) => {
                        if let Some(m) = captures.get(*n) {
                            append(&mut result, m.as_str())?;
                        }
                    }
                }
            }
            if result == matched.as_str() {
                continue;
            }
            total = total.saturating_add(result.len());
            if total > MAX_LINE {
                return Err(budget());
            }
            edits.push(RegexEdit {
                start: matched.start(),
                end: matched.end(),
                replacement: result,
            });
        }
        Ok(edits)
    }
    pub(crate) fn transform(
        &self,
        input: &str,
        matches_left: &mut usize,
    ) -> Result<String, ApiError> {
        match &self.rule {
            Rule::ChinesePunctuation { .. } => self.punctuation.as_ref().ok_or_else(invalid)?.transform(input),
            Rule::RemoveInvisible => Ok(input.chars().filter(|c| !matches!(*c,
                '\u{0000}'..='\u{0008}' | '\u{000b}' | '\u{000c}' | '\u{000e}'..='\u{001f}' | '\u{007f}' | '\u{200b}' | '\u{2060}' | '\u{feff}'
            )).collect()),
            Rule::OcrHanSpaces => Ok(crate::cleanup_ocr::remove_han_spaces(input)),
            Rule::OcrEllipsis => Ok(crate::cleanup_ocr::normalize_ellipsis(input)),
            Rule::ChineseVariant { direction, .. } => {
                // Bound a single physical line before entering the dictionary engine.
                if input.len() > 65536 {
                    return Err(budget());
                }
                let mut output = self.converter.ok_or_else(invalid)?.convert(input);
                if direction.to_simplified() {
                    output = crate::chinese_variant::protect_simplified(input, output);
                }
                if output.len() > MAX_LINE {
                    return Err(budget());
                }
                Ok(output)
            }
            Rule::TrimTrailingSpaces => Ok(input.trim_end_matches([' ', '\t']).to_owned()),
            Rule::NormalizeWidth => Ok(input
                .chars()
                .map(|c| match c {
                    '\u{3000}' => ' ',
                    '\u{ff10}'..='\u{ff19}' | '\u{ff21}'..='\u{ff3a}' | '\u{ff41}'..='\u{ff5a}' => {
                        char::from_u32(c as u32 - 0xfee0).unwrap()
                    }
                    _ => c,
                })
                .collect()),
            Rule::NormalizePunctuation => Ok(input
                .chars()
                .map(|c| match c {
                    '﹐' => '，',
                    '﹑' | '､' => '、',
                    '﹒' | '｡' => '。',
                    '﹔' => '；',
                    '﹕' => '：',
                    '﹖' => '？',
                    '﹗' => '！',
                    '﹙' => '（',
                    '﹚' => '）',
                    _ => c,
                })
                .collect()),
            Rule::LiteralReplace { find, replace } => {
                let mut result = String::new();
                let mut end = 0;
                for (start, matched) in input.match_indices(find) {
                    *matches_left = matches_left.checked_sub(1).ok_or_else(budget)?;
                    append(&mut result, &input[end..start])?;
                    append(&mut result, replace)?;
                    end = start + matched.len();
                }
                append(&mut result, &input[end..])?;
                Ok(result)
            }
            Rule::RegexReplace { .. } => {
                if input.len() > 65536 {
                    return Err(budget());
                }
                let mut result = String::new();
                let mut end = 0;
                for captures in self.regex.as_ref().unwrap().captures_iter(input) {
                    *matches_left = matches_left.checked_sub(1).ok_or_else(budget)?;
                    let matched = captures.get(0).unwrap();
                    append(&mut result, &input[end..matched.start()])?;
                    for part in &self.replacement {
                        match part {
                            Part::Text(s) => append(&mut result, s)?,
                            Part::Capture(n) => {
                                if let Some(m) = captures.get(*n) {
                                    append(&mut result, m.as_str())?;
                                }
                            }
                        }
                    }
                    end = matched.end();
                }
                append(&mut result, &input[end..])?;
                Ok(result)
            }
            _ => Err(invalid()),
        }
    }
}

/// Validate portable rule configuration without applying source-bound selections.
pub fn validate_pipeline(rules: &[Rule]) -> Result<(), ApiError> {
    if rules.is_empty() || rules.len() > 32 {
        return Err(invalid());
    }
    for rule in rules {
        rule.compile()?;
    }
    Ok(())
}

#[cfg(test)]
mod name_tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn configured_name_roundtrips_and_rejects_invalid_metadata() {
        let mut value = json!({"kind":"configured","enabled":true,"scope":"body",
            "name":"正文行尾整理","rule":{"kind":"trim_trailing_spaces"}});
        let rule: Rule = serde_json::from_value(value.clone()).unwrap();
        rule.compile().unwrap();
        assert_eq!(serde_json::to_value(rule).unwrap(), value);
        for name in [
            "".to_string(),
            "  ".to_string(),
            "名字\n".to_string(),
            "a".repeat(257),
        ] {
            value["name"] = json!(name);
            assert!(
                serde_json::from_value::<Rule>(value.clone())
                    .unwrap()
                    .compile()
                    .is_err()
            );
        }
        value.as_object_mut().unwrap().remove("name");
        let old: Rule = serde_json::from_value(value.clone()).unwrap();
        old.compile().unwrap();
        assert_eq!(serde_json::to_value(old).unwrap(), value);
    }
}
