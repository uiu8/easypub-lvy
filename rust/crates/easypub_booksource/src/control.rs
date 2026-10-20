//! 请求预算、取消与按 host 共享的自适应限速。同步规则引擎与异步 HTTP 的边界。
use std::{
    cell::RefCell,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

#[derive(Clone, Copy, Debug, Default)]
pub enum Profile {
    #[default]
    Detail,
    Content,
    Search,
    Ping,
    Import,
}
impl Profile {
    pub fn timeout(self) -> Duration {
        Duration::from_secs(match self {
            Self::Detail => 30,
            Self::Content => 15,
            Self::Search => 10,
            Self::Ping => 5,
            Self::Import => 120,
        })
    }
    pub fn connect(self) -> Duration {
        Duration::from_secs(match self {
            Self::Detail | Self::Import => 8,
            Self::Content => 5,
            Self::Search | Self::Ping => 4,
        })
    }
    pub fn index(self) -> usize {
        match self {
            Self::Detail => 0,
            Self::Content => 1,
            Self::Search => 2,
            Self::Ping => 3,
            Self::Import => 4,
        }
    }
}

#[derive(Clone, Default)]
pub struct Context {
    pub cancel: Arc<AtomicBool>,
    pub deadline: Option<Instant>,
    pub profile: Profile,
    pub ceiling: Option<usize>,
    pub remove_prompts: bool,
    pub interactive: bool,
    pub crawl: crate::source::CrawlProfile,
    pub timing: Arc<Mutex<Timing>>,
    pub batch_rate_reserved: bool,
    pub observed_host: Arc<Mutex<Option<Arc<crate::hosts::Host>>>>,
    pub network_route: Arc<Mutex<serde_json::Value>>,
    pub corpus: Option<Arc<crate::corpus::Tape>>,
}
impl Context {
    pub fn new(profile: Profile, cancel: Arc<AtomicBool>) -> Self {
        Self {
            profile,
            cancel,
            remove_prompts: true,
            interactive: true,
            ..Default::default()
        }
    }
    pub fn check(&self) -> Result<(), String> {
        if self.cancel.load(Ordering::Relaxed) {
            Err("已取消".into())
        } else if self.deadline.is_some_and(|d| Instant::now() >= d) {
            Err("请求超时".into())
        } else {
            Ok(())
        }
    }
    pub fn wait(&self, duration: Duration) -> Result<(), String> {
        let until = Instant::now() + duration;
        while Instant::now() < until {
            self.check()?;
            std::thread::sleep(
                until
                    .saturating_duration_since(Instant::now())
                    .min(Duration::from_millis(40)),
            );
        }
        self.check()
    }
    pub fn enter(self) -> Guard {
        let old = CURRENT.with(|c| c.replace(self));
        Guard(old)
    }
}
thread_local! {
    static CURRENT: RefCell<Context> = RefCell::new(Context::new(Profile::Detail, Arc::new(AtomicBool::new(false))));
}
pub struct Guard(Context);
impl Drop for Guard {
    fn drop(&mut self) {
        CURRENT.with(|c| c.replace(self.0.clone()));
    }
}
pub fn current() -> Context {
    CURRENT.with(|c| c.borrow().clone())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorKind {
    Cancelled,
    Timeout,
    Connection,
    RateLimited,
    Throttled,
    Server,
    Missing,
    Rule,
    Unsupported,
    Paid,
    Empty,
    ShortContent,
    ContentUnavailable,
    Verification,
    LoginRequired,
    AccessDenied,
    ProxyAuth,
    Storage,
    Other,
}
impl ErrorKind {
    pub fn http_status(message: &str) -> Option<u16> {
        ["网站返回 ", "HTTP "].iter().find_map(|prefix| {
            let (_, tail) = message.split_once(prefix)?;
            let code = tail.get(..3)?;
            code.parse().ok().filter(|n| (400..600).contains(n))
        })
    }
    pub fn from_http(status: u16) -> Self {
        match status {
            401 => Self::LoginRequired,
            403 => Self::AccessDenied,
            407 => Self::ProxyAuth,
            429 => Self::RateLimited,
            404 | 410 => Self::Missing,
            500..=599 => Self::Server,
            _ => Self::Other,
        }
    }
    pub fn classify(message: &str) -> Self {
        if message.contains("已取消") {
            Self::Cancelled
        } else if message.contains("不支持")
            || message.contains("只支持")
            || message.contains("尚未适配")
            || message.contains("尚未支持")
        {
            Self::Unsupported
        } else if message.contains("疑似限流") {
            Self::Throttled
        } else if message.contains("超时") {
            Self::Timeout
        } else if message.contains("需要网页验证") || message.contains("需要验证") {
            Self::Verification
        } else if let Some(status) = Self::http_status(message) {
            Self::from_http(status)
        } else if message.contains("需要登录") {
            Self::LoginRequired
        } else if message.contains("代理认证") {
            Self::ProxyAuth
        } else if message.contains("拒绝访问") {
            Self::AccessDenied
        } else if message.contains("限流") {
            Self::RateLimited
        } else if message.contains("页面不存在") {
            Self::Missing
        } else if message.contains("网站错误") {
            Self::Server
        } else if message.contains("缓存写入失败") {
            Self::Storage
        } else if message.contains("连接")
            || message.contains("DNS")
            || message.contains("读取响应失败")
        {
            Self::Connection
        } else if message.contains("付费") {
            Self::Paid
        } else if message.contains("验证") || message.contains("WebView") {
            Self::Verification
        } else if message.contains("章节内容暂缺") {
            Self::ContentUnavailable
        } else if message.contains("正文过短") {
            Self::ShortContent
        } else if message.contains("正文为空") {
            Self::Empty
        } else if message.contains("规则") || message.contains("没有搜索地址") {
            Self::Rule
        } else {
            Self::Other
        }
    }
    pub fn retryable(self) -> bool {
        matches!(
            self,
            Self::Timeout
                | Self::Connection
                | Self::RateLimited
                | Self::Throttled
                | Self::Server
                | Self::Empty
                | Self::ShortContent
        )
    }
    pub fn label(self) -> &'static str {
        match self {
            Self::Cancelled => "已取消",
            Self::Timeout => "超时",
            Self::Connection => "连接失败",
            Self::RateLimited => "限流",
            Self::Throttled => "疑似限流桩页",
            Self::Server => "网站错误",
            Self::Missing => "页面不存在",
            Self::Rule => "规则缺失或错误",
            Self::Unsupported => "插件不支持的写法",
            Self::Paid => "付费章节",
            Self::Empty => "正文为空",
            Self::ShortContent => "正文过短，待人工确认",
            Self::ContentUnavailable => "章节内容暂缺",
            Self::Verification => "需要验证",
            Self::LoginRequired => "需要登录",
            Self::AccessDenied => "拒绝访问",
            Self::ProxyAuth => "代理认证失败",
            Self::Storage => "缓存写入失败",
            Self::Other => "解析失败",
        }
    }
    pub fn requires_action(self) -> bool {
        matches!(
            self,
            Self::Verification | Self::LoginRequired | Self::AccessDenied | Self::ProxyAuth
        )
    }
    /// 业务失败分类；取消/磁盘错误不伪装成书源故障。
    pub fn cause(self) -> Option<&'static str> {
        match self {
            Self::Unsupported => Some("unsupported"),
            Self::Rule | Self::Other | Self::Empty => Some("rule"),
            Self::Timeout | Self::Connection | Self::ProxyAuth => Some("network"),
            Self::Verification | Self::LoginRequired => Some("verification"),
            Self::Cancelled | Self::Storage => None,
            _ => Some("site"),
        }
    }
    pub fn action(self) -> &'static str {
        match self {
            Self::Verification => "请在书源中完成验证后重试失败章节",
            Self::LoginRequired => "请登录书源后重试失败章节",
            Self::AccessDenied => "请检查书源访问权限或更换书源",
            Self::ProxyAuth => "请检查代理账号和密码后重试",
            Self::Connection | Self::Timeout => "请检查网络或代理设置",
            Self::RateLimited | Self::Throttled => "等待站点冷却后重试",
            Self::Missing => "请刷新目录或更换书源",
            Self::Storage => "请检查磁盘空间和下载目录权限",
            _ => "",
        }
    }
}

pub use crate::hosts::{Host, host};

#[derive(Clone, Debug, Default, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct Timing {
    pub queue: u64,
    pub net: u64,
    pub parse: u64,
    pub store: u64,
}

/// HTTP Retry-After 支持秒数和 GMT 日期；值不进入日志或错误。
pub fn retry_after(value: &str) -> Option<Duration> {
    if let Ok(seconds) = value.trim().parse::<u64>() {
        return Some(Duration::from_secs(seconds));
    }
    let date =
        time::OffsetDateTime::parse(value, &time::format_description::well_known::Rfc2822).ok()?;
    let seconds = (date - time::OffsetDateTime::now_utc())
        .whole_seconds()
        .max(0) as u64;
    Some(Duration::from_secs(seconds))
}
