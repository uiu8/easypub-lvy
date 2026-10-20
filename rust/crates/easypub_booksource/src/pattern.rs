//! 正则：先用 `regex`，书源用了环视、反向引用等写法时改用 `fancy-regex`。
//! 替换文本按 Java 写法：`$1`、`${name}`，反斜杠转义下一个字符。
use std::{
    collections::HashMap,
    sync::{Arc, Mutex, OnceLock},
};

#[derive(Clone)]
pub enum Pattern {
    Std(regex::Regex),
    Fancy(fancy_regex::Regex),
}

/// 同一条规则会对每本书、每章反复使用：按文本缓存编译结果。
pub fn compile(text: &str) -> Option<Arc<Pattern>> {
    static CACHE: OnceLock<Mutex<HashMap<String, Option<Arc<Pattern>>>>> = OnceLock::new();
    let cache = CACHE.get_or_init(Default::default);
    if let Some(hit) = cache.lock().ok()?.get(text) {
        return hit.clone();
    }
    let compiled = regex::RegexBuilder::new(text)
        .size_limit(1 << 24)
        .build()
        .map(Pattern::Std)
        .or_else(|_| fancy_regex::Regex::new(text).map(Pattern::Fancy))
        .ok()
        .map(Arc::new);
    if let Ok(mut map) = cache.lock() {
        if map.len() > 4096 {
            map.clear();
        }
        map.insert(text.to_owned(), compiled.clone());
    }
    compiled
}

/// 一次匹配的各分组（缺失的分组为空串）。
pub type Groups = Vec<Option<String>>;

impl Pattern {
    pub fn is_match(&self, text: &str) -> bool {
        match self {
            Self::Std(r) => r.is_match(text),
            Self::Fancy(r) => r.is_match(text).unwrap_or(false),
        }
    }
    /// 所有不重叠匹配：每项为 (起点, 终点, 分组)。
    pub fn matches(&self, text: &str) -> Vec<(usize, usize, Groups)> {
        let mut result = Vec::new();
        match self {
            Self::Std(r) => {
                for c in r.captures_iter(text) {
                    let all = c.get(0).unwrap();
                    result.push((
                        all.start(),
                        all.end(),
                        c.iter().map(|m| m.map(|m| m.as_str().to_owned())).collect(),
                    ));
                }
            }
            Self::Fancy(r) => {
                for c in r.captures_iter(text).map_while(Result::ok) {
                    let all = c.get(0).unwrap();
                    result.push((
                        all.start(),
                        all.end(),
                        c.iter().map(|m| m.map(|m| m.as_str().to_owned())).collect(),
                    ));
                }
            }
        }
        result
    }
    fn names(&self) -> Vec<Option<String>> {
        match self {
            Self::Std(r) => r.capture_names().map(|n| n.map(str::to_owned)).collect(),
            Self::Fancy(r) => r.capture_names().map(|n| n.map(str::to_owned)).collect(),
        }
    }
    pub fn replace_all(&self, text: &str, template: &str) -> String {
        let names = self.names();
        let mut out = String::with_capacity(text.len());
        let mut last = 0;
        for (start, end, groups) in self.matches(text) {
            out.push_str(&text[last..start]);
            out.push_str(&expand(&groups, &names, template));
            last = end;
        }
        out.push_str(&text[last..]);
        out
    }
    /// `###`：只取第一个匹配，结果是替换模板展开后的文字；没有匹配时为空。
    pub fn first(&self, text: &str, template: &str) -> String {
        let names = self.names();
        self.matches(text)
            .into_iter()
            .next()
            .map(|(_, _, g)| expand(&g, &names, template))
            .unwrap_or_default()
    }
}

pub fn expand(groups: &Groups, names: &[Option<String>], template: &str) -> String {
    let mut chars = template.chars().peekable();
    let mut result = String::new();
    while let Some(c) = chars.next() {
        if c == '\\' {
            if let Some(c) = chars.next() {
                result.push(c);
            }
        } else if let Some(first) = (c == '$')
            .then(|| chars.peek().and_then(|d| d.to_digit(10)))
            .flatten()
        {
            // Java 的写法：第一位总算组号，之后的数字能对上已有分组才并进组号。
            chars.next();
            let mut n = first as usize;
            while let Some(d) = chars.peek().and_then(|d| d.to_digit(10)) {
                let next = n * 10 + d as usize;
                if next >= groups.len() {
                    break;
                }
                n = next;
                chars.next();
            }
            if let Some(Some(m)) = groups.get(n) {
                result.push_str(m);
            }
        } else if c == '$' && chars.peek() == Some(&'{') {
            chars.next();
            let name: String = chars.by_ref().take_while(|c| *c != '}').collect();
            if let Some(i) = names
                .iter()
                .position(|n| n.as_deref() == Some(name.as_str()))
                && let Some(Some(m)) = groups.get(i)
            {
                result.push_str(m);
            }
        } else {
            result.push(c);
        }
    }
    result
}
