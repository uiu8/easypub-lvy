//! 改好的书存到磁盘，重启后直接读，不用重放。
//!
//! 这里存的是可以重建的成品，不是唯一的一份：修改步骤仍保留在项目里。文件缺失、损坏、
//! 写不进去都只是下次重算一遍，所以这里的错误一律不往外报。
//!
//! 文件名由“依据标识 + 修改步骤”决定，内容带校验和。每本书留最近 3 个状态，总量不超过
//! 1 GiB，放在缓存目录里，用户可以随时清掉。
use crate::replay_cache::Replay;
use easypub_core::{publication::EffectiveBook, structure::Tree};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs::{self, File},
    io::Write,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
    time::SystemTime,
};

const MAGIC: &[u8; 8] = b"EPRSLT01";
/// 标记、结构信息长度、校验和。
const HEADER: usize = 8 + 8 + 32;
const KEEP_PER_BOOK: usize = 3;
const MAX_TOTAL_BYTES: u64 = 1024 * 1024 * 1024;
const MAX_FILE_BYTES: usize = 512 * 1024 * 1024;
const EXTENSION: &str = "bin";
static NEXT: AtomicU64 = AtomicU64::new(1);

#[cfg(test)]
thread_local! {
    /// 单元测试不碰真实的缓存目录；只有设置过的线程才会用到磁盘。
    pub(crate) static TEST_DIRECTORY: std::cell::RefCell<Option<PathBuf>> =
        const { std::cell::RefCell::new(None) };
}

#[cfg(not(test))]
fn directory() -> Option<PathBuf> {
    Some(crate::storage::path("edit_results"))
}

#[cfg(test)]
fn directory() -> Option<PathBuf> {
    TEST_DIRECTORY.with(|d| d.borrow().clone())
}

/// 行映射绝大部分连续，按段存：16 万行的书通常只有几十段。
fn runs(map: &BTreeMap<u32, u32>) -> Vec<(u32, u32, u32)> {
    let mut runs: Vec<(u32, u32, u32)> = Vec::new();
    for (&original, &output) in map {
        match runs.last_mut() {
            Some(last)
                if last.0.checked_add(last.2) == Some(original)
                    && last.1.checked_add(last.2) == Some(output) =>
            {
                last.2 += 1
            }
            _ => runs.push((original, output, 1)),
        }
    }
    runs
}

#[derive(Serialize)]
struct MetaOut<'a> {
    original_source_id: &'a str,
    tree: &'a Tree,
    lines: Vec<(u32, u32, u32)>,
    removed_structure_lines: &'a [u32],
    text_changed: bool,
    cleanup_evidence: &'a Option<Value>,
    evidence: &'a [Value],
}

#[derive(Deserialize)]
struct MetaIn {
    original_source_id: String,
    tree: Tree,
    lines: Vec<(u32, u32, u32)>,
    removed_structure_lines: Vec<u32>,
    text_changed: bool,
    cleanup_evidence: Option<Value>,
    evidence: Vec<Value>,
}

fn digest(head: &[u8], body: &[u8]) -> [u8; 32] {
    let mut hash = Sha256::new();
    hash.update(head);
    hash.update(body);
    hash.finalize().into()
}

fn encode(value: &Replay) -> Option<Vec<u8>> {
    let (book, evidence) = value;
    let meta = serde_json::to_vec(&MetaOut {
        original_source_id: &book.original_source_id,
        tree: &book.tree,
        lines: runs(&book.source_to_output_lines),
        removed_structure_lines: &book.removed_structure_lines,
        text_changed: book.text_changed,
        cleanup_evidence: &book.cleanup_evidence,
        evidence,
    })
    .ok()?;
    let size = (meta.len() as u64).to_le_bytes();
    let total = HEADER + meta.len() + book.text.len();
    if total > MAX_FILE_BYTES {
        return None;
    }
    let mut hash = Sha256::new();
    hash.update(size);
    hash.update(&meta);
    hash.update(book.text.as_bytes());
    let mut out = Vec::with_capacity(total);
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&size);
    out.extend_from_slice(&hash.finalize());
    out.extend_from_slice(&meta);
    out.extend_from_slice(book.text.as_bytes());
    Some(out)
}

