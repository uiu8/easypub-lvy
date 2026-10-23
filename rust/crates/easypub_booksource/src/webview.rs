//! WebView 书源：在系统自带的 WebView2 里打开网页、执行书源脚本、取渲染后的内容。
//!
//! 一个专用线程（单线程套间）持有一个隐藏窗口与一个 WebView2，自己泵消息；各下载线程把任务
//! 排队交给它。书源 Cookie 进出 WebView 时与该书源的 Cookie 罐同步（含 HttpOnly）。
use crate::{
    engine::Scope,
    net::{DEFAULT_UA, Request, Response},
};
use std::time::Duration;

pub const UNSUPPORTED: &str = "这个书源需要 WebView（网页内执行脚本），本机不可用";
pub const NOT_WEB: &str = "WebView 只能打开 http / https 网页";

/// 书源是第三方内容：WebView 只打开网页，不能打开 file: 等本机地址再把内容读给书源脚本。
pub fn web_url(url: &str) -> bool {
    reqwest::Url::parse(url)
        .is_ok_and(|u| matches!(u.scheme(), "http" | "https") && u.host_str().is_some())
}
const TIMEOUT: Duration = Duration::from_secs(30);

/// 交给 WebView 线程的任务。
pub struct Job {
    pub context: crate::control::Context,
    pub url: String,
    pub method: String,
    pub body: Option<Vec<u8>>,
    pub content_type: Option<String>,
    pub headers: Vec<(String, String)>,
    /// 有 HTML 时直接载入它（相对网址按 `url` 解析）。
    pub html: Option<String>,
    /// 页面加载后反复执行，直到返回非空；没有时取整页 HTML。
    pub js: Option<String>,
    pub source_regex: Option<String>,
    pub user_agent: String,
    pub cookies: Vec<(String, String)>,
    pub timeout: Duration,
    pub interactive: Interactive,
    /// 显示窗口时的标题（告诉用户要做什么）。
    pub prompt: String,
    /// 只读 WebView 里这个网址的 Cookie（不打开网页）。
    pub cookies_only: bool,
    pub bridge: Option<std::sync::Arc<crate::engine::SourceRt>>,
}

/// WebView 窗口何时给用户看。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Interactive {
    /// 一直在后台（书源脚本自己能拿到内容）。
    Never,
    /// 页面是人机验证 / 验证码时显示，用户完成后自动继续，最多等 5 分钟。
    OnChallenge,
    /// 一打开就显示，用户关窗口时结束（登录、书源要求打开浏览器）。
    Always,
}

/// WebView 里保存的这个网址的 Cookie（登录后留在 WebView 里的状态）带回书源 Cookie 罐。
pub fn sync_cookies_from_webview(scope: &Scope<'_, '_>, url: &str) -> Result<usize, String> {
    let out = submit(Job {
        context: {
            let mut c = crate::control::current();
            c.crawl = scope.source().meta.crawl.clone();
            c
        },
        url: url.to_owned(),
        method: "GET".into(),
        body: None,
        content_type: None,
        headers: Vec::new(),
        html: None,
        js: None,
        source_regex: None,
        user_agent: DEFAULT_UA.into(),
        cookies: Vec::new(),
        timeout: Duration::from_secs(10),
        interactive: Interactive::Never,
        prompt: String::new(),
        cookies_only: true,
        bridge: None,
    })?;
    if !out.cookies.is_empty() {
        let header = out
            .cookies
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join("; ");
        scope.net().set_cookie(url, &header);
    }
    Ok(out.cookies.len())
}

/// 普通请求拿到的是人机验证页（Cloudflare 等）：状态码 403 / 429 / 503 且像验证页，或带明显的验证页标记。
pub fn is_challenge_response(r: &Response) -> bool {
    let strong = [
        "cf-chl",
        "just a moment",
        "checking your browser",
        "ddos-guard",
        "确认您是真人",
    ];
    let head: String = r.text.chars().take(6000).collect::<String>().to_lowercase();
    r.header("cf-mitigated")
        .is_some_and(|v| v.eq_ignore_ascii_case("challenge"))
        || (matches!(r.status, 403 | 429 | 503) && looks_like_challenge(&head))
        || strong.iter().any(|m| head.contains(m))
}

/// 仅识别明确提示启用 JS、且 body 没有静态文本的 HTML 空壳。
pub fn needs_javascript(r: &Response) -> bool {
    if r.status != 200 || is_challenge_response(r) {
        return false;
    }
    let doc = scraper::Html::parse_document(&r.text);
    let select = |s| scraper::Selector::parse(s).unwrap();
    let hint = doc.select(&select("noscript")).any(|n| {
        let text = n.text().collect::<String>().to_lowercase();
        [
            "enable javascript",
            "启用javascript",
            "启用 javascript",
            "开启javascript",
            "开启 javascript",
        ]
        .iter()
        .any(|p| text.contains(p))
    });
    hint && doc.select(&select("script")).next().is_some()
        && doc
            .select(&select("body"))
            .next()
            .is_some_and(|b| crate::text::html_to_text(&b.inner_html()).is_empty())
}

