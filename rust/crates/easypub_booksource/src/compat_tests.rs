use crate::{
    engine::{Engine, SourceRt},
    source::BookSource,
};
use serde_json::json;
use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

#[test]
fn static_hints_do_not_block_trials_but_runtime_interfaces_and_nontext_are_rejected() {
    for (script, warning, unsupported) in [
        (
            "// java.commentOnly()\n /* java.blockOnly() */ 'java.literalOnly()'; []",
            false,
            false,
        ),
        ("if(false) java.unimplementedFixture(); []", true, false),
        ("java.unimplementedFixture()", true, true),
        ("java.nio.file.Files.readAllBytes('private')", true, true),
    ] {
        let source = BookSource {
            search_url: "data:,fixture".into(),
            rule_search: serde_json::from_value(json!({"bookList":format!("@js:{script}")}))
                .unwrap(),
            rule_content: serde_json::from_value(json!({"content":"p@text"})).unwrap(),
            ..Default::default()
        };
        assert_eq!(!crate::support::check(&source).is_empty(), warning);
        let engine = Engine::new(SourceRt::new(source)).unwrap();
        let mut report = crate::probe::Check::default();
        let error = crate::probe::check(&engine, "fixture", &mut report).unwrap_err();
        assert_eq!(report.stage, "search");
        assert_eq!(
            report.cause == Some("unsupported"),
            unsupported,
            "{script}: {error}"
        );
        assert_eq!(report.unsupported_interface.is_some(), unsupported);
        if unsupported {
            assert!(
                crate::probe::reason(&error)
                    .contains(report.unsupported_interface.as_deref().unwrap())
            );
        } else {
            assert_eq!(error, "校验词没有搜索结果");
        }
    }
    let source = BookSource {
        book_source_type: 1,
        js_lib: "while(true){}".into(),
        ..Default::default()
    };
    assert!(Engine::new(SourceRt::new(source)).is_err());
    let source = BookSource {
        js_lib: "java.unimplementedFixture()".into(),
        ..Default::default()
    };
    let error = Engine::new(SourceRt::new(source)).err().unwrap();
    assert_eq!(
        crate::probe::unsupported_interface(&error),
        Some("java.unimplementedFixture")
    );
}

#[test]
fn java_imports_resolve_only_implemented_classes_and_preserve_js_globals() {
    let engine = Engine::new(SourceRt::new(BookSource::default())).unwrap();
    engine.run(|s| {
        let run = |code| s.eval_js_string(code, &[]).unwrap();
        assert_eq!(run("importClass(org.jsoup.Jsoup);Jsoup.parse('<p>fixture</p>').select('p').text()"), "fixture");
        assert_eq!(run("var original=String;importPackage(Packages.java.lang,Packages.java.io,Packages.java.security,Packages.java.util);var b=new ByteArrayOutputStream();b.write([65,66]);[b.toByteArray().length,MessageDigest.getInstance('MD5').digest([65]).length,String===original].join('|')"), "2|16|true");
        assert_eq!(run("var imports=new JavaImporter(java.io,javax.crypto.spec);var n;with(imports){var key=new SecretKeySpec([1,2],'AES');n=key.getEncoded().length;}[n,typeof globalThis.SecretKeySpec].join('|')"), "2|undefined");
        assert_eq!(run("importClass(javax.crypto.spec.SecretKeySpec);new SecretKeySpec([3,4,5],'AES').getEncoded().length"), "3");
        for code in ["importClass(java.io.File)", "importPackage(java.nio.file)", "new JavaImporter(java.lang.Runtime)", "importPackage(java.io);new File('private')"] {
            assert!(s.eval_js(code, &[]).is_err(), "禁止的类不能经导入绕过");
        }
    });
    let other = Engine::new(SourceRt::new(BookSource::default())).unwrap();
    assert_eq!(
        other
            .run(|s| s.eval_js_string("typeof ByteArrayOutputStream", &[]))
            .unwrap(),
        "undefined"
    );
}

