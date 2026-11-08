use super::*;
use std::{cell::RefCell, collections::HashMap};

/// 测试用：变量存在表里；“JS”只认几种固定写法，用来检验拼接顺序。
#[derive(Default)]
struct Fake {
    vars: RefCell<HashMap<String, String>>,
}
impl Host for Fake {
    fn js(&self, code: &str, input: &[Node]) -> Vec<Node> {
        let result = input.iter().map(Node::text).collect::<Vec<_>>().join("\n");
        let out = match code.trim() {
            "result.toUpperCase()" => result.to_uppercase(),
            "'js:'+result" => format!("js:{result}"),
            "1+1" => "2".into(),
            other => format!("<{other}>"),
        };
        vec![Node::Text(out)]
    }
    fn var(&self, key: &str) -> String {
        self.vars.borrow().get(key).cloned().unwrap_or_default()
    }
    fn put_var(&self, key: &str, value: String) {
        self.vars.borrow_mut().insert(key.into(), value);
    }
}

const PAGE: &str = r#"<html><head>
<meta property="og:novel:author" content="甲作者">
<meta property="og:title" content="书名">
</head><body>
<div class="info main"><h1>标题一</h1><p class="small"><span>作者：甲</span><span>分类：玄幻</span><span>状态：连载</span></p></div>
<ul id="list">
  <li><a href="/1.html">第一章</a></li>
  <li><a href="/2.html">第二章</a></li>
  <li class="vip"><a href="/3.html">第三章</a></li>
</ul>
<table><tr><td>行一</td><td>甲</td></tr><tr><td>行二</td><td>乙</td></tr></table>
<div id="content">正文第一段<br>正文第二段<script>bad()</script><p>广告：请记住本站</p></div>
<a class="next" href="/2_2.html">下一页</a>
</body></html>"#;

fn page() -> Node {
    Node::page(PAGE)
}

#[test]
fn default_rules_follow_jsoup_semantics() {
    let h = Fake::default();
    let p = page();
    assert_eq!(string(&h, "class.info@tag.h1@text", &p), "标题一");
    assert_eq!(
        string(&h, "class.info main@h1@text", &p),
        "标题一",
        "多个类名都要有"
    );
    assert_eq!(string(&h, ".small@span.1@text", &p), "分类：玄幻");
    assert_eq!(string(&h, ".small@span.-1@text", &p), "状态：连载");
    assert_eq!(
        strings(&h, ".small@span!0@text", &p),
        ["分类：玄幻", "状态：连载"]
    );
    assert_eq!(
        strings(&h, ".small@span.0:2@text", &p),
        ["作者：甲", "状态：连载"],
        "旧式冒号是位置列表"
    );
    assert_eq!(
        strings(&h, ".small@span[0:1]@text", &p),
        ["作者：甲", "分类：玄幻"],
        "方括号冒号是区间"
    );
    assert_eq!(string(&h, "id.list@li.-1@a@href", &p), "/3.html");
    assert_eq!(string(&h, "text.下一页@href", &p), "/2_2.html");
    assert_eq!(string(&h, "[property$=author]@content", &p), "甲作者");
    assert_eq!(string(&h, "@css:#list > li.vip a@href", &p), "/3.html");
    assert_eq!(
        string(&h, "id.content@textNodes", &p),
        "正文第一段\n正文第二段"
    );
    assert!(
        !string(&h, "id.content@html", &p).contains("bad()"),
        "html 去掉 script"
    );
    assert_eq!(elements(&h, "id.list@li", &p).len(), 3);
    assert_eq!(elements(&h, "id.list@children", &p).len(), 3);
    let items = elements(&h, "-id.list@li", &p);
    assert_eq!(string(&h, "a@text", &items[0]), "第三章", "开头 - 倒序");
    assert_eq!(
        string(&h, "text", &items[2]),
        "第一章",
        "单段取值作用于元素自身"
    );
}

#[test]
fn xpath_subset() {
    let h = Fake::default();
    let p = page();
    assert_eq!(string(&h, "//*[@property='og:title']/@content", &p), "书名");
    assert_eq!(
        strings(&h, "//ul[@id=\"list\"]/li/a/text()", &p),
        ["第一章", "第二章", "第三章"]
    );
    assert_eq!(string(&h, "//ul/li[last()]/a/@href", &p), "/3.html");
    assert_eq!(
        strings(
            &h,
            "//ul/li[position() >= 2 and position() < last()]/a/text()",
            &p
        ),
        ["第二章"]
    );
    assert_eq!(
        string(
            &h,
            "//li[@class='vip']/preceding-sibling::li[1]/a/text()",
            &p
        ),
        "第二章"
    );
    assert_eq!(string(&h, "//a[text()=\"下一页\"]/@href", &p), "/2_2.html");
    assert_eq!(
        string(
            &h,
            "//div[contains(@class,'info') and contains(@class, 'main')]/h1/text()",
            &p
        ),
        "标题一"
    );
    assert_eq!(
        strings(&h, "//li[not(@class='vip')]/a/text()", &p),
        ["第一章", "第二章"]
    );
    let rows = elements(&h, "//table//tr", &p);
    assert_eq!(rows.len(), 2, "tr 不能因重新解析丢失");
    assert_eq!(string(&h, "td.1@text", &rows[1]), "乙");
    assert_eq!(
        string(&h, "//td[2]/text()", &rows[0]),
        "甲",
        "阅读的 XPath 以当前元素为根"
    );
    assert_eq!(
        string(&h, "//h1[(contains (.,'标题'))]/text()", &p),
        "标题一"
    );
}