/// 页面像人机验证 / 验证码页（标题与正文前部）。
pub fn looks_like_challenge(text: &str) -> bool {
    let t = text.chars().take(4000).collect::<String>().to_lowercase();
    [
        "just a moment",
        "checking your browser",
        "cf-chl",
        "attention required",
        "verify you are human",
        "ddos-guard",
        "captcha",
        "人机验证",
        "安全验证",
        "请完成验证",
        "滑动验证",
        "访问验证",
        "验证您是",
        "确认您是真人",
    ]
    .iter()
    .any(|m| t.contains(m))
}

pub struct Output {
    pub text: String,
    pub url: String,
    pub cookies: Vec<(String, String)>,
}

fn cookie_pairs(header: &str) -> Vec<(String, String)> {
    header
        .split(';')
        .filter_map(|p| p.trim().split_once('='))
        .map(|(k, v)| (k.trim().to_owned(), v.trim().to_owned()))
        .filter(|(k, _)| !k.is_empty())
        .collect()
}

fn execute(
    scope: &Scope<'_, '_>,
    url: &str,
    html: Option<String>,
    js: Option<String>,
    request: Option<&Request>,
) -> Result<Output, String> {
    execute_with(
        scope,
        url,
        html,
        js,
        request,
        Interactive::OnChallenge,
        String::new(),
    )
}

pub fn execute_with(
    scope: &Scope<'_, '_>,
    url: &str,
    html: Option<String>,
    js: Option<String>,
    request: Option<&Request>,
    interactive: Interactive,
    prompt: String,
) -> Result<Output, String> {
    if let Some(regex) = request.and_then(|r| r.source_regex.as_deref())
        && crate::pattern::compile(regex).is_none()
    {
        return Err("资源匹配规则正则无效".into());
    }
    let headers: &[(String, String)] = request.map_or(&[], |r| &r.headers);
    let url = scope.absolute(url);
    let user_agent = headers
        .iter()
        .chain(&scope.net().headers)
        .find(|(k, _)| k.eq_ignore_ascii_case("user-agent"))
        .map(|(_, v)| v.clone())
        .unwrap_or_else(|| DEFAULT_UA.to_owned());
    let cookies = reqwest::Url::parse(&url)
        .map(|u| cookie_pairs(&scope.net().cookie_header(&u)))
        .unwrap_or_default();
    scope.log("WebView 请求打开网页");
    let out = submit(Job {
        context: {
            let mut c = crate::control::current();
            c.crawl = scope.source().meta.crawl.clone();
            c
        },
        url: url.clone(),
        method: request.map_or("GET".into(), |r| r.method.to_ascii_uppercase()),
        body: request.and_then(|r| r.body.clone()),
        content_type: headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case("content-type"))
            .map(|(_, v)| v.clone()),
        html,
        js: js.filter(|j| !j.trim().is_empty()),
        source_regex: request.and_then(|r| r.source_regex.clone()),
        headers: headers.to_vec(),
        user_agent,
        cookies,
        timeout: TIMEOUT,
        interactive,
        prompt,
        cookies_only: false,
        bridge: None,
    })?;
    if !out.cookies.is_empty() {
        let header = out
            .cookies
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join("; ");
        scope.net().set_cookie(&out.url, &header);
        if out.url != url {
            scope.net().set_cookie(&url, &header);
        }
    }
    Ok(out)
}

/// 网址选项 `"webView": true`：在 WebView 里打开，结果当作网页响应。
pub fn load(scope: &Scope<'_, '_>, request: &Request, web_js: &str) -> Result<Response, String> {
    let js = (!web_js.trim().is_empty()).then(|| web_js.to_owned());
    let out = execute(scope, &request.url, None, js, Some(request))?;
    Ok(Response {
        url: out.url,
        status: 200,
        headers: Vec::new(),
        body: out.text.clone().into_bytes(),
        text: out.text,
        ..Default::default()
    })
}

/// `java.webView(html, url, js)` 与正文的 `webJs`。
pub fn run(
    scope: &Scope<'_, '_>,
    html: Option<String>,
    url: Option<String>,
    js: Option<String>,
) -> Result<String, String> {
    let url = url.unwrap_or_else(|| scope.absolute(""));
    let url = if url.is_empty() {
        scope.source().base_url().to_owned()
    } else {
        url
    };
    Ok(execute(scope, &url, html, js, None)?.text)
}

