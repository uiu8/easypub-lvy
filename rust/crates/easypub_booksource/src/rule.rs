//! 一条书源规则的拆分与执行（按阅读规则说明，独立实现）。
//!
//! 执行顺序：先做 `@put:{键:规则}`（在当前内容上取值存进变量），再按 `<js>…</js>`、`@js:`
//! 把规则切成若干段依次执行，上一段的结果是下一段的输入。规则段里：
//! - `@get:{键}` 换成变量值；`{{…}}` 为模板：里面以 `@@`、`@css:`、`@xpath:`、`//`、`@json:`、`$.`
//!   开头的按规则取值，其余按 JS 执行；输入是整段正则的匹配时 `$1` 等换成对应分组；
//! - 否则按前缀选择解析方式：`@css:` / `@@` / 无前缀为默认规则，`@xpath:` 或 `/` 开头为 XPath，
//!   `@json:` 或 `$.`、`$[` 开头（或当前内容是 JSON）为 JSONPath，列表规则 `:` 开头为整段正则；
//! - `&&` 合并、`||` 取第一个有结果的、`%%` 交替合并；
//! - `##正则##替换` 对结果净化，末尾 `###` 表示只取第一个匹配。
use crate::{
    jsonpath, jsoup,
    node::Node,
    pattern::{self, Pattern},
    xpath,
};
use serde_json::Value;
use std::{
    rc::Rc,
    sync::{Arc, OnceLock},
};

/// `@js:` 之后另起一行的 `##`。
fn js_purify() -> &'static regex::Regex {
    static RE: OnceLock<regex::Regex> = OnceLock::new();
    RE.get_or_init(|| regex::Regex::new(r"\n\s*##").unwrap())
}

/// 规则执行需要的外部能力：JS 与变量。
pub trait Host {
    /// 以 `input` 为 `result` 执行 JS，返回结果（数组展开为多项）。
    fn js(&self, code: &str, input: &[Node]) -> Vec<Node>;
    fn var(&self, key: &str) -> String;
    fn put_var(&self, key: &str, value: String);
}

#[derive(Debug, Clone, PartialEq)]
enum Seg {
    Rule(String),
    Js(String),
}

struct Parsed {
    puts: Vec<(String, String)>,
    segs: Vec<Seg>,
}

/// 从 `@put:{…}` 起点取出整段（含嵌套括号与引号），返回 (键值对, 去掉后的规则)。
fn take_puts(rule: &str) -> (Vec<(String, String)>, String) {
    let mut puts = Vec::new();
    let mut rest = rule.to_owned();
    loop {
        let lower = rest.to_ascii_lowercase();
        let Some(start) = lower.find("@put:{") else {
            break;
        };
        let body_start = start + 5;
        let Some(len) = balanced(&rest[body_start..], '{', '}') else {
            break;
        };
        let body = rest[body_start + 1..body_start + len].to_owned();
        puts.extend(parse_put(&body));
        rest.replace_range(start..body_start + len + 1, "");
    }
    (puts, rest)
}

/// `text` 以 `open` 开头时，返回与之配对的 `close` 的位置。
fn balanced(text: &str, open: char, close: char) -> Option<usize> {
    let (mut depth, mut quote) = (0, None);
    let mut escaped = false;
    for (i, c) in text.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        if c == '\\' {
            escaped = true;
            continue;
        }
        if let Some(q) = quote {
            if c == q {
                quote = None;
            }
            continue;
        }
        if c == '"' || c == '\'' {
            quote = Some(c);
        } else if c == open {
            depth += 1;
        } else if c == close {
            depth -= 1;
            if depth == 0 {
                return Some(i);
            }
        }
    }
    None
}

/// `键:规则, 键:"规则"`：键可不加引号，值为引号字符串或到下一个顶层逗号为止。
fn parse_put(body: &str) -> Vec<(String, String)> {
    if let Ok(Value::Object(map)) = serde_json::from_str::<Value>(&format!("{{{body}}}")) {
        return map
            .into_iter()
            .map(|(k, v)| (k, jsonpath::value_text(&v)))
            .collect();
    }
    let mut out = Vec::new();
    for item in split_top(body, ",") {
        let Some((k, v)) = item.split_once(':') else {
            continue;
        };
        let k = k.trim().trim_matches(['"', '\'']).to_owned();
        let v = v.trim();
        let v = if v.len() >= 2
            && ((v.starts_with('"') && v.ends_with('"'))
                || (v.starts_with('\'') && v.ends_with('\'')))
        {
            v[1..v.len() - 1].to_owned()
        } else {
            v.to_owned()
        };
        if !k.is_empty() {
            out.push((k, v));
        }
    }
    out
}

