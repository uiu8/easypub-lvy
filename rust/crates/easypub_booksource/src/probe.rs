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
}

pub fn check(engine: &Engine, keyword: &str, report: &mut Check) -> Result<u16, String> {
    let problems = crate::support::check(engine.source());
    report.unsupported = problems
        .iter()
        .filter(|p| {
            !matches!(
                p,
                crate::support::Problem::NoSearch | crate::support::Problem::NoContentRule
            )
        })
        .map(|p| p.message())
        .collect();
    let result = if !problems.is_empty() {
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
            let books = s.search(keyword, 1)?;
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
    report.cause = result
        .as_ref()
        .err()
        .and_then(|e| ErrorKind::classify(e).cause());
    result
}

pub fn reason(error: &str) -> &str {
    // 固定词表；绝不把 JS 的任意报错（可能夹带凭据/正文）发到界面和日志。
    match error {
        "校验词没有搜索结果"
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
