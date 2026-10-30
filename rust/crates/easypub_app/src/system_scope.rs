//! 整行【】的用途（V121，LAY-169）：网文里【】除了系统提示，还常用来写角色台词或心声、
//! 聊天消息、书前标签与作者说明。逐行按内容分类，再按全书倾向决定拿不准的行：
//! 【】大多是系统提示的书，拿不准的按系统提示；大多是台词的书，只认明确带系统用语的行。
//! 正文生成、规则统计与排版视图都经 [Scope::is_system] 判断，结果一致。
use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;

use regex::Regex;

/// 识别范围：自动判断（默认）、所有整行【】（V121 以前的规则）、只认含系统用语的行。
pub const SYSTEM_SCOPES: [&str; 3] = ["auto", "all", "keyword"];

/// 一行整行【】的用途。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Bracket {
    /// 带系统用语、数值或“键：值”的行。
    System,
    /// 带人称、语气词或问号叹号的台词、心声。
    Speech,
    /// “名字：内容”的聊天消息（交给聊天记录识别，不按系统提示排）。
    Chat,
    /// 书前标签（“轻小说+系统+日常”）、作者说明（叠甲、新编）、日记日期。
    Note,
    /// 看不出用途，按全书倾向决定。
    Unsure,
}

struct Patterns {
    strong: Regex,
    value_number: Regex,
    talk: Regex,
    weak_talk: Regex,
    weak_system: Regex,
    key_value: Regex,
    note: Regex,
    digit: Regex,
}

fn patterns() -> &'static Patterns {
    static P: OnceLock<Patterns> = OnceLock::new();
    P.get_or_init(|| {
        let build = |p: &str| Regex::new(p).expect("system scope pattern");
        Patterns {
            strong: build(
                r"叮|系统|宿主|任务|奖励|获得|获取|恭喜|检测到|解锁|升级|等级|经验|属性|技能|积分|签到|抽奖|好感度|倒计时|冷却|兑换|绑定|成就|称号|主线|支线|面板|技能点|属性点|天赋点|剩余时间|进度条|(?i:lv)\s*\.?\s*\d|[+＋]\s*\d|\d+\s*[/／]\s*\d+|\d+(\.\d+)?\s*[%％]",
            ),
            value_number: build(r"[：:]\s*[-+－＋]?\d+(\.\d+)?\s*[^\p{Han}]{0,3}$"),
            talk: build(r"[我咱俺]|老子|爷|[呢吧啊呀嘛哈哦噢唉哎咳咴哼喂嘿啦哇呗]"),
            weak_talk: build(r"[你他她吗？！?!]"),
            weak_system: build(
                r"您|请|已|当前|目标|检测|余额|申请|查收|提醒|通知|注意|欢迎|是否|成功|失败|完成|开启|启动|加载|正在",
            ),
            key_value: build(r"^【[^：:【】，。！？]{1,6}[：:][^，。！？；【】]{1,14}】$"),
            note: build(r"^(叠甲|\d+[.．]\d+新编|新编|原书名|PS|ps|作者)|^\d{1,2}月\d{1,2}日"),
            digit: build(r"\d"),
        }
    })
}

/// 括号里的文字（几段【】连起来）。
fn inner(line: &str) -> String {
    let mut out = String::new();
    let mut rest = line.trim();
    while let Some(start) = rest.find('【') {
        let after = &rest[start + '【'.len_utf8()..];
        let Some(end) = after.find('】') else { break };
        out.push_str(&after[..end]);
        rest = &after[end + '】'.len_utf8()..];
    }
    out
}

/// 聊天消息的名字与内容（与聊天记录识别同一规则）。
fn chat(line: &str) -> Option<(&str, &str)> {
    let ((ns, ne), (ss, se)) = crate::insets::chat_line(line)?;
    Some((&line[ns..ne], &line[ss..se]))
}

/// 像一句聊天：内容有口语特征、不是“键：值”、没有系统用语。
fn chatty(line: &str, say: &str) -> bool {
    let p = patterns();
    (p.talk.is_match(say) || p.weak_talk.is_match(say))
        && !p.key_value.is_match(line.trim())
        && !p.strong.is_match(say)
}

/// 一行整行【】的用途；不是整行【】时为空。[speakers] 是本书里发过聊天消息的名字。
pub fn kind(line: &str, speakers: &HashSet<String>) -> Option<Bracket> {
    if !crate::publication_documents::is_system_line(line) {
        return None;
    }
    let p = patterns();
    let t = line.trim();
    let s = inner(t);
    let pluses = s.matches(['+', '＋']).count();
    if p.note.is_match(&s) || (pluses >= 2 && !p.digit.is_match(&s)) {
        return Some(Bracket::Note);
    }
    if let Some((name, say)) = chat(t)
        && (speakers.contains(name) || chatty(t, say))
    {
        return Some(Bracket::Chat);
    }
    Some(if p.strong.is_match(&s) || p.value_number.is_match(&s) {
        Bracket::System
    } else if p.key_value.is_match(t) {
        Bracket::System
    } else if p.talk.is_match(&s) {
        Bracket::Speech
    } else if p.weak_system.is_match(&s) {
        Bracket::System
    } else if p.weak_talk.is_match(&s) {
        Bracket::Speech
    } else {
        Bracket::Unsure
    })
}