fn split_js(rule: &str) -> Vec<Seg> {
    let mut segs = Vec::new();
    let mut rest = rule;
    loop {
        let lower = rest.to_ascii_lowercase();
        let tag = lower.find("<js>");
        let at = lower.find("@js:");
        match (tag, at) {
            (Some(t), a) if a.is_none_or(|a| t < a) => {
                push_rule(&mut segs, &rest[..t]);
                let body = &rest[t + 4..];
                let end = body
                    .to_ascii_lowercase()
                    .find("</js>")
                    .unwrap_or(body.len());
                segs.push(Seg::Js(body[..end].to_owned()));
                rest = body.get(end + 5..).unwrap_or("");
            }
            (_, Some(a)) => {
                push_rule(&mut segs, &rest[..a]);
                let code = &rest[a + 4..];
                // `@js:` 之后另起一行的 `##正则##替换` 是对脚本结果的净化，不属于脚本。
                match js_purify().find(code) {
                    Some(m) => {
                        segs.push(Seg::Js(code[..m.start()].to_owned()));
                        push_rule(&mut segs, &code[m.start()..]);
                    }
                    None => segs.push(Seg::Js(code.to_owned())),
                }
                break;
            }
            _ => {
                push_rule(&mut segs, rest);
                break;
            }
        }
    }
    segs
}

fn push_rule(segs: &mut Vec<Seg>, text: &str) {
    let text = text.trim();
    if !text.is_empty() {
        segs.push(Seg::Rule(text.to_owned()));
    }
}

fn parse(rule: &str) -> Parsed {
    let (puts, rest) = take_puts(rule);
    Parsed {
        puts,
        segs: split_js(&rest),
    }
}

/// 分隔符只在引号、方括号、圆括号、花括号之外生效。
pub fn split_top<'a>(text: &'a str, delimiter: &str) -> Vec<&'a str> {
    let mut pieces = Vec::new();
    let (mut start, mut depth, mut quote) = (0, 0i32, None);
    let mut escaped = false;
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let c = bytes[i];
        if escaped {
            escaped = false;
            i += 1;
            continue;
        }
        if c == b'\\' {
            escaped = true;
            i += 1;
            continue;
        }
        if let Some(q) = quote {
            if c == q {
                quote = None;
            }
            i += 1;
            continue;
        }
        match c {
            b'\'' | b'"' => quote = Some(c),
            b'[' | b'(' | b'{' => depth += 1,
            b']' | b')' | b'}' => depth -= 1,
            _ => (),
        }
        if depth <= 0 && text.is_char_boundary(i) && text[i..].starts_with(delimiter) {
            pieces.push(&text[start..i]);
            i += delimiter.len();
            start = i;
            continue;
        }
        i += 1;
    }
    pieces.push(&text[start..]);
    pieces
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Mode {
    Default,
    Css,
    XPath,
    Json,
    Regex,
}

fn mode_of<'a>(rule: &'a str, input: &Node, list: bool) -> (Mode, &'a str) {
    let lower = rule.get(..7).unwrap_or(rule).to_ascii_lowercase();
    if lower.starts_with("@css:") {
        (Mode::Css, rule)
    } else if lower.starts_with("@@") {
        (Mode::Default, &rule[2..])
    } else if lower.starts_with("@xpath:") {
        (Mode::XPath, &rule[7..])
    } else if lower.starts_with("@json:") {
        (Mode::Json, &rule[6..])
    } else if rule.starts_with("$.") || rule.starts_with("$[") || rule.starts_with("$..") {
        (Mode::Json, rule)
    } else if list && rule.starts_with(':') {
        (Mode::Regex, &rule[1..])
    } else if input.is_json() {
        // JSON 内容里以 / 开头的是网址模板（如 `/books?id={$.id}`），不是 XPath。
        (Mode::Json, rule)
    } else if rule.starts_with('/') {
        (Mode::XPath, rule)
    } else {
        (Mode::Default, rule)
    }
}

/// 模板里的内容按规则还是按 JS 执行。
fn is_rule(inner: &str) -> bool {
    let lower = inner
        .trim_start()
        .get(..7)
        .unwrap_or(inner.trim_start())
        .to_ascii_lowercase();
    lower.starts_with("@@")
        || lower.starts_with("@css:")
        || lower.starts_with("@xpath:")
        || lower.starts_with("@json:")
        || lower.starts_with("$.")
        || lower.starts_with("$[")
        || lower.starts_with("//")
}

