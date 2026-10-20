//! 场景样式（V81，LAY-135）：正文里的聊天记录、动态、论坛楼层、日记、古籍、诏书、羊皮纸、告示与剪报。
//!
//! 聊天记录可自动识别；其余场景由手工标注（`kind: inset`，`variant` 为场景）。每种场景按行的位置
//! 认出标题、落款、楼层、名字等角色，CSS 只用线条、浅灰底色、字号、字距与对齐，原文不改。
//! 文字块不用背景图，羊皮纸的淡纸纹除外：Kindle 深色模式实测，平均亮度约 243 以上的纸纹会随页面
//! 反转，更暗的不反转、反转后的白字看不见；AZW3 不显示背景，退回纯线条。
//! 公开类名：`.inset`、`.inset-{场景}`、`.inset-look-{样式}`、`.inset-inner`、`.inset-line`、
//! `.inset-{角色}`（head、body、end、who、say、time、date、floor、count、reply、mast、headline、by、blank）。
use crate::block_annotations::{Annotation, Kind};
use easypub_core::structure::Node;
use std::collections::{BTreeMap, HashMap};

/// 场景：(编号, 名称)。
pub const TYPES: [(&str, &str); 9] = [
    ("chat", "聊天记录"),
    ("post", "动态"),
    ("forum", "论坛楼层"),
    ("diary", "日记"),
    ("classic", "古籍"),
    ("edict", "诏书"),
    ("scroll", "羊皮纸"),
    ("notice", "告示"),
    ("news", "剪报"),
];

pub fn is_type(v: &str) -> bool {
    TYPES.iter().any(|(id, _)| *id == v)
}

/// 场景识别（V82，LAY-137）：off 不按规则识别；on 内置识别与自定义规则生效。
pub const INSET_DETECT: [&str; 2] = ["off", "on"];
/// 聊天记录样式：off 不自动识别（手工标注的仍按 window 排）。
pub const CHAT_BLOCK_STYLES: [&str; 4] = ["off", "window", "script", "channel"];
/// 书信样式：plain 原样（V52）；ruled 信笺格线。
pub const LETTER_BLOCK_STYLES: [&str; 2] = ["plain", "ruled"];
/// 场景字体：kai 时场景样式里选了楷体的才用楷体（KFX 生效，AZW3 由 Kindling 去掉字体设置）；body 全部退回正文字体。
pub const INSET_FONTS: [&str; 2] = ["kai", "body"];

/// 一行在场景块里的位置与角色。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Line {
    /// 所在块首行的字节偏移，同一块相同。
    pub block: usize,
    pub kind: &'static str,
    pub role: &'static str,
    /// 来源：manual 手工标注；chat 自动识别的聊天；edict、forum 内置识别；custom 自定义规则。
    pub source: &'static str,
}

impl Line {
    /// 不是手工标注（自动识别或规则识别）。
    pub fn automatic(&self) -> bool {
        self.source != "manual"
    }
}

/// 场景识别（V82，LAY-137）：内置识别（诏书、论坛楼层）与本书的自定义规则。
#[derive(Default)]
pub struct Rules {
    pub edict: bool,
    pub forum: bool,
    pub custom: Vec<(&'static str, regex::Regex, Option<regex::Regex>, usize)>,
}

/// 内置诏书识别的开头与结尾。
const EDICT_START: &str = r"^(?:奉天承运|圣旨|诏曰|皇帝诏曰|制曰)";
const EDICT_END: &str = r"钦此[。！!]?$";

impl Rules {
    /// 按本书设置：`inset_detect` 为 on 时启用；内置项可在规则页单独关闭。
    pub fn from_settings(detect: &str, options: &crate::rule_options::Options) -> Self {
        if detect != "on" {
            return Self::default();
        }
        let custom = if options.enabled("layout.inset.custom") {
            options
                .inset_rules
                .iter()
                .filter_map(|r| {
                    let (start, end) = r.compile()?;
                    Some((type_id(&r.scene)?, start, end, usize::from(r.max_lines)))
                })
                .collect()
        } else {
            Vec::new()
        };
        Self {
            edict: options.enabled("layout.inset.edict"),
            forum: options.enabled("layout.inset.forum"),
            custom,
        }
    }
}

fn type_id(v: &str) -> Option<&'static str> {
    TYPES.iter().find(|(id, _)| *id == v).map(|(id, _)| *id)
}

/// 整行外层的 【】、[]、［］ 去掉后的内容；不是整行括号时原样返回。
fn unbracket(t: &str) -> &str {
    for (open, close) in [('【', '】'), ('[', ']'), ('［', '］')] {
        if let Some(inner) = t.strip_prefix(open).and_then(|s| s.strip_suffix(close))
            && !inner.contains([open, close])
        {
            return inner.trim();
        }
    }
    t
}

