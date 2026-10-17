//! Ordered edits of the composed book, addressed by stable node identity.
use crate::{
    ApiError, ErrorCode, manual_edit,
    publication::{EffectiveBook, compose_projection},
    source::{RULE_ID, SourceSnapshot},
    structure::{Override, Role, Structure},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub base_id: String,
    pub actions: Vec<Action>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ChapterBoundary {
    pub entry_id: Option<String>,
    pub line_offset: u32,
    pub depth: u8,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Action {
    Recognize {
        // 装箱：规则含多段文本（V17 又加了三项例外），避免撑大每个操作。
        rules: Box<crate::chapter_rules::RuleSet>,
        #[serde(default = "default_preserve_decisions")]
        preserve_decisions: bool,
    },
    CreateChapterBoundaries {
        boundaries: Vec<ChapterBoundary>,
    },
    ReorderSource {
        order: Vec<(u32, u8)>,
    },
    ExcludeDuplicateChapter {
        entry_id: String,
        kept_id: String,
    },
    InsertSourceVolume {
        source_line: u32,
        title: String,
    },
    RestoreHeading {
        entry_id: Option<String>,
        line_offset: u32,
        title: String,
        depth: u8,
    },
    ExcludeBodyLines {
        entry_id: Option<String>,
        first_offset: u32,
        last_offset: u32,
    },
    Reorder {
        order: Vec<(String, u8)>,
    },
    RemoveDuplicateHeading {
        entry_id: String,
    },
    MergeInto {
        entry_id: String,
        target_id: String,
    },
    MergeSubtreePrevious {
        entry_id: String,
    },
    MoveSubtree {
        entry_id: String,
        before_id: Option<String>,
    },
    MoveIntoVolume {
        entry_id: String,
        volume_id: String,
        at_start: bool,
    },
    InsertVolume {
        entry_id: String,
        title: String,
    },
    CreateBoundary {
        entry_id: Option<String>,
        line_offset: u32,
        role: Role,
        depth: u8,
        include_toc: bool,
    },
    Split {
        entry_id: String,
        line_offset: u32,
        title: String,
    },
    Classify {
        entry_id: String,
        role: Role,
        depth: u8,
        include_toc: bool,
    },
    Rename {
        entry_id: String,
        title: String,
    },
    Move {
        entry_id: String,
        before_id: Option<String>,
    },
    MergePrevious {
        entry_id: String,
    },
}
fn default_preserve_decisions() -> bool {
    true
}
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "effective_edit",
        "review_effective_nodes_and_base",
    )
}
pub fn base_id(book: &EffectiveBook) -> String {
    let mut hash = Sha256::new();
    hash.update(b"effective-edit-v1");
    hash.update(book.original_source_id.as_bytes());
    hash.update(book.text.as_bytes());
    hash.update(serde_json::to_vec(&book.tree).expect("tree"));
    hash.update(serde_json::to_vec(&book.source_to_output_lines).expect("source map"));
    format!("{:x}", hash.finalize())
}

/// Owns its candidate: any failed later action discards the entire result.
pub const MAX_REPLAY_BYTES: usize = 512 * 1024 * 1024;

pub fn apply(
    book: EffectiveBook,
    request: &Request,
) -> Result<(EffectiveBook, Vec<Value>), ApiError> {
    let (book, evidence, _) = apply_profiled(book, request)?;
    Ok((book, evidence))
}

/// Count the exact same bytes used by the existing replay guard; no extra scan.
pub fn apply_profiled(
    mut book: EffectiveBook,
    request: &Request,
) -> Result<(EffectiveBook, Vec<Value>, usize), ApiError> {
    if request.actions.is_empty()
        || request.actions.len() > 100
        || serde_json::to_vec(request).map_err(|_| invalid())?.len() > 1024 * 1024
        || request.base_id != base_id(&book)
    {
        return Err(invalid());
    }
    let mut evidence = Vec::new();
    let mut work_bytes = 0usize;
    for action_index in 0..request.actions.len() {
        book = apply_step(book, request, action_index, &mut work_bytes, &mut evidence)?;
    }
    Ok((book, evidence, work_bytes))
}

