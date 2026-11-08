//! Legado 的无脚本规则子集。导入时编译规则，运行时不把不支持的语法当成空结果。
use regex::{Captures, Regex};
use scraper::{ElementRef, Html, Selector};
use serde_json::Value;

pub(super) type Result<T> = std::result::Result<T, &'static str>;
const UNSUPPORTED: &str = "book_source_rule_unsupported";
const LIMIT: usize = 30_000;

#[derive(Clone)]
pub(super) enum Content {
    Html(String, bool),
    Json(Value),
}
impl Content {
    pub fn page(text: String) -> Self {
        match serde_json::from_str(&text) {
            Ok(value) => Self::Json(value),
            Err(_) => Self::Html(text, false),
        }
    }
    fn text(&self) -> String {
        match self {
            Self::Html(s, _) => s.clone(),
            Self::Json(Value::String(s)) => s.clone(),
            Self::Json(Value::Null) => String::new(),
            Self::Json(v) => v.to_string(),
        }
    }
}

pub(super) struct Rule {
    expression: Expression,
    replacement: Option<Replacement>,
    list: bool,
}
enum Expression {
    Join(&'static str, Vec<Rule>),
    Json(Vec<JsonStep>),
    Html(HtmlRule),
}
struct Replacement {
    regex: Regex,
    text: String,
    first_match: bool,
}
struct HtmlRule {
    steps: Vec<HtmlStep>,
    value: Option<String>,
    // JSON 列表中的裸字段（name、author 等）沿用 Legado 的上下文识别。
    json_field: Option<Vec<JsonStep>>,
}
struct HtmlStep {
    selector: Selector,
    children: bool,
    contains: Option<String>,
    indexes: Option<Indexes>,
}
struct Indexes {
    exclude: bool,
    spans: Vec<Vec<Option<isize>>>,
}
enum JsonStep {
    Field(String),
    Index(isize),
    All,
    Descendant(String),
}

pub(super) fn requires_js(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    if ["<js", "@js:", "@webjs:", "java."]
        .iter()
        .any(|p| lower.contains(p))
    {
        return true;
    }
    let mut rest = text;
    while let Some(start) = rest.find("{{") {
        let Some(end) = rest[start + 2..].find("}}") else {
            return true;
        };
        if !matches!(rest[start + 2..start + 2 + end].trim(), "key" | "page") {
            return true;
        }
        rest = &rest[start + 4 + end..];
    }
    false
}

impl Rule {
    pub fn parse(text: &str, list: bool) -> Result<Self> {
        let text = text.trim();
        if text.len() > 16_384 || text.is_empty() {
            return Err(UNSUPPORTED);
        }
        if requires_js(text) {
            return Err("book_source_javascript_required");
        }
        let lower = text.to_ascii_lowercase();
        if lower.starts_with("@xpath:") || text.starts_with("//") {
            return Err("book_source_xpath_unsupported");
        }
        if lower.contains("@get:")
            || lower.contains("@put:")
            || lower.contains("@put{")
            || text.contains("{{")
            || Regex::new(r",\s*\{").unwrap().is_match(text)
            || text.starts_with(':')
        {
            return Err(UNSUPPORTED);
        }
        let suffix: Vec<_> = text.split("##").collect();
        if suffix.len() > 4 || (list && suffix.len() > 1) {
            return Err(UNSUPPORTED);
        }
        let replacement = if suffix.len() > 1 {
            Some(Replacement {
                regex: Regex::new(suffix[1]).map_err(|_| UNSUPPORTED)?,
                text: suffix.get(2).copied().unwrap_or("").into(),
                first_match: suffix.len() == 4,
            })
        } else {
            None
        };
        let base = suffix[0].trim();
        let mut expression = None;
        for op in ["||", "&&", "%%"] {
            let parts = split_top(base, op)?;
            if parts.len() > 1 {
                expression = Some(Expression::Join(
                    op,
                    parts
                        .into_iter()
                        .map(|part| Self::parse(part, list))
                        .collect::<Result<_>>()?,
                ));
                break;
            }
        }
        let expression = match expression {
            Some(e) => e,
            None if base.starts_with('$') || base.to_ascii_lowercase().starts_with("@json:") => {
                Expression::Json(json_path(if base.starts_with('@') {
                    &base[6..]
                } else {
                    base
                })?)
            }
            None => Expression::Html(HtmlRule::parse(base, list)?),
        };
        Ok(Self {
            expression,
            replacement,
            list,
        })
    }

