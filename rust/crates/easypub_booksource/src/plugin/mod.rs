//! 书源插件进程：标准输入每行一个请求 `{"id":1,"method":"…","params":{…}}`，
//! 标准输出每行一个回复 `{"id":1,"result":…}` / `{"id":1,"error":"…"}` 或事件 `{"event":"…",…}`。
//! 数据目录由 `--data 目录` 指定（书源列表 sources.json；不保存 Cookie）。
use crate::{
    download::{self, Options},
    engine::{Engine, SourceRt},
    source::{self, BookSource},
    support,
    webbook::{Book, Chapter},
};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    io::{BufRead, Write},
    path::PathBuf,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

mod enrich;
pub(crate) mod fqnovel;
mod interactions;
mod library;
mod management;
mod queue;
mod search;
mod sources;
mod subscriptions;
#[cfg(test)]
mod tests;
use library::{check_library, load_library};
use queue::start_download;

const PROTOCOL: u32 = 1;

#[derive(Default)]
struct State {
    data: PathBuf,
    sources: Vec<(BookSource, bool)>,
    runtimes: HashMap<String, Arc<SourceRt>>,
    tasks: HashMap<String, Arc<AtomicBool>>,
    next_task: u64,
    queue: Vec<queue::Task>,
    max_books: usize,
    searches: HashMap<String, Arc<AtomicBool>>,
    search_sessions: HashMap<String, Arc<Mutex<search::Session>>>,
    maintenance_paths: Vec<PathBuf>,
    book_cache: HashMap<String, (Book, Vec<Chapter>)>,
}

static OUT: Mutex<()> = Mutex::new(());
#[cfg(test)]
static TEST_EVENTS: Mutex<Vec<Value>> = Mutex::new(Vec::new());
static STATE: OnceLock<Mutex<State>> = OnceLock::new();

fn state() -> std::sync::MutexGuard<'static, State> {
    STATE.get().unwrap().lock().unwrap()
}

fn send(value: Value) {
    #[cfg(test)]
    TEST_EVENTS.lock().unwrap().push(value.clone());
    let _guard = OUT.lock().unwrap();
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{value}");
    let _ = out.flush();
}

fn store_path() -> PathBuf {
    state().data.join("sources.json")
}

fn save(st: &State) -> Result<(), String> {
    let items: Vec<Value> = st
        .sources
        .iter()
        .map(|(s, enabled)| {
            let mut v = serde_json::to_value(s).unwrap_or_default();
            v["enabled"] = Value::Bool(*enabled);
            sources::sanitize_json(&mut v);
            v
        })
        .collect();
    std::fs::create_dir_all(&st.data).map_err(|e| e.to_string())?;
    let path = st.data.join("sources.json");
    download::write_atomic(&path, &serde_json::to_vec(&items).unwrap_or_default())
}

fn load() {
    let path = store_path();
    let Ok(text) = std::fs::read_to_string(&path) else {
        return;
    };
    if let Ok((sources, _)) = source::import(&text) {
        state().sources = sources
            .into_iter()
            .map(|s| {
                let enabled = s.enabled;
                (s, enabled)
            })
            .collect();
    }
}

/// 同一书源复用网络端、Cookie 罐与连接池。
fn find_source<'a>(st: &'a State, id: &str) -> Option<&'a BookSource> {
    let original = id
        .rsplit_once("::")
        .filter(|(_, hash)| hash.len() == 12 && hash.chars().all(|c| c.is_ascii_hexdigit()))
        .map_or(id, |(url, _)| url);
    st.sources
        .iter()
        .find(|(s, _)| s.id() == id)
        .or_else(|| {
            st.sources
                .iter()
                .filter(|(s, _)| s.book_source_url == original)
                .max_by_key(|(s, _)| s.last_update_time)
        })
        .map(|(s, _)| s)
}

fn runtime(id: &str) -> Result<Arc<SourceRt>, String> {
    let mut st = state();
    if let Some(rt) = st.runtimes.get(id) {
        return Ok(rt.clone());
    }
    let source = find_source(&st, id).cloned().ok_or("没有这个书源")?;
    let login = !source.login_url.trim().is_empty();
    let rt = SourceRt::new(source);
    *rt.services.data_dir.lock().unwrap() = Some(st.data.clone());
    *rt.login_info.lock().unwrap() = crate::login_store::load(&st.data, rt.source.id())?;
    st.runtimes.insert(id.to_owned(), rt.clone());
    drop(st);
    // 有登录的书源：把 WebView 里保存的登录状态（Cookie）带回来。
    if login
        && crate::webview::supported()
        && let Ok(engine) = Engine::new(rt.clone())
    {
        let base = rt.source.base_url().to_owned();
        let _ = engine.run(|s| crate::webview::sync_cookies_from_webview(s, &base));
    }
    Ok(rt)
}

