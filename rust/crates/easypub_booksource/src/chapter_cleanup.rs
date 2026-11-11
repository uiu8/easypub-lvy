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
    /// 目录里按章号挪回原位或去掉的错位章节。
    pub reordered_toc_items: usize,
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

/// 目录按章号整理。网站目录页常把“最新章节”栏（多为倒序）放在完整目录前面，
/// 或把最新一章夹在目录中间；按网页顺序下载就会出现“第19章后接第470章”“编号回退”。
///
/// 做法：取有章号的各章，求最长的不减子序列，当作目录的主体顺序；不在主体里的章只在
/// 三种有把握的情形下处理，其余保持原样：
/// 1. 出现在主体第一章之前（目录头部的最新章节栏）；
/// 2. 章号比主体里所有章都大（夹在中间或头部的最新章）；
/// 3. 在主体第一章之前、又与主体里某一章章号与标题都相同（头部栏里的重复项，直接去掉）。
///    主体之后不相邻的同名章节地址不同，可能是真正的内容，仍只报告不删。
/// 前两种按章号挪到主体里章号不大于它的最后一章之后。分卷各自从第一章编号、章号大多缺失
/// 或错位太多（超过两成）的目录不动，避免误判。返回整理后的目录与处理的章数。
pub fn reorder_misplaced(chapters: Vec<Chapter>) -> (Vec<Chapter>, usize) {
    let numbered: Vec<(usize, u64)> = chapters
        .iter()
        .enumerate()
        .filter(|(_, c)| !c.is_volume)
        .filter_map(|(i, c)| chapter_number(&c.title).map(|n| (i, n)))
        .collect();
    let body = chapters.iter().filter(|c| !c.is_volume).count();
    if numbered.len() < 30 || numbered.len() * 10 < body * 6 {
        return (chapters, 0);
    }
    // 分卷各自编号：多次从很大的章号跳回 1–3，不整理。
    let resets = numbered
        .windows(2)
        .filter(|w| w[1].1 <= 3 && w[0].1 >= 30)
        .count();
    if resets >= 2 {
        return (chapters, 0);
    }
    // 最长不减子序列（O(n log n)），记下各章的前驱以还原。
    let values: Vec<u64> = numbered.iter().map(|(_, n)| *n).collect();
    let mut tails: Vec<usize> = Vec::new();
    let mut prev = vec![usize::MAX; values.len()];
    for (k, &v) in values.iter().enumerate() {
        let pos = tails.partition_point(|&t| values[t] <= v);
        if pos > 0 {
            prev[k] = tails[pos - 1];
        }
        if pos == tails.len() {
            tails.push(k);
        } else {
            tails[pos] = k;
        }
    }
    let mut keep = vec![false; values.len()];
    let mut k = tails.last().copied().unwrap_or(usize::MAX);
    while k != usize::MAX {
        keep[k] = true;
        k = prev[k];
    }
    let misplaced: Vec<usize> = (0..values.len()).filter(|&k| !keep[k]).collect();
    if misplaced.is_empty() || misplaced.len() * 5 > numbered.len() {
        return (chapters, 0);
    }
    let first_body = numbered[(0..values.len()).find(|&k| keep[k]).unwrap()].0;
    let max_body = (0..values.len())
        .filter(|&k| keep[k])
        .map(|k| values[k])
        .max()
        .unwrap_or(0);
    let body_keys: std::collections::HashSet<(u64, String)> = (0..values.len())
        .filter(|&k| keep[k])
        .map(|k| (values[k], title_key(&chapters[numbered[k].0].title)))
        .collect();
    let mut drop = std::collections::HashSet::new();
    let mut moving: Vec<(u64, usize)> = Vec::new();
    for k in misplaced {
        let (i, n) = numbered[k];
        if i < first_body && body_keys.contains(&(n, title_key(&chapters[i].title))) {
            drop.insert(i);
        } else if i < first_body || n > max_body {
            moving.push((n, i));
        }
    }
    if drop.is_empty() && moving.is_empty() {
        return (chapters, 0);
    }
    let moved: std::collections::HashSet<usize> = moving.iter().map(|(_, i)| *i).collect();
    moving.sort();
    // 每个要挪的章放到主体里章号不大于它的最后一章之后（同一位置按章号排）。
    let mut slots: HashMap<usize, Vec<usize>> = HashMap::new();
    let mut tail: Vec<usize> = Vec::new();
    for (n, i) in &moving {
        let anchor = (0..values.len())
            .filter(|&k| keep[k] && values[k] <= *n)
            .map(|k| numbered[k].0)
            .max();
        match anchor {
            Some(a) => slots.entry(a).or_default().push(*i),
            None => tail.push(*i),
        }
    }
    let count = drop.len() + moved.len();
    let mut items: Vec<Option<Chapter>> = chapters.into_iter().map(Some).collect();
    let mut out = Vec::with_capacity(items.len());
    for i in 0..items.len() {
        if drop.contains(&i) || moved.contains(&i) {
            continue;
        }
        if let Some(c) = items[i].take() {
            out.push(c);
        }
        if let Some(list) = slots.get(&i) {
            for &j in list {
                if let Some(c) = items[j].take() {
                    out.push(c);
                }
            }
        }
    }
    for j in tail {
        if let Some(c) = items[j].take() {
            out.push(c);
        }
    }
    (out, count)
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
    let (chapters, reordered) = reorder_misplaced(chapters);
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
        first.reordered_toc_items += reordered;
    }
    out
}

