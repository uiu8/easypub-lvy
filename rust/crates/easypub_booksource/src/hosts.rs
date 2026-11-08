//! 站点级准入与学习记录；只保存统计，网址只保留 host:port。
use crate::control::{Context, Profile};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{Arc, Condvar, Mutex, OnceLock},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Learned {
    pub safe_limit: usize,
    pub interval: u64,
    pub last_throttle_at: u64,
    pub stub_median: usize,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Diagnostic {
    pub host: String,
    pub active: usize,
    pub limit: usize,
    pub interval: u64,
    pub cooldown_ms: u64,
    pub stub_count: usize,
    pub http_limited: usize,
    pub network_ms: u64,
    pub learned: Learned,
}
struct HostState {
    active: usize,
    limit: usize,
    successes: usize,
    total_successes: usize,
    next: Instant,
    cooldown: Instant,
    restore: Option<usize>,
    waiting_downloads: usize,
    learned: Learned,
    stub_count: usize,
    http_limited: usize,
    network_total: u64,
    network_count: u64,
}
pub struct Host {
    key: String,
    local: bool,
    state: Mutex<HostState>,
    changed: Condvar,
}
pub struct Permit(Arc<Host>);
impl Drop for Permit {
    fn drop(&mut self) {
        self.0.state.lock().unwrap().active -= 1;
        self.0.changed.notify_all();
    }
}
#[derive(Default)]
struct Registry {
    hosts: HashMap<String, Arc<Host>>,
    learned: HashMap<String, Learned>,
    file: Option<PathBuf>,
}
fn registry() -> &'static Mutex<Registry> {
    static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
    REGISTRY.get_or_init(Default::default)
}
pub fn local(url: &str) -> bool {
    reqwest::Url::parse(url)
        .ok()
        .and_then(|u| u.host_str().map(str::to_owned))
        .is_some_and(|h| {
            h.eq_ignore_ascii_case("localhost")
                || h.trim_matches(['[', ']'])
                    .parse::<std::net::IpAddr>()
                    .is_ok_and(|a| a.is_loopback())
        })
}
pub fn load(directory: &Path) {
    let mut r = registry().lock().unwrap();
    r.file = Some(directory.join("hosts.json"));
    r.learned = std::fs::read(directory.join("hosts.json"))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default();
}
pub fn persist() -> Result<(), String> {
    let r = registry().lock().unwrap();
    let Some(path) = &r.file else { return Ok(()) };
    let mut learned = r.learned.clone();
    for (key, host) in &r.hosts {
        if !host.local {
            learned.insert(key.clone(), host.state.lock().unwrap().learned.clone());
        }
    }
    crate::download::write_atomic(
        path,
        &serde_json::to_vec(&learned).map_err(|_| "限速记录无法保存")?,
    )
}
pub fn wake() {
    for host in registry().lock().unwrap().hosts.values() {
        host.changed.notify_all();
    }
}
pub fn diagnostics() -> Vec<Diagnostic> {
    let mut out: Vec<_> = registry()
        .lock()
        .unwrap()
        .hosts
        .values()
        .map(|h| h.diagnostic())
        .collect();
    out.sort_by(|a, b| a.host.cmp(&b.host));
    out
}
pub fn host(url: &str, ceiling: usize) -> Arc<Host> {
    let key = reqwest::Url::parse(url)
        .ok()
        .map(|u| {
            format!(
                "{}:{}",
                u.host_str().unwrap_or(""),
                u.port_or_known_default().unwrap_or(80)
            )
        })
        .unwrap_or_else(|| "invalid".into());
    let mut r = registry().lock().unwrap();
    let learned = r.learned.get(&key).cloned().unwrap_or_default();
    r.hosts
        .entry(key.clone())
        .or_insert_with(|| {
            let now = Instant::now();
            let local = local(url);
            let limit = if local {
                16
            } else if learned.safe_limit > 0 {
                learned.safe_limit
            } else {
                4
            };
            Arc::new(Host {
                key,
                local,
                changed: Condvar::new(),
                state: Mutex::new(HostState {
                    active: 0,
                    limit: limit.min(ceiling.clamp(1, 32)),
                    successes: 0,
                    total_successes: 0,
                    next: now,
                    cooldown: now,
                    restore: None,
                    waiting_downloads: 0,
                    learned,
                    stub_count: 0,
                    http_limited: 0,
                    network_total: 0,
                    network_count: 0,
                }),
            })
        })
        .clone()
}
impl Host {
    pub fn acquire(self: &Arc<Self>, context: &Context) -> Result<Permit, String> {
        let ceiling = context
            .crawl
            .concurrency
            .unwrap_or(context.ceiling.unwrap_or(if self.local { 16 } else { 32 }))
            .clamp(1, 32);
        let priority = matches!(context.profile, Profile::Content);
        let mut s = self.state.lock().unwrap();
        if priority {
            s.waiting_downloads += 1;
        }
        loop {
            if let Err(e) = context.check() {
                if priority {
                    s.waiting_downloads -= 1;
                }
                self.changed.notify_all();
                return Err(e);
            }
            let now = Instant::now();
            if now >= s.cooldown
                && let Some(limit) = s.restore.take()
            {
                s.limit = limit;
            }
            let free = s.active < s.limit.min(ceiling);
            if free && now >= s.next && now >= s.cooldown && (priority || s.waiting_downloads == 0)
            {
                if priority {
                    s.waiting_downloads -= 1;
                }
                s.active += 1;
                let lo = context.crawl.min_interval;
                let hi = context.crawl.max_interval.max(lo);
                let jitter = lo + random(hi - lo + 1);
                s.next = now + Duration::from_millis(s.learned.interval.max(jitter));
                return Ok(Permit(self.clone()));
            }
            // 准入/释放主动唤醒；外部 AtomicBool 取消保留最长 500 ms 的兼容检查。
            let due = s.next.max(s.cooldown);
            let wait = if due > now {
                due - now
            } else {
                Duration::from_millis(500)
            };
            let wait = wait.min(Duration::from_millis(500));
            s = self.changed.wait_timeout(s, wait).unwrap().0;
        }
    }
    pub fn limited(&self, retry_after: Option<Duration>) {
        if self.local {
            if let Some(delay) = retry_after {
                self.defer(delay);
            }
            return;
        }
        let mut s = self.state.lock().unwrap();
        let now = Instant::now();
        if s.restore.is_none() {
            s.restore = Some((s.limit * 3 / 4).max(1));
            s.limit = (s.limit / 2).max(1);
            s.successes = 0;
            s.learned.interval = (s.learned.interval + 500).min(2000);
            s.learned.last_throttle_at = timestamp();
            s.learned.safe_limit = s.restore.unwrap();
        }
        // 同一波失败不重复延长冷却；服务端 Retry-After 例外。
        if s.cooldown <= now || retry_after.is_some() {
            s.cooldown = s
                .cooldown
                .max(now + retry_after.unwrap_or(Duration::from_secs(30)));
        }
        self.changed.notify_all();
    }
    pub fn stub(&self) {
        self.state.lock().unwrap().stub_count += 1;
        self.limited(None);
    }
    pub fn http_limited(&self, delay: Option<Duration>) {
        self.state.lock().unwrap().http_limited += 1;
        self.limited(delay);
    }
    /// 服务暂不可用时遵守 Retry-After，但不把它记成限流或调低安全并发。
    pub fn defer(&self, delay: Duration) {
        let mut s = self.state.lock().unwrap();
        s.cooldown = s.cooldown.max(Instant::now() + delay);
        self.changed.notify_all();
    }
    pub fn network(&self, ms: u64) {
        let mut s = self.state.lock().unwrap();
        s.network_count += 1;
        s.network_total += ms;
    }
    pub fn median(&self, chars: usize) {
        self.state.lock().unwrap().learned.stub_median = chars;
    }
    pub fn success(&self, ceiling: usize) {
        let mut s = self.state.lock().unwrap();
        s.successes += 1;
        s.total_successes += 1;
        let ramp = if s.learned.last_throttle_at == 0 {
            5
        } else {
            20
        };
        if s.successes >= ramp && s.restore.is_none() {
            s.limit = (s.limit + 1).min(ceiling.clamp(1, 32));
            s.successes = 0;
        }
        if s.total_successes.is_multiple_of(10) {
            s.learned.interval = s.learned.interval.saturating_sub(100);
        }
        if s.restore.is_none() {
            s.learned.safe_limit = s.limit;
        }
        self.changed.notify_all();
    }
    pub fn snapshot(&self, ceiling: usize) -> (usize, bool) {
        let s = self.state.lock().unwrap();
        (
            s.limit.min(ceiling),
            s.learned.interval > 0 || Instant::now() < s.cooldown,
        )
    }
    pub fn cooling(&self) -> bool {
        Instant::now() < self.state.lock().unwrap().cooldown
    }
    pub fn diagnostic(&self) -> Diagnostic {
        let s = self.state.lock().unwrap();
        Diagnostic {
            host: self.key.clone(),
            active: s.active,
            limit: s.limit,
            interval: s.learned.interval,
            cooldown_ms: s
                .cooldown
                .saturating_duration_since(Instant::now())
                .as_millis() as u64,
            stub_count: s.stub_count,
            http_limited: s.http_limited,
            network_ms: s.network_total / s.network_count.max(1),
            learned: s.learned.clone(),
        }
    }
}
pub fn timestamp() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
pub fn random(bound: u64) -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static STATE: AtomicU64 = AtomicU64::new(0x916a1f3d57);
    let x = STATE.fetch_add(0x9e3779b97f4a7c15, Ordering::Relaxed);
    let mut v = x ^ (x >> 30);
    v = v.wrapping_mul(0xbf58476d1ce4e5b9);
    v ^= v >> 27;
    v = v.wrapping_mul(0x94d049bb133111eb);
    (v ^ (v >> 31)) % bound.max(1)
}
