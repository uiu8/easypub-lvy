//! 仿 Java 的纯内存计算。没有文件、进程或网络入口。
use ring::{
    aead,
    rand::{SecureRandom, SystemRandom},
};
use serde_json::{Value, json};
use std::io::{Read, Write};
const LIMIT: usize = 16 * 1024 * 1024;

fn bytes(v: &Value) -> Result<Vec<u8>, String> {
    let a = v.as_array().ok_or("字节数组无效")?;
    if a.len() > LIMIT {
        return Err("内存字节数组超过上限".into());
    }
    a.iter()
        .map(|x| {
            x.as_i64()
                .filter(|n| (-128..=255).contains(n))
                .map(|n| n as u8)
                .ok_or("字节值无效".into())
        })
        .collect()
}
fn signed(b: &[u8]) -> Value {
    json!(b.iter().map(|b| *b as i8).collect::<Vec<_>>())
}
pub fn call(a: &[Value]) -> Result<Value, String> {
    let op = a.first().and_then(Value::as_str).unwrap_or("");
    let p = |i| a.get(i).unwrap_or(&Value::Null);
    match op {
        "rsa" => crate::rsa_compat::call(&a[1..]),
        "properties" => Ok(json!({
            "http.agent": crate::net::DEFAULT_UA,
            "os.name": std::env::consts::OS,
            "os.arch": std::env::consts::ARCH,
            "file.separator": std::path::MAIN_SEPARATOR.to_string(),
            "line.separator": if cfg!(windows) { "\r\n" } else { "\n" },
        })),
        "unbase64" => Ok(signed(
            &crate::crypto::unb64(p(1).as_str().ok_or("Base64 字符串无效")?)
                .ok_or("Base64 内容无效")?,
        )),
        "random" => {
            let n = p(1)
                .as_u64()
                .filter(|n| *n <= LIMIT as u64)
                .ok_or("随机字节长度无效")? as usize;
            let mut b = vec![0; n];
            SystemRandom::new()
                .fill(&mut b)
                .map_err(|_| "系统随机源失败")?;
            Ok(signed(&b))
        }
        "gzip" | "gunzip" => {
            let b = bytes(p(1))?;
            let mut out = Vec::new();
            if op == "gzip" {
                let mut w = flate2::write::GzEncoder::new(out, flate2::Compression::default());
                w.write_all(&b).map_err(|_| "压缩失败")?;
                out = w.finish().map_err(|_| "压缩失败")?;
            } else {
                flate2::read::MultiGzDecoder::new(&b[..])
                    .take(LIMIT as u64 + 1)
                    .read_to_end(&mut out)
                    .map_err(|_| "压缩数据无效")?;
            }
            if out.len() > LIMIT {
                return Err("解压内容超过上限".into());
            }
            Ok(signed(&out))
        }
        "cipher" => {
            let t = p(1).as_str().ok_or("加密算法无效")?.to_ascii_uppercase();
            let key = bytes(p(2))?;
            let iv = if p(3).is_null() {
                None
            } else {
                Some(bytes(p(3))?)
            };
            let encrypt = p(4).as_bool().ok_or("加密模式无效")?;
            let mut data = bytes(p(5))?;
            if t == "AES/GCM/NOPADDING" {
                let algo = match key.len() {
                    16 => &aead::AES_128_GCM,
                    32 => &aead::AES_256_GCM,
                    _ => return Err("不支持的 GCM 密钥长度".into()),
                };
                let nonce = aead::Nonce::try_assume_unique_for_key(iv.as_deref().unwrap_or(&[]))
                    .map_err(|_| "GCM IV 须为12字节")?;
                let k = aead::LessSafeKey::new(
                    aead::UnboundKey::new(algo, &key).map_err(|_| "密钥无效")?,
                );
                let aad = bytes(p(6))?;
                if encrypt {
                    k.seal_in_place_append_tag(nonce, aead::Aad::from(&aad), &mut data)
                        .map_err(|_| "加密失败")?;
                } else {
                    data = k
                        .open_in_place(nonce, aead::Aad::from(&aad), &mut data)
                        .map_err(|_| "密文认证失败")?
                        .to_vec();
                }
            } else {
                let parts: Vec<_> = t.split('/').collect();
                if parts.len() != 3
                    || !matches!(parts[0], "AES" | "DES" | "DESEDE")
                    || !matches!(parts[1], "ECB" | "CBC")
                    || !matches!(parts[2], "PKCS5PADDING" | "PKCS7PADDING" | "NOPADDING")
                {
                    return Err("不支持的 Cipher 算法组合".into());
                }
                let block = if parts[0] == "AES" { 16 } else { 8 };
                if parts[1] == "CBC" && iv.as_ref().map(Vec::len) != Some(block) {
                    return Err("CBC IV 长度无效".into());
                }
                if parts[2] == "NOPADDING" && !data.len().is_multiple_of(block) {
                    return Err("NoPadding 数据长度须为整块".into());
                }
                data = crate::crypto::symmetric(&t, &key, iv.as_deref(), encrypt, &data)?;
            }
            Ok(signed(&data))
        }
        "decode" | "encode" => {
            let charset = p(2).as_str().unwrap_or("UTF-8").to_ascii_uppercase();
            if charset == "ISO-8859-1" {
                if op == "decode" {
                    return Ok(json!(
                        bytes(p(1))?.into_iter().map(char::from).collect::<String>()
                    ));
                }
                return Ok(signed(
                    &p(1)
                        .as_str()
                        .ok_or("字符串无效")?
                        .chars()
                        .map(|c| if c as u32 <= 255 { c as u8 } else { b'?' })
                        .collect::<Vec<_>>(),
                ));
            }
            let enc = match charset.as_str() {
                "UTF-8" | "UTF8" => encoding_rs::UTF_8,
                "GBK" | "GB2312" => encoding_rs::GBK,
                _ => return Err("不支持的 Charset".into()),
            };
            if op == "decode" {
                Ok(json!(enc.decode(&bytes(p(1))?).0))
            } else {
                Ok(signed(&enc.encode(p(1).as_str().ok_or("字符串无效")?).0))
            }
        }
        "url" => {
            let text = p(1).as_str().ok_or("URL 无效")?;
            let base = reqwest::Url::parse(text).map_err(|_| "URL 无效")?;
            let u = if let Some(relative) = p(2).as_str() {
                base.join(relative).map_err(|_| "URL 无效")?
            } else {
                base
            };
            Ok(
                json!({"url":u.as_str(),"protocol":u.scheme(),"host":u.host_str(),"port":u.port().map(i64::from).unwrap_or(-1),"path":u.path(),"query":u.query(),"ref":u.fragment()}),
            )
        }
        "unsupported" => Err(format!(
            "不支持的 Java 类或方法：{}",
            p(1).as_str()
                .unwrap_or("unknown")
                .chars()
                .filter(|c| c.is_ascii_alphanumeric() || "._$".contains(*c))
                .take(120)
                .collect::<String>()
        )),
        _ => Err("不支持的 Java 内存操作".into()),
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        control::ErrorKind,
        engine::{Engine, SourceRt},
        source::BookSource,
    };
    #[test]
    fn properties_are_isolated_between_engines() {
        let first = Engine::new(SourceRt::new(BookSource::default())).unwrap();
        first.run(|s| {
            assert_eq!(s.eval_js_string("String(java.lang.System.getProperty('http.agent')===java.getUserAgent())", &[]).unwrap(), "true");
            assert_eq!(s.eval_js_string("JSON.stringify(new java.util.ArrayList(java.getStringList('@json:$.names[*]',JSON.stringify({names:['甲','乙']}))))", &[]).unwrap(), "[\"甲\",\"乙\"]");
            s.eval_js("java.lang.System.setProperty('fixture','private')", &[]).unwrap();
        });
        assert_eq!(
            first.run(|s| s
                .eval_js_string("java.lang.System.getProperty('fixture')", &[])
                .unwrap()),
            "private"
        );
        let second = Engine::new(SourceRt::new(BookSource::default())).unwrap();
        assert_eq!(
            second.run(|s| s
                .eval_js_string("java.lang.System.getProperty('fixture','absent')", &[])
                .unwrap()),
            "absent"
        );
    }
    #[test]
    fn public_vectors_and_denied_capabilities() {
        let context = crate::control::Context {
            pure_compute: true,
            ..Default::default()
        };
        let _guard = context.enter();
        let engine = Engine::new(SourceRt::new(BookSource::default())).unwrap();
        engine.run(|s| {
            assert_eq!(
                s.eval_js_string(include_str!("java_compat_tests.js"), &[])
                    .unwrap(),
                "vectors-ok"
            );
            for code in [
                "java.ajax('http://127.0.0.1:1')",
                "java.importScript('http://127.0.0.1:1')",
                "java.startBrowser('https://example.invalid')",
                "cache.put('fake','fake')",
                "new Packages.java.io.File('fake')",
                "new java.io.FileInputStream('fake')",
                "java.nio.file.Files.readAllBytes('fake')",
                "java.lang.Runtime.getRuntime().exec('fake')",
                "new java.lang.ProcessBuilder('fake')",
                "java.lang.Class.forName('fake')",
                "new java.lang.ClassLoader()",
                "new java.lang.Thread()",
                "java.lang.System.getenv('PATH')",
                "java.lang.System.exit(0)",
                "new java.net.URL('http://127.0.0.1:1').openConnection().getResponseCode()",
            ] {
                let error = s.eval_js(code, &[]).unwrap_err();
                assert_eq!(ErrorKind::classify(&error), ErrorKind::Unsupported);
            }
            assert!(
                s.eval_js("java.util.Base64.getDecoder().decode('???')", &[])
                    .is_err()
            );
            assert!(
                s.eval_js(
                    "new java.util.zip.GZIPInputStream(new java.io.ByteArrayInputStream([0,1]))",
                    &[]
                )
                .is_err()
            );
        });
    }
}