/// 聊天行“名字：内容”：可带整行【】[]［］；名字 1–6 字，不含空白与标点、不全是数字；内容不空。
/// 叙述里的对白不算（V82 书库实测）：名字以“说、道、问、笑”等说话动词结尾（“宁姚说道：”），
/// 或内容以引号开头（“露娜：“……””）。返回名字与内容在 `line` 里的字节范围。
pub fn chat_line(line: &str) -> Option<((usize, usize), (usize, usize))> {
    let t = line.trim();
    let inner = unbracket(t);
    let base = inner.as_ptr() as usize - line.as_ptr() as usize;
    let (pos, sep) = inner
        .char_indices()
        .take(8)
        .find(|(_, c)| matches!(c, '：' | ':'))?;
    let name = inner[..pos].trim();
    let n = name.chars().count();
    if n == 0
        || n > 6
        || name.chars().any(|c| {
            c.is_whitespace() || "，。！？、；“”‘’《》（）()【】[]［］<>…—·,.!?;\"'".contains(c)
        })
        || name.chars().all(|c| c.is_ascii_digit())
        || (n >= 2 && name.ends_with(SPEECH_VERBS))
        // 作者在章末写的“PS：”。
        || name.eq_ignore_ascii_case("ps")
    {
        return None;
    }
    let after = &inner[pos + sep.len_utf8()..];
    let say = after.trim();
    if say.is_empty() || say.starts_with(['“', '"', '「', '『', '‘', '\'']) {
        return None;
    }
    let name_start = base + (name.as_ptr() as usize - inner.as_ptr() as usize);
    let say_start = base + (say.as_ptr() as usize - inner.as_ptr() as usize);
    Some((
        (name_start, name_start + name.len()),
        (say_start, say_start + say.len()),
    ))
}

/// 名字末尾出现时说明是叙述里的“某某说道：”，不是聊天的发言人。
const SPEECH_VERBS: [char; 16] = [
    '说', '道', '问', '答', '喊', '叫', '笑', '骂', '叹', '吼', '言', '曰', '云', '称', '嚷', '哭',
];

/// 时间行：可带少量前缀（今天、星期四）与装饰符号，如“22:01”“— 昨天 22:01 —”。
pub fn is_time_line(line: &str) -> bool {
    let t = line
        .trim()
        .trim_matches(|c: char| c.is_whitespace() || "—-–~～·[]［］【】()（）".contains(c));
    if t.is_empty() || t.chars().count() > 16 {
        return false;
    }
    let digits: Vec<char> = t.chars().skip_while(|c| !c.is_ascii_digit()).collect();
    let prefix = t.chars().count() - digits.len();
    let s: String = digits.iter().collect();
    let clock = s.split([':', '：']).collect::<Vec<_>>();
    prefix <= 6
        && (2..=3).contains(&clock.len())
        && clock
            .iter()
            .all(|p| !p.is_empty() && p.len() <= 2 && p.chars().all(|c| c.is_ascii_digit()))
        && clock[1..].iter().all(|p| p.len() == 2)
}

fn short(t: &str, n: usize) -> bool {
    let c = t.chars().count();
    c > 0 && c <= n
}

fn ends_sentence(t: &str) -> bool {
    t.ends_with(['。', '！', '？', '…', '.', '!', '?', '；', '，'])
}

const COUNT_WORDS: [&str; 8] = ["转发", "评论", "点赞", "赞", "喜欢", "收藏", "分享", "回复"];

fn is_count_line(t: &str) -> bool {
    let words = COUNT_WORDS.iter().filter(|w| t.contains(*w)).count();
    words >= 2 && t.chars().any(|c| c.is_ascii_digit()) && t.chars().count() <= 40
}

/// 楼层行：阿拉伯数字加“楼”或“L”（可带 #），或“#数字”，或“沙发 / 板凳 / 地板 / 楼主”，
/// 后面是冒号，或是空白 / 行尾且整行不超过 24 字。“二楼。”“二楼窗畔……”这类叙述不算（V82 书库实测）。
fn is_floor_line(t: &str) -> bool {
    let t = t.trim();
    let hash = t.starts_with(['#', '＃']);
    let body = t.trim_start_matches(['#', '＃']);
    let digits = body.chars().take_while(|c| c.is_ascii_digit()).count();
    let after = if (1..=4).contains(&digits) {
        let rest = body[digits..].trim_start();
        rest.strip_prefix('楼')
            .or_else(|| rest.strip_prefix(['L', 'l']))
            .or(hash.then_some(rest))
    } else if digits == 0 {
        ["沙发", "板凳", "地板", "楼主"]
            .iter()
            .find_map(|w| body.strip_prefix(w))
    } else {
        None
    };
    let Some(after) = after else {
        return false;
    };
    after.starts_with(['：', ':'])
        || ((after.is_empty() || after.starts_with(char::is_whitespace) || after.starts_with('·'))
            && t.chars().count() <= 24)
}

