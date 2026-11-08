//! Font metadata inspection; technical embedding flags are not a license grant.
use easypub_core::{ApiError, ErrorCode};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{collections::BTreeSet, fs::File, io::Read, path::Path};
const MAX_FONT_BYTES: u64 = 64 * 1024 * 1024;
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    #[default]
    Subset,
    Full,
}
impl Mode {
    fn is_subset(&self) -> bool {
        *self == Self::Subset
    }
}
/// User authorization is tied to exact file bytes and collection face.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Selection {
    pub path: String,
    pub face_index: u32,
    pub sha256: String,
    pub license_confirmed: bool,
    #[serde(default, skip_serializing_if = "Mode::is_subset")]
    pub mode: Mode,
}
impl Selection {
    pub fn validate(&self) -> Result<(), ApiError> {
        if self.path.len() > 32768
            || !Path::new(&self.path).is_absolute()
            || self.sha256.len() != 64
            || !self
                .sha256
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            || !self.license_confirmed
        {
            return Err(invalid());
        }
        Ok(())
    }
    pub fn inspect_confirmed(&self) -> Result<FontReport, ApiError> {
        self.validate()?;
        let report = inspect(&self.path, self.face_index, "")?;
        if report.sha256 != self.sha256
            || !report.embedding.outline_allowed
            || (self.mode == Mode::Subset && !report.embedding.subset_allowed)
        {
            return Err(invalid());
        }
        Ok(report)
    }
}
#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct Embedding {
    pub permission: &'static str,
    pub outline_allowed: bool,
    pub subset_allowed: bool,
}
fn policy(version: u16, flags: u16) -> Embedding {
    let low = flags & 15;
    let permission = if version > 5
        || low & 1 != 0
        || (version >= 3 && low.count_ones() > 1)
        || (version >= 2 && flags & 0xfcf0 != 0)
    {
        "unknown"
    } else if low & 8 != 0 {
        "editable"
    } else if low & 4 != 0 {
        "preview_print"
    } else if low & 2 != 0 {
        "restricted"
    } else {
        "installable"
    };
    let allowed = matches!(permission, "editable" | "preview_print" | "installable");
    let outline_allowed = allowed && (version < 2 || flags & 0x200 == 0);
    Embedding {
        permission,
        outline_allowed,
        subset_allowed: outline_allowed && (version < 2 || flags & 0x100 == 0),
    }
}
#[derive(Serialize)]
pub struct FontReport {
    pub sha256: String,
    pub bytes: usize,
    pub face_index: u32,
    pub family: Option<String>,
    pub license_text: Option<String>,
    pub license_url: Option<String>,
    pub embedding: Embedding,
    pub variable: bool,
    pub glyph_count: u16,
    pub requested_characters: usize,
    pub missing_count: usize,
    pub missing_sample: Vec<String>,
    pub license_confirmation_required: bool,
}
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "font_resource",
        "choose_valid_font_and_face",
    )
}
pub fn inspect(path: &str, index: u32, text: &str) -> Result<FontReport, ApiError> {
    if path.len() > 32768 || !Path::new(path).is_absolute() || text.len() > 8 * 1024 * 1024 {
        return Err(invalid());
    }
    let bytes = read_font(path)?;
    inspect_bytes(&bytes, index, text)
}
fn read_font(path: &str) -> Result<Vec<u8>, ApiError> {
    if path.len() > 32768 || !Path::new(path).is_absolute() {
        return Err(invalid());
    }
    let file = File::open(path).map_err(|_| invalid())?;
    let meta = file.metadata().map_err(|_| invalid())?;
    if !meta.is_file() || meta.len() == 0 || meta.len() > MAX_FONT_BYTES {
        return Err(invalid());
    }
    let mut bytes = Vec::new();
    file.take(MAX_FONT_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| invalid())?;
    if bytes.len() as u64 > MAX_FONT_BYTES {
        return Err(invalid());
    }
    Ok(bytes)
}
pub(crate) fn inspect_bytes(bytes: &[u8], index: u32, text: &str) -> Result<FontReport, ApiError> {
    let face = ttf_parser::Face::parse(bytes, index).map_err(|_| invalid())?;
    let os2 = face.raw_face().table(ttf_parser::Tag::from_bytes(b"OS/2"));
    let embedding = match os2.filter(|t| t.len() >= 10) {
        Some(t) => policy(
            u16::from_be_bytes([t[0], t[1]]),
            u16::from_be_bytes([t[8], t[9]]),
        ),
        None => Embedding {
            permission: "unknown",
            outline_allowed: false,
            subset_allowed: false,
        },
    };
    let name = |id| {
        face.names()
            .into_iter()
            .filter(|n| n.name_id == id)
            .find_map(|n| n.to_string())
            .map(|s| s.chars().take(16384).collect())
    };
    let chars = text
        .chars()
        .filter(|c| !c.is_control())
        .collect::<BTreeSet<_>>();
    let missing = chars
        .iter()
        .filter(|&&c| face.glyph_index(c).is_none())
        .copied()
        .collect::<Vec<_>>();
    Ok(FontReport {
        sha256: format!("{:x}", Sha256::digest(bytes)),
        bytes: bytes.len(),
        face_index: index,
        family: name(1),
        license_text: name(13),
        license_url: name(14),
        embedding,
        variable: face.is_variable(),
        glyph_count: face.number_of_glyphs(),
        requested_characters: chars.len(),
        missing_count: missing.len(),
        missing_sample: missing
            .iter()
            .take(32)
            .map(|c| format!("U+{:04X}", *c as u32))
            .collect(),
        license_confirmation_required: true,
    })
}
pub struct PreparedSubset {
    pub original: FontReport,
    pub subset: FontReport,
    pub bytes: Vec<u8>,
}
/// The exact inspected font bytes are subsetted; confirmation is hash-bound.
pub fn prepare_subset(
    path: &str,
    index: u32,
    text: &str,
    expected_sha256: &str,
    license_confirmed: bool,
) -> Result<PreparedSubset, ApiError> {
    use write_fonts::read::{FontRef, collections::IntSet};
    if !license_confirmed || text.is_empty() || text.len() > 8 * 1024 * 1024 {
        return Err(invalid());
    }
    let bytes = read_font(path)?;
    let original = inspect_bytes(&bytes, index, text)?;
    // 字体里没有的字不阻止嵌入（V123）：成品里这些字回落到阅读器字体，书里只要有一个生僻符号
    // 不在字体里（如日文中点）以前就整本不能嵌入、真机预览也生成不了。裁剪后不能比原字体多缺字。
    if original.sha256 != expected_sha256 || !original.embedding.subset_allowed {
        return Err(invalid());
    }
    let font = FontRef::from_index(&bytes, index).map_err(|_| invalid())?;
    let mut unicodes = IntSet::empty();
    unicodes.extend(text.chars().filter(|c| !c.is_control()).map(|c| c as u32));
    let mut names = IntSet::empty();
    names.invert();
    let mut languages = IntSet::empty();
    languages.invert();
    let mut scripts = IntSet::empty();
    scripts.invert();
    let mut features = IntSet::empty();
    features.invert();
    let drop_tables = skera::DEFAULT_DROP_TABLES.iter().copied().collect();
    let plan = skera::Plan::new(
        &IntSet::empty(),
        &unicodes,
        &font,
        skera::SubsetFlags::default(),
        &drop_tables,
        &scripts,
        &features,
        &names,
        &languages,
    );
    let output = skera::subset_font(&font, &plan).map_err(|_| invalid())?;
    if output.len() as u64 > MAX_FONT_BYTES {
        return Err(invalid());
    }
    let subset = inspect_bytes(&output, 0, text)?;
    if subset.missing_count != original.missing_count
        || subset.license_text != original.license_text
        || subset.license_url != original.license_url
    {
        return Err(invalid());
    }
    Ok(PreparedSubset {
        original,
        subset,
        bytes: output,
    })
}

