//! Source-bound cleanup settings history. No output consent is persisted.
use easypub_core::{
    ApiError, ErrorCode,
    cleanup::{Request, prepare},
    source::SourceSnapshot,
};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CleanupDraft {
    pub source_id: String,
    pub source_revision: u32,
    pub history: Vec<Option<Request>>,
    pub cursor: usize,
}
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Command {
    Set { request: Request },
    Disable,
    Undo,
    Redo,
    Inspect,
}
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "cleanup_draft",
        "review_cleanup_settings_history",
    )
}
impl CleanupDraft {
    pub(crate) fn new(source: &SourceSnapshot) -> Self {
        let s = source.summary();
        Self {
            source_id: s.source_id,
            source_revision: s.revision,
            history: vec![None],
            cursor: 0,
        }
    }
    pub fn validate_shape(&self) -> Result<(), ApiError> {
        if self.history.is_empty()
            || self.history.len() > 51
            || self.cursor >= self.history.len()
            || serde_json::to_vec(self).map_err(|_| invalid())?.len() > 1024 * 1024
        {
            return Err(invalid());
        }
        Ok(())
    }
    pub fn current(&self) -> &Option<Request> {
        &self.history[self.cursor]
    }
    pub(crate) fn prepare_set(
        &mut self,
        source: &SourceSnapshot,
        request: Request,
    ) -> Result<easypub_core::cleanup::Cleanup, ApiError> {
        self.validate(source)?;
        let request = request.for_storage();
        let plan = prepare(
            source,
            &serde_json::to_string(&request).map_err(|_| invalid())?,
        )?;
        plan.output(source)?;
        self.push_state(Some(request))?;
        Ok(plan)
    }
    fn push_state(&mut self, next: Option<Request>) -> Result<(), ApiError> {
        if self.current() == &next {
            return Ok(());
        }
        let mut candidate = self.clone();
        candidate.history.truncate(candidate.cursor + 1);
        candidate.history.push(next);
        if candidate.history.len() > 51 {
            candidate.history.remove(0);
        }
        candidate.cursor = candidate.history.len() - 1;
        candidate.validate_shape()?;
        *self = candidate;
        Ok(())
    }
    pub fn validate(&self, source: &SourceSnapshot) -> Result<(), ApiError> {
        self.validate_shape()?;
        let s = source.summary();
        if self.source_id != s.source_id || self.source_revision != s.revision {
            return Err(invalid());
        }
        for request in self.history.iter().flatten() {
            if request != &request.for_storage() {
                return Err(invalid());
            }
            prepare(
                source,
                &serde_json::to_string(request).map_err(|_| invalid())?,
            )?;
        }
        Ok(())
    }
    fn apply(&mut self, source: &SourceSnapshot, command: Command) -> Result<(), ApiError> {
        if let Command::Set { request } = command {
            self.prepare_set(source, request)?;
            return Ok(());
        }
        self.validate(source)?;
        match command {
            Command::Undo if self.cursor > 0 => self.cursor -= 1,
            Command::Redo if self.cursor + 1 < self.history.len() => self.cursor += 1,
            Command::Disable => self.push_state(None)?,
            Command::Inspect => {}
            _ => return Err(invalid()),
        }
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
    if draft_json.len() > 1024 * 1024 || command_json.len() > 1024 * 1024 {
        return Err(invalid());
    }
    let source = service.source(&source_id, revision)?;
    let mut draft = if draft_json.is_empty() {
        CleanupDraft::new(&source)
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
    use easypub_core::source::RULE_ID;
    use serde_json::json;
    fn request(replace: &str) -> Request {
        serde_json::from_value(json!({"kind":"cleanup","pipeline":[{"kind":"literal_replace","find":"正文","replace":replace}]})).unwrap()
    }
    #[test]
    fn history_disable_restore_branch_budget_and_atomic_invalid_edit() {
        let source =
            SourceSnapshot::from_utf8("第一章 甲\n正文".as_bytes().to_vec(), RULE_ID, || {
                false
            })
            .unwrap();
        let mut draft = CleanupDraft::new(&source);
        draft
            .apply(
                &source,
                Command::Set {
                    request: request("内容"),
                },
            )
            .unwrap();
        draft
            .apply(
                &source,
                Command::Set {
                    request: request("内容"),
                },
            )
            .unwrap();
        assert_eq!(draft.history.len(), 2);
        draft.apply(&source, Command::Disable).unwrap();
        assert!(draft.current().is_none());
        draft.apply(&source, Command::Undo).unwrap();
        let mut restored: CleanupDraft =
            serde_json::from_str(&serde_json::to_string(&draft).unwrap()).unwrap();
        restored.apply(&source, Command::Redo).unwrap();
        assert!(restored.current().is_none());
        restored.apply(&source, Command::Undo).unwrap();
        restored
            .apply(
                &source,
                Command::Set {
                    request: request("新分支"),
                },
            )
            .unwrap();
        assert!(restored.apply(&source, Command::Redo).is_err());
        let before = serde_json::to_string(&restored).unwrap();
        let mut bad = serde_json::to_value(request("不改")).unwrap();
        bad["start_line"] = json!(99);
        assert!(
            restored
                .apply(
                    &source,
                    Command::Set {
                        request: serde_json::from_value(bad).unwrap()
                    }
                )
                .is_err()
        );
        assert_eq!(serde_json::to_string(&restored).unwrap(), before);
        for n in 0..60 {
            restored
                .apply(
                    &source,
                    Command::Set {
                        request: request(&format!("改文{n}")),
                    },
                )
                .unwrap();
        }
        assert_eq!(restored.history.len(), 51);
        assert_eq!(restored.cursor, 50);
        let mut bad_history = serde_json::to_value(&restored).unwrap();
        bad_history["history"][0]["skip_lines"] = json!([999]);
        let corrupt: CleanupDraft = serde_json::from_value(bad_history).unwrap();
        assert!(corrupt.validate(&source).is_err());
        restored.source_id = "0".repeat(64);
        assert!(restored.validate(&source).is_err());
    }
}
