//! 同一本书的目录差异和索引缓存迁移。身份按地址匹配，绝不靠相似标题猜移位。
use crate::{chapter_cleanup::title_key, download::write_atomic, webbook::Chapter};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, path::Path};

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Changes {
    pub added: usize,
    pub removed: usize,
    pub modified: usize,
    pub moved: usize,
    pub volumes: usize,
}
impl Changes {
    pub fn changed(&self) -> bool {
        self.added + self.removed + self.modified + self.moved + self.volumes > 0
    }
}
pub struct Comparison {
    pub changes: Changes,
    /// 新索引对应的、内容版本仍相同的旧索引。
    pub reuse: Vec<Option<usize>>,
}
pub fn sanitized(toc: &[Chapter]) -> Vec<Chapter> {
    let mut value = serde_json::to_value(toc).expect("Chapter serialization");
    crate::source::sanitize_json(&mut value);
    serde_json::from_value(value).expect("sanitization preserves Chapter fields")
}
fn identity(chapter: &Chapter, index: usize) -> String {
    if chapter.url.is_empty() {
        // 旧缓存没有地址时只允许原位置复用。
        format!("legacy:{index}:{}", title_key(&chapter.title))
    } else {
        format!("{}:{}", chapter.is_volume, chapter.url)
    }
}
fn same_revision(a: &Chapter, b: &Chapter) -> bool {
    a.url == b.url
        && a.extra_urls == b.extra_urls
        && title_key(&a.title) == title_key(&b.title)
        && a.update_time == b.update_time
        && a.is_volume == b.is_volume
        && a.is_vip == b.is_vip
        && a.is_pay == b.is_pay
}
pub fn compare(old: &[Chapter], new: &[Chapter]) -> Comparison {
    let old = sanitized(old);
    let new = sanitized(new);
    let keys = |toc: &[Chapter]| {
        let mut map: HashMap<String, Vec<usize>> = HashMap::new();
        for (i, c) in toc.iter().enumerate() {
            map.entry(identity(c, i)).or_default().push(i);
        }
        map
    };
    let old_keys = keys(&old);
    let new_keys = keys(&new);
    let mut used = vec![false; old.len()];
    let mut reuse = vec![None; new.len()];
    let mut changes = Changes::default();
    let mut order = Vec::new();
    for (i, c) in new.iter().enumerate() {
        let key = identity(c, i);
        let matched = old_keys.get(&key).and_then(|v| {
            if v.len() == 1 && new_keys[&key].len() == 1 {
                Some(v[0])
            } else {
                // 重复地址无法判定移位，只接受原位置的完全对应。
                old.get(i).filter(|o| same_revision(o, c)).map(|_| i)
            }
        });
        if let Some(j) = matched {
            used[j] = true;
            if same_revision(&old[j], c) {
                reuse[i] = Some(j);
            } else if c.is_volume {
                changes.volumes += 1;
            } else {
                changes.modified += 1;
            }
            if c.is_volume {
                // 卷标题相对正文的位置变化也需要重新合成。
                if i != j {
                    changes.volumes += 1;
                }
            } else {
                order.push(j);
            }
        } else if c.is_volume {
            changes.volumes += 1;
        } else {
            changes.added += 1;
        }
    }
    for (j, c) in old.iter().enumerate() {
        if !used[j] {
            if c.is_volume {
                changes.volumes += 1;
            } else {
                changes.removed += 1;
            }
        }
    }
    // 最长递增子序列：插入导致的整体后移不算调序。
    let mut tails: Vec<usize> = Vec::new();
    for &j in &order {
        let pos = tails.partition_point(|&n| n < j);
        if pos == tails.len() {
            tails.push(j);
        } else {
            tails[pos] = j;
        }
    }
    changes.moved = order.len() - tails.len();
    Comparison { changes, reuse }
}

#[derive(Serialize, Deserialize)]
struct Move {
    index: usize,
    body: bool,
    meta: bool,
}
#[derive(Serialize, Deserialize)]
struct Migration {
    toc: Vec<Chapter>,
    edits: Vec<Move>,
}
const JOURNAL: &str = "reindex.json";
const STAGE: &str = "reindex";

/// 正文缓存的所有写入都用临时文件替换，不原地修改，因此可用硬链接暂存不可变版本。
/// 同目录不支持硬链接（如部分移动盘）时退回复制，迁移协议不变。
fn snapshot(from: &Path, to: &Path) -> Result<(), String> {
    if to.exists() {
        std::fs::remove_file(to).map_err(|_| "无法清理目录迁移临时文件")?;
    }
    std::fs::hard_link(from, to)
        .or_else(|_| std::fs::copy(from, to).map(|_| ()))
        .map_err(|_| "无法暂存章节缓存")
        .map_err(str::to_owned)
}

