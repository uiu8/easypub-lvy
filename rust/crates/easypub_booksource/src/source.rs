//! 书源（阅读 3.0 JSON）。字段宽松读入：数字、布尔、对象都转成文字，缺省为空。
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

fn text<'de, D: Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    Ok(match Value::deserialize(d)? {
        Value::Null => String::new(),
        Value::String(s) => s,
        Value::Bool(b) => b.to_string(),
        other => other.to_string(),
    })
}
fn flag<'de, D: Deserializer<'de>>(d: D) -> Result<bool, D::Error> {
    Ok(match Value::deserialize(d)? {
        Value::Bool(b) => b,
        Value::Number(n) => n.as_i64().unwrap_or(0) != 0,
        Value::String(s) => matches!(s.trim(), "true" | "1"),
        _ => false,
    })
}
fn number<'de, D: Deserializer<'de>>(d: D) -> Result<i64, D::Error> {
    Ok(match Value::deserialize(d)? {
        Value::Number(n) => n.as_i64().unwrap_or(0),
        Value::String(s) => s.trim().parse().unwrap_or(0),
        _ => 0,
    })
}
fn rules<'de, D: Deserializer<'de>>(d: D) -> Result<Rules, D::Error> {
    Ok(match Value::deserialize(d)? {
        Value::Object(map) => map
            .into_iter()
            .map(|(k, v)| {
                let v = match v {
                    Value::Null => String::new(),
                    Value::String(s) => s,
                    other => other.to_string(),
                };
                (k, v)
            })
            .filter(|(_, v)| !v.trim().is_empty())
            .collect(),
        _ => Rules::new(),
    })
}

