//! JS 词法辅助：能力扫描排除注释和字面量；运行时模板共用 token 结束边界。
//! 静态扫描失败不作为运行准入拒绝；模板边界识别失败返回 None。
use ress::{Scanner, tokens::Token};

pub fn code(text: &str) -> String {
    let mut out = String::new();
    for item in Scanner::new(text) {
        let Ok(item) = item else { break };
        match item.token {
            Token::Comment(_) => out.push(' '),
            Token::String(_) | Token::RegEx(_) | Token::Template(_) => out.push_str(" ; "),
            Token::Ident(_) | Token::Keyword(_) => {
                out.push_str(&text[item.span.start..item.span.end]);
                out.push(' ');
            }
            _ => out.push_str(&text[item.span.start..item.span.end]),
        }
    }
    // 名称之间的空格保留；属性访问允许原始脚本里的空白和注释。
    static DOT: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    DOT.get_or_init(|| regex::Regex::new(r"\s*\.\s*").unwrap())
        .replace_all(&out, ".")
        .into_owned()
}

pub fn fragments(text: &str) -> String {
    let mut out = String::new();
    let mut remaining = text;
    while let Some(start) = remaining.find("<js>") {
        let tail = &remaining[start + 4..];
        let Some(end) = tail.find("</js>") else { break };
        out.push_str(&code(&tail[..end]));
        out.push('\n');
        remaining = &tail[end + 5..];
    }
    if let Some((_, js)) = remaining.split_once("@js:") {
        out.push_str(&code(js));
    }
    // 规则模板的外层分隔符不属于 JS；用 token 找结束位置，避免字符串里的 }} 提前结束。
    let mut tail = text;
    while let Some(start) = tail.find("{{") {
        let script = &tail[start + 2..];
        let Some(end) = template_end(script) else {
            break;
        };
        out.push_str(&code(&script[..end]));
        out.push('\n');
        tail = &script[end + 2..];
    }
    out
}

/// 输入从 {{ 之后开始；只有 JS token 外层的 }} 才是结束符。
pub(crate) fn template_end(script: &str) -> Option<usize> {
    let mut depth = 0usize;
    let wrapped = format!("{{{script}");
    for item in Scanner::new(&wrapped).skip(1) {
        let item = item.ok()?;
        if item.token == "{" {
            depth += 1;
        }
        if item.token == "}" {
            if depth == 0 && script[item.span.start - 1..].starts_with("}}") {
                return Some(item.span.start - 1);
            }
            depth = depth.saturating_sub(1);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn literals_comments_and_nested_template_interpolations_are_distinct() {
        let text = r#"
            // java.comment()
            /* java.block() */
            'java.string()'; /java.regex\(\)/.test('x');
            `java.raw() ${java.actual()} ${`nested ${java.nested()}`}`;
            if (true) /java.afterIf/.test('x');
            const ratio = 10 / 2; java /* comment */ . live();
        "#;
        let found = code(text);
        for name in ["comment", "block", "string", "regex", "raw", "afterIf"] {
            assert!(!found.contains(&format!("java.{name}")), "{found}");
        }
        for name in ["actual", "nested", "live"] {
            assert!(found.contains(&format!("java.{name}")), "{found}");
        }
        assert!(fragments(r#"/search?q={{ '}}' + java.template() }}"#).contains("java.template"));
    }
}