/// Applies `request.actions[action_index]` with the identity context of the
/// whole request, so a caller can replay one action at a time and still get
/// exactly the node ids a single full replay would assign.
fn apply_step(
    mut book: EffectiveBook,
    request: &Request,
    action_index: usize,
    work_bytes: &mut usize,
    evidence: &mut Vec<Value>,
) -> Result<EffectiveBook, ApiError> {
    let action = &request.actions[action_index];
    {
        if let Action::Recognize {
            rules,
            preserve_decisions,
        } = action
        {
            *work_bytes = work_bytes.saturating_add(book.text.len());
            if *work_bytes > MAX_REPLAY_BYTES {
                return Err(invalid());
            }
            let (next, summary) = crate::chapter_rules::rebuild(book, rules, *preserve_decisions)?;
            evidence.push(summary);
            return Ok(next);
        }
        if let Action::ReorderSource { order } = action {
            let resolved = order
                .iter()
                .map(|(source_line, depth)| {
                    let line = book
                        .source_to_output_lines
                        .get(source_line)
                        .ok_or_else(invalid)?;
                    let node = book
                        .tree
                        .nodes
                        .iter()
                        .find(|n| n.source_line == *line)
                        .ok_or_else(invalid)?;
                    Ok((node.entry_id.clone(), *depth))
                })
                .collect::<Result<Vec<_>, ApiError>>()?;
            let nested = Request {
                base_id: base_id(&book),
                actions: vec![Action::Reorder { order: resolved }],
            };
            let (next, stages, bytes) = apply_profiled(book, &nested)?;
            *work_bytes = work_bytes.saturating_add(bytes);
            if *work_bytes > MAX_REPLAY_BYTES {
                return Err(ApiError::new(
                    ErrorCode::TooLarge,
                    "effective_edit",
                    "reduce_edit_batch",
                ));
            }
            evidence.extend(stages);
            return Ok(next);
        }
        if let Action::InsertSourceVolume { source_line, title } = action {
            let line = book
                .source_to_output_lines
                .get(source_line)
                .ok_or_else(invalid)?;
            let node = book
                .tree
                .nodes
                .iter()
                .find(|n| n.source_line == *line)
                .ok_or_else(invalid)?;
            let nested = Request {
                base_id: base_id(&book),
                actions: vec![Action::InsertVolume {
                    entry_id: node.entry_id.clone(),
                    title: title.clone(),
                }],
            };
            let (next, stages, bytes) = apply_profiled(book, &nested)?;
            *work_bytes = work_bytes.saturating_add(bytes);
            if *work_bytes > MAX_REPLAY_BYTES {
                return Err(ApiError::new(
                    ErrorCode::TooLarge,
                    "effective_edit",
                    "reduce_edit_batch",
                ));
            }
            evidence.extend(stages);
            return Ok(next);
        }
        if let Action::RestoreHeading {
            entry_id,
            line_offset,
            title,
            depth,
        } = action
        {
            let heading_line = entry_id
                .as_ref()
                .and_then(|id| book.tree.nodes.iter().find(|n| &n.entry_id == id))
                .map(|n| n.source_line)
                .unwrap_or(0)
                + line_offset;
            let create = Request {
                base_id: base_id(&book),
                actions: vec![Action::CreateBoundary {
                    entry_id: entry_id.clone(),
                    line_offset: *line_offset,
                    role: Role::Chapter,
                    depth: *depth,
                    include_toc: true,
                }],
            };
            let (created, mut stages, bytes) = apply_profiled(book, &create)?;
            let id = created
                .tree
                .nodes
                .iter()
                .find(|n| n.source_line == heading_line)
                .ok_or_else(invalid)?
                .entry_id
                .clone();
            let rename = Request {
                base_id: base_id(&created),
                actions: vec![Action::Rename {
                    entry_id: id,
                    title: title.clone(),
                }],
            };
            let (renamed, more, rename_bytes) = apply_profiled(created, &rename)?;
            *work_bytes = work_bytes
                .saturating_add(bytes)
                .saturating_add(rename_bytes);
            if *work_bytes > MAX_REPLAY_BYTES {
                return Err(ApiError::new(
                    ErrorCode::TooLarge,
                    "effective_edit",
                    "reduce_edit_batch",
                ));
            }
            stages.extend(more);
            evidence.extend(stages);
            return Ok(renamed);
        }
        *work_bytes = work_bytes.saturating_add(book.text.len());
        if *work_bytes > MAX_REPLAY_BYTES {
            return Err(ApiError::new(
                ErrorCode::TooLarge,
                "effective_edit",
                "reduce_edit_batch",
            ));
        }
        let entry_id = match action {
            Action::Reorder { .. } | Action::CreateChapterBoundaries { .. } => None,
            Action::RestoreHeading { .. }
            | Action::Recognize { .. }
            | Action::InsertSourceVolume { .. }
            | Action::ReorderSource { .. } => unreachable!("handled above"),
            Action::CreateBoundary { entry_id, .. } | Action::ExcludeBodyLines { entry_id, .. } => {
                entry_id.as_deref()
            }
            Action::MergeInto { entry_id, .. }
            | Action::ExcludeDuplicateChapter { entry_id, .. }
            | Action::RemoveDuplicateHeading { entry_id }
            | Action::MergeSubtreePrevious { entry_id }
            | Action::MoveSubtree { entry_id, .. }
            | Action::MoveIntoVolume { entry_id, .. }
            | Action::InsertVolume { entry_id, .. }
            | Action::Split { entry_id, .. }
            | Action::Classify { entry_id, .. }
            | Action::Rename { entry_id, .. }
            | Action::Move { entry_id, .. }
            | Action::MergePrevious { entry_id } => Some(entry_id.as_str()),
        };
        let prefix = crate::structure::Node {
            entry_id: String::new(),
            parent_id: None,
            source_line: 0,
            title: String::new(),
            role: Role::Front,
            depth: 0,
            include_toc: false,
            start: 0,
            body_start: 0,
            end: book.tree.prefix_end,
        };
        let node = match entry_id {
            Some(id) => book
                .tree
                .nodes
                .iter()
                .find(|n| n.entry_id == id)
                .ok_or_else(invalid)?,
            None => &prefix,
        };
        let source = SourceSnapshot::from_utf8(book.text.as_bytes().to_vec(), RULE_ID, || false)?;
        let mut structure = Structure::new(&source);
        structure.overrides = book
            .tree
            .nodes
            .iter()
            .map(|n| Override {
                source_line: n.source_line,
                role: n.role.clone(),
                depth: n.depth,
                include_toc: n.include_toc,
            })
            .collect();
        let known = book
            .tree
            .nodes
            .iter()
            .map(|n| n.source_line)
            .collect::<BTreeSet<_>>();
        for n in Structure::new(&source).tree(&source)?.nodes {
            if !known.contains(&n.source_line) {
                structure.overrides.push(Override {
                    source_line: n.source_line,
                    role: Role::Body,
                    depth: 0,
                    include_toc: false,
                });
            }
        }
        let (mut next, stage) = if let Action::CreateChapterBoundaries { boundaries } = action {
            if boundaries.is_empty() || boundaries.len() > 1000 {
                return Err(invalid());
            }
            let mut added = BTreeSet::new();
            let mut changes = Vec::new();
            for boundary in boundaries {
                let parent = match &boundary.entry_id {
                    Some(id) => book
                        .tree
                        .nodes
                        .iter()
                        .find(|n| &n.entry_id == id)
                        .ok_or_else(invalid)?,
                    None => &prefix,
                };
                let line = parent
                    .source_line
                    .checked_add(boundary.line_offset)
                    .ok_or_else(invalid)?;
                let &(start, end) = source
                    .decoded_line_ranges()
                    .get(line.checked_sub(1).ok_or_else(invalid)? as usize)
                    .ok_or_else(invalid)?;
                if boundary.line_offset == 0
                    || start < parent.body_start
                    || start >= parent.end
                    || known.contains(&line)
                    || !added.insert(line)
                {
                    return Err(invalid());
                }
                structure.put(
                    &source,
                    Override {
                        source_line: line,
                        role: Role::Chapter,
                        depth: boundary.depth,
                        include_toc: true,
                    },
                )?;
                let title = &source.decoded_text()[start..end];
                changes.push(json!({"kind":"create_boundary","source_line":line,"before":title,"after":title,
                    "before_structure":{"role":"body"},"after_structure":{"role":"chapter","depth":boundary.depth,"include_toc":true}}));
            }
            (
                crate::publication::compose(&source, &structure, None)?,
                json!({"changes":changes}),
            )
        } else if let Action::Reorder { order } = action {
            crate::effective_move::reorder(&book, &source, order)?
        } else if let Action::RemoveDuplicateHeading { entry_id } = action {
            let target = crate::effective_repair::target(&book, entry_id)?;
            let (next, mut evidence) =
                crate::effective_merge::prepare_into(&book, &source, entry_id, &target.entry_id)?;
            evidence["changes"][0]["kind"] = json!("remove_duplicate_heading");
            evidence["changes"][0]["after"] = json!("");
            (next, evidence)
        } else if let Action::MergeInto {
            entry_id,
            target_id,
        } = action
        {
            crate::effective_merge::prepare_into(&book, &source, entry_id, target_id)?
        } else if let Action::MergeSubtreePrevious { entry_id } = action {
            crate::effective_merge::prepare(&book, &source, entry_id)?
        } else if let Action::MoveSubtree {
            entry_id,
            before_id,
        } = action
        {
            crate::effective_move::prepare(&book, &source, entry_id, before_id.as_deref())?
        } else if let Action::MoveIntoVolume {
            entry_id,
            volume_id,
            at_start,
        } = action
        {
            crate::effective_move::prepare_in_volume(
                &book, &source, entry_id, volume_id, *at_start,
            )?
        } else if let Action::CreateBoundary {
            line_offset,
            role,
            depth,
            include_toc,
            ..
        } = action
        {
            let line = node
                .source_line
                .checked_add(*line_offset)
                .ok_or_else(invalid)?;
            let &(start, end) = source
                .decoded_line_ranges()
                .get(line.checked_sub(1).ok_or_else(invalid)? as usize)
                .ok_or_else(invalid)?;
            if *line_offset == 0
                || *role == Role::Body
                || start < node.body_start
                || start >= node.end
            {
                return Err(invalid());
            }
            structure.put(
                &source,
                Override {
                    source_line: line,
                    role: role.clone(),
                    depth: *depth,
                    include_toc: *include_toc,
                },
            )?;
            let next = crate::publication::compose(&source, &structure, None)?;
            let title = &source.decoded_text()[start..end];
            let stage = json!({"changes":[{"kind":"create_boundary","source_line":line,"before":title,"after":title,
                "before_structure":{"role":"body"},"after_structure":{"role":role,"depth":depth,"include_toc":include_toc}}]});
            (next, stage)
        } else if let Action::Classify {
            role,
            depth,
            include_toc,
            ..
        } = action
        {
            structure.put(
                &source,
                Override {
                    source_line: node.source_line,
                    role: role.clone(),
                    depth: *depth,
                    include_toc: *include_toc,
                },
            )?;
            let next = crate::publication::compose(&source, &structure, None)?;
            let stage = json!({"changes":[{"kind":"classify","source_line":node.source_line,
                "before":format!("{} · {:?} · {} 层 · 目录 {}",node.title,node.role,node.depth,node.include_toc),
                "after":format!("{} · {:?} · {} 层 · 目录 {}",node.title,role,depth,include_toc),
                "before_structure":{"role":node.role,"depth":node.depth,"include_toc":node.include_toc},
                "after_structure":{"role":role,"depth":depth,"include_toc":include_toc}}]});
            (next, stage)
        } else {
            let selected = match action {
                Action::RestoreHeading { .. }
                | Action::Recognize { .. }
                | Action::InsertSourceVolume { .. }
                | Action::ReorderSource { .. } => unreachable!(),
                Action::ExcludeDuplicateChapter { kept_id, .. } => {
                    let kept = book
                        .tree
                        .nodes
                        .iter()
                        .find(|n| &n.entry_id == kept_id)
                        .ok_or_else(invalid)?;
                    if kept.entry_id == node.entry_id
                        || kept.role != Role::Chapter
                        || node.role != Role::Chapter
                        || book.text[node.body_start..node.end].trim().is_empty()
                        || book.text[kept.start..kept.end] != book.text[node.start..node.end]
                    {
                        return Err(invalid());
                    }
                    let last = source
                        .decoded_line_ranges()
                        .partition_point(|(start, _)| *start < node.end)
                        as u32;
                    json!({"kind":"exclude_lines","source_line":node.source_line,"end_line":last})
                }
                Action::MergeInto { .. }
                | Action::RemoveDuplicateHeading { .. }
                | Action::MergeSubtreePrevious { .. }
                | Action::Classify { .. }
                | Action::CreateBoundary { .. }
                | Action::CreateChapterBoundaries { .. }
                | Action::MoveSubtree { .. }
                | Action::MoveIntoVolume { .. }
                | Action::Reorder { .. } => unreachable!(),
                Action::ExcludeBodyLines {
                    first_offset,
                    last_offset,
                    ..
                } => {
                    if *first_offset == 0 || first_offset > last_offset {
                        return Err(invalid());
                    }
                    let first = node
                        .source_line
                        .checked_add(*first_offset)
                        .ok_or_else(invalid)?;
                    let last = node
                        .source_line
                        .checked_add(*last_offset)
                        .ok_or_else(invalid)?;
                    let ranges = source.decoded_line_ranges();
                    let &(start, _) = ranges.get((first - 1) as usize).ok_or_else(invalid)?;
                    let &(last_start, _) = ranges.get((last - 1) as usize).ok_or_else(invalid)?;
                    let stop = ranges
                        .get(last as usize)
                        .map(|v| v.0)
                        .unwrap_or(book.text.len());
                    // Bounds refer to this exact effective node, including prefix.
                    // A chapter/volume heading or a following child must never be
                    // consumed by a body-range command.
                    if start < node.body_start || last_start >= node.end || stop > node.end {
                        return Err(invalid());
                    }
                    json!({"kind":"exclude_lines","source_line":first,"end_line":last})
                }
                Action::InsertVolume { title, .. } => {
                    if node.role != Role::Chapter {
                        return Err(invalid());
                    }
                    json!({"kind":"set_volume","source_line":node.source_line,"volume_title":title})
                }
                Action::Split {
                    line_offset, title, ..
                } => {
                    let line = node
                        .source_line
                        .checked_add(*line_offset)
                        .ok_or_else(invalid)?;
                    let &(start, _) = source
                        .decoded_line_ranges()
                        .get(line.checked_sub(1).ok_or_else(invalid)? as usize)
                        .ok_or_else(invalid)?;
                    if node.role != Role::Chapter
                        || *line_offset == 0
                        || start < node.body_start
                        || start >= node.end
                    {
                        return Err(invalid());
                    }
                    json!({"kind":"split_chapter","source_line":line,"title":title})
                }
                Action::Rename { title, .. } => {
                    json!({"kind":"rename_title","source_line":node.source_line,"title":title})
                }
                Action::Move { before_id, .. } => {
                    let before_line = if let Some(id) = before_id {
                        book.tree
                            .nodes
                            .iter()
                            .find(|n| &n.entry_id == id)
                            .ok_or_else(invalid)?
                            .source_line
                    } else {
                        source.summary().line_count + 1
                    };
                    json!({"kind":if node.role == Role::Volume {"move_volume"} else {"move_chapter"},
                    "source_line":node.source_line,"before_line":before_line})
                }
                Action::MergePrevious { .. } => {
                    json!({"kind":"merge_previous","source_line":node.source_line})
                }
            };
            let plan = manual_edit::prepare_with_structure(
                &source,
                &json!({"kind":"manual_batch","actions":[selected]}).to_string(),
                Some(&structure),
            )?;
            let projection = plan.projection(&source)?;
            let next = if matches!(action, Action::InsertVolume { .. }) {
                crate::publication::compose_projection_at_volume_depth(
                    &source,
                    &structure,
                    projection,
                    node.depth.saturating_sub(1),
                )?
            } else {
                compose_projection(&source, &structure, projection)?
            };
            (
                next,
                serde_json::from_slice::<Value>(&plan.evidence(&source)).map_err(|_| invalid())?,
            )
        };
        if matches!(action, Action::InsertVolume { .. }) && node.depth == 0 {
            // A previously ungrouped chapter and its following peers become children
            // of the new volume; preserve each subtree's relative depth.
            let first = *next
                .source_to_output_lines
                .get(&node.source_line)
                .ok_or_else(invalid)?;
            let effective =
                SourceSnapshot::from_utf8(next.text.as_bytes().to_vec(), RULE_ID, || false)?;
            let mut settings = Structure::new(&effective);
            let mut inside = false;
            for n in &next.tree.nodes {
                if n.source_line == first {
                    inside = true;
                }
                if inside && n.role == Role::Volume {
                    inside = false;
                }
                settings.overrides.push(Override {
                    source_line: n.source_line,
                    role: n.role.clone(),
                    depth: if inside {
                        n.depth.checked_add(1).ok_or_else(invalid)?
                    } else {
                        n.depth
                    },
                    include_toc: n.include_toc,
                });
            }
            let kept = next
                .tree
                .nodes
                .iter()
                .map(|n| n.source_line)
                .collect::<BTreeSet<_>>();
            for n in Structure::new(&effective).tree(&effective)?.nodes {
                if !kept.contains(&n.source_line) {
                    settings.overrides.push(Override {
                        source_line: n.source_line,
                        role: Role::Body,
                        depth: 0,
                        include_toc: false,
                    });
                }
            }
            next.tree = settings.tree(&effective)?;
        }
        next.tree.recognition_rules = book.tree.recognition_rules.clone();
        next.tree.recognition_decisions = book.tree.recognition_decisions.clone();
        if matches!(action, Action::Classify { .. } | Action::Rename { .. })
            && book.tree.recognition_rules.is_some()
            && let Some((&original, _)) = book
                .source_to_output_lines
                .iter()
                .find(|(_, line)| **line == node.source_line)
            {
                next.tree.recognition_decisions.insert(
                    original,
                    !matches!(
                        action,
                        Action::Classify {
                            role: Role::Body,
                            ..
                        }
                    ),
                );
            }
        let mut stable_lines = book
            .tree
            .nodes
            .iter()
            .filter_map(|n| {
                next.source_to_output_lines
                    .get(&n.source_line)
                    .map(|line| (*line, n.entry_id.clone()))
            })
            .collect::<BTreeMap<_, _>>();
        if matches!(
            action,
            Action::Split { .. }
                | Action::CreateBoundary { .. }
                | Action::CreateChapterBoundaries { .. }
                | Action::InsertVolume { .. }
        ) {
            let added = next
                .tree
                .nodes
                .iter()
                .filter(|n| !stable_lines.contains_key(&n.source_line))
                .collect::<Vec<_>>();
            let expected = match action {
                Action::CreateChapterBoundaries { boundaries } => boundaries.len(),
                _ => 1,
            };
            if added.len() != expected {
                return Err(invalid());
            }
            let mut hash = Sha256::new();
            hash.update(b"effective-insert-v1");
            hash.update(request.base_id.as_bytes());
            hash.update(
                serde_json::to_vec(&request.actions[..=action_index]).map_err(|_| invalid())?,
            );
            for n in added {
                let mut item_hash = hash.clone();
                if matches!(action, Action::CreateChapterBoundaries { .. }) {
                    item_hash.update(n.source_line.to_le_bytes());
                }
                stable_lines.insert(
                    n.source_line,
                    format!("inserted:{:x}", item_hash.finalize()),
                );
            }
        }
        let stable_ids = next
            .tree
            .nodes
            .iter()
            .map(|n| {
                Ok((
                    n.entry_id.clone(),
                    stable_lines
                        .get(&n.source_line)
                        .ok_or_else(invalid)?
                        .clone(),
                ))
            })
            .collect::<Result<BTreeMap<_, _>, ApiError>>()?;
        for n in &mut next.tree.nodes {
            n.entry_id = stable_ids.get(&n.entry_id).ok_or_else(invalid)?.clone();
            n.parent_id = n
                .parent_id
                .as_ref()
                .map(|id| stable_ids.get(id).cloned().ok_or_else(invalid))
                .transpose()?;
        }
        let mut removed = book.removed_structure_lines.clone();
        for (&original, &current) in &book.source_to_output_lines {
            if next.removed_structure_lines.contains(&current) {
                removed.push(original);
            }
        }
        removed.sort_unstable();
        removed.dedup();
        next.removed_structure_lines = removed;
        next.source_to_output_lines = book
            .source_to_output_lines
            .iter()
            .filter_map(|(&original, &current)| {
                next.source_to_output_lines
                    .get(&current)
                    .map(|&line| (original, line))
            })
            .collect();
        next.original_source_id = book.original_source_id.clone();
        next.text_changed |= book.text_changed;
        next.cleanup_evidence = book.cleanup_evidence.take();
        evidence.push(
            json!({"action":action,"coordinate_system":"effective_book_before_this_action",
            "stage":stage}),
        );
        Ok(next)
    }
}