pub type Rules = BTreeMap<String, String>;

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CrawlProfile {
    pub concurrency: Option<usize>,
    pub min_interval: u64,
    pub max_interval: u64,
    pub retries: Option<usize>,
    pub timeout_ms: Option<u64>,
    pub use_proxy: bool,
    /// 空值继承全局；direct 强制直连；proxy 使用配置的代理（兼容旧 useProxy）。
    pub proxy_mode: String,
    pub throttle_phrases: Vec<String>,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DownloadSample {
    pub at: u64,
    pub ms: u64,
    pub ok: bool,
    pub stub: bool,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Health {
    pub ms: Vec<u64>,
    pub last_ok: u64,
    pub fail_streak: usize,
    pub last_error: String,
    pub last_failure: u64,
    pub retry_after: u64,
}
impl Health {
    pub fn latency(&mut self, ms: u64) {
        self.ms.push(ms);
        if self.ms.len() > 20 {
            self.ms.remove(0);
        }
    }
    pub fn record(&mut self, ms: u64, ok: bool, error: &str, at: u64) {
        self.latency(ms);
        if ok {
            self.last_ok = at;
            self.fail_streak = 0;
            self.last_error.clear();
            self.retry_after = 0;
        } else {
            self.fail_streak = self.fail_streak.saturating_add(1);
            self.last_error = error.to_owned();
            self.last_failure = at;
            if self.fail_streak >= 3 {
                let delay = (60u64 << self.fail_streak.saturating_sub(3).min(4)).min(900);
                self.retry_after = at.saturating_add(delay);
            }
        }
    }
    pub fn cooling_down(&self, at: u64) -> bool {
        // 老版本只有累计故障数，没有过期时间，升级后允许重新探测。
        self.fail_streak >= 3 && self.retry_after > at
    }
    pub fn speed(&self) -> u64 {
        if self.ms.is_empty() {
            u64::MAX / 2
        } else {
            self.ms.iter().sum::<u64>() / self.ms.len() as u64
        }
    }
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SourceMeta {
    pub id: String,
    pub file: String,
    pub imported_at: u64,
    pub updated: bool,
    pub health: Health,
    pub check: Option<Value>,
    pub ping: Option<Value>,
    pub pinned: bool,
    pub rating: i64,
    pub crawl: CrawlProfile,
    pub crawl_suggestion: Option<CrawlProfile>,
    pub import_warnings: Vec<String>,
    pub downloads: Vec<DownloadSample>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BookSource {
    /// 插件管理信息；旧阅读 JSON 没有此字段时默认未测速、未分组。
    #[serde(default, rename = "easypub")]
    pub meta: SourceMeta,
    #[serde(deserialize_with = "text")]
    pub book_source_url: String,
    #[serde(deserialize_with = "text")]
    pub book_source_name: String,
    #[serde(deserialize_with = "text")]
    pub book_source_group: String,
    #[serde(deserialize_with = "number")]
    pub book_source_type: i64,
    #[serde(deserialize_with = "text")]
    pub book_source_comment: String,
    #[serde(deserialize_with = "text")]
    pub book_url_pattern: String,
    #[serde(deserialize_with = "text")]
    pub header: String,
    #[serde(deserialize_with = "text")]
    pub login_url: String,
    #[serde(deserialize_with = "text")]
    pub login_ui: String,
    #[serde(deserialize_with = "text")]
    pub login_check_js: String,
    #[serde(deserialize_with = "text")]
    pub cover_decode_js: String,
    #[serde(deserialize_with = "text")]
    pub js_lib: String,
    #[serde(deserialize_with = "text")]
    pub main_js: String,
    /// 轻悦时光：内嵌 HTML 或远程 HTML 地址，保持原文件可再次导出。
    #[serde(deserialize_with = "text")]
    pub html: String,
    #[serde(deserialize_with = "text")]
    pub login_action: String,
    #[serde(deserialize_with = "number")]
    pub max_batch_size: i64,
    #[serde(deserialize_with = "number")]
    pub respond_time: i64,
    #[serde(deserialize_with = "text")]
    pub concurrent_rate: String,
    #[serde(deserialize_with = "flag")]
    pub enabled_cookie_jar: bool,
    #[serde(deserialize_with = "flag")]
    pub enabled: bool,
    #[serde(deserialize_with = "flag")]
    pub enabled_explore: bool,
    #[serde(deserialize_with = "text")]
    pub explore_url: String,
    #[serde(deserialize_with = "text")]
    pub search_url: String,
    #[serde(deserialize_with = "text")]
    pub variable_comment: String,
    #[serde(deserialize_with = "number")]
    pub custom_order: i64,
    #[serde(deserialize_with = "number")]
    pub weight: i64,
    #[serde(deserialize_with = "number")]
    pub last_update_time: i64,
    #[serde(deserialize_with = "rules")]
    pub rule_search: Rules,
    #[serde(deserialize_with = "rules")]
    pub rule_explore: Rules,
    #[serde(deserialize_with = "rules")]
    pub rule_book_info: Rules,
    #[serde(deserialize_with = "rules")]
    pub rule_toc: Rules,
    #[serde(deserialize_with = "rules")]
    pub rule_content: Rules,
}

impl BookSource {
    pub fn priority(&self) -> bool {
        self.meta.pinned || self.groups().iter().any(|g| g == "优先")
    }
    pub fn auto_weight(&self) -> i64 {
        let d = &self.meta.downloads;
        if d.is_empty() {
            return 0;
        }
        let n = d.len() as i64;
        let ok = d.iter().filter(|v| v.ok).count() as i64 * 100 / n;
        let stub = d.iter().filter(|v| v.stub).count() as i64 * 100 / n;
        let ms = d.iter().map(|v| v.ms).sum::<u64>() / d.len() as u64;
        ok - stub - (ms / 1000).min(30) as i64
    }
    pub fn score(&self) -> i64 {
        self.weight + self.meta.rating * 50 + self.auto_weight()
    }
    pub fn recommended(&self) -> bool {
        let since = crate::hosts::timestamp().saturating_sub(7 * 86400);
        let d: Vec<_> = self
            .meta
            .downloads
            .iter()
            .filter(|v| v.at >= since)
            .collect();
        !d.is_empty()
            && d.iter().filter(|v| v.ok).count() * 100 >= d.len() * 90
            && d.iter().filter(|v| v.stub).count() * 100 < d.len() * 5
            && self.meta.health.speed() < 2000
    }
    pub fn tags(&self) -> Vec<String> {
        let mut tags = Vec::new();
        let h = &self.meta.health;
        if self.meta.check.as_ref().is_some_and(|c| c["ok"] == true) && h.fail_streak == 0 {
            tags.push("可用");
        }
        if h.speed() > 2000 && !h.ms.is_empty() {
            tags.push("慢");
        }
        if h.fail_streak >= 3 {
            tags.push("失效");
        }
        if h.last_error.contains("验证") {
            tags.push("需验证");
        }
        if h.last_error.contains("限流") || self.meta.downloads.iter().any(|d| d.stub) {
            tags.push("限流");
        }
        if !self.login_url.is_empty() || !self.login_ui.is_empty() {
            tags.push("需登录");
        }
        if self.meta.crawl.use_proxy || self.book_source_comment.contains("代理") {
            tags.push("需代理");
        }
        if self.search_url.is_empty() && self.main_js.is_empty() {
            tags.push("无搜索");
        }
        if crate::support::needs_web_view(self) {
            tags.push("WebView");
        }
        if !self.main_js.is_empty()
            || serde_json::to_string(self)
                .unwrap_or_default()
                .contains("@js:")
        {
            tags.push("JS");
        }
        if self.batch_size() > 1 {
            tags.push("批量");
        }
        tags.into_iter().map(str::to_owned).collect()
    }
    pub fn batch_size(&self) -> usize {
        if !Self::rule(&self.rule_content, "contentBatch").is_empty()
            || self.main_js.contains("getContentBatch")
        {
            if self.max_batch_size <= 0 {
                50
            } else {
                self.max_batch_size.min(50) as usize
            }
        } else {
            1
        }
    }
    pub fn id(&self) -> &str {
        if self.meta.id.is_empty() {
            &self.book_source_url
        } else {
            &self.meta.id
        }
    }
    pub fn groups(&self) -> Vec<String> {
        self.book_source_group
            .split([',', ';', '，'])
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .collect()
    }
    /// 书源地址去掉 `#备注` 后的部分：相对网址按它补全。
    pub fn base_url(&self) -> &str {
        let url = self.book_source_url.trim();
        url.split_once('#')
            .map_or(url, |(u, _)| u)
            .trim_end_matches('/')
    }
    pub fn rule<'a>(rules: &'a Rules, key: &str) -> &'a str {
        rules.get(key).map(String::as_str).unwrap_or("").trim()
    }
}

/// 阅读 2.0 的扁平字段改成 3.0 结构（仅在没有 3.0 规则组时转换）。
fn upgrade(mut value: Value) -> Value {
    let Some(map) = value.as_object_mut() else {
        return value;
    };
    if map.contains_key("ruleSearch") || !map.contains_key("ruleSearchList") {
        return value;
    }
    let groups: &[(&str, &[(&str, &str)])] = &[
        (
            "ruleSearch",
            &[
                ("bookList", "ruleSearchList"),
                ("name", "ruleSearchName"),
                ("author", "ruleSearchAuthor"),
                ("intro", "ruleSearchIntroduce"),
                ("kind", "ruleSearchKind"),
                ("lastChapter", "ruleSearchLastChapter"),
                ("coverUrl", "ruleSearchCoverUrl"),
                ("bookUrl", "ruleSearchNoteUrl"),
            ],
        ),
        (
            "ruleBookInfo",
            &[
                ("init", "ruleBookInfoInit"),
                ("name", "ruleBookName"),
                ("author", "ruleBookAuthor"),
                ("intro", "ruleIntroduce"),
                ("kind", "ruleBookKind"),
                ("lastChapter", "ruleBookLastChapter"),
                ("coverUrl", "ruleCoverUrl"),
                ("tocUrl", "ruleChapterUrl"),
            ],
        ),
        (
            "ruleToc",
            &[
                ("chapterList", "ruleChapterList"),
                ("chapterName", "ruleChapterName"),
                ("chapterUrl", "ruleContentUrl"),
                ("nextTocUrl", "ruleChapterUrlNext"),
            ],
        ),
        (
            "ruleContent",
            &[
                ("content", "ruleBookContent"),
                ("nextContentUrl", "ruleContentUrlNext"),
            ],
        ),
    ];
    for (group, fields) in groups {
        let mut out = serde_json::Map::new();
        for (new, old) in fields.iter() {
            if let Some(v) = map.get(*old) {
                out.insert((*new).into(), v.clone());
            }
        }
        map.insert((*group).into(), Value::Object(out));
    }
    if let Some(v) = map.get("ruleSearchUrl").cloned() {
        // 2.0 的搜索地址用 searchKey / searchPage。
        let s = v
            .as_str()
            .unwrap_or("")
            .replace("searchKey", "{{key}}")
            .replace("searchPage", "{{page}}");
        map.insert("searchUrl".into(), Value::String(s));
    }
    if let Some(v) = map
        .get("httpUserAgent")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
    {
        map.insert(
            "header".into(),
            Value::String(serde_json::json!({ "User-Agent": v }).to_string()),
        );
    }
    value
}

/// 读入书源文件：数组或单个对象，允许 BOM；不能读的项跳过并计数。
pub fn import(text: &str) -> Result<(Vec<BookSource>, usize), String> {
    let text = text.trim_start_matches('\u{feff}').trim();
    let value: Value = match serde_json::from_str(text) {
        Ok(v) => v,
        Err(_) if !text.starts_with(['{', '[']) => crate::source_formats::script_source(text)?,
        Err(_) => return Err("不是有效的书源 JSON".into()),
    };
    let items = match value {
        Value::Array(items) => items,
        Value::Object(_) => vec![value],
        _ => return Err("书源文件应为数组或对象".into()),
    };
    let mut sources = Vec::new();
    let mut skipped = 0;
    for item in items {
        match serde_json::from_value::<BookSource>(upgrade(crate::source_formats::convert(item))) {
            Ok(mut s) if !s.book_source_url.trim().is_empty() => {
                crate::source_formats::suggest(&mut s);
                sources.push(s);
            }
            _ => skipped += 1,
        }
    }
    Ok((sources, skipped))
}

fn credential(name: &str) -> bool {
    matches!(
        name.to_ascii_lowercase().as_str(),
        "cookie" | "authorization" | "proxy-authorization" | "set-cookie"
    )
}

/// 只剥离请求配置中的凭据，保留规则脚本。静态值不写 sources.json 或导出文件。
pub(crate) fn sanitize_json(value: &mut Value) -> bool {
    let mut changed = false;
    match value {
        Value::Object(map) => {
            map.retain(|k, _| {
                let keep = !credential(k);
                changed |= !keep;
                keep
            });
            for value in map.values_mut() {
                changed |= sanitize_json(value);
            }
        }
        Value::Array(items) => {
            for v in items {
                changed |= sanitize_json(v);
            }
        }
        Value::String(text) => {
            if let Ok(mut url) = reqwest::Url::parse(text)
                && (!url.username().is_empty() || url.password().is_some())
            {
                let _ = url.set_username("");
                let _ = url.set_password(None);
                *text = url.to_string();
                changed = true;
            }
            if let Ok(mut nested) = serde_json::from_str::<Value>(text)
                && !nested.is_string()
                && sanitize_json(&mut nested)
            {
                *text = nested.to_string();
                changed = true;
            } else if let Some(at) = text.find(",{")
                && let Ok(mut options) = serde_json::from_str::<Value>(&text[at + 1..])
                && sanitize_json(&mut options)
            {
                *text = format!("{},{}", &text[..at], options);
                changed = true;
            }
        }
        _ => (),
    }
    changed
}
