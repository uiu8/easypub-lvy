//! 正文 HTML 转文字、中文数字、时间格式等小工具。
use scraper::{Html, Node as DomNode};

const BLOCK: &[&str] = &[
    "address",
    "article",
    "aside",
    "blockquote",
    "dd",
    "div",
    "dl",
    "dt",
    "figcaption",
    "figure",
    "footer",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "header",
    "hr",
    "li",
    "ol",
    "p",
    "pre",
    "section",
    "table",
    "tr",
    "ul",
];

/// 正文：块级元素与换行各成一行，去掉脚本与样式，每行去掉首尾空白（含全角空格），空行不要。
pub fn html_to_text(html: &str) -> String {
    let looks_html = html.contains('<') && html.contains('>');
    let raw = if looks_html {
        let fragment = Html::parse_fragment(html);
        let mut out = String::new();
        fn walk(node: ego_tree::NodeRef<'_, DomNode>, out: &mut String) {
            for child in node.children() {
                match child.value() {
                    DomNode::Text(t) => out.push_str(t),
                    DomNode::Element(e) => {
                        let name = e.name();
                        if matches!(name, "script" | "style" | "noscript") {
                            continue;
                        }
                        if name == "br" {
                            out.push('\n');
                            continue;
                        }
                        let block = BLOCK.contains(&name);
                        if block {
                            out.push('\n');
                        }
                        walk(child, out);
                        if block {
                            out.push('\n');
                        }
                    }
                    _ => (),
                }
            }
        }
        walk(fragment.tree.root(), &mut out);
        out
    } else {
        decode_entities(html)
    };
    raw.replace('\u{a0}', " ")
        .lines()
        .map(|l| l.trim_matches(|c: char| c.is_whitespace() || c == '\u{3000}'))
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

fn decode_entities(text: &str) -> String {
    if !text.contains('&') {
        return text.to_owned();
    }
    let fragment = Html::parse_fragment(&format!("<p>{}</p>", text.replace('<', "&lt;")));
    fragment.root_element().text().collect()
}

/// `第一百二十三章` → `第123章`（阅读的 toNumChapter）。
pub fn to_num_chapter(text: &str) -> String {
    static RE: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
        regex::Regex::new(
            r"第([零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟0-9]+)([章节回卷集部篇])",
        )
        .unwrap()
    });
    RE.replace_all(text, |c: &regex::Captures<'_>| {
        let n = chinese_number(&c[1])
            .map(|n| n.to_string())
            .unwrap_or_else(|| c[1].to_owned());
        format!("第{}{}", n, &c[2])
    })
    .into_owned()
}

pub fn chinese_number(text: &str) -> Option<u64> {
    if let Ok(n) = text.parse() {
        return Some(n);
    }
    let digit = |c: char| -> Option<u64> {
        Some(match c {
            '0'..='9' => c.to_digit(10)? as u64,
            '零' | '〇' => 0,
            '一' | '壹' => 1,
            '二' | '两' | '贰' => 2,
            '三' | '叁' => 3,
            '四' | '肆' => 4,
            '五' | '伍' => 5,
            '六' | '陆' => 6,
            '七' | '柒' => 7,
            '八' | '捌' => 8,
            '九' | '玖' => 9,
            _ => return None,
        })
    };
    if !text.is_empty() && text.chars().all(|c| digit(c).is_some()) {
        return text
            .chars()
            .try_fold(0u64, |n, c| n.checked_mul(10)?.checked_add(digit(c)?));
    }
    let (mut total, mut section, mut number) = (0u64, 0u64, 0u64);
    let mut any = false;
    for c in text.chars() {
        if let Some(d) = digit(c) {
            number = d;
            any = true;
            continue;
        }
        let unit = match c {
            '十' | '拾' => 10,
            '百' | '佰' => 100,
            '千' | '仟' => 1000,
            '万' => 10_000,
            _ => return None,
        };
        any = true;
        if unit == 10_000 {
            section = section.checked_add(number)?.checked_mul(unit)?;
            total = total.checked_add(section)?;
            section = 0;
        } else {
            section = section.checked_add(
                (if number == 0 && unit == 10 { 1 } else { number }).checked_mul(unit)?,
            )?;
        }
        number = 0;
    }
    if any {
        total.checked_add(section)?.checked_add(number)
    } else {
        None
    }
}

/// Java 风格的时间格式（yyyy MM dd HH mm ss SSS），`offset_hours` 为时区偏移。
pub fn time_format(ms: i64, pattern: &str, offset_hours: i64) -> String {
    let Ok(t) = time::OffsetDateTime::from_unix_timestamp_nanos(i128::from(ms) * 1_000_000) else {
        return String::new();
    };
    let t = t.to_offset(
        time::UtcOffset::from_hms(offset_hours.clamp(-23, 23) as i8, 0, 0)
            .unwrap_or(time::UtcOffset::UTC),
    );
    let mut out = pattern.to_owned();
    for (token, value) in [
        ("yyyy", format!("{:04}", t.year())),
        ("SSS", format!("{:03}", t.millisecond())),
        ("MM", format!("{:02}", u8::from(t.month()))),
        ("dd", format!("{:02}", t.day())),
        ("HH", format!("{:02}", t.hour())),
        ("mm", format!("{:02}", t.minute())),
        ("ss", format!("{:02}", t.second())),
        ("yy", format!("{:02}", t.year() % 100)),
    ] {
        out = out.replace(token, &value);
    }
    out
}

/// 作者名去掉“作者：”前缀与多余空白。
pub fn clean_author(text: &str) -> String {
    let re = regex::Regex::new(r"^\s*(作\s*者|著\s*者|author)\s*[:：]?\s*").unwrap();
    crate::dom::normalize(&re.replace(text, ""))
}
/// 书名去掉首尾空白与书名号。
pub fn clean_name(text: &str) -> String {
    crate::dom::normalize(text.trim().trim_start_matches('《').trim_end_matches('》'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_helpers() {
        for raw in ["二〇二四", "二零二四", "2〇2四", "贰零贰肆"] {
            assert_eq!(chinese_number(raw), Some(2024));
            assert_eq!(to_num_chapter(&format!("第{raw}章 标题")), "第2024章 标题");
        }
        let too_large = "九".repeat(30);
        assert_eq!(chinese_number(&too_large), None);
        let title = format!("第{too_large}章 标题");
        assert_eq!(to_num_chapter(&title), title);
        assert_eq!(
            html_to_text("<p>第一段</p><p>　　第二段&nbsp;</p>甲<br>乙<script>x()</script>"),
            "第一段\n第二段\n甲\n乙"
        );
        assert_eq!(html_to_text("a &amp; b"), "a & b");
        assert_eq!(to_num_chapter("第一百二十三章 开始"), "第123章 开始");
        assert_eq!(chinese_number("十五"), Some(15));
        assert_eq!(chinese_number("一万零三百"), Some(10300));
        assert_eq!(chinese_number("两千"), Some(2000));
        assert_eq!(time_format(0, "yyyy/MM/dd HH:mm", 8), "1970/01/01 08:00");
        assert_eq!(clean_author("作者：甲乙"), "甲乙");
        assert_eq!(clean_name("《书名》"), "书名");
    }
}