/// Chapter edits moved from one composed base onto another (for example after
/// the cleanup underneath them changed).
pub struct Rebased {
    pub book: EffectiveBook,
    /// `None` when no action survived.
    pub request: Option<Request>,
    /// Indexes of the original actions that were kept, in order.
    pub kept: Vec<usize>,
    /// `{index, action, reason}` for every action that could not be moved.
    pub skipped: Vec<Value>,
    /// Replay work of the kept actions, as `apply_profiled` counts it.
    pub work_bytes: usize,
}

fn original_lines(book: &EffectiveBook) -> BTreeMap<u32, u32> {
    book.source_to_output_lines
        .iter()
        .map(|(&original, &current)| (current, original))
        .collect()
}

/// Ids are stable across cleanup except for nodes the edits themselves insert;
/// line offsets go through the original source line. An action whose line no
/// longer exists is reported, never moved to a nearby line.
fn translate(
    action: &Action,
    ids: &BTreeMap<String, String>,
    old: &EffectiveBook,
    new: &EffectiveBook,
) -> Option<Action> {
    let inverse = original_lines(old);
    let id = |value: &String| ids.get(value).cloned().unwrap_or_else(|| value.clone());
    let anchor = |book: &EffectiveBook, value: &str| {
        book.tree
            .nodes
            .iter()
            .find(|n| n.entry_id == value)
            .map(|n| n.source_line)
    };
    let line = |entry: &Option<String>, offset: u32| -> Option<u32> {
        let (old_anchor, new_anchor) = match entry {
            Some(e) => (anchor(old, e)?, anchor(new, &id(e))?),
            None => (0, 0),
        };
        let original = inverse.get(&old_anchor.checked_add(offset)?)?;
        new.source_to_output_lines
            .get(original)?
            .checked_sub(new_anchor)
    };
    let mut next = action.clone();
    match &mut next {
        Action::Recognize { .. }
        | Action::ReorderSource { .. }
        | Action::InsertSourceVolume { .. } => {}
        Action::CreateChapterBoundaries { boundaries } => {
            for b in boundaries {
                b.line_offset = line(&b.entry_id, b.line_offset)?;
                b.entry_id = b.entry_id.as_ref().map(id);
            }
        }
        Action::RestoreHeading {
            entry_id,
            line_offset,
            ..
        }
        | Action::CreateBoundary {
            entry_id,
            line_offset,
            ..
        } => {
            *line_offset = line(entry_id, *line_offset)?;
            *entry_id = entry_id.as_ref().map(id);
        }
        Action::ExcludeBodyLines {
            entry_id,
            first_offset,
            last_offset,
        } => {
            *first_offset = line(entry_id, *first_offset)?;
            *last_offset = line(entry_id, *last_offset)?;
            *entry_id = entry_id.as_ref().map(id);
        }
        Action::Split {
            entry_id,
            line_offset,
            ..
        } => {
            *line_offset = line(&Some(entry_id.clone()), *line_offset)?;
            *entry_id = id(entry_id);
        }
        Action::Reorder { order } => {
            for (entry, _) in order {
                *entry = id(entry);
            }
        }
        Action::ExcludeDuplicateChapter {
            entry_id,
            kept_id: other,
        }
        | Action::MergeInto {
            entry_id,
            target_id: other,
        }
        | Action::MoveIntoVolume {
            entry_id,
            volume_id: other,
            ..
        } => {
            *entry_id = id(entry_id);
            *other = id(other);
        }
        Action::MoveSubtree {
            entry_id,
            before_id,
        }
        | Action::Move {
            entry_id,
            before_id,
        } => {
            *entry_id = id(entry_id);
            *before_id = before_id.as_ref().map(id);
        }
        Action::RemoveDuplicateHeading { entry_id }
        | Action::MergeSubtreePrevious { entry_id }
        | Action::InsertVolume { entry_id, .. }
        | Action::Classify { entry_id, .. }
        | Action::Rename { entry_id, .. }
        | Action::MergePrevious { entry_id } => *entry_id = id(entry_id),
    }
    Some(next)
}