/// 每种场景能用的角色（V82，LAY-138）：逐行指定时只能选这些。
pub fn allowed_roles(scene: &str) -> &'static [&'static str] {
    match scene {
        "chat" => &["head", "time", "say", "body"],
        "post" => &["head", "body", "count", "reply"],
        "forum" => &["floor", "body"],
        "diary" => &["date", "body"],
        "classic" | "edict" | "scroll" | "notice" => &["head", "body", "end"],
        "news" => &["mast", "headline", "by", "body"],
        _ => &[],
    }
}

/// 一个场景块里各行的角色。`lines` 为块内全部行（含空行）。
pub fn roles(kind: &str, lines: &[&str]) -> Vec<&'static str> {
    let texts: Vec<&str> = lines.iter().map(|l| l.trim()).collect();
    let content: Vec<usize> = (0..texts.len()).filter(|&i| !texts[i].is_empty()).collect();
    let mut out = vec!["blank"; texts.len()];
    let (Some(&first), Some(&last)) = (content.first(), content.last()) else {
        return out;
    };
    let many = content.len() > 1;
    for &i in &content {
        let t = texts[i];
        out[i] = "body";
        match kind {
            "chat" => {
                out[i] = if chat_line(t).is_some() {
                    "say"
                } else if is_time_line(t) {
                    "time"
                } else if i == first && many && short(t, 20) {
                    "head"
                } else {
                    "body"
                }
            }
            "post" => {
                if i == first && many && short(t, 40) {
                    out[i] = "head";
                } else if is_count_line(t) {
                    out[i] = "count";
                } else if content
                    .iter()
                    .any(|&j| j < i && out[j] == "count" || j < i && out[j] == "reply")
                    && chat_line(t).is_some()
                {
                    out[i] = "reply";
                }
            }
            "forum" => {
                if is_floor_line(t) {
                    out[i] = "floor";
                }
            }
            "diary" => {
                if i == first && many && short(t, 24) && !ends_sentence(t) {
                    out[i] = "date";
                }
            }
            "classic" => {
                if i == first && many && short(t, 16) && !ends_sentence(t) {
                    out[i] = "head";
                }
            }
            "edict" | "scroll" | "notice" => {
                let limit = match kind {
                    "edict" => 16,
                    "scroll" => 12,
                    _ => 10,
                };
                if i == first && many && short(t, limit) && !ends_sentence(t) {
                    out[i] = "head";
                } else if i == last && content.len() > 2 && {
                    let end_limit = if kind == "edict" { 6 } else { 16 };
                    short(t, end_limit) || t.starts_with("——")
                } {
                    out[i] = "end";
                }
            }
            "news" => {
                let position = content.iter().position(|&j| j == i).unwrap_or(0);
                let has_mast = short(texts[first], 12) && !ends_sentence(texts[first]) && many;
                if position == 0 && has_mast {
                    out[i] = "mast";
                } else if position == 1 && has_mast && short(t, 30) && !t.ends_with('。') {
                    out[i] = "headline";
                } else if position <= 2
                    && has_mast
                    && short(t, 20)
                    && ["记者", "通讯员", "报道", "电", "讯", "编辑"]
                        .iter()
                        .any(|w| t.contains(w))
                {
                    out[i] = "by";
                }
            }
            _ => {}
        }
    }
    out
}

fn line_ranges(text: &str) -> Vec<(usize, usize, usize)> {
    let mut out = Vec::new();
    let mut offset = 0;
    while offset < text.len() {
        let rest = &text[offset..];
        let length = rest.find(['\r', '\n']).unwrap_or(rest.len());
        let content_end = offset + length;
        let tail = &text[content_end..];
        let eol = if tail.starts_with("\r\n") {
            2
        } else if tail.starts_with(['\r', '\n']) {
            1
        } else {
            0
        };
        let end = content_end + eol;
        out.push((offset, content_end, end));
        offset = end.max(offset + 1);
    }
    out
}

