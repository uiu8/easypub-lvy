//! 全链校验结果只包含阶段和统计，不返回正文、请求头或第三方脚本日志。
use crate::{control::ErrorKind, engine::Engine, scheduler::content_issue};
use serde::Serialize;

#[derive(Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Check {
    pub stage: &'static str,
    pub search_results: usize,
    pub chapters: usize,
    pub sampled: usize,
    pub chars: usize,
    pub cause: Option<&'static str>,
    pub unsupported: Vec<String>,
    pub static_warnings: Vec<String>,
    pub unsupported_interface: Option<String>,
    /// 只记录选择来源和尝试次数，不回显用户输入。
    pub keyword_origin: &'static str,
    pub search_attempts: usize,
    /// 固定网络子类；没有底层证据时为 null，不把脚本错误猜成网络错误。
    pub network_failure: Option<&'static str>,
    pub diagnostic: Option<&'static str>,
}

pub fn check(engine: &Engine, keyword: &str, report: &mut Check) -> Result<u16, String> {
    let problems = crate::support::check(engine.source());
    report.static_warnings = problems
        .iter()
        .filter(|p| {
            !matches!(
                p,
                crate::support::Problem::NoSearch | crate::support::Problem::NoContentRule
            )
        })
        .map(|p| p.message())
        .collect();
    let result = if !crate::support::can_run(engine.source()) {
        report.stage = "support";
        Err(if crate::support::cause(&problems) == Some("rule") {
            "书源缺少搜索或正文规则"
        } else {
            "插件不支持的写法"
        }
        .into())
    } else {
        engine.run(|s| {
            report.stage = "search";
            let source_keyword =
                crate::source::BookSource::rule(&engine.source().rule_search, "checkKeyWord")
                    .trim();
            let keys: Vec<&str> = if !keyword.trim().is_empty() {
                report.keyword_origin = "user";
                vec![keyword.trim()]
            } else if !source_keyword.is_empty() {
                report.keyword_origin = "source";
                vec![source_keyword]
            } else {
                report.keyword_origin = "default";
                vec!["我的", "斗罗大陆", "修仙"]
            };
            let mut books = Vec::new();
            for key in keys {
                report.search_attempts += 1;
                books = s.search(key, 1)?;
                if !books.is_empty() {
                    break;
                }
            }
            report.search_results = books.len();
            let mut book = books.into_iter().next().ok_or("校验词没有搜索结果")?;
            report.stage = "detail";
            s.book_info(&mut book)?;
            report.stage = "toc";
            let toc = s.toc(&book)?;
            report.chapters = toc.iter().filter(|c| !c.is_volume).count();
            if report.chapters == 0 {
                return Err("没有解析到目录章节".into());
            }
            let mut error = "没有可校验的免费章节".to_owned();
            for (i, chapter) in toc
                .iter()
                .enumerate()
                .filter(|(_, c)| !c.is_volume && !c.is_pay && !c.is_vip)
                .take(3)
            {
                report.stage = "content";
                report.sampled += 1;
                let next = toc[i + 1..]
                    .iter()
                    .find(|c| !c.is_volume)
                    .map(|c| c.url.as_str())
                    .unwrap_or("");
                let result = s.chapter_content(&book, chapter, next).and_then(|text| {
                    report.chars = crate::scheduler::chars(&text);
                    match content_issue(
                        &text,
                        0,
                        chapter,
                        &engine.source().meta.crawl.throttle_phrases,
                    ) {
                        Some(kind) => Err(kind.label().into()),
                        None => Ok(()),
                    }
                });
                match result {
                    Ok(()) => return Ok(200),
                    Err(e) => {
                        let retry_chapter = matches!(
                            ErrorKind::classify(&e),
                            ErrorKind::Empty
                                | ErrorKind::ShortContent
                                | ErrorKind::ContentUnavailable
                                | ErrorKind::Missing
                        );
                        error = e;
                        if !retry_chapter {
                            break;
                        }
                    }
                }
            }
            Err(error)
        })
    };
    if let Err(error) = &result {
        if let Some(name) = unsupported_interface(error) {
            report.unsupported_interface = Some(name.to_owned());
            report
                .unsupported
                .push(format!("脚本调用了尚未支持的 {name}"));
        } else if !crate::support::can_run(engine.source()) {
            report.unsupported = report.static_warnings.clone();
        }
    }
    report.diagnostic = result.as_ref().err().and_then(|e| {
        if e.contains("规则 JSON 数据解析失败") {
            Some("script_json_error")
        } else if e.contains("规则脚本语法错误") {
            Some("script_syntax_error")
        } else if e.contains("时数据为空") {
            Some("script_null_input")
        } else if e.contains("调用的值不是函数") {
            Some("script_not_callable")
        } else if e.contains("规则脚本类型错误") {
            Some("script_type_error")
        } else if e.contains("尚不支持的函数或变量") {
            Some("script_missing_identifier")
        } else if e.contains("脚本出错：") {
            Some("script_error")
        } else {
            None
        }
    });
    report.network_failure = result
        .as_ref()
        .err()
        .and_then(|e| crate::network_failure::code(e));
    report.cause = result
        .as_ref()
        .err()
        .and_then(|e| ErrorKind::classify(e).cause());
    result
}

