//! 阅读书源里的 Jsoup 选择器写法（标准 CSS 之外的部分）：
//! `:contains(文字)` `:containsOwn` `:matches(正则)` `:matchesOwn` `:containsData`
//! `:eq(n)` `:lt(n)` `:gt(n)`（同级序号）、`:has(选择器)` `:not(选择器列表)` `:is()`、
//! `[属性~=正则]`（Jsoup 里 `~=` 是正则）、`[^属性前缀]`、`[属性!=值]`，以及常用的标准写法
//! （标签、`#id`、`.class`、属性、`> + ~` 与后代、`:first-child` `:last-child` `:nth-child()` 等）。
//! 标准写法优先交给 scraper；它不认识或语义不同（`~=`）时用这里的实现。
use crate::{dom, pattern};
use ego_tree::{NodeId, NodeRef};
use scraper::{ElementRef, Html, Node as DomNode, Selector};
use std::{cell::RefCell, collections::HashMap, rc::Rc, sync::Arc};

#[derive(Debug, Clone, Copy, PartialEq)]
enum Comb {
    Descendant,
    Child,
    Adjacent,
    Sibling,
}

#[derive(Clone)]
enum Cond {
    Id(String),
    Class(String),
    Attr {
        name: String,
        prefix: bool,
        op: String,
        value: String,
        regex: Option<Arc<pattern::Pattern>>,
    },
    Contains(String, bool),
    Matches(Arc<pattern::Pattern>, bool),
    ContainsData(String),
    Eq(i64),
    Lt(i64),
    Gt(i64),
    Has(Rc<Selector2>),
    Not(Rc<Selector2>),
    Is(Rc<Selector2>),
    Nth {
        a: i64,
        b: i64,
        last: bool,
        of_type: bool,
    },
    OnlyChild,
    Empty,
    Root,
}

#[derive(Clone, Default)]
struct Compound {
    tag: Option<String>,
    conds: Vec<Cond>,
}

/// 逗号分开的若干组；每组从左到右为 (与前一段的关系, 本段)。
pub struct Selector2 {
    groups: Vec<Vec<(Comb, Compound)>>,
}

struct Parser<'a> {
    s: &'a [char],
    i: usize,
}

