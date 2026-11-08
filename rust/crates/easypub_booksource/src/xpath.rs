//! XPath 1.0 子集，在已解析的网页上执行（书源里的写法见调研文档 §2.3）。
//!
//! 支持：绝对 / 相对路径、`//`、`.`、`..`、`*`、`@属性`、`@*`、`text()`、`node()`；
//! 轴 child、descendant、descendant-or-self、parent、ancestor、following-sibling、
//! preceding-sibling、self；谓词里的位置、`and` / `or`、比较、加减乘、`|` 并集；
//! 函数 position、last、count、contains、starts-with、ends-with、not、string、normalize-space、
//! string-length、concat、substring-before、substring-after、translate、true、false、number。
use crate::{dom, node::Document};
use ego_tree::{NodeId, NodeRef};
use scraper::Node as DomNode;
use std::{cell::RefCell, collections::HashMap, rc::Rc};

#[derive(Debug, Clone, PartialEq)]
enum Tok {
    Slash,
    DoubleSlash,
    LBracket,
    RBracket,
    LParen,
    RParen,
    At,
    Comma,
    Pipe,
    Dot,
    DotDot,
    Star,
    Op(&'static str),
    Name(String),
    Axis(String),
    Str(String),
    Num(f64),
}

fn tokenize(text: &str) -> Option<Vec<Tok>> {
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;
    let mut out = Vec::new();
    while i < chars.len() {
        let c = chars[i];
        let next = chars.get(i + 1).copied();
        match c {
            ' ' | '\t' | '\n' | '\r' => i += 1,
            '/' if next == Some('/') => {
                out.push(Tok::DoubleSlash);
                i += 2;
            }
            '/' => {
                out.push(Tok::Slash);
                i += 1;
            }
            '[' => {
                out.push(Tok::LBracket);
                i += 1;
            }
            ']' => {
                out.push(Tok::RBracket);
                i += 1;
            }
            '(' => {
                out.push(Tok::LParen);
                i += 1;
            }
            ')' => {
                out.push(Tok::RParen);
                i += 1;
            }
            '@' => {
                out.push(Tok::At);
                i += 1;
            }
            ',' => {
                out.push(Tok::Comma);
                i += 1;
            }
            '|' => {
                out.push(Tok::Pipe);
                i += 1;
            }
            '.' if next == Some('.') => {
                out.push(Tok::DotDot);
                i += 2;
            }
            '.' if !next.is_some_and(|n| n.is_ascii_digit()) => {
                out.push(Tok::Dot);
                i += 1;
            }
            '*' => {
                out.push(Tok::Star);
                i += 1;
            }
            '=' => {
                out.push(Tok::Op("="));
                i += 1;
            }
            '!' if next == Some('=') => {
                out.push(Tok::Op("!="));
                i += 2;
            }
            '<' | '>' => {
                let eq = next == Some('=');
                out.push(Tok::Op(match (c, eq) {
                    ('<', true) => "<=",
                    ('<', false) => "<",
                    (_, true) => ">=",
                    _ => ">",
                }));
                i += if eq { 2 } else { 1 };
            }
            '+' => {
                out.push(Tok::Op("+"));
                i += 1;
            }
            '-' => {
                out.push(Tok::Op("-"));
                i += 1;
            }
            '"' | '\'' => {
                let end = chars[i + 1..].iter().position(|&x| x == c)? + i + 1;
                out.push(Tok::Str(chars[i + 1..end].iter().collect()));
                i = end + 1;
            }
            c if c.is_ascii_digit() || c == '.' => {
                let start = i;
                while i < chars.len() && (chars[i].is_ascii_digit() || chars[i] == '.') {
                    i += 1;
                }
                out.push(Tok::Num(
                    chars[start..i].iter().collect::<String>().parse().ok()?,
                ));
            }
            c if c.is_alphabetic() || c == '_' => {
                let start = i;
                while i < chars.len()
                    && (chars[i].is_alphanumeric() || matches!(chars[i], '_' | '-' | '.'))
                {
                    // 名称里的点只在后面还是名称字符时算（避免吞掉 `a/..`）。
                    if chars[i] == '.' && !chars.get(i + 1).is_some_and(|n| n.is_alphanumeric()) {
                        break;
                    }
                    i += 1;
                }
                // 带命名空间前缀的写法（如 `og:title` 里）不出现在名称测试中；`::` 是轴。
                let name: String = chars[start..i].iter().collect();
                if chars.get(i) == Some(&':') && chars.get(i + 1) == Some(&':') {
                    out.push(Tok::Axis(name));
                    i += 2;
                } else {
                    out.push(Tok::Name(name));
                }
            }
            _ => return None,
        }
    }
    Some(out)
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Axis {
    Child,
    Descendant,
    DescendantOrSelf,
    Parent,
    Ancestor,
    FollowingSibling,
    PrecedingSibling,
    Itself,
    Attribute,
}
#[derive(Debug, Clone)]
enum Test {
    Name(String),
    Any,
    Text,
    Node,
}
#[derive(Debug, Clone)]
struct Step {
    axis: Axis,
    test: Test,
    preds: Vec<Expr>,
}
#[derive(Debug, Clone)]
enum Expr {
    Or(Box<Expr>, Box<Expr>),
    And(Box<Expr>, Box<Expr>),
    Cmp(&'static str, Box<Expr>, Box<Expr>),
    Arith(&'static str, Box<Expr>, Box<Expr>),
    Neg(Box<Expr>),
    Union(Vec<Expr>),
    /// 起点：None 为上下文节点，Some(true) 为根；`filter` 为主表达式开头（如函数）。
    Path {
        absolute: bool,
        filter: Option<Box<Expr>>,
        steps: Vec<Step>,
    },
    Str(String),
    Num(f64),
    Call(String, Vec<Expr>),
}

struct Parser {
    toks: Vec<Tok>,
    pos: usize,
}
impl Parser {
    fn peek(&self) -> Option<&Tok> {
        self.toks.get(self.pos)
    }
    fn eat(&mut self, t: &Tok) -> bool {
        if self.peek() == Some(t) {
            self.pos += 1;
            true
        } else {
            false
        }
    }
    fn keyword(&mut self, word: &str) -> bool {
        if matches!(self.peek(), Some(Tok::Name(n)) if n == word) && self.pos > 0 {
            self.pos += 1;
            true
        } else {
            false
        }
    }
    fn expr(&mut self) -> Option<Expr> {
        let mut left = self.and()?;
        while self.keyword("or") {
            left = Expr::Or(Box::new(left), Box::new(self.and()?));
        }
        Some(left)
    }
    fn and(&mut self) -> Option<Expr> {
        let mut left = self.equality()?;
        while self.keyword("and") {
            left = Expr::And(Box::new(left), Box::new(self.equality()?));
        }
        Some(left)
    }
    fn equality(&mut self) -> Option<Expr> {
        let mut left = self.relational()?;
        while let Some(Tok::Op(op @ ("=" | "!="))) = self.peek().cloned() {
            self.pos += 1;
            left = Expr::Cmp(op, Box::new(left), Box::new(self.relational()?));
        }
        Some(left)
    }
    fn relational(&mut self) -> Option<Expr> {
        let mut left = self.additive()?;
        while let Some(Tok::Op(op @ ("<" | "<=" | ">" | ">="))) = self.peek().cloned() {
            self.pos += 1;
            left = Expr::Cmp(op, Box::new(left), Box::new(self.additive()?));
        }
        Some(left)
    }
    fn additive(&mut self) -> Option<Expr> {
        let mut left = self.multiplicative()?;
        while let Some(Tok::Op(op @ ("+" | "-"))) = self.peek().cloned() {
            self.pos += 1;
            left = Expr::Arith(op, Box::new(left), Box::new(self.multiplicative()?));
        }
        Some(left)
    }
    fn multiplicative(&mut self) -> Option<Expr> {
        let mut left = self.unary()?;
        loop {
            let op = match self.peek() {
                Some(Tok::Star) => "*",
                Some(Tok::Name(n)) if n == "div" => "div",
                Some(Tok::Name(n)) if n == "mod" => "mod",
                _ => break,
            };
            self.pos += 1;
            left = Expr::Arith(op, Box::new(left), Box::new(self.unary()?));
        }
        Some(left)
    }
    fn unary(&mut self) -> Option<Expr> {
        if self.eat(&Tok::Op("-")) {
            return Some(Expr::Neg(Box::new(self.unary()?)));
        }
        let mut parts = vec![self.path()?];
        while self.eat(&Tok::Pipe) {
            parts.push(self.path()?);
        }
        Some(if parts.len() == 1 {
            parts.pop().unwrap()
        } else {
            Expr::Union(parts)
        })
    }
    fn path(&mut self) -> Option<Expr> {
        let mut steps = Vec::new();
        let mut absolute = false;
        let mut filter = None;
        match self.peek()? {
            Tok::Slash => {
                self.pos += 1;
                absolute = true;
                if !self.starts_step() {
                    return Some(Expr::Path {
                        absolute,
                        filter,
                        steps,
                    });
                }
            }
            Tok::DoubleSlash => {
                self.pos += 1;
                absolute = true;
                steps.push(Step {
                    axis: Axis::DescendantOrSelf,
                    test: Test::Node,
                    preds: vec![],
                });
            }
            Tok::Str(_) | Tok::Num(_) | Tok::LParen => {
                let primary = self.primary()?;
                if !matches!(
                    self.peek(),
                    Some(Tok::Slash | Tok::DoubleSlash | Tok::LBracket)
                ) {
                    return Some(primary);
                }
                filter = Some(Box::new(primary));
            }
            Tok::Name(n)
                if matches!(self.toks.get(self.pos + 1), Some(Tok::LParen))
                    && !matches!(n.as_str(), "text" | "node") =>
            {
                let primary = self.primary()?;
                if !matches!(self.peek(), Some(Tok::Slash | Tok::DoubleSlash)) {
                    return Some(primary);
                }
                filter = Some(Box::new(primary));
            }
            _ => (),
        }
        if filter.is_none() || matches!(self.peek(), Some(Tok::Slash | Tok::DoubleSlash)) {
            if filter.is_some() {
                self.separator(&mut steps)?;
            }
            steps.push(self.step()?);
            while matches!(self.peek(), Some(Tok::Slash | Tok::DoubleSlash)) {
                self.separator(&mut steps)?;
                steps.push(self.step()?);
            }
        }
        Some(Expr::Path {
            absolute,
            filter,
            steps,
        })
    }
    fn separator(&mut self, steps: &mut Vec<Step>) -> Option<()> {
        if self.eat(&Tok::DoubleSlash) {
            steps.push(Step {
                axis: Axis::DescendantOrSelf,
                test: Test::Node,
                preds: vec![],
            });
            Some(())
        } else {
            self.eat(&Tok::Slash).then_some(())
        }
    }
    fn starts_step(&self) -> bool {
        matches!(
            self.peek(),
            Some(Tok::Name(_) | Tok::Axis(_) | Tok::At | Tok::Star | Tok::Dot | Tok::DotDot)
        )
    }
    fn step(&mut self) -> Option<Step> {
        let mut axis = Axis::Child;
        match self.peek()?.clone() {
            Tok::Dot => {
                self.pos += 1;
                return Some(Step {
                    axis: Axis::Itself,
                    test: Test::Node,
                    preds: self.preds()?,
                });
            }
            Tok::DotDot => {
                self.pos += 1;
                return Some(Step {
                    axis: Axis::Parent,
                    test: Test::Node,
                    preds: vec![],
                });
            }
            Tok::At => {
                self.pos += 1;
                axis = Axis::Attribute;
            }
            Tok::Axis(name) => {
                self.pos += 1;
                axis = match name.as_str() {
                    "child" => Axis::Child,
                    "descendant" => Axis::Descendant,
                    "descendant-or-self" => Axis::DescendantOrSelf,
                    "parent" => Axis::Parent,
                    "ancestor" | "ancestor-or-self" => Axis::Ancestor,
                    "following-sibling" | "following" => Axis::FollowingSibling,
                    "preceding-sibling" | "preceding" => Axis::PrecedingSibling,
                    "self" => Axis::Itself,
                    "attribute" => Axis::Attribute,
                    _ => return None,
                };
            }
            _ => (),
        }
        let test = match self.peek()?.clone() {
            Tok::Star => {
                self.pos += 1;
                Test::Any
            }
            Tok::Name(n)
                if matches!(n.as_str(), "text" | "node")
                    && self.toks.get(self.pos + 1) == Some(&Tok::LParen) =>
            {
                self.pos += 3; // name ( )
                if self.toks.get(self.pos - 1) != Some(&Tok::RParen) {
                    return None;
                }
                if n == "text" { Test::Text } else { Test::Node }
            }
            Tok::Name(n) => {
                self.pos += 1;
                Test::Name(n.to_ascii_lowercase())
            }
            _ => return None,
        };
        Some(Step {
            axis,
            test,
            preds: self.preds()?,
        })
    }
    fn preds(&mut self) -> Option<Vec<Expr>> {
        let mut preds = Vec::new();
        while self.eat(&Tok::LBracket) {
            preds.push(self.expr()?);
            if !self.eat(&Tok::RBracket) {
                return None;
            }
        }
        Some(preds)
    }
    fn primary(&mut self) -> Option<Expr> {
        match self.peek()?.clone() {
            Tok::Str(s) => {
                self.pos += 1;
                Some(Expr::Str(s))
            }
            Tok::Num(n) => {
                self.pos += 1;
                Some(Expr::Num(n))
            }
            Tok::LParen => {
                self.pos += 1;
                let e = self.expr()?;
                self.eat(&Tok::RParen).then_some(e)
            }
            Tok::Name(name) => {
                self.pos += 2; // name (
                let mut args = Vec::new();
                if !self.eat(&Tok::RParen) {
                    loop {
                        args.push(self.expr()?);
                        if self.eat(&Tok::RParen) {
                            break;
                        }
                        if !self.eat(&Tok::Comma) {
                            return None;
                        }
                    }
                }
                Some(Expr::Call(name, args))
            }
            _ => None,
        }
    }
}

/// 结果里的节点。
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum XNode {
    Node(NodeId),
    Attr(NodeId, String),
}
#[derive(Debug, Clone)]
enum Val {
    Nodes(Vec<XNode>),
    Str(String),
    Num(f64),
    Bool(bool),
}

fn node_ref(doc: &Document, id: NodeId) -> Option<NodeRef<'_, DomNode>> {
    doc.html.tree.get(id)
}

pub fn string_value(doc: &Document, n: &XNode) -> String {
    match n {
        XNode::Attr(id, name) => node_ref(doc, *id)
            .and_then(|n| {
                n.value()
                    .as_element()
                    .and_then(|e| e.attr(name))
                    .map(str::to_owned)
            })
            .unwrap_or_default(),
        XNode::Node(id) => match node_ref(doc, *id) {
            Some(n) => match n.value() {
                DomNode::Text(t) => t.to_string(),
                _ => dom::text(n),
            },
            None => String::new(),
        },
    }
}

impl Val {
    fn string(&self, doc: &Document) -> String {
        match self {
            Val::Nodes(n) => n.first().map(|n| string_value(doc, n)).unwrap_or_default(),
            Val::Str(s) => s.clone(),
            Val::Num(n) => {
                if n.fract() == 0.0 && n.is_finite() {
                    format!("{}", *n as i64)
                } else {
                    n.to_string()
                }
            }
            Val::Bool(b) => b.to_string(),
        }
    }
    fn number(&self, doc: &Document) -> f64 {
        match self {
            Val::Num(n) => *n,
            Val::Bool(b) => f64::from(u8::from(*b)),
            other => other.string(doc).trim().parse().unwrap_or(f64::NAN),
        }
    }
    fn boolean(&self) -> bool {
        match self {
            Val::Nodes(n) => !n.is_empty(),
            Val::Str(s) => !s.is_empty(),
            Val::Num(n) => *n != 0.0 && !n.is_nan(),
            Val::Bool(b) => *b,
        }
    }
}

struct Ctx<'a> {
    doc: &'a Document,
    node: XNode,
    position: usize,
    size: usize,
    /// 整条 XPath 的起点元素（当作文档根）。
    origin: NodeId,
}

fn matches_test(doc: &Document, id: NodeId, test: &Test) -> bool {
    let Some(n) = node_ref(doc, id) else {
        return false;
    };
    match test {
        Test::Node => true,
        Test::Text => n.value().is_text(),
        Test::Any => n.value().is_element(),
        Test::Name(name) => n.value().as_element().is_some_and(|e| e.name() == name),
    }
}

fn axis_nodes(doc: &Document, node: &XNode, step: &Step) -> Vec<XNode> {
    let XNode::Node(id) = node else {
        return match step.axis {
            Axis::Parent | Axis::Ancestor => match node {
                XNode::Attr(id, _) => vec![XNode::Node(*id)],
                _ => vec![],
            },
            Axis::Itself => vec![node.clone()],
            _ => vec![],
        };
    };
    let Some(n) = node_ref(doc, *id) else {
        return vec![];
    };
    let ids: Vec<NodeId> = match step.axis {
        Axis::Attribute => {
            let Some(e) = n.value().as_element() else {
                return vec![];
            };
            return e
                .attrs()
                .filter(|(name, _)| match &step.test {
                    Test::Name(want) => name.eq_ignore_ascii_case(want),
                    Test::Any | Test::Node => true,
                    Test::Text => false,
                })
                .map(|(name, _)| XNode::Attr(*id, name.to_owned()))
                .collect();
        }
        Axis::Child => n.children().map(|c| c.id()).collect(),
        Axis::Descendant => n.descendants().skip(1).map(|c| c.id()).collect(),
        Axis::DescendantOrSelf => n.descendants().map(|c| c.id()).collect(),
        Axis::Parent => n.parent().map(|p| p.id()).into_iter().collect(),
        Axis::Ancestor => n.ancestors().map(|p| p.id()).collect(),
        Axis::FollowingSibling => n.next_siblings().map(|c| c.id()).collect(),
        Axis::PrecedingSibling => n.prev_siblings().map(|c| c.id()).collect(),
        Axis::Itself => vec![*id],
    };
    ids.into_iter()
        .filter(|id| matches_test(doc, *id, &step.test))
        .map(XNode::Node)
        .collect()
}

fn apply_step(doc: &Document, origin: NodeId, input: Vec<XNode>, step: &Step) -> Vec<XNode> {
    let mut out = Vec::new();
    for node in input {
        let mut candidates = axis_nodes(doc, &node, step);
        for pred in &step.preds {
            let size = candidates.len();
            candidates = candidates
                .into_iter()
                .enumerate()
                .filter(|(i, c)| {
                    let ctx = Ctx {
                        doc,
                        node: c.clone(),
                        position: i + 1,
                        size,
                        origin,
                    };
                    match eval(&ctx, pred) {
                        Val::Num(n) => (n - (i + 1) as f64).abs() < f64::EPSILON,
                        v => v.boolean(),
                    }
                })
                .map(|(_, c)| c)
                .collect();
        }
        out.extend(candidates);
        if out.len() > crate::jsoup::LIMIT {
            break;
        }
    }
    // 文档顺序去重（解析得到的节点编号即文档顺序）。
    out.sort();
    out.dedup();
    out
}

fn eval(ctx: &Ctx<'_>, expr: &Expr) -> Val {
    let doc = ctx.doc;
    match expr {
        Expr::Or(a, b) => Val::Bool(eval(ctx, a).boolean() || eval(ctx, b).boolean()),
        Expr::And(a, b) => Val::Bool(eval(ctx, a).boolean() && eval(ctx, b).boolean()),
        Expr::Cmp(op, a, b) => {
            let (a, b) = (eval(ctx, a), eval(ctx, b));
            Val::Bool(compare(doc, op, &a, &b))
        }
        Expr::Arith(op, a, b) => {
            let (a, b) = (eval(ctx, a).number(doc), eval(ctx, b).number(doc));
            Val::Num(match *op {
                "+" => a + b,
                "-" => a - b,
                "*" => a * b,
                "div" => a / b,
                _ => a % b,
            })
        }
        Expr::Neg(a) => Val::Num(-eval(ctx, a).number(doc)),
        Expr::Str(s) => Val::Str(s.clone()),
        Expr::Num(n) => Val::Num(*n),
        Expr::Union(parts) => {
            let mut nodes = Vec::new();
            for p in parts {
                if let Val::Nodes(n) = eval(ctx, p) {
                    nodes.extend(n);
                }
            }
            nodes.sort();
            nodes.dedup();
            Val::Nodes(nodes)
        }
        Expr::Path {
            absolute,
            filter,
            steps,
        } => {
            let mut nodes = if let Some(f) = filter {
                match eval(ctx, f) {
                    Val::Nodes(n) => n,
                    other => return other,
                }
            } else if *absolute {
                let root = doc.html.tree.root().id();
                if ctx.origin == root || steps.is_empty() {
                    vec![XNode::Node(root)]
                } else {
                    // 阅读的 XPath 把当前元素当作文档：`/li` 匹配它自己，`//td` 只在它里面找。
                    let mut nodes = match steps[0].axis {
                        Axis::DescendantOrSelf => vec![XNode::Node(ctx.origin)],
                        _ => {
                            let virtual_step = Step {
                                axis: Axis::Itself,
                                ..steps[0].clone()
                            };
                            apply_step(
                                doc,
                                ctx.origin,
                                vec![XNode::Node(ctx.origin)],
                                &virtual_step,
                            )
                        }
                    };
                    let rest = if matches!(steps[0].axis, Axis::DescendantOrSelf) {
                        &steps[..]
                    } else {
                        &steps[1..]
                    };
                    for step in rest {
                        nodes = apply_step(doc, ctx.origin, nodes, step);
                    }
                    return Val::Nodes(nodes);
                }
            } else {
                vec![ctx.node.clone()]
            };
            for step in steps {
                nodes = apply_step(doc, ctx.origin, nodes, step);
            }
            Val::Nodes(nodes)
        }
        Expr::Call(name, args) => call(ctx, name, args),
    }
}

fn compare(doc: &Document, op: &str, a: &Val, b: &Val) -> bool {
    let cmp_str = |x: &str, y: &str| match op {
        "=" => x == y,
        "!=" => x != y,
        _ => {
            let (x, y) = (
                x.trim().parse::<f64>().unwrap_or(f64::NAN),
                y.trim().parse::<f64>().unwrap_or(f64::NAN),
            );
            cmp_num(op, x, y)
        }
    };
    match (a, b) {
        (Val::Nodes(xs), Val::Nodes(ys)) => xs.iter().any(|x| {
            let x = string_value(doc, x);
            ys.iter().any(|y| cmp_str(&x, &string_value(doc, y)))
        }),
        (Val::Nodes(xs), other) | (other, Val::Nodes(xs)) => {
            let flipped = matches!(b, Val::Nodes(_)) && !matches!(a, Val::Nodes(_));
            xs.iter().any(|x| {
                let s = string_value(doc, x);
                match other {
                    Val::Num(n) => {
                        let v = s.trim().parse::<f64>().unwrap_or(f64::NAN);
                        if flipped {
                            cmp_num(op, *n, v)
                        } else {
                            cmp_num(op, v, *n)
                        }
                    }
                    Val::Bool(bv) => (op == "=") == (!s.is_empty() == *bv),
                    other => {
                        let o = other.string(doc);
                        if flipped {
                            cmp_str(&o, &s)
                        } else {
                            cmp_str(&s, &o)
                        }
                    }
                }
            })
        }
        _ if matches!(op, "=" | "!=") => {
            let eq = if matches!(a, Val::Num(_)) || matches!(b, Val::Num(_)) {
                a.number(doc) == b.number(doc)
            } else {
                a.string(doc) == b.string(doc)
            };
            eq == (op == "=")
        }
        _ => cmp_num(op, a.number(doc), b.number(doc)),
    }
}

fn cmp_num(op: &str, x: f64, y: f64) -> bool {
    match op {
        "=" => x == y,
        "!=" => x != y,
        "<" => x < y,
        "<=" => x <= y,
        ">" => x > y,
        _ => x >= y,
    }
}

fn call(ctx: &Ctx<'_>, name: &str, args: &[Expr]) -> Val {
    let doc = ctx.doc;
    let arg = |i: usize| args.get(i).map(|a| eval(ctx, a));
    let s = |i: usize| {
        arg(i)
            .map(|v| v.string(doc))
            .unwrap_or_else(|| string_value(doc, &ctx.node))
    };
    match name {
        "position" => Val::Num(ctx.position as f64),
        "last" => Val::Num(ctx.size as f64),
        "count" => Val::Num(match arg(0) {
            Some(Val::Nodes(n)) => n.len() as f64,
            _ => 0.0,
        }),
        "contains" => Val::Bool(s(0).contains(&s(1))),
        "starts-with" => Val::Bool(s(0).starts_with(&s(1))),
        "ends-with" => Val::Bool(s(0).ends_with(&s(1))),
        "not" => Val::Bool(!arg(0).is_some_and(|v| v.boolean())),
        "true" => Val::Bool(true),
        "false" => Val::Bool(false),
        "string" => Val::Str(s(0)),
        "number" => Val::Num(arg(0).map_or(f64::NAN, |v| v.number(doc))),
        "normalize-space" => Val::Str(dom::normalize(&s(0))),
        "string-length" => Val::Num(s(0).chars().count() as f64),
        "concat" => Val::Str((0..args.len()).map(s).collect()),
        "substring-before" => Val::Str(
            s(0).split_once(&s(1))
                .map(|(a, _)| a.to_owned())
                .unwrap_or_default(),
        ),
        "substring-after" => Val::Str(
            s(0).split_once(&s(1))
                .map(|(_, b)| b.to_owned())
                .unwrap_or_default(),
        ),
        "translate" => {
            let (from, to): (Vec<char>, Vec<char>) =
                (s(1).chars().collect(), s(2).chars().collect());
            Val::Str(
                s(0).chars()
                    .filter_map(|c| match from.iter().position(|&f| f == c) {
                        Some(i) => to.get(i).copied(),
                        None => Some(c),
                    })
                    .collect(),
            )
        }
        _ => Val::Nodes(Vec::new()),
    }
}

thread_local! {
    static CACHE: RefCell<HashMap<String, Option<Rc<Expr>>>> = RefCell::new(HashMap::new());
}

fn compiled(rule: &str) -> Option<Rc<Expr>> {
    if let Some(hit) = CACHE.with(|c| c.borrow().get(rule).cloned()) {
        return hit;
    }
    let expr = tokenize(rule).and_then(|toks| {
        let mut p = Parser { toks, pos: 0 };
        let e = p.expr()?;
        (p.pos == p.toks.len()).then_some(e)
    });
    let expr = expr.map(Rc::new);
    CACHE.with(|c| {
        let mut c = c.borrow_mut();
        if c.len() > 4096 {
            c.clear();
        }
        c.insert(rule.to_owned(), expr.clone());
    });
    expr
}

/// 执行 XPath；写法不支持时返回 None。
pub fn evaluate(doc: &Document, start: NodeId, rule: &str) -> Option<Vec<XNode>> {
    #[cfg(test)]
    if crate::corpus::broken(3) {
        return None;
    }
    let expr = compiled(rule)?;
    let ctx = Ctx {
        doc,
        node: XNode::Node(start),
        position: 1,
        size: 1,
        origin: start,
    };
    Some(match eval(&ctx, &expr) {
        Val::Nodes(n) => n,
        // 函数直接返回的字符串、数字：作为一个文字结果。
        _ => Vec::new(),
    })
}

/// XPath 返回的不是节点（如 `string(//title)`）时的文字结果。
pub fn evaluate_string(doc: &Document, start: NodeId, rule: &str) -> Option<String> {
    #[cfg(test)]
    if crate::corpus::broken(3) {
        return None;
    }
    let expr = compiled(rule)?;
    let ctx = Ctx {
        doc,
        node: XNode::Node(start),
        position: 1,
        size: 1,
        origin: start,
    };
    match eval(&ctx, &expr) {
        Val::Nodes(_) => None,
        v => Some(v.string(doc)),
    }
}
