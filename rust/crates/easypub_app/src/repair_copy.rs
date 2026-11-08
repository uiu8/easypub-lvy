//! A repair copy uses the exact reviewed history, with a companion project for
//! structure that plain text cannot express. Existing files are never replaced.
use crate::{effective_draft::History, project::Project, sessions::ImportService};
use easypub_core::{
    ApiError, ErrorCode,
    encoding::EncodingMode,
    source::{RULE_ID, SourceSnapshot},
    structure::{Override, Role, Structure},
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::BTreeSet,
    fs::{self, OpenOptions},
    io::Write,
    path::PathBuf,
};
#[derive(Deserialize)]
struct Request {
    source_id: String,
    revision: u32,
    source_path: PathBuf,
    output_path: PathBuf,
    history: History,
    project: Project,
    confirmed: bool,
}
fn invalid() -> ApiError {
    ApiError::new(ErrorCode::InvalidRule, "repair_copy", "review_repair_copy")
}
pub fn execute(service: &ImportService, value: Value) -> Result<Value, ApiError> {
    let mut r: Request = serde_json::from_value(value).map_err(|_| invalid())?;
    if !r.confirmed
        || !r.output_path.is_absolute()
        || r.output_path
            .extension()
            .and_then(|s| s.to_str())
            .is_none_or(|s| !s.eq_ignore_ascii_case("txt"))
    {
        return Err(invalid());
    }
    let source = service.source(&r.source_id, r.revision)?;
    r.history.validate(&source)?;
    let snapshot = r.history.current();
    let base = snapshot.base.compose(&source)?;
    let (book, edits) = if snapshot.request.is_empty() {
        (base, Vec::new())
    } else {
        crate::edit_checkpoint::apply(base, &snapshot.request)?
    };
    let bytes = if book.text_changed {
        source.encode_edited_text(&book.text)?
    } else {
        source.original_bytes().to_vec()
    };
    let mode = match source.summary().encoding.as_str() {
        "utf-8" => EncodingMode::Utf8,
        "utf-16le" => EncodingMode::Utf16Le,
        "utf-16be" => EncodingMode::Utf16Be,
        "utf-32le" => EncodingMode::Utf32Le,
        "utf-32be" => EncodingMode::Utf32Be,
        "cp936" => EncodingMode::Cp936,
        _ => return Err(invalid()),
    };
    let copy = SourceSnapshot::from_bytes(bytes.clone(), mode, RULE_ID, || false)?;
    let mut structure = Structure::new(&copy);
    let lines = book
        .tree
        .nodes
        .iter()
        .map(|n| n.source_line)
        .collect::<BTreeSet<_>>();
    structure.overrides.extend(
        copy.headings()
            .iter()
            .filter(|h| !lines.contains(&h.source_line))
            .map(|h| Override {
                source_line: h.source_line,
                role: Role::Body,
                depth: 0,
                include_toc: false,
            }),
    );
    structure
        .overrides
        .extend(book.tree.nodes.iter().map(|n| Override {
            source_line: n.source_line,
            role: n.role.clone(),
            depth: n.depth,
            include_toc: n.include_toc,
        }));
    structure.overrides.sort_by_key(|n| n.source_line);
    structure.tree(&copy)?;
    r.project
        .books
        .retain(|b| b.path == r.source_path.to_string_lossy() && b.source_id == r.source_id);
    if r.project.books.len() != 1 {
        return Err(invalid());
    }
    let b = &mut r.project.books[0];
    for image in &mut b.illustrations {
        if let Some(line) = image.source_line {
            image.source_line = book.source_to_output_lines.get(&line).copied();
        }
    }
    b.path = r.output_path.to_string_lossy().into_owned();
    b.origin_path = None;
    b.epub_resources = None;
    b.source_id = copy.summary().source_id;
    b.revision = 1;
    b.structure = Some(structure);
    b.manual_draft = None;
    b.effective_history = None;
    b.structure_history = None;
    b.cleanup = None;
    b.cleanup_history = None;
    b.production_history = None;
    b.review = None;
    b.selected = true;
    r.project.current_path = b.path.clone();
    r.project.project_folder_rules_enabled = false;
    r.project.validate()?;
    let project_path = r.output_path.with_extension("easypub.json");
    if r.output_path.exists() || project_path.exists() {
        return Err(ApiError::new(
            ErrorCode::OutputConflict,
            "repair_copy",
            "choose_new_output_path",
        ));
    }
    let recheck = book.check_page(0, None)?;
    let payload = serde_json::to_vec_pretty(&r.project).map_err(|_| invalid())?;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&project_path)
        .map_err(|_| {
            ApiError::new(
                ErrorCode::OutputConflict,
                "repair_copy",
                "choose_new_output_path",
            )
        })?;
    let result = (|| {
        file.write_all(&payload)
            .and_then(|_| file.sync_all())
            .map_err(|_| ApiError::new(ErrorCode::Io, "repair_copy", "check_path_permissions"))?;
        let evidence=serde_json::to_vec(&json!({"kind":"repair_copy","history":r.history,"changes":edits,"project_path":project_path,"structure":book.tree})).map_err(|_|invalid())?;
        crate::transaction::apply_new_file_bytes_with_evidence(
            &r.source_path,
            &r.output_path,
            &bytes,
            &r.source_id,
            crate::transaction::InjectFault::None,
            Some(&evidence),
        )
    })();
    drop(file);
    match result {
        Ok(transaction) => Ok(
            json!({"output_path":r.output_path,"project_path":project_path,"source_unchanged":true,"transaction":transaction,"recheck":recheck}),
        ),
        Err(error) => {
            let _ = fs::remove_file(&project_path);
            Err(error)
        }
    }
}