/// 展开 `@get:{键}`、`{{…}}`、`$1`，返回 (展开后的文字, 是否含模板)。含模板时结果就是这段文字。
fn expand(host: &dyn Host, rule: &str, input: &Node) -> (String, bool) {
    let mut text = rule.to_owned();
    let mut templated = false;
    while let Some(start) = text.to_ascii_lowercase().find("@get:{") {
        let Some(len) = text[start + 6..].find('}') else {
            break;
        };
        let key = text[start + 6..start + 6 + len].to_owned();
        text.replace_range(start..start + 7 + len, &host.var(key.trim()));
        templated = true;
    }
    if text.contains("{{") {
        let mut out = String::new();
        let mut rest = text.as_str();
        while let Some(start) = rest.find("{{") {
            let Some(end) = find_close(&rest[start + 2..]) else {
                break;
            };
            out.push_str(&rest[..start]);
            let inner = &rest[start + 2..start + 2 + end];
            let value = if is_rule(inner) {
                string(host, inner, input)
            } else {
                host.js(inner, std::slice::from_ref(input))
                    .iter()
                    .map(Node::text)
                    .collect::<Vec<_>>()
                    .join(",")
            };
            out.push_str(&value);
            rest = &rest[start + 2 + end + 2..];
            templated = true;
        }
        out.push_str(rest);
        text = out;
    }
    if let Node::Groups(groups) = input
        && text.contains('$')
    {
        let groups: Vec<Option<String>> = groups.iter().cloned().map(Some).collect();
        let re = regex::Regex::new(r"\$(\d{1,2})").unwrap();
        if re.is_match(&text) {
            text = re
                .replace_all(&text, |c: &regex::Captures<'_>| {
                    c[1].parse::<usize>()
                        .ok()
                        .and_then(|n| groups.get(n).cloned().flatten())
                        .unwrap_or_default()
                })
                .into_owned();
            templated = true;
        }
    }
    (text, templated)
}

/// 找与 `{{` 配对的 `}}`（跳过内层的花括号与字符串）。
fn find_close(text: &str) -> Option<usize> {
    let (mut depth, mut quote) = (0i32, None);
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let c = bytes[i];
        if let Some(q) = quote {
            if c == b'\\' {
                i += 2;
                continue;
            }
            if c == q {
                quote = None;
            }
        } else if c == b'"' || c == b'\'' || c == b'`' {
            quote = Some(c);
        } else if depth == 0 && c == b'}' && bytes.get(i + 1) == Some(&b'}') {
            return Some(i);
        } else if c == b'{' {
            depth += 1;
        } else if c == b'}' {
            depth -= 1;
        }
        i += 1;
    }
    None
}

struct Replace {
    pattern: Arc<Pattern>,
    with: String,
    first: bool,
}

fn split_replace(rule: &str) -> (&str, Option<Replace>) {
    let Some(at) = rule.find("##") else {
        return (rule, None);
    };
    let base = &rule[..at];
    let rest = &rule[at + 2..];
    let parts: Vec<&str> = rest.split("##").collect();
    let regex = parts[0];
    let with = parts.get(1).copied().unwrap_or("");
    let first = parts.len() >= 3;
    // 末尾 `###`：split 得到的最后一段是 "#"。
    let with = if first {
        with
    } else {
        with.strip_suffix('#').unwrap_or(with)
    };
    let replace = pattern::compile(regex).map(|pattern| Replace {
        pattern,
        with: with.to_owned(),
        first,
    });
    (base, replace)
}

impl Replace {
    fn apply(&self, text: &str) -> String {
        if self.first {
            self.pattern.first(text, &self.with)
        } else {
            self.pattern.replace_all(text, &self.with)
        }
    }
}

