// Section 6.5: manifest file references must match case on disk.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

use super::Check;
use crate::extracted::ExtractedEpub;
use crate::validate::ValidationReport;

pub struct FileCaseChecks;

struct DirectoryListing {
    exact: HashSet<String>,
    folded: HashMap<String, String>,
}

impl DirectoryListing {
    fn read(parent: &Path) -> Option<Self> {
        let mut listing = Self {
            exact: HashSet::new(),
            folded: HashMap::new(),
        };
        for entry in fs::read_dir(parent).ok()?.flatten() {
            if let Some(name) = entry.file_name().to_str() {
                listing.exact.insert(name.to_string());
                // Keep the last case-insensitive match in listing order,
                // just as the original per-item scan did.
                listing
                    .folded
                    .insert(name.to_ascii_lowercase(), name.to_string());
            }
        }
        Some(listing)
    }

    fn mismatch(&self, file_name: &str) -> Option<&str> {
        if self.exact.contains(file_name) {
            return None;
        }
        self.folded
            .get(&file_name.to_ascii_lowercase())
            .map(String::as_str)
    }
}

impl Check for FileCaseChecks {
    fn ids(&self) -> &'static [&'static str] {
        &["R6.5"]
    }

    fn run(&self, epub: &ExtractedEpub, report: &mut ValidationReport) {
        let opf = &epub.opf;
        // List and index each directory once. Caching a Vec alone still made
        // filename comparisons quadratic for thousands of chapters in one
        // folder (EasyPub patch). Same findings, same order.
        let mut listings: HashMap<PathBuf, Option<DirectoryListing>> = HashMap::new();
        for (href, _mt) in opf.manifest.values() {
            let rel = Path::new(href);
            let parent = opf.base_dir.join(rel.parent().unwrap_or(Path::new("")));
            let file_name = match rel.file_name().and_then(|s| s.to_str()) {
                Some(n) => n,
                None => continue,
            };

            let listing = listings
                .entry(parent.clone())
                .or_insert_with(|| DirectoryListing::read(&parent));
            let Some(listing) = listing.as_ref() else {
                continue;
            };

            if let Some(actual) = listing.mismatch(file_name) {
                report.emit_at(
                    "R6.5",
                    format!(
                        "Manifest references '{}' but file on disk is '{}'.",
                        file_name, actual
                    ),
                    Some(PathBuf::from(href)),
                    None,
                );
            }
        }
    }
}