    pub fn nodes(&self, content: &Content) -> Result<Vec<Content>> {
        let mut result = match &self.expression {
            Expression::Join(op, rules) => {
                let mut lists = Vec::new();
                for rule in rules {
                    let values = rule.nodes(content)?;
                    if !values.is_empty() {
                        lists.push(values);
                        if *op == "||" {
                            break;
                        }
                    }
                }
                if *op == "%%" {
                    // Legado 以第一组长度为交替合并的范围。
                    let mut result = Vec::new();
                    for i in 0..lists.first().map_or(0, Vec::len) {
                        for values in &lists {
                            if let Some(value) = values.get(i) {
                                result.push(value.clone());
                            }
                        }
                    }
                    result
                } else {
                    lists.into_iter().flatten().collect()
                }
            }
            Expression::Json(path) => {
                let json = match content {
                    Content::Json(v) => v.clone(),
                    Content::Html(s, _) => {
                        serde_json::from_str(s).map_err(|_| "book_source_parse_failed")?
                    }
                };
                json_values(&json, path)?
                    .into_iter()
                    .map(Content::Json)
                    .collect()
            }
            Expression::Html(rule) => rule.evaluate(content)?,
        };
        if result.len() > LIMIT {
            return Err("catalog_too_large");
        }
        if self.list {
            result = result
                .into_iter()
                .flat_map(|value| match value {
                    Content::Json(Value::Array(a)) => a.into_iter().map(Content::Json).collect(),
                    other => vec![other],
                })
                .collect();
            if result.len() > LIMIT {
                return Err("catalog_too_large");
            }
        } else if let Some(replacement) = &self.replacement {
            result = result
                .into_iter()
                .map(|v| {
                    let text = v.text();
                    let text = if replacement.first_match {
                        replacement
                            .regex
                            .captures(&text)
                            .map(|c| expand(&c, &replacement.text))
                            .unwrap_or_default()
                    } else {
                        replacement
                            .regex
                            .replace_all(&text, |c: &Captures<'_>| expand(c, &replacement.text))
                            .into_owned()
                    };
                    Content::Json(Value::String(text))
                })
                .collect();
        }
        Ok(result)
    }
    pub fn strings(&self, content: &Content) -> Result<Vec<String>> {
        Ok(self
            .nodes(content)?
            .into_iter()
            .flat_map(|v| match v {
                Content::Json(Value::Array(a)) => {
                    a.into_iter().map(|v| Content::Json(v).text()).collect()
                }
                other => vec![other.text()],
            })
            .filter(|s| !s.is_empty())
            .collect())
    }
    pub fn string(&self, content: &Content) -> Result<String> {
        Ok(self.strings(content)?.join("\n"))
    }
}

fn expand(captures: &Captures<'_>, template: &str) -> String {
    let mut chars = template.chars().peekable();
    let mut result = String::new();
    while let Some(c) = chars.next() {
        if c == '\\' {
            if let Some(c) = chars.next() {
                result.push(c);
            }
        } else if c == '$' && chars.peek().is_some_and(char::is_ascii_digit) {
            let mut group = String::new();
            while chars.peek().is_some_and(char::is_ascii_digit) {
                group.push(chars.next().unwrap());
            }
            if let Ok(index) = group.parse::<usize>()
                && let Some(m) = captures.get(index)
            {
                result.push_str(m.as_str());
            }
        } else if c == '$' && chars.peek() == Some(&'{') {
            chars.next();
            let name: String = chars.by_ref().take_while(|c| *c != '}').collect();
            if let Some(m) = captures.name(&name) {
                result.push_str(m.as_str());
            }
        } else {
            result.push(c);
        }
    }
    result
}

// 分隔符只在引号、属性选择器和伪类参数之外生效。
fn split_top<'a>(text: &'a str, delimiter: &str) -> Result<Vec<&'a str>> {
    let mut pieces = Vec::new();
    let mut start = 0;
    let mut quote = None;
    let mut depth = 0isize;
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
        match c {
            '\'' | '"' => quote = Some(c),
            '[' | '(' => depth += 1,
            ']' | ')' => depth -= 1,
            _ => (),
        }
        if depth < 0 {
            return Err(UNSUPPORTED);
        }
        if depth == 0 && quote.is_none() && i >= start && text[i..].starts_with(delimiter) {
            pieces.push(&text[start..i]);
            start = i + delimiter.len();
        }
    }
    if quote.is_some() || depth != 0 {
        return Err(UNSUPPORTED);
    }
    pieces.push(&text[start..]);
    Ok(pieces)
}

