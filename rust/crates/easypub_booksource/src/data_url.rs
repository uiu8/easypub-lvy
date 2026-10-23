//! data URL 只解码为内存响应，不经过网络或 WebView，不执行其中的脚本。
use crate::net::{MAX_BODY, Request, Response};

pub fn matches(url: &str) -> bool {
    url.get(..5)
        .is_some_and(|s| s.eq_ignore_ascii_case("data:"))
}

pub fn response(request: &Request, as_hex: bool) -> Result<Response, String> {
    crate::control::current().check()?;
    let limit = request.max_body.unwrap_or(MAX_BODY).min(MAX_BODY);
    if request.url.len() > limit.saturating_mul(4).saturating_add(1024) {
        return Err("内嵌内容超过限制".into());
    }
    let (metadata, payload) = request
        .url
        .get(5..)
        .map(|s| s.split_once('#').map_or(s, |(body, _)| body))
        .and_then(|s| s.split_once(','))
        .ok_or("内嵌内容地址格式无效")?;
    let mut parts = metadata.split(';');
    let mime = parts
        .next()
        .filter(|s| !s.is_empty())
        .unwrap_or("text/plain");
    let mut charset = "utf-8";
    let mut base64 = false;
    for part in parts {
        if part.eq_ignore_ascii_case("base64") {
            base64 = true;
        } else if let Some((key, value)) = part.split_once('=')
            && key.eq_ignore_ascii_case("charset")
        {
            charset = value;
        }
    }
    let bytes: Vec<u8> = percent_encoding::percent_decode_str(payload).collect();
    let body = if base64 {
        let encoded = std::str::from_utf8(&bytes).map_err(|_| "内嵌内容 Base64 无效")?;
        crate::crypto::unb64(encoded).ok_or("内嵌内容 Base64 无效")?
    } else {
        bytes
    };
    if body.len() > limit {
        return Err("内嵌内容超过限制".into());
    }
    let text = if as_hex {
        hex::encode(&body)
    } else {
        let encoding =
            encoding_rs::Encoding::for_label(charset.as_bytes()).ok_or("内嵌内容字符集不支持")?;
        encoding.decode(&body).0.into_owned()
    };
    Ok(Response {
        url: request.url.clone(),
        status: 200,
        headers: vec![("content-type".into(), format!("{mime};charset={charset}"))],
        body,
        text,
        protocol: "data".into(),
        ..Default::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        engine::{Engine, SourceRt},
        source::BookSource,
        webbook::Book,
    };
    use serde_json::json;
    #[test]
    fn inline_text_is_literal_bounded_and_does_not_use_http_or_webview() {
        let engine = Engine::new(SourceRt::new(BookSource::default())).unwrap();
        for (url, expected) in [
            ("data:,a+b%20c", "a+b c"),
            ("data:text/plain;charset=gbk,%D6%D0%CE%C4", "中文"),
            ("DATA:text/plain;base64,5Lit5paH", "中文"),
            ("data:text/plain;base64,5Lit5paH#chapter", "中文"),
            (
                "data:text/plain;base64,5Lit5paH,{\"js\":\"result\"}",
                "中文",
            ),
            (
                "data:application/json,{\"x\":\"{{java.put('secret','value')}}\"}",
                "{\"x\":\"{{java.put('secret','value')}}\"}",
            ),
        ] {
            let result = engine.run(|s| s.fetch(url)).unwrap();
            assert_eq!(result.text, expected);
            assert_eq!(result.protocol, "data");
        }
        assert!(
            engine
                .take_logs()
                .iter()
                .all(|line| !line.contains("secret") && !line.contains("data:"))
        );
        for url in [
            "data:invalid",
            "data:;base64,???",
            "data:;charset=unknown,x",
        ] {
            assert!(engine.run(|s| s.fetch(url)).is_err());
        }
        assert!(
            response(
                &Request {
                    url: "data:,12345".into(),
                    max_body: Some(4),
                    ..Default::default()
                },
                false
            )
            .is_err()
        );
        let mut context = crate::control::current();
        context.cancel = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));
        let _guard = context.enter();
        assert!(engine.run(|s| s.fetch("data:,x")).is_err());
    }
    #[test]
    fn inline_toc_and_chapter_follow_normal_rules() {
        let chapter = format!(
            "data:text/html;base64,{}",
            crate::crypto::b64("<p>内嵌正文</p>".as_bytes())
        );
        let toc = format!(
            "data:application/json;base64,{}",
            crate::crypto::b64(
                json!([{"name":"第一章","url":chapter}])
                    .to_string()
                    .as_bytes()
            )
        );
        let source = BookSource {
            rule_toc: serde_json::from_value(
                json!({"chapterList":"$[*]","chapterName":"$.name","chapterUrl":"$.url"}),
            )
            .unwrap(),
            rule_content: serde_json::from_value(json!({"content":"p@text"})).unwrap(),
            ..Default::default()
        };
        let engine = Engine::new(SourceRt::new(source)).unwrap();
        let book = Book {
            book_url: "https://fixture.test/book".into(),
            toc_url: toc,
            ..Default::default()
        };
        engine.run(|s| {
            let chapters = s.toc(&book).unwrap();
            assert_eq!(chapters.len(), 1);
            assert_eq!(
                s.chapter_content(&book, &chapters[0], "").unwrap(),
                "内嵌正文"
            );
        });
    }
}