/// Pairs the nodes one action inserted in the old and the new replay: first by
/// original source line, then, only when the remaining counts agree, by order.
fn pair_inserted(
    old_before: &BTreeSet<String>,
    old_after: &EffectiveBook,
    new_before: &BTreeSet<String>,
    new_after: &EffectiveBook,
    ids: &mut BTreeMap<String, String>,
) -> bool {
    let added = |before: &BTreeSet<String>, book: &EffectiveBook| {
        let inverse = original_lines(book);
        book.tree
            .nodes
            .iter()
            .filter(|n| !before.contains(&n.entry_id))
            .map(|n| (n.entry_id.clone(), inverse.get(&n.source_line).copied()))
            .collect::<Vec<_>>()
    };
    let old_added = added(old_before, old_after);
    let mut new_added = added(new_before, new_after);
    let mut rest = Vec::new();
    for (old_id, original) in old_added {
        let found = original.and_then(|o| new_added.iter().position(|(_, n)| *n == Some(o)));
        match found {
            Some(at) => {
                let (new_id, _) = new_added.remove(at);
                ids.insert(old_id, new_id);
            }
            None => rest.push(old_id),
        }
    }
    if rest.len() != new_added.len() {
        return false;
    }
    for (old_id, (new_id, _)) in rest.into_iter().zip(new_added) {
        ids.insert(old_id, new_id);
    }
    true
}

