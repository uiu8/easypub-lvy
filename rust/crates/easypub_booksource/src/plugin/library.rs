//! 下载记录与不联网整理。只在用户明确调用 rebuild 时替换成品，并先备份。
use super::*;
static LIBRARY: Mutex<()> = Mutex::new(());
struct Maintenance(Vec<PathBuf>);
impl Maintenance {
    fn acquire(path: PathBuf, cache: PathBuf) -> Result<Self, String> {
        let paths = vec![path, cache];
        let mut st = state();
        if st.queue.iter().any(|t| {
            st.tasks.contains_key(&t.id)
                && queue::resources(&t.params)
                    .iter()
                    .any(|p| paths.contains(p))
        }) {
            return Err("这本书正在下载，请暂停后再操作".into());
        }
        st.maintenance_paths.extend(paths.iter().cloned());
        Ok(Self(paths))
    }
}
impl Drop for Maintenance {
    fn drop(&mut self) {
        state().maintenance_paths.retain(|p| !self.0.contains(p));
        queue::schedule();
    }
}
fn library_path() -> PathBuf {
    state().data.join("library.json")
}

pub(super) fn load_library() -> Vec<Value> {
    std::fs::read_to_string(library_path())
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

pub(super) fn save_library(records: &[Value]) -> Result<(), String> {
    let path = library_path();
    std::fs::create_dir_all(path.parent().unwrap()).map_err(|_| "无法创建下载记录目录")?;
    let mut value = json!(records);
    source::sanitize_json(&mut value);
    download::write_atomic(&path, &serde_json::to_vec(&value).unwrap_or_default())
}

pub(super) fn record_download(
    id: &str,
    book: &Book,
    options: &Options,
    toc: &[Chapter],
    path: &std::path::Path,
) -> Result<(), String> {
    let _guard = LIBRARY.lock().unwrap();
    let key = format!("{}\n{}", book.origin, book.book_url);
    let mut records = load_library();
    let source_name = find_source(&state(), id)
        .map(|s| s.book_source_name.trim().to_owned())
        .unwrap_or_default();
    let mut saved_options = options.clone();
    saved_options.retry_failed.clear();
    let record = json!({
        "key": key, "sourceId": id, "sourceName": source_name, "book": book, "options": saved_options,
        "path": path, "toc": toc, "chapters": toc.iter().filter(|c| !c.is_volume).count(),
        "latest": toc.iter().rev().find(|c| !c.is_volume).map(|c| c.title.clone()).unwrap_or_default(),
        "updatedAt": now_secs(), "newChapters": 0,
    });
    records.retain(|r| r["key"] != key.as_str());
    records.insert(0, record);
    save_library(&records)
}

/// 书架定时检查更新：hours 为 0 时关闭（默认）；只检查并通知，不自动下载。
#[derive(Clone, Debug, Default, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub(super) struct AutoCheck {
    pub hours: u64,
    pub concurrency: u64,
    pub last_checked: u64,
}
fn auto_path() -> PathBuf {
    state().data.join("library-auto.json")
}
fn read_auto() -> AutoCheck {
    std::fs::read(auto_path())
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}
pub(super) fn auto_check(method: &str, params: &Value) -> Result<Value, String> {
    let mut auto = read_auto();
    if method == "library.autoCheck.set" {
        let hours = params["hours"].as_u64().unwrap_or(0);
        if hours > 24 * 30 {
            return Err("定时检查间隔最多 720 小时".into());
        }
        auto.hours = hours;
        auto.concurrency = params["concurrency"].as_u64().unwrap_or(2).clamp(1, 8);
        download::write_atomic(&auto_path(), &serde_json::to_vec(&auto).unwrap())?;
    }
    Ok(json!(auto))
}
/// 后台每分钟调用一次；到期就检查整个书架，结果发 library.autoChecked 事件。
pub(super) fn auto_due() {
    let mut auto = read_auto();
    if auto.hours == 0 || now_secs().saturating_sub(auto.last_checked) < auto.hours * 3600 {
        return;
    }
    auto.last_checked = now_secs();
    if download::write_atomic(&auto_path(), &serde_json::to_vec(&auto).unwrap()).is_err() {
        return;
    }
    let mut context = crate::control::Context::new(
        crate::control::Profile::Detail,
        Arc::new(AtomicBool::new(false)),
    );
    context.interactive = false;
    let _guard = context.enter();
    if let Ok(r) = check_library(&json!({"concurrency":auto.concurrency.max(1)})) {
        send(
            json!({"event":"library.autoChecked","newChapters":r["newChapters"],
            "changedBooks":r["changedBooks"],"errors":r["errors"]}),
        );
    }
}

