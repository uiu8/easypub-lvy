//! Token-level dependency inventory; does not fetch or rewrite resources.
use cssparser::{ParseError, Parser, ParserInput, Token};
use serde::Serialize;

#[derive(Debug, Default, Serialize)]
pub struct Report {
    pub references: Vec<String>,
    pub incomplete: bool,
    #[serde(skip)]
    pub occurrences: Vec<Occurrence>,
}
#[derive(Debug)]
pub struct Occurrence {
    pub start: usize,
    pub end: usize,
    pub is_import: bool,
    pub as_url: bool,
}
/// Replace only URL token spans; leave comments, conditions and rule order intact.
pub fn rewrite(css: &str, report: &Report, replacements: &[String]) -> Option<String> {
    if report.incomplete || replacements.len() != report.occurrences.len() {
        return None;
    }
    let mut output = String::new();
    let mut offset = 0;
    for (span, replacement) in report.occurrences.iter().zip(replacements) {
        output.push_str(css.get(offset..span.start)?);
        if span.as_url {
            output.push_str("url(");
        }
        cssparser::serialize_string(replacement, &mut output).ok()?;
        if span.as_url {
            output.push(')');
        }
        offset = span.end;
    }
    output.push_str(css.get(offset..)?);
    Some(output)
}
pub fn inspect(css: &str) -> Report {
    let mut input = ParserInput::new(css);
    let mut parser = Parser::new(&mut input);
    let mut report = Report::default();
    report.incomplete = walk(&mut parser, &mut report, 0, false).is_err();
    report
}
#[derive(Debug, Serialize)]
pub struct Resolution {
    pub reference: String,
    pub kind: &'static str,
    pub local_path: Option<String>,
    pub fragment: Option<String>,
}
/// Resolve URL spelling only. File availability and immutable bytes are separate.
pub fn resolve(reference: &str, base: &str) -> Resolution {
    let value = reference.trim();
    let mut result = Resolution {
        reference: reference.into(),
        kind: "unresolved",
        local_path: None,
        fragment: None,
    };
    if value.is_empty() {
        result.kind = "empty";
        return result;
    }
    if let Some(fragment) = value.strip_prefix('#') {
        result.kind = "document_fragment";
        result.fragment = Some(fragment.into());
        return result;
    }
    if value.starts_with("//") || value.starts_with(r"\\") {
        result.kind = "network";
        return result;
    }
    let url = reqwest::Url::parse(value).ok().or_else(|| {
        if base.is_empty() {
            return None;
        }
        reqwest::Url::from_directory_path(base)
            .ok()?
            .join(value)
            .ok()
    });
    let Some(mut url) = url else {
        return result;
    };
    result.fragment = url.fragment().map(str::to_owned);
    match url.scheme() {
        "data" => result.kind = "inline_data",
        "http" | "https" => result.kind = "network",
        "file" => {
            if url
                .host_str()
                .is_some_and(|host| !host.is_empty() && host != "localhost")
            {
                result.kind = "network";
                return result;
            }
            url.set_fragment(None);
            url.set_query(None);
            if let Ok(path) = url.to_file_path() {
                result.kind = "local";
                result.local_path = Some(path.to_string_lossy().into_owned());
            }
        }
        _ => result.kind = "unsupported_scheme",
    }
    result
}
fn push<'i>(
    parser: &Parser<'i, '_>,
    values: &mut Report,
    value: &str,
    start: usize,
    is_import: bool,
    as_url: bool,
) -> Result<(), ParseError<'i, ()>> {
    if values.references.len() >= 512 {
        return Err(parser.new_custom_error(()));
    }
    values.references.push(value.to_owned());
    values.occurrences.push(Occurrence {
        start,
        end: parser.position().byte_index(),
        is_import,
        as_url,
    });
    Ok(())
}
fn walk<'i>(
    parser: &mut Parser<'i, '_>,
    values: &mut Report,
    depth: usize,
    strings_are_urls: bool,
) -> Result<(), ParseError<'i, ()>> {
    if depth > 64 {
        return Err(parser.new_custom_error(()));
    }
    while !parser.is_exhausted() {
        parser.skip_whitespace();
        let start = parser.position().byte_index();
        let token = parser.next()?.clone();
        match token {
            Token::AtKeyword(name) if name.eq_ignore_ascii_case("import") => {
                parser.skip_whitespace();
                let start = parser.position().byte_index();
                let value = parser.expect_url_or_string()?.to_string();
                push(parser, values, &value, start, true, false)?;
            }
            Token::UnquotedUrl(value) => push(parser, values, &value, start, false, true)?,
            Token::Function(name) if name.eq_ignore_ascii_case("url") => {
                let value = parser.parse_nested_block(|inner| {
                    let value = inner.expect_string_cloned()?;
                    inner.expect_exhausted()?;
                    Ok(value.to_string())
                })?;
                push(parser, values, &value, start, false, true)?;
            }
            Token::Function(name)
                if name.eq_ignore_ascii_case("image-set")
                    || name.eq_ignore_ascii_case("-webkit-image-set") =>
            {
                parser.parse_nested_block(|inner| walk(inner, values, depth + 1, true))?;
            }
            Token::QuotedString(value) if strings_are_urls => {
                push(parser, values, &value, start, false, false)?
            }
            Token::Function(_)
            | Token::ParenthesisBlock
            | Token::SquareBracketBlock
            | Token::CurlyBracketBlock => {
                parser.parse_nested_block(|inner| walk(inner, values, depth + 1, false))?;
            }
            token if token.is_parse_error() => return Err(parser.new_custom_error(())),
            _ => {}
        }
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn replacements_preserve_conditions_comments_and_unicode() {
        let css = r#"/* 汉字 */ @import url("base") layer(theme) supports(display: grid) screen; p { background: u\72l(a.png); content: "a.png"; mask: url("图.svg#x"); }"#;
        let report = inspect(css);
        assert!(report.occurrences[0].is_import);
        let output = rewrite(
            css,
            &report,
            &["a.css".into(), "b.png".into(), "c.svg#x".into()],
        )
        .unwrap();
        assert_eq!(
            output,
            r#"/* 汉字 */ @import "a.css" layer(theme) supports(display: grid) screen; p { background: url("b.png"); content: "a.png"; mask: url("c.svg#x"); }"#
        );
        assert_eq!(inspect(&output).references, ["a.css", "b.png", "c.svg#x"]);
    }
    #[test]
    fn local_urls_have_explicit_base_and_keep_fragment() {
        let base = std::env::temp_dir().join("EasyPub CSS");
        let r = resolve("images/%E5%9B%BE%20a.png?v=2#part", base.to_str().unwrap());
        assert_eq!(r.kind, "local");
        assert_eq!(
            std::path::Path::new(r.local_path.as_ref().unwrap()),
            base.join("images").join("图 a.png")
        );
        assert_eq!(r.fragment.as_deref(), Some("part"));
        assert_eq!(resolve("relative.png", "").kind, "unresolved");
        assert_eq!(resolve("#x", "").kind, "document_fragment");
        assert_eq!(
            resolve("data:image/png;base64,AAAA", "").kind,
            "inline_data"
        );
        assert_eq!(resolve("https://example.com/a.png", "").kind, "network");
        assert_eq!(resolve("//server/share/a.png", "").kind, "network");
        assert_eq!(resolve("file://server/share/a.png", "").kind, "network");
    }
    #[test]
    fn nested_escaped_urls_and_imports_ignore_comments_and_content() {
        let report = inspect(
            r#"/* url(fake) */ @import "base.css" layer(base); @media print { p { background: u\72l("图 片.png"); mask: url(mask.svg#x); content: "url(fake)"; } }"#,
        );
        assert!(!report.incomplete);
        assert_eq!(report.references, ["base.css", "图 片.png", "mask.svg#x"]);
    }
    #[test]
    fn budgets_and_bad_tokens_are_not_reported_as_complete() {
        assert!(inspect(&format!("{}{}", "a{".repeat(66), "}".repeat(66))).incomplete);
        assert!(inspect(&"a{background:url(x)}".repeat(513)).incomplete);
        assert!(inspect("a{background:url(a b)}").incomplete);
        assert!(inspect("a{color:red}").references.is_empty());
    }
    #[test]
    fn image_set_strings_and_url_candidates() {
        let report = inspect(
            r#"p { background:image-set("a.png" 1x, "b.png" 2x, url(c.png) 3x, "d.png" type("image/png") 4x) }"#,
        );
        assert!(!report.incomplete);
        assert_eq!(report.references, ["a.png", "b.png", "c.png", "d.png"]);
    }
}
