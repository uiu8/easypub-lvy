//! Explicit R1 rule compatibility seam.
//!
//! The old desktop application accepts .NET regular expressions, including
//! constructs that Rust's linear-time `regex` engine intentionally rejects.
//! This module makes that boundary visible: the built-in rules are structured
//! code, a supported custom rule is compiled once, and unsupported syntax is a
//! structured error.  There is no silent fallback to another rule.

use crate::{ApiError, ErrorCode};
use regex::Regex;

pub const DEFAULT_NUMERIC_PATTERN: &str =
    r"^\s*(?<number>\d{1,6})(?:\s+|[.．](?!\d)\s*|[、:_：\-—]\s*)(?<title>\S.*?)\s*$";

/// Reference expression for the *matching part* of the built-in heading rule.
/// It is shown to users and can seed a custom rule; the built-in rule itself
/// stays code, because its prose exclusions cannot be written as a Rust regex.
pub const BUILTIN_CHAPTER_REFERENCE: &str = r"^\s*[【\[（(]?\s*(?:(?:序章|序言|前言|后记|後記|尾声|尾聲|终章|終章|番外篇?)(?:$|[\s:：、（(【\[])|第?\s*[0-9０-９零〇一二两兩三四五六七八九十百千万萬壹贰貳叁參肆伍陆陸柒捌玖拾佰仟]+\s*[章回]|第\s*[0-9０-９零〇一二两兩三四五六七八九十百千万萬壹贰貳叁參肆伍陆陸柒捌玖拾佰仟]+\s*[卷部篇集节])";

