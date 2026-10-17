//! Recovery-only source copies. Keep path identity separately from resident bytes.
use crate::{project::Project, sessions::ImportService};
use easypub_core::{ApiError, ErrorCode};
use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::{Component, Path, PathBuf},
};

fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "source_recovery",
        "choose_supported_project",
    )
}
fn io() -> ApiError {
    ApiError::new(ErrorCode::Io, "source_recovery", "check_path_permissions")
}

pub(crate) struct Captured {
    root: PathBuf,
    files: Vec<PathBuf>,
    keep: bool,
}
impl Captured {
    pub fn keep(mut self) {
        self.keep = true;
    }
}
impl Drop for Captured {
    fn drop(&mut self) {
        if !self.keep {
            // Only paths created by this invocation; never recursive deletion.
            for path in &self.files {
                let _ = fs::remove_file(path);
            }
            let _ = fs::remove_dir(&self.root);
        }
    }
}
pub(crate) fn capture(
    service: &ImportService,
    project: &mut Project,
    target: &Path,
) -> Result<Captured, ApiError> {
    let root = target.with_file_name(format!(
        "{}.sources",
        target
            .file_name()
            .and_then(|x| x.to_str())
            .ok_or_else(invalid)?
    ));
    fs::create_dir(&root).map_err(|e| {
        if e.kind() == std::io::ErrorKind::AlreadyExists {
            ApiError::new(
                ErrorCode::OutputConflict,
                "source_recovery",
                "choose_new_project_path",
            )
        } else {
            io()
        }
    })?;
    let mut captured = Captured {
        root,
        files: Vec::new(),
        keep: false,
    };
    for (index, book) in project.books.iter_mut().enumerate() {
        let source = service.source(&book.source_id, book.revision)?;
        // Identical-content books still need distinct paths in the project.
        let path = captured
            .root
            .join(format!("{index}-{}.txt", book.source_id));
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .map_err(|_| io())?;
        captured.files.push(path.clone());
        file.write_all(source.original_bytes()).map_err(|_| io())?;
        file.sync_all().map_err(|_| io())?;
        if book.origin_path.is_none() {
            book.origin_path = Some(book.path.clone());
        }
        if project.current_path == book.path {
            project.current_path = path.to_string_lossy().into_owned();
        }
        book.path = path.to_string_lossy().into_owned();
    }
    Ok(captured)
}

fn relative(path: &Path) -> Result<(), ApiError> {
    let mut parts = path.components();
    let Some(Component::Normal(directory)) = parts.next() else {
        return Err(invalid());
    };
    if !directory
        .to_string_lossy()
        .ends_with(".easypub.json.sources")
        || !matches!(parts.next(), Some(Component::Normal(_)))
        || parts.next().is_some()
        || path.extension().and_then(|x| x.to_str()) != Some("txt")
    {
        return Err(invalid());
    }
    Ok(())
}
pub(crate) fn relativize(project: &mut Project, target: &Path) -> Result<(), ApiError> {
    let parent = target.parent().ok_or_else(invalid)?;
    for book in &mut project.books {
        let path = Path::new(&book.path)
            .strip_prefix(parent)
            .map_err(|_| invalid())?;
        relative(path)?;
        let value = path.to_string_lossy().into_owned();
        if project.current_path == book.path {
            project.current_path = value.clone();
        }
        book.path = value;
    }
    Ok(())
}
pub(crate) fn resolve(project: &mut Project, target: &Path) -> Result<(), ApiError> {
    let parent = target.parent().ok_or_else(invalid)?;
    for book in &mut project.books {
        if !Path::new(&book.path).is_absolute() {
            relative(Path::new(&book.path))?;
            let path = parent.join(&book.path).to_string_lossy().into_owned();
            if project.current_path == book.path {
                project.current_path = path.clone();
            }
            book.path = path;
        }
    }
    Ok(())
}
