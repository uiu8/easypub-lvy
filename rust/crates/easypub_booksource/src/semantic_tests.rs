//! 根据公开规则说明自拟数据，经过真实 QuickJS/规则引擎，不访问真实站点。
use crate::{
    engine::{Engine, SourceRt},
    node::Node,
    source::BookSource,
};
use serde_json::json;

fn engine() -> Engine {
    Engine::new(SourceRt::new(BookSource::default())).unwrap()
}

#[test]
fn repair88_xpath_attribute_axes_keep_document_order() {
    engine().run(|scope| {
        scope.set_content(
            Node::page("<main><i>前</i><div id='x'><b>内</b></div><p>后</p></main>"),
            None,
        );
        for (rule, expected) in [
            ("@xpath://div/@id/following::*[1]/text()", "内"),
            ("@xpath://div/@id/following::p/text()", "后"),
            ("@xpath://div/@id/preceding::*[1]/text()", "前"),
            ("@xpath://div/@id/descendant-or-self::node()", "x"),
            ("@xpath://div/@id/parent::div/@id", "x"),
            ("@xpath://div/@id/following-sibling::*", ""),
            ("@xpath://div/@id/child::*", ""),
        ] {
            assert_eq!(scope.get_string(rule), expected, "{rule}");
        }
    });
}