/// Read-only description of the built-in recognition, for the rules panel.
pub fn builtin_description() -> serde_json::Value {
    serde_json::json!({
        "chapter": {
            "summary": "常规标题的内置识别是程序逻辑，不是一条正则。",
            "forms": [
                "第十二章、12章、第 12 章、第十二回（数字可用阿拉伯数字、全角数字、中文小写或大写）",
                "第二卷、第二部、第二篇、第二集、第三节（须带“第”）",
                "序章、序言、前言、后记、尾声、终章、番外、番外篇（后面为空或接空格、冒号、顿号、括号）",
                "以上形式外包一层【】、[]、（）、() 也可识别"
            ],
            "exclusions": [
                "“回头、回来、回到、回去、回事、回答、回忆”等以“回”开头的正文不算标题",
                "作者说明不算标题，例如“两章合一章”“第X章更新完毕”“今天更新X字”，以及括号里写“求票、求月票、加更、万字”等",
                "全书以“章”为主时，紧接正文、带句号或引号的长句式“第X回/节/卷…”视为正文",
                "每行最多 256 字"
            ],
            "hierarchy": "开启层级时：卷、部、篇、集为卷级；节为节级；章、回为章级。卷、章、节的自定义表达式优先于内置规则。",
            "reference_regex": BUILTIN_CHAPTER_REFERENCE,
            "reference_note": "参考正则只对应上面的“识别形式”，不含排除项。填写常规标题正则后，内置识别和正文排除都不再使用。"
        },
        "numeric": {
            "summary": "纯数字标题的内置规则就是这条正则（由程序按相同语义执行）。",
            "regex": DEFAULT_NUMERIC_PATTERN,
            "notes": [
                "编号 1–9999；编号后接空格、点号、顿号、冒号、下划线或横线",
                "点号后紧跟数字的（如 1.5）不算",
                "标题中至少要有一个文字；候选标题后还需满足“至少几行正文”"
            ],
            "edit_note": r"原样保留时使用内置执行；修改后按自定义正则执行，而识别器不支持其中的 (?!\d) 环视，需要改写。"
        }
    })
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NumericHeading {
    pub number: u32,
    pub title: String,
}

#[derive(Clone, Debug)]
pub enum NumericRule {
    Builtin,
    Custom { pattern: String, regex: Regex },
}

impl NumericRule {
    pub fn compile(pattern: Option<&str>) -> Result<Self, ApiError> {
        let effective = pattern
            .filter(|value| !value.trim().is_empty())
            .unwrap_or(DEFAULT_NUMERIC_PATTERN);
        if effective == DEFAULT_NUMERIC_PATTERN {
            return Ok(Self::Builtin);
        }
        reject_unsupported_regex(effective)?;
        let normalized = normalize_dotnet_named_groups(effective);
        let regex = Regex::new(&normalized).map_err(|_| {
            ApiError::new(ErrorCode::InvalidRule, "compile_numeric_rule", "edit_rule")
        })?;
        if !regex.capture_names().flatten().any(|name| name == "number")
            || !regex.capture_names().flatten().any(|name| name == "title")
        {
            return Err(ApiError::new(
                ErrorCode::InvalidRule,
                "compile_numeric_rule",
                "add_number_and_title_groups",
            ));
        }
        Ok(Self::Custom {
            pattern: effective.to_owned(),
            regex,
        })
    }

    pub fn pattern(&self) -> &str {
        match self {
            Self::Builtin => DEFAULT_NUMERIC_PATTERN,
            Self::Custom { pattern, .. } => pattern,
        }
    }

    pub fn matches(&self, line: &str) -> Option<NumericHeading> {
        let matched = match self {
            Self::Builtin => builtin_numeric(line),
            Self::Custom { regex, .. } => {
                let captures = regex.captures(line)?;
                numeric_from_captures(
                    captures.name("number")?.as_str(),
                    captures.name("title")?.as_str(),
                )
            }
        }?;
        Some(matched)
    }
}

pub fn reject_unsupported_regex(pattern: &str) -> Result<(), ApiError> {
    // These constructs are valid or commonly used in .NET, but are not
    // accepted by the linear-time Rust engine. Treating them as a no-op would
    // turn a rule failure into a misleading zero-match result.
    const UNSUPPORTED: [&str; 6] = ["(?=", "(?!", "(?<=", "(?<!", "\\1", "\\k<"];
    if UNSUPPORTED.iter().any(|marker| pattern.contains(marker)) {
        return Err(ApiError::new(
            ErrorCode::UnsupportedRule,
            "compile_numeric_rule",
            "choose_supported_regex_or_compatibility_engine",
        ));
    }
    Ok(())
}

pub fn is_default_heading(line: &str) -> bool {
    let mut text = line.trim();
    if let Some(first) = text.chars().next()
        && matches!(first, '【' | '[' | '（' | '(')
    {
        text = text[first.len_utf8()..].trim_start();
    }
    for special in [
        "序章",
        "序言",
        "前言",
        "后记",
        "後記",
        "尾声",
        "尾聲",
        "终章",
        "終章",
        "番外",
        "番外篇",
    ] {
        if let Some(rest) = text.strip_prefix(special)
            && (rest.is_empty() || rest.chars().next().is_some_and(is_heading_separator)) {
                return true;
            }
    }

    let had_di = text.starts_with('第');
    if had_di {
        text = text['第'.len_utf8()..].trim_start();
    }
    let number_end = text
        .char_indices()
        .take_while(|(_, ch)| is_heading_numeral(*ch))
        .map(|(index, ch)| index + ch.len_utf8())
        .last()
        .unwrap_or(0);
    if number_end == 0 {
        return false;
    }
    text = text[number_end..].trim_start();
    let Some(marker) = text.chars().next() else {
        return false;
    };
    let rest = &text[marker.len_utf8()..];
    match marker {
        '章' => true,
        '回' => !matches!(
            rest.chars().next(),
            Some('头' | '頭' | '到' | '来' | '來' | '去' | '事' | '答' | '忆' | '憶')
        ),
        '卷' | '部' | '篇' | '集' | '节' => had_di,
        _ => false,
    }
}

/// Keep the v1 source index stable for saved edit recipes. New imports and
/// repair proposals use book context to distinguish ordinal prose from headings.
pub fn is_author_note_heading(title: &str) -> bool {
    let text = title.trim();
    let bracketed = (text.starts_with('（') && text.ends_with('）'))
        || (text.starts_with('(') && text.ends_with(')'));
    let inner = text.trim_start_matches(['（', '(']);
    // An explicit chapter heading may legitimately mention an update or word
    // count in its title. Do not demote it solely because it is parenthesized.
    if inner.starts_with('第') && crate::source::numbered_heading(inner).is_some() {
        return false;
    }
    let quantity_note = crate::source::numbered_heading(inner)
        .is_some_and(|(_, marker)| marker == '章')
        && inner.split_once('章').is_some_and(|(_, rest)| {
            let rest = rest.trim_start();
            let update_complete = ["更新完毕", "更新完畢", "更新完成", "更新结束", "更新結束"]
                .iter()
                .any(|prefix| {
                    rest.strip_prefix(prefix).is_some_and(|tail| {
                        tail.is_empty()
                            || tail.starts_with(['！', '!', '。', '，', ',', '；', ';', '了'])
                    })
                });
            let update_with_count = [
                "更新",
                "已更新",
                "已经更新",
                "已經更新",
                "今天更新",
                "今日更新",
            ]
            .iter()
            .any(|prefix| rest.starts_with(prefix))
                && rest
                    .split_once('字')
                    .is_some_and(|(before, _)| before.chars().any(is_heading_numeral));
            [
                "合一章",
                "合为一章",
                "合為一章",
                "合起来",
                "合起來",
                "加起来",
                "加起來",
                "并作",
                "併作",
            ]
            .iter()
            .any(|prefix| rest.starts_with(prefix))
                || update_complete
                || update_with_count
                || (["共", "总共", "一共"]
                    .iter()
                    .any(|prefix| rest.starts_with(prefix))
                    && rest.contains(['字', '更']))
        });
    quantity_note
        || bracketed
            && [
                "加起来",
                "加起來",
                "字以上",
                "多字",
                "千字",
                "万字",
                "萬字",
                "求票",
                "求月票",
                "求订阅",
                "求訂閱",
                "更新",
                "三更",
                "两更",
                "兩更",
            ]
            .iter()
            .any(|word| text.contains(word))
}

pub fn is_prose_heading(title: &str, dominant: Option<char>) -> bool {
    if is_author_note_heading(title) {
        return true;
    }
    let Some((_, marker @ ('回' | '节' | '卷' | '部' | '篇' | '集'))) =
        crate::source::numbered_heading(title)
    else {
        return false;
    };
    if dominant == Some(marker) {
        return false;
    }
    let rest = title.split_once(marker).map(|(_, rest)| rest).unwrap_or("");
    let attached = !rest.is_empty() && !rest.starts_with(char::is_whitespace);
    let sentence = rest.contains(['。', '；', '“', '”'])
        || (rest.contains(['，', ',']) && rest.chars().count() > 16);
    attached && sentence && dominant.is_some()
}

pub fn dominant_marker<'a>(titles: impl Iterator<Item = &'a str>) -> Option<char> {
    let mut counts = std::collections::BTreeMap::<char, usize>::new();
    for title in titles {
        if let Some((_, unit @ ('章' | '回' | '节'))) = crate::source::numbered_heading(title) {
            *counts.entry(unit).or_default() += 1;
        }
    }
    counts
        .into_iter()
        .max_by_key(|(unit, count)| (*count, *unit == '章'))
        .map(|(unit, _)| unit)
}

