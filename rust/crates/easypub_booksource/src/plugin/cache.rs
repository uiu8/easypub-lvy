//! 章节缓存位置（V107）：默认在插件数据目录的 `chapter-cache`，可在设置里另选；
//! 换位置时把已有缓存一起搬过去。追更要用这些缓存，所以不放进可随手清理的临时缓存。
use super::*;

fn location_path() -> PathBuf {
    state().data.join("cache-location.json")
}
fn default_root() -> PathBuf {
    state().data.join("chapter-cache")
}
fn custom() -> Option<PathBuf> {
    let bytes = std::fs::read(location_path()).ok()?;
    let value: Value = serde_json::from_slice(&bytes).ok()?;
    value["path"]
        .as_str()
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .map(PathBuf::from)
}
fn root() -> PathBuf {
    custom().unwrap_or_else(default_root)
}
pub(super) fn load() {
    download::set_cache_root(Some(root()));
}
/// 书架里每本书的缓存提前搬到新位置（旧版放在下载文件夹里的 `.easypub-cache`）。
pub(super) fn migrate_library() {
    for record in load_library() {
        if let (Ok(book), Ok(options)) = (
            serde_json::from_value::<Book>(record["book"].clone()),
            serde_json::from_value::<Options>(record["options"].clone()),
        ) {
            let _ = download::cache_dir(&options.folder, &book);
        }
    }
}
fn size(dir: &std::path::Path) -> u64 {
    std::fs::read_dir(dir)
        .map(|entries| {
            entries
                .flatten()
                .map(|e| match e.metadata() {
                    Ok(m) if m.is_dir() => size(&e.path()),
                    Ok(m) => m.len(),
                    Err(_) => 0,
                })
                .sum()
        })
        .unwrap_or(0)
}
fn info() -> Value {
    let root = root();
    let books = std::fs::read_dir(&root)
        .map(|e| e.flatten().filter(|e| e.path().is_dir()).count())
        .unwrap_or(0);
    json!({
        "path": root,
        "defaultPath": default_root(),
        "custom": custom().is_some(),
        "bytes": size(&root),
        "books": books,
    })
}
pub(super) fn handle(method: &str, params: &Value) -> Result<Value, String> {
    match method {
        "cache.location.get" => Ok(info()),
        "cache.location.set" => {
            let target = params["path"]
                .as_str()
                .map(str::trim)
                .filter(|p| !p.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(default_root);
            if !target.is_absolute() {
                return Err("请选择完整的文件夹路径".into());
            }
            let current = root();
            if target == current {
                return Ok(info());
            }
            if !state().tasks.is_empty() {
                return Err("有下载或追更正在进行，请等它完成或暂停后再换位置".into());
            }
            let (moved, kept) = download::relocate_cache(&current, &target)?;
            if target == default_root() {
                let _ = std::fs::remove_file(location_path());
            } else {
                download::write_atomic(
                    &location_path(),
                    &serde_json::to_vec(&json!({"path": target})).unwrap(),
                )?;
            }
            download::set_cache_root(Some(target));
            let mut result = info();
            result["moved"] = json!(moved);
            result["kept"] = json!(kept);
            Ok(result)
        }
        _ => Err("未知的缓存操作".into()),
    }
}
