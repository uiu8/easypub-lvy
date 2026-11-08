//! 仅显式调用的录制/回放工具。正文尾部保存长度占位，回放扩展为自拟文字。
use crate::{
    control::{Context, Profile},
    engine::{Engine, SourceRt},
    net::{Request, Response},
    source::{self, BookSource},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    io::{Read, Write},
    net::TcpListener,
    path::Path,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Exchange {
    stage: String,
    method: String,
    url: String,
    body: Option<String>,
    charset: Option<String>,
    request_headers: Vec<(String, String)>,
    status: u16,
    final_url: String,
    headers: Vec<(String, String)>,
    text: String,
}
#[derive(Default)]
pub struct Tape {
    pub stage: Mutex<String>,
    entries: Mutex<Vec<Exchange>>,
    secrets: Mutex<Vec<String>>,
    playback: Option<String>,
    consumed: Mutex<Vec<bool>>,
}
fn hash(bytes: impl AsRef<[u8]>) -> String {
    hex::encode(Sha256::digest(bytes))
}
fn allowed_header(name: &str) -> bool {
    matches!(
        name.to_ascii_lowercase().as_str(),
        "content-type" | "location" | "accept" | "user-agent"
    )
}
fn body_key(req: &Request) -> Option<String> {
    req.body
        .as_ref()
        .map(|b| crate::net::decode(b, req.charset.as_deref(), ""))
}
impl Tape {
    pub fn check_browser_snapshot(&self, html: &str) -> Result<(), String> {
        if regex::Regex::new(r#"(?is)<script\b[^>]*\bsrc\s*="#)
            .unwrap()
            .is_match(html)
        {
            return Err("样本浏览器快照含外部脚本，请使用独立手写夹具覆盖".into());
        }
        Ok(())
    }
    pub fn request(&self, req: &Request) -> Result<Option<Request>, String> {
        let Some(base) = &self.playback else {
            return Ok(None);
        };
        let entries = self.entries.lock().unwrap();
        let mut consumed = self.consumed.lock().unwrap();
        let index = entries
            .iter()
            .enumerate()
            .position(|(i, e)| {
                !consumed[i]
                    && e.url == req.url
                    && e.method == req.method
                    && e.body == body_key(req)
            })
            .ok_or("离线样本没有匹配的请求，禁止回退联网")?;
        consumed[index] = true;
        let mut mapped = req.clone();
        mapped.url = format!("{base}/{index}");
        mapped.method = "GET".into();
        mapped.body = None;
        mapped.headers.clear();
        mapped.proxy = None;
        mapped.network = Some(crate::network_config::ProxyConfig {
            mode: "none".into(),
            ..Default::default()
        });
        Ok(Some(mapped))
    }
    pub fn finish(
        &self,
        original: &Request,
        mapped: Option<&Request>,
        response: &mut Response,
    ) -> Result<(), String> {
        if let Some(mapped) = mapped {
            let index = mapped
                .url
                .rsplit('/')
                .next()
                .and_then(|s| s.parse::<usize>().ok())
                .ok_or("回放索引无效")?;
            response.url = self.entries.lock().unwrap()[index].final_url.clone();
            return Ok(());
        }
        let mut secrets = self.secrets.lock().unwrap();
        for (name, value) in response.headers.iter().chain(original.headers.iter()) {
            if name.eq_ignore_ascii_case("set-cookie") {
                if let Some((_, v)) = value.split(';').next().unwrap_or("").split_once('=')
                    && !v.is_empty()
                {
                    secrets.push(v.into());
                }
            } else if matches!(
                name.to_ascii_lowercase().as_str(),
                "cookie" | "authorization" | "proxy-authorization"
            ) {
                secrets.push(value.clone());
                for part in value.split(';') {
                    if let Some((_, v)) = part.split_once('=')
                        && !v.is_empty()
                    {
                        secrets.push(v.trim().into());
                    }
                }
            }
        }
        drop(secrets);
        let mut entries = self.entries.lock().unwrap();
        if entries.iter().map(|e| e.text.len()).sum::<usize>() + response.text.len()
            > 64 * 1024 * 1024
        {
            return Err("录制响应超过 64 MiB，本样本不落盘".into());
        }
        entries.push(Exchange {
            stage: self.stage.lock().unwrap().clone(),
            method: original.method.clone(),
            url: original.url.clone(),
            body: body_key(original),
            charset: original.charset.clone(),
            request_headers: original
                .headers
                .iter()
                .filter(|(k, _)| allowed_header(k))
                .cloned()
                .collect(),
            status: response.status,
            final_url: response.url.clone(),
            headers: response
                .headers
                .iter()
                .filter(|(k, _)| allowed_header(k))
                .cloned()
                .collect(),
            text: response.text.clone(),
        });
        Ok(())
    }
}
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Expected {
    name: String,
    author: String,
    chapters: usize,
    first_chapter: String,
    chars: Vec<usize>,
    prefixes: Vec<String>,
    hashes: Vec<String>,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Corpus {
    format: u32,
    keyword: String,
    origin: String,
    coverage: Vec<String>,
    note: String,
    expected: Expected,
    exchanges: Vec<Exchange>,
}
fn flow(source: BookSource, keyword: &str, tape: Arc<Tape>) -> Result<Expected, String> {
    let mut ctx = Context::new(Profile::Detail, Arc::new(AtomicBool::new(false)));
    ctx.deadline = Some(Instant::now() + Duration::from_secs(120));
    ctx.interactive = false;
    ctx.corpus = Some(tape.clone());
    let _guard = ctx.enter();
    let engine = Engine::new(SourceRt::new(source))?;
    engine.run(|s| {
        *tape.stage.lock().unwrap() = "search".into();
        let mut book = s
            .search(keyword, 1)?
            .into_iter()
            .next()
            .ok_or("样本搜索没有结果")?;
        *tape.stage.lock().unwrap() = "detail".into();
        s.book_info(&mut book)?;
        *tape.stage.lock().unwrap() = "toc".into();
        let toc = s.toc(&book)?;
        let mut expected = Expected {
            name: book.name.clone(),
            author: book.author.clone(),
            chapters: toc.iter().filter(|c| !c.is_volume).count(),
            first_chapter: toc
                .iter()
                .find(|c| !c.is_volume)
                .map(|c| c.title.clone())
                .unwrap_or_default(),
            ..Default::default()
        };
        let selected: Vec<_> = toc
            .iter()
            .enumerate()
            .filter(|(_, c)| !c.is_volume && !c.is_pay && !c.is_vip)
            .take(3)
            .collect();
        let batch = if s.source().batch_size() > 1 {
            *tape.stage.lock().unwrap() = "content-batch".into();
            s.chapter_batch(
                &book,
                &selected
                    .iter()
                    .map(|(_, c)| (*c).clone())
                    .collect::<Vec<_>>(),
            )?
        } else {
            Default::default()
        };
        for (i, c) in selected {
            *tape.stage.lock().unwrap() = format!("content-{}", expected.chars.len());
            let text = match batch.get(&c.url) {
                Some(text) => text.clone(),
                None => s.chapter_content(
                    &book,
                    c,
                    toc.get(i + 1).map(|c| c.url.as_str()).unwrap_or(""),
                )?,
            };
            let chars = crate::scheduler::chars(&text);
            if chars == 0 {
                return Err("样本没有解析出正文".into());
            }
            expected.chars.push(chars);
            expected.prefixes.push(text.chars().take(300).collect());
            expected.hashes.push(hash(text.as_bytes()));
        }
        if expected.chars.is_empty() {
            return Err("样本没有免费正文".into());
        }
        Ok(expected)
    })
}
fn redact_string(s: &str, budget: &mut usize) -> String {
    let total = s.chars().count();
    let keep = total.min(*budget);
    *budget -= keep;
    if keep == total {
        return s.into();
    }
    let prefix: String = s.chars().take(keep).collect();
    // 只用非空白数量补自拟字，维持正文统计，原尾部文字不进入项目文件。
    let rest: String = s.chars().skip(keep).collect();
    let tail = crate::scheduler::chars(&crate::text::html_to_text(&rest));
    format!("{prefix}__EP_TEXT_{tail}__")
}
fn redact_json(v: &mut Value, budget: &mut usize) {
    match v {
        Value::String(s) => {
            if !s.starts_with("http") && !s.starts_with('/') {
                *s = if s.contains('<') && s.contains('>') {
                    redact_content(s, budget)
                } else {
                    redact_string(s, budget)
                };
            }
        }
        Value::Array(a) => {
            for v in a {
                redact_json(v, budget);
            }
        }
        Value::Object(o) => {
            for (key, v) in o {
                if ![
                    "url",
                    "href",
                    "next",
                    "nextPage",
                    "nextUrl",
                    "chapterUrl",
                    "id",
                ]
                .contains(&key.as_str())
                {
                    redact_json(v, budget);
                }
            }
        }
        _ => (),
    }
}
fn redact_content(text: &str, budget: &mut usize) -> String {
    if let Ok(mut v) = serde_json::from_str::<Value>(text) {
        redact_json(&mut v, budget);
        return v.to_string();
    }
    // 保留选择器所需标签；脚本正文无法可靠分离时拒绝录制，改用注明手写的夹具。
    if regex::Regex::new(r"(?is)<script\b").unwrap().is_match(text) {
        let scripts = regex::Regex::new(r"(?is)<script\b[^>]*>.*?</script\s*>").unwrap();
        let cleaned = scripts.replace_all(text, "");
        return redact_content(&cleaned, budget);
    }
    let tags = regex::Regex::new(r"(?s)<[^>]*>|[^<]+").unwrap();
    let mut navigation = false;
    tags.find_iter(text)
        .map(|m| {
            if m.as_str().starts_with('<') {
                let tag = m.as_str().to_ascii_lowercase();
                if tag.starts_with("</a") {
                    navigation = false;
                } else if tag.starts_with("<a ") || tag == "<a>" {
                    navigation = true;
                }
                m.as_str().to_owned()
            } else if navigation {
                // 翻页链接属于结构，正文截断不能改掉“下一页”等选择器条件。
                m.as_str().to_owned()
            } else {
                redact_string(m.as_str(), budget)
            }
        })
        .collect()
}
fn expand(text: &str) -> String {
    let re = regex::Regex::new(r"__EP_TEXT_(\d{1,8})__").unwrap();
    re.replace_all(text, |c: &regex::Captures| {
        "文".repeat(c[1].parse::<usize>().unwrap().min(1_000_000))
    })
    .into_owned()
}
pub fn record(
    source: Value,
    keyword: &str,
    folder: &Path,
    coverage: Vec<String>,
    origin: String,
) -> Result<Value, String> {
    if folder.exists() {
        return Err("样本目录已存在，请使用新编号".into());
    }
    let mut source = source;
    source::sanitize_json(&mut source);
    let raw = source
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| source.to_string());
    let mut sources = source::import(&raw)?.0;
    if sources.len() != 1 {
        return Err("一次录制只能指定一个书源".into());
    }
    let source = sources.remove(0);
    if !crate::support::can_run(&source) {
        return Err("插件不支持的写法，样本未录制".into());
    }
    let tape = Arc::new(Tape::default());
    let expected = flow(source.clone(), keyword, tape.clone())
        .map_err(|e| crate::probe::reason(&e).to_owned())?;
    let mut entries = tape.entries.lock().unwrap().clone();
    let mut budgets = BTreeMap::new();
    for e in &mut entries {
        if e.stage.starts_with("content-") {
            e.text = redact_content(&e.text, budgets.entry(e.stage.clone()).or_insert(300));
        }
    }
    let corpus = Corpus {
        format: 1,
        keyword: keyword.into(),
        origin,
        coverage,
        note: "正文尾部仅存长度占位；回放补自拟文字，不保存完整原文，不能据此证明原文内容一致"
            .into(),
        expected,
        exchanges: entries,
    };
    let mut encoded = serde_json::to_value(&corpus).unwrap();
    let mut src = serde_json::to_value(source).unwrap();
    source::sanitize_json(&mut src);
    source::sanitize_json(&mut encoded);
    let secrets = tape.secrets.lock().unwrap();
    let clean = |v: &Value| -> String {
        let mut text = serde_json::to_string_pretty(v).unwrap();
        for secret in secrets.iter().filter(|s| s.len() >= 6) {
            let escaped = serde_json::to_string(secret).unwrap();
            text = text.replace(&escaped[1..escaped.len() - 1], "EP_REDACTED");
        }
        text
    };
    std::fs::create_dir_all(folder).map_err(|_| "样本目录不能创建")?;
    std::fs::write(folder.join("source.json"), clean(&src)).map_err(|_| "样本规则不能保存")?;
    std::fs::write(folder.join("exchanges.json"), clean(&encoded))
        .map_err(|_| "样本响应不能保存")?;
    Ok(
        json!({"path":folder,"chapters":corpus.expected.chapters,"chars":corpus.expected.chars,"requests":corpus.exchanges.len(),"coverage":corpus.coverage}),
    )
}
/// 回放只允许命中录制请求，传输指向本机临时服务器；未匹配绝不访问原站。
pub fn replay(folder: &Path) -> Result<Value, String> {
    let source: BookSource = serde_json::from_slice(
        &std::fs::read(folder.join("source.json")).map_err(|_| "缺少 source.json")?,
    )
    .map_err(|_| "样本规则无效")?;
    let corpus: Corpus = serde_json::from_slice(
        &std::fs::read(folder.join("exchanges.json")).map_err(|_| "缺少 exchanges.json")?,
    )
    .map_err(|_| "样本响应无效")?;
    let listener = TcpListener::bind("127.0.0.1:0").map_err(|_| "回放服务不能启动")?;
    listener
        .set_nonblocking(true)
        .map_err(|_| "回放服务不能启动")?;
    let base = format!("http://{}", listener.local_addr().unwrap());
    let entries = corpus.exchanges.clone();
    let stop = Arc::new(AtomicBool::new(false));
    let stopped = stop.clone();
    let server = std::thread::spawn(move || {
        while !stopped.load(Ordering::Relaxed) {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    // Windows 接受的 socket 会继承监听端的非阻塞状态；
                    // 请求尚未到达时 WouldBlock 不能当成 EOF。
                    if stream.set_nonblocking(false).is_err() {
                        continue;
                    }
                    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
                    let mut data = Vec::new();
                    let mut buffer = [0u8; 2048];
                    while data.len() < 16384 && !data.windows(4).any(|b| b == b"\r\n\r\n") {
                        let n = stream.read(&mut buffer).unwrap_or(0);
                        if n == 0 {
                            break;
                        }
                        data.extend_from_slice(&buffer[..n]);
                    }
                    let request = String::from_utf8_lossy(&data);
                    let index = request
                        .split_whitespace()
                        .nth(1)
                        .and_then(|p| p.trim_start_matches('/').parse::<usize>().ok());
                    let Some(e) = index.and_then(|i| entries.get(i)) else {
                        continue;
                    };
                    let text = expand(&e.text);
                    let content_type = e
                        .headers
                        .iter()
                        .find(|(k, _)| k.eq_ignore_ascii_case("content-type"))
                        .map(|(_, v)| v.as_str())
                        .unwrap_or("text/html; charset=utf-8");
                    let encoding = e
                        .charset
                        .as_ref()
                        .and_then(|c| encoding_rs::Encoding::for_label(c.as_bytes()))
                        .unwrap_or_else(|| {
                            if content_type.to_lowercase().contains("gb") {
                                encoding_rs::GBK
                            } else {
                                encoding_rs::UTF_8
                            }
                        });
                    let body = encoding.encode(&text).0.into_owned();
                    let headers = e
                        .headers
                        .iter()
                        .filter(|(k, _)| !k.eq_ignore_ascii_case("content-type"))
                        .map(|(k, v)| format!("{k}: {v}\r\n"))
                        .collect::<String>();
                    let _ = write!(
                        stream,
                        "HTTP/1.1 {} Replay\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n{}\r\n",
                        e.status,
                        content_type,
                        body.len(),
                        headers
                    );
                    let _ = stream.write_all(&body);
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(2))
                }
                Err(_) => break,
            }
        }
    });
    let tape = Arc::new(Tape {
        consumed: Mutex::new(vec![false; corpus.exchanges.len()]),
        entries: Mutex::new(corpus.exchanges),
        playback: Some(base),
        ..Default::default()
    });
    let actual = flow(source, &corpus.keyword, tape.clone());
    stop.store(true, Ordering::Relaxed);
    let _ = server.join();
    let actual = actual.map_err(|e| crate::probe::reason(&e).to_owned())?;
    let expected = &corpus.expected;
    let mismatch = actual.name != expected.name
        || actual.author != expected.author
        || actual.chapters != expected.chapters
        || actual.first_chapter != expected.first_chapter
        || actual.chars.len() != expected.chars.len()
        || actual
            .chars
            .iter()
            .zip(&expected.chars)
            .any(|(a, b)| a.abs_diff(*b) > ((*b as f64 * 0.05).ceil() as usize).max(1));
    if mismatch {
        return Err(format!(
            "回放结果不符：预期章节 {} / 字数 {:?}；实际章节 {} / 字数 {:?}",
            expected.chapters, expected.chars, actual.chapters, actual.chars
        ));
    }
    if tape.consumed.lock().unwrap().iter().any(|v| !*v) {
        return Err("回放没有消费全部录制请求".into());
    }
    Ok(
        json!({"passed":true,"name":actual.name,"chapters":actual.chapters,"chars":actual.chars,"coverage":corpus.coverage}),
    )
}

// 只编译进测试，突变实际选择器分支；线程局部，不能影响并行用例或正式插件。
#[cfg(test)]
thread_local! {static MUTATION:std::cell::Cell<u8>=const {std::cell::Cell::new(0)};}
#[cfg(test)]
pub(crate) fn broken(kind: u8) -> bool {
    MUTATION.with(|m| m.get() == kind)
}
#[test]
fn three_selector_mutations_are_detected() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/corpus");
    for (kind, name) in [(1, "manual-html"), (2, "manual-json"), (3, "manual-xpath")] {
        let path = root.join(name);
        replay(&path).unwrap();
        MUTATION.with(|m| m.set(kind));
        let damaged = replay(&path);
        MUTATION.with(|m| m.set(0));
        assert!(damaged.is_err(), "样本必须拦住实际选择器突变 {name}");
        replay(&path).unwrap();
    }
}
