//! 引擎：一个书源 + 一个 JS 运行时 + 当前内容。每个下载线程各建一个；书源变量、缓存、
//! Cookie 与限速经 `SourceRt` 在线程间共享。
//!
//! 所有工作在 `Engine::run` 里进行（进入一次 JS 上下文），规则里的 JS 与 JS 回调里的规则
//! 共用这个上下文，可以互相嵌套。
use crate::{
    crypto,
    net::{self, Net, Rate, Request, Response},
    node::Node,
    rule::{self, Host},
    source::BookSource,
    text,
};
use rquickjs::{Context, Ctx, Function, Runtime, Value as JsValue};
use serde_json::{Value, json};
use std::{
    cell::{Cell, RefCell},
    collections::HashMap,
    rc::{Rc, Weak},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

const PRELUDE: &str = include_str!("prelude.js");
const JS_TIMEOUT: Duration = Duration::from_secs(if cfg!(test) { 2 } else { 20 });

/// 一个书源在各线程间共享的部分。
pub struct SourceRt {
    pub source: BookSource,
    pub net: Net,
    /// `source.put/get`。
    pub vars: Mutex<HashMap<String, String>>,
    /// `source.getVariable/setVariable`。
    pub variable: Mutex<String>,
    pub cache: Mutex<HashMap<String, String>>,
    /// 登录界面填写的信息（JSON 文字），只在内存里。
    pub login_info: Mutex<Option<String>>,
    pub flights: crate::singleflight::Flights,
    pub html_document: Mutex<Option<String>>,
}

impl SourceRt {
    pub fn new(source: BookSource) -> Arc<Self> {
        let rate = Rate::parse(&source.concurrent_rate);
        let headers = static_headers(&source.header);
        let mut net = Net::new(rate, headers);
        net.crawl = source.meta.crawl.clone();
        net.respond_time = source.respond_time;
        Arc::new(Self {
            net,
            source,
            vars: Mutex::default(),
            variable: Mutex::default(),
            cache: Mutex::default(),
            login_info: Mutex::default(),
            flights: Default::default(),
            html_document: Default::default(),
        })
    }
}

/// 书源请求头：JSON 对象（键值）；以 `@js:` / `<js>` 写的在引擎里再执行。
fn static_headers(header: &str) -> Vec<(String, String)> {
    let header = header.trim();
    if header.is_empty()
        || header.starts_with("@js:")
        || header.to_ascii_lowercase().starts_with("<js>")
    {
        return Vec::new();
    }
    parse_headers(header)
}
fn parse_headers(text: &str) -> Vec<(String, String)> {
    match serde_json::from_str::<Value>(text)
        .or_else(|_| serde_json::from_str::<Value>(&text.replace('\'', "\"")))
    {
        Ok(Value::Object(map)) => map
            .into_iter()
            .map(|(k, v)| (k, crate::jsonpath::value_text(&v)))
            .collect(),
        _ => Vec::new(),
    }
}

pub struct State {
    pub content: Node,
    pub base_url: String,
    pub redirect_url: String,
    pub vars: HashMap<String, String>,
    pub book: Value,
    pub chapter: Value,
    pub key: String,
    pub page: i64,
    pub title: String,
    pub src: String,
    pub next_chapter_url: String,
    pub logs: Vec<String>,
    pub batch_urls: std::collections::HashSet<String>,
    pub batch_content: HashMap<String, String>,
    native_error: Option<String>,
    objects_dirty: bool,
}
impl Default for State {
    fn default() -> Self {
        Self {
            content: Node::Text(String::new()),
            base_url: String::new(),
            redirect_url: String::new(),
            vars: HashMap::new(),
            book: json!({}),
            chapter: json!({}),
            key: String::new(),
            page: 1,
            title: String::new(),
            src: String::new(),
            next_chapter_url: String::new(),
            logs: Vec::new(),
            batch_urls: Default::default(),
            batch_content: Default::default(),
            native_error: None,
            objects_dirty: true,
        }
    }
}

pub struct Inner {
    pub rt: Arc<SourceRt>,
    pub st: RefCell<State>,
    deadline: Rc<Cell<Option<Instant>>>,
}

pub struct Engine {
    inner: Rc<Inner>,
    context: Context,
    _runtime: Runtime,
}

pub struct Scope<'a, 'js> {
    pub inner: &'a Inner,
    pub ctx: Ctx<'js>,
}

impl Engine {
    pub fn new(rt: Arc<SourceRt>) -> Result<Self, String> {
        let runtime = Runtime::new().map_err(|e| e.to_string())?;
        runtime.set_memory_limit(512 * 1024 * 1024);
        runtime.set_max_stack_size(8 * 1024 * 1024);
        let deadline: Rc<Cell<Option<Instant>>> = Rc::default();
        let watch = deadline.clone();
        runtime.set_interrupt_handler(Some(Box::new(move || {
            watch.get().is_some_and(|d| Instant::now() > d)
                || crate::control::current().check().is_err()
        })));
        let context = Context::full(&runtime).map_err(|e| e.to_string())?;
        let inner = Rc::new(Inner {
            rt,
            st: RefCell::default(),
            deadline,
        });
        let weak: Weak<Inner> = Rc::downgrade(&inner);
        context.with(|ctx| -> Result<(), String> {
            let native = Function::new(
                ctx.clone(),
                move |ctx: Ctx<'_>, op: String, args: String| -> String {
                    let Some(inner) = weak.upgrade() else {
                        return json!({"__error": "引擎已关闭"}).to_string();
                    };
                    let scope = Scope { inner: &inner, ctx };
                    let args: Vec<Value> = serde_json::from_str(&args).unwrap_or_default();
                    match scope.op(&op, &args) {
                        Ok(v) => json!({ "v": v }).to_string(),
                        Err(e) => {
                            scope.inner.st.borrow_mut().native_error =
                                Some(crate::probe::reason(&e).to_owned());
                            json!({ "__error": e }).to_string()
                        }
                    }
                },
            )
            .map_err(|e| e.to_string())?;
            ctx.globals()
                .set("__ep", native)
                .map_err(|e| e.to_string())?;
            sloppy::<()>(&ctx, PRELUDE).map_err(|e| js_error(&ctx, e))?;
            let source = serde_json::to_string(&inner.rt.source).unwrap_or_else(|_| "{}".into());
            sloppy::<()>(
                &ctx,
                format!("var source = __make_source({source}); var sourceApi = source;"),
            )
            .map_err(|e| js_error(&ctx, e))?;
            if !inner.rt.source.main_js.trim().is_empty() {
                inner.deadline.set(Some(Instant::now() + JS_TIMEOUT));
                let init = sloppy::<()>(&ctx, inner.rt.source.main_js.as_bytes().to_vec());
                inner.deadline.set(None);
                init.map_err(|e| {
                    let safe = js_error(&ctx, e);
                    inner.st.borrow_mut().native_error.take().unwrap_or(safe)
                })?;
            }
            Ok(())
        })?;
        let engine = Self {
            inner,
            context,
            _runtime: runtime,
        };
        engine.run(|s| s.load_js_lib());
        Ok(engine)
    }

    pub fn run<R>(&self, f: impl FnOnce(&Scope<'_, '_>) -> R) -> R {
        self.context.with(|ctx| {
            f(&Scope {
                inner: &self.inner,
                ctx,
            })
        })
    }

    pub fn state(&self) -> std::cell::RefMut<'_, State> {
        self.inner.st.borrow_mut()
    }
    pub fn source(&self) -> &BookSource {
        &self.inner.rt.source
    }
    pub fn take_logs(&self) -> Vec<String> {
        std::mem::take(&mut self.inner.st.borrow_mut().logs)
    }
}

