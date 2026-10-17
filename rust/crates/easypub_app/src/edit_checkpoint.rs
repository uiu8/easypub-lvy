//! Content-addressed effective-book checkpoints. History stores references,
//! never one copy of the complete manuscript per undo state.
use easypub_core::{
    ApiError, ErrorCode, effective_edit, publication::EffectiveBook, structure::Tree,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::Path,
    sync::atomic::{AtomicU64, Ordering},
};

const MAX_BYTES: u64 = 512 * 1024 * 1024;
static NEXT: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Reference {
    pub digest: String,
    pub source_id: String,
    pub base_id: String,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Payload {
    schema: u32,
    original_source_id: String,
    base_id: String,
    text: String,
    tree: Tree,
    source_to_output_lines: BTreeMap<u32, u32>,
    removed_structure_lines: Vec<u32>,
    text_changed: bool,
    cleanup_evidence: Option<Value>,
}
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "edit_checkpoint",
        "restore_edit_checkpoint",
    )
}
fn io(_: std::io::Error) -> ApiError {
    ApiError::new(
        ErrorCode::Io,
        "edit_checkpoint",
        "check_checkpoint_directory",
    )
}
fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn valid_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

impl Reference {
    pub fn validate(&self) -> Result<(), ApiError> {
        if !valid_hash(&self.digest) || !valid_hash(&self.source_id) || !valid_hash(&self.base_id) {
            return Err(invalid());
        }
        Ok(())
    }
}
fn validate_book(book: &EffectiveBook) -> Result<(), ApiError> {
    if !valid_hash(&book.original_source_id)
        || book.text.len() as u64 > MAX_BYTES
        || book.tree.source_bytes_covered != book.text.len()
        || book.tree.prefix_end > book.text.len()
        || !book.text.is_char_boundary(book.tree.prefix_end)
        || book.tree.nodes.len() > 30000
    {
        return Err(invalid());
    }
    let mut ids = BTreeSet::new();
    let mut end = book.tree.prefix_end;
    for node in &book.tree.nodes {
        if node.entry_id.is_empty()
            || node.start != end
            || node.body_start < node.start
            || node.body_start > node.end
            || node.end > book.text.len()
            || !book.text.is_char_boundary(node.start)
            || !book.text.is_char_boundary(node.body_start)
            || !book.text.is_char_boundary(node.end)
            || node.depth > 8
            || !ids.insert(node.entry_id.as_str())
        {
            return Err(invalid());
        }
        if node
            .parent_id
            .as_deref()
            .is_some_and(|id| id == node.entry_id || !ids.contains(id))
        {
            return Err(invalid());
        }
        end = node.end;
    }
    if end != book.text.len()
        || book
            .source_to_output_lines
            .iter()
            .any(|(a, b)| *a == 0 || *b == 0)
    {
        return Err(invalid());
    }
    Ok(())
}

