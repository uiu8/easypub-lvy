//! 外部 FQNovel 接入。只访问用户选择的回环服务，不嵌入签名或设备实现。
use super::*;
use crate::{
    control::{Context, Profile},
    net::{Net, Request, Response},
};
use reqwest::Url;
use std::time::Instant;

fn origin(params: &Value) -> Result<Url, String> {
    let port = match params.get("port") {
        None => 9999,
        Some(v) => v
            .as_u64()
            .filter(|p| (1..=65535).contains(p))
            .ok_or("端口须为 1–65535")?,
    };
    let raw = params
        .get("url")
        .map(|v| v.as_str().ok_or("地址须为文本"))
        .transpose()?
        .map(str::to_owned)
        .unwrap_or_else(|| format!("http://127.0.0.1:{port}"));
    let mut url = Url::parse(&raw).map_err(|_| "请输入本机 FQNovel 地址")?;
    if url.scheme() != "http"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || url.path() != "/"
    {
        return Err("只接受不含凭据、路径或查询参数的本机 HTTP 地址".into());
    }
    let host = url.host_str().unwrap_or("").trim_matches(['[', ']']);
    if host == "localhost" {
        url.set_host(Some("127.0.0.1")).unwrap();
    } else if !host
        .parse::<std::net::IpAddr>()
        .is_ok_and(|ip| ip.is_loopback())
    {
        return Err("FQNovel 没有鉴权，仅支持本机回环地址；不接受局域网或公网地址，请在本机启动 FQNovel Desktop".into());
    }
    Ok(url)
}

fn request(base: &Url, path: &str, timeout: Duration) -> Result<Response, String> {
    let mut context = Context::new(Profile::Import, Arc::new(AtomicBool::new(false)));
    context.deadline = Some(Instant::now() + timeout);
    context.interactive = false;
    let _guard = context.enter();
    let mut net = Net::new(None, vec![]);
    net.crawl.proxy_mode = "direct".into();
    // 禁止自动重定向，避免回环服务把健康检查或订阅更新转发到其他主机。
    net.fetch_no_redirect(&Request {
        inspect_error_status: true,
        url: base.join(path).unwrap().to_string(),
        method: "GET".into(),
        proxy: Some("false".into()),
        ..Default::default()
    })
    .map_err(|_| "无法连接本机 FQNovel，请先启动 FQNovel Desktop 并核对端口".into())
}

fn status(r: &Response) -> Value {
    if r.status == 503 {
        return json!({"running":true,"ready":false,"service":"FQNovel Desktop","worker":"unknown",
            "cause":"site","next_action":"FQNovel 正在维护，请等待设备刷新完成后重试"});
    }
    let value: Value = serde_json::from_str(&r.text).unwrap_or(Value::Null);
    if r.status != 200 || value["service"] != "FQNovel Desktop" || value["status"] != "UP" {
        return json!({"running":true,"ready":false,"service":null,"worker":"unknown",
            "cause":"site","next_action":"该端口未返回受支持的 FQNovel 健康信息，请核对服务与端口"});
    }
    let worker = match value["worker"]["state"].as_str() {
        Some("ready") => "ready",
        Some("starting") => "starting",
        Some("stopped") => "stopped",
        _ => "unknown",
    };
    json!({"running":true,"ready":worker == "ready","service":"FQNovel Desktop","worker":worker,
        "cause":if worker == "ready" { Value::Null } else { json!("site") },
        "next_action":if worker == "ready" { "可接入本机书源" } else { "请在 FQNovel Desktop 中等待 worker 就绪后重试" }})
}

pub(crate) fn response_error(response: &Response) -> Option<&'static str> {
    let value: Value = serde_json::from_str(&response.text).unwrap_or(Value::Null);
    let code = value["error"].as_str().unwrap_or("");
    if value["code"] == -1
        && (code.contains("SIGN") || value["message"].as_str().unwrap_or("").contains("签名"))
    {
        Some("需要验证：FQNovel 签名失败，请在 FQNovel Desktop 中恢复服务后重试")
    } else if response.status == 503 {
        Some("网站错误：FQNovel 正在维护，请等待设备刷新完成后重试")
    } else if value["code"] == -1 && code.starts_with("WORKER_") {
        Some("网站错误：FQNovel worker 尚未就绪，请先启动 FQNovel Desktop 并等待就绪后重试")
    } else {
        None
    }
}

