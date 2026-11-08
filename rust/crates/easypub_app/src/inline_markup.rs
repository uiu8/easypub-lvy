//! 正文行内标记（V28，LAY-105–107）：生成 XHTML 时把纯文本里的标记换成元素。
//!
//! · 注音：`｜汉字《hàn zì》` → `<ruby>汉字<rp>（</rp><rt>hàn zì</rt><rp>）</rp></ruby>`；
//! · 着重号：`｜文字《・》`（括号里只有点）→ `<span class="em-dot">文字</span>`；
//! · 纵中横（只在竖排时）：前后不是半角字母或数字、连续不超过 N 位的半角数字 → `<span class="tcy">12</span>`。
//!
//! 必须以全角竖线“｜”开头，避免把中文书名号《》误当成注音。标记不完整时原样保留。
use easypub_core::ApiError;

use crate::navigation_documents::escaped;

const MAX_BASE: usize = 64;
const MAX_RUBY: usize = 64;
const DOTS: &[char] = &['・', '·', '•', '﹅', '●', '﹒', '.'];

enum Piece<'a> {
    Text(&'a str),
    Ruby(&'a str, &'a str),
    Emphasis(&'a str),
}

fn pieces(text: &str) -> Vec<Piece<'_>> {
    let mut out = Vec::new();
    let mut rest = text;
    while let Some(bar) = rest.find('｜') {
        let after = &rest[bar + '｜'.len_utf8()..];
        let parsed = after.find('《').and_then(|open| {
            let base = &after[..open];
            let tail = &after[open + '《'.len_utf8()..];
            let close = tail.find('》')?;
            let ruby = &tail[..close];
            let bad = |s: &str, max: usize| {
                s.is_empty()
                    || s.chars().count() > max
                    || s.contains(['｜', '《', '》', '\n', '\r'])
            };
            (!bad(base, MAX_BASE) && !bad(ruby, MAX_RUBY)).then(|| {
                let consumed =
                    bar + '｜'.len_utf8() + open + '《'.len_utf8() + close + '》'.len_utf8();
                (base, ruby, consumed)
            })
        });
        match parsed {
            Some((base, ruby, consumed)) => {
                if bar > 0 {
                    out.push(Piece::Text(&rest[..bar]));
                }
                if ruby.chars().all(|c| DOTS.contains(&c)) {
                    out.push(Piece::Emphasis(base));
                } else {
                    out.push(Piece::Ruby(base, ruby));
                }
                rest = &rest[consumed..];
            }
            None => {
                let end = bar + '｜'.len_utf8();
                out.push(Piece::Text(&rest[..end]));
                rest = &rest[end..];
            }
        }
    }
    if !rest.is_empty() {
        out.push(Piece::Text(rest));
    }
    out
}

/// 注音和着重号标记作为一个原子，禁止从语法内部截断。
pub(crate) fn splits_markup(text: &str, at: usize) -> bool {
    pieces(text).iter().any(|p| match p {
        Piece::Text(_) => false,
        Piece::Ruby(base, ruby) => {
            let start = base.as_ptr() as usize - text.as_ptr() as usize - '｜'.len_utf8();
            let end =
                ruby.as_ptr() as usize - text.as_ptr() as usize + ruby.len() + '》'.len_utf8();
            start < at && at < end
        }
        Piece::Emphasis(base) => {
            let start = base.as_ptr() as usize - text.as_ptr() as usize - '｜'.len_utf8();
            let end = text[start..].find('》').expect("parsed emphasis") + start + '》'.len_utf8();
            start < at && at < end
        }
    })
}

/// 文字里是否有注音或着重号标记。
pub fn has_markup(text: &str) -> bool {
    text.contains('｜') && pieces(text).iter().any(|p| !matches!(p, Piece::Text(_)))
}

/// 去掉标记，只留基础文字（目录、书名等不能放元素的地方）。
pub fn plain(text: &str) -> String {
    if !text.contains('｜') {
        return text.to_owned();
    }
    pieces(text)
        .into_iter()
        .map(|p| match p {
            Piece::Text(t) => t,
            Piece::Ruby(b, _) | Piece::Emphasis(b) => b,
        })
        .collect()
}

/// 纵中横：前后不是半角字母数字、长度 1..=digits 的半角数字段包上 span。
/// 弯引号在通用断行规则里属于“引号”类，排版引擎会在右引号前、左引号后断行，
/// 句末的“。”后面的右引号因此落到下一行开头（V114）。把右引号连同前一个字、
/// 左引号连同后一个字包进不断行的片段；其余文字照常转义。
fn joined(text: &str) -> Result<String, ApiError> {
    const OPEN: [char; 2] = ['\u{201C}', '\u{2018}'];
    const CLOSE: [char; 2] = ['\u{201D}', '\u{2019}'];
    if !text.contains(OPEN) && !text.contains(CLOSE) {
        return escaped(text);
    }
    let chars: Vec<char> = text.chars().collect();
    let solid = |c: char| !c.is_whitespace() && !OPEN.contains(&c) && !CLOSE.contains(&c);
    let mut out = String::new();
    let mut plain = String::new();
    let mut i = 0;
    while i < chars.len() {
        let close_run = chars[i + 1..]
            .iter()
            .take_while(|c| CLOSE.contains(c))
            .count();
        if solid(chars[i]) && close_run > 0 {
            out.push_str(&escaped(&plain)?);
            plain.clear();
            let piece: String = chars[i..=i + close_run].iter().collect();
            out.push_str(&format!("<span class=\"nb\">{}</span>", escaped(&piece)?));
            i += close_run + 1;
            continue;
        }
        let open_run = chars[i..].iter().take_while(|c| OPEN.contains(c)).count();
        if open_run > 0 && chars.get(i + open_run).is_some_and(|&c| solid(c)) {
            out.push_str(&escaped(&plain)?);
            plain.clear();
            // 只有一个字被引号括起时（如“好”），右引号也一起放进来。
            let end = i + open_run;
            let extra = chars[end + 1..]
                .iter()
                .take_while(|c| CLOSE.contains(c))
                .count();
            let piece: String = chars[i..=end + extra].iter().collect();
            out.push_str(&format!("<span class=\"nb\">{}</span>", escaped(&piece)?));
            i = end + extra + 1;
            continue;
        }
        plain.push(chars[i]);
        i += 1;
    }
    out.push_str(&escaped(&plain)?);
    Ok(out)
}