/// 一个规则段（不含 JS），`list` 为真时取列表。
fn run_seg(host: &dyn Host, rule: &str, input: &Node, list: bool) -> Vec<Node> {
    let (rule, templated) = expand(host, rule, input);
    if templated {
        let (_, replace) = split_replace(&rule);
        // 模板结果就是文字（模板里的规则已在上面取值）；整段的 ## 已在模板之外时仍然生效。
        let text = match &replace {
            // 模板之外没有规则（如 `##…{{chapter.title}}…`）时，净化的是输入文字本身。
            Some(r) if !list => {
                let base = rule.split("##").next().unwrap_or("");
                r.apply(&if base.trim().is_empty() {
                    input.text()
                } else {
                    base.to_owned()
                })
            }
            _ => rule.clone(),
        };
        return vec![Node::Text(text)];
    }
    let (base, _) = if list {
        (rule.as_str(), None)
    } else {
        split_replace(&rule)
    };
    let base = base.trim();
    if base.is_empty() {
        // 只有 `##正则`：对输入文字本身净化（如正文的 replaceRegex）。
        return if !list && rule.trim_start().starts_with("##") {
            vec![Node::Text(input.text())]
        } else {
            Vec::new()
        };
    }
    // 组合：先 ||，再 &&，再 %%。
    for op in ["||", "&&", "%%"] {
        let parts = split_top(base, op);
        if parts.len() > 1 {
            let mut lists = Vec::new();
            for part in parts {
                let values = run_seg(host, part.trim(), input, list);
                if !values.is_empty() {
                    lists.push(values);
                    if op == "||" {
                        break;
                    }
                }
            }
            return if op == "%%" {
                let mut out = Vec::new();
                for i in 0..lists.first().map_or(0, Vec::len) {
                    for values in &lists {
                        if let Some(v) = values.get(i) {
                            out.push(v.clone());
                        }
                    }
                }
                out
            } else {
                lists.into_iter().flatten().collect()
            };
        }
    }
    // 脚本返回的“HTML 片段数组”（JSON 文字）按 HTML 继续解析。
    let html_list;
    let input = match html_array(input) {
        Some(joined) => {
            html_list = Node::page(joined);
            &html_list
        }
        None => input,
    };
    let (mode, body) = mode_of(base, input, list);
    let body = body.trim();
    match mode {
        Mode::Default | Mode::Css => {
            let rule = if mode == Mode::Css { base } else { body };
            if list {
                jsoup::elements(rule, input)
            } else {
                jsoup::strings(rule, input)
                    .into_iter()
                    .map(Node::Text)
                    .collect()
            }
        }
        Mode::Json => {
            let Some(root) = json_of(input) else {
                return Vec::new();
            };
            let root = &*root;
            if list {
                jsonpath::elements(root, body)
                    .into_iter()
                    .map(Node::Json)
                    .collect()
            } else {
                jsonpath::strings(root, body)
                    .into_iter()
                    .map(Node::Text)
                    .collect()
            }
        }
        Mode::XPath => {
            let Some((doc, start)) = input.element() else {
                return Vec::new();
            };
            match xpath::evaluate(&doc, start, body) {
                Some(nodes) if !nodes.is_empty() => nodes
                    .into_iter()
                    .filter_map(|n| match n {
                        xpath::XNode::Node(id)
                            if list
                                && doc
                                    .html
                                    .tree
                                    .get(id)
                                    .is_some_and(|n| n.value().is_element()) =>
                        {
                            Some(Node::Elem(doc.clone(), id))
                        }
                        other => {
                            let s = xpath::string_value(&doc, &other);
                            (!s.trim().is_empty())
                                .then(|| Node::Text(if list { s } else { s.trim().to_owned() }))
                        }
                    })
                    .collect(),
                _ => xpath::evaluate_string(&doc, start, body)
                    .filter(|s| !s.is_empty())
                    .map(Node::Text)
                    .into_iter()
                    .collect(),
            }
        }
        Mode::Regex => {
            let Some(pattern) = pattern::compile(body) else {
                return Vec::new();
            };
            let text = input.text();
            pattern
                .matches(&text)
                .into_iter()
                .map(|(_, _, g)| {
                    Node::Groups(Rc::new(
                        g.into_iter().map(Option::unwrap_or_default).collect(),
                    ))
                })
                .collect()
        }
    }
}

fn html_array(input: &Node) -> Option<String> {
    let value = match input {
        Node::Json(v) => v,
        Node::JsonPage(_, v) => &**v,
        _ => return None,
    };
    let items = value.as_array()?;
    (!items.is_empty()
        && items
            .iter()
            .all(|v| v.as_str().is_some_and(|s| s.trim_start().starts_with('<'))))
    .then(|| {
        items
            .iter()
            .filter_map(Value::as_str)
            .collect::<Vec<_>>()
            .join(
                "
",
            )
    })
}

fn json_of(input: &Node) -> Option<Rc<Value>> {
    match input {
        Node::Json(v) => Some(Rc::new(v.clone())),
        Node::JsonPage(_, v) => Some(v.clone()),
        other => serde_json::from_str(other.text().trim()).ok().map(Rc::new),
    }
}