/// Replays `request`, made against `old_base`, on `new_base` one action at a
/// time. Kept actions are replayed with the identity context of the final
/// request, so `apply(new_base, rebased.request)` yields exactly `rebased.book`.
pub fn rebase(
    old_base: EffectiveBook,
    new_base: EffectiveBook,
    request: &Request,
) -> Result<Rebased, ApiError> {
    if request.actions.is_empty()
        || request.actions.len() > 100
        || request.base_id != base_id(&old_base)
    {
        return Err(invalid());
    }
    let new_base_id = base_id(&new_base);
    let (mut old, mut new) = (old_base, new_base);
    let (mut old_bytes, mut new_bytes) = (0usize, 0usize);
    let mut kept: Vec<Action> = Vec::new();
    let mut kept_index = Vec::new();
    let mut skipped = Vec::new();
    let mut ids = BTreeMap::new();
    let mut sink = Vec::new();
    let node_ids = |book: &EffectiveBook| {
        book.tree
            .nodes
            .iter()
            .map(|n| n.entry_id.clone())
            .collect::<BTreeSet<_>>()
    };
    for (index, action) in request.actions.iter().enumerate() {
        let translated = translate(action, &ids, &old, &new);
        let old_before = node_ids(&old);
        let next_old = apply_step(old, request, index, &mut old_bytes, &mut sink)?;
        sink.clear();
        let reason = match translated {
            None => "line_changed",
            Some(candidate) => {
                kept.push(candidate);
                let attempt = Request {
                    base_id: new_base_id.clone(),
                    actions: kept.clone(),
                };
                let mut bytes = new_bytes;
                let result =
                    apply_step(new.clone(), &attempt, kept.len() - 1, &mut bytes, &mut sink);
                sink.clear();
                match result {
                    Ok(next_new) => {
                        let new_before = node_ids(&new);
                        if pair_inserted(&old_before, &next_old, &new_before, &next_new, &mut ids) {
                            new_bytes = bytes;
                            new = next_new;
                            kept_index.push(index);
                            old = next_old;
                            continue;
                        }
                        kept.pop();
                        "ids_diverged"
                    }
                    Err(_) => {
                        kept.pop();
                        "apply_failed"
                    }
                }
            }
        };
        skipped.push(json!({"index": index, "action": action, "reason": reason}));
        old = next_old;
    }
    Ok(Rebased {
        book: new,
        request: (!kept.is_empty()).then_some(Request {
            base_id: new_base_id,
            actions: kept,
        }),
        kept: kept_index,
        skipped,
        work_bytes: new_bytes,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::publication::{IllustrationPosition, compose_with_cleanup, prepare_output};
    const CLEANUP: &str = r#"{"kind":"cleanup","pipeline":[{"kind":"chapter_numbers","style":"chinese","bare_titles":true}]}"#;
    fn source() -> SourceSnapshot {
        SourceSnapshot::from_utf8(
            "001 起\n甲文\n002 续\n乙文\n003 终\n丙文\n"
                .as_bytes()
                .to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap()
    }
    fn book(source: &SourceSnapshot) -> EffectiveBook {
        compose_with_cleanup(source, &Structure::new(source), None, Some(CLEANUP)).unwrap()
    }
    #[test]
    fn exclude_effective_body_after_cleanup_and_move_preserves_ids_and_anchor_meaning() {
        let source = source();
        let original = book(&source);
        let ids = original
            .tree
            .nodes
            .iter()
            .map(|n| n.entry_id.clone())
            .collect::<Vec<_>>();
        let request = Request {
            base_id: base_id(&original),
            actions: vec![
                Action::MoveSubtree {
                    entry_id: ids[1].clone(),
                    before_id: Some(ids[0].clone()),
                },
                Action::ExcludeBodyLines {
                    entry_id: Some(ids[1].clone()),
                    first_offset: 1,
                    last_offset: 1,
                },
            ],
        };
        let (result, evidence) = apply(original, &request).unwrap();
        assert_eq!(result.text, "第二章 续\n第一章 起\n甲文\n第三章 终\n丙文\n");
        assert_eq!(
            result
                .tree
                .nodes
                .iter()
                .map(|n| n.entry_id.clone())
                .collect::<Vec<_>>(),
            vec![ids[1].clone(), ids[0].clone(), ids[2].clone()]
        );
        assert!(!result.source_to_output_lines.contains_key(&4));
        assert_eq!(result.source_to_output_lines.get(&2), Some(&3));
        assert!(matches!(
            result
                .illustration_position(&result.original_source_id, Some(4))
                .unwrap(),
            IllustrationPosition::NeedsRelocation { source_line: 4 }
        ));
        assert!(matches!(
            result
                .illustration_position(&result.original_source_id, Some(2))
                .unwrap(),
            IllustrationPosition::AfterLine {
                source_line: 2,
                output_line: 3
            }
        ));
        assert!(evidence[1].to_string().contains("乙文"));
        assert_eq!(
            book(&source).text,
            "第一章 起\n甲文\n第二章 续\n乙文\n第三章 终\n丙文\n"
        );
        for (first, last) in [(0, 1), (2, 1), (1, 2), (1, u32::MAX)] {
            let initial = book(&source);
            assert!(
                apply(
                    initial,
                    &Request {
                        base_id: request.base_id.clone(),
                        actions: vec![Action::ExcludeBodyLines {
                            entry_id: Some(ids[0].clone()),
                            first_offset: first,
                            last_offset: last,
                        }]
                    }
                )
                .is_err()
            );
        }
    }

    #[test]
    fn exclude_prefix_blank_ranges_and_all_body_without_changing_heading_structure() {
        let source = SourceSnapshot::from_utf8(
            "卷前甲\r\n\r\n卷前乙\r\n第一章 起\r\n正文甲\r\n\r\n正文乙"
                .as_bytes()
                .to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let initial = crate::publication::compose(&source, &Structure::new(&source), None).unwrap();
        let id = initial.tree.nodes[0].entry_id.clone();
        let base = base_id(&initial);
        let (result, _) = apply(
            initial,
            &Request {
                base_id: base.clone(),
                actions: vec![
                    Action::ExcludeBodyLines {
                        entry_id: None,
                        first_offset: 1,
                        last_offset: 3,
                    },
                    Action::ExcludeBodyLines {
                        entry_id: Some(id.clone()),
                        first_offset: 1,
                        last_offset: 3,
                    },
                ],
            },
        )
        .unwrap();
        assert_eq!(result.text, "第一章 起\r\n");
        assert_eq!(result.tree.nodes.len(), 1);
        assert_eq!(result.tree.nodes[0].entry_id, id);
        assert_eq!(result.source_to_output_lines.len(), 1);
        assert_eq!(result.source_to_output_lines.get(&4), Some(&1));
        let plain =
            SourceSnapshot::from_utf8("甲\n乙".as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let initial = crate::publication::compose(&plain, &Structure::new(&plain), None).unwrap();
        let request = Request {
            base_id: base_id(&initial),
            actions: vec![Action::ExcludeBodyLines {
                entry_id: None,
                first_offset: 1,
                last_offset: 2,
            }],
        };
        let (empty, _) = apply(initial, &request).unwrap();
        assert!(empty.text.is_empty());
        assert!(empty.tree.nodes.is_empty());
        assert!(empty.source_to_output_lines.is_empty());
    }

    #[test]
    fn replay_profile_counts_each_actual_intermediate_text_length() {
        let source = source();
        let initial = book(&source);
        let first_bytes = initial.text.len();
        let mut request = Request {
            base_id: base_id(&initial),
            actions: vec![Action::Rename {
                entry_id: initial.tree.nodes[0].entry_id.clone(),
                title: "第一章 加长后的标题".into(),
            }],
        };
        let (first, _) = apply(initial, &request).unwrap();
        let second_bytes = first.text.len();
        request.actions.push(Action::Rename {
            entry_id: first.tree.nodes[0].entry_id.clone(),
            title: "短标题".into(),
        });
        let (result, evidence, bytes) = apply_profiled(book(&source), &request).unwrap();
        let (ordinary, expected) = apply(book(&source), &request).unwrap();
        assert_eq!(bytes, first_bytes + second_bytes);
        assert_eq!(result.text, ordinary.text);
        assert_eq!(evidence, expected);
        assert_eq!(
            result.source_to_output_lines,
            ordinary.source_to_output_lines
        );
    }

    #[test]
    fn cleanup_nodes_keep_ids_and_illustrations_after_ordered_edits() {
        let source = source();
        let initial = book(&source);
        assert_eq!(initial.tree.nodes.len(), 3);
        let ids = initial
            .tree
            .nodes
            .iter()
            .map(|n| n.entry_id.clone())
            .collect::<Vec<_>>();
        let request = Request {
            base_id: base_id(&initial),
            actions: vec![
                Action::Move {
                    entry_id: ids[1].clone(),
                    before_id: Some(ids[0].clone()),
                },
                Action::Rename {
                    entry_id: ids[1].clone(),
                    title: "无编号续章".into(),
                },
                Action::MergePrevious {
                    entry_id: ids[0].clone(),
                },
            ],
        };
        let (result, evidence) = apply(initial, &request).unwrap();
        assert_eq!(result.text, "无编号续章\n乙文\n甲文\n第三章 终\n丙文\n");
        assert_eq!(result.tree.nodes.len(), 2);
        assert_eq!(result.tree.nodes[0].entry_id, ids[1]);
        assert_eq!(result.tree.nodes[1].entry_id, ids[2]);
        assert_eq!(result.tree.nodes[0].role, Role::Chapter);
        assert_eq!(result.tree.source_bytes_covered, result.text.len());
        assert_eq!(
            result
                .illustration_position(&source.summary().source_id, Some(4))
                .unwrap(),
            IllustrationPosition::AfterLine {
                source_line: 4,
                output_line: 2
            }
        );
        assert_eq!(
            result
                .illustration_position(&source.summary().source_id, Some(1))
                .unwrap(),
            IllustrationPosition::NeedsRelocation { source_line: 1 }
        );
        assert_eq!(result.removed_structure_lines, vec![1]);
        assert!(result.cleanup_evidence.is_some());
        assert_eq!(evidence.len(), 3);
        let selected=json!({"kind":"publication","cleanup":serde_json::from_str::<Value>(CLEANUP).unwrap(),"post_edits":request}).to_string();
        let plan = prepare_output(&source, &selected).unwrap();
        assert_eq!(
            String::from_utf8(plan.output(&source).unwrap()).unwrap(),
            result.text
        );
        let audit: Value = serde_json::from_slice(&plan.evidence()).unwrap();
        assert_eq!(audit["post_edits"].as_array().unwrap().len(), 3);
        let preview: Value = serde_json::from_str(&plan.preview()).unwrap();
        assert_eq!(preview["editing_base_id"], request.base_id);
        assert!(
            preview["actions"]
                .as_array()
                .unwrap()
                .iter()
                .any(|c| c["stage"] == "post_cleanup_edit")
        );
        assert_eq!(
            source.decoded_text(),
            "001 起\n甲文\n002 续\n乙文\n003 终\n丙文\n"
        );
    }
    #[test]
    fn classify_preserves_text_identity_mapping_and_validates_following_actions() {
        let source = source();
        let initial = book(&source);
        let ids = initial
            .tree
            .nodes
            .iter()
            .map(|n| n.entry_id.clone())
            .collect::<Vec<_>>();
        let mut request = Request {
            base_id: base_id(&initial),
            actions: vec![
                Action::Classify {
                    entry_id: ids[0].clone(),
                    role: Role::Volume,
                    depth: 0,
                    include_toc: false,
                },
                Action::Classify {
                    entry_id: ids[1].clone(),
                    role: Role::Section,
                    depth: 1,
                    include_toc: true,
                },
            ],
        };
        let (classified, _) = apply(initial, &request).unwrap();
        assert_eq!(classified.text, book(&source).text);
        assert_eq!(
            classified.source_to_output_lines,
            book(&source).source_to_output_lines
        );
        assert_eq!(classified.tree.nodes[0].entry_id, ids[0]);
        assert!(!classified.tree.nodes[0].include_toc);
        assert_eq!(classified.tree.nodes[1].parent_id.as_ref(), Some(&ids[0]));
        assert_eq!(classified.tree.nodes[1].role, Role::Section);
        request.actions.push(Action::Rename {
            entry_id: ids[1].clone(),
            title: "无编号节".into(),
        });
        request.actions.push(Action::Classify {
            entry_id: ids[2].clone(),
            role: Role::Body,
            depth: 0,
            include_toc: false,
        });
        let (final_book, evidence) = apply(book(&source), &request).unwrap();
        assert_eq!(final_book.tree.nodes.len(), 2);
        assert_eq!(final_book.tree.nodes[1].entry_id, ids[1]);
        assert_eq!(
            final_book.text,
            "第一章 起\n甲文\n无编号节\n乙文\n第三章 终\n丙文\n"
        );
        assert_eq!(final_book.tree.source_bytes_covered, final_book.text.len());
        assert_eq!(final_book.source_to_output_lines.get(&5), Some(&5));
        assert_eq!(evidence.len(), 4);
        request.actions.push(Action::Rename {
            entry_id: ids[2].clone(),
            title: "不得错改".into(),
        });
        assert!(apply(book(&source), &request).is_err());
        request.actions = vec![Action::Classify {
            entry_id: ids[0].clone(),
            role: Role::Section,
            depth: 2,
            include_toc: true,
        }];
        assert!(apply(book(&source), &request).is_err());
        request.actions = vec![Action::Classify {
            entry_id: ids[0].clone(),
            role: Role::Body,
            depth: 0,
            include_toc: true,
        }];
        assert!(apply(book(&source), &request).is_err());
    }

    #[test]
    fn split_creates_replayable_identity_and_preserves_body_through_move() {
        let source = SourceSnapshot::from_utf8(
            "第一章 起\n甲文\n乙文\n第二章 续\n丙文\n"
                .as_bytes()
                .to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let make = || crate::publication::compose(&source, &Structure::new(&source), None).unwrap();
        let first = make().tree.nodes[0].entry_id.clone();
        let mut request = Request {
            base_id: base_id(&make()),
            actions: vec![Action::Split {
                entry_id: first.clone(),
                line_offset: 2,
                title: "第三章 新章".into(),
            }],
        };
        let (split, _) = apply(make(), &request).unwrap();
        let added = split.tree.nodes[1].entry_id.clone();
        assert!(added.starts_with("inserted:"));
        assert_eq!(
            apply(make(), &request).unwrap().0.tree.nodes[1].entry_id,
            added
        );
        request.actions.push(Action::Rename {
            entry_id: added.clone(),
            title: "新建的无编号章".into(),
        });
        request.actions.push(Action::Move {
            entry_id: added.clone(),
            before_id: Some(first.clone()),
        });
        let (moved, _) = apply(make(), &request).unwrap();
        assert_eq!(
            moved.text,
            "新建的无编号章\n乙文\n第一章 起\n甲文\n第二章 续\n丙文\n"
        );
        assert_eq!(moved.tree.nodes[0].entry_id, added);
        assert_eq!(moved.source_to_output_lines.get(&3), Some(&2));
        assert_eq!(moved.tree.source_bytes_covered, moved.text.len());
        for offset in [0, 3, 99] {
            request.actions = vec![Action::Split {
                entry_id: first.clone(),
                line_offset: offset,
                title: "第三章 新章".into(),
            }];
            assert!(apply(make(), &request).is_err());
        }
    }

    #[test]
    fn body_preview_bounds_mixed_endings_long_lines_and_chapter_ownership() {
        let long = "😀".repeat(4510);
        let text = format!(
            "第一章 起\r\n{}\r{}\n第二章 续\r尾文",
            long,
            (0..31)
                .map(|i| format!("正文{i}"))
                .collect::<Vec<_>>()
                .join("\r\n")
        );
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let book = crate::publication::compose(&source, &Structure::new(&source), None).unwrap();
        let id = &book.tree.nodes[0].entry_id;
        let first = book.body_preview(id, 0).unwrap();
        assert_eq!(first["total"], 32);
        assert_eq!(first["rows"].as_array().unwrap().len(), 30);
        assert_eq!(
            first["rows"][0]["text"].as_str().unwrap().chars().count(),
            500
        );
        assert_eq!(first["rows"][0]["truncated"], true);
        let mut complete = first["rows"][0]["text"].as_str().unwrap().to_owned();
        let mut cursor = first["rows"][0]["next_char_offset"].as_u64();
        while let Some(chars) = cursor {
            let continuation = book.body_line_chunk(id, 0, chars as usize).unwrap();
            assert_eq!(continuation["rows"].as_array().unwrap().len(), 1);
            let row = &continuation["rows"][0];
            assert_eq!(row["line_offset"], 1);
            assert!(row["text"].as_str().unwrap().chars().count() <= 2000);
            complete.push_str(row["text"].as_str().unwrap());
            cursor = row["next_char_offset"].as_u64();
        }
        assert_eq!(complete, long);
        assert_eq!(first["rows"][0]["source_line"], 2);
        assert_eq!(first["rows"][0]["original_source_line"], 2);
        assert_eq!(first["has_more"], true);
        let last = book.body_preview(id, 30).unwrap();
        assert_eq!(last["rows"].as_array().unwrap().len(), 2);
        assert_eq!(last["rows"][1]["text"], "正文30");
        assert_eq!(last["rows"][1]["line_offset"], 32);
        assert_eq!(last["has_more"], false);
        assert_eq!(
            book.body_preview(id, usize::MAX).unwrap()["rows"],
            json!([])
        );
        assert!(book.body_preview("foreign", 0).is_err());
        assert_eq!(
            book.body_preview(&book.tree.nodes[1].entry_id, 0).unwrap()["rows"][0]["text"],
            "尾文"
        );
    }

    #[test]
    fn create_prefix_volume_then_chapter_preserves_text_and_replay_identity() {
        let source = SourceSnapshot::from_utf8(
            "卷首\r\n说明\n篇题\r正文".as_bytes().to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let make = || crate::publication::compose(&source, &Structure::new(&source), None).unwrap();
        assert!(make().tree.nodes.is_empty());
        assert_eq!(make().body_preview("$prefix", 0).unwrap()["total"], 4);
        let mut request = Request {
            base_id: base_id(&make()),
            actions: vec![Action::CreateBoundary {
                entry_id: None,
                line_offset: 1,
                role: Role::Volume,
                depth: 0,
                include_toc: true,
            }],
        };
        let (volume, _) = apply(make(), &request).unwrap();
        let volume_id = volume.tree.nodes[0].entry_id.clone();
        assert_eq!(volume.text, source.decoded_text());
        request.actions.push(Action::CreateBoundary {
            entry_id: Some(volume_id.clone()),
            line_offset: 2,
            role: Role::Chapter,
            depth: 1,
            include_toc: true,
        });
        let (chapter, _) = apply(make(), &request).unwrap();
        let chapter_id = chapter.tree.nodes[1].entry_id.clone();
        assert_eq!(chapter.tree.nodes[1].parent_id.as_ref(), Some(&volume_id));
        assert_eq!(chapter.text, source.decoded_text());
        assert_eq!(
            chapter.source_to_output_lines,
            make().source_to_output_lines
        );
        assert_eq!(
            apply(make(), &request).unwrap().0.tree.nodes[1].entry_id,
            chapter_id
        );
        request.actions.push(Action::Rename {
            entry_id: chapter_id,
            title: "新章名".into(),
        });
        assert_eq!(
            apply(make(), &request).unwrap().0.text,
            "卷首\r\n说明\n新章名\r正文"
        );
        request.actions = vec![Action::CreateBoundary {
            entry_id: None,
            line_offset: 1,
            role: Role::Body,
            depth: 0,
            include_toc: false,
        }];
        assert!(apply(make(), &request).is_err());
    }

    #[test]
    fn creation_cannot_cross_prefix_or_node_boundaries() {
        let source = SourceSnapshot::from_utf8(
            "未分组文字\n书前正文\n第一卷 起\n卷首题\n卷首文\n第一章 甲\n甲文"
                .as_bytes()
                .to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let make = || crate::publication::compose(&source, &Structure::new(&source), None).unwrap();
        let id = make().tree.nodes[0].entry_id.clone();
        for (entry_id, line_offset) in [
            (None, 0),
            (None, 3),
            (Some(id.clone()), 0),
            (Some(id.clone()), 3),
            (Some("foreign".into()), 1),
        ] {
            let request = Request {
                base_id: base_id(&make()),
                actions: vec![Action::CreateBoundary {
                    entry_id,
                    line_offset,
                    role: Role::Front,
                    depth: 0,
                    include_toc: true,
                }],
            };
            assert!(apply(make(), &request).is_err());
        }
        let request = Request {
            base_id: base_id(&make()),
            actions: vec![Action::CreateBoundary {
                entry_id: Some(id.clone()),
                line_offset: 1,
                role: Role::Front,
                depth: 1,
                include_toc: true,
            }],
        };
        let (created, _) = apply(make(), &request).unwrap();
        assert_eq!(created.tree.nodes[1].title, "卷首题");
        assert_eq!(created.tree.nodes[1].parent_id, Some(id));
        assert_eq!(created.text, source.decoded_text());
    }

    #[test]
    fn inserted_volumes_reparent_chapters_and_move_with_exact_bodies() {
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n甲文\n第二章 乙\n乙文\n第三章 丙\n丙文\n"
                .as_bytes()
                .to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let make = || crate::publication::compose(&source, &Structure::new(&source), None).unwrap();
        let ids = make()
            .tree
            .nodes
            .iter()
            .map(|n| n.entry_id.clone())
            .collect::<Vec<_>>();
        let mut req = Request {
            base_id: base_id(&make()),
            actions: vec![Action::InsertVolume {
                entry_id: ids[0].clone(),
                title: "起程".into(),
            }],
        };
        let (first, _) = apply(make(), &req).unwrap();
        let first_volume = first.tree.nodes[0].entry_id.clone();
        assert_eq!(first.tree.nodes[1].parent_id.as_ref(), Some(&first_volume));
        assert_eq!(first.tree.nodes[3].depth, 1);
        req.actions.push(Action::InsertVolume {
            entry_id: ids[2].clone(),
            title: "归来".into(),
        });
        let (second, _) = apply(make(), &req).unwrap();
        let second_volume = second.tree.nodes[3].entry_id.clone();
        assert_eq!(
            second.tree.nodes[4].parent_id.as_ref(),
            Some(&second_volume)
        );
        req.actions.push(Action::Move {
            entry_id: second_volume.clone(),
            before_id: Some(first_volume.clone()),
        });
        let (moved, _) = apply(make(), &req).unwrap();
        assert_eq!(
            moved.text,
            "归来\n第三章 丙\n丙文\n起程\n第一章 甲\n甲文\n第二章 乙\n乙文\n"
        );
        assert_eq!(moved.tree.nodes[0].entry_id, second_volume);
        assert_eq!(moved.tree.nodes[1].entry_id, ids[2]);
        assert_eq!(
            moved.tree.nodes[1].parent_id.as_ref(),
            Some(&moved.tree.nodes[0].entry_id)
        );
        assert_eq!(moved.source_to_output_lines.get(&6), Some(&3));
        assert_eq!(moved.tree.source_bytes_covered, moved.text.len());
    }

    #[test]
    fn deep_volume_insertion_preserves_ancestors_peers_and_maximum_depth() {
        for depth in 2u8..=8 {
            let mut raw = String::new();
            for level in 0..depth {
                raw.push_str(&format!("层级{level}\n层级正文{level}\n"));
            }
            raw.push_str("第一章 甲\n甲文\n第二章 乙\n乙文\n结束\n尾文");
            let source =
                SourceSnapshot::from_utf8(raw.as_bytes().to_vec(), RULE_ID, || false).unwrap();
            let mut structure = Structure::new(&source);
            for level in 0..depth {
                structure.overrides.push(Override {
                    source_line: u32::from(level) * 2 + 1,
                    role: Role::Volume,
                    depth: level,
                    include_toc: true,
                });
            }
            for line in [u32::from(depth) * 2 + 1, u32::from(depth) * 2 + 3] {
                structure.overrides.push(Override {
                    source_line: line,
                    role: Role::Chapter,
                    depth,
                    include_toc: false,
                });
            }
            structure.overrides.push(Override {
                source_line: u32::from(depth) * 2 + 5,
                role: Role::Volume,
                depth: 0,
                include_toc: true,
            });
            let make = || crate::publication::compose(&source, &structure, None).unwrap();
            let original = make();
            let chapter = original.tree.nodes[depth as usize].entry_id.clone();
            let previous_parent = original.tree.nodes[depth as usize - 1].entry_id.clone();
            let grandparent = original.tree.nodes[depth as usize - 2].entry_id.clone();
            let mut req = Request {
                base_id: base_id(&original),
                actions: vec![Action::InsertVolume {
                    entry_id: chapter.clone(),
                    title: "新增卷".into(),
                }],
            };
            let (inserted, _) = apply(make(), &req).unwrap();
            let volume = &inserted.tree.nodes[depth as usize];
            let volume_id = volume.entry_id.clone();
            assert_eq!(volume.depth, depth - 1);
            assert_eq!(volume.parent_id.as_ref(), Some(&grandparent));
            for n in &inserted.tree.nodes[depth as usize + 1..depth as usize + 3] {
                assert_eq!(n.parent_id.as_ref(), Some(&volume_id));
                assert_eq!(n.depth, depth);
                assert!(!n.include_toc);
            }
            assert_eq!(inserted.text, raw.replace("第一章 甲", "新增卷\n第一章 甲"));
            assert_eq!(inserted.tree.nodes.last().unwrap().depth, 0);
            req.actions.push(Action::MoveSubtree {
                entry_id: volume_id.clone(),
                before_id: Some(previous_parent.clone()),
            });
            let (moved, _) = apply(make(), &req).unwrap();
            let mut expected = String::new();
            for level in 0..depth - 1 {
                expected.push_str(&format!("层级{level}\n层级正文{level}\n"));
            }
            expected.push_str("新增卷\n第一章 甲\n甲文\n第二章 乙\n乙文\n");
            expected.push_str(&format!(
                "层级{}\n层级正文{}\n结束\n尾文",
                depth - 1,
                depth - 1
            ));
            assert_eq!(moved.text, expected);
            assert_eq!(moved.tree.nodes[depth as usize - 1].entry_id, volume_id);
            assert_eq!(moved.tree.nodes[depth as usize].entry_id, chapter);
            assert_eq!(moved.tree.source_bytes_covered, moved.text.len());
            assert_eq!(
                moved.source_to_output_lines.len(),
                source.summary().line_count as usize
            );
        }
    }

    #[test]
    fn subtree_move_preserves_children_and_changes_depth_at_destination() {
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n甲文\n节甲\n节正文\n第二章 乙\n乙文\n前言项\n前置正文"
                .as_bytes()
                .to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let mut structure = Structure::new(&source);
        structure
            .put(
                &source,
                Override {
                    source_line: 3,
                    role: Role::Section,
                    depth: 1,
                    include_toc: false,
                },
            )
            .unwrap();
        structure
            .put(
                &source,
                Override {
                    source_line: 7,
                    role: Role::Front,
                    depth: 0,
                    include_toc: true,
                },
            )
            .unwrap();
        let make = || crate::publication::compose(&source, &structure, None).unwrap();
        let ids = make()
            .tree
            .nodes
            .iter()
            .map(|n| n.entry_id.clone())
            .collect::<Vec<_>>();
        let mut req = Request {
            base_id: base_id(&make()),
            actions: vec![Action::MoveSubtree {
                entry_id: ids[0].clone(),
                before_id: Some(ids[3].clone()),
            }],
        };
        let (moved, _) = apply(make(), &req).unwrap();
        assert_eq!(
            moved.text,
            "第二章 乙\n乙文\n第一章 甲\n甲文\n节甲\n节正文\n前言项\n前置正文"
        );
        assert_eq!(moved.tree.nodes[2].parent_id.as_ref(), Some(&ids[0]));
        assert_eq!(moved.source_to_output_lines.len(), 8);
        req.actions.push(Action::MoveSubtree {
            entry_id: ids[1].clone(),
            before_id: Some(ids[2].clone()),
        });
        let (detached, _) = apply(make(), &req).unwrap();
        assert_eq!(detached.tree.nodes[0].entry_id, ids[1]);
        assert_eq!(detached.tree.nodes[0].depth, 0);
        assert!(!detached.tree.nodes[0].include_toc);
        req.actions.push(Action::MoveSubtree {
            entry_id: ids[3].clone(),
            before_id: Some(ids[2].clone()),
        });
        let (front, _) = apply(make(), &req).unwrap();
        assert_eq!(
            front.text,
            "节甲\n节正文\n前言项\n前置正文\n第二章 乙\n乙文\n第一章 甲\n甲文\n"
        );
        assert_eq!(front.source_to_output_lines.get(&8), Some(&4));
        assert_eq!(front.tree.source_bytes_covered, front.text.len());
        req.actions = vec![Action::MoveSubtree {
            entry_id: ids[0].clone(),
            before_id: Some(ids[1].clone()),
        }];
        assert!(apply(make(), &req).is_err());
    }

    #[test]
    fn merge_subtrees_keeps_direct_body_outside_children_for_all_roles() {
        let source = SourceSnapshot::from_utf8(
            "甲标题\n甲正文\n甲子题\n甲子文\n乙标题\n乙正文\n乙子题\n乙子文\n"
                .as_bytes()
                .to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        for role in [Role::Volume, Role::Chapter, Role::Section, Role::Front] {
            let mut structure = Structure::new(&source);
            for (line, r, depth) in [
                (1, role.clone(), 0),
                (3, Role::Section, 1),
                (5, role.clone(), 0),
                (7, Role::Section, 1),
            ] {
                structure
                    .put(
                        &source,
                        Override {
                            source_line: line,
                            role: r,
                            depth,
                            include_toc: true,
                        },
                    )
                    .unwrap();
            }
            let make = || crate::publication::compose(&source, &structure, None).unwrap();
            let ids = make()
                .tree
                .nodes
                .iter()
                .map(|n| n.entry_id.clone())
                .collect::<Vec<_>>();
            let mut req = Request {
                base_id: base_id(&make()),
                actions: vec![Action::MergeSubtreePrevious {
                    entry_id: ids[2].clone(),
                }],
            };
            let (merged, _) = apply(make(), &req).unwrap();
            assert_eq!(
                merged.text,
                "甲标题\n甲正文\n乙正文\n甲子题\n甲子文\n乙子题\n乙子文\n"
            );
            assert_eq!(
                &merged.text[merged.tree.nodes[0].body_start..merged.tree.nodes[0].end],
                "甲正文\n乙正文\n"
            );
            assert_eq!(merged.tree.nodes[2].parent_id.as_ref(), Some(&ids[0]));
            assert_eq!(merged.source_to_output_lines.get(&6), Some(&3));
            assert!(!merged.source_to_output_lines.contains_key(&5));
            assert_eq!(merged.removed_structure_lines, vec![5]);
            req.actions.push(Action::MergeSubtreePrevious {
                entry_id: ids[3].clone(),
            });
            let (twice, _) = apply(make(), &req).unwrap();
            assert_eq!(
                twice.text,
                "甲标题\n甲正文\n乙正文\n甲子题\n甲子文\n乙子文\n"
            );
            assert_eq!(twice.tree.nodes.len(), 2);
            req.actions.push(Action::Rename {
                entry_id: ids[2].clone(),
                title: "不得错改邻节点".into(),
            });
            assert!(apply(make(), &req).is_err());
            req.actions = vec![Action::MergeSubtreePrevious {
                entry_id: ids[1].clone(),
            }];
            assert!(apply(make(), &req).is_err());
        }
    }

    #[test]
    fn structure_only_plan_is_auditable_without_changing_txt() {
        let source = SourceSnapshot::from_utf8(
            "第一章 起\n甲文\n第二章 续\n乙文".as_bytes().to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let initial = crate::publication::compose(&source, &Structure::new(&source), None).unwrap();
        let request = Request {
            base_id: base_id(&initial),
            actions: vec![Action::Classify {
                entry_id: initial.tree.nodes[1].entry_id.clone(),
                role: Role::Section,
                depth: 1,
                include_toc: false,
            }],
        };
        let plan = prepare_output(
            &source,
            &json!({"kind":"publication","post_edits":request}).to_string(),
        )
        .unwrap();
        let preview: Value = serde_json::from_str(&plan.preview()).unwrap();
        assert_eq!(preview["text_changed"], false);
        assert_eq!(preview["change_count"], 1);
        assert_eq!(
            preview["actions"][0]["after_structure"]["include_toc"],
            false
        );
        assert_eq!(
            String::from_utf8(plan.output(&source).unwrap()).unwrap(),
            source.decoded_text()
        );
        let audit: Value = serde_json::from_slice(&plan.evidence()).unwrap();
        assert_eq!(audit["effective_structure"]["nodes"][1]["role"], "section");
    }

    #[test]
    fn changed_base_and_deleted_node_cannot_be_silently_retargeted() {
        let source = source();
        let initial = book(&source);
        let first = initial.tree.nodes[0].entry_id.clone();
        let second = initial.tree.nodes[1].entry_id.clone();
        let mut request = Request {
            base_id: base_id(&initial),
            actions: vec![
                Action::MergePrevious {
                    entry_id: second.clone(),
                },
                Action::Rename {
                    entry_id: second,
                    title: "不能改成邻章".into(),
                },
            ],
        };
        assert!(apply(initial, &request).is_err());
        request.actions = vec![Action::Rename {
            entry_id: first,
            title: "改名".into(),
        }];
        request.base_id = "0".repeat(64);
        assert!(apply(book(&source), &request).is_err());
        request.base_id = base_id(&book(&source));
        request.actions = vec![Action::Move {
            entry_id: "foreign:node".into(),
            before_id: None,
        }];
        assert!(apply(book(&source), &request).is_err());
        assert!(
            serde_json::from_value::<Request>(json!({"base_id":request.base_id,"actions":[
            {"kind":"rename","entry_id":"x","title":"x","source_line":2}]}))
            .is_err()
        );
    }
}

#[cfg(test)]
mod rebase_tests {
    use super::*;
    use crate::publication::compose_with_cleanup;
    const COLLAPSE: &str = r#"{"kind":"cleanup","pipeline":[{"kind":"collapse_blank_lines"}]}"#;
    fn source() -> SourceSnapshot {
        SourceSnapshot::from_utf8(
            "第一章 开始\n\n\n甲一\n\n\n甲二\n第二章 后续\n乙一\n\n\n乙二\n第三章 终\n丙一\n广告行\n丙二\n"
                .as_bytes()
                .to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap()
    }
    fn titles(book: &EffectiveBook) -> Vec<String> {
        book.tree.nodes.iter().map(|n| n.title.clone()).collect()
    }

    #[test]
    fn chapter_edits_follow_original_lines_onto_cleaned_text() {
        let source = source();
        let compose = |cleanup: Option<&str>| {
            compose_with_cleanup(&source, &Structure::new(&source), None, cleanup).unwrap()
        };
        let old = compose(None);
        let ids = old
            .tree
            .nodes
            .iter()
            .map(|n| n.entry_id.clone())
            .collect::<Vec<_>>();
        let mut request = Request {
            base_id: base_id(&old),
            actions: vec![
                Action::Rename {
                    entry_id: ids[1].clone(),
                    title: "第二章 改名".into(),
                },
                // “甲二” is old line 7, six lines below the first heading.
                Action::Split {
                    entry_id: ids[0].clone(),
                    line_offset: 6,
                    title: "第一章下".into(),
                },
            ],
        };
        let (split, _) = apply(old.clone(), &request).unwrap();
        let inserted = split
            .tree
            .nodes
            .iter()
            .find(|n| n.title == "第一章下")
            .unwrap()
            .entry_id
            .clone();
        assert!(inserted.starts_with("inserted:"));
        let third = split
            .tree
            .nodes
            .iter()
            .find(|n| n.title == "第三章 终")
            .unwrap();
        let advert = split.text.lines().position(|l| l == "广告行").unwrap() as u32 + 1;
        request.actions.extend([
            Action::Rename {
                entry_id: inserted,
                title: "第一章下 改".into(),
            },
            Action::ExcludeBodyLines {
                entry_id: Some(third.entry_id.clone()),
                first_offset: advert - third.source_line,
                last_offset: advert - third.source_line,
            },
            // Old line 3 is the second blank line of a run; cleanup removes it.
            Action::ExcludeBodyLines {
                entry_id: Some(ids[0].clone()),
                first_offset: 2,
                last_offset: 2,
            },
        ]);
        let (expected_old, _) = apply(old.clone(), &request).unwrap();

        let new_base = compose(Some(COLLAPSE));
        assert_ne!(base_id(&new_base), request.base_id);
        assert!(apply(new_base.clone(), &request).is_err());
        let rebased = rebase(old, new_base.clone(), &request).unwrap();
        assert_eq!(rebased.kept, vec![0, 1, 2, 3]);
        assert_eq!(rebased.skipped.len(), 1);
        assert_eq!(rebased.skipped[0]["index"], 4);
        assert_eq!(rebased.skipped[0]["reason"], "line_changed");
        assert_eq!(titles(&rebased.book), titles(&expected_old));
        assert!(!rebased.book.text.contains("广告行"));
        assert!(!rebased.book.text.contains("\n\n\n"));
        // The stored request replays to exactly the same book.
        let request = rebased.request.unwrap();
        assert_eq!(request.base_id, base_id(&new_base));
        let (replayed, _) = apply(new_base, &request).unwrap();
        assert_eq!(replayed.text, rebased.book.text);
        assert_eq!(base_id(&replayed), base_id(&rebased.book));
    }

    #[test]
    fn unchanged_base_keeps_every_action_and_rejects_foreign_requests() {
        let source = source();
        let book = compose_with_cleanup(&source, &Structure::new(&source), None, None).unwrap();
        let id = book.tree.nodes[2].entry_id.clone();
        let request = Request {
            base_id: base_id(&book),
            actions: vec![Action::Rename {
                entry_id: id,
                title: "第三章 新".into(),
            }],
        };
        let rebased = rebase(book.clone(), book.clone(), &request).unwrap();
        assert_eq!(rebased.kept, vec![0]);
        assert!(rebased.skipped.is_empty());
        assert_eq!(rebased.request.as_ref(), Some(&request));
        let mut foreign = request;
        foreign.base_id = "0".repeat(64);
        assert!(rebase(book.clone(), book, &foreign).is_err());
    }
}