impl Parser<'_> {
    fn peek(&self) -> Option<char> {
        self.s.get(self.i).copied()
    }
    fn ws(&mut self) -> bool {
        let start = self.i;
        while self.peek().is_some_and(char::is_whitespace) {
            self.i += 1;
        }
        self.i > start
    }
    fn ident(&mut self) -> String {
        let start = self.i;
        while self
            .peek()
            .is_some_and(|c| c.is_alphanumeric() || matches!(c, '-' | '_' | '\\'))
        {
            self.i += 1;
        }
        self.s[start..self.i].iter().collect()
    }
    /// 括号里的原文（支持嵌套与引号）。
    fn paren(&mut self) -> Option<String> {
        if self.peek() != Some('(') {
            return None;
        }
        self.i += 1;
        let start = self.i;
        let (mut depth, mut quote) = (1, None);
        while let Some(c) = self.peek() {
            if let Some(q) = quote {
                if c == '\\' {
                    self.i += 1;
                } else if c == q {
                    quote = None;
                }
            } else if c == '"' || c == '\'' {
                quote = Some(c);
            } else if c == '(' {
                depth += 1;
            } else if c == ')' {
                depth -= 1;
                if depth == 0 {
                    let text: String = self.s[start..self.i].iter().collect();
                    self.i += 1;
                    return Some(text);
                }
            }
            self.i += 1;
        }
        None
    }

    fn selector(&mut self) -> Option<Selector2> {
        let mut groups = vec![self.complex()?];
        loop {
            self.ws();
            if self.peek() == Some(',') {
                self.i += 1;
                groups.push(self.complex()?);
            } else {
                break;
            }
        }
        Some(Selector2 { groups })
    }

    fn complex(&mut self) -> Option<Vec<(Comb, Compound)>> {
        let mut parts = Vec::new();
        let mut comb = Comb::Descendant;
        self.ws();
        // 以组合符开头（如 `:has(> p)`）：相对上下文。
        if let Some(first) = match self.peek() {
            Some('>') => Some(Comb::Child),
            Some('+') => Some(Comb::Adjacent),
            Some('~') => Some(Comb::Sibling),
            _ => None,
        } {
            comb = first;
            self.i += 1;
            self.ws();
        }
        loop {
            let compound = self.compound()?;
            parts.push((comb, compound));
            let had_ws = self.ws();
            comb = match self.peek() {
                Some('>') => Comb::Child,
                Some('+') => Comb::Adjacent,
                Some('~') => Comb::Sibling,
                Some(',') | Some(')') | None => break,
                _ if had_ws => {
                    comb = Comb::Descendant;
                    continue;
                }
                _ => return None,
            };
            self.i += 1;
            self.ws();
        }
        (!parts.is_empty()).then_some(parts)
    }

    fn compound(&mut self) -> Option<Compound> {
        let mut c = Compound::default();
        if self.peek() == Some('*') {
            self.i += 1;
        } else if self.peek().is_some_and(|ch| ch.is_alphanumeric()) {
            c.tag = Some(self.ident().to_ascii_lowercase());
        }
        loop {
            match self.peek() {
                Some('#') => {
                    self.i += 1;
                    c.conds.push(Cond::Id(self.ident()));
                }
                Some('.') => {
                    self.i += 1;
                    c.conds.push(Cond::Class(self.ident()));
                }
                Some('[') => {
                    self.i += 1;
                    c.conds.push(self.attr()?);
                }
                Some(':') => {
                    self.i += 1;
                    c.conds.push(self.pseudo()?);
                }
                _ => break,
            }
        }
        (c.tag.is_some() || !c.conds.is_empty() || self.s.get(self.i.wrapping_sub(1)) == Some(&'*'))
            .then_some(c)
    }

    fn attr(&mut self) -> Option<Cond> {
        self.ws();
        let prefix = self.peek() == Some('^');
        if prefix {
            self.i += 1;
        }
        let name = self.ident().to_ascii_lowercase();
        self.ws();
        let mut op = String::new();
        while let Some(c) = self.peek() {
            if matches!(c, '=' | '~' | '^' | '$' | '*' | '!' | '|') {
                op.push(c);
                self.i += 1;
                // 运算符到 = 为止（之后的 ^、$ 属于值，如正则 `^#`）。
                if c == '=' {
                    break;
                }
            } else {
                break;
            }
        }
        self.ws();
        let mut value = String::new();
        if let Some(q @ ('"' | '\'')) = self.peek() {
            self.i += 1;
            while let Some(c) = self.peek() {
                self.i += 1;
                if c == q {
                    break;
                }
                value.push(c);
            }
        } else {
            // 不加引号的值（正则里可能有方括号）：到配对的 ] 为止。
            let mut depth = 0;
            while let Some(c) = self.peek() {
                if c == '[' {
                    depth += 1;
                } else if c == ']' {
                    if depth == 0 {
                        break;
                    }
                    depth -= 1;
                }
                value.push(c);
                self.i += 1;
            }
            value = value.trim().to_owned();
        }
        self.ws();
        if self.peek() != Some(']') {
            return None;
        }
        self.i += 1;
        let regex = if op == "~=" {
            Some(pattern::compile(&value)?)
        } else {
            None
        };
        Some(Cond::Attr {
            name,
            prefix,
            op,
            value,
            regex,
        })
    }

    fn pseudo(&mut self) -> Option<Cond> {
        let name = self.ident().to_ascii_lowercase();
        let arg = self.paren();
        let text = || {
            arg.clone()
                .unwrap_or_default()
                .trim()
                .trim_matches(['"', '\''])
                .to_owned()
        };
        let num = || arg.as_deref().unwrap_or("").trim().parse::<i64>().ok();
        let sub = || parse(arg.as_deref().unwrap_or("")).map(Rc::new);
        Some(match name.as_str() {
            "contains" => Cond::Contains(text().to_lowercase(), false),
            "containsown" => Cond::Contains(text().to_lowercase(), true),
            "matches" => Cond::Matches(pattern::compile(&text())?, false),
            "matchesown" => Cond::Matches(pattern::compile(&text())?, true),
            "containsdata" => Cond::ContainsData(text()),
            "eq" => Cond::Eq(num()?),
            "lt" => Cond::Lt(num()?),
            "gt" => Cond::Gt(num()?),
            "has" => Cond::Has(sub()?),
            "not" => Cond::Not(sub()?),
            "is" | "matches-any" | "where" => Cond::Is(sub()?),
            "first-child" => Cond::Nth {
                a: 0,
                b: 1,
                last: false,
                of_type: false,
            },
            "last-child" => Cond::Nth {
                a: 0,
                b: 1,
                last: true,
                of_type: false,
            },
            "first-of-type" => Cond::Nth {
                a: 0,
                b: 1,
                last: false,
                of_type: true,
            },
            "last-of-type" => Cond::Nth {
                a: 0,
                b: 1,
                last: true,
                of_type: true,
            },
            "only-child" => Cond::OnlyChild,
            "empty" => Cond::Empty,
            "root" => Cond::Root,
            "nth-child" | "nth-last-child" | "nth-of-type" | "nth-last-of-type" => {
                let (a, b) = nth(arg.as_deref()?)?;
                Cond::Nth {
                    a,
                    b,
                    last: name.contains("last"),
                    of_type: name.contains("type"),
                }
            }
            _ => return None,
        })
    }
}