pub fn run_source(
    scope: &Scope<'_, '_>,
    html: Option<String>,
    url: Option<String>,
    js: Option<String>,
    regex: String,
) -> Result<String, String> {
    if regex.trim().is_empty() {
        return Err("资源匹配规则不能为空".into());
    }
    let request = Request {
        url: scope.absolute(url.as_deref().unwrap_or("")),
        method: "GET".into(),
        source_regex: Some(regex),
        ..Default::default()
    };
    Ok(execute(scope, &request.url, html, js, Some(&request))?.text)
}

pub fn supported() -> bool {
    cfg!(windows)
}

#[cfg(not(windows))]
mod host {
    pub fn submit(_job: super::Job) -> Result<super::Output, String> {
        Err(super::UNSUPPORTED.into())
    }
}

#[cfg(windows)]
mod host {
    use super::{Job, Output};
    use std::{
        sync::{Mutex, OnceLock, mpsc},
        time::{Duration, Instant},
    };
    use webview2_com::{
        CreateCoreWebView2ControllerCompletedHandler,
        CreateCoreWebView2EnvironmentCompletedHandler, ExecuteScriptCompletedHandler,
        GetCookiesCompletedHandler, Microsoft::Web::WebView2::Win32::*,
        NavigationCompletedEventHandler, NavigationStartingEventHandler,
        NewWindowRequestedEventHandler, WebResourceRequestedEventHandler, take_pwstr,
    };
    use windows::{
        Win32::{
            Foundation::{E_POINTER, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM},
            System::{Com::*, LibraryLoader::GetModuleHandleW},
            UI::WindowsAndMessaging::*,
        },
        core::{BOOL, HSTRING, Interface, PCWSTR, PWSTR, w},
    };

    type Reply = mpsc::Sender<Result<Output, String>>;
    type Queue = mpsc::Sender<(Job, Reply)>;
    static QUEUE: OnceLock<Mutex<Option<Queue>>> = OnceLock::new();
    static HTML_QUEUE: OnceLock<Mutex<Option<Queue>>> = OnceLock::new();

    pub fn submit(job: Job) -> Result<Output, String> {
        // 多个线程共用一个 WebView 时任务要排队：调用方最多等 10 分钟，单个任务仍按自己的期限。
        let wait = Duration::from_secs(600);
        let context = job.context.clone();
        context.check()?;
        // 载入 HTML 时 url 是基准地址，同样只接受网页。
        if !super::web_url(&job.url) {
            return Err(super::NOT_WEB.into());
        }
        if job.interactive == super::Interactive::Always && !context.interactive {
            return Err("需要网页验证：当前任务不允许交互".into());
        }
        let html = job.bridge.is_some();
        let queues = if html { &HTML_QUEUE } else { &QUEUE };
        let sender = {
            let mut queue = queues.get_or_init(Default::default).lock().unwrap();
            if queue.is_none() {
                *queue = Some(start(html)?);
            }
            queue.clone().unwrap()
        };
        let (tx, rx) = mpsc::channel();
        if sender.send((job, tx)).is_err() {
            // 线程已退出：下次重建。
            *queues.get().unwrap().lock().unwrap() = None;
            return Err("WebView 已关闭，请重试".into());
        }
        let until = Instant::now() + wait;
        loop {
            context.check()?;
            match rx.recv_timeout(Duration::from_millis(40)) {
                Ok(value) => return value,
                Err(mpsc::RecvTimeoutError::Timeout) if Instant::now() < until => (),
                Err(_) => return Err("WebView 无响应".into()),
            }
        }
    }

    fn start(html: bool) -> Result<mpsc::Sender<(Job, Reply)>, String> {
        let (tx, rx) = mpsc::channel::<(Job, Reply)>();
        std::thread::Builder::new()
            .name("booksource-webview".into())
            .spawn(move || {
                let mut active_args = String::new();
                let mut webview = None;
                loop {
                    match rx.recv_timeout(Duration::from_millis(20)) {
                        Ok((job, reply)) => {
                            let _guard = job.context.clone().enter();
                            let args = match if html || job.context.corpus.is_some() {
                                Ok("--no-proxy-server".to_owned())
                            } else {
                                crate::network_config::browser_args(&job.context.crawl, &job.url)
                            } {
                                Ok(a) => a,
                                Err(e) => {
                                    let _ = reply.send(Err(e));
                                    continue;
                                }
                            };
                            let configuration =
                                format!("{}:{args}", html || job.context.corpus.is_some());
                            if webview.is_none()
                                || configuration != active_args
                                || job.source_regex.is_some()
                            {
                                drop(webview.take());
                                match unsafe { create(&args, html || job.context.corpus.is_some()) }
                                {
                                    Ok(w) => {
                                        webview = Some(w);
                                        active_args = configuration;
                                    }
                                    Err(e) => {
                                        let _ = reply.send(Err(e));
                                        continue;
                                    }
                                }
                            }
                            let webview = webview.as_ref().unwrap();
                            let result =
                                unsafe { run_job(&webview.0.0, &webview.1, &webview.2, &job) };
                            let result = if let Err(error) = job.context.check() {
                                Err(error)
                            } else if CLOSE_ABORT.get() && CLOSED.get() {
                                Err("验证窗口已关闭，没有完成验证".into())
                            } else {
                                result
                            };
                            if result.is_err() {
                                unsafe {
                                    let _ = webview.1.Stop();
                                }
                            }
                            hide();
                            let _ = reply.send(result);
                        }
                        Err(mpsc::RecvTimeoutError::Timeout) => pump(),
                        Err(mpsc::RecvTimeoutError::Disconnected) => break,
                    }
                }
                drop(webview);
            })
            .map_err(|e| e.to_string())?;
        // 初始化也留在宿主线程；submit 的 40 ms 等待循环可随时取消。
        Ok(tx)
    }

