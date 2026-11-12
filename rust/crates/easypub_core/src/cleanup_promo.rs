//! 网文下载里常见的四类多余文字：接在正文后面的推广语、标题末尾的求票和更新说明、
//! 章末的作者留言、分页留下的残行。都只按明确的字样删，不猜；删的范围尽量小——
//! 一行里既有正文又有推广语时，只去掉推广的那一段。
//!
//! 每个函数拿一行（不含换行符），返回处理后的这一行；整行都该去掉时返回空串。

/// 括号里出现这些字样，整段括号就是推广语。
const PROMOTION: [&str; 17] = [
    "未完待续",
    "请搜索",
    "最快更新",
    "更新最快",
    "更新更快",
    "本站",
    "手机用户",
    "手机阅读",
    "手机同步阅读",
    "无弹窗",
    "推荐票",
    "月票",
    "您的支持",
    "qidian",
    "最新章节",
    "加入书签",
    "首发",
];

/// 从这些字样起到行尾都是推广语（行尾那一段不超过 90 个字时才删）。
const TAIL_LEADS: [&str; 11] = [
    "复制本地址到浏览器",
    "跪求百度一下",
    "最快更新，无弹窗",
    "纯文字在线阅读",
    "手机同步阅读请访问",
    "本站域名",
    "为您提供大神",
    "最新章节请访问",
    "请记住本站",
    "记住本站",
    "一秒记住",
];

fn opening(close: char) -> Option<char> {
    match close {
        '）' => Some('（'),
        ')' => Some('('),
        '】' => Some('【'),
        ']' => Some('['),
        _ => None,
    }
}

fn closing(open: char) -> Option<char> {
    match open {
        '（' | '(' => Some(if open == '（' { '）' } else { ')' }),
        _ => None,
    }
}

/// 从 `start`（一个左括号的位置）找配对的右括号，圆括号全角半角混用也算配上；
/// 返回右括号之后的位置。超过 240 个字没配上就算没有。
fn group_end(text: &str, start: usize) -> Option<usize> {
    let mut depth = 0usize;
    for (count, (offset, c)) in text[start..].char_indices().enumerate() {
        if count > 240 {
            return None;
        }
        match c {
            '（' | '(' => depth += 1,
            '）' | ')' => {
                depth -= 1;
                if depth == 0 {
                    return Some(start + offset + c.len_utf8());
                }
            }
            _ => {}
        }
    }
    None
}

fn has(text: &str, words: &[&str]) -> bool {
    let lower = text.to_ascii_lowercase();
    words.iter().any(|w| lower.contains(w))
}

fn substance(text: &str) -> bool {
    text.chars().any(char::is_alphanumeric)
}

/// 去掉后如果这一行没有实际内容了，就整行不要；否则只去掉行尾多出来的空白。
fn settle(original: &str, result: String) -> String {
    if result == original {
        return result;
    }
    if !substance(&result) {
        return String::new();
    }
    result.trim_end_matches([' ', '\t', '\u{3000}']).to_owned()
}

/// 行内推广语：正文后面括号里的“未完待续……投推荐票、月票”、对白里插进来的
/// “本文由 某站 首发”、行尾的“请搜索……”“复制本地址到浏览器……”。
pub(crate) fn strip_inline(line: &str) -> String {
    if line.len() > 65536 {
        return line.to_owned();
    }
    let mut out = String::with_capacity(line.len());
    let mut rest = line;
    while let Some(start) = rest.find(['（', '(']) {
        out.push_str(&rest[..start]);
        match group_end(rest, start) {
            Some(end) if has(&rest[start..end], &PROMOTION) => rest = &rest[end..],
            Some(end) => {
                out.push_str(&rest[start..end]);
                rest = &rest[end..];
            }
            // 没有右括号、又短又带推广字样的，是被截断的推广语，到行尾都不要。
            None if rest[start..].chars().count() <= 60 && has(&rest[start..], &PROMOTION) => {
                rest = "";
            }
            None => {
                let open = rest[start..].chars().next().map_or(1, char::len_utf8);
                out.push_str(&rest[start..start + open]);
                rest = &rest[start + open..];
            }
        }
    }
    out.push_str(rest);
    // “本文由 …… 首发”：两头的字样都在，中间不超过 40 个字。
    while let Some(start) = out.find("本文由") {
        let after = start + "本文由".len();
        let Some(length) = out[after..].find("首发") else {
            break;
        };
        if out[after..after + length].chars().count() > 40 {
            break;
        }
        out.replace_range(start..after + length + "首发".len(), "");
    }
    let cut = TAIL_LEADS
        .iter()
        .filter_map(|lead| out.find(lead))
        .min()
        .filter(|&at| out[at..].chars().count() <= 90);
    if let Some(at) = cut {
        // 引号里的不算行尾：对白要留着后引号。
        let quote = out[at..].rfind('”').map(|i| at + i);
        match quote {
            Some(q) => out.replace_range(at..q, ""),
            None => out.truncate(at),
        }
    }
    settle(line, out)
}

