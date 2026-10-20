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
pub fn cache_dir(folder: &Path, book: &Book) -> PathBuf {
    let key = hex::encode(Sha256::digest(format!(
        "{}\n{}",
        book.origin, book.book_url
    )));
    folder.join(".easypub-cache").join(&key[..16])
}
pub fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|_| "无法创建保存目录")?;
    }
    let tmp = path.with_extension("part");
    std::fs::write(&tmp, bytes)
        .and_then(|_| std::fs::rename(&tmp, path))
        .map_err(|_| "无法写入文件（检查目录权限或是否被占用）".into())
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
