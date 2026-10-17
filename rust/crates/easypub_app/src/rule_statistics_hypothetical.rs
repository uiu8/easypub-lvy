//! Per-rule hypothetical views. Never publish these settings or replace the cache identity.
use super::*;
use crate::production::Settings;
use easypub_core::chapter_rules::RuleSet;
use std::collections::BTreeSet;

fn empty(template: &Statistics) -> Statistics {
    let mut result = template.clone();
    for row in result.values_mut() {
        row.count = 0;
        row.locations.clear();
        row.invalid_count = 0;
        row.affects.clear();
    }
    result
}

pub(super) fn collect(
    book: &EffectiveBook,
    settings: &Settings,
    pipeline: &Value,
    loc: &Locations<'_>,
    stats: &mut Statistics,
    cancel: &AtomicBool,
) -> Result<(), ApiError> {
    let catalog = crate::rule_catalog::catalog();
    let rows = catalog["rules"].as_array().unwrap();
    let original = book.tree.recognition_rules.clone().unwrap_or_default();
    let symbols: BTreeSet<_> = book
        .text
        .chars()
        .filter(|c| crate::publication_documents::SCENE_SYMBOLS.contains(*c))
        .collect();
    // The key is local to this calculation. Shared parent prerequisites need only one scan.
    let mut layouts: BTreeMap<String, (Settings, Vec<String>)> = BTreeMap::new();
    let mut recognitions: BTreeMap<String, (RuleSet, Vec<String>)> = BTreeMap::new();
    let mut checks: BTreeMap<String, (RuleSet, Vec<String>)> = BTreeMap::new();
    for row in rows {
        checkpoint(cancel)?;
        let id = row["id"].as_str().unwrap();
        if stats[id].enabled || stats[id].status != "complete" || row["locked"] == true {
            continue;
        }
        let group = row["group"].as_str().unwrap();
        if group == "cleanup" {
            // The cleanup collector already runs disabled steps on an isolated copy.
            stats.get_mut(id).unwrap().hypothetical = true;
            continue;
        }
        if !matches!(group, "layout" | "chapter_recognition" | "chapter_check") {
            continue;
        }
        // V59's layout collector already counts parent-off candidates, with other
        // subtype filters intact. Reuse those counts unless this subtype itself is off.
        if group == "layout" {
            let individually_enabled = if let Some(code) = id.strip_prefix("layout.scene.u") {
                let c = char::from_u32(u32::from_str_radix(code, 16).unwrap()).unwrap();
                settings
                    .rule_options
                    .scene_symbols
                    .as_ref()
                    .is_none_or(|s| s.contains(c))
            } else {
                settings.rule_options.enabled(id)
            };
            if individually_enabled {
                stats.get_mut(id).unwrap().hypothetical = true;
                continue;
            }
        }
        let mut rules = original.clone();
        let mut candidate = settings.clone();
        let mut unused_pipeline = pipeline.clone();
        if let Some(code) = id.strip_prefix("layout.scene.u") {
            let c = char::from_u32(u32::from_str_radix(code, 16).unwrap()).unwrap();
            if !symbols.contains(&c) {
                let r = stats.get_mut(id).unwrap();
                r.count = 0;
                r.locations.clear();
                r.hypothetical = true;
                continue;
            }
        }
        crate::rule_toggles::toggle(row, &mut rules, &mut candidate, &mut unused_pipeline, true)?;
        if let Some(parent) = row["parent"].as_str() {
            let parent_row = rows.iter().find(|r| r["id"] == parent).unwrap();
            if !crate::rule_toggles::enabled(parent_row, &rules, &candidate, pipeline) {
                crate::rule_toggles::toggle(
                    parent_row,
                    &mut rules,
                    &mut candidate,
                    &mut unused_pipeline,
                    true,
                )?;
            }
        }
        if id == "chapter.recognize.normalize_numeric" {
            rules.numeric = true;
            rules.disabled_recognition.retain(|id| id != "numeric");
        }
        match group {
            "layout" => {
                if let Some(symbols) = &mut candidate.rule_options.scene_symbols {
                    *symbols = symbols
                        .chars()
                        .collect::<BTreeSet<_>>()
                        .into_iter()
                        .collect();
                }
                layouts
                    .entry(serde_json::to_string(&candidate).unwrap())
                    .or_insert_with(|| (candidate, vec![]))
                    .1
                    .push(id.into());
            }
            "chapter_recognition" => {
                recognitions
                    .entry(serde_json::to_string(&rules).unwrap())
                    .or_insert_with(|| (rules, vec![]))
                    .1
                    .push(id.into());
            }
            "chapter_check" => {
                checks
                    .entry(serde_json::to_string(&rules).unwrap())
                    .or_insert_with(|| (rules, vec![]))
                    .1
                    .push(id.into());
            }
            _ => unreachable!(),
        }
    }
    for (_, (candidate, ids)) in layouts {
        checkpoint(cancel)?;
        let mut simulated = empty(stats);
        layout::collect(book, &candidate, loc, &mut simulated, cancel)?;
        install(stats, &simulated, &ids);
    }
    for (is_check, batches) in [(false, recognitions), (true, checks)] {
        for (_, (rules, ids)) in batches {
            checkpoint(cancel)?;
            let mut candidate = book.clone();
            candidate.tree.recognition_rules = Some(rules);
            let view = SourceSnapshot::for_effective_diagnostics(&candidate)?;
            let positions = Locations {
                book: &candidate,
                lines: loc.lines,
            };
            let mut simulated = empty(stats);
            if is_check {
                recognition::collect_checks(&view, &positions, &mut simulated, cancel)?;
            } else {
                recognition::collect(&view, &positions, &mut simulated, cancel)?;
                if ids
                    .iter()
                    .any(|id| id == "chapter.recognize.number_corrections")
                {
                    recognition::collect_checks(&view, &positions, &mut simulated, cancel)?;
                }
            }
            install(stats, &simulated, &ids);
        }
    }
    Ok(())
}

fn install(stats: &mut Statistics, simulated: &Statistics, ids: &[String]) {
    for id in ids {
        let row = stats.get_mut(id).unwrap();
        row.count = simulated[id].count;
        row.unit = simulated[id].unit;
        row.locations.clone_from(&simulated[id].locations);
        row.hypothetical = true;
    }
}
