//! 每个书源一个网络端：Cookie 罐、限速（`concurrentRate`）、重定向、编码识别。
//!
//! Cookie 只在内存里（以后持久化时按凭据规则加密存本机）；错误信息不带 Cookie 与请求头的值。
use crate::control::{self, Context, Profile};
use encoding_rs::Encoding;
use reqwest::{
    Method, Url,
    header::{HeaderMap, HeaderName, HeaderValue},
};
use std::{
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};

pub const MAX_BODY: usize = 16 * 1024 * 1024;
pub const DEFAULT_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36";

#[derive(Clone, Debug, Default)]
pub struct Request {
    pub url: String,
    pub method: String,
    pub body: Option<Vec<u8>>,
    pub headers: Vec<(String, String)>,
    pub charset: Option<String>,
    pub retry: u32,
    pub proxy: Option<String>,
    pub insecure: bool,
    /// 诊断使用未保存的草稿，不改变运行中下载的全局设置。
    pub network: Option<crate::network_config::ProxyConfig>,
    /// 仅连接诊断使用；正式导入/正文仍完整读取并检查 MAX_BODY。
    pub sample_bytes: Option<usize>,
}

#[derive(Clone, Debug, Default)]
pub struct Response {
    /// 跟随重定向后的最终网址。
    pub url: String,
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
    pub text: String,
    pub route: serde_json::Value,
    pub protocol: String,
}
impl Response {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
}

/// `1000` = 两次请求至少间隔 1000 ms；`20/60000` = 每 60000 ms 最多 20 次。
#[derive(Clone, Copy, Debug)]
pub enum Rate {
    Interval(u64),
    Window(u32, u64),
}
impl Rate {
    pub fn parse(text: &str) -> Option<Self> {
        let text = text.trim();
        if let Some((n, ms)) = text.split_once('/') {
            let (n, ms) = (n.trim().parse().ok()?, ms.trim().parse().ok()?);
            (n > 0 && ms > 0).then_some(Self::Window(n, ms))
        } else {
            let ms: u64 = text.parse().ok()?;
            (ms > 0).then_some(Self::Interval(ms))
        }
    }
}

#[derive(Default)]
struct RateState {
    last: Option<Instant>,
    window_start: Option<Instant>,
    count: u32,
}

pub struct Net {
    pub cookies: Mutex<cookie_store::CookieStore>,
    rate: Option<Rate>,
    pub crawl: crate::source::CrawlProfile,
    pub respond_time: i64,
    state: Mutex<RateState>,
    /// 书源请求头（已解析成键值；含 Cookie 时也只在请求里用）。
    pub headers: Vec<(String, String)>,
}

#[derive(Debug)]
pub struct NetError(pub String);
impl std::fmt::Display for NetError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl Net {
    pub fn new(rate: Option<Rate>, headers: Vec<(String, String)>) -> Self {
        Self {
            cookies: Mutex::new(cookie_store::CookieStore::new()),
            rate,
            crawl: Default::default(),
            respond_time: 0,
            state: Mutex::default(),
            headers,
        }
    }

    /// 按书源的并发率等待到可以发下一个请求。
    pub fn wait_turn(&self, context: &Context) -> Result<(), NetError> {
        let Some(rate) = self.rate else { return Ok(()) };
        loop {
            context.check().map_err(NetError)?;
            let mut st = self.state.lock().unwrap();
            let now = Instant::now();
            let wait = match rate {
                Rate::Interval(ms) => st
                    .last
                    .map(|last| Duration::from_millis(ms).saturating_sub(now - last))
                    .unwrap_or_default(),
                Rate::Window(n, ms) => {
                    let window = Duration::from_millis(ms);
                    if st.window_start.is_none_or(|s| now - s >= window) {
                        st.window_start = Some(now);
                        st.count = 0;
                    }
                    if st.count < n {
                        Duration::ZERO
                    } else {
                        window.saturating_sub(now - st.window_start.unwrap())
                    }
                }
            };
            if wait.is_zero() {
                st.last = Some(now);
                st.count += 1;
                return Ok(());
            }
            drop(st);
            context.wait(wait).map_err(NetError)?;
        }
    }

