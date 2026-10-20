//! 轻悦时光 HTML 文字书源协议，按公开接口独立实现，不复制其应用代码。
use crate::{
    engine::{Scope, SourceRt},
    net::{DEFAULT_UA, Request},
    webview::{Interactive, Job},
};
use base64::Engine as _;
use serde_json::{Value, json};
use std::{sync::Arc, time::Duration};

fn fetch_script(rt: &SourceRt, url: &str) -> Result<String, String> {
    let request = |url: &str| {
        rt.net.fetch(&Request {
            url: url.into(),
            method: "GET".into(),
            ..Default::default()
        })
    };
    let response = request(url)
        .or_else(|e| {
            // 官方旧模板使用的这个 CDN 已失效，保持相同 jQuery 版本，改读其官方 CDN。
            if url == "https://vc.jd.com/web/js/jquery-3.1.1.min.js" {
                request("https://code.jquery.com/jquery-3.1.1.min.js")
            } else {
                Err(e)
            }
        })
        .map_err(|e| e.0)?;
    if response.status >= 400 {
        return Err(format!("网站返回 {}", response.status));
    }
    Ok(response.text)
}
fn document(rt: &SourceRt) -> Result<String, String> {
    let mut cache = rt.html_document.lock().unwrap();
    if let Some(html) = &*cache {
        return Ok(html.clone());
    }
    let source = rt.source.html.trim();
    let (html, base) = if source.starts_with("https://") || source.starts_with("http://") {
        let r = rt
            .net
            .fetch(&Request {
                url: source.into(),
                method: "GET".into(),
                ..Default::default()
            })
            .map_err(|e| e.0)?;
        if r.status >= 400 {
            return Err(format!("网站返回 {}", r.status));
        }
        (r.text, r.url)
    } else {
        (source.to_owned(), rt.source.base_url().to_owned())
    };
    // 外部脚本也经过插件的网络设置；页面自身不允许另开网络通道。
    let scripts = regex::Regex::new(
        r#"(?is)<script\b[^>]*\bsrc\s*=\s*["']([^"']+)["'][^>]*>\s*</script\s*>"#,
    )
    .unwrap();
    let mut prepared = String::new();
    let mut end = 0;
    for cap in scripts.captures_iter(&html) {
        let range = cap.get(0).unwrap();
        prepared.push_str(&html[end..range.start()]);
        let url = crate::engine::absolute(&base, &cap[1]);
        let code = fetch_script(rt, &url)?;
        prepared.push_str("<script>");
        prepared.push_str(&code.replace("</script", "<\\/script"));
        prepared.push_str("</script>");
        end = range.end();
    }
    prepared.push_str(&html[end..]);
    if prepared.len() > 1_500_000 {
        return Err("HTML 书源页面过大".into());
    }
    let result = format!(
        "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:\"><script>{}</script>{prepared}",
        include_str!("qysg_bridge.js")
    );
    *cache = Some(result.clone());
    Ok(result)
}
pub fn call(scope: &Scope<'_, '_>, method: &str, args: Value) -> Result<Value, String> {
    let rt = scope.inner.rt.clone();
    let html = document(&rt)?;
    let mut context = crate::control::current();
    context.crawl = rt.source.meta.crawl.clone();
    let js = format!(
        "window.__epRun({},{});window.__epResult || ''",
        json!(method),
        args
    );
    let out = crate::webview::submit(Job {
        context,
        url: rt.source.base_url().into(),
        method: "GET".into(),
        body: None,
        content_type: None,
        headers: Vec::new(),
        html: Some(html),
        js: Some(js),
        user_agent: DEFAULT_UA.into(),
        cookies: Vec::new(),
        timeout: Duration::from_secs(30),
        interactive: Interactive::Never,
        prompt: String::new(),
        cookies_only: false,
        bridge: Some(rt),
    })?;
    let envelope: Value = serde_json::from_str(&out.text).map_err(|_| "HTML 书源返回值无效")?;
    if envelope["ok"] != true {
        return Err("HTML 书源脚本执行失败或缺少入口函数".into());
    }
    let result = envelope["value"].clone();
    if method == "content" {
        return Ok(result);
    }
    match result {
        Value::String(s) => {
            serde_json::from_str(&s).map_err(|_| "HTML 书源返回值不是有效 JSON".into())
        }
        other => Ok(other),
    }
}
fn string(args: &[Value], i: usize) -> String {
    match args.get(i) {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Null) | None => String::new(),
        Some(v) => v.to_string(),
    }
}
fn headers(raw: &str) -> Vec<(String, String)> {
    let mut v = Value::String(raw.to_owned());
    for _ in 0..3 {
        if let Value::String(s) = &v {
            v = serde_json::from_str(s).unwrap_or(Value::Null);
        } else {
            break;
        }
    }
    v.as_object()
        .map(|m| {
            m.iter()
                .map(|(k, v)| (k.clone(), v.as_str().unwrap_or("").to_owned()))
                .collect()
        })
        .unwrap_or_default()
}
/// 不向第三方页面提供本机文件、外部应用、设备标识或任意原生调用。
pub fn bridge(rt: &Arc<SourceRt>, name: &str, args: &[Value]) -> Result<Value, String> {
    match name {
        "CookieJar" | "log" | "text" | "showToast" | "showLongToast" => Ok(json!(true)),
        "device" => Ok(json!("windows")),
        "version" => Ok(json!(env!("CARGO_PKG_VERSION"))),
        "buildNumber" => Ok(json!(0)),
        "getWebViewUA" => Ok(json!(DEFAULT_UA)),
        "http" => {
            let method = string(args, 0).to_ascii_uppercase();
            if !matches!(method.as_str(), "GET" | "HEAD" | "POST") {
                return Err("HTML 书源 HTTP 方法不支持".into());
            }
            let mut h = headers(&string(args, 3));
            let content_type = string(args, 5);
            if !content_type.is_empty() {
                h.push(("content-type".into(), content_type));
            }
            let req = Request {
                url: string(args, 1),
                method: method.clone(),
                body: if method == "POST" {
                    Some(string(args, 2).into_bytes())
                } else {
                    None
                },
                headers: h,
                ..Default::default()
            };
            let r = if args.get(4) == Some(&json!(false)) {
                rt.net.fetch_no_redirect(&req)
            } else {
                rt.net.fetch(&req)
            }
            .map_err(|e| e.0)?;
            let mut h = std::collections::BTreeMap::<String, Vec<String>>::new();
            for (k, v) in r.headers {
                h.entry(k).or_default().push(v);
            }
            Ok(
                json!({"method":method.to_lowercase(),"body":base64::prelude::BASE64_STANDARD.encode(r.body),
                "headers":h,"statusCode":r.status,"statusMessage":"OK","data":r.text}),
            )
        }
        "cache.get" => Ok(rt
            .cache
            .lock()
            .unwrap()
            .get(&string(args, 0))
            .map(|s| json!(s))
            .unwrap_or(Value::Null)),
        "cache.set" => {
            rt.cache
                .lock()
                .unwrap()
                .insert(string(args, 0), string(args, 1));
            Ok(json!(true))
        }
        "cache.remove" => {
            rt.cache.lock().unwrap().remove(&string(args, 0));
            Ok(json!(true))
        }
        "cookie.get" | "cookie.getCookie" => {
            let url = reqwest::Url::parse(&string(args, 0)).map_err(|_| "Cookie 网址无效")?;
            let h = rt.net.cookie_header(&url);
            if name == "cookie.getCookie" {
                let key = string(args, 1);
                return Ok(json!(
                    h.split(';')
                        .filter_map(|p| p.trim().split_once('='))
                        .find(|(k, _)| *k == key)
                        .map(|(_, v)| v)
                        .unwrap_or("")
                ));
            }
            Ok(json!(h))
        }
        "cookie.set" => {
            rt.net.set_cookie(&string(args, 0), &string(args, 1));
            Ok(json!(true))
        }
        "cookie.remove" => {
            rt.net.remove_cookies(&string(args, 0));
            Ok(json!(true))
        }
        "htmlToText" => Ok(json!(crate::text::html_to_text(&string(args, 0)))),
        "base64encode" => Ok(json!(
            base64::prelude::BASE64_STANDARD.encode(string(args, 0))
        )),
        "base64decode" => Ok(json!(
            String::from_utf8(
                base64::prelude::BASE64_STANDARD
                    .decode(string(args, 0))
                    .map_err(|_| "Base64 格式无效")?
            )
            .map_err(|_| "Base64 内容不是 UTF-8")?
        )),
        "utf8ToGbkUrlEncoded" => {
            let text = string(args, 0);
            let (b, _, _) = encoding_rs::GBK.encode(&text);
            Ok(json!(
                percent_encoding::percent_encode(&b, percent_encoding::NON_ALPHANUMERIC)
                    .to_string()
            ))
        }
        "webview" => {
            if !string(args, 5).is_empty() || !string(args, 6).is_empty() {
                return Err("HTML 书源暂不支持网页资源拦截".into());
            }
            let url = string(args, 0);
            let js = string(args, 1);
            let html = string(args, 2);
            let body = string(args, 3);
            let h = headers(&string(args, 4));
            let mut context = crate::control::current();
            context.crawl = rt.source.meta.crawl.clone();
            let cookies = reqwest::Url::parse(&url)
                .ok()
                .map(|u| rt.net.cookie_header(&u))
                .unwrap_or_default();
            let out = crate::webview::submit(Job {
                context,
                url: url.clone(),
                method: if body.is_empty() {
                    "GET".into()
                } else {
                    "POST".into()
                },
                body: (!body.is_empty()).then(|| body.into_bytes()),
                content_type: h
                    .iter()
                    .find(|(k, _)| k.eq_ignore_ascii_case("content-type"))
                    .map(|(_, v)| v.clone()),
                headers: h.clone(),
                html: (!html.is_empty()).then_some(html),
                js: (!js.is_empty()).then_some(js),
                user_agent: h
                    .iter()
                    .find(|(k, _)| k.eq_ignore_ascii_case("user-agent"))
                    .map(|(_, v)| v.clone())
                    .unwrap_or(DEFAULT_UA.into()),
                cookies: cookies
                    .split(';')
                    .filter_map(|p| p.trim().split_once('='))
                    .map(|(k, v)| (k.into(), v.into()))
                    .collect(),
                timeout: Duration::from_secs(30),
                interactive: Interactive::Never,
                prompt: String::new(),
                cookies_only: false,
                bridge: None,
            })?;
            rt.net.set_cookie(
                &url,
                &out.cookies
                    .iter()
                    .map(|(k, v)| format!("{k}={v}"))
                    .collect::<Vec<_>>()
                    .join("; "),
            );
            Ok(json!(out.text))
        }
        _ => Err(format!(
            "尚未适配的原生接口：{}",
            known_interface_name(name)
        )),
    }
}

fn known_interface_name(name: &str) -> &str {
    // 动态接口名也可能是源脚本拼出的凭据，只公布协议中明确的接口标识。
    match name {
        "openApp" | "launchUrl" | "readFile" | "writeFile" | "getDeviceId" | "getClipboard"
        | "setClipboard" => name,
        _ => "未知接口（未回显第三方参数）",
    }
}
