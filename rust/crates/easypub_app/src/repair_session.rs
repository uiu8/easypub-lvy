//! Rust-owned repair context. Flutter receives only a handle and snapshots.
use easypub_core::{ApiError, ErrorCode};
use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
};

#[derive(Clone, Debug)]
struct SessionState {
    mode: String,
    actions: Vec<String>,
}

#[derive(Clone, Debug)]
struct Session {
    source_id: String,
    source_revision: u32,
    revision: u32,
    history: Vec<SessionState>,
    history_index: usize,
}

#[derive(Clone)]
pub struct RepairSessionManager {
    next: Arc<Mutex<u64>>,
    sessions: Arc<Mutex<BTreeMap<u64, Session>>>,
}

impl Default for RepairSessionManager {
    fn default() -> Self {
        Self::new()
    }
}

impl RepairSessionManager {
    pub fn new() -> Self {
        Self {
            next: Arc::new(Mutex::new(1)),
            sessions: Arc::new(Mutex::new(BTreeMap::new())),
        }
    }

    pub fn open(&self, source_id: String, source_revision: u32) -> Result<u64, ApiError> {
        if source_id.trim().is_empty() || source_revision == 0 {
            return Err(ApiError::new(
                ErrorCode::InvalidCursor,
                "open_repair_session",
                "reload_source",
            ));
        }
        let mut next = self.next.lock().expect("session ids");
        let handle = *next;
        *next = next.checked_add(1).ok_or_else(|| {
            ApiError::new(
                ErrorCode::Internal,
                "open_repair_session",
                "restart_application",
            )
        })?;
        self.sessions.lock().expect("sessions").insert(
            handle,
            Session {
                source_id,
                source_revision,
                revision: 1,
                history: vec![SessionState {
                    mode: "self_service".to_owned(),
                    actions: Vec::new(),
                }],
                history_index: 0,
            },
        );
        Ok(handle)
    }

    pub fn snapshot(&self, handle: u64) -> Result<String, ApiError> {
        let session = self.get(handle)?;
        Ok(format!(
            "handle={handle};source_id={};source_revision={};revision={};mode={};action_count={};undo_depth={};redo_depth={}",
            session.source_id,
            session.source_revision,
            session.revision,
            session.history[session.history_index].mode,
            session.history[session.history_index].actions.len(),
            session.history_index,
            session.history.len() - session.history_index - 1
        ))
    }

    pub fn set_mode(&self, handle: u64, mode: String) -> Result<String, ApiError> {
        if !matches!(mode.as_str(), "self_service" | "catalog") {
            return Err(ApiError::new(
                ErrorCode::InvalidRule,
                "set_repair_mode",
                "choose_supported_mode",
            ));
        }
        let mut sessions = self.sessions.lock().expect("sessions");
        let session = sessions.get_mut(&handle).ok_or_else(|| {
            ApiError::new(
                ErrorCode::NotFound,
                "set_repair_mode",
                "reopen_repair_session",
            )
        })?;
        if session.history[session.history_index].mode == mode {
            drop(sessions);
            return self.snapshot(handle);
        }
        session.history.truncate(session.history_index + 1);
        session.history.push(SessionState {
            mode,
            actions: session.history[session.history_index].actions.clone(),
        });
        session.history_index += 1;
        session.revision = session.revision.checked_add(1).ok_or_else(|| {
            ApiError::new(
                ErrorCode::Internal,
                "set_repair_mode",
                "restart_application",
            )
        })?;
        drop(sessions);
        self.snapshot(handle)
    }

    pub fn set_action(&self, handle: u64, action_json: String) -> Result<String, ApiError> {
        let value: serde_json::Value = serde_json::from_str(&action_json).map_err(|_| {
            ApiError::new(
                ErrorCode::InvalidRule,
                "set_repair_action",
                "use_action_object",
            )
        })?;
        let kind = value
            .get("kind")
            .and_then(|v| v.as_str())
            .unwrap_or_default();
        if !matches!(kind, "manual_review" | "rename_title" | "set_volume")
            || value.get("id").and_then(|v| v.as_str()).is_none()
            || value
                .get("source_lines")
                .and_then(|v| v.as_array())
                .is_none_or(Vec::is_empty)
            || action_json.len() > 64 * 1024
        {
            return Err(ApiError::new(
                ErrorCode::InvalidRule,
                "set_repair_action",
                "use_supported_action",
            ));
        }
        let mut sessions = self.sessions.lock().expect("sessions");
        let session = sessions.get_mut(&handle).ok_or_else(|| {
            ApiError::new(
                ErrorCode::NotFound,
                "set_repair_action",
                "reopen_repair_session",
            )
        })?;
        session.history.truncate(session.history_index + 1);
        let mut actions = session.history[session.history_index].actions.clone();
        actions.push(action_json);
        let mode = session.history[session.history_index].mode.clone();
        session.history.push(SessionState { mode, actions });
        session.history_index += 1;
        session.revision = session.revision.checked_add(1).ok_or_else(|| {
            ApiError::new(
                ErrorCode::Internal,
                "set_repair_action",
                "restart_application",
            )
        })?;
        drop(sessions);
        self.snapshot(handle)
    }

    pub fn undo(&self, handle: u64) -> Result<String, ApiError> {
        let mut sessions = self.sessions.lock().expect("sessions");
        let session = sessions.get_mut(&handle).ok_or_else(|| {
            ApiError::new(
                ErrorCode::NotFound,
                "undo_repair_session",
                "reopen_repair_session",
            )
        })?;
        if session.history_index == 0 {
            return Err(ApiError::new(
                ErrorCode::InvalidCursor,
                "undo_repair_session",
                "choose_previous_repair_revision",
            ));
        }
        session.history_index -= 1;
        session.revision = session.revision.checked_add(1).ok_or_else(|| {
            ApiError::new(
                ErrorCode::Internal,
                "undo_repair_session",
                "restart_application",
            )
        })?;
        drop(sessions);
        self.snapshot(handle)
    }

