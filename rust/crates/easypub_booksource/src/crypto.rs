//! 书源 JS 里常见的对称加解密与摘要（写法同 Java：`AES/CBC/PKCS5Padding`）。
use base64::Engine as _;
use cipher::{
    BlockDecryptMut, BlockEncryptMut, KeyInit, KeyIvInit,
    block_padding::{NoPadding, Pkcs7},
};
use sha2::Digest;

pub fn b64(data: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(data)
}
pub fn unb64(text: &str) -> Option<Vec<u8>> {
    let clean: String = text.chars().filter(|c| !c.is_whitespace()).collect();
    let engines = [
        base64::engine::general_purpose::STANDARD,
        base64::engine::general_purpose::STANDARD_NO_PAD,
        base64::engine::general_purpose::URL_SAFE,
        base64::engine::general_purpose::URL_SAFE_NO_PAD,
    ];
    engines.iter().find_map(|e| e.decode(clean.as_bytes()).ok())
}

/// 解密输入是文字时：十六进制或 Base64（与 Hutool 的自动识别一致）。
pub fn decode_input(text: &str) -> Option<Vec<u8>> {
    let t = text.trim();
    if !t.is_empty() && t.len().is_multiple_of(2) && t.chars().all(|c| c.is_ascii_hexdigit()) {
        return hex::decode(t).ok();
    }
    unb64(t)
}

enum Algo {
    Aes,
    Des,
    TripleDes,
}

pub fn symmetric(
    transformation: &str,
    key: &[u8],
    iv: Option<&[u8]>,
    encrypt: bool,
    data: &[u8],
) -> Result<Vec<u8>, String> {
    let parts: Vec<String> = transformation
        .split('/')
        .map(|s| s.trim().to_ascii_uppercase())
        .collect();
    let algo = match parts.first().map(String::as_str) {
        Some("AES") => Algo::Aes,
        Some("DES") => Algo::Des,
        Some("DESEDE" | "TRIPLEDES" | "3DES") => Algo::TripleDes,
        other => return Err(format!("不支持的加密算法：{}", other.unwrap_or(""))),
    };
    let mode = parts.get(1).map(String::as_str).unwrap_or("ECB");
    let padding = parts.get(2).map(String::as_str).unwrap_or("PKCS5PADDING");
    // ZeroPadding：加密时补 0 到整块，解密后去掉末尾的 0。
    let zero = padding == "ZEROPADDING";
    let pad = !(padding == "NOPADDING" || zero);
    let block = if matches!(algo, Algo::Aes) { 16 } else { 8 };
    let zero_filled;
    let data = if zero && encrypt {
        let mut d = data.to_vec();
        d.resize(d.len().div_ceil(block).max(1) * block, 0);
        zero_filled = d;
        &zero_filled[..]
    } else {
        data
    };
    let iv_or_zero = |n: usize| -> Vec<u8> {
        let mut v = iv.map(<[u8]>::to_vec).unwrap_or_default();
        v.resize(n, 0);
        v
    };
    macro_rules! run {
        ($cipher:ty, $block:expr) => {{
            match (mode, encrypt) {
                ("CBC", false) => {
                    let c = cbc::Decryptor::<$cipher>::new_from_slices(key, &iv_or_zero($block))
                        .map_err(|_| "密钥或 IV 长度不对")?;
                    if pad {
                        c.decrypt_padded_vec_mut::<Pkcs7>(data)
                    } else {
                        c.decrypt_padded_vec_mut::<NoPadding>(data)
                    }
                    .map_err(|_| "解密失败".to_string())
                }
                ("CBC", true) => {
                    let c = cbc::Encryptor::<$cipher>::new_from_slices(key, &iv_or_zero($block))
                        .map_err(|_| "密钥或 IV 长度不对")?;
                    Ok(if pad {
                        c.encrypt_padded_vec_mut::<Pkcs7>(data)
                    } else {
                        c.encrypt_padded_vec_mut::<NoPadding>(data)
                    })
                }
                ("ECB", false) => {
                    let c = ecb::Decryptor::<$cipher>::new_from_slice(key)
                        .map_err(|_| "密钥长度不对")?;
                    if pad {
                        c.decrypt_padded_vec_mut::<Pkcs7>(data)
                    } else {
                        c.decrypt_padded_vec_mut::<NoPadding>(data)
                    }
                    .map_err(|_| "解密失败".to_string())
                }
                ("ECB", true) => {
                    let c = ecb::Encryptor::<$cipher>::new_from_slice(key)
                        .map_err(|_| "密钥长度不对")?;
                    Ok(if pad {
                        c.encrypt_padded_vec_mut::<Pkcs7>(data)
                    } else {
                        c.encrypt_padded_vec_mut::<NoPadding>(data)
                    })
                }
                (m, _) => Err(format!("不支持的分组模式：{m}")),
            }
        }};
    }
    let out = match algo {
        Algo::Aes => match key.len() {
            16 => run!(aes::Aes128, 16),
            24 => run!(aes::Aes192, 16),
            32 => run!(aes::Aes256, 16),
            n => Err(format!("AES 密钥长度应为 16/24/32，实际 {n}")),
        },
        Algo::Des => run!(des::Des, 8),
        Algo::TripleDes => match key.len() {
            24 => run!(des::TdesEde3, 8),
            16 => run!(des::TdesEde2, 8),
            n => Err(format!("3DES 密钥长度应为 16/24，实际 {n}")),
        },
    }?;
    Ok(if zero && !encrypt {
        let end = out.iter().rposition(|b| *b != 0).map_or(0, |i| i + 1);
        out[..end].to_vec()
    } else {
        out
    })
}