/// Publishes only complete, synced content. Existing content is verified, never
/// overwritten; interruption before publication leaves no live reference.
pub fn save(directory: &Path, book: &EffectiveBook) -> Result<Reference, ApiError> {
    if !directory.is_absolute() {
        return Err(invalid());
    }
    validate_book(book)?;
    let base_id = effective_edit::base_id(book);
    #[derive(Serialize)]
    struct BorrowedPayload<'a> {
        schema: u32,
        original_source_id: &'a str,
        base_id: &'a str,
        text: &'a str,
        tree: &'a Tree,
        source_to_output_lines: &'a BTreeMap<u32, u32>,
        removed_structure_lines: &'a [u32],
        text_changed: bool,
        cleanup_evidence: &'a Option<Value>,
    }
    let payload = BorrowedPayload {
        schema: 1,
        original_source_id: &book.original_source_id,
        base_id: &base_id,
        text: &book.text,
        tree: &book.tree,
        source_to_output_lines: &book.source_to_output_lines,
        removed_structure_lines: &book.removed_structure_lines,
        text_changed: book.text_changed,
        cleanup_evidence: &book.cleanup_evidence,
    };
    let bytes = serde_json::to_vec(&payload).map_err(|_| invalid())?;
    if bytes.len() as u64 > MAX_BYTES {
        return Err(ApiError::new(
            ErrorCode::TooLarge,
            "edit_checkpoint",
            "reduce_checkpoint_size",
        ));
    }
    let reference = Reference {
        digest: digest(&bytes),
        source_id: book.original_source_id.clone(),
        base_id,
    };
    fs::create_dir_all(directory).map_err(io)?;
    let target = directory.join(format!("{}.json", reference.digest));
    if target.exists() {
        load(directory, &reference, &book.original_source_id)?;
        return Ok(reference);
    }
    let stage = directory.join(format!(
        ".checkpoint-{}-{}.tmp",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&stage)
        .map_err(io)?;
    let result = (|| {
        file.write_all(&bytes).map_err(io)?;
        file.sync_all().map_err(io)?;
        drop(file);
        match fs::hard_link(&stage, &target) {
            Ok(()) => (),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                load(directory, &reference, &book.original_source_id)?;
            }
            Err(e) => return Err(io(e)),
        }
        Ok(reference)
    })();
    let _ = fs::remove_file(stage);
    result
}

