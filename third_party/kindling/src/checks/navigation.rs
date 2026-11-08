// Section 5: navigation (TOC, NCX presence and spine-toc reference).

use rayon::prelude::*;

use super::Check;
use super::helpers::strip_tags_len;
use crate::extracted::ExtractedEpub;
use crate::validate::ValidationReport;

pub struct NavigationChecks;

impl Check for NavigationChecks {
    fn ids(&self) -> &'static [&'static str] {
        &["R5.1", "R5.2.1", "R5.2.2"]
    }

    fn run(&self, epub: &ExtractedEpub, report: &mut ValidationReport) {
        let opf = &epub.opf;

        let ncx_id: Option<String> = opf
            .manifest
            .iter()
            .find(|(_, (_, mt))| mt == "application/x-dtbncx+xml")
            .map(|(id, _)| id.clone());

        if ncx_id.is_none() {
            report.emit("R5.2.1", "");
        }

        if let Ok(raw) = opf.content.read_to_string(&epub.opf_path) {
            let has_spine_toc = raw.lines().any(|l| {
                let lt = l.trim();
                lt.contains("<spine") && lt.contains("toc=")
            });
            if let Some(ref id) = ncx_id {
                if !has_spine_toc {
                    report.emit("R5.2.2", format!("NCX id: '{}'.", id));
                }
            }
        }

        let total_chars: usize = opf
            .spine_items
            .par_iter()
            .map(|(_, href)| {
                let full = opf.base_dir.join(href);
                opf.content
                    .read_to_string(&full)
                    .map(|content| strip_tags_len(&content))
                    .unwrap_or(0)
            })
            .sum();
        let approx_pages = total_chars / 1800;
        if approx_pages > 20 && ncx_id.is_none() {
            report.emit("R5.1", format!("Approximately {} pages.", approx_pages));
        }
    }
}
