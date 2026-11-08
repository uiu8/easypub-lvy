//! 编辑重放缓存。
//!
//! 书稿由“合成结果 + 编辑步骤”重放出来，每步都要重建整本书的索引：约 700 万字节的书一步约 78ms，
//! 一次批量修复留下的 47 步就要 3.6 秒。而自动保存、进页面、每次编辑稿操作都要用同一个结果。
//!
//! 重放只由输入的书稿和步骤决定，所以记住结果：依据标识（对整本书的哈希）加步骤内容作键。
//! 同一个键正在算时，后来的请求等它算完，不重复算。
//! 这次的步骤开头一段已经算过时，接着那份结果只算后面新增的步骤。
//! 内存里只留最近的结果，合计估算不超过 256 MiB；太快的重放不值得留。
//! 保存项目时结果写到磁盘（`result_store`），重启后直接读。
use crate::base_identity::{estimated_bytes, recipe_key};
use easypub_core::{
    ApiError,
    effective_edit::{self, Action, Request},
    publication::EffectiveBook,
};
use serde_json::Value;
use std::{
    sync::{Arc, Condvar, Mutex},
    time::{Duration, Instant},
};

pub(crate) type Replay = (EffectiveBook, Vec<Value>);

/// 磁盘上还有一份，内存只需要留正在用的：当前状态和上一步。
const CAPACITY: usize = if cfg!(test) { 64 } else { 2 };
const MAX_BYTES: usize = 256 * 1024 * 1024;
const KEEP_AFTER: Duration = if cfg!(test) {
    Duration::ZERO
} else {
    Duration::from_millis(20)
};

struct Entry {
    key: String,
    base: String,
    actions: Vec<Action>,
    value: Arc<Replay>,
    size: usize,
}

/// 改变重放结果的修改都要换这个版本号，否则磁盘上的旧结果会被当成新的。
const VERSION: &[u8] = b"replay-v1";
/// 往回找多少个前缀：只追加几步时一下就能找到，再长不如从头合并重放。
const PREFIX_SEARCH: usize = 64;

static CACHE: Mutex<Vec<Entry>> = Mutex::new(Vec::new());
static PENDING: Mutex<Vec<String>> = Mutex::new(Vec::new());
static FINISHED: Condvar = Condvar::new();

fn replay_key(id: &str, actions: &[Action]) -> Option<String> {
    let actions = serde_json::to_vec(actions).ok()?;
    Some(recipe_key(&[VERSION, id.as_bytes(), &actions]))
}

fn cached(key: &str) -> Option<Arc<Replay>> {
    let mut cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    let index = cache.iter().position(|e| e.key == key)?;
    let entry = cache.remove(index);
    let value = entry.value.clone();
    cache.push(entry);
    Some(value)
}

/// 同一份依据下，步骤是这次开头一段的结果里最长的那个。
fn longest_prefix(id: &str, actions: &[Action]) -> Option<(usize, Arc<Replay>)> {
    let cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    cache
        .iter()
        .filter(|e| {
            e.base == id && e.actions.len() < actions.len() && actions.starts_with(&e.actions)
        })
        .max_by_key(|e| e.actions.len())
        .map(|e| (e.actions.len(), e.value.clone()))
}

/// 磁盘上最长的前缀，只看内存找到的 `known` 之后更长的。
fn stored_prefix(
    source: &str,
    id: &str,
    actions: &[Action],
    known: usize,
) -> Option<(usize, Arc<Replay>)> {
    for done in (known + 1..actions.len()).rev().take(PREFIX_SEARCH) {
        let key = replay_key(id, &actions[..done])?;
        if crate::result_store::contains(source, &key)
            && let Some(value) = crate::result_store::load(source, &key)
        {
            return Some((done, Arc::new(value)));
        }
    }
    None
}

fn keep(key: &str, id: &str, actions: &[Action], value: &Arc<Replay>) {
    let size = estimated_bytes(&value.0);
    if size > MAX_BYTES {
        return;
    }
    let mut cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    cache.retain(|e| e.key != key);
    while !cache.is_empty()
        && (cache.len() >= CAPACITY
            || cache.iter().map(|e| e.size).sum::<usize>() + size > MAX_BYTES)
    {
        cache.remove(0);
    }
    cache.push(Entry {
        key: key.to_owned(),
        base: id.to_owned(),
        actions: actions.to_vec(),
        value: value.clone(),
        size,
    });
}

