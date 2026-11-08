// EPUB content profile used to scope per-rule applicability.

use std::path::Path;

use crate::opf::OPFData;

/// Which KDP rule set applies to a given EPUB.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Profile {
    Default,
    Comic,
    Dict,
    #[allow(dead_code)]
    Textbook,
}

/// Bitmask value for `Rule::profile_mask` that selects every profile.
pub const ALL_PROFILES: u8 = 0b1111;

impl Profile {
    /// Bit value for this profile: `1 << variant_index`.
    pub const fn as_bit(&self) -> u8 {
        match self {
            Profile::Default => 1 << 0,
            Profile::Comic => 1 << 1,
            Profile::Dict => 1 << 2,
            Profile::Textbook => 1 << 3,
        }
    }

    /// Detect the profile from parsed OPF data plus the extracted content root.
    pub fn autodetect(opf: &OPFData, root: &Path) -> Profile {
        if !opf.dict_in_language.is_empty() {
            return Profile::Dict;
        }

        // Read each spine item once, borrowing the bytes retained during EPUB
        // extraction. A fixed-layout book must still be scanned for idx:entry:
        // dictionary detection takes precedence over comic detection.
        use rayon::prelude::*;
        let has_viewport = opf
            .spine_items
            .par_iter()
            .map(|(_, href)| {
                let Ok(content) = opf.content.read_to_string(&root.join(href)) else {
                    return Ok(false);
                };
                if content.contains("idx:entry") {
                    return Err(());
                }
                Ok(!opf.is_fixed_layout && has_viewport_meta(&content))
            })
            .try_reduce(|| false, |a, b| Ok(a || b));
        let Ok(has_viewport) = has_viewport else {
            return Profile::Dict;
        };
        if opf.is_fixed_layout || has_viewport {
            return Profile::Comic;
        }
        Profile::Default
    }
}

/// True if `content` has a `<meta name="viewport">` with both width and height.
fn has_viewport_meta(content: &str) -> bool {
    let lower = content.to_ascii_lowercase();
    let mut rest = lower.as_str();
    while let Some(idx) = rest.find("<meta") {
        rest = &rest[idx + 5..];
        let Some(end) = rest.find('>') else { break };
        let tag = &rest[..end];
        if tag.contains("name=\"viewport\"") && tag.contains("width=") && tag.contains("height=") {
            return true;
        }
        rest = &rest[end..];
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::content::ContentCache;

    #[test]
    fn cached_and_disk_profiles_preserve_dictionary_priority() {
        let root = std::env::temp_dir().join(format!(
            "kindling_profile_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let opf_path = root.join("book.opf");
        std::fs::write(&opf_path, b"<package/>").unwrap();
        let mut opf = OPFData::parse(&opf_path).unwrap();
        opf.spine_items = vec![
            ("first".into(), "first.xhtml".into()),
            ("second".into(), "second.xhtml".into()),
        ];
        let plain = b"<html>chapter</html>".as_slice();
        let viewport = b"<META name=\"viewport\" content=\"width=600,height=800\"/>".as_slice();
        let dictionary = b"<html><idx:entry>term</idx:entry></html>".as_slice();
        for (first, second, fixed, metadata, expected) in [
            (plain, plain, false, "", Profile::Default),
            (viewport, plain, false, "", Profile::Comic),
            (viewport, dictionary, false, "", Profile::Dict),
            (plain, dictionary, true, "", Profile::Dict),
            (plain, plain, true, "", Profile::Comic),
            (plain, plain, false, "en", Profile::Dict),
            (
                viewport,
                b"\xffidx:entry".as_slice(),
                false,
                "",
                Profile::Comic,
            ),
        ] {
            let files = [
                (root.join("first.xhtml"), first.to_vec()),
                (root.join("second.xhtml"), second.to_vec()),
            ];
            for (path, bytes) in &files {
                std::fs::write(path, bytes).unwrap();
            }
            opf.content = ContentCache::default();
            opf.is_fixed_layout = fixed;
            opf.dict_in_language = metadata.to_string();
            assert_eq!(Profile::autodetect(&opf, &root), expected);

            opf.content = ContentCache::from_files(files.clone());
            for (path, _) in files {
                std::fs::remove_file(path).unwrap();
            }
            // The retained snapshot must produce the same profile even when
            // the extracted files are no longer available on disk.
            assert_eq!(Profile::autodetect(&opf, &root), expected);
        }
        std::fs::remove_dir_all(root).unwrap();
    }
}