    pub fn cookie_header(&self, url: &Url) -> String {
        self.cookies
            .lock()
            .unwrap()
            .get_request_values(url)
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join("; ")
    }
    pub fn set_cookie(&self, url: &str, cookie: &str) {
        let Ok(url) = Url::parse(url) else { return };
        let mut jar = self.cookies.lock().unwrap();
        for part in cookie.split(';') {
            if part.contains('=') {
                let _ = jar.parse(part.trim(), &url);
            }
        }
    }
    pub fn remove_cookies(&self, url: &str) {
        let Ok(url) = Url::parse(url) else { return };
        let Some(host) = url.host_str() else { return };
        let mut jar = self.cookies.lock().unwrap();
        let names: Vec<(String, String, String)> = jar
            .iter_any()
            .filter(|c| {
                c.domain()
                    .is_some_and(|d| host.ends_with(d.trim_start_matches('.')))
            })
            .map(|c| {
                (
                    c.domain().unwrap_or("").to_owned(),
                    c.path().unwrap_or("/").to_owned(),
                    c.name().to_owned(),
                )
            })
            .collect();
        for (d, p, n) in names {
            jar.remove(&d, &p, &n);
        }
    }

    pub fn fetch(&self, req: &Request) -> Result<Response, NetError> {
        // 重试由下载队列统一调度，URL 规则的 retry 不再叠加整章重试。
        self.fetch_once(req, true)
    }

    /// 不跟随重定向（`java.get` / `java.post` 用来读 Location）。
    pub fn fetch_no_redirect(&self, req: &Request) -> Result<Response, NetError> {
        self.fetch_once(req, false)
    }

    fn fetch_once(&self, req: &Request, follow: bool) -> Result<Response, NetError> {
        static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
        let runtime = RUNTIME.get_or_init(|| {
            tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .expect("HTTP runtime")
        });
        let mut context = control::current();
        context.crawl = self.crawl.clone();
        context.check().map_err(NetError)?;
        let mapped = context
            .corpus
            .as_ref()
            .map(|t| t.request(req))
            .transpose()
            .map_err(NetError)?
            .flatten();
        let mut response = runtime.block_on(async {
            let future = self.fetch_async(
                mapped.as_ref().unwrap_or(req),
                if mapped.is_some() { false } else { follow },
                &context,
            );
            let mut future = std::pin::pin!(future);
            loop {
                context.check().map_err(NetError)?;
                match tokio::time::timeout(Duration::from_millis(40), future.as_mut()).await {
                    Ok(result) => return result,
                    Err(_) => continue,
                }
            }
        })?;
        if let Some(tape) = &context.corpus {
            tape.finish(req, mapped.as_ref(), &mut response)
                .map_err(NetError)?;
        }
        Ok(response)
    }

