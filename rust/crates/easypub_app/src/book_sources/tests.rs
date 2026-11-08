use super::*;
use std::{
    io::Write,
    net::TcpListener,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    thread,
    time::Duration,
};

static SERIAL: AtomicUsize = AtomicUsize::new(0);
fn temp() -> PathBuf {
    let p = std::env::temp_dir().join(format!(
        "easypub-v44-{}-{}",
        std::process::id(),
        SERIAL.fetch_add(1, Ordering::Relaxed)
    ));
    std::fs::create_dir_all(&p).unwrap();
    p
}
fn fixture(base: &str) -> Value {
    json!({"bookSourceName":"离线测试书源", "bookSourceUrl":base, "bookSourceType":0,
        "header":r#"{"User-Agent":"V44-fixture","Cookie":"FAKE_SECRET","AUTHORIZATION":"FAKE_SECRET"}"#,
        "searchUrl":"/search, {\"method\":\"POST\",\"body\":\"q={{key}}&page={{page}}\",\"charset\":\"gbk\",\"headers\":{\"Cookie\":\"FAKE_SECRET\",\"Accept\":\"text/html\"}}",
        "ruleSearch":{"bookList":"class.books@tag.li", "name":"tag.a@text", "bookUrl":"tag.a@href", "author":"class.author@text", "lastChapter":"class.latest@text"},
        "ruleBookInfo":{"name":"tag.h1@text", "author":"class.author@text", "tocUrl":"id.toc@href"},
        "ruleToc":{"chapterList":"class.list@children", "chapterName":"text", "chapterUrl":"href", "isVolume":"data-volume", "nextTocUrl":"id.next@href"}})
}
fn run(root: &Path, mut request: Value) -> Result<Value, ApiError> {
    request["op"] = json!("acquire");
    execute_at(&request, &CancellationToken::new(), root)
}
fn import(root: &Path, sources: Value) -> Value {
    let p = root.join("input.json");
    std::fs::write(&p, sources.to_string()).unwrap();
    run(root, json!({"source":"book_source_import","input":p})).unwrap()
}

#[test]
fn selector_index_composition_and_replacement_semantics() {
    let content = Content::page("<ul class='list'><li>A<a href='/a'>甲</a></li><li>B<a href='/b'>乙</a></li><li>C<a href='/c'>丙</a></li></ul>".into());
    for (rule, expected) in [
        ("class.list@tag.li.0@tag.a@text", vec!["甲"]),
        ("class.list@tag.li.-1@tag.a@href", vec!["/c"]),
        ("class.list@tag.li!1@tag.a@text", vec!["甲", "丙"]),
        ("class.list@tag.li[2,0]@tag.a@text", vec!["丙", "甲"]),
        ("class.list@tag.li[0:1]@tag.a@text", vec!["甲", "乙"]),
        ("class.list@tag.li[-1:0]@tag.a@text", vec!["丙", "乙", "甲"]),
        ("@css:ul.list > li:nth-child(2) a@text", vec!["乙"]),
        ("id.absent@text||tag.a.0@text", vec!["甲"]),
        ("tag.a.0@text&&tag.a.2@text", vec!["甲", "丙"]),
        (
            "tag.a[0:1]@text%%tag.a[1:2]@text",
            vec!["甲", "乙", "乙", "丙"],
        ),
        ("tag.li.0@ownText", vec!["A"]),
        ("tag.li.0@textNodes", vec!["A"]),
    ] {
        assert_eq!(
            Rule::parse(rule, false).unwrap().strings(&content).unwrap(),
            expected,
            "{rule}"
        );
    }
    let content = Content::page("<p>a12b34<span>尾部</span><script>unsafe()</script></p>".into());
    assert_eq!(
        Rule::parse(r"tag.p@ownText##(\d+)##[$1]###", false)
            .unwrap()
            .string(&content)
            .unwrap(),
        "[12]"
    );
    assert_eq!(
        Rule::parse(r"tag.p@ownText##(\d+)##[$1]", false)
            .unwrap()
            .string(&content)
            .unwrap(),
        "a[12]b[34]"
    );
    assert!(
        !Rule::parse("tag.p@html", false)
            .unwrap()
            .string(&content)
            .unwrap()
            .contains("script")
    );
    assert!(
        Rule::parse("tag.p@all", false)
            .unwrap()
            .string(&content)
            .unwrap()
            .contains("script")
    );
    assert!(Rule::parse("tag.a:contains(x)@href", false).is_err());
    assert!(Rule::parse(r"tag.a@text##(?<=第)章", false).is_err());
    assert!(Rule::parse("@get:title", false).is_err());
    assert!(Rule::parse("//a/text()", false).is_err());
}

