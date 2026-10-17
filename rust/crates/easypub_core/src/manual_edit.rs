//! Manual edits resolve against immutable source coordinates before any rendering.
use crate::{
    ApiError, ErrorCode,
    recognition::is_default_heading,
    source::{SourceSnapshot, numbered_heading},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;

#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum Action {
    RepairNumberTypo {
        source_line: u32,
        title: String,
    },
    MoveVolume {
        source_line: u32,
        before_line: u32,
    },
    MoveChapter {
        source_line: u32,
        before_line: u32,
    },
    ExcludeLines {
        source_line: u32,
        end_line: u32,
    },
    RenameTitle {
        source_line: u32,
        title: String,
    },
    SetVolume {
        source_line: u32,
        volume_title: String,
    },
    SplitChapter {
        source_line: u32,
        title: String,
    },
    MergePrevious {
        source_line: u32,
    },
}
impl Action {
    fn line(&self) -> u32 {
        match self {
            Self::RepairNumberTypo { source_line, .. }
            | Self::RenameTitle { source_line, .. }
            | Self::SetVolume { source_line, .. }
            | Self::SplitChapter { source_line, .. }
            | Self::MergePrevious { source_line }
            | Self::MoveChapter { source_line, .. }
            | Self::MoveVolume { source_line, .. }
            | Self::ExcludeLines { source_line, .. } => *source_line,
        }
    }
    fn kind(&self) -> &'static str {
        match self {
            Self::RepairNumberTypo { .. } => "repair_number_typo",
            Self::RenameTitle { .. } => "rename_title",
            Self::SetVolume { .. } => "set_volume",
            Self::SplitChapter { .. } => "split_chapter",
            Self::MergePrevious { .. } => "merge_previous",
            Self::MoveChapter { .. } => "move_chapter",
            Self::MoveVolume { .. } => "move_volume",
            Self::ExcludeLines { .. } => "exclude_lines",
        }
    }
    fn title(&self) -> &str {
        match self {
            Self::RepairNumberTypo { title, .. }
            | Self::RenameTitle { title, .. }
            | Self::SplitChapter { title, .. } => title.trim(),
            Self::SetVolume { volume_title, .. } => volume_title.trim(),
            Self::MergePrevious { .. }
            | Self::MoveChapter { .. }
            | Self::MoveVolume { .. }
            | Self::ExcludeLines { .. } => "",
        }
    }
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    kind: String,
    actions: Vec<Action>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    structure: Option<crate::structure::Structure>,
}

/// Archived actions retain their schema without requiring today's structure.
/// Applying a version still goes through prepare_with_structure.
pub fn validate_action_shapes(actions: &[Value]) -> Result<(), ApiError> {
    serde_json::from_value::<Vec<Action>>(Value::Array(actions.to_vec()))
        .map(|_| ())
        .map_err(|_| invalid("use_supported_manual_action"))
}
#[derive(Clone, Serialize)]
struct Patch {
    start: usize,
    end: usize,
    text: String,
    source_line: u32,
    kind: &'static str,
}
pub struct Prepared {
    moves: Vec<(usize, usize, usize, u32)>,
    request: Request,
    structure: Option<crate::structure::Structure>,
    stationary_volumes: BTreeSet<u32>,
    patches: Vec<Patch>,
    evidence_patches: Vec<Patch>,
    actions: Vec<Value>,
    source_id: String,
    revision: u32,
}
fn invalid(message: &str) -> ApiError {
    ApiError::new(ErrorCode::InvalidRule, "manual_edit", message)
}
fn volume(title: &str) -> bool {
    numbered_heading(title).is_some_and(|(_, c)| matches!(c, '卷' | '部' | '篇' | '集'))
}
fn clipped(s: &str) -> String {
    s.chars().take(500).collect()
}

pub fn prepare(source: &SourceSnapshot, selected: &str) -> Result<Prepared, ApiError> {
    prepare_with_structure(source, selected, None)
}