pub fn toc_quality(toc: &[Chapter]) -> Quality {
    let mut titles = HashMap::new();
    let mut quality = Quality::default();
    for c in toc {
        quality.merged_toc_items += c.extra_urls.len();
        quality.dropped_latest_block += c.dropped_latest_block;
        quality.reordered_toc_items += c.reordered_toc_items;
        if !c.is_volume && meaningful(&c.title) {
            let count = titles.entry(title_key(&c.title)).or_insert(0usize);
            quality.duplicate_headings += usize::from(*count > 0);
            *count += 1;
        }
    }
    quality
}

#[cfg(test)]
mod tests {
    use super::*;

    fn toc(titles: &[String]) -> Vec<Chapter> {
        titles
            .iter()
            .enumerate()
            .map(|(i, t)| Chapter {
                index: i,
                title: t.clone(),
                url: format!("https://example.invalid/{i}"),
                ..Default::default()
            })
            .collect()
    }
    fn titles(chapters: &[Chapter]) -> Vec<String> {
        chapters.iter().map(|c| c.title.clone()).collect()
    }

    #[test]
    fn latest_block_and_injected_latest_chapter_move_back_by_number() {
        // 网站目录：头部倒序的最新章节栏（58→55，夹一条作者的话），然后是完整目录，
        // 最新一章（第60章）夹在第19章与第20章之间。
        let mut list: Vec<String> = vec![
            "第五十八章 甲".into(),
            "第五十七章 乙".into(),
            "作者的话".into(),
        ];
        list.extend(["第五十六章 丙".into(), "第五十五章 丁".into()]);
        for n in 1..=54 {
            list.push(format!("第{n}章 正文{n}"));
            if n == 19 {
                list.push("第六十章 最新".into());
            }
        }
        list.push("第五十九章 次新".into());
        let (out, handled) = reorder_misplaced(toc(&list));
        assert_eq!(handled, 5);
        let got = titles(&out);
        assert_eq!(got.len(), list.len());
        assert_eq!(&got[..2], ["作者的话", "第1章 正文1"]);
        let expected: Vec<String> = [
            "第54章 正文54",
            "第五十五章 丁",
            "第五十六章 丙",
            "第五十七章 乙",
            "第五十八章 甲",
            "第五十九章 次新",
            "第六十章 最新",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        assert_eq!(got[got.len() - 7..], expected[..]);
        // 第19章后面接第20章。
        let at = got.iter().position(|t| t == "第19章 正文19").unwrap();
        assert_eq!(got[at + 1], "第20章 正文20");
        // 第一项记下整理数，供质量报告。
        let normalized = normalize_toc(toc(&list));
        assert_eq!(toc_quality(&normalized).reordered_toc_items, 5);
    }

    #[test]
    fn duplicates_of_body_chapters_are_dropped() {
        let mut list: Vec<String> = vec!["第三十二章 尾".into(), "第三十一章 次尾".into()];
        list.extend((1..=32).map(|n| match n {
            31 => "第三十一章 次尾".to_owned(),
            32 => "第三十二章 尾".to_owned(),
            _ => format!("第{n}章 正文"),
        }));
        let (out, handled) = reorder_misplaced(toc(&list));
        assert_eq!(handled, 2);
        assert_eq!(out.len(), 32);
        assert_eq!(out[0].title, "第1章 正文");
    }

    #[test]
    fn ambiguous_or_volume_numbered_tocs_stay_unchanged() {
        // 分卷各自从第一章编号。
        let mut volumes = Vec::new();
        for v in 1..=3 {
            volumes.extend((1..=40).map(|n| format!("第{n}章 卷{v}")));
        }
        let (out, handled) = reorder_misplaced(toc(&volumes));
        assert_eq!(handled, 0);
        assert_eq!(titles(&out), volumes);
        // 目录中间的个别章号笔误（小于主体最大章号、又不在头部）不挪。
        let mut typo: Vec<String> = (1..=60).map(|n| format!("第{n}章 正文")).collect();
        typo[30] = "第13章 笔误".into();
        let (out, handled) = reorder_misplaced(toc(&typo));
        assert_eq!(handled, 0);
        assert_eq!(titles(&out), typo);
        // 章号太少不动。
        let few: Vec<String> = vec!["第3章".into(), "第1章".into(), "第2章".into()];
        assert_eq!(reorder_misplaced(toc(&few)).1, 0);
    }
}
