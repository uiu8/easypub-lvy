use super::*;
use crate::production::Settings;
use easypub_core::{
    publication,
    structure::{Override, Structure},
};

fn layout_stats(
    book: &EffectiveBook,
    settings: &Settings,
    template: &Statistics,
    cancel: &AtomicBool,
) -> Result<Statistics, ApiError> {
    let view = SourceSnapshot::for_effective_diagnostics(book)?;
    let locations = Locations {
        book,
        lines: view.decoded_line_ranges(),
    };
    let mut stats = template.clone();
    for r in stats.values_mut() {
        r.count = 0;
        r.locations.clear();
        r.affects.clear();
        r.invalid_count = 0;
    }
    layout::collect(book, settings, &locations, &mut stats, cancel)?;
    Ok(stats)
}
pub(super) fn collect(
    book: &EffectiveBook,
    settings: &Settings,
    pipeline: &Value,
    loc: &Locations<'_>,
    stats: &mut Statistics,
    cancel: &AtomicBool,
) -> Result<(), ApiError> {
    let view = SourceSnapshot::for_effective_diagnostics(book)?;
    let structure = Structure {
        source_id: view.summary().source_id,
        revision: view.summary().revision,
        recognition_rules: Some(book.tree.recognition_rules.clone().unwrap_or_default()),
        overrides: book
            .tree
            .nodes
            .iter()
            .map(|n| Override {
                source_line: n.source_line,
                role: n.role.clone(),
                depth: n.depth,
                include_toc: n.include_toc,
            })
            .collect(),
    };
    // 清理规则对排版识别的影响：每种清理各模拟一次，彼此独立，并行计算（V83）。
    let kinds = [
        ("join_hard_wraps", "layout.verse"),
        ("site_notices", "layout.system"),
        ("normalize_punctuation", "layout.scene"),
        ("normalize_width", "layout.scene"),
    ];
    let snapshot: &Statistics = stats;
    let cleanup_affects = super::par_map(
        &kinds,
        |&(kind, target)| -> Result<Option<(String, Value)>, ApiError> {
            checkpoint(cancel)?;
            if snapshot[target].count == 0 {
                return Ok(None);
            }
            let id = format!("cleanup.{kind}");
            let mut selected: Vec<Value> = pipeline
                .as_array()
                .unwrap()
                .iter()
                .filter(|r| {
                    let b = if r["kind"] == "configured" {
                        &r["rule"]
                    } else {
                        r
                    };
                    if kind == "site_notices" {
                        b["kind"] == "notice_lines" || b["kind"] == "remove_ad_lines"
                    } else {
                        b["kind"] == kind
                    }
                })
                .cloned()
                .collect();
            if selected.is_empty() {
                selected.extend(cleanup::fallback(kind));
            }
            for r in &mut selected {
                if r["kind"] == "configured" {
                    r["enabled"] = json!(true);
                }
            }
            if selected.is_empty() {
                return Ok(None);
            }
            let request = json!({"kind":"cleanup","pipeline":selected});
            let plan = easypub_core::cleanup::prepare(&view, &request.to_string())?;
            if plan.changed_ranges().is_empty()
                && !plan
                    .notice_candidates()
                    .iter()
                    .any(|c| c["selectable"] == true)
            {
                return Ok(None);
            }
            // 广告是候选动作：模拟实际可选择的删除，绝不写入原文。
            let mut request = request;
            request["remove_lines"] = json!(
                plan.notice_candidates()
                    .iter()
                    .filter(|c| c["selectable"] == true)
                    .filter_map(|c| c["source_line"].as_u64())
                    .collect::<Vec<_>>()
            );
            let simulated = publication::compose_with_cleanup(
                &view,
                &structure,
                None,
                Some(&request.to_string()),
            )?;
            let after = layout_stats(&simulated, settings, snapshot, cancel)?;
            let delta = snapshot[target].count.saturating_sub(after[target].count);
            if delta == 0 {
                return Ok(None);
            }
            let after_lines: std::collections::BTreeSet<_> = after[target]
                .locations
                .iter()
                .filter_map(|p| p["source_line"].as_u64())
                .collect();
            let locations: Vec<_> = snapshot[target]
                .locations
                .iter()
                .filter(|p| {
                    p["source_line"].as_u64().is_some_and(|n| {
                        simulated
                            .source_to_output_lines
                            .get(&(n as u32))
                            .is_none_or(|mapped| !after_lines.contains(&u64::from(*mapped)))
                    })
                })
                .cloned()
                .collect();
            Ok(Some((
                id,
                json!({"rule":target,"count":delta,"locations":locations}),
            )))
        },
    );
    // 每次只取消一条识别规则产生的边界；其他标题和手工边界保持。
    let compiled = book
        .tree
        .recognition_rules
        .clone()
        .unwrap_or_default()
        .compile()?;
    let mut groups = BTreeMap::<String, std::collections::BTreeSet<usize>>::new();
    for n in &book.tree.nodes {
        let text = &book.text[n.start..n.body_start];
        if let Some(m) = compiled.matched(text.trim()) {
            groups
                .entry(format!("chapter.recognize.{}", m.rule_id))
                .or_default()
                .insert(n.start);
        }
    }
    let groups: Vec<_> = groups.into_iter().collect();
    let recognition_affects = super::par_map(
        &groups,
        |(id, starts)| -> Result<Vec<(String, Value)>, ApiError> {
            checkpoint(cancel)?;
            let mut body = book.clone();
            body.tree.nodes.retain(|n| !starts.contains(&n.start));
            let without = layout_stats(&body, settings, snapshot, cancel)?;
            let mut out = Vec::new();
            for target in ["layout.note", "layout.system"] {
                let delta = without[target].count.saturating_sub(snapshot[target].count);
                if delta > 0 {
                    let existing: std::collections::BTreeSet<_> = snapshot[target]
                        .locations
                        .iter()
                        .filter_map(|p| p["utf8_start"].as_u64())
                        .collect();
                    let locations: Vec<_> = without[target]
                        .locations
                        .iter()
                        .filter_map(|p| p["utf8_start"].as_u64())
                        .filter(|n| !existing.contains(n))
                        .take(50)
                        .map(|n| loc.byte(n as usize))
                        .collect();
                    out.push((
                        id.clone(),
                        json!({"rule":target,"count":delta,"locations":locations}),
                    ));
                }
            }
            Ok(out)
        },
    );
    for item in cleanup_affects {
        if let Some((id, affect)) = item? {
            stats.get_mut(&id).unwrap().affects.push(affect);
        }
    }
    for items in recognition_affects {
        for (id, affect) in items? {
            stats.get_mut(&id).unwrap().affects.push(affect);
        }
    }
    Ok(())
}
