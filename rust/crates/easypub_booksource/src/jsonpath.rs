//! JSONPath 子集：`$`、`.字段`、`['字段']`、`[*]`、`[n]`、`[n,m]`、`[起:止]`、`..字段`、
//! 过滤 `[?(@.a)]`、`[?(@.a == 'x')]`（`==`、`!=`、`<`、`<=`、`>`、`>=`，可用 `&&` / `||` 连接）。
//! 不写 `$` 的规则按 `$.规则` 处理；字符串里的 `{$.路径}` 会被替换成取到的值。
use serde_json::Value;

const LIMIT: usize = 50_000;

#[derive(Debug, Clone)]
enum Step {
    Field(String),
    Fields(Vec<String>),
    Indexes(Vec<isize>),
    Slice(Option<isize>, Option<isize>),
    All,
    Descendant(String),
    DescendantAll,
    Filter(String),
}

fn parse(text: &str) -> Option<Vec<Step>> {
    let text = text.trim();
    let mut rest = text.strip_prefix('$').unwrap_or(text);
    let mut steps = Vec::new();
    // 不写 $ 的裸字段：`name`、`data.list`。
    if !text.starts_with('$') && !rest.starts_with('.') && !rest.starts_with('[') {
        rest = text;
        let end = rest.find(['.', '[']).unwrap_or(rest.len());
        steps.push(Step::Field(rest[..end].to_owned()));
        rest = &rest[end..];
    }
    while !rest.is_empty() {
        if let Some(r) = rest.strip_prefix("..") {
            rest = r;
            if let Some(r) = rest.strip_prefix('*') {
                steps.push(Step::DescendantAll);
                rest = r;
                continue;
            }
            if rest.starts_with('[') {
                steps.push(Step::DescendantAll);
                continue;
            }
            let end = rest.find(['.', '[']).unwrap_or(rest.len());
            steps.push(Step::Descendant(rest[..end].to_owned()));
            rest = &rest[end..];
        } else if let Some(r) = rest.strip_prefix('.') {
            rest = r;
            // `$.[*]`：点后直接是方括号。
            if rest.starts_with('[') {
                continue;
            }
            if let Some(r) = rest.strip_prefix('*') {
                steps.push(Step::All);
                rest = r;
                continue;
            }
            let end = rest.find(['.', '[']).unwrap_or(rest.len());
            if end == 0 {
                return None;
            }
            steps.push(Step::Field(rest[..end].to_owned()));
            rest = &rest[end..];
        } else if rest.starts_with('[') {
            let end = bracket_end(rest)?;
            let inside = rest[1..end].trim();
            rest = &rest[end + 1..];
            steps.push(bracket(inside)?);
        } else {
            return None;
        }
    }
    Some(steps)
}

fn bracket_end(text: &str) -> Option<usize> {
    let (mut depth, mut quote) = (0, None);
    for (i, c) in text.char_indices() {
        if let Some(q) = quote {
            if c == q {
                quote = None;
            }
            continue;
        }
        match c {
            '\'' | '"' => quote = Some(c),
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if depth == 0 {
                    return Some(i);
                }
            }
            _ => (),
        }
    }
    None
}

fn unquote(s: &str) -> Option<String> {
    let s = s.trim();
    ((s.starts_with('\'') && s.ends_with('\'')) || (s.starts_with('"') && s.ends_with('"')))
        .then(|| s[1..s.len() - 1].to_owned())
        .filter(|_| s.len() >= 2)
}

fn bracket(inside: &str) -> Option<Step> {
    if inside == "*" {
        return Some(Step::All);
    }
    if let Some(filter) = inside.strip_prefix('?') {
        let filter = filter.trim();
        let filter = filter
            .strip_prefix('(')
            .and_then(|f| f.strip_suffix(')'))
            .unwrap_or(filter);
        return Some(Step::Filter(filter.to_owned()));
    }
    if inside.contains(':') && !inside.contains('\'') && !inside.contains('"') {
        let mut parts = inside
            .splitn(2, ':')
            .map(|p| p.trim().parse::<isize>().ok());
        return Some(Step::Slice(parts.next().flatten(), parts.next().flatten()));
    }
    let items: Vec<&str> = inside.split(',').map(str::trim).collect();
    if let Some(indexes) = items
        .iter()
        .map(|i| i.parse::<isize>().ok())
        .collect::<Option<Vec<_>>>()
    {
        return Some(Step::Indexes(indexes));
    }
    let fields = items
        .iter()
        .map(|i| unquote(i))
        .collect::<Option<Vec<_>>>()?;
    Some(if fields.len() == 1 {
        Step::Field(fields.into_iter().next().unwrap())
    } else {
        Step::Fields(fields)
    })
}

fn descendants<'a>(value: &'a Value, name: Option<&str>, out: &mut Vec<&'a Value>) {
    match value {
        Value::Object(o) => {
            if let Some(name) = name {
                if let Some(v) = o.get(name) {
                    out.push(v);
                }
            } else {
                out.extend(o.values());
            }
            for v in o.values() {
                descendants(v, name, out);
            }
        }
        Value::Array(a) => {
            if name.is_none() {
                out.extend(a);
            }
            for v in a {
                descendants(v, name, out);
            }
        }
        _ => (),
    }
}

/// 过滤条件里的值：`@.路径`、字符串、数字、true / false / null。
fn operand(text: &str, item: &Value) -> Option<Value> {
    let text = text.trim();
    if let Some(path) = text.strip_prefix('@') {
        let found = select(item, &format!("${path}"));
        return found.into_iter().next();
    }
    if let Some(s) = unquote(text) {
        return Some(Value::String(s));
    }
    serde_json::from_str(text).ok()
}

