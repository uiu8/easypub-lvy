//! 公开格式的独立适配。不可转换的字段保留为导入提示，不默默宣称兼容。
use crate::source::{BookSource, CrawlProfile};
use serde_json::{Value, json};

pub fn script_source(script: &str) -> Result<Value, String> {
    let rt = rquickjs::Runtime::new().map_err(|_| "JS 引擎无法创建")?;
    rt.set_memory_limit(32 * 1024 * 1024);
    let until = std::time::Instant::now() + std::time::Duration::from_secs(2);
    rt.set_interrupt_handler(Some(Box::new(move || std::time::Instant::now() >= until)));
    let ctx = rquickjs::Context::full(&rt).map_err(|_| "JS 上下文无法创建")?;
    ctx.with(|ctx| {
        // 导入配置没有网络、本机文件或 Java 能力。下载时才建立完整 sourceApi。
        let code = format!("{script}\n;JSON.stringify(typeof config === 'object' ? config : {{}})");
        let value = ctx
            .eval::<String, _>(code)
            .map_err(|_| "单文件 JS 配置不能读取（需要顶层 config 对象）")?;
        let mut v: Value = serde_json::from_str(&value).map_err(|_| "单文件 JS 配置无效")?;
        v["mainJs"] = json!(script);
        v["enabled"] = json!(true);
        Ok(v)
    })
}
fn selector(v: &Value, suffix: &str) -> Value {
    let text = v.as_str().unwrap_or("").trim();
    if text.is_empty() {
        return json!("");
    }
    if text.starts_with("@js:") || text.starts_with("//") {
        return json!(text);
    }
    let text = text.replace("::text", "@text");
    let text = regex::Regex::new(r"::attr\(([^)]+)\)")
        .unwrap()
        .replace_all(&text, "@$1");
    json!(if text.contains('@') {
        text.to_string()
    } else {
        format!("{text}{suffix}")
    })
}
pub fn convert(v: Value) -> Value {
    if v.get("bookSourceUrl").is_some() || v.get("url").is_none() || v.get("chapter").is_none() {
        return v;
    }
    let mut warnings = Vec::<String>::new();
    let mut out = json!({
        "bookSourceUrl":v["url"],"bookSourceName":v["name"],"bookSourceComment":v["comment"],
        "enabled":v["disabled"] != true,
        "searchUrl":v["search"]["url"].as_str().unwrap_or("").replace("%s","{{key}}"),
        "ruleSearch":{},"ruleBookInfo":{},"ruleToc":{},"ruleContent":{},
    });
    for (group, mappings) in [
        (
            "search",
            vec![
                ("result", "bookList", ""),
                ("bookName", "name", "@text"),
                ("author", "author", "@text"),
                ("category", "kind", "@text"),
                ("wordCount", "wordCount", "@text"),
                ("latestChapter", "lastChapter", "@text"),
            ],
        ),
        (
            "book",
            vec![
                ("bookName", "name", "@text"),
                ("author", "author", "@text"),
                ("intro", "intro", "@text"),
                ("coverUrl", "coverUrl", "@src"),
                ("latestChapter", "lastChapter", "@text"),
            ],
        ),
        (
            "toc",
            vec![
                ("item", "chapterList", ""),
                ("nextPage", "nextTocUrl", "@href"),
            ],
        ),
        (
            "chapter",
            vec![
                ("content", "content", "@html"),
                ("nextPage", "nextContentUrl", "@href"),
            ],
        ),
    ] {
        let target = match group {
            "search" => "ruleSearch",
            "book" => "ruleBookInfo",
            "toc" => "ruleToc",
            _ => "ruleContent",
        };
        for (a, b, suffix) in mappings {
            out[target][b] = selector(&v[group][a], suffix);
        }
    }
    out["ruleSearch"]["bookUrl"] = json!("@href");
    out["ruleToc"]["chapterName"] = json!("@text");
    out["ruleToc"]["chapterUrl"] = json!("@href");
    if v["toc"]["isDesc"] == true {
        out["ruleToc"]["chapterList"] = json!(format!(
            "-{}",
            out["ruleToc"]["chapterList"].as_str().unwrap_or("")
        ));
    }
    if let Some(filter) = v["chapter"]["filterTxt"].as_str().filter(|s| !s.is_empty()) {
        out["ruleContent"]["replaceRegex"] = json!(format!("##{filter}##"));
    }
    if v["search"]["disabled"] == true {
        out["searchUrl"] = json!("");
    }
    if v["search"]["method"]
        .as_str()
        .is_some_and(|s| s.eq_ignore_ascii_case("POST"))
    {
        let body = match &v["search"]["data"] {
            Value::String(s) => s.clone(),
            o => o.to_string(),
        }
        .replace("%s", "{{key}}");
        out["searchUrl"] = json!(format!(
            "{},{}",
            out["searchUrl"].as_str().unwrap_or(""),
            json!({"method":"POST","body":body})
        ));
    }
    // 正则定位 URL、XPath 变体及 HTML 标签过滤与阅读语义不同，必须明确报告。
    for (group, supported) in [
        (
            "search",
            &[
                "url",
                "method",
                "data",
                "disabled",
                "result",
                "bookName",
                "author",
                "category",
                "wordCount",
                "latestChapter",
            ][..],
        ),
        (
            "book",
            &["bookName", "author", "intro", "coverUrl", "latestChapter"][..],
        ),
        ("toc", &["item", "isDesc", "nextPage"][..]),
        ("chapter", &["content", "filterTxt", "nextPage"][..]),
        (
            "crawl",
            &["concurrency", "minInterval", "maxInterval", "maxAttempts"][..],
        ),
    ] {
        if let Some(fields) = v[group].as_object() {
            for (name, value) in fields {
                if !supported.contains(&name.as_str())
                    && !value.is_null()
                    && value != ""
                    && value != false
                {
                    warnings.push(format!("so-novel {group}.{name} 暂未转换，请核对规则"));
                }
            }
        }
    }
    let c = &v["crawl"];
    let suggestion = CrawlProfile {
        concurrency: c["concurrency"]
            .as_u64()
            .filter(|n| *n > 0)
            .map(|n| n.min(32) as usize),
        min_interval: (c["minInterval"].as_f64().unwrap_or(0.) * 1000.) as u64,
        max_interval: (c["maxInterval"].as_f64().unwrap_or(0.) * 1000.) as u64,
        retries: c["maxAttempts"]
            .as_u64()
            .map(|n| n.saturating_sub(1).min(3) as usize),
        ..Default::default()
    };
    out["easypub"] = json!({"importWarnings":warnings,"crawlSuggestion":suggestion});
    out
}
pub fn suggest(s: &mut BookSource) {
    if s.meta.crawl_suggestion.is_none() {
        let re =
            regex::Regex::new(r"线程(?:数)?(?:建议)?(?:不大于|不超过|小于等于|≤)\s*(\d+)").unwrap();
        if let Some(c) = re.captures(&s.book_source_comment) {
            s.meta.crawl_suggestion = Some(CrawlProfile {
                concurrency: c[1].parse::<usize>().ok().map(|n| n.clamp(1, 32)),
                ..Default::default()
            });
        }
    }
    if !s.main_js.is_empty() && (!s.login_ui.is_empty() || !s.login_action.is_empty()) {
        let warning = "单文件 JS 的 loginUi / loginAction 暂不支持；可使用网页登录".to_owned();
        if !s.meta.import_warnings.contains(&warning) {
            s.meta.import_warnings.push(warning);
        }
    }
}
