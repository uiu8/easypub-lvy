//! Each history state retains the recipe it was reviewed against, never the body.
use crate::edit_checkpoint::{self, EditRequest as Request, StoredCheckpoint};
use easypub_core::{
    ApiError, ErrorCode,
    effective_edit::{self, Action},
    publication::{self, EffectiveBook},
    source::SourceSnapshot,
    structure::Structure,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Base {
    pub structure: Option<Structure>,
    pub manual: Option<Value>,
    pub cleanup: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub catalog: Option<crate::catalog::CompositionRecipe>,
}
impl Base {
    pub(crate) fn compose(&self, source: &SourceSnapshot) -> Result<EffectiveBook, ApiError> {
        if let Some(catalog) = &self.catalog {
            return catalog.compose_replay(
                source,
                &self
                    .structure
                    .clone()
                    .unwrap_or_else(|| Structure::new(source)),
                self.manual.as_ref().map(Value::to_string).as_deref(),
                self.cleanup.as_ref().map(Value::to_string).as_deref(),
            );
        }
        publication::compose_with_cleanup(
            source,
            &self
                .structure
                .clone()
                .unwrap_or_else(|| Structure::new(source)),
            self.manual.as_ref().map(Value::to_string).as_deref(),
            self.cleanup.as_ref().map(Value::to_string).as_deref(),
        )
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Snapshot {
    pub base: Base,
    pub request: Request,
    /// Original reviewed recipe for change-history display after materialization.
    /// Never replayed; request remains the authoritative effective state.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recorded_request: Option<Request>,
    /// 这一步是清理变化时由上一步换算出来的（V17）。清理再变回上一步的依据时，
    /// 直接退回上一步，不再追加换算，撤销 / 重做清理才是真正的往返。
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub rebased: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct History {
    pub source_id: String,
    pub revision: u32,
    pub history: Vec<Snapshot>,
    pub cursor: usize,
}
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Command {
    AppendCatalog {
        catalog: crate::catalog::CompositionSelection,
    },
    Append {
        action: Action,
    },
    AppendBatch {
        actions: Vec<Action>,
    },
    Checkpoint {
        directory: String,
    },
    Undo,
    Redo,
    Clear,
    /// Move the current edits onto the incoming base (e.g. a changed cleanup)
    /// as a new undoable state; actions that cannot be moved are dropped and
    /// listed in the response.
    Rebase,
    Inspect,
    InspectSnapshot {
        version: usize,
        offset: usize,
        entry_id: Option<String>,
    },
    InspectComparison {
        before_version: usize,
        after_version: usize,
        entry_id: String,
        line: u32,
        kept_line: Option<u32>,
        #[serde(default)]
        before_offset: usize,
        #[serde(default)]
        after_offset: usize,
        #[serde(default)]
        before_char_offset: usize,
        #[serde(default)]
        after_char_offset: usize,
    },
}
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "effective_history",
        "review_effective_history",
    )
}
impl History {
    fn inspect_snapshot(
        &self,
        source: &SourceSnapshot,
        version: usize,
        offset: usize,
        entry_id: Option<&str>,
    ) -> Result<Value, ApiError> {
        self.validate_shape()?;
        if self.source_id != source.summary().source_id
            || self.revision != source.summary().revision
        {
            return Err(invalid());
        }
        let snapshot = self.history.get(version).ok_or_else(invalid)?;
        let book = snapshot.base.compose(source)?;
        if snapshot.request.origin_base_id() != effective_edit::base_id(&book) {
            return Err(invalid());
        }
        let book = if snapshot.request.is_empty() {
            book
        } else {
            edit_checkpoint::apply(book, &snapshot.request)?.0
        };
        let position =
            entry_id.and_then(|id| book.tree.nodes.iter().position(|n| n.entry_id == id));
        let offset = position.map(|p| p / 30 * 30).unwrap_or(offset);
        Ok(
            json!({"focus_position":position,"focus_found":position.is_some(),"nodes": book.tree.nodes.iter().skip(offset).take(30).collect::<Vec<_>>(),
            "total":book.tree.nodes.len(),"offset":offset,"version":version,"writes_source":false}),
        )
    }
    pub fn current(&self) -> &Snapshot {
        &self.history[self.cursor]
    }
    pub fn validate_shape(&self) -> Result<(), ApiError> {
        if self.source_id.len() != 64
            || self.revision != 1
            || self.history.is_empty()
            || self.history.len() > 51
            || self.cursor >= self.history.len()
            || serde_json::to_vec(self).map_err(|_| invalid())?.len() > 2 * 1024 * 1024
            || self
                .history
                .iter()
                .any(|s| s.request.actions.len() > 100 || s.request.base_id.len() != 64)
        {
            return Err(invalid());
        }
        for snapshot in &self.history {
            if let Some(c) = &snapshot.request.checkpoint {
                c.reference.validate()?;
                if !c.directory.is_absolute()
                    || c.origin_base_id.len() != 64
                    || c.reference.base_id != snapshot.request.base_id
                    || c.reference.source_id != self.source_id
                {
                    return Err(invalid());
                }
            }
        }
        Ok(())
    }
    fn materialize_history(
        &mut self,
        source: &SourceSnapshot,
        directory: &std::path::Path,
    ) -> Result<(), ApiError> {
        let mut previous: Option<(Base, Request, EffectiveBook)> = None;
        for snapshot in &mut self.history {
            if snapshot.request.actions.is_empty() {
                continue;
            }
            let original = snapshot.request.clone();
            // Only rename suffixes are incrementally reusable: structural edits
            // can derive new node IDs from their original action index.
            let reuse = previous.as_ref().is_some_and(|(base, request, _)| {
                *base == snapshot.base
                    && request.base_id == original.base_id
                    && request.checkpoint == original.checkpoint
                    && original.actions.starts_with(&request.actions)
                    && original.actions[request.actions.len()..]
                        .iter()
                        .all(|a| matches!(a, Action::Rename { .. }))
            });
            let book = if reuse {
                let (_, prefix, current) = previous.take().unwrap();
                let remaining = original.actions[prefix.actions.len()..].to_vec();
                if remaining.is_empty() {
                    current
                } else {
                    let request = effective_edit::Request {
                        base_id: effective_edit::base_id(&current),
                        actions: remaining,
                    };
                    effective_edit::apply(current, &request)?.0
                }
            } else {
                edit_checkpoint::apply(snapshot.base.compose(source)?, &original)?.0
            };
            let reference = edit_checkpoint::save(directory, &book)?;
            snapshot
                .recorded_request
                .get_or_insert_with(|| original.clone());
            snapshot.request = Request {
                base_id: reference.base_id.clone(),
                actions: vec![],
                checkpoint: Some(StoredCheckpoint {
                    directory: directory.into(),
                    origin_base_id: original.origin_base_id().into(),
                    reference,
                }),
            };
            previous = Some((snapshot.base.clone(), original, book));
        }
        Ok(())
    }

    pub fn validate(&self, source: &SourceSnapshot) -> Result<(), ApiError> {
        self.validate_shape()?;
        if self.source_id != source.summary().source_id
            || self.revision != source.summary().revision
        {
            return Err(invalid());
        }
        // Validate every retained state, but compose/hash an unchanged base only
        // once. Checkpoint decoding is bounded separately and is not edit replay.
        let mut work = 0usize;
        let mut bases: Vec<(Base, String)> = Vec::new();
        for (index, snapshot) in self.history.iter().enumerate() {
            // Appends share prefixes. Replaying a longer sequence validates each
            // of its earlier states; don't rescan a long book quadratically.
            if self.history.iter().enumerate().any(|(other_index, other)| {
                other.base == snapshot.base
                    && other.request.base_id == snapshot.request.base_id
                    && other.request.checkpoint == snapshot.request.checkpoint
                    && other.request.actions.starts_with(&snapshot.request.actions)
                    && (other.request.actions.len() > snapshot.request.actions.len()
                        || (other.request.actions.len() == snapshot.request.actions.len()
                            && other_index < index))
            }) {
                continue;
            }

            let mut composed = None;
            let identity = if let Some((_, identity)) =
                bases.iter().find(|(base, _)| *base == snapshot.base)
            {
                identity.clone()
            } else {
                let book = snapshot.base.compose(source)?;
                let identity = effective_edit::base_id(&book);
                work = work.saturating_add(book.text.len());
                composed = Some(book);
                bases.push((snapshot.base.clone(), identity.clone()));
                identity
            };
            if snapshot.request.origin_base_id() != identity {
                return Err(invalid());
            }
            if !snapshot.request.is_empty() {
                let book = if let Some(checkpoint) = &snapshot.request.checkpoint {
                    edit_checkpoint::load(
                        &checkpoint.directory,
                        &checkpoint.reference,
                        &self.source_id,
                    )?
                } else if let Some(book) = composed {
                    book
                } else {
                    let book = snapshot.base.compose(source)?;
                    work = work.saturating_add(book.text.len());
                    book
                };
                if !snapshot.request.actions.is_empty() {
                    let request = effective_edit::Request {
                        base_id: snapshot.request.base_id.clone(),
                        actions: snapshot.request.actions.clone(),
                    };
                    let (_, _, bytes) = effective_edit::apply_profiled(book, &request)?;
                    work = work.saturating_add(bytes);
                }
            }
            if work > 1024 * 1024 * 1024 {
                return Err(ApiError::new(
                    ErrorCode::TooLarge,
                    "effective_history",
                    "reduce_history",
                ));
            }
        }
        Ok(())
    }
    fn apply(
        &mut self,
        source: &SourceSnapshot,
        base: Base,
        command: Command,
    ) -> Result<bool, ApiError> {
        self.validate(source)?;
        let current_book = base.compose(source)?;
        let current_id = effective_edit::base_id(&current_book);
        let mut candidate = self.clone();
        let command = match command {
            Command::AppendCatalog { catalog } => {
                if candidate.current().request.origin_base_id() != current_id {
                    return Err(invalid());
                }
                let edited;
                let view = if candidate.current().request.is_empty() {
                    &current_book
                } else {
                    edited = edit_checkpoint::apply(
                        base.compose(source)?,
                        &candidate.current().request,
                    )?
                    .0;
                    &edited
                };
                Command::AppendBatch {
                    actions: crate::catalog::effective_actions(source, view, &catalog)?,
                }
            }
            Command::Append { action } => Command::AppendBatch {
                actions: vec![action],
            },
            other => other,
        };
        match command {
            Command::Undo if candidate.cursor > 0 => candidate.cursor -= 1,
            Command::Redo if candidate.cursor + 1 < candidate.history.len() => {
                candidate.cursor += 1
            }
            Command::AppendBatch { actions } => {
                if actions.is_empty()
                    || actions.len() > 100
                    || candidate.current().request.origin_base_id() != current_id
                {
                    return Err(invalid());
                }
                let mut snapshot = candidate.current().clone();
                snapshot.recorded_request = None;
                snapshot.rebased = false;
                snapshot.request.actions.extend(actions);
                if snapshot.request.actions.len() > 100 {
                    return Err(invalid());
                }
                edit_checkpoint::apply(current_book, &snapshot.request)?;
                candidate.push(snapshot);
            }
            Command::Checkpoint { directory } => {
                if candidate.current().request.origin_base_id() != current_id {
                    return Err(invalid());
                }
                if !candidate.current().request.actions.is_empty() {
                    // Persist every retained state before switching any active
                    // history; keep the original recipes for the history UI.
                    candidate.materialize_history(source, std::path::Path::new(&directory))?;
                    // A storage checkpoint must not discard the redo branch.
                    // At the retention limit materialize in place, without an
                    // extra no-content-change undo step displacing an edit.
                    if candidate.history.len() < 51 {
                        let snapshot = Snapshot {
                            rebased: false,
                            recorded_request: None,
                            base,
                            request: candidate.current().request.clone(),
                        };
                        candidate.history.insert(candidate.cursor + 1, snapshot);
                        candidate.cursor += 1;
                    }
                }
            }
            Command::Clear => {
                if !candidate.current().request.is_empty()
                    || candidate.current().request.origin_base_id() != current_id
                {
                    candidate.push(Snapshot {
                        rebased: false,
                        recorded_request: None,
                        base,
                        request: Request {
                            checkpoint: None,
                            base_id: current_id.clone(),
                            actions: vec![],
                        },
                    });
                }
            }
            Command::Inspect => {}
            _ => return Err(invalid()),
        }
        candidate.validate(source)?;
        let matches = candidate.current().request.origin_base_id() == current_id;
        *self = candidate;
        Ok(matches)
    }
    fn rebase(&mut self, source: &SourceSnapshot, base: Base) -> Result<Value, ApiError> {
        self.validate(source)?;
        let current_book = base.compose(source)?;
        let current_id = effective_edit::base_id(&current_book);
        // 往返（V17）：当前一步是换算结果，上一步正好建立在新依据上时退回上一步。
        // 依据按合成后的书稿标识比较：同一套清理在草稿与历史中的 JSON 写法可能不同。
        if self.current().rebased
            && self.cursor > 0
            && self.history[self.cursor - 1].request.origin_base_id() == current_id
        {
            let mut candidate = self.clone();
            candidate.history.truncate(candidate.cursor);
            candidate.cursor -= 1;
            candidate.validate(source)?;
            *self = candidate;
            let total = self.current().request.actions.len();
            return Ok(json!({"kept":(0..total).collect::<Vec<_>>(),"skipped":[],
                "total":total,"changed":true,"restored":true}));
        }
        let request = self.current().request.clone();
        if request.is_empty() || request.origin_base_id() == current_id {
            return Ok(
                json!({"kept":(0..request.actions.len()).collect::<Vec<_>>(),
                "skipped":[],"total":request.actions.len(),"changed":false}),
            );
        }
        if let Some(checkpoint) = &request.checkpoint {
            return self.rebase_checkpoint(source, base, current_book, checkpoint.clone());
        }
        let old_book = self.current().base.compose(source)?;
        let moved = effective_edit::rebase(
            old_book,
            current_book,
            &effective_edit::Request {
                base_id: request.base_id.clone(),
                actions: request.actions.clone(),
            },
        )?;
        let mut candidate = self.clone();
        candidate.push(Snapshot {
            rebased: true,
            recorded_request: None,
            base,
            request: Request {
                checkpoint: None,
                base_id: current_id.clone(),
                actions: moved.request.map(|r| r.actions).unwrap_or_default(),
            },
        });
        candidate.validate(source)?;
        *self = candidate;
        Ok(
            json!({"kept":moved.kept,"skipped":moved.skipped,"total":request.actions.len(),"changed":true}),
        )
    }
    /// 检查点之上的章节修改换算（CLEAN-105），换算本身见 [`rebase_across_checkpoint`]。
    /// 原始操作取自创建这个检查点的那一步保存的 `recorded_request`。
    fn rebase_checkpoint(
        &mut self,
        source: &SourceSnapshot,
        base: Base,
        new_origin: EffectiveBook,
        checkpoint: StoredCheckpoint,
    ) -> Result<Value, ApiError> {
        let request = self.current().request.clone();
        let root = self
            .history
            .iter()
            .find(|s| s.request.checkpoint.as_ref() == Some(&checkpoint))
            .and_then(|s| s.recorded_request.clone())
            .ok_or_else(rebase_unsupported)?;
        let old_origin = self.current().base.compose(source)?;
        let new_origin_id = effective_edit::base_id(&new_origin);
        let moved = rebase_across_checkpoint(old_origin, new_origin, &root, &request)?;
        let next = if moved.root.is_empty() {
            // 原始操作全部无法换算：检查点之后的操作直接基于新依据。
            Snapshot {
                rebased: true,
                recorded_request: None,
                base,
                request: Request {
                    checkpoint: None,
                    base_id: new_origin_id.clone(),
                    actions: moved.tail,
                },
            }
        } else {
            let reference = edit_checkpoint::save(&checkpoint.directory, &moved.checkpoint_book)?;
            let stored = StoredCheckpoint {
                directory: checkpoint.directory.clone(),
                origin_base_id: new_origin_id.clone(),
                reference,
            };
            Snapshot {
                rebased: true,
                // 新检查点同样保留换算后的原始操作，之后还能再次换算。
                recorded_request: Some(Request {
                    checkpoint: None,
                    base_id: new_origin_id.clone(),
                    actions: moved.root,
                }),
                base,
                request: Request {
                    base_id: stored.reference.base_id.clone(),
                    checkpoint: Some(stored),
                    actions: moved.tail,
                },
            }
        };
        let mut candidate = self.clone();
        candidate.push(next);
        candidate.validate(source)?;
        *self = candidate;
        Ok(json!({"kept":moved.kept,"skipped":moved.skipped,
            "total":moved.total,"changed":true,"checkpoint":true}))
    }
    fn push(&mut self, snapshot: Snapshot) {
        self.history.truncate(self.cursor + 1);
        self.history.push(snapshot);
        if self.history.len() > 51 {
            self.history.remove(0);
        }
        self.cursor = self.history.len() - 1;
    }
}
fn rebase_unsupported() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "effective_history",
        "rebase_checkpoint",
    )
}

