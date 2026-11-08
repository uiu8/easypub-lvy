//! Catalog proposals address the current manuscript, while original lines are
//! evidence anchors only. The ordinary effective-edit history applies them.
use crate::catalog::Catalog;
use easypub_core::{
    ApiError, effective_edit, effective_repair,
    publication::EffectiveBook,
    source::{SourceSnapshot, numbered_heading},
    structure::Role,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};

fn key(text: &str) -> String {
    text.chars().filter(|c| !c.is_whitespace()).collect()
}
fn title_key(text: &str) -> String {
    if numbered_heading(text).is_some()
        && let Some((i, c)) = text
            .char_indices()
            .find(|(_, c)| matches!(c, '章' | '回' | '节'))
        {
            return key(&text[i + c.len_utf8()..]);
        }
    easypub_core::recognition::NumericRule::Builtin
        .matches(text)
        .map(|n| key(&n.title))
        .unwrap_or_else(|| key(text))
}

pub fn preview(
    source: &SourceSnapshot,
    book: &EffectiveBook,
    catalog: &Catalog,
    choices: &Value,
    reorder: bool,
) -> Result<Value, ApiError> {
    let view = SourceSnapshot::for_effective_diagnostics(book)?;
    let duplicate_ranges = crate::catalog::duplicate_segments(catalog);
    if !duplicate_ranges.is_empty() && catalog.entries.len() > view.headings().len() {
        let plan_id = format!(
            "{:x}",
            Sha256::digest(
                json!([effective_edit::base_id(book), catalog.id, choices, reorder])
                    .to_string()
                    .as_bytes(),
            ),
        );
        return Ok(json!({
            "plan_id": plan_id,
            "matched": 0,
            "matches": [],
            "unresolved": [{
                "reason": "duplicate_catalog_segments_require_review",
                "segments": duplicate_ranges,
            }],
            "changes": [],
            "edits": [],
            "relocated_chapters": 0,
            "source_unchanged": true,
        }));
    }
    let corrected_titles = easypub_core::heading_typos::find(&view)
        .into_iter()
        .map(|c| (c.source_line, c.title))
        .collect::<BTreeMap<_, _>>();
    let mut full = BTreeMap::<String, Vec<usize>>::new();
    let mut titles = BTreeMap::<String, Vec<usize>>::new();
    for (i, e) in catalog.entries.iter().enumerate() {
        full.entry(key(&e.title)).or_default().push(i);
        titles.entry(title_key(&e.title)).or_default().push(i);
    }
    let nodes = book
        .tree
        .nodes
        .iter()
        .enumerate()
        .map(|(i, n)| (n.source_line, (i, n)))
        .collect::<BTreeMap<_, _>>();
    let mut original = BTreeMap::<u32, u32>::new();
    let mut ambiguous = BTreeSet::new();
    for (&from, &to) in &book.source_to_output_lines {
        if original.insert(to, from).is_some() {
            ambiguous.insert(to);
        }
    }
    for line in ambiguous {
        original.remove(&line);
    }
    let original_titles = source
        .headings()
        .iter()
        .map(|h| (h.source_line, h.title.as_str()))
        .collect::<BTreeMap<_, _>>();
    let prose = view
        .prose_headings()
        .iter()
        .map(|h| h.source_line)
        .collect::<BTreeSet<_>>();
    let mut matches = Vec::new();
    let mut unresolved = Vec::new();
    let mut used = BTreeSet::new();
    let mut changes = Vec::new();
    let mut located = BTreeMap::<usize, u32>::new();
    let mut current_volume = String::new();
    let mut previous_index = None;
    for (i, &(start, end)) in view.decoded_line_ranges().iter().enumerate() {
        let line = i as u32 + 1;
        let text = book.text[start..end].trim();
        let node = nodes.get(&line).map(|(_, n)| *n);
        if let Some(n) = node {
            if n.role == Role::Volume {
                current_volume = key(&n.title);
                continue;
            }
            if !matches!(n.role, Role::Chapter) || prose.contains(&line) {
                continue;
            }
        }
        if text.is_empty() || text.len() > 4096 {
            continue;
        }
        let mut candidates = full.get(&key(text)).cloned().unwrap_or_default();
        if candidates.is_empty()
            && let Some(corrected) = corrected_titles.get(&line) {
                candidates = full.get(&key(corrected)).cloned().unwrap_or_default();
            }
        if candidates.is_empty()
            && (node.is_some()
                || easypub_core::recognition::NumericRule::Builtin
                    .matches(text)
                    .is_some())
        {
            candidates = titles.get(&title_key(text)).cloned().unwrap_or_default();
        }
        // A manual rename retains its proven original location, not a guessed number.
        if candidates.is_empty() && node.is_some()
            && let Some(title) = original.get(&line).and_then(|l| original_titles.get(l)) {
                candidates = full.get(&key(title)).cloned().unwrap_or_default();
            }
        if candidates.len() > 1 && !current_volume.is_empty() {
            let scoped = candidates
                .iter()
                .copied()
                .filter(|i| key(&catalog.entries[*i].volume) == current_volume)
                .collect::<Vec<_>>();
            if !scoped.is_empty() {
                candidates = scoped;
            }
        }
        if let Some(id) = choices.get(line.to_string()).and_then(Value::as_str) {
            candidates.retain(|i| catalog.entries[*i].id == id);
        }
        if candidates.len() != 1 {
            if node.is_some() {
                unresolved.push(json!({"line":line,"title":text,"reason":if candidates.is_empty(){"unmatched"}else{"ambiguous_cross_volume"},"candidate_ids":candidates.iter().map(|i|&catalog.entries[*i].id).collect::<Vec<_>>()}));
            }
            continue;
        }
        let index = candidates[0];
        let entry = &catalog.entries[index];
        if !used.insert(index) {
            unresolved.push(json!({"line":line,"title":text,"reason":"duplicate_local_chapter_body_not_removed"}));
            continue;
        }
        located.insert(index, line);
        let conflict = previous_index.is_some_and(|previous| index < previous);
        previous_index = Some(index);
        let mut status = "matched";
        if let Some(n) = node {
            if key(&n.title) != key(&entry.title) {
                status = "title_difference";
                changes.push(json!({"finding_id":format!("catalog-title:{}",n.entry_id),"entry_id":n.entry_id,
                    "line":line,"kept_line":line,"title":"采用参考目录的标题（保留手工标题可不选）","before":n.title,"after":entry.title,
                    "truncated":false,"recommended":false,"actions":[{"kind":"rename","entry_id":n.entry_id,"title":entry.title}]}));
            }
        } else if let Some(action) =
            effective_repair::boundary_action(book, line, Some(entry.title.clone()))
        {
            status = "missing_heading";
            let previously_heading = original
                .get(&line)
                .is_some_and(|l| original_titles.contains_key(l));
            changes.push(json!({"finding_id":format!("catalog-heading:{line}"),"entry_id":action["entry_id"].as_str().unwrap_or("$prefix"),
                "line":line,"kept_line":line,"title":"把已找到的标题收入目录（采用参考标题）","before":format!("正文：{text}"),"after":format!("章节：{}",entry.title),
                "truncated":false,"recommended":!previously_heading && key(text)==key(&entry.title),"actions":[action]}));
        }
        matches.push(json!({"line":line,"title":text,"catalog_title":entry.title,"volume":entry.volume,
            "catalog_entry_id":entry.id,"catalog_index":index,"order_conflict":conflict,"status":status}));
    }
    for (index, e) in catalog.entries.iter().enumerate() {
        if !used.contains(&index) {
            unresolved.push(json!({"catalog_entry_id":e.id,"title":e.title,"volume":e.volume,"reason":"not_located_no_body_created"}));
        }
    }
    let ordered = matches.iter().all(|m| m["order_conflict"] != true);
    let wrong_volume = located.iter().any(|(index, line)| {
        let expected = &catalog.entries[*index];
        if !expected.structural_volume
            || !book
                .tree
                .nodes
                .iter()
                .any(|n| n.role == Role::Volume && key(&n.title) == key(&expected.volume))
        {
            return false;
        }
        let actual = nodes
            .get(line)
            .and_then(|(_, n)| n.parent_id.as_ref())
            .and_then(|id| book.tree.nodes.iter().find(|n| &n.entry_id == id));
        actual.is_none_or(|n| key(&n.title) != key(&expected.volume))
    });
    let needs_reorder = !ordered || wrong_volume;
    if wrong_volume && !reorder {
        unresolved.push(json!({"reason":"chapter_volume_differs_enable_reorder"}));
    }
    let local = effective_repair::candidates(book);
    changes.extend(
        local["items"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|v| {
                v["finding_id"].as_str().is_some_and(|id| {
                    id.starts_with("prose-heading:")
                        || id.starts_with("duplicate-title:")
                        || id.starts_with("duplicate-content:")
                })
            })
            .cloned(),
    );
    let mut volumes = BTreeSet::new();
    if ordered && !(reorder && needs_reorder) && catalog.completeness == "complete" {
        for (index, e) in catalog.entries.iter().enumerate() {
            if !e.structural_volume || e.volume.is_empty() || !volumes.insert(key(&e.volume)) {
                continue;
            }
            let Some(&line) = located.get(&index) else {
                continue;
            };
            if book
                .tree
                .nodes
                .iter()
                .any(|n| n.role == Role::Volume && key(&n.title) == key(&e.volume))
            {
                continue;
            }
            let node = nodes.get(&line).map(|(_, n)| *n);
            if node.is_some_and(|n| n.parent_id.is_some()) {
                unresolved.push(json!({"line":line,"title":e.title,"reason":"existing_volume_or_intro_requires_review","expected_volume":e.volume}));
                continue;
            }
            if let Some(&source_line) = original.get(&line) {
                changes.push(json!({"finding_id":format!("catalog-volume:{index}"),"entry_id":node.map(|n|n.entry_id.as_str()).unwrap_or("$prefix"),
                    "line":line,"kept_line":line,"title":"按参考目录建立卷","before":e.title,"after":format!("{} → {}",e.volume,e.title),
                    "truncated":false,"recommended":node.is_some() || changes.iter().any(|c|c["finding_id"]==format!("catalog-heading:{line}") && c["recommended"]==true),
                    "requires":if node.is_none(){vec![format!("catalog-heading:{line}")]}else{vec![]},
                    "actions":[{"kind":"insert_source_volume","source_line":source_line,"title":e.volume}]}));
            }
        }
    }
    let mut relocated = 0;
    if reorder
        && needs_reorder
        && catalog.completeness == "complete"
        && used.len() == catalog.entries.len()
    {
        // Compile prerequisites first, then bind the final order to immutable
        // source anchors so newly created heading IDs cannot drift on replay.
        let mut prerequisites = changes
            .iter()
            .filter(|c| {
                c["finding_id"].as_str().is_some_and(|id| {
                    id.starts_with("catalog-heading:")
                        || id.starts_with("prose-heading:")
                        || id.starts_with("duplicate-title:")
                })
            })
            .cloned()
            .collect::<Vec<_>>();
        prerequisites.sort_by_key(|c| std::cmp::Reverse(c["line"].as_u64().unwrap_or(0)));
        let actions = prerequisites
            .iter()
            .flat_map(|c| c["actions"].as_array().unwrap().iter().cloned())
            .collect::<Vec<_>>();
        let prepared = if actions.is_empty() {
            book.clone()
        } else {
            effective_edit::apply(
                book.clone(),
                &effective_edit::Request {
                    base_id: effective_edit::base_id(book),
                    actions: serde_json::from_value(json!(actions)).map_err(|_| {
                        ApiError::new(
                            easypub_core::ErrorCode::InvalidRule,
                            "catalog",
                            "review_composition",
                        )
                    })?,
                },
            )?
            .0
        };
        let mut mapped = BTreeMap::new();
        for (index, old_line) in &located {
            if let Some(line) = original
                .get(old_line)
                .and_then(|line| prepared.source_to_output_lines.get(line))
            {
                mapped.insert(*index, *line);
            }
        }
        let current_nodes = prepared
            .tree
            .nodes
            .iter()
            .map(|n| (n.source_line, n))
            .collect::<BTreeMap<_, _>>();
        let pieces = mapped
            .iter()
            .filter_map(|(&catalog_index, &line)| {
                current_nodes
                    .get(&line)
                    .map(|n| crate::catalog::RelocatedChapter {
                        start: n.start,
                        end: n.end,
                        catalog_index,
                        title: n.title.clone(),
                        source_line: line as usize,
                        insert_volume: String::new(),
                        intro_start: n.start,
                        intro_end: n.start,
                    })
            })
            .collect::<Vec<_>>();
        if pieces.len() == catalog.entries.len() {
            let plan = crate::catalog::Alignment {
                plan_id: String::new(),
                catalog_id: catalog.id.clone(),
                source_id: view.summary().source_id,
                revision: 1,
                writes: false,
                matches: matches.clone(),
                unresolved: vec![],
                edits: vec![],
                matched: pieces.len(),
                total: catalog.entries.len(),
                source_unchanged: true,
                relocation: Some(crate::catalog::Relocation {
                    prefix_end: prepared.tree.prefix_end,
                    pieces,
                    removed_headings: prepared
                        .tree
                        .nodes
                        .iter()
                        .filter(|n| n.role == Role::Volume)
                        .map(|n| json!({"line":n.source_line,"title":n.title}))
                        .collect(),
                }),
            };
            let selection = crate::catalog::CompositionSelection {
                snapshot: catalog.clone(),
                choices: choices.clone(),
                reorder: true,
                plan_id: plan.plan_id.clone(),
                confirmed: true,
            };
            match crate::catalog::effective_reorder_current(&prepared, &view, &selection, &plan) {
                Ok(actions) => {
                    let source_line = |id: &str| -> Option<u32> {
                        let n = prepared.tree.nodes.iter().find(|n| n.entry_id == id)?;
                        let mut originals = prepared
                            .source_to_output_lines
                            .iter()
                            .filter(|(_, line)| **line == n.source_line);
                        let first = *originals.next()?.0;
                        if originals.next().is_some() {
                            None
                        } else {
                            Some(first)
                        }
                    };
                    let resolved = actions
                        .into_iter()
                        .map(|a| match a {
                            effective_edit::Action::Reorder { order } => order
                                .into_iter()
                                .map(|(id, depth)| source_line(&id).map(|line| (line, depth)))
                                .collect::<Option<Vec<_>>>()
                                .map(|order| effective_edit::Action::ReorderSource { order }),
                            effective_edit::Action::InsertVolume { entry_id, title } => {
                                source_line(&entry_id).map(|source_line| {
                                    effective_edit::Action::InsertSourceVolume {
                                        source_line,
                                        title,
                                    }
                                })
                            }
                            _ => None,
                        })
                        .collect::<Option<Vec<_>>>();
                    let Some(actions) = resolved else {
                        return Ok(
                            json!({"plan_id":effective_edit::base_id(book),"matched":matches.len(),"matches":matches,"unresolved":[{"reason":"review_catalog_effective_location"}],"changes":changes,"edits":[],"relocated_chapters":0,"source_unchanged":true}),
                        );
                    };
                    relocated = located.len();
                    changes.push(json!({"finding_id":"catalog-reorder","entry_id":"$prefix","line":0,"kept_line":0,
                "title":"整章按目录归位（正文和图片随章移动）","before":matches.iter().map(|m|m["title"].as_str().unwrap_or("")).collect::<Vec<_>>().join("\n"),
                "after":catalog.entries.iter().map(|e|e.title.as_str()).collect::<Vec<_>>().join("\n"),"recommended":prerequisites.iter().all(|c|c["recommended"]==true),"requires":prerequisites.iter().map(|c|c["finding_id"].clone()).collect::<Vec<_>>(),"truncated":false,"actions":actions}));
                }
                Err(_) => {
                    unresolved.push(json!({"reason":"existing_volume_or_intro_requires_review"}))
                }
            }
        }
    }
    if catalog.completeness != "complete" {
        unresolved.push(json!({"reason":"catalog_scope_not_verified_complete"}));
    }
    let plan_id = format!(
        "{:x}",
        Sha256::digest(
            json!([
                effective_edit::base_id(book),
                catalog.id,
                choices,
                reorder,
                changes
            ])
            .to_string()
            .as_bytes()
        )
    );
    Ok(
        json!({"plan_id":plan_id,"matched":matches.len(),"matches":matches,"unresolved":unresolved,"changes":changes,
        "edits":[],"relocated_chapters":relocated,"source_unchanged":true}),
    )
}