/// 追更与缓存迁移使用相同的目录身份规则；网络请求不占书架锁。
pub(super) fn check_library(params: &Value) -> Result<Value, String> {
    let keys: Option<Vec<String>> = params
        .get("keys")
        .and_then(|v| serde_json::from_value(v.clone()).ok());
    // 同时检查几本（“检查更新并发”，默认 2）；各书源自己的站点限速仍然有效。
    let concurrency = params["concurrency"].as_u64().unwrap_or(2).clamp(1, 8) as usize;
    let mut records = load_library();
    let originals = records.clone();
    let todo: Vec<usize> = records
        .iter()
        .enumerate()
        .filter(|(_, r)| {
            keys.as_ref()
                .is_none_or(|k| k.iter().any(|x| r["key"] == x.as_str()))
                && serde_json::from_value::<Book>(r["book"].clone()).is_ok()
        })
        .map(|(i, _)| i)
        .collect();
    let checked: Vec<Value> = todo.iter().map(|&i| records[i]["key"].clone()).collect();
    let next = std::sync::atomic::AtomicUsize::new(0);
    let results = Mutex::new(Vec::new());
    let context = crate::control::current();
    std::thread::scope(|scope| {
        for _ in 0..concurrency.min(todo.len()) {
            let (records, todo, next, results, context) =
                (&records, &todo, &next, &results, context.clone());
            scope.spawn(move || {
                let _guard = context.enter();
                loop {
                    let n = next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    let Some(&i) = todo.get(n) else { return };
                    let r = &records[i];
                    let id = r["sourceId"].as_str().unwrap_or("").to_owned();
                    let mut book: Book = serde_json::from_value(r["book"].clone()).unwrap();
                    let result = with_engine(&id, |e| {
                        e.run(|s| {
                            if book.toc_url.is_empty() {
                                s.book_info(&mut book)?;
                            }
                            s.toc(&book)
                        })
                    });
                    send(json!({ "event": "library.progress", "key": r["key"] }));
                    results.lock().unwrap().push((i, result));
                }
            });
        }
    });
    for (i, result) in results.into_inner().unwrap() {
        let r = &mut records[i];
        match result {
            Ok(toc) => {
                let old: Vec<Chapter> =
                    serde_json::from_value(r["toc"].clone()).unwrap_or_default();
                let changes = crate::catalogue::compare(&old, &toc).changes;
                r["newChapters"] = json!(changes.added);
                r["catalogChanged"] = json!(changes.changed());
                r["catalogChanges"] = json!(changes);
                r["onlineToc"] = json!(toc);
                r["latestOnline"] = json!(
                    toc.iter()
                        .rev()
                        .find(|c| !c.is_volume)
                        .map(|c| c.title.clone())
                        .unwrap_or_default()
                );
                r["checkError"] = Value::Null;
            }
            Err(e) => r["checkError"] = json!(e),
        }
        r["checkedAt"] = json!(now_secs());
    }
    let _guard = LIBRARY.lock().unwrap();
    let mut current = load_library();
    for (original, changed) in originals.iter().zip(&records) {
        if checked.contains(&changed["key"])
            && let Some(record) = current.iter_mut().find(|r| r["key"] == changed["key"])
            && record == original
        {
            for key in [
                "newChapters",
                "latestOnline",
                "checkError",
                "checkedAt",
                "onlineToc",
                "catalogChanged",
                "catalogChanges",
            ] {
                record[key] = changed[key].clone();
            }
        }
    }
    save_library(&current)?;
    let found: u64 = current
        .iter()
        .map(|r| r["newChapters"].as_u64().unwrap_or(0))
        .sum();
    let changed = current
        .iter()
        .filter(|r| r["catalogChanged"] == true)
        .count();
    let errors = current
        .iter()
        .filter(|r| !r["checkError"].is_null())
        .count();
    Ok(
        json!({ "records": current, "newChapters": found, "changedBooks": changed, "errors": errors }),
    )
}

pub(super) fn rebuild(params: &Value) -> Result<Value, String> {
    let key = param::<String>(params, "key")?;
    let _guard = LIBRARY.lock().unwrap();
    let mut records = load_library();
    let record = records
        .iter_mut()
        .find(|r| r["key"] == key)
        .ok_or("没有这条下载记录")?;
    let book: Book =
        serde_json::from_value(record["book"].clone()).map_err(|_| "下载记录缺少书籍信息")?;
    let options: Options =
        serde_json::from_value(record["options"].clone()).map_err(|_| "下载记录缺少下载设置")?;
    let path = PathBuf::from(record["path"].as_str().ok_or("下载记录缺少 TXT 路径")?);
    let cache = download::cache_dir(&options.folder, &book);
    let _maintenance = Maintenance::acquire(path.clone(), cache.clone())?;
    let toc: Vec<Chapter> = serde_json::from_value(record["toc"].clone())
        .ok()
        .or_else(|| {
            std::fs::read(cache.join("toc.json"))
                .ok()
                .and_then(|b| serde_json::from_slice(&b).ok())
        })
        .map(Ok)
        .unwrap_or_else(|| {
            download::legacy_toc(&path, record["chapters"].as_u64().unwrap_or(0) as usize)
        })?;
    if toc.is_empty() {
        return Err("没有可重新整理的目录".into());
    }
    let mut backup = path.with_extension("bak.txt");
    if backup.exists() {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        backup = path.with_extension(format!("{stamp}.bak.txt"));
    }
    let quality = download::assemble(&book, &toc, &options, &path, Some(&backup))?;
    record["quality"] = json!(quality);
    record["rebuiltAt"] = json!(now_secs());
    // 旧目录只能用于本地重建，地址为空时不伪装成可联网的目录。
    save_library(&records)?;
    Ok(json!({"path":path,"quality":quality,"backup":backup}))
}

pub(super) fn remove(params: &Value) -> Result<Value, String> {
    let key = param::<String>(params, "key")?;
    let _guard = LIBRARY.lock().unwrap();
    let mut records = load_library();
    if let Some(record) = records.iter().find(|r| r["key"] == key) {
        let path = PathBuf::from(record["path"].as_str().ok_or("下载记录缺少 TXT 路径")?);
        let book: Book = param(record, "book")?;
        let options: Options = param(record, "options")?;
        let cache = download::cache_dir(&options.folder, &book);
        let _maintenance = Maintenance::acquire(path, cache.clone())?;
        if params["deleteCache"] == true && cache.is_dir() {
            std::fs::remove_dir_all(cache).map_err(|_| "缓存正在使用，无法删除")?;
        }
    }
    records.retain(|r| r["key"] != key);
    save_library(&records)?;
    Ok(Value::Null)
}
