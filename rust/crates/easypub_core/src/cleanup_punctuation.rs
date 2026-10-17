//! Contextual punctuation without changing numeric punctuation or opaque tokens.
use crate::{
    ApiError,
    cleanup_rules::{budget, invalid},
};
use regex::Regex;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Options {
    pub marks: bool,
    pub ellipsis: bool,
    pub dashes: bool,
    pub quotes: bool,
}
pub(crate) struct Matcher {
    options: Options,
    opaque: Regex,
    quotes: Regex,
}
fn han(c: char) -> bool {
    matches!(c as u32,0x3400..=0x4dbf|0x4e00..=0x9fff|0xf900..=0xfaff|0x20000..=0x323af)
}
fn context(c: char) -> bool {
    han(c)
        || matches!(
            c,
            '，' | '。' | '！' | '？' | '：' | '；' | '、' | '…' | '—'
        )
}
impl Matcher {
    pub fn new(options: &Options) -> Result<Self, ApiError> {
        Ok(Self { options:options.clone(),
            opaque:Regex::new(r#"(?i)`+[^`]*`+|(?:https?://|ftp://|www\.)[^\s<>"“”‘’，。！？；：、（）【】]+|[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)+|(?:[a-z0-9-]+\.)+(?:com|org|net|cn|cc|io|me)(?:[/?#][^\s<>"“”‘’，。！？；：、（）【】]*)?"#).map_err(|_|invalid())?,
            quotes:Regex::new(r"(?:‘‘|““)([^“”‘’]*)(?:’’|””)").map_err(|_|invalid())?,
        })
    }
    pub fn transform(&self, input: &str) -> Result<String, ApiError> {
        if input.len() > 65536 {
            return Err(budget());
        }
        let protected = self
            .opaque
            .find_iter(input)
            .map(|m| (m.start(), m.end()))
            .collect::<Vec<_>>();
        let overlaps = |start: usize, end: usize| {
            let i = protected.partition_point(|&(_, b)| b <= start);
            protected.get(i).is_some_and(|&(a, _)| a < end)
        };
        let mut quote_edits = std::collections::BTreeMap::new();
        if self.options.quotes {
            for captures in self.quotes.captures_iter(input) {
                let span = captures.get(0).unwrap();
                if captures[1].chars().any(han)
                    && !overlaps(span.start(), span.start() + 6)
                    && !overlaps(span.end() - 6, span.end())
                {
                    quote_edits.insert(span.start(), (span.start() + 6, "“".to_string()));
                    quote_edits.insert(span.end() - 6, (span.end(), "”".to_string()));
                }
            }
        }
        let chars = input.char_indices().collect::<Vec<_>>();
        let boundary = |i: usize| chars.get(i).map_or(input.len(), |&(p, _)| p);
        let surrounding = |start: usize, end: usize| {
            let ignored = |c: char| {
                c.is_whitespace()
                    || matches!(
                        c,
                        '"' | '\''
                            | '“'
                            | '”'
                            | '‘'
                            | '’'
                            | '('
                            | ')'
                            | '（'
                            | '）'
                            | '['
                            | ']'
                            | '【'
                            | '】'
                    )
            };
            chars[..start]
                .iter()
                .rev()
                .map(|&(_, c)| c)
                .find(|&c| !ignored(c))
                .is_some_and(context)
                || chars[end..]
                    .iter()
                    .map(|&(_, c)| c)
                    .find(|&c| !ignored(c))
                    .is_some_and(context)
        };
        let mut result = String::with_capacity(input.len());
        let mut i = 0;
        while i < chars.len() {
            let (start, c) = chars[i];
            if let Some((end, text)) = quote_edits.get(&start) {
                result.push_str(text);
                i = chars.partition_point(|&(p, _)| p < *end);
                continue;
            }
            if overlaps(start, boundary(i + 1)) {
                result.push(c);
                i += 1;
                continue;
            }
            let mut end = i + 1;
            if matches!(c, ',' | '!' | '?' | ';' | ':') && self.options.marks {
                while end < chars.len() && matches!(chars[end].1, ',' | '!' | '?' | ';' | ':') {
                    end += 1;
                }
                if surrounding(i, end) && !overlaps(start, boundary(end)) {
                    for &(_, mark) in &chars[i..end] {
                        result.push(match mark {
                            ',' => '，',
                            '!' => '！',
                            '?' => '？',
                            ';' => '；',
                            ':' => '：',
                            _ => unreachable!(),
                        });
                    }
                    i = end;
                    continue;
                }
            } else if c == '.' && self.options.ellipsis {
                while end < chars.len() && chars[end].1 == '.' {
                    end += 1;
                }
                if matches!(end - i, 3 | 6)
                    && surrounding(i, end)
                    && !overlaps(start, boundary(end))
                {
                    result.push_str("……");
                    i = end;
                    continue;
                }
            } else if c == '-' && self.options.dashes {
                while end < chars.len() && chars[end].1 == '-' {
                    end += 1;
                }
                if end - i == 2 && surrounding(i, end) && !overlaps(start, boundary(end)) {
                    result.push_str("——");
                    i = end;
                    continue;
                }
            } else if self.options.dashes
                && input[start..].starts_with("— —")
                && surrounding(i, (i + 3).min(chars.len()))
                && !overlaps(start, start + 7)
            {
                result.push_str("——");
                i += 3;
                continue;
            }
            result.push_str(&input[start..boundary(end)]);
            i = end;
        }
        Ok(result)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn matcher() -> Matcher {
        Matcher::new(&Options {
            marks: true,
            ellipsis: true,
            dashes: true,
            quotes: true,
        })
        .unwrap()
    }
    #[test]
    fn chinese_context_preserves_urls_emails_numbers_and_english() {
        let source = "他说:价格是1,234.56元,时间12:30;真的吗?! 访问 https://example.com/a?x=1,y=2 然后,联系 a+b@example.com。`中文,代码?` English, OK!";
        let expected = "他说：价格是1,234.56元，时间12:30；真的吗？！ 访问 https://example.com/a?x=1,y=2 然后，联系 a+b@example.com。`中文,代码?` English, OK!";
        assert_eq!(matcher().transform(source).unwrap(), expected);
        assert_eq!(
            matcher().transform("‘‘中文,你好!’’").unwrap(),
            "“中文，你好！”"
        );
        for source in [
            "访问 example.com?词=甲,乙",
            "1,234.56 12:30 2026-09-27",
            "Hello, world! Why? 3...5 x--y",
            "example.com?q=1,2",
        ] {
            assert_eq!(matcher().transform(source).unwrap(), source);
        }
    }
    #[test]
    fn exact_runs_paired_quotes_and_switches_do_not_guess_broken_quotes() {
        let source =
            "他说...嗯......甲--乙— —丙。‘‘英文word与中文’’ ““测试”” 未配对““！ 中文.... 中文---";
        let expected = "他说……嗯……甲——乙——丙。“英文word与中文” “测试” 未配对““！ 中文.... 中文---";
        assert_eq!(matcher().transform(source).unwrap(), expected);
        let off = Matcher::new(&Options {
            marks: false,
            ellipsis: false,
            dashes: false,
            quotes: false,
        })
        .unwrap();
        assert_eq!(off.transform(source).unwrap(), source);
        assert!(matcher().transform(&"x".repeat(65537)).is_err());
    }
}