fn decode(mut bytes: Vec<u8>) -> Option<Replay> {
    if bytes.len() < HEADER || &bytes[..8] != MAGIC {
        return None;
    }
    let size = usize::try_from(u64::from_le_bytes(bytes[8..16].try_into().ok()?)).ok()?;
    let end = HEADER.checked_add(size).filter(|e| *e <= bytes.len())?;
    if digest(&bytes[8..16], &bytes[HEADER..]) != bytes[16..HEADER] {
        return None;
    }
    let meta: MetaIn = serde_json::from_slice(&bytes[HEADER..end]).ok()?;
    // 正文就地留在读出来的缓冲区里，大书不用再复制一份。
    bytes.drain(..end);
    let text = String::from_utf8(bytes).ok()?;
    let mut source_to_output_lines = BTreeMap::new();
    for (original, output, count) in meta.lines {
        for offset in 0..count {
            source_to_output_lines
                .insert(original.checked_add(offset)?, output.checked_add(offset)?);
        }
    }
    let book = EffectiveBook {
        original_source_id: meta.original_source_id,
        source_to_output_lines,
        tree: meta.tree,
        removed_structure_lines: meta.removed_structure_lines,
        text_changed: meta.text_changed,
        text,
        cleanup_evidence: meta.cleanup_evidence,
    };
    crate::edit_checkpoint::validate_book(&book).ok()?;
    Some((book, meta.evidence))
}

fn file_name(source: &str, key: &str) -> Option<String> {
    let hex = |v: &str| !v.is_empty() && v.bytes().all(|b| b.is_ascii_hexdigit());
    let prefix = source.get(..16)?;
    (hex(prefix) && hex(key)).then(|| format!("{prefix}-{key}.{EXTENSION}"))
}

fn path_of(source: &str, key: &str) -> Option<PathBuf> {
    Some(directory()?.join(file_name(source, key)?))
}

/// 记下最近用过，清理时先删最久没用的。失败只影响清理顺序。
fn touch(path: &Path) {
    if let Ok(file) = File::options().write(true).open(path) {
        let _ = file.set_modified(SystemTime::now());
    }
}

pub(crate) fn load(source: &str, key: &str) -> Option<Replay> {
    let path = path_of(source, key)?;
    let bytes = fs::read(&path).ok()?;
    let value = decode(bytes);
    if value.is_some() {
        touch(&path);
    } else {
        // 坏文件留着只会每次多读一遍。
        let _ = fs::remove_file(&path);
    }
    value
}

/// 这一组步骤成功算过吗？校验只要知道这个，不读书稿。
pub(crate) fn contains(source: &str, key: &str) -> bool {
    path_of(source, key).is_some_and(|p| p.is_file())
}

/// 写临时文件再改名，崩溃不会留下半个文件。缓存可以重建，不必落盘同步：
/// 断电造成的残缺会被校验和发现。
pub(crate) fn save(key: &str, value: &Replay) {
    let source = &value.0.original_source_id;
    let Some(path) = path_of(source, key) else {
        return;
    };
    if path.is_file() {
        touch(&path);
        return;
    }
    let Some(bytes) = encode(value) else {
        return;
    };
    let Some(parent) = path.parent() else {
        return;
    };
    if fs::create_dir_all(parent).is_err() {
        return;
    }
    let stage = parent.join(format!(
        ".result-{}-{}.tmp",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let written = File::create(&stage).and_then(|mut f| f.write_all(&bytes));
    if written.is_err() || fs::rename(&stage, &path).is_err() {
        let _ = fs::remove_file(&stage);
    }
}

struct Stored {
    path: PathBuf,
    name: String,
    bytes: u64,
    modified: SystemTime,
}

fn stored(directory: &Path) -> Vec<Stored> {
    let Ok(entries) = fs::read_dir(directory) else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some(EXTENSION) {
                return None;
            }
            let meta = entry.metadata().ok()?;
            Some(Stored {
                name: entry.file_name().to_string_lossy().into_owned(),
                path,
                bytes: meta.len(),
                modified: meta.modified().ok()?,
            })
        })
        .collect()
}

fn prune_in(directory: &Path, source: &str, limit: u64) {
    let mut files = stored(directory);
    files.sort_by_key(|f| std::cmp::Reverse(f.modified));
    let Some(prefix) = source.get(..16) else {
        return;
    };
    let mut seen = 0;
    files.retain(|file| {
        if !file.name.starts_with(prefix) {
            return true;
        }
        seen += 1;
        if seen <= KEEP_PER_BOOK {
            return true;
        }
        let _ = fs::remove_file(&file.path);
        false
    });
    let mut total: u64 = files.iter().map(|f| f.bytes).sum();
    // 最新的一份总是留下：它就是现在的书稿。
    while total > limit && files.len() > 1 {
        let Some(oldest) = files.pop() else {
            return;
        };
        let _ = fs::remove_file(&oldest.path);
        total -= oldest.bytes;
    }
}