/// 标题末尾括号里是这些内容时，是求票、更新或字数说明，不是标题的一部分。
const TAIL_WORDS: [&str; 22] = [
    "求",
    "票",
    "更",
    "盟主",
    "感谢",
    "订阅",
    "打赏",
    "上架",
    "保底",
    "推荐",
    "收藏",
    "还债",
    "加餐",
    "贺",
    "万字",
    "大章",
    "补",
    "首订",
    "粉丝",
    "生日快乐",
    "新年",
    "节快乐",
];

fn word_count_tag(inner: &str) -> bool {
    let inner = inner.trim();
    let digits = inner
        .trim_end_matches(['k', 'K', 'w', 'W', '万', '千', '字', '+'])
        .trim();
    digits.len() < inner.len()
        && !digits.is_empty()
        && digits.chars().all(|c| c.is_ascii_digit() || c == '.')
}

/// 标题尾巴：“第二十五章 入山（1350票加更）”“……（第三更求月票）”“……（3K）”，
/// 以及下载站加在标题后面的“免费阅读：，！”。“（上）”“（一）”这类分段照旧保留。
pub(crate) fn strip_heading_tail(line: &str) -> String {
    let mut text = line.trim_end();
    if let Some(at) = text.rfind("免费阅读")
        && text[at..].chars().count() <= 10
        && at > 0
    {
        text = text[..at].trim_end();
    }
    loop {
        let Some(close) = text.chars().last() else {
            break;
        };
        let Some(open) = opening(close) else {
            break;
        };
        let Some(start) = text.rfind(open) else {
            break;
        };
        let inner = &text[start + open.len_utf8()..text.len() - close.len_utf8()];
        // 前面要留得下标题本身。
        if start == 0
            || !substance(&text[..start])
            || !(has(inner, &TAIL_WORDS) || word_count_tag(inner))
        {
            break;
        }
        text = text[..start].trim_end();
    }
    if text.len() == line.trim_end().len() {
        line.to_owned()
    } else {
        text.to_owned()
    }
}

const NOTE_WORDS: [&str; 10] = [
    "未完待续",
    "本章完",
    "求月票",
    "求推荐",
    "求订阅",
    "求收藏",
    "求打赏",
    "求票",
    "月票",
    "推荐票",
];

/// “第二章大概十一点左右”“第三章争取一点前出来”这类更新预告。
const TIMING: [&str; 9] = [
    "点前",
    "点左右",
    "点半",
    "今天还有",
    "稍后",
    "争取",
    "送上",
    "下一章",
    "还有一章",
];

