//! Serializable Rust-validated manual edit history; never stores source text or consent.
use easypub_core::structure::Structure;
use easypub_core::{ApiError, ErrorCode, source::SourceSnapshot};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ManualDraft {
    pub source_id: String,
    pub source_revision: u32,
    pub history: Vec<Vec<Value>>,
    pub cursor: usize,
}
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "manual_draft",
        "review_manual_draft",
    )
}
impl ManualDraft {
    pub fn new(source: &SourceSnapshot) -> Self {
        let summary = source.summary();
        Self {
            source_id: summary.source_id,
            source_revision: summary.revision,
            history: vec![vec![]],
            cursor: 0,
        }
    }
    pub fn validate_shape(&self) -> Result<(), ApiError> {
        if self.history.is_empty()
            || self.history.len() > 101
            || self.cursor >= self.history.len()
            || self.history.iter().any(|h| h.len() > 500)
            || serde_json::to_vec(self).map_err(|_| invalid())?.len() > 1024 * 1024
        {
            return Err(invalid());
        }
        for actions in &self.history {
            easypub_core::manual_edit::validate_action_shapes(actions)?;
        }
        Ok(())
    }
    pub fn validate(&self, source: &SourceSnapshot) -> Result<(), ApiError> {
        self.validate_with_structure(source, None)
    }
    pub fn validate_with_structure(
        &self,
        source: &SourceSnapshot,
        structure: Option<&Structure>,
    ) -> Result<(), ApiError> {
        self.validate_shape()?;
        if let Some(structure) = structure {
            structure.tree(source)?;
        }
        let summary = source.summary();
        if self.source_id != summary.source_id || self.source_revision != summary.revision {
            return Err(invalid());
        }
        let actions = &self.history[self.cursor];
        if !actions.is_empty() {
            easypub_core::manual_edit::prepare_with_structure(
                source,
                &json!({"kind":"manual_batch","actions":actions}).to_string(),
                structure,
            )?;
        }
        Ok(())
    }
    pub fn selection(&self) -> Value {
        json!({"kind":"manual_batch","actions":self.history[self.cursor]})
    }
    pub fn edit(&mut self, source: &SourceSnapshot, command: &Value) -> Result<(), ApiError> {
        let structure: Option<Structure> = command
            .get("structure")
            .filter(|value| !value.is_null())
            .map(|value| serde_json::from_value(value.clone()).map_err(|_| invalid()))
            .transpose()?;
        let mut candidate = self.clone();
        candidate.apply(source, command, structure.as_ref())?;
        *self = candidate;
        Ok(())
    }
    fn apply(
        &mut self,
        source: &SourceSnapshot,
        command: &Value,
        structure: Option<&Structure>,
    ) -> Result<(), ApiError> {
        self.validate_with_structure(source, structure)?;
        match command["op"].as_str() {
            Some("exclude_duplicate_blocks") => {
                let selected = command["entry_ids"].as_array().ok_or_else(invalid)?;
                if selected.is_empty() || selected.len() > 500 {
                    return Err(invalid());
                }
                let mut ids = std::collections::BTreeSet::new();
                for id in selected {
                    if !ids.insert(id.as_str().ok_or_else(invalid)?) {
                        return Err(invalid());
                    }
                }
                let groups = easypub_core::duplicate_blocks::find(source)?;
                let mut next = self.history[self.cursor].clone();
                let mut matched = 0;
                for group in groups {
                    let touched = group
                        .occurrences
                        .iter()
                        .any(|o| ids.contains(o.entry_id.as_str()));
                    if !touched {
                        continue;
                    }
                    let mut retained = 0;
                    for o in &group.occurrences {
                        let excluded = next.iter().any(|a| {
                            a["kind"] == "exclude_lines"
                                && a["source_line"]
                                    .as_u64()
                                    .is_some_and(|s| s <= u64::from(o.end_line))
                                && a["end_line"]
                                    .as_u64()
                                    .is_some_and(|e| e >= u64::from(o.start_line))
                        });
                        if ids.contains(o.entry_id.as_str()) {
                            if excluded {
                                return Err(invalid());
                            }
                            matched += 1;
                            next.push(json!({"kind":"exclude_lines","source_line":o.start_line,"end_line":o.end_line}));
                        } else if !excluded {
                            retained += 1;
                        }
                    }
                    if retained == 0 {
                        return Err(invalid());
                    }
                }
                if matched != ids.len() {
                    return Err(invalid());
                }
                self.history.truncate(self.cursor + 1);
                self.history.push(next);
                if self.history.len() > 101 {
                    self.history.remove(0);
                }
                self.cursor = self.history.len() - 1;
            }
            Some("undo") if self.cursor > 0 => self.cursor -= 1,
            Some("redo") if self.cursor + 1 < self.history.len() => self.cursor += 1,
            Some("put" | "remove" | "clear") => {
                let mut next = self.history[self.cursor].clone();
                if command["op"] == "clear" {
                    next.clear();
                } else {
                    let line = if command["op"] == "put" {
                        command["action"]["source_line"].as_u64()
                    } else {
                        command["source_line"].as_u64()
                    }
                    .ok_or_else(invalid)?;
                    let kind = if command["op"] == "put" {
                        command["action"]["kind"].as_str()
                    } else {
                        command["kind"].as_str()
                    }
                    .ok_or_else(invalid)?;
                    if !matches!(
                        kind,
                        "rename_title"
                            | "repair_number_typo"
                            | "set_volume"
                            | "split_chapter"
                            | "merge_previous"
                            | "move_chapter"
                            | "move_volume"
                            | "exclude_lines"
                    ) {
                        return Err(invalid());
                    }
                    next.retain(|v| v["source_line"].as_u64() != Some(line) || v["kind"] != kind);
                    if command["op"] == "put" {
                        next.push(command["action"].clone());
                    }
                }
                if !next.is_empty() {
                    easypub_core::manual_edit::prepare_with_structure(
                        source,
                        &json!({"kind":"manual_batch","actions":next}).to_string(),
                        structure,
                    )?;
                }
                if next == self.history[self.cursor] {
                    return Ok(());
                }
                self.history.truncate(self.cursor + 1);
                self.history.push(next);
                if self.history.len() > 101 {
                    self.history.remove(0);
                }
                self.cursor = self.history.len() - 1;
            }
            Some("inspect") => {}
            _ => return Err(invalid()),
        }
        self.validate_with_structure(source, structure)
    }
}

