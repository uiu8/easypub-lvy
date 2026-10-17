//! Logical chapter boundaries are independent of TXT spelling and TOC visibility.
use crate::{
    ApiError, ErrorCode,
    source::{SourceSnapshot, numbered_heading},
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    Volume,
    Chapter,
    Section,
    Front,
    Body,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Override {
    pub source_line: u32,
    pub role: Role,
    pub depth: u8,
    pub include_toc: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Structure {
    pub source_id: String,
    pub revision: u32,
    pub overrides: Vec<Override>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recognition_rules: Option<crate::chapter_rules::RuleSet>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Node {
    pub entry_id: String,
    pub parent_id: Option<String>,
    pub source_line: u32,
    pub title: String,
    pub role: Role,
    pub depth: u8,
    pub include_toc: bool,
    /// UTF-8 ranges partition the source exactly once, including heading lines.
    pub start: usize,
    pub end: usize,
    pub body_start: usize,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Tree {
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub recognition_decisions: BTreeMap<u32, bool>,
    pub source_id: String,
    pub revision: u32,
    pub prefix_end: usize,
    pub nodes: Vec<Node>,
    pub source_bytes_covered: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recognition_rules: Option<crate::chapter_rules::RuleSet>,
}
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "chapter_structure",
        "review_levels_and_source_lines",
    )
}
impl Structure {
    /// Persist the improved classification explicitly; legacy `new` remains
    /// unchanged so existing history hashes and node identities keep replaying.
    pub fn recognized(source: &SourceSnapshot) -> Self {
        let mut result = Self::new(source);
        result.recognition_rules = Some(crate::chapter_rules::RuleSet::default());
        let dominant =
            crate::recognition::dominant_marker(source.headings().iter().map(|h| h.title.as_str()));
        let mut in_volume = false;
        let mut in_chapter = false;
        for h in source.headings() {
            let marker = numbered_heading(&h.title).map(|(_, marker)| marker);
            if crate::recognition::is_prose_heading(&h.title, dominant) {
                result.overrides.push(Override {
                    source_line: h.source_line,
                    role: Role::Body,
                    depth: 0,
                    include_toc: false,
                });
            } else if matches!(marker, Some('卷' | '部' | '篇' | '集')) {
                in_volume = true;
                in_chapter = false;
            } else if marker == Some('节') && in_chapter && dominant != Some('节') {
                result.overrides.push(Override {
                    source_line: h.source_line,
                    role: Role::Section,
                    depth: if in_volume { 2 } else { 1 },
                    include_toc: true,
                });
            } else if matches!(marker, Some('章' | '回')) {
                in_chapter = true;
            }
        }
        result
    }

    pub fn new(source: &SourceSnapshot) -> Self {
        let s = source.summary();
        Self {
            source_id: s.source_id,
            revision: s.revision,
            overrides: Vec::new(),
            recognition_rules: None,
        }
    }
    pub fn validate_shape(&self) -> Result<(), ApiError> {
        if let Some(rules) = &self.recognition_rules {
            rules.compile()?;
        }
        if self.overrides.len() > 30000 || self.source_id.len() != 64 || self.revision != 1 {
            return Err(invalid());
        }
        let mut seen = BTreeSet::new();
        for o in &self.overrides {
            if o.source_line == 0
                || o.depth > 8
                || !seen.insert(o.source_line)
                || (o.role == Role::Body && (o.include_toc || o.depth != 0))
            {
                return Err(invalid());
            }
        }
        Ok(())
    }
    pub fn tree(&self, source: &SourceSnapshot) -> Result<Tree, ApiError> {
        self.validate_shape()?;
        let summary = source.summary();
        if self.source_id != summary.source_id || self.revision != summary.revision {
            return Err(ApiError::new(
                ErrorCode::StaleRevision,
                "chapter_structure",
                "reimport_source",
            ));
        }
        let lines = source.decoded_line_ranges();
        let raw = source.decoded_text();
        let mut settings = BTreeMap::new();
        let mut in_volume = false;
        for h in source
            .headings()
            .iter()
            .filter(|_| self.recognition_rules.is_none())
        {
            let role = if numbered_heading(&h.title)
                .is_some_and(|(_, c)| matches!(c, '卷' | '部' | '篇' | '集'))
            {
                Role::Volume
            } else {
                Role::Chapter
            };
            let depth = if role == Role::Volume {
                in_volume = true;
                0
            } else if in_volume {
                1
            } else {
                0
            };
            settings.insert(
                h.source_line,
                Override {
                    source_line: h.source_line,
                    role,
                    depth,
                    include_toc: true,
                },
            );
        }
        if let Some(rules) = &self.recognition_rules {
            for item in rules.compile()?.recognize(source) {
                settings.insert(item.source_line, item);
            }
        }
        for o in &self.overrides {
            let &(start, end) = lines.get(o.source_line as usize - 1).ok_or_else(invalid)?;
            if raw[start..end].trim().is_empty() || end - start > 4096 {
                return Err(invalid());
            }
            settings.insert(o.source_line, o.clone());
        }
        let mut nodes: Vec<Node> = Vec::new();
        let mut ancestors: Vec<String> = Vec::new();
        for o in settings.values().filter(|o| o.role != Role::Body) {
            if o.depth as usize > ancestors.len() {
                return Err(invalid());
            }
            ancestors.truncate(o.depth as usize);
            let (start, end) = lines[o.source_line as usize - 1];
            if let Some(previous) = nodes.last_mut() {
                previous.end = start;
            }
            let entry_id = format!("{}:{start}", self.source_id);
            nodes.push(Node {
                entry_id: entry_id.clone(),
                parent_id: ancestors.last().cloned(),
                source_line: o.source_line,
                title: raw[start..end].trim().into(),
                role: o.role.clone(),
                depth: o.depth,
                include_toc: o.include_toc,
                start,
                end: raw.len(),
                body_start: lines
                    .get(o.source_line as usize)
                    .map(|&(s, _)| s)
                    .unwrap_or(raw.len()),
            });
            ancestors.push(entry_id);
        }
        let prefix_end = nodes.first().map(|n| n.start).unwrap_or(raw.len());
        let covered = prefix_end + nodes.iter().map(|n| n.end - n.start).sum::<usize>();
        if covered != raw.len() {
            return Err(invalid());
        }
        Ok(Tree {
            recognition_decisions: BTreeMap::new(),
            source_id: self.source_id.clone(),
            revision: self.revision,
            prefix_end,
            nodes,
            source_bytes_covered: covered,
            recognition_rules: self.recognition_rules.clone(),
        })
    }
    pub fn put(&mut self, source: &SourceSnapshot, change: Override) -> Result<(), ApiError> {
        let mut next = self.clone();
        next.overrides
            .retain(|o| o.source_line != change.source_line);
        next.overrides.push(change);
        next.overrides.sort_by_key(|o| o.source_line);
        next.tree(source)?;
        *self = next;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::RULE_ID;
    fn source() -> SourceSnapshot {
        SourceSnapshot::from_utf8("卷前文字\n第一卷 起\n卷首说明\n第一章 甲\n甲文\n第二章 误识别\n仍是甲文\n第三章 丙\n丙文".as_bytes().to_vec(),RULE_ID,||false).unwrap()
    }
    #[test]
    fn body_classification_keeps_heading_words_and_toc_does_not_remove_content() {
        let s = source();
        let mut settings = Structure::new(&s);
        settings
            .put(
                &s,
                Override {
                    source_line: 6,
                    role: Role::Body,
                    depth: 0,
                    include_toc: false,
                },
            )
            .unwrap();
        settings
            .put(
                &s,
                Override {
                    source_line: 8,
                    role: Role::Section,
                    depth: 2,
                    include_toc: false,
                },
            )
            .unwrap();
        let tree = settings.tree(&s).unwrap();
        assert_eq!(tree.nodes.len(), 3);
        assert_eq!(
            tree.nodes[2].parent_id.as_ref(),
            Some(&tree.nodes[1].entry_id)
        );
        assert!(!tree.nodes[2].include_toc);
        assert!(
            s.decoded_text()[tree.nodes[1].body_start..tree.nodes[1].end]
                .contains("第二章 误识别\n仍是甲文")
        );
        let mut assembled = s.decoded_text()[..tree.prefix_end].to_string();
        for n in &tree.nodes {
            assembled.push_str(&s.decoded_text()[n.start..n.end]);
        }
        assert_eq!(assembled, s.decoded_text());
        let reopened: Structure =
            serde_json::from_str(&serde_json::to_string(&settings).unwrap()).unwrap();
        assert_eq!(
            serde_json::to_value(reopened.tree(&s).unwrap()).unwrap(),
            serde_json::to_value(tree).unwrap()
        );
    }
    #[test]
    fn invalid_levels_and_source_identity_leave_settings_unchanged() {
        let s = source();
        let mut settings = Structure::new(&s);
        let before = serde_json::to_string(&settings).unwrap();
        for change in [
            Override {
                source_line: 4,
                role: Role::Section,
                depth: 8,
                include_toc: true,
            },
            Override {
                source_line: 99,
                role: Role::Body,
                depth: 0,
                include_toc: false,
            },
            Override {
                source_line: 6,
                role: Role::Body,
                depth: 1,
                include_toc: true,
            },
        ] {
            assert!(settings.put(&s, change).is_err());
            assert_eq!(serde_json::to_string(&settings).unwrap(), before);
        }
        settings.source_id = "0".repeat(64);
        assert!(settings.tree(&s).is_err());
    }
    #[test]
    fn unnumbered_volume_is_explicit_structure_and_identity_survives_toc_change() {
        let s = source();
        let mut settings = Structure::new(&s);
        settings
            .put(
                &s,
                Override {
                    source_line: 1,
                    role: Role::Volume,
                    depth: 0,
                    include_toc: true,
                },
            )
            .unwrap();
        let id = settings.tree(&s).unwrap().nodes[0].entry_id.clone();
        settings
            .put(
                &s,
                Override {
                    source_line: 1,
                    role: Role::Volume,
                    depth: 0,
                    include_toc: false,
                },
            )
            .unwrap();
        assert_eq!(settings.tree(&s).unwrap().nodes[0].entry_id, id);
    }
}