/// 章末留言和求票：整行是“ps：……”、整行括号里的更新预告或求票、单独一行的“未完待续”。
/// 只认整行；夹在正文里的归“行内推广语”。
pub(crate) fn strip_author_note(line: &str) -> String {
    let text = line.trim();
    let count = text.chars().count();
    if count == 0 || count > 200 {
        return line.to_owned();
    }
    let unwrapped = text.trim_start_matches(['（', '(', '【', '[']).trim_start();
    let lower = unwrapped.to_ascii_lowercase();
    let lower = lower
        .strip_prefix('ｐ')
        .map_or(lower.clone(), |r| format!("p{r}"));
    let postscript = lower
        .strip_prefix("ps")
        .or_else(|| lower.strip_prefix("p.s"))
        .is_some_and(|rest| rest.starts_with([':', '：', '.', '．', '，', ',', ' ', '\u{3000}']));
    // 整行由一个或几个括号段组成（“（第一章，下一章十点前。）（未完待续）”），
    // 或者只有左括号、没写右括号。
    let mut rest = text;
    let mut groups = 0;
    while rest.chars().next().and_then(closing).is_some() {
        let Some(end) = group_end(rest, 0) else {
            break;
        };
        groups += 1;
        rest = rest[end..].trim_start();
    }
    let whole_bracket = (groups > 0 && rest.is_empty())
        || (text.starts_with(['（', '(']) && !text.contains(['）', ')']));
    let noted = has(text, &NOTE_WORDS);
    let timing = text.contains('章') && has(text, &TIMING);
    if postscript
        || (whole_bracket && count <= 120 && (noted || timing))
        || (count <= 40 && has(text, &NOTE_WORDS[2..8]))
        || matches!(text.trim_matches(['。', '.', '…', ' ']), "未完待续")
    {
        String::new()
    } else {
        line.to_owned()
    }
}

/// 一段“(第2/2页)”的结束位置：`start` 处是左括号。
fn page_mark_end(text: &str, start: usize) -> Option<usize> {
    let mut chars = text[start..].char_indices();
    let (_, open) = chars.next()?;
    let close = closing(open)?;
    let rest = &text[start + open.len_utf8()..];
    let body = rest.strip_prefix('第')?;
    let end = body.find(['）', ')'])?;
    let inner = &body[..end];
    let (page, total) = inner.strip_suffix('页')?.split_once('/')?;
    let number = |s: &str| !s.trim().is_empty() && s.trim().chars().all(|c| c.is_ascii_digit());
    (number(page) && number(total) && inner.len() <= 16)
        .then(|| {
            start
                + open.len_utf8()
                + '第'.len_utf8()
                + end
                + body[end..].chars().next().map_or(0, char::len_utf8)
        })
        .filter(|_| matches!(close, '）' | ')'))
}

