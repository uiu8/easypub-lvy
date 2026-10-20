//! V89 的跨层夹具：仅本机自拟内容，不启动第三方服务。
use crate::{
    control::{Context, Profile},
    download::{self, Options},
    engine::{Engine, SourceRt},
    scheduler::{self, Lane},
    source::{self, BookSource},
    tests::{html, serve},
    webbook::{Book, Chapter},
};
use serde_json::json;
use std::{
    sync::{
        Arc, Barrier, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

fn rt(base: &str) -> Arc<SourceRt> {
    SourceRt::new(
        serde_json::from_value(json!({"bookSourceUrl":base,"ruleContent":{"content":"#c@html"}}))
            .unwrap(),
    )
}
fn book(base: &str) -> Book {
    Book {
        name: "自拟协议样书".into(),
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
fn folder(label: &str) -> std::path::PathBuf {
    std::env::temp_dir().join(format!("ep-v89-{label}-{}", std::process::id()))
}
fn content(index: usize) -> String {
    format!(
        "自拟章节 {index}。\n{}",
        "窗外的风吹动了树叶，灯下的人认真整理着今天的记录。".repeat(18)
    )
}

#[test]
fn search_health_expires_and_legacy_failures_can_retry() {
    let mut health: source::Health = serde_json::from_value(json!({
        "failStreak": 10, "lastError": "没有结果"
    }))
    .unwrap();
    assert!(
        !health.cooling_down(1000),
        "旧版没有截止时间的失败不能永久禁搜"
    );
    health = source::Health::default();
    for at in [1000, 1001, 1002] {
        health.record(20, false, "连接失败", at);
    }
    assert!(health.cooling_down(1061));
    assert!(!health.cooling_down(1062));
    health.latency(30);
    assert_eq!(health.fail_streak, 3, "空结果和测速不能冒充正文校验通过");
    health.record(20, false, "连接失败", 1062);
    assert_eq!(health.retry_after, 1182);
    health.record(20, true, "", 1063);
    assert!(!health.cooling_down(1063));
    assert_eq!(health.fail_streak, 0);
}

#[test]
fn bundle_check_samples_body_and_distinguishes_missing_content() {
    use crate::control::ErrorKind;
    let normal = format!("他说，休息一下再走。\n{}", content(0));
    let page = normal.clone();
    let (base, requests) = serve(move |req| {
        html(&match req.path.as_str() {
            "/s" => "<li><a href='/b'>自拟小说</a></li>".into(),
            "/b" => "<a id='toc' href='/toc'>目录</a>".into(),
            "/toc" => {
                "<li><a href='/preface'>前言</a></li><li><a href='/normal'>第一章</a></li>".into()
            }
            "/preface" => "<div id='c'>写在前面。</div>".into(),
            "/c/0" => "<div id='c'>本章内容正在获取中，请稍候重试。</div>".into(),
            "/limited" => "<div id='c'>访问太频繁，请 30 秒后刷新。</div>".into(),
            _ => format!("<div id='c'>{page}</div>"),
        })
    });
    let mut source: BookSource = serde_json::from_value(json!({
        "bookSourceUrl":base,"bookSourceName":"校验夹具",
        "bookSourceComment":"示例文档 java.unknownExample 和 java.webView，不是脚本",
        "searchUrl":"/s", "ruleSearch":{"bookList":"li","name":"a@text","bookUrl":"a@href"},
        "ruleBookInfo":{"tocUrl":"#toc@href"},
        "ruleToc":{"chapterList":"li","chapterName":"a@text","chapterUrl":"a@href"},
        "ruleContent":{"content":"#c@html"}
    }))
    .unwrap();
    assert!(crate::support::check(&source).is_empty());
    assert!(!crate::support::needs_web_view(&source));
    let engine = Engine::new(SourceRt::new(source.clone())).unwrap();
    let mut report = crate::probe::Check::default();
    crate::probe::check(&engine, "我的", &mut report).unwrap();
    assert_eq!((report.chapters, report.sampled), (2, 2));
    assert_eq!(report.chars, scheduler::chars(&normal));
    source
        .rule_toc
        .insert("chapterUrl".into(), "@js:'/limited'".into());
    let engine = Engine::new(SourceRt::new(source)).unwrap();
    let mut report = crate::probe::Check::default();
    assert_eq!(
        crate::probe::check(&engine, "我的", &mut report).unwrap_err(),
        ErrorKind::Throttled.label()
    );
    assert_eq!((report.stage, report.sampled), ("content", 1));

    // 持续缺内容只使这一章失败；正常对话不变成限流，也不拖停同站其他章。
    let options = Options {
        folder: folder("bundle-classification"),
        retries: 3,
        ..Default::default()
    };
    let output = download::download(
        rt(&base),
        &book(&base),
        &toc(&base, 2),
        &options,
        Arc::new(AtomicBool::new(false)),
        Arc::new(|_| {}),
    )
    .unwrap();
    assert_eq!((output.downloaded, output.failures.len()), (1, 1));
    assert!(output.failures[0].reason.contains("章节内容暂缺"));
    assert_eq!(
        requests
            .lock()
            .unwrap()
            .iter()
            .filter(|r| r.ends_with("/c/0"))
            .count(),
        1
    );
    assert_eq!(crate::hosts::host(&base, 32).diagnostic().stub_count, 0);
    std::fs::remove_dir_all(options.folder).unwrap();
}

#[test]
fn v89_controller_ramp_recovery_cancel_and_loopback() {
    let host = crate::hosts::host("https://v89-controller.invalid", 8);
    for _ in 0..30 {
        host.success(8);
    }
    assert_eq!(host.snapshot(8).0, 8);
    host.limited(Some(Duration::from_millis(80)));
    assert_eq!(host.snapshot(8).0, 4);
    let cancel = Arc::new(AtomicBool::new(false));
    let mut ctx = Context::new(Profile::Content, cancel.clone());
    ctx.ceiling = Some(8);
    let permit = host.acquire(&ctx).unwrap();
    assert_eq!(host.snapshot(8).0, 6);
    drop(permit);
    for _ in 0..10 {
        host.success(8);
    }
    assert_eq!(host.diagnostic().interval, 400);
    host.limited(Some(Duration::from_secs(30)));
    let h = host.clone();
    let worker = std::thread::spawn(move || h.acquire(&ctx).is_err());
    std::thread::sleep(Duration::from_millis(40));
    let at = Instant::now();
    cancel.store(true, Ordering::Relaxed);
    crate::hosts::wake();
    assert!(worker.join().unwrap());
    assert!(at.elapsed() < Duration::from_secs(2));
    for url in [
        "http://127.0.0.1:8197",
        "http://[::1]:8197",
        "http://localhost:8197",
    ] {
        let local = crate::hosts::host(url, 32);
        local.limited(None);
        assert!(!local.cooling());
        assert_eq!(local.snapshot(32).0, 16);
    }
}

#[test]
fn v89_mainjs_batch_partial_fallback_and_format_import() {
    let (base, log) = serve(|req| {
        let body=match req.path.as_str() {
            "/search"=>json!([{"name":"自拟协议样书","author":"测试作者","bookUrl":"/book","tocUrl":"/toc"}]).to_string(),
            "/book"=>json!({"tocUrl":"/toc","intro":"自拟正文测试"}).to_string(),
            "/toc"=>json!((0..6).map(|i|json!({"title":format!("第{}章 测试{}",i+1,i+1),"url":format!("/c/{i}")})).collect::<Vec<_>>()).to_string(),
            "/chapters/batch"=>{
                assert_eq!(req.method,"POST");
                let input:serde_json::Value=serde_json::from_slice(&req.body).unwrap();
                let ids=input["chapterIds"].as_array().unwrap();
                json!({"data":ids.iter().take(ids.len().saturating_sub(1)).map(|v|json!({"url":v,"content":format!("广告{}",content(v.as_str().unwrap().rsplit('/').next().unwrap().parse().unwrap()))})).collect::<Vec<_>>()} ).to_string()
            },
            path if path.starts_with("/c/")=>json!({"content":format!("广告{}",content(path[3..].parse().unwrap()))}).to_string(),
            _=>String::new(),
        };
        html(&body)
    });
    let script=r#"
      var config={bookSourceUrl:"BASE",bookSourceName:"本地协议夹具",maxBatchSize:50,respondTime:180000};
      function search(key,page){return JSON.parse(java.ajax("BASE/search"));}
      function getBookInfo(book){return JSON.parse(java.ajax("BASE/book"));}
      function getChapters(book){return JSON.parse(java.ajax("BASE/toc"));}
      function getContent(chapter,book,nextChapterUrl){return JSON.parse(java.ajax(chapter.url)).content;}
      function getContentBatch(chapters,book){
        var result=JSON.parse(java.post("BASE/chapters/batch",JSON.stringify({bookId:"sample",chapterIds:chapters.map(c=>c.url)}),{}).body()).data;
        result.forEach(item=>java.cacheContent(item.url,item.content));
      }
      function login(){sourceApi.put("login","called");}
    "#.replace("BASE",&base);
    let (mut imported, skipped) = source::import(&script).unwrap();
    assert_eq!(skipped, 0);
    imported[0]
        .rule_content
        .insert("replaceRegex".into(), "##广告##".into());
    let rt = SourceRt::new(imported.remove(0));
    let start = Instant::now();
    for _ in 0..20 {
        Engine::new(rt.clone()).unwrap();
    }
    eprintln!(
        "V89 QuickJS new+prelude+mainJs mean_ms={:.3}",
        start.elapsed().as_secs_f64() * 1000. / 20.
    );
    let e = Engine::new(rt.clone()).unwrap();
    let (book, chapters) = e.run(|s| {
        let mut books = s.search("样书", 1).unwrap();
        let mut b = books.remove(0);
        s.book_info(&mut b).unwrap();
        let chapters = s.toc(&b).unwrap();
        s.main_call("login", json!([])).unwrap();
        (b, chapters)
    });
    assert_eq!(rt.vars.lock().unwrap().get("login").unwrap(), "called");
    let options = Options {
        folder: folder("batch"),
        threads: 1,
        ..Default::default()
    };
    let output = download::download(
        rt.clone(),
        &book,
        &chapters,
        &options,
        Arc::new(AtomicBool::new(false)),
        Arc::new(|_| {}),
    )
    .unwrap();
    assert!(output.failures.is_empty(), "{:?}", output.failures);
    let requests = log.lock().unwrap().clone();
    assert_eq!(
        requests
            .iter()
            .filter(|p| p.contains("/chapters/batch"))
            .count(),
        1
    );
    assert_eq!(
        requests.iter().filter(|p| p.contains("/c/")).count(),
        1,
        "仅漏项回退单章"
    );
    assert!(
        !std::fs::read_to_string(output.path)
            .unwrap()
            .contains("广告")
    );
    e.run(|s| {
        assert!(
            s.eval_js(
                "java.cacheContent('https://outside.invalid/steal','x')",
                &[]
            )
            .is_err()
        );
    });
    let converted=source::import(&json!({"url":base,"name":"转换样例","search":{"url":"/s?q=%s","result":"li","bookName":"a","author":"span"},"toc":{"item":"li a","nextPage":"a.next"},"chapter":{"content":"#c","filterTxt":"广告","filterTag":"script"},"crawl":{"concurrency":5,"minInterval":0.2,"maxInterval":0.4}}).to_string()).unwrap().0.remove(0);
    assert_eq!(converted.meta.crawl_suggestion.unwrap().min_interval, 200);
    assert!(
        converted.meta.crawl.concurrency.is_none(),
        "导入建议不能自动应用"
    );
    assert_eq!(converted.rule_content["content"], "#c@html");
    assert!(!converted.meta.import_warnings.is_empty());
    std::fs::remove_dir_all(options.folder).unwrap();
}

#[test]
fn v89_singleflight_and_duplicate_stub_never_become_good_cache() {
    let (base, log) = serve(|req| {
        std::thread::sleep(Duration::from_millis(80));
        html(&format!(
            "<div id='c'>{}</div>",
            if req.path == "/shared" {
                content(1)
            } else {
                content(9)
            }
        ))
    });
    let rt = rt(&base);
    let barrier = Arc::new(Barrier::new(3));
    std::thread::scope(|scope| {
        for _ in 0..3 {
            let rt = rt.clone();
            let barrier = barrier.clone();
            let base = &base;
            scope.spawn(move || {
                let e = Engine::new(rt).unwrap();
                barrier.wait();
                assert!(
                    e.run(|s| s.chapter_content(
                        &book(base),
                        &Chapter {
                            url: format!("{base}/shared"),
                            ..Default::default()
                        },
                        ""
                    ))
                    .is_ok()
                );
            });
        }
    });
    assert_eq!(
        log.lock()
            .unwrap()
            .iter()
            .filter(|p| p.ends_with("/shared"))
            .count(),
        1
    );
    let options = Options {
        folder: folder("duplicates"),
        threads: 3,
        retries: 0,
        ..Default::default()
    };
    let output = download::download(
        rt,
        &book(&base),
        &toc(&base, 3),
        &options,
        Arc::new(AtomicBool::new(false)),
        Arc::new(|_| {}),
    )
    .unwrap();
    assert_eq!(output.downloaded, 0);
    assert_eq!(output.failures.len(), 3);
    assert!(
        output
            .failures
            .iter()
            .all(|f| f.reason.contains("疑似限流"))
    );
    assert!(scheduler::is_stub(
        "访问太频繁，请 30 秒后刷新",
        0,
        &Chapter::default(),
        &[]
    ));
    std::fs::remove_dir_all(options.folder).unwrap();
}

#[test]
fn v89_multi_source_alignment_speed_provenance_and_bad_length_return() {
    let (primary, _) = serve(|req| {
        std::thread::sleep(Duration::from_millis(35));
        let i = req.path[3..].parse().unwrap();
        html(&format!("<div id='c'>{}</div>", content(i)))
    });
    let (alt, _) = serve(|req| {
        std::thread::sleep(Duration::from_millis(8));
        let i = req.path[3..].parse().unwrap();
        html(&format!(
            "<div id='c'>{}</div>",
            if i == 5 {
                content(i).repeat(5)
            } else {
                content(i)
            }
        ))
    });
    let (third, _) = serve(|req| {
        std::thread::sleep(Duration::from_millis(8));
        let i = req.path[3..].parse().unwrap();
        html(&format!(
            "<div id='c'>{}</div>",
            if i == 8 {
                "访问太频繁，请稍后再试".into()
            } else {
                content(i)
            }
        ))
    });
    let main_toc = toc(&primary, 60);
    let alt_toc = toc(&alt, 60);
    let third_toc = toc(&third, 60);
    // 来源标签/详情地址不同不等于独立正文站点。
    assert_eq!(
        scheduler::content_site(&book("https://source-alias.invalid"), &main_toc),
        scheduler::content_site(&book(&primary), &main_toc)
    );
    let mut bad = alt_toc.clone();
    for c in bad.iter_mut().take(20) {
        c.title = "另一部书".into();
    }
    assert!(scheduler::alignment(&main_toc, &bad).is_none());
    assert!(scheduler::alignment(&main_toc, &alt_toc[..55]).is_none());
    let rt = |base: &str| {
        let mut s: BookSource = serde_json::from_value(
            json!({"bookSourceUrl":base,"ruleContent":{"content":"#c@html"}}),
        )
        .unwrap();
        s.meta.crawl.concurrency = Some(1);
        SourceRt::new(s)
    };
    let opts = Options {
        folder: folder("single"),
        threads: 1,
        retries: 1,
        ..Default::default()
    };
    let at = Instant::now();
    let single = download::download(
        rt(&primary),
        &book(&primary),
        &main_toc,
        &opts,
        Arc::new(AtomicBool::new(false)),
        Arc::new(|_| {}),
    )
    .unwrap();
    let single_time = at.elapsed();
    assert!(single.failures.is_empty());
    let multi = Options {
        folder: folder("multi"),
        ..opts.clone()
    };
    let lanes = vec![
        Lane {
            rt: rt(&alt),
            book: book(&alt),
            mapping: scheduler::alignment(&main_toc, &alt_toc).unwrap(),
            toc: alt_toc,
        },
        Lane {
            rt: rt(&third),
            book: book(&third),
            mapping: scheduler::alignment(&main_toc, &third_toc).unwrap(),
            toc: third_toc,
        },
    ];
    let reports = Arc::new(Mutex::new(Vec::new()));
    let events = reports.clone();
    let at = Instant::now();
    let output = download::download_multi(
        rt(&primary),
        &book(&primary),
        &main_toc,
        &multi,
        Arc::new(AtomicBool::new(false)),
        Arc::new(move |p| events.lock().unwrap().push(p)),
        lanes,
    )
    .unwrap();
    assert!(output.failures.is_empty(), "{:?}", output.failures);
    assert!(at.elapsed() < single_time);
    let cache = download::cache_dir(&multi.folder, &book(&primary));
    let mut origins = std::collections::HashSet::new();
    for i in 0..60 {
        let v: serde_json::Value = serde_json::from_slice(
            &std::fs::read(cache.join(format!("{i:05}.meta.json"))).unwrap(),
        )
        .unwrap();
        origins.insert(v["source"].as_str().unwrap().to_owned());
        assert!(v["hash"].as_str().unwrap().len() == 64);
        assert_eq!(
            std::fs::read_to_string(cache.join(format!("{i:05}.txt"))).unwrap(),
            content(i)
        );
    }
    assert!(origins.len() >= 2);
    assert_eq!(
        std::fs::read_to_string(output.path)
            .unwrap()
            .matches("第6章 测试6")
            .count(),
        1
    );
    for folder in [opts.folder, multi.folder] {
        std::fs::remove_dir_all(folder).unwrap();
    }
}

#[test]
fn v89_http_proxy_credentials_redaction_and_reused_client() {
    let (proxy, log) = serve(|req| {
        assert!(req.path.starts_with("http://unresolvable.invalid"));
        html("代理夹具响应")
    });
    crate::network_config::set(crate::network_config::ProxyConfig {
        mode: "manual".into(),
        url: proxy.replacen("http://", "http://fixture:secret@", 1),
        ..Default::default()
    })
    .unwrap();
    let shown = crate::network_config::get().to_string();
    assert!(!shown.contains("secret") && !shown.contains("fixture:"));
    let mut net = crate::net::Net::new(None, Vec::new());
    net.crawl.use_proxy = true;
    for _ in 0..2 {
        assert_eq!(
            net.fetch(&crate::net::Request {
                url: "http://unresolvable.invalid/book".into(),
                method: "GET".into(),
                ..Default::default()
            })
            .unwrap()
            .text,
            "代理夹具响应"
        );
    }
    assert_eq!(log.lock().unwrap().len(), 2);
    // 自拟 SOCKS5h 网关，只服务本测试，不接触外网。
    use std::io::{Read, Write};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut hello = [0u8; 2];
        stream.read_exact(&mut hello).unwrap();
        assert_eq!(hello[0], 5);
        let mut methods = vec![0; hello[1] as usize];
        stream.read_exact(&mut methods).unwrap();
        stream.write_all(&[5, 0]).unwrap();
        let mut request = [0u8; 4];
        stream.read_exact(&mut request).unwrap();
        assert_eq!(request, [5, 1, 0, 3]);
        let mut len = [0];
        stream.read_exact(&mut len).unwrap();
        let mut target = vec![0; len[0] as usize + 2];
        stream.read_exact(&mut target).unwrap();
        stream
            .write_all(&[5, 0, 0, 1, 127, 0, 0, 1, 0, 80])
            .unwrap();
        let mut header = Vec::new();
        let mut byte = [0];
        while !header.ends_with(b"\r\n\r\n") {
            stream.read_exact(&mut byte).unwrap();
            header.push(byte[0]);
        }
        stream
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nSOCKS")
            .unwrap();
    });
    let response = net
        .fetch(&crate::net::Request {
            url: "http://unresolvable.invalid/socks".into(),
            method: "GET".into(),
            proxy: Some(format!("socks5h://{address}")),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(response.text, "SOCKS");
    server.join().unwrap();
    let cache = folder("credential-cache");
    let mut chapters = toc("http://fixture.invalid", 1);
    chapters[0].url = r#"http://fixture.invalid/c,{"proxy":"http://fake:proxy-secret@localhost:1","headers":{"Cookie":"cookie-secret"}}"#.into();
    download::prepare_cache(&cache, &chapters).unwrap();
    std::fs::write(cache.join("00000.txt"), content(0)).unwrap();
    scheduler::write_provenance(&cache, 0, "fixture", &chapters[0].url, &content(0)).unwrap();
    chapters[0].url = chapters[0].url.replace("proxy-secret", "changed-secret");
    download::prepare_cache(&cache, &chapters).unwrap();
    assert_eq!(
        std::fs::read_to_string(cache.join("00000.txt")).unwrap(),
        content(0)
    );
    for name in ["toc.json", "00000.meta.json"] {
        let stored = std::fs::read_to_string(cache.join(name)).unwrap();
        assert!(!stored.contains("secret"), "认证值不写目录与来源缓存");
    }
    std::fs::remove_dir_all(cache).unwrap();
    crate::network_config::set(crate::network_config::ProxyConfig {
        mode: "none".into(),
        url: String::new(),
        ..Default::default()
    })
    .unwrap();
}
