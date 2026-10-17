//! Compose text edits and logical structure; no converter or file writes.
use crate::{
    ApiError, ErrorCode, manual_edit,
    source::{RULE_ID, SourceSnapshot},
    structure::{Override, Role, Structure, Tree},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Serialize)]
pub struct EffectiveBook {
    pub original_source_id: String,
    /// Exact original source line -> effective output line. Missing entries are
    /// removed or ambiguously expanded regions, never nearest-neighbor guesses.
    #[serde(skip)]
    pub source_to_output_lines: BTreeMap<u32, u32>,
    pub tree: Tree,
    pub removed_structure_lines: Vec<u32>,
    pub text_changed: bool,
    #[serde(skip)]
    pub text: String,
    #[serde(skip)]
    pub cleanup_evidence: Option<Value>,
}
#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum IllustrationPosition {
    Unplaced,
    NeedsRelocation { source_line: u32 },
    AfterLine { source_line: u32, output_line: u32 },
}
impl EffectiveBook {
    /// Fixed, read-only hygiene checks on composed text. Do not replay custom
    /// replacements (which may be non-idempotent) or original-line selections.
    pub fn cleanup_check_page(&self, offset: usize) -> Result<Value, ApiError> {
        self.cleanup_check_selected(offset, None)
    }

    pub fn cleanup_check_selected(
        &self,
        offset: usize,
        rules: Option<Vec<String>>,
    ) -> Result<Value, ApiError> {
        self.cleanup_check_pipeline(offset, rules, None)
    }
    pub fn cleanup_check_pipeline(
        &self,
        offset: usize,
        rules: Option<Vec<String>>,
        selected: Option<Vec<Value>>,
    ) -> Result<Value, ApiError> {
        let view = SourceSnapshot::for_effective_diagnostics(self)?;
        let rules = rules.unwrap_or_else(|| {
            vec![
                "trim_trailing_spaces".into(),
                "collapse_blank_lines".into(),
                "remove_ad_lines".into(),
            ]
        });
        let pipeline: Vec<Value> =
            selected.unwrap_or_else(|| rules.iter().map(|kind| json!({"kind":kind})).collect());
        let rules: Vec<String> = pipeline
            .iter()
            .map(|r| {
                r["rule"]["kind"]
                    .as_str()
                    .or_else(|| r["kind"].as_str())
                    .unwrap_or("unknown")
                    .to_string()
            })
            .collect();
        if pipeline.is_empty() {
            return Ok(
                json!({"scope":"effective_draft", "composition_id":view.summary().source_id,
                "checks":[], "report":{"change_count":0,"candidate_count":0,"actions":[],"candidates":[]},
                "writes_source":false,"can_apply":false}),
            );
        }
        let request = json!({"kind":"cleanup", "preview_offset":offset, "pipeline":pipeline});
        let plan = crate::cleanup::prepare(&view, &request.to_string())?;
        let mut report: Value = serde_json::from_str(&plan.preview())
            .map_err(|_| ApiError::new(ErrorCode::InvalidRule, "cleanup_check", "retry_check"))?;
        let mut original_lines = BTreeMap::<u32, Option<u32>>::new();
        for (&original, &effective) in &self.source_to_output_lines {
            original_lines
                .entry(effective)
                .and_modify(|v| *v = None)
                .or_insert(Some(original));
        }
        for key in ["actions", "candidates"] {
            for row in report[key].as_array_mut().expect("cleanup report rows") {
                let effective = row["source_line"]
                    .as_u64()
                    .and_then(|v| u32::try_from(v).ok());
                row["original_source_line"] =
                    json!(effective.and_then(|v| original_lines.get(&v).copied().flatten()));
            }
        }
        Ok(
            json!({"scope":"effective_draft", "composition_id":view.summary().source_id,
            "checks":rules,
            "report":report,"writes_source":false,"can_apply":false}),
        )
    }

    /// Read-only findings in effective-text coordinates. Original review records
    /// are deliberately not applied to this separate, composition-bound evidence.
    pub fn check_page(&self, offset: usize, line: Option<u32>) -> Result<Value, ApiError> {
        self.check_page_filtered(offset, line, None, None)
    }
    pub fn check_page_filtered(
        &self,
        offset: usize,
        line: Option<u32>,
        category: Option<&str>,
        severity: Option<&str>,
    ) -> Result<Value, ApiError> {
        self.check_page_reviewed(
            offset,
            line,
            category,
            severity,
            &crate::review::Review::default(),
        )
    }
    pub fn check_page_reviewed(
        &self,
        offset: usize,
        line: Option<u32>,
        category: Option<&str>,
        severity: Option<&str>,
        review: &crate::review::Review,
    ) -> Result<Value, ApiError> {
        let view = SourceSnapshot::for_effective_diagnostics(self)?;
        let repairs = crate::effective_repair::candidates(self);
        let evidence = crate::review::ReviewEvidence::new(&view)?;
        self.check_page_using(&view, &evidence, &repairs, offset, line, category, severity, review)
    }

    /// A session can reuse the immutable diagnostics and candidate set while
    /// paging or changing review decisions for the same composed book.
    #[allow(clippy::too_many_arguments)]
    pub fn check_page_using(
        &self,
        view: &SourceSnapshot,
        evidence: &crate::review::ReviewEvidence,
        repairs: &Value,
        offset: usize,
        line: Option<u32>,
        category: Option<&str>,
        severity: Option<&str>,
        review: &crate::review::Review,
    ) -> Result<Value, ApiError> {
        let mut report = review.report_using(evidence, offset, category, severity)?;
        let original_lines = self.unique_original_lines();
        self.decorate_review_items(
            view,
            repairs,
            &original_lines,
            report["diagnostic"]["review_items"]
                .as_array_mut()
                .expect("internal review items"),
        );
        let excerpt = line.map(|line| {
            view.read_page(crate::source::SourceCursor {
                line_index: line.saturating_sub(3), utf8_column: 0,
            }, 12).map(|page| page.items.into_iter().map(|row| {
                json!({"line":row.line_number,"text":row.text.chars().take(1000).collect::<String>(),
                    "original_line":original_lines.get(&row.line_number).copied().flatten(),
                    "anchor":format!("{}:{}",self.tree.source_id,row.line_number),
                    "truncated":row.continues || row.text.chars().count() > 1000})
            }).collect::<Vec<_>>())
        }).transpose()?;
        Ok(
            json!({"scope":"effective_draft","composition_id":view.summary().source_id,
            "report":report,"repairs":repairs,"excerpt":excerpt,"writes_source":false}),
        )
    }

    /// Effective line -> original line, only where exactly one original maps to it.
    fn unique_original_lines(&self) -> BTreeMap<u32, Option<u32>> {
        let mut original_lines = BTreeMap::<u32, Option<u32>>::new();
        for (&original, &effective) in &self.source_to_output_lines {
            original_lines
                .entry(effective)
                .and_modify(|v| *v = None)
                .or_insert(Some(original));
        }
        original_lines
    }

    fn node_locations(&self) -> BTreeMap<&str, usize> {
        self.tree
            .nodes
            .iter()
            .enumerate()
            .map(|(i, n)| (n.entry_id.as_str(), i))
            .collect()
    }

    /// The structure node a finding belongs to: its own entry, else the node
    /// containing its first line. `None` is the text before the first heading.
    fn finding_node(&self, locations: &BTreeMap<&str, usize>, item: &Value) -> Option<usize> {
        if let Some(&index) = item["entry_id"].as_str().and_then(|id| locations.get(id)) {
            return Some(index);
        }
        let line = u32::try_from(item["source_lines"].get(0)?.as_u64()?).ok()?;
        self.tree.nodes.partition_point(|n| n.source_line <= line).checked_sub(1)
    }

    /// Adds structure coordinates, anchors and repair availability to review items.
    fn decorate_review_items(
        &self,
        view: &SourceSnapshot,
        repairs: &Value,
        original_lines: &BTreeMap<u32, Option<u32>>,
        items: &mut [Value],
    ) {
        let locations = self.node_locations();
        for item in items {
            let id = item["entry_id"].as_str().unwrap_or("");
            let node_offset = locations.get(id).map(|i| i / 30 * 30);
            item["auto_applicable"] = json!(
                repairs["items"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|p| p["finding_id"] == item["id"] && p["recommended"] == true)
            );
            item["has_suggestion"] = json!(
                repairs["items"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|p| p["finding_id"] == item["id"])
            );
            item["node_offset"] = json!(node_offset);
            let anchors = item["source_lines"].as_array().unwrap().iter().enumerate().filter_map(|(anchor,line)| {
                let line = u32::try_from(line.as_u64()?).ok()?;
                let index = self.tree.nodes.partition_point(|n|n.source_line<=line).checked_sub(1);
                let node=index.map(|i|&self.tree.nodes[i]);
                let context_line = if anchor==0 && item["source_lines"].as_array().unwrap().len()==2 && item["finding_id"]=="number-gap" {
                    index.and_then(|i| self.tree.nodes.get(i+1)).map(|next| next.source_line.saturating_sub(5).max(line)).unwrap_or(line)
                } else {line};
                Some(json!({"title":node.map(|n|n.title.as_str()).unwrap_or("卷前正文"),"line":context_line,
                    "start_line":node.map(|n|n.source_line).unwrap_or(1),
                    "end_line":index.and_then(|i|self.tree.nodes.get(i+1)).map(|n|n.source_line.saturating_sub(1))
                        .unwrap_or_else(||view.summary().line_count),
                    "heading_line":line,"entry_id":node.map(|n|n.entry_id.as_str()).unwrap_or("$prefix"),
                    "node_offset":index.map(|i|i/30*30).unwrap_or(0),
                    "body_offset":context_line.saturating_sub(node.map(|n|n.source_line+1).unwrap_or(1)),
                    "original_line":original_lines.get(&context_line).copied().flatten()}))
            }).collect::<Vec<_>>();
            if item["entry_id"].is_null() && !anchors.is_empty() {
                item["entry_id"] = anchors[0]["entry_id"].clone();
                item["node_offset"] = anchors[0]["node_offset"].clone();
            }
            item["anchors"] = json!(anchors);
            item["original_source_lines"] = json!(item["source_lines"].as_array().map(|lines| {
                lines
                    .iter()
                    .map(|line| {
                        line.as_u64()
                            .and_then(|v| u32::try_from(v).ok())
                            .and_then(|v| original_lines.get(&v).copied().flatten())
                    })
                    .collect::<Vec<_>>()
            }));
        }
    }