impl HtmlRule {
    fn parse(text: &str, list: bool) -> Result<Self> {
        let css = text.to_ascii_lowercase().starts_with("@css:");
        let text = if css {
            &text[5..]
        } else {
            text.trim_start_matches('@')
        };
        let json_field = if !text.contains('@') {
            json_path(text).ok()
        } else {
            None
        };
        let mut parts = split_top(text, "@")?;
        let value = if list {
            None
        } else {
            Some(parts.pop().ok_or(UNSUPPORTED)?.trim().to_owned())
        };
        if value
            .as_ref()
            .is_some_and(|s| s.is_empty() || s.chars().any(char::is_whitespace))
        {
            return Err(UNSUPPORTED);
        }
        let parts = if css {
            vec![parts.join("@")]
        } else {
            parts.into_iter().map(str::to_owned).collect()
        };
        let mut steps = Vec::new();
        for part in parts.into_iter().filter(|p| !p.is_empty()) {
            steps.push(HtmlStep::parse(&part, css)?);
        }
        Ok(Self {
            steps,
            value,
            json_field,
        })
    }
    fn evaluate(&self, content: &Content) -> Result<Vec<Content>> {
        if let Content::Json(json) = content {
            return json_values(json, self.json_field.as_ref().ok_or(UNSUPPORTED)?)
                .map(|v| v.into_iter().map(Content::Json).collect());
        }
        let Content::Html(text, fragment) = content else {
            unreachable!()
        };
        let document = if *fragment {
            Html::parse_fragment(text)
        } else {
            Html::parse_document(text)
        };
        let root = if *fragment {
            document
                .root_element()
                .children()
                .find_map(ElementRef::wrap)
                .unwrap_or(document.root_element())
        } else {
            document.root_element()
        };
        let mut current = vec![root];
        for step in &self.steps {
            let mut next = Vec::new();
            for element in current {
                let mut found = if step.children {
                    element
                        .children()
                        .filter_map(ElementRef::wrap)
                        .collect::<Vec<_>>()
                } else {
                    let mut found = Vec::new();
                    if step.selector.matches(&element) {
                        found.push(element);
                    }
                    found.extend(element.select(&step.selector));
                    found
                };
                if let Some(text) = &step.contains {
                    found.retain(|e| own_text(*e, " ").contains(text));
                }
                if let Some(indexes) = &step.indexes {
                    found = indexes.select(found)?;
                }
                next.extend(found);
                if next.len() > LIMIT {
                    return Err("catalog_too_large");
                }
            }
            current = next;
        }
        let mut values = Vec::new();
        for element in current {
            let value = match self.value.as_deref() {
                None => {
                    values.push(Content::Html(element.html(), true));
                    continue;
                }
                Some("text") => element
                    .text()
                    .collect::<Vec<_>>()
                    .join(" ")
                    .split_whitespace()
                    .collect::<Vec<_>>()
                    .join(" "),
                Some("textNodes") => own_text(element, "\n"),
                Some("ownText") => own_text(element, " "),
                Some("all") => element.html(),
                Some("html") => {
                    let mut fragment = Html::parse_fragment(&element.html());
                    let ids: Vec<_> = fragment
                        .select(&Selector::parse("script,style").unwrap())
                        .map(|n| n.id())
                        .collect();
                    for id in ids {
                        fragment.tree.get_mut(id).unwrap().detach();
                    }
                    fragment.root_element().inner_html()
                }
                Some(attr) => element.value().attr(attr).unwrap_or("").into(),
            };
            if !value.is_empty() {
                values.push(Content::Json(Value::String(value)));
            }
        }
        Ok(values)
    }
}
fn own_text(element: ElementRef<'_>, separator: &str) -> String {
    element
        .children()
        .filter_map(|n| n.value().as_text())
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(separator)
}

