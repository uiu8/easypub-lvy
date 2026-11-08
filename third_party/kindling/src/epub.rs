use crate::content::{ContentCache, path_key};
use quick_xml::Reader;
/// EPUB extraction support.
///
/// An EPUB is a ZIP archive containing an OPF file and HTML/CSS/image content.
/// This module extracts an EPUB to a temporary directory and locates the OPF
/// root file via META-INF/container.xml.
use quick_xml::events::Event;
use rayon::prelude::*;
use std::collections::HashSet;
use std::fs;
use std::io::{Cursor, Read};
use std::path::{Path, PathBuf};

/// Extract an EPUB file to a temporary directory and return the path to the OPF file.
///
/// The caller is responsible for cleaning up the temp directory after use.
pub fn extract_epub(epub_path: &Path) -> Result<(PathBuf, PathBuf), Box<dyn std::error::Error>> {
    let (dir, opf, _) = extract_epub_with_content(epub_path)?;
    Ok((dir, opf))
}

/// Extract once, retaining the exact file bytes for validation and conversion.
pub fn extract_epub_with_content(
    epub_path: &Path,
) -> Result<(PathBuf, PathBuf, ContentCache), Box<dyn std::error::Error>> {
    let epub_path = epub_path
        .canonicalize()
        .unwrap_or_else(|_| epub_path.to_path_buf());

    // Create temp directory next to the EPUB file
    let stem = epub_path
        .file_stem()
        .unwrap_or_default()
        .to_string_lossy()
        .to_string();
    let parent = epub_path.parent().unwrap_or(Path::new("."));
    let temp_dir = parent.join(format!(".kindling_epub_{}_{}", stem, std::process::id()));

    // Clean up any previous extraction
    if temp_dir.exists() {
        fs::remove_dir_all(&temp_dir)?;
    }
    fs::create_dir_all(&temp_dir)?;

    // Workers share the compressed bytes, but have independent ZIP cursors.
    // Create each parent only once: repeated create_dir_all calls are costly
    // for the thousands of files in chapter-per-file EPUBs on Windows.
    let zip_bytes = fs::read(&epub_path)?;
    let mut archive = zip::ZipArchive::new(Cursor::new(&zip_bytes))?;
    let mut files = Vec::new();
    let mut directories = HashSet::new();
    #[cfg(not(windows))]
    let mut destinations = HashSet::new();
    let mut has_aliases = false;
    #[cfg(windows)]
    let mut directory_spellings = HashSet::new();
    for i in 0..archive.len() {
        let entry = archive.by_index_raw(i)?;
        let name = entry
            .enclosed_name()
            .ok_or("EPUB entry escapes extraction directory")?;
        let out_path = temp_dir.join(name);
        #[cfg(windows)]
        {
            // Stream names still need filesystem handling. Ordinary Unicode
            // names are checked for actual ordinal case aliases below.
            has_aliases |= entry.name().contains(':');
            for dir in out_path.ancestors().skip(usize::from(!entry.is_dir())) {
                if dir == temp_dir {
                    break;
                }
                directory_spellings.insert(path_key(dir));
            }
        }
        if entry.is_dir() {
            if directories.insert(out_path.clone()) {
                fs::create_dir_all(&out_path)?;
            }
            continue;
        }
        if let Some(parent_dir) = out_path.parent() {
            if directories.insert(parent_dir.to_path_buf()) {
                fs::create_dir_all(parent_dir)?;
            }
        }
        #[cfg(not(windows))]
        {
            has_aliases |= !destinations.insert(path_key(&out_path));
        }
        files.push((i, out_path));
    }
    #[cfg(windows)]
    {
        has_aliases |= has_windows_path_aliases(&files, directory_spellings);
    }
    let extract_chunk = |chunk: &[(usize, PathBuf)]| -> Result<Vec<(PathBuf, Vec<u8>)>, String> {
        let mut archive = archive.clone();
        let mut contents = Vec::with_capacity(chunk.len());
        for (index, out_path) in chunk {
            let mut entry = archive.by_index(*index).map_err(|e| e.to_string())?;
            let mut bytes = Vec::with_capacity(entry.size() as usize);
            entry.read_to_end(&mut bytes).map_err(|e| e.to_string())?;
            fs::write(out_path, &bytes).map_err(|e| e.to_string())?;
            contents.push((out_path.clone(), bytes));
        }
        Ok(contents)
    };
    // Aliased names must retain archive-order overwrite behavior. They are
    // uncommon, so keep this case sequential and read it back from disk.
    let content = if has_aliases {
        extract_chunk(&files)?;
        ContentCache::default()
    } else {
        let chunk_size = files
            .len()
            .div_ceil(rayon::current_num_threads() * 4)
            .max(1);
        let chunks: Vec<_> = files.par_chunks(chunk_size).map(extract_chunk).collect();
        let contents = chunks.into_iter().collect::<Result<Vec<_>, _>>()?;
        ContentCache::from_files(contents.into_iter().flatten())
    };

    // Find the OPF path from META-INF/container.xml
    let container_path = temp_dir.join("META-INF").join("container.xml");
    let opf_relative = if container_path.exists() {
        parse_container_xml(&container_path, &content)?
    } else {
        // Fallback: look for any .opf file in the extracted directory
        find_opf_file(&temp_dir)?
    };

    let opf_path = temp_dir.join(&opf_relative);
    if !opf_path.exists() {
        return Err(format!(
            "OPF file not found at expected path: {}",
            opf_path.display()
        )
        .into());
    }

    eprintln!(
        "Extracted EPUB to {} (OPF: {})",
        temp_dir.display(),
        opf_relative
    );

    Ok((temp_dir, opf_path, content))
}