fn nth(text: &str) -> Option<(i64, i64)> {
    let t = text.trim().to_ascii_lowercase().replace(' ', "");
    match t.as_str() {
        "odd" => return Some((2, 1)),
        "even" => return Some((2, 0)),
        _ => (),
    }
    if let Some((a, b)) = t.split_once('n') {
        let a = match a {
            "" | "+" => 1,
            "-" => -1,
            x => x.parse().ok()?,
        };
        let b = if b.is_empty() { 0 } else { b.parse().ok()? };
        Some((a, b))
    } else {
        Some((0, t.parse().ok()?))
    }
}

pub fn parse(text: &str) -> Option<Selector2> {
    let chars: Vec<char> = text.chars().collect();
    let mut p = Parser { s: &chars, i: 0 };
    let sel = p.selector()?;
    p.ws();
    (p.i == chars.len()).then_some(sel)
}

fn element_children<'a>(node: NodeRef<'a, DomNode>) -> impl Iterator<Item = NodeRef<'a, DomNode>> {
    node.children().filter(|n| n.value().is_element())
}

fn matches_compound(node: NodeRef<'_, DomNode>, c: &Compound) -> bool {
    let Some(el) = node.value().as_element() else {
        return false;
    };
    if let Some(tag) = &c.tag
        && el.name() != tag
    {
        return false;
    }
    c.conds.iter().all(|cond| match cond {
        Cond::Id(id) => el.id() == Some(id.as_str()),
        Cond::Class(class) => el.classes().any(|x| x == class),
        Cond::Attr {
            name,
            prefix,
            op,
            value,
            regex,
        } => {
            let mut values = el
                .attrs()
                .filter(|(k, _)| {
                    if *prefix {
                        k.starts_with(name.as_str())
                    } else {
                        k.eq_ignore_ascii_case(name)
                    }
                })
                .map(|(_, v)| v);
            if op.is_empty() {
                return values.next().is_some();
            }
            let v = values.next();
            if op == "!=" {
                return v.is_none_or(|v| !v.eq_ignore_ascii_case(value));
            }
            let Some(v) = v else { return false };
            match op.as_str() {
                "=" => v.trim().eq_ignore_ascii_case(value),
                "^=" => v.to_lowercase().starts_with(&value.to_lowercase()),
                "$=" => v.to_lowercase().ends_with(&value.to_lowercase()),
                "*=" => v.to_lowercase().contains(&value.to_lowercase()),
                "~=" => regex.as_ref().is_some_and(|r| r.is_match(v)),
                "|=" => v == value || v.starts_with(&format!("{value}-")),
                _ => false,
            }
        }
        Cond::Contains(text, own) => {
            #[cfg(test)]
            if crate::corpus::broken(1) {
                return false;
            }
            let t = if *own {
                dom::own_text(node)
            } else {
                dom::text(node)
            };
            t.to_lowercase().contains(text)
        }
        Cond::Matches(re, own) => re.is_match(&if *own {
            dom::own_text(node)
        } else {
            dom::text(node)
        }),
        Cond::ContainsData(text) => node.descendants().any(|n| match n.value() {
            DomNode::Text(t) => {
                n.parent()
                    .and_then(|p| p.value().as_element())
                    .is_some_and(|e| matches!(e.name(), "script" | "style"))
                    && t.contains(text.as_str())
            }
            DomNode::Comment(c) => c.contains(text.as_str()),
            _ => false,
        }),
        Cond::Eq(n) | Cond::Lt(n) | Cond::Gt(n) => {
            let index = node
                .prev_siblings()
                .filter(|s| s.value().is_element())
                .count() as i64;
            match cond {
                Cond::Eq(_) => index == *n,
                Cond::Lt(_) => index < *n,
                _ => index > *n,
            }
        }
        Cond::Has(sel) => {
            // 相邻/后续兄弟关系需要搜索父节点子树，但仍以当前元素为锚点。
            let siblings = sel
                .groups
                .iter()
                .any(|p| matches!(p[0].0, Comb::Adjacent | Comb::Sibling));
            let root = if siblings {
                node.parent().unwrap_or(node)
            } else {
                node
            };
            root.descendants().any(|d| {
                sel.groups
                    .iter()
                    .any(|parts| match_from(d, parts, parts.len() - 1, Some(node.id())))
            })
        }
        Cond::Not(sel) => !sel.matches(node),
        Cond::Is(sel) => sel.matches(node),
        Cond::Nth {
            a,
            b,
            last,
            of_type,
        } => {
            let same = |s: &NodeRef<'_, DomNode>| {
                s.value()
                    .as_element()
                    .is_some_and(|e| !*of_type || e.name() == el.name())
            };
            let pos = if *last {
                node.next_siblings().filter(same).count()
            } else {
                node.prev_siblings().filter(same).count()
            } as i64
                + 1;
            if *a == 0 {
                pos == *b
            } else {
                (pos - b) % a == 0 && (pos - b) / a >= 0
            }
        }
        Cond::OnlyChild => node
            .parent()
            .is_some_and(|p| element_children(p).count() == 1),
        Cond::Empty => node.children().all(|c| {
            matches!(c.value(), DomNode::Comment(_))
                || c.value().as_text().is_some_and(|t| t.is_empty())
        }),
        Cond::Root => node.parent().is_none_or(|p| !p.value().is_element()),
    })
}

