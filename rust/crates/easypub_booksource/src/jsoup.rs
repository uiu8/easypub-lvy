//! 阅读的默认规则（`@@` 或不加前缀）与 `@css:` 规则。
//!
//! 默认规则按 `@` 分段，每段为 `类型.名称.位置`：类型有 `class`、`id`、`tag`、`text`、`children`，
//! 不是这几种时整段按 CSS 选择器；位置可写 `.N`、`.-N`、`!N`（排除）、旧式 `.1:2:3`（列表），
//! 或方括号 `[N,M]`、`[!N]`、`[起:止:步长]`。字符串规则的最后一段是取值（见 `dom::value`）。
//! 选择包含起点元素本身（与 Jsoup 相同），位置按每个起点元素各自计算。
use crate::{
    dom,
    node::{Document, Node},
};
use ego_tree::NodeId;
use scraper::{ElementRef, Selector};
use std::{
    cell::RefCell,
    collections::{BTreeSet, HashMap},
    rc::Rc,
};

pub const LIMIT: usize = 50_000;

struct Step {
    kind: Kind,
    indexes: Option<Indexes>,
}
enum Kind {
    Children,
    Css(Selector),
    /// Jsoup 专有写法（`:contains`、`[属性~=正则]` 等）。
    Own(std::rc::Rc<crate::jcss::Selector2>),
    /// `text.文字`：自身文字含该文字的元素。
    Contains(String),
    Invalid,
}
pub struct Indexes {
    exclude: bool,
    spans: Vec<Vec<Option<isize>>>,
}
struct Parsed {
    steps: Vec<Step>,
    getter: Option<String>,
}

thread_local! {
    static CACHE: RefCell<HashMap<(String, bool), Rc<Parsed>>> = RefCell::new(HashMap::new());
}

fn parsed(rule: &str, list: bool) -> Rc<Parsed> {
    let key = (rule.to_owned(), list);
    if let Some(hit) = CACHE.with(|c| c.borrow().get(&key).cloned()) {
        return hit;
    }
    let value = Rc::new(parse(rule, list));
    CACHE.with(|c| {
        let mut c = c.borrow_mut();
        if c.len() > 4096 {
            c.clear();
        }
        c.insert(key, value.clone());
    });
    value
}

fn parse(rule: &str, list: bool) -> Parsed {
    let rule = rule.trim();
    let (css, body) = match rule.get(..5) {
        Some(p) if p.eq_ignore_ascii_case("@css:") => (true, rule[5..].trim()),
        _ => (false, rule.trim_start_matches("@@").trim()),
    };
    if css {
        // CSS 规则：最后一个 @ 之后是取值，前面整体是一个选择器。
        let (selector, getter) = match (list, body.rfind('@')) {
            (false, Some(i)) => (&body[..i], Some(body[i + 1..].trim().to_owned())),
            _ => (body, None),
        };
        let steps = if selector.trim().is_empty() {
            Vec::new()
        } else {
            vec![Step {
                kind: css_kind(selector.trim()),
                indexes: None,
            }]
        };
        return Parsed { steps, getter };
    }
    let mut parts = split_at(body);
    let getter = if list {
        None
    } else {
        parts.pop().map(|s| s.trim().to_owned())
    };
    let steps = parts
        .into_iter()
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .map(step)
        .collect();
    Parsed { steps, getter }
}

/// 按 `@` 分段，方括号、圆括号与引号里的 `@` 不算。
fn split_at(text: &str) -> Vec<&str> {
    let mut parts = Vec::new();
    let (mut start, mut depth, mut quote) = (0, 0i32, None);
    for (i, c) in text.char_indices() {
        if let Some(q) = quote {
            if c == q {
                quote = None;
            }
            continue;
        }
        match c {
            '\'' | '"' => quote = Some(c),
            '[' | '(' => depth += 1,
            ']' | ')' => depth -= 1,
            '@' if depth == 0 => {
                parts.push(&text[start..i]);
                start = i + 1;
            }
            _ => (),
        }
    }
    parts.push(&text[start..]);
    parts
}

fn css_kind(selector: &str) -> Kind {
    if crate::jcss::needs_own(selector) {
        return crate::jcss::compiled(selector)
            .map(Kind::Own)
            .unwrap_or(Kind::Invalid);
    }
    Selector::parse(selector)
        .map(Kind::Css)
        .unwrap_or(Kind::Invalid)
}

