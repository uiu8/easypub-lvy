//! 书源静态能力提示；文字源准入与实际运行结果独立于提示。
use crate::source::BookSource;
use serde::Serialize;

/// 静态检查和运行时 Java 导入共同使用的已实现类清单。
pub(crate) const JAVA_CLASSES: &[&str] = &[
    "org.jsoup.Jsoup",
    "okhttp3.Request",
    "okhttp3.OkHttpClient",
    "cn.hutool.crypto.digest.DigestUtil",
    "java.lang.String",
    "java.lang.System",
    "java.lang.Thread",
    "java.util.ArrayList",
    "java.nio.charset.Charset",
    "java.nio.ByteBuffer",
    "java.util.Arrays",
    "java.util.Base64",
    "android.util.Base64",
    "android.text.TextUtils",
    "android.webkit.CookieManager",
    "java.security.MessageDigest",
    "java.security.SecureRandom",
    "java.security.KeyFactory",
    "java.security.Signature",
    "java.security.spec.X509EncodedKeySpec",
    "java.security.spec.PKCS8EncodedKeySpec",
    "java.util.UUID",
    "javax.crypto.spec.SecretKeySpec",
    "javax.crypto.spec.IvParameterSpec",
    "javax.crypto.spec.GCMParameterSpec",
    "javax.crypto.Cipher",
    "javax.crypto.Mac",
    "java.math.BigInteger",
    "java.io.ByteArrayInputStream",
    "java.io.ByteArrayOutputStream",
    "java.io.InputStreamReader",
    "java.io.BufferedReader",
    "java.util.zip.GZIPInputStream",
    "java.util.zip.GZIPOutputStream",
    "java.net.URL",
];

/// prelude.js 里提供的 java.* 函数。
pub(crate) const JAVA_FUNCTIONS: &[&str] = &[
    "refreshExplore",
    "searchBook",
    "open",
    "ruleUrl",
    "ajaxTestAll",
    "copyText",
    "openUrl",
    "openWeb",
    "showReadingBrowser",
    "startBrowserDp",
    "deviceID",
    "getUserAgent",
    "sleep",
    "base64Decoder",
    "getStrResponse",
    "clearCookie",
    "getVerificationCode",
    "upLoginData",
    "reLoginView",
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
    "createAsymmetricCrypto",
    "createSign",
    "queryTTF",
    "queryBase64TTF",
    "replaceFont",
    "downloadFile",
    "readTxtFile",
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
    "java.openUrl",
    "java.openWeb",
    "java.showReadingBrowser",
    "java.startBrowserDp",
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

/// 静态扫描的结果按书源内容指纹缓存。书源列表每次要扫两千多个书源，原来每个书源要把全部脚本
/// 拼成可执行文本三四遍（check、needs_web_view、tags 各一遍），sources.list 从约 0.4 秒退化到 6 秒。
/// 指纹只取会影响扫描结果的字段；书源内容一改，指纹就变，不会用到旧结果。
struct Scan {
    problems: Vec<Problem>,
    web_view: bool,
}

fn fingerprint(source: &BookSource) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    (
        source.book_source_type,
        &source.search_url,
        &source.explore_url,
        &source.html,
        &source.main_js,
        &source.js_lib,
        &source.login_check_js,
        &source.cover_decode_js,
        &source.login_action,
        &source.header,
        &source.login_url,
        &source.login_ui,
    )
        .hash(&mut h);
    for rules in [
        &source.rule_search,
        &source.rule_explore,
        &source.rule_book_info,
        &source.rule_toc,
        &source.rule_content,
    ] {
        rules.hash(&mut h);
    }
    h.finish()
}

