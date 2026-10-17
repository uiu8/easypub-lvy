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
    stamp: String,
    diagnostic: Value,
    items: Vec<Value>,
}
impl ReviewEvidence {
    pub fn new(source: &SourceSnapshot) -> Result<Self, ApiError> {
        let diagnostic = serde_json::from_str(&source.diagnostic_json()).expect("internal diagnostic");
        let items = items(source)?;
        let material = json!(["finding-review-v2", RULE_ID, diagnostic, items]);
        let stamp = format!("{:x}",Sha256::digest(material.to_string().as_bytes()));
        Ok(Self {stamp,diagnostic,items})
    }
    pub fn stamp(&self) -> &str {
        &self.stamp
    }
}
fn items(source: &SourceSnapshot) -> Result<Vec<Value>, ApiError> {
    let plan: Value = serde_json::from_str(&source.repair_plan_json(
        r#"["duplicate-content","prose-heading","unrecognized-heading","duplicate-title","number-reset","number-gap","no-headings","missing-heading-prefix","heading-number-typo"]"#,
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
        self.set_using(&ReviewEvidence::new(source)?, id, expected_evidence, decision, note)
    }
    pub fn set_using(&mut self, evidence: &ReviewEvidence, id: &str,
        expected_evidence: &str, decision: Option<Decision>, note: String) -> Result<(),ApiError> {
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
    pub fn report_using(&self, evidence: &ReviewEvidence, offset: usize,
        category: Option<&str>, severity: Option<&str>) -> Result<Value, ApiError> {
        if category.is_some_and(|v| {
            ![
                "duplicate-content",
                "prose-heading",
                "unrecognized-heading",
                "duplicate-title",
                "number-reset",
                "number-gap",
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
        let mut all = evidence.items.clone();
        let mut categories = BTreeMap::<String, usize>::new();
        let mut severities = BTreeMap::<String, usize>::new();
        for item in &mut all {
            let id = item["finding_id"].as_str().unwrap_or("").to_owned();
            let level = diagnostic["findings"]
                .as_array()
                .unwrap()
                .iter()
                .find(|f| f["id"] == id)
                .and_then(|f| f["severity"].as_str())
                .unwrap_or("info")
                .to_owned();
            item["severity"] = json!(level);
            *categories.entry(id).or_default() += 1;
            *severities.entry(level).or_default() += 1;
        }
        // 按“要做的事”排序（CHK-053）：认全 → 去重 → 归位，组内按类别、行号；
        // 排序稳定，同一行的多条问题保持原有先后。
        all.sort_by_key(|item| {
            let id = item["finding_id"].as_str().unwrap_or("");
            let line = item["source_lines"][0].as_u64().unwrap_or(u64::MAX);
            (issue_group(id), issue_category_rank(id), line)
        });
        let reviewed = all
            .iter()
            .filter(|item| {
                let id = item["id"].as_str().unwrap_or("");
                let group = item["finding_id"].as_str().unwrap_or("");
                [id, group].iter().any(|key| {
                    self.records.get(*key).is_some_and(|r| r.evidence_id == stamp)
                })
            })
            .count();
        diagnostic["review_unfiltered_total"] = json!(all.len());
        diagnostic["review_reviewed"] = json!(reviewed);
        diagnostic["review_categories"] = json!(categories);
        diagnostic["review_severities"] = json!(severities);
        all.retain(|item| {
            category.is_none_or(|v| item["finding_id"] == v)
                && severity.is_none_or(|v| item["severity"] == v)
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
            .cloned()
            .collect::<Vec<_>>();
        for item in &mut page {
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
/// 问题分组（CHK-053）：0 认全（漏识别、缺章）；1 去重；2 归位（编号、层级与误收的标题）。
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
}
