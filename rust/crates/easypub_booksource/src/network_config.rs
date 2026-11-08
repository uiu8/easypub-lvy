//! 统一代理决策：网址导入、书源 HTTP、诊断共用；凭据只在进程内。
use crate::{control::Profile, source::CrawlProfile};
use reqwest::Url;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::{Mutex, OnceLock},
    time::Duration,
};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ProxyConfig {
    pub mode: String,
    pub url: String,
    pub scope: String,
    pub bypass_local: bool,
    pub no_proxy: String,
    pub connect_timeout_ms: u64,
    #[serde(skip_serializing)]
    pub keep_credentials: bool,
}
impl Default for ProxyConfig {
    fn default() -> Self {
        Self {
            mode: "none".into(),
            url: String::new(),
            scope: "all".into(),
            bypass_local: true,
            no_proxy: String::new(),
            connect_timeout_ms: 8000,
            keep_credentials: false,
        }
    }
}
#[derive(Clone, Default)]
struct SystemProxy {
    http: String,
    https: String,
    bypass: String,
    pac: bool,
    source: String,
}
fn system() -> &'static Mutex<SystemProxy> {
    static SYSTEM: OnceLock<Mutex<SystemProxy>> = OnceLock::new();
    SYSTEM.get_or_init(|| Mutex::new(read_system()))
}
fn config() -> &'static Mutex<ProxyConfig> {
    static CONFIG: OnceLock<Mutex<ProxyConfig>> = OnceLock::new();
    CONFIG.get_or_init(Default::default)
}
fn clients() -> &'static Mutex<HashMap<String, reqwest::Client>> {
    static CLIENTS: OnceLock<Mutex<HashMap<String, reqwest::Client>>> = OnceLock::new();
    CLIENTS.get_or_init(Default::default)
}
pub fn current() -> ProxyConfig {
    config().lock().unwrap().clone()
}
fn clean_url(text: &str) -> String {
    Url::parse(text)
        .ok()
        .map(|mut u| {
            let _ = u.set_username("");
            let _ = u.set_password(None);
            u.to_string()
        })
        .unwrap_or_default()
}
fn has_credentials(text: &str) -> bool {
    Url::parse(text).is_ok_and(|u| !u.username().is_empty() || u.password().is_some())
}
fn proxy_url(text: &str) -> Result<String, String> {
    let text = text.trim();
    if text.is_empty() {
        return Err("代理地址为空".into());
    }
    let text = if text.contains("://") {
        text.to_owned()
    } else {
        format!("http://{text}")
    };
    let u = Url::parse(&text).map_err(|_| "代理地址无效")?;
    if !["http", "https", "socks5", "socks5h"].contains(&u.scheme())
        || u.host_str().is_none()
        || !matches!(u.path(), "" | "/")
        || u.query().is_some()
        || u.fragment().is_some()
    {
        return Err("代理地址需为 HTTP / HTTPS / SOCKS5 / SOCKS5h 主机和端口".into());
    }
    Ok(u.to_string())
}
pub fn validated(mut c: ProxyConfig) -> Result<ProxyConfig, String> {
    if c.mode.is_empty() {
        c.mode = "none".into();
    }
    if !["none", "system", "manual"].contains(&c.mode.as_str()) {
        return Err("代理模式无效".into());
    }
    if !["all", "marked"].contains(&c.scope.as_str()) {
        return Err("代理作用范围无效".into());
    }
    if !(1000..=60000).contains(&c.connect_timeout_ms) {
        return Err("连接超时应为 1–60 秒".into());
    }
    if !c.url.trim().is_empty() {
        c.url = proxy_url(&c.url)?;
    }
    if c.mode == "manual" && c.url.is_empty() {
        return Err("请填写代理地址".into());
    }
    if c.no_proxy
        .split([',', ';', '\n'])
        .any(|s| s.trim().contains(['/', '\\', '"', ' ']))
    {
        return Err("绕过列表请填主机、域名或 IP，以逗号分隔".into());
    }
    if c.keep_credentials {
        let old = current();
        if !has_credentials(&c.url) && clean_url(&old.url) == c.url {
            c.url = old.url;
        }
    }
    Ok(c)
}
pub fn set(c: ProxyConfig) -> Result<(), String> {
    let c = validated(c)?;
    *config().lock().unwrap() = c;
    refresh();
    Ok(())
}
pub fn refresh() {
    *system().lock().unwrap() = read_system();
    clients().lock().unwrap().clear();
}
pub fn get() -> Value {
    let c = current();
    let mut v = serde_json::to_value(&c).unwrap();
    v["url"] = json!(clean_url(&c.url));
    v["credentialsInMemory"] = json!(has_credentials(&c.url));
    let s = system().lock().unwrap();
    v["system"] = json!({"http":clean_url(&s.http),"https":clean_url(&s.https),
        "source":s.source,"pac":s.pac,"available":!s.http.is_empty() || !s.https.is_empty()});
    v
}
fn env(name: &str) -> String {
    std::env::var(name.to_ascii_lowercase())
        .or_else(|_| std::env::var(name))
        .unwrap_or_default()
}
fn read_system() -> SystemProxy {
    let mut s = SystemProxy::default();
    #[cfg(windows)]
    if let Ok(key) = windows_registry::CURRENT_USER
        .open(r"Software\Microsoft\Windows\CurrentVersion\Internet Settings")
    {
        s.pac = key.get_string("AutoConfigURL").is_ok_and(|v| !v.is_empty());
        if key.get_u32("ProxyEnable").unwrap_or(0) != 0 {
            let server = key.get_string("ProxyServer").unwrap_or_default();
            if server.contains('=') {
                for part in server.split(';') {
                    if let Some((scheme, addr)) = part.split_once('=') {
                        let addr = proxy_url(addr).unwrap_or_default();
                        match scheme.trim() {
                            "http" => s.http = addr,
                            "https" => s.https = addr,
                            _ => (),
                        }
                    }
                }
            } else if let Ok(addr) = proxy_url(&server) {
                s.http = addr.clone();
                s.https = addr;
            }
            s.bypass = key.get_string("ProxyOverride").unwrap_or_default();
            s.source = "Windows 系统设置".into();
        }
    }
    let all = env("ALL_PROXY");
    let http = env("HTTP_PROXY");
    let https = env("HTTPS_PROXY");
    if !all.is_empty() || !http.is_empty() || !https.is_empty() {
        s.http = proxy_url(if http.is_empty() { &all } else { &http }).unwrap_or_default();
        s.https = proxy_url(if https.is_empty() { &all } else { &https }).unwrap_or_default();
        s.bypass = env("NO_PROXY");
        s.source = "进程环境变量".into();
    }
    s
}
fn bypass(host: &str, list: &str) -> bool {
    list.split([',', ';', '\n'])
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .any(|item| {
            if item == "*" {
                return true;
            }
            if item == "<local>" {
                return !host.contains(['.', ':']);
            }
            let item = item
                .trim_start_matches('*')
                .trim_start_matches('.')
                .trim_matches(['[', ']'])
                .to_ascii_lowercase();
            host.eq_ignore_ascii_case(&item)
                || host.to_ascii_lowercase().ends_with(&format!(".{item}"))
        })
}
pub fn local(url: &Url) -> bool {
    let host = url.host_str().unwrap_or("").trim_matches(['[', ']']);
    host.eq_ignore_ascii_case("localhost")
        || host.ends_with(".localhost")
        || host
            .parse::<std::net::IpAddr>()
            .is_ok_and(|ip| ip.is_loopback())
}
#[derive(Clone)]
pub struct Route {
    pub proxy: Option<String>,
    pub reason: &'static str,
}
impl Route {
    pub fn json(&self) -> Value {
        json!({"mode":if self.proxy.is_some() {"proxy"} else {"direct"},
            "endpoint":self.proxy.as_deref().map(clean_url), "reason":self.reason,
            "dns":self.proxy.as_deref().map(|p| if p.starts_with("socks5h:") {"代理解析"} else if p.starts_with("socks5:") {"本机解析"} else {"代理连接目标"})})
    }
}
pub fn route(
    c: &ProxyConfig,
    crawl: &CrawlProfile,
    option: Option<&str>,
    url: &Url,
) -> Result<Route, String> {
    let direct = |reason| {
        Ok(Route {
            proxy: None,
            reason,
        })
    };
    let host = url.host_str().unwrap_or("").trim_matches(['[', ']']);
    if c.bypass_local && local(url) {
        return direct("本地地址绕过代理");
    }
    if bypass(host, &c.no_proxy) {
        return direct("命中绕过列表");
    }
    if option == Some("false") || crawl.proxy_mode == "direct" {
        return direct("请求或书源指定直连");
    }
    if let Some(option) = option.filter(|o| !o.is_empty() && *o != "true") {
        return Ok(Route {
            proxy: Some(proxy_url(option)?),
            reason: "网址规则指定代理",
        });
    }
    if c.scope == "marked"
        && !crawl.use_proxy
        && crawl.proxy_mode != "proxy"
        && option != Some("true")
    {
        return direct("此书源未选择代理");
    }
    match c.mode.as_str() {
        "manual" => Ok(Route {
            proxy: Some(proxy_url(&c.url)?),
            reason: "手动代理",
        }),
        "system" => {
            let s = system().lock().unwrap();
            if bypass(host, &s.bypass) {
                return direct("系统绕过列表");
            }
            let p = if url.scheme() == "https" {
                &s.https
            } else {
                &s.http
            };
            if p.is_empty() {
                if s.pac {
                    return Err("系统仅配置了 PAC，当前 HTTP 引擎不执行 PAC；请填写手动代理".into());
                }
                direct("系统没有为该协议配置代理")
            } else {
                Ok(Route {
                    proxy: Some(p.clone()),
                    reason: "系统代理",
                })
            }
        }
        _ => direct("直连（不读取系统或环境代理）"),
    }
}
pub fn client(
    profile: Profile,
    c: &ProxyConfig,
    route: &Route,
    insecure: bool,
) -> Result<reqwest::Client, String> {
    let key = format!(
        "{}:{insecure}:{}:{:?}",
        profile.index(),
        c.connect_timeout_ms,
        route.proxy
    );
    let mut cache = clients().lock().unwrap();
    if let Some(client) = cache.get(&key) {
        return Ok(client.clone());
    }
    let mut builder = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_millis(c.connect_timeout_ms))
        .pool_idle_timeout(Duration::from_secs(60))
        .tcp_keepalive(Duration::from_secs(30))
        .gzip(true)
        .brotli(true)
        .danger_accept_invalid_certs(insecure);
    if let Some(url) = &route.proxy {
        builder = builder.proxy(reqwest::Proxy::all(url).map_err(|_| "代理地址无效")?);
    }
    let client = builder.build().map_err(|_| "HTTP 客户端创建失败")?;
    if cache.len() >= 64 {
        cache.clear();
    }
    cache.insert(key, client.clone());
    Ok(client)
}
pub fn error(error: &reqwest::Error) -> &'static str {
    crate::network_failure::describe(error)
}

