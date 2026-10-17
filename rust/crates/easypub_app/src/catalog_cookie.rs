//! Explicitly supported imports; never persist or include credential values in errors.
use serde_json::Value;

const MAX_IMPORT: usize = 512 * 1024;
const MAX_HEADER: usize = 16 * 1024;
struct Cookie {
    name: String,
    value: String,
    domain: String,
    path: String,
    host_only: bool,
    expires: Option<f64>,
}
type Result<T> = std::result::Result<T, &'static str>;
fn invalid<T>() -> Result<T> {
    Err("invalid_cookie_format")
}
fn pair(name: &str, value: &str) -> Result<()> {
    if name.is_empty()
        || !name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&b))
    {
        return invalid();
    }
    let value = value
        .strip_prefix('"')
        .and_then(|v| v.strip_suffix('"'))
        .unwrap_or(value);
    if !value
        .bytes()
        .all(|b| matches!(b, 0x21 | 0x23..=0x2b | 0x2d..=0x3a | 0x3c..=0x5b | 0x5d..=0x7e))
    {
        return invalid();
    }
    Ok(())
}
fn string(v: &Value, key: &str) -> Result<String> {
    v.get(key)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or("invalid_cookie_format")
}
fn domain(value: &str) -> Result<String> {
    let value = value
        .strip_prefix('.')
        .unwrap_or(value)
        .to_ascii_lowercase();
    if value.is_empty()
        || value.split('.').any(|label| {
            label.is_empty()
                || label.starts_with('-')
                || label.ends_with('-')
                || !label
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-')
        })
    {
        return invalid();
    }
    Ok(value)
}
fn json_cookies(text: &str) -> Result<Vec<Cookie>> {
    let value: Value = serde_json::from_str(text).map_err(|_| "invalid_cookie_format")?;
    let items = value
        .as_array()
        .or_else(|| value.get("cookies").and_then(Value::as_array))
        .ok_or("invalid_cookie_format")?;
    if items.len() > 4096 {
        return Err("cookie_import_too_large");
    }
    items
        .iter()
        .map(|v| {
            if v.get("partitionKey").is_some_and(|p| !p.is_null()) {
                return Err("cookie_partition_unsupported");
            }
            let raw_domain = string(v, "domain")?;
            let host_only = match v.get("hostOnly") {
                None => !raw_domain.starts_with('.'),
                Some(x) => x.as_bool().ok_or("invalid_cookie_format")?,
            };
            let session = match v.get("session") {
                None => false,
                Some(x) => x.as_bool().ok_or("invalid_cookie_format")?,
            };
            let expiry = v.get("expirationDate").or_else(|| v.get("expires"));
            let expires = match expiry {
                None => None,
                Some(x) => {
                    let n = x.as_f64().ok_or("invalid_cookie_format")?;
                    if session || n == -1.0 { None } else { Some(n) }
                }
            };
            let c = Cookie {
                name: string(v, "name")?,
                value: string(v, "value")?,
                domain: domain(&raw_domain)?,
                path: string(v, "path")?,
                host_only,
                expires,
            };
            validate(&c)?;
            Ok(c)
        })
        .collect()
}
fn netscape(text: &str) -> Result<Vec<Cookie>> {
    let mut result = Vec::new();
    for line in text.lines() {
        let line = line.trim_end_matches('\r');
        let line = if let Some(value) = line.strip_prefix("#HttpOnly_") {
            value
        } else if line.starts_with('#') || line.trim().is_empty() {
            continue;
        } else {
            line
        };
        let cols: Vec<_> = line.split('\t').collect();
        if cols.len() != 7
            || !matches!(cols[1], "TRUE" | "FALSE")
            || !matches!(cols[3], "TRUE" | "FALSE")
        {
            return invalid();
        }
        let expiry: u64 = cols[4].parse().map_err(|_| "invalid_cookie_format")?;
        let c = Cookie {
            name: cols[5].into(),
            value: cols[6].into(),
            domain: domain(cols[0])?,
            path: cols[2].into(),
            host_only: cols[1] == "FALSE",
            expires: if expiry == 0 {
                None
            } else {
                Some(expiry as f64)
            },
        };
        validate(&c)?;
        result.push(c);
        if result.len() > 4096 {
            return Err("cookie_import_too_large");
        }
    }
    Ok(result)
}
fn validate(c: &Cookie) -> Result<()> {
    pair(&c.name, &c.value)?;
    if !c.path.starts_with('/') || c.path.bytes().any(|b| b < 0x20 || b == 0x7f) {
        return invalid();
    }
    Ok(())
}

