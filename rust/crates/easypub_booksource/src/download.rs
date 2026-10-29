//! 有界下载、失败补抓与离线合成。缓存逐章提交，取消不覆盖已有 TXT。
use crate::{
    chapter_cleanup::{self, Quality},
    engine::SourceRt,
    webbook::{Book, Chapter},
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    io::{BufWriter, Write},
    path::{Path, PathBuf},
    sync::{Arc, atomic::AtomicBool},
};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Options {
    pub folder: PathBuf,
    pub threads: usize,
    pub from: Option<usize>,
    pub to: Option<usize>,
    pub retries: u32,
    pub include_volumes: bool,
    pub file_name: String,
    pub remove_page_prompts: bool,
    pub multi_source: bool,
    pub max_alternates: usize,
    /// 换源补章时同时尝试的书源数（1–4）。
    pub alternate_concurrency: usize,
    pub retry_failed: Vec<usize>,
    pub preserve_existing: bool,
}
impl Default for Options {
    fn default() -> Self {
        Self {
            folder: PathBuf::new(),
            threads: 8,
            from: None,
            to: None,
            retries: 3,
            include_volumes: true,
            file_name: "{name} - {author}".into(),
            remove_page_prompts: true,
            multi_source: true,
            max_alternates: 2,
            alternate_concurrency: 2,
            retry_failed: Vec::new(),
            preserve_existing: false,
        }
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Progress {
    pub total: usize,
    pub done: usize,
    pub failed: usize,
    pub current: String,
    pub speed: f64,
    pub eta: Option<u64>,
    pub concurrency: usize,
    pub retrying: usize,
    pub throttled: bool,
    pub chapter_ms: u64,
    pub hosts: Vec<crate::hosts::Diagnostic>,
    pub timing: crate::control::Timing,
    pub chapter: Option<crate::scheduler::ChapterTask>,
    pub invalidated: Vec<usize>,
    pub source_count: usize,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Failure {
    pub index: usize,
    pub title: String,
    pub reason: String,
    #[serde(default)]
    pub cause: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Outcome {
    pub path: PathBuf,
    pub chapters: usize,
    pub downloaded: usize,
    pub from_cache: usize,
    pub failures: Vec<Failure>,
    pub cancelled: bool,
    #[serde(default)]
    pub output_preserved: bool,
    #[serde(default)]
    pub quality: Quality,
}

fn safe_name(text: &str) -> String {
    let s: String = text
        .chars()
        .map(|c| {
            if matches!(c, '\\' | '/' | ':' | '*' | '?' | '"' | '<' | '>' | '|') || c.is_control() {
                '_'
            } else {
                c
            }
        })
        .collect();
    let s = s.trim().trim_end_matches('.');
    if s.is_empty() {
        "未命名".into()
    } else {
        s.chars().take(120).collect()
    }
}
pub fn file_name(book: &Book, template: &str) -> String {
    let name = template
        .replace("{name}", &book.name)
        .replace("{author}", &book.author);
    format!(
        "{}.txt",
        safe_name(name.trim().trim_end_matches(['-', ' ']))
    )
}
/// 章节缓存的根目录（V107）。插件启动时设为数据目录下的 `chapter-cache` 或用户选的位置；
/// 没设（单独调用下载、测试）时沿用旧位置：下载文件夹里的 `.easypub-cache`。
static CACHE_ROOT: std::sync::Mutex<Option<PathBuf>> = std::sync::Mutex::new(None);
/// 旧缓存搬家时串行，免得两个线程同时搬同一本。
static CACHE_MOVE: std::sync::Mutex<()> = std::sync::Mutex::new(());

pub fn set_cache_root(root: Option<PathBuf>) {
    *CACHE_ROOT.lock().unwrap() = root;
}
pub fn cache_root(folder: &Path) -> PathBuf {
    CACHE_ROOT
        .lock()
        .unwrap()
        .clone()
        .unwrap_or_else(|| folder.join(".easypub-cache"))
}
fn cache_key(book: &Book) -> String {
    hex::encode(Sha256::digest(format!(
        "{}\n{}",
        book.origin, book.book_url
    )))
}
/// 缓存文件夹名：`书名 - 作者 [编号前 8 位]`；同一本书从两个书源下载时靠编号区分。
pub fn cache_name(book: &Book) -> String {
    let label = if book.author.trim().is_empty() {
        book.name.clone()
    } else {
        format!("{} - {}", book.name.trim(), book.author.trim())
    };
    let label: String = safe_name(&label).chars().take(60).collect();
    format!("{} [{}]", label.trim(), &cache_key(book)[..8])
}
/// 某本书的章节缓存。按 `书名 - 作者 [编号]` 找；书名改过时按编号找；
/// 还在旧位置（下载文件夹里的 `.easypub-cache/编号16位`）的，第一次用到时搬过来。
pub fn cache_dir(folder: &Path, book: &Book) -> PathBuf {
    let root = cache_root(folder);
    let named = root.join(cache_name(book));
    if named.is_dir() {
        return named;
    }
    let _guard = CACHE_MOVE.lock().unwrap();
    if named.is_dir() {
        return named;
    }
    let key = cache_key(book);
    let suffix = format!(" [{}]", &key[..8]);
    if let Ok(entries) = std::fs::read_dir(&root) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir()
                && entry
                    .file_name()
                    .to_str()
                    .is_some_and(|n| n.ends_with(&suffix))
            {
                return path;
            }
        }
    }
    let legacy_root = folder.join(".easypub-cache");
    for old in [root.join(&key[..16]), legacy_root.join(&key[..16])] {
        if old.is_dir() && old != named {
            if move_dir(&old, &named).is_err() {
                return old;
            }
            // 旧位置搬空了就把外层文件夹也去掉。
            let _ = std::fs::remove_dir(&legacy_root);
            return named;
        }
    }
    named
}
/// 换缓存位置：把 `from` 里每本书的缓存搬到 `to`，返回（搬了几本、没搬动的文件夹名）。
/// 没搬动的留在原处，不影响其他书。
pub fn relocate_cache(from: &Path, to: &Path) -> Result<(usize, Vec<String>), String> {
    if to.starts_with(from) && to != from {
        return Err("新位置不能放在当前缓存文件夹里面".into());
    }
    std::fs::create_dir_all(to).map_err(|_| "无法创建新的缓存文件夹，请检查权限")?;
    let _guard = CACHE_MOVE.lock().unwrap();
    let (mut moved, mut kept) = (0, Vec::new());
    if let Ok(entries) = std::fs::read_dir(from) {
        for entry in entries.flatten() {
            if !entry.path().is_dir() {
                continue;
            }
            let name = entry.file_name();
            match move_dir(&entry.path(), &to.join(&name)) {
                Ok(()) => moved += 1,
                Err(_) => kept.push(name.to_string_lossy().into_owned()),
            }
        }
    }
    // 旧位置搬空了就去掉（只删空文件夹）。
    let _ = std::fs::remove_dir(from);
    Ok((moved, kept))
}
/// 搬一个缓存文件夹：同盘直接改名；跨盘先完整复制、核对文件数，再删旧的。
pub fn move_dir(from: &Path, to: &Path) -> Result<(), String> {
    if let Some(parent) = to.parent() {
        std::fs::create_dir_all(parent).map_err(|_| "无法创建缓存目录")?;
    }
    if to.exists() {
        return Err("目标位置已有同名缓存".into());
    }
    if std::fs::rename(from, to).is_ok() {
        return Ok(());
    }
    fn copy(from: &Path, to: &Path) -> std::io::Result<usize> {
        std::fs::create_dir_all(to)?;
        let mut count = 0;
        for entry in std::fs::read_dir(from)? {
            let entry = entry?;
            let target = to.join(entry.file_name());
            if entry.file_type()?.is_dir() {
                count += copy(&entry.path(), &target)?;
            } else {
                std::fs::copy(entry.path(), target)?;
                count += 1;
            }
        }
        Ok(count)
    }
    fn count(dir: &Path) -> std::io::Result<usize> {
        let mut n = 0;
        for entry in std::fs::read_dir(dir)? {
            let entry = entry?;
            n += if entry.file_type()?.is_dir() {
                count(&entry.path())?
            } else {
                1
            };
        }
        Ok(n)
    }
    let copied = copy(from, to);
    match copied {
        Ok(n) if count(from).ok() == Some(n) => {
            std::fs::remove_dir_all(from).map_err(|_| "旧缓存已复制，但删除旧位置失败".into())
        }
        _ => {
            let _ = std::fs::remove_dir_all(to);
            Err("搬移缓存失败，原缓存保留".into())
        }
    }
}
pub fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    write_atomic_with(path, |file| file.write_all(bytes))
}

fn write_atomic_with(
    path: &Path,
    write: impl FnOnce(&mut std::fs::File) -> std::io::Result<()>,
) -> Result<(), String> {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|_| "无法创建保存目录")?;
    }
    let (tmp, mut file) = loop {
        let tmp = path.with_file_name(format!(
            ".easypub-write-{}-{}.tmp",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)
        {
            Ok(file) => break (tmp, file),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(_) => return Err("无法创建临时文件，请检查磁盘空间和目录权限后重试".into()),
        }
    };
    let result = (|| {
        write(&mut file)?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&tmp, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result.map_err(|_| "无法保存文件，请检查磁盘空间、目录权限或文件占用后重试".into())
}

pub(crate) fn wanted(toc: &[Chapter], options: &Options) -> Vec<usize> {
    (options.from.unwrap_or(1).max(1).saturating_sub(1)
        ..options.to.unwrap_or(toc.len()).min(toc.len()))
        .collect()
}

/// 保留索引缓存接口，目录迁移由共享章节身份规则处理。
pub(crate) fn prepare_cache(cache: &Path, toc: &[Chapter]) -> Result<(), String> {
    crate::catalogue::prepare(cache, toc)
}

pub fn download(
    rt: Arc<SourceRt>,
    book: &Book,
    toc: &[Chapter],
    options: &Options,
    cancel: Arc<AtomicBool>,
    on_progress: Arc<dyn Fn(Progress) + Send + Sync>,
) -> Result<Outcome, String> {
    download_multi(rt, book, toc, options, cancel, on_progress, Vec::new())
}
pub fn download_multi(
    rt: Arc<SourceRt>,
    book: &Book,
    toc: &[Chapter],
    options: &Options,
    cancel: Arc<AtomicBool>,
    on_progress: Arc<dyn Fn(Progress) + Send + Sync>,
    alternates: Vec<crate::scheduler::Lane>,
) -> Result<Outcome, String> {
    let mut lanes = vec![crate::scheduler::Lane {
        rt,
        book: book.clone(),
        toc: toc.to_vec(),
        mapping: (0..toc.len()).map(Some).collect(),
    }];
    if options.multi_source && toc.iter().filter(|c| !c.is_volume).count() >= 50 {
        lanes.extend(alternates.into_iter().take(options.max_alternates.min(4)));
    }
    crate::scheduler::run(lanes, book, toc, options, cancel, on_progress)
}

/// 共用合成路径：不请求网络；rebuild 成功写好临时文件后才备份、替换。
pub fn assemble(
    book: &Book,
    toc: &[Chapter],
    options: &Options,
    path: &Path,
    backup: Option<&Path>,
) -> Result<Quality, String> {
    let cache = cache_dir(&options.folder, book);
    if crate::catalogue::pending(&cache) {
        return Err("目录缓存正在迁移，请先继续下载；原 TXT 保留".into());
    }
    if let Ok(bytes) = std::fs::read(cache.join("toc.json"))
        && let Ok(cached_toc) = serde_json::from_slice::<Vec<Chapter>>(&bytes)
        && (cached_toc.len() != toc.len()
            || crate::catalogue::compare(&cached_toc, toc)
                .reuse
                .iter()
                .enumerate()
                .any(|(i, old)| *old != Some(i)))
    {
        return Err("缓存目录已变化，请先完成追更再整理；原 TXT 保留".into());
    }
    let mut quality = chapter_cleanup::toc_quality(toc);
    std::fs::create_dir_all(&options.folder).map_err(|_| "无法创建下载文件夹")?;
    let temp = path.with_extension("txt.part");
    let file = std::fs::File::create(&temp).map_err(|_| "无法写入临时 TXT")?;
    let mut out = BufWriter::with_capacity(128 * 1024, file);
    writeln!(out, "{}", book.name).map_err(|_| "无法写入临时 TXT")?;
    if !book.author.is_empty() {
        writeln!(out, "作者：{}", book.author).map_err(|_| "无法写入临时 TXT")?;
    }
    if !book.intro.is_empty() {
        writeln!(out, "\n简介：\n{}", book.intro).map_err(|_| "无法写入临时 TXT")?;
    }
    for i in wanted(toc, options) {
        let chapter = &toc[i];
        if chapter.is_volume {
            if options.include_volumes {
                writeln!(out, "\n\n{}", chapter.title).map_err(|_| "无法写入临时 TXT")?;
            }
            continue;
        }
        writeln!(out, "\n\n{}\n", chapter.title).map_err(|_| "无法写入临时 TXT")?;
        match std::fs::read_to_string(cache.join(format!("{i:05}.txt"))) {
            Ok(body) => {
                let (body, removed) = chapter_cleanup::clean_cached(
                    &body,
                    &chapter.title,
                    options.remove_page_prompts,
                );
                quality.removed_duplicate_headings += removed;
                for line in body.lines() {
                    writeln!(out, "　　{}", line.trim()).map_err(|_| "无法写入临时 TXT")?;
                }
            }
            Err(_) if backup.is_some() => {
                return Err(format!("第 {} 章缓存缺失，未替换原文件", i + 1));
            }
            Err(_) => writeln!(out, "（本章未下载）").map_err(|_| "无法写入临时 TXT")?,
        }
    }
    out.flush().map_err(|_| "无法写入临时 TXT")?;
    drop(out);
    if let Some(bak) = backup.filter(|_| path.is_file()) {
        std::fs::copy(path, bak).map_err(|_| "备份失败，未替换原文件")?;
    }
    std::fs::rename(temp, path).map_err(|_| "无法替换 TXT（原文件及备份保留）")?;
    Ok(quality)
}

/// V87 没有存目录。只恢复旧合成器明确写出的无缩进标题，不从正文猜章号。
pub fn legacy_toc(path: &Path, expected: usize) -> Result<Vec<Chapter>, String> {
    let text = std::fs::read_to_string(path).map_err(|_| "原 TXT 无法读取，不能恢复旧目录")?;
    let lines: Vec<_> = text.lines().collect();
    let mut toc = Vec::new();
    for i in 1..lines.len().saturating_sub(1) {
        let line = lines[i];
        if lines[i - 1].is_empty()
            && lines[i + 1].is_empty()
            && !line.is_empty()
            && line.chars().next().is_some_and(|c| !c.is_whitespace())
        {
            toc.push(Chapter {
                index: toc.len(),
                title: line.to_owned(),
                ..Default::default()
            });
        }
    }
    if toc.len() != expected {
        return Err("旧 TXT 的标题与下载记录无法一一对应；请重新下载目录后再整理".into());
    }
    Ok(toc)
}

#[cfg(test)]
mod atomic_tests {
    use super::*;
    #[cfg(windows)]
    #[test]
    fn windows_long_unicode_paths_readonly_and_exclusive_lock_preserve_data() {
        use std::os::windows::fs::OpenOptionsExt;
        let root = std::env::temp_dir().join(format!("easypub-boundary-{}", std::process::id()));
        let mut directory = root.clone();
        for _ in 0..8 {
            directory = directory.join("中文 空格 #[] & 长路径验证123456789");
        }
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("书源 💡.json");
        assert!(path.as_os_str().len() > 260);
        write_atomic(&path, b"old-complete").unwrap();
        let lock = std::fs::OpenOptions::new()
            .read(true)
            .share_mode(0)
            .open(&path)
            .unwrap();
        let error = write_atomic(&path, b"new-complete").unwrap_err();
        assert!(error.contains("占用") && error.contains("重试"));
        drop(lock);
        assert_eq!(std::fs::read(&path).unwrap(), b"old-complete");
        let original = std::fs::metadata(&path).unwrap().permissions();
        let mut readonly = original.clone();
        readonly.set_readonly(true);
        std::fs::set_permissions(&path, readonly).unwrap();
        let rejected = write_atomic(&path, b"new-complete");
        std::fs::set_permissions(&path, original).unwrap();
        assert!(rejected.is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"old-complete");
        write_atomic(&path, b"new-complete").unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"new-complete");
        // 文件只读属性不同于目录 ACL；另在本测试新建的短路径目录拒绝建文件。
        let acl_path = root.join("acl.json");
        write_atomic(&acl_path, b"old-acl").unwrap();
        let identity = std::process::Command::new("whoami").output().unwrap();
        assert!(identity.status.success());
        let identity = String::from_utf8(identity.stdout).unwrap();
        let identity = identity.trim();
        let denied = std::process::Command::new("icacls")
            .arg(&root)
            .args(["/deny", &format!("{identity}:(WD)")])
            .output()
            .unwrap();
        assert!(denied.status.success());
        let rejected = write_atomic(&acl_path, b"new-acl");
        let restored = std::process::Command::new("icacls")
            .arg(&root)
            .args(["/remove:d", identity])
            .output()
            .unwrap();
        assert!(restored.status.success(), "必须恢复本测试目录 ACL");
        assert!(rejected.is_err(), "目录拒绝新建临时文件时必须失败");
        assert_eq!(std::fs::read(&acl_path).unwrap(), b"old-acl");
        write_atomic(&acl_path, b"new-acl").unwrap();
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn interrupted_writer_and_disk_full_preserve_previous_data() {
        const ENV: &str = "EASYPUB_ATOMIC_CRASH_TEST";
        if let Some(path) = std::env::var_os(ENV) {
            let _ = write_atomic_with(Path::new(&path), |file| {
                file.write_all(b"partial")?;
                file.sync_all()?;
                std::process::exit(73);
            });
            panic!("未到达写入中断点");
        }
        let root =
            std::env::temp_dir().join(format!("easypub-atomic-crash-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join("sources.json");
        write_atomic(&path, b"old-complete").unwrap();
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "download::atomic_tests::interrupted_writer_and_disk_full_preserve_previous_data",
            ])
            .env(ENV, &path)
            .status()
            .unwrap();
        assert_eq!(status.code(), Some(73));
        assert_eq!(std::fs::read(&path).unwrap(), b"old-complete");
        let failure = write_atomic_with(&path, |file| {
            file.write_all(b"partial")?;
            Err(std::io::Error::from(std::io::ErrorKind::StorageFull))
        })
        .unwrap_err();
        assert!(failure.contains("磁盘空间") && failure.contains("重试"));
        assert_eq!(std::fs::read(&path).unwrap(), b"old-complete");
        write_atomic(&path, b"new-complete").unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"new-complete");
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn concurrent_same_stem_and_failed_replace_preserve_complete_files() {
        let root = std::env::temp_dir().join(format!(
            "easypub-atomic-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        std::thread::scope(|scope| {
            for extension in ["json", "txt"] {
                let path = root.join(format!("same.{extension}"));
                scope.spawn(move || {
                    for _ in 0..40 {
                        write_atomic(&path, extension.repeat(4096).as_bytes()).unwrap();
                    }
                });
            }
        });
        for extension in ["json", "txt"] {
            assert_eq!(
                std::fs::read(root.join(format!("same.{extension}"))).unwrap(),
                extension.repeat(4096).as_bytes()
            );
        }
        let blocked = root.join("blocked");
        std::fs::create_dir(&blocked).unwrap();
        std::fs::write(blocked.join("keep"), b"old").unwrap();
        assert!(write_atomic(&blocked, b"new").is_err());
        assert_eq!(std::fs::read(blocked.join("keep")).unwrap(), b"old");
        assert!(
            !std::fs::read_dir(&root).unwrap().any(|e| e
                .unwrap()
                .file_name()
                .to_string_lossy()
                .ends_with(".tmp"))
        );
        std::fs::remove_dir_all(root).unwrap();
    }
}