#[test]
fn repair88_jsonpath_template_respects_quoted_braces() {
    let value = json!({"a}b":"甲", "c'{d}":"乙", "tail":"丙"});
    assert_eq!(
        crate::jsonpath::strings(&value, r#"/{$['a}b']}/{$['c\'{d}']}/{$.tail}"#).unwrap(),
        ["/甲/乙/丙"]
    );
    assert!(crate::jsonpath::strings(&value, r#"/{$['a}b']"#).is_err());
    assert!(crate::jsonpath::strings(&value, r#"/{$['a}b]}"#).is_err());
}

#[test]
fn repair88_xpath_unsupported_branch_cannot_return_partial_success() {
    let engine = engine();
    engine.run(|scope| {
        scope.set_content(Node::page("<main><p>有效正文</p></main>"), None);
        for rule in [
            "@xpath://p/text() | namespace::*",
            "@xpath://p/text() | unknown-function()",
            "@xpath://p[contains('x')]/text()",
        ] {
            engine.state().script_error = None;
            assert_eq!(scope.get_string(rule), "", "{rule}");
            assert!(
                engine
                    .state()
                    .script_error
                    .as_deref()
                    .is_some_and(|error| error.contains("XPath")),
                "{rule}"
            );
        }
        engine.state().script_error = None;
        assert_eq!(scope.get_string("@xpath://missing/text()"), "");
        assert!(engine.state().script_error.is_none());
        assert_eq!(scope.get_string("@xpath://p/text()"), "有效正文");
    });
}

#[test]
fn repair88_jsonpath_limit_is_an_error_not_partial_success() {
    let exact = serde_json::json!({"rows": vec![0; 50_000]});
    assert_eq!(
        crate::jsonpath::select(&exact, "$.rows[*]").unwrap().len(),
        50_000
    );
    let over = serde_json::json!({"groups": [vec![0; 25_001], vec![1; 25_000], vec![2]]});
    for rule in ["$.groups[*][*]", "$.groups[*][*].missing"] {
        assert!(
            crate::jsonpath::select(&over, rule)
                .unwrap_err()
                .contains("50000")
        );
    }
    assert!(crate::jsonpath::strings(&over, "{$.groups[*][*]}").is_err());
    let nested = serde_json::json!([{"children": vec![0; 50_001]}]);
    for rule in [
        "$[?(@.children[*])]",
        "$[?(@.children[*] == 0)]",
        "$[?(@.children[*] || true)]",
        "$[?(@.children[*] && true)]",
    ] {
        assert!(
            crate::jsonpath::select(&nested, rule)
                .unwrap_err()
                .contains("50000")
        );
    }
}

#[test]
fn repair88_single_at_selector_template_is_not_javascript() {
    engine().run(|scope| {
        scope.set_content(Node::page("<p class='intro'>简介</p>"), None);
        assert_eq!(scope.get_string("前{{@.intro@text}}后"), "前简介后");
    });
}

#[test]
fn repair88_urlconnection_read_timeout_reaches_network() {
    let (base, _) = crate::tests::serve(|_| {
        std::thread::sleep(std::time::Duration::from_millis(200));
        crate::tests::html("late")
    });
    engine().run(|scope| {
        let script = format!(
            r#"
          var c=new Packages.java.net.URL('{base}/slow').openConnection();
          c.setConnectTimeout(1000);c.setReadTimeout(25);
          c.getResponseCode();
        "#
        );
        let error = scope.eval_js_string(&script, &[]).unwrap_err();
        assert!(error.contains("超时"), "{error}");
        let result = scope
            .eval_js_string(
                r#"
          var c=new Packages.java.net.URL('https://example.invalid').openConnection();
          var rejected=0;for(var v of [-1,1.5,Infinity,2147483648]){
            try{c.setReadTimeout(v);}catch(e){rejected++;}
          }
          c.setReadTimeout(0);c.setConnectTimeout(123);
          [rejected,c.getReadTimeout(),c.getConnectTimeout()].join('|');
        "#,
                &[],
            )
            .unwrap();
        assert_eq!(result, "4|0|123");
    });
}

#[test]
fn repair88_toc_volume_fallback_does_not_hide_other_errors() {
    let (base, _) =
        crate::tests::serve(|_| crate::tests::html("<li>卷名</li><a href='/c'>第一章</a>"));
    for (name, url) in [
        ("@js:null.name", "href"),
        ("text", "@js:throw new Error('目录地址解析失败')"),
    ] {
        let source: BookSource = serde_json::from_value(json!({
            "bookSourceUrl":base,
            "ruleToc":{"chapterList":"li,a","chapterName":name,"chapterUrl":url}
        }))
        .unwrap();
        Engine::new(SourceRt::new(source)).unwrap().run(|scope| {
            let book = crate::webbook::Book {
                toc_url: format!("{base}/toc"),
                ..Default::default()
            };
            assert!(scope.toc(&book).is_err(), "非链接类型错误不能当作卷名忽略");
        });
    }
}

#[test]
fn repair88_jsoup_chained_removal_keeps_identity_and_live_parent() {
    engine().run(|scope| {
        let result = scope
            .eval_js_string(
                r#"
          const J = org.jsoup.Jsoup;
          const d = J.parse('<div><p><b>同</b><i>甲</i></p><p><b>同</b><i>乙</i></p></div>');
          const p = d.select('p').eq(1).first();
          d.select('p').eq(0).select('b').remove();
          const first = d.text();
          p.children().eq(1).remove();
          JSON.stringify([first,d.text(),p.text(),d.select('b').size()]);
        "#,
                &[],
            )
            .unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&result).unwrap(),
            json!(["甲 同乙", "甲 同", "同", 1])
        );
    });
}

#[test]
fn repair88_jsonpath_rejects_invalid_filters_and_preserves_quoted_operators() {
    let data = json!({"rows":[{"name":"a||b","n":2},{"name":"x","n":3}],"a,b":[0,1,2,3]});
    assert_eq!(
        crate::jsonpath::select(&data, "$['a,b'][::-1]").unwrap(),
        vec![json!(3), json!(2), json!(1), json!(0)]
    );
    assert_eq!(
        crate::jsonpath::select(&data, "$.rows[?(@.name == 'a||b' && @.n >= 2)].name").unwrap(),
        vec![json!("a||b")]
    );
    for rule in [
        "$.rows[?(@.n === 2)]",
        "$.rows[::0]",
        "$.",
        "$.rows[?(@.n &&)]",
    ] {
        assert!(crate::jsonpath::select(&data, rule).is_err(), "{rule}");
    }
    assert!(
        crate::jsonpath::select(&data, "$.missing")
            .unwrap()
            .is_empty()
    );
}

#[test]
fn repair88_cookie_sync_preserves_paths_and_rejects_cleared_snapshot() {
    let net = crate::net::Net::new(None, vec![]);
    let url = reqwest::Url::parse("https://example.test/books/one").unwrap();
    {
        let mut jar = net.cookies.lock().unwrap();
        jar.parse("sid=old; Path=/books; Secure; HttpOnly", &url)
            .unwrap();
        jar.parse("other=keep; Path=/else", &url).unwrap();
    }
    let before = crate::browser_cookie::export(&net, url.as_str());
    crate::browser_cookie::import(&net, url.as_str(), &before, &[]).unwrap();
    assert!(net.cookie_header(&url).is_empty());
    assert_eq!(
        net.cookie_header(&reqwest::Url::parse("https://example.test/else").unwrap()),
        "other=keep"
    );
    net.remove_cookies(url.as_str());
    assert!(crate::browser_cookie::import(&net, url.as_str(), &before, &before.entries).is_err());
}

#[test]
fn repair88_cookie_sync_preserves_concurrent_attribute_updates() {
    let net = crate::net::Net::new(None, vec![]);
    let url = reqwest::Url::parse("https://example.test/books/one").unwrap();
    for update in [
        "sid=same; Path=/books; Secure",
        "sid=same; Path=/books; HttpOnly",
        "sid=same; Path=/books; SameSite=Strict",
        "sid=same; Path=/books; Max-Age=3600",
        "sid=same; Path=/books; Domain=example.test",
    ] {
        net.cookies
            .lock()
            .unwrap()
            .parse("sid=same; Path=/books", &url)
            .unwrap();
        let before = crate::browser_cookie::export(&net, url.as_str());
        net.cookies.lock().unwrap().parse(update, &url).unwrap();
        // 旧网页删除或写回旧值，都不能抹掉并发更新的属性。
        for returned in [&[][..], before.entries.as_slice()] {
            crate::browser_cookie::import(&net, url.as_str(), &before, returned).unwrap();
            let current = crate::browser_cookie::export(&net, url.as_str());
            assert_eq!(current.entries.len(), 1, "{update}");
            let c = &current.entries[0];
            assert_eq!(c.secure, update.contains("Secure"));
            assert_eq!(c.http_only, update.contains("HttpOnly"));
            assert_eq!(c.same_site == "Strict", update.contains("Strict"));
            assert_eq!(c.expires.is_some(), update.contains("Max-Age"));
            assert_eq!(c.domain.starts_with('.'), update.contains("Domain"));
        }
    }
}

#[test]
fn repair88_cookie_redirect_expiry_and_atomic_retry() {
    use crate::browser_cookie::{BrowserCookie, export, import};
    let net = crate::net::Net::new(None, vec![]);
    let origin = reqwest::Url::parse("https://origin.test/").unwrap();
    let final_url = reqwest::Url::parse("https://target.test/books/1").unwrap();
    net.cookies
        .lock()
        .unwrap()
        .parse("origin=keep; Path=/", &origin)
        .unwrap();
    let before = export(&net, origin.as_str());
    let cookie = BrowserCookie {
        name: "session".into(),
        value: "fixture".into(),
        domain: "target.test".into(),
        path: "/books".into(),
        secure: true,
        http_only: true,
        same_site: "Strict".into(),
        expires: None,
    };
    let mut invalid = cookie.clone();
    invalid.domain = "invalid domain".into();
    assert!(
        import(
            &net,
            final_url.as_str(),
            &before,
            &[cookie.clone(), invalid]
        )
        .is_err()
    );
    assert!(net.cookie_header(&final_url).is_empty());
    import(&net, final_url.as_str(), &before, &[cookie.clone()]).unwrap();
    assert_eq!(net.cookie_header(&origin), "origin=keep");
    assert_eq!(net.cookie_header(&final_url), "session=fixture");
    assert!(
        net.cookie_header(&reqwest::Url::parse("http://target.test/books/1").unwrap())
            .is_empty()
    );
    assert!(
        net.cookie_header(&reqwest::Url::parse("https://target.test/other").unwrap())
            .is_empty()
    );
    let before = export(&net, final_url.as_str());
    let mut expired = cookie;
    expired.expires = Some(1.0);
    import(&net, final_url.as_str(), &before, &[expired]).unwrap();
    assert!(net.cookie_header(&final_url).is_empty());
    assert_eq!(net.cookie_header(&origin), "origin=keep");
}

#[test]
fn semantic_matrix_combinations_indexes_json_and_java_regex() {
    let html = Node::page(
        "<ul><li class='a'>甲</li><li class='b'>乙</li><li class='b'>丙</li><li class='b'>丁</li></ul>",
    );
    let data = Node::page(
        r#"{"none":"","books":[{"name":"甲","price":3},{"name":"乙","price":8},{"name":"丙","price":12}]}"#,
    );
    let text = Node::Text("甲12乙34".into());
    let cases: Vec<(&str, &Node, Vec<&str>)> = vec![
        (".a@text&&.b@text", &html, vec!["甲", "乙", "丙", "丁"]),
        (".missing@text||.b@text", &html, vec!["乙", "丙", "丁"]),
        (".a@text||.b@text", &html, vec!["甲"]),
        (".a@text%%.b@text", &html, vec!["甲", "乙", "丙", "丁"]),
        (".missing@text%%.b@text", &html, vec!["乙", "丙", "丁"]),
        ("li[-1:0]@text", &html, vec!["丁", "丙", "乙", "甲"]),
        ("li[0:3:2]@text", &html, vec!["甲", "丙"]),
        ("li[!0,-1]@text", &html, vec!["乙", "丙"]),
        ("li.0:2@text", &html, vec!["甲", "丙"]),
        ("$.none||$.books[0].name", &data, vec!["甲"]),
        (
            "$.books[?(@.price >= 8 && @.price < 12)].name",
            &data,
            vec!["乙"],
        ),
        ("$.books[-1].name", &data, vec!["丙"]),
        (r"##(?<=甲)\d+##号", &text, vec!["甲号乙34"]),
        (r"##(\d+)##[$1]", &text, vec!["甲[12]乙[34]"]),
        (r"##(\d+)##$1###", &text, vec!["12"]),
        ("##甲##名#", &text, vec!["名#12乙34"]),
    ];
    engine().run(|scope| {
        for (rule, input, expected) in cases {
            assert_eq!(scope.get_strings_on(rule, input), expected, "规则：{rule}");
        }
        scope.set_content(html.clone(), None);
        let reversed = scope.get_elements("-li");
        assert_eq!(scope.get_string_on("text", &reversed[0]), "丁");
        assert_eq!(scope.get_string_on("text", &reversed[3]), "甲");
    });
}

#[test]
fn semantic_matrix_template_delimiters_are_data_not_rule_operators() {
    engine().run(|scope| {
        let input = Node::page("<p>甲</p>");
        for (rule, expected) in [
            (r#"{{ '}}'.length }}"#, "2"),
            (r#"{{ /}}/.test('}}') ? '好' : '坏' }}"#, "好"),
            (r#"{{ (/* }} */ '好') }}"#, "好"),
            (r#"{{ `字${({x:'}}'}).x.length}` }}"#, "字2"),
            (r#"{{ '甲##乙' }}"#, "甲##乙"),
            (r#"{{ '甲##乙' }}##乙##丙#"#, "甲##丙#"),
            (r#"{{ '' }}##甲##乙"#, ""),
            (r#"{{@@p@text}}##甲##乙"#, "乙"),
            (
                r#"{{ (java.put('times', Number(java.get('times')||0)+1), '甲') }}##甲##乙"#,
                "乙",
            ),
        ] {
            assert_eq!(scope.get_string_on(rule, &input), expected, "规则：{rule}");
        }
        assert_eq!(
            scope.get_string_on("@get:{times}", &input),
            "1",
            "模板只执行一次"
        );
        for (template, expected) in [
            ("{{ '}}'.length }}", "2"),
            ("{{ /}}/.test('}}') ? 'yes' : 'no' }}", "yes"),
            ("{{ (/* }} */ 'ok') }}", "ok"),
            ("{{ `x${({x:'}}'}).x.length}` }}", "x2"),
        ] {
            assert_eq!(
                scope
                    .analyze_url(&format!("https://example.invalid/{template}"))
                    .unwrap()
                    .request
                    .url,
                format!("https://example.invalid/{expected}")
            );
        }
        let selector = Node::page("<p data-tag='a##b'>匹配</p>");
        assert_eq!(
            scope.get_string_on("p[data-tag='a##b']@text", &selector),
            "匹配"
        );
    });
}

#[test]
fn semantic_matrix_dom_getters_relative_urls_and_variable_isolation() {
    let input = Node::page(
        "<div id='c'>甲<b>乙</b>丙<br>丁<script>ignored()</script><style>b{}</style></div><a href='../chapter/2'>第二章</a>",
    );
    engine().run(|scope| {
        for (getter, expected) in [
            ("text", "甲乙丙 丁"),
            ("ownText", "甲丙 丁"),
            ("textNodes", "甲\n丙\n丁"),
        ] {
            assert_eq!(
                scope.get_string_on(&format!("#c@{getter}"), &input),
                expected,
                "{getter}"
            );
        }
        let cleaned = scope.get_string_on("#c@html", &input);
        let all = scope.get_string_on("#c@all", &input);
        assert!(
            cleaned.starts_with("<div")
                && cleaned.contains("<b>乙</b>")
                && !cleaned.contains("<script")
                && !cleaned.contains("<style")
        );
        assert!(all.contains("<script>ignored()</script>") && all.contains("<style>b{}</style>"));
        scope.set_content(
            input.clone(),
            Some("https://example.invalid/books/index.html"),
        );
        assert_eq!(
            scope
                .eval_js_string("java.getString('a@href', undefined, true)", &[])
                .unwrap(),
            "https://example.invalid/chapter/2"
        );
        assert_eq!(
            scope.get_string_on("a@text@put:{saved:'a@href'}", &input),
            "第二章"
        );
        assert_eq!(
            scope.get_string_on("@get:{saved}", &Node::Text("另一次取值".into())),
            "../chapter/2"
        );
    });
    engine().run(|scope| {
        assert_eq!(
            scope.get_string_on("@get:{saved}", &input),
            "",
            "不同源运行时不串变量"
        )
    });
}

#[test]
fn semantic_matrix_toc_cycle_stops_and_preserves_first_seen_order() {
    let (base, requests) = crate::tests::serve(|request| match request.path.as_str() {
        "/one" => crate::tests::html(
            "<li><a href='/c1'>第一章</a></li><a class='next' href='/two'>后页</a><a class='next' href='/two'>重复</a>",
        ),
        "/two" => crate::tests::html(
            "<li><a href='/c1'>第一章</a></li><li><a href='/c2'>第二章</a></li><a class='next' href='/one'>回环</a>",
        ),
        _ => panic!("不应请求其他页面"),
    });
    let source: BookSource = serde_json::from_value(json!({"bookSourceUrl":base,
        "ruleToc":{"chapterList":"li","chapterName":"a@text","chapterUrl":"a@href","nextTocUrl":"a.next@href"}})).unwrap();
    Engine::new(SourceRt::new(source)).unwrap().run(|scope| {
        let book = crate::webbook::Book {
            toc_url: format!("{base}/one"),
            ..Default::default()
        };
        let toc = scope.toc(&book).unwrap();
        assert_eq!(
            toc.iter().map(|c| c.title.as_str()).collect::<Vec<_>>(),
            ["第一章", "第二章"]
        );
    });
    assert_eq!(requests.lock().unwrap().len(), 2);
}