fn upright_digits(text: &str, digits: u8) -> Result<String, ApiError> {
    if digits == 0 || !text.bytes().any(|b| b.is_ascii_digit()) {
        return joined(text);
    }
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::new();
    let mut plain = String::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i].is_ascii_digit() {
            let start = i;
            while i < chars.len() && chars[i].is_ascii_digit() {
                i += 1;
            }
            let before = start.checked_sub(1).map(|j| chars[j]);
            let after = chars.get(i).copied();
            let isolated = !before.is_some_and(|c| c.is_ascii_alphanumeric())
                && !after.is_some_and(|c| c.is_ascii_alphanumeric());
            let run: String = chars[start..i].iter().collect();
            if isolated && run.len() <= usize::from(digits) {
                out.push_str(&joined(&plain)?);
                plain.clear();
                out.push_str(&format!("<span class=\"tcy\">{run}</span>"));
            } else {
                plain.push_str(&run);
            }
            continue;
        }
        plain.push(chars[i]);
        i += 1;
    }
    out.push_str(&joined(&plain)?);
    Ok(out)
}

/// 生成一段正文的 XHTML 内容。[vertical_digits] 为 None 时是横排（不做纵中横）。
pub fn render(text: &str, vertical_digits: Option<u8>) -> Result<String, ApiError> {
    let digits = vertical_digits.unwrap_or(0);
    if !text.contains('｜') {
        return upright_digits(text, digits);
    }
    let mut out = String::new();
    for piece in pieces(text) {
        match piece {
            Piece::Text(t) => out.push_str(&upright_digits(t, digits)?),
            Piece::Ruby(base, ruby) => out.push_str(&format!(
                "<ruby>{}<rp>（</rp><rt>{}</rt><rp>）</rp></ruby>",
                upright_digits(base, digits)?,
                escaped(ruby)?
            )),
            Piece::Emphasis(base) => out.push_str(&format!(
                "<span class=\"em-dot\">{}</span>",
                upright_digits(base, digits)?
            )),
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ruby_and_emphasis_need_the_full_width_bar() {
        assert_eq!(
            render("读｜汉字《hàn zì》与《红楼梦》", None).unwrap(),
            "读<ruby>汉字<rp>（</rp><rt>hàn zì</rt><rp>）</rp></ruby>与《红楼梦》"
        );
        assert_eq!(
            render("这是｜重点《・・》。", None).unwrap(),
            "这是<span class=\"em-dot\">重点</span>。"
        );
        // 不完整的标记原样保留并转义。
        assert_eq!(
            render("｜没有括号 & 符号", None).unwrap(),
            "｜没有括号 &amp; 符号"
        );
        assert_eq!(render("｜《空》", None).unwrap(), "｜《空》");
        assert!(has_markup("｜甲《jiǎ》") && !has_markup("《书名》") && !has_markup("｜单独"));
        assert_eq!(plain("｜汉字《hàn zì》和｜重点《・》"), "汉字和重点");
    }

    /// V114：句末“。”后的右引号不会被挤到下一行开头，左引号不会留在行尾。
    #[test]
    fn curly_quotes_stay_with_their_neighbours() {
        assert_eq!(
            render("他说：\u{201C}住着。\u{201D}然后走了", None).unwrap(),
            "他说：<span class=\"nb\">\u{201C}住</span>着<span class=\"nb\">。\u{201D}</span>然后走了"
        );
        assert_eq!(
            render("没有引号 & 符号", None).unwrap(),
            "没有引号 &amp; 符号"
        );
        // 竖排数字横排与引号同时出现。
        assert_eq!(
            render("第12章\u{201C}好\u{201D}", Some(2)).unwrap(),
            "第<span class=\"tcy\">12</span>章<span class=\"nb\">\u{201C}好\u{201D}</span>"
        );
    }

    #[test]
    fn vertical_digits_combine_only_short_isolated_runs() {
        assert_eq!(
            render("第12章，共365页，iPhone15，2024年", Some(2)).unwrap(),
            "第<span class=\"tcy\">12</span>章，共365页，iPhone15，2024年"
        );
        assert_eq!(
            render("共365页", Some(3)).unwrap(),
            "共<span class=\"tcy\">365</span>页"
        );
        assert_eq!(render("第12章", Some(0)).unwrap(), "第12章");
        assert_eq!(render("第12章", None).unwrap(), "第12章");
        assert_eq!(
            render("｜第3回《dì sān huí》", Some(2)).unwrap(),
            "<ruby>第<span class=\"tcy\">3</span>回<rp>（</rp><rt>dì sān huí</rt><rp>）</rp></ruby>"
        );
    }
}
