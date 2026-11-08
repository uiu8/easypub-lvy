//! Prove redundant sibling boundaries before removing their title lines.
use crate::{source::SourceSnapshot, structure::Node};
use std::collections::BTreeMap;

pub(crate) fn targets(source: &SourceSnapshot, nodes: &[Node]) -> BTreeMap<u32, u32> {
    let mut targets = BTreeMap::new();
    let mut aliases = BTreeMap::new();
    let raw = source.decoded_text();
    for pair in nodes.windows(2) {
        let (first, second) = (&pair[0], &pair[1]);
        let parent = |node: &Node| {
            node.parent_id
                .as_ref()
                .map(|id| aliases.get(id).unwrap_or(id).clone())
        };
        if first.title == second.title
            && first.role == second.role
            && first.depth == second.depth
            && first.include_toc == second.include_toc
            && parent(first) == parent(second)
            && raw[first.body_start..second.start].trim().is_empty()
        {
            targets.insert(second.source_line, first.source_line);
            let retained_id = aliases
                .get(&first.entry_id)
                .cloned()
                .unwrap_or(first.entry_id.clone());
            aliases.insert(second.entry_id.clone(), retained_id);
        }
    }
    targets
}
