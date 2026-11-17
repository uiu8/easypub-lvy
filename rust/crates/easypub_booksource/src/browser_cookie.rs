//! 在网络 Cookie 罐与 WebView 之间保留作用域和安全属性。
use crate::net::Net;
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};

#[derive(Clone)]
pub struct Snapshot {
    pub entries: Vec<BrowserCookie>,
    revision: Arc<AtomicU64>,
    generation: u64,
}

impl Snapshot {
    pub fn check(&self) -> Result<(), String> {
        if self.generation != self.revision.load(Ordering::SeqCst) {
            Err("登录状态已清理，请重新请求".into())
        } else {
            Ok(())
        }
    }
}

#[derive(Clone)]
pub struct BrowserCookie {
    pub name: String,
    pub value: String,
    /// 前导点表示 Domain Cookie；无前导点表示 HostOnly。
    pub domain: String,
    pub path: String,
    pub secure: bool,
    pub http_only: bool,
    pub same_site: String,
    pub expires: Option<f64>,
}

impl BrowserCookie {
    fn matches_current(&self, current: &cookie_store::Cookie<'_>) -> bool {
        let domain = match &current.domain {
            cookie_store::CookieDomain::Suffix(domain) => format!(".{domain}"),
            _ => String::from(&current.domain),
        };
        let expires = match &current.expires {
            cookie_store::CookieExpiration::AtUtc(time) => Some(time.unix_timestamp() as f64),
            cookie_store::CookieExpiration::SessionEnd => None,
        };
        self.value == current.value()
            && self.domain == domain
            && self.secure == current.secure().unwrap_or(false)
            && self.http_only == current.http_only().unwrap_or(false)
            && self.same_site
                == current
                    .same_site()
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| "Lax".into())
            && self.expires == expires
    }
}

pub fn export(net: &Net, url: &str) -> Snapshot {
    let url = reqwest::Url::parse(url).ok();
    let jar = net.cookies.lock().unwrap();
    let generation = net.cookie_revision.load(Ordering::SeqCst);
    let entries = jar
        .iter_unexpired()
        .filter(|c| url.as_ref().is_some_and(|url| c.domain.matches(url)))
        .map(|c| BrowserCookie {
            name: c.name().to_owned(),
            value: c.value().to_owned(),
            domain: match &c.domain {
                cookie_store::CookieDomain::Suffix(domain) => format!(".{domain}"),
                _ => String::from(&c.domain),
            },
            path: String::from(&c.path),
            secure: c.secure().unwrap_or(false),
            http_only: c.http_only().unwrap_or(false),
            same_site: c
                .same_site()
                .map(|s| s.to_string())
                .unwrap_or_else(|| "Lax".into()),
            expires: match &c.expires {
                cookie_store::CookieExpiration::AtUtc(time) => Some(time.unix_timestamp() as f64),
                cookie_store::CookieExpiration::SessionEnd => None,
            },
        })
        .collect();
    Snapshot {
        entries,
        revision: net.cookie_revision.clone(),
        generation,
    }
}

pub fn import(
    net: &Net,
    url: &str,
    before: &Snapshot,
    cookies: &[BrowserCookie],
) -> Result<(), String> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as f64;
    let mut target = net.cookies.lock().unwrap();
    before.check()?;
    let mut jar = target.clone();
    let url = reqwest::Url::parse(url).map_err(|_| "Cookie 网址无效")?;
    // 只删除本次出发前已有、当前仍相同且本次响应范围内消失的项。
    // 不清除其他路径，也不覆盖并发请求刚写入的新值。
    for old in &before.entries {
        let domain = old.domain.trim_start_matches('.');
        let unchanged = jar
            .get(domain, &old.path, &old.name)
            .is_some_and(|c| c.matches(&url) && old.matches_current(c));
        if unchanged
            && !cookies
                .iter()
                .any(|c| c.name == old.name && c.domain == old.domain && c.path == old.path)
        {
            jar.remove(domain, &old.path, &old.name);
        }
    }
    for c in cookies {
        let host = c.domain.trim_start_matches('.');
        let origin = reqwest::Url::parse(&format!("https://{host}/"))
            .map_err(|_| "浏览器 Cookie 域名无效")?;
        let previous = before
            .entries
            .iter()
            .find(|old| old.domain == c.domain && old.path == c.path && old.name == c.name);
        if let Some(current) = target.get(host, &c.path, &c.name) {
            if previous.is_none_or(|old| !old.matches_current(current)) {
                continue;
            }
        } else if previous.is_some() {
            continue;
        }
        if c.expires.is_some_and(|expires| expires <= now) {
            jar.remove(host, &c.path, &c.name);
            continue;
        }
        let mut header = format!("{}={}; Path={}", c.name, c.value, c.path);
        if c.domain.starts_with('.') {
            header.push_str(&format!("; Domain={host}"));
        }
        if c.secure {
            header.push_str("; Secure");
        }
        if c.http_only {
            header.push_str("; HttpOnly");
        }
        header.push_str(&format!("; SameSite={}", c.same_site));
        if let Some(expires) = c.expires {
            header.push_str(&format!("; Max-Age={}", (expires - now).max(0.0) as i64));
        }
        jar.parse(&header, &origin)
            .map_err(|_| "浏览器 Cookie 无法同步到网络会话")?;
    }
    *target = jar;
    Ok(())
}