/// 对照测试不写配置、不记录正文，也不改变书源健康分数。
pub fn diagnose(params: &Value) -> Result<Value, String> {
    let url = params["url"].as_str().ok_or("请填写测试网址")?;
    let target = Url::parse(url).map_err(|_| "测试网址无效")?;
    if !matches!(target.scheme(), "http" | "https")
        || !target.username().is_empty()
        || target.password().is_some()
    {
        return Err("测试网址需为无账号密码的 HTTP / HTTPS 地址".into());
    }
    let selected = if params.get("config").is_some() {
        validated(serde_json::from_value(params["config"].clone()).map_err(|_| "网络配置无效")?)?
    } else {
        current()
    };
    let mut samples = Vec::new();
    for (label, config) in [
        (
            "直连",
            ProxyConfig {
                connect_timeout_ms: selected.connect_timeout_ms,
                ..Default::default()
            },
        ),
        ("当前选择", selected),
    ] {
        let mut net = crate::net::Net::new(None, Vec::new());
        net.crawl.proxy_mode = "proxy".into();
        let planned = route(&config, &net.crawl, None, &target);
        let at = std::time::Instant::now();
        let ctx = crate::control::Context {
            deadline: Some(at + Duration::from_secs(20)),
            ..Default::default()
        };
        let _guard = ctx.enter();
        let response = net.fetch(&crate::net::Request {
            url: url.into(),
            method: "GET".into(),
            network: Some(config),
            sample_bytes: Some(8192),
            ..Default::default()
        });
        let value = match response {
            Ok(r) => json!({"label":label,"ok":true,"status":r.status,"route":r.route,
                "protocol":r.protocol,"sampledBytes":r.body.len(),"finalHost":Url::parse(&r.url).ok().and_then(|u|u.host_str().map(str::to_owned))}),
            Err(e) => {
                json!({"label":label,"ok":false,"error":e.0,"route":planned.ok().map(|r|r.json())})
            }
        };
        let mut value = value;
        value["ms"] = json!(at.elapsed().as_millis());
        samples.push(value);
    }
    Ok(json!({"samples":samples}))
}