pub fn reason(error: &str) -> &str {
    if error.starts_with("外部 JS 库下载失败：") {
        return "外部 JS 库下载失败";
    }
    if unsupported_interface(error).is_some() {
        return error
            .split_once("不支持的 Java 类或方法：")
            .map_or(error, |(_, name)| {
                // 返回固定前缀起始的切片，不包含阶段前缀和其他错误内容。
                &error[error.len() - name.len() - "不支持的 Java 类或方法：".len()..]
            });
    }
    for (prefix, label) in [
        ("搜索脚本出错：", "搜索脚本执行失败"),
        ("详情脚本出错：", "详情脚本执行失败"),
        ("目录脚本出错：", "目录脚本执行失败"),
        ("正文脚本出错：", "正文脚本执行失败"),
    ] {
        if error.starts_with(prefix) {
            return label;
        }
    }
    // 固定词表；绝不把 JS 的任意报错（可能夹带凭据/正文）发到界面和日志。
    match error {
        "不支持的 Java 类或方法：java.io.File"
        | "不支持的 Java 类或方法：java.io.FileInputStream"
        | "不支持的 Java 类或方法：java.nio.file.Files.readAllBytes"
        | "不支持的 Java 类或方法：java.lang.Runtime.getRuntime"
        | "不支持的 Java 类或方法：java.lang.ProcessBuilder"
        | "不支持的 Java 类或方法：java.lang.Class.forName"
        | "不支持的 Java 类或方法：java.lang.ClassLoader"
        | "不支持的 Java 类或方法：java.net.URL.openConnection"
        | "不支持的 Java 类或方法：java.net.URL.openStream" => error,
        "需要验证：FQNovel 签名失败，请在 FQNovel Desktop 中恢复服务后重试"
        | "网站错误：FQNovel 正在维护，请等待设备刷新完成后重试"
        | "网站错误：FQNovel worker 尚未就绪，请先启动 FQNovel Desktop 并等待就绪后重试"
        | "校验词没有搜索结果"
        | "没有解析到目录章节"
        | "没有可校验的免费章节"
        | "HTML 书源远程页面加载失败"
        | "HTML 书源外部脚本加载失败"
        | "HTML 书源脚本执行失败或缺少入口函数"
        | "HTML 书源调用了尚未适配的原生接口"
        | "HTML 书源返回音频或漫画，当前仅支持文字书籍"
        | "HTML 书源当前仅支持文字书籍" => error,
        _ => ErrorKind::classify(error).label(),
    }
}

pub(crate) fn unsupported_interface(error: &str) -> Option<&str> {
    let (_, name) = error.split_once("不支持的 Java 类或方法：")?;
    let roots = [
        "java.",
        "javax.",
        "android.",
        "Packages.",
        "okhttp3.",
        "cn.",
    ];
    (name.len() <= 120
        && roots.iter().any(|root| name.starts_with(root))
        && name.split('.').all(|part| {
            !part.is_empty()
                && part.len() <= 48
                && part
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '$')
        }))
    .then_some(name)
}