pub fn edit(
    service: &crate::sessions::ImportService,
    source_id: String,
    revision: u32,
    draft_json: String,
    command_json: String,
) -> Result<String, ApiError> {
    let source = service.source(&source_id, revision)?;
    let invalid = || {
        ApiError::new(
            easypub_core::ErrorCode::InvalidRule,
            "manual_draft",
            "review_manual_draft",
        )
    };
    if draft_json.len() > 1024 * 1024 || command_json.len() > 3 * 1024 * 1024 {
        return Err(invalid());
    }
    let mut draft = if draft_json.is_empty() {
        ManualDraft::new(&source)
    } else {
        serde_json::from_str(&draft_json).map_err(|_| invalid())?
    };
    let command = serde_json::from_str(&command_json).map_err(|_| invalid())?;
    draft.edit(&source, &command)?;
    serde_json::to_string(&draft).map_err(|_| invalid())
}

#[cfg(test)]
mod tests {
    use super::*;
    use easypub_core::{encoding::EncodingMode, source::RULE_ID};
    #[test]
    fn duplicate_selection_is_one_undo_and_cannot_remove_last_copy() {
        let text =
            "第一章 甲\n正文\n第一章 甲\n正文\n第二章 乙\n乙文\n第二章 乙\n乙文\n第三章 终\n尾文";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let groups = easypub_core::duplicate_blocks::find(&source).unwrap();
        assert_eq!(groups.len(), 2);
        let ids = groups
            .iter()
            .map(|g| g.occurrences[1].entry_id.clone())
            .collect::<Vec<_>>();
        let mut draft = ManualDraft::new(&source);
        draft
            .edit(
                &source,
                &json!({"op":"exclude_duplicate_blocks","entry_ids":ids}),
            )
            .unwrap();
        assert_eq!(draft.cursor, 1);
        assert_eq!(draft.history[1].len(), 2);
        let committed = serde_json::to_string(&draft).unwrap();
        let remaining = groups
            .iter()
            .map(|g| g.occurrences[0].entry_id.clone())
            .collect::<Vec<_>>();
        for values in [
            remaining,
            ids.clone(),
            vec![ids[0].clone(), ids[0].clone()],
            vec!["unknown".into()],
        ] {
            assert!(
                draft
                    .edit(
                        &source,
                        &json!({"op":"exclude_duplicate_blocks","entry_ids":values})
                    )
                    .is_err()
            );
            assert_eq!(serde_json::to_string(&draft).unwrap(), committed);
        }
        draft.edit(&source, &json!({"op":"undo"})).unwrap();
        assert_eq!(draft.history[draft.cursor].len(), 0);
        draft.edit(&source, &json!({"op":"redo"})).unwrap();
        assert_eq!(serde_json::to_string(&draft).unwrap(), committed);
    }
    #[test]
    fn whole_volume_history_reopens_and_undoes_without_changing_source() {
        let source = SourceSnapshot::from_utf8(
            "第一卷 甲\n第一章 甲\n甲文\n第二卷 乙\n第二章 乙\n乙文"
                .as_bytes()
                .to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let mut draft = ManualDraft::new(&source);
        draft.edit(&source, &json!({"op":"put","action":{"kind":"move_volume","source_line":4,"before_line":1}})).unwrap();
        let selected = draft.selection();
        let mut reopened: ManualDraft =
            serde_json::from_str(&serde_json::to_string(&draft).unwrap()).unwrap();
        reopened.edit(&source, &json!({"op":"undo"})).unwrap();
        assert!(reopened.history[reopened.cursor].is_empty());
        reopened.edit(&source, &json!({"op":"redo"})).unwrap();
        assert_eq!(reopened.selection(), selected);
        let output = source.repair_output_json(&selected.to_string()).unwrap();
        assert_eq!(
            String::from_utf8(output).unwrap(),
            "第二卷 乙\n第二章 乙\n乙文\n第一卷 甲\n第一章 甲\n甲文\n"
        );
    }
    #[test]
    fn archived_structure_dependencies_are_checked_when_redone() {
        let source = SourceSnapshot::from_utf8(
            "序篇\n第一章 开始\n正文".as_bytes().to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let mut structure = Structure::new(&source);
        structure.overrides.push(easypub_core::structure::Override {
            source_line: 1,
            role: easypub_core::structure::Role::Volume,
            depth: 0,
            include_toc: true,
        });
        let mut draft = ManualDraft::new(&source);
        draft
            .edit(
                &source,
                &json!({"op":"put","structure":structure,
            "action":{"kind":"rename_title","source_line":1,"title":"序篇修订"}}),
            )
            .unwrap();
        draft
            .edit(&source, &json!({"op":"undo","structure":structure}))
            .unwrap();
        // The structure can be undone and the project reopened with redo kept.
        let saved = serde_json::to_string(&draft).unwrap();
        let mut reopened: ManualDraft = serde_json::from_str(&saved).unwrap();
        reopened.validate(&source).unwrap();
        assert!(reopened.edit(&source, &json!({"op":"redo"})).is_err());
        assert_eq!(serde_json::to_string(&reopened).unwrap(), saved);
        reopened
            .edit(&source, &json!({"op":"redo","structure":structure}))
            .unwrap();
        assert_eq!(reopened.cursor, 1);
        assert_eq!(reopened.history[1][0]["title"], "序篇修订");
    }
    #[test]
    fn combined_insert_and_rename_survive_order_changes_and_selective_remove() {
        let source = SourceSnapshot::from_bytes(
            "第一章 甲\r\n独有正文".as_bytes().to_vec(),
            EncodingMode::Auto,
            RULE_ID,
            || false,
        )
        .unwrap();
        let rename = json!({"kind":"rename_title","source_line":1,"title":"第一章 更长的新名"});
        let volume = json!({"kind":"set_volume","source_line":1,"volume_title":"第一卷 序"});
        for actions in [
            vec![rename.clone(), volume.clone()],
            vec![volume.clone(), rename.clone()],
        ] {
            let mut draft = ManualDraft::new(&source);
            for action in actions {
                draft
                    .edit(&source, &json!({"op":"put","action":action}))
                    .unwrap();
            }
            assert_eq!(draft.history[draft.cursor].len(), 2);
            assert_eq!(
                String::from_utf8(
                    source
                        .repair_output_json(&draft.selection().to_string())
                        .unwrap()
                )
                .unwrap(),
                "第一卷 序\r\n第一章 更长的新名\r\n独有正文"
            );
            draft
                .edit(
                    &source,
                    &json!({"op":"remove","source_line":1,"kind":"set_volume"}),
                )
                .unwrap();
            assert_eq!(draft.history[draft.cursor], vec![rename.clone()]);
            draft.edit(&source, &json!({"op":"undo"})).unwrap();
            assert_eq!(draft.history[draft.cursor].len(), 2);
            draft.edit(&source,&json!({"op":"put","action":{"kind":"rename_title","source_line":1,"title":"第一章 短"}})).unwrap();
            assert_eq!(draft.history[draft.cursor].len(), 2);
            assert_eq!(
                String::from_utf8(
                    source
                        .repair_output_json(&draft.selection().to_string())
                        .unwrap()
                )
                .unwrap(),
                "第一卷 序\r\n第一章 短\r\n独有正文"
            );
            assert!(draft.edit(&source, &json!({"op":"redo"})).is_err());
        }
    }
    #[test]
    fn batches_reject_conflicts_nested_batches_and_body_edits() {
        let source = SourceSnapshot::from_bytes(
            "第一章 甲\r\n正文甲\n第二章 乙\r正文乙".as_bytes().to_vec(),
            EncodingMode::Auto,
            RULE_ID,
            || false,
        )
        .unwrap();
        let rename = json!({"kind":"rename_title","source_line":1,"title":"第一章 新甲"});
        for actions in [
            json!([]),
            json!([rename, rename]),
            json!([{"kind":"manual_batch","actions":[rename]}]),
            json!([rename,{"kind":"rename_title","source_line":2,"title":"伪标题"}]),
        ] {
            let request = json!({"kind":"manual_batch","actions":actions}).to_string();
            assert!(source.repair_plan_json(&request).is_err());
            assert!(source.repair_output_json(&request).is_err());
        }
        let request=json!({"kind":"manual_batch","actions":[rename,{"kind":"set_volume","source_line":3,"volume_title":"第二卷 续"}]}).to_string();
        assert_eq!(
            String::from_utf8(source.repair_output_json(&request).unwrap()).unwrap(),
            "第一章 新甲\r\n正文甲\n第二卷 续\r第二章 乙\r正文乙"
        );
    }
    #[test]
    fn history_roundtrip_branching_and_batch_output() {
        let source = SourceSnapshot::from_bytes(
            "第一章 甲\r\n正文甲\n第二章 乙\r正文乙".as_bytes().to_vec(),
            EncodingMode::Auto,
            RULE_ID,
            || false,
        )
        .unwrap();
        let mut draft = ManualDraft::new(&source);
        for (line, title) in [(1, "第一章 新甲"), (3, "第二章 新乙")] {
            draft.edit(&source,&json!({"op":"put","action":{"kind":"rename_title","source_line":line,"title":title}})).unwrap();
        }
        assert_eq!(
            String::from_utf8(
                source
                    .repair_output_json(&draft.selection().to_string())
                    .unwrap()
            )
            .unwrap(),
            "第一章 新甲\r\n正文甲\n第二章 新乙\r正文乙"
        );
        draft.edit(&source, &json!({"op":"undo"})).unwrap();
        let mut reopened: ManualDraft =
            serde_json::from_str(&serde_json::to_string(&draft).unwrap()).unwrap();
        reopened.validate(&source).unwrap();
        reopened.edit(&source, &json!({"op":"redo"})).unwrap();
        assert_eq!(
            reopened.selection(),
            json!({"kind":"manual_batch","actions":draft.history[2]})
        );
        reopened.edit(&source, &json!({"op":"undo"})).unwrap();
        reopened.edit(&source, &json!({"op":"clear"})).unwrap();
        assert!(reopened.edit(&source, &json!({"op":"redo"})).is_err());
        let before = serde_json::to_string(&reopened).unwrap();
        assert!(reopened.edit(&source,&json!({"op":"put","action":{"kind":"rename_title","source_line":2,"title":"正文不能冒充标题"}})).is_err());
        assert_eq!(before, serde_json::to_string(&reopened).unwrap());
    }
}
