//! Translate replacement tokens explicitly: .NET numbers unnamed groups first.
pub(crate) fn translate(
    pattern: &str,
    replacement: &str,
    ignore_case: bool,
) -> Result<(String, String), &'static str> {
    if pattern.len() > 4096
        || replacement.len() > 4096
        || pattern.contains("(?P")
        || pattern.contains("(?'")
        || ["&&", "--", "~~", "^^"].iter().any(|s| pattern.contains(s))
    {
        return Err("正则语法或长度需人工检查，未转换");
    }
    let regex = regex::RegexBuilder::new(pattern)
        .size_limit(1024 * 1024)
        .nest_limit(64)
        .build()
        .map_err(|_| "正则使用未支持的语法（例如回溯引用或环视），未转换")?;
    let names: Vec<_> = regex.capture_names().collect();
    let numbers: Vec<_> = std::iter::once(0)
        .chain((1..names.len()).filter(|&i| names[i].is_none()))
        .chain((1..names.len()).filter(|&i| names[i].is_some()))
        .collect();
    let resolve = |token: &str| {
        if token.bytes().all(|c| c.is_ascii_digit()) && !token.is_empty() {
            token
                .parse::<usize>()
                .ok()
                .and_then(|n| numbers.get(n).copied())
        } else {
            names.iter().position(|n| *n == Some(token))
        }
    };
    let mut output = String::new();
    let mut rest = replacement;
    while let Some(pos) = rest.find('$') {
        output.push_str(&rest[..pos]);
        rest = &rest[pos + 1..];
        if let Some(tail) = rest.strip_prefix('$') {
            output.push_str("$$");
            rest = tail;
            continue;
        }
        if let Some(tail) = rest.strip_prefix('&') {
            output.push_str("${0}");
            rest = tail;
            continue;
        }
        if rest.starts_with(['`', '\'', '+', '_']) {
            return Err("替换引用了匹配前后文、整行或最后捕获组，需单独迁移，未转换");
        }
        if let Some(tail) = rest.strip_prefix('{')
            && let Some(end) = tail.find('}') {
                let token = &tail[..end];
                if let Some(index) = resolve(token) {
                    output.push_str(&format!("${{{index}}}"));
                } else {
                    output.push_str("$${");
                    output.push_str(token);
                    output.push('}');
                }
                rest = &tail[end + 1..];
                continue;
            }
        let end = rest.bytes().take_while(|c| c.is_ascii_digit()).count();
        if end > 0 {
            let token = &rest[..end];
            if let Some(index) = resolve(token) {
                output.push_str(&format!("${{{index}}}"));
            } else {
                output.push_str("$$");
                output.push_str(token);
            }
            rest = &rest[end..];
        } else {
            // .NET treats unrecognized substitutions as literal dollar text.
            output.push_str("$$");
        }
    }
    output.push_str(rest);
    Ok((
        if ignore_case {
            format!("(?i:{pattern})")
        } else {
            pattern.into()
        },
        output,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn maps_dotnet_group_order_and_literal_dollars_without_prefix_ambiguity() {
        let (_, replacement) = translate(
            "(?<名>甲)(乙)",
            "$1a|$2|${名}|$&|$$|$99|$word|${absent}|$",
            false,
        )
        .unwrap();
        assert_eq!(
            replacement,
            "${2}a|${1}|${1}|${0}|$$|$$99|$$word|$${absent}|$$"
        );
        assert_eq!(
            translate("a", r"\n", true).unwrap(),
            ("(?i:a)".into(), r"\n".into())
        );
        for replacement in ["$`", "$'", "$+", "$_"] {
            assert!(translate("a", replacement, false).is_err());
        }
        for pattern in [r"(a)\1", "(?<=a)b", "(?<name>a)(?<name>b)", "[a-z&&x]"] {
            assert!(translate(pattern, "", false).is_err());
        }
    }
}
