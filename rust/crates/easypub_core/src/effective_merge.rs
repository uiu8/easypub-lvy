//! Merge sibling roots while retaining their children's separate bodies.
use crate::{
    ApiError, ErrorCode, publication::EffectiveBook, source::SourceSnapshot, structure::Override,
};
use serde_json::{Value, json};
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "effective_merge",
        "choose_previous_sibling_of_same_role",
    )
}

/// Explicitly selected disjoint subtree. Target identity, title, role and TOC
/// setting win. Source direct body joins target direct body; its children follow
/// the target's existing children with relative depths preserved.
pub fn prepare_into(
    book: &EffectiveBook,
    source: &SourceSnapshot,
    entry_id: &str,
    target_id: &str,
) -> Result<(EffectiveBook, Value), ApiError> {
    let invalid = || {
        ApiError::new(
            ErrorCode::InvalidRule,
            "effective_merge",
            "choose_disjoint_target_with_valid_depth",
        )
    };
    let nodes = &book.tree.nodes;
    let index = nodes
        .iter()
        .position(|n| n.entry_id == entry_id)
        .ok_or_else(invalid)?;
    let target_index = nodes
        .iter()
        .position(|n| n.entry_id == target_id)
        .ok_or_else(invalid)?;
    let root = &nodes[index];
    let target = &nodes[target_index];
    let stop = |i: usize| {
        nodes
            .iter()
            .enumerate()
            .skip(i + 1)
            .find(|(_, n)| n.depth <= nodes[i].depth)
            .map(|(j, _)| j)
            .unwrap_or(nodes.len())
    };
    let root_stop = stop(index);
    let target_stop = stop(target_index);
    if (index..root_stop).contains(&target_index) || (target_index..target_stop).contains(&index) {
        return Err(invalid());
    }
    let root_end = nodes
        .get(root_stop)
        .map(|n| n.start)
        .unwrap_or(book.text.len());
    let target_end = nodes
        .get(target_stop)
        .map(|n| n.start)
        .unwrap_or(book.text.len());
    let spans = if target_index < index {
        vec![
            (0, target.end),
            (root.body_start, root.end),
            (target.end, target_end),
            (root.end, root_end),
            (target_end, root.start),
            (root_end, book.text.len()),
        ]
    } else {
        vec![
            (0, root.start),
            (root_end, target.end),
            (root.body_start, root.end),
            (target.end, target_end),
            (root.end, root_end),
            (target_end, book.text.len()),
        ]
    };
    let settings = nodes
        .iter()
        .enumerate()
        .filter(|(i, _)| *i != index)
        .map(|(i, n)| {
            let depth = if i > index && i < root_stop {
                n.depth
                    .checked_sub(root.depth)
                    .and_then(|d| d.checked_add(target.depth))
                    .ok_or_else(invalid)?
            } else {
                n.depth
            };
            Ok(Override {
                source_line: n.source_line,
                role: n.role.clone(),
                depth,
                include_toc: n.include_toc,
            })
        })
        .collect::<Result<Vec<_>, ApiError>>()?;
    let result =
        crate::effective_move::recompose(book, source, &spans, &settings, vec![root.source_line])?;
    let stage = json!({"changes":[{"kind":"merge_into", "source_line":root.source_line,
        "before":root.title, "after":format!("并入 {}；保留目标类型和标题，直属正文合并，子节点移到目标子节点之后",target.title),
        "target_entry_id":target_id,"removed_title_utf8_start":root.start,"removed_title_utf8_end":root.body_start,
        "source_subtree_utf8_end":root_end,"target_subtree_utf8_end":target_end,
        "old_depth":root.depth,"target_depth":target.depth,"source_parent_id":root.parent_id,"target_parent_id":target.parent_id}]});
    Ok((result, stage))
}
pub fn prepare(
    book: &EffectiveBook,
    source: &SourceSnapshot,
    entry_id: &str,
) -> Result<(EffectiveBook, Value), ApiError> {
    let index = book
        .tree
        .nodes
        .iter()
        .position(|n| n.entry_id == entry_id)
        .ok_or_else(invalid)?;
    let root = &book.tree.nodes[index];
    let previous = book.tree.nodes[..index]
        .iter()
        .rev()
        .find(|n| n.depth <= root.depth)
        .ok_or_else(invalid)?;
    if previous.depth != root.depth
        || previous.parent_id != root.parent_id
        || previous.role != root.role
    {
        return Err(invalid());
    }
    // Keep both roots' own bodies together before either root's children.
    let spans = [
        (0, previous.end),
        (root.body_start, root.end),
        (previous.end, root.start),
        (root.end, book.text.len()),
    ];
    let settings = book
        .tree
        .nodes
        .iter()
        .filter(|n| n.entry_id != entry_id)
        .map(|n| Override {
            source_line: n.source_line,
            role: n.role.clone(),
            depth: n.depth,
            include_toc: n.include_toc,
        })
        .collect::<Vec<_>>();
    let result =
        crate::effective_move::recompose(book, source, &spans, &settings, vec![root.source_line])?;
    let stage = json!({"changes":[{"kind":"merge_subtree_previous","source_line":root.source_line,
        "before":root.title,"after":format!("并入 {}；直属正文合并，下级节点保留",previous.title),
        "previous_entry_id":previous.entry_id,"removed_title_utf8_start":root.start,"removed_title_utf8_end":root.body_start,
        "moved_body_utf8_start":root.body_start,"moved_body_utf8_end":root.end,"body_target_utf8":previous.end}]});
    Ok((result, stage))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        effective_edit::{self, Action, Request},
        source::RULE_ID,
        structure::{Role, Structure},
    };
    #[test]
    fn selected_cross_parent_and_cross_role_merge_preserves_bodies_both_directions() {
        let raw = "甲卷\n甲卷正文\n父节\n父节正文\n目标节\n目标正文\n目标子节\n目标子正文\n乙卷\n乙卷正文\n来源章\n来源正文\n来源子节\n来源子正文";
        let source = SourceSnapshot::from_utf8(raw.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let mut structure = Structure::new(&source);
        for (line, role, depth) in [
            (1, Role::Volume, 0),
            (3, Role::Section, 1),
            (5, Role::Section, 2),
            (7, Role::Section, 3),
            (9, Role::Volume, 0),
            (11, Role::Chapter, 1),
            (13, Role::Section, 2),
        ] {
            structure.overrides.push(Override {
                source_line: line,
                role,
                depth,
                include_toc: line != 7 && line != 13,
            });
        }
        let make = || crate::publication::compose(&source, &structure, None).unwrap();
        let base = make();
        let ids = base
            .tree
            .nodes
            .iter()
            .map(|n| n.entry_id.clone())
            .collect::<Vec<_>>();
        for (from, to, expected, child, depth) in [
            (
                5,
                2,
                "甲卷\n甲卷正文\n父节\n父节正文\n目标节\n目标正文\n来源正文\n目标子节\n目标子正文\n来源子节\n来源子正文\n乙卷\n乙卷正文\n",
                6,
                3,
            ),
            (
                2,
                5,
                "甲卷\n甲卷正文\n父节\n父节正文\n乙卷\n乙卷正文\n来源章\n来源正文\n目标正文\n来源子节\n来源子正文\n目标子节\n目标子正文\n",
                3,
                2,
            ),
        ] {
            let mut request = Request {
                base_id: effective_edit::base_id(&base),
                actions: vec![Action::MergeInto {
                    entry_id: ids[from].clone(),
                    target_id: ids[to].clone(),
                }],
            };
            let (merged, _) = effective_edit::apply(make(), &request).unwrap();
            assert_eq!(merged.text, expected);
            let moved = merged
                .tree
                .nodes
                .iter()
                .find(|n| n.entry_id == ids[child])
                .unwrap();
            assert_eq!(moved.depth, depth);
            assert_eq!(moved.parent_id.as_ref(), Some(&ids[to]));
            assert!(!moved.include_toc);
            assert!(!merged.tree.nodes.iter().any(|n| n.entry_id == ids[from]));
            assert_eq!(
                merged.source_to_output_lines.len(),
                source.summary().line_count as usize - 1
            );
            assert_eq!(
                merged.removed_structure_lines,
                vec![base.tree.nodes[from].source_line]
            );
            request.actions.push(Action::Rename {
                entry_id: ids[to].clone(),
                title: "合并定稿".into(),
            });
            assert!(
                effective_edit::apply(make(), &request)
                    .unwrap()
                    .0
                    .text
                    .contains("合并定稿")
            );
        }
        for (from, to) in [(2, 2), (2, 3), (3, 2), (5, 4)] {
            let request = Request {
                base_id: effective_edit::base_id(&base),
                actions: vec![Action::MergeInto {
                    entry_id: ids[from].clone(),
                    target_id: ids[to].clone(),
                }],
            };
            assert!(effective_edit::apply(make(), &request).is_err());
        }
    }
}
