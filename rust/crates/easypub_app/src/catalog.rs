//! Catalog acquisition and review. Credentials never enter serializable state.
use crate::{
    sessions::ImportService,
    transaction::{InjectFault, apply_new_file_bytes},
};
use easypub_core::{ApiError, ErrorCode, source::SourceSnapshot};
use regex::Regex;
use scraper::{Html, Selector};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    io::Read,
    path::PathBuf,
    sync::{Mutex, OnceLock},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

#[path = "book_sources/mod.rs"]
mod book_sources;

const MAX_BYTES: usize = 8 * 1024 * 1024;
const MAX_ENTRIES: usize = 30_000;
static CATALOGS: OnceLock<Mutex<BTreeMap<String, Catalog>>> = OnceLock::new();
static NETWORK: Mutex<()> = Mutex::new(());
static REQUESTS: OnceLock<Mutex<BTreeMap<String, tokio_util::sync::CancellationToken>>> =
    OnceLock::new();
static REQUEST_SERIAL: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

fn begin_request() -> Result<Value, ApiError> {
    let mut requests = REQUESTS
        .get_or_init(Default::default)
        .lock()
        .map_err(|_| err("catalog_busy"))?;
    if requests.len() >= 64 {
        return Err(err("catalog_busy"));
    }
    let id = format!(
        "catalog-{}",
        REQUEST_SERIAL.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    );
    requests.insert(id.clone(), tokio_util::sync::CancellationToken::new());
    Ok(json!({"request_id": id}))
}
fn cancel_request(id: &str) -> Result<Value, ApiError> {
    if let Some(token) = REQUESTS
        .get_or_init(Default::default)
        .lock()
        .map_err(|_| err("catalog_busy"))?
        .remove(id)
    {
        token.cancel();
    }
    Ok(json!({"cancelled": true}))
}
fn request_token(request: &Value) -> Result<tokio_util::sync::CancellationToken, ApiError> {
    if request.get("request_id").is_none() {
        return Ok(tokio_util::sync::CancellationToken::new());
    }
    REQUESTS
        .get_or_init(Default::default)
        .lock()
        .map_err(|_| err("catalog_busy"))?
        .get(&string(request, "request_id"))
        .cloned()
        .ok_or_else(|| err("catalog_cancelled"))
}
fn check_cancelled(token: &tokio_util::sync::CancellationToken) -> Result<(), ApiError> {
    if token.is_cancelled() {
        Err(err("catalog_cancelled"))
    } else {
        Ok(())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Entry {
    pub id: String,
    pub title: String,
    pub volume_id: String,
    pub volume: String,
    pub structural_volume: bool,
    pub volume_kind: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Catalog {
    pub id: String,
    pub book_id: String,
    pub title: String,
    pub author: String,
    pub origin: String,
    pub fetched_at: u64,
    pub total: Option<usize>,
    pub completeness: String,
    pub entries: Vec<Entry>,
}
fn err(reason: &str) -> ApiError {
    ApiError::new(ErrorCode::InvalidRule, "catalog", reason)
}
fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
fn string(v: &Value, key: &str) -> String {
    v.get(key)
        .map(|v| {
            v.as_str()
                .map(str::to_owned)
                .unwrap_or_else(|| v.to_string())
        })
        .unwrap_or_default()
}
fn sel(s: &str) -> Selector {
    Selector::parse(s).expect("static selector")
}
fn clean(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}
fn key(s: &str) -> String {
    s.chars().filter(|c| !c.is_whitespace()).collect()
}
/// Qidian's display groups are not automatically book structure. Generic
/// groups gate VIP/access presentation and must not create a volume boundary.
fn volume_kind(title: &str) -> &'static str {
    let normalized = key(title).trim_matches(['·', '-', '_']).to_owned();
    if normalized.is_empty() {
        return "unknown";
    }
    let access = [
        "正文卷",
        "VIP章节",
        "VIP",
        "免费章节",
        "付费章节",
        "收费章节",
    ];
    if access
        .iter()
        .any(|item| normalized.eq_ignore_ascii_case(item))
    {
        return "access";
    }
    let auxiliary = [
        "作品相关",
        "上架感言",
        "番外",
        "楔子",
        "序章",
        "尾声",
        "后记",
        "完本感言",
    ];
    if auxiliary
        .iter()
        .any(|item| normalized.eq_ignore_ascii_case(item))
    {
        return "auxiliary";
    }
    "structural"
}
fn structural_volume(title: &str) -> bool {
    volume_kind(title) == "structural"
}
fn finish(mut c: Catalog) -> Result<Catalog, ApiError> {
    if c.entries.is_empty() {
        return Err(err("parse_failed_no_catalog_entries"));
    }
    if c.title.len() > 4096
        || c.author.len() > 4096
        || c.origin.len() > 32768
        || c.entries.len() > MAX_ENTRIES
        || c.entries.iter().any(|e| {
            e.title.is_empty()
                || e.title.len() > 4096
                || e.title.contains(['\r', '\n'])
                || e.volume.len() > 4096
                || e.volume.contains(['\r', '\n'])
                || e.id.len() > 256
                || e.volume_id.len() > 256
                || !["structural", "access", "auxiliary", "unknown"]
                    .contains(&e.volume_kind.as_str())
                || e.structural_volume != (e.volume_kind == "structural")
        })
    {
        return Err(err("catalog_too_large"));
    }
    let mut ids = BTreeSet::new();
    if c.entries
        .iter()
        .any(|e| e.id.is_empty() || !ids.insert(&e.id))
    {
        return Err(err("duplicate_catalog_identity"));
    }
    c.completeness = match c.total {
        Some(n) if n == c.entries.len() => "complete",
        Some(n) if n > c.entries.len() => "partial",
        Some(_) => "inconsistent",
        None => "unknown",
    }
    .into();
    c.id = hash(
        &serde_json::to_vec(&(
            &c.book_id, &c.title, &c.author, &c.origin, c.total, &c.entries,
        ))
        .unwrap(),
    );
    Ok(c)
}

pub fn validate_snapshot(c: &Catalog) -> Result<(), ApiError> {
    let validated = finish(c.clone())?;
    if c.id != validated.id || c.completeness != validated.completeness {
        return Err(err("catalog_snapshot_invalid"));
    }
    if c.origin.starts_with("source:") {
        book_sources::validate_identity(c)?;
    } else if !c.book_id.is_empty() {
        let (url, id) = book_url(&c.origin)?;
        if url != c.origin || id != c.book_id {
            return Err(err("catalog_snapshot_invalid"));
        }
    } else if c.origin != "paste" && !c.origin.starts_with("local:") {
        return Err(err("catalog_snapshot_invalid"));
    }
    Ok(())
}
pub fn parse_text(
    text: &str,
    title: &str,
    author: &str,
    origin: &str,
    total: Option<usize>,
) -> Result<Catalog, ApiError> {
    parse_text_cancellable(
        text,
        title,
        author,
        origin,
        total,
        &tokio_util::sync::CancellationToken::new(),
    )
}
fn parse_text_cancellable(
    text: &str,
    title: &str,
    author: &str,
    origin: &str,
    total: Option<usize>,
    token: &tokio_util::sync::CancellationToken,
) -> Result<Catalog, ApiError> {
    check_cancelled(token)?;
    if text.len() > MAX_BYTES {
        return Err(err("catalog_too_large"));
    }
    let volume = Regex::new(r"^第[^\s]{1,16}[卷部篇集季幕辑册](?:\s|$|[:：]).*").unwrap();
    let chapter = Regex::new(r"^(?:第[^\s]{1,16}[章节回]|[0-9]{1,8}[.、\s]).*").unwrap();
    let mut entries = Vec::new();
    let mut current = String::new();
    let mut volume_id = String::new();
    let mut current_structural = false;
    for (i, line) in text.lines().enumerate() {
        check_cancelled(token)?;
        let markdown_group = line.trim().starts_with("## ");
        let line = line.trim().trim_start_matches('#').trim();
        if volume.is_match(line) || (markdown_group && !chapter.is_match(line)) {
            if line.len() > 4096 {
                return Err(err("catalog_too_large"));
            }
            current = line.to_owned();
            volume_id = format!("volume:{}", i + 1);
            current_structural = structural_volume(line);
        } else if chapter.is_match(line) {
            if line.len() > 4096 || entries.len() >= MAX_ENTRIES {
                return Err(err("catalog_too_large"));
            }
            entries.push(Entry {
                id: format!("line:{}", i + 1),
                title: line.into(),
                volume_id: volume_id.clone(),
                volume: current.clone(),
                structural_volume: current_structural,
                volume_kind: volume_kind(&current).into(),
            });
        }
    }
    finish(Catalog {
        id: String::new(),
        book_id: String::new(),
        title: title.trim().into(),
        author: author.trim().into(),
        origin: origin.into(),
        fetched_at: now(),
        total,
        completeness: String::new(),
        entries,
    })
}

pub fn parse_qidian(html: &str, book_id: &str, origin: &str) -> Result<Catalog, ApiError> {
    let doc = Html::parse_document(html);
    let mut entries = Vec::new();
    let mut title = String::new();
    let mut author = String::new();
    let mut total = None;
    if let Some(script) = doc
        .select(&sel("script#vite-plugin-ssr_pageContext"))
        .next()
    {
        let raw = script.inner_html();
        let root: Value =
            serde_json::from_str(&raw).map_err(|_| err("parse_failed_invalid_payload"))?;
        let mut data = &root;
        for k in ["pageContext", "pageProps", "pageData"] {
            if let Some(next) = data.get(k) {
                data = next;
            }
        }
        if string(data, "bookId") != book_id {
            return Err(err("book_identity_mismatch"));
        }
        title = string(data, "bookName");
        if title.is_empty() {
            title = string(data, "bName");
        }
        author = string(data, "authorName");
        total = data
            .get("chapterTotalCnt")
            .and_then(Value::as_u64)
            .map(|n| n as usize);
        if let Some(volumes) = data.get("vs").and_then(Value::as_array) {
            let mut previous_volume = String::new();
            for v in volumes {
                let vid = string(v, "vId");
                let vn = clean(&string(v, "vN"));
                let mut kind = volume_kind(&vn).to_owned();
                // Qidian's `vS`/`hS` flags describe access partitions. A repeated
                // title with the paid flag is the continuation of the same work
                // volume, not a new volume. A new named title remains structural
                // even when it is entirely VIP.
                let paid_partition = v.get("vS").and_then(Value::as_u64).unwrap_or(0) > 0
                    || v.get("hS").and_then(Value::as_bool).unwrap_or(false);
                if paid_partition && key(&previous_volume) == key(&vn) && !vn.is_empty() {
                    kind = "access".into();
                }
                let structural = kind == "structural";
                if let Some(chapters) = v.get("cs").and_then(Value::as_array) {
                    for c in chapters {
                        entries.push(Entry {
                            id: string(c, "id"),
                            title: clean(&string(c, "cN")),
                            volume_id: vid.clone(),
                            volume: vn.clone(),
                            structural_volume: structural,
                            volume_kind: kind.clone(),
                        });
                    }
                }
                previous_volume = vn;
            }
        }
    }
    if entries.is_empty() {
        for (i, block) in doc.select(&sel(".catalog-volume")).enumerate() {
            let volume = block
                .select(&sel("h3"))
                .next()
                .map(|n| clean(&n.text().collect::<String>()))
                .unwrap_or_default();
            let vid = block
                .value()
                .attr("data-volume-id")
                .unwrap_or("")
                .to_owned();
            for a in block.select(&sel("a[href]")) {
                let href = a.value().attr("href").unwrap_or("");
                if !href.contains(&format!("/chapter/{book_id}/")) {
                    continue;
                }
                entries.push(Entry {
                    id: href
                        .trim_end_matches('/')
                        .rsplit('/')
                        .next()
                        .unwrap_or("")
                        .into(),
                    title: clean(&a.text().collect::<String>()),
                    volume: volume.clone(),
                    volume_id: if vid.is_empty() {
                        format!("volume:{i}")
                    } else {
                        vid.clone()
                    },
                    structural_volume: structural_volume(&volume),
                    volume_kind: volume_kind(&volume).into(),
                });
            }
        }
    }
    if entries.is_empty() {
        let reason = if ["captcha", "probe.js", "人机验证", "安全验证"]
            .iter()
            .any(|s| html.contains(s))
        {
            "verification_required"
        } else if ["请先登录", "登录后查看", "请登录后"]
            .iter()
            .any(|s| html.contains(s))
        {
            "login_required"
        } else {
            "parse_failed_no_catalog_entries"
        };
        return Err(err(reason));
    }
    for (name, dest) in [
        ("og:novel:book_name", &mut title),
        ("og:novel:author", &mut author),
    ] {
        if dest.is_empty() {
            *dest = doc
                .select(&sel(&format!("meta[property='{name}']")))
                .next()
                .and_then(|n| n.value().attr("content"))
                .unwrap_or("")
                .into();
        }
    }
    if title.is_empty() {
        title = doc
            .select(&sel("title"))
            .next()
            .map(|n| clean(&n.text().collect::<String>()))
            .unwrap_or_default();
    }
    if total.is_none() {
        total = Regex::new(r#"(?:chapterTotalCnt["']?\s*[:=]\s*|共\s*)([0-9]+)"#)
            .unwrap()
            .captures(html)
            .and_then(|c| c[1].parse().ok());
    }
    finish(Catalog {
        id: String::new(),
        book_id: book_id.into(),
        title,
        author,
        origin: origin.into(),
        fetched_at: now(),
        total,
        completeness: String::new(),
        entries,
    })
}

fn book_url(input: &str) -> Result<(String, String), ApiError> {
    let id = if !input.is_empty() && input.chars().all(|c| c.is_ascii_digit()) {
        input.into()
    } else {
        let url = reqwest::Url::parse(input).map_err(|_| err("invalid_qidian_url"))?;
        if url.scheme() != "https"
            || !matches!(
                url.host_str(),
                Some("www.qidian.com" | "m.qidian.com" | "book.qidian.com")
            )
            || !url.username().is_empty()
            || url.password().is_some()
            || url.port().is_some()
        {
            return Err(err("unsupported_source"));
        }
        Regex::new(r"/(?:book|info)/(\d+)(?:/|$)")
            .unwrap()
            .captures(url.path())
            .map(|c| c[1].to_owned())
            .ok_or_else(|| err("invalid_qidian_url"))?
    };
    if id.len() > 24 {
        return Err(err("invalid_qidian_url"));
    }
    Ok((format!("https://m.qidian.com/book/{id}/catalog/"), id))
}
fn fetch(
    url: &str,
    cookie: &str,
    token: &tokio_util::sync::CancellationToken,
) -> Result<String, ApiError> {
    check_cancelled(token)?;
    let _permit = NETWORK.try_lock().map_err(|_| err("network_busy"))?;
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|_| err("network_initialization_failed"))?;
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(25))
        .connect_timeout(Duration::from_secs(8))
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .user_agent("Mozilla/5.0 EasyPub/0.1 CatalogReview")
        .build()
        .map_err(|_| err("network_initialization_failed"))?;
    runtime.block_on(fetch_response(client, url, cookie, token))
}

async fn fetch_response(
    client: reqwest::Client,
    url: &str,
    cookie: &str,
    token: &tokio_util::sync::CancellationToken,
) -> Result<String, ApiError> {
    fetch_response_observed(client, url, cookie, token, || {}).await
}

async fn fetch_response_observed(
    client: reqwest::Client,
    url: &str,
    cookie: &str,
    token: &tokio_util::sync::CancellationToken,
    mut on_chunk: impl FnMut(),
) -> Result<String, ApiError> {
    // Dropping this future cancels both header waits and streamed body reads.
    token
        .run_until_cancelled(async move {
            let mut req = client.get(url);
            let cookie = crate::catalog_cookie::header(cookie, url, now()).map_err(err)?;
            if !cookie.is_empty() {
                let mut value = reqwest::header::HeaderValue::from_str(&cookie)
                    .map_err(|_| err("invalid_cookie_format"))?;
                value.set_sensitive(true);
                req = req.header(reqwest::header::COOKIE, value);
            }
            let response = req.send().await.map_err(|e| {
                err(if e.is_timeout() {
                    "network_timeout"
                } else {
                    "network_failed"
                })
            })?;
            let bytes = read_response_observed(response, &mut on_chunk).await?;
            String::from_utf8(bytes).map_err(|_| err("invalid_catalog_encoding"))
        })
        .await
        .ok_or_else(|| err("catalog_cancelled"))?
}

async fn read_response_observed(
    mut response: reqwest::Response,
    mut on_chunk: impl FnMut(),
) -> Result<Vec<u8>, ApiError> {
    match response.status().as_u16() {
        200 => (),
        202 | 403 => return Err(err("verification_required")),
        401 => return Err(err("login_required")),
        429 => return Err(err("rate_limited")),
        404 => return Err(err("not_found")),
        300..=399 => return Err(err("redirect_requires_review")),
        _ => return Err(err("http_failed")),
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| err("network_read_failed"))?
    {
        if chunk.len() > MAX_BYTES.saturating_sub(bytes.len()) {
            return Err(err("catalog_too_large"));
        }
        bytes.extend_from_slice(&chunk);
        on_chunk();
    }
    Ok(bytes)
}

fn cache_path(url: &str) -> Result<PathBuf, ApiError> {
    let root = std::env::var_os("LOCALAPPDATA").ok_or_else(|| err("cache_unavailable"))?;
    Ok(PathBuf::from(root)
        .join("EasyPubRustFlutter/catalog-v1")
        .join(format!("{}.json", hash(url.as_bytes()))))
}
fn remember(c: Catalog, cached: bool) -> Result<Value, ApiError> {
    let id = c.id.clone();
    let mut map = CATALOGS
        .get_or_init(Default::default)
        .lock()
        .map_err(|_| err("catalog_busy"))?;
    if map.len() >= 32 && !map.contains_key(&id)
        && let Some(oldest) = map
            .values()
            .min_by_key(|c| c.fetched_at)
            .map(|c| c.id.clone())
        {
            map.remove(&oldest);
        }
    map.insert(id, c.clone());
    Ok(
        json!({"stage":"candidate", "catalog":c, "from_cache":cached, "identity_confirmed":false,"duplicate_segments":duplicate_segments(&c)}),
    )
}
pub fn acquire(request: &Value, cookie: &str) -> Result<Value, ApiError> {
    acquire_cancellable(request, cookie, &request_token(request)?)
}
fn acquire_cancellable(
    request: &Value,
    cookie: &str,
    token: &tokio_util::sync::CancellationToken,
) -> Result<Value, ApiError> {
    check_cancelled(token)?;
    let input = string(request, "input");
    let mode = string(request, "source");
    if mode.starts_with("book_source_") {
        return book_sources::execute(request, token);
    }
    if mode == "search" {
        if input.trim().is_empty() || input.len() > 512 {
            return Err(err("invalid_search_query"));
        }
        let mut url = reqwest::Url::parse("https://www.qidian.com/search/").unwrap();
        url.query_pairs_mut().append_pair("kw", input.trim());
        let credential = crate::catalog_credentials::for_request(request, cookie)?;
        let html = fetch(url.as_str(), &credential, token)?;
        let doc = Html::parse_document(&html);
        let mut books = BTreeMap::new();
        for a in doc.select(&sel("a[href]")) {
            check_cancelled(token)?;
            let href = a.value().attr("href").unwrap_or("");
            let Ok(link) = url.join(href) else {
                continue;
            };
            if let Ok((link, id)) = book_url(link.as_str()) {
                let title = clean(&a.text().collect::<String>());
                if !title.is_empty() {
                    books
                        .entry(id.clone())
                        .or_insert(json!({"book_id":id,"title":title,"url":link}));
                }
            }
        }
        if books.is_empty() {
            return Err(err(
                if html.contains("captcha") || html.contains("probe.js") {
                    "verification_required"
                } else {
                    "search_empty_or_layout_changed"
                },
            ));
        }
        return Ok(
            json!({"stage":"search_results","books":books.into_values().take(50).collect::<Vec<_>>()}),
        );
    }
    if mode == "qidian" {
        let (url, id) = book_url(input.trim())?;
        let path = cache_path(&url)?;
        if request["use_cache"] == true && path.exists() {
            let file = std::fs::File::open(&path).map_err(|_| err("cache_read_failed"))?;
            let mut bytes = Vec::new();
            file.take(MAX_BYTES as u64 + 1)
                .read_to_end(&mut bytes)
                .map_err(|_| err("cache_read_failed"))?;
            if bytes.len() > MAX_BYTES {
                return Err(err("cache_invalid"));
            }
            let c: Catalog = serde_json::from_slice(&bytes).map_err(|_| err("cache_invalid"))?;
            let validated = finish(c.clone())?;
            if validated.id != c.id || c.origin != url || c.book_id != id {
                return Err(err("cache_invalid"));
            }
            let stale = now().saturating_sub(c.fetched_at) > 86400;
            check_cancelled(token)?;
            let mut result = remember(c, true)?;
            result["cache_stale"] = json!(stale);
            return Ok(result);
        }
        let credential = crate::catalog_credentials::for_request(request, cookie)?;
        let c = parse_qidian(&fetch(&url, &credential, token)?, &id, &url)?;
        check_cancelled(token)?;
        let mut cache_saved = false;
        if let Some(parent) = path.parent()
            && std::fs::create_dir_all(parent).is_ok() {
                cache_saved = std::fs::write(&path, serde_json::to_vec(&c).unwrap()).is_ok();
            }
        check_cancelled(token)?;
        let mut result = remember(c, false)?;
        result["cache_saved"] = json!(cache_saved);
        return Ok(result);
    }
    let text = if mode == "local" {
        let file = std::fs::File::open(&input).map_err(|_| err("local_catalog_unreadable"))?;
        let mut bytes = Vec::new();
        file.take(MAX_BYTES as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| err("local_catalog_unreadable"))?;
        if bytes.len() > MAX_BYTES {
            return Err(err("catalog_too_large"));
        }
        easypub_core::encoding::decode(&bytes, easypub_core::encoding::EncodingMode::Auto)?.text
    } else if mode == "paste" {
        input.clone()
    } else {
        return Err(err("unsupported_source"));
    };
    let origin = if mode == "local" {
        format!("local:{}", hash(text.as_bytes()))
    } else {
        "paste".into()
    };
    check_cancelled(token)?;
    let catalog = parse_text_cancellable(
        &text,
        &string(request, "title"),
        &string(request, "author"),
        &origin,
        request["total"].as_u64().map(|n| n as usize),
        token,
    )?;
    check_cancelled(token)?;
    remember(catalog, false)
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Edit {
    pub line: usize,
    pub before: String,
    pub after: String,
    pub kind: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Alignment {
    pub plan_id: String,
    pub catalog_id: String,
    pub source_id: String,
    pub revision: u32,
    pub writes: bool,
    pub matches: Vec<Value>,
    pub unresolved: Vec<Value>,
    pub edits: Vec<Edit>,
    pub matched: usize,
    pub total: usize,
    pub source_unchanged: bool,
    pub relocation: Option<Relocation>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Relocation {
    pub prefix_end: usize,
    pub pieces: Vec<RelocatedChapter>,
    pub removed_headings: Vec<Value>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RelocatedChapter {
    pub start: usize,
    pub end: usize,
    pub catalog_index: usize,
    pub title: String,
    pub source_line: usize,
    pub insert_volume: String,
    pub intro_start: usize,
    pub intro_end: usize,
}

#[derive(Clone, Debug, Serialize)]
pub struct DuplicateSegment {
    pub original_start: usize,
    pub start: usize,
    pub length: usize,
    pub first_title: String,
    pub last_title: String,
}

/// Suggest only exact adjacent repeated sequences with at least three distinct
/// entries. Rolling fingerprints prune comparisons; exact equality proves each
/// suggestion. Never modifies the acquired snapshot or assumes user intent.
pub fn duplicate_segments(c: &Catalog) -> Vec<DuplicateSegment> {
    let mut symbols = BTreeMap::new();
    let mut ids = Vec::with_capacity(c.entries.len());
    for entry in &c.entries {
        let next = symbols.len() as u64 + 1;
        let symbol = (
            key(&entry.title),
            key(&entry.volume),
            entry.volume_kind.clone(),
        );
        ids.push(*symbols.entry(symbol).or_insert(next));
    }
    let mut prefix = vec![0u64; ids.len() + 1];
    let mut powers = vec![1u64; ids.len() + 1];
    const BASE: u64 = 1_000_003;
    for (i, id) in ids.iter().enumerate() {
        prefix[i + 1] = prefix[i].wrapping_mul(BASE).wrapping_add(*id);
        powers[i + 1] = powers[i].wrapping_mul(BASE);
    }
    let fingerprint = |start: usize, length: usize| {
        prefix[start + length].wrapping_sub(prefix[start].wrapping_mul(powers[length]))
    };
    let mut seen = BTreeMap::new();
    let mut result = Vec::new();
    let mut i = 0;
    while i + 3 <= ids.len() {
        let signature = (ids[i], ids[i + 1], ids[i + 2]);
        if let Some(&previous) = seen.get(&signature) {
            let length = i - previous;
            if length >= 3
                && i + length <= ids.len()
                && fingerprint(previous, length) == fingerprint(i, length)
                && ids[previous..i] == ids[i..i + length]
                && ids[previous..i].iter().collect::<BTreeSet<_>>().len() >= 3
            {
                result.push(DuplicateSegment {
                    original_start: previous,
                    start: i,
                    length,
                    first_title: c.entries[i].title.clone(),
                    last_title: c.entries[i + length - 1].title.clone(),
                });
                // For three copies, compare the next copy to this one. Kept
                // original ranges may themselves be explicitly removed later.
                seen.insert(signature, i);
                i += length;
                continue;
            }
        }
        seen.insert(signature, i);
        i += 1;
    }
    result
}

pub fn remove_duplicate_segments(
    c: &Catalog,
    starts: &[usize],
    confirmed: bool,
) -> Result<Catalog, ApiError> {
    validate_snapshot(c)?;
    if !confirmed || starts.is_empty() {
        return Err(err("confirm_duplicate_catalog_segments"));
    }
    let diagnostics = duplicate_segments(c);
    let requested: BTreeSet<_> = starts.iter().copied().collect();
    if requested.len() != starts.len()
        || requested
            .iter()
            .any(|start| !diagnostics.iter().any(|d| d.start == *start))
    {
        return Err(err("refresh_duplicate_catalog_segments"));
    }
    let mut excluded = BTreeSet::new();
    for segment in diagnostics.iter().filter(|d| requested.contains(&d.start)) {
        excluded.extend(segment.start..segment.start + segment.length);
    }
    let mut next = c.clone();
    next.entries = c
        .entries
        .iter()
        .enumerate()
        .filter(|(i, _)| !excluded.contains(i))
        .map(|(_, e)| e.clone())
        .collect();
    // Declared scope is independent evidence. Never decrease it just to make
    // the resulting catalog appear complete.
    finish(next)
}

pub fn align(source: &SourceSnapshot, c: &Catalog, confirmed: bool) -> Result<Alignment, ApiError> {
    align_with_options(source, c, confirmed, &Value::Null, false)
}
pub(crate) fn align_with_options(
    source: &SourceSnapshot,
    c: &Catalog,
    confirmed: bool,
    choices: &Value,
    reorder: bool,
) -> Result<Alignment, ApiError> {
    if !confirmed {
        return Err(err("confirm_book_identity_and_scope"));
    }
    let mut plan = Alignment {
        plan_id: String::new(),
        catalog_id: c.id.clone(),
        source_id: source.summary().source_id,
        revision: source.summary().revision,
        writes: false,
        matches: vec![],
        unresolved: vec![],
        edits: vec![],
        matched: 0,
        total: c.entries.len(),
        source_unchanged: true,
        relocation: None,
    };
    let duplicate_ranges = duplicate_segments(c);
    if !duplicate_ranges.is_empty() && c.entries.len() > source.headings().len() {
        plan.unresolved
            .push(json!({"reason":"duplicate_catalog_segments_require_review",
            "segments":duplicate_ranges}));
        plan.plan_id = hash(&serde_json::to_vec(&(&plan, choices, reorder)).unwrap());
        return Ok(plan);
    }
    let mut index: BTreeMap<String, Vec<usize>> = BTreeMap::new();
    for (i, e) in c.entries.iter().enumerate() {
        index.entry(key(&e.title)).or_default().push(i);
    }
    let volume_titles: BTreeSet<_> = c
        .entries
        .iter()
        .filter(|e| e.structural_volume && !e.volume.is_empty())
        .map(|e| key(&e.volume))
        .collect();
    let volume_re = Regex::new(r"^第[^\s]{1,16}[卷部篇]").unwrap();
    let mut volume = String::new();
    let mut used = BTreeSet::new();
    let mut last = None;
    let lines: Vec<_> = source
        .decoded_line_ranges()
        .iter()
        .map(|&(a, b)| &source.decoded_text()[a..b])
        .collect();
    let mut previous_line = 0usize;
    let mut planned_volume = String::new();
    let mut headings: BTreeMap<usize, String> = source
        .headings()
        .iter()
        .map(|h| (h.source_line as usize, h.title.clone()))
        .collect();
    for (i, line) in lines.iter().enumerate() {
        if line.len() <= 4096 && index.contains_key(&key(line)) {
            headings
                .entry(i + 1)
                .or_insert_with(|| line.trim().to_owned());
        }
    }
    if choices.as_object().is_some_and(|obj| {
        obj.keys().any(|line| {
            line.parse::<usize>()
                .ok()
                .is_none_or(|line| !headings.contains_key(&line))
        })
    }) {
        return Err(err("invalid_explicit_choice"));
    }
    for (source_line, heading) in headings {
        let title = key(&heading);
        // Volume boundaries are facts from source lines, never inferred from a chapter number reset.
        for line in &lines[previous_line..(source_line).min(lines.len())] {
            if volume_titles.contains(&key(line))
                || (volume_re.is_match(line.trim()) && structural_volume(line.trim()))
            {
                volume = key(line);
                planned_volume = volume.clone();
            }
        }
        previous_line = source_line;
        if volume_titles.contains(&title)
            || (volume_re.is_match(&heading) && structural_volume(&heading))
        {
            continue;
        }
        let candidates = index.get(&title).cloned().unwrap_or_default();
        let scoped: Vec<_> = candidates
            .iter()
            .copied()
            .filter(|&i| !volume.is_empty() && key(&c.entries[i].volume) == volume)
            .collect();
        let mut candidates_for_line =
            if scoped.is_empty() || choices.get(source_line.to_string()).is_some() {
                candidates
            } else {
                scoped
            };
        if let Some(chosen) = choices.get(source_line.to_string()).and_then(Value::as_str) {
            let selected = candidates_for_line
                .iter()
                .copied()
                .filter(|&i| c.entries[i].id == chosen)
                .collect::<Vec<_>>();
            if selected.len() != 1 {
                return Err(err("invalid_explicit_choice"));
            }
            candidates_for_line = selected;
        }
        if candidates_for_line.len() != 1 {
            plan.unresolved.push(json!({"line":source_line,"title":heading,"reason":if candidates_for_line.is_empty(){"unmatched"}else{"ambiguous_cross_volume"},"candidate_ids": candidates_for_line.iter().map(|&i| &c.entries[i].id).collect::<Vec<_>>()}));
            continue;
        }
        let i = candidates_for_line[0];
        let e = &c.entries[i];
        if !used.insert(i) {
            plan.unresolved.push(json!({"line":source_line,"title":heading,"reason":"duplicate_local_chapter_body_not_removed"}));
            continue;
        }
        plan.matched += 1;
        let out_of_order = last.is_some_and(|n| i <= n);
        plan.matches.push(json!({"line":source_line,"title":heading,"catalog_title":e.title,"volume":e.volume,"catalog_entry_id":e.id,"catalog_index":i,"order_conflict":out_of_order}));
        if out_of_order {
            plan.unresolved
                .push(json!({"line":source_line,"reason":"order_conflict_review_required"}));
        }
        // Adjacent access partitions can have different source IDs while still being
        // one logical work volume; only a changed structural title is a boundary.
        let first_of_volume = i == 0 || key(&c.entries[i - 1].volume) != key(&e.volume);
        if e.structural_volume && !e.volume.is_empty() && key(&e.volume) != planned_volume {
            if first_of_volume && !out_of_order && c.completeness == "complete" {
                // Only insert a missing heading if there is no existing (possibly wrong) volume block.
                if volume.is_empty() {
                    planned_volume = key(&e.volume);
                    plan.edits.push(Edit {
                        line: source_line,
                        before: String::new(),
                        after: e.volume.clone(),
                        kind: "insert_volume".into(),
                    });
                } else {
                    plan.unresolved.push(json!({"line":source_line,"reason":"existing_volume_or_intro_requires_review","expected_volume":e.volume}));
                }
            } else {
                plan.unresolved.push(json!({"line":source_line,"reason":"volume_boundary_not_proven","expected_volume":e.volume}));
            }
        }
        last = Some(i);
    }
    for (i, e) in c.entries.iter().enumerate() {
        if !used.contains(&i) {
            plan.unresolved.push(json!({"catalog_entry_id":e.id,"title":e.title,"volume":e.volume,"reason":"not_located_no_body_created"}));
        }
    }
    if c.completeness != "complete" {
        plan.unresolved.push(
            json!({"reason":"catalog_scope_not_verified_complete","completeness":c.completeness}),
        );
    }
    // A contradictory order invalidates all inferred volume insertions.
    if plan.matches.iter().any(|m| m["order_conflict"] == true) {
        plan.edits.clear();
    }
    if reorder {
        match build_relocation(source, c, &plan) {
            Ok(relocation) => {
                plan.edits.clear();
                plan.unresolved.retain(|v| {
                    !matches!(
                        v["reason"].as_str(),
                        Some(
                            "order_conflict_review_required"
                                | "existing_volume_or_intro_requires_review"
                                | "volume_boundary_not_proven"
                        )
                    )
                });
                plan.relocation = Some(relocation);
                if render(source, &plan)? == source.original_bytes() {
                    plan.relocation = None;
                }
            }
            Err(e) => plan.unresolved.push(json!({"reason":e.next_action})),
        }
    }
    plan.plan_id = hash(&serde_json::to_vec(&(&plan, choices, reorder)).unwrap());
    Ok(plan)
}
/// Relocate complete chapter spans only after an explicit request and a complete
/// one-to-one mapping. A volume introduction may travel only with its proven
/// first chapter. Unknown or contradictory boundaries stay pending.
fn build_relocation(
    source: &SourceSnapshot,
    c: &Catalog,
    plan: &Alignment,
) -> Result<Relocation, ApiError> {
    if c.completeness != "complete"
        || plan.matched != c.entries.len()
        || plan.unresolved.iter().any(|v| {
            !matches!(
                v["reason"].as_str(),
                Some(
                    "order_conflict_review_required"
                        | "existing_volume_or_intro_requires_review"
                        | "volume_boundary_not_proven"
                )
            )
        })
    {
        return Err(err("reorder_requires_complete_unique_alignment"));
    }
    let ranges = source.decoded_line_ranges();
    let text = source.decoded_text();
    let volumes: BTreeSet<_> = c
        .entries
        .iter()
        .filter(|e| e.structural_volume)
        .map(|e| key(&e.volume))
        .collect();
    let chapter_lines: Vec<_> = plan
        .matches
        .iter()
        .map(|m| {
            (
                m["line"].as_u64().unwrap() as usize - 1,
                m["catalog_index"].as_u64().unwrap() as usize,
            )
        })
        .collect();
    let mut original = Vec::new();
    let mut removed = Vec::new();
    let mut boundaries = Vec::new();
    let volume_re = Regex::new(r"^第[^\s]{1,16}[卷部篇集季幕辑册]").unwrap();
    for (position, &(line, index)) in chapter_lines.iter().enumerate() {
        let previous_end = if position == 0 {
            0
        } else {
            chapter_lines[position - 1].0 + 1
        };
        let headers: Vec<_> = (previous_end..line)
            .filter(|&i| {
                let title = &text[ranges[i].0..ranges[i].1];
                volumes.contains(&key(title)) || volume_re.is_match(title.trim())
            })
            .collect();
        if headers.len() > 1 {
            return Err(err("volume_intro_requires_review"));
        }
        let start = ranges[line].0;
        let mut intro_start = start;
        let boundary = headers.first().map(|&h| ranges[h].0).unwrap_or(start);
        if let Some(&header) = headers.first() {
            let heading = &text[ranges[header].0..ranges[header].1];
            let e = &c.entries[index];
            let first = index == 0 || key(&c.entries[index - 1].volume) != key(&e.volume);
            intro_start = ranges.get(header + 1).map(|r| r.0).unwrap_or(start);
            // A bare known heading can be relocated; an introduction cannot be
            // assigned by guesswork when the following chapter is displaced.
            if !volumes.contains(&key(heading))
                || (!text[intro_start..start].trim().is_empty()
                    && (!first || key(heading) != key(&e.volume)))
            {
                return Err(err("volume_intro_requires_review"));
            }
            removed
                .push(json!({"line":header+1,"title":heading,"start":boundary,"end":intro_start}));
        }
        boundaries.push(boundary);
        original.push(RelocatedChapter {
            start,
            end: text.len(),
            catalog_index: index,
            title: c.entries[index].title.clone(),
            source_line: line + 1,
            insert_volume: String::new(),
            intro_start,
            intro_end: start,
        });
    }
    if let Some(&(last_line, _)) = chapter_lines.last()
        && ranges.iter().skip(last_line + 1).any(|&(a, b)| {
            volumes.contains(&key(&text[a..b])) || volume_re.is_match(text[a..b].trim())
        }) {
            return Err(err("volume_intro_requires_review"));
        }
    original.sort_by_key(|p| p.start);
    for (i, piece) in original.iter_mut().enumerate() {
        piece.end = boundaries.get(i + 1).copied().unwrap_or(text.len());
    }
    let prefix_end = boundaries.first().copied().unwrap_or(text.len());
    let mut pieces = original;
    pieces.sort_by_key(|p| p.catalog_index);
    for piece in &mut pieces {
        let e = &c.entries[piece.catalog_index];
        let first = piece.catalog_index == 0
            || key(&c.entries[piece.catalog_index - 1].volume) != key(&e.volume);
        if first && e.structural_volume {
            piece.insert_volume = e.volume.clone();
        }
    }
    // Every original byte is retained once, except explicitly listed old headings.
    let mut spans = vec![(0, prefix_end)];
    for p in &pieces {
        spans.push((p.start, p.end));
        spans.push((p.intro_start, p.intro_end));
    }
    for heading in &removed {
        spans.push((
            heading["start"].as_u64().unwrap() as usize,
            heading["end"].as_u64().unwrap() as usize,
        ));
    }
    spans.retain(|(a, b)| a != b);
    spans.sort_unstable();
    let mut cursor = 0;
    for (a, b) in spans {
        if a != cursor || b < a {
            return Err(err("invalid_catalog_edit"));
        }
        cursor = b;
    }
    if cursor != text.len() {
        return Err(err("invalid_catalog_edit"));
    }
    Ok(Relocation {
        prefix_end,
        pieces,
        removed_headings: removed,
    })
}

/// Persistable replay recipe, deliberately excludes confirmation and plan consent.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CompositionRecipe {
    pub snapshot: Catalog,
    pub choices: Value,
    pub reorder: bool,
}
impl CompositionRecipe {
    pub fn compose_replay(
        &self,
        source: &SourceSnapshot,
        structure: &easypub_core::structure::Structure,
        manual: Option<&str>,
        cleanup: Option<&str>,
    ) -> Result<easypub_core::publication::EffectiveBook, ApiError> {
        validate_snapshot(&self.snapshot)?;
        // Replay only computes and validates historical state. It cannot authorize writes.
        let plan = align_with_options(source, &self.snapshot, true, &self.choices, self.reorder)?;
        if self.reorder && plan.relocation.is_none() {
            return Err(err("refresh_catalog_composition"));
        }
        let mut projection = project(source, &plan)?;
        if let Some(manual) = manual {
            projection =
                easypub_core::publication::edit_projection(source, structure, projection, manual)?;
        }
        easypub_core::publication::compose_projected_with_cleanup(
            source, structure, projection, cleanup,
        )
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CompositionSelection {
    pub snapshot: Catalog,
    pub choices: Value,
    pub reorder: bool,
    pub plan_id: String,
    pub confirmed: bool,
}
impl CompositionSelection {
    pub fn confirmed_recipe(&self, source: &SourceSnapshot) -> Result<CompositionRecipe, ApiError> {
        self.resolve(source)?;
        Ok(CompositionRecipe {
            snapshot: self.snapshot.clone(),
            choices: self.choices.clone(),
            reorder: self.reorder,
        })
    }
    pub fn resolve(&self, source: &SourceSnapshot) -> Result<Alignment, ApiError> {
        validate_snapshot(&self.snapshot)?;
        if !self.confirmed {
            return Err(err("confirm_current_catalog_composition"));
        }
        let plan = align_with_options(source, &self.snapshot, true, &self.choices, self.reorder)?;
        if plan.plan_id != self.plan_id || (self.reorder && plan.relocation.is_none()) {
            return Err(err("refresh_catalog_composition"));
        }
        Ok(plan)
    }
}

/// Resolve proven catalog insertions to the current effective node identities.
/// Only returns edit commands; persistence and undo use the ordinary history.
pub fn effective_actions(
    source: &SourceSnapshot,
    book: &easypub_core::publication::EffectiveBook,
    selection: &CompositionSelection,
) -> Result<Vec<easypub_core::effective_edit::Action>, ApiError> {
    use easypub_core::{effective_edit::Action, structure::Role};
    let plan = selection.resolve(source)?;
    if selection.reorder {
        return effective_reorder_actions(source, book, selection, &plan, false);
    }
    if plan.relocation.is_some() || plan.edits.is_empty() {
        return Err(err("review_catalog_effective_changes"));
    }
    if book.original_source_id != plan.source_id
        || book.tree.nodes.iter().any(|n| n.role == Role::Volume)
    {
        return Err(err("review_existing_effective_volumes"));
    }
    let nodes = book
        .tree
        .nodes
        .iter()
        .map(|n| (n.source_line, n))
        .collect::<BTreeMap<_, _>>();
    let locate = |line: u32| {
        book.source_to_output_lines
            .get(&line)
            .and_then(|output| nodes.get(output).copied())
            .filter(|n| n.role == Role::Chapter)
            .ok_or_else(|| err("review_catalog_effective_location"))
    };
    // A moved, merged, excluded or reclassified matching chapter invalidates the
    // original volume-boundary proof; never retarget by title or nearest line.
    let mut previous = None;
    for matched in &plan.matches {
        let line = matched["line"]
            .as_u64()
            .and_then(|line| u32::try_from(line).ok())
            .ok_or_else(|| err("review_catalog_effective_location"))?;
        let node = locate(line)?;
        if previous.is_some_and(|start| node.start <= start) {
            return Err(err("review_catalog_effective_order"));
        }
        previous = Some(node.start);
    }
    plan.edits
        .iter()
        .map(|edit| {
            if edit.kind != "insert_volume" {
                return Err(err("review_catalog_effective_changes"));
            }
            let node = locate(
                u32::try_from(edit.line).map_err(|_| err("review_catalog_effective_location"))?,
            )?;
            Ok(Action::InsertVolume {
                entry_id: node.entry_id.clone(),
                title: edit.after.clone(),
            })
        })
        .collect()
}

pub(crate) fn effective_reorder_current(
    book: &easypub_core::publication::EffectiveBook,
    source: &SourceSnapshot,
    selection: &CompositionSelection,
    plan: &Alignment,
) -> Result<Vec<easypub_core::effective_edit::Action>, ApiError> {
    effective_reorder_actions(source, book, selection, plan, true)
}

fn effective_reorder_actions(
    source: &SourceSnapshot,
    book: &easypub_core::publication::EffectiveBook,
    selection: &CompositionSelection,
    plan: &Alignment,
    effective_coordinates: bool,
) -> Result<Vec<easypub_core::effective_edit::Action>, ApiError> {
    use easypub_core::{effective_edit::Action, structure::Role};
    let invalid = || err("review_catalog_effective_location");
    if !effective_coordinates && book.original_source_id != source.summary().source_id {
        return Err(invalid());
    }
    let relocation = plan.relocation.as_ref().ok_or_else(invalid)?;
    let by_line = book
        .tree
        .nodes
        .iter()
        .enumerate()
        .map(|(i, n)| (n.source_line, i))
        .collect::<BTreeMap<_, _>>();
    let locate = |line: usize| -> Result<usize, ApiError> {
        let effective = if effective_coordinates {
            Some(line as u32)
        } else {
            book.source_to_output_lines.get(&(line as u32)).copied()
        };
        effective
            .and_then(|line| by_line.get(&line))
            .copied()
            .ok_or_else(invalid)
    };
    let mut chapters = BTreeMap::new();
    for piece in &relocation.pieces {
        let index = locate(piece.source_line)?;
        if book.tree.nodes[index].role != Role::Chapter
            || chapters.insert(piece.catalog_index, index).is_some()
        {
            return Err(invalid());
        }
    }
    if chapters.len() != selection.snapshot.entries.len()
        || chapters.values().copied().collect::<BTreeSet<_>>().len() != chapters.len()
    {
        return Err(invalid());
    }
    let mut volumes = BTreeMap::new();
    for header in &relocation.removed_headings {
        let index = locate(header["line"].as_u64().ok_or_else(invalid)? as usize)?;
        if book.tree.nodes[index].role != Role::Volume {
            return Err(invalid());
        }
        if volumes
            .insert(key(header["title"].as_str().ok_or_else(invalid)?), index)
            .is_some()
        {
            return Err(err("review_existing_effective_volumes"));
        }
    }
    let chapter_indices = chapters.values().copied().collect::<BTreeSet<_>>();
    let volume_indices = volumes.values().copied().collect::<BTreeSet<_>>();
    let mut children: BTreeMap<usize, Vec<usize>> = BTreeMap::new();
    let mut prefix = Vec::new();
    let mut owner = None;
    for (i, n) in book.tree.nodes.iter().enumerate() {
        if volume_indices.contains(&i) {
            owner = None;
        } else if chapter_indices.contains(&i) {
            owner = Some(i);
            children.insert(i, vec![i]);
        } else if let Some(parent) = owner {
            if n.role != Role::Section || n.depth <= book.tree.nodes[parent].depth {
                return Err(invalid());
            }
            children.get_mut(&parent).unwrap().push(i);
        } else if chapters.values().all(|index| i < *index)
            && volumes.values().all(|index| i < *index)
        {
            if matches!(n.role, Role::Chapter | Role::Volume) {
                return Err(invalid());
            }
            prefix.push((n.entry_id.clone(), n.depth));
        } else {
            return Err(invalid());
        }
    }
    let mut order = prefix;
    let mut inserts = Vec::new();
    let mut used_volumes = BTreeSet::new();
    let mut previous_group = String::new();
    for (catalog_index, entry) in selection.snapshot.entries.iter().enumerate() {
        let index = *chapters.get(&catalog_index).ok_or_else(invalid)?;
        let root = &book.tree.nodes[index];
        let group = if entry.structural_volume {
            key(&entry.volume)
        } else {
            String::new()
        };
        let new_group = catalog_index == 0 || group != previous_group;
        let existing = volumes.get(&group);
        if new_group && !group.is_empty() {
            if !used_volumes.insert(group.clone()) {
                return Err(err("review_existing_effective_volumes"));
            }
            if let Some(&v) = existing {
                let volume = &book.tree.nodes[v];
                let first_current = book
                    .tree
                    .nodes
                    .iter()
                    .enumerate()
                    .skip(v + 1)
                    .take_while(|(_, n)| n.role != Role::Volume)
                    .find(|(i, _)| chapter_indices.contains(i))
                    .map(|(i, _)| i);
                if !book.text[volume.body_start..volume.end].trim().is_empty()
                    && first_current != Some(index)
                {
                    return Err(err("volume_intro_requires_review"));
                }
                order.push((volume.entry_id.clone(), 0));
            } else {
                inserts.push(Action::InsertVolume {
                    entry_id: root.entry_id.clone(),
                    title: entry.volume.clone(),
                });
            }
        }
        let depth = if existing.is_some() { 1 } else { 0 };
        for &child in children.get(&index).ok_or_else(invalid)? {
            let node = &book.tree.nodes[child];
            let adjusted = node
                .depth
                .checked_sub(root.depth)
                .and_then(|d| d.checked_add(depth))
                .ok_or_else(invalid)?;
            order.push((node.entry_id.clone(), adjusted));
        }
        previous_group = group;
    }
    if order.len() != book.tree.nodes.len() {
        return Err(invalid());
    }
    let mut actions = vec![Action::Reorder { order }];
    actions.extend(inserts);
    Ok(actions)
}

pub fn compose_selection(
    source: &SourceSnapshot,
    structure: &easypub_core::structure::Structure,
    selection: Option<CompositionSelection>,
    manual: Option<&str>,
    cleanup: Option<&str>,
) -> Result<easypub_core::publication::EffectiveBook, ApiError> {
    if let Some(selection) = selection {
        let plan = selection.resolve(source)?;
        let mut projection = project(source, &plan)?;
        if let Some(manual) = manual {
            projection =
                easypub_core::publication::edit_projection(source, structure, projection, manual)?;
        }
        easypub_core::publication::compose_projected_with_cleanup(
            source, structure, projection, cleanup,
        )
    } else {
        easypub_core::publication::compose_with_cleanup(source, structure, manual, cleanup)
    }
}

/// Catalog order, cleanup and illustration lookup now consume one effective tree.
pub fn compose(
    source: &SourceSnapshot,
    plan: &Alignment,
    structure: &easypub_core::structure::Structure,
    cleanup_json: Option<&str>,
) -> Result<easypub_core::publication::EffectiveBook, ApiError> {
    easypub_core::publication::compose_projected_with_cleanup(
        source,
        structure,
        project(source, plan)?,
        cleanup_json,
    )
}

pub fn render(source: &SourceSnapshot, plan: &Alignment) -> Result<Vec<u8>, ApiError> {
    source.encode_edited_text(&project(source, plan)?.text)
}

/// The byte writer and downstream composition share exactly this source mapping.
pub fn project(
    source: &SourceSnapshot,
    plan: &Alignment,
) -> Result<easypub_core::manual_edit::Projection, ApiError> {
    use easypub_core::manual_edit::{Anchor, Projection};
    fn copy_span(
        result: &mut Projection,
        source: &SourceSnapshot,
        start: usize,
        end: usize,
    ) -> Result<(), ApiError> {
        let text = source.decoded_text();
        let piece = text
            .get(start..end)
            .ok_or_else(|| err("invalid_catalog_edit"))?;
        // Binary search limits each visit to the copied lines, avoiding a full
        // source scan per chapter on long books.
        let ranges = source.decoded_line_ranges();
        let first = ranges.partition_point(|r| r.0 < start);
        for (i, &(offset, _)) in ranges
            .iter()
            .enumerate()
            .skip(first)
            .take_while(|(_, r)| r.0 < end)
        {
            result.anchors.push(Anchor {
                source_line: i as u32 + 1,
                output_start: result.text.len() + offset - start,
                inserted: None,
            });
        }
        result.text.push_str(piece);
        Ok(())
    }
    let mut result = Projection {
        text: String::new(),
        anchors: Vec::new(),
    };
    if plan.source_id != source.summary().source_id || plan.revision != source.summary().revision {
        return Err(err("stale_plan"));
    }
    let text = source.decoded_text();
    let ranges = source.decoded_line_ranges();
    let newline = ranges
        .first()
        .map(|r| {
            let tail = &text[r.1..];
            if tail.starts_with("\r\n") {
                "\r\n"
            } else if tail.starts_with('\r') {
                "\r"
            } else {
                "\n"
            }
        })
        .unwrap_or("\n");
    if let Some(relocation) = &plan.relocation {
        copy_span(&mut result, source, 0, relocation.prefix_end)?;
        for piece in &relocation.pieces {
            if !result.text.is_empty() && !result.text.ends_with(['\r', '\n']) {
                result.text.push_str(newline);
            }
            if !piece.insert_volume.is_empty() {
                result.anchors.push(Anchor {
                    source_line: piece.source_line as u32,
                    output_start: result.text.len(),
                    inserted: Some("set_volume"),
                });
                result.text.push_str(&piece.insert_volume);
                result.text.push_str(newline);
            }
            copy_span(&mut result, source, piece.intro_start, piece.intro_end)?;
            copy_span(&mut result, source, piece.start, piece.end)?;
        }
        return Ok(result);
    }
    let mut edits = plan.edits.iter().peekable();
    for (i, &(start, _)) in ranges.iter().enumerate() {
        while let Some(edit) = edits.peek().filter(|e| e.line == i + 1) {
            if edit.kind != "insert_volume"
                || !edit.before.is_empty()
                || edit.after.contains(['\r', '\n'])
            {
                return Err(err("invalid_catalog_edit"));
            }
            result.anchors.push(Anchor {
                source_line: i as u32 + 1,
                output_start: result.text.len(),
                inserted: Some("set_volume"),
            });
            result.text.push_str(&edit.after);
            result.text.push_str(newline);
            edits.next();
        }
        copy_span(
            &mut result,
            source,
            start,
            ranges.get(i + 1).map(|r| r.0).unwrap_or(text.len()),
        )?;
    }
    if edits.next().is_some() {
        return Err(err("invalid_catalog_edit"));
    }
    Ok(result)
}
fn get_catalog(id: &str) -> Result<Catalog, ApiError> {
    CATALOGS
        .get_or_init(Default::default)
        .lock()
        .map_err(|_| err("catalog_busy"))?
        .get(id)
        .cloned()
        .ok_or_else(|| err("catalog_expired_reacquire"))
}
pub fn execute(
    service: &ImportService,
    request_json: &str,
    cookie: &str,
) -> Result<Value, ApiError> {
    if request_json.len() > MAX_BYTES + 65536 {
        return Err(err("request_too_large"));
    }
    let r: Value = serde_json::from_str(request_json).map_err(|_| err("invalid_request"))?;
    match string(&r, "op").as_str() {
        "credential_status" | "credential_save" | "credential_clear" => {
            crate::catalog_credentials::execute(&r, cookie)
        }
        "begin_request" => begin_request(),
        "cancel_request" => cancel_request(&string(&r, "request_id")),
        "acquire" => acquire(&r, cookie),
        "remove_duplicate_segments" => {
            let c: Catalog = serde_json::from_value(r["catalog_snapshot"].clone())
                .map_err(|_| err("catalog_snapshot_invalid"))?;
            if c.id != string(&r, "catalog_id") {
                return Err(err("catalog_snapshot_invalid"));
            }
            let starts: Vec<usize> = serde_json::from_value(r["starts"].clone())
                .map_err(|_| err("refresh_duplicate_catalog_segments"))?;
            remember(
                remove_duplicate_segments(&c, &starts, r["confirmed"] == true)?,
                false,
            )
        }
        "export_repair_copy" => crate::repair_copy::execute(service, r),
        "preview_effective" => {
            let source = service.source(
                &string(&r, "source_id"),
                r["revision"].as_u64().unwrap_or(0) as u32,
            )?;
            let base: crate::effective_draft::Base =
                serde_json::from_value(r["base"].clone()).map_err(|_| err("review_composition"))?;
            let mut book = base.compose(&source)?;
            if !r["post_edits"].is_null() {
                let edits = serde_json::from_value(r["post_edits"].clone())
                    .map_err(|_| err("review_composition"))?;
                book = crate::edit_checkpoint::apply(book, &edits)?.0;
            }
            let c: Catalog = serde_json::from_value(r["catalog_snapshot"].clone())
                .map_err(|_| err("catalog_snapshot_invalid"))?;
            validate_snapshot(&c)?;
            if r["identity_confirmed"] != true {
                return Err(err("confirm_book_identity_and_scope"));
            }
            Ok(
                json!({"stage":"aligned","plan":crate::catalog_repair::preview(&source,&book,&c,&r["choices"],r["reorder"]==true)?}),
            )
        }
        "preview" | "commit" => {
            let c = if r["catalog_snapshot"].is_object() {
                let c: Catalog = serde_json::from_value(r["catalog_snapshot"].clone())
                    .map_err(|_| err("catalog_snapshot_invalid"))?;
                validate_snapshot(&c)?;
                if c.id != string(&r, "catalog_id") {
                    return Err(err("catalog_snapshot_invalid"));
                }
                c
            } else {
                get_catalog(&string(&r, "catalog_id"))?
            };
            let source = service.source(
                &string(&r, "source_id"),
                r["revision"].as_u64().unwrap_or(0) as u32,
            )?;
            let plan = align_with_options(
                &source,
                &c,
                r["identity_confirmed"] == true,
                &r["choices"],
                r["reorder"] == true,
            )?;
            if r["op"] == "preview" {
                return Ok(json!({"stage":"aligned","plan":plan}));
            }
            if r["confirmed"] != true
                || r["plan_id"] != plan.plan_id
                || (plan.edits.is_empty() && plan.relocation.is_none())
            {
                return Err(err("confirm_current_nonempty_plan"));
            }
            let output = render(&source, &plan)?;
            let path = string(&r, "output_path");
            let report = apply_new_file_bytes(
                string(&r, "source_path"),
                &path,
                &output,
                &plan.source_id,
                InjectFault::None,
            )?;
            let actual = std::fs::read(&path).map_err(|_| err("output_recheck_failed"))?;
            if actual != output {
                return Err(err("output_recheck_failed"));
            }
            let recheck = SourceSnapshot::from_bytes(
                actual,
                easypub_core::encoding::EncodingMode::Auto,
                easypub_core::source::RULE_ID,
                || false,
            )?;
            Ok(
                json!({"stage":"result","committed":true,"source_unchanged":report.source_unchanged,"output_path":path,"output_sha256":report.output_sha256,"transaction_dir":report.transaction_dir,"executed":plan.edits.len()+plan.relocation.as_ref().map(|r|r.pieces.len()).unwrap_or(0),"recheck":align(&recheck,&c,true)?}),
            )
        }
        _ => Err(err("unsupported_operation")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn src(text: &str) -> SourceSnapshot {
        SourceSnapshot::from_utf8(
            text.as_bytes().to_vec(),
            easypub_core::source::RULE_ID,
            || false,
        )
        .unwrap()
    }
    #[test]
    fn volume_insert_preserves_all_body_and_requires_confirmation() {
        let c = parse_text(
            "第一卷 起\n第一章 甲\n第二卷 续\n第二章 乙",
            "书",
            "作者",
            "paste",
            Some(2),
        )
        .unwrap();
        let source = src("前言\r\n第一章 甲\r\n独有正文甲\n第二章 乙\n独有正文乙");
        assert!(align(&source, &c, false).is_err());
        let plan = align(&source, &c, true).unwrap();
        assert_eq!(plan.edits.len(), 2);
        let bytes = render(&source, &plan).unwrap();
        assert_eq!(
            String::from_utf8(bytes).unwrap(),
            "前言\r\n第一卷 起\r\n第一章 甲\r\n独有正文甲\n第二卷 续\r\n第二章 乙\n独有正文乙"
        );
    }
    #[test]
    fn ambiguity_missing_body_and_partial_catalog_do_not_invent() {
        let c = parse_text(
            "第一卷 起\n第一章 同名\n第二卷 续\n第一章 同名\n第二章 缺失",
            "书",
            "",
            "paste",
            Some(4),
        )
        .unwrap();
        let p = align(&src("第一章 同名\n正文"), &c, true).unwrap();
        assert!(p.edits.is_empty());
        assert_eq!(p.matched, 0);
        assert!(
            p.unresolved
                .iter()
                .any(|v| v["reason"] == "ambiguous_cross_volume")
        );
    }
    #[test]
    fn wrong_order_never_reorders_bodies() {
        let c = parse_text(
            "第一卷 起\n第一章 甲\n第二卷 续\n第二章 乙",
            "书",
            "",
            "paste",
            Some(2),
        )
        .unwrap();
        let s = src("第二章 乙\n正文乙\n第一章 甲\n正文甲");
        let p = align(&s, &c, true).unwrap();
        assert!(p.edits.is_empty());
        assert_eq!(render(&s, &p).unwrap(), s.original_bytes());
    }
    #[test]
    fn real_volume_intro_is_preserved_and_not_reassigned() {
        let c = parse_text(
            "第一卷 起\n第一章 甲\n第二卷 续\n第二章 乙",
            "书",
            "",
            "paste",
            Some(2),
        )
        .unwrap();
        let s = src("第一卷 起\n卷首正文\n第一章 甲\n甲\n第二卷 续\n卷首乙\n第二章 乙\n乙");
        let p = align(&s, &c, true).unwrap();
        assert!(p.edits.is_empty());
        assert_eq!(p.matched, 2);
        assert_eq!(render(&s, &p).unwrap(), s.original_bytes());
    }
    #[test]
    fn qidian_payload_identity_and_partial_are_checked() {
        let h = r#"<script id="vite-plugin-ssr_pageContext">{"pageContext":{"pageProps":{"pageData":{"bookId":100,"bookName":"测试","chapterTotalCnt":2,"vs":[{"vId":8,"vN":"正文卷","cs":[{"id":9,"cN":"第一章 甲"}]}]}}}}</script>"#;
        let c = parse_qidian(h, "100", "fixture").unwrap();
        assert_eq!(c.completeness, "partial");
        assert_eq!(c.entries[0].volume_id, "8");
        assert!(parse_qidian(h, "101", "fixture").is_err());
        assert!(book_url("https://evil.test/?qidian.com/book/100").is_err());
        assert_eq!(
            parse_qidian("captcha", "100", "fixture")
                .unwrap_err()
                .next_action,
            "verification_required"
        );
    }
    #[test]
    fn qidian_paid_partition_is_not_a_new_volume_but_new_named_paid_part_is() {
        let h = r#"<script id="vite-plugin-ssr_pageContext">{"pageData":{"bookId":100,"chapterTotalCnt":4,"vs":[{"vId":1,"vN":"小丑","vS":0,"hS":false,"cs":[{"id":1,"cN":"第一章 甲"}]},{"vId":2,"vN":"小丑","vS":1,"hS":true,"cs":[{"id":2,"cN":"第二章 乙"}]},{"vId":3,"vN":"第二部 无面人","vS":1,"hS":true,"cs":[{"id":3,"cN":"第一章 丙"}]},{"vId":4,"vN":"正文卷","vS":1,"hS":true,"cs":[{"id":4,"cN":"第三章 丁"}]}]}}</script>"#;
        let c = parse_qidian(h, "100", "fixture").unwrap();
        assert_eq!(c.entries[0].volume_kind, "structural");
        assert_eq!(c.entries[1].volume_kind, "access");
        assert_eq!(c.entries[2].volume_kind, "structural");
        assert_eq!(c.entries[3].volume_kind, "access");
    }

    #[test]
    fn explicit_relocation_moves_whole_chapters_and_keeps_volume_intro() {
        let c = parse_text(
            "第一卷 起\n第一章 甲\n第二卷 续\n第二章 乙",
            "书",
            "",
            "paste",
            Some(2),
        )
        .unwrap();
        let s = src("第二卷 续\n卷首乙\n第二章 乙\n乙正文\n第一卷 起\n卷首甲\n第一章 甲\n甲正文");
        let p = align_with_options(&s, &c, true, &Value::Null, true).unwrap();
        assert!(p.relocation.is_some(), "{:?}", p.unresolved);
        assert!(p.edits.is_empty());
        let rendered = String::from_utf8(render(&s, &p).unwrap()).unwrap();
        assert_eq!(
            rendered,
            "第一卷 起\n卷首甲\n第一章 甲\n甲正文\n第二卷 续\n卷首乙\n第二章 乙\n乙正文\n"
        );
        assert!(rendered.contains("卷首甲") && rendered.contains("卷首乙"));
        let projection = project(&s, &p).unwrap();
        assert_eq!(projection.text, rendered);
        let mapped = projection
            .anchors
            .iter()
            .filter(|a| a.inserted.is_none())
            .map(|a| (a.source_line, &projection.text[a.output_start..]))
            .collect::<BTreeMap<_, _>>();
        assert_eq!(mapped.len(), 6);
        assert!(mapped[&6].starts_with("卷首甲"));
        assert!(mapped[&2].starts_with("卷首乙"));
        assert!(mapped[&8].starts_with("甲正文"));
        assert!(mapped[&4].starts_with("乙正文"));
        assert!(!mapped.contains_key(&1) && !mapped.contains_key(&5));
        assert_eq!(
            projection
                .anchors
                .iter()
                .filter(|a| a.inserted == Some("set_volume"))
                .count(),
            2
        );
    }

    #[test]
    fn relocation_cleanup_scope_and_illustrations_follow_original_lines() {
        use easypub_core::{
            publication::IllustrationPosition,
            structure::{Role, Structure},
        };
        let c = parse_text(
            "第一卷 起\n第一章 甲\n第二卷 续\n第二章 乙",
            "书",
            "",
            "paste",
            Some(2),
        )
        .unwrap();
        let s = src("第二卷 续\n卷首乙\n第二章 乙\n乙正文\n第一卷 起\n卷首甲\n第一章 甲\n甲正文");
        let p = align_with_options(&s, &c, true, &Value::Null, true).unwrap();
        let cleanup = json!({"kind":"cleanup","start_line":8,"end_line":8,"pipeline":[{"kind":"literal_replace","find":"正文","replace":"修正文"}]}).to_string();
        let book = compose(&s, &p, &Structure::new(&s), Some(&cleanup)).unwrap();
        assert_eq!(
            book.text,
            "第一卷 起\n卷首甲\n第一章 甲\n甲修正文\n第二卷 续\n卷首乙\n第二章 乙\n乙正文\n"
        );
        assert_eq!(
            book.tree
                .nodes
                .iter()
                .filter(|n| n.role == Role::Volume)
                .count(),
            2
        );
        assert_eq!(
            book.illustration_position(&s.summary().source_id, Some(8))
                .unwrap(),
            IllustrationPosition::AfterLine {
                source_line: 8,
                output_line: 4
            }
        );
        assert_eq!(
            book.illustration_position(&s.summary().source_id, Some(4))
                .unwrap(),
            IllustrationPosition::AfterLine {
                source_line: 4,
                output_line: 8
            }
        );
        assert_eq!(
            book.illustration_position(&s.summary().source_id, Some(5))
                .unwrap(),
            IllustrationPosition::NeedsRelocation { source_line: 5 }
        );
    }

    #[test]
    fn composition_selection_requires_current_plan_and_confirmation() {
        let c = parse_text("第一章 甲\n第二章 乙", "书", "", "paste", Some(2)).unwrap();
        let s = src("第二章 乙\n乙正文\n第一章 甲\n甲正文");
        let p = align_with_options(&s, &c, true, &Value::Null, true).unwrap();
        let mut selection = CompositionSelection {
            snapshot: c,
            choices: Value::Null,
            reorder: true,
            plan_id: p.plan_id,
            confirmed: true,
        };
        assert!(selection.resolve(&s).is_ok());
        let request = json!({
            "source_id":s.summary().source_id,"revision":s.summary().revision,
            "settings":{"title":"书","author":"作者","description":"","cover_path":null,"cover_fit":"contain","font_family":"SimSun","font_size":18.0,"line_height":1.8,"include_toc":true,"illustrations":[]},
            "catalog":{"snapshot":selection.snapshot,"choices":null,"reorder":true,"plan_id":selection.plan_id,"confirmed":true}
        });
        let resources = crate::publication_resources::prepare(
            &s,
            serde_json::from_value(request.clone()).unwrap(),
        )
        .unwrap();
        assert_eq!(
            resources.book().text,
            "第一章 甲\n甲正文\n第二章 乙\n乙正文\n"
        );
        let mut conflict = request;
        conflict["manual"] = json!({"kind":"manual_batch","actions":[{"kind":"rename_title","source_line":1,"title":"第二章 新乙"}]});
        let edited =
            crate::publication_resources::prepare(&s, serde_json::from_value(conflict).unwrap())
                .unwrap();
        assert_eq!(
            edited.book().text,
            "第一章 甲\n甲正文\n第二章 新乙\n乙正文\n"
        );
        selection.confirmed = false;
        assert!(selection.resolve(&s).is_err());
        selection.confirmed = true;
        selection.reorder = false;
        assert!(selection.resolve(&s).is_err());
        selection.reorder = true;
        assert!(
            selection
                .resolve(&src("第一章 甲\n甲文\n第二章 乙\n乙文"))
                .is_err()
        );
    }

    #[test]
    fn catalog_manual_split_cleanup_and_images_share_original_coordinates() {
        use easypub_core::{
            publication::{IllustrationPosition, compose_projected_with_cleanup, edit_projection},
            structure::Structure,
        };
        let c = parse_text("第一章 甲\n第二章 乙", "书", "", "paste", Some(2)).unwrap();
        let s = src("第二章 乙\n乙正文\n第一章 甲\n甲正文\n后半正文");
        let p = align_with_options(&s, &c, true, &Value::Null, true).unwrap();
        let st = Structure::new(&s);
        let manual = json!({"kind":"manual_batch","actions":[{"kind":"split_chapter","source_line":5,"title":"第三章 后半"},{"kind":"rename_title","source_line":1,"title":"第二章 新乙"}]}).to_string();
        let projection = edit_projection(&s, &st, project(&s, &p).unwrap(), &manual).unwrap();
        let cleanup = json!({"kind":"cleanup","start_line":5,"end_line":5,"pipeline":[{"kind":"literal_replace","find":"正文","replace":"修正文"}]}).to_string();
        let book = compose_projected_with_cleanup(&s, &st, projection, Some(&cleanup)).unwrap();
        assert_eq!(
            book.text,
            "第一章 甲\n甲正文\n第三章 后半\n后半修正文\n第二章 新乙\n乙正文\n"
        );
        assert_eq!(
            book.illustration_position(&s.summary().source_id, Some(5))
                .unwrap(),
            IllustrationPosition::AfterLine {
                source_line: 5,
                output_line: 4
            }
        );
        let exclusion = json!({"kind":"manual_batch","actions":[{"kind":"exclude_lines","source_line":2,"end_line":4}]}).to_string();
        assert!(edit_projection(&s, &st, project(&s, &p).unwrap(), &exclusion).is_err());
    }

    #[test]
    fn relocated_join_maps_both_original_lines_to_one_output_line() {
        use easypub_core::{publication::IllustrationPosition, structure::Structure};
        let c = parse_text("第一章 甲\n第二章 乙", "书", "", "paste", Some(2)).unwrap();
        let s = src("第二章 乙\n乙正文。\n第一章 甲\n这是足够长的断\n行正文。\n");
        let p = align_with_options(&s, &c, true, &Value::Null, true).unwrap();
        assert!(p.relocation.is_some());
        let cleanup = json!({"kind":"cleanup","pipeline":[{"kind":"join_hard_wraps","mode":"chinese","min_chars":4}]}).to_string();
        let book = compose(&s, &p, &Structure::new(&s), Some(&cleanup)).unwrap();
        assert_eq!(
            book.text,
            "第一章 甲\n这是足够长的断行正文。\n第二章 乙\n乙正文。\n"
        );
        for source_line in [4, 5] {
            assert_eq!(
                book.illustration_position(&s.summary().source_id, Some(source_line))
                    .unwrap(),
                IllustrationPosition::AfterLine {
                    source_line,
                    output_line: 2
                }
            );
        }
    }

    #[test]
    fn relocation_rejects_unproven_introduction_and_incomplete_catalog() {
        let c = parse_text(
            "第一卷 起\n第一章 甲\n第二卷 续\n第二章 乙",
            "书",
            "",
            "paste",
            Some(2),
        )
        .unwrap();
        let source = src("第一卷 起\n这一段属于第一卷\n第二章 乙\n乙正文\n第一章 甲\n甲正文");
        let plan = align_with_options(&source, &c, true, &Value::Null, true).unwrap();
        assert!(plan.relocation.is_none());
        assert!(
            plan.unresolved
                .iter()
                .any(|v| v["reason"] == "volume_intro_requires_review")
        );
        assert_eq!(render(&source, &plan).unwrap(), source.original_bytes());
        let unknown = parse_text("第一卷 起\n第一章 甲", "书", "", "paste", None).unwrap();
        let source = src("第一章 甲\n甲正文");
        let plan = align_with_options(&source, &unknown, true, &Value::Null, true).unwrap();
        assert!(plan.edits.is_empty() && plan.relocation.is_none());
    }

    #[test]
    fn explicit_same_title_choices_bind_different_bodies_and_plan_identity() {
        let c = parse_text(
            "第一卷 起\n第一章 同名\n第二卷 续\n第一章 同名",
            "书",
            "",
            "paste",
            Some(2),
        )
        .unwrap();
        let source = src("第一章 同名\n乙正文\n第一章 同名\n甲正文");
        let pending = align_with_options(&source, &c, true, &Value::Null, true).unwrap();
        assert!(pending.relocation.is_none());
        let choices = json!({"1":c.entries[1].id,"3":c.entries[0].id});
        let plan = align_with_options(&source, &c, true, &choices, true).unwrap();
        assert!(plan.relocation.is_some());
        let output = String::from_utf8(render(&source, &plan).unwrap()).unwrap();
        assert!(output.find("甲正文").unwrap() < output.find("乙正文").unwrap());
        assert_eq!(output.matches("甲正文").count(), 1);
        assert_eq!(output.matches("乙正文").count(), 1);
        assert_ne!(plan.plan_id, pending.plan_id);
        assert!(align_with_options(&source, &c, true, &json!({"99":"missing"}), true).is_err());
    }

    #[test]
    fn relocation_preserves_encoding_bom_and_cr_only_lines() {
        use easypub_core::encoding::{EncodingKind, EncodingMode, decode, encode};
        let c = parse_text(
            "第一卷 起\n第一章 甲\n第二卷 续\n第二章 乙",
            "书",
            "",
            "paste",
            Some(2),
        )
        .unwrap();
        for kind in [
            EncodingKind::Utf8,
            EncodingKind::Utf16Le,
            EncodingKind::Utf16Be,
            EncodingKind::Utf32Le,
            EncodingKind::Utf32Be,
            EncodingKind::Cp936,
        ] {
            let bytes = encode(
                "第二章 乙\r乙正文\r第一章 甲\r甲正文",
                kind,
                kind != EncodingKind::Cp936,
            )
            .unwrap();
            let source = SourceSnapshot::from_bytes(
                bytes.clone(),
                EncodingMode::Auto,
                easypub_core::source::RULE_ID,
                || false,
            )
            .unwrap();
            let plan = align_with_options(&source, &c, true, &Value::Null, true).unwrap();
            let output = render(&source, &plan).unwrap();
            let result = decode(&output, EncodingMode::Auto).unwrap();
            assert_eq!(result.encoding, kind);
            assert_eq!(result.bom, decode(&bytes, EncodingMode::Auto).unwrap().bom);
            assert_eq!(
                result.text,
                "第一卷 起\r第一章 甲\r甲正文\r第二卷 续\r第二章 乙\r乙正文\r"
            );
            assert_eq!(source.original_bytes(), bytes);
        }
    }

    #[test]
    fn repeated_reference_segment_is_one_review_then_explicitly_removed() {
        let titles: Vec<_> = (1..=1834).map(|n| format!("第{n}章 标题{n}")).collect();
        let mut pasted = titles.clone();
        pasted.extend_from_slice(&titles[2..]);
        let c = parse_text(&pasted.join("\n"), "书", "", "paste", Some(1834)).unwrap();
        let source = src(&titles
            .iter()
            .map(|t| format!("{t}\n正文\n"))
            .collect::<String>());
        let duplicates = duplicate_segments(&c);
        assert_eq!(duplicates.len(), 1);
        assert_eq!(duplicates[0].start, 1834);
        assert_eq!(duplicates[0].length, 1832);
        let p = align(&source, &c, true).unwrap();
        assert_eq!(p.unresolved.len(), 1);
        assert_eq!(
            p.unresolved[0]["reason"],
            "duplicate_catalog_segments_require_review"
        );
        assert!(p.edits.is_empty());
        assert_eq!(render(&source, &p).unwrap(), source.original_bytes());
        assert!(remove_duplicate_segments(&c, &[1834], false).is_err());
        assert!(remove_duplicate_segments(&c, &[1835], true).is_err());
        let cleaned = remove_duplicate_segments(&c, &[1834], true).unwrap();
        assert_eq!(cleaned.entries.len(), 1834);
        assert_eq!(c.entries.len(), 3666);
        assert_eq!(cleaned.completeness, "complete");
        validate_snapshot(&cleaned).unwrap();
        let ready = align(&source, &cleaned, true).unwrap();
        assert_eq!(ready.matched, 1834);
        assert!(ready.unresolved.is_empty());
        assert_eq!(render(&source, &ready).unwrap(), source.original_bytes());
    }

    #[test]
    fn duplicate_review_does_not_drop_same_named_chapters_or_distinct_volumes() {
        let c = parse_text("第一卷 甲\n第一章 同名\n第二章 继续\n第三章 结束\n第二卷 乙\n第一章 同名\n第二章 继续\n第三章 结束", "书", "", "paste", Some(6)).unwrap();
        assert!(duplicate_segments(&c).is_empty());
        let repeated_title = parse_text(
            "第一章 同名\n第一章 同名\n第一章 同名\n第一章 同名\n第一章 同名\n第一章 同名",
            "书",
            "",
            "paste",
            Some(6),
        )
        .unwrap();
        assert!(duplicate_segments(&repeated_title).is_empty());
        assert!(remove_duplicate_segments(&c, &[3], true).is_err());
        let partial = parse_text(
            "第一章 甲\n第二章 乙\n第三章 丙\n第一章 甲\n第二章 乙\n第三章 丙",
            "书",
            "",
            "paste",
            Some(6),
        )
        .unwrap();
        let cleaned = remove_duplicate_segments(&partial, &[3], true).unwrap();
        assert_eq!(cleaned.total, Some(6));
        assert_eq!(cleaned.completeness, "partial");
        let full = src(
            "第一章 甲\n正文一\n第二章 乙\n正文二\n第三章 丙\n正文三\n第一章 甲\n正文四\n第二章 乙\n正文五\n第三章 丙\n正文六",
        );
        let plan = align(&full, &partial, true).unwrap();
        assert!(
            !plan
                .unresolved
                .iter()
                .any(|v| v["reason"] == "duplicate_catalog_segments_require_review")
        );
        assert_eq!(render(&full, &plan).unwrap(), full.original_bytes());
    }
}

#[cfg(test)]
mod cancellation_tests {
    use super::*;
    use std::{
        io::{Read, Write},
        net::TcpListener,
        sync::mpsc,
        thread,
        time::Instant,
    };

    #[test]
    fn registered_request_cancellation_rejects_late_start_and_is_idempotent() {
        let id = begin_request().unwrap()["request_id"]
            .as_str()
            .unwrap()
            .to_owned();
        let request = json!({"request_id":id,"source":"paste","input":"第一章 测试"});
        let token = request_token(&request).unwrap();
        cancel_request(&id).unwrap();
        assert!(token.is_cancelled());
        assert!(acquire(&request, "").is_err());
        cancel_request(&id).unwrap();
        let next = begin_request().unwrap()["request_id"]
            .as_str()
            .unwrap()
            .to_owned();
        assert!(
            !request_token(&json!({"request_id":next}))
                .unwrap()
                .is_cancelled()
        );
        cancel_request(&next).unwrap();
    }

    fn cancel_network(headers: bool) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/", listener.local_addr().unwrap());
        let (ready_tx, ready_rx) = mpsc::channel();
        let body_ready = ready_tx.clone();
        let server = thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(4)))
                .unwrap();
            let mut request = Vec::new();
            let mut byte = [0];
            while !request.ends_with(b"\r\n\r\n") {
                socket.read_exact(&mut byte).unwrap();
                request.push(byte[0]);
            }
            if headers {
                socket
                    .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 100000\r\n\r\nx")
                    .unwrap();
            }
            if !headers {
                ready_tx.send(()).unwrap();
            }
            // A cancelled fetch must close the transport, not just hide its result.
            match socket.read(&mut byte) {
                Ok(0) => (),
                Err(e)
                    if [
                        std::io::ErrorKind::ConnectionReset,
                        std::io::ErrorKind::ConnectionAborted,
                    ]
                    .contains(&e.kind()) => {}
                other => panic!("connection remained open: {other:?}"),
            }
        });
        let token = tokio_util::sync::CancellationToken::new();
        let worker_token = token.clone();
        let worker = thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            runtime.block_on(fetch_response_observed(
                reqwest::Client::new(),
                &url,
                "",
                &worker_token,
                || {
                    if headers {
                        body_ready.send(()).unwrap();
                    }
                },
            ))
        });
        ready_rx.recv_timeout(Duration::from_secs(4)).unwrap();
        let started = Instant::now();
        token.cancel();
        let error = worker.join().unwrap().unwrap_err();
        assert_eq!(error.next_action, "catalog_cancelled");
        assert!(started.elapsed() < Duration::from_secs(2));
        server.join().unwrap();
    }
    #[test]
    fn cancellation_aborts_waiting_headers_and_closes_socket() {
        cancel_network(false);
    }
    #[test]
    fn cancellation_aborts_waiting_body_and_closes_socket() {
        cancel_network(true);
    }
}

#[cfg(test)]
mod text_capacity_tests {
    use super::*;
    #[test]
    fn oversized_groups_and_entry_counts_fail_without_building_unbounded_entries() {
        for text in [
            format!("## {}\n第一章 一", "卷".repeat(4096)),
            format!("第一章 {}", "字".repeat(4096)),
            (0..=MAX_ENTRIES)
                .map(|i| format!("第{}章 标题\n", i + 1))
                .collect::<String>(),
        ] {
            assert_eq!(
                parse_text(&text, "书", "", "paste", None)
                    .unwrap_err()
                    .next_action,
                "catalog_too_large"
            );
        }
    }
    #[test]
    fn cancelled_text_parser_rejects_input_before_creating_catalog() {
        let token = tokio_util::sync::CancellationToken::new();
        token.cancel();
        assert_eq!(
            parse_text_cancellable("第一章 甲", "书", "", "paste", None, &token)
                .unwrap_err()
                .next_action,
            "catalog_cancelled"
        );
    }
}

#[cfg(test)]
mod effective_reorder_tests {
    use super::*;
    use easypub_core::{
        effective_edit::{self, Action, Request},
        publication::{self, IllustrationPosition},
        structure::Structure,
    };
    fn exercise(
        text: &str,
        catalog: &str,
        expected: &str,
        image_source_line: u32,
        image_output_line: u32,
    ) {
        let source = SourceSnapshot::from_utf8(
            text.as_bytes().to_vec(),
            easypub_core::source::RULE_ID,
            || false,
        )
        .unwrap();
        let catalog = parse_text(catalog, "书", "", "paste", Some(3)).unwrap();
        let plan = align_with_options(&source, &catalog, true, &Value::Null, true).unwrap();
        assert!(plan.relocation.is_some(), "{:?}", plan.unresolved);
        let selection = CompositionSelection {
            snapshot: catalog,
            choices: Value::Null,
            reorder: true,
            plan_id: plan.plan_id,
            confirmed: true,
        };
        let initial = publication::compose_with_cleanup(
            &source,
            &Structure::new(&source),
            None,
            Some(r#"{"kind":"cleanup","pipeline":[{"kind":"trim_trailing_spaces"}]}"#),
        )
        .unwrap();
        let beta = initial
            .tree
            .nodes
            .iter()
            .find(|n| n.title == "第二章 乙")
            .unwrap()
            .entry_id
            .clone();
        let base_id = effective_edit::base_id(&initial);
        let (edited, _) = effective_edit::apply(
            initial,
            &Request {
                base_id,
                actions: vec![Action::Rename {
                    entry_id: beta.clone(),
                    title: "手工标题乙".into(),
                }],
            },
        )
        .unwrap();
        let actions = effective_actions(&source, &edited, &selection).unwrap();
        assert!(matches!(actions[0], Action::Reorder { .. }));
        let base_id = effective_edit::base_id(&edited);
        let (result, _) = effective_edit::apply(edited, &Request { base_id, actions }).unwrap();
        assert_eq!(result.text, expected);
        assert_eq!(
            result
                .tree
                .nodes
                .iter()
                .find(|n| n.entry_id == beta)
                .unwrap()
                .title,
            "手工标题乙"
        );
        assert_eq!(
            result
                .illustration_position(&source.summary().source_id, Some(image_source_line))
                .unwrap(),
            IllustrationPosition::AfterLine {
                source_line: image_source_line,
                output_line: image_output_line
            }
        );
        assert_eq!(source.original_bytes(), text.as_bytes());
    }
    #[test]
    fn reordered_current_chapters_keep_manual_titles_cleaned_body_and_image_anchors() {
        exercise(
            "第二章 乙\n乙文  \n第一章 甲\n甲文  \n第三章 丙\n丙文  \n",
            "第一卷 起\n第一章 甲\n第二章 乙\n第二卷 终\n第三章 丙",
            "第一卷 起\n第一章 甲\n甲文\n手工标题乙\n乙文\n第二卷 终\n第三章 丙\n丙文\n",
            2,
            5,
        );
    }
    #[test]
    fn existing_volume_headers_and_introductions_travel_with_proven_first_chapter() {
        exercise(
            "第二卷 终\n终卷引言\n第三章 丙\n丙文  \n第一卷 起\n起卷引言\n第一章 甲\n甲文  \n第二章 乙\n乙文  \n",
            "第一卷 起\n第一章 甲\n第二章 乙\n第二卷 终\n第三章 丙",
            "第一卷 起\n起卷引言\n第一章 甲\n甲文\n手工标题乙\n乙文\n第二卷 终\n终卷引言\n第三章 丙\n丙文\n",
            10,
            6,
        );
    }
}
