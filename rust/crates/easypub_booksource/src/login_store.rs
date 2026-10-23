//! 登录字段只通过当前 Windows 用户的 DPAPI 持久化；不写入书源集合。
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
fn path(dir: &Path, source: &str) -> PathBuf {
    dir.join("login-data").join(format!(
        "{}.bin",
        hex::encode(Sha256::digest(source.as_bytes()))
    ))
}
pub fn save(dir: &Path, source: &str, value: &str) -> Result<(), String> {
    let protected = crypt(value.as_bytes(), source.as_bytes(), true)?;
    let path = path(dir, source);
    std::fs::create_dir_all(path.parent().unwrap()).map_err(|_| "无法创建受保护登录目录")?;
    crate::download::write_atomic(&path, &protected).map_err(|_| "无法保存受保护登录数据".into())
}
pub fn load(dir: &Path, source: &str) -> Result<Option<String>, String> {
    let path = path(dir, source);
    match std::fs::metadata(&path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Ok(m) if m.len() <= 128 * 1024 => {}
        _ => return Err("受保护登录数据不可读取".into()),
    }
    let bytes = std::fs::read(path).map_err(|_| "无法读取受保护登录数据")?;
    let plain = crypt(&bytes, source.as_bytes(), false)?;
    let text = String::from_utf8(plain).map_err(|_| "受保护登录数据格式无效")?;
    if text.len() > 65536
        || !serde_json::from_str::<serde_json::Value>(&text).is_ok_and(|v| v.is_object())
    {
        return Err("受保护登录数据格式无效".into());
    }
    Ok(Some(text))
}
pub fn clear(dir: &Path, source: &str) -> Result<(), String> {
    match std::fs::remove_file(path(dir, source)) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(_) => Err("无法清除受保护登录数据".into()),
    }
}
#[cfg(windows)]
pub(crate) fn crypt(bytes: &[u8], entropy: &[u8], protect: bool) -> Result<Vec<u8>, String> {
    use windows_sys::Win32::{
        Foundation::LocalFree,
        Security::Cryptography::{
            CRYPT_INTEGER_BLOB, CRYPTPROTECT_UI_FORBIDDEN, CryptProtectData, CryptUnprotectData,
        },
    };
    if bytes.is_empty() || bytes.len() > 128 * 1024 {
        return Err("登录数据保护失败".into());
    }
    let input = CRYPT_INTEGER_BLOB {
        cbData: bytes.len() as u32,
        pbData: bytes.as_ptr() as *mut u8,
    };
    let entropy = CRYPT_INTEGER_BLOB {
        cbData: entropy.len() as u32,
        pbData: entropy.as_ptr() as *mut u8,
    };
    let mut output = CRYPT_INTEGER_BLOB {
        cbData: 0,
        pbData: std::ptr::null_mut(),
    };
    let ok = unsafe {
        if protect {
            CryptProtectData(
                &input,
                std::ptr::null(),
                &entropy,
                std::ptr::null(),
                std::ptr::null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        } else {
            CryptUnprotectData(
                &input,
                std::ptr::null_mut(),
                &entropy,
                std::ptr::null(),
                std::ptr::null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        }
    };
    if ok == 0 {
        return Err("登录数据保护失败，请使用原 Windows 用户或重新登录".into());
    }
    let result =
        unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec() };
    unsafe {
        for i in 0..output.cbData as usize {
            std::ptr::write_volatile(output.pbData.add(i), 0);
        }
        LocalFree(output.pbData as *mut _);
    }
    Ok(result)
}
#[cfg(not(windows))]
pub(crate) fn crypt(_: &[u8], _: &[u8], _: bool) -> Result<Vec<u8>, String> {
    Err("当前平台不支持受保护登录存储".into())
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;
    #[test]
    fn encrypted_roundtrip_source_binding_and_corruption() {
        let dir = std::env::temp_dir().join(format!(
            "easypub-login-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let value = r#"{"user":"synthetic-login-value"}"#;
        save(&dir, "source-one", value).unwrap();
        assert_eq!(load(&dir, "source-one").unwrap().as_deref(), Some(value));
        assert_eq!(load(&dir, "source-two").unwrap(), None);
        let bytes = std::fs::read(path(&dir, "source-one")).unwrap();
        assert!(!bytes.windows(value.len()).any(|w| w == value.as_bytes()));
        std::fs::write(path(&dir, "source-two"), &bytes).unwrap();
        assert!(load(&dir, "source-two").is_err());
        std::fs::write(path(&dir, "source-one"), b"corrupt").unwrap();
        assert!(load(&dir, "source-one").is_err());
        clear(&dir, "source-one").unwrap();
        clear(&dir, "source-two").unwrap();
        assert!(load(&dir, "source-one").unwrap().is_none());
        std::fs::remove_dir(dir.join("login-data")).unwrap();
        std::fs::remove_dir(dir).unwrap();
    }
}