// 浏览器表格复制：每条以 name=\t 开头，后续行拼回同一个值。
fn folded_header(text: &str) -> Option<Result<String>> {
    let first = text.lines().find(|line| !line.trim().is_empty())?;
    let (name, _) = first.split_once("=\t")?;
    if pair(name, "").is_err() || text.lines().any(|line| line.split('\t').count() == 7) {
        return None;
    }
    Some((|| {
        let mut entries: Vec<(String, String)> = Vec::new();
        for line in text.lines().filter(|line| !line.trim().is_empty()) {
            if let Some((name, value)) = line.split_once("=\t") {
                pair(name, value)?;
                entries.push((name.into(), value.into()));
            } else {
                entries
                    .last_mut()
                    .ok_or("invalid_cookie_format")?
                    .1
                    .push_str(line);
            }
        }
        let mut result = Vec::with_capacity(entries.len());
        for (name, value) in entries {
            pair(&name, &value)?;
            result.push(format!("{name}={value}"));
        }
        Ok(result.join("; "))
    })())
}

/// Scope is checked for each actual HTTPS destination, before any header is built.
/// RFC6265 path matching and longer-path ordering; redirects remain disabled.
pub(crate) fn header(input: &str, target: &str, now: u64) -> Result<String> {
    if input.len() > MAX_IMPORT {
        return Err("cookie_import_too_large");
    }
    let text = input
        .trim_start_matches('\u{feff}')
        .trim_matches([' ', '\r', '\n']);
    if text.is_empty() {
        return Ok(String::new());
    }
    let url = reqwest::Url::parse(target).map_err(|_| "cookie_origin_mismatch")?;
    let host = url.host_str().ok_or("cookie_origin_mismatch")?;
    if url.scheme() != "https" || !(host == "qidian.com" || host.ends_with(".qidian.com")) {
        return Err("cookie_origin_mismatch");
    }
    let exported = text.starts_with('[')
        || text.starts_with('{')
        || text.starts_with('#')
        || text.contains('\t');
    let value = if let Some(value) = folded_header(text) {
        value?
    } else if exported {
        let items = if text.starts_with('[') || text.starts_with('{') {
            json_cookies(text)?
        } else {
            netscape(text)?
        };
        let mut selected: Vec<Cookie> = Vec::new();
        for c in items {
            if !(c.domain == "qidian.com" || c.domain.ends_with(".qidian.com")) {
                continue;
            }
            let domain_matches =
                host == c.domain || (!c.host_only && host.ends_with(&format!(".{}", c.domain)));
            let path_matches = url.path() == c.path
                || (url.path().starts_with(&c.path)
                    && (c.path.ends_with('/')
                        || url.path().as_bytes().get(c.path.len()) == Some(&b'/')));
            if !domain_matches || !path_matches || c.expires.is_some_and(|e| e <= now as f64) {
                continue;
            }
            if let Some(previous) = selected
                .iter()
                .find(|old| old.name == c.name && old.path == c.path)
            {
                if previous.value != c.value {
                    return Err("cookie_ambiguous");
                }
                continue;
            }
            selected.push(c);
        }
        if selected.is_empty() {
            return Err("cookie_no_applicable_entries");
        }
        selected.sort_by_key(|c| std::cmp::Reverse(c.path.len()));
        selected
            .iter()
            .map(|c| format!("{}={}", c.name, c.value))
            .collect::<Vec<_>>()
            .join("; ")
    } else {
        let text = if text
            .get(..7)
            .is_some_and(|prefix| prefix.eq_ignore_ascii_case("cookie:"))
        {
            text[7..].trim()
        } else {
            text
        };
        if text.contains(['\r', '\n']) {
            return invalid();
        }
        let mut result = Vec::new();
        for part in text.split(';') {
            let part = part.trim();
            if part.is_empty() {
                continue;
            }
            let (name, value) = part.split_once('=').ok_or("invalid_cookie_format")?;
            let name = name.trim();
            let value = value.trim();
            pair(name, value)?;
            result.push(format!("{name}={value}"));
        }
        if result.is_empty() {
            return invalid();
        }
        result.join("; ")
    };
    if value.len() > MAX_HEADER {
        return Err("cookie_import_too_large");
    }
    Ok(value)
}

