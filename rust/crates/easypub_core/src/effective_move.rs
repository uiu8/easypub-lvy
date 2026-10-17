//! Move an explicit logical subtree while preserving every source line.
use crate::{
    ApiError, ErrorCode,
    publication::EffectiveBook,
    source::{RULE_ID, SourceSnapshot},
    structure::{Override, Role, Structure},
};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "effective_move",
        "choose_target_outside_subtree",
    )
}

#[cfg(test)]
mod volume_tests {
    use super::*;
    use crate::effective_edit::{self, Action, Request};

    #[test]
    fn explicit_volume_edges_preserve_intro_children_ids_and_every_line() {
        let text = "第一卷 起\n卷引言\n第一章 甲\n甲文\n第一节 子\n子文\n第二卷 终\n第二卷引言\n第二章 乙\n乙文\n第三卷 空\n空卷引言\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let mut structure = Structure::new(&source);
        for line in [2, 4, 6, 8, 10, 12] {
            structure.overrides.push(Override {
                source_line: line,
                role: Role::Body,
                depth: 0,
                include_toc: false,
            });
        }
        for (line, role, depth) in [
            (1, Role::Volume, 0),
            (3, Role::Chapter, 1),
            (5, Role::Section, 2),
            (7, Role::Volume, 0),
            (9, Role::Chapter, 1),
            (11, Role::Volume, 0),
        ] {
            structure.overrides.push(Override {
                source_line: line,
                role,
                depth,
                include_toc: true,
            });
        }
        for (volume_index, at_start, expected) in [
            (3, true, vec![0, 3, 1, 2, 4, 5]),
            (3, false, vec![0, 3, 4, 1, 2, 5]),
            (5, true, vec![0, 3, 4, 5, 1, 2]),
            (5, false, vec![0, 3, 4, 5, 1, 2]),
        ] {
            let book = crate::publication::compose(&source, &structure, None).unwrap();
            let ids = book
                .tree
                .nodes
                .iter()
                .map(|n| n.entry_id.clone())
                .collect::<Vec<_>>();
            let nav = book.volume_navigation(None, 0).unwrap();
            assert_eq!(nav["total"], 3);
            let children = book.volume_navigation(Some(&ids[3]), 0).unwrap();
            assert_eq!(children["total"], 1);
            assert!(book.volume_navigation(Some(&ids[1]), 0).is_err());
            let request = Request {
                base_id: effective_edit::base_id(&book),
                actions: vec![Action::MoveIntoVolume {
                    entry_id: ids[1].clone(),
                    volume_id: ids[volume_index].clone(),
                    at_start,
                }],
            };
            let (moved, _) = effective_edit::apply(book, &request).unwrap();
            assert_eq!(
                moved
                    .tree
                    .nodes
                    .iter()
                    .map(|n| &n.entry_id)
                    .collect::<Vec<_>>(),
                expected.iter().map(|i| &ids[*i]).collect::<Vec<_>>()
            );
            let root = moved
                .tree
                .nodes
                .iter()
                .find(|n| n.entry_id == ids[1])
                .unwrap();
            let child = moved
                .tree
                .nodes
                .iter()
                .find(|n| n.entry_id == ids[2])
                .unwrap();
            assert_eq!(root.parent_id.as_deref(), Some(ids[volume_index].as_str()));
            assert_eq!(child.parent_id.as_deref(), Some(ids[1].as_str()));
            assert_eq!((root.depth, child.depth), (1, 2));
            let mut before = text.lines().collect::<Vec<_>>();
            before.sort();
            let mut after = moved.text.lines().collect::<Vec<_>>();
            after.sort();
            assert_eq!(before, after);
            assert!(moved.text.contains("第二卷 终\n第二卷引言\n"));
            assert!(moved.text.contains("第三卷 空\n空卷引言\n"));
        }
    }
}
pub fn prepare(
    book: &EffectiveBook,
    source: &SourceSnapshot,
    entry_id: &str,
    before_id: Option<&str>,
) -> Result<(EffectiveBook, Value), ApiError> {
    let root = book
        .tree
        .nodes
        .iter()
        .find(|n| n.entry_id == entry_id)
        .ok_or_else(invalid)?;
    let (target, depth) = if let Some(id) = before_id {
        let n = book
            .tree
            .nodes
            .iter()
            .find(|n| n.entry_id == id)
            .ok_or_else(invalid)?;
        if root.role == Role::Volume && n.role != Role::Volume {
            return Err(invalid());
        }
        (n.start, n.depth)
    } else {
        (book.text.len(), root.depth)
    };
    prepare_at(book, source, entry_id, target, depth, before_id)
}

