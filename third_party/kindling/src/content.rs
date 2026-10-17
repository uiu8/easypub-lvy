//! Immutable bytes retained during EPUB extraction, owned by one build.
//!
//! Loose OPF inputs use an empty cache and retain ordinary filesystem semantics.
use std::borrow::Cow;
use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

#[derive(Clone, Debug, Default)]
pub struct ContentCache {
    files: Arc<HashMap<PathBuf, Vec<u8>>>,
}

impl ContentCache {
    pub(crate) fn from_files(files: impl IntoIterator<Item = (PathBuf, Vec<u8>)>) -> Self {
        Self {
            files: Arc::new(files.into_iter().map(|(p, b)| (path_key(&p), b)).collect()),
        }
    }

    pub fn read(&self, path: &Path) -> io::Result<Cow<'_, [u8]>> {
        if let Some(bytes) = self.files.get(&path_key(path)) {
            return Ok(Cow::Borrowed(bytes));
        }
        fs::read(path).map(Cow::Owned)
    }

    pub fn read_to_string(&self, path: &Path) -> io::Result<Cow<'_, str>> {
        if let Some(bytes) = self.files.get(&path_key(path)) {
            return std::str::from_utf8(bytes)
                .map(Cow::Borrowed)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e));
        }
        fs::read_to_string(path).map(Cow::Owned)
    }

    /// Extracted files are ordinary files at known absolute paths. Other paths
    /// still resolve through the filesystem, including symlinks in loose OPFs.
    pub fn canonicalize(&self, path: &Path) -> PathBuf {
        let key = path_key(path);
        if self.files.contains_key(&key) {
            canonical_key(key)
        } else {
            path.canonicalize().unwrap_or_else(|_| path.to_path_buf())
        }
    }
}

// Keep the same path form as fs::canonicalize. In particular, loose OPFs may
// depend on Windows verbatim paths for trailing-dot or trailing-space names.
fn canonical_key(key: PathBuf) -> PathBuf {
    #[cfg(windows)]
    {
        use std::os::windows::ffi::{OsStrExt, OsStringExt};
        if key.is_absolute() {
            let wide: Vec<u16> = key.as_os_str().encode_wide().collect();
            let (prefix, tail) = if wide.starts_with(&[92, 92]) {
                (r"\\?\UNC\", &wide[2..])
            } else {
                (r"\\?\", wide.as_slice())
            };
            let path: Vec<u16> = prefix.encode_utf16().chain(tail.iter().copied()).collect();
            return PathBuf::from(std::ffi::OsString::from_wide(&path));
        }
    }
    key
}

/// Match ordinary and verbatim Windows paths without filesystem queries.
pub(crate) fn path_key(path: &Path) -> PathBuf {
    #[cfg(windows)]
    let ordinary = {
        use std::os::windows::ffi::{OsStrExt, OsStringExt};
        let wide: Vec<u16> = path.as_os_str().encode_wide().collect();
        let prefix: Vec<u16> = "\\\\?\\".encode_utf16().collect();
        let unc: Vec<u16> = "\\\\?\\UNC\\".encode_utf16().collect();
        let wide = if wide.starts_with(&unc) {
            [vec![92, 92], wide[8..].to_vec()].concat()
        } else if wide.starts_with(&prefix) {
            wide[4..].to_vec()
        } else {
            wide
        };
        PathBuf::from(std::ffi::OsString::from_wide(&wide))
    };
    #[cfg(windows)]
    let path = ordinary.as_path();
    let mut key = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir
                if matches!(key.components().next_back(), Some(Component::Normal(_))) =>
            {
                key.pop();
            }
            Component::ParentDir if key.has_root() => {}
            _ => key.push(component.as_os_str()),
        }
    }
    key
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cached_bytes_preserve_utf8_errors_and_dot_aliases() {
        let root = std::env::temp_dir().join("kindling-content-unit");
        let cache = ContentCache::from_files([
            (root.join("chapter.xhtml"), "章节".as_bytes().to_vec()),
            (root.join("invalid.xhtml"), vec![0xff]),
        ]);
        assert_eq!(
            cache.read_to_string(&root.join("./chapter.xhtml")).unwrap(),
            "章节"
        );
        assert_eq!(
            cache.read(&root.join("invalid.xhtml")).unwrap().as_ref(),
            &[0xff]
        );
        assert_eq!(
            cache
                .read_to_string(&root.join("invalid.xhtml"))
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidData
        );
        assert!(cache.read(&root.join("missing.xhtml")).is_err());
    }

    #[test]
    #[cfg(windows)]
    fn windows_verbatim_disk_and_unc_aliases() {
        assert_eq!(
            path_key(Path::new(r"\\?\D:\book\a\..\./chapter.xhtml")),
            PathBuf::from(r"D:\book\chapter.xhtml")
        );
        assert_eq!(
            path_key(Path::new(r"\\?\UNC\server\share\book\chapter.xhtml")),
            PathBuf::from(r"\\server\share\book\chapter.xhtml")
        );
    }

    #[test]
    #[cfg(windows)]
    fn loose_opf_preserves_verbatim_file_names() {
        let root = std::env::temp_dir().join(format!("kindling_verbatim_{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let root = root.canonicalize().unwrap();
        let path = root.join("book.opf.");
        fs::write(&path, b"<package/>").unwrap();
        let opf = crate::opf::OPFData::parse(&path).unwrap();
        assert_eq!(opf.base_dir, root);
        fs::remove_dir_all(&root).unwrap();
    }
}
