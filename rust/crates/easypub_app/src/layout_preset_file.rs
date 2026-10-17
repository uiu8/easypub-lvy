//! Bounded, portable layout preset exchange. Publishing never overwrites a file.
use crate::layout_presets::Preset;
use easypub_core::{ApiError, ErrorCode};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::Path,
    sync::atomic::{AtomicU64, Ordering},
};

const MAX_BYTES: usize = 1024 * 1024;
static NEXT: AtomicU64 = AtomicU64::new(0);
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Bundle {
    pub schema_version: u32,
    pub kind: String,
    pub presets: Vec<Preset>,
}
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Request {
    Read { path: String },
    Write { path: String, bundle: Bundle },
}
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "layout_preset_file",
        "review_preset_file",
    )
}
fn io() -> ApiError {
    ApiError::new(
        ErrorCode::OutputConflict,
        "layout_preset_file",
        "choose_new_writable_path",
    )
}
fn validate(bundle: &Bundle) -> Result<(), ApiError> {
    if bundle.schema_version != 1
        || bundle.kind != "easypub_layout_presets"
        || bundle.presets.is_empty()
    {
        return Err(invalid());
    }
    crate::layout_presets::validate(&bundle.presets)?;
    for preset in &bundle.presets {
        crate::layout_settings::Layers {
            preset: preset.values.clone(),
            ..Default::default()
        }
        .resolve()?;
    }
    Ok(())
}
fn read(path: &Path) -> Result<Bundle, ApiError> {
    let mut bytes = Vec::new();
    File::open(path)
        .map_err(|_| io())?
        .take((MAX_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| io())?;
    if bytes.len() > MAX_BYTES {
        return Err(invalid());
    }
    let bundle: Bundle = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
    validate(&bundle)?;
    Ok(bundle)
}
fn write(path: &Path, bundle: &Bundle) -> Result<(), ApiError> {
    validate(bundle)?;
    let bytes = serde_json::to_vec_pretty(bundle).map_err(|_| invalid())?;
    if bytes.len() > MAX_BYTES || !path.is_absolute() {
        return Err(invalid());
    }
    let parent = path.parent().ok_or_else(invalid)?;
    let stage = parent.join(format!(
        ".easypub-preset-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&stage)
        .map_err(|_| io())?;
    let result = (|| {
        file.write_all(&bytes).map_err(|_| io())?;
        file.sync_all().map_err(|_| io())?;
        fs::hard_link(&stage, path).map_err(|_| io())?;
        Ok(())
    })();
    drop(file);
    let _ = fs::remove_file(stage);
    result
}
pub fn request_text(input: &str) -> Result<String, ApiError> {
    if input.len() > MAX_BYTES + 32768 {
        return Err(invalid());
    }
    let bundle = match serde_json::from_str(input).map_err(|_| invalid())? {
        Request::Read { path } => read(Path::new(&path))?,
        Request::Write { path, bundle } => {
            write(Path::new(&path), &bundle)?;
            bundle
        }
    };
    serde_json::to_string(&bundle).map_err(|_| invalid())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn roundtrip_rejects_overwrite_and_invalid_or_oversized_input() {
        let root = std::env::temp_dir().join(format!(
            "easypub-preset-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&root).unwrap();
        let path = root.join("预设.json");
        let bundle: Bundle =
            serde_json::from_value(json!({"schema_version":1,"kind":"easypub_layout_presets",
            "presets":[{"name":"正文","values":{"font_size":20}}]}))
            .unwrap();
        write(&path, &bundle).unwrap();
        let original = fs::read(&path).unwrap();
        assert_eq!(read(&path).unwrap().presets[0].name, "正文");
        assert!(write(&path, &bundle).is_err());
        assert_eq!(fs::read(&path).unwrap(), original);
        assert_eq!(fs::read_dir(&root).unwrap().count(), 1);
        fs::write(&path, vec![b' '; MAX_BYTES + 1]).unwrap();
        assert!(read(&path).is_err());
        assert!(request_text(r#"{"op":"read","path":"x","extra":true}"#).is_err());
        let invalid_bundle = Bundle {
            schema_version: 2,
            ..bundle
        };
        assert!(write(&root.join("bad.json"), &invalid_bundle).is_err());
        assert!(!root.join("bad.json").exists());
        fs::remove_file(path).unwrap();
        fs::remove_dir(root).unwrap();
    }
}
