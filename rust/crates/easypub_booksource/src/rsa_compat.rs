//! RSA 纯内存桥接；密钥解析、填充和密码运算均由 AWS-LC 完成。
use aws_lc_sys::*;
use serde_json::{Value, json};
use std::ptr::{NonNull, null_mut};

const ERROR: &str = "RSA 参数、密钥或数据无效";
struct Key(NonNull<EVP_PKEY>);
impl Drop for Key {
    fn drop(&mut self) {
        unsafe { EVP_PKEY_free(self.0.as_ptr()) }
    }
}
struct Context(NonNull<EVP_PKEY_CTX>);
impl Drop for Context {
    fn drop(&mut self) {
        unsafe { EVP_PKEY_CTX_free(self.0.as_ptr()) }
    }
}
struct Digest(NonNull<EVP_MD_CTX>);
impl Drop for Digest {
    fn drop(&mut self) {
        unsafe { EVP_MD_CTX_free(self.0.as_ptr()) }
    }
}
fn check(result: i32) -> Result<(), String> {
    if result == 1 {
        Ok(())
    } else {
        Err(ERROR.into())
    }
}
fn bytes(v: &Value) -> Result<Vec<u8>, String> {
    let a = v
        .as_array()
        .filter(|a| a.len() <= 16 * 1024 * 1024)
        .ok_or(ERROR)?;
    a.iter()
        .map(|v| {
            v.as_i64()
                .filter(|v| (-128..=255).contains(v))
                .map(|v| v as u8)
                .ok_or(ERROR.into())
        })
        .collect()
}
fn key(v: &Value, private: bool) -> Result<Key, String> {
    let data = if let Some(s) = v.as_str() {
        if s.len() > 32768 {
            return Err(ERROR.into());
        }
        if s.starts_with("-----BEGIN ") {
            let label = if private { "PRIVATE KEY" } else { "PUBLIC KEY" };
            let s = s
                .trim()
                .strip_prefix(&format!("-----BEGIN {label}-----"))
                .and_then(|s| s.strip_suffix(&format!("-----END {label}-----")))
                .ok_or(ERROR)?;
            crate::crypto::unb64(&s.split_whitespace().collect::<String>()).ok_or(ERROR)?
        } else {
            crate::crypto::unb64(s).ok_or(ERROR)?
        }
    } else {
        bytes(v)?
    };
    if data.len() > 16384 {
        return Err(ERROR.into());
    }
    // CBS only borrows data until parsing returns; Key owns the parsed allocation.
    unsafe {
        let mut cbs = std::mem::zeroed();
        CBS_init(&mut cbs, data.as_ptr(), data.len());
        let raw = if private {
            EVP_parse_private_key(&mut cbs)
        } else {
            EVP_parse_public_key(&mut cbs)
        };
        let key = Key(NonNull::new(raw).ok_or(ERROR)?);
        if CBS_len(&cbs) != 0
            || EVP_PKEY_id(raw) != EVP_PKEY_RSA
            || !(1024..=4096).contains(&EVP_PKEY_bits(raw))
        {
            return Err(ERROR.into());
        }
        Ok(key)
    }
}

