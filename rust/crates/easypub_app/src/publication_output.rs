//! Application composition adds confirmed catalog input to the shared output plan.
use easypub_core::{
    ApiError, ErrorCode,
    publication::{self, OutputPlan},
    source::SourceSnapshot,
    structure::Structure,
};
use serde::Deserialize;
use serde_json::{Value, json};
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    kind: String,
    #[serde(default)]
    allow_unchanged_copy: bool,
    structure: Option<Structure>,
    manual: Option<Value>,
    cleanup: Option<Value>,
    post_edits: Option<crate::edit_checkpoint::EditRequest>,
    catalog: Option<crate::catalog::CompositionSelection>,
    #[serde(default)]
    preview_offset: usize,
}
fn invalid() -> ApiError {
    ApiError::new(ErrorCode::InvalidRule, "publication", "review_composition")
}
pub fn try_prepare(source: &SourceSnapshot, request: &str) -> Result<Option<OutputPlan>, ApiError> {
    if request.len() > 3 * 1024 * 1024 {
        return Err(invalid());
    }
    let mut value: Value = serde_json::from_str(request).map_err(|_| invalid())?;
    if value["kind"] != "publication" {
        return Ok(None);
    }
    let request: Request = serde_json::from_value(value.clone()).map_err(|_| invalid())?;
    if let Some(edits) = &request.post_edits {
        value["post_edits"] = serde_json::to_value(edits).map_err(|_| invalid())?;
    }
    let Some(catalog) = request.catalog else {
        if let Some(edits) = request
            .post_edits
            .as_ref()
            .filter(|e| e.checkpoint.is_some())
        {
            let structure = request.structure.unwrap_or_else(|| Structure::new(source));
            let book = publication::compose_with_cleanup(
                source,
                &structure,
                request.manual.as_ref().map(Value::to_string).as_deref(),
                request.cleanup.as_ref().map(Value::to_string).as_deref(),
            )?;
            let base_id = easypub_core::effective_edit::base_id(&book);
            let (book, evidence) = crate::edit_checkpoint::apply(book, edits)?;
            let manual_evidence = request
                .manual
                .as_ref()
                .map(|manual| {
                    let plan = easypub_core::manual_edit::prepare_with_structure(
                        source,
                        &manual.to_string(),
                        Some(&structure),
                    )?;
                    serde_json::from_slice::<Value>(&plan.evidence(source)).map_err(|_| invalid())
                })
                .transpose()?;
            return publication::prepare_composed_output_resolved(
                source,
                value,
                book,
                manual_evidence,
                None,
                Vec::new(),
                Some((base_id, evidence)),
            )
            .map(Some);
        }
        let mut value = value;
        value.as_object_mut().ok_or_else(invalid)?.remove("catalog");
        return publication::prepare_output(source, &value.to_string()).map(Some);
    };
    if request.kind != "publication" {
        return Err(invalid());
    }
    let _ = (
        request.preview_offset,
        &request.post_edits,
        request.allow_unchanged_copy,
    ); // Typed validation; shared builder consumes canonical request.
    let plan = catalog.resolve(source)?;
    let structure = request.structure.unwrap_or_else(|| Structure::new(source));
    let mut projection = crate::catalog::project(source, &plan)?;
    let manual_evidence = if let Some(manual) = request.manual {
        let (edited, evidence) = publication::edit_projection_with_evidence(
            source,
            &structure,
            projection,
            &manual.to_string(),
        )?;
        projection = edited;
        Some(evidence)
    } else {
        None
    };
    let book = publication::compose_projected_with_cleanup(
        source,
        &structure,
        projection,
        request.cleanup.as_ref().map(Value::to_string).as_deref(),
    )?;
    let mut changes = Vec::new();
    if let Some(relocation) = &plan.relocation {
        // Include each complete moved chapter and its introduction; exact source
        // byte ranges plus the transaction backup reconstruct every character.
        for heading in &relocation.removed_headings {
            changes.push(
                json!({"stage":"catalog","coordinate_system":"original_source",
                "source_line":heading["line"],"kind":"replace_volume_heading",
                "before":heading["title"],"after":"【旧卷名移除，按目录在归位位置重建】",
                "source_utf8_start":heading["start"],"source_utf8_end":heading["end"]}),
            );
        }
        for (index, piece) in relocation.pieces.iter().enumerate() {
            changes.push(json!({"stage":"catalog","coordinate_system":"original_source",
                "source_line":piece.source_line,"kind":"relocate_chapter",
                "before":piece.title,"after":format!("目录第 {} 项 · {}",index+1,piece.title),
                "insert_volume":piece.insert_volume,"source_utf8_start":piece.start,"source_utf8_end":piece.end,
                "intro_utf8_start":piece.intro_start,"intro_utf8_end":piece.intro_end}));
        }
    } else {
        for edit in &plan.edits {
            changes.push(
                json!({"stage":"catalog","coordinate_system":"original_source",
                "source_line":edit.line,"kind":edit.kind,"before":edit.before,"after":edit.after}),
            );
        }
    }
    let (book, resolved) = if let Some(edits) = request
        .post_edits
        .as_ref()
        .filter(|e| e.checkpoint.is_some())
    {
        let base_id = easypub_core::effective_edit::base_id(&book);
        let (book, evidence) = crate::edit_checkpoint::apply(book, edits)?;
        (book, Some((base_id, evidence)))
    } else {
        (book, None)
    };
    publication::prepare_composed_output_resolved(
        source,
        value,
        book,
        manual_evidence,
        Some(serde_json::to_value(plan).map_err(|_| invalid())?),
        changes,
        resolved,
    )
    .map(Some)
}
