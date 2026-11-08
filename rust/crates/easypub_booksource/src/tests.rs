//! 引擎整体测试：本机夹具网站（127.0.0.1 随机端口），不访问外网。
use crate::{
    engine::{Engine, SourceRt},
    source,
};
use std::{
    io::{BufRead, BufReader, Read, Write},
    net::TcpListener,
    sync::{Arc, Mutex},
};

#[derive(Clone)]
pub(crate) struct Req {
    pub(crate) method: String,
    pub(crate) path: String,
    headers: Vec<(String, String)>,
    pub(crate) body: Vec<u8>,
}
impl Req {
    fn header(&self, name: &str) -> String {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.clone())
            .unwrap_or_default()
    }
}
pub(crate) struct Resp {
    status: u16,
    content_type: &'static str,
    body: Vec<u8>,
    extra: Vec<(String, String)>,
}
pub(crate) fn html(body: &str) -> Resp {
    Resp {
        status: 200,
        content_type: "text/html; charset=utf-8",
        body: body.as_bytes().to_vec(),
        extra: vec![],
    }
}

#[test]
fn okhttp_get_uses_source_network_and_consumes_raw_bytes_once() {
    let (base, log) = serve(|request| {
        assert_eq!(request.method, "GET");
        assert_eq!(request.header("x-fixture"), "first");
        Resp {
            status: 403,
            content_type: "application/octet-stream",
            body: vec![0, 255, 128, 65],
            extra: vec![],
        }
    });
    let engine = Engine::new(SourceRt::new(source::BookSource::default())).unwrap();
    engine.run(|s| {
        let url=serde_json::to_string(&format!("{base}/bytes")).unwrap();
        assert_eq!(s.eval_js_string(&format!(r#"
            var imports=new JavaImporter();imports.importPackage(Packages.okhttp3);
            with(imports){{
                var builder=new Request.Builder().url({url}).get().addHeader('X-Fixture','first');
                var request=builder.build();builder.url('https://unused.invalid/');
                var call=new OkHttpClient().newCall(request),response=call.execute();
                var code=response.code(),bytes=response.body().bytes(),failures=0;
                try{{call.execute();}}catch(e){{failures++;}}
                try{{response.body().bytes();}}catch(e){{failures++;}}
                try{{builder.addHeader('x-fixture','second');}}catch(e){{failures++;}}
                response.close();response.close();
                JSON.stringify([code,bytes,failures]);
            }}
        "#), &[]).unwrap(), "[403,[0,-1,-128,65],3]");
        assert!(s.eval_js("new okhttp3.OkHttpClient().newCall(new okhttp3.Request.Builder().url('file:///private').build()).execute()",&[]).is_err());
    });
    let requests = log.lock().unwrap();
    assert_eq!(requests.len(), 1);
}

#[test]
fn typed_responses_preserve_bytes_and_feed_hex_to_rules() {
    let (base, _) = serve(|_| Resp {
        status: 200,
        content_type: "application/octet-stream",
        body: vec![0, 0xff, 0x80, 65],
        extra: vec![],
    });
    let engine = Engine::new(SourceRt::new(source::BookSource {
        rule_content: serde_json::from_value(serde_json::json!({
            "content": "@js:java.hexDecodeToString(result)"
        }))
        .unwrap(),
        ..Default::default()
    }))
    .unwrap();
    engine.run(|s| {
        for url in [
            format!("{base}/bytes,{{\"type\":\"binary\",\"webView\":true}}"),
            "data:;charset=unknown;base64,AP+AQQ==,{\"type\":\"binary\",\"webView\":true}".into(),
        ] {
            let response = s.fetch(&url).unwrap();
            assert_eq!(response.text, "00ff8041");
            assert_eq!(response.body, [0, 0xff, 0x80, 65]);
        }
        for option in ["null", "\"\"", "\" \""] {
            let response = s
                .fetch(&format!("data:;base64,QQ==,{{\"type\":{option}}}"))
                .unwrap();
            assert_eq!(response.text, "A");
        }
        let chapter = crate::webbook::Chapter {
            url: format!(
                "data:;base64,{},{{\"type\":\"binary\"}}",
                crate::crypto::b64("合成章节正文".as_bytes())
            ),
            ..Default::default()
        };
        assert_eq!(
            s.chapter_content(&crate::webbook::Book::default(), &chapter, "")
                .unwrap(),
            "合成章节正文"
        );
    });
}

#[test]
fn font_http_uses_source_network_and_rejects_invalid_body() {
    let (base, log) = serve(|req| Resp {
        status: 200,
        content_type: "font/ttf",
        body: if req.path == "/font" {
            include_bytes!("../tests/fonts/correct.ttf").to_vec()
        } else {
            b"not a font".to_vec()
        },
        extra: vec![],
    });
    let engine = Engine::new(SourceRt::new(source::BookSource::default())).unwrap();
    engine.run(|s| {
        let url = serde_json::to_string(&format!("{base}/font")).unwrap();
        assert_eq!(
            s.eval_js_string(
                &format!("var f=java.queryTTF({url});java.replaceFont('甲乙𠀀丙',f,f)"),
                &[]
            )
            .unwrap(),
            "甲乙𠀀丙"
        );
        let url = serde_json::to_string(&format!("{base}/bad")).unwrap();
        assert!(s.eval_js(&format!("java.queryTTF({url})"), &[]).is_err());
    });
    assert_eq!(log.lock().unwrap().len(), 2);
}

#[test]
fn temporary_download_read_and_runtime_isolation() {
    let (base, log) = serve(|req| Resp {
        status: if req.path == "/missing" { 404 } else { 200 },
        content_type: "text/plain",
        body: "合成下载正文".as_bytes().to_vec(),
        extra: vec![],
    });
    let source = SourceRt::new(source::BookSource::default());
    let engine = Engine::new(source.clone()).unwrap();
    let token = engine.run(|s| {
        let url = serde_json::to_string(&format!("{base}/text")).unwrap();
        let token = s
            .eval_js_string(&format!("var tmp=java.downloadFile({url});tmp"), &[])
            .unwrap();
        assert_eq!(
            s.eval_js_string(
                &format!(
                    "java.readTxtFile({},'UTF-8')",
                    serde_json::to_string(&token).unwrap()
                ),
                &[]
            )
            .unwrap(),
            "合成下载正文"
        );
        for code in [
            "java.readTxtFile('../secret')",
            "java.downloadFile('file:///secret')",
            "java.downloadFile('https://example.invalid', 'extra')",
            "new java.nio.file.Path('secret')",
        ] {
            assert!(s.eval_js(code, &[]).is_err());
        }
        let missing = serde_json::to_string(&format!("{base}/missing")).unwrap();
        assert!(
            s.eval_js(&format!("java.downloadFile({missing})"), &[])
                .is_err()
        );
        token
    });
    let other = Engine::new(source).unwrap();
    other.run(|s| {
        assert!(
            s.eval_js(
                &format!(
                    "java.readTxtFile({})",
                    serde_json::to_string(&token).unwrap()
                ),
                &[]
            )
            .is_err()
        )
    });
    let context = crate::control::Context {
        pure_compute: true,
        ..Default::default()
    };
    let _guard = context.enter();
    engine.run(|s|{
        assert!(s.eval_js(&format!("java.readTxtFile({})",serde_json::to_string(&token).unwrap()),&[]).is_err());
        let url=serde_json::to_string(&format!("{base}/text")).unwrap();assert!(s.eval_js(&format!("java.downloadFile({url})"),&[]).is_err());
        assert_eq!(s.eval_js_string("var b=java.nio.ByteBuffer.allocate(3);b.array()[0]=-1;JSON.stringify([b.array(),b.capacity()])",&[]).unwrap(),"[[-1,0,0],3]");
        assert!(s.eval_js("java.nio.ByteBuffer.allocate(-1)",&[]).is_err());
        assert!(s.eval_js("java.nio.ByteBuffer.allocate(4).putInt(1)",&[]).is_err());
    });
    assert_eq!(log.lock().unwrap().len(), 2);
}

#[test]
fn http_counter_includes_redirects_and_failed_responses() {
    use crate::{
        control::{Context, Profile},
        net::{Net, Request},
    };
    use std::sync::atomic::AtomicBool;
    let (base, log) = serve(|req| Resp {
        status: if req.path == "/redirect" { 302 } else { 503 },
        content_type: "text/plain",
        body: b"fixture".to_vec(),
        extra: if req.path == "/redirect" {
            vec![("Location".into(), "/failed".into())]
        } else {
            vec![]
        },
    });
    let context = Context::new(Profile::Content, Arc::new(AtomicBool::new(false)));
    let timing = context.timing.clone();
    let _guard = context.enter();
    let net = Net::new(None, vec![]);
    let _ = net.fetch(&Request {
        url: format!("{base}/redirect"),
        ..Default::default()
    });
    assert_eq!(log.lock().unwrap().len(), 2);
    assert_eq!(timing.lock().unwrap().requests, 2);
}
fn gbk_html(body: &str) -> Resp {
    // 不在响应头声明编码，只在 meta 里写 gbk：检验 meta 识别。
    Resp {
        status: 200,
        content_type: "text/html",
        body: encoding_rs::GBK.encode(body).0.into_owned(),
        extra: vec![],
    }
}
fn json(body: &str) -> Resp {
    Resp {
        status: 200,
        content_type: "application/json",
        body: body.as_bytes().to_vec(),
        extra: vec![],
    }
}

/// 起一个只服务本测试的网站，返回地址与请求记录。
pub(crate) fn serve(
    handler: impl Fn(&Req) -> Resp + Send + Sync + 'static,
) -> (String, Arc<Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let log = Arc::new(Mutex::new(Vec::new()));
    let log2 = log.clone();
    let handler = Arc::new(handler);
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let handler = handler.clone();
            let log = log2.clone();
            std::thread::spawn(move || {
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut line = String::new();
                if reader.read_line(&mut line).is_err() || line.is_empty() {
                    return;
                }
                let mut parts = line.split_whitespace();
                let method = parts.next().unwrap_or("").to_owned();
                let path = parts.next().unwrap_or("").to_owned();
                let mut headers = Vec::new();
                loop {
                    let mut h = String::new();
                    reader.read_line(&mut h).unwrap();
                    let h = h.trim_end();
                    if h.is_empty() {
                        break;
                    }
                    if let Some((k, v)) = h.split_once(':') {
                        headers.push((k.trim().to_owned(), v.trim().to_owned()));
                    }
                }
                let len: usize = headers
                    .iter()
                    .find(|(k, _)| k.eq_ignore_ascii_case("content-length"))
                    .and_then(|(_, v)| v.parse().ok())
                    .unwrap_or(0);
                let mut body = vec![0; len];
                reader.read_exact(&mut body).unwrap();
                let req = Req {
                    method,
                    path,
                    headers,
                    body,
                };
                log.lock()
                    .unwrap()
                    .push(format!("{} {}", req.method, req.path));
                let resp = handler(&req);
                let mut out = stream;
                let mut head = format!(
                    "HTTP/1.1 {} X\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n",
                    resp.status,
                    resp.content_type,
                    resp.body.len()
                );
                for (k, v) in &resp.extra {
                    head.push_str(&format!("{k}: {v}\r\n"));
                }
                head.push_str("\r\n");
                let _ = out.write_all(head.as_bytes());
                let _ = out.write_all(&resp.body);
            });
        }
    });
    (base, log)
}

