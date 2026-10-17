//! Context-supported suggestions, never automatic heading recognition or deletion.
use crate::source::{SourceSnapshot, numbered_heading};
use serde::Serialize;

#[derive(Clone, Serialize)]
pub struct Candidate {
    pub source_line: u32,
    pub before: String,
    pub title: String,
    pub previous_line: u32,
    pub next_line: u32,
    pub number: u32,
}

fn one_edit(a: &str, b: &str) -> bool {
    let a: Vec<_> = a.chars().collect();
    let b: Vec<_> = b.chars().collect();
    if a.len().abs_diff(b.len()) > 1 || a == b {
        return false;
    }
    let (mut i, mut j, mut edits) = (0, 0, 0);
    while i < a.len() && j < b.len() {
        if a[i] == b[j] {
            i += 1;
            j += 1;
            continue;
        }
        edits += 1;
        if edits > 1 {
            return false;
        }
        if a.len() >= b.len() {
            i += 1;
        }
        if b.len() >= a.len() {
            j += 1;
        }
    }
    edits + usize::from(i < a.len() || j < b.len()) == 1
}

pub fn find(source: &SourceSnapshot) -> Vec<Candidate> {
    let corrections = source.number_corrections();
    let headings = source.headings();
    let mut next = 0;
    let mut result = Vec::new();
    for (i, &(a, b)) in source.decoded_line_ranges().iter().enumerate() {
        let line = (i + 1) as u32;
        while next < headings.len() && headings[next].source_line < line {
            next += 1;
        }
        if next == 0 || next == headings.len() || headings[next].source_line == line || b - a > 768
        {
            continue;
        }
        let original = &source.decoded_text()[a..b];
        if source.is_non_heading(original) {
            continue;
        }
        let trimmed = original.trim_start();
        let Some(rest) = trimmed.strip_prefix('第') else {
            continue;
        };
        let Some((end, marker)) = rest
            .char_indices()
            .find(|(_, c)| matches!(c, '章' | '回' | '节'))
        else {
            continue;
        };
        let numeral = &rest[..end];
        if numeral.is_empty()
            || numeral.chars().count() > 16
            || numeral.chars().any(char::is_whitespace)
        {
            continue;
        }
        let suffix = &rest[end + marker.len_utf8()..];
        if !suffix.starts_with(char::is_whitespace) || suffix.trim().is_empty() {
            continue;
        }
        let previous = &headings[next - 1];
        let following = &headings[next];
        let (Some((p, pm)), Some((n, nm))) = (
            numbered_heading(&previous.title),
            numbered_heading(&following.title),
        ) else {
            continue;
        };
        if pm != marker || nm != marker || p.checked_add(2) != Some(n) || p >= 99_999_999 {
            continue;
        }
        let number = p + 1;
        let chinese = crate::cleanup_numbers::chinese(number);
        let arabic = number.to_string();
        let suggestions: Vec<_> = [&chinese, &arabic]
            .into_iter()
            .filter(|s| {
                one_edit(numeral, s)
                    && corrections.as_ref().is_none_or(|table| {
                        numeral
                            .chars()
                            .map(|ch| table.iter().find(|(a, _)| *a == ch).map_or(ch, |(_, b)| *b))
                            .collect::<String>()
                            .as_str()
                            == s.as_str()
                    })
            })
            .collect();
        if suggestions.len() != 1 {
            continue;
        }
        let leading = &original[..original.len() - trimmed.len()];
        result.push(Candidate {
            source_line: line,
            before: original.into(),
            title: format!("{leading}第{}{marker}{suffix}", suggestions[0]),
            previous_line: previous.source_line,
            next_line: following.source_line,
            number,
        });
    }
    // Multiple possible headings inside the same gap are ambiguous: retain no guess.
    let mut counts = std::collections::BTreeMap::new();
    for c in &result {
        *counts.entry((c.previous_line, c.next_line)).or_insert(0) += 1;
    }
    result.retain(|c| counts[&(c.previous_line, c.next_line)] == 1);
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::RULE_ID;
    fn candidates(text: &str) -> Vec<Candidate> {
        find(&SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap())
    }
    #[test]
    fn contextual_typo_preserves_suffix_and_rejects_ambiguity_prose_and_volume_boundaries() {
        let prefix = "第一百一十八章 前\n正文里有久字\n";
        let typo = "第一百一十久章 后续久字保留\n正文\n";
        let suffix = "第一百二十章 后\n";
        let c = candidates(&format!("{prefix}{typo}{suffix}"));
        assert_eq!(c.len(), 1);
        assert_eq!(c[0].source_line, 3);
        assert_eq!(c[0].title, "第一百一十九章 后续久字保留");
        for text in [
            format!("{prefix}{typo}{typo}{suffix}"),
            format!("{prefix}{typo}第二卷 新卷\n{suffix}"),
            format!("{typo}{suffix}"),
            format!("{prefix}第一百一十久章说了很多话\n{suffix}"),
            format!("{prefix}{typo}第一百二十一章 后\n"),
        ] {
            assert!(candidates(&text).is_empty());
        }
    }
}