    /// Whole-book finding positions from the same cached evidence as the paged
    /// report. `summary` returns one row per structure node with findings (worst
    /// severity, total and still-open counts); `entry_id` returns the findings
    /// that belong to or touch that node, decorated like report items and capped.
    /// Read-only: review decisions are applied, never changed.
    pub fn issue_positions_using(
        &self,
        view: &SourceSnapshot,
        evidence: &crate::review::ReviewEvidence,
        repairs: &Value,
        review: &crate::review::Review,
        summary: bool,
        entry_id: Option<&str>,
    ) -> Result<Value, ApiError> {
        const CHAPTER_LIMIT: usize = 200;
        const LEVELS: [&str; 3] = ["error", "warning", "info"];
        let rank = |item: &Value| {
            LEVELS
                .iter()
                .position(|v| item["severity"] == *v)
                .unwrap_or(2)
        };
        let all = review.all_using(evidence)?;
        let locations = self.node_locations();
        let target = match entry_id {
            None => None,
            Some("$prefix") => Some(None),
            Some(id) => Some(Some(*locations.get(id).ok_or_else(|| {
                ApiError::new(ErrorCode::InvalidCursor, "publication", "select_body_node")
            })?)),
        };
        // (worst open, worst any, count, open) per node; usize::MAX = none yet.
        let mut nodes = BTreeMap::<Option<usize>, (usize, usize, usize, usize)>::new();
        let mut open_severities = BTreeMap::<&str, usize>::new();
        let mut open = 0;
        let mut chapter = Vec::new();
        for item in &all {
            let node = self.finding_node(&locations, item);
            let level = rank(item);
            let is_open = item["open"] == true;
            let entry = nodes.entry(node).or_insert((usize::MAX, usize::MAX, 0, 0));
            entry.1 = entry.1.min(level);
            entry.2 += 1;
            if is_open {
                entry.0 = entry.0.min(level);
                entry.3 += 1;
                open += 1;
                *open_severities.entry(LEVELS[level]).or_default() += 1;
            }
            if let Some(target) = target {
                let (start, end) = match target {
                    None => (0, self.tree.nodes.first().map_or(u32::MAX, |n| n.source_line)),
                    Some(i) => (
                        self.tree.nodes[i].source_line,
                        self.tree.nodes.get(i + 1).map_or(u32::MAX, |n| n.source_line),
                    ),
                };
                let touches = item["source_lines"].as_array().is_some_and(|lines| {
                    lines.iter().any(|line| {
                        line.as_u64()
                            .and_then(|v| u32::try_from(v).ok())
                            .is_some_and(|line| line >= start && line < end)
                    })
                });
                if node == target || touches {
                    chapter.push(item.clone());
                }
            }
        }
        let chapter = target.map(|target| {
            let total = chapter.len();
            chapter.truncate(CHAPTER_LIMIT);
            self.decorate_review_items(view, repairs, &self.unique_original_lines(), &mut chapter);
            json!({"entry_id": entry_id, "index": target, "total": total,
                "truncated": total > CHAPTER_LIMIT, "items": chapter})
        });
        let rows = summary.then(|| {
            nodes
                .iter()
                .map(|(&index, &(worst_open, worst, count, open))| {
                    json!({
                        "entry_id": index.map_or("$prefix", |i| self.tree.nodes[i].entry_id.as_str()),
                        "index": index,
                        "severity": LEVELS[if open > 0 { worst_open } else { worst }],
                        "count": count,
                        "open": open,
                    })
                })
                .collect::<Vec<_>>()
        });
        Ok(json!({
            "evidence_id": evidence.stamp(),
            "total": all.len(),
            "open": open,
            "open_severities": open_severities,
            "node_count": self.tree.nodes.len(),
            "nodes": rows,
            "chapter": chapter,
            "writes_source": false,
        }))
    }

    /// Volume navigation is computed from structure, never from title keywords.
    pub fn volume_navigation(
        &self,
        volume_id: Option<&str>,
        offset: usize,
    ) -> Result<Value, ApiError> {
        if let Some(id) = volume_id
            && !self
                .tree
                .nodes
                .iter()
                .any(|n| n.entry_id == id && n.role == Role::Volume)
            {
                return Err(ApiError::new(
                    ErrorCode::InvalidCursor,
                    "publication",
                    "refresh_effective_tree",
                ));
            }
        let matches = |n: &&crate::structure::Node| match volume_id {
            None => n.role == Role::Volume,
            Some(id) => n.parent_id.as_deref() == Some(id),
        };
        let total = self.tree.nodes.iter().filter(matches).count();
        let nodes = self
            .tree
            .nodes
            .iter()
            .filter(matches)
            .skip(offset)
            .take(30)
            .collect::<Vec<_>>();
        Ok(json!({"nodes":nodes,"total":total,"offset":offset,"volume_id":volume_id}))
    }

    /// Bounded chapter-body view in the current composed coordinate system.
    pub fn body_preview(&self, entry_id: &str, offset: usize) -> Result<Value, ApiError> {
        self.body_slice(entry_id, offset, None)
    }

    /// Continue one physical line without changing the ordinary 30-line cursor.
    pub fn body_line_chunk(&self, entry_id: &str, offset: usize, char_offset: usize) -> Result<Value, ApiError> {
        self.body_slice(entry_id, offset, Some(char_offset))
    }

    fn body_slice(&self, entry_id: &str, offset: usize, char_offset: Option<usize>) -> Result<Value, ApiError> {
        let (body_start, body_end, heading_line) = if entry_id == "$prefix" {
            (0, self.tree.prefix_end, 0)
        } else {
            let node = self
                .tree
                .nodes
                .iter()
                .find(|n| n.entry_id == entry_id)
                .ok_or_else(|| {
                    ApiError::new(
                        ErrorCode::InvalidCursor,
                        "publication",
                        "refresh_effective_tree",
                    )
                })?;
            (node.body_start, node.end, node.source_line)
        };
        let text = &self.text[body_start..body_end];
        let bytes = text.as_bytes();
        let mut start = 0;
        let mut index = 0usize;
        let mut rows = Vec::new();
        // Image anchors use original coordinates even after chapters move or
        // cleanup joins lines. The last contributing original line is an exact
        // after-paragraph anchor; generated text has no original anchor.
        let first_line = (heading_line as usize)
            .saturating_add(1)
            .saturating_add(offset);
        let row_limit = if char_offset.is_some() { 1 } else { 30 };
        let char_limit = if char_offset.is_some() { 2000 } else { 500 };
        let last_line = first_line.saturating_add(row_limit);
        let original_lines: BTreeMap<u32, u32> = self
            .source_to_output_lines
            .iter()
            .filter(|(_, output)| (first_line..last_line).contains(&(**output as usize)))
            .map(|(&original, &output)| (output, original))
            .collect();
        while start < bytes.len() {
            let mut end = start;
            while end < bytes.len() && !matches!(bytes[end], b'\r' | b'\n') {
                end += 1;
            }
            if index >= offset && rows.len() < row_limit {
                let full = &text[start..end];
                let skip = char_offset.unwrap_or(0);
                let mut chars = full.chars().skip(skip);
                let shown = chars.by_ref().take(char_limit).collect::<String>();
                let continues = chars.next().is_some();
                let output_line = heading_line + 1 + index as u32;
                rows.push(json!({"source_line":output_line,
                    "original_source_line":original_lines.get(&output_line),
                    "line_offset":index+1,"text":shown,"truncated":continues,
                    "char_offset":skip,"next_char_offset":continues.then_some(skip.saturating_add(char_limit)),
                    "selectable":!full.trim().is_empty()}));
            }
            index += 1;
            start = end;
            if start < bytes.len() {
                start += if bytes[start] == b'\r' && bytes.get(start + 1) == Some(&b'\n') {
                    2
                } else {
                    1
                };
            }
        }
        let continued = char_offset.is_some() && rows.first().is_some_and(|row|row["truncated"]==true);
        let next_offset = if continued {Some(offset)} else {
            (offset.saturating_add(rows.len()) < index).then_some(offset.saturating_add(rows.len()))
        };
        let next_char_offset = if continued { rows[0]["next_char_offset"].clone() } else {json!(0)};
        Ok(json!({"entry_id":entry_id,"offset":offset,"total":index,
            "next_offset":next_offset,"next_char_offset":next_char_offset,
            "has_more":offset.saturating_add(rows.len()) < index,"rows":rows}))
    }

    /// The source identity is mandatory even if a line number happens to exist.
    pub fn illustration_position(
        &self,
        source_id: &str,
        source_line: Option<u32>,
    ) -> Result<IllustrationPosition, ApiError> {
        if source_id != self.original_source_id || source_line == Some(0) {
            return Err(ApiError::new(
                ErrorCode::InvalidCursor,
                "illustration_position",
                "choose_position_in_own_source",
            ));
        }
        Ok(match source_line {
            None => IllustrationPosition::Unplaced,
            Some(line) => match self.source_to_output_lines.get(&line) {
                Some(&output_line) => IllustrationPosition::AfterLine {
                    source_line: line,
                    output_line,
                },
                None => IllustrationPosition::NeedsRelocation { source_line: line },
            },
        })
    }
}
pub fn compose(
    source: &SourceSnapshot,
    structure: &Structure,
    manual: Option<&str>,
) -> Result<EffectiveBook, ApiError> {
    let original = structure.tree(source)?;
    let Some(request) = manual else {
        return Ok(EffectiveBook {
            original_source_id: source.summary().source_id,
            source_to_output_lines: (1..=source.summary().line_count).map(|n| (n, n)).collect(),
            tree: original,
            removed_structure_lines: Vec::new(),
            text_changed: false,
            text: source.decoded_text().into(),
            cleanup_evidence: None,
        });
    };
    let prepared = manual_edit::prepare_with_structure(source, request, Some(structure))?;
    let projection = prepared.projection(source)?;
    compose_projection(source, structure, projection)
}

