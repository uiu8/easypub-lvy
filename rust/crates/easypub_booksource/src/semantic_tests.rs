//! V102 C：根据公开规则说明自拟数据，经过真实 QuickJS/规则引擎，不访问真实站点。
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
