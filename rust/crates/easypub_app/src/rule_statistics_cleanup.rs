use super::*;
use easypub_core::cleanup_rules;
use std::collections::BTreeSet;

fn base(rule: &Value) -> &Value {
    if rule["kind"] == "configured" {
        &rule["rule"]
    } else {
        rule
    }
}
fn base_mut(rule: &mut Value) -> &mut Value {
    if rule["kind"] == "configured" {
        &mut rule["rule"]
    } else {
        rule
    }
}
fn enabled(rule: &Value) -> bool {
    rule["kind"] != "configured" || rule["enabled"] == true
}
fn active(mut rule: Value) -> Value {
    if rule["kind"] == "configured" {
        rule["enabled"] = json!(true);
    }
    rule
}
fn ranges(mut ranges: Vec<(u32, u32)>) -> Vec<(u32, u32)> {
    ranges.sort_unstable();
    let mut result: Vec<(u32, u32)> = Vec::new();
    for (a, b) in ranges {
        if let Some(last) = result
            .last_mut()
            .filter(|last| a <= last.1.saturating_add(1))
        {
            last.1 = last.1.max(b);
        } else {
            result.push((a, b));
        }
    }
    result
}
pub(crate) fn fallback(kind: &str) -> Option<Value> {
    if matches!(
        kind,
        "literal_replace" | "regex_replace" | "multiline_regex_replace"
    ) {
        return None;
    }
    let presets = cleanup_rules::presets();
    let preset = match kind {
        "site_notices" => Some("site-notices-v1"),
        "repeated_headers" => Some("repeated-headers-v1"),
        "chinese_punctuation" => Some("typography-v1"),
        _ => None,
    };
    let expected = if matches!(kind, "site_notices" | "repeated_headers") {
        "notice_lines"
    } else {
        kind
    };
    if let Some(r) = presets
        .as_array()
        .expect("presets")
        .iter()
        .filter(|p| preset.is_none_or(|id| p["id"] == id))
        .flat_map(|p| p["rules"].as_array().expect("preset rules"))
        .find(|r| base(r)["kind"] == expected)
    {
        return Some(r.clone());
    }
    match kind {
        "chinese_variant" => Some(
            json!({"kind":kind,"direction":"t2s","dictionary_version":cleanup_rules::DICTIONARY_VERSION}),
        ),
        _ => None,
    }
}