pub fn prepare_with_structure(
    source: &SourceSnapshot,
    selected: &str,
    structure: Option<&crate::structure::Structure>,
) -> Result<Prepared, ApiError> {
    if selected.len() > 1024 * 1024 {
        return Err(invalid("reduce_edit_batch"));
    }
    let mut request: Request =
        serde_json::from_str(selected).map_err(|_| invalid("use_supported_manual_action"))?;
    let embedded = request.structure.take();
    if let (Some(provided), Some(selected)) = (structure, embedded.as_ref())
        && provided != selected {
            return Err(invalid("review_changed_structure"));
        }
    let structure = structure.or(embedded.as_ref());
    if request.kind != "manual_batch" || request.actions.is_empty() || request.actions.len() > 500 {
        return Err(invalid("select_bounded_manual_actions"));
    }
    let lines = source.decoded_line_ranges();
    let raw = source.decoded_text();
    struct Heading {
        source_line: u32,
        title: String,
        is_volume: bool,
    }
    let headings = if let Some(structure) = structure {
        structure
            .tree(source)?
            .nodes
            .into_iter()
            .map(|n| Heading {
                source_line: n.source_line,
                title: n.title,
                is_volume: n.role == crate::structure::Role::Volume,
            })
            .collect::<Vec<_>>()
    } else {
        source
            .headings()
            .iter()
            .map(|h| Heading {
                source_line: h.source_line,
                title: h.title.clone(),
                is_volume: volume(&h.title),
            })
            .collect()
    };
    let mut keys = BTreeSet::new();
    let mut merge_lines = BTreeSet::new();
    for action in &request.actions {
        if !keys.insert((action.line(), action.kind())) {
            return Err(invalid("resolve_conflicting_line_edits"));
        }
        if matches!(action, Action::MergePrevious { .. }) {
            merge_lines.insert(action.line());
        }
    }
    let excludes = request
        .actions
        .iter()
        .filter_map(|a| {
            if let Action::ExcludeLines {
                source_line,
                end_line,
            } = a
            {
                Some((*source_line, *end_line))
            } else {
                None
            }
        })
        .collect::<Vec<_>>();
    for &(first, last) in &excludes {
        if first == 0 || first > last || last as usize > lines.len() {
            return Err(invalid("choose_valid_exclusion_range"));
        }
    }
    let moving = request
        .actions
        .iter()
        .any(|a| matches!(a, Action::MoveChapter { .. } | Action::MoveVolume { .. }));
    if moving && !merge_lines.is_empty() {
        return Err(invalid("review_moves_and_merges_in_separate_batches"));
    }
    // Compute final structural boundaries for merge targets, including inserted
    // splits and volumes. A merge cannot accidentally cross a new volume boundary.
    let mut boundaries = headings
        .iter()
        .filter(|h| {
            !merge_lines.contains(&h.source_line)
                && !excludes
                    .iter()
                    .any(|&(a, b)| h.source_line >= a && h.source_line <= b)
        })
        .map(|h| (h.source_line, h.title.clone(), h.is_volume))
        .collect::<Vec<_>>();
    for action in &request.actions {
        match action {
            Action::RenameTitle { source_line, title } => {
                if let Some(h) = boundaries.iter_mut().find(|h| h.0 == *source_line) {
                    h.1 = title.trim().to_owned();
                    if structure.is_none() {
                        h.2 = volume(title);
                    }
                }
            }
            Action::SetVolume { source_line, .. } => {
                boundaries.push((*source_line, action.title().into(), true))
            }
            Action::RepairNumberTypo { source_line, .. }
            | Action::SplitChapter { source_line, .. } => {
                boundaries.push((*source_line, action.title().into(), false))
            }
            _ => {}
        }
    }
    // Inserted volumes precede a chapter at the same original line.
    boundaries.sort_by_key(|h| (h.0, !h.2));
    let mut patches = Vec::new();
    let mut previews = Vec::new();
    let number_typos = if request
        .actions
        .iter()
        .any(|a| matches!(a, Action::RepairNumberTypo { .. }))
    {
        crate::heading_typos::find(source)
    } else {
        Vec::new()
    };
    let mut moves = Vec::<(usize, usize, usize, u32)>::new();
    for action in &request.actions {
        let n = action.line();
        let &(start, end) = n
            .checked_sub(1)
            .and_then(|n| lines.get(n as usize))
            .ok_or_else(|| invalid("choose_source_line"))?;
        let original = &raw[start..end];
        let next = lines
            .get(n as usize)
            .map(|&(start, _)| start)
            .unwrap_or(raw.len());
        let ending = &raw[end..next];
        let newline = if ending == "\r\n" {
            "\r\n"
        } else if ending == "\r" {
            "\r"
        } else {
            "\n"
        };
        let heading = headings.iter().find(|h| h.source_line == n);
        let title = action.title();
        if !matches!(
            action,
            Action::MergePrevious { .. }
                | Action::MoveChapter { .. }
                | Action::MoveVolume { .. }
                | Action::ExcludeLines { .. }
        ) && (title.is_empty() || title.len() > 4096 || title.contains(['\r', '\n']))
        {
            return Err(invalid("use_single_line_title"));
        }
        if merge_lines.contains(&n) && !matches!(action, Action::MergePrevious { .. }) {
            return Err(invalid("resolve_merge_title_conflict"));
        }
        if !matches!(action, Action::ExcludeLines { .. })
            && excludes.iter().any(|&(a, b)| n >= a && n <= b)
        {
            return Err(invalid("resolve_excluded_action_conflict"));
        }
        let (patch_end, text, context) = match action {
            Action::RepairNumberTypo { .. } => {
                let candidate = number_typos
                    .iter()
                    .find(|c| c.source_line == n && c.title.trim() == title)
                    .ok_or_else(|| invalid("confirm_current_number_typo_candidate"))?;
                if heading.is_some()
                    || structure.is_some_and(|s| s.overrides.iter().any(|o| o.source_line == n))
                    || request.actions.iter().any(|a| {
                        a.line() == n
                            && !matches!(
                                a,
                                Action::RepairNumberTypo { .. } | Action::MoveChapter { .. }
                            )
                    })
                {
                    return Err(invalid("review_heading_classification_before_typo_repair"));
                }
                (
                    end,
                    candidate.title.clone(),
                    format!(
                        "仅替换源行 {n} 的编号；前后标题位于源行 {} / {}，候选编号 {}。正文和标题其余文字保留。",
                        candidate.previous_line, candidate.next_line, candidate.number
                    ),
                )
            }
            Action::MoveChapter { before_line, .. } | Action::MoveVolume { before_line, .. } => {
                let whole_volume = matches!(action, Action::MoveVolume { .. });
                if excludes
                    .iter()
                    .any(|&(a, b)| *before_line >= a && *before_line <= b)
                {
                    return Err(invalid("move_target_is_excluded"));
                }
                let index = boundaries
                    .iter()
                    .position(|h| h.0 == n && h.2 == whole_volume)
                    .ok_or_else(|| {
                        invalid(if whole_volume {
                            "move_requires_volume_heading"
                        } else {
                            "move_requires_chapter_heading"
                        })
                    })?;
                let next_heading = boundaries
                    .iter()
                    .skip(index + 1)
                    .find(|h| h.0 > n && (!whole_volume || h.2));
                let stop = next_heading
                    .map(|h| lines[h.0 as usize - 1].0)
                    .unwrap_or(raw.len());
                let target = if *before_line as usize == lines.len() + 1 {
                    raw.len()
                } else {
                    let h = boundaries
                        .iter()
                        .find(|h| h.0 == *before_line && (!whole_volume || h.2))
                        .ok_or_else(|| invalid("move_before_heading_or_end"))?;
                    lines[h.0 as usize - 1].0
                };
                if target >= start && target <= stop {
                    return Err(invalid("move_target_inside_or_unchanged"));
                }
                moves.push((start, stop, target, n));
                previews.push(json!({"id":format!("manual:{n}:{}", action.kind()),"kind":action.kind(),"before":original,"title":format!("移到源行 {before_line} 之前"),"source_lines":[n],"before_line":before_line,
                    "evidence":format!("移动完整{}区段：源行 {n} 至 {}；原有正文随章移动，不复制第二份。若拼接处缺少换行会补一个换行分隔。",if whole_volume { "卷" } else { "章节" },next_heading.map(|h|h.0-1).unwrap_or(lines.len() as u32)),"requires_confirmation":true,"auto_applicable":false}));
                continue;
            }
            Action::ExcludeLines { end_line, .. } => {
                let stop = lines
                    .get(*end_line as usize)
                    .map(|&(start, _)| start)
                    .unwrap_or(raw.len());
                if stop == start {
                    return Err(invalid("exclude_nonempty_source_range"));
                }
                (
                    stop,
                    String::new(),
                    format!(
                        "排除源行 {n} 至 {end_line}（含首尾），共 {} 行；完整内容写入变更清单",
                        end_line - n + 1
                    ),
                )
            }
            Action::RenameTitle { .. } => {
                if heading.is_none() {
                    return Err(invalid("select_recognized_heading"));
                }
                (end, title.to_owned(), String::new())
            }
            Action::SetVolume { .. } => {
                if heading.is_none() {
                    return Err(invalid("select_recognized_heading"));
                }
                (
                    start,
                    format!("{title}{newline}"),
                    "插入卷名，后方原标题及正文保留".into(),
                )
            }
            Action::SplitChapter { .. } => {
                if heading.is_some()
                    || original.trim().is_empty()
                    || !is_default_heading(title)
                    || volume(title)
                {
                    return Err(invalid("split_at_body_line_with_chapter_title"));
                }
                (
                    start,
                    format!("{title}{newline}"),
                    "在此正文行前建立章节边界，原行完整保留".into(),
                )
            }
            Action::MergePrevious { .. } => {
                let current = heading
                    .filter(|h| !h.is_volume)
                    .ok_or_else(|| invalid("merge_requires_chapter_heading"))?;
                let previous = boundaries
                    .iter()
                    .rev()
                    .find(|h| h.0 < n)
                    .filter(|h| !h.2)
                    .ok_or_else(|| invalid("merge_requires_previous_chapter_in_same_volume"))?;
                (
                    next,
                    String::new(),
                    format!(
                        "合并“{}”到“{}”；只排除此标题行，正文顺序不变",
                        current.title, previous.1
                    ),
                )
            }
        };
        previews.push(json!({"id":format!("manual:{n}:{}",action.kind()),"kind":action.kind(),"before":clipped(if matches!(action,Action::ExcludeLines{..}) {&raw[start..patch_end]}else{original}),"title":if matches!(action,Action::MergePrevious{..}) {"（移除此标题行，正文归入前章）"} else if matches!(action,Action::ExcludeLines{..}) {"（排除此范围，保留原稿和完整清单）"} else {title},
            "source_lines":if let Action::ExcludeLines{end_line,..}=action {vec![n,*end_line]} else {vec![n]},"evidence":context,"auto_applicable":false,"requires_confirmation":true,"excludes_heading":matches!(action,Action::MergePrevious{..})}));
        patches.push(Patch {
            start,
            end: patch_end,
            text,
            source_line: n,
            kind: action.kind(),
        });
    }
    patches.sort_by_key(|p| (p.start, p.end, p.kind != "move_destination"));
    let mut consumed = 0;
    for patch in &patches {
        if patch.start < consumed {
            return Err(invalid("resolve_overlapping_edits"));
        }
        consumed = patch.end;
    }
    let mut evidence_patches = patches.clone();
    // Resolve moved chunks with any edits wholly contained in them, then remove
    // the original chunk. Destination anchors must remain outside other moves.
    moves.sort_by_key(|m| m.0);
    for (i, &(start, stop, target, _)) in moves.iter().enumerate() {
        if i > 0 && moves[i - 1].1 > start {
            return Err(invalid("resolve_overlapping_moves"));
        }
        if moves
            .iter()
            .enumerate()
            .any(|(j, &(a, b, _, _))| j != i && target >= a && target < b)
        {
            return Err(invalid("choose_stationary_move_target"));
        }
        if patches.iter().any(|p| {
            (p.start < start && p.end > start)
                || (p.start < stop && p.end > stop)
                || (p.start < target && p.end > target)
        }) {
            return Err(invalid("resolve_move_edit_overlap"));
        }
    }
    let stationary_volumes = request
        .actions
        .iter()
        .filter_map(|a| {
            if let Action::MoveChapter { source_line, .. } = a {
                Some(*source_line)
            } else {
                None
            }
        })
        .collect::<BTreeSet<_>>();
    let travels =
        |p: &Patch| !(p.kind == "set_volume" && stationary_volumes.contains(&p.source_line));
    let mut resolved = Vec::new();
    for &(start, stop, target, n) in &moves {
        let contained = patches
            .iter()
            .filter(|p| p.start >= start && p.start < stop && travels(p))
            .collect::<Vec<_>>();
        let mut chunk = String::new();
        let mut cursor = start;
        for p in contained {
            chunk.push_str(&raw[cursor..p.start]);
            chunk.push_str(&p.text);
            cursor = p.end;
        }
        chunk.push_str(&raw[cursor..stop]);
        let mut join = String::new();
        if target == raw.len() && !raw.ends_with(['\r', '\n']) {
            join.push('\n');
        }
        join.push_str(&chunk);
        if target < raw.len() && !chunk.ends_with(['\r', '\n']) {
            join.push('\n');
        }
        resolved.push(Patch {
            start,
            end: stop,
            text: String::new(),
            source_line: n,
            kind: "move_source",
        });
        resolved.push(Patch {
            start: target,
            end: target,
            text: join,
            source_line: n,
            kind: "move_destination",
        });
    }
    patches.retain(|p| {
        !moves
            .iter()
            .any(|&(a, b, _, _)| p.start >= a && p.start < b && travels(p))
    });
    evidence_patches.extend(resolved.iter().cloned());
    patches.extend(resolved);
    patches.sort_by_key(|p| (p.start, p.end, p.kind != "move_destination"));
    let summary = source.summary();
    Ok(Prepared {
        moves,
        request,
        structure: structure.cloned(),
        stationary_volumes,
        patches,
        evidence_patches,
        actions: previews,
        source_id: summary.source_id,
        revision: summary.revision,
    })
}
impl Prepared {
    /// Project source-line anchors through the same patches used for byte output.
    /// Deleted anchors disappear; moved anchors travel with their complete chunk.
    pub fn projection(&self, source: &SourceSnapshot) -> Result<Projection, ApiError> {
        self.output(source)?;
        let raw = source.decoded_text();
        let mut result = Projection {
            text: String::new(),
            anchors: Vec::new(),
        };
        let originals = source
            .decoded_line_ranges()
            .iter()
            .enumerate()
            .map(|(i, &(s, _))| (s, i as u32 + 1))
            .collect::<std::collections::BTreeMap<_, _>>();
        fn copy(
            result: &mut Projection,
            raw: &str,
            originals: &std::collections::BTreeMap<usize, u32>,
            start: usize,
            end: usize,
        ) {
            for (&pos, &line) in originals.range(start..end) {
                result.anchors.push(Anchor {
                    source_line: line,
                    output_start: result.text.len() + pos - start,
                    inserted: None,
                });
            }
            result.text.push_str(&raw[start..end]);
        }
        fn patch(result: &mut Projection, p: &Patch) {
            if p.kind == "repair_number_typo" {
                result.anchors.push(Anchor {
                    source_line: p.source_line,
                    output_start: result.text.len(),
                    inserted: Some("split_chapter"),
                });
            }
            if p.kind == "rename_title" {
                result.anchors.push(Anchor {
                    source_line: p.source_line,
                    output_start: result.text.len(),
                    inserted: None,
                });
            }
            if matches!(p.kind, "split_chapter" | "set_volume") {
                result.anchors.push(Anchor {
                    source_line: p.source_line,
                    output_start: result.text.len(),
                    inserted: Some(p.kind),
                });
            }
            result.text.push_str(&p.text);
        }
        let mut cursor = 0;
        for p in &self.patches {
            copy(&mut result, raw, &originals, cursor, p.start);
            if p.kind == "move_destination" {
                let &(start, stop, target, _) = self
                    .moves
                    .iter()
                    .find(|m| m.3 == p.source_line)
                    .expect("prepared move");
                let base = result.text.len();
                if target == raw.len() && !raw.ends_with(['\r', '\n']) {
                    result.text.push('\n');
                }
                let mut inside = start;
                for child in self.evidence_patches.iter().filter(|c| {
                    !matches!(c.kind, "move_source" | "move_destination")
                        && c.start >= start
                        && c.start < stop
                        && !(c.kind == "set_volume"
                            && self.stationary_volumes.contains(&c.source_line))
                }) {
                    copy(&mut result, raw, &originals, inside, child.start);
                    patch(&mut result, child);
                    inside = child.end;
                }
                copy(&mut result, raw, &originals, inside, stop);
                if result.text.len() - base < p.text.len() {
                    result.text.push('\n');
                }
                if result.text[base..] != p.text {
                    return Err(invalid("projection_must_match_output"));
                }
            } else {
                patch(&mut result, p);
            }
            cursor = p.end;
        }
        copy(&mut result, raw, &originals, cursor, raw.len());
        if source.encode_edited_text(&result.text)? != self.output(source)? {
            return Err(invalid("projection_must_match_output"));
        }
        Ok(result)
    }
    fn id(&self) -> String {
        let mut h = Sha256::new();
        h.update(b"manual-patches-v4");
        h.update(self.source_id.as_bytes());
        h.update(self.revision.to_le_bytes());
        h.update(serde_json::to_vec(&self.request).expect("typed actions"));
        h.update(serde_json::to_vec(&self.structure).expect("validated structure"));
        format!("{:x}", h.finalize())
    }
    pub fn preview(&self) -> String {
        json!({"plan_id":self.id(),"source_id":self.source_id,"revision":self.revision,"stage":"preview","writes":false,"source_unchanged":true,"requires_confirmation":true,"actions":self.actions}).to_string()
    }
    pub fn output(&self, source: &SourceSnapshot) -> Result<Vec<u8>, ApiError> {
        if source.summary().source_id != self.source_id
            || source.summary().revision != self.revision
        {
            return Err(ApiError::new(
                ErrorCode::StaleRevision,
                "manual_edit",
                "reopen_preview",
            ));
        }
        let raw = source.decoded_text();
        let mut text = String::with_capacity(raw.len());
        let mut cursor = 0;
        for p in &self.patches {
            text.push_str(&raw[cursor..p.start]);
            text.push_str(&p.text);
            cursor = p.end;
        }
        text.push_str(&raw[cursor..]);
        source.encode_edited_text(&text)
    }
    pub fn evidence(&self, source: &SourceSnapshot) -> Vec<u8> {
        let changes=self.evidence_patches.iter().map(|p|json!({"source_line":p.source_line,"kind":p.kind,"before":&source.decoded_text()[p.start..p.end],"after":p.text,"source_utf8_start":p.start,"source_utf8_end":p.end})).collect::<Vec<_>>();
        serde_json::to_vec(&json!({"schema":1,"kind":"manual_batch","source_id":self.source_id,"revision":self.revision,"plan_id":self.id(),"actions":self.request.actions,"structure":self.structure,"changes":changes})).expect("evidence")
    }
}