/// Build the effective tree from the same projection used by the text writer.
/// Callers supply a validated manual or catalog plan, never client-made offsets.
pub fn compose_projection(
    source: &SourceSnapshot,
    structure: &Structure,
    projection: manual_edit::Projection,
) -> Result<EffectiveBook, ApiError> {
    compose_projection_at_volume_depth(source, structure, projection, 0)
}

/// Explicit inserted-volume depth for effective-tree edits. Existing node depths
/// and all original line anchors remain unchanged.
pub(crate) fn compose_projection_at_volume_depth(
    source: &SourceSnapshot,
    structure: &Structure,
    projection: manual_edit::Projection,
    volume_depth: u8,
) -> Result<EffectiveBook, ApiError> {
    let original = structure.tree(source)?;
    let mut offsets = BTreeSet::new();
    let mut source_lines = BTreeSet::new();
    for anchor in &projection.anchors {
        if anchor.source_line == 0
            || anchor.source_line > source.summary().line_count
            || !offsets.insert(anchor.output_start)
            || (anchor.inserted.is_none() && !source_lines.insert(anchor.source_line))
            || !matches!(anchor.inserted, None | Some("set_volume" | "split_chapter"))
        {
            return Err(ApiError::new(
                ErrorCode::InvalidCursor,
                "publication",
                "review_projection",
            ));
        }
    }
    let effective =
        SourceSnapshot::from_utf8(projection.text.as_bytes().to_vec(), RULE_ID, || false)?;
    let output_lines = effective
        .decoded_line_ranges()
        .iter()
        .enumerate()
        .map(|(i, &(start, _))| (start, i as u32 + 1))
        .collect::<BTreeMap<_, _>>();
    let mut settings = Structure::new(&effective);
    let overrides = structure
        .overrides
        .iter()
        .map(|o| (o.source_line, o))
        .collect::<BTreeMap<_, _>>();
    let old_nodes = original
        .nodes
        .iter()
        .map(|n| (n.source_line, n))
        .collect::<BTreeMap<_, _>>();
    let mut ids = BTreeMap::new();
    let mut retained = BTreeSet::new();
    let mut in_volume = false;
    let mut anchors = projection.anchors.iter().collect::<Vec<_>>();
    anchors.sort_by_key(|a| a.output_start);
    for a in anchors {
        let output_line = *output_lines.get(&a.output_start).ok_or_else(|| {
            ApiError::new(
                ErrorCode::InvalidCursor,
                "publication",
                "review_line_boundaries",
            )
        })?;
        let item = if let Some(kind) = a.inserted {
            let role = if kind == "set_volume" {
                Role::Volume
            } else {
                Role::Chapter
            };
            let depth = if role == Role::Volume {
                volume_depth
            } else if in_volume {
                1
            } else {
                0
            };
            Some(Override {
                source_line: output_line,
                role,
                depth,
                include_toc: true,
            })
        } else if let Some(o) = overrides.get(&a.source_line) {
            retained.insert(a.source_line);
            let mut o = (*o).clone();
            o.source_line = output_line;
            Some(o)
        } else { old_nodes.get(&a.source_line).map(|n| Override {
                source_line: output_line,
                role: n.role.clone(),
                depth: if n.role == Role::Volume {
                    0
                } else if in_volume {
                    1
                } else {
                    0
                },
                include_toc: n.include_toc,
            }) };
        if let Some(o) = item {
            if o.role == Role::Volume {
                in_volume = true;
            }
            settings.overrides.push(o);
            ids.insert(
                a.output_start,
                if let Some(kind) = a.inserted {
                    format!(
                        "{}:insert:{kind}:{}",
                        source.summary().source_id,
                        a.source_line
                    )
                } else {
                    format!(
                        "{}:{}",
                        source.summary().source_id,
                        source.decoded_line_ranges()[a.source_line as usize - 1].0
                    )
                },
            );
        }
    }
    let mut tree = settings.tree(&effective)?;
    tree.recognition_rules = structure.recognition_rules.clone();
    let remap = tree
        .nodes
        .iter()
        .map(|n| {
            (
                n.entry_id.clone(),
                ids.get(&n.start)
                    .cloned()
                    .unwrap_or_else(|| n.entry_id.clone()),
            )
        })
        .collect::<BTreeMap<_, _>>();
    for node in &mut tree.nodes {
        node.entry_id = remap[&node.entry_id].clone();
        node.parent_id = node.parent_id.as_ref().map(|id| remap[id].clone());
    }
    Ok(EffectiveBook {
        original_source_id: source.summary().source_id,
        source_to_output_lines: projection
            .anchors
            .iter()
            .filter(|a| a.inserted.is_none())
            .map(|a| (a.source_line, output_lines[&a.output_start]))
            .collect(),
        tree,
        removed_structure_lines: overrides
            .keys()
            .filter(|n| !retained.contains(n))
            .copied()
            .collect(),
        text_changed: projection.text != source.decoded_text(),
        text: projection.text,
        cleanup_evidence: None,
    })
}

/// Apply original-coordinate manual actions after a validated catalog projection.
pub fn edit_projection(
    source: &SourceSnapshot,
    structure: &Structure,
    base: manual_edit::Projection,
    manual: &str,
) -> Result<manual_edit::Projection, ApiError> {
    Ok(edit_projection_with_evidence(source, structure, base, manual)?.0)
}

pub fn edit_projection_with_evidence(
    source: &SourceSnapshot,
    structure: &Structure,
    base: manual_edit::Projection,
    manual: &str,
) -> Result<(manual_edit::Projection, Value), ApiError> {
    let fail = || {
        ApiError::new(
            ErrorCode::InvalidRule,
            "publication",
            "review_catalog_manual_coordinates",
        )
    };
    if manual.len() > 1024 * 1024 {
        return Err(fail());
    }
    let intermediate = SourceSnapshot::from_utf8(base.text.as_bytes().to_vec(), RULE_ID, || false)?;
    let offsets = intermediate
        .decoded_line_ranges()
        .iter()
        .enumerate()
        .map(|(i, r)| (r.0, i as u32 + 1))
        .collect::<BTreeMap<_, _>>();
    let mut reverse = BTreeMap::new();
    let mut forward = BTreeMap::new();
    for anchor in &base.anchors {
        let line = *offsets.get(&anchor.output_start).ok_or_else(fail)?;
        reverse.insert(line, (anchor.source_line, anchor.inserted));
        if anchor.inserted.is_none() {
            forward.insert(anchor.source_line, line);
        }
    }
    let book = compose_projection(source, structure, base)?;
    let mut context = Structure::new(&intermediate);
    context.overrides = book
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
    let mut request: Value = serde_json::from_str(manual).map_err(|_| fail())?;
    // Embedded context uses original coordinates. Validate before replacing it
    // with the catalog-projected context; never compare it to remapped line IDs.
    if let Some(selected) = request
        .as_object_mut()
        .ok_or_else(fail)?
        .remove("structure")
        && !selected.is_null() {
            let selected: Structure = serde_json::from_value(selected).map_err(|_| fail())?;
            if &selected != structure {
                return Err(fail());
            }
        }
    let actions = request
        .get_mut("actions")
        .and_then(Value::as_array_mut)
        .ok_or_else(fail)?;
    if actions.len() > 500 {
        return Err(fail());
    }
    for action in actions {
        let original = action["source_line"]
            .as_u64()
            .and_then(|n| u32::try_from(n).ok())
            .ok_or_else(fail)?;
        let mapped = *forward.get(&original).ok_or_else(fail)?;
        action["source_line"] = json!(mapped);
        if let Some(end) = action.get("end_line") {
            let end = end
                .as_u64()
                .and_then(|n| u32::try_from(n).ok())
                .ok_or_else(fail)?;
            if end < original || end > source.summary().line_count {
                return Err(fail());
            }
            // Never turn a discontinuous original selection into a broader range.
            for (offset, line) in (original..=end).enumerate() {
                if forward.get(&line).copied() != Some(mapped + offset as u32) {
                    return Err(fail());
                }
            }
            action["end_line"] = json!(mapped + end - original);
        }
        if let Some(target) = action.get("before_line") {
            let target = target
                .as_u64()
                .and_then(|n| u32::try_from(n).ok())
                .ok_or_else(fail)?;
            action["before_line"] = json!(if target == source.summary().line_count + 1 {
                intermediate.summary().line_count + 1
            } else {
                *forward.get(&target).ok_or_else(fail)?
            });
        }
    }
    let prepared =
        manual_edit::prepare_with_structure(&intermediate, &request.to_string(), Some(&context))?;
    let mut evidence: Value =
        serde_json::from_slice(&prepared.evidence(&intermediate)).map_err(|_| fail())?;
    evidence["coordinate_system"] = json!("after_catalog_before_manual");
    evidence["source_line_origins"] = json!(reverse);
    for change in evidence["changes"].as_array_mut().ok_or_else(fail)? {
        let line = change["source_line"].as_u64().ok_or_else(fail)? as u32;
        if let Some((original, inserted)) = reverse.get(&line) {
            change["original_source_line"] = json!(original);
            change["inserted_anchor"] = json!(inserted);
        }
        change["coordinate_system"] = json!("after_catalog_before_manual");
    }
    let mut result = prepared.projection(&intermediate)?;
    for anchor in &mut result.anchors {
        let (original, inserted) = *reverse.get(&anchor.source_line).ok_or_else(fail)?;
        anchor.source_line = original;
        if anchor.inserted.is_none() {
            anchor.inserted = inserted;
        }
    }
    Ok((result, evidence))
}

