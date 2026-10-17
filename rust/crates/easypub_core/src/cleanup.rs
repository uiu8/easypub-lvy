//! Line-based cleanup with explicit exclusions and unchanged source coordinates.
use crate::{
    ApiError, ErrorCode,
    cleanup_rules::{Rule, budget},
    source::SourceSnapshot,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StepExclusion {
    pub step_index: u32,
    pub source_line: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_end_line: Option<u32>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    kind: String,
    #[serde(default)]
    pub(crate) rules: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pipeline: Option<Vec<Rule>>,
    #[serde(default)]
    pub(crate) remove_lines: BTreeSet<u32>,
    #[serde(default)]
    pub(crate) skip_lines: BTreeSet<u32>,
    #[serde(default)]
    pub(crate) start_line: Option<u32>,
    #[serde(default)]
    pub(crate) end_line: Option<u32>,
    #[serde(default)]
    pub(crate) preview_offset: usize,
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub(crate) protected_lines: BTreeSet<u32>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) step_exclusions: Vec<StepExclusion>,
}
impl Request {
    pub fn preview_identity(mut self) -> (String, usize) {
        let offset = self.preview_offset;
        self.preview_offset = 0;
        (
            serde_json::to_string(&self).expect("cleanup request"),
            offset,
        )
    }
    pub fn ordered_rules(&self) -> Result<Vec<Rule>, ApiError> {
        if self.kind != "cleanup" {
            return Err(invalid());
        }
        if self.pipeline.is_none() {
            if self.rules.is_empty()
                || self.rules.len() > 3
                || self.rules.iter().any(|r| {
                    !matches!(
                        r.as_str(),
                        "trim_trailing_spaces" | "collapse_blank_lines" | "remove_ad_lines"
                    )
                })
            {
                return Err(invalid());
            }
            // Legacy projects used this fixed ordering regardless of checkbox order.
            Ok([
                ("trim_trailing_spaces", Rule::TrimTrailingSpaces),
                ("remove_ad_lines", Rule::RemoveAdLines),
                ("collapse_blank_lines", Rule::CollapseBlankLines),
            ]
            .into_iter()
            .filter(|(id, _)| self.rules.iter().any(|r| r == id))
            .map(|(_, r)| r)
            .collect::<Vec<_>>())
        } else {
            let Some(pipeline) = self.pipeline.as_ref() else {
                unreachable!("checked above")
            };
            if !self.rules.is_empty() || pipeline.len() > 32 {
                return Err(invalid());
            }
            Ok(pipeline.clone())
        }
    }
    pub fn apply_rules(
        current: Option<&Self>,
        rules: &[Rule],
        append: bool,
        protected: &BTreeSet<u32>,
    ) -> Result<Self, ApiError> {
        let mut next = current.cloned().unwrap_or(Self {
            kind: "cleanup".into(),
            rules: vec![],
            pipeline: None,
            remove_lines: BTreeSet::new(),
            skip_lines: BTreeSet::new(),
            start_line: None,
            end_line: None,
            preview_offset: 0,
            protected_lines: BTreeSet::new(),
            step_exclusions: Vec::new(),
        });
        let mut steps = if append && current.is_some() {
            next.ordered_rules()?
        } else {
            vec![]
        };
        steps.extend_from_slice(rules);
        if steps.is_empty() || steps.len() > 32 {
            return Err(invalid());
        }
        // Batch replacement transfers the template rules but deliberately keeps each
        // target's own source-bound exclusions. Their step indexes are target-local
        // coordinates; remapping them against the template would make an exclusion
        // silently refer to a different rule (or reject a valid target setting).
        next.rules.clear();
        next.pipeline = Some(steps);
        next.preview_offset = 0;
        next.protected_lines.extend(protected);
        if !next.remove_lines.is_empty()
            && !next
                .pipeline
                .as_ref()
                .expect("set pipeline")
                .iter()
                .any(Rule::is_notice)
        {
            return Err(ApiError::new(
                ErrorCode::InvalidRule,
                "cleanup_batch_notice_conflict",
                "keep_notice_rule_or_clear_target_selection",
            ));
        }
        Ok(next)
    }
    pub fn for_storage(&self) -> Self {
        let mut settings = self.clone();
        settings.preview_offset = 0;
        settings
    }
    fn validate_step_exclusions(&self, line_count: u32, step_count: usize) -> Result<(), ApiError> {
        if self.step_exclusions.len() > 10000 {
            return Err(invalid());
        }
        let mut seen = BTreeSet::new();
        for exclusion in &self.step_exclusions {
            let end = exclusion.source_end_line.unwrap_or(exclusion.source_line);
            if exclusion.step_index as usize >= step_count
                || exclusion.source_line == 0
                || end < exclusion.source_line
                || end > line_count
                || !seen.insert((exclusion.step_index, exclusion.source_line, end))
            {
                return Err(invalid());
            }
        }
        Ok(())
    }
}
#[derive(Serialize)]
struct Change {
    step_index: u32,
    source_line: u32,
    source_end_line: u32,
    before: String,
    after: Option<String>,
    reason: &'static str,
}
#[derive(Serialize)]
struct SourceRange {
    source_line: usize,
    source_end_line: usize,
    output_line: Option<u32>,
    output_end_line: Option<u32>,
    output_utf8_start: usize,
    output_utf8_end: usize,
    mapping: &'static str,
}
pub struct Cleanup {
    request: Request,
    text: String,
    changes: Vec<Change>,
    candidates: Vec<Value>,
    promoted_headings: BTreeSet<u32>,
    removed_duplicate_headings: BTreeMap<u32, u32>,
    stages: Vec<Value>,
    line_map: Vec<(u32, u32)>,
    source_ranges: Vec<SourceRange>,
    source_id: String,
    revision: u32,
}
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "cleanup",
        "review_cleanup_rules_and_lines",
    )
}
pub(crate) fn candidate(text: &str) -> bool {
    let t = text.trim();
    matches!(
        t,
        "本章完"
            | "（本章完）"
            | "(本章完)"
            | "【本章完】"
            | "作者有话说"
            | "请收藏"
            | "请收藏本站"
    ) || t.starts_with("广告：")
        || t.starts_with("广告:")
}
fn snippet(s: &str) -> String {
    s.chars().take(300).collect()
}
pub fn prepare(source: &SourceSnapshot, json: &str) -> Result<Cleanup, ApiError> {
    prepare_cancellable(source, json, &|| false)
}

/// Read-only callers may abandon a long preview without publishing partial results.
pub fn prepare_cancellable(
    source: &SourceSnapshot,
    json: &str,
    cancelled: &dyn Fn() -> bool,
) -> Result<Cleanup, ApiError> {
    if json.len() > 1024 * 1024 {
        return Err(invalid());
    }
    let request: Request = serde_json::from_str(json).map_err(|_| invalid())?;
    let protected = source.headings().iter().map(|h| h.source_line).collect();
    prepare_context_cancellable(source, request, &protected, &BTreeSet::new(), &BTreeMap::new(), None, cancelled)
}
pub(crate) fn prepare_with_context(
    source: &SourceSnapshot,
    request: Request,
    structural_lines: &BTreeSet<u32>,
    explicit_body_lines: &BTreeSet<u32>,
    heading_markers: &BTreeMap<u32, Option<char>>,
    duplicate_targets: Option<&BTreeMap<u32, u32>>,
) -> Result<Cleanup, ApiError> {
    prepare_context_cancellable(source, request, structural_lines, explicit_body_lines, heading_markers, duplicate_targets, &|| false)
}