    async fn fetch_async(
        &self,
        req: &Request,
        follow: bool,
        context: &Context,
    ) -> Result<Response, NetError> {
        let network = req
            .network
            .clone()
            .unwrap_or_else(crate::network_config::current);
        let mut url = Url::parse(&req.url).map_err(|_| NetError("网址无效".into()))?;
        if !matches!(url.scheme(), "http" | "https") {
            return Err(NetError("只支持 http / https 网址".into()));
        }
        let mut method =
            Method::from_bytes(req.method.to_ascii_uppercase().as_bytes()).unwrap_or(Method::GET);
        let mut body = req.body.clone();
        let mut network_time = Duration::ZERO;
        for _ in 0..10 {
            if !matches!(url.scheme(), "http" | "https") {
                return Err(NetError("重定向只支持 HTTP / HTTPS".into()));
            }
            let route =
                crate::network_config::route(&network, &context.crawl, req.proxy.as_deref(), &url)
                    .map_err(NetError)?;
            *context.network_route.lock().unwrap() = route.json();
            let client =
                crate::network_config::client(context.profile, &network, &route, req.insecure)
                    .map_err(NetError)?;
            let queued = Instant::now();
            if !context.batch_rate_reserved && !crate::hosts::local(url.as_str()) {
                self.wait_turn(context)?;
            }
            let host = Some(control::host(
                url.as_str(),
                context
                    .crawl
                    .concurrency
                    .unwrap_or(context.ceiling.unwrap_or(32)),
            ));
            *context.observed_host.lock().unwrap() = host.clone();
            let _permit = host
                .as_ref()
                .map(|h| h.acquire(context))
                .transpose()
                .map_err(NetError)?;
            // 主动限流的排队时间不算网站响应超时，否则降速本身会制造新的超时。
            // 搜索的整源期限仍由 Context 限制；请求和所有重定向共享网络时间预算。
            context.timing.lock().unwrap().queue += queued.elapsed().as_millis() as u64;
            let timeout = if matches!(context.profile, Profile::Content) {
                context
                    .crawl
                    .timeout_ms
                    .map(|ms| Duration::from_millis(ms.clamp(1000, 180000)))
                    .or_else(|| {
                        (crate::hosts::local(url.as_str()) && self.respond_time > 0)
                            .then(|| Duration::from_millis(self.respond_time.min(180000) as u64))
                    })
                    .unwrap_or(context.profile.timeout())
            } else {
                context.profile.timeout()
            };
            let remaining = timeout.saturating_sub(network_time);
            if remaining.is_zero() {
                return Err(NetError("请求超时".into()));
            }
            let network_started = Instant::now();
            let _timer = NetworkTimer {
                start: network_started,
                context: context.clone(),
                host: host.clone().unwrap(),
            };
            let mut headers = HeaderMap::new();
            headers.insert("user-agent", HeaderValue::from_static(DEFAULT_UA));
            for (k, v) in self.headers.iter().chain(&req.headers) {
                if let (Ok(name), Ok(value)) = (
                    HeaderName::from_bytes(k.trim().as_bytes()),
                    HeaderValue::from_str(v.trim()),
                ) {
                    if name == "cookie" {
                        self.set_cookie(url.as_str(), v);
                        continue;
                    }
                    headers.insert(name, value);
                }
            }
            let cookie = self.cookie_header(&url);
            if !cookie.is_empty()
                && let Ok(v) = HeaderValue::from_str(&cookie)
            {
                headers.insert("cookie", v);
            }
            if method == Method::POST && !headers.contains_key("content-type") {
                let looks_json = body
                    .as_deref()
                    .is_some_and(|b| matches!(b.first(), Some(b'{' | b'[')));
                headers.insert(
                    "content-type",
                    HeaderValue::from_static(if looks_json {
                        "application/json; charset=UTF-8"
                    } else {
                        "application/x-www-form-urlencoded"
                    }),
                );
            }
            let mut builder = client
                .request(method.clone(), url.clone())
                .timeout(remaining)
                .headers(headers);
            if let Some(b) = &body {
                builder = builder.body(b.clone());
            }
            let mut resp = builder.send().await.map_err(|e| {
                NetError(format!(
                    "{} · {}",
                    crate::network_config::error(&e),
                    route.reason
                ))
            })?;
            let status = resp.status();
            let protocol = format!("{:?}", resp.version());
            if let Some(h) = &host {
                let retry_after = resp
                    .headers()
                    .get("retry-after")
                    .and_then(|v| v.to_str().ok())
                    .and_then(control::retry_after);
                if status.as_u16() == 429 {
                    h.http_limited(retry_after);
                } else if status.as_u16() == 503
                    && let Some(delay) = retry_after
                {
                    h.defer(delay);
                }
            }
            {
                let mut jar = self.cookies.lock().unwrap();
                for v in resp.headers().get_all("set-cookie") {
                    if let Ok(s) = v.to_str() {
                        let _ = jar.parse(s, &url);
                    }
                }
            }
            if follow
                && status.is_redirection()
                && let Some(location) = resp.headers().get("location").and_then(|v| v.to_str().ok())
            {
                url = url
                    .join(location)
                    .map_err(|_| NetError("重定向网址无效".into()))?;
                if status.as_u16() == 303
                    || ((status.as_u16() == 301 || status.as_u16() == 302)
                        && method == Method::POST)
                {
                    method = Method::GET;
                    body = None;
                }
                network_time += network_started.elapsed();
                continue;
            }
            let headers: Vec<(String, String)> = resp
                .headers()
                .iter()
                .map(|(k, v)| {
                    (
                        k.as_str().to_owned(),
                        String::from_utf8_lossy(v.as_bytes()).into_owned(),
                    )
                })
                .collect();
            let mut bytes = Vec::new();
            while let Some(chunk) = resp
                .chunk()
                .await
                .map_err(|_| NetError("读取响应失败".into()))?
            {
                if let Some(limit) = req.sample_bytes {
                    let take = chunk.len().min(limit.saturating_sub(bytes.len()));
                    bytes.extend_from_slice(&chunk[..take]);
                    if bytes.len() >= limit {
                        break;
                    }
                    continue;
                }
                if bytes.len() + chunk.len() > MAX_BODY {
                    return Err(NetError("响应过大".into()));
                }
                bytes.extend_from_slice(&chunk);
            }
            let content_type = headers
                .iter()
                .find(|(k, _)| k.eq_ignore_ascii_case("content-type"))
                .map(|(_, v)| v.as_str())
                .unwrap_or("");
            let text = decode(&bytes, req.charset.as_deref(), content_type);
            if !status.is_success() && !status.is_redirection() {
                let kind = if matches!(status.as_u16(), 403 | 503)
                    && crate::webview::looks_like_challenge(&text)
                {
                    control::ErrorKind::Verification
                } else {
                    control::ErrorKind::from_http(status.as_u16())
                };
                // 只返回状态和固定提示，不把响应页、认证头或代理密码写进任务记录。
                return Err(NetError(format!(
                    "网站返回 {}：{}；{}",
                    status.as_u16(),
                    kind.label(),
                    kind.action()
                )));
            }
            return Ok(Response {
                url: url.to_string(),
                status: status.as_u16(),
                headers,
                body: bytes,
                text,
                route: route.json(),
                protocol,
            });
        }
        Err(NetError("重定向次数过多".into()))
    }
}