impl HtmlStep {
    fn parse(text: &str, css: bool) -> Result<Self> {
        let (base, indexes) = if css {
            (text, None)
        } else {
            Indexes::parse(text)?
        };
        let children = !css && (base.is_empty() || base == "children");
        let mut contains = None;
        let selector = if css {
            base.to_owned()
        } else if let Some(value) = base.strip_prefix("class.") {
            format!("[class~=\"{}\"]", css_quote(value))
        } else if let Some(value) = base.strip_prefix("id.") {
            format!("[id=\"{}\"]", css_quote(value))
        } else if let Some(value) = base.strip_prefix("tag.") {
            value.into()
        } else if let Some(value) = base.strip_prefix("text.") {
            contains = Some(value.into());
            "*".into()
        } else if children {
            "*".into()
        } else {
            base.into()
        };
        Ok(Self {
            selector: Selector::parse(&selector).map_err(|_| UNSUPPORTED)?,
            children,
            contains,
            indexes,
        })
    }
}
fn css_quote(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}
impl Indexes {
    fn parse(text: &str) -> Result<(&str, Option<Self>)> {
        let mut base = text;
        let mut index = None;
        let mut exclude = false;
        if text.ends_with(']')
            && let Some(start) = text.rfind('[')
        {
            let inside = &text[start + 1..text.len() - 1];
            if !inside.is_empty()
                && inside
                    .chars()
                    .all(|c| c.is_ascii_digit() || " ,:!-".contains(c))
            {
                base = &text[..start];
                exclude = inside.trim().starts_with('!');
                index = Some(inside.trim().trim_start_matches('!'));
            }
        }
        if index.is_none() {
            for (i, c) in text.char_indices().rev() {
                if (c == '.' || c == '!')
                    && !text[i + 1..].is_empty()
                    && text[i + 1..]
                        .chars()
                        .all(|c| c.is_ascii_digit() || ":-".contains(c))
                {
                    base = &text[..i];
                    exclude = c == '!';
                    // 原写法 .0:2 是索引列表；方括号中的冒号才是区间。
                    let spans = text[i + 1..]
                        .split(':')
                        .map(|n| {
                            n.parse::<isize>()
                                .map(|v| vec![Some(v)])
                                .map_err(|_| UNSUPPORTED)
                        })
                        .collect::<Result<_>>()?;
                    return Ok((base, Some(Self { exclude, spans })));
                }
            }
        }
        let Some(index) = index else {
            return Ok((base, None));
        };
        let spans = index
            .split(',')
            .map(|span| {
                let parts = span
                    .split(':')
                    .map(|n| {
                        let n = n.trim();
                        if n.is_empty() {
                            Ok(None)
                        } else {
                            n.parse::<isize>().map(Some).map_err(|_| UNSUPPORTED)
                        }
                    })
                    .collect::<Result<Vec<_>>>()?;
                if parts.is_empty()
                    || parts.len() > 3
                    || parts == [None]
                    || parts.get(2) == Some(&Some(0))
                {
                    return Err(UNSUPPORTED);
                }
                Ok(parts)
            })
            .collect::<Result<_>>()?;
        Ok((base, Some(Self { exclude, spans })))
    }
    fn select<T: Copy>(&self, items: Vec<T>) -> Result<Vec<T>> {
        let len = items.len() as isize;
        if len == 0 {
            return Ok(Vec::new());
        }
        let normal = |n: isize| if n < 0 { n + len } else { n };
        let mut positions = Vec::new();
        for span in &self.spans {
            let start = normal(span[0].unwrap_or(0));
            if span.len() == 1 {
                if (0..len).contains(&start) {
                    positions.push(start);
                }
            } else {
                let end = normal(span[1].unwrap_or(-1));
                if (start < 0 && end < 0) || (start >= len && end >= len) {
                    continue;
                }
                let mut i = start.clamp(0, len - 1);
                let end = end.clamp(0, len - 1);
                let step = span.get(2).copied().flatten().unwrap_or(1);
                let step = if step > 0 { step } else { (len + step).max(1) };
                let direction = if i <= end { 1 } else { -1 };
                while (direction == 1 && i <= end) || (direction == -1 && i >= end) {
                    positions.push(i);
                    i += step * direction;
                }
            }
        }
        let mut seen = std::collections::BTreeSet::new();
        positions.retain(|i| seen.insert(*i));
        Ok(if self.exclude {
            items
                .into_iter()
                .enumerate()
                .filter(|(i, _)| !seen.contains(&(*i as isize)))
                .map(|(_, v)| v)
                .collect()
        } else {
            positions.into_iter().map(|i| items[i as usize]).collect()
        })
    }
}