/// 一本书的整行【】判断。
#[derive(Clone, Debug)]
pub struct Scope {
    mode: &'static str,
    kinds: HashMap<String, Bracket>,
    system_book: bool,
    counts: [usize; 5],
}

impl Scope {
    /// 按全文分类：先找出发过两次以上聊天消息的名字，再逐行分类、统计全书倾向。
    pub fn new(text: &str, mode: &str) -> Self {
        let mode = SYSTEM_SCOPES
            .into_iter()
            .find(|m| *m == mode)
            .unwrap_or("auto");
        let lines: Vec<&str> = text
            .lines()
            .filter(|l| crate::publication_documents::is_system_line(l))
            .collect();
        let mut said: HashMap<&str, usize> = HashMap::new();
        for line in &lines {
            if let Some((name, say)) = chat(line.trim())
                && chatty(line, say)
            {
                *said.entry(name).or_default() += 1;
            }
        }
        let speakers: HashSet<String> = said
            .into_iter()
            .filter(|(_, n)| *n >= 2)
            .map(|(name, _)| name.to_owned())
            .collect();
        let mut kinds = HashMap::new();
        let mut counts = [0usize; 5];
        for line in lines {
            let k = kind(line, &speakers).expect("whole bracket line");
            counts[k as usize] += 1;
            kinds.insert(line.trim().to_owned(), k);
        }
        let system_book = counts[Bracket::System as usize]
            >= counts[Bracket::Speech as usize] + counts[Bracket::Chat as usize];
        Self {
            mode,
            kinds,
            system_book,
            counts,
        }
    }

    /// 这一行按系统提示排吗（只对整行【】为真）。
    pub fn is_system(&self, line: &str) -> bool {
        if !crate::publication_documents::is_system_line(line) {
            return false;
        }
        if self.mode == "all" {
            return true;
        }
        let k = self
            .kinds
            .get(line.trim())
            .copied()
            .unwrap_or_else(|| kind(line, &HashSet::new()).unwrap_or(Bracket::Unsure));
        match k {
            Bracket::System => true,
            Bracket::Speech | Bracket::Unsure => self.mode == "auto" && self.system_book,
            Bracket::Chat | Bracket::Note => false,
        }
    }

    /// 给界面看的判断结果：全书倾向与各类行数。
    pub fn summary(&self) -> serde_json::Value {
        let [system, speech, chat, note, unsure] = self.counts;
        serde_json::json!({
            "mode": self.mode,
            "system_book": self.system_book,
            "system": system, "speech": speech, "chat": chat, "note": note, "unsure": unsure,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(text: &str) -> (Scope, Vec<Option<Bracket>>) {
        let scope = Scope::new(text, "auto");
        let k = text
            .lines()
            .map(|l| scope.kinds.get(l.trim()).copied())
            .collect();
        (scope, k)
    }

    #[test]
    fn speech_book_keeps_only_clear_system_lines() {
        // 马在说话的书（用户书库《龙游令》的写法）：台词不按系统提示排。
        let text = "正文。\n【咴——他马的我料呢？】\n【你看你马呢？赶紧给老子上料啊！】\n【咴？？？】\n【……】\n【叮！获得技能：识马 LV1】\n";
        let (scope, k) = kinds(text);
        assert!(!scope.system_book);
        assert_eq!(k[1], Some(Bracket::Speech));
        assert_eq!(k[4], Some(Bracket::Unsure));
        assert!(!scope.is_system("【咴——他马的我料呢？】"));
        assert!(!scope.is_system("【……】"));
        assert!(scope.is_system("【叮！获得技能：识马 LV1】"));
        assert!(!scope.is_system("正文。"));
        // 识别范围“所有整行【】”保持 V121 以前的规则。
        assert!(Scope::new(text, "all").is_system("【咴？？？】"));
    }

    #[test]
    fn system_book_counts_unsure_lines_as_system() {
        let text = "【姓名：羽住悠】\n【年龄：18】\n【德：C】\n【宿主不属于这个时空，无法看清他人的相貌】\n【正在绑定......】\n【什么时间都有】\n";
        let (scope, k) = kinds(text);
        assert!(scope.system_book);
        assert_eq!(k[0], Some(Bracket::System));
        assert!(scope.is_system("【什么时间都有】"));
        // “只认含系统用语”时，拿不准的不算。
        assert!(!Scope::new(text, "keyword").is_system("【什么时间都有】"));
    }

    #[test]
    fn chat_notes_and_speakers_are_never_system() {
        let text = "【秦可：人呢？】\n【秦可：林夜你死了吗？】\n【秦可：照片.jpg】\n【轻小说+恋爱喜剧+日常】\n【8月10日，晴】\n【叠甲：本书为平行世界】\n【获得称号：夜猫子】\n";
        let (scope, k) = kinds(text);
        assert_eq!(k[0], Some(Bracket::Chat));
        // 发过聊天消息的名字，后面没有口语特征的消息也算聊天。
        assert_eq!(k[2], Some(Bracket::Chat));
        assert_eq!(k[3], Some(Bracket::Note));
        assert_eq!(k[4], Some(Bracket::Note));
        assert_eq!(k[5], Some(Bracket::Note));
        assert!(!scope.is_system("【秦可：照片.jpg】"));
        assert!(!scope.is_system("【轻小说+恋爱喜剧+日常】"));
        assert!(scope.is_system("【获得称号：夜猫子】"));
    }
}