/// 执行整条规则（含 JS 段与 @put）。`list` 决定规则段取列表还是字符串。
fn run(host: &dyn Host, rule: &str, input: &Node, list: bool, join: bool) -> Vec<Node> {
    let rule = rule.trim();
    if rule.is_empty() {
        return Vec::new();
    }
    let parsed = parse(rule);
    for (key, value_rule) in &parsed.puts {
        let value = string(host, value_rule, input);
        host.put_var(key, value);
    }
    let mut current: Vec<Node> = vec![input.clone()];
    let count = parsed.segs.len();
    for (i, seg) in parsed.segs.iter().enumerate() {
        let last = i + 1 == count;
        current = match seg {
            Seg::Js(code) => {
                // 脚本里的 `{{$.x}}` 等规则模板先按当前内容取值（阅读的写法）。
                let input = current.first().cloned().unwrap_or_else(|| input.clone());
                host.js(&expand_rule_templates(host, code, &input), &current)
            }
            Seg::Rule(text) => {
                // 上一段是 JS 时，它的结果作为新内容（文字重新识别为 JSON 或网页）。
                let input = match current.as_slice() {
                    [one] => one.clone().reparse(),
                    many => Node::Text(many.iter().map(Node::text).collect::<Vec<_>>().join("\n"))
                        .reparse(),
                };
                let values = run_seg(host, text, &input, list);
                if !list {
                    let (_, replace) = split_replace(&expand_plain(text));
                    let strings: Vec<String> = values
                        .iter()
                        .map(Node::text)
                        .filter(|s| !s.is_empty())
                        .collect();
                    match replace {
                        // 字符串结果：先合并再净化（与阅读一致）；列表字符串逐项净化。
                        Some(r) if join || !last => vec![Node::Text(r.apply(&strings.join("\n")))],
                        Some(r) => strings.iter().map(|s| Node::Text(r.apply(s))).collect(),
                        None if join || !last => vec![Node::Text(strings.join("\n"))],
                        None => strings.into_iter().map(Node::Text).collect(),
                    }
                } else {
                    values
                }
            }
        };
    }
    current
}

/// 只展开规则类模板（`{{$.x}}`、`{{@@…}}` 等），脚本本身的花括号不动。
fn expand_rule_templates(host: &dyn Host, code: &str, input: &Node) -> String {
    if !code.contains("{{") {
        return code.to_owned();
    }
    let mut out = String::new();
    let mut rest = code;
    while let Some(start) = rest.find("{{") {
        let Some(end) = find_close(&rest[start + 2..]) else {
            break;
        };
        let inner = &rest[start + 2..start + 2 + end];
        out.push_str(&rest[..start]);
        if is_rule(inner) {
            out.push_str(&string(host, inner, input));
        } else {
            out.push_str(&rest[start..start + 2 + end + 2]);
        }
        rest = &rest[start + 2 + end + 2..];
    }
    out.push_str(rest);
    out
}

/// 判断净化后缀时不展开模板（模板内部的 ## 属于模板）。
fn expand_plain(rule: &str) -> String {
    if !rule.contains("{{") {
        return rule.to_owned();
    }
    let mut out = String::new();
    let mut rest = rule;
    while let Some(start) = rest.find("{{") {
        let Some(end) = find_close(&rest[start + 2..]) else {
            break;
        };
        out.push_str(&rest[..start]);
        out.push('x');
        rest = &rest[start + 2 + end + 2..];
    }
    out.push_str(rest);
    // 模板规则的 ## 已在 run_seg 里处理。
    if out.contains("##") && rule.contains("{{") {
        return out.split("##").next().unwrap_or("").to_owned();
    }
    out
}

/// 字符串结果（多项以换行合并）。
pub fn string(host: &dyn Host, rule: &str, input: &Node) -> String {
    run(host, rule, input, false, true)
        .iter()
        .map(Node::text)
        .collect::<Vec<_>>()
        .join("\n")
}

/// 字符串列表（如分类、多个网址）。
pub fn strings(host: &dyn Host, rule: &str, input: &Node) -> Vec<String> {
    run(host, rule, input, false, false)
        .iter()
        .map(Node::text)
        .filter(|s| !s.is_empty())
        .collect()
}

/// 列表规则：开头 `-` 表示倒序、`+` 表示正序（阅读的写法）。
pub fn elements(host: &dyn Host, rule: &str, input: &Node) -> Vec<Node> {
    let rule = rule.trim();
    let (reverse, rule) = match rule.as_bytes().first() {
        Some(b'-') => (true, &rule[1..]),
        Some(b'+') => (false, &rule[1..]),
        _ => (false, rule),
    };
    let mut values = run(host, rule, input, true, false);
    // JS 返回的字符串数组（如网址列表）里的每项仍是文字。
    if reverse {
        values.reverse();
    }
    values
}

#[cfg(test)]
mod tests;