fn json_path(text: &str) -> Result<Vec<JsonStep>> {
    let mut rest = text.trim().strip_prefix('$').unwrap_or(text.trim());
    let mut steps = Vec::new();
    while !rest.is_empty() {
        let recursive = rest.starts_with("..");
        if recursive {
            rest = &rest[2..];
        } else if rest.starts_with('.') {
            rest = &rest[1..];
        }
        if rest.starts_with('[') && !recursive {
            let end = rest.find(']').ok_or(UNSUPPORTED)?;
            let field = &rest[1..end];
            steps.push(if field == "*" {
                JsonStep::All
            } else if let Ok(index) = field.parse() {
                JsonStep::Index(index)
            } else if (field.starts_with('\'') && field.ends_with('\''))
                || (field.starts_with('"') && field.ends_with('"'))
            {
                JsonStep::Field(field[1..field.len() - 1].into())
            } else {
                return Err(UNSUPPORTED);
            });
            rest = &rest[end + 1..];
        } else {
            let end = rest.find(['.', '[']).unwrap_or(rest.len());
            let name = &rest[..end];
            if name.is_empty()
                || !name
                    .chars()
                    .all(|c| c.is_alphanumeric() || c == '_' || c == '-')
            {
                return Err(UNSUPPORTED);
            }
            steps.push(if recursive {
                JsonStep::Descendant(name.into())
            } else {
                JsonStep::Field(name.into())
            });
            rest = &rest[end..];
        }
    }
    Ok(steps)
}
fn json_values(json: &Value, path: &[JsonStep]) -> Result<Vec<Value>> {
    let mut values = vec![json];
    for step in path {
        let mut next = Vec::new();
        for value in values {
            match step {
                JsonStep::Field(name) => {
                    if let Some(v) = value.get(name) {
                        next.push(v);
                    }
                }
                JsonStep::Index(index) => {
                    if let Some(a) = value.as_array() {
                        let n = if *index < 0 {
                            a.len() as isize + index
                        } else {
                            *index
                        };
                        if n >= 0
                            && let Some(v) = a.get(n as usize)
                        {
                            next.push(v);
                        }
                    }
                }
                JsonStep::All => match value {
                    Value::Array(a) => next.extend(a),
                    Value::Object(o) => next.extend(o.values()),
                    _ => (),
                },
                JsonStep::Descendant(name) => descendants(value, name, &mut next),
            }
            if next.len() > LIMIT {
                return Err("catalog_too_large");
            }
        }
        values = next;
    }
    Ok(values.into_iter().cloned().collect())
}
fn descendants<'a>(value: &'a Value, name: &str, result: &mut Vec<&'a Value>) {
    match value {
        Value::Object(o) => {
            if let Some(v) = o.get(name) {
                result.push(v);
            }
            for v in o.values() {
                descendants(v, name, result);
            }
        }
        Value::Array(a) => {
            for v in a {
                descendants(v, name, result);
            }
        }
        _ => (),
    }
}