/// 日志写好之后，暂存文件保持不变；重放不依赖正在被覆盖的旧索引。
fn replay(cache: &Path, migration: &Migration) -> Result<(), String> {
    for edit in &migration.edits {
        for (ext, present) in [("txt", edit.body), ("meta.json", edit.meta)] {
            let name = format!("{:05}.{ext}", edit.index);
            let dest = cache.join(&name);
            if present {
                let temp = dest.with_extension("part");
                snapshot(&cache.join(STAGE).join(&name), &temp)?;
                std::fs::rename(temp, dest).map_err(|_| "无法提交章节缓存迁移")?;
            } else if dest.exists() {
                std::fs::rename(&dest, dest.with_extension(format!("{ext}.stale")))
                    .map_err(|_| "旧缓存无法隔离")?;
            }
        }
    }
    write_atomic(
        &cache.join("toc.json"),
        &serde_json::to_vec(&migration.toc).map_err(|_| "目录无法保存")?,
    )?;
    std::fs::remove_file(cache.join(JOURNAL)).map_err(|_| "目录迁移日志无法提交")?;
    // 删除日志后暂存文件已不参与恢复；只清理本次明确生成的文件。
    for edit in &migration.edits {
        for ext in ["txt", "meta.json"] {
            let _ =
                std::fs::remove_file(cache.join(STAGE).join(format!("{:05}.{ext}", edit.index)));
        }
    }
    let _ = std::fs::remove_dir(cache.join(STAGE));
    Ok(())
}
pub fn pending(cache: &Path) -> bool {
    cache.join(JOURNAL).exists()
}
pub fn prepare(cache: &Path, toc: &[Chapter]) -> Result<(), String> {
    std::fs::create_dir_all(cache).map_err(|_| "无法创建缓存")?;
    if pending(cache) {
        let bytes = std::fs::read(cache.join(JOURNAL)).map_err(|_| "无法读取目录迁移日志")?;
        let migration: Migration =
            serde_json::from_slice(&bytes).map_err(|_| "目录迁移日志损坏，请保留缓存")?;
        replay(cache, &migration)?;
    }
    let toc = sanitized(toc);
    if std::fs::read_dir(cache)
        .map_err(|_| "无法读取缓存目录")?
        .next()
        .is_none()
    {
        return write_atomic(&cache.join("toc.json"), &serde_json::to_vec(&toc).unwrap());
    }
    let old = std::fs::read(cache.join("toc.json"))
        .ok()
        .and_then(|b| serde_json::from_slice::<Vec<Chapter>>(&b).ok());
    let reuse = match &old {
        Some(old) => compare(old, &toc).reuse,
        None => toc
            .iter()
            .enumerate()
            .map(|(i, c)| {
                (c.extra_urls.is_empty()
                    && std::fs::read_to_string(cache.join(format!("{i:05}.txt")))
                        .ok()
                        .is_some_and(|s| {
                            s.lines()
                                .find(|l| !l.trim().is_empty())
                                .is_some_and(|l| crate::chapter_cleanup::same_title(l, &c.title))
                        }))
                .then_some(i)
            })
            .collect(),
    };
    let mut migration = Migration {
        toc,
        edits: Vec::new(),
    };
    let count = old.as_ref().map_or(0, Vec::len).max(reuse.len());
    for i in 0..count {
        if reuse.get(i) == Some(&Some(i)) {
            continue;
        }
        let mut edit = Move {
            index: i,
            body: false,
            meta: false,
        };
        if let Some(Some(j)) = reuse.get(i) {
            let body = cache.join(format!("{j:05}.txt"));
            if body.is_file() {
                std::fs::create_dir_all(cache.join(STAGE)).map_err(|_| "无法暂存目录迁移")?;
                snapshot(&body, &cache.join(STAGE).join(format!("{i:05}.txt")))?;
                edit.body = true;
                let meta = cache.join(format!("{j:05}.meta.json"));
                if meta.is_file() {
                    snapshot(&meta, &cache.join(STAGE).join(format!("{i:05}.meta.json")))?;
                    edit.meta = true;
                }
            }
        }
        migration.edits.push(edit);
    }
    // 即使本次不需要移动，目录元数据也会更新。
    if migration.edits.is_empty() {
        return write_atomic(
            &cache.join("toc.json"),
            &serde_json::to_vec(&migration.toc).unwrap(),
        );
    }
    write_atomic(
        &cache.join(JOURNAL),
        &serde_json::to_vec(&migration).unwrap(),
    )?;
    replay(cache, &migration)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn chapters(ids: &[&str]) -> Vec<Chapter> {
        ids.iter()
            .enumerate()
            .map(|(index, id)| Chapter {
                index,
                title: format!("章节 {id}"),
                url: format!("https://fixture.invalid/{id}"),
                ..Default::default()
            })
            .collect()
    }
    fn fixture(name: &str) -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!("ep-catalogue-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&path).unwrap();
        path
    }
    #[test]
    fn edits_keep_identity_and_revision_separate() {
        let old = chapters(&["a", "b", "c"]);
        let insertion = compare(&old, &chapters(&["x", "a", "b", "c"]));
        assert_eq!(
            insertion.changes,
            Changes {
                added: 1,
                ..Default::default()
            }
        );
        assert_eq!(insertion.reuse, [None, Some(0), Some(1), Some(2)]);
        let mut new = chapters(&["c", "x", "a"]);
        new[2].update_time = "revision-2".into();
        let diff = compare(&old, &new);
        assert_eq!(
            diff.changes,
            Changes {
                added: 1,
                removed: 1,
                modified: 1,
                moved: 1,
                volumes: 0
            }
        );
        assert_eq!(diff.reuse, [Some(2), None, None]);
        let mut duplicate = old.clone();
        duplicate[1].url = duplicate[0].url.clone();
        assert!(!compare(&duplicate, &duplicate).changes.changed());
        let mut swapped = duplicate.clone();
        swapped.swap(0, 1);
        assert_eq!(&compare(&duplicate, &swapped).reuse[..2], &[None, None]);
        let mut signed = old.clone();
        signed[0].url = "https://user:old-secret@fixture.invalid/a".into();
        let mut refreshed = signed.clone();
        refreshed[0].url = refreshed[0].url.replace("old-secret", "new-secret");
        assert_eq!(
            compare(&signed, &refreshed).reuse,
            [Some(0), Some(1), Some(2)]
        );
        // 不猜查询参数是否参与章节身份，变化时重新抓取。
        refreshed[0].url.push_str("?token=different-resource");
        assert_eq!(compare(&signed, &refreshed).reuse[0], None);
    }
    #[test]
    fn interrupted_overlap_replays_before_next_migration_and_legacy_cache_survives() {
        let cache = fixture("replay");
        let old = chapters(&["a", "b", "c"]);
        let new = chapters(&["b", "c", "a"]);
        std::fs::create_dir_all(cache.join(STAGE)).unwrap();
        for (i, c) in old.iter().enumerate() {
            std::fs::write(cache.join(format!("{i:05}.txt")), &c.title).unwrap();
        }
        write_atomic(&cache.join("toc.json"), &serde_json::to_vec(&old).unwrap()).unwrap();
        for (i, j) in [1, 2, 0].iter().enumerate() {
            std::fs::copy(
                cache.join(format!("{j:05}.txt")),
                cache.join(STAGE).join(format!("{i:05}.txt")),
            )
            .unwrap();
        }
        let migration = Migration {
            toc: new.clone(),
            edits: (0..3)
                .map(|index| Move {
                    index,
                    body: true,
                    meta: false,
                })
                .collect(),
        };
        write_atomic(
            &cache.join(JOURNAL),
            &serde_json::to_vec(&migration).unwrap(),
        )
        .unwrap();
        // 模拟移动第一章后被强制结束；旧索引 0 此刻已被覆盖。
        std::fs::write(cache.join("00000.txt"), &new[0].title).unwrap();
        prepare(&cache, &new).unwrap();
        assert!(!pending(&cache));
        for (i, c) in new.iter().enumerate() {
            assert_eq!(
                std::fs::read_to_string(cache.join(format!("{i:05}.txt"))).unwrap(),
                c.title
            );
        }
        let shrunk = chapters(&["a", "x"]);
        prepare(&cache, &shrunk).unwrap();
        assert_eq!(
            std::fs::read_to_string(cache.join("00000.txt")).unwrap(),
            "章节 a"
        );
        assert!(!cache.join("00001.txt").exists());
        assert!(!cache.join("00002.txt").exists());
        std::fs::remove_dir_all(&cache).unwrap();
        let legacy = fixture("legacy");
        std::fs::write(legacy.join("00000.txt"), "章节 a\n旧正文").unwrap();
        prepare(&legacy, &chapters(&["a"])).unwrap();
        assert_eq!(
            std::fs::read_to_string(legacy.join("00000.txt")).unwrap(),
            "章节 a\n旧正文"
        );
        std::fs::remove_dir_all(legacy).unwrap();
    }
}
