//! Exact whole-chapter candidates in the immutable source, never deletion authority.
use crate::{
    ApiError, ErrorCode,
    source::{SourceSnapshot, numbered_heading},
};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

#[derive(Debug, Serialize)]
pub struct Occurrence {
    pub entry_id: String,
    pub start_line: u32,
    pub end_line: u32,
}
#[derive(Debug, Serialize)]
pub struct Group {
    pub title: String,
    pub block_sha256: String,
    pub occurrences: Vec<Occurrence>,
}
/// Hashing only narrows comparisons; bytes must also match. Different chapter
/// bodies and empty-body repeated headings are not whole-chapter candidates.
pub fn find(source: &SourceSnapshot) -> Result<Vec<Group>, ApiError> {
    let headings = source.headings();
    if headings.len() > 30000 {
        return Err(ApiError::new(
            ErrorCode::TooLarge,
            "duplicate_blocks",
            "reduce_source_size",
        ));
    }
    let lines = source.decoded_line_ranges();
    let text = source.decoded_text();
    let mut buckets: BTreeMap<[u8; 32], Vec<(usize, usize, Group)>> = BTreeMap::new();
    for (index, heading) in headings.iter().enumerate() {
        if numbered_heading(&heading.title)
            .is_some_and(|(_, marker)| matches!(marker, '卷' | '部' | '篇' | '集'))
        {
            continue;
        }
        let start = lines[heading.source_line as usize - 1].0;
        let next_line = headings
            .get(index + 1)
            .map(|h| h.source_line)
            .unwrap_or(source.summary().line_count + 1);
        let end = lines
            .get(next_line as usize - 1)
            .map(|line| line.0)
            .unwrap_or(text.len());
        let body_start = lines
            .get(heading.source_line as usize)
            .map(|line| line.0)
            .unwrap_or(text.len());
        if body_start >= end || text[body_start..end].trim().is_empty() {
            continue;
        }
        let digest: [u8; 32] = Sha256::digest(&text.as_bytes()[start..end]).into();
        let occurrence = Occurrence {
            entry_id: heading.entry_id.clone(),
            start_line: heading.source_line,
            end_line: next_line - 1,
        };
        let bucket = buckets.entry(digest).or_default();
        if let Some((_, _, group)) = bucket
            .iter_mut()
            .find(|(s, e, _)| text[*s..*e] == text[start..end])
        {
            group.occurrences.push(occurrence);
        } else {
            bucket.push((
                start,
                end,
                Group {
                    title: heading.title.chars().take(500).collect(),
                    block_sha256: format!("{:x}", Sha256::digest(&text.as_bytes()[start..end])),
                    occurrences: vec![occurrence],
                },
            ));
        }
    }
    let mut groups = buckets
        .into_values()
        .flatten()
        .map(|(_, _, g)| g)
        .filter(|g| g.occurrences.len() > 1)
        .collect::<Vec<_>>();
    groups.sort_by_key(|g| g.occurrences[0].start_line);
    Ok(groups)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::RULE_ID;
    #[test]
    fn exact_body_groups_do_not_conflate_number_or_empty_heading_repeats() {
        let text = "第一卷 起\n第一章 同题\n甲正文\n\n第一章 同题\n甲正文\n\n第一章 同题\n不同正文\n\n第二章 空\n第二章 空\n第二卷 续\n第一章 同题\n甲正文\n\n第三章 末\n尾声";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let groups = find(&source).unwrap();
        assert_eq!(groups.len(), 1);
        assert_eq!(
            groups[0]
                .occurrences
                .iter()
                .map(|o| (o.start_line, o.end_line))
                .collect::<Vec<_>>(),
            vec![(2, 4), (5, 7), (14, 16)]
        );
        assert_eq!(source.decoded_text(), text);
    }
}
