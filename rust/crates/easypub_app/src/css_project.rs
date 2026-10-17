//! Project-local CSS sidecars, including retained production history states.
use crate::{
    css_bundle::{self, Reference},
    production::Settings,
    project::Project,
};
use easypub_core::{ApiError, ErrorCode};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
};
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "css_project",
        "review_css_project_resources",
    )
}
struct Writer {
    parent: PathBuf,
    root: Option<PathBuf>,
    copies: BTreeMap<String, Reference>,
    total: usize,
}
impl Writer {
    fn attach(&mut self, settings: &mut Settings) -> Result<(), ApiError> {
        if settings.additional_css.is_empty() {
            settings.additional_css_bundle = None;
            return Ok(());
        }
        let key = format!(
            "{:x}",
            Sha256::digest(
                serde_json::to_vec(&(
                    &settings.additional_css,
                    &settings.additional_css_base,
                    settings
                        .additional_css_bundle
                        .as_ref()
                        .map(|r| &r.manifest_sha256)
                ))
                .map_err(|_| invalid())?
            )
        );
        if let Some(reference) = self.copies.get(&key) {
            settings.additional_css_bundle = Some(reference.clone());
            return Ok(());
        }
        let snapshot = css_bundle::for_settings(settings);
        // Projects may retain unavailable dependencies for later repair.
        if !snapshot.report.rewritten {
            return Ok(());
        }
        let bytes = snapshot
            .bytes
            .values()
            .chain(snapshot.resources.values())
            .map(Vec::len)
            .sum::<usize>();
        self.total = self.total.checked_add(bytes).ok_or_else(invalid)?;
        if self.total > 256 * 1024 * 1024 {
            return Err(invalid());
        }
        if self.root.is_none() {
            let root = self.parent.join(format!(
                "easypub-css-assets-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_err(|_| invalid())?
                    .as_nanos()
            ));
            fs::create_dir(&root).map_err(|_| invalid())?;
            self.root = Some(root);
        }
        let root = self.root.as_ref().unwrap();
        let directory = root.join(&key);
        let manifest_sha256 = css_bundle::persist(
            &directory,
            &settings.additional_css,
            &settings.additional_css_base,
            &snapshot,
        )?;
        let reference = Reference {
            directory: directory
                .strip_prefix(&self.parent)
                .map_err(|_| invalid())?
                .to_string_lossy()
                .into_owned(),
            manifest_sha256,
        };
        settings.additional_css_bundle = Some(reference.clone());
        self.copies.insert(key, reference);
        Ok(())
    }
}
pub fn attach(project: &mut Project, target: &Path) -> Result<(), ApiError> {
    let mut writer = Writer {
        parent: target.parent().ok_or_else(invalid)?.to_path_buf(),
        root: None,
        copies: BTreeMap::new(),
        total: 0,
    };
    for book in &mut project.books {
        let mut current = Settings::from(&*book);
        writer.attach(&mut current)?;
        book.additional_css_bundle = current.additional_css_bundle;
        if let Some(history) = &mut book.production_history {
            for settings in &mut history.states {
                writer.attach(settings)?;
            }
        }
    }
    Ok(())
}
pub fn resolve(project: &mut Project, target: &Path) -> Result<(), ApiError> {
    let parent = target.parent().ok_or_else(invalid)?;
    let resolve = |reference: &mut Option<Reference>| {
        if let Some(reference) = reference
            && !Path::new(&reference.directory).is_absolute() {
                reference.directory = parent
                    .join(&reference.directory)
                    .to_string_lossy()
                    .into_owned();
            }
    };
    for book in &mut project.books {
        resolve(&mut book.additional_css_bundle);
        if let Some(history) = &mut book.production_history {
            for state in &mut history.states {
                resolve(&mut state.additional_css_bundle);
            }
        }
    }
    Ok(())
}