fn with_engine<R>(id: &str, f: impl FnOnce(&Engine) -> Result<R, String>) -> Result<R, String> {
    let engine = Engine::new(runtime(id)?)?;
    f(&engine)
}

fn param<T: serde::de::DeserializeOwned>(params: &Value, key: &str) -> Result<T, String> {
    serde_json::from_value(params.get(key).cloned().unwrap_or(Value::Null))
        .map_err(|_| format!("参数 {key} 不对"))
}

fn handle(method: &str, params: &Value) -> Result<Value, String> {
    if method == "source.loginData.clear" {
        let id: String = param(params, "id")?;
        let st = state();
        let source = find_source(&st, &id).ok_or("没有这个书源")?;
        let mut infos: Vec<_> = st
            .runtimes
            .values()
            .filter(|rt| rt.source.id() == source.id())
            .map(|rt| rt.login_info.lock().unwrap())
            .collect();
        crate::login_store::clear(&st.data, source.id())?;
        for info in &mut infos {
            **info = None;
        }
        return Ok(json!({"ok":true}));
    }
    if method.starts_with("source.interaction.") {
        return interactions::handle(method, params);
    }
    if method.starts_with("fqnovel.") {
        return fqnovel::handle(method, params);
    }
    if method.starts_with("subscriptions.") {
        return subscriptions::handle(method, params);
    }
    if method.starts_with("sources.") || method == "__import_body" {
        return sources::handle(method, params);
    }
    if method.starts_with("queue.") {
        return queue::handle(method, params);
    }
    if method.starts_with("network.proxy.")
        || method.starts_with("filters.")
        || matches!(method, "download.diagnose" | "library.provenance")
    {
        return management::handle(method, params);
    }
    match method {
        "corpus.record" => crate::corpus::record(
            params["source"].clone(),
            params["key"].as_str().unwrap_or("三国演义"),
            &PathBuf::from(param::<String>(params, "folder")?),
            param(params, "coverage")?,
            params["origin"].as_str().unwrap_or("recorded").to_owned(),
        ),
        "corpus.replay" => {
            crate::corpus::replay(&PathBuf::from(param::<String>(params, "folder")?))
        }
        "hello" => Ok(
            json!({ "name": "书源下载", "version": env!("CARGO_PKG_VERSION"), "protocol": PROTOCOL, "webView": crate::webview::supported() }),
        ),
        "source.loginInfo" => {
            let id: String = param(params, "id")?;
            let st = state();
            let (s, _) = st
                .sources
                .iter()
                .find(|(s, _)| s.id() == id)
                .ok_or("没有这个书源")?;
            let ui: Value = serde_json::from_str(&s.login_ui).unwrap_or(Value::Null);
            let url = s.login_url.trim();
            Ok(
                json!({ "ui": ui, "web": url.starts_with("http") || url.starts_with('/'), "has": !url.is_empty() }),
            )
        }
        "source.login" => login(params),
        "source.loginAction" => login_action(params),
        "source.explore" => {
            let id: String = param(params, "id")?;
            let url: String = param(params, "url")?;
            let page = params.get("page").and_then(Value::as_i64).unwrap_or(1);
            if page < 1 {
                return Err("发现页码必须大于零".into());
            }
            let rt = runtime(&id)?;
            let revision = rt.services.explore_revision.load(Ordering::SeqCst);
            let mut context = crate::control::current();
            context.exploring = true;
            let _guard = context.enter();
            let books = Engine::new(rt.clone())?.run(|scope| scope.explore(&url, page))?;
            let current = rt.services.explore_revision.load(Ordering::SeqCst);
            Ok(
                json!({"books":if current == revision { books } else { vec![] },"revision":revision,"current_revision":current,"stale":current != revision}),
            )
        }
        "source.exploreRevision" => {
            let id: String = param(params, "id")?;
            Ok(json!({"revision":runtime(&id)?.services.explore_revision.load(Ordering::SeqCst)}))
        }
        "library.list" => Ok(Value::Array(load_library())),
        "library.check" => check_library(params),
        "library.autoCheck.get" | "library.autoCheck.set" => library::auto_check(method, params),
        "library.update" => {
            let key: String = param(params, "key")?;
            let record = load_library()
                .into_iter()
                .find(|r| r["key"] == key.as_str())
                .ok_or("没有这条下载记录")?;
            let mut options: Options = param(&record, "options")?;
            options.preserve_existing = true;
            options.retry_failed.clear();
            // 检查失败后不继续使用更早一次的在线目录。
            let toc = if record["checkError"].is_null() {
                record["onlineToc"].clone()
            } else {
                Value::Null
            };
            start_download(&json!({
                "sourceId": record["sourceId"], "book": record["book"],
                "options": options, "toc": toc, "update": true
            }))
        }
        "library.remove" => library::remove(params),
        "search" => search::search(params),
        "search.more" => search::resume(params, false),
        "search.retry" => search::resume(params, true),
        "search.cancel" => search::cancel(params),
        "search.enrich" => enrich::run(params),
        "batch.resolve" => search::resolve(params),
        "library.rebuild" => library::rebuild(params),
        "book.info" => {
            let id: String = param(params, "sourceId")?;
            let mut book: Book = param(params, "book")?;
            let cached = state().book_cache.get(&enrich::key(&id, &book)).cloned();
            if let Some((b, _)) = cached {
                book = b;
            } else {
                with_engine(&id, |e| e.run(|s| s.book_info(&mut book)))?;
                state()
                    .book_cache
                    .insert(enrich::key(&id, &book), (book.clone(), Vec::new()));
            }
            Ok(serde_json::to_value(book).unwrap_or_default())
        }
        "book.toc" => {
            let id: String = param(params, "sourceId")?;
            let mut book: Book = param(params, "book")?;
            let toc = enrich::toc(&id, &mut book, params["refresh"] == true)?;
            Ok(serde_json::to_value(toc).unwrap_or_default())
        }
        "download.start" => start_download(params),
        "download.cancel" => queue::handle("queue.cancel", params),
        other => Err(format!("不支持的请求：{other}")),
    }
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// 登录：有登录界面时用填写的信息执行书源的 login()；登录地址是网址时打开网页让用户登录，
/// 登录状态（Cookie）带回书源。填写的信息按书源经 DPAPI 加密保存。
/// 登录界面按钮（阅读 loginUi 的 button）：按序号执行书源自带的 action。
/// action 是网址时打开登录网页；否则把登录脚本（loginUrl 里的函数）与 action 一起执行。
/// 界面只传序号和可选的表单字段，不能提交任意脚本。
fn login_action(params: &Value) -> Result<Value, String> {
    let id: String = param(params, "id")?;
    let index: usize = param(params, "index")?;
    let rt = runtime(&id)?;
    if !rt.source.main_js.is_empty() {
        return Err("单文件 JS 的 loginUi / loginAction 暂不支持".into());
    }
    let ui: Value = serde_json::from_str(&rt.source.login_ui).map_err(|_| "登录界面定义无效")?;
    let item = ui
        .get(index)
        .filter(|i| i["type"] == "button")
        .ok_or("没有这个登录按钮")?;
    let action = item["action"].as_str().unwrap_or("").trim().to_owned();
    if action.is_empty() {
        return Err("这个按钮没有设置动作".into());
    }
    if let Some(info) = params
        .get("info")
        .filter(|v| v.as_object().is_some_and(|m| !m.is_empty()))
    {
        rt.set_login_info(info.to_string())?;
    }
    let engine = Engine::new(rt.clone())?;
    if action.starts_with("http://") || action.starts_with("https://") {
        let name = rt.source.book_source_name.trim().to_owned();
        engine.run(|s| {
            crate::webview::execute_with(
                s,
                &action,
                None,
                None,
                None,
                crate::webview::Interactive::Always,
                format!("EasyPub：{name}，完成后关闭窗口"),
            )
            .map(|_| ())
        })?;
        return Ok(json!({"ok":true,"message":"网页已关闭"}));
    }
    let login = rt.source.login_url.trim();
    // 与阅读一致：loginUrl 不是网址时整段都是登录脚本（可带 @js: / <js> 前缀）。
    let login = if login.starts_with("http://")
        || login.starts_with("https://")
        || login.starts_with('/')
    {
        ""
    } else {
        login
            .trim_start_matches("@js:")
            .trim_start_matches("<js>")
            .trim_end_matches("</js>")
    };
    let action = action
        .trim_start_matches("@js:")
        .trim_start_matches("<js>")
        .trim_end_matches("</js>");
    engine.run(|s| s.eval_js(&format!("{login}\n;{action}"), &[]))?;
    let _logs = engine.take_logs();
    Ok(json!({"ok":true,"message":format!("已执行“{}”", item["name"].as_str().unwrap_or("按钮"))}))
}

fn login(params: &Value) -> Result<Value, String> {
    let id: String = param(params, "id")?;
    let rt = runtime(&id)?;
    if !rt.source.main_js.is_empty() {
        if !rt.source.login_ui.is_empty() || !rt.source.login_action.is_empty() {
            return Err("单文件 JS 的 loginUi / loginAction 暂不支持".into());
        }
        Engine::new(rt.clone())?.run(|s| s.main_call("login", json!([])))?;
        return Ok(json!({"ok":true,"message":"已执行书源登录"}));
    }
    let url = rt.source.login_url.trim().to_owned();
    if url.is_empty() {
        return Err("这个书源没有登录设置".into());
    }
    if let Some(info) = params.get("info").filter(|v| v.is_object()) {
        rt.set_login_info(info.to_string())?;
        let code = url
            .trim_start_matches("@js:")
            .trim_start_matches("<js>")
            .trim_end_matches("</js>")
            .to_owned();
        let engine = Engine::new(rt.clone())?;
        engine.run(|s| {
            s.eval_js(
                &format!("{code}\n;if (typeof login == 'function') login();"),
                &[],
            )
        })?;
        let _logs = engine.take_logs();
        return Ok(json!({ "ok": true, "message": "已执行书源的登录" }));
    }
    let engine = Engine::new(rt.clone())?;
    let name = rt.source.book_source_name.trim().to_owned();
    engine.run(|s| {
        let target = s.absolute(&url);
        crate::webview::execute_with(
            s,
            &target,
            None,
            None,
            None,
            crate::webview::Interactive::Always,
            format!("EasyPub：登录 {name}，登录完成后关闭窗口"),
        )
        .map(|_| ())
    })?;
    Ok(json!({ "ok": true, "message": "登录窗口已关闭，登录状态已带回书源" }))
}

pub fn run() {
    let args: Vec<String> = std::env::args().collect();
    let data = args
        .iter()
        .position(|a| a == "--data")
        .and_then(|i| args.get(i + 1))
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("easypub-booksource"));
    // WebView 的数据（Cookie 等）放在插件数据目录里。
    if std::env::var_os("EASYPUB_WEBVIEW_DATA").is_none() {
        // SAFETY: 启动时、其他线程开始之前设置。
        unsafe { std::env::set_var("EASYPUB_WEBVIEW_DATA", data.join("webview")) };
    }
    STATE
        .set(Mutex::new(State {
            data,
            max_books: 2,
            ..Default::default()
        }))
        .ok();
    load();
    management::load();
    if subscriptions::load().is_err() {
        send(
            json!({"event":"subscriptions.error","error":"订阅恢复失败，请保留数据目录检查；本次未检查更新"}),
        );
    } else {
        std::thread::spawn(|| {
            subscriptions::due(true);
            loop {
                std::thread::sleep(Duration::from_secs(60));
                subscriptions::due(false);
                library::auto_due();
            }
        });
    }
    queue::load();
    queue::schedule();
    let stdin = std::io::stdin();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let request: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => {
                send(json!({ "id": null, "error": "请求不是 JSON" }));
                continue;
            }
        };
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let method = request
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned();
        let params = request.get("params").cloned().unwrap_or(Value::Null);
        if method == "exit" {
            queue::shutdown();
            send(json!({ "id": id, "result": null }));
            break;
        }
        // 每个请求单独一个线程：搜索与下载耗时，不挡住取消等请求。
        std::thread::spawn(move || {
            let reply = match std::panic::catch_unwind(|| handle(&method, &params)) {
                Ok(Ok(result)) => json!({ "id": id, "result": result }),
                Ok(Err(error)) => json!({ "id": id, "error": error }),
                Err(_) => json!({ "id": id, "error": "插件内部错误" }),
            };
            send(reply);
        });
    }
}
