//! V107 章节缓存位置：按书名命名、旧位置自动搬、换位置整体搬移。
//! 缓存根目录是进程级设置，所以放在单独的测试进程里，并且只用一个测试函数。
use easypub_booksource::{download, webbook::Book};
use std::path::Path;

fn book(name: &str, author: &str, url: &str) -> Book {
    Book {
        name: name.into(),
        author: author.into(),
        book_url: url.into(),
        origin: "https://example.invalid".into(),
        ..Default::default()
    }
}

fn write_chapter(dir: &Path, text: &str) {
    std::fs::create_dir_all(dir).unwrap();
    std::fs::write(dir.join("00000.txt"), text).unwrap();
    std::fs::write(dir.join("toc.json"), "[]").unwrap();
}

#[test]
fn cache_names_legacy_migration_and_relocation() {
    let root = std::env::temp_dir().join(format!(
        "easypub-v107-cache-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let downloads = root.join("下载");
    let cache = root.join("缓存");
    let a = book("雾港来信", "某某", "/book/1");
    let b = book("雾港来信", "某某", "/book/2");

    // 没设根目录时沿用下载文件夹里的 .easypub-cache，文件夹名用书名、作者和编号。
    download::set_cache_root(None);
    let legacy_named = download::cache_dir(&downloads, &a);
    assert_eq!(
        legacy_named.parent().unwrap(),
        downloads.join(".easypub-cache")
    );
    let name = download::cache_name(&a);
    assert!(name.starts_with("雾港来信 - 某某 ["), "{name}");
    assert_ne!(name, download::cache_name(&b), "同名的两本书靠编号区分");

    // 旧版缓存（下载文件夹里的 16 位编号）第一次用到时搬到新位置并改名，旧外层文件夹去掉。
    let legacy_root = downloads.join(".easypub-cache");
    let legacy = legacy_root.join(legacy_key(&a));
    write_chapter(&legacy, "第一章正文");
    download::set_cache_root(Some(cache.clone()));
    let moved = download::cache_dir(&downloads, &a);
    assert_eq!(moved, cache.join(&name));
    assert_eq!(
        std::fs::read_to_string(moved.join("00000.txt")).unwrap(),
        "第一章正文"
    );
    assert!(!legacy.exists());
    assert!(!legacy_root.exists(), "旧位置搬空后去掉");

    // 书名改了也按编号找回原来的缓存，不另开一份。
    let renamed = book("雾港来信（修订）", "某某", "/book/1");
    assert_eq!(download::cache_dir(&downloads, &renamed), moved);

    // 换位置：整体搬过去，旧位置搬空后删除；新位置不能在旧位置里面。
    let elsewhere = root.join("别处");
    assert!(download::relocate_cache(&cache, &cache.join("子")).is_err());
    let (count, kept) = download::relocate_cache(&cache, &elsewhere).unwrap();
    assert_eq!((count, kept.len()), (1, 0));
    assert!(!cache.exists());
    assert_eq!(
        std::fs::read_to_string(elsewhere.join(&name).join("00000.txt")).unwrap(),
        "第一章正文"
    );
    download::set_cache_root(Some(elsewhere.clone()));
    assert_eq!(download::cache_dir(&downloads, &a), elsewhere.join(&name));

    download::set_cache_root(None);
    std::fs::remove_dir_all(root).unwrap();
}

/// 旧版缓存文件夹名：来源与书址的 SHA-256 前 16 位。
fn legacy_key(book: &Book) -> String {
    use sha2::{Digest, Sha256};
    let key = hex::encode(Sha256::digest(format!(
        "{}\n{}",
        book.origin, book.book_url
    )));
    key[..16].to_owned()
}
