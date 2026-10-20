//! 订阅更新先暂存预览；只在确认后提交。版本和提交日志一起原子保存。
use super::*;
use crate::{
    control::{Context, Profile},
    net::{Net, Request},
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};

static WRITER: Mutex<()> = Mutex::new(());

#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct Version {
    hash: String,
    at: u64,
    sources: Vec<(BookSource, bool)>,
}
#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct Preview {
    id: String,
    base: String,
    version: Version,
    diff: Value,
}
#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct Subscription {
    url: String,
    imported_at: u64,
    checked_at: u64,
    startup: bool,
    days: u64,
    versions: Vec<Version>,
    preview: Option<Preview>,
    error: Option<String>,
}
#[derive(Default, Serialize, Deserialize)]
#[serde(default)]
struct Store {
    items: BTreeMap<String, Subscription>,
    /// 完整 sources 快照只用于跨文件提交恢复；正常提交后立即清空。
    pending: Option<Vec<(BookSource, bool)>>,
}

fn path() -> PathBuf {
    state().data.join("subscriptions.json")
}
fn read() -> Result<Store, String> {
    let mut store: Store = match std::fs::read(path()) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map_err(|_| "订阅记录不能读取，请保留文件后检查备份".to_owned()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Store::default()),
        Err(_) => Err("订阅记录不能读取".to_owned()),
    }?;
    if let Some(items) = store.pending.take() {
        let mut st = state();
        st.sources = items;
        st.runtimes.clear();
        save(&st)?;
        drop(st);
        write(&store)?;
    }
    Ok(store)
}
fn write(store: &Store) -> Result<(), String> {
    let mut value = serde_json::to_value(store).map_err(|_| "订阅记录不能保存")?;
    source::sanitize_json(&mut value);
    download::write_atomic(
        &path(),
        &serde_json::to_vec(&value).map_err(|_| "订阅记录不能保存")?,
    )
}
fn snapshot(url: &str) -> Vec<(BookSource, bool)> {
    state()
        .sources
        .iter()
        .filter(|(s, _)| s.meta.file == url)
        .cloned()
        .collect()
}
fn digest(bytes: impl AsRef<[u8]>) -> String {
    hex::encode(Sha256::digest(bytes))
}
fn rule(source: &BookSource) -> Value {
    let mut value = serde_json::to_value(source).unwrap();
    for key in [
        "easypub",
        "enabled",
        "bookSourceGroup",
        "customOrder",
        "weight",
    ] {
        value.as_object_mut().unwrap().remove(key);
    }
    source::sanitize_json(&mut value);
    value
}
fn revision(items: &[(BookSource, bool)]) -> String {
    let map: BTreeMap<_, _> = items
        .iter()
        .map(|(s, _)| (&s.book_source_url, rule(s)))
        .collect();
    digest(serde_json::to_vec(&map).unwrap())
}
fn safe_url(url: &str) -> Result<String, String> {
    let mut u = reqwest::Url::parse(url).map_err(|_| "请输入完整订阅网址")?;
    if !matches!(u.scheme(), "http" | "https") || u.host_str().is_none() {
        return Err("订阅只能使用 http / https 网址".into());
    }
    if !u.username().is_empty()
        || u.password().is_some()
        || u.query_pairs().any(|(k, _)| {
            matches!(
                k.to_ascii_lowercase().as_str(),
                "cookie" | "authorization" | "password" | "proxy-authorization"
            )
        })
    {
        return Err("订阅网址不能携带账号密码或认证字段".into());
    }
    u.set_fragment(None);
    Ok(u.to_string())
}
fn parsed(text: &str, url: &str) -> Result<Vec<(BookSource, bool)>, String> {
    let (sources, _) = source::import(text)?;
    if sources.is_empty() {
        return Err("更新没有可识别的书源，旧版保留".into());
    }
    // 与首次导入一致，同地址最后一条生效；预览公开数量，删除仍需用户确认。
    let sources: BTreeMap<_, _> = sources
        .into_iter()
        .map(|s| (s.book_source_url.clone(), s))
        .collect();
    sources
        .into_values()
        .map(|s| {
            let mut v = serde_json::to_value(s).unwrap();
            source::sanitize_json(&mut v);
            let mut s: BookSource = serde_json::from_value(v).map_err(|_| "书源格式不正确")?;
            s.meta = source::SourceMeta {
                file: url.into(),
                imported_at: now_secs(),
                ..Default::default()
            };
            let enabled = s.enabled && support::check(&s).is_empty();
            Ok((s, enabled))
        })
        .collect()
}
fn diff(old: &[(BookSource, bool)], new: &[(BookSource, bool)]) -> Value {
    let old: BTreeMap<_, _> = old
        .iter()
        .map(|(s, _)| (s.book_source_url.clone(), s))
        .collect();
    let new: BTreeMap<_, _> = new
        .iter()
        .map(|(s, _)| (s.book_source_url.clone(), s))
        .collect();
    let added: Vec<_> = new
        .iter()
        .filter(|(id, _)| !old.contains_key(*id))
        .map(|(id, s)| json!({"id":id,"name":s.book_source_name}))
        .collect();
    let removed: Vec<_> = old
        .iter()
        .filter(|(id, _)| !new.contains_key(*id))
        .map(|(id, s)| json!({"id":id,"name":s.book_source_name}))
        .collect();
    let changed: Vec<_> = new
        .iter()
        .filter_map(|(id, s)| {
            let a = rule(old.get(id)?);
            let b = rule(s);
            let keys: BTreeSet<_> = a.as_object()?.keys().chain(b.as_object()?.keys()).collect();
            let fields: Vec<_> = keys
                .into_iter()
                .filter(|k| a[*k] != b[*k])
                .cloned()
                .collect();
            (!fields.is_empty()).then(|| json!({"id":id,"name":s.book_source_name,"fields":fields}))
        })
        .collect();
    json!({"added":added,"removed":removed,"changed":changed})
}
fn summary(s: &Subscription) -> Value {
    json!({"url":s.url,"importedAt":s.imported_at,"checkedAt":s.checked_at,"startup":s.startup,"days":s.days,
        "hash":s.versions.last().map(|v|&v.hash),"count":s.versions.last().map(|v|v.sources.len()).unwrap_or(0),
        "versions":s.versions.iter().map(|v|json!({"hash":v.hash,"at":v.at,"count":v.sources.len()})).collect::<Vec<_>>(),
        "preview":s.preview.as_ref().map(|p|json!({"id":p.id,"hash":p.version.hash,"diff":p.diff})), "error":s.error})
}
fn ensure<'a>(store: &'a mut Store, url: &str) -> &'a mut Subscription {
    store.items.entry(url.into()).or_insert_with(|| {
        let sources = snapshot(url);
        Subscription {
            url: url.into(),
            imported_at: now_secs(),
            versions: vec![Version {
                hash: revision(&sources),
                at: now_secs(),
                sources,
            }],
            ..Default::default()
        }
    })
}
pub(super) fn load() -> Result<(), String> {
    let _guard = WRITER.lock().unwrap();
    let mut store = read()?;
    if let Some(items) = store.pending.take() {
        let mut st = state();
        st.sources = items;
        st.runtimes.clear();
        save(&st)?;
        drop(st);
        write(&store)?;
    }
    let urls: BTreeSet<_> = state()
        .sources
        .iter()
        .map(|(s, _)| s.meta.file.clone())
        .filter(|s| s.starts_with("http://") || s.starts_with("https://"))
        .collect();
    for url in urls {
        if let Ok(url) = safe_url(&url) {
            ensure(&mut store, &url);
        }
    }
    write(&store)
}
pub(super) fn import(text: &str, url: &str) -> Result<Value, String> {
    let url = safe_url(url)?;
    let _guard = WRITER.lock().unwrap();
    let mut store = read()?;
    if store.items.contains_key(&url) {
        preview(&mut store, &url, text)?;
        return Ok(
            json!({"previewRequired":true,"subscription":summary(&store.items[&url]),"added":0,"total":state().sources.len()}),
        );
    }
    // 初次导入沿用既有容错导入（1316 的一条空记录），后续更新不默默丢条目。
    let result = sources::import_text(text, &url)?;
    let sub = ensure(&mut store, &url);
    sub.versions[0].hash = digest(text.as_bytes());
    write(&store)?;
    Ok(result)
}
fn preview(store: &mut Store, url: &str, text: &str) -> Result<Value, String> {
    let items = parsed(text, url)?;
    let (raw, skipped) = source::import(text)?;
    let old = snapshot(url);
    let mut changes = diff(&old, &items);
    changes["ignored"] =
        json!({"unrecognized":skipped,"duplicates":raw.len().saturating_sub(items.len())});
    let sub = ensure(store, url);
    sub.checked_at = now_secs();
    sub.error = None;
    let hash = digest(text.as_bytes());
    if ["added", "removed", "changed"]
        .iter()
        .all(|k| changes[k].as_array().is_some_and(Vec::is_empty))
    {
        sub.preview = None;
    } else {
        sub.preview = Some(Preview {
            id: format!("{}-{}", now_secs(), &hash[..16]),
            base: revision(&old),
            version: Version {
                hash,
                at: now_secs(),
                sources: items,
            },
            diff: changes,
        });
    }
    let result = summary(sub);
    write(store)?;
    Ok(result)
}
fn fetch(url: &str) -> Result<String, String> {
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return std::fs::read_to_string(url)
            .map_err(|_| "无法读取原书源文件，请重新选择文件导入".into());
    }
    let mut net = Net::new(None, vec![]);
    net.crawl.proxy_mode = "proxy".into();
    let mut ctx = Context::new(Profile::Import, Arc::new(AtomicBool::new(false)));
    ctx.deadline = Some(std::time::Instant::now() + Duration::from_secs(120));
    ctx.interactive = false;
    let _guard = ctx.enter();
    let r = net
        .fetch(&Request {
            url: url.into(),
            method: "GET".into(),
            ..Default::default()
        })
        .map_err(|e| crate::probe::reason(&e.0).to_owned())?;
    if r.status >= 400 {
        return Err(format!("网站返回 {}", r.status));
    }
    Ok(r.text)
}
fn preserve(new: &mut BookSource, enabled: &mut bool, old: &(BookSource, bool)) {
    new.meta = old.0.meta.clone();
    new.enabled = old.1;
    *enabled = old.1;
    new.custom_order = old.0.custom_order;
    new.weight = old.0.weight;
    sources::keep_user_fields(new, &old.0, &sources::import_options());
    new.concurrent_rate = old.0.concurrent_rate.clone();
}
fn commit(
    store: &mut Store,
    url: &str,
    mut items: Vec<(BookSource, bool)>,
    hash: String,
    rollback: bool,
    base: Option<&str>,
) -> Result<(), String> {
    let mut st = state();
    if base.is_some_and(|base| {
        revision(
            &st.sources
                .iter()
                .filter(|(s, _)| s.meta.file == url)
                .cloned()
                .collect::<Vec<_>>(),
        ) != base
    }) {
        return Err("校验期间书源规则已变化，请重新预览".into());
    }
    let current: HashMap<_, _> = st
        .sources
        .iter()
        .filter(|(s, _)| s.meta.file == url)
        .map(|(s, e)| (s.book_source_url.clone(), (s.clone(), *e)))
        .collect();
    for (s, enabled) in &mut items {
        if let Some(old) = current.get(&s.book_source_url) {
            preserve(s, enabled, old);
        } else {
            let duplicate = st
                .sources
                .iter()
                .any(|(x, _)| x.meta.file != url && x.book_source_url == s.book_source_url);
            s.meta.id = if duplicate {
                format!(
                    "{}::{}",
                    s.book_source_url,
                    &digest(format!("{url}\n{}", s.book_source_url))[..12]
                )
            } else {
                s.book_source_url.clone()
            };
        }
        s.meta.file = url.into();
    }
    // 订阅里新出现的书源同样按“新书源位置”排在已有书源的最前或最后。
    if !rollback {
        let fresh: Vec<usize> = (0..items.len())
            .filter(|&i| !current.contains_key(&items[i].0.book_source_url))
            .collect();
        let orders = st
            .sources
            .iter()
            .filter(|(s, _)| s.meta.file != url)
            .map(|(s, _)| s.custom_order)
            .chain(
                (0..items.len())
                    .filter(|i| !fresh.contains(i))
                    .map(|i| items[i].0.custom_order),
            );
        let (top, bottom) = (
            orders.clone().min().unwrap_or(0),
            orders.max().unwrap_or(-1),
        );
        let n = fresh.len() as i64;
        let top_first = sources::import_options().position == "top";
        for (k, &i) in fresh.iter().enumerate() {
            items[i].0.custom_order = if top_first {
                top - n + k as i64
            } else {
                bottom + 1 + k as i64
            };
        }
    }
    let mut next: Vec<_> = st
        .sources
        .iter()
        .filter(|(s, _)| s.meta.file != url)
        .cloned()
        .collect();
    next.extend(items.clone());
    let sub = store.items.get_mut(url).ok_or("订阅不存在")?;
    if rollback {
        sub.versions.pop();
    } else {
        // 把删除前的用户设置保存在历史中，手动恢复新增回来的源仍有原设置。
        if let Some(old) = sub.versions.last_mut() {
            old.sources = current.into_values().collect();
        }
        sub.versions.push(Version {
            hash,
            at: now_secs(),
            sources: items,
        });
        if sub.versions.len() > 3 {
            sub.versions.remove(0);
        }
    }
    sub.preview = None;
    store.pending = Some(next.clone());
    // WRITER -> State；write 使用显式 data 路径，不能再次拿 State 锁。
    let location = st.data.join("subscriptions.json");
    let mut value = serde_json::to_value(&store).unwrap();
    source::sanitize_json(&mut value);
    download::write_atomic(&location, &serde_json::to_vec(&value).unwrap())?;
    st.sources = next;
    st.runtimes.clear();
    save(&st)?;
    drop(st);
    store.pending = None;
    write(store)
}
pub(super) fn handle(method: &str, params: &Value) -> Result<Value, String> {
    let _guard = WRITER.lock().unwrap();
    let mut store = read()?;
    if method == "subscriptions.list" {
        return Ok(json!(store.items.values().map(summary).collect::<Vec<_>>()));
    }
    let input = params["url"]
        .as_str()
        .or(params["file"].as_str())
        .ok_or("缺少订阅网址或原书源文件")?;
    // 文件分组原有的“更新”也必须先预览；仅接受已导入的来源路径。
    // 网址导入仍使用 safe_url，不能借这里放宽 WebView 的协议范围。
    let url = if !input.starts_with("http://")
        && !input.starts_with("https://")
        && (store.items.contains_key(input) || !snapshot(input).is_empty())
    {
        input.to_owned()
    } else {
        safe_url(input)?
    };
    ensure(&mut store, &url);
    match method {
        "subscriptions.configure" => {
            let sub = store.items.get_mut(&url).unwrap();
            sub.startup = params["startup"] == true;
            sub.days = params["days"].as_u64().unwrap_or(0).min(365);
            let result = summary(sub);
            write(&store)?;
            Ok(result)
        }
        "subscriptions.preview" => {
            match fetch(&url).and_then(|text| preview(&mut store, &url, &text)) {
                Ok(v) => Ok(v),
                Err(e) => {
                    let sub = store.items.get_mut(&url).unwrap();
                    sub.error = Some(e.clone());
                    sub.checked_at = now_secs();
                    write(&store)?;
                    Err(e)
                }
            }
        }
        "subscriptions.apply" => {
            let p = store.items[&url].preview.clone().ok_or("请先检查更新")?;
            if params["previewId"] != p.id {
                return Err("预览已过期，请重新检查更新".into());
            }
            let old = snapshot(&url);
            if revision(&old) != p.base {
                return Err("书源规则已变化，请重新预览".into());
            }
            let old: BTreeMap<_, _> = old
                .into_iter()
                .map(|(s, e)| (s.book_source_url.clone(), (s, e)))
                .collect();
            let mut items = p.version.sources;
            let to_check: Vec<_> = items
                .iter()
                .enumerate()
                .filter_map(|(i, (s, _))| {
                    let prev = old.get(&s.book_source_url)?;
                    (rule(s) != rule(&prev.0)
                        && prev.0.meta.check.as_ref().is_some_and(|c| c["ok"] == true))
                    .then_some(i)
                })
                .take(20)
                .collect();
            let results = Mutex::new(Vec::new());
            // 校验候选的个人网络参数，候选执行不污染已用规则或运行时。
            std::thread::scope(|scope| {
                for chunk in to_check.chunks(4) {
                    let handles: Vec<_> = chunk
                        .iter()
                        .map(|&i| {
                            let mut s = items[i].0.clone();
                            let previous = old[&s.book_source_url].clone();
                            let results = &results;
                            let mut enabled = previous.1;
                            preserve(&mut s, &mut enabled, &previous);
                            scope.spawn(move || {
                                let mut ctx =
                                    Context::new(Profile::Detail, Arc::new(AtomicBool::new(false)));
                                ctx.deadline =
                                    Some(std::time::Instant::now() + Duration::from_secs(40));
                                ctx.interactive = false;
                                let _guard = ctx.enter();
                                let mut check = crate::probe::Check::default();
                                let key =
                                    BookSource::rule(&s.rule_search, "checkKeyWord").to_owned();
                                let result = Engine::new(SourceRt::new(s)).and_then(|e| {
                                    crate::probe::check(
                                        &e,
                                        if key.is_empty() { "我的" } else { &key },
                                        &mut check,
                                    )
                                });
                                let cause = check.cause.or_else(|| {
                                    result.as_ref().err().and_then(|e| {
                                        crate::control::ErrorKind::classify(e).cause()
                                    })
                                });
                                if matches!(cause, Some("unsupported" | "rule")) {
                                    results.lock().unwrap().push((i, cause));
                                }
                            })
                        })
                        .collect();
                    for h in handles {
                        h.join().map_err(|_| "订阅校验异常，旧版保留")?;
                    }
                }
                Ok::<_, String>(())
            })?;
            let mut reverted = Vec::new();
            for (i, cause) in results.into_inner().unwrap() {
                let id = items[i].0.book_source_url.clone();
                reverted.push(json!({"id":id,"name":items[i].0.book_source_name,"cause":cause}));
                items[i] = old[&id].clone();
            }
            commit(
                &mut store,
                &url,
                items,
                p.version.hash,
                false,
                Some(&p.base),
            )?;
            Ok(
                json!({"subscription":summary(&store.items[&url]),"reverted":reverted,"checked":to_check.len()}),
            )
        }
        "subscriptions.rollback" => {
            let sub = &store.items[&url];
            if sub.versions.len() < 2 {
                return Err("没有可回退的上一版本".into());
            }
            let version = sub.versions[sub.versions.len() - 2].clone();
            commit(&mut store, &url, version.sources, version.hash, true, None)?;
            Ok(summary(&store.items[&url]))
        }
        _ => Err("不支持的订阅请求".into()),
    }
}
/// 自动检查只产生待确认预览，绝不自动应用删除或规则替换。
pub(super) fn due(startup: bool) {
    let urls = {
        let _guard = WRITER.lock().unwrap();
        let Ok(store) = read() else {
            return;
        };
        store
            .items
            .values()
            .filter(|s| {
                (startup && s.startup)
                    || (s.days > 0 && now_secs().saturating_sub(s.checked_at) >= s.days * 86400)
            })
            .map(|s| s.url.clone())
            .collect::<Vec<_>>()
    };
    for url in urls {
        let _ = handle("subscriptions.preview", &json!({"url":url}));
        send(json!({"event":"subscriptions.changed"}));
    }
}