pub(super) fn collect(
    source: &SourceSnapshot,
    pipeline: &Value,
    loc: &Locations<'_>,
    stats: &mut Statistics,
    cancel: &AtomicBool,
) -> Result<(), ApiError> {
    let configured = pipeline
        .as_array()
        .ok_or_else(|| error("review_cleanup_rule"))?;
    // Validate the same rule shapes accepted by the cleanup preview, including disabled rules.
    let _: Vec<cleanup_rules::Rule> =
        serde_json::from_value(pipeline.clone()).map_err(|_| error("review_cleanup_rule"))?;
    let ids: Vec<_> = stats
        .keys()
        .filter(|k| k.starts_with("cleanup."))
        .cloned()
        .collect();
    for id in ids {
        checkpoint(cancel)?;
        let suffix = &id[8..];
        let (kind, option) = suffix
            .split_once('.')
            .map_or((suffix, None), |(k, o)| (k, Some(o)));
        let matches = |r: &&Value| {
            let b = base(r);
            match kind {
                "site_notices" => b["kind"] == "remove_ad_lines" || b["kind"] == "notice_lines",
                "repeated_headers" => b["kind"] == "notice_lines",
                _ => b["kind"] == kind,
            }
        };
        let current: Vec<_> = configured.iter().filter(matches).cloned().collect();
        let rule_enabled = |r: &Value| {
            if !enabled(r) {
                return false;
            }
            let b = base(r);
            match kind {
                "repeated_headers" => b["options"]["include_headers"] == true,
                "site_notices" => {
                    b["kind"] == "remove_ad_lines"
                        || b["options"]["include_defaults"] == true
                        || b["options"]["pattern"].is_object()
                        || b["options"]["keywords"]
                            .as_array()
                            .is_some_and(|v| !v.is_empty())
                }
                "chinese_punctuation" => match option {
                    Some(o) => b["options"][o] == true,
                    None => ["marks", "ellipsis", "dashes", "quotes"]
                        .iter()
                        .any(|o| b["options"][o] == true),
                },
                _ => true,
            }
        };
        let target = stats.get_mut(&id).expect("rule");
        target.enabled = current.iter().any(rule_enabled);
        let to_evaluate = if current.is_empty() {
            fallback(kind).into_iter().collect::<Vec<_>>()
        } else if target.enabled {
            current.into_iter().filter(rule_enabled).collect()
        } else {
            current
        };
        if to_evaluate.is_empty() {
            target.status = "unconfigured";
            continue;
        }
        let notices = matches!(kind, "site_notices" | "repeated_headers");
        if notices {
            target.unit = "candidates";
        }
        let mut changes = Vec::new();
        let mut candidates = BTreeSet::new();
        let mut selectable = BTreeSet::new();
        for rule in to_evaluate {
            checkpoint(cancel)?;
            let mut hypothetical = active(rule);
            let b = base_mut(&mut hypothetical);
            if kind == "chinese_punctuation" {
                if let Some(option) = option {
                    for o in ["marks", "ellipsis", "dashes", "quotes"] {
                        b["options"][o] = json!(o == option);
                    }
                } else if !["marks", "ellipsis", "dashes", "quotes"]
                    .iter()
                    .any(|o| b["options"][o] == true)
                {
                    for o in ["marks", "ellipsis", "dashes", "quotes"] {
                        b["options"][o] = json!(true);
                    }
                }
            }
            if kind == "repeated_headers" {
                b["options"]["include_headers"] = json!(true);
            }
            if kind == "site_notices"
                && b["kind"] == "notice_lines"
                && b["options"]["include_defaults"] != true
                && !b["options"]["pattern"].is_object()
                && !b["options"]["keywords"]
                    .as_array()
                    .is_some_and(|v| !v.is_empty())
            {
                b["options"]["include_defaults"] = json!(true);
            }
            let request = json!({"kind":"cleanup","pipeline":[hypothetical]});
            let plan = match easypub_core::cleanup::prepare_cancellable(
                source,
                &request.to_string(),
                &|| cancel.load(Ordering::Relaxed),
            ) {
                Ok(v) => v,
                Err(e) => {
                    checkpoint(cancel)?;
                    target.status = "failed";
                    target.reason = Some(e.next_action);
                    break;
                }
            };
            if notices {
                for c in plan.notice_candidates() {
                    let has_reason = c["reasons"].as_array().expect("reasons").iter().any(|r| {
                        if kind == "repeated_headers" {
                            r == "page_header"
                        } else {
                            r != "page_header"
                        }
                    });
                    if has_reason {
                        let line = c["source_line"].as_u64().expect("candidate line") as u32;
                        candidates.insert(line);
                        if c["selectable"] == true {
                            selectable.insert(line);
                        }
                    }
                }
            } else {
                changes.extend(plan.changed_ranges());
            }
        }
        if target.status == "failed" {
            continue;
        }
        target.changed_ranges = ranges(changes);
        target.candidate_ranges = ranges(selectable.into_iter().map(|l| (l, l)).collect());
        if notices {
            for line in candidates {
                target.hit(loc.line(line));
            }
        } else {
            target.count = target
                .changed_ranges
                .iter()
                .map(|(a, b)| (b - a + 1) as usize)
                .sum();
            target.locations = target
                .changed_ranges
                .iter()
                .flat_map(|&(a, b)| a..=b)
                .take(50)
                .map(|l| loc.line(l))
                .collect();
        }
    }
    Ok(())
}
