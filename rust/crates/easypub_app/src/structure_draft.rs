//! Source-bound structural history; storing a history never authorizes output.
use easypub_core::{ApiError, ErrorCode, source::SourceSnapshot, structure::Structure};
use serde::{Deserialize, Serialize};
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StructureDraft {
    pub history: Vec<Structure>,
    pub cursor: usize,
}
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Command {
    Recognize {
        #[serde(default)]
        rules: Option<easypub_core::chapter_rules::RuleSet>,
    },
    Set {
        structure: Structure,
    },
    Undo,
    Redo,
    Inspect,
}
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "structure_history",
        "review_structure_history",
    )
}
impl StructureDraft {
    pub fn validate_shape(&self) -> Result<(), ApiError> {
        if self.history.is_empty()
            || self.history.len() > 51
            || self.cursor >= self.history.len()
            || serde_json::to_vec(self).map_err(|_| invalid())?.len() > 2 * 1024 * 1024
        {
            return Err(invalid());
        }
        let first = &self.history[0];
        for value in &self.history {
            value.validate_shape()?;
            if value.source_id != first.source_id || value.revision != first.revision {
                return Err(invalid());
            }
        }
        Ok(())
    }
    pub fn current(&self) -> &Structure {
        &self.history[self.cursor]
    }
    pub fn validate(&self, source: &SourceSnapshot) -> Result<(), ApiError> {
        self.validate_shape()?;
        for value in &self.history {
            value.tree(source)?;
        }
        Ok(())
    }
    fn apply(&mut self, source: &SourceSnapshot, command: Command) -> Result<(), ApiError> {
        self.validate(source)?;
        let mut next = self.clone();
        match command {
            Command::Recognize { rules } => {
                let mut structure = Structure::recognized(source);
                if let Some(rules) = rules {
                    rules.compile()?;
                    structure.recognition_rules = Some(rules);
                    structure.overrides.clear();
                }
                next = Self {
                    history: vec![structure],
                    cursor: 0,
                };
            }
            Command::Set { structure } => {
                structure.tree(source)?;
                if next.current() != &structure {
                    next.history.truncate(next.cursor + 1);
                    next.history.push(structure);
                    if next.history.len() > 51 {
                        next.history.remove(0);
                    }
                    next.cursor = next.history.len() - 1;
                }
            }
            Command::Undo if next.cursor > 0 => next.cursor -= 1,
            Command::Redo if next.cursor + 1 < next.history.len() => next.cursor += 1,
            Command::Inspect => {}
            _ => return Err(invalid()),
        }
        next.validate_shape()?;
        *self = next;
        Ok(())
    }
}
pub fn edit(
    service: &crate::sessions::ImportService,
    source_id: String,
    revision: u32,
    draft_json: String,
    command_json: String,
) -> Result<String, ApiError> {
    if draft_json.len() > 2 * 1024 * 1024 || command_json.len() > 2 * 1024 * 1024 {
        return Err(invalid());
    }
    let source = service.source(&source_id, revision)?;
    let mut draft = if draft_json.is_empty() {
        StructureDraft {
            history: vec![Structure::new(&source)],
            cursor: 0,
        }
    } else {
        serde_json::from_str(&draft_json).map_err(|_| invalid())?
    };
    draft.apply(
        &source,
        serde_json::from_str(&command_json).map_err(|_| invalid())?,
    )?;
    serde_json::to_string(&draft).map_err(|_| invalid())
}
#[cfg(test)]
mod tests {
    use super::*;
    use easypub_core::structure::{Override, Role};
    #[test]
    fn history_roundtrip_branch_and_invalid_edit_are_atomic() {
        let source = SourceSnapshot::from_utf8(
            "序言\n第一章 开始\n正文".as_bytes().to_vec(),
            easypub_core::source::RULE_ID,
            || false,
        )
        .unwrap();
        let base = Structure::new(&source);
        let mut draft = StructureDraft {
            history: vec![base.clone()],
            cursor: 0,
        };
        let mut changed = base.clone();
        changed
            .put(
                &source,
                Override {
                    source_line: 1,
                    role: Role::Volume,
                    depth: 0,
                    include_toc: true,
                },
            )
            .unwrap();
        draft
            .apply(
                &source,
                Command::Set {
                    structure: changed.clone(),
                },
            )
            .unwrap();
        let raw = serde_json::to_string(&draft).unwrap();
        draft = serde_json::from_str(&raw).unwrap();
        draft.apply(&source, Command::Undo).unwrap();
        assert_eq!(draft.current(), &base);
        draft.apply(&source, Command::Redo).unwrap();
        assert_eq!(draft.current(), &changed);
        let mut invalid_structure = changed.clone();
        invalid_structure.overrides[0].depth = 2;
        assert!(
            draft
                .apply(
                    &source,
                    Command::Set {
                        structure: invalid_structure
                    }
                )
                .is_err()
        );
        assert_eq!(serde_json::to_string(&draft).unwrap(), raw);
        draft.apply(&source, Command::Undo).unwrap();
        changed.overrides[0].include_toc = false;
        draft
            .apply(&source, Command::Set { structure: changed })
            .unwrap();
        assert!(draft.apply(&source, Command::Redo).is_err());
        let unchanged = source.decoded_text().to_owned();
        assert_eq!(unchanged, "序言\n第一章 开始\n正文");
    }
    #[test]
    fn retained_history_is_bounded_and_every_state_is_source_bound() {
        let source = SourceSnapshot::from_utf8(
            "序篇\n第一章 甲\n正文".as_bytes().to_vec(),
            easypub_core::source::RULE_ID,
            || false,
        )
        .unwrap();
        let base = Structure::new(&source);
        let mut draft = StructureDraft {
            history: vec![base.clone()],
            cursor: 0,
        };
        for i in 0..60 {
            let mut value = base.clone();
            value
                .put(
                    &source,
                    Override {
                        source_line: 1,
                        role: Role::Front,
                        depth: 0,
                        include_toc: i % 2 == 0,
                    },
                )
                .unwrap();
            draft
                .apply(&source, Command::Set { structure: value })
                .unwrap();
        }
        assert_eq!(draft.history.len(), 51);
        assert_eq!(draft.cursor, 50);
        let raw = serde_json::to_string(&draft).unwrap();
        draft
            .apply(
                &source,
                Command::Set {
                    structure: draft.current().clone(),
                },
            )
            .unwrap();
        assert_eq!(serde_json::to_string(&draft).unwrap(), raw);
        for _ in 0..50 {
            draft.apply(&source, Command::Undo).unwrap();
        }
        assert!(draft.apply(&source, Command::Undo).is_err());
        let mut mixed = draft.clone();
        mixed.history[50].source_id = "0".repeat(64);
        assert!(mixed.validate_shape().is_err());
        let mut invalid_old = draft.clone();
        invalid_old.history[50].overrides[0].depth = 3;
        assert!(invalid_old.validate(&source).is_err());
        let changed = SourceSnapshot::from_utf8(
            "序篇\n第一章 甲\n已改正文".as_bytes().to_vec(),
            easypub_core::source::RULE_ID,
            || false,
        )
        .unwrap();
        assert!(draft.validate(&changed).is_err());
    }
}