#[test]
fn json_rules() {
    let h = Fake::default();
    let j = Node::page(
        r#"{"data":{"list":[{"name":"甲","id":1,"tags":["a","b"]},{"name":"乙","id":2,"tags":[]}]},"total":2}"#,
    );
    assert_eq!(elements(&h, "$.data.list[*]", &j).len(), 2);
    assert_eq!(
        elements(&h, "$.[*]", &Node::page("[1,2,3]")).len(),
        3,
        "点后直接方括号"
    );
    assert_eq!(elements(&h, "$.data.list", &j).len(), 2, "数组展开");
    let items = elements(&h, "$.data.list", &j);
    assert_eq!(string(&h, "name", &items[0]), "甲", "JSON 内容里的裸字段");
    assert_eq!(string(&h, "$.tags", &items[0]), "a\nb");
    assert_eq!(
        string(&h, "https://x/{$.id}.html", &items[1]),
        "https://x/2.html",
        "JSON 内容里的单花括号模板"
    );
    assert_eq!(
        string(&h, "@json:https://x/{$.id}.html", &items[1]),
        "https://x/2.html"
    );
    assert_eq!(string(&h, "$..name", &j), "甲\n乙");
    assert_eq!(string(&h, "$.data.list[?(@.id == 2)].name", &j), "乙");
    assert_eq!(string(&h, "$.data.list[-1].name", &j), "乙");
    assert_eq!(string(&h, "$.total&&$.data.list[0].name", &j), "2\n甲");
}

#[test]
fn combinators_and_purification() {
    let h = Fake::default();
    let p = page();
    assert_eq!(
        string(&h, "class.nothing@text||.small@span.0@text", &p),
        "作者：甲"
    );
    assert_eq!(
        string(
            &h,
            ".small@span.1@text&&.small@span.2@text##分类：|状态：",
            &p
        ),
        "玄幻\n连载"
    );
    assert_eq!(
        strings(&h, "id.list@li.0@text%%id.list@li.1@text", &p),
        ["第一章", "第二章"]
    );
    assert_eq!(
        string(&h, ".small@span.0@text##作者：(.+)##$1###", &p),
        "甲",
        "### 只取第一个匹配"
    );
    assert_eq!(string(&h, ".small@span.0@text##作者：##", &p), "甲");
    assert_eq!(
        string(&h, "id.content@text##广告.*", &p).trim(),
        "正文第一段 正文第二段"
    );
}

#[test]
fn put_get_templates_and_js_segments() {
    let h = Fake::default();
    let p = page();
    assert_eq!(
        string(
            &h,
            ".small@span.0@text@put:{who:\".small@span.1@text\"}",
            &p
        ),
        "作者：甲"
    );
    assert_eq!(h.var("who"), "分类：玄幻");
    assert_eq!(string(&h, "@get:{who}", &p), "分类：玄幻");
    assert_eq!(
        string(&h, "{{@@.small@span.0@text}}|{{//h1/text()}}|{{1+1}}", &p),
        "作者：甲|标题一|2"
    );
    assert_eq!(
        string(&h, "class.info@h1@text@js:result.toUpperCase()", &p),
        "标题一"
    );
    assert_eq!(
        string(&h, "class.info@h1@text<js>'js:'+result</js>", &p),
        "js:标题一"
    );
    let j = Node::page(r#"{"bid":9}"#);
    assert_eq!(string(&h, "$.bid@put:{b:$.bid}", &j), "9");
    assert_eq!(h.var("b"), "9");
}

#[test]
fn all_in_one_regex_lists() {
    let h = Fake::default();
    let p = page();
    let items = elements(&h, r#":href="(/\d)\.html">([^<]+)<"#, &p);
    assert_eq!(items.len(), 3);
    assert_eq!(string(&h, "$2", &items[1]), "第二章");
    assert_eq!(
        string(&h, "https://a.com$1.html", &items[0]),
        "https://a.com/1.html"
    );
}

#[test]
fn debug_put_parse() {
    let (puts, rest) = take_puts(".small@span.0@text@put:{who:\".small@span.1@text\"}");
    assert_eq!(rest, ".small@span.0@text");
    assert_eq!(
        puts,
        vec![("who".to_string(), ".small@span.1@text".to_string())]
    );
}

#[test]
fn purification_after_js_segment() {
    let h = Fake::default();
    let p = page();
    assert_eq!(
        string(
            &h,
            "class.info@h1@text\n@js:result.toUpperCase()\n##标题(.)##第$1",
            &p
        ),
        "第一",
        "@js: 后另起一行的 ## 对脚本结果净化"
    );
}

#[test]
fn templated_purification_applies_to_input() {
    let h = Fake::default();
    let input = Node::Text("第一章 2 内容".into());
    assert_eq!(
        string(&h, "##第.章|{{1+1}}", &input),
        "  内容",
        "模板展开后对输入文字净化"
    );
}