impl Selector2 {
    fn matches(&self, node: NodeRef<'_, DomNode>) -> bool {
        self.groups
            .iter()
            .any(|parts| match_from(node, parts, parts.len() - 1, None))
    }
}

fn match_from(
    node: NodeRef<'_, DomNode>,
    parts: &[(Comb, Compound)],
    i: usize,
    scope: Option<NodeId>,
) -> bool {
    let (comb, compound) = &parts[i];
    if !matches_compound(node, compound) {
        return false;
    }
    if i == 0 {
        return scope.is_none_or(|scope| match comb {
            Comb::Child => node.parent().is_some_and(|p| p.id() == scope),
            Comb::Descendant => node.ancestors().any(|p| p.id() == scope),
            Comb::Adjacent => node
                .prev_siblings()
                .find(|p| p.value().is_element())
                .is_some_and(|p| p.id() == scope),
            Comb::Sibling => node.prev_siblings().any(|p| p.id() == scope),
        });
    }
    let prev = i - 1;
    match comb {
        Comb::Child => node
            .parent()
            .is_some_and(|p| match_from(p, parts, prev, scope)),
        Comb::Descendant => node.ancestors().any(|a| match_from(a, parts, prev, scope)),
        Comb::Adjacent => node
            .prev_siblings()
            .find(|s| s.value().is_element())
            .is_some_and(|s| match_from(s, parts, prev, scope)),
        Comb::Sibling => node
            .prev_siblings()
            .filter(|s| s.value().is_element())
            .any(|s| match_from(s, parts, prev, scope)),
    }
}

thread_local! {
    static CACHE: RefCell<HashMap<String, Option<Rc<Selector2>>>> = RefCell::new(HashMap::new());
}

pub fn compiled(text: &str) -> Option<Rc<Selector2>> {
    if let Some(hit) = CACHE.with(|c| c.borrow().get(text).cloned()) {
        return hit;
    }
    let v = parse(text).map(Rc::new);
    CACHE.with(|c| {
        let mut c = c.borrow_mut();
        if c.len() > 2048 {
            c.clear();
        }
        c.insert(text.to_owned(), v.clone());
    });
    v
}

/// scraper 能正确处理的写法交给它；`~=`（Jsoup 为正则）与 Jsoup 伪类走自己的实现。
pub fn needs_own(text: &str) -> bool {
    text.contains("~=")
        || text.contains("[^")
        || text.contains("!=")
        || [
            ":contains",
            ":matches",
            ":eq(",
            ":lt(",
            ":gt(",
            ":has(",
            ":containsown",
            ":containsdata",
        ]
        .iter()
        .any(|p| text.to_ascii_lowercase().contains(p))
        || Selector::parse(text).is_err()
}

/// 在 `root` 及其后代里选（含 root 自身，同 Jsoup）。
pub fn select(sel: &Selector2, doc: &Html, root: NodeId) -> Vec<NodeId> {
    let Some(start) = doc.tree.get(root) else {
        return Vec::new();
    };
    start
        .descendants()
        .filter(|n| {
            n.value().is_element()
                && sel.groups.iter().any(|parts| {
                    let scope = (parts[0].0 != Comb::Descendant).then_some(root);
                    match_from(*n, parts, parts.len() - 1, scope)
                })
        })
        .map(|n| n.id())
        .collect()
}

