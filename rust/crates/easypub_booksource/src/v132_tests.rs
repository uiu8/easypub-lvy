//! V132：疑似不完整的章换书源核对；卡住的章由空闲书源抢下。仅本机自拟内容。
use crate::{
    download::{self, Options},
    engine::SourceRt,
    scheduler::{self, Lane},
    source::BookSource,
    tests::{html, serve},
    webbook::{Book, Chapter},
};
use serde_json::json;
use std::{
    sync::{Arc, atomic::AtomicBool},
    time::{Duration, Instant},
};

fn runtime(url: &str, threads: usize) -> Arc<SourceRt> {
    let mut source: BookSource =
        serde_json::from_value(json!({"bookSourceUrl":url,"ruleContent":{"content":"#c@html"}}))
            .unwrap();
    source.meta.crawl.concurrency = Some(threads);
    SourceRt::new(source)
}
fn book(base: &str) -> Book {
    Book {
        name: "自拟样书".into(),
        author: "测试作者".into(),
        origin: base.into(),
        book_url: format!("{base}/book"),
        ..Default::default()
    }
}
fn toc(base: &str, n: usize) -> Vec<Chapter> {
    (0..n)
        .map(|i| Chapter {
            index: i,
            title: format!("第{}章 测试{}", i + 1, i + 1),
            url: format!("{base}/c/{i}"),
            ..Default::default()
        })
        .collect()
}
fn full(i: usize) -> String {
    format!(
        "自拟章节 {i}。{}",
        "窗外的风吹动了树叶，灯下的人认真整理着今天的记录。".repeat(60)
    )
}
fn index(path: &str) -> usize {
    path.rsplit('/').next().unwrap().parse().unwrap()
}
/// 替代源只对得上第 1 章（其余章号对不上），保证它只做核对或抢下。
fn only_first(n: usize) -> Vec<Option<usize>> {
    (0..n).map(|i| (i == 0).then_some(0)).collect()
}

fn run(
    label: &str,
    primary: Arc<SourceRt>,
    base: &str,
    alt: &str,
    n: usize,
) -> (download::Outcome, String, Duration) {
    let folder = std::env::temp_dir().join(format!("ep-v132-{label}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&folder);
    let options = Options {
        folder: folder.clone(),
        threads: 4,
        retries: 0,
        // V134 起默认关闭；这里测的就是多源分摊下的核对与抢下。
        multi_source: true,
        ..Default::default()
    };
    let lane = Lane {
        rt: runtime(alt, 2),
        book: book(alt),
        toc: toc(alt, n),
        mapping: only_first(n),
    };
    let start = Instant::now();
    let outcome = download::download_multi(
        primary,
        &book(base),
        &toc(base, n),
        &options,
        Arc::new(AtomicBool::new(false)),
        Arc::new(|_| {}),
        vec![lane],
    )
    .unwrap();
    let elapsed = start.elapsed();
    let cache = download::cache_dir(&folder, &book(base));
    let first = std::fs::read_to_string(cache.join("00000.txt")).unwrap();
    let _ = std::fs::remove_dir_all(&folder);
    (outcome, first, elapsed)
}

#[test]
fn suspiciously_short_chapter_is_rechecked_on_another_source_and_the_fuller_copy_kept() {
    let n = 60;
    // 主源第 1 章只给出约四分之一（被截断），而且回得慢一点，等其余各章先定出常见字数。
    let (base, _) = serve(|req| {
        let i = index(&req.path);
        if i == 0 {
            std::thread::sleep(Duration::from_millis(150));
            let cut: String = full(0).chars().take(400).collect();
            return html(&format!("<div id='c'>{cut}</div>"));
        }
        html(&format!("<div id='c'>{}</div>", full(i)))
    });
    let (alt, alt_log) =
        serve(|req| html(&format!("<div id='c'>{}</div>", full(index(&req.path)))));
    let (outcome, first, _) = run("verify", runtime(&base, 4), &base, &alt, n);
    assert!(outcome.failures.is_empty(), "{:?}", outcome.failures);
    assert_eq!(outcome.downloaded, n);
    assert!(
        scheduler::chars(&first) > 1000,
        "第 1 章换成了更完整的那份：{} 字",
        scheduler::chars(&first)
    );
    assert_eq!(alt_log.lock().unwrap().len(), 1, "替代源只核对了这一章");
}

#[test]
fn chapter_stuck_on_one_source_is_taken_by_an_idle_source_and_the_slow_request_ends() {
    let n = 60;
    // 主源第 1 章卡 20 秒；替代源很快。
    let (base, _) = serve(|req| {
        let i = index(&req.path);
        if i == 0 {
            std::thread::sleep(Duration::from_secs(20));
        }
        html(&format!("<div id='c'>{}</div>", full(i)))
    });
    let (alt, alt_log) =
        serve(|req| html(&format!("<div id='c'>{}</div>", full(index(&req.path)))));
    let (outcome, first, elapsed) = run("hedge", runtime(&base, 4), &base, &alt, n);
    assert!(outcome.failures.is_empty(), "{:?}", outcome.failures);
    assert_eq!(outcome.downloaded, n);
    assert_eq!(scheduler::chars(&first), scheduler::chars(&full(0)));
    assert_eq!(alt_log.lock().unwrap().len(), 1);
    // 慢请求被结束，不用等满 20 秒。
    assert!(elapsed < Duration::from_secs(8), "用了 {elapsed:?}");
}

#[test]
fn normal_chapters_are_not_rechecked_or_duplicated() {
    let n = 60;
    let (base, base_log) =
        serve(|req| html(&format!("<div id='c'>{}</div>", full(index(&req.path)))));
    let (alt, alt_log) =
        serve(|req| html(&format!("<div id='c'>{}</div>", full(index(&req.path)))));
    let (outcome, _, _) = run("plain", runtime(&base, 4), &base, &alt, n);
    assert!(outcome.failures.is_empty());
    assert_eq!(
        base_log.lock().unwrap().len() + alt_log.lock().unwrap().len(),
        n
    );
}
