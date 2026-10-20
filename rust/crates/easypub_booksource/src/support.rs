//! 导入时的静态检查：书源能否由本引擎执行，不能时给出原因（显示给用户）。
//! “能执行”只表示规则与脚本本引擎都认识，不表示网站现在可访问。
use crate::source::BookSource;
use serde::Serialize;

/// prelude.js 里提供的 java.* 函数。
const JAVA_FUNCTIONS: &[&str] = &[
    "HMacBase64",
    "HMacHex",
    "aesBase64DecodeToString",
    "aesDecodeToString",
    "aesEncodeToBase64String",
    "aesEncodeToString",
    "ajax",
    "cacheContent",
    "ajaxAll",
    "androidId",
    "base64Decode",
    "base64DecodeToByteArray",
    "base64Encode",
    "bytesToStr",
    "connect",
    "createSymmetricCrypto",
    "desBase64DecodeToString",
    "desDecodeToString",
    "desEncodeToBase64String",
    "digestBase64Str",
    "digestHex",
    "encodeURI",
    "get",
    "getBaseUrl",
    "getCookie",
    "getElement",
    "getElements",
    "getString",
    "getStringList",
    "getWebViewUA",
    "head",
    "headerMap",
    "hexDecodeToByteArray",
    "hexDecodeToString",
    "hexEncodeToString",
    "htmlFormat",
    "importScript",
    "initUrl",
    "lang",
    "log",
    "logType",
    "longToast",
    "md5Encode",
    "md5Encode16",
    "net",
    "post",
    "put",
    "randomUUID",
    "reGetBook",
    "refreshTocUrl",
    "s2t",
    "setContent",
    "startBrowser",
    "startBrowserAwait",
    "strToBytes",
    "t2s",
    "timeFormat",
    "timeFormatUTC",
    "toNumChapter",
    "toast",
    "tripleDESDecodeStr",
    "tripleDESEncodeBase64Str",
    "url",
    "util",
    "webView",
    "webViewGetSource",
];
/// 需要 WebView 的写法。
const WEB_VIEW: &[&str] = &[
    "java.webView",
    "webViewGetSource",
    "startBrowserAwait",
    "\"webView\"",
    "'webView'",
    "webView:",
];

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "code", content = "detail", rename_all = "snake_case")]
pub enum Problem {
    /// 漫画、音频、文件书源。
    NotText(i64),
    NoSearch,
    NoContentRule,
    /// 需要 WebView（暂不支持时才算问题）。
    NeedsWebView,
    /// Rhino / Android 专有写法，如 org.jsoup、android.。
    JavaOnly(String),
    UnknownFunction(String),
}

impl Problem {
    pub fn message(&self) -> String {
        match self {
            Self::NotText(t) => format!(
                "{}书源，暂只支持文字书源",
                match t {
                    1 => "音频",
                    2 => "漫画",
                    3 => "文件",
                    _ => "非文字",
                }
            ),
            Self::NoSearch => "没有搜索地址".into(),
            Self::NoContentRule => "没有正文规则".into(),
            Self::NeedsWebView => crate::webview::UNSUPPORTED.into(),
            Self::JavaOnly(w) => format!("脚本用了安卓 / Java 专有写法（{w}）"),
            Self::UnknownFunction(f) => format!("脚本用了尚未支持的函数 java.{f}"),
        }
    }
}

pub fn cause(problems: &[Problem]) -> Option<&'static str> {
    if problems.is_empty() {
        None
    } else if problems
        .iter()
        .all(|p| matches!(p, Problem::NoSearch | Problem::NoContentRule))
    {
        Some("rule")
    } else {
        Some("unsupported")
    }
}

/// 书源是否用到 WebView（网址选项、脚本函数或正文的 webJs）。
pub fn needs_web_view(source: &BookSource) -> bool {
    let blob = execution_blob(source);
    !source.html.trim().is_empty()
        || WEB_VIEW.iter().any(|w| blob.contains(w))
        || !BookSource::rule(&source.rule_content, "webJs").is_empty()
}

// 书源说明、名称、分组和历史检查结果不是可执行代码。
fn execution_blob(source: &BookSource) -> String {
    serde_json::json!([
        source.header,
        source.login_url,
        source.login_ui,
        source.login_check_js,
        source.cover_decode_js,
        source.js_lib,
        source.main_js,
        source.login_action,
        source.explore_url,
        source.search_url,
        source.rule_search,
        source.rule_explore,
        source.rule_book_info,
        source.rule_toc,
        source.rule_content,
    ])
    .to_string()
    .replace("\\\"", "\"")
}

pub fn web_view_supported() -> bool {
    crate::webview::supported()
}

pub fn check(source: &BookSource) -> Vec<Problem> {
    let mut problems = Vec::new();
    if source.book_source_type != 0 {
        problems.push(Problem::NotText(source.book_source_type));
    }
    if source.search_url.trim().is_empty() && source.main_js.is_empty() && source.html.is_empty() {
        problems.push(Problem::NoSearch);
    }
    if BookSource::rule(&source.rule_content, "content").is_empty()
        && source.main_js.is_empty()
        && source.html.is_empty()
    {
        problems.push(Problem::NoContentRule);
    }
    let blob = execution_blob(source);
    if !web_view_supported() && needs_web_view(source) {
        problems.push(Problem::NeedsWebView);
    }
    for word in ["android.", "java.io.", "javax.", "JavaAdapter"] {
        if blob.contains(word) {
            problems.push(Problem::JavaOnly(word.trim_end_matches('.').to_owned()));
            break;
        }
    }
    let re = regex::Regex::new(r"\bjava\.([A-Za-z_][A-Za-z0-9_]*)").unwrap();
    let mut unknown: Vec<String> = re
        .captures_iter(&blob)
        .map(|c| c[1].to_owned())
        .filter(|f| !JAVA_FUNCTIONS.contains(&f.as_str()))
        .collect();
    unknown.sort();
    unknown.dedup();
    problems.extend(unknown.into_iter().map(Problem::UnknownFunction));
    problems
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    /// 用户样本统计（不进仓库）：`EASYPUB_BOOKSOURCE_SAMPLE=文件 cargo test -p easypub_booksource sample_support -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn sample_support() {
        let path =
            std::env::var("EASYPUB_BOOKSOURCE_SAMPLE").expect("设置 EASYPUB_BOOKSOURCE_SAMPLE");
        let text = std::fs::read_to_string(path).unwrap();
        let (sources, skipped) = crate::source::import(&text).unwrap();
        let mut ok = 0;
        let mut text_sources = 0;
        let mut reasons: BTreeMap<String, usize> = BTreeMap::new();
        for s in &sources {
            if s.book_source_type == 0 {
                text_sources += 1;
            }
            let problems = check(s);
            if problems.is_empty() {
                ok += 1;
            }
            let mut seen = std::collections::BTreeSet::new();
            for p in problems {
                let key = match &p {
                    Problem::UnknownFunction(f) => format!("unknown java.{f}"),
                    Problem::JavaOnly(w) => format!("java-only {w}"),
                    other => format!("{other:?}"),
                };
                if seen.insert(key.clone()) {
                    *reasons.entry(key).or_default() += 1;
                }
            }
        }
        println!(
            "BOOKSOURCE_SUPPORT total={} skipped={skipped} text={text_sources} runnable={ok}",
            sources.len()
        );
        let mut sorted: Vec<_> = reasons.into_iter().collect();
        sorted.sort_by_key(|(_, n)| std::cmp::Reverse(*n));
        for (k, v) in sorted {
            println!("  {v:4}  {k}");
        }
    }
}
