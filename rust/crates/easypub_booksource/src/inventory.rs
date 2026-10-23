//! 显式调用的只读普查。输出固定类别、接口标识符和计数，不输出规则或地址。
use crate::{source::BookSource, support};
use regex::Regex;
use serde::Serialize;
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

#[derive(Debug, Serialize)]
pub struct Row {
    pub category: String,
    pub name: String,
    pub sources: usize,
    pub text_sources: usize,
    pub status: &'static str,
    pub boundary: &'static str,
}

#[derive(Serialize)]
pub struct Report {
    pub input_sources: usize,
    pub unique_sources: usize,
    pub text_sources: usize,
    pub rows: Vec<Row>,
    pub limits: &'static str,
}

fn capability(category: &str, name: &str) -> (&'static str, &'static str) {
    let name = name.strip_prefix("Packages.").unwrap_or(name);
    if [
        "java.nio.file",
        "java.lang.Runtime",
        "java.lang.ProcessBuilder",
        "java.lang.reflect",
        "java.lang.Class",
        "java.io.File",
        "java.net.Socket",
        "java.net.InetSocketAddress",
    ]
    .iter()
    .any(|prefix| name.starts_with(prefix))
        || name == "java.readFile"
    {
        return (
            "有意不支持",
            "不开放任意文件、进程、反射、类加载或绕过插件网络通道的原始套接字",
        );
    }
    for (class, boundary) in [
        (
            "java.util.ArrayList",
            "内存集合构造、add/addAll/get/set/remove/size/toArray/subList/clear；非完整 Java Collections",
        ),
        (
            "java.lang.Thread",
            "仅 sleep，0–30000 毫秒、可取消；不创建线程",
        ),
        (
            "java.lang.System",
            "时间及引擎隔离的兼容属性表；不读环境变量、用户目录，不提供 JVM/进程能力",
        ),
    ] {
        if name == class || name.starts_with(&format!("{class}.")) {
            return ("部分支持", boundary);
        }
    }
    if category == "规则标记" {
        return match name {
            "webJs" => ("部分支持", "依赖 Windows WebView2；非交互校验不代办验证码"),
            "sourceRegex" => (
                "部分支持",
                "WebView2 捕获首个匹配的 HTTP(S) 请求网址，不返回资源正文；超时或取消不伪装成 HTML",
            ),
            _ => (
                "部分支持",
                "已有解析分支；组合、边界与阅读一致性由 C 批语义夹具验证",
            ),
        };
    }
    if category == "URL选项" {
        return match name {
            "method" | "body" | "headers" | "charset" | "retry" | "type" | "proxy" | "insecure"
            | "js" => (
                "已支持",
                "静态选项字段已有分支；值及脚本的具体语义不由频次普查验证",
            ),
            "webView" | "webJs" | "sourceRegex" => {
                ("部分支持", "依赖 Windows WebView2，验证交互受任务权限控制")
            }
            _ => ("不支持", "analyze_url 未读取此选项"),
        };
    }
    if category == "java函数" {
        return if support::JAVA_FUNCTIONS.contains(&name.strip_prefix("java.").unwrap_or(name)) {
            (
                "部分支持",
                "已实现入口；重载、宿主差异及调用参数仍受实现约束，不代表完整安卓 API",
            )
        } else {
            ("不支持", "当前 java 函数清单没有此入口")
        };
    }
    if category != "导入目标"
        && [
            "java.lang.Integer",
            "java.lang.Long",
            "java.lang.Math",
            "java.net.URLEncoder",
            "java.net.URLDecoder",
        ]
        .iter()
        .any(|class| name == *class || name.starts_with(&format!("{class}.")))
    {
        return (
            "部分支持",
            "prelude 提供直接属性访问的子集；未登记到 Java 导入类表，导入语义不齐全",
        );
    }
    if support::JAVA_CLASSES
        .iter()
        .any(|class| name == *class || name.starts_with(&format!("{class}.")))
    {
        ("部分支持", "仅白名单类的已实现方法和重载；不是 JVM 类库")
    } else if matches!(category, "导入目标" | "Packages路径")
        && support::JAVA_CLASSES
            .iter()
            .any(|class| class.rsplit_once('.').is_some_and(|(p, _)| p == name))
    {
        ("部分支持", "仅导入包内已实现白名单类，不开放整个包")
    } else {
        (
            "不支持",
            "当前类白名单未实现；动态别名和运行时生成的目标不在静态普查内",
        )
    }
}