    thread_local! {
        static WINDOW: std::cell::Cell<isize> = const { std::cell::Cell::new(0) };
        static CLOSED: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
        static CLOSE_ABORT: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    }

    extern "system" fn window_proc(hwnd: HWND, msg: u32, w: WPARAM, l: LPARAM) -> LRESULT {
        unsafe {
            if msg == WM_CLOSE {
                // 用户关窗口：只隐藏，WebView 留着下次用。
                let _ = ShowWindow(hwnd, SW_HIDE);
                CLOSED.set(true);
                return LRESULT(0);
            }
            DefWindowProcW(hwnd, msg, w, l)
        }
    }

    fn window() -> HWND {
        HWND(WINDOW.get() as *mut _)
    }

    unsafe fn show(controller: &ICoreWebView2Controller, prompt: &str) {
        unsafe {
            let hwnd = window();
            CLOSED.set(false);
            let _ = SetWindowTextW(hwnd, &HSTRING::from(prompt));
            let _ = ShowWindow(hwnd, SW_SHOWNORMAL);
            let _ = SetForegroundWindow(hwnd);
            let mut rect = RECT::default();
            if GetClientRect(hwnd, &mut rect).is_ok() {
                let _ = controller.SetBounds(rect);
            }
        }
    }

    fn hide() {
        CLOSE_ABORT.set(false);
        unsafe {
            let _ = ShowWindow(window(), SW_HIDE);
        }
    }

    fn data_folder() -> String {
        if let Ok(dir) = std::env::var("EASYPUB_WEBVIEW_DATA") {
            return dir;
        }
        let base = std::env::var("LOCALAPPDATA")
            .unwrap_or_else(|_| std::env::temp_dir().to_string_lossy().into_owned());
        format!("{base}\\EasyPubRustFlutter\\booksource-webview")
    }

    struct Controller(ICoreWebView2Controller);
    impl Drop for Controller {
        fn drop(&mut self) {
            unsafe {
                let _ = self.0.Close();
                let _ = DestroyWindow(window());
            }
        }
    }