/// Cleanup selections keep original source coordinates even after manual moves.
/// Inserted lines are excluded from source-scoped cleanup.
pub fn compose_with_cleanup(
    source: &SourceSnapshot,
    structure: &Structure,
    manual: Option<&str>,
    cleanup_json: Option<&str>,
) -> Result<EffectiveBook, ApiError> {
    let book = compose(source, structure, manual)?;
    cleanup_composed(source, structure, book, cleanup_json)
}

pub fn compose_projected_with_cleanup(
    source: &SourceSnapshot,
    structure: &Structure,
    projection: manual_edit::Projection,
    cleanup_json: Option<&str>,
) -> Result<EffectiveBook, ApiError> {
    let book = compose_projection(source, structure, projection)?;
    cleanup_composed(source, structure, book, cleanup_json)
}

fn cleanup_composed(
    source: &SourceSnapshot,
    structure: &Structure,
    mut book: EffectiveBook,
    cleanup_json: Option<&str>,
) -> Result<EffectiveBook, ApiError> {
    let Some(cleanup_json) = cleanup_json else {
        return Ok(book);
    };
    crate::cleanup::prepare(source, cleanup_json)?;
    let mut request: crate::cleanup::Request = serde_json::from_str(cleanup_json)
        .map_err(|_| ApiError::new(ErrorCode::InvalidRule, "publication", "review_cleanup"))?;
    let edited = SourceSnapshot::from_utf8(book.text.as_bytes().to_vec(), RULE_ID, || false)?;
    let origins = book
        .source_to_output_lines
        .iter()
        .map(|(&original, &output)| (output, original))
        .collect::<BTreeMap<_, _>>();
    // Cleanup selections are stored against original source coordinates. Map each
    // step-local exclusion through the manual projection before preparing cleanup;
    // never guess a new line when an excluded source span disappeared.
    if !request.step_exclusions.is_empty() {
        let reverse = origins
            .iter()
            .map(|(&line, &origin)| (origin, line))
            .collect::<BTreeMap<_, _>>();
        let mut mapped = Vec::with_capacity(request.step_exclusions.len());
        let mut mapped_lines = 0usize;
        for exclusion in request.step_exclusions {
            let start = exclusion.source_line;
            let end = exclusion.source_end_line.unwrap_or(start);
            mapped_lines = mapped_lines.saturating_add((end - start + 1) as usize);
            if mapped_lines > 1_000_000 {
                return Err(crate::cleanup_rules::budget());
            }
            let mut selected = reverse
                .range(start..=end)
                .map(|(_, &line)| line)
                .collect::<Vec<_>>();
            if selected.len() != (end - start + 1) as usize {
                return Err(ApiError::new(
                    ErrorCode::InvalidRule,
                    "cleanup_step_exclusion_conflict",
                    "reselect_step_difference",
                ));
            }
            selected.sort_unstable();
            let mut groups: Vec<(u32, u32)> = Vec::new();
            for line in selected {
                if let Some(group) = groups.last_mut().filter(|g| g.1 + 1 == line) {
                    group.1 = line;
                } else {
                    groups.push((line, line));
                }
            }
            for (start, end) in groups {
                mapped.push(crate::cleanup::StepExclusion {
                    step_index: exclusion.step_index,
                    source_line: start,
                    source_end_line: (end != start).then_some(end),
                });
            }
        }
        mapped.sort_by_key(|e| {
            (
                e.step_index,
                e.source_line,
                e.source_end_line.unwrap_or(e.source_line),
            )
        });
        mapped.dedup();
        request.step_exclusions = mapped;
    }
    let first = request.start_line.unwrap_or(1);
    let last = request
        .end_line
        .unwrap_or(source.decoded_line_ranges().len() as u32);
    let removed = request.remove_lines.clone();
    let skipped = request.skip_lines.clone();
    let protected = request.protected_lines.clone();
    request.protected_lines = origins
        .iter()
        .filter(|(_, n)| protected.contains(n))
        .map(|(&line, _)| line)
        .collect();
    // A gap caused by an explicit manual exclusion is also a join barrier.
    let mut previous_origin = None;
    for (&line, &origin) in &origins {
        if previous_origin.is_some_and(|(l, n)| line == l + 1 && origin != n + 1) {
            request.protected_lines.insert(line);
        }
        previous_origin = Some((line, origin));
    }
    request.start_line = None;
    request.end_line = None;
    request.preview_offset = 0;
    request.remove_lines.clear();
    request.skip_lines.clear();
    for line in 1..=edited.decoded_line_ranges().len() as u32 {
        match origins.get(&line) {
            Some(n) if *n >= first && *n <= last && !skipped.contains(n) => {
                if removed.contains(n) {
                    request.remove_lines.insert(line);
                }
            }
            _ => {
                request.skip_lines.insert(line);
            }
        }
    }
    let structural_lines = book.tree.nodes.iter().map(|n| n.source_line).collect();
    let original_body = structure
        .overrides
        .iter()
        .filter(|o| o.role == Role::Body)
        .map(|o| o.source_line)
        .collect::<BTreeSet<_>>();
    let explicit_body = origins
        .iter()
        .filter(|(_, n)| original_body.contains(n))
        .map(|(&n, _)| n)
        .collect();
    let heading_markers = book
        .tree
        .nodes
        .iter()
        .map(|n| {
            (
                n.source_line,
                match n.role {
                    Role::Volume => Some('卷'),
                    Role::Chapter => Some('章'),
                    Role::Section => Some('节'),
                    Role::Front | Role::Body => None,
                },
            )
        })
        .collect();
    let cleanup = crate::cleanup::prepare_with_context(
        &edited,
        request,
        &structural_lines,
        &explicit_body,
        &heading_markers,
        Some(&crate::cleanup_duplicates::targets(
            &edited,
            &book.tree.nodes,
        )),
    )?;
    let line_map = cleanup
        .retained_lines()
        .iter()
        .copied()
        .collect::<BTreeMap<_, _>>();
    let cleaned = SourceSnapshot::from_utf8(cleanup.text().as_bytes().to_vec(), RULE_ID, || false)?;
    let mut settings = Structure::new(&cleaned);
    let mut stable_ids = BTreeMap::new();
    for node in &book.tree.nodes {
        if cleanup
            .removed_duplicate_headings()
            .contains_key(&node.source_line)
        {
            if let Some(&original) = origins.get(&node.source_line) {
                book.removed_structure_lines.push(original);
            }
            continue;
        }
        let line = *line_map.get(&node.source_line).ok_or_else(|| {
            ApiError::new(
                ErrorCode::InvalidRule,
                "publication",
                "cleanup_would_remove_structural_heading",
            )
        })?;
        settings.overrides.push(Override {
            source_line: line,
            role: node.role.clone(),
            depth: node.depth,
            include_toc: node.include_toc,
        });
        stable_ids.insert(line, node.entry_id.clone());
    }
    // Only the explicit bare-number option may create headings during cleanup.
    // Keep their IDs tied to original lines and attach them to the current volume.
    let mut promotions = BTreeMap::new();
    for &before_line in cleanup.promoted_headings() {
        let &line = line_map.get(&before_line).ok_or_else(|| {
            ApiError::new(
                ErrorCode::InvalidRule,
                "publication",
                "cleanup_would_remove_structural_heading",
            )
        })?;
        let &original = origins.get(&before_line).ok_or_else(|| {
            ApiError::new(
                ErrorCode::InvalidRule,
                "publication",
                "review_line_boundaries",
            )
        })?;
        promotions.insert(line, original);
    }
    let existing = settings
        .overrides
        .iter()
        .map(|o| (o.source_line, o.clone()))
        .collect::<BTreeMap<_, _>>();
    let all_lines = existing
        .keys()
        .chain(promotions.keys())
        .copied()
        .collect::<BTreeSet<_>>();
    let mut ancestry: Vec<(u8, Role)> = Vec::new();
    for line in all_lines {
        let entry = if let Some(o) = existing.get(&line) {
            o.clone()
        } else {
            let depth = ancestry
                .iter()
                .rev()
                .find(|(_, role)| *role == Role::Volume)
                .map_or(0, |(d, _)| d + 1);
            let o = Override {
                source_line: line,
                role: Role::Chapter,
                depth,
                include_toc: true,
            };
            settings.overrides.push(o.clone());
            let original = promotions[&line];
            stable_ids.insert(
                line,
                format!(
                    "{}:{}",
                    source.summary().source_id,
                    source.decoded_line_ranges()[original as usize - 1].0
                ),
            );
            o
        };
        while ancestry.last().is_some_and(|(d, _)| *d >= entry.depth) {
            ancestry.pop();
        }
        ancestry.push((entry.depth, entry.role));
    }
    // Recognition must not resurrect headings previously classified as body.
    for node in Structure::new(&cleaned).tree(&cleaned)?.nodes {
        if !stable_ids.contains_key(&node.source_line) {
            settings.overrides.push(Override {
                source_line: node.source_line,
                role: Role::Body,
                depth: 0,
                include_toc: false,
            });
        }
    }
    let mut tree = settings.tree(&cleaned)?;
    // Cleanup changes text, not the book's chosen recognition policy or its
    // original-coordinate review decisions. Dropping these also invalidates an
    // otherwise unchanged base underneath subsequent chapter edits.
    tree.recognition_rules = book.tree.recognition_rules.clone();
    tree.recognition_decisions = book.tree.recognition_decisions.clone();
    let ids = tree
        .nodes
        .iter()
        .map(|n| (n.entry_id.clone(), stable_ids[&n.source_line].clone()))
        .collect::<BTreeMap<_, _>>();
    for node in &mut tree.nodes {
        node.entry_id = ids[&node.entry_id].clone();
        node.parent_id = node.parent_id.as_ref().map(|id| ids[id].clone());
    }
    book.cleanup_evidence = Some(json!({
        "coordinate_system":"after_manual_before_cleanup",
        "source_line_origins":origins,
        "stage":serde_json::from_slice::<Value>(&cleanup.evidence()).expect("cleanup evidence")
    }));
    book.source_to_output_lines = book
        .source_to_output_lines
        .iter()
        .filter_map(|(&original, &edited)| line_map.get(&edited).map(|&out| (original, out)))
        .collect();
    book.text = cleanup.text().to_owned();
    book.text_changed = book.text != source.decoded_text();
    book.tree = tree;
    Ok(book)
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct OutputRequest {
    kind: String,
    #[serde(default)]
    allow_unchanged_copy: bool,
    #[serde(default)]
    structure: Option<Structure>,
    #[serde(default)]
    manual: Option<Value>,
    #[serde(default)]
    cleanup: Option<Value>,
    #[serde(default)]
    preview_offset: usize,
    #[serde(default)]
    post_edits: Option<crate::effective_edit::Request>,
}
pub struct OutputPlan {
    editing_base_id: String,
    pub book: EffectiveBook,
    id: String,
    evidence: Value,
    changes: Vec<Value>,
    offset: usize,
}
pub fn prepare_output(source: &SourceSnapshot, request: &str) -> Result<OutputPlan, ApiError> {
    let invalid = || ApiError::new(ErrorCode::InvalidRule, "publication", "review_composition");
    if request.len() > 3 * 1024 * 1024 {
        return Err(invalid());
    }
    let request: OutputRequest = serde_json::from_str(request).map_err(|_| invalid())?;
    if request.kind != "publication" {
        return Err(invalid());
    }
    let structure = request
        .structure
        .clone()
        .unwrap_or_else(|| Structure::new(source));
    let manual = request.manual.as_ref().map(Value::to_string);
    let cleanup = request.cleanup.as_ref().map(Value::to_string);
    let book = compose_with_cleanup(source, &structure, manual.as_deref(), cleanup.as_deref())?;
    let manual_evidence = if let Some(manual) = &manual {
        Some(
            serde_json::from_slice::<Value>(
                &manual_edit::prepare_with_structure(source, manual, Some(&structure))?
                    .evidence(source),
            )
            .map_err(|_| invalid())?,
        )
    } else {
        None
    };
    prepare_composed_output(
        source,
        serde_json::to_value(request).map_err(|_| invalid())?,
        book,
        manual_evidence,
        None,
        Vec::new(),
    )
}

/// Finalize a server-composed book; callers must validate any external catalog.
pub fn prepare_composed_output(
    source: &SourceSnapshot,
    request: Value,
    book: EffectiveBook,
    manual_evidence: Option<Value>,
    catalog_evidence: Option<Value>,
    changes: Vec<Value>,
) -> Result<OutputPlan, ApiError> {
    prepare_composed_output_resolved(
        source,
        request,
        book,
        manual_evidence,
        catalog_evidence,
        changes,
        None,
    )
}

pub fn prepare_composed_output_resolved(
    source: &SourceSnapshot,
    mut request: Value,
    book: EffectiveBook,
    manual_evidence: Option<Value>,
    catalog_evidence: Option<Value>,
    mut changes: Vec<Value>,
    resolved_edits: Option<(String, Vec<Value>)>,
) -> Result<OutputPlan, ApiError> {
    let invalid = || ApiError::new(ErrorCode::InvalidRule, "publication", "review_composition");
    if request["kind"] != "publication" || book.original_source_id != source.summary().source_id {
        return Err(invalid());
    }
    let offset = request
        .get("preview_offset")
        .map(|v| {
            v.as_u64()
                .and_then(|n| usize::try_from(n).ok())
                .ok_or_else(invalid)
        })
        .transpose()?
        .unwrap_or(0);
    request["preview_offset"] = json!(0);
    let (mut book, post_evidence, editing_base_id) =
        if let Some((base_id, evidence)) = resolved_edits {
            (book, evidence, base_id)
        } else {
            let post_edits: Option<crate::effective_edit::Request> = request
                .get("post_edits")
                .filter(|v| !v.is_null())
                .map(|v| serde_json::from_value(v.clone()).map_err(|_| invalid()))
                .transpose()?;
            let editing_base_id = crate::effective_edit::base_id(&book);
            let (book, post_evidence) = if let Some(edits) = &post_edits {
                crate::effective_edit::apply(book, edits)?
            } else {
                (book, Vec::new())
            };
            (book, post_evidence, editing_base_id)
        };
    book.text_changed = book.text != source.decoded_text();
    let mut hash = Sha256::new();
    hash.update(b"publication-output-v3");
    hash.update(source.summary().source_id.as_bytes());
    hash.update(serde_json::to_vec(&request).map_err(|_| invalid())?);
    hash.update(book.text.as_bytes());
    let id = format!("{:x}", hash.finalize());
    if let Some(stage) = &manual_evidence {
        for change in stage["changes"].as_array().into_iter().flatten() {
            let mut change = change.clone();
            change["stage"] = json!("manual");
            changes.push(change);
        }
    }
    if let Some(stage) = &book.cleanup_evidence {
        for change in stage["stage"]["changes"].as_array().into_iter().flatten() {
            let mut change = change.clone();
            change["stage"] = json!("cleanup");
            let key = change["source_line"].to_string();
            change["original_source_line"] = stage["source_line_origins"][&key].clone();
            let end_key = change["source_end_line"].to_string();
            change["original_source_end_line"] = stage["source_line_origins"][&end_key].clone();
            changes.push(change);
        }
    }
    for (index, edit) in post_evidence.iter().enumerate() {
        for change in edit["stage"]["changes"].as_array().into_iter().flatten() {
            let mut change = change.clone();
            change["stage"] = json!("post_cleanup_edit");
            change["edit_index"] = json!(index);
            change["coordinate_system"] = json!("effective_book_before_this_action");
            changes.push(change);
        }
    }
    let evidence = json!({"schema":1,"kind":"publication","plan_id":id,"source_id":source.summary().source_id,
        "request":request,"catalog":catalog_evidence,"manual":manual_evidence,"cleanup":book.cleanup_evidence,"post_edits":post_evidence,"effective_structure":book.tree,
        "removed_structure_lines":book.removed_structure_lines,"text_utf8_sha256":format!("{:x}",Sha256::digest(book.text.as_bytes()))});
    Ok(OutputPlan {
        editing_base_id,
        book,
        id,
        evidence,
        changes,
        offset,
    })
}
impl OutputPlan {
    pub fn preview(&self) -> String {
        let actions = self
            .changes
            .iter()
            .skip(self.offset)
            .take(40)
            .map(|c| {
                let mut c = c.clone();
                let mut truncated = false;
                for key in ["before", "after"] {
                    if let Some(text) = c[key].as_str() {
                        truncated |= text.chars().count() > 500;
                        c[key] = json!(text.chars().take(500).collect::<String>());
                    }
                }
                c["truncated"] = json!(truncated);
                c
            })
            .collect::<Vec<_>>();
        json!({"kind":"publication","editing_base_id":self.editing_base_id,"plan_id":self.id,"writes":false,"requires_confirmation":true,
            "source_unchanged":true,"text_changed":self.book.text_changed,"unchanged_copy_allowed":!self.book.text_changed && self.evidence["request"]["allow_unchanged_copy"] == true,"change_count":self.changes.len(),
            "actions":actions,"preview_offset":self.offset,"page_size":40,
            "txt_structure_warning":"TXT retains text only; hierarchy and TOC settings are stored in audit evidence"}).to_string()
    }
    pub fn output(&self, source: &SourceSnapshot) -> Result<Vec<u8>, ApiError> {
        if !self.book.text_changed {
            return Ok(source.original_bytes().to_vec());
        }
        source.encode_edited_text(&self.book.text)
    }
    pub fn evidence(&self) -> Vec<u8> {
        serde_json::to_vec(&self.evidence).expect("publication evidence")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn issue_original_coordinates_follow_cleanup_and_never_guess() {
        let text = "第一章 起\n正文\n\n\n第三章 终\n尾文\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let cleanup =
            json!({"kind":"cleanup","pipeline":[{"kind":"collapse_blank_lines"}]}).to_string();
        let mut book =
            compose_with_cleanup(&source, &Structure::new(&source), None, Some(&cleanup)).unwrap();
        let page = book.check_page(0, Some(4)).unwrap();
        let issue = &page["report"]["diagnostic"]["review_items"][0];
        assert_eq!(issue["source_lines"][1], 4);
        assert_eq!(issue["original_source_lines"][1], 5);
        book.source_to_output_lines.insert(100, 4);
        assert_eq!(
            book.check_page(0, None).unwrap()["report"]["diagnostic"]["review_items"][0]["original_source_lines"]
                [1],
            Value::Null
        );
        book.source_to_output_lines.remove(&100);
        book.source_to_output_lines.remove(&5);
        assert_eq!(
            book.check_page(0, None).unwrap()["report"]["diagnostic"]["review_items"][0]["original_source_lines"]
                [1],
            Value::Null
        );
        assert_eq!(source.original_bytes(), text.as_bytes());
    }
    #[test]
    fn cleanup_recheck_maps_shifted_lines_but_rejects_missing_or_ambiguous_origins() {
        let text = "第一章 起\n正文  \n\n\n请收藏\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let cleanup = json!({"kind":"cleanup","pipeline":[
            {"kind":"trim_trailing_spaces"},{"kind":"collapse_blank_lines"}]})
        .to_string();
        let mut book =
            compose_with_cleanup(&source, &Structure::new(&source), None, Some(&cleanup)).unwrap();
        let report = book.cleanup_check_page(0).unwrap();
        assert_eq!(report["report"]["candidates"][0]["source_line"], 4);
        assert_eq!(report["report"]["candidates"][0]["original_source_line"], 5);
        book.source_to_output_lines.insert(100, 4);
        assert_eq!(
            book.cleanup_check_page(0).unwrap()["report"]["candidates"][0]["original_source_line"],
            Value::Null
        );
        book.source_to_output_lines.remove(&100);
        book.source_to_output_lines.remove(&5);
        assert_eq!(
            book.cleanup_check_page(0).unwrap()["report"]["candidates"][0]["original_source_line"],
            Value::Null
        );
        assert_eq!(source.original_bytes(), text.as_bytes());
    }

    #[test]
    fn cleanup_recheck_uses_effective_text_and_never_replays_custom_rules() {
        let text = "第一章 起\n甲文  \n请收藏\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let settings = Structure::new(&source);
        let original = compose(&source, &settings, None).unwrap();
        let before = original.cleanup_check_page(0).unwrap();
        assert_eq!(before["report"]["change_count"], 1);
        assert_eq!(before["report"]["candidate_count"], 1);
        let cleanup = json!({"kind":"cleanup", "pipeline":[
            {"kind":"trim_trailing_spaces"},{"kind":"remove_ad_lines"},
            {"kind":"literal_replace","find":"甲","replace":"甲甲"}],"remove_lines":[3]})
        .to_string();
        let changed = compose_with_cleanup(&source, &settings, None, Some(&cleanup)).unwrap();
        let frozen = changed.text.clone();
        let after = changed.cleanup_check_page(0).unwrap();
        assert_eq!(after["scope"], "effective_draft");
        assert_eq!(after["report"]["change_count"], 0);
        assert_eq!(after["report"]["candidate_count"], 0);
        assert_eq!(after["can_apply"], false);
        assert_ne!(before["composition_id"], after["composition_id"]);
        assert_eq!(changed.text, frozen);
        assert!(changed.text.contains("甲甲文"));
        assert!(!changed.text.contains("甲甲甲甲"));
        assert_eq!(source.original_bytes(), text.as_bytes());
        assert_eq!(
            original.cleanup_check_page(0).unwrap()["report"]["change_count"],
            1
        );
    }

    #[test]
    fn effective_check_rechecks_renamed_title_without_changing_original() {
        use crate::effective_edit::{self, Action, Request};
        let text = "第一章 起\n正文甲\n第三章 终\n正文乙\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let book = compose(&source, &Structure::new(&source), None).unwrap();
        let before = book.check_page(0, Some(3)).unwrap();
        assert_eq!(before["report"]["diagnostic"]["review_total"], 1);
        assert_eq!(before["excerpt"][2]["text"], "第三章 终");
        let request = Request {
            base_id: effective_edit::base_id(&book),
            actions: vec![Action::Rename {
                entry_id: book.tree.nodes[1].entry_id.clone(),
                title: "第二章 终".into(),
            }],
        };
        let changed = effective_edit::apply(book, &request).unwrap().0;
        let after = changed.check_page(0, Some(3)).unwrap();
        assert_eq!(after["report"]["diagnostic"]["review_total"], 0);
        assert_eq!(after["excerpt"][2]["text"], "第二章 终");
        assert_ne!(before["composition_id"], after["composition_id"]);
        assert!(source.diagnostic_json().contains("number-gap"));
        assert_eq!(source.original_bytes(), text.as_bytes());
    }

    #[test]
    fn effective_check_respects_body_override_and_bounds_problem_pages() {
        let text = "第一章 甲\n正文\n第九十九章 正文中的引用\n第二章 乙\n正文\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let mut structure = Structure::new(&source);
        structure
            .put(
                &source,
                Override {
                    source_line: 3,
                    role: Role::Body,
                    depth: 0,
                    include_toc: false,
                },
            )
            .unwrap();
        let book = compose(&source, &structure, None).unwrap();
        assert_eq!(
            book.check_page(0, None).unwrap()["report"]["diagnostic"]["review_total"],
            0
        );
        assert!(book.text.contains("第九十九章 正文中的引用"));
        assert!(source.diagnostic_json().contains("number-gap"));

        let text = (0..102)
            .map(|n| format!("第{}章 标题\n正文\n", n * 2 + 1))
            .collect::<String>();
        let source = SourceSnapshot::from_utf8(text.into_bytes(), RULE_ID, || false).unwrap();
        let book = compose(&source, &Structure::new(&source), None).unwrap();
        let page = book.check_page(50, None).unwrap();
        assert_eq!(page["report"]["diagnostic"]["review_total"], 101);
        assert_eq!(
            page["report"]["diagnostic"]["review_items"]
                .as_array()
                .unwrap()
                .len(),
            50
        );
        assert_eq!(
            book.check_page(100, None).unwrap()["report"]["diagnostic"]["review_items"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert!(book.check_page(102, None).is_err());
    }

    #[test]
    fn issue_positions_cover_every_finding_once_and_follow_review() {
        use crate::review::{Decision, Review, ReviewEvidence};
        let text = (0..102)
            .map(|n| format!("第{}章 标题\n正文\n", n * 2 + 1))
            .collect::<String>();
        let source = SourceSnapshot::from_utf8(text.into_bytes(), RULE_ID, || false).unwrap();
        let book = compose(&source, &Structure::new(&source), None).unwrap();
        let view = SourceSnapshot::for_effective_diagnostics(&book).unwrap();
        let evidence = ReviewEvidence::new(&view).unwrap();
        let repairs = crate::effective_repair::candidates(&book);
        let mut review = Review::default();
        let positions = |review: &Review, entry: Option<&str>| {
            book.issue_positions_using(&view, &evidence, &repairs, review, true, entry)
                .unwrap()
        };

        let all = positions(&review, None);
        assert_eq!(all["total"], 101);
        assert_eq!(all["open"], 101);
        assert_eq!(all["node_count"], 102);
        assert!(all["chapter"].is_null());
        let rows = all["nodes"].as_array().unwrap();
        assert_eq!(rows.iter().map(|r| r["count"].as_u64().unwrap()).sum::<u64>(), 101);
        let paged = (0..3)
            .flat_map(|page| {
                book.check_page(page * 50, None).unwrap()["report"]["diagnostic"]["review_items"]
                    .as_array()
                    .unwrap()
                    .clone()
            })
            .collect::<Vec<_>>();
        assert_eq!(paged.len(), 101);
        for row in rows {
            let index = row["index"].as_u64().unwrap() as usize;
            assert_eq!(row["entry_id"], book.tree.nodes[index].entry_id.as_str());
            assert_eq!(
                row["count"].as_u64().unwrap() as usize,
                paged.iter().filter(|item| item["entry_id"] == row["entry_id"]).count()
            );
        }

        let entry = rows[0]["entry_id"].as_str().unwrap().to_owned();
        let chapter = &positions(&review, Some(&entry))["chapter"];
        let items = chapter["items"].as_array().unwrap();
        assert!(!items.is_empty());
        assert_eq!(chapter["total"].as_u64().unwrap() as usize, items.len());
        let first = &items[0];
        let index = first["review_index"].as_u64().unwrap() as usize;
        assert_eq!(first["id"], paged[index]["id"]);
        assert_eq!(first["anchors"], paged[index]["anchors"]);
        assert_eq!(first["open"], true);

        review
            .set_using(
                &evidence,
                first["id"].as_str().unwrap(),
                evidence.stamp(),
                Some(Decision::Ignored),
                String::new(),
            )
            .unwrap();
        let reviewed = positions(&review, Some(&entry));
        assert_eq!(reviewed["total"], 101);
        assert_eq!(reviewed["open"], 100);
        assert_eq!(reviewed["chapter"]["items"][0]["open"], false);
        assert_eq!(reviewed["chapter"]["items"][0]["review"]["decision"], "ignored");

        let prefix = positions(&review, Some("$prefix"));
        assert_eq!(prefix["chapter"]["total"], 0);
        assert!(
            book.issue_positions_using(&view, &evidence, &repairs, &review, false, Some("missing"))
                .is_err()
        );
        assert!(book.issue_positions_using(&view, &evidence, &repairs, &review, false, None)
            .unwrap()["nodes"]
            .is_null());
    }

    #[test]
    fn effective_check_uses_named_volume_boundaries_and_structural_identity() {
        use crate::effective_edit::{self, Action, Request};
        let source = SourceSnapshot::from_utf8(
            "第八章 甲\n正文\n第二卷 中\n第一章 乙\n正文\n"
                .as_bytes()
                .to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let book = compose(&source, &Structure::new(&source), None).unwrap();
        let request = Request {
            base_id: effective_edit::base_id(&book),
            actions: vec![Action::Rename {
                entry_id: book.tree.nodes[1].entry_id.clone(),
                title: "悲悯诗篇".into(),
            }],
        };
        let mut book = effective_edit::apply(book, &request).unwrap().0;
        let before = book.check_page(0, None).unwrap();
        assert_eq!(before["report"]["diagnostic"]["review_total"], 0);
        let unchanged_text = book.text.clone();
        book.tree.nodes[1].role = Role::Chapter;
        let after = book.check_page(0, None).unwrap();
        assert_eq!(book.text, unchanged_text);
        assert_ne!(before["composition_id"], after["composition_id"]);
        assert_eq!(
            after["report"]["diagnostic"]["review_items"][0]["finding_id"],
            "number-reset"
        );
    }

    #[test]
    fn unchanged_copy_opt_in_is_preview_bound_and_preserves_all_encodings() {
        use crate::encoding::{EncodingKind, EncodingMode, encode};
        for kind in [
            EncodingKind::Utf8,
            EncodingKind::Utf16Le,
            EncodingKind::Utf16Be,
            EncodingKind::Utf32Le,
            EncodingKind::Utf32Be,
            EncodingKind::Cp936,
        ] {
            let bytes = encode(
                "第一章 甲\r\n正文\n末行无换行",
                kind,
                kind != EncodingKind::Cp936,
            )
            .unwrap();
            let source =
                SourceSnapshot::from_bytes(bytes.clone(), EncodingMode::Auto, RULE_ID, || false)
                    .unwrap();
            let plain = prepare_output(&source, r#"{"kind":"publication"}"#).unwrap();
            let copy = prepare_output(
                &source,
                r#"{"kind":"publication","allow_unchanged_copy":true}"#,
            )
            .unwrap();
            let plain_preview: Value = serde_json::from_str(&plain.preview()).unwrap();
            let copy_preview: Value = serde_json::from_str(&copy.preview()).unwrap();
            assert_eq!(plain_preview["unchanged_copy_allowed"], false);
            assert_eq!(copy_preview["unchanged_copy_allowed"], true);
            assert_eq!(copy_preview["text_changed"], false);
            assert_ne!(plain_preview["plan_id"], copy_preview["plan_id"]);
            assert_eq!(copy.output(&source).unwrap(), bytes);
            assert_eq!(copy.evidence["request"]["allow_unchanged_copy"], true);
        }
    }

    #[test]
    fn illustration_in_expanded_region_requires_relocation() {
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n甲上\n甲下\n未改行".as_bytes().to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let cleanup=json!({"kind":"cleanup","pipeline":[{"kind":"multiline_regex_replace","pattern":"甲上\\n甲下","replace":"合并\\n新增\\n三行"}]}).to_string();
        let book =
            compose_with_cleanup(&source, &Structure::new(&source), None, Some(&cleanup)).unwrap();
        assert_eq!(
            book.illustration_position(&source.summary().source_id, Some(2))
                .unwrap(),
            IllustrationPosition::NeedsRelocation { source_line: 2 }
        );
        assert_eq!(
            book.illustration_position(&source.summary().source_id, Some(4))
                .unwrap(),
            IllustrationPosition::AfterLine {
                source_line: 4,
                output_line: 5
            }
        );
    }
    #[test]
    fn illustration_anchors_follow_moves_and_joined_lines_without_guessing() {
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n这是长长的断\n行继续。\n第二章 乙\n另一处长长断\n行完成。\n"
                .as_bytes()
                .to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let structure = Structure::new(&source);
        let id = source.summary().source_id;
        let manual = r#"{"kind":"manual_batch","actions":[{"kind":"move_chapter","source_line":4,"before_line":1}]}"#;
        let cleanup = r#"{"kind":"cleanup","pipeline":[{"kind":"join_hard_wraps","mode":"chinese","min_chars":4}]}"#;
        let book = compose_with_cleanup(&source, &structure, Some(manual), Some(cleanup)).unwrap();
        assert_eq!(
            book.illustration_position(&id, Some(6)).unwrap(),
            IllustrationPosition::AfterLine {
                source_line: 6,
                output_line: 2
            }
        );
        assert_eq!(
            book.illustration_position(&id, Some(3)).unwrap(),
            IllustrationPosition::AfterLine {
                source_line: 3,
                output_line: 4
            }
        );
        assert_eq!(
            book.illustration_position(&id, None).unwrap(),
            IllustrationPosition::Unplaced
        );
        assert!(book.illustration_position("other-book", Some(3)).is_err());
        let excluded = r#"{"kind":"manual_batch","actions":[{"kind":"exclude_lines","source_line":3,"end_line":3}]}"#;
        let book = compose(&source, &structure, Some(excluded)).unwrap();
        assert_eq!(
            book.illustration_position(&id, Some(3)).unwrap(),
            IllustrationPosition::NeedsRelocation { source_line: 3 }
        );
        assert_eq!(
            book.illustration_position(&id, Some(6)).unwrap(),
            IllustrationPosition::AfterLine {
                source_line: 6,
                output_line: 5
            }
        );
    }
    #[test]
    fn existing_numeric_volume_and_section_keep_their_logical_roles() {
        let raw = "001 故事\n002 剧情\n003 细节\n004 前言";
        let source = SourceSnapshot::from_utf8(raw.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let mut structure = Structure::new(&source);
        for (source_line, role, depth) in [
            (1, Role::Volume, 0),
            (2, Role::Chapter, 1),
            (3, Role::Section, 2),
            (4, Role::Front, 1),
        ] {
            structure
                .put(
                    &source,
                    Override {
                        source_line,
                        role,
                        depth,
                        include_toc: true,
                    },
                )
                .unwrap();
        }
        let before = structure.tree(&source).unwrap().nodes;
        let req = r#"{"kind":"cleanup","pipeline":[{"kind":"chapter_numbers","style":"chinese","bare_titles":false}]}"#;
        let book = compose_with_cleanup(&source, &structure, None, Some(req)).unwrap();
        assert_eq!(book.text, "第一卷 故事\n第二章 剧情\n第三节 细节\n004 前言");
        for (old, new) in before.iter().zip(&book.tree.nodes) {
            assert_eq!(old.role, new.role);
            assert_eq!(old.entry_id, new.entry_id);
            assert_eq!(old.depth, new.depth);
        }
    }
    #[test]
    fn bare_only_book_gains_root_chapters_without_losing_prefix_or_body() {
        let raw = "序前说明。\n001 雨夜\r\n正文,段落\n002 黎明\r结尾。";
        let source = SourceSnapshot::from_utf8(raw.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        assert!(source.headings().is_empty());
        let structure = Structure::new(&source);
        let cleanup = r#"{"kind":"cleanup","pipeline":[{"kind":"chapter_numbers","style":"arabic","bare_titles":true}]}"#;
        let book = compose_with_cleanup(&source, &structure, None, Some(cleanup)).unwrap();
        assert_eq!(
            book.tree
                .nodes
                .iter()
                .map(|n| (n.title.as_str(), n.depth))
                .collect::<Vec<_>>(),
            [("第1章 雨夜", 0), ("第2章 黎明", 0)]
        );
        assert_eq!(&book.text[..book.tree.prefix_end], "序前说明。\n");
        assert_eq!(
            book.text,
            "序前说明。\n第1章 雨夜\r\n正文,段落\n第2章 黎明\r结尾。"
        );
        assert_eq!(book.tree.source_bytes_covered, book.text.len());
    }
    #[test]
    fn explicit_numeric_titles_create_stable_volume_children_but_preserve_body_overrides() {
        let raw = "第一卷 故事\r\n001 雨夜\n正文,来了\r002 明确正文\n第三章 后续\n正文";
        let source = SourceSnapshot::from_utf8(raw.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let mut structure = Structure::new(&source);
        structure
            .put(
                &source,
                Override {
                    source_line: 4,
                    role: Role::Body,
                    depth: 0,
                    include_toc: false,
                },
            )
            .unwrap();
        let request=json!({"kind":"cleanup","pipeline":[{"kind":"chapter_numbers","style":"chinese","bare_titles":true}]}).to_string();
        let first = compose_with_cleanup(&source, &structure, None, Some(&request)).unwrap();
        assert_eq!(
            first.text,
            "第一卷 故事\r\n第一章 雨夜\n正文,来了\r002 明确正文\n第三章 后续\n正文"
        );
        assert_eq!(first.tree.nodes.len(), 3);
        assert_eq!(first.tree.nodes[1].role, Role::Chapter);
        assert_eq!(first.tree.nodes[1].depth, 1);
        assert_eq!(
            first.tree.nodes[1].parent_id,
            Some(first.tree.nodes[0].entry_id.clone())
        );
        let expected_id = format!(
            "{}:{}",
            source.summary().source_id,
            source.decoded_line_ranges()[1].0
        );
        assert_eq!(first.tree.nodes[1].entry_id, expected_id);
        assert_eq!(first.tree.source_bytes_covered, first.text.len());
        let manual=json!({"kind":"manual_batch","actions":[{"kind":"move_chapter","source_line":5,"before_line":2}]}).to_string();
        // Bare title is not a pre-existing manual move anchor; move before the volume's first chapter instead.
        assert!(compose_with_cleanup(&source, &structure, Some(&manual), Some(&request)).is_err());
        let manual=json!({"kind":"manual_batch","actions":[{"kind":"rename_title","source_line":5,"title":"第３章 新名"}]}).to_string();
        let next =
            compose_with_cleanup(&source, &structure, Some(&manual), Some(&request)).unwrap();
        assert_eq!(next.tree.nodes[1].entry_id, expected_id);
        assert_eq!(next.tree.nodes[2].title, "第三章 新名");
        assert_eq!(source.decoded_text(), raw);
    }
    #[test]
    fn multiline_expansion_preserves_ids_and_actual_mixed_ending_coordinates() {
        let raw = "第一章 甲\r占位\r第二章 乙\n正文";
        let source = SourceSnapshot::from_utf8(raw.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let structure = Structure::new(&source);
        let ids: Vec<_> = structure
            .tree(&source)
            .unwrap()
            .nodes
            .into_iter()
            .map(|n| n.entry_id)
            .collect();
        let cleanup = json!({"kind":"cleanup","pipeline":[{"kind":"multiline_regex_replace","pattern":"占位","replace":r"\n新增\n第三章 仅为正文\n后行"}]}).to_string();
        let book = compose_with_cleanup(&source, &structure, None, Some(&cleanup)).unwrap();
        assert_eq!(
            book.text,
            "第一章 甲\r\n新增\n第三章 仅为正文\n后行\r第二章 乙\n正文"
        );
        assert_eq!(
            book.tree
                .nodes
                .iter()
                .map(|n| n.entry_id.clone())
                .collect::<Vec<_>>(),
            ids
        );
        assert_eq!(
            book.tree
                .nodes
                .iter()
                .map(|n| n.source_line)
                .collect::<Vec<_>>(),
            vec![1, 5]
        );
        assert_eq!(book.tree.source_bytes_covered, book.text.len());
    }
    #[test]
    fn joined_moved_chapters_keep_ids_and_multi_source_line_mapping() {
        let raw = "第一章 甲\n这是长长的断\n行继续。\n第二章 乙\n另一处长长断\n行完成。\n";
        let source = SourceSnapshot::from_utf8(raw.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let structure = Structure::new(&source);
        let ids = structure
            .tree(&source)
            .unwrap()
            .nodes
            .iter()
            .map(|n| n.entry_id.clone())
            .collect::<Vec<_>>();
        let request = json!({"kind":"publication","manual":{"kind":"manual_batch","actions":[{"kind":"move_chapter","source_line":4,"before_line":1}]},"cleanup":{"kind":"cleanup","pipeline":[{"kind":"join_hard_wraps","mode":"chinese","min_chars":4},{"kind":"literal_replace","find":"断行","replace":"整句"}]}});
        let plan = prepare_output(&source, &request.to_string()).unwrap();
        assert_eq!(
            plan.book.text,
            "第二章 乙\n另一处长长整句完成。\n第一章 甲\n这是长长的整句继续。\n"
        );
        assert_eq!(
            plan.book
                .tree
                .nodes
                .iter()
                .map(|n| n.entry_id.clone())
                .collect::<Vec<_>>(),
            vec![ids[1].clone(), ids[0].clone()]
        );
        let stage = &plan.evidence["cleanup"]["stage"];
        assert_eq!(
            stage["source_to_output_lines"],
            json!([[1, 1], [2, 2], [3, 2], [4, 3], [5, 4], [6, 4]])
        );
        let first = plan
            .changes
            .iter()
            .find(|c| c["stage"] == "cleanup")
            .unwrap();
        assert_eq!(first["original_source_line"], 5);
        assert_eq!(first["original_source_end_line"], 6);
        assert_eq!(plan.book.tree.source_bytes_covered, plan.book.text.len());
    }
    #[test]
    fn logical_heading_and_manual_exclusion_are_join_barriers() {
        let raw = "第一章 甲\n第一段正文未完\n无编号结构标题\n下一段正文未完\n尾句。\n";
        let source = SourceSnapshot::from_utf8(raw.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let mut structure = Structure::new(&source);
        structure
            .put(
                &source,
                Override {
                    source_line: 3,
                    role: Role::Front,
                    depth: 0,
                    include_toc: false,
                },
            )
            .unwrap();
        let cleanup = r#"{"kind":"cleanup","pipeline":[{"kind":"join_hard_wraps","mode":"chinese","min_chars":4}]}"#;
        let book = compose_with_cleanup(&source, &structure, None, Some(cleanup)).unwrap();
        assert_eq!(
            book.text,
            "第一章 甲\n第一段正文未完\n无编号结构标题\n下一段正文未完尾句。\n"
        );
        assert_eq!(book.tree.nodes.len(), 2);
        assert!(!book.tree.nodes[1].include_toc);
        let manual = r#"{"kind":"manual_batch","actions":[{"kind":"exclude_lines","source_line":3,"end_line":3}]}"#;
        let book = compose_with_cleanup(
            &source,
            &Structure::new(&source),
            Some(manual),
            Some(cleanup),
        )
        .unwrap();
        assert_eq!(
            book.text,
            "第一章 甲\n第一段正文未完\n下一段正文未完\n尾句。\n"
        );
    }
    #[test]
    fn output_plan_pagination_is_stable_and_structure_changes_invalidate_id() {
        let source =
            SourceSnapshot::from_utf8("第一章 甲\n正文  ".as_bytes().to_vec(), RULE_ID, || false)
                .unwrap();
        let mut request = json!({"kind":"publication","cleanup":{"kind":"cleanup","rules":["trim_trailing_spaces"]}});
        let first = prepare_output(&source, &request.to_string()).unwrap();
        request["preview_offset"] = json!(40);
        let next = prepare_output(&source, &request.to_string()).unwrap();
        assert_eq!(first.id, next.id);
        assert_eq!(
            first.output(&source).unwrap(),
            next.output(&source).unwrap()
        );
        let mut structure = Structure::new(&source);
        structure
            .put(
                &source,
                Override {
                    source_line: 1,
                    role: Role::Chapter,
                    depth: 0,
                    include_toc: false,
                },
            )
            .unwrap();
        request["structure"] = serde_json::to_value(structure).unwrap();
        let changed = prepare_output(&source, &request.to_string()).unwrap();
        assert_ne!(first.id, changed.id);
        assert_eq!(
            first.output(&source).unwrap(),
            changed.output(&source).unwrap()
        );
    }
    #[test]
    fn cleanup_scope_follows_moved_original_lines_and_retains_demotions() {
        let text = "第一章 甲\r\n甲文  \n第二章 乙\n乙文  \n\n本章完\n第三章 误识别\n尾文";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let mut structure = Structure::new(&source);
        structure
            .put(
                &source,
                Override {
                    source_line: 7,
                    role: Role::Body,
                    depth: 0,
                    include_toc: false,
                },
            )
            .unwrap();
        let ids = structure
            .tree(&source)
            .unwrap()
            .nodes
            .iter()
            .map(|n| n.entry_id.clone())
            .collect::<Vec<_>>();
        let manual = r#"{"kind":"manual_batch","actions":[{"kind":"move_chapter","source_line":3,"before_line":1}]}"#;
        let cleanup = r#"{"kind":"cleanup","rules":["trim_trailing_spaces","remove_ad_lines"],"start_line":4,"end_line":6,"remove_lines":[6]}"#;
        let book = compose_with_cleanup(&source, &structure, Some(manual), Some(cleanup)).unwrap();
        assert_eq!(
            book.text,
            "第二章 乙\n乙文\n\n第三章 误识别\n尾文\n第一章 甲\r\n甲文  \n"
        );
        assert_eq!(book.tree.nodes.len(), 2);
        // A heading explicitly demoted to body belongs to the preceding chapter.
        // It must travel with that chapter, including the following tail text.
        assert_eq!(book.source_to_output_lines.get(&7), Some(&4));
        assert_eq!(book.source_to_output_lines.get(&8), Some(&5));
        let moved = &book.tree.nodes[0];
        assert!(book.text[moved.body_start..moved.end].contains("第三章 误识别\n尾文"));
        assert_eq!(book.tree.nodes[0].entry_id, ids[1]);
        assert_eq!(book.tree.nodes[1].entry_id, ids[0]);
        assert_eq!(book.tree.source_bytes_covered, book.text.len());
        assert_eq!(source.decoded_text(), text);
    }
    #[test]
    fn cleanup_preserves_inserted_heading_and_rejects_structural_notice_deletion() {
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n本章完\n尾文  ".as_bytes().to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let manual = r#"{"kind":"manual_batch","actions":[{"kind":"set_volume","source_line":1,"volume_title":"自定卷名"}]}"#;
        let cleanup = r#"{"kind":"cleanup","rules":["trim_trailing_spaces","remove_ad_lines"],"remove_lines":[2]}"#;
        let mut structure = Structure::new(&source);
        structure.recognition_rules = Some(crate::chapter_rules::RuleSet::default());
        let plain = compose(&source, &structure, None).unwrap();
        let unchanged = compose_with_cleanup(&source, &structure, None,
            Some(r#"{"kind":"cleanup","pipeline":[]}"#)).unwrap();
        assert_eq!(crate::effective_edit::base_id(&plain),crate::effective_edit::base_id(&unchanged));
        let book = compose_with_cleanup(&source, &structure, Some(manual), Some(cleanup)).unwrap();
        assert_eq!(book.text, "自定卷名\n第一章 甲\n尾文");
        assert_eq!(book.tree.nodes.len(), 2);
        structure
            .put(
                &source,
                Override {
                    source_line: 2,
                    role: Role::Chapter,
                    depth: 0,
                    include_toc: true,
                },
            )
            .unwrap();
        assert!(compose_with_cleanup(&source, &structure, None, Some(cleanup)).is_err());
    }
    #[test]
    fn moved_renamed_hidden_node_keeps_identity_and_demoted_text_remains_body() {
        let source = SourceSnapshot::from_utf8(
            "第一章 甲\n甲文\n第二章 乙\n乙文\n第三章 误识别\n尾文"
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
                    role: Role::Chapter,
                    depth: 0,
                    include_toc: false,
                },
            )
            .unwrap();
        structure
            .put(
                &source,
                Override {
                    source_line: 5,
                    role: Role::Body,
                    depth: 0,
                    include_toc: false,
                },
            )
            .unwrap();
        let id = structure.tree(&source).unwrap().nodes[1].entry_id.clone();
        let actions=json!({"kind":"manual_batch","actions":[{"kind":"move_chapter","source_line":3,"before_line":1},{"kind":"rename_title","source_line":3,"title":"没有编号的新标题"}]}).to_string();
        let composed = compose(&source, &structure, Some(&actions)).unwrap();
        assert_eq!(composed.tree.nodes[0].entry_id, id);
        assert!(!composed.tree.nodes[0].include_toc);
        assert_eq!(composed.tree.nodes[0].title, "没有编号的新标题");
        assert!(composed.text.contains("第三章 误识别\n尾文"));
        assert_eq!(composed.tree.nodes.len(), 2);
        assert_eq!(composed.tree.source_bytes_covered, composed.text.len());
    }
    #[test]
    fn inserted_named_volume_and_split_become_stable_structural_nodes() {
        let s = SourceSnapshot::from_utf8(
            "第一章 甲\r\n甲上\n甲下".as_bytes().to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let request=json!({"kind":"manual_batch","actions":[{"kind":"set_volume","source_line":1,"volume_title":"无编号卷名"},{"kind":"split_chapter","source_line":3,"title":"第二章 新章"}]}).to_string();
        let book = compose(&s, &Structure::new(&s), Some(&request)).unwrap();
        assert_eq!(book.tree.nodes.len(), 3);
        assert_eq!(book.tree.nodes[0].role, Role::Volume);
        assert_eq!(
            book.tree.nodes[1].parent_id.as_ref(),
            Some(&book.tree.nodes[0].entry_id)
        );
        assert!(
            book.tree.nodes[2]
                .entry_id
                .contains("insert:split_chapter:3")
        );
    }
    #[test]
    fn excluded_override_is_reported_not_reapplied_to_another_line() {
        let s = SourceSnapshot::from_utf8(
            "第一章 甲\n甲文\n第二章 乙\n乙文".as_bytes().to_vec(),
            RULE_ID,
            || false,
        )
        .unwrap();
        let mut structure = Structure::new(&s);
        structure
            .put(
                &s,
                Override {
                    source_line: 3,
                    role: Role::Chapter,
                    depth: 0,
                    include_toc: false,
                },
            )
            .unwrap();
        let request=json!({"kind":"manual_batch","actions":[{"kind":"exclude_lines","source_line":3,"end_line":4}]}).to_string();
        let book = compose(&s, &structure, Some(&request)).unwrap();
        assert_eq!(book.removed_structure_lines, vec![3]);
        assert_eq!(book.tree.nodes.len(), 1);
    }
}
