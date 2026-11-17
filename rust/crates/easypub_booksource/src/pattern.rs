//! 正则：先用 `regex`，书源用了环视、反向引用等写法时改用 `fancy-regex`。
//! 替换文本按 Java 写法：`$1`、`${name}`，反斜杠转义下一个字符。
use std::{
    cell::RefCell,
    collections::HashMap,
    sync::{Arc, Mutex, OnceLock},
};

thread_local! {
    static ERRORS: RefCell<Vec<Option<String>>> = const { RefCell::new(Vec::new()) };
}

/// CSS 布尔谓词不能携带错误；由同步规则/原生调用边界统一接收。
/// 独立栈帧避免嵌套调用和后续任务串错，Drop 也覆盖 panic 展开。
pub fn checked<T>(run: impl FnOnce() -> T) -> Result<T, String> {
    struct Frame;
    impl Drop for Frame {
        fn drop(&mut self) {
            ERRORS.with(|errors| {
                errors.borrow_mut().pop();
            });
        }
    }
    ERRORS.with(|errors| errors.borrow_mut().push(None));
    let frame = Frame;
    let value = run();
    let error = ERRORS.with(|errors| errors.borrow().last().cloned().flatten());
    drop(frame);
    error.map_or(Ok(value), Err)
}

fn failed() {
    ERRORS.with(|errors| {
        for error in errors.borrow_mut().iter_mut() {
            error
                .get_or_insert_with(|| "高级正则执行失败（回溯或运行限制），请调整书源规则".into());
        }
    });
}

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
            Self::Fancy(r) => r.is_match(text).unwrap_or_else(|_| {
                failed();
                false
            }),
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
                for c in r.captures_iter(text) {
                    let c = match c {
                        Ok(c) => c,
                        Err(_) => {
                            failed();
                            return Vec::new();
                        }
                    };
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

#[cfg(test)]
mod repair88_tests {
    use super::*;

    fn limited() -> Pattern {
        Pattern::Fancy(
            fancy_regex::RegexBuilder::new(r"ok|(?=(a+)+$)a+")
                .backtrack_limit(32)
                .build()
                .unwrap(),
        )
    }

    #[test]
    fn repair88_regex_runtime_failure_discards_partial_matches() {
        let pattern = limited();
        let bad = format!("{}!", "a".repeat(40));
        assert!(checked(|| pattern.is_match(&bad)).is_err());
        let partial = format!("ok {bad}");
        assert!(
            checked(|| {
                assert!(pattern.matches(&partial).is_empty());
            })
            .is_err()
        );
        assert!(checked(|| pattern.replace_all(&partial, "changed")).is_err());
        assert!(checked(|| pattern.first(&partial, "$0")).is_err());
        assert_eq!(checked(|| pattern.is_match("ok")), Ok(true));
    }

    #[test]
    fn repair88_regex_nested_failure_and_panic_do_not_leak() {
        let pattern = limited();
        let bad = format!("{}!", "a".repeat(40));
        assert!(
            checked(|| {
                assert!(checked(|| pattern.is_match(&bad)).is_err());
                assert_eq!(checked(|| pattern.is_match("ok")), Ok(true));
            })
            .is_err()
        );
        let panic = std::panic::catch_unwind(|| {
            let _ = checked(|| {
                pattern.is_match(&bad);
                panic!("test unwind");
            });
        });
        assert!(panic.is_err());
        ERRORS.with(|errors| assert!(errors.borrow().is_empty()));
        assert_eq!(checked(|| pattern.is_match("ok")), Ok(true));
    }
}