fn builtin_numeric(line: &str) -> Option<NumericHeading> {
    let line = line.trim();
    let mut end = 0;
    for (index, ch) in line.char_indices() {
        if !ch.is_ascii_digit() || index >= 6 {
            break;
        }
        end = index + 1;
    }
    if end == 0 {
        return None;
    }
    let number = line[..end].parse::<u32>().ok()?;
    if !(1..=9999).contains(&number) {
        return None;
    }
    let mut rest = &line[end..];
    if matches!(rest.chars().next(), Some('.' | '．')) {
        let separator_len = rest.chars().next()?.len_utf8();
        rest = &rest[separator_len..];
        if rest.chars().next().is_some_and(char::is_numeric) {
            return None;
        }
        rest = rest.trim_start();
    } else if rest.chars().next().is_some_and(char::is_whitespace) {
        rest = rest.trim_start();
    } else if matches!(
        rest.chars().next(),
        Some('、' | ':' | '_' | '：' | '-' | '—')
    ) {
        let separator_len = rest.chars().next()?.len_utf8();
        rest = rest[separator_len..].trim_start();
    } else {
        return None;
    }
    let title = rest.trim_end();
    if title.is_empty() || !title.chars().any(char::is_alphabetic) {
        return None;
    }
    Some(NumericHeading {
        number,
        title: title.to_owned(),
    })
}

fn numeric_from_captures(number: &str, title: &str) -> Option<NumericHeading> {
    let number = number.parse::<u32>().ok()?;
    if !(1..=9999).contains(&number) || !title.chars().any(char::is_alphabetic) {
        return None;
    }
    Some(NumericHeading {
        number,
        title: title.trim().to_owned(),
    })
}