#[test]
fn importer_instance_methods_initialize_library_helpers_without_global_imports() {
    let engine = Engine::new(SourceRt::new(BookSource {
        js_lib: r#"
            var fixtureImports = new JavaImporter();
            fixtureImports.importPackage(java.lang, java.io);
            fixtureImports.importClass(javax.crypto.spec.SecretKeySpec);
            fixtureImports.importPackage(java.io);
            with (fixtureImports) {
                function fixtureBytes(text) { return new String(text).getBytes('GBK'); }
                function fixtureKey() { return new SecretKeySpec([1,2], 'AES').getEncoded(); }
            }
        "#
        .into(),
        ..Default::default()
    }))
    .unwrap();
    engine.run(|s| {
        assert_eq!(s.eval_js_string("JSON.stringify(fixtureBytes('中文'))", &[]).unwrap(), "[-42,-48,-50,-60]");
        assert_eq!(s.eval_js_string("JSON.stringify(fixtureKey())", &[]).unwrap(), "[1,2]");
        assert_eq!(s.eval_js_string("[typeof globalThis.SecretKeySpec,typeof globalThis.ByteArrayOutputStream,String===java.lang.String].join('|')", &[]).unwrap(), "undefined|undefined|false");
        for code in [
            "fixtureImports.importClass(java.io.File)",
            "fixtureImports.importPackage(java.nio.file)",
            "var local=new JavaImporter();local.SecretKeySpec=1;local.importClass(javax.crypto.spec.SecretKeySpec)",
        ] {
            assert!(s.eval_js(code, &[]).is_err());
        }
    });
}

#[test]
fn source_navigation_requests_ui_without_recursive_search_or_login_data() {
    for (code, kind, payload) in [
        (
            "java.searchBook('fixture', 'group')",
            "book_search",
            json!({"keyword":"fixture","scope":"group","source_id":null}),
        ),
        (
            "java.searchBook('fixture', {bookSourceUrl:'fixture-source',loginData:'private'})",
            "book_search",
            json!({"keyword":"fixture","scope":null,"source_id":"fixture-source"}),
        ),
        (
            "java.open('search',null,'fixture','fixture-source')",
            "book_search",
            json!({"keyword":"fixture","scope":null,"source_id":"fixture-source"}),
        ),
        (
            "java.open('login')",
            "login_open",
            json!({"source_id":null}),
        ),
        (
            "java.open('login',null,null,'fixture-source')",
            "login_open",
            json!({"source_id":"fixture-source"}),
        ),
    ] {
        let rt = SourceRt::new(BookSource::default());
        let calls = Arc::new(std::sync::Mutex::new(Vec::new()));
        let captured = calls.clone();
        *rt.services.interaction.lock().unwrap() = Some(Arc::new(move |kind, payload| {
            captured.lock().unwrap().push((kind.to_owned(), payload));
            Ok(json!(true))
        }));
        let engine = Engine::new(rt).unwrap();
        assert_eq!(
            engine
                .run(|s| s.eval_js_string(&format!("typeof ({code})"), &[]))
                .unwrap(),
            "undefined"
        );
        assert_eq!(*calls.lock().unwrap(), vec![(kind.to_owned(), payload)]);
        assert!(engine.take_logs().is_empty());
        let mut context = crate::control::current();
        context.interactive = false;
        let _guard = context.enter();
        assert!(engine.run(|s| s.eval_js(code, &[])).is_err());
        assert_eq!(calls.lock().unwrap().len(), 1);
    }
    let engine = Engine::new(SourceRt::new(BookSource::default())).unwrap();
    for code in [
        "java.searchBook('fixture')",
        "java.open('login')",
        "java.open('file:///private')",
        "java.open('rss')",
        "java.open('search')",
        "java.searchBook('x'.repeat(4097))",
        "java.searchBook('fixture',{})",
    ] {
        assert!(engine.run(|s| s.eval_js(code, &[])).is_err());
    }
}