/// 跨检查点换算的结果（CLEAN-105）。
pub(crate) struct AcrossCheckpoint {
    /// 原始操作换算到新依据后的书稿（新的检查点书稿）。
    pub checkpoint_book: EffectiveBook,
    /// 再加上检查点之后的操作后的最终书稿。
    pub book: EffectiveBook,
    /// 保留的操作序号：原始操作在前，检查点之后的操作接着编号。
    pub kept: Vec<usize>,
    pub skipped: Vec<Value>,
    pub total: usize,
    /// 换算后的原始操作（相对新依据）与检查点之后的操作（相对新的检查点书稿）。
    pub root: Vec<Action>,
    pub tail: Vec<Action>,
}

/// 检查点只存了结果，但创建它的那一步保留了从原始依据开始的完整操作（`root`）。
/// 分两段换算：先把 `root` 换算到新依据上，得到新的检查点书稿；再把检查点之后的
/// 操作（`tail`）从旧检查点书稿换算到新的检查点书稿上。不能把两段直接拼起来重放：
/// 结构操作按自身序号生成新节点标识，拼接会改变序号。只支持一层检查点：`root`
/// 本身又基于检查点（多次压缩），或重放 `root` 得不到当初保存的检查点书稿时，如实拒绝。
pub(crate) fn rebase_across_checkpoint(
    old_origin: EffectiveBook,
    new_origin: EffectiveBook,
    root: &Request,
    tail: &Request,
) -> Result<AcrossCheckpoint, ApiError> {
    let checkpoint = tail.checkpoint.as_ref().ok_or_else(rebase_unsupported)?;
    if root.checkpoint.is_some()
        || root.actions.is_empty()
        || root.base_id != effective_edit::base_id(&old_origin)
        || root.base_id != checkpoint.origin_base_id
    {
        return Err(rebase_unsupported());
    }
    let root_request = effective_edit::Request {
        base_id: root.base_id.clone(),
        actions: root.actions.clone(),
    };
    let old_checkpoint = effective_edit::apply(old_origin.clone(), &root_request)?.0;
    if effective_edit::base_id(&old_checkpoint) != checkpoint.reference.base_id
        || tail.base_id != checkpoint.reference.base_id
    {
        return Err(rebase_unsupported());
    }
    let first = effective_edit::rebase(old_origin, new_origin, &root_request)?;
    let root_len = root.actions.len();
    let mut kept = first.kept.clone();
    let mut skipped = first.skipped.clone();
    let checkpoint_book = first.book;
    let mut book = checkpoint_book.clone();
    let mut moved_tail = Vec::new();
    if !tail.actions.is_empty() {
        let second = effective_edit::rebase(
            old_checkpoint,
            checkpoint_book.clone(),
            &effective_edit::Request {
                base_id: tail.base_id.clone(),
                actions: tail.actions.clone(),
            },
        )?;
        kept.extend(second.kept.iter().map(|i| i + root_len));
        for mut item in second.skipped {
            if let Some(i) = item["index"].as_u64() {
                item["index"] = json!(i as usize + root_len);
            }
            skipped.push(item);
        }
        book = second.book;
        moved_tail = second.request.map(|r| r.actions).unwrap_or_default();
    }
    Ok(AcrossCheckpoint {
        checkpoint_book,
        book,
        kept,
        skipped,
        total: root_len + tail.actions.len(),
        root: first.request.map(|r| r.actions).unwrap_or_default(),
        tail: moved_tail,
    })
}
pub fn edit(
    service: &crate::sessions::ImportService,
    source_id: String,
    revision: u32,
    base_json: String,
    draft_json: String,
    command_json: String,
) -> Result<String, ApiError> {
    if base_json.len() > 3 * 1024 * 1024
        || draft_json.len() > 2 * 1024 * 1024
        || command_json.len() > 3 * 1024 * 1024
    {
        return Err(invalid());
    }
    let source = service.source(&source_id, revision)?;
    let command: Command = serde_json::from_str(&command_json).map_err(|_| invalid())?;
    if command_json.len() > 65536 && !matches!(command, Command::AppendCatalog { .. }) {
        return Err(invalid());
    }
    if let Command::InspectSnapshot {
        version,
        offset,
        entry_id,
    } = command
    {
        let history: History = serde_json::from_str(&draft_json).map_err(|_| invalid())?;
        return Ok(history
            .inspect_snapshot(&source, version, offset, entry_id.as_deref())?
            .to_string());
    }
    if let Command::InspectComparison { before_version, after_version, entry_id, line,
        kept_line, before_offset, after_offset, before_char_offset, after_char_offset } = command {
        let history: History = serde_json::from_str(&draft_json).map_err(|_| invalid())?;
        history.validate_shape()?;
        if history.source_id != source.summary().source_id || history.revision != revision
            || after_version != before_version.saturating_add(1) || line == 0 {
            return Err(invalid());
        }
        let compose = |version: usize| -> Result<EffectiveBook, ApiError> {
            let snapshot = history.history.get(version).ok_or_else(invalid)?;
            let book = snapshot.base.compose(&source)?;
            if snapshot.request.origin_base_id() != effective_edit::base_id(&book) { return Err(invalid()); }
            if snapshot.request.is_empty() { Ok(book) } else { Ok(edit_checkpoint::apply(book, &snapshot.request)?.0) }
        };
        let before = compose(before_version)?;
        let after = compose(after_version)?;
        let comparison = crate::repair_comparison::compare(&before, &after, &entry_id, line,
            kept_line, before_offset, after_offset, before_char_offset, after_char_offset);
        return Ok(json!({"comparison":comparison,"before_version":before_version,
            "after_version":after_version,"writes_source":false}).to_string());
    }
    let mut incoming: Value = serde_json::from_str(&base_json).map_err(|_| invalid())?;
    if let Some(catalog) = incoming.get("catalog").filter(|v| !v.is_null()) {
        let selection: crate::catalog::CompositionSelection =
            serde_json::from_value(catalog.clone()).map_err(|_| invalid())?;
        incoming["catalog"] =
            serde_json::to_value(selection.confirmed_recipe(&source)?).map_err(|_| invalid())?;
    }
    let base: Base = serde_json::from_value(incoming).map_err(|_| invalid())?;
    let mut history: History = if draft_json.is_empty() {
        let base_id = effective_edit::base_id(&base.compose(&source)?);
        History {
            source_id,
            revision,
            history: vec![Snapshot {
                rebased: false,
                recorded_request: None,
                base: base.clone(),
                request: Request {
                    checkpoint: None,
                    base_id,
                    actions: vec![],
                },
            }],
            cursor: 0,
        }
    } else {
        serde_json::from_str(&draft_json).map_err(|_| invalid())?
    };
    if let Command::Rebase = command {
        let summary = history.rebase(&source, base)?;
        return Ok(
            json!({"history":history,"matches_current":true,"rebase":summary,
            "writes_source":false})
            .to_string(),
        );
    }
    let matches = history.apply(&source, base, command)?;
    Ok(json!({"history":history,"matches_current":matches,"writes_source":false}).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn setup() -> (SourceSnapshot, Base, History, String) {
        let source = SourceSnapshot::from_utf8(
            "001 起\n正文\n".as_bytes().to_vec(),
            easypub_core::source::RULE_ID,
            || false,
        )
        .unwrap();
        let base = Base {
            catalog: None,
            structure: None,
            manual: None,
            cleanup: Some(
                json!({"kind":"cleanup","pipeline":[{"kind":"chapter_numbers","style":"chinese","bare_titles":true}]}),
            ),
        };
        let book = base.compose(&source).unwrap();
        let id = book.tree.nodes[0].entry_id.clone();
        let history = History {
            source_id: source.summary().source_id,
            revision: 1,
            cursor: 0,
            history: vec![Snapshot {
                rebased: false,
                recorded_request: None,
                base: base.clone(),
                request: Request {
                    checkpoint: None,
                    base_id: effective_edit::base_id(&book),
                    actions: vec![],
                },
            }],
        };
        (source, base, history, id)
    }
    #[test]
    fn rebase_moves_edits_onto_changed_cleanup_as_an_undoable_state() {
        let (source, base, mut history, id) = setup();
        history
            .apply(
                &source,
                base.clone(),
                Command::Append {
                    action: Action::Rename {
                        entry_id: id,
                        title: "第一章 改名".into(),
                    },
                },
            )
            .unwrap();
        let before = history.history.len();
        let mut cleaned = base.clone();
        cleaned.cleanup = Some(json!({"kind":"cleanup","pipeline":[
            {"kind":"chapter_numbers","style":"chinese","bare_titles":true},
            {"kind":"literal_replace","find":"正文","replace":"内容"}]}));
        // The stored edit no longer matches the changed cleanup...
        assert!(
            !history
                .apply(&source, cleaned.clone(), Command::Inspect)
                .unwrap()
        );
        // ...until it is rebased as a new state.
        let summary = history.rebase(&source, cleaned.clone()).unwrap();
        assert_eq!(summary["kept"], json!([0]));
        assert_eq!(summary["skipped"], json!([]));
        assert_eq!(history.history.len(), before + 1);
        let current = history.current();
        assert_eq!(current.base, cleaned);
        let book = edit_checkpoint::apply(cleaned.compose(&source).unwrap(), &current.request)
            .unwrap()
            .0;
        assert!(book.text.starts_with("第一章 改名\n内容"));
        // Undo returns to the edit on the previous cleanup.
        assert!(history.apply(&source, base.clone(), Command::Undo).unwrap());
        // Rebasing again onto the same base is a no-op.
        history
            .apply(&source, cleaned.clone(), Command::Redo)
            .unwrap();
        let len = history.history.len();
        assert_eq!(history.rebase(&source, cleaned.clone()).unwrap()["changed"], false);
        assert_eq!(history.history.len(), len);
        // V17：清理变回上一步的依据时退回原来那一步（往返不留换算步骤），
        // 之后章节修改仍能按顺序撤销。
        let restored = history.rebase(&source, base.clone()).unwrap();
        assert_eq!(restored["restored"], true);
        assert_eq!(restored["skipped"], json!([]));
        assert_eq!(history.history.len(), before);
        assert!(!history.current().rebased);
        assert_eq!(history.current().base, base);
        assert!(history.apply(&source, base.clone(), Command::Undo).unwrap());
        assert!(history.current().request.actions.is_empty());
        // 换算之后又追加了修改：不能退回，照常换算为新的一步。
        history.apply(&source, base.clone(), Command::Redo).unwrap();
        history.rebase(&source, cleaned.clone()).unwrap();
        let entry = edit_checkpoint::apply(cleaned.compose(&source).unwrap(), &history.current().request)
            .unwrap()
            .0
            .tree
            .nodes[0]
            .entry_id
            .clone();
        history
            .apply(
                &source,
                cleaned.clone(),
                Command::Append {
                    action: Action::Rename {
                        entry_id: entry,
                        title: "第一章 再改".into(),
                    },
                },
            )
            .unwrap();
        assert!(!history.current().rebased);
        let moved = history.rebase(&source, base.clone()).unwrap();
        assert!(moved.get("restored").is_none());
        assert!(history.current().rebased);
        assert_eq!(history.current().request.actions.len(), 2);
    }
    #[test]
    fn rebase_moves_edits_across_a_checkpoint_in_two_stages() {
        let (source, base, mut history, id) = setup();
        let directory = std::env::temp_dir().join(format!(
            "easypub-rebase-checkpoint-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let rename = |history: &mut History, base: &Base, title: &str| {
            history
                .apply(
                    &source,
                    base.clone(),
                    Command::Append {
                        action: Action::Rename {
                            entry_id: id.clone(),
                            title: title.into(),
                        },
                    },
                )
                .unwrap();
        };
        let checkpoint = |history: &mut History, base: &Base| {
            history
                .apply(
                    &source,
                    base.clone(),
                    Command::Checkpoint {
                        directory: directory.to_string_lossy().into_owned(),
                    },
                )
                .unwrap();
        };
        rename(&mut history, &base, "第一章 压缩前");
        checkpoint(&mut history, &base);
        assert!(history.current().request.checkpoint.is_some());
        let renamed = edit_checkpoint::apply(base.compose(&source).unwrap(), &history.current().request)
            .unwrap()
            .0;
        let renamed_id = renamed.tree.nodes[0].entry_id.clone();
        history
            .apply(
                &source,
                base.clone(),
                Command::Append {
                    action: Action::Rename {
                        entry_id: renamed_id,
                        title: "第一章 压缩后".into(),
                    },
                },
            )
            .unwrap();
        let mut cleaned = base.clone();
        cleaned.cleanup = Some(json!({"kind":"cleanup","pipeline":[
            {"kind":"chapter_numbers","style":"chinese","bare_titles":true},
            {"kind":"literal_replace","find":"正文","replace":"内容"}]}));
        // 原来遇到检查点就拒绝；现在先换算原始操作，再换算检查点之后的操作。
        let summary = history.rebase(&source, cleaned.clone()).unwrap();
        assert_eq!(summary["kept"], json!([0, 1]));
        assert_eq!(summary["skipped"], json!([]));
        assert_eq!(summary["checkpoint"], true);
        let current = history.current();
        assert_eq!(current.base, cleaned);
        assert!(current.request.checkpoint.is_some());
        assert!(current.recorded_request.is_some());
        let book = edit_checkpoint::apply(cleaned.compose(&source).unwrap(), &current.request)
            .unwrap()
            .0;
        assert!(book.text.starts_with("第一章 压缩后\n内容"), "{}", book.text);
        // 新检查点保留了换算后的原始操作，可以再换算回原来的清理。
        let back = history.rebase(&source, base.clone()).unwrap();
        assert_eq!(back["skipped"], json!([]));
        let book = edit_checkpoint::apply(base.compose(&source).unwrap(), &history.current().request)
            .unwrap()
            .0;
        assert!(book.text.starts_with("第一章 压缩后\n正文"), "{}", book.text);
        // 检查点之上再压缩一次：原始操作本身基于检查点，如实拒绝。
        checkpoint(&mut history, &base);
        let error = history.rebase(&source, cleaned).unwrap_err();
        assert!(format!("{error:?}").contains("rebase_checkpoint"), "{error:?}");
        let _ = std::fs::remove_dir_all(&directory);
    }
    #[test]
    fn checkpoint_preserves_redo_and_every_state_at_retention_limit() {
        let (source, base, mut history, id) = setup();
        let directory = std::env::temp_dir().join(format!(
            "easypub-redo67-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        for i in 1..=2 {
            history
                .apply(
                    &source,
                    base.clone(),
                    Command::Append {
                        action: Action::Rename {
                            entry_id: id.clone(),
                            title: format!("第一章 编辑{i}"),
                        },
                    },
                )
                .unwrap();
        }
        history.apply(&source, base.clone(), Command::Undo).unwrap();
        history
            .apply(
                &source,
                base.clone(),
                Command::Checkpoint {
                    directory: directory.to_string_lossy().into_owned(),
                },
            )
            .unwrap();
        assert_eq!(history.history.len(), 4);
        history.apply(&source, base.clone(), Command::Redo).unwrap();
        let current =
            edit_checkpoint::apply(base.compose(&source).unwrap(), &history.current().request)
                .unwrap()
                .0;
        assert_eq!(current.tree.nodes[0].title, "第一章 编辑2");
        for i in 3..=52 {
            history
                .apply(
                    &source,
                    base.clone(),
                    Command::Append {
                        action: Action::Rename {
                            entry_id: id.clone(),
                            title: format!("第一章 编辑{i}"),
                        },
                    },
                )
                .unwrap();
        }
        history.apply(&source, base.clone(), Command::Undo).unwrap();
        let expected = history
            .history
            .iter()
            .map(|s| {
                let book = s.base.compose(&source).unwrap();
                edit_checkpoint::apply(book, &s.request).unwrap().0.text
            })
            .collect::<Vec<_>>();
        let cursor = history.cursor;
        history
            .apply(
                &source,
                base.clone(),
                Command::Checkpoint {
                    directory: directory.to_string_lossy().into_owned(),
                },
            )
            .unwrap();
        assert_eq!(history.history.len(), 51);
        assert_eq!(history.cursor, cursor);
        for (snapshot, text) in history.history.iter().zip(expected) {
            assert_eq!(
                edit_checkpoint::apply(snapshot.base.compose(&source).unwrap(), &snapshot.request)
                    .unwrap()
                    .0
                    .text,
                text
            );
        }
        history.apply(&source, base, Command::Redo).unwrap();
        assert_eq!(history.cursor, 50);
    }

    #[test]
    fn materialized_mixed_history_preserves_every_tree_map_and_original_recipe() {
        let source = SourceSnapshot::from_utf8(
            "第一章 开始\n甲文\n乙文\n第二章 继续\n丙文\n"
                .as_bytes()
                .to_vec(),
            easypub_core::source::RULE_ID,
            || false,
        )
        .unwrap();
        let base = Base {
            structure: None,
            manual: None,
            cleanup: None,
            catalog: None,
        };
        let book = base.compose(&source).unwrap();
        let first = book.tree.nodes[0].entry_id.clone();
        let mut history = History {
            source_id: source.summary().source_id.clone(),
            revision: 1,
            cursor: 0,
            history: vec![Snapshot {
                rebased: false,
                recorded_request: None,
                base: base.clone(),
                request: Request {
                    base_id: effective_edit::base_id(&book),
                    actions: vec![],
                    checkpoint: None,
                },
            }],
        };
        for action in [
            Action::Split {
                entry_id: first.clone(),
                line_offset: 2,
                title: "第二章 插入标题".into(),
            },
            Action::Rename {
                entry_id: first.clone(),
                title: "第一章 改名".into(),
            },
            Action::InsertVolume {
                entry_id: first,
                title: "第一卷 卷名".into(),
            },
        ] {
            history
                .apply(&source, base.clone(), Command::Append { action })
                .unwrap();
        }
        let original = history
            .history
            .iter()
            .map(|s| serde_json::to_value(&s.request).unwrap())
            .collect::<Vec<_>>();
        let states=history.history.iter().map(|s| {
            let book=s.base.compose(&source).unwrap();
            let book=if s.request.is_empty(){book}else{edit_checkpoint::apply(book,&s.request).unwrap().0};
            json!({"text":book.text,"tree":book.tree,"map":book.source_to_output_lines,"removed":book.removed_structure_lines})
        }).collect::<Vec<_>>();
        let directory = std::env::temp_dir().join(format!(
            "easypub-mixed67-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        history
            .apply(
                &source,
                base,
                Command::Checkpoint {
                    directory: directory.to_string_lossy().into_owned(),
                },
            )
            .unwrap();
        assert_eq!(history.history.len(), states.len() + 1);
        for (i, snapshot) in history.history.iter().take(states.len()).enumerate() {
            let book = snapshot.base.compose(&source).unwrap();
            let book = if snapshot.request.is_empty() {
                book
            } else {
                edit_checkpoint::apply(book, &snapshot.request).unwrap().0
            };
            assert_eq!(
                json!({"text":book.text,"tree":book.tree,"map":book.source_to_output_lines,"removed":book.removed_structure_lines}),
                states[i]
            );
            if i > 0 {
                assert_eq!(
                    serde_json::to_value(snapshot.recorded_request.as_ref().unwrap()).unwrap(),
                    original[i]
                );
            }
        }
        let restored: History =
            serde_json::from_str(&serde_json::to_string(&history).unwrap()).unwrap();
        restored.validate(&source).unwrap();
    }

    #[test]
    #[ignore = "8 MiB multi-checkpoint history; run explicitly in release"]
    fn large_history_continues_across_six_checkpoints_without_dropping_states() {
        let started = std::time::Instant::now();
        let source = SourceSnapshot::from_utf8(
            format!("第一章 开始\n{}\n", "甲".repeat(8 * 1024 * 1024 / 3)).into_bytes(),
            easypub_core::source::RULE_ID,
            || false,
        )
        .unwrap();
        let base = Base {
            structure: None,
            manual: None,
            cleanup: None,
            catalog: None,
        };
        let initial = base.compose(&source).unwrap();
        let id = initial.tree.nodes[0].entry_id.clone();
        let mut history = History {
            source_id: source.summary().source_id.clone(),
            revision: 1,
            cursor: 0,
            history: vec![Snapshot {
                rebased: false,
                recorded_request: None,
                base: base.clone(),
                request: Request {
                    base_id: effective_edit::base_id(&initial),
                    actions: vec![],
                    checkpoint: None,
                },
            }],
        };
        let directory = std::env::temp_dir().join(format!(
            "easypub-history67-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        for round in 1..=6 {
            history
                .apply(
                    &source,
                    base.clone(),
                    Command::AppendBatch {
                        actions: (0..24)
                            .map(|_| Action::Rename {
                                entry_id: id.clone(),
                                title: format!("第一章 第{round}轮"),
                            })
                            .collect(),
                    },
                )
                .unwrap_or_else(|e| panic!("round {round}: {e:?}"));
            history
                .apply(
                    &source,
                    base.clone(),
                    Command::Checkpoint {
                        directory: directory.to_string_lossy().into_owned(),
                    },
                )
                .unwrap();
            assert_eq!(history.history.len(), 1 + round * 2);
            let encoded = serde_json::to_string(&history).unwrap();
            history = serde_json::from_str(&encoded).unwrap();
            history.validate(&source).unwrap();
        }
        for round in (1..=6).rev() {
            let book =
                edit_checkpoint::apply(base.compose(&source).unwrap(), &history.current().request)
                    .unwrap()
                    .0;
            assert_eq!(book.tree.nodes[0].title, format!("第一章 第{round}轮"));
            history.apply(&source, base.clone(), Command::Undo).unwrap();
            history.apply(&source, base.clone(), Command::Undo).unwrap();
        }
        assert!(history.current().request.is_empty());
        for _ in 0..12 {
            history.apply(&source, base.clone(), Command::Redo).unwrap();
        }
        assert_eq!(history.cursor, 12);
        assert!(source.decoded_text().starts_with("第一章 开始\n"));
        println!(
            "scale67 rounds=6 actions=144 retained_states={} elapsed_ms={}",
            history.history.len(),
            started.elapsed().as_millis()
        );
    }

    #[test]
    fn checkpoints_keep_history_reopen_and_undo_across_240_actions() {
        let (source, base, mut history, id) = setup();
        let directory = std::env::temp_dir().join(format!(
            "easypub-history-checkpoints-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let original = source.original_bytes().to_vec();
        for round in 0..4 {
            history
                .apply(
                    &source,
                    base.clone(),
                    Command::AppendBatch {
                        actions: (1..=60)
                            .map(|i| Action::Rename {
                                entry_id: id.clone(),
                                title: format!("第一章 编辑{}", round * 60 + i),
                            })
                            .collect(),
                    },
                )
                .unwrap();
            let before =
                edit_checkpoint::apply(base.compose(&source).unwrap(), &history.current().request)
                    .unwrap()
                    .0;
            history
                .apply(
                    &source,
                    base.clone(),
                    Command::Checkpoint {
                        directory: directory.to_string_lossy().into_owned(),
                    },
                )
                .unwrap();
            assert!(history.current().request.actions.is_empty());
            assert!(history.current().request.checkpoint.is_some());
            let restored =
                edit_checkpoint::apply(base.compose(&source).unwrap(), &history.current().request)
                    .unwrap()
                    .0;
            assert_eq!(before.text, restored.text);
            assert_eq!(
                before.source_to_output_lines,
                restored.source_to_output_lines
            );
            history = serde_json::from_str(&serde_json::to_string(&history).unwrap()).unwrap();
            history.validate(&source).unwrap();
        }
        let saved = serde_json::to_string(&history).unwrap();
        // Undo the checkpoint, then the last 60-edit batch: return to edit 180.
        history.apply(&source, base.clone(), Command::Undo).unwrap();
        history.apply(&source, base.clone(), Command::Undo).unwrap();
        let previous =
            edit_checkpoint::apply(base.compose(&source).unwrap(), &history.current().request)
                .unwrap()
                .0;
        assert_eq!(previous.tree.nodes[0].title, "第一章 编辑180");
        history.apply(&source, base.clone(), Command::Redo).unwrap();
        history.apply(&source, base.clone(), Command::Redo).unwrap();
        assert_eq!(serde_json::to_string(&history).unwrap(), saved);
        history
            .apply(
                &source,
                base.clone(),
                Command::Append {
                    action: Action::Rename {
                        entry_id: id,
                        title: "第一章 编辑241".into(),
                    },
                },
            )
            .unwrap();
        let final_book =
            edit_checkpoint::apply(base.compose(&source).unwrap(), &history.current().request)
                .unwrap()
                .0;
        assert_eq!(final_book.tree.nodes[0].title, "第一章 编辑241");
        let before_failure = serde_json::to_string(&history).unwrap();
        let invalid_directory = directory.join("not-a-directory");
        std::fs::write(&invalid_directory, b"keep").unwrap();
        assert!(
            history
                .apply(
                    &source,
                    base,
                    Command::Checkpoint {
                        directory: invalid_directory.to_string_lossy().into_owned()
                    }
                )
                .is_err()
        );
        assert_eq!(serde_json::to_string(&history).unwrap(), before_failure);
        assert_eq!(std::fs::read(invalid_directory).unwrap(), b"keep");
        assert_eq!(source.original_bytes(), original);
    }

    #[test]
    fn cumulative_action_limit_survives_history_truncation_and_reopen_without_partial_apply() {
        let (source, base, mut history, id) = setup();
        let original = source.original_bytes().to_vec();
        for index in 1..=100 {
            history
                .apply(
                    &source,
                    base.clone(),
                    Command::Append {
                        action: Action::Rename {
                            entry_id: id.clone(),
                            title: format!("第1章 修改{index}"),
                        },
                    },
                )
                .unwrap();
        }
        assert_eq!(history.history.len(), 51);
        assert_eq!(history.current().request.actions.len(), 100);
        let saved = serde_json::to_string(&history).unwrap();
        let mut reopened: History = serde_json::from_str(&saved).unwrap();
        reopened.validate(&source).unwrap();
        let before =
            edit_checkpoint::apply(base.compose(&source).unwrap(), &reopened.current().request)
                .unwrap()
                .0;
        assert_eq!(before.tree.nodes[0].title, "第1章 修改100");
        assert!(
            reopened
                .apply(
                    &source,
                    base.clone(),
                    Command::Append {
                        action: Action::Rename {
                            entry_id: id.clone(),
                            title: "第1章 第101次".into()
                        },
                    }
                )
                .is_err()
        );
        assert_eq!(serde_json::to_string(&reopened).unwrap(), saved);
        reopened
            .apply(&source, base.clone(), Command::Undo)
            .unwrap();
        let undone =
            edit_checkpoint::apply(base.compose(&source).unwrap(), &reopened.current().request)
                .unwrap()
                .0;
        assert_eq!(undone.tree.nodes[0].title, "第1章 修改99");
        reopened
            .apply(&source, base.clone(), Command::Redo)
            .unwrap();
        let redone =
            edit_checkpoint::apply(base.compose(&source).unwrap(), &reopened.current().request)
                .unwrap()
                .0;
        assert_eq!(redone.text, before.text);
        assert_eq!(
            serde_json::to_value(redone.tree).unwrap(),
            serde_json::to_value(before.tree).unwrap()
        );
        assert_eq!(redone.source_to_output_lines, before.source_to_output_lines);
        assert_eq!(source.original_bytes(), original);
    }

    #[test]
    fn snapshot_focus_follows_stable_id_across_pages() {
        let text = (1..=65)
            .map(|n| format!("第{n}章 标题\n正文{n}\n"))
            .collect::<String>();
        let source =
            SourceSnapshot::from_utf8(text.into_bytes(), easypub_core::source::RULE_ID, || false)
                .unwrap();
        let base = Base {
            structure: None,
            manual: None,
            cleanup: None,
            catalog: None,
        };
        let book = base.compose(&source).unwrap();
        assert_eq!(book.tree.nodes.len(), 65);
        let id = book.tree.nodes[0].entry_id.clone();
        let mut history = History {
            source_id: source.summary().source_id,
            revision: 1,
            cursor: 0,
            history: vec![Snapshot {
                rebased: false,
                recorded_request: None,
                base: base.clone(),
                request: Request {
                    checkpoint: None,
                    base_id: effective_edit::base_id(&book),
                    actions: vec![],
                },
            }],
        };
        history
            .apply(
                &source,
                base,
                Command::Append {
                    action: Action::Move {
                        entry_id: id.clone(),
                        before_id: None,
                    },
                },
            )
            .unwrap();
        let saved = serde_json::to_string(&history).unwrap();
        let before = history.inspect_snapshot(&source, 0, 30, Some(&id)).unwrap();
        let after = history.inspect_snapshot(&source, 1, 0, Some(&id)).unwrap();
        assert_eq!(before["offset"], 0);
        assert_eq!(after["offset"], 60);
        assert_eq!(after["focus_position"], 64);
        assert_eq!(
            before["nodes"][0]["entry_id"],
            after["nodes"][4]["entry_id"]
        );
        assert_eq!(before["focus_found"], true);
        assert_eq!(after["focus_found"], true);
        let missing = history
            .inspect_snapshot(&source, 1, 0, Some("missing"))
            .unwrap();
        assert_eq!(missing["focus_found"], false);
        assert_eq!(serde_json::to_string(&history).unwrap(), saved);
    }

    #[test]
    fn snapshot_page_is_read_only_and_rejects_invalid_history() {
        let (source, base, mut history, id) = setup();
        history
            .apply(
                &source,
                base,
                Command::Append {
                    action: Action::Rename {
                        entry_id: id,
                        title: "第一章 新标题".into(),
                    },
                },
            )
            .unwrap();
        let encoded = serde_json::to_string(&history).unwrap();
        let before = history.inspect_snapshot(&source, 0, 0, None).unwrap();
        let after = history.inspect_snapshot(&source, 1, 0, None).unwrap();
        assert_ne!(before["nodes"][0]["title"], after["nodes"][0]["title"]);
        assert_eq!(after["nodes"][0]["title"], "第一章 新标题");
        assert_eq!(
            history.inspect_snapshot(&source, 1, 30, None).unwrap()["nodes"],
            json!([])
        );
        assert!(history.inspect_snapshot(&source, 99, 0, None).is_err());
        assert_eq!(serde_json::to_string(&history).unwrap(), encoded);
        history.history[1].request.base_id = "0".repeat(64);
        assert!(history.inspect_snapshot(&source, 1, 0, None).is_err());
    }

    #[test]
    fn snapshot_page_replays_saved_catalog_recipe_without_write_confirmation() {
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n正文\n第二章 乙\n尾文\n".as_bytes().to_vec(),
            easypub_core::source::RULE_ID,
            || false,
        )
        .unwrap();
        let catalog = crate::catalog::parse_text(
            "第一卷 起\n第一章 甲\n第二卷 终\n第二章 乙",
            "样书",
            "",
            "paste",
            Some(2),
        )
        .unwrap();
        let base = Base {
            structure: None,
            manual: None,
            cleanup: None,
            catalog: Some(crate::catalog::CompositionRecipe {
                snapshot: catalog,
                choices: Value::Null,
                reorder: false,
            }),
        };
        let book = base.compose(&source).unwrap();
        let history = History {
            source_id: source.summary().source_id,
            revision: 1,
            cursor: 0,
            history: vec![Snapshot {
                rebased: false,
                recorded_request: None,
                base,
                request: Request {
                    checkpoint: None,
                    base_id: effective_edit::base_id(&book),
                    actions: vec![],
                },
            }],
        };
        let original = serde_json::to_string(&history).unwrap();
        let result = history.inspect_snapshot(&source, 0, 0, None).unwrap();
        assert_eq!(result["total"], 4);
        assert_eq!(result["nodes"][0]["title"], "第一卷 起");
        assert_eq!(result["writes_source"], false);
        assert_eq!(serde_json::to_string(&history).unwrap(), original);
    }

    #[test]
    fn catalog_append_preserves_edits_and_roundtrips_as_one_undo_step() {
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n正文  \n第二章 乙\n尾文  \n".as_bytes().to_vec(),
            easypub_core::source::RULE_ID,
            || false,
        )
        .unwrap();
        let base = Base {
            catalog: None,
            structure: None,
            manual: None,
            cleanup: Some(json!({"kind":"cleanup","pipeline":[{"kind":"trim_trailing_spaces"}]})),
        };
        let book = base.compose(&source).unwrap();
        let first_id = book.tree.nodes[0].entry_id.clone();
        let second_id = book.tree.nodes[1].entry_id.clone();
        let mut history = History {
            source_id: source.summary().source_id,
            revision: 1,
            cursor: 0,
            history: vec![Snapshot {
                rebased: false,
                recorded_request: None,
                base: base.clone(),
                request: Request {
                    checkpoint: None,
                    base_id: effective_edit::base_id(&book),
                    actions: vec![],
                },
            }],
        };
        history
            .apply(
                &source,
                base.clone(),
                Command::Append {
                    action: Action::Rename {
                        entry_id: second_id.clone(),
                        title: "第二章 新乙".into(),
                    },
                },
            )
            .unwrap();
        let catalog = crate::catalog::parse_text(
            "第一卷 起\n第一章 甲\n第二卷 终\n第二章 乙",
            "样书",
            "",
            "paste",
            Some(2),
        )
        .unwrap();
        let plan = crate::catalog::align(&source, &catalog, true).unwrap();
        assert_eq!(plan.edits.len(), 2);
        let selection = || crate::catalog::CompositionSelection {
            snapshot: catalog.clone(),
            choices: Value::Null,
            reorder: false,
            plan_id: plan.plan_id.clone(),
            confirmed: true,
        };
        let before = serde_json::to_string(&history).unwrap();
        let mut unconfirmed = selection();
        unconfirmed.confirmed = false;
        assert!(
            history
                .apply(
                    &source,
                    base.clone(),
                    Command::AppendCatalog {
                        catalog: unconfirmed
                    }
                )
                .is_err()
        );
        let mut stale = selection();
        stale.plan_id = "stale".into();
        assert!(
            history
                .apply(
                    &source,
                    base.clone(),
                    Command::AppendCatalog { catalog: stale }
                )
                .is_err()
        );
        assert_eq!(serde_json::to_string(&history).unwrap(), before);
        history
            .apply(
                &source,
                base.clone(),
                Command::AppendCatalog {
                    catalog: selection(),
                },
            )
            .unwrap();
        assert_eq!(history.cursor, 2);
        let result =
            edit_checkpoint::apply(base.compose(&source).unwrap(), &history.current().request)
                .unwrap()
                .0;
        assert_eq!(
            result.text,
            "第一卷 起\n第一章 甲\n正文\n第二卷 终\n第二章 新乙\n尾文\n"
        );
        assert_eq!(result.tree.nodes[1].entry_id, first_id);
        assert_eq!(result.tree.nodes[3].entry_id, second_id);
        let applied = serde_json::to_string(&history).unwrap();
        assert!(
            history
                .apply(
                    &source,
                    base.clone(),
                    Command::AppendCatalog {
                        catalog: selection()
                    }
                )
                .is_err()
        );
        assert_eq!(serde_json::to_string(&history).unwrap(), applied);
        let mut restored: History = serde_json::from_str(&applied).unwrap();
        restored.validate(&source).unwrap();
        restored
            .apply(&source, base.clone(), Command::Undo)
            .unwrap();
        assert_eq!(restored.current().request.actions.len(), 1);
        restored
            .apply(&source, base.clone(), Command::Redo)
            .unwrap();
        assert_eq!(serde_json::to_string(&restored).unwrap(), applied);
        restored
            .apply(&source, base.clone(), Command::Undo)
            .unwrap();
        restored
            .apply(
                &source,
                base.clone(),
                Command::Append {
                    action: Action::Move {
                        entry_id: second_id,
                        before_id: Some(first_id),
                    },
                },
            )
            .unwrap();
        let moved = serde_json::to_string(&restored).unwrap();
        assert!(
            restored
                .apply(
                    &source,
                    base,
                    Command::AppendCatalog {
                        catalog: selection()
                    }
                )
                .is_err()
        );
        assert_eq!(serde_json::to_string(&restored).unwrap(), moved);
    }

    #[test]
    fn batch_is_one_history_step_and_failed_tail_keeps_history_unchanged() {
        let (source, base, mut history, id) = setup();
        let rename = |title: &str| Action::Rename {
            entry_id: id.clone(),
            title: title.into(),
        };
        let before = serde_json::to_string(&history).unwrap();
        assert!(
            history
                .apply(
                    &source,
                    base.clone(),
                    Command::AppendBatch {
                        actions: vec![
                            rename("候选"),
                            Action::Rename {
                                entry_id: "missing".into(),
                                title: "无效".into()
                            }
                        ]
                    }
                )
                .is_err()
        );
        assert_eq!(serde_json::to_string(&history).unwrap(), before);
        assert!(
            history
                .apply(
                    &source,
                    base.clone(),
                    Command::AppendBatch { actions: vec![] }
                )
                .is_err()
        );
        history
            .apply(
                &source,
                base.clone(),
                Command::AppendBatch {
                    actions: vec![rename("中间"), rename("最终")],
                },
            )
            .unwrap();
        assert_eq!(history.cursor, 1);
        assert_eq!(history.history.len(), 2);
        assert_eq!(history.current().request.actions.len(), 2);
        history.apply(&source, base.clone(), Command::Undo).unwrap();
        assert!(history.current().request.actions.is_empty());
        history.apply(&source, base, Command::Redo).unwrap();
        assert_eq!(history.current().request.actions.len(), 2);
        history.validate(&source).unwrap();
    }

    #[test]
    fn stale_base_can_be_preserved_cleared_and_undone_without_retargeting() {
        let (source, base, mut history, id) = setup();
        history
            .apply(
                &source,
                base.clone(),
                Command::Append {
                    action: Action::Rename {
                        entry_id: id.clone(),
                        title: "新名".into(),
                    },
                },
            )
            .unwrap();
        let changed = Base {
            cleanup: None,
            ..base.clone()
        };
        assert!(
            !history
                .apply(&source, changed.clone(), Command::Inspect)
                .unwrap()
        );
        let before = serde_json::to_string(&history).unwrap();
        assert!(
            history
                .apply(
                    &source,
                    changed.clone(),
                    Command::Append {
                        action: Action::Rename {
                            entry_id: id,
                            title: "不能套用".into()
                        }
                    }
                )
                .is_err()
        );
        assert_eq!(serde_json::to_string(&history).unwrap(), before);
        assert!(
            history
                .apply(&source, changed.clone(), Command::Clear)
                .unwrap()
        );
        assert!(history.current().request.actions.is_empty());
        assert!(
            !history
                .apply(&source, changed.clone(), Command::Undo)
                .unwrap()
        );
        assert_eq!(history.current().request.actions.len(), 1);
        let mut reopened: History =
            serde_json::from_str(&serde_json::to_string(&history).unwrap()).unwrap();
        reopened.validate(&source).unwrap();
        assert!(reopened.apply(&source, changed, Command::Redo).unwrap());
        reopened
            .apply(&source, base.clone(), Command::Clear)
            .unwrap();
        reopened
            .apply(&source, base.clone(), Command::Undo)
            .unwrap();
        reopened.apply(&source, base, Command::Clear).unwrap();
        assert_eq!(reopened.cursor + 1, reopened.history.len());
        let mut bad = reopened.clone();
        bad.history[0].request.base_id = "0".repeat(64);
        assert!(bad.validate(&source).is_err());
        let foreign = SourceSnapshot::from_utf8(
            "001 别书\n正文\n".as_bytes().to_vec(),
            easypub_core::source::RULE_ID,
            || false,
        )
        .unwrap();
        assert!(history.validate(&foreign).is_err());
    }
}