fn scan(source: &BookSource) -> std::sync::Arc<Scan> {
    use std::{
        collections::HashMap,
        sync::{Arc, Mutex, OnceLock},
    };
    static CACHE: OnceLock<Mutex<HashMap<u64, Arc<Scan>>>> = OnceLock::new();
    let cache = CACHE.get_or_init(Default::default);
    let key = fingerprint(source);
    if let Some(hit) = cache.lock().unwrap().get(&key) {
        return hit.clone();
    }
    let blob = execution_blob(source);
    let web_view = web_view_in(source, &blob);
    let result = Arc::new(Scan {
        problems: check_in(source, &blob, web_view),
        web_view,
    });
    let mut cache = cache.lock().unwrap();
    // 书源总数有限；超出上限时整体清空，避免反复导入改动的书源让缓存无限增长。
    if cache.len() >= 20_000 {
        cache.clear();
    }
    cache.insert(key, result.clone());
    result
}

/// 列书源前把还没扫过的书源分给几个线程先扫一遍（结果进缓存），插件刚启动时第一次打开书源页也不用久等。
pub fn prewarm<'a>(sources: impl Iterator<Item = &'a BookSource>) {
    let list: Vec<&BookSource> = sources.collect();
    let threads = std::thread::available_parallelism()
        .map_or(4, |n| n.get())
        .min(8);
    let chunk = list.len().div_ceil(threads).max(1);
    std::thread::scope(|s| {
        for part in list.chunks(chunk) {
            s.spawn(move || {
                for source in part {
                    scan(source);
                }
            });
        }
    });
}

/// 书源是否用到 WebView（网址选项、脚本函数或正文的 webJs）。
pub fn needs_web_view(source: &BookSource) -> bool {
    scan(source).web_view
}

fn web_view_in(source: &BookSource, blob: &str) -> bool {
    !source.html.trim().is_empty()
        || WEB_VIEW.iter().any(|w| blob.contains(w))
        || !BookSource::rule(&source.rule_content, "webJs").is_empty()
        || [&source.search_url, &source.explore_url].iter().any(|url| {
            crate::engine::split_options(url).1.is_some_and(|options| {
                ["webJs", "sourceRegex"].iter().any(|key| {
                    options
                        .get(*key)
                        .and_then(serde_json::Value::as_str)
                        .is_some_and(|v| !v.trim().is_empty())
                }) || options.get("webView").is_some_and(|v| {
                    !matches!(v, serde_json::Value::Null | serde_json::Value::Bool(false))
                        && v.as_str() != Some("")
                })
            })
        })
}

// 书源说明、名称、分组和历史检查结果不是可执行代码。
pub(crate) fn execution_blob(source: &BookSource) -> String {
    let mut out = String::new();
    for script in [
        &source.js_lib,
        &source.main_js,
        &source.login_check_js,
        &source.cover_decode_js,
        &source.login_action,
    ] {
        out.push_str(&crate::script_scan::code(script));
        out.push('\n');
    }
    fn visit(value: &serde_json::Value, out: &mut String) {
        match value {
            serde_json::Value::String(text) => {
                out.push_str(&crate::script_scan::fragments(text));
                out.push('\n');
            }
            serde_json::Value::Array(items) => {
                for item in items {
                    visit(item, out);
                }
            }
            serde_json::Value::Object(items) => {
                for (key, item) in items {
                    if matches!(key.as_str(), "webJs" | "js" | "bodyJs" | "callBackJs") {
                        if let Some(text) = item.as_str() {
                            out.push_str(&crate::script_scan::code(text));
                            out.push('\n');
                        }
                    } else {
                        visit(item, out);
                    }
                }
            }
            _ => (),
        }
    }
    visit(
        &serde_json::json!([
            source.header,
            source.login_url,
            source.login_ui,
            source.explore_url,
            source.search_url,
            source.rule_search,
            source.rule_explore,
            source.rule_book_info,
            source.rule_toc,
            source.rule_content
        ]),
        &mut out,
    );
    out
}

/// 静态能力提示不是运行准入；非文字源仍不执行。
pub fn can_run(source: &BookSource) -> bool {
    source.book_source_type == 0
}

pub fn web_view_supported() -> bool {
    crate::webview::supported()
}

pub fn check(source: &BookSource) -> Vec<Problem> {
    scan(source).problems.clone()
}