/// 按非严格模式执行（与阅读用的 Rhino 一致：给未声明的变量赋值即建全局变量）。
fn sloppy<'js, V: rquickjs::FromJs<'js>>(
    ctx: &Ctx<'js>,
    code: impl Into<Vec<u8>>,
) -> rquickjs::Result<V> {
    let mut options = rquickjs::context::EvalOptions::default();
    options.strict = false;
    ctx.eval_with_options(code, options)
}

fn js_error(ctx: &Ctx<'_>, error: rquickjs::Error) -> String {
    if matches!(error, rquickjs::Error::Exception) {
        // 第三方脚本可以 throw Cookie 或登录表单，错误文本不能越过凭据边界。
        let _ = ctx.catch();
        return "书源 JS 执行失败".into();
    }
    error.to_string()
}

fn bytes_arg(v: &Value) -> Vec<u8> {
    match v {
        Value::Object(o) if o.contains_key("b") => o["b"]
            .as_array()
            .map(|a| a.iter().map(|n| n.as_i64().unwrap_or(0) as u8).collect())
            .unwrap_or_default(),
        Value::Object(o) => o
            .get("s")
            .and_then(Value::as_str)
            .unwrap_or("")
            .as_bytes()
            .to_vec(),
        Value::String(s) => s.as_bytes().to_vec(),
        Value::Array(a) => a.iter().map(|n| n.as_i64().unwrap_or(0) as u8).collect(),
        _ => Vec::new(),
    }
}
/// Java 的 byte 是有符号的。
fn bytes_value(b: &[u8]) -> Value {
    Value::Array(b.iter().map(|x| json!(*x as i8)).collect())
}
fn charset_decode(bytes: &[u8], charset: Option<&str>) -> String {
    let enc = charset
        .and_then(|c| encoding_rs::Encoding::for_label(c.trim().as_bytes()))
        .unwrap_or(encoding_rs::UTF_8);
    enc.decode(bytes).0.into_owned()
}
fn arg(args: &[Value], i: usize) -> &Value {
    args.get(i).unwrap_or(&Value::Null)
}
fn s(args: &[Value], i: usize) -> String {
    match arg(args, i) {
        Value::Null => String::new(),
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}
fn opt(args: &[Value], i: usize) -> Option<String> {
    arg(args, i)
        .as_str()
        .map(str::to_owned)
        .filter(|s| !s.is_empty())
}

pub fn response_json(r: &Response) -> Value {
    let headers: serde_json::Map<String, Value> = r
        .headers
        .iter()
        .map(|(k, v)| (k.to_ascii_lowercase(), Value::String(v.clone())))
        .collect();
    json!({ "body": r.text, "code": r.status, "url": r.url, "headers": headers })
}

/// 解析好的请求。
#[derive(Debug, Clone, Default)]
pub struct UrlSpec {
    pub request: Request,
    pub web_view: bool,
    pub web_js: String,
    pub kind: String,
}

impl Host for Scope<'_, '_> {
    fn js(&self, code: &str, input: &[Node]) -> Vec<Node> {
        match self.eval_js(code, input) {
            Ok(v) => v,
            Err(e) => {
                self.log(format!("JS 出错：{e}"));
                Vec::new()
            }
        }
    }
    fn var(&self, key: &str) -> String {
        let st = self.inner.st.borrow();
        if let Some(v) = st.vars.get(key) {
            return v.clone();
        }
        drop(st);
        self.inner
            .rt
            .vars
            .lock()
            .unwrap()
            .get(key)
            .cloned()
            .unwrap_or_default()
    }
    fn put_var(&self, key: &str, value: String) {
        self.inner
            .st
            .borrow_mut()
            .vars
            .insert(key.to_owned(), value);
    }
}

impl<'js> Scope<'_, 'js> {
    pub fn log(&self, msg: impl Into<String>) {
        let mut st = self.inner.st.borrow_mut();
        if st.logs.len() < 500 {
            let _ = msg.into();
            // 第三方 JS 能读取 Cookie，不能把其任意日志文字向界面或文件转发。
            st.logs.push("书源执行了操作".into());
        }
    }
    pub fn source(&self) -> &BookSource {
        &self.inner.rt.source
    }
    pub fn net(&self) -> &Net {
        &self.inner.rt.net
    }

    fn load_js_lib(&self) {
        let lib = self.source().js_lib.trim().to_owned();
        if lib.is_empty() {
            return;
        }
        // `{"名称":"网址"}` 形式：逐个下载后执行；否则整段是 JS。
        let code = match serde_json::from_str::<Value>(&lib) {
            Ok(Value::Object(map)) => map
                .values()
                .filter_map(Value::as_str)
                .filter_map(|url| self.fetch_plain(url).ok().map(|r| r.text))
                .collect::<Vec<_>>()
                .join("\n;\n"),
            _ => lib,
        };
        self.inner.deadline.set(Some(Instant::now() + JS_TIMEOUT));
        let result = sloppy::<()>(&self.ctx, code);
        self.inner.deadline.set(None);
        if let Err(e) = result {
            let msg = js_error(&self.ctx, e);
            self.log(format!("jsLib 出错：{msg}"));
        }
    }

    // ---------- JS ----------

    fn to_js(&self, node: &Node) -> JsValue<'js> {
        let ctx = &self.ctx;
        match node {
            Node::Json(v) => ctx
                .json_parse(v.to_string())
                .unwrap_or_else(|_| JsValue::new_undefined(ctx.clone())),
            // 页面里的元素：给脚本 org.jsoup 风格的元素对象（String(元素) 仍是 HTML）。
            Node::Elem(..) => {
                let make: Option<Function> = ctx.globals().get("__make_element").ok();
                match make.and_then(|f| f.call::<_, JsValue>((node.text(),)).ok()) {
                    Some(v) => v,
                    None => JsValue::new_undefined(ctx.clone()),
                }
            }
            Node::Groups(g) => ctx
                .json_parse(serde_json::to_string(&**g).unwrap_or_default())
                .unwrap_or_else(|_| JsValue::new_undefined(ctx.clone())),
            other => rquickjs::String::from_str(ctx.clone(), &other.text())
                .map(|s| s.into_value())
                .unwrap_or_else(|_| JsValue::new_undefined(ctx.clone())),
        }
    }

    fn js_to_nodes(&self, v: JsValue<'js>) -> Vec<Node> {
        if v.is_undefined() || v.is_null() {
            return Vec::new();
        }
        if let Some(s) = v.as_string() {
            return vec![Node::Text(s.to_string().unwrap_or_default())];
        }
        let text = self
            .ctx
            .json_stringify(v)
            .ok()
            .flatten()
            .and_then(|s| s.to_string().ok())
            .unwrap_or_default();
        let value: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
        fn one(v: Value) -> Option<Node> {
            match v {
                Value::Null => None,
                Value::String(s) => Some(Node::Text(s)),
                Value::Bool(_) | Value::Number(_) => Some(Node::Text(v.to_string())),
                other => Some(Node::Json(other)),
            }
        }
        match value {
            Value::Array(items) => items.into_iter().filter_map(one).collect(),
            other => one(other).into_iter().collect(),
        }
    }

    fn set_globals(&self, input: &[Node], code: &str) -> Result<(), String> {
        let g = self.ctx.globals();
        let result = match input {
            [one] => self.to_js(one),
            many if !many.is_empty() && many.iter().all(|n| matches!(n, Node::Elem(..))) => {
                // 元素列表：org.jsoup 的 Elements 风格（toArray、size、get…）。
                let make: Function = self
                    .ctx
                    .globals()
                    .get("__make_elements")
                    .map_err(|e| e.to_string())?;
                let htmls: Vec<String> = many.iter().map(Node::text).collect();
                make.call::<_, JsValue>((htmls,))
                    .map_err(|e| js_error(&self.ctx, e))?
            }
            many => {
                let arr = rquickjs::Array::new(self.ctx.clone()).map_err(|e| e.to_string())?;
                for (i, n) in many.iter().enumerate() {
                    arr.set(i, self.to_js(n)).map_err(|e| e.to_string())?;
                }
                arr.into_value()
            }
        };
        g.set("result", result).map_err(|e| e.to_string())?;
        let (base, key, page, title, src, next, dirty, book, chapter) = {
            let st = self.inner.st.borrow();
            (
                if st.redirect_url.is_empty() {
                    st.base_url.clone()
                } else {
                    st.redirect_url.clone()
                },
                st.key.clone(),
                st.page,
                st.title.clone(),
                st.src.clone(),
                st.next_chapter_url.clone(),
                st.objects_dirty,
                st.book.to_string(),
                st.chapter.to_string(),
            )
        };
        let base = if base.is_empty() {
            self.source().base_url().to_owned()
        } else {
            base
        };
        g.set("baseUrl", base).map_err(|e| e.to_string())?;
        g.set("key", key).map_err(|e| e.to_string())?;
        g.set("page", page).map_err(|e| e.to_string())?;
        g.set("title", title).map_err(|e| e.to_string())?;
        // src：当前页面原文（只在脚本用到时取，避免每次复制大页面）。
        let src = if src.is_empty() && code.contains("src") {
            self.inner.st.borrow().content.text()
        } else {
            src
        };
        g.set("src", src).map_err(|e| e.to_string())?;
        g.set("nextChapterUrl", next).map_err(|e| e.to_string())?;
        if dirty {
            sloppy::<()>(
                &self.ctx,
                format!("var book = __make_book({book}); var chapter = __make_chapter({chapter});"),
            )
            .map_err(|e| js_error(&self.ctx, e))?;
            self.inner.st.borrow_mut().objects_dirty = false;
        }
        Ok(())
    }

    pub fn eval_js(&self, code: &str, input: &[Node]) -> Result<Vec<Node>, String> {
        self.set_globals(input, code)?;
        let run: Function = self.ctx.globals().get("__run").map_err(|e| e.to_string())?;
        // 嵌套调用时只由最外层设置期限。
        let outer = self.inner.deadline.get().is_none();
        if outer {
            self.inner.st.borrow_mut().native_error = None;
            let network_budget = if crate::hosts::local(self.source().base_url()) {
                Duration::from_millis(self.source().respond_time.clamp(0, 180000) as u64)
            } else {
                Duration::ZERO
            };
            self.inner
                .deadline
                .set(Some(Instant::now() + JS_TIMEOUT + network_budget));
        }
        let out = run.call::<_, JsValue>((code,));
        if outer {
            self.inner.deadline.set(None);
        }
        match out {
            Ok(v) => Ok(self.js_to_nodes(v)),
            Err(e) => {
                let msg = js_error(&self.ctx, e);
                if let Some(native) = self.inner.st.borrow_mut().native_error.take() {
                    return Err(native);
                }
                crate::control::current().check()?;
                Err(if msg.contains("interrupted") {
                    "JS 运行超时".into()
                } else {
                    msg
                })
            }
        }
    }

    pub fn eval_js_string(&self, code: &str, input: &[Node]) -> Result<String, String> {
        Ok(self
            .eval_js(code, input)?
            .iter()
            .map(Node::text)
            .collect::<Vec<_>>()
            .join("\n"))
    }

    pub fn main_call(&self, name: &str, arguments: Value) -> Result<Value, String> {
        let code = format!(
            "JSON.stringify((typeof {name} === 'function' ? {name}.apply(null,{arguments}) : null) ?? null)"
        );
        let text = self.eval_js_string(&code, &[])?;
        serde_json::from_str(&text).map_err(|_| "单文件 JS 返回值不是有效数据".into())
    }

    /// 改了 book / chapter 后，下次执行 JS 前重建这两个对象。
    pub fn set_book(&self, book: Value) {
        let mut st = self.inner.st.borrow_mut();
        st.book = book;
        st.objects_dirty = true;
    }
    pub fn set_chapter(&self, chapter: Value) {
        let mut st = self.inner.st.borrow_mut();
        st.title = chapter
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned();
        st.chapter = chapter;
        st.objects_dirty = true;
    }

    // ---------- 规则 ----------

    pub fn content(&self) -> Node {
        self.inner.st.borrow().content.clone()
    }
    pub fn set_content(&self, node: Node, base: Option<&str>) {
        let mut st = self.inner.st.borrow_mut();
        st.content = node;
        if let Some(b) = base {
            st.base_url = b.to_owned();
            st.redirect_url = b.to_owned();
        }
    }
    pub fn get_string(&self, rule: &str) -> String {
        rule::string(self, rule, &self.content())
    }
    /// 在某项（列表里的一本书、一章）上执行规则：期间 java.getString 等也以它为当前内容。
    fn on<R>(&self, node: &Node, f: impl FnOnce() -> R) -> R {
        let old = std::mem::replace(&mut self.inner.st.borrow_mut().content, node.clone());
        let result = f();
        self.inner.st.borrow_mut().content = old;
        result
    }
    pub fn get_string_on(&self, rule: &str, node: &Node) -> String {
        self.on(node, || rule::string(self, rule, node))
    }
    pub fn get_strings_on(&self, rule: &str, node: &Node) -> Vec<String> {
        self.on(node, || rule::strings(self, rule, node))
    }
    pub fn get_elements(&self, rule: &str) -> Vec<Node> {
        rule::elements(self, rule, &self.content())
    }

    /// 相对网址按当前页面（重定向后的地址）补全。
    pub fn absolute(&self, url: &str) -> String {
        let url = url.trim();
        // 带选项的网址（`地址,{"webView":true}`）：只补全地址部分，选项原样保留。
        if let (head, Some(_)) = split_options(url) {
            return format!("{}{}", self.absolute(head), &url[head.len()..]);
        }
        if url.is_empty() || url.starts_with("data:") || url.contains("://") {
            return url.to_owned();
        }
        let base = {
            let st = self.inner.st.borrow();
            if !st.redirect_url.is_empty() {
                st.redirect_url.clone()
            } else {
                st.base_url.clone()
            }
        };
        absolute(
            if base.is_empty() {
                self.source().base_url()
            } else {
                &base
            },
            url,
        )
    }

    // ---------- 网址 ----------

    /// 按阅读的网址规则得到请求：JS 段、`<页1,页2>`、`{{}}`、`网址,{选项}`。
    pub fn analyze_url(&self, rule: &str) -> Result<UrlSpec, String> {
        let mut text = self.url_js(rule.trim())?;
        let (key, page) = {
            let st = self.inner.st.borrow();
            (st.key.clone(), st.page)
        };
        // <a,b,c>：按页码取一项，页码超出取最后一项。
        let page_list = regex::Regex::new(r"<([^<>]*,[^<>]*)>").unwrap();
        if let Some(c) = page_list.captures(&text) {
            let items: Vec<&str> = c[1].split(',').collect();
            let pick = items
                .get((page.max(1) - 1) as usize)
                .or(items.last())
                .copied()
                .unwrap_or("");
            text = text.replacen(&c[0], pick.trim(), 1);
        }
        // {{key}} {{page}} 与 JS 模板
        if text.contains("{{") {
            let mut out = String::new();
            let mut rest = text.as_str();
            while let Some(start) = rest.find("{{") {
                let Some(end) = rest[start + 2..].find("}}") else {
                    break;
                };
                out.push_str(&rest[..start]);
                let inner = rest[start + 2..start + 2 + end].trim();
                let value = match inner {
                    "key" => key.clone(),
                    "page" => page.to_string(),
                    js => self.eval_js_string(js, &[Node::Text(String::new())])?,
                };
                out.push_str(&value);
                rest = &rest[start + 2 + end + 2..];
            }
            out.push_str(rest);
            text = out;
        }
        let (url, options) = split_options(&text);
        let mut url = url.trim().to_owned();
        let mut option_js = None;
        let mut spec = UrlSpec::default();
        let mut headers: Vec<(String, String)> = self.source_headers();
        let mut method = "GET".to_owned();
        let mut body = None;
        let mut charset = None;
        if let Some(Value::Object(o)) = &options {
            let get = |k: &str| {
                o.iter()
                    .find(|(name, _)| name.eq_ignore_ascii_case(k))
                    .map(|(_, v)| v)
            };
            if let Some(m) = get("method").and_then(Value::as_str) {
                method = m.to_ascii_uppercase();
            }
            charset = get("charset")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .filter(|c| !c.trim().is_empty());
            body = match get("body") {
                Some(Value::String(b)) => Some(b.clone()),
                Some(Value::Null) | None => None,
                Some(other) => Some(other.to_string()),
            };
            match get("headers") {
                Some(Value::Object(h)) => headers.extend(
                    h.iter()
                        .map(|(k, v)| (k.clone(), crate::jsonpath::value_text(v))),
                ),
                Some(Value::String(h)) => headers.extend(parse_headers(h)),
                _ => (),
            }
            spec.request.retry = get("retry").and_then(Value::as_u64).unwrap_or(0) as u32;
            spec.web_view = get("webView").is_some_and(|v| {
                !matches!(v, Value::Null | Value::Bool(false)) && v.as_str() != Some("")
            });
            spec.web_js = get("webJs")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned();
            spec.kind = get("type").and_then(Value::as_str).unwrap_or("").to_owned();
            spec.request.proxy = get("proxy").map(crate::jsonpath::value_text);
            spec.request.insecure = get("insecure") == Some(&Value::Bool(true));
            option_js = get("js")
                .and_then(Value::as_str)
                .filter(|j| !j.trim().is_empty())
                .map(str::to_owned);
        }
        // 搜索词等查询参数先按网站编码做百分号编码（已编码的不动），再补全成绝对网址。
        url = self.absolute(&encode_query(&url, charset.as_deref()));
        if let Some(js) = option_js {
            let (u, h) = self.url_option_js(&js, &url, &headers)?;
            url = u;
            headers = h;
        }
        if let Some(b) = &body
            && method == "POST"
        {
            let looks_json = b.trim_start().starts_with('{') || b.trim_start().starts_with('[');
            body = Some(if looks_json {
                b.clone()
            } else {
                encode_form(b, charset.as_deref())
            });
        }
        spec.request.url = url;
        spec.request.method = method;
        spec.request.body = body.map(|b| {
            match charset
                .as_deref()
                .and_then(|c| encoding_rs::Encoding::for_label(c.as_bytes()))
            {
                Some(enc) if !b.trim_start().starts_with('{') => enc.encode(&b).0.into_owned(),
                _ => b.into_bytes(),
            }
        });
        spec.request.headers = headers;
        spec.request.charset = charset;
        Ok(spec)
    }

    /// 网址规则里的 `<js>` / `@js:` 段：段前文字作为 result，`@result` 换成上一段结果。
    fn url_js(&self, rule: &str) -> Result<String, String> {
        let lower = rule.to_ascii_lowercase();
        if !lower.contains("<js>") && !lower.starts_with("@js:") {
            return Ok(rule.to_owned());
        }
        let mut result = String::new();
        let mut rest = rule;
        loop {
            let lower = rest.to_ascii_lowercase();
            let tag = lower.find("<js>");
            let at = lower.find("@js:");
            let (start, code, next): (usize, String, &str) = match (tag, at) {
                (Some(t), a) if a.is_none_or(|a| t < a) => {
                    let body = &rest[t + 4..];
                    let end = body
                        .to_ascii_lowercase()
                        .find("</js>")
                        .unwrap_or(body.len());
                    (t, body[..end].to_owned(), body.get(end + 5..).unwrap_or(""))
                }
                (_, Some(a)) => (a, rest[a + 4..].to_owned(), ""),
                _ => {
                    if !rest.trim().is_empty() {
                        result = rest.trim().replace("@result", &result);
                    }
                    break;
                }
            };
            let before = rest[..start].trim();
            if !before.is_empty() {
                result = before.replace("@result", &result);
            }
            result = self.eval_js_string(&code, &[Node::Text(result.clone())])?;
            rest = next;
            if rest.is_empty() {
                break;
            }
        }
        Ok(result)
    }

    fn url_option_js(
        &self,
        js: &str,
        url: &str,
        headers: &[(String, String)],
    ) -> Result<(String, Vec<(String, String)>), String> {
        let header_json =
            serde_json::to_string(&headers.iter().cloned().collect::<HashMap<_, _>>())
                .unwrap_or_default();
        sloppy::<()>(
            &self.ctx,
            format!(
                "java.url = {}; (function(m){{ for (var k in java.headerMap) delete java.headerMap[k]; for (var k in m) java.headerMap[k] = m[k]; }})({header_json});",
                serde_json::to_string(url).unwrap_or_default()
            ))
            .map_err(|e| js_error(&self.ctx, e))?;
        let out = self.eval_js_string(js, &[Node::Text(url.to_owned())])?;
        let new_url: String =
            sloppy(&self.ctx, "String(java.url)").map_err(|e| js_error(&self.ctx, e))?;
        let headers_text: String = sloppy(&self.ctx, "JSON.stringify(java.headerMap)")
            .map_err(|e| js_error(&self.ctx, e))?;
        let url = if new_url != url {
            new_url
        } else if out.starts_with("http") {
            out
        } else {
            url.to_owned()
        };
        Ok((self.absolute(&url), parse_headers(&headers_text)))
    }

    /// 书源请求头（JS 写的在这里执行）。
    pub fn source_headers(&self) -> Vec<(String, String)> {
        let header = self.source().header.trim().to_owned();
        if header.starts_with("@js:") || header.to_ascii_lowercase().starts_with("<js>") {
            let code = header
                .strip_prefix("@js:")
                .map(str::to_owned)
                .unwrap_or_else(|| {
                    header[4..]
                        .to_ascii_lowercase()
                        .find("</js>")
                        .map_or(header[4..].to_owned(), |e| header[4..4 + e].to_owned())
                });
            return match self.eval_js_string(&code, &[Node::Text(String::new())]) {
                Ok(text) => parse_headers(&text),
                Err(e) => {
                    self.log(format!("请求头 JS 出错：{e}"));
                    Vec::new()
                }
            };
        }
        Vec::new() // 静态请求头在 Net 里统一加上
    }

    /// 按网址规则请求，成功后把页面设为当前内容。
    pub fn fetch(&self, rule: &str) -> Result<Response, String> {
        crate::control::current().check()?;
        let spec = self.analyze_url(rule)?;
        self.log(format!("请求 {} {}", spec.request.method, spec.request.url));
        let response = self.fetch_spec(&spec)?;
        if response.status >= 400 {
            return Err(format!("网站返回 {}", response.status));
        }
        if crate::webview::is_challenge_response(&response) {
            return Err("需要网页验证".into());
        }
        self.set_content(Node::page(response.text.clone()), Some(&response.url));
        self.inner.st.borrow_mut().base_url = spec.request.url.clone();
        Ok(response)
    }

    pub fn fetch_spec(&self, spec: &UrlSpec) -> Result<Response, String> {
        if spec.web_view {
            return crate::webview::load(self, &spec.request, &spec.web_js);
        }
        let response = self.net().fetch(&spec.request).map_err(|e| e.0)?;
        // 普通请求被人机验证拦下：打开验证窗口让用户完成，拿到 Cookie 后重试。
        if crate::webview::supported()
            && crate::control::current().interactive
            && spec.request.method.eq_ignore_ascii_case("GET")
            && crate::webview::is_challenge_response(&response)
        {
            self.log("网站要求人机验证，已打开验证窗口");
            let out = crate::webview::execute_with(
                self,
                &spec.request.url,
                None,
                None,
                Some(&spec.request),
                crate::webview::Interactive::OnChallenge,
                format!(
                    "EasyPub：{} 要求人机验证，请在此完成，完成后会自动继续",
                    self.source().book_source_name.trim()
                ),
            )?;
            let retry = self.net().fetch(&spec.request).map_err(|e| e.0)?;
            if !crate::webview::is_challenge_response(&retry) {
                return Ok(retry);
            }
            return Ok(Response {
                url: out.url,
                status: 200,
                headers: Vec::new(),
                body: out.text.clone().into_bytes(),
                text: out.text,
                ..Default::default()
            });
        }
        Ok(response)
    }

    fn fetch_plain(&self, url: &str) -> Result<Response, String> {
        let request = Request {
            url: self.absolute(url),
            method: "GET".into(),
            ..Default::default()
        };
        self.net().fetch(&request).map_err(|e| e.0)
    }

    // ---------- JS 本机操作 ----------

    fn op(&self, op: &str, args: &[Value]) -> Result<Value, String> {
        let st = &self.inner.st;
        Ok(match op {
            "cacheContent" => {
                let target = arg(args, 0);
                let url = target
                    .as_str()
                    .or_else(|| target["url"].as_str())
                    .or_else(|| target["chapterUrl"].as_str())
                    .unwrap_or("");
                let mut state = st.borrow_mut();
                if !state.batch_urls.contains(url) {
                    return Err("批量正文只能回存本批唯一章节网址".into());
                }
                if state.batch_content.contains_key(url) {
                    return Err("批量正文重复回存".into());
                }
                state.batch_content.insert(url.to_owned(), s(args, 1));
                Value::Null
            }
            "log" => {
                self.log(s(args, 0));
                Value::Null
            }
            "varPut" => {
                st.borrow_mut().vars.insert(s(args, 0), s(args, 1));
                Value::Null
            }
            "varGet" => Value::String(self.var(&s(args, 0))),
            "sourcePut" => {
                self.inner
                    .rt
                    .vars
                    .lock()
                    .unwrap()
                    .insert(s(args, 0), s(args, 1));
                Value::Null
            }
            "sourceGet" => Value::String(
                self.inner
                    .rt
                    .vars
                    .lock()
                    .unwrap()
                    .get(&s(args, 0))
                    .cloned()
                    .unwrap_or_default(),
            ),
            "objVarGet" | "objVarPut" => {
                return self.obj_var(op == "objVarPut", &s(args, 0), opt(args, 1), s(args, 2));
            }
            "loginInfo" => self
                .inner
                .rt
                .login_info
                .lock()
                .unwrap()
                .clone()
                .map(Value::String)
                .unwrap_or(Value::Null),
            "sourceHeaders" => {
                let mut map = serde_json::Map::new();
                for (k, v) in self
                    .net()
                    .headers
                    .iter()
                    .cloned()
                    .chain(self.source_headers())
                {
                    map.insert(k, Value::String(v));
                }
                Value::Object(map)
            }
            "ajax" => {
                let mut rule = s(args, 0);
                if let Some(h) = opt(args, 1) {
                    rule = format!("{rule},{{\"headers\":{h}}}");
                }
                match self
                    .analyze_url(&rule)
                    .and_then(|spec| self.fetch_spec(&spec))
                {
                    Ok(r) => response_json(&r),
                    Err(e) => {
                        self.log(format!("ajax 失败：{e}"));
                        json!({ "body": e, "code": 500, "url": rule, "headers": {} })
                    }
                }
            }
            "ajaxAll" => Value::Array(
                arg(args, 0)
                    .as_array()
                    .cloned()
                    .unwrap_or_default()
                    .iter()
                    .map(|u| {
                        let rule = crate::jsonpath::value_text(u);
                        match self
                            .analyze_url(&rule)
                            .and_then(|spec| self.fetch_spec(&spec))
                        {
                            Ok(r) => response_json(&r),
                            Err(e) => json!({ "body": e, "code": 500, "url": rule, "headers": {} }),
                        }
                    })
                    .collect(),
            ),
            "http" => {
                let headers = match arg(args, 3) {
                    Value::Object(m) => m
                        .iter()
                        .map(|(k, v)| (k.clone(), crate::jsonpath::value_text(v)))
                        .collect(),
                    _ => Vec::new(),
                };
                let request = Request {
                    url: self.absolute(&s(args, 1)),
                    method: s(args, 0),
                    body: opt(args, 2).map(String::into_bytes),
                    headers,
                    ..Default::default()
                };
                response_json(&self.net().fetch_no_redirect(&request).map_err(|e| e.0)?)
            }
            "getString" | "getStringList" => {
                let rule = s(args, 0);
                let node = opt(args, 1)
                    .map(Node::page)
                    .unwrap_or_else(|| self.content());
                let mut values = rule::strings(self, &rule, &node);
                if arg(args, 2).as_bool() == Some(true) {
                    values = values.iter().map(|u| self.absolute(u)).collect();
                }
                if op == "getString" {
                    Value::String(values.join("\n"))
                } else {
                    Value::Array(values.into_iter().map(Value::String).collect())
                }
            }
            "getElements" => Value::Array(
                self.get_elements(&s(args, 0))
                    .into_iter()
                    .map(|n| match n {
                        Node::Json(v) => v,
                        other => Value::String(other.text()),
                    })
                    .collect(),
            ),
            "setContent" => {
                let base = opt(args, 1);
                self.set_content(Node::page(s(args, 0)), base.as_deref());
                Value::Null
            }
            "encodeURI" => {
                Value::String(net::encode_component(&s(args, 0), opt(args, 1).as_deref()))
            }
            "decodeURI" => {
                let bytes: Vec<u8> =
                    percent_encoding::percent_decode_str(&s(args, 0).replace('+', " ")).collect();
                Value::String(charset_decode(&bytes, opt(args, 1).as_deref()))
            }
            "base64Encode" => Value::String(crypto::b64(&bytes_arg(arg(args, 0)))),
            "base64Decode" => {
                let bytes = crypto::unb64(&s(args, 0)).unwrap_or_default();
                Value::String(charset_decode(&bytes, opt(args, 1).as_deref()))
            }
            "base64DecodeBytes" => bytes_value(&crypto::unb64(&s(args, 0)).unwrap_or_default()),
            "hexDecode" => {
                let bytes = hex::decode(s(args, 0).trim()).map_err(|_| "不是十六进制")?;
                if s(args, 1) == "bytes" {
                    bytes_value(&bytes)
                } else {
                    Value::String(String::from_utf8_lossy(&bytes).into_owned())
                }
            }
            "hexEncode" => Value::String(hex::encode(bytes_arg(arg(args, 0)))),
            "strToBytes" => {
                let text = s(args, 0);
                let enc = opt(args, 1)
                    .and_then(|c| encoding_rs::Encoding::for_label(c.as_bytes()))
                    .unwrap_or(encoding_rs::UTF_8);
                bytes_value(&enc.encode(&text).0)
            }
            "bytesToStr" => Value::String(charset_decode(
                &bytes_arg(arg(args, 0)),
                opt(args, 1).as_deref(),
            )),
            "digest" => {
                let hexed = hex::encode(crypto::digest(&bytes_arg(arg(args, 0)), &s(args, 1))?);
                Value::String(if arg(args, 2).as_i64() == Some(16) {
                    hexed[8..24].to_owned()
                } else {
                    hexed
                })
            }
            "digestBase64" => Value::String(crypto::b64(&crypto::digest(
                &bytes_arg(arg(args, 0)),
                &s(args, 1),
            )?)),
            "hmac" => {
                let mac = crypto::hmac(
                    &bytes_arg(arg(args, 0)),
                    &s(args, 1),
                    &bytes_arg(arg(args, 2)),
                )?;
                Value::String(if s(args, 3) == "base64" {
                    crypto::b64(&mac)
                } else {
                    hex::encode(mac)
                })
            }
            "crypto" => {
                let spec = arg(args, 0);
                let encrypt = s(args, 1) == "encrypt";
                let key = bytes_arg(&spec["key"]);
                let iv = (!spec["iv"].is_null()).then(|| bytes_arg(&spec["iv"]));
                let data = match arg(args, 2) {
                    Value::Object(o) if o.contains_key("s") && !encrypt => {
                        crypto::decode_input(o["s"].as_str().unwrap_or(""))
                            .ok_or("密文不是 Base64 或十六进制")?
                    }
                    other => bytes_arg(other),
                };
                let out = crypto::symmetric(
                    spec["t"].as_str().unwrap_or(""),
                    &key,
                    iv.as_deref(),
                    encrypt,
                    &data,
                )?;
                match s(args, 3).as_str() {
                    "utf8" => Value::String(String::from_utf8_lossy(&out).into_owned()),
                    "base64" => Value::String(crypto::b64(&out)),
                    "hex" => Value::String(hex::encode(out)),
                    _ => bytes_value(&out),
                }
            }
            "timeFormat" => Value::String(text::time_format(
                arg(args, 0).as_f64().unwrap_or(0.0) as i64,
                &s(args, 1),
                arg(args, 2).as_i64().unwrap_or(8),
            )),
            "t2s" => Value::String(zhconv::zhconv(&s(args, 0), zhconv::Variant::ZhHans)),
            "s2t" => Value::String(zhconv::zhconv(&s(args, 0), zhconv::Variant::ZhHant)),
            "toNumChapter" => Value::String(text::to_num_chapter(&s(args, 0))),
            "htmlFormat" => Value::String(text::html_to_text(&s(args, 0))),
            "uuid" => Value::String(uuid()),
            "userAgent" => Value::String(net::DEFAULT_UA.into()),
            "cookieGet" => {
                let url =
                    reqwest::Url::parse(&self.absolute(&s(args, 0))).map_err(|_| "网址无效")?;
                Value::String(self.net().cookie_header(&url))
            }
            "cookieKey" => {
                let url =
                    reqwest::Url::parse(&self.absolute(&s(args, 0))).map_err(|_| "网址无效")?;
                let key = s(args, 1);
                let all = self.net().cookie_header(&url);
                Value::String(
                    all.split("; ")
                        .find_map(|p| {
                            p.split_once('=')
                                .filter(|(k, _)| *k == key)
                                .map(|(_, v)| v.to_owned())
                        })
                        .unwrap_or_default(),
                )
            }
            "cookieSet" => {
                self.net()
                    .set_cookie(&self.absolute(&s(args, 0)), &s(args, 1));
                Value::Null
            }
            "cookieRemove" => {
                self.net().remove_cookies(&self.absolute(&s(args, 0)));
                Value::Null
            }
            "cacheGet" => self
                .inner
                .rt
                .cache
                .lock()
                .unwrap()
                .get(&s(args, 0))
                .cloned()
                .map(Value::String)
                .unwrap_or(Value::Null),
            "cachePut" => {
                let mut cache = self.inner.rt.cache.lock().unwrap();
                match arg(args, 1) {
                    Value::Null => cache.remove(&s(args, 0)),
                    _ => cache.insert(s(args, 0), s(args, 1)),
                };
                Value::Null
            }
            "importScript" => {
                let path = s(args, 0);
                if !path.starts_with("http") {
                    return Err("只支持从网址导入脚本".into());
                }
                Value::String(self.fetch_plain(&path)?.text)
            }
            "browser" => {
                // java.startBrowser / startBrowserAwait：显示网页让用户操作，关窗口后返回当前页面。
                let url = self.absolute(&s(args, 0));
                let title = opt(args, 1).unwrap_or_else(|| "请在网页中完成操作".into());
                let out = crate::webview::execute_with(
                    self,
                    &url,
                    None,
                    None,
                    None,
                    crate::webview::Interactive::Always,
                    format!("EasyPub：{title}（完成后关闭窗口）"),
                )?;
                json!({ "body": out.text, "code": 200, "url": out.url, "headers": {} })
            }
            "verificationCode" => {
                // java.getVerificationCode(图片网址)：显示图片，用户输入后关闭窗口。
                let url = self.absolute(&s(args, 0));
                let html = format!(
                    "<meta charset=utf-8><body style='font:16px sans-serif;padding:24px'><p>请输入图片里的验证码，然后关闭窗口：</p><img src=\"{}\" style='max-width:90%'><p><input id=c autofocus style='font-size:20px'></p></body>",
                    url.replace('"', "%22")
                );
                let out = crate::webview::execute_with(
                    self,
                    &url,
                    Some(html),
                    Some("document.getElementById('c').value".into()),
                    None,
                    crate::webview::Interactive::Always,
                    "EasyPub：输入验证码后关闭窗口".into(),
                )?;
                Value::String(out.text.trim().to_owned())
            }
            "webView" => Value::String(crate::webview::run(
                self,
                opt(args, 0),
                opt(args, 1),
                opt(args, 2),
            )?),
            "absolute" => Value::String(self.absolute(&s(args, 0))),
            "jsoupSelect" => {
                let (doc, root) = jsoup_root(&s(args, 0));
                let css = s(args, 1);
                let found: Vec<Value> = if css.trim() == ":scope > *" {
                    doc.tree
                        .get(root)
                        .map(|n| {
                            n.children()
                                .filter_map(scraper::ElementRef::wrap)
                                .map(|e| Value::String(e.html()))
                                .collect()
                        })
                        .unwrap_or_default()
                } else {
                    crate::jcss::select_css(&doc, root, &css)?
                        .into_iter()
                        .filter_map(|id| doc.tree.get(id).and_then(scraper::ElementRef::wrap))
                        .map(|e| Value::String(e.html()))
                        .collect()
                };
                Value::Array(found)
            }
            "jsoupValue" => {
                let (doc, root) = jsoup_root(&s(args, 0));
                let kind = s(args, 1);
                let Some(node) = doc.tree.get(root) else {
                    return Ok(Value::String(String::new()));
                };
                let element = scraper::ElementRef::wrap(node);
                Value::String(match kind.as_str() {
                    "text" => crate::dom::text(node),
                    "ownText" => crate::dom::own_text(node),
                    "inner" => element.map(|e| e.inner_html()).unwrap_or_default(),
                    "tag" => element
                        .map(|e| e.value().name().to_owned())
                        .unwrap_or_default(),
                    k if k.starts_with("attr:") => element
                        .and_then(|e| e.attr(&k[5..]))
                        .unwrap_or("")
                        .to_owned(),
                    k if k.starts_with("has:") => element
                        .is_some_and(|e| e.attr(&k[4..]).is_some())
                        .to_string(),
                    _ => String::new(),
                })
            }
            "jsoupRemove" => {
                let html = s(args, 0);
                let css = s(args, 1);
                let full = html
                    .trim_start()
                    .to_ascii_lowercase()
                    .starts_with("<!doctype")
                    || html.trim_start().to_ascii_lowercase().starts_with("<html");
                let mut doc = if full {
                    scraper::Html::parse_document(&html)
                } else {
                    scraper::Html::parse_fragment(&html)
                };
                let doc_root = doc.tree.root().id();
                let ids = crate::jcss::select_css(&doc, doc_root, &css)?;
                for id in ids {
                    if let Some(mut n) = doc.tree.get_mut(id) {
                        n.detach();
                    }
                }
                Value::String(if full {
                    doc.root_element().html()
                } else {
                    doc.root_element().inner_html()
                })
            }
            other => return Err(format!("不支持 {other}")),
        })
    }

    fn obj_var(
        &self,
        put: bool,
        kind: &str,
        key: Option<String>,
        value: String,
    ) -> Result<Value, String> {
        match kind {
            "source" => {
                if put {
                    match key {
                        Some(k) => {
                            self.inner.rt.vars.lock().unwrap().insert(k, value);
                        }
                        None => *self.inner.rt.variable.lock().unwrap() = value,
                    }
                    return Ok(Value::Null);
                }
                Ok(Value::String(match key {
                    Some(k) => self
                        .inner
                        .rt
                        .vars
                        .lock()
                        .unwrap()
                        .get(&k)
                        .cloned()
                        .unwrap_or_default(),
                    None => self.inner.rt.variable.lock().unwrap().clone(),
                }))
            }
            "book" | "chapter" => {
                let mut st = self.inner.st.borrow_mut();
                let obj = if kind == "book" {
                    &mut st.book
                } else {
                    &mut st.chapter
                };
                if !obj.is_object() {
                    *obj = json!({});
                }
                let vars = obj
                    .as_object_mut()
                    .unwrap()
                    .entry("variables")
                    .or_insert_with(|| json!({}));
                if put {
                    vars[key.unwrap_or_else(|| "custom".into())] = Value::String(value);
                    st.objects_dirty = true;
                    return Ok(Value::Null);
                }
                Ok(match key {
                    Some(k) => vars
                        .get(&k)
                        .cloned()
                        .unwrap_or(Value::String(String::new())),
                    None => Value::String(vars.to_string()),
                })
            }
            _ => Err("未知对象".into()),
        }
    }
}

