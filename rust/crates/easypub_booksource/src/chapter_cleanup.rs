//! 下载阶段的分页整理：只比较完整标题，不用包含匹配删正文。
use crate::{text, webbook::Chapter};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, sync::LazyLock};

static PAGE_SUFFIX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?:[（(]\s*\d+\s*[/／]\s*\d+\s*[）)]|\s*第\s*\d+\s*页|[-_]\s*\d+)\s*$").unwrap()
});

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Quality {
    /// 整理后仍有的同名章节（不同地址、不相邻时仅报告）。
    pub duplicate_headings: usize,
    pub merged_toc_items: usize,
    pub dropped_latest_block: usize,
    pub removed_duplicate_headings: usize,
}

pub fn title_key(title: &str) -> String {
    PAGE_SUFFIX
        .replace(&text::to_num_chapter(title.trim()), "")
        .chars()
        .filter(|c| !c.is_whitespace())
        .collect()
}

fn meaningful(title: &str) -> bool {
    let key = title_key(title);
    !key.is_empty() && !key.chars().all(|c| c.is_numeric())
}

pub fn same_title(line: &str, title: &str) -> bool {
    meaningful(title) && title_key(line) == title_key(title)
}

fn prompt(line: &str) -> bool {
    // 只匹配独立的固定提示，不模糊匹配小说里的对话或叙述。
    let l = line
        .trim()
        .trim_matches(['（', '）', '(', ')', '。', '！', '!', '…', '.']);
    matches!(
        l,
        "本章未完，点击下一页继续阅读"
            | "本章未完，请点击下一页继续阅读"
            | "本章未完，点击下一页"
            | "本章未完，请点击下一页"
            | "请收藏本站"
            | "请记住本站网址"
    )
}

pub fn clean_page(body: &str, title: &str, remove_prompts: bool) -> String {
    let lines: Vec<_> = body
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect();
    lines
        .iter()
        .enumerate()
        .filter_map(|(i, line)| {
            if (i < 3 && same_title(line, title))
                || (remove_prompts && (i < 2 || i + 2 >= lines.len()) && prompt(line))
            {
                None
            } else {
                Some(*line)
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn unfinished(text: &str) -> bool {
    text.trim_end()
        .chars()
        .last()
        .is_some_and(|c| !"。！？!?…\"”’』」）)；;：:".contains(c))
}

pub fn append_page(out: &mut String, page: &str) {
    let page = page.trim();
    if page.is_empty() {
        return;
    }
    if !out.is_empty() && !unfinished(out) {
        out.push('\n');
    }
    out.push_str(page);
}

/// 老缓存没有页边界；重复标题所在行就是可确认的分页边界。
pub fn clean_cached(body: &str, title: &str, remove_prompts: bool) -> (String, usize) {
    let lines: Vec<_> = body
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect();
    let mut out = String::new();
    let mut boundary = false;
    let mut removed = 0;
    let title = title_key(title);
    let valid_title = !title.is_empty() && !title.chars().all(|c| c.is_numeric());
    let headings: Vec<_> = lines
        .iter()
        .map(|line| valid_title && title_key(line) == title)
        .collect();
    for (i, line) in lines.iter().enumerate() {
        if headings[i] {
            removed += 1;
            boundary = true;
            continue;
        }
        let near_page = i < 2
            || i + 2 >= lines.len()
            || headings[i.saturating_sub(2)..(i + 3).min(lines.len())].contains(&true);
        if remove_prompts && near_page && prompt(line) {
            continue;
        }
        if !out.is_empty() && (!boundary || !unfinished(&out)) {
            out.push('\n');
        }
        out.push_str(line);
        boundary = false;
    }
    (out, removed)
}

fn chapter_number(title: &str) -> Option<u64> {
    static NUMBER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^第(\d+)[章节回]").unwrap());
    NUMBER
        .captures(&title_key(title))
        .and_then(|c| c[1].parse().ok())
}

pub fn normalize_toc(mut chapters: Vec<Chapter>) -> Vec<Chapter> {
    // 先找完整的最新章节块，再去重地址，否则先去重会把正文目录里的条目删掉。
    let mut dropped = 0;
    for n in (1..=30.min(chapters.len() / 2)).rev() {
        let prefix = &chapters[..n];
        let repeated = (n..=chapters.len() - n).any(|at| {
            prefix.iter().zip(&chapters[at..at+n]).all(|(a,b)|
                !a.is_volume && !b.is_volume && title_key(&a.title) == title_key(&b.title))
                && chapter_number(&chapters[at].title).is_some_and(|first|
                    chapter_number(&chapters[at-1].title).is_some_and(|prev| prev < first))
                && chapters[at..at+n].windows(2).all(|w|
                    matches!((chapter_number(&w[0].title), chapter_number(&w[1].title)), (Some(a), Some(b)) if b > a))
        });
        if repeated {
            dropped = n;
            chapters.drain(..n);
            break;
        }
    }
    let mut seen = std::collections::HashSet::new();
    chapters.retain(|c| seen.insert((c.url.clone(), c.title.clone())));
    let mut out: Vec<Chapter> = Vec::new();
    for chapter in chapters {
        if let Some(last) = out.last_mut()
            && !last.is_volume
            && !chapter.is_volume
            && title_key(&last.title) == title_key(&chapter.title)
            && (PAGE_SUFFIX.is_match(&last.title) || PAGE_SUFFIX.is_match(&chapter.title))
            && last.url != chapter.url
        {
            if !last.extra_urls.contains(&chapter.url) {
                last.extra_urls.push(chapter.url);
            }
            for url in chapter.extra_urls {
                if url != last.url && !last.extra_urls.contains(&url) {
                    last.extra_urls.push(url);
                }
            }
            last.is_pay |= chapter.is_pay;
            last.is_vip |= chapter.is_vip;
        } else {
            out.push(chapter);
        }
    }
    for (i, c) in out.iter_mut().enumerate() {
        c.index = i;
        if !c.extra_urls.is_empty() {
            c.title = PAGE_SUFFIX.replace(&c.title, "").trim().to_owned();
        }
    }
    if let Some(first) = out.first_mut() {
        first.dropped_latest_block += dropped;
    }
    out
}

pub fn toc_quality(toc: &[Chapter]) -> Quality {
    let mut titles = HashMap::new();
    let mut quality = Quality::default();
    for c in toc {
        quality.merged_toc_items += c.extra_urls.len();
        quality.dropped_latest_block += c.dropped_latest_block;
        if !c.is_volume && meaningful(&c.title) {
            let count = titles.entry(title_key(&c.title)).or_insert(0usize);
            quality.duplicate_headings += usize::from(*count > 0);
            *count += 1;
        }
    }
    quality
}