#[test]
fn android_text_and_cookie_helpers_preserve_source_and_url_scope() {
    let engine = Engine::new(SourceRt::new(BookSource::default())).unwrap();
    engine.run(|s| {
        assert_eq!(s.eval_js_string("importClass(android.text.TextUtils);[null,'',' ',new java.lang.String('')].map(x=>TextUtils.isEmpty(x)).join(',')",&[]).unwrap(), "true,true,false,true");
        assert_eq!(s.eval_js_string("var cm=android.webkit.CookieManager.getInstance();cm.setCookie('https://fixture.test/private','fixture=value; Secure; Path=/private');cm.getCookie('https://fixture.test/private/chapter')",&[]).unwrap(), "fixture=value");
        for url in ["https://other.test/private", "https://fixture.test/public", "http://fixture.test/private"] {
            assert_eq!(s.eval_js_string(&format!("android.webkit.CookieManager.getInstance().getCookie({})===null",json!(url)),&[]).unwrap(), "true");
        }
        for code in ["android.webkit.CookieManager.getInstance().removeAllCookies(null)","android.webkit.CookieManager.getInstance().setCookie('https://fixture.test','x=y',function(){})", "android.text.TextUtils.htmlEncode('x')"] {
            assert!(s.eval_js(code,&[]).is_err());
        }
    });
    let other = Engine::new(SourceRt::new(BookSource::default())).unwrap();
    assert_eq!(other.run(|s|s.eval_js_string("android.webkit.CookieManager.getInstance().getCookie('https://fixture.test/private')===null",&[])).unwrap(), "true");
    assert!(engine.take_logs().is_empty());
    let source = BookSource {
        search_url: "/search".into(),
        js_lib: "importClass(android.text.TextUtils);android.webkit.CookieManager.getInstance();"
            .into(),
        rule_content: serde_json::from_value(json!({"content":"#c@text"})).unwrap(),
        ..Default::default()
    };
    assert!(crate::support::check(&source).is_empty());
}

#[test]
fn json_parse_diagnostics_keep_exception_and_reviver_semantics() {
    let engine = Engine::new(SourceRt::new(BookSource::default())).unwrap();
    engine.run(|s| {
        assert_eq!(s.eval_js("JSON.parse('EP_FAKE_PRIVATE_BODY')",&[]).unwrap_err(),"规则 JSON 数据解析失败");
        assert!(s.eval_js("let = ;",&[]).unwrap_err().contains("规则脚本语法错误"));
        assert_eq!(s.eval_js_string("try{JSON.parse('invalid')}catch(e){e instanceof SyntaxError && e.name==='SyntaxError' && __is_json_parse_error(e)}",&[]).unwrap(),"true");
        assert_eq!(s.eval_js_string("JSON.parse('{\"n\":2}',function(k,v){return k==='n'?v+3:v}).n",&[]).unwrap(),"5");
        for code in ["JSON.parse('{}',function(){throw new SyntaxError('EP_FAKE_PRIVATE_BODY')})", "JSON.parse({toString(){throw new SyntaxError('EP_FAKE_PRIVATE_BODY')}})"] {
            let error=s.eval_js(code,&[]).unwrap_err();
            assert!(error.contains("规则脚本语法错误"));
            assert!(!error.contains("EP_FAKE_PRIVATE_BODY"));
        }
        assert!(s.eval_js("JSON.parse(Symbol('fixture'))",&[]).is_err());
    });
    let source = BookSource {
        search_url: "data:,fixture".into(),
        rule_search: serde_json::from_value(json!({"bookList":"@js:JSON.parse('invalid')"}))
            .unwrap(),
        rule_content: serde_json::from_value(json!({"content":"p@text"})).unwrap(),
        ..Default::default()
    };
    let e = Engine::new(SourceRt::new(source)).unwrap();
    let mut report = crate::probe::Check::default();
    assert!(crate::probe::check(&e, "fixture", &mut report).is_err());
    assert_eq!(report.diagnostic, Some("script_json_error"));
}