/// Compare names with Windows ordinal casing, not linguistic Unicode folding.
/// Sorting makes alias detection O(n log n); UTF-16 conversion happens once.
#[cfg(windows)]
fn has_windows_path_aliases(files: &[(usize, PathBuf)], directories: HashSet<PathBuf>) -> bool {
    use std::os::windows::ffi::OsStrExt;

    fn compare(a: &[u16], b: &[u16]) -> std::cmp::Ordering {
        #[link(name = "kernel32")]
        unsafe extern "system" {
            fn CompareStringOrdinal(
                string1: *const u16,
                count1: i32,
                string2: *const u16,
                count2: i32,
                ignore_case: i32,
            ) -> i32;
        }
        // SAFETY: both slices remain valid for their explicit UTF-16 lengths.
        // ZIP names and Windows paths fit in i32; TRUE must be exactly 1.
        let result = unsafe {
            CompareStringOrdinal(a.as_ptr(), a.len() as i32, b.as_ptr(), b.len() as i32, 1)
        };
        assert_ne!(
            result,
            0,
            "CompareStringOrdinal: {}",
            std::io::Error::last_os_error()
        );
        result.cmp(&2) // CSTR_LESS_THAN / EQUAL / GREATER_THAN = 1 / 2 / 3.
    }

    let mut paths: Vec<(Vec<u16>, bool)> = files
        .iter()
        .map(|(_, path)| (path_key(path).as_os_str().encode_wide().collect(), true))
        .chain(
            directories
                .into_iter()
                .map(|path| (path.as_os_str().encode_wide().collect(), false)),
        )
        .collect();
    paths.sort_unstable_by(|a, b| compare(&a.0, &b.0));
    paths.windows(2).any(|pair| {
        let (a, file_a) = &pair[0];
        let (b, file_b) = &pair[1];
        compare(a, b).is_eq() && (*file_a || *file_b || a != b)
    })
}

/// Parse META-INF/container.xml to find the rootfile (OPF) path.
fn parse_container_xml(
    path: &Path,
    cache: &ContentCache,
) -> Result<String, Box<dyn std::error::Error>> {
    let content = cache.read_to_string(path)?;
    let mut reader = Reader::from_str(&content);
    reader.config_mut().trim_text(true);
    let mut buf = Vec::new();

    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(ref e)) | Ok(Event::Empty(ref e)) => {
                let qname = e.name();
                let name = std::str::from_utf8(qname.as_ref()).unwrap_or("");
                if name == "rootfile" || name.ends_with(":rootfile") {
                    for attr in e.attributes().flatten() {
                        if attr.key.as_ref() == b"full-path" {
                            let path_str = String::from_utf8_lossy(&attr.value).to_string();
                            return Ok(path_str);
                        }
                    }
                }
            }
            Ok(Event::Eof) => break,
            Err(e) => return Err(format!("Error parsing container.xml: {}", e).into()),
            _ => {}
        }
        buf.clear();
    }

    Err("No rootfile found in container.xml".into())
}

/// Fallback: recursively find a .opf file in the extracted directory.
fn find_opf_file(dir: &Path) -> Result<String, Box<dyn std::error::Error>> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            if let Ok(result) = find_opf_file(&path) {
                // Return path relative to the original dir
                let relative = path.join(result);
                return Ok(relative
                    .strip_prefix(dir)
                    .unwrap_or(&relative)
                    .to_string_lossy()
                    .to_string());
            }
        } else if let Some(ext) = path.extension() {
            if ext == "opf" {
                return Ok(path
                    .strip_prefix(dir)
                    .unwrap_or(&path)
                    .to_string_lossy()
                    .to_string());
            }
        }
    }
    Err("No .opf file found in EPUB archive".into())
}

/// Create an EPUB (zip) from a directory of OPF/HTML/image files.
/// Returns the raw bytes of the EPUB zip.
pub fn create_epub_from_dir(dir: &Path) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    use std::io::Write;
    let buf = Vec::new();
    let cursor = std::io::Cursor::new(buf);
    let mut zip = zip::ZipWriter::new(cursor);
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);

    // Walk directory and add all files
    fn add_dir(
        zip: &mut zip::ZipWriter<std::io::Cursor<Vec<u8>>>,
        base: &Path,
        dir: &Path,
        options: zip::write::SimpleFileOptions,
    ) -> Result<(), Box<dyn std::error::Error>> {
        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let path = entry.path();
            let name = path.strip_prefix(base)?.to_string_lossy().to_string();
            if path.is_dir() {
                add_dir(zip, base, &path, options)?;
            } else {
                zip.start_file(&name, options)?;
                let data = fs::read(&path)?;
                zip.write_all(&data)?;
            }
        }
        Ok(())
    }

    add_dir(&mut zip, dir, dir, options)?;
    let cursor = zip.finish()?;
    Ok(cursor.into_inner())
}

