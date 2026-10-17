//! Frozen batch settings plans: transfer rules, retain each target's own coordinates.
use crate::{
    cleanup_draft::CleanupDraft,
    sessions::{ImportService, MAX_BATCH_TARGETS},
};
use easypub_core::{ApiError, ErrorCode, cleanup::Request, source::SourceSnapshot};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{collections::BTreeSet, sync::Arc};

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Target {
    book_id: String,
    source_id: String,
    revision: u32,
    #[serde(default)]
    current: Option<Request>,
    #[serde(default)]
    history: Option<CleanupDraft>,
    #[serde(default)]
    protected_lines: BTreeSet<u32>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct BatchRequest {
    template: Request,
    append: bool,
    targets: Vec<Target>,
}
struct Batch {
    id: String,
    items: Vec<Value>,
    drafts: Vec<Value>,
    failed: bool,
}
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "cleanup_batch",
        "review_batch_targets_and_rules",
    )
}
fn bounded_json(value: &Value) -> Result<String, ApiError> {
    let text = value.to_string();
    if text.len() > 8 * 1024 * 1024 {
        return Err(ApiError::new(
            ErrorCode::TooLarge,
            "cleanup_batch",
            "reduce_batch_size",
        ));
    }
    Ok(text)
}
fn prepare_batch(
    request: &BatchRequest,
    lookup: impl Fn(&str, u32) -> Result<Arc<SourceSnapshot>, ApiError>,
) -> Result<Batch, ApiError> {
    if request.targets.is_empty() || request.targets.len() > MAX_BATCH_TARGETS {
        return Err(invalid());
    }
    let rules = request.template.ordered_rules()?;
    let mut ids = BTreeSet::new();
    let mut items = Vec::new();
    let mut drafts = Vec::new();
    let mut failed = false;
    for target in &request.targets {
        if target.book_id.is_empty() || target.book_id.len() > 32768 || !ids.insert(&target.book_id)
        {
            return Err(invalid());
        }
        let result = (|| {
            let source = lookup(&target.source_id, target.revision)?;
            let mut draft = if let Some(draft) = &target.history {
                draft.validate_shape()?;
                if draft.current() != &target.current {
                    return Err(invalid());
                }
                draft.clone()
            } else {
                let mut draft = CleanupDraft::new(&source);
                if let Some(current) = &target.current {
                    draft.history.push(Some(current.for_storage()));
                    draft.cursor = 1;
                }
                draft
            };
            let next = Request::apply_rules(
                target.current.as_ref(),
                &rules,
                request.append,
                &target.protected_lines,
            )?;
            let changed = target.current.as_ref() != Some(&next);
            let plan = draft.prepare_set(&source, next.clone())?;
            let preview: Value = serde_json::from_str(&plan.preview()).map_err(|_| invalid())?;
            let samples = preview["actions"]
                .as_array()
                .ok_or_else(invalid)?
                .iter()
                .take(3)
                .cloned()
                .collect::<Vec<_>>();
            Ok((
                json!({"book_id":target.book_id,"source_id":target.source_id,"revision":target.revision,"ready":true,"settings_changed":changed,"change_count":preview["change_count"],"candidate_count":preview["candidate_count"],"cleanup_plan_id":preview["plan_id"],"samples":samples,"next_request":next}),
                json!({"book_id":target.book_id,"history":draft}),
            ))
        })();
        match result {
            Ok((item, draft)) => {
                items.push(item);
                drafts.push(draft);
            }
            Err(error) => {
                failed = true;
                items.push(json!({"book_id":target.book_id,"ready":false,"error":format!("{:?}",error.code),"operation":error.operation,"next_action":error.next_action}));
            }
        }
    }
    let mut hash = Sha256::new();
    hash.update(b"cleanup-settings-batch-v1");
    hash.update(serde_json::to_vec(request).map_err(|_| invalid())?);
    hash.update(serde_json::to_vec(&items).map_err(|_| invalid())?);
    Ok(Batch {
        id: format!("{:x}", hash.finalize()),
        items,
        drafts,
        failed,
    })
}
impl Batch {
    fn response(&self, apply: bool, plan_id: &str, confirmed: bool) -> Result<String, ApiError> {
        if apply && (!confirmed || self.failed || plan_id != self.id) {
            return Err(ApiError::new(
                ErrorCode::StaleRevision,
                "cleanup_batch",
                "preview_and_confirm_all_targets",
            ));
        }
        bounded_json(
            &json!({"plan_id":self.id,"all_valid":!self.failed,"applied":apply,
            "items":self.items,"drafts":if apply {Some(&self.drafts)} else {None},"writes_source":false}),
        )
    }
}
pub fn run(
    service: &ImportService,
    request_json: String,
    apply: bool,
    plan_id: String,
    confirmed: bool,
) -> Result<String, ApiError> {
    if request_json.len() > 4 * 1024 * 1024 {
        return Err(invalid());
    }
    let request: BatchRequest = serde_json::from_str(&request_json).map_err(|_| invalid())?;
    prepare_batch(&request, |id, revision| service.source(id, revision))?
        .response(apply, &plan_id, confirmed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use easypub_core::cleanup::prepare;
    use easypub_core::source::RULE_ID;
    fn sample() -> Arc<SourceSnapshot> {
        Arc::new(
            SourceSnapshot::from_utf8(
                "第一章 甲\n正文  \n保留  \n本章完\n尾行  "
                    .as_bytes()
                    .to_vec(),
                RULE_ID,
                || false,
            )
            .unwrap(),
        )
    }
    fn request(source: &SourceSnapshot) -> BatchRequest {
        let id = source.summary().source_id;
        serde_json::from_value(json!({"template":{"kind":"cleanup","pipeline":[{"kind":"trim_trailing_spaces"},{"kind":"remove_ad_lines"}],"start_line":99,"skip_lines":[100],"remove_lines":[101]},"append":false,"targets":[
            {"book_id":"a","source_id":id,"revision":1,"current":{"kind":"cleanup","rules":["remove_ad_lines"],"start_line":2,"end_line":4,"skip_lines":[3],"remove_lines":[4]}},
            {"book_id":"b","source_id":id,"revision":1,"protected_lines":[3]}
        ]})).unwrap()
    }
    #[test]
    fn unrepresentable_replacement_is_rejected_during_batch_preview() {
        use easypub_core::encoding::{EncodingKind, EncodingMode, encode};
        let raw = encode("第一章 甲\n正文", EncodingKind::Cp936, false).unwrap();
        let source = Arc::new(
            SourceSnapshot::from_bytes(raw, EncodingMode::Cp936, RULE_ID, || false).unwrap(),
        );
        let id = source.summary().source_id;
        let req:BatchRequest=serde_json::from_value(json!({"template":{"kind":"cleanup","pipeline":[{"kind":"literal_replace","find":"正文","replace":"😀"}]},"append":false,"targets":[{"book_id":"cp936","source_id":id,"revision":1}]})).unwrap();
        let batch = prepare_batch(&req, |_, _| Ok(source.clone())).unwrap();
        assert!(batch.failed);
        assert!(batch.response(true, &batch.id, true).is_err());
        assert_eq!(batch.items[0]["ready"], false);
    }
    #[test]
    fn only_rules_transfer_scopes_and_exclusions_stay_target_local() {
        let source = sample();
        let req = request(&source);
        let batch = prepare_batch(&req, |_, _| Ok(source.clone())).unwrap();
        assert!(!batch.failed);
        let a = &batch.items[0]["next_request"];
        let b = &batch.items[1]["next_request"];
        assert_eq!(a["skip_lines"], json!([3]));
        assert_eq!(a["remove_lines"], json!([4]));
        assert_eq!(a["start_line"], 2);
        assert_eq!(b["skip_lines"], json!([]));
        assert_eq!(b["remove_lines"], json!([]));
        assert!(b["start_line"].is_null());
        assert_eq!(b["protected_lines"], json!([3]));
        let plan = prepare(&source, &a.to_string()).unwrap();
        assert_eq!(
            plan.output(&source).unwrap(),
            "第一章 甲\n正文\n保留  \n尾行  ".as_bytes()
        );
        assert!(batch.response(true, &batch.id, false).is_err());
        assert!(batch.response(true, "stale", true).is_err());
        assert!(batch.response(true, &batch.id, true).is_ok());
        let mut changed = request(&source);
        changed.append = true;
        let newer = prepare_batch(&changed, |_, _| Ok(source.clone())).unwrap();
        assert_ne!(batch.id, newer.id);
        assert_eq!(
            newer.items[0]["next_request"]["pipeline"][0]["kind"],
            "remove_ad_lines"
        );
    }
    #[test]
    fn one_invalid_target_prevents_entire_apply_and_duplicate_ids_are_rejected() {
        let source = sample();
        let mut req = request(&source);
        req.template = serde_json::from_value(
            json!({"kind":"cleanup","pipeline":[{"kind":"trim_trailing_spaces"}]}),
        )
        .unwrap();
        let batch = prepare_batch(&req, |_, _| Ok(source.clone())).unwrap();
        assert!(batch.failed);
        assert_eq!(batch.items[0]["operation"], "cleanup_batch_notice_conflict");
        assert_eq!(batch.items[1]["ready"], true);
        assert!(batch.response(true, &batch.id, true).is_err());
        req.targets[1].book_id = "a".into();
        assert!(prepare_batch(&req, |_, _| Ok(source.clone())).is_err());
    }
}