#[test]
fn ui_actions_are_acknowledged_bounded_and_do_not_log_text() {
    let rt = SourceRt::new(BookSource::default());
    let engine = Engine::new(rt.clone()).unwrap();
    assert_eq!(
        engine
            .run(|s| s.eval_js_string("java.toast('fixture-private-text')", &[]))
            .unwrap(),
        "false"
    );
    assert!(!format!("{:?}", engine.take_logs()).contains("fixture-private-text"));
    assert!(
        engine
            .run(|s| s.eval_js("java.copyText('text')", &[]))
            .is_err()
    );
    let actions = Arc::new(std::sync::Mutex::new(Vec::new()));
    let captured = actions.clone();
    *rt.services.interaction.lock().unwrap() = Some(Arc::new(move |kind, payload| {
        captured.lock().unwrap().push((kind.to_owned(), payload));
        Ok(json!(kind != "clipboard"))
    }));
    // 新运行时没有此前未连接的复制尝试留下的节流时间。
    let other = SourceRt::new(BookSource::default());
    *other.services.interaction.lock().unwrap() = rt.services.interaction.lock().unwrap().clone();
    let engine = Engine::new(other.clone()).unwrap();
    assert_eq!(engine.run(|s| s.eval_js_string("[java.longToast('notice'),java.toast('again'),java.copyText('copy'),java.refreshExplore(),java.refreshExplore()].join(',')", &[])).unwrap(), "true,false,false,true,false");
    assert_eq!(actions.lock().unwrap().len(), 3);
    assert_eq!(other.services.explore_revision.load(Ordering::SeqCst), 1);
    assert!(engine.take_logs().is_empty());
    assert!(
        engine
            .run(|s| s.eval_js("java.copyText('x'.repeat(16385))", &[]))
            .is_err()
    );
    let mut context = crate::control::current();
    context.exploring = true;
    let _guard = context.enter();
    let fresh = SourceRt::new(BookSource::default());
    assert!(!fresh.services.action("explore_refresh", json!({})).unwrap());
    assert_eq!(fresh.services.explore_revision.load(Ordering::SeqCst), 0);
}

#[test]
fn browser_aliases_delegate_and_reject_non_web_schemes() {
    let engine = Engine::new(SourceRt::new(BookSource::default())).unwrap();
    let out = engine
        .run(|s| {
            s.eval_js_string(
                r#"
        var saved=__ep, calls=[];
        try {
          __ep=function(op,args){calls.push([op,JSON.parse(args)]);return '{"v":null}';};
          java.openUrl('https://fixture.test/a'); java.openWeb('https://fixture.test/b');
          java.showReadingBrowser('https://fixture.test/c','title');
          java.startBrowserDp('https://fixture.test/d','title');
        } finally { __ep=saved; }
        JSON.stringify(calls);
    "#,
                &[],
            )
        })
        .unwrap();
    let calls: serde_json::Value = serde_json::from_str(&out).unwrap();
    assert_eq!(calls.as_array().unwrap().len(), 4);
    assert!(calls.as_array().unwrap().iter().all(|c| c[0] == "browser"));
    for method in [
        "openUrl",
        "openWeb",
        "showReadingBrowser",
        "startBrowserDp",
        "startBrowserAwait",
    ] {
        for url in [
            "file:///C:/fixture",
            "javascript:alert(1)",
            "intent://fixture",
            "data:text/html,test",
        ] {
            let code = format!("java.{method}({})", json!(url));
            assert!(engine.run(|s| s.eval_js(&code, &[])).is_err());
        }
    }
    assert!(
        engine
            .run(|s| s.eval_js(
                "java.showBrowser('https://fixture.test','html','js','{}')",
                &[]
            ))
            .is_err()
    );
    assert!(engine.run(|s| s.eval_js("java.webview()", &[])).is_err());
    let mut context = crate::control::current();
    context.interactive = false;
    let _guard = context.enter();
    assert!(
        engine
            .run(|s| s.eval_js("java.openUrl('https://fixture.test')", &[]))
            .is_err()
    );
}

