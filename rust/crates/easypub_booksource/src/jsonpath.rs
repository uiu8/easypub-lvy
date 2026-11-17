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
    Slice(Option<isize>, Option<isize>, isize),
    All,
    Descendant(String),
    DescendantAll,
    Filter(String),
}

fn parse(text: &str) -> Option<Vec<Step>> {
    let text = text.trim();
    if text.is_empty() {
        return None;
    }
    let mut rest = text.strip_prefix('$').unwrap_or(text);
    let mut steps = Vec::new();
    // 不写 $ 的裸字段：`name`、`data.list`。
    if !text.starts_with('$') && !rest.starts_with('.') && !rest.starts_with('[') {
        rest = text;
        let end = rest.find(['.', '[']).unwrap_or(rest.len());
        if !bare_field(&rest[..end]) {
            return None;
        }
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
            if !bare_field(&rest[..end]) {
                return None;
            }
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
            if !bare_field(&rest[..end]) {
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

fn bare_field(name: &str) -> bool {
    !name.is_empty()
        && !name
            .chars()
            .any(|c| c.is_whitespace() || "'\"()]=!<>|&?,{}".contains(c))
}

fn valid_condition(expr: &str) -> bool {
    for separator in ["||", "&&"] {
        let Some(parts) = split_top(expr, separator) else {
            return false;
        };
        if parts.len() > 1 {
            return parts.iter().all(|p| valid_condition(p));
        }
    }
    let expr = expr.trim();
    if let Some(inner) = expr.strip_prefix('(').and_then(|s| s.strip_suffix(')')) {
        return valid_condition(inner);
    }
    let valid_operand = |text: &str| {
        if let Some(path) = text.trim().strip_prefix('@') {
            parse(&format!("${path}")).is_some()
        } else {
            unquote(text).is_some()
                || serde_json::from_str::<Value>(text)
                    .is_ok_and(|v| !v.is_array() && !v.is_object())
        }
    };
    for op in ["==", "!=", "<=", ">=", "<", ">"] {
        let Some(parts) = split_top(expr, op) else {
            return false;
        };
        if parts.len() > 1 {
            return parts.len() == 2 && parts.iter().all(|p| valid_operand(p));
        }
    }
    valid_operand(expr)
}

fn bracket_end(text: &str) -> Option<usize> {
    quoted_group_end(text, '[', ']')
}

fn quoted_group_end(text: &str, open: char, close: char) -> Option<usize> {
    let (mut depth, mut quote, mut escaped) = (0, None, false);
    for (i, c) in text.char_indices() {
        if let Some(q) = quote {
            if escaped {
                escaped = false;
                continue;
            }
            if c == '\\' {
                escaped = true;
                continue;
            }
            if c == q {
                quote = None;
            }
            continue;
        }
        match c {
            '\'' | '"' => quote = Some(c),
            c if c == open => depth += 1,
            c if c == close => {
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

// 只在字符串和嵌套括号之外识别分隔符。
fn split_top<'a>(text: &'a str, separator: &str) -> Option<Vec<&'a str>> {
    let (mut quote, mut escaped, mut depth) = (None, false, 0usize);
    let mut parts = Vec::new();
    let mut start = 0;
    for (i, c) in text.char_indices() {
        if i < start {
            continue;
        }
        if let Some(q) = quote {
            if escaped {
                escaped = false;
            } else if c == '\\' {
                escaped = true;
            } else if c == q {
                quote = None;
            }
            continue;
        }
        if depth == 0 && text[i..].starts_with(separator) {
            parts.push(text[start..i].trim());
            start = i + separator.len();
            continue;
        }
        match c {
            '\'' | '"' => quote = Some(c),
            '[' | '(' => depth += 1,
            ']' | ')' => depth = depth.checked_sub(1)?,
            _ => (),
        }
    }
    if quote.is_some() || depth != 0 {
        return None;
    }
    parts.push(text[start..].trim());
    Some(parts)
}

fn unquote(s: &str) -> Option<String> {
    let s = s.trim();
    if s.len() < 2 {
        return None;
    }
    if s.starts_with('"') {
        return serde_json::from_str::<String>(s).ok();
    }
    if !s.starts_with('\'') || !s.ends_with('\'') {
        return None;
    }
    let mut json = String::from("\"");
    let mut chars = s[1..s.len() - 1].chars();
    while let Some(c) = chars.next() {
        match c {
            '\'' => return None,
            '"' => json.push_str("\\\""),
            '\\' => match chars.next()? {
                '\'' => json.push('\''),
                next => {
                    json.push('\\');
                    json.push(next);
                }
            },
            _ => json.push(c),
        }
    }
    json.push('"');
    serde_json::from_str(&json).ok()
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
        return valid_condition(filter).then(|| Step::Filter(filter.to_owned()));
    }
    if inside.contains(':') && !inside.contains('\'') && !inside.contains('"') {
        let parts = inside.split(':').collect::<Vec<_>>();
        if !(2..=3).contains(&parts.len()) {
            return None;
        }
        let number = |p: &str| -> Option<Option<isize>> {
            if p.trim().is_empty() {
                Some(None)
            } else {
                Some(Some(p.trim().parse().ok()?))
            }
        };
        let start = number(parts[0])?;
        let end = number(parts[1])?;
        let step = if parts.len() == 3 {
            number(parts[2])?.unwrap_or(1)
        } else {
            1
        };
        if step == 0 {
            return None;
        }
        return Some(Step::Slice(start, end, step));
    }

    let items = split_top(inside, ",")?;
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
fn operand(text: &str, item: &Value) -> Result<Option<Value>, String> {
    let text = text.trim();
    if let Some(path) = text.strip_prefix('@') {
        let found = select(item, &format!("${path}"))?;
        return Ok(found.into_iter().next());
    }
    if let Some(s) = unquote(text) {
        return Ok(Some(Value::String(s)));
    }
    Ok(serde_json::from_str(text).ok())
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

fn condition(expr: &str, item: &Value) -> Result<bool, String> {
    if let Some(parts) = split_top(expr, "||") {
        if parts.len() > 1 {
            for part in parts {
                if condition(part, item)? {
                    return Ok(true);
                }
            }
            return Ok(false);
        }
    } else {
        return Err("JSONPath 过滤条件无效".into());
    }
    if let Some(parts) = split_top(expr, "&&") {
        if parts.len() > 1 {
            for part in parts {
                if !condition(part, item)? {
                    return Ok(false);
                }
            }
            return Ok(true);
        }
    } else {
        return Err("JSONPath 过滤条件无效".into());
    }
    let expr = expr.trim();
    if let Some(inner) = expr.strip_prefix('(').and_then(|s| s.strip_suffix(')')) {
        return condition(inner, item);
    }
    for op in ["==", "!=", "<=", ">=", "<", ">"] {
        let Some(parts) = split_top(expr, op) else {
            return Err("JSONPath 过滤条件无效".into());
        };
        if parts.len() == 2 {
            let (l, r) = (parts[0], parts[1]);
            let (Some(a), Some(b)) = (operand(l, item)?, operand(r, item)?) else {
                return Ok(op == "!=");
            };
            let ord = compare(&a, &b);
            use std::cmp::Ordering::*;
            return Ok(match op {
                "==" => ord == Some(Equal),
                "!=" => ord != Some(Equal),
                "<=" => matches!(ord, Some(Less | Equal)),
                ">=" => matches!(ord, Some(Greater | Equal)),
                "<" => ord == Some(Less),
                _ => ord == Some(Greater),
            });
        }
    }
    Ok(operand(expr, item)?.is_some_and(|v| !matches!(v, Value::Null | Value::Bool(false))))
}

fn run<'a>(root: &'a Value, steps: &[Step]) -> Result<Vec<&'a Value>, String> {
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
                Step::Slice(start, end, step) => {
                    if let Some(a) = value.as_array() {
                        let len = a.len() as isize;
                        let reverse = *step < 0;
                        let norm = |n: isize| {
                            let n = if n < 0 { len.saturating_add(n) } else { n };
                            if reverse {
                                n.clamp(-1, len - 1)
                            } else {
                                n.clamp(0, len)
                            }
                        };
                        let mut index =
                            start.map(norm).unwrap_or(if reverse { len - 1 } else { 0 });
                        let end = end.map(norm).unwrap_or(if reverse { -1 } else { len });
                        while if reverse { index > end } else { index < end } {
                            if let Some(value) = a.get(index as usize) {
                                next.push(value);
                            }
                            let Some(n) = index.checked_add(*step) else {
                                break;
                            };
                            index = n;
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
                    Value::Array(a) => {
                        for item in a {
                            if condition(expr, item)? {
                                next.push(item);
                            }
                        }
                    }
                    Value::Object(_) if condition(expr, value)? => next.push(value),
                    _ => (),
                },
            }
            if next.len() > LIMIT {
                return Err("JSONPath 匹配结果超过 50000 项，请缩小书源规则范围".into());
            }
        }
        values = next;
    }
    Ok(values)
}

/// 有效路径未命中返回空列表；无效或不支持的写法明确报错。
pub fn select(root: &Value, path: &str) -> Result<Vec<Value>, String> {
    #[cfg(test)]
    if crate::corpus::broken(2) {
        return Ok(Vec::new());
    }
    let steps =
        parse(path).ok_or_else(|| "JSONPath 写法不受支持或语法无效，请修改书源规则".to_string())?;
    Ok(run(root, &steps)?.into_iter().cloned().collect())
}

pub fn value_text(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

/// 字符串规则：路径中含 `{$.x}` 时为模板替换，否则取到的值逐个转文字（数组展开）。
pub fn strings(root: &Value, rule: &str) -> Result<Vec<String>, String> {
    if rule.contains("{$") {
        let mut out = String::new();
        let mut rest = rule;
        while let Some(start) = rest.find("{$") {
            out.push_str(&rest[..start]);
            let Some(end) = quoted_group_end(&rest[start..], '{', '}') else {
                return Err("JSONPath 模板缺少结束括号".into());
            };
            let path = &rest[start + 1..start + end];
            out.push_str(
                &select(root, path)?
                    .iter()
                    .map(value_text)
                    .collect::<Vec<_>>()
                    .join(","),
            );
            rest = &rest[start + end + 1..];
        }
        out.push_str(rest);
        return Ok(vec![out]);
    }
    Ok(select(root, rule)?
        .into_iter()
        .flat_map(|v| match v {
            Value::Array(a) => a.into_iter().map(|v| value_text(&v)).collect(),
            v => vec![value_text(&v)],
        })
        .filter(|s| !s.is_empty())
        .collect())
}

/// 列表规则：取到的数组展开成各项。
pub fn elements(root: &Value, rule: &str) -> Result<Vec<Value>, String> {
    Ok(select(root, rule)?
        .into_iter()
        .flat_map(|v| match v {
            Value::Array(a) => a,
            v => vec![v],
        })
        .collect())
}