pub fn load(
    directory: &Path,
    reference: &Reference,
    expected_source: &str,
) -> Result<EffectiveBook, ApiError> {
    reference.validate()?;
    if !directory.is_absolute() || reference.source_id != expected_source {
        return Err(invalid());
    }
    let path = directory.join(format!("{}.json", reference.digest));
    let mut bytes = Vec::new();
    File::open(path)
        .map_err(io)?
        .take(MAX_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(io)?;
    if bytes.len() as u64 > MAX_BYTES || digest(&bytes) != reference.digest {
        return Err(invalid());
    }
    let payload: Payload = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
    if payload.schema != 1
        || payload.original_source_id != expected_source
        || payload.base_id != reference.base_id
    {
        return Err(invalid());
    }
    let book = EffectiveBook {
        original_source_id: payload.original_source_id,
        text: payload.text,
        tree: payload.tree,
        source_to_output_lines: payload.source_to_output_lines,
        removed_structure_lines: payload.removed_structure_lines,
        text_changed: payload.text_changed,
        cleanup_evidence: payload.cleanup_evidence,
    };
    validate_book(&book)?;
    if effective_edit::base_id(&book) != reference.base_id {
        return Err(invalid());
    }
    Ok(book)
}

/// A request keeps its original JSON fields; checkpoints are opt-in.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EditRequest {
    pub base_id: String,
    pub actions: Vec<effective_edit::Action>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checkpoint: Option<StoredCheckpoint>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct StoredCheckpoint {
    pub directory: std::path::PathBuf,
    pub origin_base_id: String,
    pub reference: Reference,
}

impl EditRequest {
    pub fn origin_base_id(&self) -> &str {
        self.checkpoint
            .as_ref()
            .map_or(&self.base_id, |c| &c.origin_base_id)
    }
    pub fn is_empty(&self) -> bool {
        self.actions.is_empty() && self.checkpoint.is_none()
    }
}

/// Used by previews, illustration positioning, resource preparation and output.
/// A changed cleanup/catalog/structure base must not silently use an old book.
pub fn apply(
    book: EffectiveBook,
    edits: &EditRequest,
) -> Result<(EffectiveBook, Vec<Value>), ApiError> {
    let (book, evidence, _) = apply_profiled(book, edits)?;
    Ok((book, evidence))
}

pub fn apply_profiled(
    book: EffectiveBook,
    edits: &EditRequest,
) -> Result<(EffectiveBook, Vec<Value>, usize), ApiError> {
    let book = if let Some(stored) = &edits.checkpoint {
        if stored.origin_base_id != effective_edit::base_id(&book)
            || edits.base_id != stored.reference.base_id
        {
            return Err(invalid());
        }
        load(
            &stored.directory,
            &stored.reference,
            &book.original_source_id,
        )?
    } else {
        book
    };
    if edits.actions.is_empty() && edits.checkpoint.is_some() {
        return Ok((book, Vec::new(), 0));
    }
    effective_edit::apply_profiled(
        book,
        &effective_edit::Request {
            base_id: edits.base_id.clone(),
            actions: edits.actions.clone(),
        },
    )
}

#[cfg(test)]
mod scale_tests {
    use super::*;
    use easypub_core::{
        effective_edit::{Action, Request},
        publication,
        source::{RULE_ID, SourceSnapshot},
        structure::Structure,
    };

    #[test]
    #[ignore = "8 MiB production replay boundary; run explicitly in release"]
    fn eight_mib_replay_budget_and_checkpoint_restore() {
        let started = std::time::Instant::now();
        let text = format!("第一章 开始\n{}\n", "甲".repeat(8 * 1024 * 1024 / 3));
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let compose = || publication::compose(&source, &Structure::new(&source), None).unwrap();
        let initial = compose();
        let id = initial.tree.nodes[0].entry_id.clone();
        let mut request = Request {
            base_id: effective_edit::base_id(&initial),
            actions: vec![
                Action::Rename {
                    entry_id: id.clone(),
                    title: "第一章 修改".into()
                };
                63
            ],
        };
        let (book, _, work) = effective_edit::apply_profiled(initial, &request).unwrap();
        assert_eq!(work, text.len() * 63);
        assert!(work + book.text.len() > effective_edit::MAX_REPLAY_BYTES);
        request.actions.push(Action::Rename {
            entry_id: id.clone(),
            title: "第一章 超限".into(),
        });
        assert_eq!(
            effective_edit::apply(compose(), &request)
                .err()
                .unwrap()
                .code,
            ErrorCode::TooLarge
        );
        let root = std::env::temp_dir().join(format!(
            "easypub-scale66-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let reference = save(&root, &book).unwrap();
        let edits = EditRequest {
            base_id: reference.base_id.clone(),
            actions: vec![],
            checkpoint: Some(StoredCheckpoint {
                directory: root,
                origin_base_id: request.base_id.clone(),
                reference,
            }),
        };
        let (restored, _, reset) = apply_profiled(compose(), &edits).unwrap();
        assert_eq!(reset, 0);
        assert_eq!(restored.text, book.text);
        assert_eq!(restored.source_to_output_lines, book.source_to_output_lines);
        let mut next = edits;
        next.actions.push(Action::Rename {
            entry_id: id,
            title: "第一章 继续".into(),
        });
        let (continued, _, next_work) = apply_profiled(compose(), &next).unwrap();
        assert_eq!(next_work, book.text.len());
        assert!(continued.text.starts_with("第一章 继续\n"));
        assert_eq!(source.decoded_text(), text);
        println!(
            "scale66 bytes={} actions=63 blocked=64 reset={} elapsed_ms={}",
            text.len(),
            reset,
            started.elapsed().as_millis()
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use easypub_core::{
        effective_edit::{Action, Request},
        publication,
        source::{RULE_ID, SourceSnapshot},
        structure::Structure,
    };
    fn fixture() -> (std::path::PathBuf, EffectiveBook) {
        let dir = std::env::temp_dir().join(format!(
            "easypub-checkpoint-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let source = SourceSnapshot::from_utf8(
            "第一章 开始\n正文甲\n第二章 后续\n正文乙\n"
                .as_bytes()
                .to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let book = publication::compose_with_cleanup(&source, &Structure::new(&source), None, None)
            .unwrap();
        (dir, book)
    }
    #[test]
    fn shared_request_restores_same_book_in_structure_resources_positions_and_output() {
        use serde_json::json;
        use std::sync::Arc;
        let (dir, initial) = fixture();
        let original_base = effective_edit::base_id(&initial);
        let source = Arc::new(
            SourceSnapshot::from_utf8(
                "第一章 开始\n正文甲\n第二章 后续\n正文乙\n"
                    .as_bytes()
                    .to_vec(),
                RULE_ID,
                || false,
            )
            .unwrap(),
        );
        let source_id = source.summary().source_id;
        let id = initial.tree.nodes[0].entry_id.clone();
        let prior = Request {
            base_id: original_base.clone(),
            actions: vec![Action::Rename {
                entry_id: id.clone(),
                title: "检查点标题".into(),
            }],
        };
        let checkpoint_book = effective_edit::apply(initial, &prior).unwrap().0;
        let reference = save(&dir, &checkpoint_book).unwrap();
        let edits = EditRequest {
            base_id: reference.base_id.clone(),
            actions: vec![Action::Rename {
                entry_id: id.clone(),
                title: "继续编辑标题".into(),
            }],
            checkpoint: Some(StoredCheckpoint {
                directory: dir,
                origin_base_id: original_base,
                reference,
            }),
        };
        let json_edits = serde_json::to_value(&edits).unwrap();
        let expected = "继续编辑标题\n正文甲\n第二章 后续\n正文乙\n";
        let service = crate::sessions::ImportService::new().unwrap();
        service
            .replace_sources(BTreeMap::from([(source_id.clone(), source.clone())]))
            .unwrap();
        let preview = service
            .effective_structure_text(
                source_id.clone(),
                1,
                String::new(),
                json!({"kind":"publication","post_edits":json_edits}).to_string(),
                0,
            )
            .unwrap();
        assert!(preview.contains("继续编辑标题"));
        let positions = crate::production::illustration_positions(
            &service,
            source_id.clone(),
            1,
            json!({"source_lines":[2,4],"post_edits":json_edits}).to_string(),
        )
        .unwrap();
        assert!(positions.contains("继续编辑标题"));
        let resources:crate::publication_resources::Request=serde_json::from_value(json!({"source_id":source_id,"revision":1,
            "settings":{"title":"测试书","author":"","description":"","cover_path":null,"cover_fit":"contain","font_family":"Microsoft YaHei","font_size":18.0,"line_height":1.8,"include_toc":true,"illustrations":[]},
            "post_edits":json_edits})).unwrap();
        assert_eq!(
            crate::publication_resources::prepare(&source, resources)
                .unwrap()
                .book()
                .text,
            expected
        );
        let plan = crate::publication_output::try_prepare(
            &source,
            &json!({"kind":"publication","post_edits":json_edits}).to_string(),
        )
        .unwrap()
        .unwrap();
        assert_eq!(plan.output(&source).unwrap(), expected.as_bytes());
        assert!(plan.preview().contains("继续编辑标题"));
        let base = publication::compose_with_cleanup(&source, &Structure::new(&source), None, None)
            .unwrap();
        let changed = effective_edit::apply(
            base,
            &Request {
                base_id: prior.base_id.clone(),
                actions: vec![Action::Rename {
                    entry_id: id,
                    title: "基础已改".into(),
                }],
            },
        )
        .unwrap()
        .0;
        assert!(apply(changed, &edits).is_err());
        let empty = EditRequest {
            actions: vec![],
            ..edits
        };
        let base = publication::compose_with_cleanup(&source, &Structure::new(&source), None, None)
            .unwrap();
        assert_eq!(apply(base, &empty).unwrap().0.text, checkpoint_book.text);
        let legacy: EditRequest =
            serde_json::from_value(serde_json::to_value(&prior).unwrap()).unwrap();
        let mut legacy_json = serde_json::to_value(&prior).unwrap();
        legacy_json["checkpoint"] = serde_json::Value::Null;
        let classic_output = crate::publication_output::try_prepare(
            &source,
            &json!({"kind":"publication","post_edits":legacy_json}).to_string(),
        )
        .unwrap()
        .unwrap();
        assert_eq!(
            classic_output.output(&source).unwrap(),
            checkpoint_book.text.as_bytes()
        );
        assert!(legacy.checkpoint.is_none());
        let base = publication::compose_with_cleanup(&source, &Structure::new(&source), None, None)
            .unwrap();
        assert_eq!(apply(base, &legacy).unwrap().0.text, checkpoint_book.text);
    }

    #[test]
    fn checkpoints_preserve_ids_text_and_original_line_mapping_across_250_edits() {
        let (dir, mut book) = fixture();
        let source_id = book.original_source_id.clone();
        let id = book.tree.nodes[0].entry_id.clone();
        let mapping = book.source_to_output_lines.clone();
        let mut references = Vec::new();
        for round in 0..5 {
            let request = Request {
                base_id: effective_edit::base_id(&book),
                actions: (1..=50)
                    .map(|i| Action::Rename {
                        entry_id: id.clone(),
                        title: format!("第一章 编辑{}", round * 50 + i),
                    })
                    .collect(),
            };
            book = effective_edit::apply(book, &request).unwrap().0;
            let reference = save(&dir, &book).unwrap();
            assert_eq!(save(&dir, &book).unwrap(), reference);
            let restored = load(&dir, &reference, &source_id).unwrap();
            assert_eq!(restored.text, book.text);
            assert_eq!(
                serde_json::to_value(&restored.tree).unwrap(),
                serde_json::to_value(&book.tree).unwrap()
            );
            assert_eq!(restored.source_to_output_lines, mapping);
            references.push(reference);
            book = restored;
        }
        assert_eq!(book.tree.nodes[0].title, "第一章 编辑250");
        assert_eq!(
            load(&dir, &references[0], &source_id).unwrap().tree.nodes[0].title,
            "第一章 编辑50"
        );
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 5);
    }
    #[test]
    fn moved_and_merged_checkpoints_keep_illustration_positions_and_removed_headings() {
        let (dir, book) = fixture();
        let source_id = book.original_source_id.clone();
        let a = book.tree.nodes[0].entry_id.clone();
        let b = book.tree.nodes[1].entry_id.clone();
        let edits = Request {
            base_id: effective_edit::base_id(&book),
            actions: vec![
                Action::Move {
                    entry_id: b.clone(),
                    before_id: Some(a.clone()),
                },
                Action::Rename {
                    entry_id: b.clone(),
                    title: "无编号后续".into(),
                },
                Action::MergePrevious { entry_id: a },
            ],
        };
        let edited = effective_edit::apply(book, &edits).unwrap().0;
        let reference = save(&dir, &edited).unwrap();
        let restored = load(&dir, &reference, &source_id).unwrap();
        assert_eq!(restored.text, "无编号后续\n正文乙\n正文甲\n");
        assert_eq!(restored.tree.nodes[0].entry_id, b);
        assert_eq!(
            restored.removed_structure_lines,
            edited.removed_structure_lines
        );
        for line in 1..=4 {
            assert_eq!(
                restored
                    .illustration_position(&source_id, Some(line))
                    .unwrap(),
                edited
                    .illustration_position(&source_id, Some(line))
                    .unwrap()
            );
        }
        let next = Request {
            base_id: effective_edit::base_id(&restored),
            actions: vec![Action::Rename {
                entry_id: b,
                title: "新的标题".into(),
            }],
        };
        let continued = effective_edit::apply(restored, &next).unwrap().0;
        assert!(continued.text.starts_with("新的标题\n"));
        assert_eq!(
            continued.source_to_output_lines,
            edited.source_to_output_lines
        );
    }

    #[test]
    fn foreign_missing_and_corrupted_checkpoints_fail_without_replacing_valid_content() {
        let (dir, book) = fixture();
        let reference = save(&dir, &book).unwrap();
        assert!(load(&dir, &reference, &"0".repeat(64)).is_err());
        let mut wrong = reference.clone();
        wrong.digest = "../outside".into();
        assert!(load(&dir, &wrong, &book.original_source_id).is_err());
        wrong.digest = "0".repeat(64);
        assert!(load(&dir, &wrong, &book.original_source_id).is_err());
        let path = dir.join(format!("{}.json", reference.digest));
        fs::write(&path, b"broken").unwrap();
        assert!(load(&dir, &reference, &book.original_source_id).is_err());
        assert!(save(&dir, &book).is_err());
        assert_eq!(fs::read(path).unwrap(), b"broken");
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 1);
    }
}