pub(super) fn fetch_source(url: &str) -> Result<String, String> {
    let mut base = Url::parse(url).map_err(|_| "本机订阅地址无效")?;
    if base.path() != "/book-source/fqnovel.json" {
        return Err("本机订阅路径无效".into());
    }
    base.set_path("/");
    let base = origin(&json!({"url":base.as_str()}))?;
    let r = request(&base, "/book-source/fqnovel.json", Duration::from_secs(10))?;
    if let Some(message) = response_error(&r) {
        return Err(message.into());
    }
    if r.status != 200 {
        return Err("本机 FQNovel 书源不可用或正在维护，请等待服务就绪后重试；不接受重定向".into());
    }
    Ok(r.text)
}

pub(super) fn handle(method: &str, params: &Value) -> Result<Value, String> {
    let base = origin(params)?;
    match method {
        "fqnovel.detect" => Ok(
            match request(&base, "/api/v1/health", Duration::from_secs(1)) {
                Ok(r) => status(&r),
                Err(_) => json!({"running":false,"ready":false,"service":null,"worker":"unknown",
                "cause":"network","next_action":"无法连接本机 FQNovel，请先启动 FQNovel Desktop 并核对端口"}),
            },
        ),
        "fqnovel.import" => {
            let health = handle("fqnovel.detect", params)?;
            if health["ready"] != true {
                return Ok(json!({"imported":false,"health":health}));
            }
            let url = base.join("/book-source/fqnovel.json").unwrap().to_string();
            let body = fetch_source(&url)?;
            let result = subscriptions::import(&body, &url)?;
            Ok(json!({"imported":true,"subscription":result,"health":health}))
        }
        _ => Err("未知本机书源操作，请更新插件与界面".into()),
    }
}