/// 统一入口：返回匹配元素（文档顺序）。写法不认识时为 Err。
pub fn select_css(doc: &Html, root: NodeId, css: &str) -> Result<Vec<NodeId>, String> {
    if !needs_own(css)
        && let Ok(selector) = Selector::parse(css)
    {
        let Some(node) = doc.tree.get(root) else {
            return Ok(Vec::new());
        };
        let Some(el) =
            ElementRef::wrap(node).or_else(|| node.children().find_map(ElementRef::wrap))
        else {
            return Ok(Vec::new());
        };
        let mut out = Vec::new();
        if selector.matches(&el) {
            out.push(el.id());
        }
        out.extend(el.select(&selector).map(|e| e.id()));
        return Ok(out);
    }
    let sel = compiled(css).ok_or_else(|| format!("不支持的选择器：{css}"))?;
    Ok(select(&sel, doc, root))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn texts(html: &str, css: &str) -> Vec<String> {
        let doc = Html::parse_document(html);
        let root = doc.root_element().id();
        select_css(&doc, root, css)
            .unwrap()
            .into_iter()
            .map(|id| dom::text(doc.tree.get(id).unwrap()))
            .collect()
    }

    #[test]
    fn relative_has_anchors_combinators_to_the_candidate() {
        let html = "<main><div id='a'><p>甲</p></div><div id='b'><section><p>乙</p></section></div><div id='c'><p>丙</p></div></main>";
        assert_eq!(
            texts(html, "div:has(>:last-child:matchesOwn(^甲$))"),
            ["甲"]
        );
        assert_eq!(texts(html, "div:has(>p:matchesOwn(^乙$))").len(), 0);
        assert_eq!(texts(html, "div:has(p:matchesOwn(^乙$))"), ["乙"]);
        assert_eq!(
            texts(html, "div:has(main p:matchesOwn(^甲$))").len(),
            0,
            "不得借用锚点外的祖先"
        );
        assert_eq!(texts(html, "div:has(+div p:matchesOwn(^乙$))"), ["甲"]);
        assert_eq!(
            texts(html, "div:has(~div p:matchesOwn(^丙$))"),
            ["甲", "乙"]
        );
        assert_eq!(
            texts(html, "div:has(>p:matchesOwn(^甲$), >section)"),
            ["甲", "乙"]
        );
    }

    #[test]
    fn jsoup_extensions() {
        let html = r##"<div id="m"><a href="/1.html">第一章</a><a href="javascript:void(0)">目录</a><a href="/2.html">下一页</a><p></p><a href="#top">下 一 页</a></div>
            <ul><li>甲</li><li>乙</li><li>丙</li><li>丁</li></ul><script>var x = "secret";</script>"##;
        assert_eq!(texts(html, "a:contains(下一页)"), ["下一页"]);
        assert_eq!(
            texts(html, "a:matches(下[一\\s]*页)"),
            ["下一页", "下 一 页"]
        );
        assert_eq!(
            texts(html, "a[href~=\\.html$]"),
            ["第一章", "下一页"],
            "~= 是正则"
        );
        assert_eq!(
            texts(
                html,
                "a[href~=\\S]:matches(下[一\\s]*[页頁]):not([href~=^#|javascript:])"
            ),
            ["下一页"]
        );
        assert_eq!(texts(html, ":matchesOwn(^目录$)"), ["目录"]);
        assert_eq!(texts(html, "li:eq(1)"), ["乙"]);
        assert_eq!(texts(html, "li:lt(2)"), ["甲", "乙"]);
        assert_eq!(texts(html, "li:gt(2)"), ["丁"]);
        assert_eq!(texts(html, "div:has(a:contains(目录))").len(), 1);
        assert_eq!(texts(html, "ul > li:nth-child(odd)"), ["甲", "丙"]);
        assert_eq!(texts(html, "li:last-child"), ["丁"]);
        assert_eq!(texts(html, "#m > p:empty").len(), 1);
        assert_eq!(texts(html, "script:containsData(secret)").len(), 1);
        assert_eq!(texts(html, "li:not(:eq(0), :eq(3))"), ["乙", "丙"]);
        assert_eq!(texts(html, "[^hr]").len(), 4, "[^前缀] 属性名前缀");
        assert_eq!(texts(html, "a[href!=/1.html]").len(), 3);
        assert_eq!(texts(html, "li + li ~ li"), ["丙", "丁"]);
    }
}
