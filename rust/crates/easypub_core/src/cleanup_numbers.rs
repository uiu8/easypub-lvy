//! Numeric spelling changes preserve values; optional bare titles are explicit structure edits.
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Style {
    Chinese,
    Arabic,
}

fn digit(c: char) -> Option<u32> {
    match c {
        '０'..='９' => Some(c as u32 - '０' as u32),
        '0'..='9' => c.to_digit(10),
        _ => None,
    }
}
fn group(n: u32, omit_one: bool) -> String {
    let digits = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九'];
    let mut result = String::new();
    let mut zero = false;
    for (divisor, unit) in [(1000, "千"), (100, "百"), (10, "十"), (1, "")] {
        let d = n / divisor % 10;
        if d == 0 {
            if !result.is_empty() && !n.is_multiple_of(divisor) {
                zero = true;
            }
            continue;
        }
        if zero {
            result.push('零');
            zero = false;
        }
        if !(omit_one && divisor == 10 && d == 1 && result.is_empty()) {
            result.push(digits[d as usize]);
        }
        result.push_str(unit);
    }
    result
}
pub(crate) fn chinese(n: u32) -> String {
    if n == 0 {
        return "零".into();
    }
    if n < 10000 {
        return group(n, true);
    }
    let mut s = format!("{}万", group(n / 10000, true));
    let low = n % 10000;
    if low != 0 {
        if low < 1000 {
            s.push('零');
        }
        s.push_str(&group(low, false));
    }
    s
}
fn value(text: &str) -> Option<u32> {
    let text = text
        .replace(['兩', '两'], "二")
        .replace('萬', "万")
        .replace('〇', "零");
    let n = crate::source::parse_number(&text)?;
    if n > 99_999_999 {
        return None;
    }
    // Unitless digits are unambiguous. Reject colloquial/malformed unit sequences,
    // e.g. 一百一 could mean 101 or 110; never choose a value for the author.
    if text.chars().any(|c| matches!(c, '十' | '百' | '千' | '万'))
        && text != chinese(n)
        && !(n < 20 && text == format!("一{}", chinese(n)))
    {
        return None;
    }
    Some(n)
}
fn number(n: u32, style: &Style) -> String {
    match style {
        Style::Chinese => chinese(n),
        Style::Arabic => n.to_string(),
    }
}
pub(crate) fn marked(text: &str, style: &Style) -> Option<String> {
    let start = text.len() - text.trim_start().len();
    let mut p = start;
    if text[p..].starts_with(['【', '[', '（', '(']) {
        p += text[p..].chars().next()?.len_utf8();
    }
    p += text[p..].len() - text[p..].trim_start().len();
    if text[p..].starts_with('第') {
        p += '第'.len_utf8();
    }
    p += text[p..].len() - text[p..].trim_start().len();
    let end = text[p..]
        .char_indices()
        .find(|(_, c)| matches!(c, '章' | '回' | '节' | '卷' | '部' | '篇' | '集'))?
        .0
        + p;
    let numeral = text[p..end].trim_end();
    let n = value(numeral)?;
    Some(format!(
        "{}{}{}",
        &text[..p],
        number(n, style),
        &text[p + numeral.len()..]
    ))
}
pub(crate) fn bare(text: &str, style: &Style) -> Option<String> {
    bare_with_marker(text, style, '章')
}
pub(crate) fn bare_with_marker(text: &str, style: &Style, marker: char) -> Option<String> {
    let leading = text.len() - text.trim_start().len();
    let content = &text[leading..];
    let end = content
        .char_indices()
        .take_while(|(_, c)| digit(*c).is_some())
        .map(|(i, c)| i + c.len_utf8())
        .last()?;
    let digits = &content[..end];
    if digits.chars().count() > 8 {
        return None;
    }
    let n = digits
        .chars()
        .try_fold(0u32, |v, c| v.checked_mul(10)?.checked_add(digit(c)?))?;
    let separator = content[end..].chars().next()?;
    let mut title = &content[end + separator.len_utf8()..];
    if matches!(separator, '.' | '．') && title.chars().next().is_some_and(char::is_numeric) {
        return None;
    }
    if !separator.is_whitespace()
        && !matches!(separator, '.' | '．' | '、' | ':' | '：' | '_' | '-' | '—')
    {
        return None;
    }
    title = title.trim_start();
    if !title.chars().any(char::is_alphabetic) {
        return None;
    }
    Some(format!(
        "{}第{}{marker} {}",
        &text[..leading],
        number(n, style),
        title
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn representations_keep_values_wrappers_spacing_and_large_numbers() {
        assert_eq!(
            marked("第一百〇一章 题", &Style::Arabic).as_deref(),
            Some("第101章 题")
        );
        for (input, expected) in [
            ("第００１章 雨夜", "第一章 雨夜"),
            (" 【第 １００１０ 回 标题】 ", " 【第 一万零一十 回 标题】 "),
            ("第二十万卷 名称", "第二十万卷 名称"),
        ] {
            assert_eq!(marked(input, &Style::Chinese).as_deref(), Some(expected));
        }
        assert_eq!(
            marked("第两百章 题", &Style::Arabic).as_deref(),
            Some("第200章 题")
        );
        assert_eq!(
            bare("　００１. 雨夜 ", &Style::Chinese).as_deref(),
            Some("　第一章 雨夜 ")
        );
        assert_eq!(
            bare("10000000 标题", &Style::Chinese).as_deref(),
            Some("第一千万章 标题")
        );
        for s in ["一百一章 题", "第一二十章 题", "第一亿章 题"] {
            assert!(marked(s, &Style::Arabic).is_none());
        }
        for s in ["3.14 元", "12:30", "123456789 题", "2024-09-27", "12 345"] {
            assert!(bare(s, &Style::Chinese).is_none(), "{s}");
        }
    }
}