/// Validate the export itself before storing it, without assuming a book path.
pub(crate) fn validate_for_storage(input: &str) -> Result<()> {
    if input.len() > MAX_IMPORT {
        return Err("cookie_import_too_large");
    }
    let text = input
        .trim_start_matches('\u{feff}')
        .trim_matches([' ', '\r', '\n']);
    if text.is_empty() {
        return invalid();
    }
    if folded_header(text).is_some() {
        return header(text, "https://www.qidian.com/search/", 0).map(|_| ());
    }
    if text.starts_with('[')
        || text.starts_with('{')
        || text.starts_with('#')
        || text.contains('\t')
    {
        let cookies = if text.starts_with('[') || text.starts_with('{') {
            json_cookies(text)?
        } else {
            netscape(text)?
        };
        if !cookies
            .iter()
            .any(|c| c.domain == "qidian.com" || c.domain.ends_with(".qidian.com"))
        {
            return Err("cookie_no_applicable_entries");
        }
        Ok(())
    } else {
        header(text, "https://www.qidian.com/search/", 0).map(|_| ())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    const URL: &str = "https://m.qidian.com/book/123/catalog/";
    #[test]
    fn folded_table_values_share_storage_and_request_validation() {
        for (input, expected) in [
            ("sid=\tabc", "sid=abc"),
            ("sid=\tabc\ncsrf=\tdef", "sid=abc; csrf=def"),
            (
                "sid=\tabc\ndef\nxyz==\ncsrf=\t123",
                "sid=abcdefxyz==; csrf=123",
            ),
            (
                "\u{feff}  \r\nsid=\tabc\r\ndef==\r\n\r\ncsrf=\t123\r\n ",
                "sid=abcdef==; csrf=123",
            ),
            ("sid=\ta=b==", "sid=a=b=="),
            ("empty=\t", "empty="),
            ("sid=\ta\nsid=\tb", "sid=a; sid=b"),
        ] {
            assert_eq!(header(input, URL, 0).unwrap(), expected);
            validate_for_storage(input).unwrap();
        }
        for input in [
            "sid=\tFAKE_SECRET\ncontains space",
            "sid=\tFAKE_SECRET\n\tbad",
            "sid=\tFAKE_SECRET;",
            "sid=\tFAKE_SECRET\n中",
        ] {
            assert_eq!(header(input, URL, 0).unwrap_err(), "invalid_cookie_format");
            assert_eq!(
                validate_for_storage(input).unwrap_err(),
                "invalid_cookie_format"
            );
        }
        assert_eq!(
            header("sid=\ta", "https://example.org/", 0).unwrap_err(),
            "cookie_origin_mismatch"
        );
        assert_eq!(
            header("sid=\ta", "http://m.qidian.com/", 0).unwrap_err(),
            "cookie_origin_mismatch"
        );
        let oversized = format!("sid=\t{}", "x".repeat(MAX_HEADER));
        assert_eq!(
            validate_for_storage(&oversized).unwrap_err(),
            "cookie_import_too_large"
        );
    }
    #[test]
    fn raw_prefix_quotes_and_equals_preserve_order() {
        assert_eq!(
            header(
                " Cookie: sid=abc==; x=\"ok\"; empty=; sid=second; ",
                URL,
                100
            )
            .unwrap(),
            "sid=abc==; x=\"ok\"; empty=; sid=second"
        );
        assert_eq!(header("   ", URL, 100).unwrap(), "");
        for bad in [
            "Cookie:",
            "<html>sid=x</html>",
            "curl -H 'Cookie: sid=x'",
            "a=x\r\nInjected: y",
            "a=bad value",
            "a=中",
            "bad(name=x",
            "a=\\x",
        ] {
            assert!(header(bad, URL, 100).is_err());
        }
        assert_eq!(
            header("a=x", "https://qidian.com.example.org/", 100).unwrap_err(),
            "cookie_origin_mismatch"
        );
        assert_eq!(
            header("a=x", "http://m.qidian.com/", 100).unwrap_err(),
            "cookie_origin_mismatch"
        );
    }
    #[test]
    fn netscape_selects_domain_path_expiry_and_orders_duplicates() {
        let text = "# Netscape HTTP Cookie File\n.qidian.com\tTRUE\t/\tTRUE\t0\tsid\troot\n#HttpOnly_m.qidian.com\tFALSE\t/book/123\tTRUE\t200\tsid\tbook\n.qidian.com\tTRUE\t/book/12\tTRUE\t0\twrongpath\tx\nwww.qidian.com\tFALSE\t/\tTRUE\t0\twronghost\tx\n.example.org\tTRUE\t/\tTRUE\t0\tother\tx\n.qidian.com\tTRUE\t/\tTRUE\t99\texpired\tx";
        assert_eq!(header(text, URL, 100).unwrap(), "sid=book; sid=root");
        assert_eq!(
            header(text, "https://www.qidian.com/search/", 100).unwrap(),
            "sid=root; wronghost=x"
        );
    }
    #[test]
    fn browser_arrays_and_playwright_wrappers_have_explicit_scope() {
        let items = json!([
            {"name":"sid","value":"root","domain":".qidian.com","path":"/","secure":true,"expirationDate":200.5},
            {"name":"sid","value":"book","domain":"m.qidian.com","hostOnly":true,"path":"/book/123/","expires":-1},
            {"name":"skip","value":"expired","domain":".qidian.com","path":"/","expires":100},
            {"name":"skip","value":"host","domain":"www.qidian.com","path":"/"}
        ]);
        for value in [items.clone(), json!({"cookies":items,"origins":[]})] {
            assert_eq!(
                header(&value.to_string(), URL, 100).unwrap(),
                "sid=book; sid=root"
            );
        }
        let duplicate = json!([{"name":"sid","value":"a","domain":".qidian.com","path":"/"},{"name":"sid","value":"b","domain":"m.qidian.com","path":"/"}]);
        assert_eq!(
            header(&duplicate.to_string(), URL, 100).unwrap_err(),
            "cookie_ambiguous"
        );
        let partitioned = json!([{"name":"sid","value":"a","domain":".qidian.com","path":"/","partitionKey":"https://example.org"}]);
        assert_eq!(
            header(&partitioned.to_string(), URL, 100).unwrap_err(),
            "cookie_partition_unsupported"
        );
        assert_eq!(
            header("[]", URL, 100).unwrap_err(),
            "cookie_no_applicable_entries"
        );
    }
    #[test]
    fn import_and_header_bounds_and_errors_never_echo_secrets() {
        assert_eq!(
            header(&"x".repeat(MAX_IMPORT + 1), URL, 100).unwrap_err(),
            "cookie_import_too_large"
        );
        assert_eq!(
            header(&format!("sid={}", "x".repeat(MAX_HEADER)), URL, 100).unwrap_err(),
            "cookie_import_too_large"
        );
        let secret = "PRIVATE_TEST_VALUE";
        let invalid = json!([{"name":"sid","value":secret,"domain":".qidian.com"}]);
        assert!(
            !header(&invalid.to_string(), URL, 100)
                .unwrap_err()
                .contains(secret)
        );
    }
}
