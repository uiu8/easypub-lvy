//! 书源只保存在本机；项目仅保存不含凭据的 Catalog 快照。
mod http;
mod rules;

#[cfg(test)]
mod tests;

use super::{
    Catalog, Entry, MAX_BYTES, MAX_ENTRIES, NETWORK, check_cancelled, err, finish, hash, now,
    remember, string,
};
use easypub_core::ApiError;
use rules::{Content, Rule};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet, VecDeque},
    io::Read,
    path::{Path, PathBuf},
    sync::Mutex,
};
use tokio_util::sync::CancellationToken;

const MAX_IMPORT: usize = 16 * 1024 * 1024;
// V45：长篇每页目录只有二三十章时需要几十页；300 页只作防失控上限（“阅读”App 不设页数上限）。
const MAX_PAGES: usize = 300;
static STORAGE: Mutex<()> = Mutex::new(());
type Fields = BTreeMap<String, String>;

#[derive(Clone, Serialize, Deserialize)]
struct Source {
    id: String,
    name: String,
    url: String,
    group: String,
    reason: String,
    revision: String,
    // 不支持的书源只保留名称、来源和原因，不保存原始脚本或凭据。
    spec: Option<Spec>,
}
#[derive(Clone, Serialize, Deserialize)]
struct Spec {
    search: http::Request,
    headers: BTreeMap<String, String>,
    search_rules: Fields,
    info_rules: Fields,
    toc_rules: Fields,
    reverse: bool,
}
struct Compiled {
    search: BTreeMap<String, Rule>,
    info: BTreeMap<String, Rule>,
    toc: BTreeMap<String, Rule>,
}
impl Spec {
    fn compile(&self) -> rules::Result<Compiled> {
        fn group(fields: &Fields) -> rules::Result<BTreeMap<String, Rule>> {
            fields
                .iter()
                .map(|(name, value)| {
                    Ok((
                        name.clone(),
                        Rule::parse(value, name == "bookList" || name == "chapterList")?,
                    ))
                })
                .collect()
        }
        Ok(Compiled {
            search: group(&self.search_rules)?,
            info: group(&self.info_rules)?,
            toc: group(&self.toc_rules)?,
        })
    }
}
fn fields(value: &Value, names: &[&str]) -> rules::Result<Fields> {
    let mut result = Fields::new();
    for name in names {
        match value.get(name) {
            None | Some(Value::Null) => (),
            Some(Value::String(s)) if s.trim().is_empty() => (),
            Some(Value::String(s)) => {
                result.insert((*name).into(), s.clone());
            }
            _ => return Err("book_source_rule_unsupported"),
        }
    }
    Ok(result)
}
fn source_spec(value: &Value, base: &str) -> rules::Result<Spec> {
    if value["enabled"] == false {
        return Err("book_source_disabled");
    }
    if value
        .get("bookSourceType")
        .is_some_and(|v| !v.is_null() && v.as_i64() != Some(0))
    {
        return Err("book_source_type_unsupported");
    }
    if ["loginUrl", "loginUi", "loginCheckJs"]
        .iter()
        .any(|k| value.get(k).is_some_and(|v| !v.is_null() && v != ""))
    {
        return Err("book_source_login_required");
    }
    let search_text = value["searchUrl"]
        .as_str()
        .filter(|s| !s.trim().is_empty())
        .ok_or("book_source_incomplete")?;
    let search = http::Request::parse(search_text)?;
    search.validate(base)?;
    let header = match value.get("header") {
        None | Some(Value::Null) => Value::Null,
        Some(Value::String(s)) if s.trim().is_empty() => Value::Null,
        Some(Value::String(s)) => {
            if rules::requires_js(s) {
                return Err("book_source_javascript_required");
            }
            serde_json::from_str(s).map_err(|_| "book_source_header_unsupported")?
        }
        _ => return Err("book_source_header_unsupported"),
    };
    let headers = http::clean_headers(&header)?;
    for field in [
        &value["ruleBookInfo"]["init"],
        &value["ruleToc"]["formatJs"],
    ] {
        if field.as_str().is_some_and(|s| !s.is_empty()) {
            return Err(
                if field == &value["ruleToc"]["formatJs"]
                    || rules::requires_js(field.as_str().unwrap())
                {
                    "book_source_javascript_required"
                } else {
                    "book_source_rule_unsupported"
                },
            );
        }
    }
    let search_rules = fields(
        &value["ruleSearch"],
        &["bookList", "name", "author", "bookUrl", "lastChapter"],
    )?;
    let info_rules = fields(&value["ruleBookInfo"], &["name", "author", "tocUrl"])?;
    let mut toc_rules = fields(
        &value["ruleToc"],
        &[
            "chapterList",
            "chapterName",
            "chapterUrl",
            "isVolume",
            "nextTocUrl",
        ],
    )?;
    if ["bookList", "name", "bookUrl"]
        .iter()
        .any(|k| !search_rules.contains_key(*k))
        || ["chapterList", "chapterName", "chapterUrl"]
            .iter()
            .any(|k| !toc_rules.contains_key(*k))
    {
        return Err("book_source_incomplete");
    }
    let chapter_list = toc_rules.get_mut("chapterList").unwrap();
    let reverse = chapter_list.trim_start().starts_with('-');
    if reverse {
        *chapter_list = chapter_list
            .trim_start()
            .trim_start_matches('-')
            .trim()
            .into();
    }
    let spec = Spec {
        search,
        headers,
        search_rules,
        info_rules,
        toc_rules,
        reverse,
    };
    spec.compile()?;
    Ok(spec)
}
fn source(value: &Value) -> Result<Source, ApiError> {
    if !value.is_object() {
        return Err(err("book_source_invalid_json"));
    }
    let raw_url = string(value, "bookSourceUrl");
    let name = string(value, "bookSourceName");
    let group = string(value, "bookSourceGroup");
    if raw_url.trim().is_empty()
        || name.len() > 4096
        || raw_url.len() > 16_384
        || group.len() > 4096
    {
        return Err(err("book_source_invalid_json"));
    }
    let url = http::absolute(raw_url.trim(), "").map(|u| u.to_string());
    let spec = match &url {
        Ok(url) => source_spec(value, url),
        Err(_) => Err("book_source_invalid_url"),
    };
    let url = url.unwrap_or_else(|_| {
        // 无效来源仍可列出原因，但不把 URL 中的账号密码落盘或返回。
        if let Ok(mut parsed) = reqwest::Url::parse(&raw_url) {
            let _ = parsed.set_username("");
            let _ = parsed.set_password(None);
            parsed.to_string()
        } else {
            raw_url
        }
    });
    let (spec, reason) = match spec {
        Ok(s) => (Some(s), String::new()),
        Err(e) => (None, e.into()),
    };
    let revision = hash(&serde_json::to_vec(&spec).unwrap());
    Ok(Source {
        id: hash(url.as_bytes()),
        name: if name.is_empty() { url.clone() } else { name },
        url,
        group,
        reason,
        revision,
        spec,
    })
}
fn read_limited(path: &Path, limit: usize) -> Result<Vec<u8>, ApiError> {
    let file = std::fs::File::open(path).map_err(|_| err("book_source_read_failed"))?;
    let mut bytes = Vec::new();
    file.take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| err("book_source_read_failed"))?;
    if bytes.len() > limit {
        return Err(err("book_source_too_large"));
    }
    Ok(bytes)
}
fn load(root: &Path) -> Result<Vec<Source>, ApiError> {
    let path = root.join("sources.json");
    if !path.exists() {
        return Ok(Vec::new());
    }
    serde_json::from_slice(&read_limited(&path, MAX_IMPORT)?)
        .map_err(|_| err("book_source_store_invalid"))
}
fn save(root: &Path, sources: &[Source]) -> Result<(), ApiError> {
    let bytes = serde_json::to_vec(sources).unwrap();
    if bytes.len() > MAX_IMPORT {
        return Err(err("book_source_too_large"));
    }
    std::fs::create_dir_all(root).map_err(|_| err("book_source_write_failed"))?;
    let temp = root.join("sources.tmp");
    std::fs::write(&temp, bytes)
        .and_then(|_| std::fs::rename(&temp, root.join("sources.json")))
        .map_err(|_| err("book_source_write_failed"))
}
fn listing(sources: &[Source]) -> Value {
    json!({"stage":"book_sources", "sources": sources.iter().map(|s| json!({
        "id":s.id, "name":s.name, "url":s.url, "group":s.group,
        "supported":s.spec.is_some(), "reason":s.reason,
    })).collect::<Vec<_>>()})
}
pub(super) fn execute(request: &Value, token: &CancellationToken) -> Result<Value, ApiError> {
    let root =
        std::env::var_os("LOCALAPPDATA").ok_or_else(|| err("book_source_store_unavailable"))?;
    execute_at(
        request,
        token,
        &PathBuf::from(root).join("EasyPubRustFlutter/book-sources-v1"),
    )
}
fn execute_at(request: &Value, token: &CancellationToken, root: &Path) -> Result<Value, ApiError> {
    check_cancelled(token)?;
    let mode = string(request, "source");
    let source = {
        let _storage = STORAGE
            .lock()
            .map_err(|_| err("book_source_store_unavailable"))?;
        let mut sources = if mode == "book_source_clear" {
            Vec::new()
        } else {
            load(root)?
        };
        match mode.as_str() {
            "book_source_list" => return Ok(listing(&sources)),
            "book_source_import" => {
                let bytes = read_limited(Path::new(&string(request, "input")), MAX_IMPORT)?;
                let bytes = bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(&bytes);
                let value: Value =
                    serde_json::from_slice(bytes).map_err(|_| err("book_source_invalid_json"))?;
                let values = if let Value::Array(a) = value {
                    a
                } else {
                    vec![value]
                };
                if values.len() > 4096 {
                    return Err(err("book_source_too_large"));
                }
                let mut by_url: BTreeMap<String, Source> =
                    sources.into_iter().map(|s| (s.url.clone(), s)).collect();
                for value in values {
                    check_cancelled(token)?;
                    let item = source(&value)?;
                    by_url.insert(item.url.clone(), item);
                }
                sources = by_url.into_values().collect();
                if sources.len() > 4096 {
                    return Err(err("book_source_too_large"));
                }
                check_cancelled(token)?;
                save(root, &sources)?;
                return Ok(listing(&sources));
            }
            "book_source_clear" => {
                // 只操作本能力拥有的配置文件及哈希命名缓存，保留未知文件。
                for name in ["sources.json", "sources.tmp"] {
                    let path = root.join(name);
                    if path.exists() {
                        std::fs::remove_file(path).map_err(|_| err("book_source_write_failed"))?;
                    }
                }
                let cache = root.join("cache");
                if cache.is_dir() {
                    for entry in
                        std::fs::read_dir(cache).map_err(|_| err("book_source_write_failed"))?
                    {
                        let entry = entry.map_err(|_| err("book_source_write_failed"))?;
                        let name = entry.file_name().to_string_lossy().into_owned();
                        if name.ends_with(".json")
                            && valid_hash(&name[..name.len() - 5])
                            && entry.file_type().is_ok_and(|t| t.is_file())
                        {
                            std::fs::remove_file(entry.path())
                                .map_err(|_| err("book_source_write_failed"))?;
                        }
                    }
                }
                return Ok(listing(&[]));
            }
            "book_source_search" | "book_source_toc" => (),
            _ => return Err(err("unsupported_source")),
        }
        sources
            .into_iter()
            .find(|s| s.id == string(request, "book_source_id"))
            .ok_or_else(|| err("book_source_not_found"))?
    };
    let spec = source.spec.as_ref().ok_or_else(|| err(&source.reason))?;
    let compiled = spec.compile().map_err(err)?;
    if mode == "book_source_toc" {
        let url = book_url(&source.url, &string(request, "input"))?;
        let path = cache_path(root, &source, &url);
        if request["use_cache"] == true && path.exists() {
            let catalog: Catalog = serde_json::from_slice(&read_limited(&path, MAX_BYTES)?)
                .map_err(|_| err("cache_invalid"))?;
            super::validate_snapshot(&catalog)?;
            if catalog.origin != origin(&source.id, &url) {
                return Err(err("cache_invalid"));
            }
            check_cancelled(token)?;
            let stale = now().saturating_sub(catalog.fetched_at) > 86400;
            let mut value = remember(catalog, true)?;
            value["cache_stale"] = json!(stale);
            return Ok(value);
        }
    }
    let _network = NETWORK.try_lock().map_err(|_| err("network_busy"))?;
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|_| err("network_initialization_failed"))?;
    let client = http::Client::new(spec.headers.clone())?;
    let result = runtime
        .block_on(token.run_until_cancelled(async {
            if mode == "book_source_search" {
                search(
                    &source,
                    spec,
                    &compiled,
                    &client,
                    &string(request, "input"),
                    token,
                )
                .await
            } else {
                let catalog = toc(&source, spec, &compiled, &client, request, token).await?;
                check_cancelled(token)?;
                let path = cache_path(
                    root,
                    &source,
                    &book_url(&source.url, &string(request, "input"))?,
                );
                let cache_saved = {
                    let _storage = STORAGE
                        .lock()
                        .map_err(|_| err("book_source_store_unavailable"))?;
                    let current = load(root)?
                        .into_iter()
                        .any(|s| s.id == source.id && s.revision == source.revision);
                    let bytes = serde_json::to_vec(&catalog).unwrap();
                    current
                        && bytes.len() <= MAX_BYTES
                        && std::fs::create_dir_all(root.join("cache")).is_ok()
                        && std::fs::write(path, bytes).is_ok()
                };
                check_cancelled(token)?;
                let mut value = remember(catalog, false)?;
                value["cache_saved"] = json!(cache_saved);
                Ok(value)
            }
        }))
        .ok_or_else(|| err("catalog_cancelled"))??;
    check_cancelled(token)?;
    Ok(result)
}
fn book_url(base: &str, value: &str) -> Result<String, ApiError> {
    if value.trim().is_empty() {
        return Err(err("book_source_invalid_url"));
    }
    let mut url = http::absolute(base, value)?;
    url.set_fragment(None);
    Ok(url.to_string())
}
fn origin(source_id: &str, url: &str) -> String {
    format!("source:{source_id}|{url}")
}
fn valid_hash(id: &str) -> bool {
    id.len() == 64
        && id
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}
pub(super) fn validate_identity(catalog: &Catalog) -> Result<(), ApiError> {
    let (id, url) = catalog
        .origin
        .strip_prefix("source:")
        .and_then(|s| s.split_once('|'))
        .ok_or_else(|| err("catalog_snapshot_invalid"))?;
    if !valid_hash(id)
        || book_url(url, url)? != url
        || catalog.book_id != hash(catalog.origin.as_bytes())
    {
        return Err(err("catalog_snapshot_invalid"));
    }
    Ok(())
}
fn cache_path(root: &Path, source: &Source, url: &str) -> PathBuf {
    root.join("cache").join(format!(
        "{}.json",
        hash(format!("{}|{}|{url}", source.id, source.revision).as_bytes())
    ))
}
fn value(
    fields: &BTreeMap<String, Rule>,
    key: &str,
    content: &Content,
) -> Result<String, ApiError> {
    fields
        .get(key)
        .map(|r| r.string(content).map_err(err))
        .transpose()
        .map(Option::unwrap_or_default)
}
fn url_value(
    fields: &BTreeMap<String, Rule>,
    key: &str,
    content: &Content,
) -> Result<String, ApiError> {
    Ok(fields
        .get(key)
        .map(|r| r.strings(content).map_err(err))
        .transpose()?
        .unwrap_or_default()
        .into_iter()
        .next()
        .unwrap_or_default())
}
async fn search(
    source: &Source,
    spec: &Spec,
    rules: &Compiled,
    client: &http::Client,
    query: &str,
    token: &CancellationToken,
) -> Result<Value, ApiError> {
    let query = query.trim();
    if query.is_empty() || query.len() > 512 {
        return Err(err("invalid_search_query"));
    }
    let page = client.fetch(&spec.search, &source.url, query).await?;
    let mut books = Vec::new();
    let mut seen = BTreeSet::new();
    for node in rules.search["bookList"].nodes(&page.content).map_err(err)? {
        check_cancelled(token)?;
        let name = super::clean(&value(&rules.search, "name", &node)?);
        let url = url_value(&rules.search, "bookUrl", &node)?;
        if name.is_empty() || url.is_empty() {
            return Err(err("book_source_parse_failed"));
        }
        let url = book_url(&page.url, &url)?;
        if !seen.insert(url.clone()) {
            continue;
        }
        books.push(json!({"book_id": hash(origin(&source.id, &url).as_bytes()), "title":name,
            "url":url, "author":author_name(&super::clean(&value(&rules.search,"author",&node)?)),
            "last_chapter":super::clean(&value(&rules.search,"lastChapter",&node)?), "book_source_id":source.id}));
        if books.len() == 50 {
            break;
        }
    }
    Ok(json!({"stage":"search_results", "books":books}))
}
async fn toc(
    source: &Source,
    spec: &Spec,
    rules: &Compiled,
    client: &http::Client,
    request: &Value,
    token: &CancellationToken,
) -> Result<Catalog, ApiError> {
    let url = book_url(&source.url, &string(request, "input"))?;
    let detail = client
        .fetch(&http::Request::parse(&url).map_err(err)?, &url, "")
        .await?;
    let mut title = super::clean(&value(&rules.info, "name", &detail.content)?);
    let mut author = author_name(&super::clean(&value(
        &rules.info,
        "author",
        &detail.content,
    )?));
    if title.is_empty() {
        title = string(request, "title");
    }
    if author.is_empty() {
        author = string(request, "author");
    }
    let toc_url = url_value(&rules.info, "tocUrl", &detail.content)?;
    let first = if toc_url.is_empty() {
        detail
    } else {
        client
            .fetch(
                &http::Request::parse(&toc_url).map_err(err)?,
                &detail.url,
                "",
            )
            .await?
    };
    let mut pending = VecDeque::new();
    let mut page = Some(first);
    let mut visited = BTreeSet::new();
    let mut scheduled = BTreeSet::new();
    let mut entries: Vec<Entry> = Vec::new();
    let mut identities: BTreeMap<String, (String, String)> = BTreeMap::new();
    let mut volume = String::new();
    let mut volume_id = String::new();
    let mut volume_serial = 0;
    let mut pages = 0;
    while let Some(current) = page.take() {
        check_cancelled(token)?;
        if !visited.insert(current.url.clone()) {
            return Err(err("book_source_page_cycle"));
        }
        pages += 1;
        for node in rules.toc["chapterList"]
            .nodes(&current.content)
            .map_err(err)?
        {
            check_cancelled(token)?;
            let name = super::clean(&value(&rules.toc, "chapterName", &node)?);
            let is_volume = value(&rules.toc, "isVolume", &node)?
                .trim()
                .to_ascii_lowercase();
            if !["", "false", "0", "null"].contains(&is_volume.as_str()) {
                if name.is_empty() {
                    return Err(err("book_source_parse_failed"));
                }
                if volume != name {
                    volume = name;
                    volume_serial += 1;
                    volume_id = format!("source-volume:{volume_serial}");
                }
                continue;
            }
            let chapter_url = url_value(&rules.toc, "chapterUrl", &node)?;
            if name.is_empty() || chapter_url.is_empty() {
                return Err(err("book_source_parse_failed"));
            }
            let chapter_url = http::absolute(&current.url, &chapter_url)?.to_string();
            if let Some(previous) = identities.get(&chapter_url) {
                if previous != &(name.clone(), volume.clone()) {
                    return Err(err("book_source_conflicting_chapter"));
                }
                continue;
            }
            identities.insert(chapter_url.clone(), (name.clone(), volume.clone()));
            entries.push(Entry {
                id: hash(chapter_url.as_bytes()),
                title: name,
                volume_id: volume_id.clone(),
                volume: volume.clone(),
                structural_volume: super::structural_volume(&volume),
                volume_kind: super::volume_kind(&volume).into(),
            });
            if entries.len() > MAX_ENTRIES {
                return Err(err("catalog_too_large"));
            }
        }
        if let Some(next) = rules.toc.get("nextTocUrl") {
            for link in next.strings(&current.content).map_err(err)? {
                if link.trim().is_empty() {
                    continue;
                }
                let next = book_url(&current.url, &link)?;
                // 与“阅读”一致：翻页下拉常把全部页（含当前页）都列出来，抓过或已排队的跳过。
                if visited.contains(&next) {
                    continue;
                }
                if scheduled.insert(next.clone()) {
                    pending.push_back(next);
                }
            }
        }
        if let Some(next) = pending.pop_front() {
            if pages >= MAX_PAGES {
                return Err(err("book_source_page_limit"));
            }
            page = Some(
                client
                    .fetch(&http::Request::parse(&next).map_err(err)?, &current.url, "")
                    .await?,
            );
        }
    }
    if spec.reverse {
        entries.reverse();
    }
    let origin = origin(&source.id, &url);
    finish(Catalog {
        id: String::new(),
        book_id: hash(origin.as_bytes()),
        title,
        author,
        origin,
        fetched_at: now(),
        total: None,
        completeness: String::new(),
        entries,
    })
}

/// 作者名去掉开头的“作者：”与结尾的“ 著”，与“阅读”App 的 formatBookAuthor 相同（V45）。
fn author_name(raw: &str) -> String {
    static PATTERN: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let name = PATTERN
        .get_or_init(|| regex::Regex::new(r"^\s*作\s*者[\s:：]*|\s+著$").unwrap())
        .replace_all(raw, "");
    // 去掉后为空（例如作者名就是“作者”）时保留原文。
    match name.trim() {
        "" => raw.trim().to_string(),
        name => name.to_string(),
    }
}

#[cfg(test)]
#[test]
fn author_name_matches_legado() {
    assert_eq!(author_name("作者：爱潜水的乌贼"), "爱潜水的乌贼");
    assert_eq!(author_name(" 作 者: 林沉舟 "), "林沉舟");
    assert_eq!(author_name("天蚕土豆 著"), "天蚕土豆");
    assert_eq!(author_name("作者"), "作者");
    assert_eq!(author_name("林作者"), "林作者");
}