fn normalize_dotnet_named_groups(pattern: &str) -> String {
    let mut normalized = String::with_capacity(pattern.len());
    let mut index = 0;
    while index < pattern.len() {
        let rest = &pattern[index..];
        if rest.starts_with("(?<") {
            let marker = pattern.as_bytes().get(index + 3).copied();
            if !matches!(marker, Some(b'=') | Some(b'!')) {
                normalized.push_str("(?P<");
                index += 3;
                continue;
            }
        }
        let ch = rest.chars().next().expect("index is a char boundary");
        normalized.push(ch);
        index += ch.len_utf8();
    }
    normalized
}

fn is_heading_numeral(ch: char) -> bool {
    ch.is_ascii_digit()
        || ('０'..='９').contains(&ch)
        || "零〇一二两兩三四五六七八九十百千万萬壹贰貳叁參肆伍陆陸柒捌玖拾佰仟".contains(ch)
}

fn is_heading_separator(ch: char) -> bool {
    ch.is_whitespace() || matches!(ch, ':' | '：' | '、' | '（' | '(' | '【' | '[')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builtin_reference_regex_covers_the_matching_part() {
        let reference = Regex::new(&normalize_dotnet_named_groups(BUILTIN_CHAPTER_REFERENCE)).unwrap();
        reject_unsupported_regex(BUILTIN_CHAPTER_REFERENCE).unwrap();
        for line in [
            "第十二章 开始",
            "12章 测试",
            "第 12 章",
            "第十二回 回目",
            "第二卷 风起",
            "第三节 小节",
            "序章",
            "番外篇：后日谈",
            "【第一章】",
            "（第３章 续）",
        ] {
            assert!(is_default_heading(line), "{line}");
            assert!(reference.is_match(line), "{line}");
        }
        for line in ["这是一段正文", "二卷书", "卷首语", "番外地"] {
            assert!(!is_default_heading(line), "{line}");
            assert!(!reference.is_match(line), "{line}");
        }
        let description = builtin_description();
        assert_eq!(description["numeric"]["regex"], DEFAULT_NUMERIC_PATTERN);
        assert_eq!(description["chapter"]["reference_regex"], BUILTIN_CHAPTER_REFERENCE);
    }

    #[test]
    fn builtin_heading_keeps_markers_and_prose_exclusions() {
        assert!(is_default_heading("第一章 开始"));
        assert!(is_default_heading("八百三十章 赌徒"));
        assert!(is_default_heading("第十卷 上卷"));
        assert!(is_default_heading("序章"));
        assert!(!is_default_heading("九节鞭、三节棍，随意变换"));
        assert!(!is_default_heading("九回头看向门口"));
        assert!(is_prose_heading("第三卷还差几页。", Some('章')));
        assert!(!is_prose_heading("第三卷 新的开始", Some('章')));
        assert!(!is_prose_heading("第三卷新的开始", Some('章')));
        assert!(!is_prose_heading("第三回人生如梦。", Some('回')));
    }

    #[test]
    fn builtin_numeric_preserves_dot_lookahead_semantics() {
        let rule = NumericRule::compile(None).unwrap();
        assert_eq!(rule.matches("1. 第一章").unwrap().number, 1);
        assert_eq!(rule.matches("1. 𠮷").unwrap().title, "𠮷");
        assert!(rule.matches("1.2 不是标题").is_none());
        assert!(rule.matches("10000 标题").is_none());
    }

    #[test]
    fn custom_rule_is_explicit_and_failures_are_not_silent() {
        let rule = NumericRule::compile(Some(r"^第(?<number>\d+)章\s+(?<title>.+)$")).unwrap();
        assert_eq!(rule.matches("第12章 自定义").unwrap().number, 12);
        assert_eq!(
            NumericRule::compile(Some("[")).unwrap_err().code,
            ErrorCode::InvalidRule
        );
        assert_eq!(
            NumericRule::compile(Some(r"^(?<number>\d+)(?<title>.+)$"))
                .unwrap()
                .matches("aaaa!"),
            None
        );
        assert_eq!(
            NumericRule::compile(Some(r"^(?<number>\d+)(?!\d)(?<title>.+)$"))
                .unwrap_err()
                .code,
            ErrorCode::UnsupportedRule
        );
    }
}