fn uuid() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let seed = format!(
        "{nanos}-{}-{}",
        COUNTER.fetch_add(1, Ordering::Relaxed),
        std::process::id()
    );
    let h = hex::encode(crypto::digest(seed.as_bytes(), "SHA256").unwrap_or_default());
    format!(
        "{}-{}-4{}-a{}-{}",
        &h[0..8],
        &h[8..12],
        &h[13..16],
        &h[17..20],
        &h[20..32]
    )
}

/// org.jsoup 替代：整页按文档解析，元素片段按片段解析，返回起点元素。
fn jsoup_root(html: &str) -> (scraper::Html, ego_tree::NodeId) {
    let lower = html
        .trim_start()
        .get(..20)
        .unwrap_or(html.trim_start())
        .to_ascii_lowercase();
    if lower.starts_with("<!doctype") || lower.starts_with("<html") {
        let doc = scraper::Html::parse_document(html);
        let id = doc.root_element().id();
        return (doc, id);
    }
    let doc = scraper::Html::parse_fragment(html);
    let wrapper = doc.root_element();
    let elements: Vec<_> = wrapper
        .children()
        .filter_map(scraper::ElementRef::wrap)
        .collect();
    let has_text = wrapper
        .children()
        .any(|n| n.value().as_text().is_some_and(|t| !t.trim().is_empty()));
    // 只有一个元素（选择结果的外层 HTML）时以它为起点，否则以包裹层为起点。
    let id = if elements.len() == 1 && !has_text {
        elements[0].id()
    } else {
        wrapper.id()
    };
    (doc, id)
}

