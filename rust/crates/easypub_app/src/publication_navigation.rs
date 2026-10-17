//! Navigation identities from the final composed tree; no guessed body boundaries.
use easypub_core::structure::{Role, Tree};
use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct Entry {
    pub entry_id: String,
    pub title: String,
    pub depth: u8,
    pub parent_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub document: Option<String>,
}
#[derive(Debug, Serialize)]
pub struct ChapterLinks {
    pub entry_id: String,
    pub previous: Option<String>,
    pub next: Option<String>,
    /// Logical destination. The exporter must resolve it to a real document.
    pub contents: Option<&'static str>,
}
#[derive(Debug, Serialize)]
pub struct Navigation {
    pub machine_toc: bool,
    pub visible_toc: bool,
    pub entries: Vec<Entry>,
    pub chapters: Vec<ChapterLinks>,
}

pub fn prepare(
    tree: &Tree,
    machine_toc: bool,
    visible_toc: bool,
    chapter_navigation: bool,
) -> Navigation {
    // Keep structural ancestors even when omitted from the TOC. Excluded parents
    // promote included descendants to their closest included ancestor.
    let mut ancestors: Vec<(u8, Option<String>)> = Vec::new();
    let mut entries = Vec::new();
    if machine_toc || visible_toc {
        for node in &tree.nodes {
            while ancestors
                .last()
                .is_some_and(|(depth, _)| *depth >= node.depth)
            {
                ancestors.pop();
            }
            let included = node.include_toc && node.role != Role::Body;
            if included {
                let parent_id = ancestors.iter().rev().find_map(|(_, id)| id.clone());
                let depth = ancestors.iter().filter(|(_, id)| id.is_some()).count() as u8;
                entries.push(Entry {
                    entry_id: node.entry_id.clone(),
                    title: crate::inline_markup::plain(&node.title),
                    depth,
                    parent_id,
                    document: None,
                });
            }
            ancestors.push((node.depth, included.then(|| node.entry_id.clone())));
        }
    }
    let chapter_nodes: Vec<_> = if chapter_navigation {
        tree.nodes
            .iter()
            .filter(|n| n.role == Role::Chapter)
            .collect()
    } else {
        Vec::new()
    };
    let contents = if entries.is_empty() {
        None
    } else if visible_toc {
        Some("visible_toc")
    } else if machine_toc {
        Some("machine_toc")
    } else {
        None
    };
    let chapters = chapter_nodes
        .iter()
        .enumerate()
        .map(|(index, node)| ChapterLinks {
            entry_id: node.entry_id.clone(),
            previous: index
                .checked_sub(1)
                .map(|i| chapter_nodes[i].entry_id.clone()),
            next: chapter_nodes.get(index + 1).map(|n| n.entry_id.clone()),
            contents,
        })
        .collect();
    Navigation {
        machine_toc,
        visible_toc,
        entries,
        chapters,
    }
}

impl Navigation {
    pub fn with_supplements(mut self, pages: &[crate::supplemental_pages::Page]) -> Self {
        use crate::supplemental_pages::Position;
        if !self.machine_toc && !self.visible_toc { return self; }
        let entries = |position| pages.iter().filter(move |p| p.content.include_toc && p.content.position == position).map(|p| Entry {
            entry_id: format!("matter-{}", p.id), title: p.content.label().into(), depth: 0,
            parent_id: None, document: Some(p.filename()),
        });
        self.entries = entries(Position::Front).chain(self.entries).chain(entries(Position::Back)).collect();
        if !self.entries.is_empty() {
            for chapter in &mut self.chapters {
                chapter.contents = Some(if self.visible_toc { "visible_toc" } else { "machine_toc" });
            }
        }
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use easypub_core::structure::Node;
    fn tree() -> Tree {
        let rows = [
            ("v", Role::Volume, 0, true),
            ("hidden", Role::Chapter, 1, false),
            ("s", Role::Section, 2, true),
            ("c", Role::Chapter, 1, true),
            ("last", Role::Chapter, 0, true),
        ];
        Tree {
            recognition_decisions: Default::default(),
            recognition_rules: None,
            source_id: "test".into(),
            revision: 1,
            prefix_end: 0,
            source_bytes_covered: 0,
            nodes: rows
                .into_iter()
                .map(|(id, role, depth, include_toc)| Node {
                    entry_id: id.into(),
                    parent_id: None,
                    source_line: 1,
                    title: format!("标题 {id}"),
                    role,
                    depth,
                    include_toc,
                    start: 0,
                    end: 0,
                    body_start: 0,
                })
                .collect(),
        }
    }
    #[test]
    fn hidden_parent_promotes_descendant_but_remains_in_reading_order() {
        let result = prepare(&tree(), true, true, true);
        assert_eq!(
            result
                .entries
                .iter()
                .map(|e| e.entry_id.as_str())
                .collect::<Vec<_>>(),
            ["v", "s", "c", "last"]
        );
        assert_eq!(result.entries[1].parent_id.as_deref(), Some("v"));
        assert_eq!(result.entries[1].depth, 1);
        assert_eq!(result.entries[3].parent_id, None);
        assert_eq!(result.chapters[0].entry_id, "hidden");
        assert_eq!(result.chapters[0].previous, None);
        assert_eq!(result.chapters[0].next.as_deref(), Some("c"));
        assert_eq!(result.chapters[2].previous.as_deref(), Some("c"));
        assert_eq!(result.chapters[2].next, None);
        assert!(
            result
                .chapters
                .iter()
                .all(|c| c.contents == Some("visible_toc"))
        );
    }
    #[test]
    fn switches_are_independent_and_no_dead_contents_destination() {
        for machine in [false, true] {
            for visible in [false, true] {
                for links in [false, true] {
                    let result = prepare(&tree(), machine, visible, links);
                    assert_eq!(result.entries.is_empty(), !machine && !visible);
                    assert_eq!(result.chapters.is_empty(), !links);
                    if !machine && !visible {
                        assert!(result.chapters.iter().all(|c| c.contents.is_none()));
                    }
                }
            }
        }
        let mut empty = tree();
        empty.nodes.clear();
        assert!(prepare(&empty, true, true, true).entries.is_empty());
        let mut single = tree();
        single.nodes.truncate(2);
        let result = prepare(&single, false, false, true);
        assert_eq!(result.chapters.len(), 1);
        assert!(result.chapters[0].previous.is_none() && result.chapters[0].next.is_none());
    }
}