fn engine(source_json: &str) -> Engine {
    let (sources, skipped) = source::import(source_json).unwrap();
    assert_eq!(skipped, 0);
    Engine::new(SourceRt::new(sources.into_iter().next().unwrap())).unwrap()
}

#[test]
fn book_rule_variables_survive_rpc_engines_without_cross_book_leakage() {
    let (base, _) = serve(|req| match req.path.as_str() {
        "/search" => json(r#"[{"id":"one","name":"甲"},{"id":"two","name":"乙"}]"#),
        _ => json(r#"{"title":"详情","list":[{"title":"第一章"}]}"#),
    });
    let source = serde_json::json!({
        "bookSourceUrl":base,"searchUrl":"/search",
        "ruleSearch":{"bookList":"$[*]","name":"$.name@put:{id:$.id}","bookUrl":"/book/@get:{id}"},
        "ruleBookInfo":{"name":"$.title","tocUrl":"/book/@get:{id}/volumes"},
        "ruleToc":{"chapterList":"$.list","chapterName":"$.title@put:{chapterTitle:$.title}","chapterUrl":"/chapter/@get:{id}"},
        "ruleContent":{"content":"正文内容：@get:{chapterTitle}"}
    })
    .to_string();
    let books = engine(&source).run(|s| s.search("测试", 1).unwrap());
    assert_eq!(books.len(), 2);
    for (mut book, id) in books.into_iter().zip(["one", "two"]) {
        assert_eq!(book.book_url, format!("{base}/book/{id}"));
        // 每次 RPC 都会创建 Engine；书籍经 JSON 传递，不能依赖上一次运行时局部变量。
        let encoded = serde_json::to_value(book).unwrap();
        assert!(encoded["ruleVariables"].is_string());
        assert!(!encoded["ruleVariables"].as_str().unwrap().contains("one"));
        book = serde_json::from_value(encoded).unwrap();
        engine(&source).run(|s| s.book_info(&mut book).unwrap());
        assert_eq!(book.toc_url, format!("{base}/book/{id}/volumes"));
        let toc = engine(&source).run(|s| s.toc(&book).unwrap());
        let toc: Vec<crate::webbook::Chapter> =
            serde_json::from_value(serde_json::to_value(toc).unwrap()).unwrap();
        assert_eq!(toc[0].url, format!("{base}/chapter/{id}"));
        assert_eq!(
            engine(&source).run(|s| s.chapter_content(&book, &toc[0], "").unwrap()),
            "正文内容：第一章"
        );
    }
}

#[test]
fn content_variables_are_available_to_next_page_rule() {
    let (base, _) = serve(|req| {
        if req.path == "/first" {
            json(r#"{"body":"第一页正文。","next":"/second"}"#)
        } else {
            json(r#"{"body":"第二页补充。","next":""}"#)
        }
    });
    let e = engine(
        &serde_json::json!({"bookSourceUrl":base,
        "ruleContent":{"content":"$.body@put:{next:$.next}","nextContentUrl":"@get:{next}"}})
        .to_string(),
    );
    e.run(|s| {
        let book = crate::webbook::Book {
            book_url: format!("{base}/book"),
            ..Default::default()
        };
        let chapter = crate::webbook::Chapter {
            url: format!("{base}/first"),
            ..Default::default()
        };
        assert_eq!(
            s.chapter_content(&book, &chapter, "").unwrap(),
            "第一页正文。\n第二页补充。"
        );
    });
}

#[test]
fn content_pagination_ignores_non_http_navigation() {
    let (base, requests) = serve(|req| match req.path.as_str() {
        "/first" => json(
            r#"{"body":"第一页正文。","next":["javascript:void(0)","/second","mailto:test@example.invalid"]}"#,
        ),
        "/second" => json(r#"{"body":"第二页补充。","next":["data:text/plain,ignored","/first"]}"#),
        _ => panic!("不应请求额外页面"),
    });
    let e = engine(
        &serde_json::json!({"bookSourceUrl":base,
        "ruleContent":{"content":"$.body","nextContentUrl":"$.next[*]"}})
        .to_string(),
    );
    e.run(|s| {
        let book = crate::webbook::Book::default();
        let chapter = crate::webbook::Chapter {
            url: format!("{base}/first"),
            ..Default::default()
        };
        assert_eq!(
            s.chapter_content(&book, &chapter, "").unwrap(),
            "第一页正文。\n第二页补充。"
        );
        let invalid = crate::webbook::Chapter {
            url: "file:///private".into(),
            ..Default::default()
        };
        assert!(s.chapter_content(&book, &invalid, "").is_err());
    });
    assert_eq!(requests.lock().unwrap().len(), 2);
}

#[test]
fn check_keyword_fallback_respects_user_and_source_choices() {
    let (base, requests) = serve(|req| match req.path.as_str() {
        "/search?key=%E6%88%91%E7%9A%84" | "/search?key=absent" => json("[]"),
        p if p.starts_with("/search") => json(r#"[{"name":"合成书","url":"/book"}]"#),
        "/book" => json(r#"{"title":"合成书"}"#),
        "/toc" => json(r#"[{"title":"第一章","url":"/chapter"}]"#),
        _ => json(&serde_json::json!({"body":"正常正文内容。".repeat(80)}).to_string()),
    });
    let mut src = serde_json::json!({"bookSourceUrl":base,"searchUrl":"/search?key={{key}}",
        "ruleSearch":{"bookList":"$[*]","name":"$.name","bookUrl":"$.url"},
        "ruleBookInfo":{"name":"$.title","tocUrl":"{{'/toc'}}"},
        "ruleToc":{"chapterList":"$[*]","chapterName":"$.title","chapterUrl":"$.url"},
        "ruleContent":{"content":"$.body"}});
    let mut report = crate::probe::Check::default();
    crate::probe::check(&engine(&src.to_string()), "", &mut report).unwrap();
    assert_eq!(
        (report.search_attempts, report.keyword_origin),
        (2, "default")
    );
    for source_choice in [false, true] {
        if source_choice {
            src["ruleSearch"]["checkKeyWord"] = "absent".into();
        }
        let mut report = crate::probe::Check::default();
        let result = crate::probe::check(
            &engine(&src.to_string()),
            if source_choice { "" } else { "absent" },
            &mut report,
        );
        assert_eq!(result.unwrap_err(), "校验词没有搜索结果");
        assert_eq!(report.search_attempts, 1);
        assert_eq!(
            report.keyword_origin,
            if source_choice { "source" } else { "user" }
        );
    }
    assert_eq!(
        requests
            .lock()
            .unwrap()
            .iter()
            .filter(|r| r.starts_with("GET /search"))
            .count(),
        4
    );
    assert_eq!(
        crate::probe::reason("目录脚本出错：secret-cookie"),
        "目录脚本执行失败"
    );
}

#[test]
fn url_rule_context_and_json_chapter_templates() {
    let e = engine(r#"{"bookSourceUrl":"https://fixture.invalid"}"#);
    e.run(|s| {
        s.eval_js("java.put('id','7')", &[]).unwrap();
        assert_eq!(s.analyze_url("/book/@get:{id}/volumes").unwrap().request.url, "https://fixture.invalid/book/7/volumes");
        let rule = "@js:java.ruleUrl.indexOf('@js:')===0 ? '/correct' : '/wrong'";
        assert_eq!(s.analyze_url(rule).unwrap().request.url,"https://fixture.invalid/correct");
        assert_eq!(s.eval_js_string("java.ruleUrl",&[]).unwrap(), "");
        let item = crate::node::Node::Json(serde_json::json!({"chapter_id":7}));
        let url = s.get_string_on("@js:'/read,'+JSON.stringify({method:'POST',body:JSON.stringify({id:'{{$.chapter_id}}',book:@get:{id},sign:java.md5Encode('fixture')})})", &item);
        let request = s.analyze_url(&url).unwrap().request;
        assert_eq!(request.method,"POST");
        let body: serde_json::Value = serde_json::from_slice(&request.body.unwrap()).unwrap();
        assert_eq!(body["id"],"7");
        assert_eq!(body["book"],7);
    });
}

#[test]
fn ajax_test_all_keeps_order_and_response_timing() {
    let (base, _) = serve(|req| {
        if req.path == "/slow" {
            std::thread::sleep(std::time::Duration::from_millis(250));
        }
        Resp {
            status: if req.path == "/missing" { 404 } else { 200 },
            ..html(&req.path)
        }
    });
    engine(&serde_json::json!({"bookSourceUrl":base}).to_string()).run(|s| {
        let value = s.eval_js_string("JSON.stringify(java.ajaxTestAll(['/first','/missing'],1000).map(r=>[r.code(),r.body(),r.callTime()>=0]))",&[]).unwrap();
        assert_eq!(serde_json::from_str::<serde_json::Value>(&value).unwrap(),serde_json::json!([[200,"/first",true],[404,"/missing",true]]));
        assert_eq!(s.eval_js_string("java.ajaxTestAll(['/slow'],20)[0].callTime()",&[]).unwrap(),"-1");
        assert!(s.eval_js("java.ajaxTestAll(['/first'],1000,true)",&[]).is_err());
        assert!(s.eval_js("java.ajaxTestAll(['file:///secret'],1000)",&[]).is_err());
    });
}

#[test]
fn plain_rules_search_info_toc_and_paged_content() {
    let (base, log) = serve(|req| {
        let p = req.path.as_str();
        if p.starts_with("/s.php?") {
            // 搜索词按 GBK 编码：剑来 = BDA3 C0B4
            assert!(p.contains("q=%BD%A3%C0%B4"), "搜索词应按 GBK 编码：{p}");
            return gbk_html(
                r#"<html><head><meta charset="gbk"></head><body>
<div class="bookbox"><h4><a href="/book/1/">《剑来》</a></h4><span class="author">作者：烽火</span><img src="/c1.jpg"></div>
<div class="bookbox"><h4><a href="/book/2/">剑来外传</a></h4><span class="author">某人</span></div>
</body></html>"#,
            );
        }
        match p {
            "/book/1/" => html(
                r#"<html><head><meta property="og:novel:author" content="烽火戏诸侯">
<meta property="og:description" content="&lt;p&gt;简介一&lt;/p&gt;"></head><body><h1>剑来</h1>
<div class="small"><span>分类：仙侠</span><span>状态：连载</span></div><a id="toc" href="list.html">目录</a></body></html>"#,
            ),
            "/book/1/list.html" => html(
                r#"<ul class="listmain"><dd><a href="1.html">第一章 起</a></dd><dd><a href="2.html">第二章 承</a></dd></ul><a href="list_2.html">下一页</a>"#,
            ),
            "/book/1/list_2.html" => html(
                r#"<ul class="listmain"><dd><a href="3.html">第三章 转</a></dd></ul><a href="list.html">上一页</a>"#,
            ),
            "/book/1/1.html" => html(
                r#"<div id="content">　　第一页正文<br>　　请记住本站网址</div><a href="1_2.html">下一页</a>"#,
            ),
            "/book/1/1_2.html" => {
                html(r#"<div id="content"><p>第二页正文</p></div><a href="2.html">下一页</a>"#)
            }
            "/book/1/2.html" => html(r#"<div id="content">不应读到</div>"#),
            _ => Resp {
                status: 404,
                content_type: "text/plain",
                body: b"no".to_vec(),
                extra: vec![],
            },
        }
    });
    let source = format!(
        r###"{{"bookSourceUrl":"{base}#🎃","bookSourceName":"夹具甲","searchUrl":"/s.php?q={{{{key}}}},{{\"charset\":\"gbk\"}}",
        "ruleSearch":{{"bookList":"class.bookbox","name":"h4@a@text","author":"class.author@text","bookUrl":"h4@a@href","coverUrl":"img@src"}},
        "ruleBookInfo":{{"author":"[property$=author]@content","intro":"[property$=description]@content","kind":".small@span@text##分类：|状态：","tocUrl":"id.toc@href"}},
        "ruleToc":{{"chapterList":"class.listmain@dd","chapterName":"a@text","chapterUrl":"a@href","nextTocUrl":"text.下一页@href"}},
        "ruleContent":{{"content":"id.content@html","nextContentUrl":"text.下一页@href","replaceRegex":"##请记住本站.*"}}}}"###
    );
    let engine = engine(&source);
    engine.run(|s| {
        let books = s.search("剑来", 1).unwrap();
        assert_eq!(books.len(), 2);
        assert_eq!(books[0].name, "剑来");
        assert_eq!(books[0].author, "烽火");
        assert_eq!(books[0].book_url, format!("{base}/book/1/"));
        assert_eq!(books[0].cover_url, format!("{base}/c1.jpg"));
        let mut book = books[0].clone();
        s.book_info(&mut book).unwrap();
        assert_eq!(book.author, "烽火", "没有 canReName 时保留搜索结果的作者");
        assert_eq!(book.intro, "简介一");
        assert_eq!(book.kind, "仙侠,连载");
        assert_eq!(book.toc_url, format!("{base}/book/1/list.html"));
        let toc = s.toc(&book).unwrap();
        let titles: Vec<_> = toc.iter().map(|c| c.title.as_str()).collect();
        assert_eq!(
            titles,
            ["第一章 起", "第二章 承", "第三章 转"],
            "第二页的“上一页”不能让目录重复"
        );
        let text = s.chapter_content(&book, &toc[0], &toc[1].url).unwrap();
        assert_eq!(
            text, "第一页正文第二页正文",
            "翻页到下一章即停；净化后分页断句接续"
        );
    });
    assert!(
        !log.lock()
            .unwrap()
            .iter()
            .any(|l| l.ends_with("/book/1/2.html")),
        "不应请求下一章"
    );
}

#[test]
fn javascript_source_with_json_api_cookies_and_variables() {
    let (base, _log) = serve(|req| {
        let p = req.path.as_str();
        match (req.method.as_str(), p) {
            ("POST", "/api/search") => {
                let body: serde_json::Value = serde_json::from_slice(&req.body).unwrap();
                assert_eq!(body["kw"], "乙书");
                json(r#"{"data":[{"bid":7,"name":"乙书","author":"乙","tags":["玄幻","完结"]}]}"#)
            }
            ("GET", "/api/book/7") => Resp {
                extra: vec![("Set-Cookie".into(), "sid=abc123; Path=/".into())],
                ..json(r#"{"title":"乙书","intro":"乙的简介","count":2}"#)
            },
            ("GET", "/api/toc/7") => json(r#"{"list":[{"id":1,"t":"一"},{"id":2,"t":"二"}]}"#),
            ("GET", p) if p.starts_with("/api/c/7/") => {
                if !req.header("cookie").contains("sid=abc123") {
                    return Resp {
                        status: 403,
                        content_type: "text/plain",
                        body: b"no cookie".to_vec(),
                        extra: vec![],
                    };
                }
                let id = &p["/api/c/7/".len()..];
                // 正文 Base64：“第N章正文\n广告”
                let text = format!("<p>第{id}章正文</p><p>广告</p>");
                json(&format!(
                    r#"{{"content":"{}"}}"#,
                    crate::crypto::b64(text.as_bytes())
                ))
            }
            _ => Resp {
                status: 404,
                content_type: "text/plain",
                body: b"no".to_vec(),
                extra: vec![],
            },
        }
    });
    let source = serde_json::json!({
        "bookSourceUrl": base,
        "bookSourceName": "夹具乙",
        "searchUrl": "@js:'/api/search,' + JSON.stringify({method:'POST', body: JSON.stringify({kw: key})})",
        "ruleSearch": {"bookList": "$.data", "name": "$.name", "author": "$.author", "kind": "$.tags",
                       "bookUrl": "/api/book/{{$.bid}}@put:{bid:$.bid}"},
        "ruleBookInfo": {"name": "$.title", "intro": "$.intro", "wordCount": "{{$.count}}章",
                         "tocUrl": "@js:java.put('seen', 'yes'); baseUrl.replace('/book/', '/toc/')"},
        "ruleToc": {"chapterList": "$.list", "chapterName": "$.t",
                    "chapterUrl": "<js>'/api/c/' + java.get('bid') + '/' + java.getString('$.id')</js>"},
        "ruleContent": {"content": "$.content@js:java.base64Decode(result)", "replaceRegex": "##广告"}
    })
    .to_string();
    let engine = engine(&source);
    engine.run(|s| {
        let books = s.search("乙书", 1).unwrap();
        assert_eq!(books.len(), 1, "{:?}", s.inner.st.borrow().logs);
        assert_eq!(books[0].kind, "玄幻,完结");
        assert_eq!(books[0].book_url, format!("{base}/api/book/7"));
        let mut book = books[0].clone();
        s.book_info(&mut book).unwrap();
        assert_eq!(book.intro, "乙的简介");
        assert_eq!(book.word_count, "2章");
        assert_eq!(book.toc_url, format!("{base}/api/toc/7"));
        let toc = s.toc(&book).unwrap();
        assert_eq!(toc.len(), 2, "{:?}", s.inner.st.borrow().logs);
        assert_eq!(toc[1].url, format!("{base}/api/c/7/2"));
        let text = s.chapter_content(&book, &toc[1], "").unwrap();
        assert_eq!(
            text, "第2章正文",
            "Cookie 随请求带上；JS 解码；净化去掉广告"
        );
    });
}

#[test]
fn javascript_helpers_and_url_options() {
    let (base, _) = serve(|req| html(&format!("<p>{} {}</p>", req.method, req.path)));
    let source = serde_json::json!({"bookSourceUrl": base, "bookSourceName": "夹具丙",
        "header": "{\"X-From\":\"easypub\"}"})
    .to_string();
    let engine = engine(&source);
    engine.run(|s| {
        let js = |code: &str| s.eval_js_string(code, &[crate::node::Node::Text(String::new())]).unwrap();
        assert_eq!(js("java.md5Encode('abc')"), "900150983cd24fb0d6963f7d28e17f72");
        assert_eq!(js("java.md5Encode16('abc')"), "3cd24fb0d6963f7d");
        assert_eq!(js("java.base64Decode(java.base64Encode('中文'))"), "中文");
        assert_eq!(js("java.encodeURI('剑来', 'gbk')"), "%BD%A3%C0%B4");
        assert_eq!(js("java.t2s('劍來')"), "剑来");
        assert_eq!(js("java.timeFormatUTC(0, 'yyyy-MM-dd', 0)"), "1970-01-01");
        assert_eq!(js("var c = java.createSymmetricCrypto('AES/CBC/PKCS5Padding', '0123456789abcdef', 'fedcba9876543210'); c.decryptStr(c.encryptBase64('秘密'))"), "秘密");
        assert_eq!(js("let x = 1; x + 1"), "2");
        assert_eq!(js("let x = 5; x"), "5", "每段脚本的顶层 let 互不冲突");
        assert_eq!(js("[1,2].map(i => `第${i}`).join(',')"), "第1,第2");
        assert_eq!(js("String(java.ajax('/p?a=中'))").trim(), "<p>GET /p?a=%E4%B8%AD</p>");
        assert_eq!(js("java.post('/form', 'a=1', {}).body()").trim(), "<p>POST /form</p>");
        assert_eq!(js("java.lang.String(java.strToBytes('好','gbk'),'gbk')"), "好");
        let spec = s.analyze_url("/x?p={{page}}&k={{key}},{\"method\":\"POST\",\"body\":\"q={{key}}\",\"js\":\"java.headerMap.put('Y','1'); java.url = java.url + '&z=1'\"}").unwrap();
        assert_eq!(spec.request.method, "POST");
        assert!(spec.request.url.ends_with("/x?p=1&k=&z=1"), "{}", spec.request.url);
        assert!(spec.request.headers.iter().any(|(k, v)| k == "Y" && v == "1"));
        let spec = s.analyze_url("/list_<,_2,_3>.html").unwrap();
        assert!(spec.request.url.ends_with("/list_.html"));
        // 死循环会在期限后中断，不会卡住线程。
        let started = std::time::Instant::now();
        assert!(s.eval_js("while(true){}", &[]).is_err());
        assert!(started.elapsed() < std::time::Duration::from_secs(30));
    });
}

#[test]
fn jsoup_shim_in_javascript() {
    let (base, _) = serve(|_| {
        html(
            "<ul class='l'><li><a href='/a'>甲</a></li><li><a href='/b'>乙</a></li></ul><script>x</script>",
        )
    });
    let source = serde_json::json!({"bookSourceUrl": base, "bookSourceName": "夹具丁"}).to_string();
    let engine = engine(&source);
    engine.run(|s| {
        let js = |code: &str| s.eval_js_string(code, &[crate::node::Node::Text(String::new())]).unwrap();
        assert_eq!(js("var d = org.jsoup.Jsoup.parse(java.ajax('/')); d.select('ul.l li a').size()"), "2");
        assert_eq!(js("var d = org.jsoup.Jsoup.parse(java.ajax('/')); d.select('li a').eachText().join('|')"), "甲|乙");
        assert_eq!(js("var d = org.jsoup.Jsoup.parse(java.ajax('/')); d.select('a').get(1).attr('abs:href')"), format!("{base}/b"));
        assert_eq!(js("var d = Packages.org.jsoup.Jsoup.parse(java.ajax('/')); d.select('script').remove(); d.html().indexOf('<script') < 0"), "true");
        assert_eq!(js("var out=[]; for (var e of org.jsoup.Jsoup.parse('<p>一</p><p>二</p>').select('p')) out.push(e.text()); out.join()"), "一,二");
    });
}

#[test]
fn native_lists_and_jsoup_results_preserve_their_semantics() {
    let e = engine(r#"{"bookSourceUrl":"https://example.invalid"}"#);
    e.run(|s| {
        s.set_content(crate::node::Node::page("<a href='/a'>甲</a><a href='/b'>乙</a><a href='/c'>丙</a>"), None);
        let js = |code| s.eval_js_string(code, &[]).unwrap();
        assert_eq!(js("var list=java.getStringList('a@href');var view=list.subList(1,3);view.subList(0,1).clear();[list.size(),view.size(),view.get(0),list.contains('/b'),typeof [].size].join('|')"), "2|1|/c|false|undefined");
        assert_eq!(js("java.getElements('.missing').size()"), "0");
        assert_eq!(js("var d=org.jsoup.Jsoup.parse('<p>甲</p><p>乙</p>');var es=d.select('p');es.subList(0,1).clear();[es.size(),d.select('p').size(),es.eachText().get(0)].join('|')"), "1|2|乙", "清空列表视图不移除 DOM 节点");
        for rule in ["@js:org.jsoup.Jsoup.parse(src).select('a')", "@js:org.jsoup.Jsoup.parse(src).select('a').subList(0,2)"] {
            let nodes = s.get_elements(rule);
            assert!(matches!(nodes[0], crate::node::Node::Elem(..)));
            assert_eq!(s.get_string_on("href", &nodes[0]), "/a");
            assert_eq!(s.get_string_on("text", &nodes[1]), "乙");
        }
        assert_eq!(js("var x=java.getStringList('.missing@href');try{x.get(0)}catch(e){e instanceof RangeError}"), "true");
    });
}

#[test]
fn toc_direction_survives_rpc_and_bad_volume_link_does_not_abort_mixed_toc() {
    let (base, _) = serve(|req| {
        if req.path == "/broken" {
            html("<li>卷名</li>")
        } else {
            html("<li>卷名</li><a href='/b'>第二章</a><a href='/a'>第一章</a>")
        }
    });
    let source=serde_json::json!({"bookSourceUrl":base,
        "ruleBookInfo":{"name":"@js:book.setReverseToc(true); book.getReverseToc() ? '合成书' : ''"},
        "ruleToc":{"chapterList":"@js:org.jsoup.Jsoup.parse(src).select('li,a')","chapterName":"text","chapterUrl":"href@js:result.match(/^\\/.+/)[0]"}}).to_string();
    let mut book = crate::webbook::Book {
        book_url: format!("{base}/book"),
        ..Default::default()
    };
    engine(&source).run(|s| s.book_info(&mut book).unwrap());
    let book: crate::webbook::Book =
        serde_json::from_value(serde_json::to_value(book).unwrap()).unwrap();
    assert!(book.reverse_toc);
    let toc = engine(&source).run(|s| s.toc(&book).unwrap());
    assert_eq!(
        toc.iter()
            .filter(|c| !c.is_volume)
            .map(|c| c.title.as_str())
            .collect::<Vec<_>>(),
        ["第一章", "第二章"]
    );
    assert!(toc.last().unwrap().is_volume);
    let broken = crate::webbook::Book {
        toc_url: format!("{base}/broken"),
        ..book
    };
    assert!(
        engine(&source)
            .run(|s| s.toc(&broken))
            .unwrap_err()
            .contains("目录脚本出错")
    );
}

#[test]
fn nested_rule_javascript_restores_outer_globals_even_on_error() {
    let e = engine(r#"{"bookSourceUrl":"https://example.invalid"}"#);
    e.run(|s| {
        for nested in ["'inner'", "throw new TypeError('synthetic')"] {
            let rule = serde_json::to_string(&format!("@js:{nested}")).unwrap();
            let code = format!("src=org.jsoup.Jsoup.parse('<p>外层页面</p>'); var before=result; java.getString({rule}); [src.select('p').text(), result===before].join('|')");
            assert_eq!(s.eval_js_string(&code, &[crate::node::Node::Text("外层结果".into())]).unwrap(), "外层页面|true");
        }
    });
}

#[test]
fn javascript_is_not_strict_like_rhino() {
    let (base, _) = serve(|_| html("ok"));
    let source = serde_json::json!({"bookSourceUrl": base, "bookSourceName": "夹具戊"}).to_string();
    let engine = engine(&source);
    engine.run(|s| {
        let out = s
            .eval_js_string(
                "function f(){ undeclared = {a: 1}; return JSON.stringify(undeclared); } f()",
                &[],
            )
            .unwrap();
        assert_eq!(out, r#"{"a":1}"#, "给未声明变量赋值不报错");
    });
}

/// WebView2：页面脚本延迟写入的正文、网址选项 webView、页面里设置的 Cookie 回到书源 Cookie 罐。
#[cfg(windows)]
#[test]
fn webview_sources() {
    let dir = std::env::temp_dir().join(format!("easypub-webview-test-{}", std::process::id()));
    // SAFETY: 测试进程里只在这里设置，WebView 线程启动前读取。
    unsafe { std::env::set_var("EASYPUB_WEBVIEW_DATA", &dir) };
    let (base, log) = serve(|req| {
        match req.path.as_str() {
        "/s" => html(
            r#"<html><body><div id="list"></div><script>
            setTimeout(function(){ document.getElementById('list').innerHTML = '<p class="b"><a href="/book/1">动态书</a></p>'; }, 300);
            document.cookie = 'wv=ok; path=/';
            </script></body></html>"#,
        ),
        "/c/1" => html(
            r#"<html><body><div id="c"></div><script>
            setTimeout(function(){ document.getElementById('c').textContent = '这是页面脚本延迟写入的正文，需要等待以后才能取到。'; }, 600);
            </script></body></html>"#,
        ),
        "/shell" => html(r#"<body><noscript>Please enable JavaScript</noscript><div id="app"></div><script>setTimeout(()=>document.getElementById('app').textContent='动态空壳已加载',300)</script></body>"#),
        "/capture" => html("<body>resource fixture<script>setTimeout(()=>fetch('/resource/one.txt'),200)</script></body>"),
        "/challenge" => Resp { status:403, content_type:"text/html", body:b"<body>cf-chl<script>document.body.innerHTML='<p>verified fixture</p>'</script></body>".to_vec(), extra:vec![] },
        "/blocked" => Resp { status:403, content_type:"text/html", body:b"<body>cf-chl</body>".to_vec(), extra:vec![] },
        "/check" => html(&format!("<p>{}</p>", req.header("cookie"))),
        "/p" => html(&format!(
            "<p id=\"r\">{} {}</p>",
            req.method,
            String::from_utf8_lossy(&req.body)
        )),
        _ => html("<p>no</p>"),
    }
    });
    let source = serde_json::json!({
        "bookSourceUrl": base, "bookSourceName": "夹具己",
        "searchUrl": "/s,{\"webView\": true, \"webJs\": \"document.querySelector('.b') ? document.documentElement.outerHTML : ''\"}",
        "ruleSearch": {"bookList": ".b", "name": "a@text", "bookUrl": "a@href"},
        "ruleContent": {"content": "id.c@text", "webJs": "document.getElementById('c').textContent ? document.documentElement.outerHTML : ''"}
    })
    .to_string();
    let engine = engine(&source);
    engine.run(|s| {
        let books = s
            .search("x", 1)
            .unwrap_or_else(|e| panic!("{e} {:?}", s.inner.st.borrow().logs));
        assert_eq!(books.len(), 1, "webJs 等到异步列表出现");
        assert_eq!(books[0].name, "动态书");
        let chapter = crate::webbook::Chapter {
            title: "一".into(),
            url: format!("{base}/c/1"),
            ..Default::default()
        };
        let text = s.chapter_content(&books[0], &chapter, "").unwrap();
        assert!(text.contains("延迟写入的正文"), "{text}");
        let check = s.eval_js_string("java.ajax('/check')", &[]).unwrap();
        assert!(
            check.contains("wv=ok"),
            "WebView 里设置的 Cookie 随后续普通请求带上：{check}"
        );
        let spec = s
            .analyze_url("/p,{\"method\":\"POST\",\"body\":\"k=v\",\"webView\":true}")
            .unwrap();
        let page = s.fetch_spec(&spec).unwrap();
        assert!(
            page.text.contains("POST k=v"),
            "WebView 里用 POST 打开：{}",
            page.text
        );
        let _background = crate::control::Context::default().enter();
        let shell = s.fetch("/shell").unwrap();
        assert!(shell.text.contains(">动态空壳已加载<"));
        assert_eq!(s.fetch("/challenge").unwrap_err(), "需要网页验证");
        {
            let context = crate::control::Context { interactive:true, ..Default::default() };
            let _guard = context.enter();
            let page = s.fetch("/challenge").unwrap();
            assert!(page.text.contains("verified fixture"));
        }
        let rendered = s.fetch(r#"/s,{"webJs":"document.querySelector('.b') ? document.documentElement.outerHTML : ''"}"#).unwrap();
        assert!(rendered.text.contains("动态书"));
        let captured = s.eval_js_string("java.webViewGetSource(null, '/capture', null, '/resource/one[.]txt')", &[]).unwrap();
        assert_eq!(captured, format!("{base}/resource/one.txt"));
        let captured = s.fetch(r#"/capture,{"webView":true,"sourceRegex":"/resource/two[.]txt","webJs":"fetch('/resource/two.txt'); ''"}"#).unwrap();
        assert_eq!(captured.text, format!("{base}/resource/two.txt"));
        assert!(s.eval_js_string("java.webViewGetSource(null, '/capture', null, '[')", &[]).is_err());
        assert!(s.fetch(r#"/blocked,{"webView":true}"#).unwrap_err().contains("需要网页验证"));
        {
            let context = crate::control::Context { deadline:Some(std::time::Instant::now()+std::time::Duration::from_secs(2)), ..Default::default() };
            let _guard = context.enter();
            assert!(s.eval_js_string("java.webViewGetSource(null, '/capture', null, '/never-matches')", &[]).is_err());
        }
        assert_eq!(s.fetch("/check").unwrap().status, 200, "资源任务取消后普通请求仍可用");
        #[cfg(windows)]
        for cancel_window in [false, true] {
            use windows::{core::HSTRING, Win32::Foundation::{LPARAM, WPARAM}, Win32::UI::WindowsAndMessaging::{FindWindowW, GetWindowThreadProcessId, PostMessageW, WM_CLOSE}};
            use std::{sync::atomic::{AtomicBool, Ordering}, time::{Duration, Instant}};
            let cancel = Arc::new(AtomicBool::new(false));
            let token = cancel.clone();
            let title = format!("EasyPub V103 fixture {} {cancel_window}", std::process::id());
            let window_title = title.clone();
            let closer = std::thread::spawn(move || {
                let until = Instant::now() + Duration::from_secs(8);
                while Instant::now() < until {
                    unsafe {
                        if let Ok(hwnd) = FindWindowW(None, &HSTRING::from(&window_title)) {
                            let mut pid = 0;
                            GetWindowThreadProcessId(hwnd, Some(&mut pid));
                            if pid == std::process::id() {
                                let at = Instant::now();
                                if cancel_window { token.store(true, Ordering::Relaxed); }
                                else { PostMessageW(Some(hwnd), WM_CLOSE, WPARAM(0), LPARAM(0)).unwrap(); }
                                return Some(at);
                            }
                        }
                    }
                    std::thread::sleep(Duration::from_millis(10));
                }
                None
            });
            let _guard = crate::control::Context {interactive:true, cancel, deadline:Some(Instant::now()+Duration::from_secs(10)), ..Default::default()}.enter();
            let result = crate::webview::execute_with(s, &format!("{base}/blocked"), None, None, None, crate::webview::Interactive::OnChallenge, title);
            let error = result.err().expect("验证窗口必须以关闭或取消结束");
            let closed_at = closer.join().unwrap().expect("必须显示本测试进程的验证窗口");
            assert!(closed_at.elapsed() < Duration::from_secs(2), "关闭或取消后必须及时结束");
            if cancel_window { assert_eq!(error, "已取消"); }
            else { assert_eq!(error, "验证窗口已关闭，没有完成验证"); }
        }
        // 书源脚本不能让 WebView 打开本机文件再读回内容。
        let secret = dir.join("local-secret.txt");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(&secret, "EP-LOCAL-SECRET").unwrap();
        let file_url = reqwest::Url::from_file_path(&secret).unwrap().to_string();
        let read = s.eval_js_string(
            &format!("java.webView(null, '{file_url}', 'document.body.innerText')"),
            &[],
        );
        assert!(read.is_err(), "书源脚本读不到本机文件：{read:?}");
        let direct = crate::webview::run(
            s,
            None,
            Some(file_url.clone()),
            Some("document.body.innerText".into()),
        );
        assert_eq!(direct, Err(crate::webview::NOT_WEB.to_string()));
        let inline = s
            .eval_js_string(
                "java.webView('<p id=\"x\">内嵌页面</p>', '/h', \"document.getElementById('x').textContent\")",
                &[],
            )
            .unwrap();
        assert_eq!(inline, "内嵌页面", "载入 HTML 字符串不受跳转拦截影响");
    });
    assert!(log.lock().unwrap().iter().any(|l| l == "GET /s"));
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn download_with_retry_failure_and_resume() {
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    static HITS: AtomicUsize = AtomicUsize::new(0);
    let (base, log) = serve(|req| match req.path.as_str() {
        "/toc" => html(
            r#"<ul><li><a href="/c/1">第一章</a></li><li><a href="/c/2">第二章</a></li><li>卷二</li><li><a href="/c/3">第三章</a></li><li><a href="/c/4">第四章</a></li></ul>"#,
        ),
        "/c/2" if HITS.fetch_add(1, Ordering::SeqCst) == 0 => Resp {
            status: 500,
            content_type: "text/plain",
            body: vec![],
            extra: vec![],
        },
        "/c/3" => Resp {
            status: 500,
            content_type: "text/plain",
            body: vec![],
            extra: vec![],
        },
        p => html(&format!(
            "<div id='c'><p>第{}章</p><p>正文{}</p><p>{}</p></div>",
            &p[3..],
            &p[3..],
            "这是一段自拟的测试正文，用来验证章节下载、缓存续传和顺序合成。".repeat(12)
        )),
    });
    let source = serde_json::json!({"bookSourceUrl": base, "bookSourceName": "夹具辛",
        "ruleToc": {"chapterList": "li", "chapterName": "text", "chapterUrl": "a@href"},
        "ruleContent": {"content": "id.c@html"}})
    .to_string();
    let (sources, _) = source::import(&source).unwrap();
    let rt = SourceRt::new(sources.into_iter().next().unwrap());
    let engine = Engine::new(rt.clone()).unwrap();
    let book = crate::webbook::Book {
        name: "测试书".into(),
        author: "甲".into(),
        book_url: format!("{base}/b"),
        toc_url: format!("{base}/toc"),
        origin: base.clone(),
        ..Default::default()
    };
    let toc = engine.run(|s| s.toc(&book)).unwrap();
    assert_eq!(toc.len(), 5);
    assert!(toc[2].is_volume);
    let folder = std::env::temp_dir().join(format!("easypub-dl-{}", std::process::id()));
    let options = crate::download::Options {
        folder: folder.clone(),
        threads: 3,
        retries: 1,
        ..Default::default()
    };
    let progress = Arc::new(Mutex::new(Vec::new()));
    let p2 = progress.clone();
    let outcome = crate::download::download(
        rt.clone(),
        &book,
        &toc,
        &options,
        Arc::new(AtomicBool::new(false)),
        Arc::new(move |p| p2.lock().unwrap().push(p.done)),
    )
    .unwrap();
    assert_eq!(outcome.chapters, 4);
    assert_eq!(outcome.downloaded, 3, "第二章重试后取到");
    assert_eq!(outcome.failures.len(), 1);
    assert_eq!(outcome.failures[0].title, "第三章");
    let text = std::fs::read_to_string(&outcome.path).unwrap();
    assert!(outcome.path.ends_with("测试书 - 甲.txt"));
    assert!(
        text.contains("\n\n第一章\n\n　　正文1\n"),
        "正文开头重复的标题去掉、段首缩进：{text}"
    );
    assert!(text.contains("\n\n卷二\n"));
    assert!(text.contains("第三章\n\n（本章未下载）"));
    // 续传：已取到的章节不再请求。
    let before = log.lock().unwrap().len();
    let outcome = crate::download::download(
        rt,
        &book,
        &toc,
        &options,
        Arc::new(AtomicBool::new(false)),
        Arc::new(|_| {}),
    )
    .unwrap();
    assert_eq!(outcome.from_cache, 3);
    let after: Vec<String> = log.lock().unwrap()[before..].to_vec();
    assert!(
        after.iter().all(|l| l.contains("/c/3")),
        "只重试失败的章节：{after:?}"
    );
    assert!(!progress.lock().unwrap().is_empty());
    let _ = std::fs::remove_dir_all(folder);
}

#[test]
fn webview_opens_only_web_pages() {
    use crate::webview::web_url;
    assert!(web_url("https://example.invalid/a"));
    assert!(web_url("http://127.0.0.1:9999/book-source/x.json"));
    for url in [
        "file:///C:/Windows/win.ini",
        "file://server/share/a.txt",
        "javascript:alert(1)",
        "about:blank",
        "data:text/html,x",
        "ms-settings:privacy",
        "/relative",
        "",
    ] {
        assert!(!web_url(url), "{url}");
    }
}

#[test]
fn challenge_pages_are_recognised_without_false_alarms() {
    use crate::{net::Response, webview::is_challenge_response};
    let page = |status: u16, text: &str| Response {
        status,
        text: text.into(),
        ..Default::default()
    };
    assert!(is_challenge_response(&page(
        503,
        "<title>Just a moment...</title>"
    )));
    assert!(is_challenge_response(&page(403, "<p>请完成人机验证</p>")));
    assert!(is_challenge_response(&page(
        200,
        "<div id=\"cf-chl-widget\"></div>"
    )));
    assert!(
        !is_challenge_response(&page(200, "<form>用户名 密码 验证码</form>")),
        "普通登录页里的“验证码”不算"
    );
    assert!(!is_challenge_response(&page(404, "not found")));
}

#[test]
fn v88_pagination_toc_and_content_preserve_order_without_duplicate_headings() {
    let (base, _) = serve(|req| match req.path.as_str() {
        "/toc" => {
            let mut out = String::new();
            for i in (21..=30).chain(1..=30) {
                out.push_str(&format!("<li><a href='/c/{i}'>第{i}章 故事</a></li>"));
            }
            out.push_str("<li><a href='/p1'>第31章 帮助（1/3）</a></li><li><a href='/p2'>第31章 帮助（2/3）</a></li><li><a href='/p3'>第31章 帮助（3/3）</a></li><li><a href='/other'>第3章 故事</a></li>");
            html(&out)
        }
        "/p1" => html(
            "<div id='c'>第31章 帮助（1/3）<br>在路上，他四下<br>本章未完，点击下一页继续阅读</div>",
        ),
        "/p2" => {
            html("<div id='c'>第三十一章 帮助 第2页<br>看了看，有些神秘地说。<br>大家都</div>")
        }
        "/p3" => html("<div id='c'>第31章 帮助-3<br>点头同意。</div>"),
        _ => html("<div id='c'>正文。</div>"),
    });
    let e = engine(&serde_json::json!({"bookSourceUrl":base,"ruleToc":{"chapterList":"li","chapterName":"a@text","chapterUrl":"a@href"},"ruleContent":{"content":"#c@html@js:nextChapterUrl.endsWith('/other') ? result : '分页上下文缺失'"}}).to_string());
    let book = crate::webbook::Book {
        toc_url: format!("{base}/toc"),
        ..Default::default()
    };
    e.run(|s| {
        let toc = s.toc(&book).unwrap();
        assert_eq!(toc.len(), 32);
        assert_eq!(toc[0].title, "第1章 故事");
        assert_eq!(toc[0].dropped_latest_block, 10);
        assert_eq!(toc[30].extra_urls.len(), 2);
        assert_eq!(toc[30].title, "第31章 帮助");
        assert_eq!(toc[31].title, "第3章 故事", "不相邻同名章节保留");
        assert_eq!(
            s.chapter_content(&book, &toc[30], &toc[31].url).unwrap(),
            "在路上，他四下看了看，有些神秘地说。\n大家都点头同意。"
        );
        let q = crate::chapter_cleanup::toc_quality(&toc);
        assert_eq!(
            (
                q.duplicate_headings,
                q.merged_toc_items,
                q.dropped_latest_block
            ),
            (1, 2, 10)
        );
    });
    let (body, _) = crate::chapter_cleanup::clean_cached("1\n人物说：第1章 起点\n1", "1", true);
    assert_eq!(
        body, "1\n人物说：第1章 起点\n1",
        "纯数字标题和正文里的标题引用不能删"
    );
    assert_eq!(
        crate::chapter_cleanup::clean_page("请收藏本站\n正文。", "第1章", false),
        "请收藏本站\n正文。"
    );
}

#[test]
fn v88_download_retries_transient_errors_but_not_404_and_cancels_pending_http() {
    use crate::{
        download,
        webbook::{Book, Chapter},
    };
    use std::{
        sync::atomic::{AtomicBool, AtomicUsize, Ordering},
        time::{Duration, Instant},
    };
    let tries = Arc::new(AtomicUsize::new(0));
    let hit = tries.clone();
    let slow = Arc::new(AtomicBool::new(false));
    let waiting = slow.clone();
    let (base, log) = serve(move |req| match req.path.as_str() {
        "/retry" if hit.fetch_add(1, Ordering::Relaxed) == 0 => Resp {
            status: 429,
            content_type: "text/html",
            body: b"rate limited".to_vec(),
            extra: vec![("Retry-After".into(), "1".into())],
        },
        "/missing" => Resp {
            status: 404,
            content_type: "text/html",
            body: b"missing".to_vec(),
            extra: vec![],
        },
        "/slow" => {
            waiting.store(true, Ordering::Relaxed);
            std::thread::sleep(Duration::from_secs(5));
            html("<div id='c'>正文。</div>")
        }
        _ => html(&format!(
            "<div id='c'>正常正文。{}</div>",
            "测试文章内容应当足够长，避免被短正文检测认作桩页。".repeat(12)
        )),
    });
    let source: crate::source::BookSource = serde_json::from_value(
        serde_json::json!({"bookSourceUrl":base,"ruleContent":{"content":"#c@html"}}),
    )
    .unwrap();
    let rt = SourceRt::new(source);
    let folder = std::env::temp_dir().join(format!("ep-v88-retry-{}", std::process::id()));
    let book = Book {
        name: "限流测试".into(),
        origin: base.clone(),
        book_url: format!("{base}/b"),
        ..Default::default()
    };
    let toc: Vec<_> = ["ok", "retry", "missing"]
        .iter()
        .enumerate()
        .map(|(i, p)| Chapter {
            index: i,
            title: format!("第{}章", i + 1),
            url: format!("{base}/{p}"),
            ..Default::default()
        })
        .collect();
    let options = download::Options {
        folder: folder.clone(),
        threads: 16,
        retries: 2,
        ..Default::default()
    };
    let progress = Arc::new(Mutex::new(Vec::new()));
    let reports = progress.clone();
    let result = download::download(
        rt.clone(),
        &book,
        &toc,
        &options,
        Arc::new(AtomicBool::new(false)),
        Arc::new(move |p| reports.lock().unwrap().push(p)),
    )
    .unwrap();
    assert_eq!(result.downloaded, 2);
    assert_eq!(result.failures.len(), 1);
    assert_eq!(
        log.lock()
            .unwrap()
            .iter()
            .filter(|s| s.ends_with("/missing"))
            .count(),
        1
    );
    assert!(
        progress
            .lock()
            .unwrap()
            .iter()
            .any(|p| p.hosts.iter().any(|h| h.http_limited > 0))
    );
    let cancel = Arc::new(AtomicBool::new(false));
    let flag = cancel.clone();
    let worker = std::thread::spawn(move || {
        let _guard = crate::control::Context::new(crate::control::Profile::Content, flag).enter();
        let e = Engine::new(rt).unwrap();
        e.run(|s| {
            s.chapter_content(
                &book,
                &Chapter {
                    url: format!("{base}/slow"),
                    ..Default::default()
                },
                "",
            )
        })
    });
    let start = Instant::now();
    while !slow.load(Ordering::Relaxed) && start.elapsed() < Duration::from_secs(2) {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(slow.load(Ordering::Relaxed));
    let at = Instant::now();
    cancel.store(true, Ordering::Relaxed);
    assert!(worker.join().unwrap().is_err());
    assert!(at.elapsed() < Duration::from_secs(2));
    std::fs::remove_dir_all(folder).unwrap();
}

/// 规则脚本出错时不再静默返回 0 章：目录、搜索返回脱敏后的原因（合成书源与本机夹具）。
#[test]
fn script_errors_surface_without_leaking_secrets() {
    use crate::engine::safe_script_message;
    let secrets = vec!["sid-fake-0042".to_owned()];
    assert_eq!(
        safe_script_message("Error", "设备池为空，请检查网络后重试", &secrets).as_deref(),
        Some("书源提示：设备池为空，请检查网络后重试")
    );
    assert_eq!(
        safe_script_message("ReferenceError", "FQ_missing is not defined", &secrets).as_deref(),
        Some("书源用到了尚不支持的函数或变量：FQ_missing")
    );
    for leaky in [
        "登录失败 sid-fake-0042",
        "请求失败 https://example.invalid/a?x=1",
        "签名错误 abcdefghijklmnopqrstuvwxyz012345",
        "only ascii message",
    ] {
        assert_eq!(
            safe_script_message("Error", leaky, &secrets),
            None,
            "{leaky}"
        );
    }
    assert!(
        safe_script_message(
            "TypeError",
            "cannot read property 'data' of undefined",
            &secrets
        )
        .unwrap()
        .contains("data")
    );

    let (base, _) = serve(|_| html("<html><body>目录页</body></html>"));
    let source = serde_json::json!({"bookSourceUrl": base, "bookSourceName": "夹具脚本错",
        "header": "{\"Cookie\":\"sid=sid-fake-0042\"}",
        "searchUrl": "/s?q={{key}}",
        "ruleSearch": {"bookList": "@js:throw new Error('登录失败 sid-fake-0042')", "name": "$.name"},
        "ruleToc": {"chapterList": "@js:throw new Error('设备池为空，请检查网络后重试')",
            "chapterName": "$.name", "chapterUrl": "$.url"}})
    .to_string();
    let (sources, _) = source::import(&source).unwrap();
    let rt = SourceRt::new(sources.into_iter().next().unwrap());
    let engine = Engine::new(rt).unwrap();
    let book = crate::webbook::Book {
        name: "测试书".into(),
        book_url: format!("{base}/b"),
        toc_url: format!("{base}/toc"),
        origin: base.clone(),
        ..Default::default()
    };
    let error = engine.run(|s| s.toc(&book)).unwrap_err();
    assert_eq!(
        error,
        "目录脚本出错：书源提示：设备池为空，请检查网络后重试"
    );
    let error = engine.run(|s| s.search("测试", 1)).unwrap_err();
    assert_eq!(error, "搜索脚本出错：书源 JS 执行失败");
    assert!(!error.contains("sid-fake"));
}

/// java.net.URL.openConnection 子集：二进制 POST、gzip 响应、自定义响应头、错误流（本机夹具，写法同番茄书源）。
#[test]
fn http_url_connection_subset_uses_plugin_network() {
    use flate2::{Compression, read::GzDecoder, write::GzEncoder};
    use std::io::{Read as _, Write as _};
    let (base, log) = serve(|req| match req.path.as_str() {
        "/register" => {
            let mut text = String::new();
            GzDecoder::new(&req.body[..])
                .read_to_string(&mut text)
                .unwrap();
            let mut gz = GzEncoder::new(Vec::new(), Compression::default());
            gz.write_all(format!("收到:{text}\n第二行").as_bytes())
                .unwrap();
            Resp {
                status: 200,
                content_type: "application/json",
                body: gz.finish().unwrap(),
                extra: vec![
                    ("Content-Encoding".into(), "gzip".into()),
                    ("y".into(), "fake-y".into()),
                ],
            }
        }
        _ => Resp {
            status: 404,
            content_type: "text/plain",
            body: "没有这个接口".as_bytes().to_vec(),
            extra: vec![],
        },
    });
    let engine = Engine::new(SourceRt::new(crate::source::BookSource {
        book_source_url: base.clone(),
        ..Default::default()
    }))
    .unwrap();
    let script = format!(
        r#"
        function read(c){{var code=c.getResponseCode();var is=(code>=400)?c.getErrorStream():c.getInputStream();
          var enc=String(c.getHeaderField('Content-Encoding')||'');var st=is;
          if(enc.indexOf('gzip')>=0)st=new Packages.java.util.zip.GZIPInputStream(is);
          var rd=new Packages.java.io.BufferedReader(new Packages.java.io.InputStreamReader(st,'UTF-8'));
          var line,sb='';while((line=rd.readLine())!=null)sb+=String(line)+'|';rd.close();
          return code+' '+sb+' y='+c.getHeaderField('y');}}
        var bos=new Packages.java.io.ByteArrayOutputStream();var g=new Packages.java.util.zip.GZIPOutputStream(bos);
        var b=new Packages.java.lang.String('设备-fake').getBytes('UTF-8');g.write(b,0,b.length);g.close();
        var arr=bos.toByteArray();
        var c=new Packages.java.net.URL('{base}/register').openConnection();
        c.setRequestMethod('POST');c.setDoOutput(true);c.setRequestProperty('Content-Type','application/octet-stream');
        c.setConnectTimeout(20000);c.setReadTimeout(25000);
        var out=c.getOutputStream();out.write(arr,0,arr.length);out.flush();out.close();
        var first=read(c);
        var e=new Packages.java.net.URL('{base}/missing').openConnection();e.setRequestMethod('GET');
        first+' / '+read(e);
        "#
    );
    let result = engine.run(|s| s.eval_js_string(&script, &[])).unwrap();
    assert_eq!(
        result,
        "200 收到:设备-fake|第二行| y=fake-y / 404 没有这个接口| y=null"
    );
    assert!(
        log.lock()
            .unwrap()
            .iter()
            .any(|l| l.contains("POST /register"))
    );
    let denied = engine
        .run(|s| {
            s.eval_js(
                "new java.net.URL('file:///C:/x').openConnection().getResponseCode()",
                &[],
            )
        })
        .unwrap_err();
    assert!(!denied.is_empty());
}

/// BigInteger(numBits, SecureRandom)：番茄 APP 书源正文的 Diffie-Hellman 用它生成私钥；范围 [0, 2^n)，两次不同。
#[test]
fn replace_all_accepts_java_regex_strings() {
    let engine = Engine::new(SourceRt::new(crate::source::BookSource::default())).unwrap();
    let result = engine
        .run(|s| {
            s.eval_js_string(
                r#"['<p class="a">甲</p><br>乙'.replaceAll('<[^>]+>',''),
                   'a.b.c'.replaceAll('.','-'),
                   '价 5 元'.replaceAll('(\\d+)','[$1]'),
                   '共(1)页'.replaceAll('(1)','一'),
                   'x'.replaceAll('(?i)X','y')].join('|')"#,
                &[],
            )
        })
        .unwrap();
    // 原文里有这串字面文字时仍按 JS 原意整串替换；Java 才有的 (?i) 写法转不了时原样返回。
    assert_eq!(result, "甲乙|a-b-c|价 [5] 元|共一页|x");
}

#[test]
fn unlinked_toc_items_are_chapters_on_the_toc_page() {
    let (base, log) = serve(|req| match req.path.as_str() {
        "/poem" => html(
            "<h1>静夜思</h1><div id='c'><p>床前明月光，疑是地上霜。</p><p>举头望明月，低头思故乡。</p></div>",
        ),
        "/mixed" => html(
            r#"<ul><li>卷一</li><li><a href="/c/1">第一章</a></li></ul><div id='c'>目录页</div>"#,
        ),
        _ => html("<div id='c'>其他页</div>"),
    });
    let source = serde_json::json!({"bookSourceUrl": base, "bookSourceName": "单篇夹具",
        "ruleToc": {"chapterList": "tag.h1", "chapterName": "text"},
        "ruleContent": {"content": "id.c@text"}})
    .to_string();
    let (sources, _) = source::import(&source).unwrap();
    let engine = Engine::new(SourceRt::new(sources.into_iter().next().unwrap())).unwrap();
    let book = |path: &str| crate::webbook::Book {
        name: "测试书".into(),
        book_url: format!("{base}{path}"),
        toc_url: format!("{base}{path}"),
        origin: base.clone(),
        ..Default::default()
    };
    let poem = book("/poem");
    let toc = engine.run(|s| s.toc(&poem)).unwrap();
    assert_eq!(toc.len(), 1);
    assert!(!toc[0].is_volume, "整本没有链接时，目录项是章节");
    assert_eq!(toc[0].url, format!("{base}/poem"));
    let text = engine
        .run(|s| s.chapter_content(&poem, &toc[0], ""))
        .unwrap();
    assert!(text.contains("举头望明月"), "{text}");

    let source = serde_json::json!({"bookSourceUrl": base, "bookSourceName": "混合夹具",
        "ruleToc": {"chapterList": "li", "chapterName": "text", "chapterUrl": "a@href"},
        "ruleContent": {"content": "id.c@text"}})
    .to_string();
    let (sources, _) = source::import(&source).unwrap();
    let engine = Engine::new(SourceRt::new(sources.into_iter().next().unwrap())).unwrap();
    let toc = engine.run(|s| s.toc(&book("/mixed"))).unwrap();
    assert_eq!(toc.len(), 2);
    assert!(toc[0].is_volume, "有链接的目录里，没链接的项仍是卷名");
    assert!(!toc[1].is_volume);
    assert!(log.lock().unwrap().iter().any(|l| l == "GET /poem"));
}

#[test]
fn big_integer_random_bits_constructor() {
    let context = crate::control::Context {
        pure_compute: true,
        ..Default::default()
    };
    let _guard = context.enter();
    let engine = Engine::new(SourceRt::new(crate::source::BookSource::default())).unwrap();
    let result = engine
        .run(|s| {
            s.eval_js_string(
                r#"var B=Packages.java.math.BigInteger,R=Packages.java.security.SecureRandom;
                var a=new B(256,new R()),b=new B(256,new R()),top=B.ONE.shiftLeft(256);
                var P=new B('23',10),pub=B.valueOf(2).modPow(new B(5,new R()),P);
                [a.signum()>=0,a.compareTo(top)<0,!a.equals(b),new B(0,new R()).signum(),
                 pub.compareTo(P)<0].join(',')"#,
                &[],
            )
        })
        .unwrap();
    assert_eq!(result, "true,true,true,0,true");
    let bad = engine.run(|s| {
        s.eval_js(
            "new Packages.java.math.BigInteger(-1,new Packages.java.security.SecureRandom())",
            &[],
        )
    });
    assert!(bad.is_err());
}

#[test]
fn network_redirect_scopes_credentials_and_null_user_agent() {
    use crate::net::{Net, Request};
    let recorded = Arc::new(Mutex::new(Vec::<Req>::new()));
    let capture = recorded.clone();
    let (target, _) = serve(move |req| {
        capture.lock().unwrap().push(req.clone());
        html("ok")
    });
    // 使用不同主机名，Cookie 本身不按端口隔离。
    let target = target.replace("127.0.0.1", "localhost");
    let capture = recorded.clone();
    let (base, _) = serve(move |request| {
        capture.lock().unwrap().push(request.clone());
        Resp {
            status: 302,
            content_type: "text/plain",
            body: Vec::new(),
            extra: if request.path == "/first" {
                vec![
                    ("Location".into(), "/second".into()),
                    ("Set-Cookie".into(), "session=updated; Path=/".into()),
                ]
            } else {
                vec![("Location".into(), target.clone())]
            },
        }
    });
    let net = Net::new(
        None,
        vec![
            ("Cookie".into(), "session=initial".into()),
            ("Authorization".into(), "fixture-secret".into()),
        ],
    );
    net.fetch(&Request {
        url: format!("{base}/first"),
        method: "POST".into(),
        body: Some(b"x=1".to_vec()),
        headers: vec![
            ("User-Agent".into(), "null".into()),
            (
                "Content-Type".into(),
                "application/x-www-form-urlencoded".into(),
            ),
        ],
        ..Default::default()
    })
    .unwrap();
    let log = recorded.lock().unwrap();
    assert_eq!(log.len(), 3);
    assert_eq!(log[0].header("cookie"), "session=initial");
    assert_eq!(log[1].header("cookie"), "session=updated");
    assert_eq!(log[1].header("authorization"), "fixture-secret");
    assert_eq!(log[1].method, "GET");
    assert!(log[1].body.is_empty());
    assert!(log[1].header("content-type").is_empty());
    assert!(log[2].header("cookie").is_empty());
    assert!(log[2].header("authorization").is_empty());
    assert!(log[2].header("user-agent").is_empty());
}

#[test]
fn external_js_lib_download_errors_are_not_missing_functions() {
    let (base, requests) = serve(|request| {
        if request.path == "/ok" {
            html("var fixtureLibrary = 42;")
        } else {
            Resp {
                status: 404,
                ..html("EP_FAKE_LIBRARY_SECRET")
            }
        }
    });
    let source = source::BookSource {
        js_lib: serde_json::json!({"a":format!("{base}/ok"),"secret-name":format!("{base}/EP_FAKE_URL_SECRET")}).to_string(),
        ..Default::default()
    };
    let error = Engine::new(SourceRt::new(source)).err().unwrap();
    assert_eq!(error, "外部 JS 库下载失败：页面不存在");
    assert_eq!(
        crate::control::ErrorKind::classify(&error),
        crate::control::ErrorKind::Missing
    );
    assert_eq!(crate::probe::reason(&error), "外部 JS 库下载失败");
    assert_eq!(requests.lock().unwrap().len(), 2);
    let engine = Engine::new(SourceRt::new(source::BookSource {
        js_lib: serde_json::json!({"a":format!("{base}/ok")}).to_string(),
        ..Default::default()
    }))
    .unwrap();
    assert_eq!(
        engine
            .run(|s| s.eval_js_string("fixtureLibrary", &[]))
            .unwrap(),
        "42"
    );
    let _guard = crate::control::Context::new(
        crate::control::Profile::Detail,
        Arc::new(std::sync::atomic::AtomicBool::new(true)),
    )
    .enter();
    assert!(
        Engine::new(SourceRt::new(source::BookSource {
            js_lib: serde_json::json!({"a":format!("{base}/ok")}).to_string(),
            ..Default::default()
        }))
        .err()
        .unwrap()
        .contains("已取消")
    );
    assert_eq!(requests.lock().unwrap().len(), 3);
}