/// 占住一个键：同一个键只有一个线程在算。出错或崩溃时也会放开。
struct Claim(String);
impl Drop for Claim {
    fn drop(&mut self) {
        let mut pending = PENDING.lock().unwrap_or_else(|e| e.into_inner());
        pending.retain(|k| *k != self.0);
        drop(pending);
        FINISHED.notify_all();
    }
}

/// 没人在算就占住；有人在算就等它结束，返回 None 让调用方重新查缓存。
fn claim(key: &str) -> Option<Claim> {
    let mut pending = PENDING.lock().unwrap_or_else(|e| e.into_inner());
    if pending.iter().any(|k| k == key) {
        // 结果可能太大不进缓存，所以等一轮后重新判断，不死等。
        let _ = FINISHED
            .wait_timeout(pending, Duration::from_millis(100))
            .unwrap_or_else(|e| e.into_inner());
        return None;
    }
    pending.push(key.to_owned());
    Some(Claim(key.to_owned()))
}

fn shared(
    book: EffectiveBook,
    book_id: Option<&str>,
    request: &Request,
) -> Result<Arc<Replay>, ApiError> {
    let computed;
    let id = match book_id {
        Some(id) => id,
        None => {
            computed = effective_edit::base_id(&book);
            &computed
        }
    };
    // 依据对不上：走原来的路，给出原来的错误，不进缓存。
    let key = replay_key(id, &request.actions).filter(|_| request.base_id == id);
    let Some(key) = key else {
        return effective_edit::apply_identified(book, Some(id), request).map(Arc::new);
    };
    let _claim = loop {
        if let Some(hit) = cached(&key) {
            return Ok(hit);
        }
        if let Some(claim) = claim(&key) {
            break claim;
        }
    };
    let source = book.original_source_id.clone();
    if let Some(value) = crate::result_store::load(&source, &key) {
        let value = Arc::new(value);
        keep(&key, id, &request.actions, &value);
        return Ok(value);
    }
    let started = Instant::now();
    let known = longest_prefix(id, &request.actions);
    let from = known.as_ref().map_or(0, |k| k.0);
    let prefix = stored_prefix(&source, id, &request.actions, from).or(known);
    let result = Arc::new(match prefix {
        Some((done, prefix)) => {
            let (book, more) = effective_edit::apply_remaining(prefix.0.clone(), request, done)?;
            let mut evidence = prefix.1.clone();
            evidence.extend(more);
            (book, evidence)
        }
        None => effective_edit::apply_identified(book, Some(id), request)?,
    });
    if started.elapsed() >= KEEP_AFTER {
        keep(&key, id, &request.actions, &result);
    }
    Ok(result)
}

/// 重放并返回结果；已经算过时直接复制。
pub(crate) fn replay(
    book: EffectiveBook,
    book_id: Option<&str>,
    request: &Request,
) -> Result<Replay, ApiError> {
    let value = shared(book, book_id, request)?;
    Ok((value.0.clone(), value.1.clone()))
}

/// 只确认这组步骤能重放（校验用）：算过的不读书稿，也不复制。
pub(crate) fn ensure_replayable(
    book: EffectiveBook,
    book_id: Option<&str>,
    request: &Request,
) -> Result<(), ApiError> {
    if let Some(id) = book_id.filter(|id| *id == request.base_id)
        && let Some(key) = replay_key(id, &request.actions)
        && (cached(&key).is_some() || crate::result_store::contains(&book.original_source_id, &key))
    {
        return Ok(());
    }
    shared(book, book_id, request).map(|_| ())
}