pub struct Anchor {
    pub source_line: u32,
    pub output_start: usize,
    pub inserted: Option<&'static str>,
}
pub struct Projection {
    pub text: String,
    pub anchors: Vec<Anchor>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        encoding::{EncodingKind, EncodingMode, encode},
        source::RULE_ID,
    };
    fn source(raw: &str) -> SourceSnapshot {
        SourceSnapshot::from_utf8(raw.as_bytes().to_vec(), RULE_ID, || false).unwrap()
    }
    fn request(actions: Value) -> String {
        json!({"kind":"manual_batch","actions":actions}).to_string()
    }
    #[test]
    fn explicit_number_typo_repair_is_single_line_and_creates_effective_chapter() {
        let raw = "第一百一十八章 前\n久字正文\n第一百一十久章 名字久\n这一章正文久\n第一百二十章 后\n后文\n";
        let s = source(raw);
        let req = request(
            json!([{"kind":"repair_number_typo","source_line":3,"title":"第一百一十九章 名字久"}]),
        );
        let plan = prepare(&s, &req).unwrap();
        let expected = raw.replacen("第一百一十久章", "第一百一十九章", 1);
        assert_eq!(plan.output(&s).unwrap(), expected.as_bytes());
        let projection = plan.projection(&s).unwrap();
        let book = crate::publication::compose_projection(
            &s,
            &crate::structure::Structure::new(&s),
            projection,
        )
        .unwrap();
        assert_eq!(book.text, expected);
        assert_eq!(book.tree.nodes.len(), 3);
        for (line, title) in [(2, "第一百一十九章 名字久"), (3, "第一百一十九章 改其他字")]
        {
            assert!(
                prepare(
                    &s,
                    &request(
                        json!([{"kind":"repair_number_typo","source_line":line,"title":title}])
                    )
                )
                .is_err()
            );
        }
        assert!(
            prepare(
                &s,
                &request(json!([
                    {"kind":"repair_number_typo","source_line":3,"title":"第一百一十九章 名字久"},
                    {"kind":"split_chapter","source_line":3,"title":"第119章 新"}
                ]))
            )
            .is_err()
        );
        assert_eq!(s.original_bytes(), raw.as_bytes());
    }
    #[test]
    fn inserted_boundaries_support_moves_without_stealing_adjacent_body() {
        let raw = "第一章 甲\n甲上\n甲下\n第二章 乙\n乙文\n第三章 丙\n丙文\n";
        let s = source(raw);
        let cases = [
            (
                json!([
                    {"kind":"split_chapter","source_line":3,"title":"第二章 新章"},
                    {"kind":"move_chapter","source_line":3,"before_line":1}
                ]),
                "第二章 新章\n甲下\n第一章 甲\n甲上\n第二章 乙\n乙文\n第三章 丙\n丙文\n",
            ),
            (
                json!([
                    {"kind":"set_volume","source_line":1,"volume_title":"启程"},
                    {"kind":"set_volume","source_line":4,"volume_title":"归来"},
                    {"kind":"move_volume","source_line":4,"before_line":1}
                ]),
                "归来\n第二章 乙\n乙文\n第三章 丙\n丙文\n启程\n第一章 甲\n甲上\n甲下\n",
            ),
            (
                json!([
                    {"kind":"set_volume","source_line":1,"volume_title":"启程"},
                    {"kind":"set_volume","source_line":4,"volume_title":"归来"},
                    {"kind":"move_chapter","source_line":1,"before_line":6}
                ]),
                "启程\n归来\n第二章 乙\n乙文\n第一章 甲\n甲上\n甲下\n第三章 丙\n丙文\n",
            ),
            (
                json!([
                    {"kind":"split_chapter","source_line":3,"title":"第二章 新章"},
                    {"kind":"move_chapter","source_line":1,"before_line":6}
                ]),
                "第二章 新章\n甲下\n第二章 乙\n乙文\n第一章 甲\n甲上\n第三章 丙\n丙文\n",
            ),
        ];
        for (actions, expected) in cases {
            let mut reversed = actions.as_array().unwrap().clone();
            reversed.reverse();
            for actions in [actions, json!(reversed)] {
                let req = request(actions);
                let plan = prepare(&s, &req).unwrap();
                assert_eq!(
                    String::from_utf8(plan.output(&s).unwrap()).unwrap(),
                    expected
                );
                let book = crate::publication::compose(
                    &s,
                    &crate::structure::Structure::new(&s),
                    Some(&req),
                )
                .unwrap();
                assert_eq!(book.text, expected);
                assert_eq!(book.tree.source_bytes_covered, expected.len());
                for text in ["甲上", "甲下", "乙文", "丙文"] {
                    assert_eq!(book.text.matches(text).count(), 1);
                }
                for line in [1, 2, 3, 4, 5, 6, 7] {
                    assert!(book.source_to_output_lines.contains_key(&line));
                }
                assert!(
                    book.tree
                        .nodes
                        .iter()
                        .any(|n| n.entry_id.contains(":insert:"))
                );
            }
        }
        assert_eq!(s.decoded_text(), raw);
    }

    #[test]
    fn explicit_named_volumes_move_and_block_cross_volume_merge() {
        use crate::structure::{Override, Role, Structure};
        let s = source("启程\n第一章 甲\n甲文\n归来\n第二章 乙\n乙文");
        let mut structure = Structure::new(&s);
        structure.overrides = vec![
            Override {
                source_line: 1,
                role: Role::Volume,
                depth: 0,
                include_toc: true,
            },
            Override {
                source_line: 4,
                role: Role::Volume,
                depth: 0,
                include_toc: true,
            },
        ];
        let req = request(json!([{"kind":"move_volume","source_line":4,"before_line":1}]));
        let prepared = prepare_with_structure(&s, &req, Some(&structure)).unwrap();
        assert_eq!(
            prepared.projection(&s).unwrap().text,
            "归来\n第二章 乙\n乙文\n启程\n第一章 甲\n甲文\n"
        );
        // The public composition path must use the same explicit boundaries.
        let book = crate::publication::compose(&s, &structure, Some(&req)).unwrap();
        assert_eq!(book.text, prepared.projection(&s).unwrap().text);
        assert_eq!(book.tree.nodes[0].title, "归来");
        assert_eq!(book.tree.nodes[0].role, Role::Volume);
        assert_eq!(book.source_to_output_lines.get(&4), Some(&1));
        assert_eq!(book.source_to_output_lines.get(&1), Some(&4));
        let output_request = json!({"kind":"publication","structure":structure,
            "manual":serde_json::from_str::<Value>(&req).unwrap()})
        .to_string();
        let output_plan = crate::publication::prepare_output(&s, &output_request).unwrap();
        assert_eq!(
            output_plan.output(&s).unwrap(),
            prepared.output(&s).unwrap()
        );
        let output_evidence: Value = serde_json::from_slice(&output_plan.evidence()).unwrap();
        assert!(output_evidence.to_string().contains("归来"));

        let evidence: Value = serde_json::from_slice(&prepared.evidence(&s)).unwrap();
        assert_eq!(
            evidence["structure"],
            serde_json::to_value(&structure).unwrap()
        );
        let mut hidden = structure.clone();
        hidden.overrides[0].include_toc = false;
        let changed = prepare_with_structure(&s, &req, Some(&hidden)).unwrap();
        assert_eq!(prepared.output(&s).unwrap(), changed.output(&s).unwrap());
        assert_ne!(prepared.id(), changed.id());
        // Same action and source with a different logical boundary changes its span.
        let mut extended = structure.clone();
        extended.overrides[1].role = Role::Chapter;
        assert!(prepare_with_structure(&s, &req, Some(&extended)).is_err());
        let mut foreign = structure.clone();
        foreign.source_id = "0".repeat(64);
        assert!(prepare_with_structure(&s, &req, Some(&foreign)).is_err());
        let merge = request(json!([{"kind":"merge_previous","source_line":5}]));
        assert!(prepare_with_structure(&s, &merge, Some(&structure)).is_err());
    }
    #[test]
    fn whole_volume_keeps_intro_chapters_and_original_position_mapping() {
        let raw =
            "第一卷 甲\n甲卷序言\n第一章 甲章\n甲正文\n第二卷 乙\n乙卷序言\n第二章 乙章\n乙正文";
        let s = source(raw);
        let req = request(json!([
            {"kind":"move_volume","source_line":5,"before_line":1},
            {"kind":"rename_title","source_line":7,"title":"第二章 新乙章"}
        ]));
        let p = prepare(&s, &req).unwrap();
        let expected = "第二卷 乙\n乙卷序言\n第二章 新乙章\n乙正文\n第一卷 甲\n甲卷序言\n第一章 甲章\n甲正文\n";
        assert_eq!(p.projection(&s).unwrap().text, expected);
        assert_eq!(p.output(&s).unwrap(), expected.as_bytes());
        let book =
            crate::publication::compose(&s, &crate::structure::Structure::new(&s), Some(&req))
                .unwrap();
        assert_eq!(book.source_to_output_lines[&8], 4);
        assert_eq!(book.source_to_output_lines[&4], 8);
        assert_eq!(s.decoded_text(), raw);
        for action in [
            json!({"kind":"move_volume","source_line":1,"before_line":3}),
            json!({"kind":"move_volume","source_line":3,"before_line":1}),
            json!({"kind":"move_volume","source_line":1,"before_line":5}),
        ] {
            assert!(prepare(&s, &request(json!([action]))).is_err());
        }
    }
    #[test]
    fn moves_carry_renames_and_preserve_each_body_once_in_all_encodings() {
        let raw = "第一章 甲\r\n甲文\n第二章 乙\r乙文";
        for encoding in [
            EncodingKind::Utf8,
            EncodingKind::Utf16Le,
            EncodingKind::Utf16Be,
            EncodingKind::Utf32Le,
            EncodingKind::Utf32Be,
            EncodingKind::Cp936,
        ] {
            let bom = encoding != EncodingKind::Cp936;
            let original = encode(raw, encoding, bom).unwrap();
            let s =
                SourceSnapshot::from_bytes(original.clone(), EncodingMode::Auto, RULE_ID, || false)
                    .unwrap();
            let p=prepare(&s,&request(json!([{"kind":"move_chapter","source_line":3,"before_line":1},{"kind":"rename_title","source_line":3,"title":"第二章 新乙"}]))).unwrap();
            assert_eq!(
                p.output(&s).unwrap(),
                encode("第二章 新乙\r乙文\n第一章 甲\r\n甲文\n", encoding, bom).unwrap()
            );
            assert_eq!(s.original_bytes(), original);
            let p = prepare(
                &s,
                &request(json!([{"kind":"move_chapter","source_line":1,"before_line":5}])),
            )
            .unwrap();
            assert_eq!(
                p.output(&s).unwrap(),
                encode("第二章 乙\r乙文\n第一章 甲\r\n甲文\n", encoding, bom).unwrap()
            );
        }
    }
    #[test]
    fn exclusion_inside_moved_chapter_is_explicit_and_audited() {
        let s = source("第一章 甲\n甲文\n第二章 乙\n乙文\n尾注");
        let p=prepare(&s,&request(json!([{"kind":"move_chapter","source_line":3,"before_line":1},{"kind":"exclude_lines","source_line":5,"end_line":5}]))).unwrap();
        assert_eq!(
            String::from_utf8(p.output(&s).unwrap()).unwrap(),
            "第二章 乙\n乙文\n第一章 甲\n甲文\n"
        );
        let evidence: Value = serde_json::from_slice(&p.evidence(&s)).unwrap();
        assert!(
            evidence["changes"]
                .as_array()
                .unwrap()
                .iter()
                .any(|c| c["kind"] == "exclude_lines"
                    && c["source_line"] == 5
                    && c["before"] == "尾注"
                    && c["after"] == "")
        );
        for a in [
            json!([{"kind":"exclude_lines","source_line":4,"end_line":3}]),
            json!([{"kind":"exclude_lines","source_line":4,"end_line":99}]),
            json!([{"kind":"exclude_lines","source_line":2,"end_line":4},{"kind":"rename_title","source_line":3,"title":"第二章 改"}]),
            json!([{"kind":"move_chapter","source_line":1,"before_line":2}]),
            json!([{"kind":"move_chapter","source_line":1,"before_line":3}]),
            json!([{"kind":"move_chapter","source_line":1,"before_line":6},{"kind":"move_chapter","source_line":3,"before_line":1}]),
            json!([{"kind":"move_chapter","source_line":3,"before_line":1},{"kind":"exclude_lines","source_line":1,"end_line":1}]),
        ] {
            assert!(prepare(&s, &request(a)).is_err());
        }
    }
    #[test]
    fn split_and_merge_preserve_body_endings_encoding_and_exclusion_evidence() {
        let raw = "第一卷 起\r\n第一章 甲\r甲上\n甲下\r\n第二章 乙\n乙文";
        let expected = "第一卷 起\r\n第一章 甲\r甲上\n第二章 新章\r\n甲下\r\n乙文";
        for encoding in [
            EncodingKind::Utf8,
            EncodingKind::Utf16Le,
            EncodingKind::Utf16Be,
            EncodingKind::Utf32Le,
            EncodingKind::Utf32Be,
            EncodingKind::Cp936,
        ] {
            let bom = encoding != EncodingKind::Cp936;
            let original = encode(raw, encoding, bom).unwrap();
            let source =
                SourceSnapshot::from_bytes(original.clone(), EncodingMode::Auto, RULE_ID, || false)
                    .unwrap();
            let plan=prepare(&source,&request(json!([{"kind":"split_chapter","source_line":4,"title":"第二章 新章"},{"kind":"merge_previous","source_line":5}]))).unwrap();
            assert_eq!(
                plan.output(&source).unwrap(),
                encode(expected, encoding, bom).unwrap()
            );
            assert_eq!(source.original_bytes(), original);
            let evidence: Value = serde_json::from_slice(&plan.evidence(&source)).unwrap();
            assert_eq!(evidence["changes"][1]["before"], "第二章 乙\n");
            assert_eq!(evidence["changes"][1]["after"], "");
            assert!(
                plan.actions[1]["evidence"]
                    .as_str()
                    .unwrap()
                    .contains("第二章 新章")
            );
        }
    }
    #[test]
    fn merges_reject_first_chapter_cross_volume_and_conflicting_actions() {
        let s = source("第一章 甲\n甲文\n第二卷 续\n第二章 乙\n乙文");
        for actions in [
            json!([{"kind":"merge_previous","source_line":1}]),
            json!([{"kind":"merge_previous","source_line":4}]),
            json!([{"kind":"merge_previous","source_line":3}]),
            json!([{"kind":"split_chapter","source_line":2,"title":"未编号"}]),
            json!([{"kind":"split_chapter","source_line":1,"title":"第三章 丙"}]),
            json!([{"kind":"split_chapter","source_line":2,"title":"第三卷 丙"}]),
            json!([{"kind":"split_chapter","source_line":2,"title":"第三章 丙\n注入"}]),
        ] {
            assert!(prepare(&s, &request(actions)).is_err());
        }
        let s = source("第一章 甲\n甲文\n第二章 乙\n乙文");
        for action in [
            json!({"kind":"set_volume","source_line":3,"volume_title":"新卷"}),
            json!({"kind":"rename_title","source_line":3,"title":"第二章 新乙"}),
        ] {
            assert!(
                prepare(
                    &s,
                    &request(json!([{"kind":"merge_previous","source_line":3},action]))
                )
                .is_err()
            );
        }
    }
    #[test]
    fn merge_target_uses_final_boundaries_and_consecutive_merges_share_target() {
        let s = source("第一章 甲\n甲文\n第二章 乙\n乙文\n第三章 丙\n丙文");
        let actions = json!([{"kind":"merge_previous","source_line":5},{"kind":"set_volume","source_line":1,"volume_title":"第一卷 起"},{"kind":"merge_previous","source_line":3}]);
        let plan = prepare(&s, &request(actions)).unwrap();
        assert_eq!(
            String::from_utf8(plan.output(&s).unwrap()).unwrap(),
            "第一卷 起\n第一章 甲\n甲文\n乙文\n丙文"
        );
        for i in [0, 2] {
            assert!(
                plan.actions[i]["evidence"]
                    .as_str()
                    .unwrap()
                    .contains("第一章 甲")
            );
        }
        let actions = json!([{"kind":"merge_previous","source_line":5},{"kind":"rename_title","source_line":3,"title":"第二卷 续"}]);
        assert!(prepare(&s, &request(actions)).is_err());
        assert!(plan.output(&source("不同原稿")).is_err());
    }
}