/// 全书场景块的逐行计划：手工标注的场景，以及（`chat` 为真时）自动识别的聊天记录。
/// 自动识别只看不是标题、不在任何手工标注里的行：连续的“名字：内容”行，中间可夹空行与时间行，
/// 首尾都是聊天行；至少两行，且有人说话两次以上（避免把“力量：10”“敏捷：8”这类面板当聊天）。
pub fn plan(
    text: &str,
    nodes: &[Node],
    annotations: &[Annotation],
    chat: bool,
    rules: &Rules,
) -> BTreeMap<usize, Line> {
    let ranges = line_ranges(text);
    let mut out = BTreeMap::new();
    for a in annotations.iter().filter(|a| a.kind == Kind::Inset) {
        let Some(kind) = a.variant.as_deref().and_then(type_id) else {
            continue;
        };
        let inside: Vec<_> = ranges
            .iter()
            .filter(|(s, _, _)| *s >= a.start && *s < a.end)
            .collect();
        let lines: Vec<&str> = inside.iter().map(|(s, e, _)| &text[*s..*e]).collect();
        // 逐行指定的角色优先（V82，LAY-138）；空行不改。
        let allowed = allowed_roles(kind);
        let computed: Vec<&'static str> = roles(kind, &lines)
            .into_iter()
            .enumerate()
            .map(|(i, role)| {
                a.roles
                    .get(&i)
                    .filter(|_| role != "blank")
                    .and_then(|r| allowed.iter().find(|x| **x == r.as_str()).copied())
                    .unwrap_or(role)
            })
            .collect();
        for ((s, _, _), role) in inside.iter().zip(computed) {
            out.insert(
                *s,
                Line {
                    block: a.start,
                    kind,
                    role,
                    source: "manual",
                },
            );
        }
    }
    // 每行是否被标题或手工标注占用、是否像聊天行：各算一次（V83），不再每行遍历全部标注。
    let mut sorted: Vec<(usize, usize)> = annotations.iter().map(|a| (a.start, a.end)).collect();
    sorted.sort_unstable();
    let mut heads: Vec<usize> = nodes.iter().map(|n| n.start).collect();
    heads.sort_unstable();
    let (mut ai, mut hi) = (0, 0);
    let taken: Vec<bool> = ranges
        .iter()
        .map(|&(s, _, _)| {
            while sorted.get(ai).is_some_and(|&(_, e)| e <= s) {
                ai += 1;
            }
            while heads.get(hi).is_some_and(|&h| h < s) {
                hi += 1;
            }
            heads.get(hi) == Some(&s)
                || sorted[ai..]
                    .iter()
                    .take_while(|&&(a, _)| a <= s)
                    .any(|&(_, e)| s < e)
        })
        .collect();
    let chats: Vec<bool> = ranges
        .iter()
        .enumerate()
        .map(|(k, &(s, e, _))| !taken[k] && chat_line(&text[s..e]).is_some())
        .collect();
    // 规则识别（V82）：手工标注之后、聊天识别之前；只用没有标题、没有标注、还没归入场景的行。
    let free = |out: &BTreeMap<usize, Line>, k: usize| !taken[k] && !out.contains_key(&ranges[k].0);
    let assign = |out: &mut BTreeMap<usize, Line>,
                  first: usize,
                  last: usize,
                  kind: &'static str,
                  source: &'static str| {
        let lines: Vec<&str> = (first..=last)
            .map(|k| &text[ranges[k].0..ranges[k].1])
            .collect();
        for (k, role) in (first..=last).zip(roles(kind, &lines)) {
            out.insert(
                ranges[k].0,
                Line {
                    block: ranges[first].0,
                    kind,
                    role,
                    source,
                },
            );
        }
    };
    let line = |k: usize| text[ranges[k].0..ranges[k].1].trim();
    let mut spans: Vec<(
        &'static str,
        &'static str,
        regex::Regex,
        Option<regex::Regex>,
        usize,
    )> = Vec::new();
    for (kind, start, end, max) in &rules.custom {
        spans.push((kind, "custom", start.clone(), end.clone(), *max));
    }
    if rules.edict {
        spans.push((
            "edict",
            "edict",
            regex::Regex::new(EDICT_START).expect("edict start"),
            Some(regex::Regex::new(EDICT_END).expect("edict end")),
            30,
        ));
    }
    for (kind, source, start, end, max) in &spans {
        let mut i = 0;
        while i < ranges.len() {
            if !free(&out, i) || !start.is_match(line(i)) {
                i += 1;
                continue;
            }
            let found = match end {
                None => Some(i),
                Some(end) => (i..ranges.len().min(i + max))
                    .take_while(|&k| free(&out, k))
                    .find(|&k| end.is_match(line(k))),
            };
            match found {
                Some(last) => {
                    assign(&mut out, i, last, kind, source);
                    i = last + 1;
                }
                None => i += 1,
            }
        }
    }
    // 论坛楼层：从楼层行起，连续的楼层与正文行；空行只在下一段仍是楼层时跨过；至少两层。
    if rules.forum {
        let mut i = 0;
        while i < ranges.len() {
            if !free(&out, i) || !is_floor_line(line(i)) {
                i += 1;
                continue;
            }
            let (mut j, mut last, mut floors, mut body) = (i, i, 1, 0);
            while j + 1 < ranges.len() && j + 1 < i + 80 && free(&out, j + 1) {
                let t = line(j + 1);
                if t.is_empty() {
                    let next = (j + 1..ranges.len().min(i + 80)).find(|&k| !line(k).is_empty());
                    match next {
                        Some(k) if free(&out, k) && is_floor_line(line(k)) => {
                            // 跳过空行，下一轮处理楼层行本身。
                            j = k - 1;
                            continue;
                        }
                        _ => break,
                    }
                } else {
                    // 两层之间最多 6 行正文，超过说明已回到叙述。
                    if is_floor_line(t) {
                        floors += 1;
                        body = 0;
                    } else {
                        body += 1;
                        if body > 6 {
                            break;
                        }
                    }
                    last = j + 1;
                }
                j += 1;
            }
            if floors >= 2 {
                assign(&mut out, i, last, "forum", "forum");
                i = last + 1;
            } else {
                i += 1;
            }
        }
    }
    if !chat {
        return out;
    }
    let mut i = 0;
    while i < ranges.len() {
        let usable = |k: usize| !taken[k] && !out.contains_key(&ranges[k].0);
        let is_chat = |k: usize| chats[k] && !out.contains_key(&ranges[k].0);
        if !is_chat(i) {
            i += 1;
            continue;
        }
        // 从 i 起尽量延伸：聊天行、空行、时间行；记下最后一个聊天行。
        let (mut j, mut last) = (i, i);
        while j + 1 < ranges.len() && usable(j + 1) {
            let t = text[ranges[j + 1].0..ranges[j + 1].1].trim();
            if is_chat(j + 1) {
                last = j + 1;
            } else if !(t.is_empty() || is_time_line(t)) {
                break;
            }
            j += 1;
        }
        let mut names: HashMap<&str, usize> = HashMap::new();
        let mut count = 0;
        for k in i..=last {
            let line = &text[ranges[k].0..ranges[k].1];
            if let Some(((ns, ne), _)) = chat_line(line) {
                *names.entry(&line[ns..ne]).or_default() += 1;
                count += 1;
            }
        }
        if count >= 2 && names.values().any(|&n| n >= 2) {
            // 紧贴在第一条消息上方的时间行一并归入。
            let mut first = i;
            while first > 0
                && usable(first - 1)
                && !out.contains_key(&ranges[first - 1].0)
                && is_time_line(&text[ranges[first - 1].0..ranges[first - 1].1])
            {
                first -= 1;
            }
            let i = first;
            let lines: Vec<&str> = (i..=last)
                .map(|k| &text[ranges[k].0..ranges[k].1])
                .collect();
            for (k, role) in (i..=last).zip(roles("chat", &lines)) {
                out.insert(
                    ranges[k].0,
                    Line {
                        block: ranges[i].0,
                        kind: "chat",
                        role,
                        source: "chat",
                    },
                );
            }
        }
        i = last + 1;
    }
    out
}