pub(crate) fn prune(source: &str) {
    if let Some(directory) = directory() {
        prune_in(&directory, source, MAX_TOTAL_BYTES);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use easypub_core::{
        effective_edit::{self, Action, Request},
        publication,
        source::{RULE_ID, SourceSnapshot},
        structure::Structure,
    };

    fn sample() -> Replay {
        let text = "第1章 甲\n甲文\n第1章 甲\n第2章 乙\n乙文\n第3章 丙\n丙文\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let book = publication::compose(&source, &Structure::new(&source), None).unwrap();
        let request = Request {
            base_id: effective_edit::base_id(&book),
            actions: vec![
                Action::Rename {
                    entry_id: book.tree.nodes[1].entry_id.clone(),
                    title: "第2章 新名".into(),
                },
                Action::Classify {
                    entry_id: book.tree.nodes[2].entry_id.clone(),
                    role: easypub_core::structure::Role::Body,
                    depth: 0,
                    include_toc: false,
                },
            ],
        };
        effective_edit::apply(book, &request).unwrap()
    }

    fn folder(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "result-store-{name}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&dir).unwrap();
        TEST_DIRECTORY.with(|d| *d.borrow_mut() = Some(dir.clone()));
        dir
    }

    fn assert_same(left: &Replay, right: &Replay) {
        assert_eq!(left.0.text, right.0.text);
        assert_eq!(
            serde_json::to_value(&left.0.tree).unwrap(),
            serde_json::to_value(&right.0.tree).unwrap()
        );
        assert_eq!(
            left.0.source_to_output_lines,
            right.0.source_to_output_lines
        );
        assert_eq!(
            left.0.removed_structure_lines,
            right.0.removed_structure_lines
        );
        assert_eq!(left.0.text_changed, right.0.text_changed);
        assert_eq!(left.0.original_source_id, right.0.original_source_id);
        assert_eq!(left.0.cleanup_evidence, right.0.cleanup_evidence);
        assert_eq!(left.1, right.1);
    }

    #[test]
    fn a_saved_result_reads_back_exactly() {
        let dir = folder("round");
        let value = sample();
        let source = value.0.original_source_id.clone();
        assert!(load(&source, "abc").is_none());
        save("abc", &value);
        assert!(contains(&source, "abc"));
        assert_same(&load(&source, "abc").unwrap(), &value);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_damaged_file_is_ignored_and_removed() {
        let dir = folder("damaged");
        let value = sample();
        let source = value.0.original_source_id.clone();
        let cut = |bytes: &mut Vec<u8>| bytes.truncate(bytes.len() - 3);
        let flip = |bytes: &mut Vec<u8>| {
            let last = bytes.len() - 1;
            bytes[last] ^= 1;
        };
        let head = |bytes: &mut Vec<u8>| bytes[0] = b'X';
        let size = |bytes: &mut Vec<u8>| bytes[8] ^= 1;
        let damage: [&dyn Fn(&mut Vec<u8>); 4] = [&cut, &flip, &head, &size];
        for damage in damage {
            save("abc", &value);
            let path = path_of(&source, "abc").unwrap();
            let mut bytes = fs::read(&path).unwrap();
            damage(&mut bytes);
            fs::write(&path, bytes).unwrap();
            assert!(load(&source, "abc").is_none());
            assert!(!path.exists());
        }
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn unsafe_names_never_reach_the_disk() {
        assert!(file_name("..\\..\\windows!!", "abc").is_none());
        assert!(file_name("0123456789abcdef0000", "../x").is_none());
        assert!(file_name("short", "abc").is_none());
    }

    #[test]
    fn only_recent_states_are_kept_and_the_budget_is_respected() {
        let dir = folder("prune");
        let name = |book: &str, n: u32| format!("{book}-{n:04}.bin");
        let (one, two) = ("aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb");
        let start = SystemTime::now() - std::time::Duration::from_secs(1000);
        let put = |book: &str, n: u32| {
            let path = dir.join(name(book, n));
            fs::write(&path, vec![0u8; 100]).unwrap();
            File::options()
                .write(true)
                .open(&path)
                .unwrap()
                .set_modified(start + std::time::Duration::from_secs(n.into()))
                .unwrap();
        };
        for n in 1..=5 {
            put(one, n);
        }
        put(two, 1);
        fs::write(dir.join(".storage-use.lock"), b"").unwrap();
        prune_in(&dir, &format!("{one}0000"), u64::MAX);
        let left = |book: &str, n: u32| dir.join(name(book, n)).exists();
        assert!(!left(one, 1) && !left(one, 2), "只留最近 3 个");
        assert!(left(one, 3) && left(one, 4) && left(one, 5));
        assert!(left(two, 1), "别的书不受影响");
        assert!(dir.join(".storage-use.lock").exists());
        prune_in(&dir, &format!("{one}0000"), 150);
        assert!(left(one, 5), "超预算时留最新的");
        assert!(!left(two, 1) && !left(one, 3) && !left(one, 4));
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn line_map_is_stored_as_runs() {
        let map: BTreeMap<u32, u32> = (1..=5).map(|n| (n, n)).chain([(7, 6), (8, 7)]).collect();
        assert_eq!(runs(&map), vec![(1, 1, 5), (7, 6, 2)]);
    }
}
