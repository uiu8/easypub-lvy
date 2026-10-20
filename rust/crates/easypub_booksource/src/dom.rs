//! 元素的文字与取值，按阅读（Jsoup）的含义：
//! `text` 为去掉多余空白的全部文字（块级元素、换行之间留一个空格），
//! `ownText` 只取自身的文字节点，`textNodes` 为自身文字节点逐行，
//! `html` 为去掉 script / style 的外层 HTML，`all` 为原样外层 HTML，其余为属性。
use crate::node::Document;
use ego_tree::{NodeId, NodeRef};
use scraper::{ElementRef, Node as DomNode};

const BLOCK: &[&str] = &[
    "address",
    "article",
    "aside",
    "blockquote",
    "br",
    "dd",
    "div",
    "dl",
    "dt",
    "fieldset",
    "figcaption",
    "figure",
    "footer",
    "form",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "header",
    "hr",
    "li",
    "main",
    "nav",
    "ol",
    "p",
    "pre",
    "section",
    "table",
    "tbody",
    "td",
    "tfoot",
    "th",
    "thead",
    "tr",
    "ul",
];

pub fn element(doc: &Document, id: NodeId) -> Option<ElementRef<'_>> {
    doc.html.tree.get(id).and_then(ElementRef::wrap)
}

pub fn normalize(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

pub fn text(node: NodeRef<'_, DomNode>) -> String {
    fn walk(node: NodeRef<'_, DomNode>, out: &mut String) {
        for child in node.children() {
            match child.value() {
                DomNode::Text(t) => out.push_str(t),
                DomNode::Element(e) => {
                    let name = e.name();
                    if matches!(name, "script" | "style") {
                        continue;
                    }
                    let block = BLOCK.contains(&name);
                    if block {
                        out.push(' ');
                    }
                    walk(child, out);
                    if block {
                        out.push(' ');
                    }
                }
                _ => (),
            }
        }
    }
    let mut out = String::new();
    if let DomNode::Text(t) = node.value() {
        out.push_str(t);
    }
    walk(node, &mut out);
    normalize(&out)
}

fn own_texts(node: NodeRef<'_, DomNode>) -> Vec<String> {
    node.children()
        .filter_map(|n| n.value().as_text().map(|t| t.trim().to_owned()))
        .filter(|s| !s.is_empty())
        .collect()
}

pub fn own_text(node: NodeRef<'_, DomNode>) -> String {
    normalize(&own_texts(node).join(" "))
}

pub fn text_nodes(node: NodeRef<'_, DomNode>) -> String {
    own_texts(node).join("\n")
}

pub fn clean_html(element: ElementRef<'_>) -> String {
    let html = element.html();
    if !html.contains("<script") && !html.contains("<style") {
        return html;
    }
    let mut fragment = scraper::Html::parse_fragment(&html);
    let selector = scraper::Selector::parse("script,style").unwrap();
    let ids: Vec<_> = fragment.select(&selector).map(|n| n.id()).collect();
    for id in ids {
        if let Some(mut node) = fragment.tree.get_mut(id) {
            node.detach();
        }
    }
    fragment.root_element().inner_html()
}

/// 规则末段的取值。没有该属性时为空串。
pub fn value(doc: &Document, id: NodeId, getter: &str) -> String {
    let Some(node) = doc.html.tree.get(id) else {
        return String::new();
    };
    match getter {
        "text" => text(node),
        "textNodes" => text_nodes(node),
        "ownText" | "oweText" => own_text(node),
        "html" => ElementRef::wrap(node).map(clean_html).unwrap_or_default(),
        "all" | "outerHtml" => ElementRef::wrap(node).map(|e| e.html()).unwrap_or_default(),
        attr => {
            let attr = attr.strip_prefix("abs:").unwrap_or(attr);
            node.value()
                .as_element()
                .and_then(|e| e.attr(attr))
                .unwrap_or("")
                .to_owned()
        }
    }
}
