//! Carry every retained checkpoint alongside a saved project, including redo.
use crate::{edit_checkpoint, project::Project};
use easypub_core::{ApiError, ErrorCode};
use std::{
    collections::BTreeSet,
    fs,
    path::{Component, Path, PathBuf},
};

fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "checkpoint_project",
        "restore_project_checkpoints",
    )
}

// Called only after history validation, before publishing the project file.
// The live workspace is not mutated: this owns the parsed save snapshot.
pub fn attach(project: &mut Project, target: &Path) -> Result<(), ApiError> {
    let parent = target.parent().ok_or_else(invalid)?;
    let mut root: Option<PathBuf> = None;
    let mut copied = BTreeSet::new();
    for book in &mut project.books {
        if let Some(history) = &mut book.effective_history {
            for state in &mut history.history {
                if let Some(checkpoint) = &mut state.request.checkpoint {
                    if root.is_none() {
                        let directory = parent.join(format!(
                            "easypub-edit-assets-{}-{}",
                            std::process::id(),
                            std::time::SystemTime::now()
                                .duration_since(std::time::UNIX_EPOCH)
                                .map_err(|_| invalid())?
                                .as_nanos()
                        ));
                        fs::create_dir(&directory).map_err(|_| invalid())?;
                        root = Some(directory);
                    }
                    let directory = root.as_ref().unwrap();
                    if copied.insert(checkpoint.reference.digest.clone()) {
                        let effective = edit_checkpoint::load(
                            &checkpoint.directory,
                            &checkpoint.reference,
                            &history.source_id,
                        )?;
                        let reference = edit_checkpoint::save(directory, &effective)?;
                        if reference != checkpoint.reference {
                            return Err(invalid());
                        }
                    }
                    checkpoint.directory = directory.clone();
                }
            }
        }
    }
    Ok(())
}

// Only the on-disk project has relative references. Runtime APIs keep absolute
// paths and their existing validation; project JSON cannot relax that contract.
pub fn relativize(project: &mut Project, target: &Path) -> Result<(), ApiError> {
    let parent = target.parent().ok_or_else(invalid)?;
    for book in &mut project.books {
        if let Some(history) = &mut book.effective_history {
            for state in &mut history.history {
                if let Some(checkpoint) = &mut state.request.checkpoint {
                    checkpoint.directory = checkpoint
                        .directory
                        .strip_prefix(parent)
                        .map_err(|_| invalid())?
                        .to_path_buf();
                    validate_relative(&checkpoint.directory)?;
                }
            }
        }
    }
    Ok(())
}

fn validate_relative(directory: &Path) -> Result<(), ApiError> {
    let mut components = directory.components();
    if !matches!(components.next(), Some(Component::Normal(_))) || components.next().is_some() {
        return Err(invalid());
    }
    Ok(())
}

pub fn resolve(project: &mut Project, target: &Path) -> Result<(), ApiError> {
    let parent = target.parent().ok_or_else(invalid)?;
    for book in &mut project.books {
        if let Some(history) = &mut book.effective_history {
            for state in &mut history.history {
                if let Some(checkpoint) = &mut state.request.checkpoint
                    && !checkpoint.directory.is_absolute() {
                        validate_relative(&checkpoint.directory)?;
                        checkpoint.directory = parent.join(&checkpoint.directory);
                    }
            }
        }
    }
    Ok(())
}
