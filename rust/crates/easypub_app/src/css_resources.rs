//! Immutable dependency graph and token-preserving content-addressed CSS rewriting.
use crate::css_references;
use base64::Engine;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::File,
    io::Read,
};
const MAX_TOTAL: usize = 128 * 1024 * 1024;
const MAX_FILE: usize = 32 * 1024 * 1024;
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileEvidence {
    pub path: String,
    pub sha256: String,
    pub byte_length: usize,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Resource {
    pub id: String,
    pub byte_length: usize,
}
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Report {
    pub files: Vec<FileEvidence>,
    pub issues: Vec<String>,
    pub total_bytes: usize,
    pub rewritten: bool,
    pub root_id: Option<String>,
    pub resources: Vec<Resource>,
}
#[derive(Default)]
pub struct Snapshot {
    pub report: Report,
    pub bytes: BTreeMap<String, Vec<u8>>,
    pub resources: BTreeMap<String, Vec<u8>>,
    paths: BTreeMap<String, String>,
    processed: BTreeMap<(String, bool), String>,
    active: BTreeSet<(String, bool)>,
    output_bytes: usize,
    edges: usize,
}
pub fn collect(css: &str, base: &str) -> Snapshot {
    let mut snapshot = Snapshot::default();
    let rewritten = snapshot.visit_css(css, base, 0);
    if snapshot.report.issues.is_empty()
        && let Some(css) = rewritten {
            snapshot.report.root_id = snapshot.emit(css.into_bytes(), "css");
        }
    snapshot.report.rewritten =
        snapshot.report.issues.is_empty() && snapshot.report.root_id.is_some();
    if !snapshot.report.rewritten {
        snapshot.resources.clear();
        snapshot.report.root_id = None;
    }
    snapshot.report.resources = snapshot
        .resources
        .iter()
        .map(|(id, bytes)| Resource {
            id: id.clone(),
            byte_length: bytes.len(),
        })
        .collect();
    snapshot
}
impl Snapshot {
    pub fn from_restored(value: crate::css_bundle::Restored) -> Self {
        Self {
            report: value.manifest.report,
            bytes: value.originals,
            resources: value.resources,
            ..Self::default()
        }
    }
    fn issue(&mut self, reason: &str, value: &str) {
        if self.report.issues.len() < 129 {
            self.report.issues.push(format!("{reason}: {value}"));
        }
    }
    fn emit(&mut self, bytes: Vec<u8>, extension: &str) -> Option<String> {
        let id = format!("{:x}.{extension}", Sha256::digest(&bytes));
        if !self.resources.contains_key(&id) {
            if self.output_bytes + bytes.len() > MAX_TOTAL {
                self.issue("重写资源超过 128 MiB", &id);
                return None;
            }
            self.output_bytes += bytes.len();
            self.resources.insert(id.clone(), bytes);
        }
        Some(id)
    }
    fn visit_css(&mut self, css: &str, base: &str, depth: usize) -> Option<String> {
        if depth > 16 {
            self.issue("导入层数超过 16", base);
            return None;
        }
        let refs = css_references::inspect(css);
        if refs.incomplete {
            self.issue("引用扫描未完成", base);
            return None;
        }
        let mut replacements = Vec::new();
        let mut valid = true;
        for (value, span) in refs.references.iter().zip(&refs.occurrences) {
            self.edges += 1;
            if self.edges > 512 {
                self.issue("依赖引用超过 512 项", base);
                return None;
            }
            let resolved = css_references::resolve(value, base);
            if resolved.kind == "inline_data" {
                let id = self.visit_inline(value, depth, span.is_import);
                if let Some(id) = id {
                    replacements.push(id);
                } else {
                    self.issue("内联资源编码、格式或大小不受支持", "data URI");
                    valid = false;
                    replacements.push(value.clone());
                }
                continue;
            }
            if resolved.kind == "document_fragment" && !span.is_import {
                replacements.push(value.clone());
                continue;
            }
            let Some(path) = resolved.local_path else {
                self.issue("引用尚不能建立本地快照", value);
                valid = false;
                replacements.push(value.clone());
                continue;
            };
            match self.visit_file(&path, depth, span.is_import) {
                Some(mut id) => {
                    if let Some(fragment) = resolved.fragment {
                        id.push('#');
                        id.push_str(&fragment);
                    }
                    replacements.push(id);
                }
                None => {
                    valid = false;
                    replacements.push(value.clone());
                }
            }
        }
        if valid {
            css_references::rewrite(css, &refs, &replacements)
        } else {
            None
        }
    }
    fn visit_inline(&mut self, value: &str, depth: usize, is_css: bool) -> Option<String> {
        let value = value.trim();
        // CSS itself is bounded; retain a separate limit for this reusable collector.
        if value.len() > 262144 {
            return None;
        }
        let (header, payload) = value.get(5..)?.split_once(',')?;
        let header = header.to_ascii_lowercase();
        let (mime, encoded) = header
            .strip_suffix(";base64")
            .map(|m| (m, true))
            .unwrap_or((&header, false));
        let extension = match mime {
            "text/css" | "text/css;charset=utf-8" if is_css => "css",
            "image/png" => "png",
            "image/jpeg" => "jpg",
            "image/webp" => "webp",
            "font/ttf" => "ttf",
            "font/otf" => "otf",
            "font/woff" | "application/font-woff" => "woff",
            _ => return None,
        };
        if is_css != (extension == "css") {
            return None;
        }
        let mut decoded = Vec::with_capacity(payload.len());
        let raw = payload.as_bytes();
        let mut i = 0;
        while i < raw.len() {
            if raw[i] == b'%' {
                let hex = |b: u8| (b as char).to_digit(16).map(|n| n as u8);
                decoded.push(hex(*raw.get(i + 1)?)? * 16 + hex(*raw.get(i + 2)?)?);
                i += 3;
            } else {
                // '+' is a literal byte in data URLs, not form-encoded space.
                decoded.push(raw[i]);
                i += 1;
            }
        }
        let bytes = if encoded {
            base64::engine::general_purpose::STANDARD
                .decode(decoded)
                .ok()?
        } else {
            decoded
        };
        if bytes.is_empty() && !is_css {
            return None;
        }
        if is_css {
            if self.report.total_bytes + bytes.len() > MAX_TOTAL {
                return None;
            }
            self.report.total_bytes += bytes.len();
            let css =
                std::str::from_utf8(bytes.strip_prefix(&[239, 187, 191]).unwrap_or(&bytes)).ok()?;
            if css.contains('\0') {
                return None;
            }
            // A data stylesheet has no filesystem base. Never resolve its relative
            // references against the enclosing file's directory.
            let rewritten = self.visit_css(css, "", depth + 1)?;
            return self.emit(rewritten.into_bytes(), "css");
        }
        let id = format!("{:x}.{extension}", Sha256::digest(&bytes));
        if self.resources.contains_key(&id) {
            return Some(id);
        }
        let audit = crate::css_media::inspect(&BTreeMap::from([(id.clone(), bytes.clone())]));
        if !matches!(
            audit[0].status,
            "image_decoded" | "font_permission_required"
        ) {
            return None;
        }
        if self.report.total_bytes + bytes.len() > MAX_TOTAL {
            return None;
        }
        self.report.total_bytes += bytes.len();
        self.emit(bytes, extension)
    }
    fn visit_file(&mut self, path: &str, depth: usize, is_css: bool) -> Option<String> {
        let Ok(canonical) = std::fs::canonicalize(path) else {
            self.issue("文件不存在或无法访问", path);
            return None;
        };
        let key = canonical.to_string_lossy().into_owned();
        let role_key = (key.clone(), is_css);
        if self.active.contains(&role_key) {
            self.issue("循环导入", path);
            return None;
        }
        if let Some(id) = self.processed.get(&role_key) {
            return Some(id.clone());
        }
        let bytes = if let Some(hash) = self.paths.get(&key) {
            self.bytes[hash].clone()
        } else {
            if self.paths.len() >= 128 {
                self.issue("依赖文件超过 128 项", path);
                return None;
            }
            let limit = if is_css { 262144 + 3 } else { MAX_FILE };
            let read = (|| -> std::io::Result<Vec<u8>> {
                let file = File::open(&canonical)?;
                let meta = file.metadata()?;
                if !meta.is_file() || meta.len() > limit as u64 {
                    return Err(std::io::ErrorKind::InvalidData.into());
                }
                let mut bytes = Vec::new();
                file.take(limit as u64 + 1).read_to_end(&mut bytes)?;
                if bytes.len() > limit {
                    return Err(std::io::ErrorKind::InvalidData.into());
                }
                Ok(bytes)
            })();
            let Ok(bytes) = read else {
                self.issue("文件不可读取或超过大小限制", path);
                return None;
            };
            if self.report.total_bytes + bytes.len() > MAX_TOTAL {
                self.issue("依赖总量超过 128 MiB", path);
                return None;
            }
            let hash = format!("{:x}", Sha256::digest(&bytes));
            self.report.total_bytes += bytes.len();
            self.report.files.push(FileEvidence {
                path: key.clone(),
                sha256: hash.clone(),
                byte_length: bytes.len(),
            });
            self.paths.insert(key.clone(), hash.clone());
            self.bytes.entry(hash).or_insert_with(|| bytes.clone());
            bytes
        };
        let result = if is_css {
            let raw = bytes.strip_prefix(&[239, 187, 191]).unwrap_or(&bytes);
            if raw.len() > 262144 {
                self.issue("样式内容超过 256 KiB", path);
                return None;
            }
            match std::str::from_utf8(raw) {
                Ok(css) if !css.contains('\0') => {
                    self.active.insert(role_key.clone());
                    let base = canonical.parent().unwrap().to_string_lossy();
                    let css = self.visit_css(css, &base, depth + 1);
                    self.active.remove(&role_key);
                    css.and_then(|css| self.emit(css.into_bytes(), "css"))
                }
                _ => {
                    self.issue("导入样式必须是无空字符 UTF-8", path);
                    None
                }
            }
        } else {
            let extension = canonical
                .extension()
                .and_then(|e| e.to_str())
                .unwrap_or("bin")
                .to_ascii_lowercase();
            let extension = match extension.as_str() {
                "png" | "jpg" | "jpeg" | "webp" | "svg" | "ttf" | "otf" | "woff" | "woff2" => {
                    extension.as_str()
                }
                _ => "bin",
            };
            self.emit(bytes, extension)
        };
        if let Some(id) = &result {
            self.processed.insert(role_key, id.clone());
        }
        result
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn inline_stylesheets_recurse_preserve_conditions_and_refuse_relative_base_guessing() {
        let uri = |css: &str| {
            format!(
                "data:text/css;charset=utf-8;base64,{}",
                base64::engine::general_purpose::STANDARD.encode(css)
            )
        };
        let nested = format!(
            "@import url('{}') print; p{{color:blue}}",
            uri("h1{color:red}")
        );
        let root = format!("@import '{}' screen;", uri(&nested));
        let snapshot = collect(&root, "D:/must-not-be-inherited");
        assert!(snapshot.report.rewritten, "{:?}", snapshot.report.issues);
        assert_eq!(snapshot.resources.len(), 3);
        let root_css =
            std::str::from_utf8(&snapshot.resources[snapshot.report.root_id.as_ref().unwrap()])
                .unwrap();
        assert!(root_css.ends_with(" screen;"));
        assert!(
            snapshot
                .resources
                .values()
                .any(|v| std::str::from_utf8(v).unwrap().contains(" print;"))
        );
        for css in [
            "p{background:url(relative.png)}",
            "@import 'relative.css';",
            "p{color:\0red}",
        ] {
            assert!(
                !collect(&format!("@import '{}';", uri(css)), "D:/")
                    .report
                    .rewritten
            );
        }
        let mut deep = "p{color:red}".to_owned();
        for _ in 0..18 {
            deep = format!("@import '{}';", uri(&deep));
        }
        assert!(!collect(&deep, "").report.rewritten);
        assert!(
            !collect("@import 'data:text/css;base64,/w==';", "")
                .report
                .rewritten
        );
        assert!(
            collect("@import 'data:text/css,p%7Bcolor%3Ared%7D';", "")
                .report
                .rewritten
        );
    }
    #[test]
    fn inline_images_decode_deduplicate_and_survive_offline_bundle() {
        let mut encoded = std::io::Cursor::new(Vec::new());
        image::DynamicImage::new_rgb8(2, 3)
            .write_to(&mut encoded, image::ImageFormat::Png)
            .unwrap();
        let bytes = encoded.into_inner();
        let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
        let percent = bytes
            .iter()
            .map(|b| format!("%{b:02X}"))
            .collect::<String>();
        let css = format!(
            "a{{background:url('data:image/png;base64,{b64}')}}b{{background:url('DATA:image/png,{percent}')}}"
        );
        let snapshot = collect(&css, "");
        assert!(snapshot.report.rewritten, "{:?}", snapshot.report.issues);
        assert_eq!(snapshot.resources.len(), 2);
        assert_eq!(snapshot.report.total_bytes, bytes.len());
        assert!(snapshot.report.files.is_empty());
        let rewritten =
            std::str::from_utf8(&snapshot.resources[snapshot.report.root_id.as_ref().unwrap()])
                .unwrap();
        assert!(!rewritten.contains("data:"));
        let dir = std::env::temp_dir().join(format!(
            "easypub-inline-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let hash = crate::css_bundle::persist(&dir, &css, "", &snapshot).unwrap();
        let restored = crate::css_bundle::restore(&dir, &hash).unwrap();
        assert_eq!(restored.resources, snapshot.resources);
        std::fs::remove_dir_all(dir).unwrap();
        for url in [
            "data:image/png;base64,!!!!",
            "data:image/png,%XZ",
            "data:image/png;base64,ZmFrZQ==",
            "data:text/html;base64,PHNjcmlwdD4=",
            "data:image/svg+xml,%3Csvg/%3E",
        ] {
            let failed = collect(&format!("a{{background:url('{url}')}}"), "");
            assert!(!failed.report.rewritten);
            assert!(failed.resources.is_empty());
            assert!(!failed.report.issues[0].contains(url));
        }
        assert!(
            !collect(&format!("@import 'data:image/png;base64,{b64}';"), "")
                .report
                .rewritten
        );
        assert!(
            !collect(
                &format!("a{{background:url('data:image/jpeg;base64,{b64}')}}"),
                ""
            )
            .report
            .rewritten
        );
    }
    fn fixture() -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!(
            "easypub-css-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(path.join("sub")).unwrap();
        path
    }
    #[test]
    fn recursive_files_are_immutable_deduplicated_and_cycles_reported() {
        let dir = fixture();
        std::fs::write(dir.join("image.png"), b"snapshot bytes").unwrap();
        std::fs::write(dir.join("sub/a.css"), "p{background:url(../image.png)}").unwrap();
        let css = "@import 'sub/a.css'; p{background:url(image.png)}";
        let snapshot = collect(css, dir.to_str().unwrap());
        assert!(snapshot.report.issues.is_empty());
        assert_eq!(snapshot.report.files.len(), 2);
        assert_eq!(snapshot.bytes.len(), 2);
        let original = snapshot
            .report
            .files
            .iter()
            .find(|f| f.path.ends_with("image.png"))
            .unwrap();
        std::fs::write(dir.join("image.png"), b"changed bytes!").unwrap();
        assert_eq!(snapshot.bytes[&original.sha256], b"snapshot bytes");
        let changed = collect(css, dir.to_str().unwrap());
        assert_ne!(
            original.sha256,
            changed
                .report
                .files
                .iter()
                .find(|f| f.path.ends_with("image.png"))
                .unwrap()
                .sha256
        );
        std::fs::write(dir.join("sub/a.css"), "@import 'a.css';").unwrap();
        assert!(
            collect(css, dir.to_str().unwrap())
                .report
                .issues
                .iter()
                .any(|i| i.contains("循环"))
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn extensionless_imports_rewrite_to_closed_resource_graph() {
        let dir = fixture();
        std::fs::write(dir.join("image.png"), b"image-snapshot").unwrap();
        std::fs::write(
            dir.join("sub/theme"),
            "/* 内层 */ p { background:url(../image.png#view); content:'../image.png'; }",
        )
        .unwrap();
        let css = "/* 根 */ @import 'sub/theme' layer(theme) supports(display:grid) screen; p{background:url(image.png)}";
        let snapshot = collect(css, dir.to_str().unwrap());
        assert!(snapshot.report.rewritten, "{:?}", snapshot.report.issues);
        assert_eq!(snapshot.report.files.len(), 2);
        assert_eq!(snapshot.report.resources.len(), 3);
        let root =
            std::str::from_utf8(&snapshot.resources[snapshot.report.root_id.as_ref().unwrap()])
                .unwrap();
        assert!(root.contains("layer(theme) supports(display:grid) screen"));
        for (id, bytes) in &snapshot.resources {
            assert!(id.starts_with(&format!("{:x}", Sha256::digest(bytes))));
            if id.ends_with(".css") {
                let report = css_references::inspect(std::str::from_utf8(bytes).unwrap());
                assert!(!report.incomplete);
                for reference in report.references {
                    assert!(
                        snapshot
                            .resources
                            .contains_key(reference.split('#').next().unwrap())
                    );
                }
            }
        }
        std::fs::write(dir.join("sub/theme"), "@import 'theme';").unwrap();
        let broken = collect(css, dir.to_str().unwrap());
        assert!(!broken.report.rewritten);
        assert!(broken.report.root_id.is_none());
        assert!(broken.resources.is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn missing_external_and_non_utf8_imports_remain_visible() {
        let dir = fixture();
        std::fs::write(dir.join("bad.css"), [255, 254]).unwrap();
        let snapshot = collect(
            "@import 'bad.css'; p { background:url(missing.png); mask:url(https://example.com/a); }",
            dir.to_str().unwrap(),
        );
        assert_eq!(snapshot.report.issues.len(), 3);
        assert!(!snapshot.report.rewritten);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