fn digest_with<D: Digest>(data: &[u8]) -> Vec<u8> {
    D::digest(data).to_vec()
}

pub fn digest(data: &[u8], algo: &str) -> Result<Vec<u8>, String> {
    Ok(match algo.to_ascii_uppercase().replace('-', "").as_str() {
        "MD5" => digest_with::<md5::Md5>(data),
        "SHA1" | "SHA" => digest_with::<sha1::Sha1>(data),
        "SHA224" => digest_with::<sha2::Sha224>(data),
        "SHA256" => digest_with::<sha2::Sha256>(data),
        "SHA384" => digest_with::<sha2::Sha384>(data),
        "SHA512" => digest_with::<sha2::Sha512>(data),
        other => return Err(format!("不支持的摘要算法：{other}")),
    })
}

/// HMAC：H((K ^ opad) || H((K ^ ipad) || m))。
pub fn hmac(data: &[u8], algo: &str, key: &[u8]) -> Result<Vec<u8>, String> {
    let name = algo
        .to_ascii_uppercase()
        .replace("HMAC", "")
        .replace('-', "");
    let block = if matches!(name.as_str(), "SHA384" | "SHA512") {
        128
    } else {
        64
    };
    let mut k = if key.len() > block {
        digest(key, &name)?
    } else {
        key.to_vec()
    };
    k.resize(block, 0);
    let inner: Vec<u8> = k
        .iter()
        .map(|b| b ^ 0x36)
        .chain(data.iter().copied())
        .collect();
    let inner = digest(&inner, &name)?;
    let outer: Vec<u8> = k.iter().map(|b| b ^ 0x5c).chain(inner).collect();
    digest(&outer, &name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aes_cbc_round_trip_and_known_vector() {
        let key = b"0123456789abcdef";
        let iv = b"fedcba9876543210";
        let enc = symmetric(
            "AES/CBC/PKCS5Padding",
            key,
            Some(iv),
            true,
            "书源正文".as_bytes(),
        )
        .unwrap();
        let dec = symmetric("AES/CBC/PKCS5Padding", key, Some(iv), false, &enc).unwrap();
        assert_eq!(String::from_utf8(dec).unwrap(), "书源正文");
        // ECB 无 IV；DES 8 字节密钥。
        let enc = symmetric("DES/ECB/PKCS5Padding", b"12345678", None, true, b"abc").unwrap();
        assert_eq!(
            symmetric("DES", b"12345678", None, false, &enc).unwrap(),
            b"abc"
        );
        assert_eq!(
            hex::encode(digest(b"abc", "MD5").unwrap()),
            "900150983cd24fb0d6963f7d28e17f72"
        );
        // RFC 2202 HMAC-MD5 测试 2。
        assert_eq!(
            hex::encode(hmac(b"what do ya want for nothing?", "HmacMD5", b"Jefe").unwrap()),
            "750c783e6ab0b503eaa86e310a5db738"
        );
        assert_eq!(decode_input("616263"), Some(b"abc".to_vec()));
        let enc = symmetric("AES/CBC/ZeroPadding", key, Some(iv), true, b"zero").unwrap();
        assert_eq!(enc.len(), 16);
        assert_eq!(
            symmetric("AES/CBC/ZeroPadding", key, Some(iv), false, &enc).unwrap(),
            b"zero"
        );
        assert_eq!(decode_input("YWJj"), Some(b"abc".to_vec()));
    }
}
