use super::*;
use easypub_core::{chapter_rules::RuleSet, recognition};
use std::collections::BTreeSet;

pub(super) fn collect(
    source: &SourceSnapshot,
    loc: &Locations<'_>,
    stats: &mut Statistics,
    cancel: &AtomicBool,
) -> Result<(), ApiError> {
    let rules = loc.book.tree.recognition_rules.clone().unwrap_or_default();
    let compiled = rules.compile()?;
    let prefix = "chapter.recognize.";
    for (id, enabled) in [
        ("volume", rules.hierarchy),
        ("section", rules.hierarchy),
        (
            "level_chapter",
            rules.hierarchy && !rules.level_chapter_pattern.trim().is_empty(),
        ),
        ("numeric", rules.numeric),
        (
            "normalize_numeric",
            rules.numeric && rules.normalize_numeric_titles,
        ),
        ("author_note", rules.chapter_pattern.trim().is_empty()),
        ("prose", true),
        (
            "number_corrections",
            !rules.number_corrections.trim().is_empty(),
        ),
        ("non_heading", !rules.non_heading.trim().is_empty()),
        ("force_heading", !rules.force_heading.trim().is_empty()),
        ("title_suffixes", !rules.title_suffixes.trim().is_empty()),
    ] {
        stats
            .get_mut(&format!("{prefix}{id}"))
            .expect("rule")
            .enabled = enabled;
    }
    for (id, empty) in [
        (
            "level_chapter",
            rules.level_chapter_pattern.trim().is_empty(),
        ),
        (
            "number_corrections",
            rules.number_corrections.trim().is_empty(),
        ),
        ("non_heading", rules.non_heading.trim().is_empty()),
        ("force_heading", rules.force_heading.trim().is_empty()),
        ("title_suffixes", rules.title_suffixes.trim().is_empty()),
    ] {
        if empty {
            stats
                .get_mut(&format!("{prefix}{id}"))
                .expect("rule")
                .status = "unconfigured";
        }
    }
    let recognized = compiled.recognize(source);
    let accepted: BTreeSet<_> = recognized.iter().map(|n| n.source_line).collect();
    for n in &recognized {
        let (a, b) = loc.lines[n.source_line as usize - 1];
        let m = compiled
            .matched(&source.decoded_text()[a..b])
            .expect("recognized match");
        stats
            .get_mut(&format!("{prefix}{}", m.rule_id))
            .expect("rule")
            .hit(loc.line(n.source_line));
        if m.numeric {
            stats
                .get_mut(&format!("{prefix}normalize_numeric"))
                .expect("rule")
                .hit(loc.line(n.source_line));
        }
        if compiled.clean_title(&m.title).is_some() {
            stats
                .get_mut(&format!("{prefix}title_suffixes"))
                .expect("rule")
                .hit(loc.line(n.source_line));
        }
    }
    // Only the disabled option changes. Other filters and minimum body length remain intact.
    for (needed, hypothetical, ids) in [
        (
            !rules.hierarchy,
            RuleSet {
                hierarchy: true,
                ..rules.clone()
            },
            vec!["volume", "section", "level_chapter"],
        ),
        (
            !rules.numeric,
            RuleSet {
                numeric: true,
                ..rules.clone()
            },
            vec!["numeric", "normalize_numeric"],
        ),
    ] {
        if !needed {
            continue;
        }
        checkpoint(cancel)?;
        let h = hypothetical.compile()?;
        for n in h.recognize(source) {
            let (a, b) = loc.lines[n.source_line as usize - 1];
            let m = h
                .matched(&source.decoded_text()[a..b])
                .expect("recognized match");
            for id in &ids {
                if *id == m.rule_id || (*id == "normalize_numeric" && m.numeric) {
                    stats
                        .get_mut(&format!("{prefix}{id}"))
                        .expect("rule")
                        .hit(loc.line(n.source_line));
                }
            }
        }
    }
    for id in ["non_heading", "author_note", "prose"] {
        stats.get_mut(&format!("{prefix}{id}")).expect("rule").unit = "excluded_lines";
    }
    let dominant = recognition::dominant_marker(loc.lines.iter().filter_map(|&(a, b)| {
        let text = &source.decoded_text()[a..b];
        compiled.matched(text).map(|_| text)
    }));
    let without_non_heading = RuleSet {
        non_heading: String::new(),
        ..rules.clone()
    }
    .compile()?;
    for (i, &(a, b)) in loc.lines.iter().enumerate() {
        if i % 256 == 0 {
            checkpoint(cancel)?;
        }
        let text = &source.decoded_text()[a..b];
        let line = i as u32 + 1;
        let id = if compiled.is_non_heading(text) && without_non_heading.matched(text).is_some() {
            Some("non_heading")
        } else if rules.chapter_pattern.trim().is_empty()
            && recognition::is_default_heading(text)
            && recognition::is_author_note_heading(text)
        {
            Some("author_note")
        } else if compiled.matched(text).is_some_and(|m| !m.numeric)
            && !accepted.contains(&line)
            && recognition::is_prose_heading(text, dominant)
        {
            Some("prose")
        } else {
            None
        };
        if let Some(id) = id {
            stats
                .get_mut(&format!("{prefix}{id}"))
                .expect("rule")
                .hit(loc.line(line));
        }
    }
    checkpoint(cancel)?;
    let check_ids: Vec<_> = stats
        .keys()
        .filter(|k| k.starts_with("check.") && k.matches('.').count() == 1)
        .map(|k| k[6..].replace('_', "-"))
        .collect();
    let plan: Value =
        serde_json::from_str(&source.repair_plan_json(&json!(check_ids).to_string())?)
            .expect("repair plan");
    for action in plan["actions"].as_array().expect("actions") {
        checkpoint(cancel)?;
        let finding = action["finding_id"]
            .as_str()
            .expect("finding")
            .replace('-', "_");
        let line = action["source_lines"]
            .as_array()
            .and_then(|a| a.last())
            .and_then(Value::as_u64)
            .unwrap_or(1) as u32;
        stats
            .get_mut(&format!("check.{finding}"))
            .expect("rule")
            .hit(loc.line(line));
        if finding == "number_reset" {
            let subtype = action["subtype"]
                .as_str()
                .expect("subtype")
                .replace('-', "_");
            stats
                .get_mut(&format!("check.number_reset.{subtype}"))
                .expect("rule")
                .hit(loc.line(line));
        }
        if finding == "heading_number_typo" {
            let r = stats
                .get_mut("chapter.recognize.number_corrections")
                .expect("rule");
            r.unit = "issues";
            r.hit(loc.line(line));
        }
    }
    Ok(())
}
