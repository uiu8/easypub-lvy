//! 合成书稿与依据标识缓存（桥接第 2 批）。
//!
//! 一次编辑稿操作会对同一个配方合成好几遍书稿，每遍还要算依据标识
//! （`effective_edit::base_id` 对整本书做哈希）。实测带识别规则的一万章 100 MiB 书，
//! 合成一遍约 270ms、哈希约 100ms，而复制一份已合成的书约 30ms。
//! 合成只由“源快照 + 配方”决定，所以按配方记住：
//! - 标识：最多 32 个，只占几十字节；
//! - 书稿：最近 2 本，合计估算不超过 256 MiB，超出的书只记标识不留书稿。
//!
//! 标识的算法和取值都不变，已存的历史照常可用。键里含源快照的进程内编号
//! （`SourceSnapshot::instance`），不同快照不会串用。
use easypub_core::{ApiError, effective_edit, publication::EffectiveBook};
use sha2::{Digest, Sha256};
use std::sync::{Arc, Mutex};

const CAPACITY: usize = 32;
const BOOK_CAPACITY: usize = 2;
const MAX_BOOK_BYTES: usize = 256 * 1024 * 1024;
static IDS: Mutex<Vec<(String, String)>> = Mutex::new(Vec::new());
static BOOKS: Mutex<Vec<(String, Arc<EffectiveBook>, usize)>> = Mutex::new(Vec::new());

/// 合成书稿在内存里的大致大小：正文、行号对照表与目录节点。
pub(crate) fn estimated_bytes(book: &EffectiveBook) -> usize {
    book.text
        .len()
        .saturating_add(book.source_to_output_lines.len().saturating_mul(32))
        .saturating_add(book.tree.nodes.len().saturating_mul(256))
}

fn cached_book(key: &str) -> Option<Arc<EffectiveBook>> {
    let mut books = BOOKS.lock().unwrap_or_else(|e| e.into_inner());
    let index = books.iter().position(|(k, _, _)| k == key)?;
    let entry = books.remove(index);
    let book = entry.1.clone();
    books.push(entry);
    Some(book)
}

fn keep_book(key: &str, book: &EffectiveBook) {
    let size = estimated_bytes(book);
    if size > MAX_BOOK_BYTES {
        return;
    }
    let mut books = BOOKS.lock().unwrap_or_else(|e| e.into_inner());
    books.retain(|(k, _, _)| k != key);
    while !books.is_empty()
        && (books.len() >= BOOK_CAPACITY
            || books.iter().map(|(_, _, s)| s).sum::<usize>() + size > MAX_BOOK_BYTES)
    {
        books.remove(0);
    }
    books.push((key.to_owned(), Arc::new(book.clone()), size));
}

/// 配方键：各部分依次哈希，部分之间用长度分隔，不会拼接出歧义。
pub(crate) fn recipe_key(parts: &[&[u8]]) -> String {
    let mut hash = Sha256::new();
    hash.update(b"base-identity-v1");
    for part in parts {
        hash.update((part.len() as u64).to_le_bytes());
        hash.update(part);
    }
    format!("{:x}", hash.finalize())
}

fn remembered(key: &str) -> Option<String> {
    let mut ids = IDS.lock().unwrap_or_else(|e| e.into_inner());
    let index = ids.iter().position(|(k, _)| k == key)?;
    let entry = ids.remove(index);
    let id = entry.1.clone();
    ids.push(entry);
    Some(id)
}

fn remember(key: String, id: &str) {
    let mut ids = IDS.lock().unwrap_or_else(|e| e.into_inner());
    ids.retain(|(k, _)| *k != key);
    if ids.len() >= CAPACITY {
        ids.remove(0);
    }
    ids.push((key, id.to_owned()));
}

/// 合成书稿并给出它的依据标识；同一配方第二次起直接复制缓存的书稿，不再合成和哈希。
pub(crate) fn identified(
    key: String,
    compose: impl FnOnce() -> Result<EffectiveBook, ApiError>,
) -> Result<(EffectiveBook, String), ApiError> {
    if let (Some(book), Some(id)) = (cached_book(&key), remembered(&key)) {
        return Ok((EffectiveBook::clone(&book), id));
    }
    let book = compose()?;
    let id = match remembered(&key) {
        Some(id) => id,
        None => {
            let id = effective_edit::base_id(&book);
            remember(key.clone(), &id);
            id
        }
    };
    keep_book(&key, &book);
    Ok((book, id))
}

#[cfg(test)]
mod tests {
    use super::*;
    use easypub_core::{
        publication,
        source::{RULE_ID, SourceSnapshot},
        structure::Structure,
    };

    #[test]
    fn cached_identity_equals_a_fresh_hash_and_keys_do_not_collide() {
        let source =
            SourceSnapshot::from_utf8("第1章 起\n正文\n".as_bytes().to_vec(), RULE_ID, || {
                false
            })
            .unwrap();
        let structure = Structure::new(&source);
        let compose = || publication::compose_with_cleanup(&source, &structure, None, None);
        let key = recipe_key(&[b"test", b"identity-a"]);
        let (book, first) = identified(key.clone(), compose).unwrap();
        assert_eq!(first, effective_edit::base_id(&book));
        // 第二次直接用缓存的书稿：不再调用合成。
        let (again, second) = identified(key, || panic!("should reuse the cached book")).unwrap();
        assert_eq!(first, second);
        assert_eq!(again.text, book.text);
        assert_eq!(effective_edit::base_id(&again), first);
        assert_ne!(recipe_key(&[b"ab", b"c"]), recipe_key(&[b"a", b"bc"]));
    }
}