/// 书里是否用到场景样式（决定是否写入场景 CSS，未用到的旧书样式表不变）。
pub fn used(settings: &crate::production::Settings) -> bool {
    settings.chat_block_style != "off"
        || settings.inset_detect == "on"
        || settings.letter_block_style != "plain"
        || settings
            .block_annotations
            .iter()
            .any(|a| a.kind == Kind::Inset)
}

/// 本书可能出现的场景：手工标注的场景，以及开启时自动识别的聊天。
pub fn scenes(settings: &crate::production::Settings) -> std::collections::BTreeSet<&'static str> {
    let mut out: std::collections::BTreeSet<&'static str> = settings
        .block_annotations
        .iter()
        .filter(|a| a.kind == Kind::Inset)
        .filter_map(|a| a.variant.as_deref().and_then(type_id))
        .collect();
    if settings.chat_block_style != "off" {
        out.insert("chat");
    }
    if settings.inset_detect == "on" {
        let options = &settings.rule_options;
        if options.enabled("layout.inset.edict") {
            out.insert("edict");
        }
        if options.enabled("layout.inset.forum") {
            out.insert("forum");
        }
        if options.enabled("layout.inset.custom") {
            out.extend(options.inset_rules.iter().filter_map(|r| type_id(&r.scene)));
        }
    }
    out
}