pub fn prepare_in_volume(
    book: &EffectiveBook,
    source: &SourceSnapshot,
    entry_id: &str,
    volume_id: &str,
    at_start: bool,
) -> Result<(EffectiveBook, Value), ApiError> {
    let index = book
        .tree
        .nodes
        .iter()
        .position(|n| n.entry_id == volume_id && n.role == Role::Volume)
        .ok_or_else(invalid)?;
    let volume = &book.tree.nodes[index];
    let root = book
        .tree
        .nodes
        .iter()
        .find(|n| n.entry_id == entry_id)
        .ok_or_else(invalid)?;
    if root.role == Role::Volume {
        return Err(invalid());
    }
    let target = if at_start {
        volume.end
    } else {
        book.tree
            .nodes
            .iter()
            .skip(index + 1)
            .find(|n| n.depth <= volume.depth)
            .map(|n| n.start)
            .unwrap_or(book.text.len())
    };
    let depth = volume.depth.checked_add(1).ok_or_else(invalid)?;
    let (next, mut evidence) = prepare_at(book, source, entry_id, target, depth, None)?;
    evidence["changes"][0]["target_volume_id"] = json!(volume_id);
    evidence["changes"][0]["volume_position"] = json!(if at_start { "start" } else { "end" });
    Ok((next, evidence))
}

fn prepare_at(
    book: &EffectiveBook,
    source: &SourceSnapshot,
    entry_id: &str,
    target: usize,
    depth: u8,
    before_id: Option<&str>,
) -> Result<(EffectiveBook, Value), ApiError> {
    let index = book
        .tree
        .nodes
        .iter()
        .position(|n| n.entry_id == entry_id)
        .ok_or_else(invalid)?;
    let root = &book.tree.nodes[index];
    let stop_index = book
        .tree
        .nodes
        .iter()
        .enumerate()
        .skip(index + 1)
        .find(|(_, n)| n.depth <= root.depth)
        .map(|(i, _)| i)
        .unwrap_or(book.tree.nodes.len());
    let end = book
        .tree
        .nodes
        .get(stop_index)
        .map(|n| n.start)
        .unwrap_or(book.text.len());
    if target >= root.start && target <= end {
        return Err(invalid());
    }
    let spans = if target < root.start {
        vec![
            (0, target),
            (root.start, end),
            (target, root.start),
            (end, book.text.len()),
        ]
    } else {
        vec![
            (0, root.start),
            (end, target),
            (root.start, end),
            (target, book.text.len()),
        ]
    };
    let settings = book
        .tree
        .nodes
        .iter()
        .enumerate()
        .map(|(i, n)| {
            let new_depth = if i >= index && i < stop_index {
                n.depth
                    .checked_sub(root.depth)
                    .and_then(|d| d.checked_add(depth))
                    .ok_or_else(invalid)?
            } else {
                n.depth
            };
            Ok(Override {
                source_line: n.source_line,
                role: n.role.clone(),
                depth: new_depth,
                include_toc: n.include_toc,
            })
        })
        .collect::<Result<Vec<_>, ApiError>>()?;
    let result = recompose(book, source, &spans, &settings, vec![])?;
    let stage = json!({"changes":[{"kind":"move_subtree","source_line":root.source_line,
        "before":root.title,"after":format!("移动完整子树（{} 个节点）",stop_index-index),"before_id":before_id,
        "source_utf8_start":root.start,"source_utf8_end":end,"target_utf8":target,"old_depth":root.depth,"new_depth":depth}]});
    Ok((result, stage))
}

