//! Current-user DPAPI storage. No plaintext read operation crosses the bridge.
use easypub_core::{ApiError, ErrorCode};
use serde_json::{Value, json};
fn err(reason: &str) -> ApiError {
    ApiError::new(ErrorCode::InvalidRule, "catalog", reason)
}
pub(crate) fn execute(request: &Value, cookie: &str) -> Result<Value, ApiError> {
    if request["source"] != "qidian" {
        return Err(err("cookie_origin_mismatch"));
    }
    #[cfg(windows)]
    {
        windows::execute(request, cookie).map_err(err)
    }
    #[cfg(not(windows))]
    {
        let _ = cookie;
        Err(err("credential_storage_unsupported"))
    }
}
pub(crate) fn for_request(request: &Value, cookie: &str) -> Result<String, ApiError> {
    if !cookie.trim().is_empty() || request["use_saved_cookie"] != true {
        return Ok(cookie.into());
    }
    #[cfg(windows)]
    {
        windows::load().map(|s| s.unwrap_or_default()).map_err(err)
    }
    #[cfg(not(windows))]
    {
        Ok(String::new())
    }
}

#[cfg(windows)]
mod windows {
    use super::*;
    use std::{
        fs::{self, File, OpenOptions},
        io::{Read, Write},
        os::windows::ffi::OsStrExt,
        path::{Path, PathBuf},
        sync::{
            Mutex,
            atomic::{AtomicU64, Ordering},
        },
    };
    use windows_sys::Win32::{
        Foundation::LocalFree,
        Security::Cryptography::{
            CRYPT_INTEGER_BLOB, CRYPTPROTECT_UI_FORBIDDEN, CryptProtectData, CryptUnprotectData,
        },
        Storage::FileSystem::{MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH, MoveFileExW},
    };
    type Result<T> = std::result::Result<T, &'static str>;
    const LIMIT: usize = 600 * 1024;
    const ENTROPY: &[u8] = b"EasyPubRustFlutter/catalog-cookie/qidian/v1";
    static LOCK: Mutex<()> = Mutex::new(());
    static NEXT: AtomicU64 = AtomicU64::new(1);
    struct Store {
        path: PathBuf,
    }
    impl Store {
        fn current() -> Result<Self> {
            let root = std::env::var_os("LOCALAPPDATA").ok_or("credential_storage_unavailable")?;
            Ok(Self {
                path: PathBuf::from(root).join("EasyPubRustFlutter/credentials-v1/qidian.dpapi"),
            })
        }
        fn saved(&self) -> Result<bool> {
            self.path.try_exists().map_err(|_| "credential_read_failed")
        }
        fn load(&self) -> Result<Option<String>> {
            let file = match File::open(&self.path) {
                Ok(file) => file,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
                Err(_) => return Err("credential_read_failed"),
            };
            let mut bytes = Vec::new();
            file.take(LIMIT as u64 + 1)
                .read_to_end(&mut bytes)
                .map_err(|_| "credential_read_failed")?;
            if bytes.is_empty() || bytes.len() > LIMIT {
                return Err("credential_read_failed");
            }
            let plaintext = crypt(&bytes, false).map_err(|_| "credential_read_failed")?;
            String::from_utf8(plaintext)
                .map(Some)
                .map_err(|_| "credential_read_failed")
        }
        fn save(&self, value: &str) -> Result<()> {
            crate::catalog_cookie::validate_for_storage(value)?;
            let encrypted = crypt(value.as_bytes(), true)?;
            let parent = self.path.parent().ok_or("credential_save_failed")?;
            fs::create_dir_all(parent).map_err(|_| "credential_save_failed")?;
            let staging = parent.join(format!(
                ".cookie-{}-{}.tmp",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&staging)
                .map_err(|_| "credential_save_failed")?;
            let written = file.write_all(&encrypted).and_then(|_| file.sync_all());
            drop(file);
            if written.is_err() {
                let _ = fs::remove_file(&staging);
                return Err("credential_save_failed");
            }
            fn wide(path: &Path) -> Vec<u16> {
                path.as_os_str().encode_wide().chain(Some(0)).collect()
            }
            let from = wide(&staging);
            let to = wide(&self.path);
            // A failed replacement leaves the old ciphertext in place.
            let success = unsafe {
                MoveFileExW(
                    from.as_ptr(),
                    to.as_ptr(),
                    MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
                )
            };
            if success == 0 {
                let _ = fs::remove_file(&staging);
                return Err("credential_save_failed");
            }
            Ok(())
        }
        fn clear(&self) -> Result<()> {
            match fs::remove_file(&self.path) {
                Ok(()) => Ok(()),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(_) => Err("credential_clear_failed"),
            }
        }
    }
    fn crypt(bytes: &[u8], protect: bool) -> Result<Vec<u8>> {
        if bytes.is_empty() || bytes.len() > LIMIT {
            return Err("credential_protection_failed");
        }
        let input = CRYPT_INTEGER_BLOB {
            cbData: bytes.len() as u32,
            pbData: bytes.as_ptr() as *mut u8,
        };
        let entropy = CRYPT_INTEGER_BLOB {
            cbData: ENTROPY.len() as u32,
            pbData: ENTROPY.as_ptr() as *mut u8,
        };
        let mut output = CRYPT_INTEGER_BLOB {
            cbData: 0,
            pbData: std::ptr::null_mut(),
        };
        let success = unsafe {
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
        if success == 0 {
            return Err("credential_protection_failed");
        }
        // The API allocates output; copy it before zeroing and releasing that buffer.
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
    pub(super) fn execute(request: &Value, cookie: &str) -> Result<Value> {
        let _guard = LOCK.lock().map_err(|_| "credential_storage_busy")?;
        let store = Store::current()?;
        match request["op"].as_str() {
            Some("credential_status") => Ok(json!({"saved":store.saved()?})),
            Some("credential_save") => {
                store.save(cookie)?;
                Ok(json!({"saved":true}))
            }
            Some("credential_clear") => {
                store.clear()?;
                Ok(json!({"saved":false}))
            }
            _ => Err("invalid_request"),
        }
    }
    pub(super) fn load() -> Result<Option<String>> {
        let _guard = LOCK.lock().map_err(|_| "credential_storage_busy")?;
        Store::current()?.load()
    }
    #[cfg(test)]
    mod tests {
        use super::*;
        use std::os::windows::fs::OpenOptionsExt;
        fn store() -> Store {
            let root = std::env::temp_dir().join(format!(
                "easypub-credential-test-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            Store {
                path: root.join("qidian.dpapi"),
            }
        }
        #[test]
        fn dpapi_roundtrip_replacement_clear_and_no_plaintext() {
            if let Some(path) = std::env::var_os("EASYPUB_CREDENTIAL_TEST_REOPEN") {
                let reopened = Store {
                    path: PathBuf::from(path),
                };
                assert_eq!(
                    reopened.load().unwrap().unwrap(),
                    "Cookie: session=SYNTHETIC_FIRST"
                );
                return;
            }
            let store = store();
            assert!(!store.saved().unwrap());
            store.save("Cookie: session=SYNTHETIC_FIRST").unwrap();
            let child = std::process::Command::new(std::env::current_exe().unwrap())
                .args(["--exact", "catalog_credentials::windows::tests::dpapi_roundtrip_replacement_clear_and_no_plaintext"])
                .env("EASYPUB_CREDENTIAL_TEST_REOPEN", &store.path).output().unwrap();
            assert!(child.status.success(), "fresh-process DPAPI read failed");
            let bytes = fs::read(&store.path).unwrap();
            assert!(!bytes.windows(15).any(|v| v == b"SYNTHETIC_FIRST"));
            let reopened = Store {
                path: store.path.clone(),
            };
            assert_eq!(
                reopened.load().unwrap().unwrap(),
                "Cookie: session=SYNTHETIC_FIRST"
            );
            reopened.save("session=SYNTHETIC_SECOND").unwrap();
            assert_eq!(store.load().unwrap().unwrap(), "session=SYNTHETIC_SECOND");
            assert!(store.save("not a cookie").is_err());
            assert_eq!(store.load().unwrap().unwrap(), "session=SYNTHETIC_SECOND");
            store.clear().unwrap();
            store.clear().unwrap();
            assert!(store.load().unwrap().is_none());
            fs::remove_dir(store.path.parent().unwrap()).unwrap();
        }
        #[test]
        fn failed_atomic_replace_and_clear_preserve_old_value() {
            let store = store();
            store.save("session=SYNTHETIC_OLD").unwrap();
            let lock = OpenOptions::new()
                .read(true)
                .share_mode(0)
                .open(&store.path)
                .unwrap();
            assert_eq!(
                store.save("session=SYNTHETIC_NEW").unwrap_err(),
                "credential_save_failed"
            );
            assert_eq!(store.clear().unwrap_err(), "credential_clear_failed");
            drop(lock);
            assert_eq!(store.load().unwrap().unwrap(), "session=SYNTHETIC_OLD");
            assert_eq!(
                fs::read_dir(store.path.parent().unwrap()).unwrap().count(),
                1
            );
            store.clear().unwrap();
            fs::remove_dir(store.path.parent().unwrap()).unwrap();
        }
        #[test]
        fn corrupt_ciphertext_is_not_treated_as_anonymous_and_can_be_cleared() {
            let store = store();
            store.save("session=SYNTHETIC").unwrap();
            let mut bytes = fs::read(&store.path).unwrap();
            let last = bytes.len() - 1;
            bytes[last] ^= 0x55;
            fs::write(&store.path, bytes).unwrap();
            assert_eq!(store.load().unwrap_err(), "credential_read_failed");
            store.clear().unwrap();
            fs::remove_dir(store.path.parent().unwrap()).unwrap();
        }
    }
}