    unsafe fn create(
        args: &str,
        html: bool,
    ) -> Result<(Controller, ICoreWebView2, ICoreWebView2Environment), String> {
        let fail = |e: &dyn std::fmt::Debug| {
            format!("WebView2 不可用（可能没有安装 WebView2 运行时）：{e:?}")
        };
        unsafe {
            let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
            let class = w!("EasyPubBookSourceWebView");
            let instance = GetModuleHandleW(None).ok().map(|h| HINSTANCE(h.0));
            RegisterClassW(&WNDCLASSW {
                lpfnWndProc: Some(window_proc),
                lpszClassName: class,
                hInstance: instance.unwrap_or_default(),
                ..Default::default()
            });
            // 不显示的普通窗口（不是纯消息窗口，WebView2 才会渲染与执行定时器）。
            let hwnd = CreateWindowExW(
                Default::default(),
                class,
                w!("EasyPub WebView"),
                WS_OVERLAPPEDWINDOW,
                0,
                0,
                1280,
                900,
                None,
                None,
                instance,
                None,
            )
            .map_err(|e| fail(&e))?;
            WINDOW.set(hwnd.0 as isize);
            use sha2::{Digest, Sha256};
            let hash = hex::encode(Sha256::digest(args.as_bytes()));
            let folder = HSTRING::from(format!(
                "{}\\{}-{}",
                data_folder(),
                if html { "html" } else { "page" },
                &hash[..12]
            ));
            let options = webview2_com::CoreWebView2EnvironmentOptions::default();
            options.set_additional_browser_arguments(args.to_owned());
            let options: ICoreWebView2EnvironmentOptions = options.into();
            let (tx, rx) = mpsc::channel();
            CreateCoreWebView2EnvironmentCompletedHandler::wait_for_async_operation(
                Box::new(move |handler| {
                    CreateCoreWebView2EnvironmentWithOptions(
                        PCWSTR::null(),
                        &folder,
                        &options,
                        &handler,
                    )
                    .map_err(webview2_com::Error::WindowsError)
                }),
                Box::new(move |error, environment| {
                    error?;
                    let _ =
                        tx.send(environment.ok_or_else(|| windows::core::Error::from(E_POINTER)));
                    Ok(())
                }),
            )
            .map_err(|e| fail(&e))?;
            let environment = rx.recv().map_err(|e| fail(&e))?.map_err(|e| fail(&e))?;
            let env_for_jobs = environment.clone();
            let (tx, rx) = mpsc::channel();
            CreateCoreWebView2ControllerCompletedHandler::wait_for_async_operation(
                Box::new(move |handler| {
                    environment
                        .CreateCoreWebView2Controller(hwnd, &handler)
                        .map_err(webview2_com::Error::WindowsError)
                }),
                Box::new(move |error, controller| {
                    error?;
                    let _ =
                        tx.send(controller.ok_or_else(|| windows::core::Error::from(E_POINTER)));
                    Ok(())
                }),
            )
            .map_err(|e| fail(&e))?;
            let controller = rx.recv().map_err(|e| fail(&e))?.map_err(|e| fail(&e))?;
            controller
                .SetBounds(RECT {
                    left: 0,
                    top: 0,
                    right: 1280,
                    bottom: 900,
                })
                .map_err(|e| fail(&e))?;
            controller.SetIsVisible(true).map_err(|e| fail(&e))?;
            let webview = controller.CoreWebView2().map_err(|e| fail(&e))?;
            if let Ok(settings) = webview.Settings() {
                let _ = settings.SetAreDevToolsEnabled(false);
                let _ = settings.SetAreDefaultContextMenusEnabled(false);
                let _ = settings.SetIsStatusBarEnabled(false);
            }
            // 页面内跳转同样只放行网页；about: / data: 是载入 HTML 字符串本身。
            let mut token = 0i64;
            webview
                .add_NavigationStarting(
                    &NavigationStartingEventHandler::create(Box::new(move |_, args| {
                        if let Some(args) = args {
                            let mut uri = PWSTR::null();
                            if args.Uri(&mut uri).is_ok() {
                                let uri = take_pwstr(uri);
                                if !((!html && super::web_url(&uri))
                                    || uri.starts_with("about:")
                                    || uri.starts_with("data:"))
                                {
                                    let _ = args.SetCancel(true);
                                }
                            }
                        }
                        Ok(())
                    })),
                    &mut token,
                )
                .map_err(|e| fail(&e))?;
            webview
                .add_NewWindowRequested(
                    &NewWindowRequestedEventHandler::create(Box::new(move |sender, args| {
                        if let Some(args) = args {
                            let _ = args.SetHandled(true);
                            if !html && let Some(sender) = sender {
                                let mut uri = PWSTR::null();
                                if args.Uri(&mut uri).is_ok() {
                                    let target = take_pwstr(uri);
                                    if super::web_url(&target) {
                                        let _ = sender.Navigate(&HSTRING::from(target));
                                    }
                                }
                            }
                        }
                        Ok(())
                    })),
                    &mut token,
                )
                .map_err(|e| fail(&e))?;
            if html {
                // HTML 桥接宿主的网络只能由 Rust 发送；连页面导航也不能
                // 绕过代理、取消和限速。使用覆盖 frame / worker 的新接口。
                webview
                    .cast::<ICoreWebView2_22>()
                    .and_then(|view| {
                        view.AddWebResourceRequestedFilterWithRequestSourceKinds(
                            w!("*"),
                            COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL,
                            COREWEBVIEW2_WEB_RESOURCE_REQUEST_SOURCE_KINDS_ALL,
                        )
                    })
                    .map_err(|e| fail(&e))?;
                let response_env = env_for_jobs.clone();
                webview
                    .add_WebResourceRequested(
                        &WebResourceRequestedEventHandler::create(Box::new(move |_, args| {
                            if let Some(args) = args {
                                let response = response_env.CreateWebResourceResponse(
                                    None,
                                    403,
                                    w!("Use the source bridge"),
                                    w!("Content-Length: 0"),
                                )?;
                                args.SetResponse(&response)?;
                            }
                            Ok(())
                        })),
                        &mut token,
                    )
                    .map_err(|e| fail(&e))?;
            }
            Ok((Controller(controller), webview, env_for_jobs))
        }
    }