/// Clean up the temporary extraction directory.
fn remove_files_in_parallel(dir: &Path) {
    use rayon::prelude::*;
    let mut files = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = fs::read_dir(&d) else {
            continue;
        };
        for entry in entries.flatten() {
            match entry.file_type() {
                Ok(t) if t.is_dir() => stack.push(entry.path()),
                Ok(t) if t.is_file() => files.push(entry.path()),
                _ => {}
            }
        }
    }
    files.par_iter().for_each(|f| {
        let _ = fs::remove_file(f);
    });
}

pub fn cleanup_temp_dir(temp_dir: &Path) {
    if temp_dir.exists() {
        // Delete the files of each directory on the worker pool first; the
        // directory tree itself is then removed in one call (EasyPub patch).
        remove_files_in_parallel(temp_dir);
        if let Err(e) = fs::remove_dir_all(temp_dir) {
            eprintln!(
                "Warning: failed to clean up temp dir {}: {}",
                temp_dir.display(),
                e
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    #[cfg(windows)]
    fn directory_case_aliases_resolve_to_the_actual_disk_path() {
        let root =
            std::env::temp_dir().join(format!("kindling_directory_alias_{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        for (first_dir, opf_dir) in [("OEBPS", "oebps"), ("章节Ä", "章节ä")] {
            let path = root.join("aliases.epub");
            let mut zip = zip::ZipWriter::new(fs::File::create(&path).unwrap());
            let options = zip::write::SimpleFileOptions::default();
            zip.add_directory(format!("{first_dir}/"), options).unwrap();
            for (name, bytes) in [
                (
                    "META-INF/container.xml".to_string(),
                    format!("<container><rootfile full-path=\"{opf_dir}/book.opf\"/></container>"),
                ),
                (format!("{opf_dir}/book.opf"), "<package/>".to_string()),
            ] {
                zip.start_file(name, options).unwrap();
                zip.write_all(bytes.as_bytes()).unwrap();
            }
            zip.finish().unwrap();
            let (dir, opf, content) = extract_epub_with_content(&path).unwrap();
            assert_eq!(content.canonicalize(&opf), opf.canonicalize().unwrap());
            cleanup_temp_dir(&dir);
            assert!(content.read(&opf).is_err());
        }
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn extraction_cache_matches_disk_and_preserves_alias_overwrites() {
        let root = std::env::temp_dir().join(format!(
            "kindling_中文路径_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        for (first, second, aliased) in [
            ("chapter.xhtml", None, false),
            ("第一章.xhtml", None, false),
            ("résumé🙂.xhtml", None, false),
            ("é.xhtml", Some("e\u{301}.xhtml"), false),
            ("chapter.xhtml", Some("./chapter.xhtml"), true),
            #[cfg(windows)]
            ("章节Ä.xhtml", Some("章节ä.xhtml"), true),
            #[cfg(windows)]
            ("Σ.xhtml", Some("σ.xhtml"), true),
        ] {
            let path = root.join("中文书名.epub");
            let mut zip = zip::ZipWriter::new(fs::File::create(&path).unwrap());
            let mut files = vec![
                (
                    "META-INF/container.xml".to_string(),
                    "<container><rootfile full-path=\"正文/书籍.opf\"/></container>",
                ),
                ("正文/书籍.opf".to_string(), "<package/>"),
                (format!("正文/{first}"), "original chapter"),
            ];
            if let Some(second) = second {
                files.push((format!("正文/{second}"), "last chapter"));
            }
            for (name, content) in files {
                zip.start_file(name, zip::write::SimpleFileOptions::default())
                    .unwrap();
                zip.write_all(content.as_bytes()).unwrap();
            }
            zip.finish().unwrap();
            let (dir, opf, content) = extract_epub_with_content(&path).unwrap();
            let chapter = opf.parent().unwrap().join(first);
            let disk = fs::read(&chapter).unwrap();
            assert_eq!(content.read(&chapter).unwrap().as_ref(), disk);
            assert_eq!(
                disk,
                if aliased {
                    b"last chapter".as_slice()
                } else {
                    b"original chapter".as_slice()
                }
            );
            cleanup_temp_dir(&dir);
            if !aliased {
                assert_eq!(content.read(&chapter).unwrap().as_ref(), disk);
                if let Some(second) = second {
                    assert_eq!(
                        content
                            .read_to_string(&opf.parent().unwrap().join(second))
                            .unwrap(),
                        "last chapter"
                    );
                }
            } else {
                assert!(content.read(&chapter).is_err());
            }
        }
        fs::remove_dir_all(root).unwrap();
    }
}
