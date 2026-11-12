//! Review decisions never edit text or turn findings into repaired facts.
use crate::{
    ApiError, ErrorCode,
    source::{RULE_ID, SourceSnapshot},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Decision {
    ConfirmedNormal,
    Ignored,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Record {
    pub evidence_id: String,
    pub decision: Decision,
    pub note: String,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Review {
    pub records: BTreeMap<String, Record>,
}
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "finding_review",
        "review_current_findings",
    )
}
fn evidence(source: &SourceSnapshot) -> Result<(String, Value), ApiError> {
    let value = ReviewEvidence::new(source)?;
    Ok((value.stamp, value.diagnostic))
}

/// Expensive immutable detection is separate from inexpensive review decisions.
pub struct ReviewEvidence {
    pub(crate) stamp: String,
    diagnostic: Value,
    items: Vec<Value>,
    /// 成片出现的原因：同一个原因引出的许多条问题合成一条来讲。见 [`mark_causes`]。
    causes: Vec<Value>,
    /// 报告顺序：`items` 的下标按“要做的事”排好。问题可能上万条，只排一次。
    order: std::sync::OnceLock<Vec<u32>>,
    /// 问题 id → 它在报告里的位置。筛选后的列表要用它和进度条对上。
    offsets: std::sync::OnceLock<BTreeMap<String, u32>>,
}
impl ReviewEvidence {
    /// 认全 → 去重 → 归位，组内按类别、行号；排序稳定，同一行的多条问题保持原有先后。
    fn ordered(&self) -> &[u32] {
        self.order.get_or_init(|| {
            let mut order = (0..self.items.len() as u32).collect::<Vec<_>>();
            order.sort_by_cached_key(|&index| {
                let item = &self.items[index as usize];
                let id = item["finding_id"].as_str().unwrap_or("");
                let line = item["source_lines"][0].as_u64().unwrap_or(u64::MAX);
                // 归到某个原因的排在最前，按原因、行号；其余照旧。
                match cause_rank(item) {
                    Some(rank) => (rank, 0, 0, line),
                    None => (u8::MAX, issue_group(id), issue_category_rank(id), line),
                }
            });
            order
        })
    }
    fn offsets(&self) -> &BTreeMap<String, u32> {
        self.offsets.get_or_init(|| {
            self.ordered()
                .iter()
                .enumerate()
                .map(|(position, index)| {
                    let id = self.items[*index as usize]["id"].as_str().unwrap_or("");
                    (id.to_owned(), position as u32)
                })
                .collect()
        })
    }
    pub fn new(source: &SourceSnapshot) -> Result<Self, ApiError> {
        let diagnostic =
            serde_json::from_str(&source.diagnostic_json()).expect("internal diagnostic");
        let mut items = items(source)?;
        let causes = mark_causes(source, &mut items);
        let material = json!(["finding-review-v2", RULE_ID, diagnostic, items]);
        let stamp = format!("{:x}", Sha256::digest(material.to_string().as_bytes()));
        Ok(Self {
            stamp,
            diagnostic,
            items,
            causes,
            order: std::sync::OnceLock::new(),
            offsets: std::sync::OnceLock::new(),
        })
    }
    pub fn stamp(&self) -> &str {
        &self.stamp
    }
}
fn items(source: &SourceSnapshot) -> Result<Vec<Value>, ApiError> {
    let plan: Value = serde_json::from_str(&source.repair_plan_json(
        r#"["duplicate-content","prose-heading","unrecognized-heading","duplicate-title","number-reset","number-gap","chapter-misplaced","no-headings","missing-heading-prefix","heading-number-typo"]"#,
    )?)
    .map_err(|_| invalid())?;
    Ok(plan["actions"].as_array().ok_or_else(invalid)?.clone())
}
impl Review {
    pub fn validate_shape(&self) -> Result<(), ApiError> {
        if self.records.len() > 10000 {
            return Err(invalid());
        }
        for (key, r) in &self.records {
            if key.is_empty()
                || key.len() > 128
                || r.note.len() > 4096
                || r.evidence_id.len() != 64
                || !r
                    .evidence_id
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            {
                return Err(invalid());
            }
        }
        Ok(())
    }
    pub fn set(
        &mut self,
        source: &SourceSnapshot,
        id: &str,
        expected_evidence: &str,
        decision: Option<Decision>,
        note: String,
    ) -> Result<(), ApiError> {
        self.set_using(
            &ReviewEvidence::new(source)?,
            id,
            expected_evidence,
            decision,
            note,
        )
    }
    pub fn set_using(
        &mut self,
        evidence: &ReviewEvidence,
        id: &str,
        expected_evidence: &str,
        decision: Option<Decision>,
        note: String,
    ) -> Result<(), ApiError> {
        self.validate_shape()?;
        let stamp = evidence.stamp.as_str();
        let diagnostic = &evidence.diagnostic;
        let known_category = diagnostic["findings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|f| f["id"] == id);
        if stamp != expected_evidence
            || (!known_category && !evidence.items.iter().any(|f| f["id"] == id))
        {
            return Err(invalid());
        }
        let mut candidate = self.clone();
        if let Some(decision) = decision {
            candidate.records.insert(
                id.into(),
                Record {
                    evidence_id: stamp.to_owned(),
                    decision,
                    note,
                },
            );
        } else {
            candidate.records.remove(id);
        }
        candidate.validate_shape()?;
        *self = candidate;
        Ok(())
    }
    pub fn suppressed(&self, source: &SourceSnapshot) -> Result<Vec<String>, ApiError> {
        self.validate_shape()?;
        let (stamp, _) = evidence(source)?;
        Ok(self
            .records
            .iter()
            .filter(|(_, r)| r.evidence_id == stamp)
            .map(|(id, _)| id.clone())
            .collect())
    }
    pub fn report(&self, source: &SourceSnapshot) -> Result<Value, ApiError> {
        self.report_page(source, 0)
    }
    pub fn report_page(&self, source: &SourceSnapshot, offset: usize) -> Result<Value, ApiError> {
        self.report_filtered(source, offset, None, None)
    }
    pub fn report_filtered(
        &self,
        source: &SourceSnapshot,
        offset: usize,
        category: Option<&str>,
        severity: Option<&str>,
    ) -> Result<Value, ApiError> {
        self.report_using(&ReviewEvidence::new(source)?, offset, category, severity)
    }
    /// Every current finding, unpaged and unfiltered, in report order. Each item
    /// carries `severity`, `review_index` (its position in the unfiltered report)
    /// and `open` (no current decision on the item or its category).
    pub fn all_using(&self, evidence: &ReviewEvidence) -> Result<Vec<Value>, ApiError> {
        self.validate_shape()?;
        let stamp = evidence.stamp.as_str();
        let severities = evidence.diagnostic["findings"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|f| Some((f["id"].as_str()?, f["severity"].as_str().unwrap_or("info"))))
            .collect::<BTreeMap<_, _>>();
        let current = |id: &str| self.records.get(id).filter(|r| r.evidence_id == stamp);
        Ok(evidence
            .items
            .iter()
            .enumerate()
            .map(|(index, item)| {
                let mut item = item.clone();
                let group = item["finding_id"].as_str().unwrap_or("").to_owned();
                let record = current(item["id"].as_str().unwrap_or(""));
                item["severity"] = json!(severities.get(group.as_str()).copied().unwrap_or("info"));
                item["review_index"] = json!(index);
                item["category_reviewed"] = json!(current(&group).is_some());
                item["open"] = json!(record.is_none() && current(&group).is_none());
                if let Some(record) = record {
                    item["review"] = serde_json::to_value(record).unwrap();
                }
                item
            })
            .collect())
    }
    /// 还没下结论的问题在报告里的位置，升序。只读这一份下标，不复制任何问题内容，
    /// 进度条据此按位置取页。
    pub fn open_queue(&self, evidence: &ReviewEvidence) -> Result<Vec<u32>, ApiError> {
        self.validate_shape()?;
        let stamp = evidence.stamp.as_str();
        let decided = |id: &str| self.records.get(id).is_some_and(|r| r.evidence_id == stamp);
        Ok(evidence
            .ordered()
            .iter()
            .enumerate()
            .filter(|(_, index)| {
                let item = &evidence.items[**index as usize];
                !decided(item["id"].as_str().unwrap_or(""))
                    && !decided(item["finding_id"].as_str().unwrap_or(""))
            })
            .map(|(position, _)| position as u32)
            .collect())
    }
    pub fn report_using(
        &self,
        evidence: &ReviewEvidence,
        offset: usize,
        category: Option<&str>,
        severity: Option<&str>,
    ) -> Result<Value, ApiError> {
        if category.is_some_and(|v| {
            ![
                "duplicate-content",
                "prose-heading",
                "unrecognized-heading",
                "duplicate-title",
                "number-reset",
                "number-gap",
                "chapter-misplaced",
                "no-headings",
                "missing-heading-prefix",
                "heading-number-typo",
            ]
            .contains(&v)
        }) || severity.is_some_and(|v| !["error", "warning", "info"].contains(&v))
        {
            return Err(invalid());
        }
        self.validate_shape()?;
        let stamp = evidence.stamp.as_str();
        let mut diagnostic = evidence.diagnostic.clone();
        for finding in diagnostic["findings"].as_array_mut().unwrap() {
            let id = finding["id"].as_str().unwrap();
            if let Some(record) = self.records.get(id).filter(|r| r.evidence_id == stamp) {
                finding["review"] = serde_json::to_value(record).unwrap();
            }
        }
        // 问题可能上万条，这里只排序引用；只有落在本页的才复制。
        let levels = evidence.diagnostic["findings"]
            .as_array()
            .unwrap()
            .iter()
            .rev() // 与 `find` 取第一个相同：同 id 时靠前的覆盖靠后的
            .filter_map(|f| Some((f["id"].as_str()?, f["severity"].as_str().unwrap_or("info"))))
            .collect::<BTreeMap<_, _>>();
        let level_of = |item: &Value| {
            levels
                .get(item["finding_id"].as_str().unwrap_or(""))
                .copied()
                .unwrap_or("info")
        };
        let mut all = evidence
            .ordered()
            .iter()
            .map(|index| &evidence.items[*index as usize])
            .collect::<Vec<_>>();
        let mut categories = BTreeMap::<String, usize>::new();
        let mut severities = BTreeMap::<String, usize>::new();
        for item in &all {
            let id = item["finding_id"].as_str().unwrap_or("").to_owned();
            *categories.entry(id).or_default() += 1;
            *severities.entry(level_of(item).to_owned()).or_default() += 1;
        }
        let reviewed = all
            .iter()
            .filter(|item| {
                let id = item["id"].as_str().unwrap_or("");
                let group = item["finding_id"].as_str().unwrap_or("");
                [id, group].iter().any(|key| {
                    self.records
                        .get(*key)
                        .is_some_and(|r| r.evidence_id == stamp)
                })
            })
            .count();
        diagnostic["review_unfiltered_total"] = json!(all.len());
        diagnostic["review_reviewed"] = json!(reviewed);
        diagnostic["review_categories"] = json!(categories);
        diagnostic["review_severities"] = json!(severities);
        let decided = |item: &Value| {
            [item["id"].as_str(), item["finding_id"].as_str()]
                .into_iter()
                .flatten()
                .any(|key| {
                    self.records
                        .get(key)
                        .is_some_and(|r| r.evidence_id == stamp)
                })
        };
        if category.is_none() && severity.is_none() {
            // 每个原因名下有多少条、还有多少条没下结论；其余问题按类别另计。
            let mut plain = BTreeMap::<String, usize>::new();
            let mut totals = BTreeMap::<&str, (usize, usize)>::new();
            for item in &all {
                match item["cause"].as_str() {
                    Some(kind) => {
                        let entry = totals.entry(kind).or_default();
                        entry.0 += 1;
                        entry.1 += usize::from(!decided(item));
                    }
                    None => {
                        *plain
                            .entry(item["finding_id"].as_str().unwrap_or("").to_owned())
                            .or_default() += 1
                    }
                }
            }
            let causes = evidence
                .causes
                .iter()
                .map(|cause| {
                    let mut cause = cause.clone();
                    let (total, open) = totals
                        .get(cause["kind"].as_str().unwrap_or(""))
                        .copied()
                        .unwrap_or_default();
                    cause["total"] = json!(total);
                    cause["open"] = json!(open);
                    cause
                })
                .collect::<Vec<_>>();
            diagnostic["review_causes"] = json!(causes);
            diagnostic["review_plain_categories"] = json!(plain);
        } else {
            // 筛选后不按原因分组：恢复 认全 → 去重 → 归位 的顺序，界面按类别计数切组。
            all.sort_by_cached_key(|item| {
                let id = item["finding_id"].as_str().unwrap_or("");
                let line = item["source_lines"][0].as_u64().unwrap_or(u64::MAX);
                (issue_group(id), issue_category_rank(id), line)
            });
        }
        all.retain(|item| {
            category.is_none_or(|v| item["finding_id"] == v)
                && severity.is_none_or(|v| level_of(item) == v)
        });
        let mut filtered = BTreeMap::<String, usize>::new();
        for item in &all {
            *filtered
                .entry(item["finding_id"].as_str().unwrap_or("").to_owned())
                .or_default() += 1;
        }
        diagnostic["review_filtered_categories"] = json!(filtered);
        if offset > all.len() {
            return Err(invalid());
        }
        let mut page = all
            .iter()
            .skip(offset)
            .take(50)
            .map(|item| (*item).clone())
            .collect::<Vec<_>>();
        for item in &mut page {
            item["severity"] = json!(level_of(item));
            item["report_offset"] = json!(evidence.offsets().get(item["id"].as_str().unwrap()));
            let id = item["id"].as_str().unwrap();
            if let Some(record) = self.records.get(id).filter(|r| r.evidence_id == stamp) {
                item["review"] = serde_json::to_value(record).unwrap();
            }
            let group = item["finding_id"].as_str().unwrap_or("");
            item["category_reviewed"] = json!(
                self.records
                    .get(group)
                    .is_some_and(|r| r.evidence_id == stamp)
            );
        }
        diagnostic["review_items"] = json!(page);
        diagnostic["review_total"] = json!(all.len());
        diagnostic["review_offset"] = json!(offset);
        let expired = self
            .records
            .iter()
            .filter(|(_, r)| r.evidence_id != stamp)
            .map(|(id, _)| id)
            .collect::<Vec<_>>();
        Ok(
            json!({"diagnostic":diagnostic,"evidence_id":stamp,"expired":expired,"review":self,"writes_source":false}),
        )
    }
}
/// 成片原因的先后，报告里原因和它名下的问题都按这个顺序排：
/// 漏识别的标题 → 同一章存两遍 → 章号写错 → 正文里重复标题 → 正文句子当了标题 → 标题不带“第”。
const CAUSES: [&str; 6] = [
    "unrecognized",
    "twin",
    "misnumbered",
    "echo",
    "prose",
    "no-prefix",
];

fn cause_rank(item: &Value) -> Option<u8> {
    let kind = item["cause"].as_str()?;
    CAUSES.iter().position(|c| *c == kind).map(|i| i as u8)
}

/// 找出成片出现的原因，并在归它的问题上写 `cause`。
///
/// 一本书的问题常常是同一件事重复几十上百次（整段存了两遍、每章正文开头又写一遍标题），
/// 逐条列出来既看不出原因，也没法一次处理。这里只归并数量够多的：
/// - `unrecognized`：正文里像标题、却没收进目录的行至少 5 处（多半是整本书用了另一种标题写法）。
/// - `twin`：整章重复或近似重复至少 3 处。被排除的那一份带出的跳号、编号回退也算它的。
/// - `misnumbered`：章号写成了别的号（常见是两套编号交替）至少 3 处，连带的跳号、回退算它的。
/// - `echo`：紧跟着重复的标题至少 3 处。
/// - `prose`：正文句子被当成标题至少 3 处。
/// - `no-prefix`：编号标题不带“第”至少 5 处。
fn mark_causes(source: &SourceSnapshot, items: &mut [Value]) -> Vec<Value> {
    let count = |items: &[Value], id: &str| items.iter().filter(|i| i["finding_id"] == id).count();
    let heading: BTreeMap<u64, &str> = source
        .headings()
        .iter()
        .map(|h| (u64::from(h.source_line), h.title.as_str()))
        .collect();
    let sample = |items: &[Value], id: &str| {
        items
            .iter()
            .filter(|i| i["finding_id"] == id)
            .take(3)
            .map(|i| {
                // 这条问题所在标题行的原文：问题标题常是一句通用的话，例子要给原文。
                let text = i["source_lines"]
                    .as_array()
                    .and_then(|lines| lines.last())
                    .and_then(Value::as_u64)
                    .and_then(|line| heading.get(&line));
                json!({"id":i["id"],"title":i["title"],"heading":text,"before_title":i["before_title"],
                    "after_title":i["after_title"],"source_lines":i["source_lines"],
                    "differing_lines":i["differing_lines"],"subtype":i["subtype"]})
            })
            .collect::<Vec<_>>()
    };
    let mut causes = Vec::new();
    let twins = count(items, "duplicate-content");
    if twins >= 3 {
        // 每条的后一行是“后一份”的标题行。
        let later: std::collections::BTreeSet<u64> = items
            .iter()
            .filter(|i| i["finding_id"] == "duplicate-content")
            .filter_map(|i| {
                i["drop_line"]
                    .as_u64()
                    .or_else(|| i["source_lines"][1].as_u64())
            })
            .collect();
        let ordinal: BTreeMap<u64, usize> = source
            .headings()
            .iter()
            .enumerate()
            .map(|(index, h)| (u64::from(h.source_line), index))
            .collect();
        // 连着的算一段：两份交替排（甲、甲′、乙、乙′）时序号隔一个，也算连着。
        let mut runs = 0;
        let mut previous = None;
        for line in &later {
            let Some(&at) = ordinal.get(line) else {
                continue;
            };
            if previous.is_none_or(|p: usize| at > p + 2) {
                runs += 1;
            }
            previous = Some(at);
        }
        let near = items
            .iter()
            .filter(|i| i["finding_id"] == "duplicate-content" && !i["subtype"].is_null())
            .count();
        let mut linked = BTreeMap::<&str, usize>::new();
        for item in items.iter_mut() {
            let id = item["finding_id"].as_str().unwrap_or("").to_owned();
            let touches = item["source_lines"].as_array().is_some_and(|lines| {
                lines
                    .iter()
                    .any(|l| l.as_u64().is_some_and(|l| later.contains(&l)))
            });
            match id.as_str() {
                "duplicate-content" => item["cause"] = json!("twin"),
                "number-gap" if touches => {
                    item["cause"] = json!("twin");
                    *linked.entry("number-gap").or_default() += 1;
                }
                "number-reset" if touches => {
                    item["cause"] = json!("twin");
                    *linked.entry("number-reset").or_default() += 1;
                }
                _ => {}
            }
        }
        causes.push(
            json!({"kind":"twin","count":twins,"near":near,"runs":runs,"linked":linked,
            "category":"duplicate-content","samples":sample(items, "duplicate-content")}),
        );
    }
    let wrong = source.misnumbered_chapters();
    if wrong.len() >= 3 {
        let ids: std::collections::BTreeSet<String> = wrong
            .iter()
            .flat_map(|m| {
                [&m.entry_id, &m.next.entry_id]
                    .into_iter()
                    .flat_map(|id| [format!("number-gap:{id}"), format!("number-reset:{id}")])
            })
            .collect();
        let mut linked = BTreeMap::<&str, usize>::new();
        for item in items.iter_mut().filter(|i| i["cause"].is_null()) {
            if item["id"].as_str().is_some_and(|id| ids.contains(id)) {
                item["cause"] = json!("misnumbered");
                let category = if item["finding_id"] == "number-gap" {
                    "number-gap"
                } else {
                    "number-reset"
                };
                *linked.entry(category).or_default() += 1;
            }
        }
        let samples = wrong
            .iter()
            .take(3)
            .map(|m| {
                json!({"title":m.title,"before_title":m.previous.title,"after_title":m.next.title,
                    "source_lines":[m.source_line],"number":m.number,"expected":m.expected,"unit":m.unit.to_string()})
            })
            .collect::<Vec<_>>();
        if !linked.is_empty() {
            causes.push(
                json!({"kind":"misnumbered","count":wrong.len(),"linked":linked,"samples":samples}),
            );
        }
    }
    for (kind, category, least) in [
        ("unrecognized", "unrecognized-heading", 5),
        ("echo", "duplicate-title", 3),
        ("prose", "prose-heading", 3),
        ("no-prefix", "missing-heading-prefix", 5),
    ] {
        let found = count(items, category);
        if found < least {
            continue;
        }
        for item in items
            .iter_mut()
            .filter(|i| i["finding_id"] == category && i["cause"].is_null())
        {
            item["cause"] = json!(kind);
        }
        causes.push(json!({"kind":kind,"count":found,"category":category,"samples":sample(items, category)}));
    }
    // 和名下问题的排列顺序一致，界面按这个顺序切分列表。
    causes.sort_by_key(|cause| {
        CAUSES
            .iter()
            .position(|kind| cause["kind"] == *kind)
            .unwrap_or(usize::MAX)
    });
    causes
}

/// 问题分组：0 认全（漏识别、缺章）；1 去重；2 归位（编号、层级与误收的标题）。
pub fn issue_group(category: &str) -> u8 {
    match category {
        "unrecognized-heading" | "number-gap" | "heading-number-typo" | "no-headings" => 0,
        "duplicate-content" | "duplicate-title" => 1,
        _ => 2,
    }
}

fn issue_category_rank(category: &str) -> u8 {
    [
        "no-headings",
        "unrecognized-heading",
        "heading-number-typo",
        "number-gap",
        "duplicate-content",
        "duplicate-title",
        "chapter-misplaced",
        "number-reset",
        "prose-heading",
        "missing-heading-prefix",
    ]
    .iter()
    .position(|c| *c == category)
    .unwrap_or(99) as u8
}

pub fn execute(source: &SourceSnapshot, input: &str) -> Result<String, ApiError> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Request {
        review: Review,
        finding_id: Option<String>,
        evidence_id: Option<String>,
        decision: Option<Decision>,
        #[serde(default)]
        note: String,
        #[serde(default)]
        offset: usize,
        category: Option<String>,
        severity: Option<String>,
    }
    if input.len() > 1024 * 1024 {
        return Err(invalid());
    }
    let mut request: Request = serde_json::from_str(input).map_err(|_| invalid())?;
    if let Some(id) = request.finding_id {
        request.review.set(
            source,
            &id,
            request.evidence_id.as_deref().ok_or_else(invalid)?,
            request.decision,
            request.note,
        )?;
    }
    Ok(request
        .review
        .report_filtered(
            source,
            request.offset,
            request.category.as_deref(),
            request.severity.as_deref(),
        )?
        .to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn source(text: &str) -> SourceSnapshot {
        SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap()
    }
    #[test]
    fn filtering_precedes_pagination_and_keeps_evidence_identity() {
        let text = (0..90)
            .map(|i| format!("第{}章 标题{}\n正文\n\n", i * 2 + 1, i))
            .collect::<String>();
        let source = source(&text);
        let review = Review::default();
        let first = review.report(&source).unwrap();
        let total = first["diagnostic"]["review_total"].as_u64().unwrap() as usize;
        assert!(total > 50);
        let mut all = Vec::new();
        for offset in (0..total).step_by(50) {
            all.extend(
                review.report_page(&source, offset).unwrap()["diagnostic"]["review_items"]
                    .as_array()
                    .unwrap()
                    .clone(),
            );
        }
        for category in first["diagnostic"]["review_categories"]
            .as_object()
            .unwrap()
            .keys()
        {
            let expected = all
                .iter()
                .filter(|v| v["finding_id"] == *category)
                .collect::<Vec<_>>();
            let filtered = review
                .report_filtered(&source, 0, Some(category), None)
                .unwrap();
            assert_eq!(filtered["evidence_id"], first["evidence_id"]);
            assert_eq!(filtered["diagnostic"]["review_total"], expected.len());
            for offset in (0..expected.len()).step_by(50) {
                let page = review
                    .report_filtered(&source, offset, Some(category), None)
                    .unwrap();
                assert_eq!(
                    page["diagnostic"]["review_items"],
                    json!(expected.iter().skip(offset).take(50).collect::<Vec<_>>())
                );
            }
        }
        assert!(
            review
                .report_filtered(&source, 0, Some("bogus"), None)
                .is_err()
        );
        assert!(
            review
                .report_filtered(&source, 0, None, Some("bogus"))
                .is_err()
        );
        for severity in ["error", "warning", "info"] {
            let page = review
                .report_filtered(&source, 0, None, Some(severity))
                .unwrap();
            assert_eq!(
                page["diagnostic"]["review_total"],
                all.iter().filter(|v| v["severity"] == severity).count()
            );
        }
    }
    #[test]
    fn individual_review_preserves_only_selected_duplicate_and_pages() {
        let s = source("第一章 甲\r\n第一章 甲\n甲文\n第二章 乙\r第二章 乙\n乙文");
        let mut review = Review::default();
        let report = review.report(&s).unwrap();
        let stamp = report["evidence_id"].as_str().unwrap();
        let id = report["diagnostic"]["review_items"][0]["id"]
            .as_str()
            .unwrap();
        review
            .set(&s, id, stamp, Some(Decision::Ignored), String::new())
            .unwrap();
        let request = json!({"finding_ids":["duplicate-title"],"review":review}).to_string();
        assert_eq!(
            String::from_utf8(s.repair_output_json(&request).unwrap()).unwrap(),
            "第一章 甲\r\n第一章 甲\n甲文\n第二章 乙\r乙文"
        );
        let plan: Value = serde_json::from_str(&s.repair_plan_json(&request).unwrap()).unwrap();
        assert_eq!(plan["actions"].as_array().unwrap().len(), 1);
        assert_eq!(
            review.report(&s).unwrap()["diagnostic"]["findings"][0]["count"],
            2
        );
        let large = source(&"第一章 甲\n".repeat(62));
        let first = Review::default().report(&large).unwrap();
        let second = Review::default().report_page(&large, 50).unwrap();
        assert_eq!(
            first["diagnostic"]["review_items"]
                .as_array()
                .unwrap()
                .len(),
            50
        );
        assert_eq!(
            second["diagnostic"]["review_items"]
                .as_array()
                .unwrap()
                .len(),
            11
        );
        assert!(Review::default().report_page(&large, 100).is_err());
    }
    #[test]
    fn decisions_reopen_expire_and_never_remove_findings() {
        let s = source("第一章 甲\n第一章 甲\n正文");
        let mut review = Review::default();
        let stamp = review.report(&s).unwrap()["evidence_id"]
            .as_str()
            .unwrap()
            .to_owned();
        review
            .set(
                &s,
                "duplicate-title",
                &stamp,
                Some(Decision::ConfirmedNormal),
                "已核对全部重复标题".into(),
            )
            .unwrap();
        let selected = json!({"finding_ids":["duplicate-title"],"review":review}).to_string();
        let plan: Value = serde_json::from_str(&s.repair_plan_json(&selected).unwrap()).unwrap();
        assert_eq!(plan["actions"], json!([]));
        assert_eq!(plan["suppressed_findings"], json!(["duplicate-title"]));
        assert_eq!(s.repair_output_json(&selected).unwrap(), s.original_bytes());
        let mut reopened: Review =
            serde_json::from_str(&serde_json::to_string(&review).unwrap()).unwrap();
        let report = reopened.report(&s).unwrap();
        assert_eq!(
            report["diagnostic"]["findings"][0]["review"]["decision"],
            "confirmed_normal"
        );
        assert_eq!(report["diagnostic"]["findings"][0]["count"], 1);
        let changed = source("第一章 甲\n第一章 甲\n新的正文");
        let report = reopened.report(&changed).unwrap();
        assert_eq!(report["expired"], json!(["duplicate-title"]));
        assert!(report["diagnostic"]["findings"][0]["review"].is_null());
        assert!(
            reopened
                .set(
                    &changed,
                    "duplicate-title",
                    &stamp,
                    Some(Decision::Ignored),
                    String::new()
                )
                .is_err()
        );
        assert!(
            reopened
                .set(
                    &s,
                    "invented",
                    &stamp,
                    Some(Decision::Ignored),
                    String::new()
                )
                .is_err()
        );
        reopened
            .set(&s, "duplicate-title", &stamp, None, String::new())
            .unwrap();
        assert!(reopened.records.is_empty());
        let restored = json!({"finding_ids":["duplicate-title"],"review":reopened}).to_string();
        assert_ne!(s.repair_output_json(&restored).unwrap(), s.original_bytes());
        let old_on_new: Value =
            serde_json::from_str(&changed.repair_plan_json(&selected).unwrap()).unwrap();
        assert!(!old_on_new["actions"].as_array().unwrap().is_empty());
        assert_eq!(old_on_new["suppressed_findings"], json!([]));

        assert_eq!(s.decoded_text(), "第一章 甲\n第一章 甲\n正文");
    }
    #[test]
    fn indented_sentences_are_prose_when_real_headings_are_flush_left() {
        // 40 个顶格的标题；另有三行缩进的正文以“几章”开头，读起来是一句话。
        let mut text = String::new();
        for n in 1..=40 {
            text.push_str(&format!("第{n}章 标题{n}\n"));
            if n == 20 {
                text.push_str("　　第20章标题20\n");
            }
            text.push_str(&format!("　　这是第{n}章的正文。\n"));
            if n == 7 {
                text.push_str("　　九章齐现？\n　　后面还有正文。\n");
            }
            if n == 12 {
                text.push_str("　　（第二章大概十一点左右。）\n");
            }
        }
        let s = source(&text);
        let evidence = ReviewEvidence::new(&s).unwrap();
        let report = Review::default()
            .report_using(&evidence, 0, None, None)
            .unwrap();
        let categories = &report["diagnostic"]["review_categories"];
        // 两句话归“正文被当成标题”，不再带出跳号、回退或“未带第”；
        // 缩进的重复标题仍归“重复标题”。
        assert_eq!(
            categories,
            &json!({"duplicate-title":1,"prose-heading":2}),
            "{categories}"
        );
        // 标题本来就都缩进的书，不按缩进判断。
        let indented = text
            .lines()
            .map(|l| {
                if l.starts_with('第') {
                    format!("　　{l}\n")
                } else {
                    format!("{l}\n")
                }
            })
            .collect::<String>();
        let s = source(&indented);
        let evidence = ReviewEvidence::new(&s).unwrap();
        let report = Review::default()
            .report_using(&evidence, 0, None, None)
            .unwrap();
        let items = evidence.items.iter();
        assert!(
            !items
                .filter(|i| i["finding_id"] == "prose-heading")
                .any(|i| i["title"].as_str().unwrap().contains("九章齐现"))
        );
    }
    #[test]
    fn repeated_cause_groups_items_and_leads_the_report() {
        // 每章正文开头又写一遍标题：少了空格和括号里的求票；中间只有一个逗号。
        let mut text = String::new();
        for n in 1..=4 {
            text.push_str(&format!(
                "第{n}章 标题{n}（求月票）\n\n　　，\n　　第{n}章标题{n}\n　　这是第{n}章的正文。\n\n"
            ));
        }
        // 另有一处跳号，不属于任何原因。
        text.push_str("第6章 末尾\n　　正文。\n");
        let s = source(&text);
        let evidence = ReviewEvidence::new(&s).unwrap();
        let report = Review::default()
            .report_using(&evidence, 0, None, None)
            .unwrap();
        let diagnostic = &report["diagnostic"];
        // 不再报成“同一个章号出现两次”。
        assert!(
            diagnostic["review_categories"]
                .get("number-reset")
                .is_none()
        );
        assert_eq!(diagnostic["review_categories"]["duplicate-title"], 4);
        let causes = diagnostic["review_causes"].as_array().unwrap();
        assert_eq!(causes.len(), 1);
        assert_eq!(causes[0]["kind"], "echo");
        assert_eq!(
            (&causes[0]["count"], &causes[0]["total"], &causes[0]["open"]),
            (&json!(4), &json!(4), &json!(4))
        );
        assert_eq!(causes[0]["samples"][0]["heading"], "第1章标题1");
        assert_eq!(
            diagnostic["review_plain_categories"],
            json!({"number-gap":1})
        );
        // 原因名下的排在最前；筛选后回到按类别的顺序，不再给原因。
        let items = diagnostic["review_items"].as_array().unwrap();
        assert!(items[..4].iter().all(|i| i["cause"] == "echo"));
        assert_eq!(items[4]["finding_id"], "number-gap");
        let filtered = Review::default()
            .report_using(&evidence, 0, None, Some("warning"))
            .unwrap();
        assert!(filtered["diagnostic"].get("review_causes").is_none());
        // 整类下结论后，原因名下不再有待处理的。
        let mut review = Review::default();
        review
            .set_using(
                &evidence,
                "duplicate-title",
                evidence.stamp(),
                Some(Decision::ConfirmedNormal),
                String::new(),
            )
            .unwrap();
        let decided = review.report_using(&evidence, 0, None, None).unwrap();
        assert_eq!(decided["diagnostic"]["review_causes"][0]["open"], 0);
    }
}
