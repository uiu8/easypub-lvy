//! 网络失败固定词表；底层错误只用于分类，绝不回传地址或凭据。
const KINDS: &[(&str, &str)] = &[
    ("timeout", "连接或响应超时"),
    ("dns", "DNS 解析失败"),
    ("connection_refused", "连接被拒绝"),
    ("certificate_expired", "TLS 证书已过期或尚未生效"),
    ("certificate_name", "TLS 证书域名不符"),
    ("certificate_untrusted", "TLS 证书链不受信任"),
    ("tls", "TLS 连接或证书校验失败"),
    ("proxy_auth", "代理认证失败"),
    ("connect", "无法建立连接（目标或代理不可达）"),
    ("response", "连接中断或响应读取失败"),
];

pub fn code(message: &str) -> Option<&'static str> {
    KINDS
        .iter()
        .find(|(_, label)| message.contains(label))
        .map(|(code, _)| *code)
}

pub(crate) fn label(code: &str) -> &'static str {
    KINDS.iter().find(|(key, _)| *key == code).unwrap().1
}

fn io_code(error: &std::io::Error) -> Option<&'static str> {
    // Schannel/CryptoAPI 状态码不依赖 Windows 显示语言。
    match error.raw_os_error().map(|code| code as u32) {
        Some(0x800B0101 | 0x80090328) => Some("certificate_expired"),
        Some(0x800B010F | 0x80090322) => Some("certificate_name"),
        Some(0x800B0109 | 0x800B010A | 0x80090325) => Some("certificate_untrusted"),
        _ => match error.kind() {
            std::io::ErrorKind::ConnectionRefused => Some("connection_refused"),
            std::io::ErrorKind::TimedOut => Some("timeout"),
            _ => None,
        },
    }
}

pub fn describe(error: &reqwest::Error) -> &'static str {
    if error.is_timeout() {
        return label("timeout");
    }
    if error.is_dns() {
        return label("dns");
    }
    let mut chain: Option<&(dyn std::error::Error + 'static)> = Some(error);
    let mut detail = String::new();
    while let Some(e) = chain {
        if let Some(code) = e.downcast_ref::<std::io::Error>().and_then(io_code) {
            return label(code);
        }
        // 顶层 reqwest Display 含请求 URL，不能拿 URL 单词判断 TLS/认证失败。
        if !e.is::<reqwest::Error>() {
            let message = e.to_string();
            // native-tls 的 Schannel 包装不暴露内部 io::Error，保留标准 OS 数字后缀。
            if let Some(raw) = message
                .rsplit_once("(os error ")
                .and_then(|(_, tail)| tail.strip_suffix(')'))
                .and_then(|s| s.parse::<i32>().ok())
            {
                if let Some(code) = io_code(&std::io::Error::from_raw_os_error(raw)) {
                    return label(code);
                }
                if matches!((raw as u32) >> 16, 0x8009 | 0x800B) {
                    return label("tls");
                }
            }
            detail.push_str(&message.to_lowercase());
        }
        chain = e.source();
    }
    let code = if detail.contains("certificate has expired")
        || detail.contains("certificate is not yet valid")
    {
        "certificate_expired"
    } else if detail.contains("hostname mismatch") || detail.contains("ip address mismatch") {
        "certificate_name"
    } else if detail.contains("self-signed certificate")
        || detail.contains("unable to get local issuer")
    {
        // 不受信任的根不一定是自签证书，不能进一步猜测。
        "certificate_untrusted"
    } else if detail.contains("certificate") || detail.contains("tls") || detail.contains("ssl") {
        "tls"
    } else if detail.contains("407") || detail.contains("authentication") {
        "proxy_auth"
    } else if error.is_connect() {
        "connect"
    } else {
        "response"
    };
    label(code)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_codes_and_fixed_reports() {
        for (raw, expected) in [
            (0x800B0101u32, "certificate_expired"),
            (0x800B010F, "certificate_name"),
            (0x800B0109, "certificate_untrusted"),
        ] {
            assert_eq!(
                io_code(&std::io::Error::from_raw_os_error(raw as i32)),
                Some(expected)
            );
        }
        for (code_value, text) in KINDS {
            assert_eq!(
                code(&format!("搜索脚本出错：{text} · 直连")),
                Some(*code_value)
            );
            assert_eq!(
                crate::control::ErrorKind::classify(text).cause(),
                Some("network")
            );
        }
        assert_eq!(code("规则脚本类型错误"), None);
    }

    #[test]
    fn refused_request_survives_probe_without_url() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        drop(listener);
        let source = serde_json::from_value(serde_json::json!({
            "bookSourceUrl":format!("http://{address}"),
            "searchUrl":format!("http://{address}/tls-certificate?secret=private"),
            "ruleSearch":{"bookList":"a", "name":"text", "bookUrl":"href"},
            "ruleContent":{"content":"body@text"}
        }))
        .unwrap();
        let engine = crate::engine::Engine::new(crate::engine::SourceRt::new(source)).unwrap();
        let mut report = crate::probe::Check::default();
        let error = crate::probe::check(&engine, "自拟", &mut report).unwrap_err();
        assert_eq!(report.network_failure, Some("connection_refused"));
        assert_eq!(report.cause, Some("network"));
        assert_eq!(crate::probe::reason(&error), "连接失败");
        let json = serde_json::to_string(&report).unwrap();
        assert!(!json.contains("private"));
        assert!(!json.contains(&address.to_string()));
    }
}