fn compare(a: &Value, b: &Value) -> Option<std::cmp::Ordering> {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64()?.partial_cmp(&y.as_f64()?),
        (Value::String(x), Value::String(y)) => Some(x.cmp(y)),
        (Value::Number(x), Value::String(y)) | (Value::String(y), Value::Number(x)) => {
            let ord = x.as_f64()?.partial_cmp(&y.parse::<f64>().ok()?)?;
            Some(if matches!(a, Value::Number(_)) {
                ord
            } else {
                ord.reverse()
            })
        }
        _ => (a == b).then_some(std::cmp::Ordering::Equal),
    }
}

fn condition(expr: &str, item: &Value) -> bool {
    if let Some((l, r)) = expr.split_once("||") {
        return condition(l, item) || condition(r, item);
    }
    if let Some((l, r)) = expr.split_once("&&") {
        return condition(l, item) && condition(r, item);
    }
    for op in ["==", "!=", "<=", ">=", "<", ">"] {
        if let Some((l, r)) = expr.split_once(op) {
            let (Some(a), Some(b)) = (operand(l, item), operand(r, item)) else {
                return op == "!=";
            };
            let ord = compare(&a, &b);
            use std::cmp::Ordering::*;
            return match op {
                "==" => ord == Some(Equal),
                "!=" => ord != Some(Equal),
                "<=" => matches!(ord, Some(Less | Equal)),
                ">=" => matches!(ord, Some(Greater | Equal)),
                "<" => ord == Some(Less),
                _ => ord == Some(Greater),
            };
        }
    }
    operand(expr, item).is_some_and(|v| !matches!(v, Value::Null | Value::Bool(false)))
}

fn run<'a>(root: &'a Value, steps: &[Step]) -> Vec<&'a Value> {
    let mut values = vec![root];
    for step in steps {
        let mut next = Vec::new();
        for value in values {
            match step {
                Step::Field(name) => {
                    if let Some(v) = value.get(name) {
                        next.push(v);
                    } else if let Value::Array(a) = value {
                        // 对数组取字段：逐项取（与阅读的宽松写法一致）。
                        next.extend(a.iter().filter_map(|v| v.get(name)));
                    }
                }
                Step::Fields(names) => next.extend(names.iter().filter_map(|n| value.get(n))),
                Step::Indexes(indexes) => {
                    if let Some(a) = value.as_array() {
                        for i in indexes {
                            let n = if *i < 0 { a.len() as isize + i } else { *i };
                            if n >= 0
                                && let Some(v) = a.get(n as usize)
                            {
                                next.push(v);
                            }
                        }
                    }
                }
                Step::Slice(start, end) => {
                    if let Some(a) = value.as_array() {
                        let len = a.len() as isize;
                        let norm = |n: isize| if n < 0 { (len + n).max(0) } else { n.min(len) };
                        let (s, e) = (norm(start.unwrap_or(0)), norm(end.unwrap_or(len)));
                        if s < e {
                            next.extend(&a[s as usize..e as usize]);
                        }
                    }
                }
                Step::All => match value {
                    Value::Array(a) => next.extend(a),
                    Value::Object(o) => next.extend(o.values()),
                    _ => (),
                },
                Step::Descendant(name) => descendants(value, Some(name), &mut next),
                Step::DescendantAll => descendants(value, None, &mut next),
                Step::Filter(expr) => match value {
                    Value::Array(a) => next.extend(a.iter().filter(|v| condition(expr, v))),
                    Value::Object(_) if condition(expr, value) => next.push(value),
                    _ => (),
                },
            }
            if next.len() > LIMIT {
                break;
            }
        }
        values = next;
    }
    values
}

/// 按路径取值；路径写错时为空。
pub fn select(root: &Value, path: &str) -> Vec<Value> {
    #[cfg(test)]
    if crate::corpus::broken(2) {
        return Vec::new();
    }
    parse(path)
        .map(|steps| run(root, &steps).into_iter().cloned().collect())
        .unwrap_or_default()
}

pub fn value_text(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

/// 字符串规则：路径中含 `{$.x}` 时为模板替换，否则取到的值逐个转文字（数组展开）。
pub fn strings(root: &Value, rule: &str) -> Vec<String> {
    if rule.contains("{$") {
        let mut out = String::new();
        let mut rest = rule;
        while let Some(start) = rest.find("{$") {
            out.push_str(&rest[..start]);
            let Some(end) = rest[start..].find('}') else {
                out.push_str(&rest[start..]);
                rest = "";
                break;
            };
            let path = &rest[start + 1..start + end];
            out.push_str(
                &select(root, path)
                    .iter()
                    .map(value_text)
                    .collect::<Vec<_>>()
                    .join(","),
            );
            rest = &rest[start + end + 1..];
        }
        out.push_str(rest);
        return vec![out];
    }
    select(root, rule)
        .into_iter()
        .flat_map(|v| match v {
            Value::Array(a) => a.into_iter().map(|v| value_text(&v)).collect(),
            v => vec![value_text(&v)],
        })
        .filter(|s| !s.is_empty())
        .collect()
}

/// 列表规则：取到的数组展开成各项。
pub fn elements(root: &Value, rule: &str) -> Vec<Value> {
    select(root, rule)
        .into_iter()
        .flat_map(|v| match v {
            Value::Array(a) => a,
            v => vec![v],
        })
        .collect()
}