pub fn absolute(base: &str, url: &str) -> String {
    match reqwest::Url::parse(base).and_then(|b| b.join(url)) {
        Ok(u) => u.to_string(),
        Err(_) => url.to_owned(),
    }
}

/// `网址,{选项}`：从第一个后面能读成 JSON 对象的 `,{` 处分开。
pub fn split_options(text: &str) -> (&str, Option<Value>) {
    let mut search = 0;
    while let Some(i) = text[search..].find(',').map(|i| i + search) {
        let rest = text[i + 1..].trim_start();
        if rest.starts_with('{') {
            if let Ok(v) = serde_json::from_str::<Value>(rest) {
                return (&text[..i], Some(v));
            }
            if let Ok(v) = serde_json::from_str::<Value>(&lenient_json(rest)) {
                return (&text[..i], Some(v));
            }
        }
        search = i + 1;
    }
    (text, None)
}

/// 单引号与不加引号的键（Gson 宽松写法）改成标准 JSON。
fn lenient_json(text: &str) -> String {
    let swapped: String = text
        .chars()
        .map(|c| {
            if matches!(c, '\'' | '“' | '”') {
                '"'
            } else {
                c
            }
        })
        .collect();
    regex::Regex::new(r#"([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:"#)
        .unwrap()
        .replace_all(&swapped, "$1\"$2\":")
        .into_owned()
}

fn already_encoded(text: &str) -> bool {
    regex::Regex::new(r"%[0-9A-Fa-f]{2}")
        .unwrap()
        .is_match(text)
}

fn encode_pairs(text: &str, charset: Option<&str>) -> String {
    text.split('&')
        .map(|pair| match pair.split_once('=') {
            Some((k, v)) if !already_encoded(v) => {
                format!("{k}={}", net::encode_component(v, charset))
            }
            _ => pair.to_owned(),
        })
        .collect::<Vec<_>>()
        .join("&")
}

fn encode_query(url: &str, charset: Option<&str>) -> String {
    let Some((head, query)) = url.split_once('?') else {
        return url.to_owned();
    };
    let (query, fragment) = match query.split_once('#') {
        Some((q, f)) => (q, Some(f)),
        None => (query, None),
    };
    let mut out = format!("{head}?{}", encode_pairs(query, charset));
    if let Some(f) = fragment {
        out.push('#');
        out.push_str(f);
    }
    out
}

fn encode_form(body: &str, charset: Option<&str>) -> String {
    if !body.contains('=') {
        return body.to_owned();
    }
    encode_pairs(body, charset)
}