#[test]
fn aliases_identity_cookie_scope_and_login_memory() {
    let root = std::env::temp_dir().join(format!(
        "easypub-c07-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let rt = SourceRt::new(BookSource {
        book_source_url: "https://a.example".into(),
        ..Default::default()
    });
    *rt.services.data_dir.lock().unwrap() = Some(root.clone());
    let engine = Engine::new(rt.clone()).unwrap();
    let id = engine
        .run(|s| s.eval_js_string("java.deviceID()", &[]))
        .unwrap();
    assert_eq!(id.len(), 32);
    let other = SourceRt::new(rt.source.clone());
    *other.services.data_dir.lock().unwrap() = Some(root.clone());
    assert_eq!(other.services.device_id().unwrap(), id);
    *rt.services.data_dir.lock().unwrap() = None;
    rt.net.set_cookie("https://a.example/", "a=one");
    rt.net.set_cookie("https://nota.example/", "b=two");
    other.net.set_cookie("https://a.example/", "a=other");
    engine
        .run(|s| {
            s.eval_js(
                "java.clearCookie(); java.upLoginData({user:'synthetic'});",
                &[],
            )
        })
        .unwrap();
    assert!(
        rt.net
            .cookie_header(&"https://a.example/".parse().unwrap())
            .is_empty()
    );
    assert_eq!(
        rt.net
            .cookie_header(&"https://nota.example/".parse().unwrap()),
        "b=two"
    );
    assert_eq!(
        other
            .net
            .cookie_header(&"https://a.example/".parse().unwrap()),
        "a=other"
    );
    assert!(other.login_info.lock().unwrap().is_none());
    assert_eq!(engine.run(|s| s.eval_js_string("java.base64Decoder('5Lit5paH') + ':' + (java.getUserAgent() === java.getWebViewUA())", &[])).unwrap(), "中文:true");
    for code in [
        "java.base64Decoder('%%%')",
        "java.sleep(-1)",
        "java.sleep(30001)",
        "java.lang.Thread.sleep(-1)",
        "java.lang.Thread.sleep(30000,1)",
        "java.lang.Thread.sleep(0,1000000)",
        "java.getStrResponse()",
        "java.reLoginView()",
    ] {
        assert!(engine.run(|s| s.eval_js(code, &[])).is_err());
    }
    *rt.services.interaction.lock().unwrap() = Some(Arc::new(|kind, _| {
        Ok(if kind == "login_data" {
            json!({"user":"updated"})
        } else {
            json!(null)
        })
    }));
    engine
        .run(|s| s.eval_js("java.upLoginData(); java.reLoginView();", &[]))
        .unwrap();
    assert_eq!(
        rt.login_info.lock().unwrap().as_deref(),
        Some("{\"user\":\"updated\"}")
    );
    assert_eq!(std::fs::read_dir(&root).unwrap().count(), 1);
    std::fs::remove_file(root.join("anonymous-device-id.txt")).unwrap();
    std::fs::remove_dir(root).unwrap();
}

#[test]
fn sleep_cancels_without_waiting_full_duration() {
    for script in [
        "java.sleep(30000)",
        "importClass(java.lang.Thread); Thread.sleep(30000)",
    ] {
        let cancel = Arc::new(AtomicBool::new(false));
        let context = crate::control::Context::new(crate::control::Profile::Detail, cancel.clone());
        let _guard = context.enter();
        let engine = Engine::new(SourceRt::new(BookSource::default())).unwrap();
        let thread = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(60));
            cancel.store(true, Ordering::Relaxed);
        });
        let start = Instant::now();
        assert!(engine.run(|s| s.eval_js(script, &[])).is_err());
        assert!(start.elapsed() < Duration::from_secs(1));
        thread.join().unwrap();
    }
}

fn endpoint(status: u16, mime: &str, body: Vec<u8>) -> String {
    use std::io::{Read, Write};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let mime = mime.to_owned();
    std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut buf = [0; 4096];
        let _ = stream.read(&mut buf);
        let _ = write!(
            stream,
            "HTTP/1.1 {status} Fixture\r\nContent-Type: {mime}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        );
        let _ = stream.write_all(&body);
    });
    url
}

#[test]
fn response_status_and_verification_image_boundaries() {
    let rt = SourceRt::new(BookSource::default());
    *rt.services.interaction.lock().unwrap() = Some(Arc::new(|kind, payload| {
        assert_eq!(kind, "verification");
        assert_eq!(payload["mime"], "image/png");
        assert!(payload.get("url").is_none());
        Ok(json!("1234"))
    }));
    let engine = Engine::new(rt).unwrap();
    let url = endpoint(404, "text/plain", b"fixture missing".to_vec());
    let code = format!(
        "var r=java.getStrResponse({}); r.code()+':'+r.body()",
        json!(url)
    );
    assert_eq!(
        engine.run(|s| s.eval_js_string(&code, &[])).unwrap(),
        "404:fixture missing"
    );
    let url = endpoint(200, "image/png", vec![137, 80, 78, 71]);
    let code = format!("java.getVerificationCode({})", json!(url));
    assert_eq!(
        engine.run(|s| s.eval_js_string(&code, &[])).unwrap(),
        "1234"
    );
    for (mime, body) in [
        ("text/html", b"not image".to_vec()),
        ("image/png", vec![0; 1024 * 1024 + 1]),
    ] {
        let url = endpoint(200, mime, body);
        let code = format!("java.getVerificationCode({})", json!(url));
        assert!(engine.run(|s| s.eval_js(&code, &[])).is_err());
    }
}