pub(super) fn recompose(
    book: &EffectiveBook,
    source: &SourceSnapshot,
    spans: &[(usize, usize)],
    settings: &[Override],
    removed: Vec<u32>,
) -> Result<EffectiveBook, ApiError> {
    let originals = source
        .decoded_line_ranges()
        .iter()
        .enumerate()
        .map(|(i, (start, _))| (*start, i as u32 + 1))
        .collect::<BTreeMap<_, _>>();
    let mut text = String::with_capacity(book.text.len() + 4);
    let mut anchors = BTreeMap::new();
    for &(start, end) in spans {
        if start == end {
            continue;
        }
        if !text.is_empty() && !text.ends_with(['\r', '\n']) {
            text.push('\n');
        }
        let base = text.len();
        for (&pos, &line) in originals.range(start..end) {
            anchors.insert(line, base + pos - start);
        }
        text.push_str(&book.text[start..end]);
    }
    let effective = SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false)?;
    let output_lines = effective
        .decoded_line_ranges()
        .iter()
        .enumerate()
        .map(|(i, (s, _))| (*s, i as u32 + 1))
        .collect::<BTreeMap<_, _>>();
    let mapping = anchors
        .into_iter()
        .map(|(line, start)| Ok((line, *output_lines.get(&start).ok_or_else(invalid)?)))
        .collect::<Result<BTreeMap<_, _>, ApiError>>()?;
    let mut structure = Structure::new(&effective);
    for n in settings {
        structure.overrides.push(Override {
            source_line: *mapping.get(&n.source_line).ok_or_else(invalid)?,
            role: n.role.clone(),
            depth: n.depth,
            include_toc: n.include_toc,
        });
    }
    let known = structure
        .overrides
        .iter()
        .map(|o| o.source_line)
        .collect::<BTreeSet<_>>();
    for n in Structure::new(&effective).tree(&effective)?.nodes {
        if !known.contains(&n.source_line) {
            structure.overrides.push(Override {
                source_line: n.source_line,
                role: Role::Body,
                depth: 0,
                include_toc: false,
            });
        }
    }
    let tree = structure.tree(&effective)?;
    Ok(EffectiveBook {
        original_source_id: source.summary().source_id,
        source_to_output_lines: mapping,
        tree,
        removed_structure_lines: removed,
        text_changed: text != book.text,
        text,
        cleanup_evidence: None,
    })
}

/// One complete permutation, so large catalog moves do not replay the entire
/// book once per chapter. Every node body and source line must occur once.
pub fn reorder(
    book: &EffectiveBook,
    source: &SourceSnapshot,
    order: &[(String, u8)],
) -> Result<(EffectiveBook, Value), ApiError> {
    let nodes = book
        .tree
        .nodes
        .iter()
        .map(|n| (n.entry_id.as_str(), n))
        .collect::<BTreeMap<_, _>>();
    if order.len() != nodes.len()
        || order
            .iter()
            .map(|(id, _)| id)
            .collect::<BTreeSet<_>>()
            .len()
            != nodes.len()
    {
        return Err(invalid());
    }
    let mut spans = vec![(0, book.tree.prefix_end)];
    let mut settings = Vec::with_capacity(order.len());
    for (id, depth) in order {
        let node = nodes.get(id.as_str()).ok_or_else(invalid)?;
        if *depth > 8 {
            return Err(invalid());
        }
        spans.push((node.start, node.end));
        settings.push(Override {
            source_line: node.source_line,
            role: node.role.clone(),
            depth: *depth,
            include_toc: node.include_toc,
        });
    }
    let mut coverage = spans.clone();
    coverage.sort_unstable();
    let mut cursor = 0;
    for (start, end) in coverage {
        if start != cursor || end < start {
            return Err(invalid());
        }
        cursor = end;
    }
    if cursor != book.text.len() {
        return Err(invalid());
    }
    let next = recompose(book, source, &spans, &settings, vec![])?;
    Ok((
        next,
        json!({"changes":[{"kind":"reorder_chapters","before":"当前章节顺序",
        "after":format!("按参考目录重排 {} 个结构节点，正文随章节保留", order.len()),
        "node_count":order.len()}]}),
    ))
}

#[cfg(test)]
mod permutation_tests {
    use super::*;
    #[test]
    fn permutation_rejects_missing_repeated_and_unknown_nodes_without_mutating_book() {
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n甲文\n第二章 乙\n乙文\n".as_bytes().to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let book = crate::publication::compose(&source, &Structure::new(&source), None).unwrap();
        let ids = book
            .tree
            .nodes
            .iter()
            .map(|n| n.entry_id.clone())
            .collect::<Vec<_>>();
        for order in [
            vec![(ids[0].clone(), 0)],
            vec![(ids[0].clone(), 0), (ids[0].clone(), 0)],
            vec![(ids[0].clone(), 0), ("missing".into(), 0)],
        ] {
            assert!(reorder(&book, &source, &order).is_err());
        }
        assert_eq!(book.text, source.decoded_text());
    }
}