/// 用到的场景里是否有卷轴杆、淡纸纹（决定是否生成图片资源）。
pub fn image_needs(settings: &crate::production::Settings) -> (bool, bool) {
    let (mut rods, mut paper) = (false, false);
    for scene in scenes(settings) {
        let style = crate::inset_styles::effective(
            settings.inset_styles.as_ref(),
            scene,
            &settings.chat_block_style,
        );
        rods |= style.rods;
        paper |= style.shade == "paper";
    }
    (rods, paper)
}

/// 程序生成的卷轴杆与淡纸纹在成品里的资源编号；没用到的为空。
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub struct Images {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rod: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub paper: Option<String>,
}

/// 与其他图片相同的内容寻址编号：SHA-256 加扩展名。
pub fn image_id(png: &[u8]) -> String {
    use sha2::Digest;
    format!("{:x}.png", sha2::Sha256::digest(png))
}

/// 确定性的伪随机数（同一本书每次生成的图片逐字节相同）。
struct Lcg(u32);
impl Lcg {
    fn next(&mut self) -> u32 {
        self.0 = self.0.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        self.0 >> 8
    }
    fn spread(&mut self, n: i32) -> i32 {
        (self.next() % (2 * n as u32 + 1)) as i32 - n
    }
}

fn png(image: image::GrayImage) -> Vec<u8> {
    let mut bytes = Vec::new();
    image::DynamicImage::ImageLuma8(image)
        .write_to(
            &mut std::io::Cursor::new(&mut bytes),
            image::ImageFormat::Png,
        )
        .expect("encode png");
    bytes
}

/// 羊皮纸的淡纸纹：256×256 灰度，平均亮度约 245（真机测试中深色模式能正常反转的一级）。
pub fn paper_png() -> Vec<u8> {
    let mut rng = Lcg(0x5EED_0081);
    let mut image = image::GrayImage::new(256, 256);
    for p in image.pixels_mut() {
        p.0[0] = (245 + rng.spread(4)) as u8;
    }
    // 少量纤维：短横线略暗。
    for _ in 0..24 {
        let (x, y) = (rng.next() % 256, rng.next() % 256);
        let len = 8 + rng.next() % 24;
        for k in 0..len {
            let px = (x + k) % 256;
            image.put_pixel(px, y, image::Luma([236]));
        }
    }
    png(image)
}