#[test]
fn json_fields_arrays_recursive_paths_and_empty_alternatives() {
    let content =
        Content::Json(json!({"a":{"books":[{"name":"甲"},{"name":"乙"}]},"nested":{"name":"丙"}}));
    for (rule, expected) in [
        ("$.a.books[*].name", vec!["甲", "乙"]),
        ("@json:$.a.books[1].name", vec!["乙"]),
        ("$..name", vec!["甲", "乙", "丙"]),
    ] {
        assert_eq!(
            Rule::parse(rule, false).unwrap().strings(&content).unwrap(),
            expected
        );
    }
    let rows = Rule::parse("$.a.books", true)
        .unwrap()
        .nodes(&content)
        .unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(
        Rule::parse("name", false)
            .unwrap()
            .string(&rows[0])
            .unwrap(),
        "甲"
    );
    assert_eq!(
        Rule::parse("$.missing||$.nested.name", false)
            .unwrap()
            .string(&content)
            .unwrap(),
        "丙"
    );
    assert!(Rule::parse("$.a.books[?(@.name)]", true).is_err());
    let request =
        http::Request::parse(r#"/search, {"method":"POST","body":"{\"q\":\"{{ key }}\"}"}"#)
            .unwrap();
    let (_, body) = request
        .expanded("https://example.test/", "甲\"&乙")
        .unwrap();
    assert_eq!(
        serde_json::from_slice::<Value>(&body).unwrap(),
        json!({"q":"甲\"&乙"})
    );
}

#[test]
fn import_deduplicates_sanitizes_and_classifies_without_persisting_scripts() {
    let root = temp();
    let base = fixture("https://example.test/");
    assert_eq!(
        import(&root, base.clone())["sources"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let mut updated = base.clone();
    updated["bookSourceName"] = json!("更新名称");
    let mut values = vec![base, updated];
    for (i, reason) in [
        "book_source_javascript_required",
        "book_source_login_required",
        "book_source_type_unsupported",
        "book_source_disabled",
        "book_source_xpath_unsupported",
        "book_source_rule_unsupported",
        "book_source_javascript_required",
    ]
    .iter()
    .enumerate()
    {
        let mut s = fixture(&format!("https://{i}.example.test/"));
        match i {
            0 => s["ruleToc"]["formatJs"] = json!("result + 'FAKE_SECRET'"),
            1 => s["loginUrl"] = json!("/login"),
            2 => s["bookSourceType"] = json!(2),
            3 => s["enabled"] = json!(false),
            4 => s["ruleToc"]["chapterList"] = json!("//a"),
            5 => s["ruleSearch"]["name"] = json!("@get:title"),
            _ => s["searchUrl"] = json!("/search,{\"webView\":true}"),
        }
        assert_eq!(source(&s).unwrap().reason, *reason);
        values.push(s);
    }
    let list = import(&root, json!(values));
    assert_eq!(list["sources"].as_array().unwrap().len(), 8);
    assert_eq!(
        list["sources"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|s| s["supported"] == true)
            .count(),
        1
    );
    let stored = std::fs::read_to_string(root.join("sources.json")).unwrap();
    assert!(!stored.contains("FAKE_SECRET"));
    assert!(!stored.contains("Cookie"));
    assert!(stored.contains("更新名称"));
    let bad = root.join("bad.json");
    std::fs::write(&bad, "[invalid").unwrap();
    assert!(run(&root, json!({"source":"book_source_import","input":bad})).is_err());
    assert_eq!(
        std::fs::read_to_string(root.join("sources.json")).unwrap(),
        stored
    );
    std::fs::write(root.join("sources.json"), "[broken").unwrap();
    std::fs::write(root.join("keep.txt"), "not owned").unwrap();
    run(&root, json!({"source":"book_source_clear"})).unwrap();
    assert!(root.join("keep.txt").exists());
    assert_eq!(
        run(&root, json!({"source":"book_source_list"})).unwrap()["sources"],
        json!([])
    );
}

struct Server {
    url: String,
    requests: Arc<Mutex<Vec<String>>>,
    stop: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
}
impl Server {
    fn new(handler: impl Fn(&str) -> (u16, String, Vec<u8>) + Send + 'static) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let url = format!("http://{}/", listener.local_addr().unwrap());
        let stop = Arc::new(AtomicBool::new(false));
        let exit = stop.clone();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let received = requests.clone();
        let worker = thread::spawn(move || {
            while !exit.load(Ordering::Relaxed) {
                let (mut socket, _) = match listener.accept() {
                    Ok(v) => v,
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(2));
                        continue;
                    }
                    Err(e) => panic!("{e}"),
                };
                socket.set_nonblocking(false).unwrap();
                socket
                    .set_read_timeout(Some(Duration::from_secs(3)))
                    .unwrap();
                let mut bytes = Vec::new();
                let mut byte = [0];
                while !bytes.ends_with(b"\r\n\r\n") {
                    socket.read_exact(&mut byte).unwrap();
                    bytes.push(byte[0]);
                }
                let headers = String::from_utf8(bytes.clone()).unwrap();
                let len = headers
                    .lines()
                    .find_map(|s| {
                        s.to_ascii_lowercase()
                            .strip_prefix("content-length:")
                            .map(|v| v.trim().parse::<usize>().unwrap())
                    })
                    .unwrap_or(0);
                let mut body = vec![0; len];
                socket.read_exact(&mut body).unwrap();
                bytes.extend(body);
                let text = String::from_utf8(bytes).unwrap();
                received.lock().unwrap().push(text.clone());
                let (status, extra, body) = handler(&text);
                if status == 0 {
                    let _ = socket.read(&mut byte);
                    continue;
                }
                let head = format!(
                    "HTTP/1.1 {status} Fixture\r\nConnection: close\r\nContent-Length: {}\r\n{extra}\r\n",
                    body.len()
                );
                let _ = socket.write_all(head.as_bytes());
                let _ = socket.write_all(&body);
            }
        });
        Self {
            url,
            requests,
            stop,
            worker: Some(worker),
        }
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        let result = self.worker.take().unwrap().join();
        if !thread::panicking() {
            result.unwrap();
        }
    }
}

#[test]
fn local_http_search_gbk_post_redirect_pages_cache_and_failures() {
    let server = Server::new(|request| {
        let path = request.split_whitespace().nth(1).unwrap();
        let html=match path {
            "/search"=>"<meta charset='gbk'><ul class='books'><li><a href='/book'>测试书</a><span class='author'>作者</span><span class='latest'>第二章 乙</span></li></ul>".into(),
            "/book"=>return(302,"Location: /novel/info\r\n".into(),vec![]),
            "/novel/info"=>"<h1>测试书</h1><span class='author'>作者</span><a id='toc' href='toc'>目录</a>".into(),
            "/novel/toc"=>"<div class='list'><h2 data-volume='true'>第一卷 开始</h2><a href='c1'>第一章 甲</a></div><a id='next' href='toc2'>下一页</a>".into(),
            "/novel/toc2"=>"<div class='list'><a href='c2'>第二章 乙</a></div>".into(),
            "/cycle"=>"<div class='list'><a href='/a'>第一章 甲</a></div><a id='next' href='/cycle'>下一页</a>".into(),
            "/sel1"=>"<div class='list'><a href='/s/1'>第一章 甲</a></div><a id='next' href='/sel1'>1</a><a id='next' href='/sel2'>2</a>".into(),
            "/sel2"=>"<div class='list'><a href='/s/2'>第二章 乙</a></div><a id='next' href='/sel1'>1</a><a id='next' href='/sel2'>2</a>".into(),
            "/limit"=>"<div class='list'><a href='/a'>第一章 甲</a></div><a id='next' href='/page/1'>下一页</a>".into(),
            "/loop"=>return(302,"Location: /loop\r\n".into(),vec![]),
            "/badredirect"=>return(302,"Location: file:///private\r\n".into(),vec![]),
            "/failure"=>return(500,String::new(),vec![]),
            "/login"=>return(401,String::new(),vec![]),
            "/verify"=>return(403,String::new(),vec![]),
            "/rate"=>return(429,String::new(),vec![]),
            _ if path.starts_with("/page/")=>{
                let i:usize=path[6..].parse().unwrap();format!("<div class='list'><a href='/c/{i}'>第{i}章 甲</a></div><a id='next' href='/page/{}'>下一页</a>",i+1)
            },
            _=>panic!("unexpected fixture route"),
        };
        let body = if path == "/search" {
            easypub_core::encoding::encode(
                &html,
                easypub_core::encoding::EncodingKind::Cp936,
                false,
            )
            .unwrap()
        } else {
            html.into_bytes()
        };
        (200, String::new(), body)
    });
    let root = temp();
    let source_json = fixture(&server.url);
    let list = import(&root, source_json.clone());
    let id = list["sources"][0]["id"].as_str().unwrap();
    let found = run(
        &root,
        json!({"source":"book_source_search","book_source_id":id,"input":"测试"}),
    )
    .unwrap();
    assert_eq!(found["books"][0]["title"], "测试书");
    assert_eq!(found["books"][0]["author"], "作者");
    let request = json!({"source":"book_source_toc","book_source_id":id,"input":found["books"][0]["url"],"use_cache":true});
    let result = run(&root, request.clone()).unwrap();
    let catalog: Catalog = serde_json::from_value(result["catalog"].clone()).unwrap();
    super::super::validate_snapshot(&catalog).unwrap();
    assert_eq!(catalog.entries.len(), 2);
    assert_eq!(catalog.entries[1].volume, "第一卷 开始");
    assert_eq!(
        catalog.entries[1].id,
        hash(format!("{}novel/c2", server.url).as_bytes())
    );
    assert_eq!(catalog.completeness, "unknown");
    assert_eq!(run(&root, request.clone()).unwrap()["from_cache"], true);
    let mut reverse = source_json.clone();
    reverse["ruleToc"]["chapterList"] = json!("-class.list@children");
    import(&root, reverse);
    let reversed = run(&root, request.clone()).unwrap();
    assert_eq!(reversed["from_cache"], false);
    assert_eq!(reversed["catalog"]["entries"][0]["title"], "第二章 乙");
    // V45：翻页下拉列出全部页（含当前页、已抓过的页）时逐页抓取一次，不当作循环。
    for (path, titles) in [
        ("cycle", vec!["第一章 甲"]),
        ("sel1", vec!["第一章 甲", "第二章 乙"]),
    ] {
        let mut s = source_json.clone();
        s["ruleBookInfo"]["tocUrl"] = json!("");
        import(&root, s);
        let got = run(&root,json!({"source":"book_source_toc","book_source_id":id,"input":format!("{}{path}",server.url),"use_cache":false})).unwrap();
        let entries: Vec<String> = got["catalog"]["entries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["title"].as_str().unwrap().to_owned())
            .collect();
        assert_eq!(entries, titles, "{path}");
    }
    for (path, reason) in [
        ("limit", "book_source_page_limit"),
        ("loop", "book_source_redirect_limit"),
        ("badredirect", "book_source_invalid_url"),
        ("failure", "http_failed"),
        ("login", "book_source_auth_required"),
        ("verify", "book_source_verification_required"),
        ("rate", "book_source_rate_limited"),
    ] {
        let mut s = source_json.clone();
        s["ruleBookInfo"]["tocUrl"] = json!("");
        import(&root, s);
        assert_eq!(run(&root,json!({"source":"book_source_toc","book_source_id":id,"input":format!("{}{path}",server.url)})).unwrap_err().next_action,reason);
    }
    let requests = server.requests.lock().unwrap();
    assert!(requests[0].starts_with("POST /search"));
    assert!(requests[0].contains("q=%B2%E2%CA%D4&page=1"));
    for request in requests.iter() {
        let lower = request.to_ascii_lowercase();
        assert!(!lower.contains("cookie:"));
        assert!(!lower.contains("authorization:"));
        assert!(!request.contains("FAKE_SECRET"));
    }
    drop(requests);
    run(&root, json!({"source":"book_source_clear"})).unwrap();
    super::super::validate_snapshot(&catalog).unwrap();
}

#[test]
fn source_transport_cancels_waiting_headers_and_rejects_non_http() {
    let server = Server::new(|_| (0, String::new(), vec![]));
    let token = CancellationToken::new();
    let cancel = token.clone();
    let url = server.url.clone();
    let worker = thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let client = http::Client::new(BTreeMap::new()).unwrap();
        runtime
            .block_on(token.run_until_cancelled(client.fetch(
                &http::Request::parse(&url).unwrap(),
                &url,
                "",
            )))
            .is_none()
    });
    for _ in 0..500 {
        if !server.requests.lock().unwrap().is_empty() {
            break;
        }
        thread::sleep(Duration::from_millis(2));
    }
    assert_eq!(server.requests.lock().unwrap().len(), 1);
    cancel.cancel();
    assert!(worker.join().unwrap());
    for url in [
        "file:///a",
        "data:text/plain,x",
        "https://name:secret@example.test/",
    ] {
        assert!(http::absolute("https://example.test/", url).is_err());
    }
}