fn prepare_context_cancellable(
    source: &SourceSnapshot,
    mut request: Request,
    structural_lines: &BTreeSet<u32>,
    explicit_body_lines: &BTreeSet<u32>,
    heading_markers: &BTreeMap<u32, Option<char>>,
    duplicate_targets: Option<&BTreeMap<u32, u32>>,
    cancelled: &dyn Fn() -> bool,
) -> Result<Cleanup, ApiError> {
    let checkpoint = || if cancelled() {
        Err(ApiError::new(ErrorCode::Cancelled, "cleanup", "request_statistics_again"))
    } else { Ok(()) };
    checkpoint()?;
    let lines = source.decoded_line_ranges();
    let first = request.start_line.unwrap_or(1);
    let last = request.end_line.unwrap_or(lines.len() as u32);
    if request.kind != "cleanup"
        || first == 0
        || first > last
        || last as usize > lines.len()
        || request
            .remove_lines
            .union(&request.skip_lines)
            .any(|&n| n < first || n > last)
        || request
            .protected_lines
            .iter()
            .any(|&n| n == 0 || n as usize > lines.len())
        || !request.remove_lines.is_disjoint(&request.skip_lines)
    {
        return Err(invalid());
    }
    let legacy = request.pipeline.is_none();
    let pipeline = request.ordered_rules()?;
    if legacy {
        request.rules.sort();
        request.rules.dedup();
    }
    let has_notices = pipeline.iter().any(Rule::is_notice);
    if !has_notices && !request.remove_lines.is_empty() {
        return Err(invalid());
    }
    let compiled = pipeline
        .iter()
        .map(Rule::compile)
        .collect::<Result<Vec<_>, _>>()?;
    request.validate_step_exclusions(lines.len() as u32, compiled.len())?;
    let discover_bare = compiled.iter().any(|r| {
        r.enabled
            && r.scope != crate::cleanup_rules::Scope::Headings
            && matches!(
                r.rule,
                Rule::ChapterNumbers {
                    bare_titles: true,
                    ..
                }
            )
    });
    struct Row<'a> {
        before: &'a str,
        text: Cow<'a, str>,
        ending: Cow<'a, str>,
        multiline: bool,
        removed: bool,
        merged: bool,
        source_start: usize,
        source_end: usize,
        protected: bool,
        eligible: bool,
        in_scope: bool,
        structural: bool,
        heading: bool,
        bare_title: bool,
        bare_marker: Option<char>,
        notice_mask: u32,
        reason: &'static str,
        last_step: usize,
    }
    let raw = source.decoded_text();
    let default_targets;
    let duplicate_targets = if let Some(targets) = duplicate_targets {
        targets
    } else {
        default_targets = if compiled
            .iter()
            .any(|r| r.enabled && matches!(r.rule, Rule::RemoveDuplicateTitles))
        {
            crate::cleanup_duplicates::targets(
                source,
                &crate::structure::Structure::new(source).tree(source)?.nodes,
            )
        } else {
            BTreeMap::new()
        };
        &default_targets
    };
    let mut removed_duplicate_headings = BTreeMap::new();
    let mut candidates = Vec::new();
    let mut candidate_text_bytes = 0usize;
    let mut promoted_headings = BTreeSet::new();
    let mut rows = Vec::with_capacity(lines.len());
    let mut excluded_ranges = vec![Vec::<(u32, u32)>::new(); compiled.len()];
    for e in &request.step_exclusions {
        excluded_ranges[e.step_index as usize]
            .push((e.source_line, e.source_end_line.unwrap_or(e.source_line)));
    }
    for ranges in &mut excluded_ranges {
        ranges.sort_unstable();
        let mut merged: Vec<(u32, u32)> = Vec::new();
        for &(start, end) in ranges.iter() {
            if let Some(last) = merged
                .last_mut()
                .filter(|last| start <= last.1.saturating_add(1))
            {
                last.1 = last.1.max(end);
            } else {
                merged.push((start, end));
            }
        }
        *ranges = merged;
    }
    let step_excluded = |step: usize, start: u32, end: u32| {
        let ranges = &excluded_ranges[step];
        let index = ranges.partition_point(|&(_, last)| last < start);
        ranges.get(index).is_some_and(|&(first, _)| first <= end)
    };
    for (index, &(start, end)) in lines.iter().enumerate() {
        if index % 256 == 0 { checkpoint()?; }
        let n = index as u32 + 1;
        let next = lines.get(index + 1).map(|&(s, _)| s).unwrap_or(raw.len());
        let before = &raw[start..end];
        let in_scope = n >= first && n <= last;
        let structural = structural_lines.contains(&n) || request.protected_lines.contains(&n);
        let bare_title = if discover_bare
            && in_scope
            && !request.skip_lines.contains(&n)
            && !explicit_body_lines.contains(&n)
            && !structural_lines.contains(&n)
        {
            if before.len() > 65536 {
                return Err(budget());
            }
            crate::cleanup_numbers::bare(before, &crate::cleanup_rules::NumberStyle::Arabic)
                .is_some()
        } else {
            false
        };
        let mut notice_mask = 0u32;
        let mut active_mask = 0u32;
        let mut reasons = Vec::new();
        let mut preserved = None;
        let mut new_notice_boundary = false;
        if in_scope && has_notices {
            for (step, rule) in compiled.iter().enumerate() {
                let mut matched = if let Some(matcher) = &rule.notices {
                    if rule.enabled {
                        preserved = preserved.or(matcher.preserve_reason(before)?);
                    }
                    matcher.reasons(before)?
                } else if matches!(rule.rule, Rule::RemoveAdLines) && candidate(before) {
                    vec!["default_notice"]
                } else {
                    vec![]
                };
                if !matched.is_empty() {
                    notice_mask |= 1 << step;
                    if rule.enabled {
                        active_mask |= 1 << step;
                    }
                    new_notice_boundary |= rule.enabled && rule.notices.is_some();
                    reasons.append(&mut matched);
                }
            }
        }
        if notice_mask != 0 {
            reasons.sort_unstable();
            reasons.dedup();
            let selectable = !structural && preserved.is_none();
            let excerpt = snippet(before);
            candidate_text_bytes = candidate_text_bytes.saturating_add(excerpt.len());
            if candidates.len() >= 100_000 || candidate_text_bytes > 16 * 1024 * 1024 {
                return Err(budget());
            }
            candidates.push(json!({"source_line":n,"text":excerpt,"truncated":before.chars().count()>300,"selected":request.remove_lines.contains(&n),"selectable":selectable,"active":active_mask!=0,"reasons":reasons,"preserved_by":preserved,"structural":structural}));
            if !selectable && request.remove_lines.contains(&n) {
                return Err(ApiError::new(
                    ErrorCode::InvalidRule,
                    "cleanup_preserve_conflict",
                    "clear_conflicting_notice_selections",
                ));
            }
        } else if request.remove_lines.contains(&n) {
            return Err(invalid());
        }
        rows.push(Row {
            before,
            text: Cow::Borrowed(before),
            ending: Cow::Borrowed(&raw[end..next]),
            multiline: false,
            removed: false,
            merged: false,
            source_start: index,
            source_end: index,
            protected: bare_title
                || new_notice_boundary
                || request.protected_lines.contains(&n)
                || structural_lines.contains(&n)
                || request.remove_lines.contains(&n),
            eligible: in_scope && !request.skip_lines.contains(&n),
            in_scope: in_scope && !request.skip_lines.contains(&n),
            structural,
            heading: structural_lines.contains(&n),
            bare_title,
            bare_marker: heading_markers.get(&n).copied().unwrap_or(Some('章')),
            notice_mask,
            reason: "ordered_rules",
            last_step: usize::MAX,
        });
    }
    let mut stages = Vec::new();
    let mut audit_bytes = 0usize;
    let mut output_bytes = raw.len();
    let mut matches_left = 1_000_000usize;
    for (step_index, compiled) in compiled.iter().enumerate() {
        checkpoint()?;
        if !compiled.enabled {
            continue;
        }
        for row in &mut rows {
            row.eligible = row.in_scope && compiled.scope.includes(row.structural);
        }
        if matches!(compiled.rule, Rule::RemoveDuplicateTitles) {
            for (&line, &previous) in duplicate_targets {
                let target = removed_duplicate_headings
                    .get(&previous)
                    .copied()
                    .unwrap_or(previous);
                let index = line as usize - 1;
                let retained = target as usize - 1;
                let row = &rows[index];
                // Eligibility is proved before cleanup, and still must hold now.
                // Earlier rules may have changed one heading or inserted body text.
                if !row.eligible
                    || row.removed
                    || row.merged
                    || rows[retained].removed
                    || rows[retained].merged
                    || rows[retained].text.trim() != row.text.trim()
                    || step_excluded(step_index, line, line)
                    || rows[previous as usize..index]
                        .iter()
                        .any(|r| !r.removed && !r.merged && !r.text.trim().is_empty())
                {
                    continue;
                }
                let before = format!("{}{}", row.text, row.ending);
                record_stage(
                    &mut stages,
                    &mut audit_bytes,
                    &mut output_bytes,
                    step_index,
                    index,
                    index,
                    &before,
                    None,
                    "duplicate_title",
                )?;
                rows[index].removed = true;
                rows[index].reason = "duplicate_title";
                rows[index].last_step = step_index;
                removed_duplicate_headings.insert(line, target);
            }
            continue;
        }
        if matches!(compiled.rule, Rule::MultilineRegexReplace { .. }) {
            let usable = |row: &Row| {
                row.eligible
                    && !row.protected
                    && !row.removed
                    && !row.merged
                    && !step_excluded(
                        step_index,
                        row.source_start as u32 + 1,
                        row.source_end as u32 + 1,
                    )
            };
            let mut index = 0;
            while index < rows.len() {
                if !usable(&rows[index]) {
                    index += 1;
                    continue;
                }
                let mut members = vec![index];
                let mut last = index;
                loop {
                    let next = rows[last].source_end + 1;
                    if next >= rows.len() || !usable(&rows[next]) {
                        break;
                    }
                    members.push(next);
                    last = next;
                }
                let mut block = String::new();
                let mut positions = Vec::new();
                for (part, &member) in members.iter().enumerate() {
                    let start = block.len();
                    block.push_str(&rows[member].text);
                    positions.push((start, block.len()));
                    if part + 1 < members.len() {
                        block.push_str(&rows[member].ending);
                    }
                    if block.len() > 256 * 1024 {
                        return Err(budget());
                    }
                }
                let edits = compiled.regex_edits(&block, &mut matches_left)?;
                // Group only overlapping source rows; unrelated matches stay independent.
                let mut groups: Vec<(usize, usize, Vec<usize>)> = Vec::new();
                for (e, edit) in edits.iter().enumerate() {
                    let first = positions
                        .partition_point(|(start, _)| *start <= edit.start)
                        .saturating_sub(1);
                    let mut end = positions
                        .partition_point(|(start, _)| *start <= edit.end)
                        .saturating_sub(1);
                    if edit.end > positions[end].1 && end + 1 < members.len() {
                        end += 1;
                    }
                    if let Some(group) = groups.last_mut().filter(|g| first <= g.1) {
                        group.1 = group.1.max(end);
                        group.2.push(e);
                    } else {
                        groups.push((first, end, vec![e]));
                    }
                }
                for (first, last, edit_indexes) in groups {
                    let head = members[first];
                    let tail = members[last];
                    let end = rows[tail].source_end;
                    let ending = rows[tail].ending.clone();
                    let start = positions[first].0;
                    let stop = positions[last].1;
                    let mut replacement = String::new();
                    let mut cursor = start;
                    for e in edit_indexes {
                        let edit = &edits[e];
                        replacement.push_str(&block[cursor..edit.start]);
                        replacement.push_str(&edit.replacement);
                        cursor = edit.end;
                    }
                    replacement.push_str(&block[cursor..stop]);
                    if replacement.len() > 1024 * 1024 {
                        return Err(budget());
                    }
                    let before = format!("{}{ending}", &block[start..stop]);
                    let after = format!("{replacement}{ending}");
                    record_stage(
                        &mut stages,
                        &mut audit_bytes,
                        &mut output_bytes,
                        step_index,
                        head,
                        end,
                        &before,
                        Some(&after),
                        "multiline_regex",
                    )?;
                    for &member in &members[first + 1..=last] {
                        rows[member].merged = true;
                    }
                    rows[head].text = Cow::Owned(replacement);
                    rows[head].ending = ending;
                    rows[head].source_end = end;
                    rows[head].multiline = true;
                    rows[head].reason = "multiline_regex";
                    rows[head].last_step = step_index;
                }
                index = rows[*members.last().unwrap()].source_end + 1;
            }
            continue;
        }
        if let Rule::JoinHardWraps { min_chars, mode } = &compiled.rule {
            // A previous cross-line replacement may have inserted new physical lines.
            for (index, row) in rows.iter_mut().enumerate() {
                if step_excluded(
                    step_index,
                    row.source_start as u32 + 1,
                    row.source_end as u32 + 1,
                ) {
                    continue;
                }
                if !row.eligible
                    || row.protected
                    || row.removed
                    || row.merged
                    || !row.text.contains(['\r', '\n'])
                {
                    continue;
                }
                let before = format!("{}{}", row.text, row.ending);
                let after = crate::cleanup_text::join_inside(&before, *min_chars, mode);
                if before == after {
                    continue;
                }
                record_stage(
                    &mut stages,
                    &mut audit_bytes,
                    &mut output_bytes,
                    step_index,
                    index,
                    row.source_end,
                    &before,
                    Some(&after),
                    "joined_hard_wraps",
                )?;
                let (body, ending) = crate::cleanup_text::split_ending(&after);
                row.text = Cow::Owned(body.to_owned());
                row.ending = Cow::Owned(ending.to_owned());
                row.multiline = true;
                row.reason = "joined_hard_wraps";
                row.last_step = step_index;
            }
            let usable = |row: &Row| {
                row.eligible
                    && !row.removed
                    && !row.merged
                    && !row.protected
                    && !candidate(row.before)
                    && !row.text.trim().is_empty()
                    && !crate::recognition::is_default_heading(&row.text)
                    && !step_excluded(
                        step_index,
                        row.source_start as u32 + 1,
                        row.source_end as u32 + 1,
                    )
            };
            let mut index = 0;
            while index < rows.len() {
                if !usable(&rows[index]) {
                    index += 1;
                    continue;
                }
                let mut members = vec![index];
                let mut last = index;
                let mut bytes = rows[index].text.len();
                loop {
                    let next = rows[last].source_end + 1;
                    if next >= rows.len()
                        || !usable(&rows[next])
                        || rows[last].ending.is_empty()
                        || !crate::cleanup_text::joinable(
                            &rows[last].text,
                            &rows[next].text,
                            *min_chars,
                            mode,
                        )
                    {
                        break;
                    }
                    bytes = bytes
                        .saturating_add(mode.separator().len())
                        .saturating_add(rows[next].text.len());
                    if bytes > 1024 * 1024 {
                        return Err(budget());
                    }
                    members.push(next);
                    last = next;
                }
                if members.len() == 1 {
                    index = rows[index].source_end + 1;
                    continue;
                }
                let end = rows[last].source_end;
                let ending = rows[last].ending.clone();
                let mut before = String::new();
                let mut joined = String::with_capacity(bytes);
                for (position, &member) in members.iter().enumerate() {
                    before.push_str(&rows[member].text);
                    before.push_str(&rows[member].ending);
                    if position > 0 {
                        joined.push_str(mode.separator());
                    }
                    joined.push_str(&rows[member].text);
                }
                let after = format!("{joined}{ending}");
                audit_bytes = audit_bytes
                    .saturating_add(before.len())
                    .saturating_add(after.len())
                    .saturating_add(64);
                output_bytes = output_bytes
                    .saturating_sub(before.len())
                    .saturating_add(after.len());
                if audit_bytes > 64 * 1024 * 1024
                    || output_bytes > 128 * 1024 * 1024
                    || stages.len() >= 100_000
                {
                    return Err(budget());
                }
                stages.push(json!({"step_index":step_index,"source_line":index+1,"source_end_line":end+1,"before":before,"after":after,"reason":"joined_hard_wraps"}));
                for &member in members.iter().skip(1) {
                    rows[member].merged = true;
                }
                rows[index].multiline |= members.iter().any(|&m| rows[m].multiline);
                rows[index].text = Cow::Owned(joined);
                rows[index].ending = ending;
                rows[index].source_end = end;
                rows[index].reason = "joined_hard_wraps";
                rows[index].last_step = step_index;
                index = end + 1;
            }
            continue;
        }
        let mut previous_blank = false;
        for (index, row) in rows.iter_mut().enumerate() {
            if index % 256 == 0 { checkpoint()?; }
            if !row.eligible {
                previous_blank = false;
                continue;
            }
            if row.removed || row.merged {
                continue;
            }
            if step_excluded(
                step_index,
                row.source_start as u32 + 1,
                row.source_end as u32 + 1,
            ) {
                previous_blank = false;
                continue;
            }
            if row.text.contains(['\r', '\n']) && matches!(compiled.rule, Rule::CollapseBlankLines)
            {
                let before = format!("{}{}", row.text, row.ending);
                let mut after = String::new();
                for (line, ending) in crate::cleanup_text::lines(&before, false) {
                    let blank = line.trim().is_empty();
                    if !(blank && previous_blank) {
                        after.push_str(line);
                        after.push_str(ending);
                    }
                    previous_blank = blank;
                }
                if before != after {
                    record_stage(
                        &mut stages,
                        &mut audit_bytes,
                        &mut output_bytes,
                        step_index,
                        index,
                        row.source_end,
                        &before,
                        if after.is_empty() { None } else { Some(&after) },
                        "duplicate_blank",
                    )?;
                    let (body, ending) = crate::cleanup_text::split_ending(&after);
                    row.text = Cow::Owned(body.to_owned());
                    row.ending = Cow::Owned(ending.to_owned());
                    row.removed = after.is_empty();
                    row.multiline = true;
                    row.last_step = step_index;
                    row.reason = "duplicate_blank";
                }
                continue;
            }
            let n = index as u32 + 1;
            let mut after = None;
            let remove = match &compiled.rule {
                Rule::ChapterNumbers { style, bare_titles } => {
                    if row.heading || (*bare_titles && row.bare_title) {
                        if row.text.len() > 65536 {
                            return Err(budget());
                        }
                        let converted = if row.heading {
                            crate::cleanup_numbers::marked(&row.text, style).or_else(|| {
                                row.bare_marker.and_then(|marker| {
                                    crate::cleanup_numbers::bare_with_marker(
                                        &row.text, style, marker,
                                    )
                                })
                            })
                        } else {
                            crate::cleanup_numbers::bare(&row.text, style)
                        };
                        if let Some(converted) = converted {
                            if !row.heading {
                                promoted_headings.insert(n);
                                row.heading = true;
                                row.structural = true;
                                row.protected = true;
                            }
                            after = Some(converted);
                        }
                    }
                    false
                }
                Rule::RemoveAdLines | Rule::NoticeLines { .. } => {
                    request.remove_lines.contains(&n)
                        && row.notice_mask & (1 << step_index) != 0
                        && !step_excluded(
                            step_index,
                            row.source_start as u32 + 1,
                            row.source_end as u32 + 1,
                        )
                }
                Rule::CollapseBlankLines => {
                    let blank = row.text.trim().is_empty();
                    let remove =
                        blank && previous_blank && (!row.text.is_empty() || !row.ending.is_empty());
                    previous_blank = blank;
                    remove
                }
                _ => {
                    after = Some(if row.text.contains(['\r', '\n']) {
                        crate::cleanup_text::transform_lines(
                            compiled,
                            &row.text,
                            &mut matches_left,
                        )?
                    } else {
                        compiled.transform(&row.text, &mut matches_left)?
                    });
                    false
                }
            };
            if !remove && after.as_deref().is_none_or(|v| v == row.text) {
                continue;
            }
            let before = if remove {
                format!("{}{}", row.text, row.ending)
            } else {
                row.text.to_string()
            };
            let replacement_len = after.as_ref().map_or(0, String::len);
            audit_bytes = audit_bytes
                .saturating_add(before.len())
                .saturating_add(replacement_len)
                .saturating_add(64);
            output_bytes = output_bytes
                .saturating_sub(if remove {
                    row.text.len() + row.ending.len()
                } else {
                    row.text.len()
                })
                .saturating_add(replacement_len);
            if audit_bytes > 64 * 1024 * 1024
                || output_bytes > 128 * 1024 * 1024
                || stages.len() >= 100_000
            {
                return Err(budget());
            }
            stages.push(
                json!({"step_index":step_index,"source_line":n,"source_end_line":row.source_end+1,"before":before,"after":after}),
            );
            row.reason = if row.multiline {
                "multiline_regex"
            } else if row.source_end > index {
                "joined_hard_wraps"
            } else {
                match compiled.rule {
                    Rule::TrimTrailingSpaces => "trailing_spaces",
                    Rule::RemoveAdLines | Rule::NoticeLines { .. } => "selected_notice",
                    Rule::RemoveDuplicateTitles => "duplicate_title",
                    Rule::CollapseBlankLines => "duplicate_blank",
                    _ => "ordered_rules",
                }
            };
            row.last_step = step_index;
            if remove {
                row.removed = true;
            } else {
                row.text = Cow::Owned(after.unwrap());
            }
        }
    }
    let mut text = String::with_capacity(output_bytes);
    let mut changes = Vec::new();
    let mut line_map = Vec::new();
    let mut source_ranges = Vec::new();
    let mut output_spans = Vec::new();
    for (index, row) in rows.into_iter().enumerate() {
        if index % 256 == 0 { checkpoint()?; }
        if row.merged {
            continue;
        }
        let original_end = lines
            .get(row.source_end + 1)
            .map(|&(s, _)| s)
            .unwrap_or(raw.len());
        let before_full = &raw[lines[index].0..original_end];
        let after_full = if row.removed {
            String::new()
        } else {
            format!("{}{}", row.text, row.ending)
        };
        let output_start = text.len();
        text.push_str(&after_full);
        output_spans.push((index, row.source_end, output_start, text.len()));
        if before_full != after_full {
            let wide = row.source_end > index || row.multiline;
            changes.push(Change {
                step_index: row.last_step as u32,
                source_line: index as u32 + 1,
                source_end_line: row.source_end as u32 + 1,
                before: if row.removed || wide {
                    before_full.to_owned()
                } else {
                    row.before.to_owned()
                },
                after: if row.removed {
                    None
                } else if wide {
                    Some(after_full)
                } else {
                    Some(row.text.into_owned())
                },
                reason: row.reason,
            });
        }
    }
    // A replacement starting with LF can join a preceding CR across two spans.
    // Derive line numbers from the complete output, never sum per-span counts.
    let mut offset = 0;
    let starts: Vec<_> = crate::cleanup_text::lines(&text, false)
        .into_iter()
        .map(|(body, ending)| {
            let start = offset;
            offset += body.len() + ending.len();
            start
        })
        .collect();
    for (first, last, start, end) in output_spans {
        if start == end {
            source_ranges.push(SourceRange {
                source_line: first + 1,
                source_end_line: last + 1,
                output_line: None,
                output_end_line: None,
                output_utf8_start: start,
                output_utf8_end: end,
                mapping: "removed",
            });
            continue;
        }
        let first_line = starts.partition_point(|&s| s <= start) as u32;
        let last_line = starts.partition_point(|&s| s < end) as u32;
        if first_line == last_line {
            for n in first..=last {
                line_map.push((n as u32 + 1, first_line));
            }
        }
        source_ranges.push(SourceRange {
            source_line: first + 1,
            source_end_line: last + 1,
            output_line: Some(first_line),
            output_end_line: Some(last_line),
            output_utf8_start: start,
            output_utf8_end: end,
            mapping: if first_line == last_line {
                "line"
            } else {
                "region"
            },
        });
    }
    let summary = source.summary();
    Ok(Cleanup {
        request,
        text,
        changes,
        candidates,
        promoted_headings,
        removed_duplicate_headings,
        stages,
        line_map,
        source_ranges,
        source_id: summary.source_id,
        revision: summary.revision,
    })
}