/// 名称+网址完全相同的记录合并，写法取所有副本的并集，避免选副本时丢掉写法。
pub fn analyze(values: &[Value]) -> Result<Report, &'static str> {
    let dotted = Regex::new(r"\b(?:Packages\.[A-Za-z_$][A-Za-z0-9_$]*(?:\.[A-Za-z_$][A-Za-z0-9_$]*)*|(?:java|javax|android|org|okhttp3|cn)\.[A-Za-z_$][A-Za-z0-9_$]*(?:\.[A-Za-z_$][A-Za-z0-9_$]*)*)").unwrap();
    let target = Regex::new(
        r"^(?:Packages\.[A-Za-z_$][A-Za-z0-9_$]*(?:\.[A-Za-z_$][A-Za-z0-9_$]*)*|(?:java|javax|android|org|okhttp3|cn)(?:\.[A-Za-z_$][A-Za-z0-9_$]*)*)$",
    )
    .unwrap();
    let imports =
        Regex::new(r"\b(?:importClass|importPackage|JavaImporter)\s*\(([^()]*)\)").unwrap();
    let mut unique = BTreeMap::<(String, String), (bool, BTreeSet<(String, String)>)>::new();
    for value in values {
        let source: BookSource = serde_json::from_value(value.clone())
            .map_err(|_| "存在不能反序列化的书源，未输出部分报告")?;
        let (text, hits) = unique
            .entry((
                source.book_source_name.clone(),
                source.book_source_url.clone(),
            ))
            .or_default();
        *text |= source.book_source_type == 0;
        let code = support::execution_blob(&source);
        for found in dotted.find_iter(&code) {
            let original = found.as_str();
            let name = original.strip_prefix("Packages.").unwrap_or(original);
            let parts: Vec<_> = name.split('.').collect();
            if original.starts_with("Packages.") {
                hits.insert(("Packages路径".into(), original.into()));
            }
            if parts.len() == 2
                && parts[0] == "java"
                && !["lang", "util", "net", "io", "nio", "security", "math"].contains(&parts[1])
            {
                hits.insert(("java函数".into(), name.into()));
            } else if let Some(index) = parts.iter().position(|s| s.starts_with(char::is_uppercase))
            {
                hits.insert(("Java类".into(), parts[..=index].join(".")));
            }
        }
        for captures in imports.captures_iter(&code) {
            for arg in captures[1].split(',').map(str::trim) {
                if target.is_match(arg) {
                    hits.insert(("导入目标".into(), arg.into()));
                    if arg.starts_with("Packages.") {
                        hits.insert(("Packages路径".into(), arg.into()));
                    }
                }
            }
        }
        // 仅规则字段与 URL 字段，排除名称、说明、历史记录；标记计数不是 DSL 执行次数。
        for (key, item) in value.as_object().ok_or("书源不是对象")? {
            if key.starts_with("rule") || matches!(key.as_str(), "searchUrl" | "exploreUrl") {
                visit_rules(item, hits);
            }
        }
    }
    let mut counts = BTreeMap::<(String, String), (usize, usize)>::new();
    for (text, hits) in unique.values() {
        for hit in hits {
            let n = counts.entry(hit.clone()).or_default();
            n.0 += 1;
            n.1 += usize::from(*text);
        }
    }
    let mut rows: Vec<_> = counts
        .into_iter()
        .map(|((category, name), (sources, text_sources))| {
            let (status, boundary) = capability(&category, &name);
            Row {
                category,
                name,
                sources,
                text_sources,
                status,
                boundary,
            }
        })
        .collect();
    rows.sort_by(|a, b| {
        b.sources
            .cmp(&a.sources)
            .then(a.category.cmp(&b.category))
            .then(a.name.cmp(&b.name))
    });
    Ok(Report {
        input_sources: values.len(),
        unique_sources: unique.len(),
        text_sources: unique.values().filter(|v| v.0).count(),
        rows,
        limits: "JS接口经词法分析排除注释/字面量，截断于词法错误；不追踪动态属性、别名或外部脚本。规则标记为字段文本出现次数，可能出现在内嵌JS字符串，不能等同执行。每源每项只计一次；名称+网址去重后合并副本写法，任一副本为文字则计文字。频次不是可用率。",
    })
}

