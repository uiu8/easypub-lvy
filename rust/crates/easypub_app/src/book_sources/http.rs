use super::{err, rules};
use easypub_core::{
    ApiError,
    encoding::{self, EncodingKind, EncodingMode},
};
use reqwest::{
    Url,
    header::{HeaderMap, HeaderName, HeaderValue},
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::BTreeMap, time::Duration};

#[derive(Clone, Serialize, Deserialize)]
pub(super) struct Request {
    pub template: String,
    pub method: String,
    pub body: String,
    pub charset: String,
    pub headers: BTreeMap<String, String>,
}
pub(super) fn clean_headers(value: &Value) -> rules::Result<BTreeMap<String, String>> {
    let Some(headers) = value.as_object() else {
        return if value.is_null() {
            Ok(BTreeMap::new())
        } else {
            Err("book_source_header_unsupported")
        };
    };
    let mut result = BTreeMap::new();
    for (name, value) in headers {
        let name = name.to_ascii_lowercase();
        if ![
            "user-agent",
            "referer",
            "accept",
            "accept-language",
            "content-type",
            "origin",
            "cache-control",
            "x-requested-with",
        ]
        .contains(&name.as_str())
        {
            continue;
        }
        let value = value.as_str().ok_or("book_source_header_unsupported")?;
        if rules::requires_js(value) {
            return Err("book_source_javascript_required");
        }
        if value.contains("{{") || HeaderValue::from_str(value).is_err() {
            return Err("book_source_header_unsupported");
        }
        result.insert(name, value.into());
    }
    Ok(result)
}
impl Request {
    pub fn validate(&self, base: &str) -> rules::Result<()> {
        self.expanded(base, "key")
            .map(|_| ())
            .map_err(|_| "book_source_invalid_url")
    }
    pub fn parse(text: &str) -> rules::Result<Self> {
        if rules::requires_js(text) {
            return Err("book_source_javascript_required");
        }
        let mut template = text.trim();
        let mut options = serde_json::json!({});
        for (i, _) in template.match_indices(',') {
            if template[i + 1..].trim_start().starts_with('{') {
                options = serde_json::from_str(template[i + 1..].trim())
                    .map_err(|_| "book_source_request_unsupported")?;
                template = template[..i].trim();
                break;
            }
        }
        let object = options
            .as_object()
            .ok_or("book_source_request_unsupported")?;
        if object.iter().any(|(k, v)| {
            ["js", "webView", "webJs"].contains(&k.as_str())
                && !v.is_null()
                && v != false
                && v != ""
        }) {
            return Err("book_source_javascript_required");
        }
        if object.keys().any(|k| {
            ![
                "method", "body", "charset", "headers", "js", "webView", "webJs",
            ]
            .contains(&k.as_str())
        }) {
            return Err("book_source_request_unsupported");
        }
        let method = options
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or("GET")
            .to_ascii_uppercase();
        if !["GET", "POST"].contains(&method.as_str()) {
            return Err("book_source_request_unsupported");
        }
        let charset = options
            .get("charset")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_ascii_lowercase();
        encoding_mode(&charset)?;
        let body = match options.get("body") {
            None | Some(Value::Null) => String::new(),
            Some(Value::String(s)) => s.clone(),
            _ => return Err("book_source_request_unsupported"),
        };
        if template.is_empty() {
            return Err("book_source_request_unsupported");
        }
        Ok(Self {
            template: template.into(),
            method,
            body,
            charset,
            headers: clean_headers(&options["headers"])?,
        })
    }
    pub(super) fn expanded(&self, base: &str, key: &str) -> Result<(Url, Vec<u8>), ApiError> {
        let kind = if matches!(self.charset.as_str(), "gbk" | "gb2312" | "cp936") {
            EncodingKind::Cp936
        } else {
            EncodingKind::Utf8
        };
        let encoded =
            encoding::encode(key, kind, false).map_err(|_| err("book_source_query_encoding"))?;
        let encoded_key = percent_encode(&encoded);
        let template = substitute(&self.template, &encoded_key);
        let url = absolute(base, &template)?;
        let body = if self.json_body() {
            let escaped = serde_json::to_string(key).unwrap();
            let body = substitute(&self.body, &escaped[1..escaped.len() - 1]);
            serde_json::from_str::<Value>(&body)
                .map_err(|_| err("book_source_request_unsupported"))?;
            body
        } else {
            substitute(&self.body, &encoded_key)
        };
        Ok((
            url,
            encoding::encode(&body, kind, false).map_err(|_| err("book_source_query_encoding"))?,
        ))
    }
    fn json_body(&self) -> bool {
        self.body.trim_start().starts_with(['{', '['])
    }
}
fn substitute(template: &str, key: &str) -> String {
    regex::Regex::new(r"\{\{\s*(key|page)\s*\}\}")
        .unwrap()
        .replace_all(
            template,
            |c: &regex::Captures<'_>| if &c[1] == "key" { key } else { "1" },
        )
        .into_owned()
}
fn percent_encode(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-._~".contains(b) {
                (*b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}
pub(super) fn absolute(base: &str, input: &str) -> Result<Url, ApiError> {
    let url = Url::parse(base)
        .and_then(|base| base.join(input))
        .map_err(|_| err("book_source_invalid_url"))?;
    if !["http", "https"].contains(&url.scheme())
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err(err("book_source_invalid_url"));
    }
    Ok(url)
}
fn encoding_mode(charset: &str) -> rules::Result<EncodingMode> {
    match charset.trim().to_ascii_lowercase().as_str() {
        "" => Ok(EncodingMode::Auto),
        "utf-8" | "utf8" => Ok(EncodingMode::Utf8),
        "gbk" | "gb2312" | "cp936" => Ok(EncodingMode::Cp936),
        _ => Err("book_source_encoding_unsupported"),
    }
}
pub(super) struct Page {
    pub url: String,
    pub content: rules::Content,
}
pub(super) struct Client {
    client: reqwest::Client,
    headers: BTreeMap<String, String>,
}
impl Client {
    pub fn new(headers: BTreeMap<String, String>) -> Result<Self, ApiError> {
        Ok(Self {
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(25))
                .connect_timeout(Duration::from_secs(8))
                .redirect(reqwest::redirect::Policy::none())
                .user_agent("Mozilla/5.0 EasyPub/0.1 CatalogReview")
                .build()
                .map_err(|_| err("network_initialization_failed"))?,
            headers,
        })
    }
    pub async fn fetch(&self, request: &Request, base: &str, key: &str) -> Result<Page, ApiError> {
        let (mut url, mut body) = request.expanded(base, key)?;
        let mut method = request.method.clone();
        let mut values = self.headers.clone();
        values.extend(request.headers.clone());
        // 保存和发送共用白名单，既不读取起点凭据，也不启用 cookie jar。
        let values = clean_headers(&serde_json::to_value(values).unwrap()).map_err(err)?;
        let mut headers = HeaderMap::new();
        for (name, value) in values {
            headers.insert(
                HeaderName::from_bytes(name.as_bytes())
                    .map_err(|_| err("book_source_header_unsupported"))?,
                HeaderValue::from_str(&value).map_err(|_| err("book_source_header_unsupported"))?,
            );
        }
        for redirect in 0..=3 {
            let mut req = if method == "POST" {
                let req = self.client.post(url.clone()).body(body.clone());
                if headers.contains_key(reqwest::header::CONTENT_TYPE) {
                    req
                } else {
                    req.header(
                        reqwest::header::CONTENT_TYPE,
                        if request.json_body() {
                            "application/json"
                        } else {
                            "application/x-www-form-urlencoded"
                        },
                    )
                }
            } else {
                self.client.get(url.clone())
            };
            req = req.headers(headers.clone());
            let response = req.send().await.map_err(|e| {
                err(if e.is_timeout() {
                    "network_timeout"
                } else {
                    "network_failed"
                })
            })?;
            if response.status().is_redirection() {
                if redirect == 3 {
                    return Err(err("book_source_redirect_limit"));
                }
                let location = response
                    .headers()
                    .get(reqwest::header::LOCATION)
                    .and_then(|v| v.to_str().ok())
                    .ok_or_else(|| err("book_source_invalid_url"))?;
                let next = absolute(url.as_str(), location)?;
                if next.origin() != url.origin() {
                    headers.remove(reqwest::header::REFERER);
                    headers.remove(reqwest::header::ORIGIN);
                }
                if response.status().as_u16() == 303
                    || (method == "POST" && matches!(response.status().as_u16(), 301 | 302))
                {
                    method = "GET".into();
                    body.clear();
                    headers.remove(reqwest::header::CONTENT_TYPE);
                }
                url = next;
                continue;
            }
            let content_type = response
                .headers()
                .get(reqwest::header::CONTENT_TYPE)
                .and_then(|v| v.to_str().ok())
                .unwrap_or("")
                .to_owned();
            let bytes = super::super::read_response_observed(response, || {})
                .await
                .map_err(|error| match error.next_action.as_str() {
                    "login_required" => err("book_source_auth_required"),
                    "verification_required" => err("book_source_verification_required"),
                    "rate_limited" => err("book_source_rate_limited"),
                    _ => error,
                })?;
            let charset = if !request.charset.is_empty() {
                request.charset.clone()
            } else {
                detect_charset(&content_type, &bytes)
            };
            let text = encoding::decode(&bytes, encoding_mode(&charset).map_err(err)?)
                .map_err(|_| err("invalid_catalog_encoding"))?
                .text;
            return Ok(Page {
                url: url.to_string(),
                content: rules::Content::page(text),
            });
        }
        unreachable!()
    }
}
fn detect_charset(content_type: &str, bytes: &[u8]) -> String {
    let re = regex::Regex::new(r#"(?i)charset\s*=\s*["']?([a-z0-9_-]+)"#).unwrap();
    if let Some(c) = re.captures(content_type) {
        return c[1].to_owned();
    }
    // 只在 meta 标签内找声明，正文中出现 charset 不改变解码方式。
    let prefix = String::from_utf8_lossy(&bytes[..bytes.len().min(8192)]);
    let tags = regex::Regex::new(r"(?i)<meta\b[^>]*>").unwrap();
    for tag in tags.find_iter(&prefix) {
        if let Some(c) = re.captures(tag.as_str()) {
            return c[1].to_owned();
        }
    }
    String::new()
}