// 参数各有独立含义，改成结构体会牵动所有调用者；V21 保留现状。
#[allow(clippy::too_many_arguments)]
fn record_stage(
    stages: &mut Vec<Value>,
    audit_bytes: &mut usize,
    output_bytes: &mut usize,
    step: usize,
    start: usize,
    end: usize,
    before: &str,
    after: Option<&str>,
    reason: &str,
) -> Result<(), ApiError> {
    *audit_bytes = audit_bytes
        .saturating_add(before.len())
        .saturating_add(after.map_or(0, str::len))
        .saturating_add(64);
    *output_bytes = output_bytes
        .saturating_sub(before.len())
        .saturating_add(after.map_or(0, str::len));
    if *audit_bytes > 64 * 1024 * 1024
        || *output_bytes > 128 * 1024 * 1024
        || stages.len() >= 100_000
    {
        return Err(budget());
    }
    stages.push(json!({"step_index":step,"source_line":start+1,"source_end_line":end+1,"before":before,"after":after,"reason":reason}));
    Ok(())
}

impl Cleanup {
    pub(crate) fn text(&self) -> &str {
        &self.text
    }
    pub(crate) fn retained_lines(&self) -> &[(u32, u32)] {
        &self.line_map
    }
    pub(crate) fn promoted_headings(&self) -> &BTreeSet<u32> {
        &self.promoted_headings
    }
    pub(crate) fn removed_duplicate_headings(&self) -> &BTreeMap<u32, u32> {
        &self.removed_duplicate_headings
    }

    fn id(&self) -> String {
        let mut request = self.request.clone();
        request.preview_offset = 0;
        let mut hash = Sha256::new();
        hash.update(b"cleanup-v7");
        hash.update(self.source_id.as_bytes());
        hash.update(self.revision.to_le_bytes());
        hash.update(serde_json::to_vec(&request).expect("request"));
        format!("{:x}", hash.finalize())
    }
    pub fn preview(&self) -> String {
        self.preview_at(self.request.preview_offset)
    }

    /// Conservative retained-allocation estimate for an optional preview cache.
    pub fn cache_bytes(&self) -> usize {
        fn value_bytes(v: &Value) -> usize {
            std::mem::size_of::<Value>()
                + match v {
                    Value::String(s) => s.capacity(),
                    Value::Array(a) => {
                        a.capacity() * std::mem::size_of::<Value>()
                            + a.iter().map(value_bytes).sum::<usize>()
                    }
                    Value::Object(m) => m
                        .iter()
                        .map(|(k, v)| 128 + k.capacity() + value_bytes(v))
                        .sum(),
                    _ => 0,
                }
        }
        std::mem::size_of::<Self>()
            + self.text.capacity()
            + self.source_id.capacity()
            + serde_json::to_vec(&self.request).expect("request").len() * 8
            + self.changes.capacity() * std::mem::size_of::<Change>()
            + self
                .changes
                .iter()
                .map(|c| c.before.capacity() + c.after.as_ref().map_or(0, String::capacity))
                .sum::<usize>()
            + self.stages.capacity() * std::mem::size_of::<Value>()
            + self.stages.iter().map(value_bytes).sum::<usize>()
            + self.candidates.capacity() * std::mem::size_of::<Value>()
            + self.candidates.iter().map(value_bytes).sum::<usize>()
            + self.line_map.capacity() * std::mem::size_of::<(u32, u32)>()
            + self.source_ranges.capacity() * std::mem::size_of::<SourceRange>()
            + (self.promoted_headings.len() + self.removed_duplicate_headings.len()) * 128
    }