fn visit_rules(value: &Value, hits: &mut BTreeSet<(String, String)>) {
    match value {
        Value::String(s) => {
            for (marker, name) in [
                ("@css:", "@css"),
                ("@xpath:", "@xpath"),
                ("@json:", "@json"),
                ("$.", "$."),
                ("##", "##替换"),
                ("{{", "{{表达式}}"),
                ("<js>", "<js>"),
                ("@js:", "@js:"),
                ("@put:", "@put"),
                ("@get:", "@get"),
                ("&&", "&&"),
                ("||", "||"),
                ("%%", "%%"),
            ] {
                if s.contains(marker) {
                    hits.insert(("规则标记".into(), name.into()));
                }
            }
            if s.trim_start().starts_with(':') {
                hits.insert(("规则标记".into(), ":正则".into()));
            }
            if let Some(Value::Object(options)) = crate::engine::split_options(s).1 {
                for name in [
                    "method",
                    "body",
                    "headers",
                    "charset",
                    "retry",
                    "type",
                    "proxy",
                    "insecure",
                    "js",
                    "webView",
                    "webJs",
                    "sourceRegex",
                    "serverID",
                ] {
                    if options.keys().any(|key| key.eq_ignore_ascii_case(name)) {
                        hits.insert(("URL选项".into(), name.into()));
                    }
                }
            }
        }
        Value::Object(items) => {
            for (key, item) in items {
                if matches!(key.as_str(), "webJs" | "sourceRegex")
                    && item.as_str().is_some_and(|s| !s.is_empty())
                {
                    hits.insert(("规则标记".into(), key.clone()));
                }
                visit_rules(item, hits);
            }
        }
        Value::Array(items) => {
            for item in items {
                visit_rules(item, hits);
            }
        }
        _ => (),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn dedupe_unions_variants_without_counting_comments_or_metadata() {
        let values = vec![
            json!({"bookSourceName":"示例","bookSourceUrl":"https://example.invalid","jsLib":"/*java.fake()*/java.ajax('java.secret()');importClass(Packages.java.lang.String);","ruleContent":{"content":"@css:p@text##a##b"}}),
            json!({"bookSourceName":"示例","bookSourceUrl":"https://example.invalid","jsLib":"java.put('x','y');importClass(Packages.custom.Example);","easypub":{"check":{"error":"java.leak()"}}}),
            json!({"bookSourceName":"其他","bookSourceUrl":"https://example.invalid","bookSourceType":2,"jsLib":"java.ajax('x')"}),
        ];
        let report = analyze(&values).unwrap();
        assert_eq!(
            (
                report.input_sources,
                report.unique_sources,
                report.text_sources
            ),
            (3, 2, 1)
        );
        let ajax = report.rows.iter().find(|r| r.name == "java.ajax").unwrap();
        assert_eq!((ajax.sources, ajax.text_sources), (2, 1));
        assert!(
            report
                .rows
                .iter()
                .any(|r| r.name == "java.put" && r.sources == 1)
        );
        let output = serde_json::to_string(&report).unwrap();
        assert!(
            report
                .rows
                .iter()
                .any(|r| r.category == "导入目标" && r.name == "Packages.custom.Example")
        );
        for forbidden in [
            "example.invalid",
            "java.fake",
            "java.secret",
            "java.leak",
            "示例",
        ] {
            assert!(!output.contains(forbidden));
        }
        assert_eq!(capability("Java类", "java.io.File").0, "有意不支持");
    }
}