/// 把这本书最近几个状态的结果存到磁盘。内存里没有的不特意去算。
pub(crate) fn persist(history: &crate::effective_draft::History) {
    let mut source = None;
    for snapshot in &history.history[history.cursor.saturating_sub(2)..=history.cursor] {
        let edits = &snapshot.request;
        if edits.actions.is_empty() {
            continue;
        }
        if let Some(key) = replay_key(&edits.base_id, &edits.actions)
            && let Some(value) = cached(&key)
        {
            crate::result_store::save(&key, &value);
            source = Some(value.0.original_source_id.clone());
        }
    }
    if let Some(source) = source {
        crate::result_store::prune(&source);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use easypub_core::{
        effective_edit::Action,
        publication,
        source::{RULE_ID, SourceSnapshot},
        structure::Structure,
    };

    fn setup(text: &str) -> (EffectiveBook, Request) {
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let structure = Structure::new(&source);
        let book = publication::compose_with_cleanup(&source, &structure, None, None).unwrap();
        let request = Request {
            base_id: effective_edit::base_id(&book),
            actions: vec![Action::Rename {
                entry_id: book.tree.nodes[0].entry_id.clone(),
                title: "第1章 新名字".into(),
            }],
        };
        (book, request)
    }

    #[test]
    fn cached_replay_equals_a_fresh_replay_and_is_not_recomputed() {
        let (book, request) = setup("第1章 缓存甲\n正文\n第2章 乙\n正文\n");
        let fresh = effective_edit::apply(book.clone(), &request).unwrap();
        let first = replay(book.clone(), None, &request).unwrap();
        let second = replay(book.clone(), Some(&request.base_id), &request).unwrap();
        for (other, name) in [(&first, "第一次"), (&second, "第二次")] {
            assert_eq!(
                effective_edit::base_id(&other.0),
                effective_edit::base_id(&fresh.0),
                "{name}"
            );
            assert_eq!(other.1, fresh.1, "{name}");
        }
        let key = replay_key(&request.base_id, &request.actions).unwrap();
        assert!(cached(&key).is_some());
        ensure_replayable(book, None, &request).unwrap();
    }

    fn forget(key: &str) {
        CACHE.lock().unwrap().retain(|e| e.key != key);
    }

    fn disk(name: &str) -> std::path::PathBuf {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        let dir = std::env::temp_dir().join(format!(
            "replay-disk-{name}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        crate::result_store::TEST_DIRECTORY.with(|d| *d.borrow_mut() = Some(dir.clone()));
        dir
    }

    fn saved(book: &EffectiveBook, request: &Request) -> String {
        let value = shared(book.clone(), None, request).unwrap();
        let key = replay_key(&request.base_id, &request.actions).unwrap();
        crate::result_store::save(&key, &value);
        forget(&key);
        key
    }

    #[test]
    fn a_restart_reads_the_saved_result_instead_of_replaying() {
        let dir = disk("restart");
        let (book, request) = setup("第1章 磁盘甲\n正文\n第2章 乙\n正文\n");
        let fresh = effective_edit::apply_stepwise(book.clone(), &request).unwrap();
        let key = saved(&book, &request);
        let source = book.original_source_id.clone();
        let path = dir.join(
            std::fs::read_dir(&dir)
                .unwrap()
                .next()
                .unwrap()
                .unwrap()
                .file_name(),
        );
        // 算过的不用读书稿：别的书稿传进来也不会重放。
        ensure_replayable(book.clone(), Some(&request.base_id), &request).unwrap();
        let read = replay(book.clone(), None, &request).unwrap();
        assert_eq!(
            effective_edit::base_id(&read.0),
            effective_edit::base_id(&fresh.0)
        );
        assert_eq!(read.1, fresh.1);
        forget(&key);
        // 文件坏了：退回重算，结果不变。
        let mut bytes = std::fs::read(&path).unwrap();
        let last = bytes.len() - 1;
        bytes[last] ^= 1;
        std::fs::write(&path, &bytes).unwrap();
        let rebuilt = replay(book, None, &request).unwrap();
        assert_eq!(rebuilt.0.text, fresh.0.text);
        assert!(crate::result_store::load(&source, &key).is_none());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_longer_request_continues_from_a_saved_prefix() {
        let dir = disk("prefix");
        let (book, mut request) = setup("第1章 磁盘丙\n正文\n第2章 丁\n正文\n");
        saved(&book, &request);
        request.actions.push(Action::Rename {
            entry_id: book.tree.nodes[1].entry_id.clone(),
            title: "第2章 新名字".into(),
        });
        assert_eq!(
            longest_prefix(&request.base_id, &request.actions).map(|p| p.0),
            None,
            "内存里已经没有了"
        );
        let source = book.original_source_id.clone();
        assert_eq!(
            stored_prefix(&source, &request.base_id, &request.actions, 0).map(|p| p.0),
            Some(1)
        );
        let fresh = effective_edit::apply_stepwise(book.clone(), &request).unwrap();
        let continued = replay(book, None, &request).unwrap();
        assert_eq!(
            effective_edit::base_id(&continued.0),
            effective_edit::base_id(&fresh.0)
        );
        assert_eq!(continued.1, fresh.1);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn saving_a_project_writes_recent_states_only() {
        use crate::{
            edit_checkpoint::EditRequest,
            effective_draft::{Base, History, Snapshot},
        };
        let dir = disk("persist");
        let (book, first) = setup("第1章 磁盘戊\n正文\n第2章 己\n正文\n第3章 庚\n正文\n");
        let actions: Vec<_> = (0..4)
            .map(|i| Action::Rename {
                entry_id: book.tree.nodes[i % 3].entry_id.clone(),
                title: format!("第{}章 名{i}", i % 3 + 1),
            })
            .collect();
        let state = |count: usize| Snapshot {
            base: Base {
                structure: None,
                manual: None,
                cleanup: None,
                catalog: None,
            },
            request: EditRequest {
                base_id: first.base_id.clone(),
                actions: actions[..count].to_vec(),
                checkpoint: None,
            },
            recorded_request: None,
            rebased: false,
        };
        let history = History {
            source_id: book.original_source_id.clone(),
            revision: 1,
            cursor: 4,
            history: (0..=4).map(state).collect(),
        };
        for count in 1..=4 {
            replay(
                book.clone(),
                None,
                &Request {
                    base_id: first.base_id.clone(),
                    actions: actions[..count].to_vec(),
                },
            )
            .unwrap();
        }
        persist(&history);
        let source = &book.original_source_id;
        let stored = |count: usize| {
            crate::result_store::contains(
                source,
                &replay_key(&first.base_id, &actions[..count]).unwrap(),
            )
        };
        assert!(stored(4) && stored(3) && stored(2));
        assert!(!stored(1), "只留最近 3 个状态");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_longer_request_continues_from_the_shorter_one() {
        let (book, mut request) = setup("第1章 缓存庚\n正文\n第2章 辛\n正文\n");
        replay(book.clone(), None, &request).unwrap();
        request.actions.push(Action::Rename {
            entry_id: book.tree.nodes[1].entry_id.clone(),
            title: "第2章 新名字".into(),
        });
        assert_eq!(
            longest_prefix(&request.base_id, &request.actions)
                .unwrap()
                .0,
            1
        );
        let fresh = effective_edit::apply_stepwise(book.clone(), &request).unwrap();
        let continued = replay(book, None, &request).unwrap();
        assert_eq!(continued.0.text, fresh.0.text);
        assert_eq!(
            effective_edit::base_id(&continued.0),
            effective_edit::base_id(&fresh.0)
        );
        assert_eq!(continued.1, fresh.1);
    }

    #[test]
    fn a_book_that_does_not_match_the_request_is_rejected_not_served_from_cache() {
        let (book, request) = setup("第1章 缓存丙\n正文\n第2章 丁\n正文\n");
        replay(book, None, &request).unwrap();
        let (other, _) = setup("第1章 别的书\n别的正文\n");
        assert!(replay(other, None, &request).is_err());
    }

    #[test]
    fn concurrent_requests_all_get_the_same_answer() {
        let (book, request) = setup("第1章 缓存戊\n正文\n第2章 己\n正文\n");
        let expected = effective_edit::apply(book.clone(), &request).unwrap();
        let id = effective_edit::base_id(&expected.0);
        std::thread::scope(|scope| {
            let handles: Vec<_> = (0..8)
                .map(|_| {
                    let book = book.clone();
                    let request = &request;
                    scope.spawn(move || replay(book, None, request).unwrap())
                })
                .collect();
            for handle in handles {
                assert_eq!(effective_edit::base_id(&handle.join().unwrap().0), id);
            }
        });
        let key = replay_key(&request.base_id, &request.actions).unwrap();
        assert!(!PENDING.lock().unwrap().contains(&key), "算完要放开");
    }
}