    pub fn preview_at(&self, offset: usize) -> String {
        let actions=self.changes.iter().skip(offset).take(40).map(|c|json!({"step_index":c.step_index,"source_line":c.source_line,"source_end_line":c.source_end_line,"before":snippet(&c.before),"after":c.after.as_ref().map(|s|snippet(s)),"reason":c.reason,"truncated":c.before.chars().count()>300||c.after.as_ref().is_some_and(|s|s.chars().count()>300)})).collect::<Vec<_>>();
        let stage_actions = self
            .stages
            .iter()
            .skip(offset)
            .take(40)
            .map(|stage| {
                let mut stage = stage.clone();
                let mut truncated = false;
                for key in ["before", "after"] {
                    if let Some(text) = stage[key].as_str() {
                        truncated |= text.chars().count() > 300;
                        stage[key] = json!(snippet(text));
                    }
                }
                stage["truncated"] = json!(truncated);
                stage
            })
            .collect::<Vec<_>>();
        let mut step_counts = std::collections::BTreeMap::<usize, usize>::new();
        for stage in &self.stages {
            if let Some(index) = stage["step_index"].as_u64() {
                *step_counts.entry(index as usize).or_default() += 1;
            }
        }
        json!({"step_counts":step_counts,"kind":"cleanup","plan_id":self.id(),"source_id":self.source_id,"revision":self.revision,"writes":false,"requires_confirmation":true,"source_unchanged":true,
            "promoted_heading_count":self.promoted_headings.len(),"promoted_heading_lines":self.promoted_headings.iter().skip(offset).take(40).collect::<Vec<_>>(),"stage_actions":stage_actions,"rules_ordered":self.request.pipeline.is_some(),"pipeline":self.request.pipeline.as_deref().unwrap_or(&[]),"stage_count":self.stages.len(),"change_count":self.changes.len(),"candidate_count":self.candidates.len(),"preview_offset":offset,"page_size":40,
            "actions":actions,"candidates":self.candidates.iter().skip(offset).take(40).collect::<Vec<_>>()}).to_string()
    }
    /// Paired, source-anchored regions from the exact final cleanup projection.
    /// Context is read-only and does not alter the plan or its identity.
    pub fn context(
        &self,
        source: &SourceSnapshot,
        first: u32,
        last: u32,
        offset: usize,
    ) -> Result<Value, ApiError> {
        if source.summary().source_id != self.source_id
            || first == 0
            || last < first
            || last > source.summary().line_count
        {
            return Err(invalid());
        }
        let low = first.saturating_sub(3).max(1) as usize;
        let high = last.saturating_add(3) as usize;
        let ranges = source.decoded_line_ranges();
        let matching = self
            .source_ranges
            .iter()
            .filter(|r| r.source_end_line >= low && r.source_line <= high)
            .collect::<Vec<_>>();
        let rows = matching.iter().skip(offset).take(30).map(|r| {
            let start = ranges[r.source_line-1].0;
            let end = ranges.get(r.source_end_line).map(|v|v.0).unwrap_or(source.decoded_text().len());
            let before = &source.decoded_text()[start..end];
            let after = &self.text[r.output_utf8_start..r.output_utf8_end];
            json!({"source_line":r.source_line,"source_end_line":r.source_end_line,
                "output_line":r.output_line,"output_end_line":r.output_end_line,
                "before":before.chars().take(2000).collect::<String>(),
                "after":if r.mapping=="removed" {None} else {Some(after.chars().take(2000).collect::<String>())},
                "truncated":before.chars().count()>2000 || after.chars().count()>2000,
                "selected":r.source_end_line>=first as usize && r.source_line<=last as usize,
                "mapping":r.mapping})
        }).collect::<Vec<_>>();
        Ok(
            json!({"plan_id":self.id(),"rows":rows,"offset":offset,"total":matching.len(),"has_more":offset.saturating_add(rows.len())<matching.len(),"read_only":true}),
        )
    }

    pub fn stage_region(
        &self,
        source: &SourceSnapshot,
        first: u32,
        last: u32,
        step: u32,
        char_offset: usize,
    ) -> Result<Value, ApiError> {
        if source.summary().source_id != self.source_id || !char_offset.is_multiple_of(2000) {
            return Err(invalid());
        }
        let stage = self
            .stages
            .iter()
            .find(|s| {
                s["source_line"] == first && s["source_end_line"] == last && s["step_index"] == step
            })
            .ok_or_else(invalid)?;
        let before = stage["before"].as_str().ok_or_else(invalid)?;
        let after = stage["after"].as_str();
        let before_total = before.chars().count();
        let after_total = after.map_or(0, |s| s.chars().count());
        let total = before_total.max(after_total);
        if char_offset >= total && char_offset != 0 {
            return Err(invalid());
        }
        Ok(
            json!({"plan_id":self.id(),"source_line":first,"source_end_line":last,"step_index":step,
            "before":before.chars().skip(char_offset).take(2000).collect::<String>(),
            "after":after.map(|s| s.chars().skip(char_offset).take(2000).collect::<String>()),
            "before_total":before_total,"after_total":after_total,"char_offset":char_offset,
            "next_offset":char_offset.saturating_add(2000),"has_more":char_offset.saturating_add(2000)<total,"read_only":true}),
        )
    }

    pub fn context_region(
        &self,
        source: &SourceSnapshot,
        first: u32,
        last: u32,
        region_line: u32,
        char_offset: usize,
    ) -> Result<Value, ApiError> {
        if source.summary().source_id != self.source_id
            || first == 0
            || last < first
            || last > source.summary().line_count
            || !char_offset.is_multiple_of(2000)
        {
            return Err(invalid());
        }
        let range = self
            .source_ranges
            .iter()
            .find(|r| {
                r.source_line == region_line as usize
                    && r.source_end_line >= first.saturating_sub(3).max(1) as usize
                    && r.source_line <= last.saturating_add(3) as usize
            })
            .ok_or_else(invalid)?;
        let lines = source.decoded_line_ranges();
        let start = lines[range.source_line - 1].0;
        let end = lines
            .get(range.source_end_line)
            .map(|r| r.0)
            .unwrap_or(source.decoded_text().len());
        let before = &source.decoded_text()[start..end];
        let after = &self.text[range.output_utf8_start..range.output_utf8_end];
        let before_total = before.chars().count();
        let after_total = after.chars().count();
        let total = before_total.max(after_total);
        if char_offset >= total && char_offset != 0 {
            return Err(invalid());
        }
        Ok(
            json!({"plan_id":self.id(),"source_line":range.source_line,"source_end_line":range.source_end_line,
            "output_line":range.output_line,"output_end_line":range.output_end_line,
            "before":before.chars().skip(char_offset).take(2000).collect::<String>(),
            "after":if range.mapping=="removed" {None} else {Some(after.chars().skip(char_offset).take(2000).collect::<String>())},
            "before_total":before_total,"after_total":after_total,"char_offset":char_offset,
            "next_offset":char_offset.saturating_add(2000),"has_more":char_offset.saturating_add(2000)<total,"read_only":true}),
        )
    }