struct NetworkTimer {
    start: Instant,
    context: Context,
    host: std::sync::Arc<control::Host>,
}
impl Drop for NetworkTimer {
    fn drop(&mut self) {
        let ms = self.start.elapsed().as_millis() as u64;
        self.context.timing.lock().unwrap().net += ms;
        self.host.network(ms);
    }
}

/// 编码：指定的 charset → Content-Type → 网页 meta → UTF-8（不是有效 UTF-8 时按 GBK）。
pub fn decode(bytes: &[u8], charset: Option<&str>, content_type: &str) -> String {
    let label = charset
        .filter(|c| !c.trim().is_empty())
        .map(str::to_owned)
        .or_else(|| {
            content_type.to_ascii_lowercase().split(';').find_map(|p| {
                p.trim()
                    .strip_prefix("charset=")
                    .map(|c| c.trim_matches(['"', '\'']).to_owned())
            })
        })
        .or_else(|| meta_charset(&bytes[..bytes.len().min(4096)]));
    if let Some(enc) = label
        .as_deref()
        .and_then(|l| Encoding::for_label(l.trim().as_bytes()))
    {
        return enc.decode(bytes).0.into_owned();
    }
    match std::str::from_utf8(bytes) {
        Ok(s) => s.trim_start_matches('\u{feff}').to_owned(),
        Err(_) => encoding_rs::GBK.decode(bytes).0.into_owned(),
    }
}

fn meta_charset(head: &[u8]) -> Option<String> {
    let head = String::from_utf8_lossy(head).to_ascii_lowercase();
    let at = head.find("charset=")?;
    let rest = head[at + 8..].trim_start_matches(['"', '\'', ' ']);
    let end = rest
        .find(|c: char| !(c.is_ascii_alphanumeric() || c == '-' || c == '_'))
        .unwrap_or(rest.len());
    (end > 0).then(|| rest[..end].to_owned())
}

/// 按书源编码做百分号编码（GBK 网站的搜索词要按 GBK 字节编码）。
pub fn encode_component(text: &str, charset: Option<&str>) -> String {
    let enc = charset
        .and_then(|c| Encoding::for_label(c.trim().as_bytes()))
        .unwrap_or(encoding_rs::UTF_8);
    let (bytes, _, _) = enc.encode(text);
    percent_encoding::percent_encode(&bytes, URL_COMPONENT).to_string()
}

const URL_COMPONENT: &percent_encoding::AsciiSet = &percent_encoding::NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'_')
    .remove(b'.')
    .remove(b'~')
    .remove(b'*');
