//! Original-text candidate evidence, never an implicit deletion decision.
use crate::{
    ApiError,
    cleanup_rules::{budget, invalid},
};
use regex::{Regex, RegexBuilder};
use serde::{Deserialize, Serialize};
fn yes() -> bool {
    true
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Pattern {
    pub text: String,
    pub regex: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    fn options() -> Options {
        Options {
            include_defaults: true,
            include_headers: true,
            ignore_case: true,
            pattern: None,
            preserve_pattern: None,
            keywords: vec![],
            preserve_keywords: vec![],
        }
    }
    #[test]
    fn defaults_require_signals_and_headers_are_whole_lines() {
        let m = Matcher::new(&options()).unwrap();
        for line in [
            "广告：样本",
            "本书来自示例站",
            "书友分享，无错更新 example.com",
            "--- 第１２页 ---",
            "Page 12",
            "www.example.com",
        ] {
            assert!(!m.reasons(line).unwrap().is_empty(), "{line}");
        }
        for line in [
            "他在 example.com 上写日记。",
            "他翻到第12页读了下去。",
            "第12章 月色",
            "正文中的 www.example.com",
            "123",
            "全体读者都在分享自己的生活。",
        ] {
            assert!(m.reasons(line).unwrap().is_empty(), "{line}");
        }
    }
    #[test]
    fn literal_regex_case_and_preserve_conditions_are_distinct() {
        let mut o = options();
        o.include_defaults = false;
        o.include_headers = false;
        o.pattern = Some(Pattern {
            text: "a.b".into(),
            regex: false,
        });
        o.keywords = vec!["[推广]".into()];
        o.preserve_keywords = vec!["正文引用".into()];
        o.preserve_pattern = Some(Pattern {
            text: "^保留[0-9]+$".into(),
            regex: true,
        });
        let m = Matcher::new(&o).unwrap();
        assert_eq!(m.reasons("A.B").unwrap(), ["match_pattern"]);
        assert!(m.reasons("axb").unwrap().is_empty());
        assert_eq!(m.reasons("[推广] 正文引用").unwrap(), ["match_keyword"]);
        assert_eq!(
            m.preserve_reason("[推广] 正文引用").unwrap(),
            Some("preserve_keyword")
        );
        assert_eq!(
            m.preserve_reason("保留12").unwrap(),
            Some("preserve_pattern")
        );
        o.ignore_case = false;
        assert!(Matcher::new(&o).unwrap().reasons("A.B").unwrap().is_empty());
    }
    #[test]
    fn malformed_and_excessive_input_is_rejected() {
        for p in ["", "(", "(?=x)", "a\nb"] {
            let mut o = options();
            o.preserve_pattern = Some(Pattern {
                text: p.into(),
                regex: true,
            });
            assert!(Matcher::new(&o).is_err());
        }
        for words in [
            vec![" ".into()],
            vec!["x".repeat(257)],
            vec!["x".into(); 65],
        ] {
            let mut o = options();
            o.preserve_keywords = words;
            assert!(Matcher::new(&o).is_err());
        }
        let m = Matcher::new(&options()).unwrap();
        assert!(m.reasons(&"x".repeat(65537)).is_err());
        assert!(m.preserve_reason(&"x".repeat(65537)).is_err());
    }
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Options {
    pub include_defaults: bool,
    pub include_headers: bool,
    #[serde(default = "yes")]
    pub ignore_case: bool,
    #[serde(default)]
    pub pattern: Option<Pattern>,
    #[serde(default)]
    pub preserve_pattern: Option<Pattern>,
    #[serde(default)]
    pub keywords: Vec<String>,
    #[serde(default)]
    pub preserve_keywords: Vec<String>,
}
pub(crate) struct Matcher {
    options: Options,
    pattern: Option<Regex>,
    preserve: Option<Regex>,
    keywords: Option<Regex>,
    keep_words: Option<Regex>,
    defaults: Regex,
    website: Regex,
    headers: Regex,
}
fn compile(pattern: &str, ignore_case: bool) -> Result<Regex, ApiError> {
    RegexBuilder::new(pattern)
        .case_insensitive(ignore_case)
        .size_limit(1024 * 1024)
        .dfa_size_limit(2 * 1024 * 1024)
        .nest_limit(64)
        .build()
        .map_err(|_| invalid())
}
fn custom(pattern: &Option<Pattern>, ignore_case: bool) -> Result<Option<Regex>, ApiError> {
    pattern
        .as_ref()
        .map(|p| {
            if p.text.is_empty() || p.text.len() > 4096 || p.text.contains(['\0', '\r', '\n']) {
                return Err(invalid());
            }
            compile(
                &if p.regex {
                    p.text.clone()
                } else {
                    regex::escape(&p.text)
                },
                ignore_case,
            )
        })
        .transpose()
}
fn keywords(words: &[String], ignore_case: bool) -> Result<Option<Regex>, ApiError> {
    if words.len() > 64
        || words
            .iter()
            .any(|w| w.trim().is_empty() || w.len() > 256 || w.contains(['\0', '\r', '\n']))
    {
        return Err(invalid());
    }
    if words.is_empty() {
        return Ok(None);
    }
    compile(
        &words
            .iter()
            .map(|w| regex::escape(w))
            .collect::<Vec<_>>()
            .join("|"),
        ignore_case,
    )
    .map(Some)
}
impl Matcher {
    pub fn new(options: &Options) -> Result<Self, ApiError> {
        Ok(Self {
            options: options.clone(),
            pattern: custom(&options.pattern, options.ignore_case)?,
            preserve: custom(&options.preserve_pattern, options.ignore_case)?,
            keywords: keywords(&options.keywords, options.ignore_case)?,
            keep_words: keywords(&options.preserve_keywords, options.ignore_case)?,
            defaults: compile(
                r"(?:本书来自|更多精彩.{0,80}访问|请记住本站|最新网址|手机用户请浏览|下载本书|txt电子书|小说下载|加入书签|投推荐票|章节错误.{0,80}举报|广告位)",
                true,
            )?,
            website: compile(
                r"(?:https?://|www\.|(?:[a-z0-9-]+\.)+(?:com|org|net|cn|cc|me|io))(?:[^\s]*)",
                true,
            )?,
            headers: compile(
                r"^\s*(?:[-—_=]{2,}\s*)?(?:第\s*[0-9０-９]+\s*页|页码\s*[:：]?\s*[0-9０-９]+|page\s*[:：]?\s*[0-9]+|www\.[^\s]+)(?:\s*[-—_=]{2,})?\s*$",
                true,
            )?,
        })
    }
    pub fn reasons(&self, text: &str) -> Result<Vec<&'static str>, ApiError> {
        if text.len() > 65536 {
            return Err(budget());
        }
        let mut result = Vec::new();
        if self.keywords.as_ref().is_some_and(|r| r.is_match(text)) {
            result.push("match_keyword");
        }
        if self.pattern.as_ref().is_some_and(|r| r.is_match(text)) {
            result.push("match_pattern");
        }
        if self.options.include_defaults {
            if crate::cleanup::candidate(text) || self.defaults.is_match(text) {
                result.push("default_notice");
            }
            let context = ["更新不易", "书友", "章节", "小说", "本书", "无错"]
                .iter()
                .any(|word| text.contains(word));
            let signals = [
                "更新不易",
                "书友",
                "读者",
                "分享",
                "搜索",
                "域名",
                "最新",
                "无错",
                "更新快",
                "请访问",
            ]
            .iter()
            .filter(|word| text.contains(**word))
            .count();
            if context && signals >= 2 && self.website.is_match(text) {
                result.push("web_promotion");
            }
        }
        if self.options.include_headers && self.headers.is_match(text) {
            result.push("page_header");
        }
        Ok(result)
    }
    pub fn preserve_reason(&self, text: &str) -> Result<Option<&'static str>, ApiError> {
        if text.len() > 65536 {
            return Err(budget());
        }
        if self.keep_words.as_ref().is_some_and(|r| r.is_match(text)) {
            return Ok(Some("preserve_keyword"));
        }
        Ok(self
            .preserve
            .as_ref()
            .is_some_and(|r| r.is_match(text))
            .then_some("preserve_pattern"))
    }
}
