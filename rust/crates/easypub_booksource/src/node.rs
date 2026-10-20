//! 规则之间传递的值：整页、页内元素、JSON、纯文本、整段正则的一次匹配。
//!
//! 元素引用同一份解析好的文档（不重新解析外层 HTML：`<tr>`、`<td>` 单独解析会被丢掉）。
//! 文档用 `Rc`，所以值只在一个线程里流转；下载时每个线程有自己的引擎。
use ego_tree::NodeId;
use scraper::{ElementRef, Html};
use serde_json::Value;
use std::rc::Rc;

pub struct Document {
    pub html: Html,
    pub source: String,
}

#[derive(Clone)]
pub enum Node {
    Doc(Rc<Document>),
    Elem(Rc<Document>, NodeId),
    Json(Value),
    /// 整页是 JSON：JS 里的 result / src 是原文（与阅读一致），JSONPath 用解析好的值。
    JsonPage(Rc<str>, Rc<Value>),
    Text(String),
    /// 整段正则（`:` 开头）的一次匹配：下标 0 是整段，之后是各分组。
    Groups(Rc<Vec<String>>),
}

impl std::fmt::Debug for Node {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Doc(_) => f.write_str("Doc"),
            Self::Elem(..) => write!(
                f,
                "Elem({})",
                self.text().chars().take(60).collect::<String>()
            ),
            Self::Json(v) => write!(f, "Json({v})"),
            Self::JsonPage(raw, _) => {
                write!(f, "JsonPage({})", raw.chars().take(60).collect::<String>())
            }
            Self::Text(s) => write!(f, "Text({s:?})"),
            Self::Groups(g) => write!(f, "Groups({g:?})"),
        }
    }
}

impl Node {
    /// 网页响应：能解析成 JSON 对象或数组的按 JSON，否则按 HTML。
    pub fn page(text: impl Into<String>) -> Self {
        let text = text.into();
        let trimmed = text.trim_start_matches('\u{feff}').trim();
        if ((trimmed.starts_with('{') && trimmed.ends_with('}'))
            || (trimmed.starts_with('[') && trimmed.ends_with(']')))
            && let Ok(value) = serde_json::from_str::<Value>(trimmed)
        {
            return Self::JsonPage(Rc::from(text.as_str()), Rc::new(value));
        }
        Self::Doc(Rc::new(Document {
            html: Html::parse_document(&text),
            source: text,
        }))
    }
    pub fn is_json(&self) -> bool {
        matches!(self, Self::Json(_) | Self::JsonPage(..))
    }
    /// HTML 类值的文档与起点元素；其他值按页面重新解析。
    pub fn element(&self) -> Option<(Rc<Document>, NodeId)> {
        match self {
            Self::Doc(d) => Some((d.clone(), d.html.root_element().id())),
            Self::Elem(d, id) => Some((d.clone(), *id)),
            Self::Text(s) => Self::page(s.clone()).element(),
            Self::Groups(g) => Self::page(g.first().cloned().unwrap_or_default()).element(),
            Self::Json(Value::String(s)) => Self::page(s.clone()).element(),
            Self::Json(_) | Self::JsonPage(..) => None,
        }
    }
    /// 作为字符串结果时的文字：整页为原文，元素为外层 HTML。
    pub fn text(&self) -> String {
        match self {
            Self::Doc(d) => d.source.clone(),
            Self::Elem(d, id) => d
                .html
                .tree
                .get(*id)
                .and_then(ElementRef::wrap)
                .map(|e| e.html())
                .unwrap_or_default(),
            Self::Json(Value::String(s)) => s.clone(),
            Self::Json(Value::Null) => String::new(),
            Self::Json(v) => v.to_string(),
            Self::JsonPage(raw, _) => raw.to_string(),
            Self::Text(s) => s.clone(),
            Self::Groups(g) => g.first().cloned().unwrap_or_default(),
        }
    }
    /// 文字结果作为下一段规则的输入时重新识别为 JSON 或页面。
    pub fn reparse(self) -> Self {
        match self {
            Self::Text(s) => Self::page(s),
            Self::Json(Value::String(s)) => Self::page(s),
            other => other,
        }
    }
}