/// 卷轴杆：1000×36，白底深色细杆与两端圆头（深色模式下随页面反转）。
pub fn rod_png() -> Vec<u8> {
    let (w, h) = (1000u32, 36u32);
    let mut image = image::GrayImage::from_pixel(w, h, image::Luma([255]));
    for y in 0..h {
        for x in 0..w {
            let (fx, fy) = (x as f32, y as f32);
            let knob = |cx: f32| ((fx - cx).powi(2) + (fy - 18.0).powi(2)).sqrt();
            let v = if knob(16.0) <= 14.0 || knob(984.0) <= 14.0 {
                40
            } else if (28..=972).contains(&x) && (13..=23).contains(&y) {
                if (15..=16).contains(&y) { 150 } else { 70 }
            } else {
                255
            };
            image.put_pixel(x, y, image::Luma([v]));
        }
    }
    png(image)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chat_lines_times_roles_and_detection() {
        for (line, name, say) in [
            ("四：不排除这个可能。", "四", "不排除这个可能。"),
            ("【四：有这个可能。】", "四", "有这个可能。"),
            ("[赤西：树君现在有空吗？]", "赤西", "树君现在有空吗？"),
            ("  林小满: 在吗  ", "林小满", "在吗"),
        ] {
            let ((ns, ne), (ss, se)) = chat_line(line).unwrap_or_else(|| panic!("{line}"));
            assert_eq!((&line[ns..ne], &line[ss..se]), (name, say));
        }
        for no in [
            "宁姚说道：“我去趟十万大山。”",
            "唐三十六说道：“是的。”",
            "露娜：“.......”",
            "李修文笑道：好，那今夜行动。",
            "PS：推荐票排名越来越高了。",
            "这是一句很长的名字的人：你好",
            "22:01",
            "四：",
            "“你好，”他说：好",
            "【力量：10】【敏捷：8】",
        ] {
            assert!(chat_line(no).is_none(), "{no}");
        }
        for yes in ["22:01", "— 22:01 —", "昨天 08:30", "[星期四 23:59:01]"] {
            assert!(is_time_line(yes), "{yes}");
        }
        for no in ["2:1", "第 22 章", "比分 3:2 落后", ""] {
            assert!(!is_time_line(no), "{no}");
        }
        assert_eq!(
            roles("chat", &["九州一号群", "— 22:01 —", "四：甲", "", "一：乙"]),
            ["head", "time", "say", "blank", "say"]
        );
        assert_eq!(
            roles(
                "post",
                &[
                    "林小满 @xiaoman · 3 分钟前",
                    "今天的江面。",
                    "转发 12 评论 34 赞 560",
                    "沈舟：拍得真好"
                ]
            ),
            ["head", "body", "count", "reply"]
        );
        assert_eq!(
            roles(
                "forum",
                &["1楼 楼主", "有人知道吗？", "#2 楼 路过", "元婴渡劫。"]
            ),
            ["floor", "body", "floor", "body"]
        );
        assert_eq!(
            roles("diary", &["九月十二日 星期四 阴", "今天又梦见那扇门。"]),
            ["date", "body"]
        );
        assert_eq!(
            roles("classic", &["九阴真经", "天之道，损有余而补不足。"]),
            ["head", "body"]
        );
        assert_eq!(
            roles("edict", &["奉天承运 皇帝诏曰", "着即晋封国公。", "钦此"]),
            ["head", "body", "end"]
        );
        assert_eq!(
            roles("scroll", &["契约", "立约人以血为誓。", "——灰塔之印"]),
            ["head", "body", "end"]
        );
        assert_eq!(
            roles(
                "notice",
                &["悬赏", "“红鸦”伊莲娜", "赏金五百金克朗", "王都治安厅 立"]
            ),
            ["head", "body", "body", "end"]
        );
        assert_eq!(
            roles(
                "news",
                &[
                    "江城晚报",
                    "城西夜现金光",
                    "本报记者 周明",
                    "昨晚十一时许……"
                ]
            ),
            ["mast", "headline", "by", "body"]
        );
        // 只有一行时不认标题、落款。
        assert_eq!(roles("edict", &["钦此"]), ["body"]);
        assert_eq!(roles("news", &["", ""]), ["blank", "blank"]);

        let text = "正文。\n四：甲\n\n一：乙\n22:01\n四：丙\n后文。\n【力量：10】\n【敏捷：8】\n张三：好\n李四：好\n";
        let p = plan(text, &[], &[], true, &Rules::default());
        let starts: Vec<_> = p.keys().copied().collect();
        let block = text.find("四：甲").unwrap();
        assert!(p.values().all(|l| l.automatic()));
        assert_eq!(p.len(), 5, "{starts:?}");
        assert!(p.values().all(|l| l.block == block));
        assert_eq!(p[&text.find("22:01").unwrap()].role, "time");
        assert!(
            !p.contains_key(&text.find("【力量").unwrap()),
            "面板没人说话两次"
        );
        assert!(
            !p.contains_key(&text.find("张三").unwrap()),
            "两人各一次不算"
        );
        assert!(plan(text, &[], &[], false, &Rules::default()).is_empty());
    }

    #[test]
    fn rules_edict_forum_custom_precedence_and_limits() {
        use crate::rule_options::{InsetRule, Options};
        let text = "开头。\n奉天承运 皇帝诏曰\n着即晋封国公。\n钦此\n圣旨\n赏银百两。\n钦此！\n中间。\n1楼 楼主\n有人吗？\n\n2楼 路过\n元婴渡劫。\n\n后文。\n【契约】\n立约。\n——灰塔之印\n四：甲\n一：乙\n四：丙\n奉天承运\n没有结尾。\n";
        let options = Options {
            inset_rules: vec![InsetRule {
                scene: "scroll".into(),
                start: "【契约】".into(),
                end: r"——.+之印".into(),
                max_lines: 5,
            }],
            ..Default::default()
        };
        options.validate().unwrap();
        let rules = Rules::from_settings("on", &options);
        let p = plan(text, &[], &[], true, &rules);
        let at = |needle: &str| p.get(&text.find(needle).unwrap()).copied();
        // 两份诏书各自成块（块首不同），开头、落款认出。
        let first = at("奉天承运 皇帝诏曰").unwrap();
        let second = at("圣旨").unwrap();
        assert_eq!(
            (first.kind, first.role, first.source),
            ("edict", "head", "edict")
        );
        assert_eq!(at("钦此\n圣旨").unwrap().role, "end");
        assert_ne!(first.block, second.block);
        assert_eq!(at("钦此！").unwrap().role, "end");
        // 论坛：空行后仍是楼层就跨过，块到“元婴渡劫。”为止。
        let floor = at("1楼").unwrap();
        assert_eq!((floor.kind, floor.role), ("forum", "floor"));
        assert_eq!(at("元婴渡劫").unwrap().block, floor.block);
        assert!(at("后文").is_none());
        // 自定义规则：羊皮纸，落款认出。
        let scroll = at("【契约】").unwrap();
        assert_eq!((scroll.kind, scroll.source), ("scroll", "custom"));
        assert_eq!(at("——灰塔之印").unwrap().role, "end");
        // 聊天仍识别；没有结尾的“奉天承运”不成块。
        assert_eq!(at("四：甲").unwrap().source, "chat");
        assert!(at("没有结尾").is_none() && at("奉天承运\n没有").is_none());
        // 未开启时只有聊天；内置项可单独关闭。
        let off = plan(text, &[], &[], true, &Rules::from_settings("off", &options));
        assert!(off.values().all(|l| l.source == "chat"));
        let mut no_edict = options.clone();
        no_edict.disabled = vec!["layout.inset.edict".into()];
        let p2 = plan(
            text,
            &[],
            &[],
            false,
            &Rules::from_settings("on", &no_edict),
        );
        assert!(p2.values().all(|l| l.kind != "edict"));
        assert!(p2.values().any(|l| l.kind == "forum"));
        // 书库实测的误判：叙述里的“二楼”不算楼层。
        for no in [
            "二楼。",
            "二楼窗畔的大人物们看出了他的用意。",
            "2楼。",
            "楼主是谁",
            "12345楼",
        ] {
            assert!(!is_floor_line(no), "{no}");
        }
        for yes in [
            "1楼：好长",
            "#2",
            "#2 楼 路过",
            "3L 路人",
            "沙发：前排",
            "1楼 楼主",
        ] {
            assert!(is_floor_line(yes), "{yes}");
        }
        // 两层之间超过 6 行正文时，块在第 6 行后结束。
        let long = format!("1楼 楼主\n{}2楼 路过\n", "叙述。\n".repeat(7));
        assert!(
            plan(
                &long,
                &[],
                &[],
                false,
                &Rules {
                    forum: true,
                    ..Default::default()
                }
            )
            .is_empty()
        );
        // 结尾为空时只标开头一行；超过最多行数不成块。
        let single = Options {
            inset_rules: vec![InsetRule {
                scene: "notice".into(),
                start: "后文".into(),
                end: String::new(),
                max_lines: 1,
            }],
            disabled: vec!["layout.inset.edict".into(), "layout.inset.forum".into()],
            ..Default::default()
        };
        let p3 = plan(text, &[], &[], false, &Rules::from_settings("on", &single));
        assert_eq!(p3.len(), 1);
        let short = Options {
            inset_rules: vec![InsetRule {
                scene: "scroll".into(),
                start: "【契约】".into(),
                end: r"——.+之印".into(),
                max_lines: 2,
            }],
            disabled: vec!["layout.inset.edict".into(), "layout.inset.forum".into()],
            ..Default::default()
        };
        assert!(plan(text, &[], &[], false, &Rules::from_settings("on", &short)).is_empty());
        // 非法规则被拒。
        for bad in [
            InsetRule {
                scene: "letter".into(),
                start: "a".into(),
                end: String::new(),
                max_lines: 3,
            },
            InsetRule {
                scene: "edict".into(),
                start: " ".into(),
                end: String::new(),
                max_lines: 3,
            },
            InsetRule {
                scene: "edict".into(),
                start: "(".into(),
                end: String::new(),
                max_lines: 3,
            },
            InsetRule {
                scene: "edict".into(),
                start: "a".into(),
                end: String::new(),
                max_lines: 0,
            },
            InsetRule {
                scene: "edict".into(),
                start: "a".into(),
                end: String::new(),
                max_lines: 61,
            },
        ] {
            let o = Options {
                inset_rules: vec![bad.clone()],
                ..Default::default()
            };
            assert!(o.validate().is_err(), "{bad:?}");
        }
    }

    #[test]
    fn images_are_deterministic() {
        assert_eq!(paper_png(), paper_png());
        assert_eq!(rod_png(), rod_png());
        let paper = image::load_from_memory(&paper_png()).unwrap().to_luma8();
        let mean = paper.pixels().map(|p| u64::from(p.0[0])).sum::<u64>()
            / u64::from(paper.width() * paper.height());
        assert!((243..=247).contains(&mean), "{mean}");
    }
}
