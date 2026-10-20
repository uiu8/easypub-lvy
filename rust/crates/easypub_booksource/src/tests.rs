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
    let (base, log) = serve(|req| match req.path.as_str() {
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
        "/check" => html(&format!("<p>{}</p>", req.header("cookie"))),
        "/p" => html(&format!(
            "<p id=\"r\">{} {}</p>",
            req.method,
            String::from_utf8_lossy(&req.body)
        )),
        _ => html("<p>no</p>"),
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