    pub fn output(&self, source: &SourceSnapshot) -> Result<Vec<u8>, ApiError> {
        source.encode_edited_text(&self.text)
    }
    /// Complete source-line coverage for statistics/R4; independent of preview pagination.
    pub fn changed_ranges(&self) -> Vec<(u32, u32)> {
        self.changes.iter().map(|c| (c.source_line, c.source_end_line)).collect()
    }
    pub fn notice_candidates(&self) -> &[Value] {
        &self.candidates
    }
    pub fn evidence(&self) -> Vec<u8> {
        // Borrow the large tables: do not create a second JSON object graph per source line.
        #[derive(Serialize)]
        struct Evidence<'a> {
            schema: u32,
            kind: &'static str,
            plan_id: String,
            source_id: &'a str,
            revision: u32,
            request: &'a Request,
            changes: &'a [Change],
            stages: &'a [Value],
            source_to_output_lines: &'a [(u32, u32)],
            source_to_output_ranges: &'a [SourceRange],
            promoted_heading_lines: &'a BTreeSet<u32>,
            removed_duplicate_headings: &'a BTreeMap<u32, u32>,
        }
        serde_json::to_vec(&Evidence {
            promoted_heading_lines: &self.promoted_headings,
            removed_duplicate_headings: &self.removed_duplicate_headings,
            schema: 1,
            kind: "cleanup",
            plan_id: self.id(),
            source_id: &self.source_id,
            revision: self.revision,
            request: &self.request,
            changes: &self.changes,
            stages: &self.stages,
            source_to_output_lines: &self.line_map,
            source_to_output_ranges: &self.source_ranges,
        })
        .expect("cleanup evidence")
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn complete_stage_is_intermediate_not_original_or_final() {
        let raw = format!("{}尾声\r\n", "😀甲".repeat(2100));
        let source = SourceSnapshot::from_utf8(raw.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let plan = prepare(&source, r#"{"kind":"cleanup","pipeline":[{"kind":"literal_replace","find":"甲","replace":"乙"},{"kind":"literal_replace","find":"乙","replace":"丙"},{"kind":"literal_replace","find":"丙","replace":"丁"}]}"#).unwrap();
        let mut before = String::new();
        let mut after = String::new();
        for offset in [0, 2000, 4000] {
            let piece = plan.stage_region(&source, 1, 1, 1, offset).unwrap();
            before.push_str(piece["before"].as_str().unwrap());
            after.push_str(piece["after"].as_str().unwrap());
            assert_eq!(piece["plan_id"], plan.id());
        }
        assert_eq!(before, raw.trim_end_matches("\r\n").replace('甲', "乙"));
        assert_eq!(after, raw.trim_end_matches("\r\n").replace('甲', "丙"));
        assert_eq!(plan.text, raw.replace('甲', "丁"));
        assert_eq!(source.decoded_text(), raw);
        assert!(plan.stage_region(&source, 1, 1, 3, 0).is_err());
        assert!(plan.stage_region(&source, 1, 2, 1, 0).is_err());
        assert!(plan.stage_region(&source, 1, 1, 1, 6000).is_err());
    }
    #[test]
    fn complete_context_chunks_reconstruct_unicode_and_unequal_sides() {
        let raw = format!("{}\r\n", "😀汉".repeat(2100));
        let source = SourceSnapshot::from_utf8(raw.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let plan=prepare(&source,r#"{"kind":"cleanup","pipeline":[{"kind":"literal_replace","find":"汉","replace":""}]}"#).unwrap();
        let mut before = String::new();
        let mut after = String::new();
        let mut offset = 0;
        loop {
            let piece = plan.context_region(&source, 1, 1, 1, offset).unwrap();
            before.push_str(piece["before"].as_str().unwrap());
            after.push_str(piece["after"].as_str().unwrap());
            if piece["has_more"] == false {
                break;
            }
            offset = piece["next_offset"].as_u64().unwrap() as usize;
        }
        assert_eq!(before, raw);
        assert_eq!(after, plan.text);
        assert_eq!(after, format!("{}\r\n", "😀".repeat(2100)));
        assert!(plan.context_region(&source, 1, 1, 1, 1).is_err());
        assert!(plan.context_region(&source, 1, 1, 1, 6000).is_err());
        assert!(plan.context_region(&source, 1, 1, 2, 0).is_err());
        assert_eq!(source.original_bytes(), raw.as_bytes());
    }
    #[test]
    fn paired_context_tracks_merged_deleted_and_unchanged_regions_without_changing_plan() {
        let source = SourceSnapshot::from_utf8(
            "第一章 起\n长长中文段落\n继续中文尾句。\n\n\n末段。\n"
                .as_bytes()
                .to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let plan=prepare(&source,r#"{"kind":"cleanup","pipeline":[{"kind":"join_hard_wraps","mode":"chinese","min_chars":4},{"kind":"collapse_blank_lines"}]}"#).unwrap();
        let before = plan.preview();
        let context = plan.context(&source, 2, 5, 0).unwrap();
        let rows = context["rows"].as_array().unwrap();
        let merged = rows.iter().find(|r| r["source_line"] == 2).unwrap();
        assert_eq!(merged["source_end_line"], 3);
        assert_eq!(merged["output_line"], 2);
        assert_eq!(merged["output_end_line"], 2);
        assert_eq!(merged["before"], "长长中文段落\n继续中文尾句。\n");
        assert_eq!(merged["after"], "长长中文段落继续中文尾句。\n");
        let removed = rows.iter().find(|r| r["mapping"] == "removed").unwrap();
        assert_eq!(removed["before"], "\n");
        assert!(removed["after"].is_null());
        assert_eq!(before, plan.preview());
        assert_eq!(
            context["plan_id"],
            serde_json::from_str::<Value>(&before).unwrap()["plan_id"]
        );
        assert!(plan.context(&source, 0, 2, 0).is_err());
    }

    #[test]
    fn paired_context_paginates_ranges_and_marks_long_content() {
        let raw = (0..65)
            .map(|i| format!("独立行{i}。\n"))
            .collect::<String>();
        let source = SourceSnapshot::from_utf8(raw.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let plan = prepare(&source, r#"{"kind":"cleanup","pipeline":[]}"#).unwrap();
        let mut lines = Vec::new();
        for offset in [0, 30, 60] {
            let page = plan.context(&source, 1, 65, offset).unwrap();
            lines.extend(
                page["rows"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|r| r["source_line"].as_u64().unwrap()),
            );
        }
        assert_eq!(lines, (1..=65).collect::<Vec<_>>());
        let long =
            SourceSnapshot::from_utf8("字".repeat(2500).into_bytes(), RULE_ID, || false).unwrap();
        let plan = prepare(&long, r#"{"kind":"cleanup","pipeline":[]}"#).unwrap();
        let page = plan.context(&long, 1, 1, 0).unwrap();
        assert_eq!(page["rows"][0]["truncated"], true);
        assert_eq!(
            page["rows"][0]["before"].as_str().unwrap().chars().count(),
            2000
        );
    }
    use super::*;
    use crate::{
        encoding::{EncodingKind, EncodingMode, encode},
        source::RULE_ID,
    };
    fn variant_rule(direction: &str) -> Value {
        json!({"kind":"chinese_variant","direction":direction,"dictionary_version":crate::cleanup_rules::DICTIONARY_VERSION})
    }
    fn configured(rule: Value, enabled: bool, scope: &str) -> Value {
        json!({"kind":"configured","enabled":enabled,"scope":scope,"rule":rule})
    }
    #[test]
    fn step_exclusions_are_source_bound_and_do_not_disable_later_steps() {
        let source = SourceSnapshot::from_utf8(
            "第一章 标题\n正文,测试...\n另一行,继续...\n尾声"
                .as_bytes()
                .to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let pipeline = json!([
            {"kind":"literal_replace","find":"正文","replace":"内容"},
            configured(json!({"kind":"chinese_punctuation","options":{"marks":true,"ellipsis":true,"dashes":true,"quotes":true}}),true,"body")
        ]);
        let mut request = json!({"kind":"cleanup","pipeline":pipeline});
        let all = prepare(&source, &request.to_string()).unwrap();
        assert_eq!(all.text, "第一章 标题\n内容，测试……\n另一行，继续……\n尾声");
        assert_eq!(
            all.stages
                .iter()
                .map(|s| s["step_index"].as_u64().unwrap())
                .collect::<Vec<_>>(),
            vec![0, 1, 1]
        );
        request["step_exclusions"] = json!([{"step_index":0,"source_line":2}]);
        let later = prepare(&source, &request.to_string()).unwrap();
        assert_eq!(
            later.text,
            "第一章 标题\n正文，测试……\n另一行，继续……\n尾声"
        );
        assert!(later.stages.iter().all(|s| s["step_index"] != 0));
        request["step_exclusions"] = json!([{"step_index":1,"source_line":2}]);
        let first = prepare(&source, &request.to_string()).unwrap();
        assert_eq!(
            first.text,
            "第一章 标题\n内容,测试...\n另一行，继续……\n尾声"
        );
        assert!(first.stages.iter().any(|s| s["step_index"] == 0));
        assert!(
            first
                .stages
                .iter()
                .any(|s| s["step_index"] == 1 && s["source_line"] == 3)
        );
        for invalid_request in [
            json!({"kind":"cleanup","pipeline":pipeline,"step_exclusions":[{"step_index":9,"source_line":2}]}),
            json!({"kind":"cleanup","pipeline":pipeline,"step_exclusions":[{"step_index":0,"source_line":0}]}),
            json!({"kind":"cleanup","pipeline":pipeline,"step_exclusions":[{"step_index":0,"source_line":4,"source_end_line":2}]}),
            json!({"kind":"cleanup","pipeline":pipeline,"step_exclusions":[{"step_index":0,"source_line":2},{"step_index":0,"source_line":2}]}),
        ] {
            assert!(prepare(&source, &invalid_request.to_string()).is_err());
        }
    }
    #[test]
    fn step_exclusion_is_a_crossline_barrier_and_notice_exclusion_keeps_other_steps() {
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n前一段\n广告：示例\n后一段\n"
                .as_bytes()
                .to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let join = json!({"kind":"join_hard_wraps","mode":"chinese","min_chars":2});
        let mut request = json!({"kind":"cleanup","pipeline":[join]});
        request["step_exclusions"] = json!([{"step_index":0,"source_line":2}]);
        let plan = prepare(&source, &request.to_string()).unwrap();
        assert_eq!(plan.text, source.decoded_text());
        let notice = json!({"kind":"notice_lines","options":{"include_defaults":true,"include_headers":false}});
        let punctuation = configured(
            json!({"kind":"chinese_punctuation","options":{"marks":true,"ellipsis":true,"dashes":true,"quotes":true}}),
            true,
            "body",
        );
        let mut selected = json!({"kind":"cleanup","pipeline":[notice,punctuation],"remove_lines":[3],"step_exclusions":[{"step_index":0,"source_line":3}]});
        let kept = prepare(&source, &selected.to_string()).unwrap();
        assert_eq!(kept.text, "第一章 甲\n前一段\n广告：示例\n后一段\n");
        selected["step_exclusions"] = json!([]);
        let removed = prepare(&source, &selected.to_string()).unwrap();
        assert_eq!(removed.text, "第一章 甲\n前一段\n后一段\n");
    }
    #[test]
    fn duplicate_title_rule_only_removes_proven_adjacent_heading() {
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n正文\n\n第二章 乙\n\n第二章 乙\n中间正文\n第二章 乙\n尾声"
                .as_bytes()
                .to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let request = json!({
            "kind":"cleanup",
            "pipeline":[{"kind":"remove_duplicate_titles"}]
        });
        let plan = prepare(&source, &request.to_string()).unwrap();
        assert_eq!(
            plan.text,
            "第一章 甲\n正文\n\n第二章 乙\n\n中间正文\n第二章 乙\n尾声"
        );
        assert_eq!(plan.changes.len(), 1);
        assert_eq!(plan.changes[0].source_line, 6);
        assert_eq!(plan.changes[0].reason, "duplicate_title");
        assert_eq!(plan.stages[0]["step_index"], 0);
    }
    #[test]
    fn number_and_punctuation_steps_preserve_encodings_scope_and_body() {
        let raw = "第００１章 题,名\r\n他说:金额1,234.56元,时间12:30。\n002 雨夜\r正文...\r\n003 保留的行\n第4章 跳过";
        let expected = "第一章 题,名\r\n他说：金额1,234.56元，时间12:30。\n第二章 雨夜\r正文……\r\n003 保留的行\n第4章 跳过";
        for encoding in [
            EncodingKind::Utf8,
            EncodingKind::Utf16Le,
            EncodingKind::Utf16Be,
            EncodingKind::Utf32Le,
            EncodingKind::Utf32Be,
            EncodingKind::Cp936,
        ] {
            let bom = encoding != EncodingKind::Cp936;
            let bytes = encode(raw, encoding, bom).unwrap();
            let source =
                SourceSnapshot::from_bytes(bytes.clone(), EncodingMode::Auto, RULE_ID, || false)
                    .unwrap();
            let req = json!({"kind":"cleanup","end_line":5,"skip_lines":[5],"pipeline":[
                {"kind":"chapter_numbers","style":"chinese","bare_titles":true},
                configured(json!({"kind":"chinese_punctuation","options":{"marks":true,"ellipsis":true,"dashes":true,"quotes":true}}),true,"body")
            ]});
            let result = prepare(&source, &req.to_string()).unwrap();
            assert_eq!(
                result.output(&source).unwrap(),
                encode(expected, encoding, bom).unwrap()
            );
            assert_eq!(result.promoted_headings(), &BTreeSet::from([3]));
            assert_eq!(source.original_bytes(), bytes);
        }
    }
    #[test]
    fn bare_title_recognition_is_opt_in_and_changes_later_heading_scope() {
        let source =
            SourceSnapshot::from_utf8("001 雨 夜\n正文".as_bytes().to_vec(), RULE_ID, || false)
                .unwrap();
        let n = json!({"kind":"chapter_numbers","style":"arabic","bare_titles":true});
        let later = configured(json!({"kind":"ocr_han_spaces"}), true, "headings");
        let req = json!({"kind":"cleanup","pipeline":[n,later]});
        assert_eq!(
            prepare(&source, &req.to_string()).unwrap().text,
            "第1章雨夜\n正文"
        );
        let disabled = json!({"kind":"cleanup","pipeline":[configured(n,false,"all"),later]});
        assert_eq!(
            prepare(&source, &disabled.to_string()).unwrap().text,
            source.decoded_text()
        );
        let no_bare = json!({"kind":"cleanup","pipeline":[{"kind":"chapter_numbers","style":"chinese","bare_titles":false}]});
        assert_eq!(
            prepare(&source, &no_bare.to_string()).unwrap().text,
            source.decoded_text()
        );
    }
    fn notice(options: Value) -> Value {
        let mut defaults = json!({"include_defaults":true,"include_headers":true});
        defaults
            .as_object_mut()
            .unwrap()
            .extend(options.as_object().unwrap().clone());
        json!({"kind":"notice_lines","options":defaults})
    }
    #[test]
    fn overly_broad_candidate_rules_are_bounded_before_preview() {
        let raw = format!("第一章 甲\n{}", "x\n".repeat(100_001));
        let source = SourceSnapshot::from_utf8(raw.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let mut req = json!({"kind":"cleanup","pipeline":[notice(json!({"include_defaults":false,"include_headers":false,"keywords":["x"]}))]});
        assert_eq!(
            prepare(&source, &req.to_string()).err().unwrap().code,
            ErrorCode::TooLarge
        );
        assert_eq!(source.decoded_text(), raw);
        req["end_line"] = json!(41);
        assert_eq!(
            prepare(&source, &req.to_string()).unwrap().candidates.len(),
            40
        );
    }
    #[test]
    fn notice_candidates_preserve_encoding_and_require_explicit_selection() {
        let raw = "第一章 广告位\r\n正文引用：广告位\n第12页\r书友分享无错更新 example.com\r\n他打开 example.com 看新闻。\n正文";
        let expected = "第一章 广告位\r\n正文引用：广告位\n他打开 example.com 看新闻。\n正文";
        for encoding in [
            EncodingKind::Utf8,
            EncodingKind::Utf16Le,
            EncodingKind::Utf16Be,
            EncodingKind::Utf32Le,
            EncodingKind::Utf32Be,
            EncodingKind::Cp936,
        ] {
            let bom = encoding != EncodingKind::Cp936;
            let bytes = encode(raw, encoding, bom).unwrap();
            let source =
                SourceSnapshot::from_bytes(bytes.clone(), EncodingMode::Auto, RULE_ID, || false)
                    .unwrap();
            let mut req = json!({"kind":"cleanup","pipeline":[notice(json!({"preserve_keywords":["正文引用"]}))]});
            let preview = prepare(&source, &req.to_string()).unwrap();
            assert_eq!(preview.text, raw);
            assert_eq!(preview.candidates.len(), 4);
            assert_eq!(preview.candidates[0]["selectable"], false);
            assert_eq!(preview.candidates[0]["structural"], true);
            assert_eq!(preview.candidates[1]["preserved_by"], "preserve_keyword");
            req["remove_lines"] = json!([3, 4]);
            let plan = prepare(&source, &req.to_string()).unwrap();
            assert_eq!(
                plan.output(&source).unwrap(),
                encode(expected, encoding, bom).unwrap()
            );
            assert_eq!(source.original_bytes(), bytes);
            for protected in [1, 2] {
                req["remove_lines"] = json!([protected]);
                let error = prepare(&source, &req.to_string()).err().unwrap();
                assert_eq!(error.operation, "cleanup_preserve_conflict");
            }
        }
    }
    #[test]
    fn preserve_priority_applies_across_rules_and_disable_restores_selection() {
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n广告：正文引用\n正文".as_bytes().to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let preserve = notice(
            json!({"include_defaults":false,"include_headers":false,"preserve_pattern":{"text":"正文引用","regex":false}}),
        );
        let mut req = json!({"kind":"cleanup","remove_lines":[2],"pipeline":[{"kind":"remove_ad_lines"},configured(preserve,true,"all")]});
        assert_eq!(
            prepare(&source, &req.to_string()).err().unwrap().operation,
            "cleanup_preserve_conflict"
        );
        req["pipeline"][1]["enabled"] = json!(false);
        assert_eq!(
            prepare(&source, &req.to_string()).unwrap().text,
            "第一章 甲\n正文"
        );
        req["pipeline"][0] = configured(notice(json!({})), false, "all");
        let off = prepare(&source, &req.to_string()).unwrap();
        assert_eq!(off.candidates[0]["selected"], true);
        assert_eq!(off.candidates[0]["active"], false);
        assert_eq!(off.text, source.decoded_text());
    }
    #[test]
    fn candidate_qualification_and_removal_stage_use_original_text() {
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n标记A\n正文".as_bytes().to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let a =
            notice(json!({"include_defaults":false,"include_headers":false,"keywords":["标记A"]}));
        let b =
            notice(json!({"include_defaults":false,"include_headers":false,"keywords":["标记B"]}));
        let replace = json!({"kind":"literal_replace","find":"标记A","replace":"标记B"});
        let req = json!({"kind":"cleanup","remove_lines":[2],"pipeline":[b,replace,a]});
        let plan = prepare(&source, &req.to_string()).unwrap();
        assert_eq!(plan.text, "第一章 甲\n正文");
        assert_eq!(plan.stages[0]["step_index"], 1);
        assert_eq!(plan.stages[1]["step_index"], 2);
        let manufactured = json!({"kind":"cleanup","remove_lines":[2],"pipeline":[replace,b]});
        assert!(prepare(&source, &manufactured.to_string()).is_err());
    }
    #[test]
    fn new_candidates_bound_crossline_rules_and_respect_scope_skips() {
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n正文前半\n推广候选\n正文后半\n页码:2"
                .as_bytes()
                .to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let n = notice(json!({"keywords":["推广候选"]}));
        let join = json!({"kind":"join_hard_wraps","min_chars":2,"mode":"chinese"});
        let req = json!({"kind":"cleanup","pipeline":[n,join]});
        assert_eq!(
            prepare(&source, &req.to_string()).unwrap().text,
            source.decoded_text()
        );
        let disabled =
            json!({"kind":"cleanup","pipeline":[configured(n.clone(),false,"all"),join]});
        assert!(
            prepare(&source, &disabled.to_string())
                .unwrap()
                .text
                .contains("正文前半推广候选正文后半")
        );
        let scoped =
            json!({"kind":"cleanup","pipeline":[n],"start_line":2,"end_line":4,"skip_lines":[3]});
        let plan = prepare(&source, &scoped.to_string()).unwrap();
        assert_eq!(plan.text, source.decoded_text());
        assert_eq!(plan.candidates.len(), 1);
        let invalid = json!({"kind":"cleanup","pipeline":[configured(n,true,"body")]});
        assert!(prepare(&source, &invalid.to_string()).is_err());
    }
    #[test]
    fn ocr_steps_preserve_scope_disablement_encodings_and_audit() {
        let raw = "第一章 标 题\r\n正 文\t之 间。。。。。。\n跳 过\r尾 行";
        let expected = "第一章 标 题\r\n正文之间……\n跳 过\r尾行";
        for encoding in [
            EncodingKind::Utf8,
            EncodingKind::Utf16Le,
            EncodingKind::Utf16Be,
            EncodingKind::Utf32Le,
            EncodingKind::Utf32Be,
            EncodingKind::Cp936,
        ] {
            let bom = encoding != EncodingKind::Cp936;
            let bytes = encode(raw, encoding, bom).unwrap();
            let source =
                SourceSnapshot::from_bytes(bytes.clone(), EncodingMode::Auto, RULE_ID, || false)
                    .unwrap();
            let req = json!({"kind":"cleanup","skip_lines":[3],"pipeline":[
                configured(json!({"kind":"ocr_han_spaces"}),true,"body"),
                configured(json!({"kind":"ocr_ellipsis"}),true,"body"),
                configured(json!({"kind":"literal_replace","find":"正文","replace":"不应替换"}),false,"all")
            ]});
            let plan = prepare(&source, &req.to_string()).unwrap();
            assert_eq!(
                plan.output(&source).unwrap(),
                encode(expected, encoding, bom).unwrap()
            );
            assert!(plan.stages.iter().all(|s| s["step_index"] != 2));
            assert_eq!(source.original_bytes(), bytes);
            let headings = json!({"kind":"cleanup","pipeline":[configured(json!({"kind":"literal_replace","find":"标 题","replace":"标题"}),true,"headings")]});
            let plan = prepare(&source, &headings.to_string()).unwrap();
            assert_eq!(plan.text, raw.replacen("标 题", "标题", 1));
        }
    }
    #[test]
    fn invisible_cleanup_keeps_joiners_and_order_is_observable() {
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n正\u{200b} 文 👩\u{200d}💻 ا\u{200c}ب e\u{301}"
                .as_bytes()
                .to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let invisible = configured(json!({"kind":"remove_invisible"}), true, "body");
        let gaps = configured(json!({"kind":"ocr_han_spaces"}), true, "body");
        let a = prepare(
            &source,
            &json!({"kind":"cleanup","pipeline":[invisible,gaps]}).to_string(),
        )
        .unwrap();
        let b = prepare(
            &source,
            &json!({"kind":"cleanup","pipeline":[gaps,invisible]}).to_string(),
        )
        .unwrap();
        assert_eq!(a.text, "第一章 甲\n正文 👩\u{200d}💻 ا\u{200c}ب e\u{301}");
        assert_eq!(b.text, "第一章 甲\n正 文 👩\u{200d}💻 ا\u{200c}ب e\u{301}");
        assert_ne!(a.id(), b.id());
    }
    #[test]
    fn disabled_notice_selection_is_preserved_and_invalid_dormant_rules_are_rejected() {
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n广告：示例\n正文".as_bytes().to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let mut req = json!({"kind":"cleanup","remove_lines":[2],"pipeline":[configured(json!({"kind":"remove_ad_lines"}),false,"all")]});
        let off = prepare(&source, &req.to_string()).unwrap();
        assert!(off.changes.is_empty());
        assert_eq!(off.candidates[0]["selected"], true);
        req["pipeline"][0]["enabled"] = json!(true);
        let on = prepare(&source, &req.to_string()).unwrap();
        assert_eq!(on.text, "第一章 甲\n正文");
        assert_ne!(off.id(), on.id());
        let mut bad = configured(json!({"kind":"ocr_han_spaces"}), false, "body");
        bad["original"] = json!({"kind":"regex_replace","pattern":"(","replace":""});
        for rule in [
            bad,
            configured(
                configured(json!({"kind":"ocr_han_spaces"}), true, "all"),
                true,
                "all",
            ),
            configured(
                json!({"kind":"multiline_regex_replace","pattern":"x","replace":"y"}),
                true,
                "headings",
            ),
        ] {
            assert!(
                prepare(
                    &source,
                    &json!({"kind":"cleanup","pipeline":[rule]}).to_string()
                )
                .is_err()
            );
        }
    }
    #[test]
    fn chinese_variant_preserves_six_encodings_scope_and_endings() {
        let raw = "第一章 发后\r\n头发发展，皇后后来，干燥干活。\n保持头发\r末行发展";
        let expected = "第一章 发后\r\n頭髮發展，皇后後來，乾燥幹活。\n保持头发\r末行发展";
        for encoding in [
            EncodingKind::Utf8,
            EncodingKind::Utf16Le,
            EncodingKind::Utf16Be,
            EncodingKind::Utf32Le,
            EncodingKind::Utf32Be,
            EncodingKind::Cp936,
        ] {
            let bom = encoding != EncodingKind::Cp936;
            let bytes = encode(raw, encoding, bom).unwrap();
            let source =
                SourceSnapshot::from_bytes(bytes.clone(), EncodingMode::Auto, RULE_ID, || false)
                    .unwrap();
            let request = json!({"kind":"cleanup","pipeline":[variant_rule("s2t")],"start_line":2,"end_line":3,"skip_lines":[3]});
            let plan = prepare(&source, &request.to_string()).unwrap();
            assert_eq!(
                plan.output(&source).unwrap(),
                encode(expected, encoding, bom).unwrap()
            );
            assert_eq!(source.original_bytes(), bytes);
            assert_eq!(plan.changes.len(), 1);
            assert_eq!(plan.stages[0]["source_line"], 2);
            let doc: Value = serde_json::from_slice(&plan.evidence()).unwrap();
            assert_eq!(doc["request"]["pipeline"][0], variant_rule("s2t"));
            let traditional = SourceSnapshot::from_bytes(
                encode(expected, encoding, bom).unwrap(),
                EncodingMode::Auto,
                RULE_ID,
                || false,
            )
            .unwrap();
            let reverse = prepare(
                &traditional,
                &json!({"kind":"cleanup","pipeline":[variant_rule("t2s")]}).to_string(),
            )
            .unwrap();
            assert_eq!(reverse.output(&traditional).unwrap(), bytes);
        }
    }
    #[test]
    fn chinese_variant_order_and_explicit_encoding_failure() {
        let source =
            SourceSnapshot::from_utf8("第一章 甲\n头\n发\n".as_bytes().to_vec(), RULE_ID, || false)
                .unwrap();
        let join = json!({"kind":"join_hard_wraps","min_chars":1,"mode":"chinese"});
        let a = prepare(
            &source,
            &json!({"kind":"cleanup","pipeline":[join,variant_rule("s2t")]}).to_string(),
        )
        .unwrap();
        let b = prepare(
            &source,
            &json!({"kind":"cleanup","pipeline":[variant_rule("s2t"),join]}).to_string(),
        )
        .unwrap();
        assert_eq!(a.text, "第一章 甲\n頭髮\n");
        assert_eq!(b.text, "第一章 甲\n頭發\n");
        assert_ne!(a.id(), b.id());
        let original = encode("第一章 甲\n\u{523e}", EncodingKind::Cp936, false).unwrap();
        let source =
            SourceSnapshot::from_bytes(original.clone(), EncodingMode::Auto, RULE_ID, || false)
                .unwrap();
        let plan = prepare(
            &source,
            &json!({"kind":"cleanup","pipeline":[variant_rule("s2t")]}).to_string(),
        )
        .unwrap();
        assert_eq!(plan.text, "第一章 甲\n\u{34e8}");
        assert_eq!(
            plan.output(&source).unwrap_err().code,
            ErrorCode::InvalidEncoding
        );
        assert_eq!(source.original_bytes(), original);
    }
    #[test]
    fn chinese_variant_rejects_unknown_identity_direction_and_oversized_line() {
        let source =
            SourceSnapshot::from_utf8("正文".as_bytes().to_vec(), RULE_ID, || false).unwrap();
        for rule in [
            variant_rule("unknown"),
            json!({"kind":"chinese_variant","direction":"s2t"}),
            json!({"kind":"chinese_variant","direction":"s2t","dictionary_version":"future"}),
        ] {
            assert!(
                prepare(
                    &source,
                    &json!({"kind":"cleanup","pipeline":[rule]}).to_string()
                )
                .is_err()
            );
        }
        let source =
            SourceSnapshot::from_utf8("发".repeat(22_000).into_bytes(), RULE_ID, || false).unwrap();
        let error = prepare(
            &source,
            &json!({"kind":"cleanup","pipeline":[variant_rule("s2t")]}).to_string(),
        )
        .err()
        .unwrap();
        assert_eq!(error.code, ErrorCode::TooLarge);
    }
    #[test]
    fn multiline_anchors_treat_cr_lf_and_crlf_as_complete_boundaries() {
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n甲\r\n甲\r甲\n甲".as_bytes().to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let request = json!({"kind":"cleanup","pipeline":[{"kind":"multiline_regex_replace","pattern":"^甲$","replace":"乙"}]}).to_string();
        let plan = prepare(&source, &request).unwrap();
        assert_eq!(plan.text, "第一章 甲\n乙\r\n乙\r乙\n乙");
        assert_eq!(plan.changes.len(), 4);
        let request = json!({"kind":"cleanup","pipeline":[{"kind":"multiline_regex_replace","pattern":"^","replace":"前"}]}).to_string();
        let plan = prepare(&source, &request).unwrap();
        assert_eq!(plan.text, "第一章 甲\n前甲\r\n前甲\r前甲\n前甲");
    }
    #[test]
    fn multiline_captures_escapes_zero_width_noops_and_limits() {
        let raw = "第一章 甲\n甲\\n\n乙\n末尾";
        let source = SourceSnapshot::from_utf8(raw.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let prepare_rule = |pattern: &str, replace: &str| {
            prepare(&source, &json!({"kind":"cleanup","pipeline":[{"kind":"multiline_regex_replace","pattern":pattern,"replace":replace}]}).to_string())
        };
        let changed = prepare_rule(r"(?P<a>甲\\n)\n(乙)", r"${a}\t$$\\${2}").unwrap();
        assert_eq!(changed.text, "第一章 甲\n甲\\n\t$\\乙\n末尾");
        let prefix = prepare_rule("^", "前").unwrap();
        assert_eq!(prefix.text, "第一章 甲\n前甲\\n\n前乙\n前末尾");
        assert_eq!(prefix.changes.len(), 3);
        let noop = prepare_rule(r"(?s).+", "$0").unwrap();
        assert!(noop.changes.is_empty());
        assert_eq!(noop.retained_lines().len(), 4);
        for replace in ["$unknown", r"\q", "\\"] {
            assert!(prepare_rule("甲", replace).is_err());
        }
        let large = SourceSnapshot::from_utf8(
            format!("第一章 甲\n{}", "a".repeat(256 * 1024 + 1)).into_bytes(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let rule = json!({"kind":"cleanup","pipeline":[{"kind":"multiline_regex_replace","pattern":"z","replace":"q"}]}).to_string();
        assert!(prepare(&large, &rule).is_err());
    }
    #[test]
    fn multiline_regex_expands_source_span_and_later_rules_run_per_output_line() {
        let raw = "第一章 甲\r\n甲上\r\n甲下\n未改行\r第二章 乙\n结束";
        let req = json!({"kind":"cleanup","pipeline":[
            {"kind":"multiline_regex_replace","pattern":r"甲上\r\n甲下","replace":r"合并\n新增\n三行  "},
            {"kind":"regex_replace","pattern":"^新增$","replace":"新的一行"},
            {"kind":"trim_trailing_spaces"}
        ]});
        for encoding in [
            EncodingKind::Utf8,
            EncodingKind::Utf16Le,
            EncodingKind::Utf16Be,
            EncodingKind::Utf32Le,
            EncodingKind::Utf32Be,
            EncodingKind::Cp936,
        ] {
            let bom = encoding != EncodingKind::Cp936;
            let bytes = encode(raw, encoding, bom).unwrap();
            let source =
                SourceSnapshot::from_bytes(bytes.clone(), EncodingMode::Auto, RULE_ID, || false)
                    .unwrap();
            let plan = prepare(&source, &req.to_string()).unwrap();
            assert_eq!(
                plan.output(&source).unwrap(),
                encode(
                    "第一章 甲\r\n合并\n新的一行\n三行\n未改行\r第二章 乙\n结束",
                    encoding,
                    bom
                )
                .unwrap()
            );
            assert_eq!(plan.changes.len(), 1);
            assert_eq!(plan.changes[0].source_end_line, 3);
            assert_eq!(plan.changes[0].before, "甲上\r\n甲下\n");
            assert_eq!(plan.source_ranges[1].mapping, "region");
            assert_eq!(plan.source_ranges[1].output_end_line, Some(4));
            assert!(!plan.line_map.iter().any(|(n, _)| *n == 2 || *n == 3));
            assert!(plan.line_map.contains(&(5, 6)));
            assert_eq!(source.original_bytes(), bytes);
        }
    }
    #[test]
    fn multiline_matches_do_not_cross_structural_skip_or_scope_boundaries() {
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n起始\n中间\n卷首名\n结束\n第二章 乙\n末尾"
                .as_bytes()
                .to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let pipeline = json!([{"kind":"multiline_regex_replace","pattern":"(?s)起始.*结束","replace":"删除区段"}]);
        for restrictions in [
            json!({"protected_lines":[4]}),
            json!({"skip_lines":[3]}),
            json!({"end_line":4}),
        ] {
            let mut req = restrictions;
            req["kind"] = json!("cleanup");
            req["pipeline"] = pipeline.clone();
            assert_eq!(
                prepare(&source, &req.to_string()).unwrap().text,
                source.decoded_text()
            );
        }
        let req = json!({"kind":"cleanup","pipeline":[{"kind":"multiline_regex_replace","pattern":"(?s)起始.*末尾","replace":"错误跨章"}]});
        assert_eq!(
            prepare(&source, &req.to_string()).unwrap().text,
            source.decoded_text()
        );
    }
    #[test]
    fn touched_line_grouping_preserves_unmatched_rows_and_partial_crlf_replacements() {
        let raw = "第一章 甲\n甲\r\n乙\n保留\r丙\n丁";
        let source = SourceSnapshot::from_utf8(raw.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let req = json!({"kind":"cleanup","pipeline":[{"kind":"multiline_regex_replace","pattern":r"\r(?=\n)","replace":""}]});
        assert!(prepare(&source, &req.to_string()).is_err());
        let req = json!({"kind":"cleanup","pipeline":[{"kind":"multiline_regex_replace","pattern":r"甲\r|丙\n丁","replace":"替换"}]});
        let plan = prepare(&source, &req.to_string()).unwrap();
        assert_eq!(plan.text, "第一章 甲\n替换\n乙\n保留\r替换");
        assert_eq!(plan.changes.len(), 2);
        assert_eq!(plan.changes[0].source_end_line, 3);
        assert_eq!(plan.changes[1].source_line, 5);
        assert!(plan.line_map.contains(&(4, 4)));
    }
    #[test]
    fn inserted_lines_can_be_collapsed_joined_and_replaced_in_order() {
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n占位\r\n保留。".as_bytes().to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let req = json!({"kind":"cleanup","pipeline":[
            {"kind":"multiline_regex_replace","pattern":"占位","replace":r"前行未完\r\n后行完成。\n\n\n另段"},
            {"kind":"join_hard_wraps","mode":"chinese","min_chars":4},
            {"kind":"collapse_blank_lines"}
        ]});
        let plan = prepare(&source, &req.to_string()).unwrap();
        assert_eq!(plan.text, "第一章 甲\n前行未完后行完成。\n\n另段\r\n保留。");
        assert_eq!(plan.changes[0].before, "占位\r\n");
        assert_eq!(plan.source_ranges[1].output_end_line, Some(4));
    }
    #[test]
    fn hard_wraps_preserve_content_boundaries_and_encoding_with_complete_source_spans() {
        let raw = "第一章 开始\r\n长长的中文断\r行继续未完\n尾句。\r\n\r\n第二章 继续\r下一段正文\n　缩进新段\r最后结束。";
        let request=json!({"kind":"cleanup","pipeline":[{"kind":"join_hard_wraps","mode":"chinese","min_chars":4}]}).to_string();
        let expected = "第一章 开始\r\n长长的中文断行继续未完尾句。\r\n\r\n第二章 继续\r下一段正文\n　缩进新段最后结束。";
        for encoding in [
            EncodingKind::Utf8,
            EncodingKind::Utf16Le,
            EncodingKind::Utf16Be,
            EncodingKind::Utf32Le,
            EncodingKind::Utf32Be,
            EncodingKind::Cp936,
        ] {
            let bom = encoding != EncodingKind::Cp936;
            let bytes = encode(raw, encoding, bom).unwrap();
            let source =
                SourceSnapshot::from_bytes(bytes.clone(), EncodingMode::Auto, RULE_ID, || false)
                    .unwrap();
            let result = prepare(&source, &request).unwrap();
            assert_eq!(
                result.output(&source).unwrap(),
                encode(expected, encoding, bom).unwrap()
            );
            assert_eq!(result.changes[0].source_line, 2);
            assert_eq!(result.changes[0].source_end_line, 4);
            assert_eq!(
                result.changes[0].before,
                "长长的中文断\r行继续未完\n尾句。\r\n"
            );
            assert_eq!(
                result.changes[0].after.as_deref(),
                Some("长长的中文断行继续未完尾句。\r\n")
            );
            assert_eq!(
                result.line_map,
                vec![
                    (1, 1),
                    (2, 2),
                    (3, 2),
                    (4, 2),
                    (5, 3),
                    (6, 4),
                    (7, 5),
                    (8, 6),
                    (9, 6)
                ]
            );
            assert_eq!(source.original_bytes(), bytes);
        }
    }
    #[test]
    fn join_respects_scope_skips_explicit_headings_notices_and_deleted_gaps() {
        let source=SourceSnapshot::from_utf8("这是前段\n正文第一\n正文第二\n自定卷名\n正文第三\n本章完\n正文第四\n正文第五\n正文第六".as_bytes().to_vec(),RULE_ID,||false).unwrap();
        let req = json!({"kind":"cleanup","pipeline":[{"kind":"remove_ad_lines"},{"kind":"join_hard_wraps","mode":"chinese","min_chars":2}],"start_line":2,"end_line":8,"skip_lines":[3],"protected_lines":[4],"remove_lines":[6]});
        let result = prepare(&source, &req.to_string()).unwrap();
        assert_eq!(
            result.text,
            "这是前段\n正文第一\n正文第二\n自定卷名\n正文第三\n正文第四正文第五\n正文第六"
        );
        // An unselected notice remains a boundary even without the notice rule.
        let plain = json!({"kind":"cleanup","pipeline":[{"kind":"join_hard_wraps","mode":"chinese","min_chars":2}]});
        let result = prepare(&source, &plain.to_string()).unwrap();
        assert!(result.text.contains("\n本章完\n"));
    }
    #[test]
    fn replacements_after_join_use_joined_text_and_source_span() {
        let source = SourceSnapshot::from_utf8(
            "long broken\r\nword here\r\nEnds.\nNew paragraph"
                .as_bytes()
                .to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let mut req = json!({"kind":"cleanup","pipeline":[{"kind":"join_hard_wraps","mode":"space","min_chars":4},{"kind":"literal_replace","find":"broken word","replace":"complete"}]});
        let result = prepare(&source, &req.to_string()).unwrap();
        assert_eq!(result.text, "long complete here Ends.\nNew paragraph");
        assert_eq!(result.changes[0].source_end_line, 3);
        assert_eq!(result.stages[1]["source_end_line"], 3);
        req["pipeline"].as_array_mut().unwrap().reverse();
        assert_eq!(
            prepare(&source, &req.to_string()).unwrap().text,
            "long broken word here Ends.\nNew paragraph"
        );
        req["skip_lines"] = json!([1, 2, 3]);
        assert_eq!(
            prepare(&source, &req.to_string()).unwrap().text,
            source.decoded_text()
        );
    }
    #[test]
    fn pipeline_order_and_each_stage_are_visible_and_bound_to_plan() {
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\r\n甲\r乙\n尾".as_bytes().to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let mut value = json!({"kind":"cleanup","pipeline":[
            {"kind":"literal_replace","find":"甲","replace":"乙"},
            {"kind":"literal_replace","find":"乙","replace":"丙"}
        ],"start_line":2,"end_line":3,"skip_lines":[3]});
        let a = prepare(&source, &value.to_string()).unwrap();
        assert_eq!(a.text, "第一章 甲\r\n丙\r乙\n尾");
        assert_eq!(a.changes.len(), 1);
        assert_eq!(a.stages.len(), 2);
        assert_eq!(a.stages[0]["before"], "甲");
        assert_eq!(a.stages[0]["after"], "乙");
        assert_eq!(a.stages[1]["before"], "乙");
        value["pipeline"].as_array_mut().unwrap().reverse();
        let b = prepare(&source, &value.to_string()).unwrap();
        assert_eq!(b.text, "第一章 甲\r\n乙\r乙\n尾");
        assert_ne!(a.id(), b.id());
        value["preview_offset"] = json!(40);
        assert_eq!(b.id(), prepare(&source, &value.to_string()).unwrap().id());
    }
    #[test]
    fn deletion_order_controls_blank_merging_but_not_notice_authorization() {
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n\r\n本章完\r\n\n正文".as_bytes().to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let mut value = json!({"kind":"cleanup","pipeline":[{"kind":"remove_ad_lines"},{"kind":"collapse_blank_lines"}],"remove_lines":[3]});
        let a = prepare(&source, &value.to_string()).unwrap();
        assert_eq!(a.text, "第一章 甲\n\r\n正文");
        value["pipeline"].as_array_mut().unwrap().reverse();
        let b = prepare(&source, &value.to_string()).unwrap();
        assert_eq!(b.text, "第一章 甲\n\r\n\n正文");
        // A replacement must not manufacture authority to delete original prose.
        value["pipeline"] = json!([{"kind":"literal_replace","find":"正文","replace":"本章完"},{"kind":"remove_ad_lines"}]);
        value["remove_lines"] = json!([5]);
        assert!(prepare(&source, &value.to_string()).is_err());
    }
    #[test]
    fn regex_captures_width_punctuation_and_encoding_roundtrip() {
        let raw = "第一章 甲\r\nＡ１２　﹗ e\u{301} 😀\r尾文";
        let request=json!({"kind":"cleanup","pipeline":[
            {"kind":"normalize_width"},{"kind":"normalize_punctuation"},
            {"kind":"regex_replace","pattern":"(?<letter>[A-Z])(?<n>[0-9]+)","replace":"${n}-$letter-$$"}
        ]}).to_string();
        for encoding in [
            EncodingKind::Utf8,
            EncodingKind::Utf16Le,
            EncodingKind::Utf16Be,
            EncodingKind::Utf32Le,
            EncodingKind::Utf32Be,
        ] {
            let bytes = encode(raw, encoding, true).unwrap();
            let source =
                SourceSnapshot::from_bytes(bytes.clone(), EncodingMode::Auto, RULE_ID, || false)
                    .unwrap();
            let result = prepare(&source, &request).unwrap();
            assert_eq!(
                result.output(&source).unwrap(),
                encode("第一章 甲\r\n12-A-$ ！ e\u{301} 😀\r尾文", encoding, true).unwrap()
            );
            assert_eq!(source.original_bytes(), bytes);
            assert_eq!(result.stages.len(), 3);
        }
    }
    #[test]
    fn invalid_rules_and_expansion_fail_without_partial_output() {
        let source =
            SourceSnapshot::from_utf8("第一章 甲\n正文".as_bytes().to_vec(), RULE_ID, || {
                false
            })
            .unwrap();
        for rule in [
            json!({"kind":"regex_replace","pattern":"(","replace":""}),
            json!({"kind":"regex_replace","pattern":"(?<=甲)乙","replace":""}),
            json!({"kind":"regex_replace","pattern":"(甲)","replace":"$missing"}),
            json!({"kind":"literal_replace","find":"","replace":"乙"}),
            json!({"kind":"literal_replace","find":"甲","replace":"乙\n丙"}),
        ] {
            assert!(
                prepare(
                    &source,
                    &json!({"kind":"cleanup","pipeline":[{"kind":"normalize_width"},rule]})
                        .to_string()
                )
                .is_err()
            );
        }
        let source =
            SourceSnapshot::from_utf8("甲".repeat(300).into_bytes(), RULE_ID, || false).unwrap();
        let req = json!({"kind":"cleanup","pipeline":[{"kind":"literal_replace","find":"甲","replace":"x".repeat(4096)}]});
        assert_eq!(
            prepare(&source, &req.to_string()).err().unwrap().code,
            ErrorCode::TooLarge
        );
        let too_many =
            json!({"kind":"cleanup","pipeline":vec![json!({"kind":"normalize_width"});33]});
        assert!(prepare(&source, &too_many.to_string()).is_err());
    }
    #[test]
    fn preserves_mixed_endings_and_only_removes_explicit_notices() {
        let raw = "第一章 甲  \r\n\r\n\n他说请收藏这个盒子。\r广告：站点\n本章完\r\n尾文\r";
        for encoding in [
            EncodingKind::Utf8,
            EncodingKind::Utf16Le,
            EncodingKind::Utf16Be,
            EncodingKind::Utf32Le,
            EncodingKind::Utf32Be,
            EncodingKind::Cp936,
        ] {
            let bom = encoding != EncodingKind::Cp936;
            let bytes = encode(raw, encoding, bom).unwrap();
            let source =
                SourceSnapshot::from_bytes(bytes.clone(), EncodingMode::Auto, RULE_ID, || false)
                    .unwrap();
            let req = r#"{"kind":"cleanup","rules":["trim_trailing_spaces","collapse_blank_lines","remove_ad_lines"],"remove_lines":[5]}"#;
            let plan = prepare(&source, req).unwrap();
            assert_eq!(
                plan.output(&source).unwrap(),
                encode(
                    "第一章 甲\r\n\r\n他说请收藏这个盒子。\r本章完\r\n尾文\r",
                    encoding,
                    bom
                )
                .unwrap()
            );
            assert_eq!(source.original_bytes(), bytes);
            assert_eq!(plan.candidates.len(), 2);
            assert_eq!(plan.changes.len(), 3);
            assert!(
                prepare(
                    &source,
                    r#"{"kind":"cleanup","rules":["remove_ad_lines"],"remove_lines":[4]}"#
                )
                .is_err()
            );
        }
    }
    #[test]
    fn scope_skips_noop_and_pages_are_bound_to_actual_changes() {
        let source = SourceSnapshot::from_utf8(
            "第一章 甲  \n甲 \n乙 \n本章完".as_bytes().to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let req = r#"{"kind":"cleanup","rules":["trim_trailing_spaces"],"start_line":2,"end_line":3,"skip_lines":[2]}"#;
        let a = prepare(&source, req).unwrap();
        assert_eq!(a.text, "第一章 甲  \n甲 \n乙\n本章完");
        let mut v: Value = serde_json::from_str(req).unwrap();
        v["preview_offset"] = json!(40);
        assert_eq!(a.id(), prepare(&source, &v.to_string()).unwrap().id());
        v["skip_lines"] = json!([]);
        assert_ne!(a.id(), prepare(&source, &v.to_string()).unwrap().id());
        let unchanged =
            prepare(&source, r#"{"kind":"cleanup","rules":["remove_ad_lines"]}"#).unwrap();
        assert!(unchanged.changes.is_empty());
        assert_eq!(unchanged.output(&source).unwrap(), source.original_bytes());
        assert!(prepare(&source, r#"{"kind":"cleanup","rules":["regex"]}"#).is_err());
        assert!(
            prepare(
                &source,
                r#"{"kind":"cleanup","rules":["trim_trailing_spaces"],"start_line":0}"#
            )
            .is_err()
        );
    }
}

#[cfg(test)]
mod explicit_empty_pipeline_tests {
    use super::*;
    #[test]
    fn empty_pipeline_is_a_serializable_noop_not_missing_input_or_legacy_rules() {
        let empty: Request =
            serde_json::from_value(json!({"kind":"cleanup","pipeline":[]})).unwrap();
        assert!(empty.ordered_rules().unwrap().is_empty());
        assert_eq!(serde_json::to_value(&empty).unwrap()["pipeline"], json!([]));
        let missing: Request = serde_json::from_value(json!({"kind":"cleanup"})).unwrap();
        assert!(missing.ordered_rules().is_err());
        let legacy: Request=serde_json::from_value(json!({"kind":"cleanup","rules":["collapse_blank_lines","remove_ad_lines","trim_trailing_spaces"]})).unwrap();
        assert_eq!(
            serde_json::to_value(legacy.ordered_rules().unwrap()).unwrap(),
            json!([{"kind":"trim_trailing_spaces"},{"kind":"remove_ad_lines"},{"kind":"collapse_blank_lines"}])
        );
        let ambiguous: Request = serde_json::from_value(
            json!({"kind":"cleanup","rules":["trim_trailing_spaces"],"pipeline":[]}),
        )
        .unwrap();
        assert!(ambiguous.ordered_rules().is_err());
    }
}

#[cfg(test)]
mod legacy_option_presets_tests {
    use super::*;
    #[test]
    fn eleven_options_are_independent_valid_and_reach_real_cleanup() {
        let presets = crate::cleanup_rules::presets();
        let choices: Vec<_> = presets
            .as_array()
            .unwrap()
            .iter()
            .filter(|p| p["legacy_option"].is_string())
            .collect();
        assert_eq!(choices.len(), 11);
        let keys: BTreeSet<_> = choices
            .iter()
            .map(|p| p["legacy_option"].as_str().unwrap())
            .collect();
        assert_eq!(keys.len(), 11);
        let raw = "第1章 开始\n这 是正文,标点。　　后段\n不可见\u{200b}文字　空白  \n\n\n广告：下载小说\n第 12 页\n第二章 后续\n第二章 后续\n他走过长长的街道来到河边终于看见\n了远方的灯火。\n";
        let source =
            SourceSnapshot::from_utf8(raw.as_bytes().to_vec(), crate::source::RULE_ID, || false)
                .unwrap();
        for p in choices {
            let request = json!({"kind":"cleanup","pipeline":p["rules"]});
            let plan = prepare(&source, &request.to_string()).unwrap();
            assert!(
                !plan.changes.is_empty() || !plan.candidates.is_empty(),
                "{}",
                p["legacy_option"]
            );
            assert_eq!(source.original_bytes(), raw.as_bytes());
            if matches!(
                p["legacy_option"].as_str().unwrap(),
                "RemoveSiteNotices" | "RemoveRepeatedHeaders"
            ) {
                assert_eq!(plan.text, raw);
                assert!(!plan.candidates.is_empty());
            }
        }
    }
}