/// WebView2 使用同一代理策略；认证代理只用于原生 HTTP，绝不把密码放进浏览器参数。
pub fn browser_args(crawl: &CrawlProfile, url: &str) -> Result<String, String> {
    let c = current();
    let target = Url::parse(url).map_err(|_| "WebView 网址无效")?;
    let r = route(&c, crawl, None, &target)?;
    if r.proxy.is_none() {
        return Ok("--no-proxy-server".into());
    }
    let browser_proxy = |s: &str| -> Result<String, String> {
        if has_credentials(s) {
            return Err("WebView 暂不支持带认证的代理，请使用本机无认证代理端口".into());
        }
        Ok(s.replace("socks5h://", "socks5://")
            .trim_end_matches('/')
            .to_owned())
    };
    let mut excludes = c.no_proxy.replace([',', '\n'], ";");
    let proxy = if c.mode == "system" {
        let s = system().lock().unwrap();
        excludes.push(';');
        excludes.push_str(&s.bypass);
        format!(
            "http={};https={}",
            browser_proxy(&s.http)?,
            browser_proxy(&s.https)?
        )
    } else {
        browser_proxy(r.proxy.as_deref().unwrap())?
    };
    if c.bypass_local {
        excludes.push_str(";localhost;*.localhost;127.0.0.1;[::1]");
    } else {
        excludes.push_str(";<-loopback>");
    }
    Ok(format!(
        "--proxy-server=\"{proxy}\" --proxy-bypass-list=\"{excludes}\""
    ))
}