/// Explicit full mode retains every glyph; collections become one complete face.
pub fn prepare_selected(selection: &Selection, text: &str) -> Result<PreparedSubset, ApiError> {
    selection.validate()?;
    if selection.mode == Mode::Subset {
        return prepare_subset(
            &selection.path,
            selection.face_index,
            text,
            &selection.sha256,
            selection.license_confirmed,
        );
    }
    if text.is_empty() || text.len() > 8 * 1024 * 1024 {
        return Err(invalid());
    }
    let bytes = read_font(&selection.path)?;
    let original = inspect_bytes(&bytes, selection.face_index, text)?;
    if original.sha256 != selection.sha256 || !original.embedding.outline_allowed {
        return Err(invalid());
    }
    let output = if bytes.starts_with(b"ttcf") {
        complete_face(&bytes, selection.face_index)?
    } else {
        bytes
    };
    let subset = inspect_bytes(&output, 0, text)?;
    if subset.glyph_count != original.glyph_count
        || subset.missing_count != original.missing_count
        || subset.license_text != original.license_text
        || subset.license_url != original.license_url
    {
        return Err(invalid());
    }
    Ok(PreparedSubset {
        original,
        subset,
        bytes: output,
    })
}
fn complete_face(bytes: &[u8], index: u32) -> Result<Vec<u8>, ApiError> {
    use write_fonts::{FontBuilder, read::FontRef};
    let font = FontRef::from_index(bytes, index).map_err(|_| invalid())?;
    let records = font.table_directory().table_records();
    if records.len() > 4095 {
        return Err(invalid());
    }
    let mut builder = FontBuilder::new();
    let mut seen = BTreeSet::new();
    let mut size = 12 + records.len() * 16;
    for record in records {
        let tag = record.tag();
        if !seen.insert(tag) {
            return Err(invalid());
        }
        // A signature over the original container cannot authenticate a new SFNT.
        if tag == write_fonts::types::Tag::new(b"DSIG") {
            continue;
        }
        let data = font.table_data(tag).ok_or_else(invalid)?.as_bytes();
        size = size.checked_add(data.len() + 3).ok_or_else(invalid)?;
        if size as u64 > MAX_FONT_BYTES {
            return Err(invalid());
        }
        builder.add_raw(tag, data);
    }
    Ok(builder.build())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn embedding_flags_respect_version_and_restrictions() {
        assert_eq!(policy(4, 0).permission, "installable");
        assert!(!policy(4, 2).outline_allowed);
        assert!(policy(4, 4).outline_allowed);
        assert!(policy(4, 8).subset_allowed);
        assert!(!policy(4, 0x108).subset_allowed);
        assert!(policy(4, 0x108).outline_allowed);
        assert!(!policy(4, 0x208).outline_allowed);
        assert_eq!(policy(4, 12).permission, "unknown");
        assert_eq!(policy(2, 12).permission, "editable");
        assert!(policy(1, 0x308).subset_allowed);
        assert_eq!(policy(4, 0x10).permission, "unknown");
        assert_eq!(policy(4, 1).permission, "unknown");
        assert_eq!(policy(6, 0).permission, "unknown");
    }
    #[test]
    fn malformed_font_does_not_become_an_allowed_font() {
        assert!(inspect_bytes(b"fake.ttf", 0, "中文").is_err());
        assert!(inspect_bytes(&[], 0, "abc").is_err());
    }
}
