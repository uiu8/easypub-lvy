//! 手动联网抽查（不在自动测试里跑）：随机取能执行的文字书源，走 搜索 → 详情 → 目录 → 第一章。
//! 只输出走到哪一步、出错原因与长度，不保存正文。
//! `EASYPUB_BOOKSOURCE_SAMPLE=文件 EASYPUB_LIVE_COUNT=30 cargo test --release -p easypub_booksource live_sample -- --ignored --nocapture`
use crate::{
    engine::{Engine, SourceRt},
    source, support,
};
use std::{sync::mpsc, time::Duration};

fn try_source(src: source::BookSource) -> (String, String) {
    let (name, result, _) = try_source_logged(src);
    (name, result)
}

fn try_source_logged(src: source::BookSource) -> (String, String, Vec<String>) {
    let name = src.book_source_name.clone();
    // EASYPUB_LIVE_KEYWORD：指定搜索词（排查某本书搜不到时用）。
    let keyword = if let Ok(k) = std::env::var("EASYPUB_LIVE_KEYWORD") {
        k
    } else {
        let k = source::BookSource::rule(&src.rule_search, "checkKeyWord");
        if k.is_empty() {
            "我的".to_owned()
        } else {
            k.to_owned()
        }
    };
    let engine = match Engine::new(SourceRt::new(src)) {
        Ok(e) => e,
        Err(e) => return (name, format!("引擎：{e}"), Vec::new()),
    };
    let result = engine.run(|s| -> Result<String, String> {
        let books = s.search(&keyword, 1).map_err(|e| format!("搜索：{e}"))?;
        let found = format!(
            "搜到 {} 本（{}）；",
            books.len(),
            books
                .iter()
                .take(3)
                .map(|b| format!("{}/{}", b.name, b.author))
                .collect::<Vec<_>>()
                .join("、")
        );
        let Some(first) = books.into_iter().next() else {
            return Err(format!("搜索：没有结果（{keyword}）"));
        };
        let mut book = first;
        s.book_info(&mut book).map_err(|e| format!("详情：{e}"))?;
        let toc = s.toc(&book).map_err(|e| format!("{found}目录：{e}"))?;
        let Some(chapter) = toc.iter().find(|c| !c.is_volume) else {
            return Err("目录：空".into());
        };
        let next = toc
            .get(chapter.index + 1)
            .map(|c| c.url.clone())
            .unwrap_or_default();
        let text = s
            .chapter_content(&book, chapter, &next)
            .map_err(|e| format!("正文：{e}"))?;
        if text.chars().count() < 50 {
            return Err(format!("正文：太短（{} 字）", text.chars().count()));
        }
        Ok(format!(
            "{found}成功：目录 {} 章，第一章 {} 字",
            toc.len(),
            text.chars().count()
        ))
    });
    let logs = engine.take_logs();
    let tail = logs
        .iter()
        .rev()
        .filter(|l| !l.starts_with("请求 "))
        .take(2)
        .cloned()
        .collect::<Vec<_>>()
        .join(" / ");
    let text = match result {
        Ok(ok) => ok,
        Err(e) if tail.is_empty() => e,
        Err(e) => format!(
            "{e}  [日志：{}]",
            tail.chars().take(160).collect::<String>()
        ),
    };
    (name, text, logs)
}

#[test]
#[ignore]
fn live_sample() {
    let path = std::env::var("EASYPUB_BOOKSOURCE_SAMPLE").expect("设置 EASYPUB_BOOKSOURCE_SAMPLE");
    let count: usize = std::env::var("EASYPUB_LIVE_COUNT")
        .ok()
        .and_then(|c| c.parse().ok())
        .unwrap_or(20);
    let seed: u64 = std::env::var("EASYPUB_LIVE_SEED")
        .ok()
        .and_then(|c| c.parse().ok())
        .unwrap_or(1);
    let (sources, _) = source::import(&std::fs::read_to_string(path).unwrap()).unwrap();
    let mut runnable: Vec<_> = sources.into_iter().filter(support::can_run).collect();
    // EASYPUB_LIVE_FILTER=webview：只跑用到 WebView 的书源。
    if std::env::var("EASYPUB_LIVE_FILTER").as_deref() == Ok("webview") {
        runnable.retain(support::needs_web_view);
    }
    // 指定书源名（逗号分隔）时只跑这些，并打印完整日志。
    if let Ok(names) = std::env::var("EASYPUB_LIVE_NAME") {
        let names: Vec<&str> = names.split(',').map(str::trim).collect();
        for src in runnable
            .into_iter()
            .filter(|s| names.contains(&s.book_source_name.trim()))
        {
            let name = src.book_source_name.clone();
            let (_, result, logs) = try_source_logged(src);
            println!("== {name}：{result}");
            for l in logs {
                println!("   {}", l.chars().take(300).collect::<String>());
            }
        }
        return;
    }
    // 固定种子的洗牌，便于前后对比同一批书源。
    let mut state = seed
        .wrapping_mul(6364136223846793005)
        .wrapping_add(1442695040888963407);
    for i in (1..runnable.len()).rev() {
        state = state
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        runnable.swap(i, (state >> 33) as usize % (i + 1));
    }
    runnable.truncate(count);
    let (tx, rx) = mpsc::channel();
    let pool = 8;
    let mut pending = runnable.into_iter();
    let mut running = 0;
    let mut results = Vec::new();
    loop {
        while running < pool {
            let Some(src) = pending.next() else { break };
            let tx = tx.clone();
            std::thread::spawn(move || {
                let (inner_tx, inner_rx) = mpsc::channel();
                let name = src.book_source_name.clone();
                std::thread::spawn(move || {
                    let _ = inner_tx.send(try_source(src));
                });
                let r = inner_rx
                    .recv_timeout(Duration::from_secs(120))
                    .unwrap_or((name, "超时（120 秒）".into()));
                let _ = tx.send(r);
            });
            running += 1;
        }
        if running == 0 {
            break;
        }
        results.push(rx.recv().unwrap());
        running -= 1;
    }
    let ok = results
        .iter()
        .filter(|(_, r)| r.starts_with("成功"))
        .count();
    println!("LIVE_SAMPLE ok={ok}/{}", results.len());
    results.sort();
    for (name, r) in results {
        println!("  {name}：{r}");
    }
}