/// 分页残留：“（本章未完，请点击下一页继续阅读）……(第2/2页)”“本章未完，请翻页”
/// “热门推荐:、、、、”“（本章完）”和下载站插在每页开头的“为您提供……最快更新”。
pub(crate) fn strip_paging(line: &str) -> String {
    let text = line.trim();
    let count = text.chars().count();
    if count == 0 {
        return line.to_owned();
    }
    let short = count <= 80;
    let bare = text.trim_matches(['（', '(', '【', '）', ')', '】', ' ']);
    if (short && text.contains("本章未完") && has(text, &["下一页", "翻页", "继续阅读"]))
        || bare == "本章完"
        || (text.starts_with("热门推荐") && !substance(&text["热门推荐".len()..]))
        || (short && text.starts_with("为您提供") && has(text, &["最快更新", "最新章节"]))
        || (count <= 30 && text.starts_with("『』") && has(text, &["最快更新", "最新章节"]))
    {
        return String::new();
    }
    let mut out = String::with_capacity(line.len());
    let mut rest = line;
    while let Some(start) = rest.find(['（', '(']) {
        out.push_str(&rest[..start]);
        match page_mark_end(rest, start) {
            Some(end) => rest = &rest[end..],
            None => {
                let open = rest[start..].chars().next().map_or(1, char::len_utf8);
                out.push_str(&rest[start..start + open]);
                rest = &rest[start + open..];
            }
        }
    }
    out.push_str(rest);
    settle(line, out)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn inline_promotions_leave_the_prose() {
        for (before, after) in [
            (
                "　　没等她开口，他补了一句：“他姓林。”(未完待续。如果您喜欢这部作品，欢迎您来起点（qidian）投推荐票、月票，您的支持，就是我最大的动力。手机用户请到m.qidian阅读。)",
                "　　没等她开口，他补了一句：“他姓林。”",
            ),
            (
                "　　“是。本文由　www.example.invalid　首发”老周一脸无所谓地喝茶。",
                "　　“是。”老周一脸无所谓地喝茶。",
            ),
            (
                "　　小满今年十四岁，一脸稚气。(请搜索，更新最快的站!)看着像个孩子。",
                "　　小满今年十四岁，一脸稚气。看着像个孩子。",
            ),
            (
                "　　好像很喜欢那个少年。(请搜索，",
                "　　好像很喜欢那个少年。",
            ),
            (
                "　　现在的自己连一招都接不住。复制本地址到浏览器看最新章节%77%77%77%2e%63%6f%6d",
                "　　现在的自己连一招都接不住。",
            ),
            ("　　最快更新，无弹窗阅读请。", ""),
            ("　　老周感觉到了杀意。(未完待续)", "　　老周感觉到了杀意。"),
            // 普通的括号、提到网站的正文不动。
            ("　　他（指着门）说：“走。”", "　　他（指着门）说：“走。”"),
            (
                "　　这本书在起点首发那天，他正好休假。",
                "　　这本书在起点首发那天，他正好休假。",
            ),
            (
                "　　“你去百度搜索一下不就知道了？”他笑道。",
                "　　“你去百度搜索一下不就知道了？”他笑道。",
            ),
        ] {
            assert_eq!(strip_inline(before), after, "{before}");
        }
    }
    #[test]
    fn heading_tails_go_but_parts_stay() {
        for (before, after) in [
            ("第二十五章 入山（1350票加更）", "第二十五章 入山"),
            (
                "第二百五十五章 路见不平（第三更贺黄金总盟）",
                "第二百五十五章 路见不平",
            ),
            ("第三章 来客（第一更求推荐票）", "第三章 来客"),
            ("番外：生日（3K）", "番外：生日"),
            (
                "第一百零三章 等风等雪（为盟主加更！）",
                "第一百零三章 等风等雪",
            ),
            ("　　第四十章夜行免费阅读：，！", "　　第四十章夜行"),
            ("第五十三章 喜庆（上架求票）（第二更）", "第五十三章 喜庆"),
            ("第一五三章 烧楼（上）", "第一五三章 烧楼（上）"),
            ("第十七章 学院的新生（下）", "第十七章 学院的新生（下）"),
            ("（求月票）", "（求月票）"),
        ] {
            assert_eq!(strip_heading_tail(before), after, "{before}");
        }
    }
    #[test]
    fn author_notes_are_whole_lines_only() {
        for gone in [
            "　　ps：第二更送上，求月票和推荐票~",
            "　　（第二章大概十一点左右。）",
            "　　（第一章，下一章十点前。）（未完待续）",
            "　　(未完待续)",
            "　　未完待续。",
            "　　大的剧情即将展开，求票^_^",
            "　　(三章完毕,累死了,请投月票双倍期间,谁敢抢我的月票,我敢他没完",
        ] {
            assert_eq!(strip_author_note(gone), "", "{gone}");
        }
        for kept in [
            "　　他把月票递给检票员，上了车。这趟车开往郊外，路上要走两个钟头，他靠着窗睡了过去，醒来已是黄昏。",
            "　　（这是他第三章手稿里写下的话。）",
            "　　“未完待续？”他念着纸上的四个字。",
        ] {
            assert_eq!(strip_author_note(kept), kept);
        }
    }
    #[test]
    fn paging_leftovers() {
        assert_eq!(
            strip_paging("　　（本章未完，请点击下一页继续阅读）第1章山门夜话(第2/2页)"),
            ""
        );
        assert_eq!(strip_paging("　　（本章未完，请翻页）"), "");
        assert_eq!(strip_paging("　　（本章完）"), "");
        assert_eq!(strip_paging("　　热门推荐:、、、、、、、"), "");
        assert_eq!(
            strip_paging("　　为您提供大神某某的《山海之间》最快更新，！"),
            ""
        );
        assert_eq!(strip_paging("　　『』，最快更新最新章节！"), "");
        assert_eq!(
            strip_paging("　　他推门进去。(第1/3页)"),
            "　　他推门进去。"
        );
        assert_eq!(
            strip_paging("　　热门推荐的那家店关门了。"),
            "　　热门推荐的那家店关门了。"
        );
        assert_eq!(
            strip_paging("　　（第三页写着他的名字）"),
            "　　（第三页写着他的名字）"
        );
    }
}
