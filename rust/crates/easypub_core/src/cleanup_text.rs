//! Physical line boundaries, preserving CRLF/LF/CR exactly.
use crate::{
    ApiError,
    cleanup_rules::{Compiled, JoinMode, budget},
};

pub(crate) fn lines(text: &str, terminal_empty: bool) -> Vec<(&str, &str)> {
    let bytes = text.as_bytes();
    let mut result = Vec::new();
    let mut start = 0;
    let mut i = 0;
    while i < bytes.len() {
        if matches!(bytes[i], b'\r' | b'\n') {
            let end = i;
            i += 1;
            if bytes[end] == b'\r' && bytes.get(i) == Some(&b'\n') {
                i += 1;
            }
            result.push((&text[start..end], &text[end..i]));
            start = i;
        } else {
            i += 1;
        }
    }
    if start < text.len() || terminal_empty {
        result.push((&text[start..], ""));
    }
    result
}
pub(crate) fn split_ending(text: &str) -> (&str, &str) {
    let size = if text.ends_with("\r\n") {
        2
    } else if text.ends_with(['\r', '\n']) {
        1
    } else {
        0
    };
    text.split_at(text.len() - size)
}
pub(crate) fn transform_lines(
    compiled: &Compiled,
    text: &str,
    matches_left: &mut usize,
) -> Result<String, ApiError> {
    let mut result = String::new();
    for (line, end) in lines(text, true) {
        result.push_str(&compiled.transform(line, matches_left)?);
        result.push_str(end);
        if result.len() > 1024 * 1024 {
            return Err(budget());
        }
    }
    Ok(result)
}
pub(crate) fn joinable(left: &str, right: &str, min_chars: u32, mode: &JoinMode) -> bool {
    let left = left.rsplit(['\r', '\n']).next().unwrap_or("");
    let right = right.split(['\r', '\n']).next().unwrap_or("");
    !crate::recognition::is_default_heading(left)
        && !crate::recognition::is_default_heading(right)
        && !crate::cleanup::candidate(left)
        && !crate::cleanup::candidate(right)
        && mode.can_join(left, right, min_chars)
}
pub(crate) fn join_inside(text: &str, min_chars: u32, mode: &JoinMode) -> String {
    let parts = lines(text, false);
    let mut result = String::with_capacity(text.len());
    for (i, &(line, ending)) in parts.iter().enumerate() {
        result.push_str(line);
        if parts
            .get(i + 1)
            .is_some_and(|(right, _)| joinable(line, right, min_chars, mode))
        {
            result.push_str(mode.separator());
        } else {
            result.push_str(ending);
        }
    }
    result
}