pub fn call(args: &[Value]) -> Result<Value, String> {
    let p = |i| args.get(i).unwrap_or(&Value::Null);
    let op = p(0).as_str().ok_or(ERROR)?;
    let algorithm = p(1).as_str().ok_or(ERROR)?.to_ascii_uppercase();
    if matches!(op, "publicKey" | "privateKey") && algorithm == "RSA" {
        key(p(2), op == "privateKey")?;
        return Ok(Value::Null);
    }
    if !matches!(op, "encrypt" | "decrypt" | "sign" | "verify") {
        return Err(ERROR.into());
    }
    let signature = matches!(op, "sign" | "verify");
    let padding = match algorithm.as_str() {
        "SHA256WITHRSA" if signature => RSA_PKCS1_PADDING,
        "RSA" | "RSA/ECB/PKCS1PADDING" if !signature => RSA_PKCS1_PADDING,
        "RSA/ECB/OAEPWITHSHA-1ANDMGF1PADDING" | "RSA/ECB/OAEPWITHSHA-256ANDMGF1PADDING"
            if !signature =>
        {
            RSA_PKCS1_OAEP_PADDING
        }
        _ => return Err("不支持的 RSA 算法组合".into()),
    };
    let key = key(p(2), matches!(op, "decrypt" | "sign"))?;
    let data = bytes(p(3))?;
    // All pointers below are scoped RAII allocations; buffers are sized to the
    // validated RSA modulus and never exposed to JS before successful completion.
    unsafe {
        let size = EVP_PKEY_size(key.0.as_ptr()) as usize;
        let mut out = vec![0; size];
        let mut len = size;
        if signature {
            let ctx = Digest(NonNull::new(EVP_MD_CTX_new()).ok_or(ERROR)?);
            if op == "verify" {
                let sig = bytes(p(4))?;
                check(EVP_DigestVerifyInit(
                    ctx.0.as_ptr(),
                    null_mut(),
                    EVP_sha256(),
                    null_mut(),
                    key.0.as_ptr(),
                ))?;
                return Ok(json!(
                    EVP_DigestVerify(
                        ctx.0.as_ptr(),
                        sig.as_ptr(),
                        sig.len(),
                        data.as_ptr(),
                        data.len()
                    ) == 1
                ));
            }
            check(EVP_DigestSignInit(
                ctx.0.as_ptr(),
                null_mut(),
                EVP_sha256(),
                null_mut(),
                key.0.as_ptr(),
            ))?;
            check(EVP_DigestSign(
                ctx.0.as_ptr(),
                out.as_mut_ptr(),
                &mut len,
                data.as_ptr(),
                data.len(),
            ))?;
        } else {
            let overhead = if padding == RSA_PKCS1_PADDING {
                11
            } else if algorithm.contains("256") {
                66
            } else {
                42
            };
            if (op == "encrypt" && data.len() > size - overhead)
                || (op == "decrypt" && data.len() != size)
            {
                return Err("RSA 单块数据长度无效".into());
            }
            let ctx =
                Context(NonNull::new(EVP_PKEY_CTX_new(key.0.as_ptr(), null_mut())).ok_or(ERROR)?);
            let c = ctx.0.as_ptr();
            check(if op == "encrypt" {
                EVP_PKEY_encrypt_init(c)
            } else {
                EVP_PKEY_decrypt_init(c)
            })?;
            check(EVP_PKEY_CTX_set_rsa_padding(c, padding))?;
            if padding == RSA_PKCS1_OAEP_PADDING {
                check(EVP_PKEY_CTX_set_rsa_oaep_md(
                    c,
                    if algorithm.contains("256") {
                        EVP_sha256()
                    } else {
                        EVP_sha1()
                    },
                ))?;
                // SunJCE transformation defaults to MGF1 SHA-1, including SHA-256 OAEP.
                check(EVP_PKEY_CTX_set_rsa_mgf1_md(c, EVP_sha1()))?;
            }
            check(if op == "encrypt" {
                EVP_PKEY_encrypt(c, out.as_mut_ptr(), &mut len, data.as_ptr(), data.len())
            } else {
                EVP_PKEY_decrypt(c, out.as_mut_ptr(), &mut len, data.as_ptr(), data.len())
            })?;
        }
        out.truncate(len);
        Ok(json!(out.iter().map(|b| *b as i8).collect::<Vec<_>>()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        engine::{Engine, SourceRt},
        source::BookSource,
    };
    #[test]
    fn jdk_vectors_and_js_contract() {
        let fixture: Value = serde_json::from_str(include_str!("rsa_test_vectors.json")).unwrap();
        let context = crate::control::Context {
            pure_compute: true,
            ..Default::default()
        };
        let _guard = context.enter();
        let engine = Engine::new(SourceRt::new(BookSource::default())).unwrap();
        engine.run(|s| {
            let script = format!("var f={fixture};\n{}", include_str!("rsa_compat_tests.js"));
            assert_eq!(s.eval_js_string(&script, &[]).unwrap(), "rsa-ok");
        });
        let data = json!("公开测试 RSA 中文".as_bytes());
        let mut export = format!("private={}\n", fixture["private"].as_str().unwrap());
        for (i, case) in fixture["cases"].as_array().unwrap().iter().enumerate() {
            let encrypted = call(&[
                json!("encrypt"),
                case["algorithm"].clone(),
                fixture["public"].clone(),
                data.clone(),
            ])
            .unwrap();
            export.push_str(&format!(
                "cipher{i}={}\n",
                crate::crypto::b64(&bytes(&encrypted).unwrap())
            ));
            let decrypted = call(&[
                json!("decrypt"),
                case["algorithm"].clone(),
                fixture["private"].clone(),
                encrypted,
            ])
            .unwrap();
            assert_eq!(bytes(&decrypted).unwrap(), "公开测试 RSA 中文".as_bytes());
        }
        if let Ok(path) = std::env::var("EASYPUB_RSA_ORACLE_OUTPUT") {
            std::fs::write(path, export).unwrap();
        }
        for invalid in [json!([256]), json!([0.5]), json!([null])] {
            assert!(
                call(&[
                    json!("encrypt"),
                    json!("RSA"),
                    fixture["public"].clone(),
                    invalid
                ])
                .is_err()
            );
        }
        let mut trailing = crate::crypto::unb64(fixture["public"].as_str().unwrap()).unwrap();
        trailing.push(0);
        assert!(key(&json!(trailing), false).is_err());
        assert!(key(&fixture["public"], true).is_err());
        assert!(
            call(&[
                json!("encrypt"),
                json!("RSA/ECB/NoPadding"),
                fixture["public"].clone(),
                data.clone()
            ])
            .is_err()
        );
        assert!(
            call(&[
                json!("encrypt"),
                json!("RSA"),
                fixture["public"].clone(),
                json!(vec![0; 246])
            ])
            .is_err()
        );
        assert!(
            call(&[
                json!("decrypt"),
                json!("RSA"),
                fixture["private"].clone(),
                json!(vec![0; 256])
            ])
            .is_err()
        );
        let pem = format!(
            "-----BEGIN PUBLIC KEY-----\n{}\n-----END PUBLIC KEY-----",
            fixture["public"].as_str().unwrap()
        );
        assert!(key(&json!(pem), false).is_ok());
    }
}