    fn pump() {
        unsafe {
            let mut msg = MSG::default();
            while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
    }

    /// 一边泵消息一边等回调结果，到期限返回 None。
    fn wait<T>(rx: &mpsc::Receiver<T>, deadline: Instant) -> Option<T> {
        loop {
            if let Ok(v) = rx.try_recv() {
                return Some(v);
            }
            if Instant::now() > deadline
                || crate::control::current().check().is_err()
                || (CLOSE_ABORT.get() && CLOSED.get())
            {
                return None;
            }
            pump();
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    fn sleep_pumping(d: Duration) {
        let end = Instant::now() + d;
        while Instant::now() < end
            && crate::control::current().check().is_ok()
            && !(CLOSE_ABORT.get() && CLOSED.get())
        {
            pump();
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    /// POST：用请求对象带上正文与 Content-Type。
    unsafe fn post(
        webview: &ICoreWebView2,
        environment: &ICoreWebView2Environment,
        job: &Job,
    ) -> windows::core::Result<()> {
        unsafe {
            let env2 = environment.cast::<ICoreWebView2Environment2>()?;
            let body = job.body.clone().unwrap_or_default();
            let stream = windows::Win32::UI::Shell::SHCreateMemStream(Some(&body));
            let content_type = job
                .content_type
                .clone()
                .unwrap_or_else(|| "application/x-www-form-urlencoded".into());
            let mut headers = job.headers.clone();
            if job.method == "POST"
                && !headers
                    .iter()
                    .any(|(k, _)| k.eq_ignore_ascii_case("content-type"))
            {
                headers.push(("Content-Type".into(), content_type));
            }
            let headers = headers
                .iter()
                .filter(|(k, v)| !k.contains(['\r', '\n', ':']) && !v.contains(['\r', '\n']))
                .map(|(k, v)| format!("{k}: {v}\r\n"))
                .collect::<String>();
            let request = env2.CreateWebResourceRequest(
                &HSTRING::from(job.url.as_str()),
                &HSTRING::from(job.method.as_str()),
                stream.as_ref(),
                &HSTRING::from(headers),
            )?;
            webview
                .cast::<ICoreWebView2_2>()?
                .NavigateWithWebResourceRequest(&request)
        }
    }

    unsafe fn script(
        webview: &ICoreWebView2,
        js: &str,
        deadline: Instant,
    ) -> Result<String, String> {
        let (tx, rx) = mpsc::channel();
        let handler = ExecuteScriptCompletedHandler::create(Box::new(move |error, result| {
            let _ = tx.send(error.map(|_| result));
            Ok(())
        }));
        unsafe { webview.ExecuteScript(&HSTRING::from(js), &handler) }
            .map_err(|e| format!("脚本无法执行：{e}"))?;
        let json = wait(&rx, deadline)
            .ok_or("WebView 脚本超时")?
            .map_err(|e| format!("脚本出错：{e}"))?;
        // 结果是 JSON：字符串去引号，其他原样。
        Ok(match serde_json::from_str::<serde_json::Value>(&json) {
            Ok(serde_json::Value::String(s)) => s,
            Ok(serde_json::Value::Null) => String::new(),
            Ok(other) => other.to_string(),
            Err(_) => json,
        })
    }

    unsafe fn run_job(
        controller: &ICoreWebView2Controller,
        webview: &ICoreWebView2,
        environment: &ICoreWebView2Environment,
        job: &Job,
    ) -> Result<Output, String> {
        job.context.check()?;
        let mut deadline = Instant::now() + job.timeout;
        unsafe {
            if job.cookies_only {
                let cookies = match webview
                    .cast::<ICoreWebView2_2>()
                    .and_then(|w| w.CookieManager())
                {
                    Ok(manager) => read_cookies(&manager, &job.url, deadline),
                    Err(_) => Vec::new(),
                };
                return Ok(Output {
                    text: String::new(),
                    url: job.url.clone(),
                    cookies,
                });
            }
            // 注册在导航之前，返回首个匹配的 HTTP(S) 请求 URL，不读取资源正文。
            let captured = std::rc::Rc::new(std::cell::RefCell::new(None::<String>));
            let _capture = if let Some(regex) = &job.source_regex {
                let pattern = crate::pattern::compile(regex).ok_or("资源匹配规则正则无效")?;
                webview
                    .AddWebResourceRequestedFilter(w!("*"), COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL)
                    .map_err(|_| "资源捕获不可用")?;
                let result = captured.clone();
                let mut token = 0;
                webview
                    .add_WebResourceRequested(
                        &WebResourceRequestedEventHandler::create(Box::new(move |_, args| {
                            if result.borrow().is_none()
                                && let Some(args) = args
                            {
                                let request = args.Request()?;
                                let mut uri = PWSTR::null();
                                request.Uri(&mut uri)?;
                                let uri = take_pwstr(uri);
                                if super::web_url(&uri) && pattern.is_match(&uri) {
                                    *result.borrow_mut() = Some(uri);
                                }
                            }
                            Ok(())
                        })),
                        &mut token,
                    )
                    .map_err(|_| "资源捕获不可用")?;
                Some(ResourceCapture {
                    view: webview.clone(),
                    token,
                })
            } else {
                None
            };
            if let Ok(settings) = webview
                .Settings()
                .and_then(|s| s.cast::<ICoreWebView2Settings2>())
            {
                let _ = settings.SetUserAgent(&HSTRING::from(job.user_agent.as_str()));
            }
            let manager = webview
                .cast::<ICoreWebView2_2>()
                .and_then(|w| w.CookieManager())
                .ok();
            if let (Some(manager), Ok(url)) = (&manager, reqwest::Url::parse(&job.url)) {
                let domain = url.host_str().unwrap_or("").to_owned();
                for (name, value) in &job.cookies {
                    if let Ok(cookie) = manager.CreateCookie(
                        &HSTRING::from(name.as_str()),
                        &HSTRING::from(value.as_str()),
                        &HSTRING::from(domain.as_str()),
                        w!("/"),
                    ) {
                        let _ = manager.AddOrUpdateCookie(&cookie);
                    }
                }
            }
            let (tx, rx) = mpsc::channel();
            let handler = NavigationCompletedEventHandler::create(Box::new(move |_, args| {
                let ok = args
                    .map(|a| {
                        let mut ok = BOOL::default();
                        let _ = a.IsSuccess(&mut ok);
                        ok.as_bool()
                    })
                    .unwrap_or(false);
                let _ = tx.send(ok);
                Ok(())
            }));
            let mut token = 0i64;
            webview
                .add_NavigationCompleted(&handler, &mut token)
                .map_err(|e| e.to_string())?;
            let started = match &job.html {
                Some(html) => {
                    let base = format!("<base href=\"{}\">", job.url.replace('"', "%22"));
                    webview.NavigateToString(&HSTRING::from(format!("{base}{html}")))
                }
                None if job.method != "GET" || !job.headers.is_empty() => {
                    post(webview, environment, job)
                }
                None => webview.Navigate(&HSTRING::from(job.url.as_str())),
            };
            let loaded = started
                .map_err(|e| format!("网页无法打开：{e}"))
                .and_then(|_| wait(&rx, deadline).ok_or_else(|| "网页加载超时".to_string()));
            let _ = webview.remove_NavigationCompleted(token);
            // 加载“不成功”（如 4xx、验证页）时页面里往往仍有内容：照样执行脚本，由脚本结果决定。
            loaded?;
            // 书源脚本可能要等页面里的异步内容：返回空时每半秒再试，直到期限。
            let js = job
                .js
                .clone()
                .unwrap_or_else(|| "document.documentElement.outerHTML".into());
            let started = Instant::now();
            let mut shown = false;
            if job.interactive == super::Interactive::Always {
                show(controller, &job.prompt);
                shown = true;
                deadline = Instant::now() + Duration::from_secs(600);
            }
            let probe = r"document.title + '\n' + (document.body ? document.body.innerText : '')";
            let text = loop {
                job.context.check()?;
                if let Some(url) = captured.borrow_mut().take() {
                    break url;
                }
                if let Some(rt) = &job.bridge {
                    let queue = script(
                        webview,
                        "JSON.stringify(window.__epDrain ? window.__epDrain() : [])",
                        deadline,
                    )?;
                    let calls: Vec<serde_json::Value> =
                        serde_json::from_str(&queue).unwrap_or_default();
                    for call in calls {
                        let name = call["name"].as_str().unwrap_or("");
                        let args = call["args"].as_array().map(Vec::as_slice).unwrap_or(&[]);
                        let result = crate::qysg::bridge(rt, name, args);
                        // 不能让源脚本 catch 网络/接口异常后把它伪装成空列表。
                        let value = result?;
                        let reply = format!("window.__epReply({}, {}, null)", call["id"], value);
                        script(webview, &reply, deadline)?;
                    }
                }
                let empty = |t: &str| t.trim().is_empty() || t == "null" || t == "undefined";
                if job.interactive == super::Interactive::Always {
                    // 由用户决定何时结束：关窗口后取当前页面。
                    if CLOSED.get() {
                        break script(webview, &js, Instant::now() + Duration::from_secs(10))
                            .unwrap_or_default();
                    }
                    if Instant::now() > deadline {
                        break script(webview, &js, Instant::now() + Duration::from_secs(10))
                            .unwrap_or_default();
                    }
                    sleep_pumping(Duration::from_millis(300));
                    continue;
                }
                let text = script(webview, &js, deadline)?;
                let challenge = job.interactive == super::Interactive::OnChallenge
                    && (started.elapsed() > Duration::from_secs(3) || !empty(&text))
                    && script(webview, probe, deadline)
                        .map(|t| super::looks_like_challenge(&t))
                        .unwrap_or(false);
                let pending_render = job.js.is_none()
                    && super::needs_javascript(&crate::net::Response {
                        status: 200,
                        text: text.clone(),
                        ..Default::default()
                    });
                if !empty(&text) && !challenge && !pending_render && job.source_regex.is_none() {
                    break text;
                }
                if challenge
                    && (!job.context.interactive
                        || std::env::var_os("EASYPUB_WEBVIEW_NONINTERACTIVE").is_some())
                {
                    return Err("需要网页验证".into());
                }
                if challenge && !shown {
                    show(
                        controller,
                        if job.prompt.is_empty() {
                            "EasyPub：请在此完成网页验证，完成后会自动继续"
                        } else {
                            &job.prompt
                        },
                    );
                    shown = true;
                    CLOSE_ABORT.set(true);
                    deadline = Instant::now() + Duration::from_secs(300);
                }
                if shown && CLOSED.get() {
                    return Err("验证窗口已关闭，没有完成验证".into());
                }
                if Instant::now() + Duration::from_millis(500) > deadline {
                    return Err(if job.source_regex.is_some() && !shown {
                        "资源匹配规则未捕获到网址".into()
                    } else if shown {
                        "等待网页验证超时".into()
                    } else {
                        "WebView 脚本一直没有返回内容".into()
                    });
                }
                sleep_pumping(Duration::from_millis(if job.bridge.is_some() {
                    20
                } else {
                    500
                }));
            };
            let mut source = PWSTR::null();
            let url = if webview.Source(&mut source).is_ok() {
                take_pwstr(source)
            } else {
                job.url.clone()
            };
            let url = if url.starts_with("http") {
                url
            } else {
                job.url.clone()
            };
            let cookies = match manager {
                Some(manager) => read_cookies(&manager, &url, deadline),
                None => Vec::new(),
            };
            Ok(Output { text, url, cookies })
        }
    }

    struct ResourceCapture {
        view: ICoreWebView2,
        token: i64,
    }
    impl Drop for ResourceCapture {
        fn drop(&mut self) {
            unsafe {
                let _ = self.view.remove_WebResourceRequested(self.token);
                let _ = self.view.RemoveWebResourceRequestedFilter(
                    w!("*"),
                    COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL,
                );
                let _ = self.view.Stop();
            }
        }
    }

    unsafe fn read_cookies(
        manager: &ICoreWebView2CookieManager,
        url: &str,
        deadline: Instant,
    ) -> Vec<(String, String)> {
        unsafe {
            let mut cookies = Vec::new();
            {
                let (tx, rx) = mpsc::channel();
                let handler = GetCookiesCompletedHandler::create(Box::new(move |error, list| {
                    let mut out = Vec::new();
                    if error.is_ok()
                        && let Some(list) = list
                    {
                        let mut count = 0u32;
                        let _ = list.Count(&mut count);
                        for i in 0..count {
                            if let Ok(cookie) = list.GetValueAtIndex(i) {
                                let (mut name, mut value) = (PWSTR::null(), PWSTR::null());
                                if cookie.Name(&mut name).is_ok()
                                    && cookie.Value(&mut value).is_ok()
                                {
                                    out.push((take_pwstr(name), take_pwstr(value)));
                                }
                            }
                        }
                    }
                    let _ = tx.send(out);
                    Ok(())
                }));
                if manager.GetCookies(&HSTRING::from(url), &handler).is_ok() {
                    cookies = wait(&rx, deadline + Duration::from_secs(5)).unwrap_or_default();
                }
            }
            cookies
        }
    }
}

/// 让引擎的公共入口编译期就检查任务字段齐全。
pub fn submit(mut job: Job) -> Result<Output, String> {
    if let Some(tape) = job.context.corpus.clone() {
        if !web_url(&job.url) {
            return Err(NOT_WEB.into());
        }
        if job.cookies_only {
            return Ok(Output {
                text: String::new(),
                url: job.url,
                cookies: vec![],
            });
        }
        if job.html.is_none() {
            // 样本回放使用录下的 HTML 快照，仍实际执行 DOM / webJs。
            let _guard = job.context.clone().enter();
            let net = crate::net::Net::new(None, vec![]);
            let r = net
                .fetch(&Request {
                    url: job.url.clone(),
                    method: job.method.clone(),
                    body: job.body.clone(),
                    headers: job.headers.clone(),
                    ..Default::default()
                })
                .map_err(|e| e.0)?;
            if r.status >= 400 {
                return Err(format!("网站返回 {}", r.status));
            }
            job.html = Some(r.text);
        }
        tape.check_browser_snapshot(job.html.as_deref().unwrap_or(""))?;
        job.html=job.html.map(|html|format!("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:\">{html}"));
    }
    host::submit(job)
}