    pub fn redo(&self, handle: u64) -> Result<String, ApiError> {
        let mut sessions = self.sessions.lock().expect("sessions");
        let session = sessions.get_mut(&handle).ok_or_else(|| {
            ApiError::new(
                ErrorCode::NotFound,
                "redo_repair_session",
                "reopen_repair_session",
            )
        })?;
        if session.history_index + 1 >= session.history.len() {
            return Err(ApiError::new(
                ErrorCode::InvalidCursor,
                "redo_repair_session",
                "choose_next_repair_revision",
            ));
        }
        session.history_index += 1;
        session.revision = session.revision.checked_add(1).ok_or_else(|| {
            ApiError::new(
                ErrorCode::Internal,
                "redo_repair_session",
                "restart_application",
            )
        })?;
        drop(sessions);
        self.snapshot(handle)
    }

    pub fn cancel(&self, handle: u64) -> Result<String, ApiError> {
        let mut sessions = self.sessions.lock().expect("sessions");
        let session = sessions.get_mut(&handle).ok_or_else(|| {
            ApiError::new(
                ErrorCode::NotFound,
                "cancel_repair_session",
                "reopen_repair_session",
            )
        })?;
        if session.history_index == 0 {
            drop(sessions);
            return self.snapshot(handle);
        }
        let base = session.history[0].clone();
        session.history.clear();
        session.history.push(base);
        session.history_index = 0;
        session.revision = session.revision.checked_add(1).ok_or_else(|| {
            ApiError::new(
                ErrorCode::Internal,
                "cancel_repair_session",
                "restart_application",
            )
        })?;
        drop(sessions);
        self.snapshot(handle)
    }

    pub fn close(&self, handle: u64) -> Result<(), ApiError> {
        if self
            .sessions
            .lock()
            .expect("sessions")
            .remove(&handle)
            .is_none()
        {
            return Err(ApiError::new(
                ErrorCode::NotFound,
                "close_repair_session",
                "reopen_repair_session",
            ));
        }
        Ok(())
    }

    fn get(&self, handle: u64) -> Result<Session, ApiError> {
        self.sessions
            .lock()
            .expect("sessions")
            .get(&handle)
            .cloned()
            .ok_or_else(|| {
                ApiError::new(
                    ErrorCode::NotFound,
                    "repair_session",
                    "reopen_repair_session",
                )
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn one_handle_owns_both_modes_and_revision_changes() {
        let manager = RepairSessionManager::new();
        let handle = manager.open("source".into(), 1).unwrap();
        assert!(
            manager
                .snapshot(handle)
                .unwrap()
                .contains("mode=self_service;action_count=0;undo_depth=0;redo_depth=0")
        );
        let next = manager.set_mode(handle, "catalog".into()).unwrap();
        assert!(next.contains("revision=2;mode=catalog;action_count=0;undo_depth=1;redo_depth=0"));
        let undone = manager.undo(handle).unwrap();
        assert!(
            undone
                .contains("revision=3;mode=self_service;action_count=0;undo_depth=0;redo_depth=1")
        );
        let redone = manager.redo(handle).unwrap();
        assert!(
            redone.contains("revision=4;mode=catalog;action_count=0;undo_depth=1;redo_depth=0")
        );
        let cancelled = manager.cancel(handle).unwrap();
        assert!(
            cancelled
                .contains("revision=5;mode=self_service;action_count=0;undo_depth=0;redo_depth=0")
        );
        assert_eq!(manager.close(handle).unwrap(), ());
        assert_eq!(
            manager.snapshot(handle).unwrap_err().code,
            ErrorCode::NotFound
        );
    }

    #[test]
    fn invalid_mode_cannot_change_session() {
        let manager = RepairSessionManager::new();
        let handle = manager.open("source".into(), 1).unwrap();
        assert_eq!(
            manager.set_mode(handle, "other".into()).unwrap_err().code,
            ErrorCode::InvalidRule
        );
        assert!(manager.snapshot(handle).unwrap().contains("revision=1"));
    }

    #[test]
    fn manual_action_is_validated_and_undoable() {
        let manager = RepairSessionManager::new();
        let handle = manager.open("source".into(), 1).unwrap();
        let state = manager
            .set_action(
                handle,
                r#"{"id":"number-reset:1","kind":"manual_review","source_lines":[5,6]}"#.into(),
            )
            .unwrap();
        assert!(state.contains("action_count=1;undo_depth=1"));
        assert_eq!(
            manager
                .set_action(handle, r#"{"kind":"unknown","source_lines":[1]}"#.into())
                .unwrap_err()
                .code,
            ErrorCode::InvalidRule
        );
        assert!(manager.undo(handle).unwrap().contains("action_count=0"));
        assert!(manager.redo(handle).unwrap().contains("action_count=1"));
    }

    #[test]
    fn cancel_drops_only_session_draft_and_keeps_source_identity() {
        let manager = RepairSessionManager::new();
        let handle = manager.open("source".into(), 7).unwrap();
        manager.set_mode(handle, "catalog".into()).unwrap();
        let snapshot = manager.cancel(handle).unwrap();
        assert!(snapshot.contains("source_id=source;source_revision=7"));
        assert!(snapshot.contains("mode=self_service;action_count=0;undo_depth=0;redo_depth=0"));
    }
}