#[cfg(test)]
pub(super) mod tests {
    use super::*;
    #[test]
    fn http_timeout_unready_and_redirect_are_bounded() {
        use std::{
            io::{Read, Write},
            net::TcpListener,
        };
        for (status, delay, worker, expected) in [
            (200, 0, "starting", "site"),
            (503, 0, "ready", "site"),
            (302, 0, "ready", "site"),
            (200, 1300, "ready", "network"),
        ] {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let base = format!("http://{}", listener.local_addr().unwrap());
            let thread = std::thread::spawn(move || {
                let (mut stream, _) = listener.accept().unwrap();
                let mut buffer = [0; 4096];
                let _ = stream.read(&mut buffer);
                std::thread::sleep(Duration::from_millis(delay));
                let body =
                    json!({"status":"UP","service":"FQNovel Desktop","worker":{"state":worker}})
                        .to_string();
                let _ = write!(
                    stream,
                    "HTTP/1.1 {status} Fixture\r\nLocation: http://127.0.0.1:1/forbidden\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
            });
            let start = Instant::now();
            let result = handle("fqnovel.import", &json!({"url":base})).unwrap();
            assert_eq!(result["imported"], false);
            assert_eq!(result["health"]["cause"], expected);
            assert!(start.elapsed() < Duration::from_millis(1250));
            thread.join().unwrap();
        }
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        drop(listener);
        assert_eq!(
            handle("fqnovel.detect", &json!({"url":base})).unwrap()["running"],
            false
        );
    }
    pub(in crate::plugin) fn subscription_fixture() {
        use crate::{
            download,
            engine::{Engine, SourceRt},
        };
        let source = Arc::new(Mutex::new(String::new()));
        let body = source.clone();
        let (base, requests) = crate::tests::serve(move |req| {
            let value = match req.path.as_str() {
                "/api/v1/health" => {
                    json!({"status":"UP","service":"FQNovel Desktop","worker":{"state":"ready"}})
                }
                "/book-source/fqnovel.json" => return crate::tests::html(&body.lock().unwrap()),
                "/search" => json!({"books":[{"name":"离线样书","url":"/book"}]}),
                "/book" => json!({"toc":"/toc"}),
                "/toc" => {
                    json!({"chapters":[{"name":"第一章", "url":"/c/1"},{"name":"第二章", "url":"/c/2"},{"name":"第三章", "url":"/c/3"}]})
                }
                "/api/fqnovel/chapters/batch" => {
                    assert_eq!(req.method, "POST");
                    let input: Value = serde_json::from_slice(&req.body).unwrap();
                    assert_eq!(input["bookId"], "fixture");
                    let chapters: serde_json::Map<String,Value> = input["chapterIds"].as_array().unwrap().iter().enumerate().map(|(i,id)|(id.as_str().unwrap().to_owned(), json!({"txtContent":format!("样本{}。{}",i,"这是自拟的本地验证正文。".repeat(35))}))).collect();
                    json!({"code":0,"data":{"bookId":"fixture","chapters":chapters,"failures":{}}})
                }
                _ => panic!("意外夹具请求"),
            };
            crate::tests::html(&value.to_string())
        });
        *source.lock().unwrap() = json!([{"bookSourceUrl":base,"bookSourceName":"FQNovel 夹具","searchUrl":"/search","respondTime":180000,"maxBatchSize":3,
            "ruleSearch":{"bookList":"$.books[*]","name":"$.name","bookUrl":"$.url"},
            "ruleBookInfo":{"tocUrl":"$.toc"},"ruleToc":{"chapterList":"$.chapters[*]","chapterName":"$.name","chapterUrl":"$.url"},
            "ruleContent":{"content":"$.content","contentBatch":format!("var r=JSON.parse(java.post('{base}/api/fqnovel/chapters/batch', JSON.stringify({{bookId:'fixture',chapterIds:chapters.map(c=>c.url.split('/').pop())}}), {{}}).body());chapters.forEach(c=>java.cacheContent(c.url,r.data.chapters[c.url.split('/').pop()].txtContent));")}}]).to_string();
        let result = handle("fqnovel.import", &json!({"url":base})).unwrap();
        assert_eq!(result["imported"], true);
        let url = format!("{base}/book-source/fqnovel.json");
        assert!(
            super::super::handle("subscriptions.list", &json!({}))
                .unwrap()
                .to_string()
                .contains(&url)
        );
        let imported = state()
            .sources
            .iter()
            .find(|(s, _)| s.book_source_url == base)
            .unwrap()
            .0
            .clone();
        let rt = SourceRt::new(imported);
        let engine = Engine::new(rt.clone()).unwrap();
        let (book, toc) = engine.run(|s| {
            let mut book = s.search("样书", 1).unwrap().remove(0);
            s.book_info(&mut book).unwrap();
            let toc = s.toc(&book).unwrap();
            (book, toc)
        });
        let options = download::Options {
            folder: state().data.join("fq-output"),
            threads: 1,
            retries: 0,
            ..Default::default()
        };
        let start = Instant::now();
        let outcome = download::download(
            rt,
            &book,
            &toc,
            &options,
            Arc::new(AtomicBool::new(false)),
            Arc::new(|_| {}),
        )
        .unwrap();
        assert!(outcome.failures.is_empty());
        assert_eq!(outcome.downloaded, 3);
        assert!(
            std::fs::read_to_string(outcome.path)
                .unwrap()
                .contains("第三章")
        );
        assert!(
            start.elapsed() < Duration::from_secs(10),
            "respondTime 是上限，不是等待时间"
        );
        assert_eq!(
            requests
                .lock()
                .unwrap()
                .iter()
                .filter(|r| r.contains("chapters/batch"))
                .count(),
            1
        );
        assert_eq!(fetch_source(&url).unwrap(), *source.lock().unwrap());
    }
    #[test]
    fn endpoint_and_health_boundaries() {
        for (status, code, expected) in [
            (500, "SIGN_FAILED", "verification"),
            (503, "MAINTENANCE", "site"),
            (500, "WORKER_TIMEOUT", "site"),
        ] {
            let response = Response {
                status,
                text: json!({"code":-1,"error":code,"message":"FAKE_SECRET"}).to_string(),
                ..Default::default()
            };
            let error = response_error(&response).unwrap();
            assert_eq!(
                crate::control::ErrorKind::classify(error).cause(),
                Some(expected)
            );
            assert!(!error.contains("FAKE_SECRET"));
        }
        for url in [
            "http://192.168.1.1:9999",
            "http://example.com",
            "http://localhost.evil",
            "file:///tmp/a",
            "http://user:fake@127.0.0.1",
            "http://127.0.0.1/?token=fake",
            "http://127.0.0.1/path",
        ] {
            assert!(origin(&json!({"url":url})).is_err());
        }
        assert_eq!(
            origin(&json!({"url":"http://localhost:1234"}))
                .unwrap()
                .host_str(),
            Some("127.0.0.1")
        );
        assert!(origin(&json!({"url":"http://[::1]:1234"})).is_ok());
        assert!(origin(&json!({"port":0})).is_err());
        for (worker, ready) in [
            ("ready", true),
            ("starting", false),
            ("stopped", false),
            ("FAKE_SECRET", false),
        ] {
            let result = status(&Response {
                status: 200,
                text: json!({"service":"FQNovel Desktop","status":"UP",
                "worker":{"state":worker,"secret":"FAKE_SECRET"}})
                .to_string(),
                ..Default::default()
            });
            assert_eq!(result["ready"], ready);
            assert!(!result.to_string().contains("FAKE_SECRET"));
        }
        assert_eq!(
            status(&Response {
                status: 503,
                ..Default::default()
            })["cause"],
            "site"
        );
    }
}