fn check_in(source: &BookSource, blob: &str, web_view: bool) -> Vec<Problem> {
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
    if !web_view_supported() && web_view {
        problems.push(Problem::NeedsWebView);
    }
    // 仿 Java 仅放行已实现的具体类，绝不把 java.io/java.security 整个包放行。
    let mut executable = blob
        .replace("\"android.article.news\"", "\"\"")
        .replace("'android.article.news'", "''")
        .replace("android.article.news", "app_package_name");
    // Android 子域名是网络地址，不是 android.* 类；只去掉 HTTP URL 的 authority。
    static ORIGIN: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    executable = ORIGIN
        .get_or_init(|| regex::Regex::new(r"https?://[A-Za-z0-9.-]+(?::[0-9]+)?").unwrap())
        .replace_all(&executable, "supported_origin")
        .into_owned();
    static CLASSES: std::sync::OnceLock<Vec<regex::Regex>> = std::sync::OnceLock::new();
    for pattern in CLASSES.get_or_init(|| {
        JAVA_CLASSES
            .iter()
            .map(|class| regex::Regex::new(&format!(r"\b{}\b", regex::escape(class))).unwrap())
            .collect()
    }) {
        executable = pattern
            .replace_all(&executable, "supported_class")
            .into_owned();
    }
    // 只放行字面量导入调用中的已实现包；包外任意类引用仍按原规则检查。
    static IMPORTS: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    executable = IMPORTS
        .get_or_init(|| {
            regex::Regex::new(r"\b(?:importPackage|JavaImporter)\s*\(([^()]*)\)").unwrap()
        })
        .replace_all(&executable, |c: &regex::Captures<'_>| {
            let args = c[1]
                .replace(r"\n", " ")
                .replace(r"\r", " ")
                .replace(r"\t", " ");
            let known = args.split(',').all(|arg| {
                let arg = arg.trim().strip_prefix("Packages.").unwrap_or(arg.trim());
                arg == "supported_class"
                    || JAVA_CLASSES.iter().any(|class| {
                        class
                            .rsplit_once('.')
                            .is_some_and(|(package, _)| package == arg)
                    })
            });
            if known {
                "supported_import".to_owned()
            } else {
                c[0].to_owned()
            }
        })
        .into_owned();
    for word in [
        "android.",
        "java.io.",
        "javax.",
        "JavaAdapter",
        "java.nio.file",
        "java.lang.Runtime",
        "java.lang.ProcessBuilder",
        "java.lang.Class",
        "java.lang.reflect",
        "java.lang.ClassLoader",
    ] {
        if executable.contains(word) {
            problems.push(Problem::JavaOnly(word.trim_end_matches('.').to_owned()));
            break;
        }
    }
    static JAVA_CALL: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let re =
        JAVA_CALL.get_or_init(|| regex::Regex::new(r"\bjava\.([A-Za-z_][A-Za-z0-9_]*)").unwrap());
    let mut unknown: Vec<String> = re
        .captures_iter(&executable)
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

    #[test]
    fn scan_cache_follows_source_content() {
        // 同一书源反复检查走缓存；改了脚本，结果跟着变，不会拿到旧结果。
        let mut source = BookSource {
            search_url: "/search".into(),
            js_lib: "java.someNewThing()".into(),
            rule_content: serde_json::from_value(serde_json::json!({"content":"#c@text"})).unwrap(),
            ..Default::default()
        };
        let first = check(&source);
        assert_eq!(first, check(&source));
        assert!(first.contains(&Problem::UnknownFunction("someNewThing".into())));
        assert!(!needs_web_view(&source));
        source.js_lib = "java.ajax('x')".into();
        assert!(check(&source).is_empty());
        source.js_lib = "java.webView('x')".into();
        assert!(needs_web_view(&source));
        // 并行预热后结果不变。
        prewarm([&source].into_iter());
        assert!(needs_web_view(&source));
    }

    #[test]
    fn implemented_package_imports_do_not_allow_other_java_classes() {
        let source = |code: &str| BookSource {
            search_url: "/search".into(),
            js_lib: code.into(),
            rule_content: serde_json::from_value(serde_json::json!({"content":"#c@text"})).unwrap(),
            ..Default::default()
        };
        for code in [
            "importPackage(Packages.java.lang,\nPackages.javax.crypto.spec,Packages.javax.crypto,Packages.java.util);",
            "with(new JavaImporter(java.io,javax.crypto.spec)){new SecretKeySpec([], 'AES');}",
            "importClass(java.security.MessageDigest);",
        ] {
            assert!(check(&source(code)).is_empty());
        }
        for code in [
            "importPackage(java.io);new java.io.File('private')",
            "new JavaImporter(java.nio.file)",
            "importPackage(java.security.interfaces)",
            "java.io.FileInputStream('private')",
        ] {
            assert_eq!(cause(&check(&source(code))), Some("unsupported"));
        }
    }

    #[test]
    #[ignore = "只读用户指定合集，仅输出分类数字"]
    fn v97_c_classification_comparison() {
        let names = [
            "deviceID",
            "getUserAgent",
            "sleep",
            "base64Decoder",
            "getStrResponse",
            "clearCookie",
            "getVerificationCode",
            "upLoginData",
            "reLoginView",
        ];
        let selected = std::env::var("EASYPUB_V97_C_FUNCTIONS").ok();
        let names: Vec<&str> = selected
            .as_deref()
            .map(|s| s.split(',').collect())
            .unwrap_or_else(|| names.to_vec());
        let pattern = regex::Regex::new(r"\bjava\.([A-Za-z_][A-Za-z0-9_]*)").unwrap();
        let mut reports = Vec::new();
        for (index, path) in std::env::var("EASYPUB_V97_INPUTS")
            .unwrap()
            .split(';')
            .enumerate()
        {
            let input = std::fs::read(path).unwrap();
            let text = std::str::from_utf8(&input)
                .unwrap()
                .trim_start_matches('\u{feff}');
            let (sources, _) = crate::source::import(text).unwrap();
            let mut before: BTreeMap<&str, usize> = names.iter().map(|n| (*n, 0)).collect();
            let mut after = before.clone();
            let (mut before_sources, mut after_sources) = (0, 0);
            for source in &sources {
                let problems = check(source);
                let blob = execution_blob(source);
                let hits: std::collections::BTreeSet<_> = pattern
                    .captures_iter(&blob)
                    .map(|c| c[1].to_owned())
                    .filter(|n| names.contains(&n.as_str()))
                    .collect();
                for name in &hits {
                    *before.get_mut(name.as_str()).unwrap() += 1;
                }
                for problem in &problems {
                    if let Problem::UnknownFunction(name) = problem
                        && let Some(count) = after.get_mut(name.as_str())
                    {
                        *count += 1;
                    }
                }
                before_sources += usize::from(!problems.is_empty() || !hits.is_empty());
                after_sources += usize::from(!problems.is_empty());
            }
            // 只恢复本轮指定函数的 UnknownFunction，其他检查与当前版本相同。历史报告保持冻结。
            reports.push(serde_json::json!({"input_index":index,"total":sources.len(),"before_unknown":before,"after_unknown":after,"before_problem_sources":before_sources,"after_problem_sources":after_sources}));
            assert_eq!(std::fs::read(path).unwrap(), input);
        }
        std::fs::write(
            std::env::var("EASYPUB_V97_REPORT").unwrap(),
            serde_json::to_vec_pretty(&reports).unwrap(),
        )
        .unwrap();
    }

    #[test]
    fn concrete_classes_keep_forbidden_names_rejected() {
        let source = |code: &str| BookSource {
            search_url: "/search".into(),
            js_lib: code.into(),
            rule_content: serde_json::from_value(serde_json::json!({"content":"#c@text"})).unwrap(),
            ..Default::default()
        };
        assert!(check(&source("var packageName='android.article.news';new Packages.java.io.ByteArrayOutputStream();javax.crypto.Cipher.getInstance('AES/CBC/PKCS5Padding');")).is_empty());
        assert!(
            check(&source(
                "java.ajax('https://android.example.invalid/search')"
            ))
            .is_empty()
        );
        assert!(!check(&source("android.graphics.BitmapFactory.decodeStream(null)")).is_empty());
        for code in [
            "new java.io.File('fake')",
            "new java.io.FileInputStream('fake')",
            "java.nio.file.Files.readAllBytes('fake')",
            "java.lang.Class.forName('fake')",
            "java.lang.Runtime.getRuntime()",
            "new java.lang.ClassLoader()",
        ] {
            assert_eq!(cause(&check(&source(code))), Some("unsupported"));
        }
    }

    #[test]
    #[ignore = "只读私有合集和内存夹具；显式指定路径，仅写统计"]
    fn v97_private_syntax_comparison() {
        use serde_json::json;
        let inputs = std::env::var("EASYPUB_V97_INPUTS").expect("指定输入路径列表");
        let mut reports = Vec::new();
        let re = regex::Regex::new(r"\bjava\.([A-Za-z_][A-Za-z0-9_]*)").unwrap();
        for (index, path) in inputs.split(';').enumerate() {
            let raw = std::fs::read(path).expect("读取失败");
            let (sources, skipped) =
                crate::source::import(&String::from_utf8_lossy(&raw)).expect("合集解析失败");
            let mut before = BTreeMap::<String, usize>::new();
            let mut after = BTreeMap::<String, usize>::new();
            let mut private = Vec::new();
            for source in &sources {
                let blob = execution_blob(source);
                for word in ["android.", "java.io.", "javax.", "JavaAdapter"] {
                    if blob.contains(word) {
                        *before
                            .entry(format!("java-only {}", word.trim_end_matches('.')))
                            .or_default() += 1;
                        break;
                    }
                }
                let unknown: std::collections::BTreeSet<_> = re
                    .captures_iter(&blob)
                    .map(|c| c[1].to_owned())
                    .filter(|f| !JAVA_FUNCTIONS.contains(&f.as_str()))
                    .collect();
                for f in unknown {
                    *before.entry(format!("unknown java.{f}")).or_default() += 1;
                }
                for p in check(source) {
                    let name = match p {
                        Problem::JavaOnly(w) => format!("java-only {w}"),
                        Problem::UnknownFunction(f) => format!("unknown java.{f}"),
                        _ => continue,
                    };
                    *after.entry(name).or_default() += 1;
                }
                if source.book_source_name.contains("番茄")
                    && source.book_source_name.to_uppercase().contains("APP")
                    && !source.js_lib.is_empty()
                {
                    let ctx = crate::control::Context {
                        pure_compute: true,
                        ..Default::default()
                    };
                    let _guard = ctx.enter();
                    let engine = crate::engine::Engine::new(crate::engine::SourceRt::new(
                        BookSource::default(),
                    ))
                    .unwrap();
                    let result = engine.run(|s| s.eval_js(&source.js_lib, &[]));
                    let vectors = engine.run(|s| {
                        s.eval_js_string(
                            &format!(
                                "{}\n{}",
                                source.js_lib,
                                include_str!("java_private_vectors.js")
                            ),
                            &[],
                        )
                    });
                    let stage = engine
                        .run(|s| {
                            s.eval_js_string("String(Number(globalThis.__private_stage)||0)", &[])
                        })
                        .unwrap_or_default();
                    private.push(json!({"js_bytes":source.js_lib.len(),"initialization_ok":result.is_ok(),"failure_cause":result.err().and_then(|e|crate::control::ErrorKind::classify(&e).cause()),"algorithm_vectors_ok":vectors.as_deref()==Ok("private-vectors-ok"),"algorithm_stage":stage.parse::<u32>().unwrap_or(0),"algorithm_failure_cause":vectors.err().and_then(|e|crate::control::ErrorKind::classify(&e).cause()),"network_allowed":false,"remaining_problems":check(source).iter().map(Problem::message).collect::<Vec<_>>()}));
                }
            }
            assert_eq!(raw, std::fs::read(path).unwrap(), "输入必须保持不变");
            reports.push(json!({"input_index":index,"total":sources.len(),"skipped":skipped,"before":before,"after":after,"private_app_initialization":private}));
        }
        std::fs::write(
            std::env::var("EASYPUB_V97_REPORT").unwrap(),
            serde_json::to_vec_pretty(&reports).unwrap(),
        )
        .unwrap();
    }

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
