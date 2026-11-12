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

/// 正文几乎相同的两章：标题可以不同（两套编号），正文只差几行（多半是推广语）。
#[derive(Debug, Serialize)]
pub struct NearPair {
    pub first: Occurrence,
    pub second: Occurrence,
    pub first_title: String,
    pub second_title: String,
    /// 两章里对不上的行数（取多的一边）。
    pub differing_lines: u32,
    /// 一份只是另一份的一部分（下载时截断了）：只能排除短的那份。
    pub partial: bool,
    /// 默认排除哪一份：一般是后一份；短的那份在前时是前一份。
    pub drop_first: bool,
}

/// 正文里每个有分量的行（去空白后至少 12 个字）的指纹，排序去重。
fn line_keys(body: &str) -> Vec<u64> {
    let mut keys = Vec::new();
    for line in body.lines() {
        let mut hash = 0xcbf2_9ce4_8422_2325u64;
        let mut count = 0;
        for c in line.chars().filter(|c| !c.is_whitespace()) {
            hash = (hash ^ c as u64).wrapping_mul(0x0100_0000_01b3);
            count += 1;
        }
        if count >= 12 {
            keys.push(hash);
        }
    }
    keys.sort_unstable();
    keys.dedup();
    keys
}

fn shared(a: &[u64], b: &[u64]) -> usize {
    let (mut i, mut j, mut n) = (0, 0, 0);
    while i < a.len() && j < b.len() {
        match a[i].cmp(&b[j]) {
            std::cmp::Ordering::Less => i += 1,
            std::cmp::Ordering::Greater => j += 1,
            std::cmp::Ordering::Equal => {
                n += 1;
                i += 1;
                j += 1;
            }
        }
    }
    n
}

/// 至少 5 行、且 85% 以上的行一样，才算同一章的两份。
fn close(a: &[u64], b: &[u64], shared: usize) -> bool {
    let most = a.len().max(b.len());
    shared >= 5 && shared * 100 >= most * 85
}

/// 短的一份至少 5 行，且 85% 以上的行都在长的那份里：短的是长的一部分。
fn inside(short: &[u64], shared: usize) -> bool {
    shared >= 5 && shared * 100 >= short.len() * 85
}

/// 排除前复核：[dropped] 是不是 [kept] 的另一份，或只是它的一部分。两段都不含标题行。
pub fn similar(kept: &str, dropped: &str) -> bool {
    let (a, b) = (line_keys(kept), line_keys(dropped));
    let common = shared(&a, &b);
    close(&a, &b, common) || (b.len() <= a.len() && inside(&b, common))
}

/// 近似重复的章节对。逐字相同（连标题）的归 [`find`]，这里不重复给。
/// 每章只和它前面最像的一章配对。
pub fn find_near(source: &SourceSnapshot) -> Result<Vec<NearPair>, ApiError> {
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
    // (标题下标, 整章起点, 正文起点, 终点, 末行, 指纹)
    let mut chapters = Vec::new();
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
        if body_start >= end {
            continue;
        }
        let keys = line_keys(&text[body_start..end]);
        if keys.len() >= 5 {
            chapters.push((index, start, body_start, end, next_line - 1, keys));
        }
    }
    let mut owners: std::collections::HashMap<u64, Vec<u32>> = std::collections::HashMap::new();
    let mut pairs = Vec::new();
    for (position, (index, start, _, end, last_line, keys)) in chapters.iter().enumerate() {
        let mut votes: BTreeMap<u32, usize> = BTreeMap::new();
        for key in keys {
            // 很多章都有的行（固定的推广语、分隔语）不能说明两章相同。
            if let Some(list) = owners.get(key).filter(|list| list.len() <= 6) {
                for &other in list {
                    *votes.entry(other).or_default() += 1;
                }
            }
        }
        let best = votes
            .into_iter()
            .max_by_key(|&(other, count)| (count, std::cmp::Reverse(other)));
        if let Some((other, _)) = best {
            let (other_index, other_start, _, other_end, other_last, other_keys) =
                &chapters[other as usize];
            let common = shared(keys, other_keys);
            let whole = close(keys, other_keys, common);
            let short = if keys.len() <= other_keys.len() {
                keys
            } else {
                other_keys
            };
            if (whole || inside(short, common))
                && text[*other_start..*other_end] != text[*start..*end]
            {
                let occurrence = |i: usize, last: u32| Occurrence {
                    entry_id: headings[i].entry_id.clone(),
                    start_line: headings[i].source_line,
                    end_line: last,
                };
                pairs.push(NearPair {
                    first: occurrence(*other_index, *other_last),
                    second: occurrence(*index, *last_line),
                    first_title: headings[*other_index].title.chars().take(500).collect(),
                    second_title: headings[*index].title.chars().take(500).collect(),
                    differing_lines: (keys.len().max(other_keys.len()) - common) as u32,
                    partial: !whole,
                    drop_first: !whole && other_keys.len() < keys.len(),
                });
            }
        }
        for key in keys {
            let list = owners.entry(*key).or_default();
            if list.len() <= 6 {
                list.push(position as u32);
            }
        }
    }
    Ok(pairs)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::RULE_ID;
    fn body(tag: &str, lines: usize) -> String {
        (0..lines)
            .map(|i| format!("　　{tag}的第{i}段正文，写得足够长才算有分量的一行。\n"))
            .collect()
    }
    #[test]
    fn near_pairs_cover_other_numbering_extra_lines_and_cut_copies() {
        let text = format!(
            "第525章 黄昏\n{a}\n第二十章 黄昏\n{a}　　请搜索本站，更新最快的小说站点就是这里！\n\n第526章 举手\n{b}\n第527章 整章\n{c}\n第二十二章 整章\n{cut}\n第528章 别的\n{d}",
            a = body("甲", 12),
            b = body("乙", 12),
            c = body("丙", 20),
            cut = body("丙", 8),
            d = body("丁", 12),
        );
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        // 连标题逐字相同的才归 find；这里一对都没有。
        assert!(find(&source).unwrap().is_empty());
        let pairs = find_near(&source).unwrap();
        assert_eq!(pairs.len(), 2);
        // 换了编号、多一行推广语：两份都完整，默认排除后一份。
        assert_eq!(
            (
                pairs[0].first_title.as_str(),
                pairs[0].second_title.as_str()
            ),
            ("第525章 黄昏", "第二十章 黄昏")
        );
        assert!(!pairs[0].partial && !pairs[0].drop_first);
        assert_eq!(pairs[0].differing_lines, 1);
        // 后一份只有前 8 段：是前一份的一部分，排除短的。
        assert!(pairs[1].partial && !pairs[1].drop_first);
        // 复核有方向：短的可以排除，长的不行。
        assert!(similar(&body("丙", 20), &body("丙", 8)));
        assert!(!similar(&body("丙", 8), &body("丙", 20)));
        assert!(!similar(&body("甲", 12), &body("乙", 12)));
    }
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