fn quote(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

fn step(text: &str) -> Step {
    let (base, indexes) = Indexes::split(text);
    let base = base.trim();
    let kind = if base.is_empty() || base == "children" {
        Kind::Children
    } else if let Some(v) = base.strip_prefix("class.") {
        // 多个类名（以空格分开）都要有。
        let classes: Vec<_> = v
            .split_whitespace()
            .map(|c| format!("[class~=\"{}\"]", quote(c)))
            .collect();
        if classes.is_empty() {
            Kind::Invalid
        } else {
            css_kind(&classes.concat())
        }
    } else if let Some(v) = base.strip_prefix("id.") {
        css_kind(&format!("[id=\"{}\"]", quote(v)))
    } else if let Some(v) = base.strip_prefix("tag.") {
        css_kind(v)
    } else if let Some(v) = base.strip_prefix("text.") {
        Kind::Contains(v.to_owned())
    } else {
        css_kind(base)
    };
    Step { kind, indexes }
}

impl Indexes {
    /// 拆出段尾的位置写法，返回 (其余部分, 位置)。
    pub fn split(text: &str) -> (&str, Option<Self>) {
        let text = text.trim();
        if text.ends_with(']')
            && let Some(start) = text.rfind('[')
        {
            let inside = text[start + 1..text.len() - 1].trim();
            if !inside.is_empty()
                && inside
                    .chars()
                    .all(|c| c.is_ascii_digit() || " ,:!-".contains(c))
            {
                let exclude = inside.starts_with('!');
                let spans = inside
                    .trim_start_matches('!')
                    .split(',')
                    .map(|span| {
                        span.split(':')
                            .map(|n| n.trim().parse::<isize>().ok())
                            .collect::<Vec<_>>()
                    })
                    .filter(|p| !p.is_empty() && p.len() <= 3 && *p != [None])
                    .collect::<Vec<_>>();
                if !spans.is_empty() {
                    return (&text[..start], Some(Self { exclude, spans }));
                }
            }
        }
        for (i, c) in text.char_indices().rev() {
            if c != '.' && c != '!' {
                continue;
            }
            let rest = &text[i + 1..];
            if rest.is_empty()
                || !rest
                    .chars()
                    .all(|c| c.is_ascii_digit() || c == ':' || c == '-')
            {
                break;
            }
            // 旧式 `.1:2:3` 是位置列表（不是区间）。
            let spans: Option<Vec<_>> = rest
                .split(':')
                .map(|n| n.parse::<isize>().ok().map(|v| vec![Some(v)]))
                .collect();
            if let Some(spans) = spans {
                return (
                    &text[..i],
                    Some(Self {
                        exclude: c == '!',
                        spans,
                    }),
                );
            }
            break;
        }
        (text, None)
    }

    pub fn select<T: Copy>(&self, items: Vec<T>) -> Vec<T> {
        let len = items.len() as isize;
        if len == 0 {
            return items;
        }
        let normal = |n: isize| if n < 0 { n + len } else { n };
        let mut positions = Vec::new();
        for span in &self.spans {
            if span.len() == 1 {
                let i = normal(span[0].unwrap_or(0));
                if (0..len).contains(&i) {
                    positions.push(i);
                }
                continue;
            }
            let start = normal(span[0].unwrap_or(0));
            let end = normal(span[1].unwrap_or(-1));
            if (start < 0 && end < 0) || (start >= len && end >= len) {
                continue;
            }
            let (mut i, end) = (start.clamp(0, len - 1), end.clamp(0, len - 1));
            let step = span.get(2).copied().flatten().unwrap_or(1);
            let step = if step > 0 { step } else { (len + step).max(1) };
            let direction = if i <= end { 1 } else { -1 };
            while (direction == 1 && i <= end) || (direction == -1 && i >= end) {
                positions.push(i);
                i += step * direction;
            }
        }
        let mut seen = BTreeSet::new();
        positions.retain(|i| seen.insert(*i));
        if self.exclude {
            items
                .into_iter()
                .enumerate()
                .filter(|(i, _)| !seen.contains(&(*i as isize)))
                .map(|(_, v)| v)
                .collect()
        } else {
            positions.into_iter().map(|i| items[i as usize]).collect()
        }
    }
}

fn run(doc: &Document, start: NodeId, steps: &[Step]) -> Vec<NodeId> {
    let mut current = vec![start];
    for step in steps {
        let mut next = Vec::new();
        for id in current {
            let Some(node) = doc.html.tree.get(id) else {
                continue;
            };
            let mut found: Vec<NodeId> = match &step.kind {
                Kind::Invalid => Vec::new(),
                Kind::Children => node
                    .children()
                    .filter(|n| n.value().is_element())
                    .map(|n| n.id())
                    .collect(),
                Kind::Css(selector) => {
                    let Some(element) = ElementRef::wrap(node).or_else(|| {
                        // 整页起点：从根元素开始。
                        node.children().find_map(ElementRef::wrap)
                    }) else {
                        continue;
                    };
                    let mut found = Vec::new();
                    if selector.matches(&element) {
                        found.push(element.id());
                    }
                    found.extend(element.select(selector).map(|e| e.id()));
                    found
                }
                Kind::Own(sel) => crate::jcss::select(sel, &doc.html, id),
                Kind::Contains(text) => node
                    .descendants()
                    .filter(|n| n.value().is_element() && dom::own_text(*n).contains(text.as_str()))
                    .map(|n| n.id())
                    .collect(),
            };
            if let Some(indexes) = &step.indexes {
                found = indexes.select(found);
            }
            next.extend(found);
            if next.len() > LIMIT {
                break;
            }
        }
        current = next;
    }
    current
}

/// 列表规则：取元素。
pub fn elements(rule: &str, node: &Node) -> Vec<Node> {
    let Some((doc, start)) = node.element() else {
        return Vec::new();
    };
    let parsed = parsed(rule, true);
    run(&doc, start, &parsed.steps)
        .into_iter()
        .map(|id| Node::Elem(doc.clone(), id))
        .collect()
}

/// 字符串规则：每个元素一项，空值不要。
pub fn strings(rule: &str, node: &Node) -> Vec<String> {
    let Some((doc, start)) = node.element() else {
        return Vec::new();
    };
    let parsed = parsed(rule, false);
    let getter = parsed.getter.as_deref().unwrap_or("text");
    run(&doc, start, &parsed.steps)
        .into_iter()
        .map(|id| dom::value(&doc, id, getter))
        .filter(|s| !s.is_empty())
        .collect()
}
