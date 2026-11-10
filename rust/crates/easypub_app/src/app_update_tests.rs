use super::*;
use easypub_updater::{
    PLUGIN_MANIFEST_NAME, PLUGIN_SIGNATURE_NAME, PRODUCT, PackageFile, sha256_hex,
};
use ed25519_dalek::{Signer, SigningKey};
use std::{
    collections::HashMap,
    io::{BufRead, BufReader},
    net::TcpListener,
    sync::Mutex,
};

/// 下载状态是进程内单例，测试逐个运行。
static SERIAL: Mutex<()> = Mutex::new(());

const ROOT: &str = "easypub-lvy-v68-20261017-win-x64";
const ZIP: &str = "easypub-lvy-v68-20261017-win-x64.zip";

fn key() -> SigningKey {
    SigningKey::from_bytes(&[3; 32])
}

fn temp(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "easypub-app-update-{name}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// 本机测试源：按路径返回内容，未知路径 404；[slow] 时分块慢速发送，用于取消测试。
fn serve(files: HashMap<String, Vec<u8>>, slow: bool) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let files = files.clone();
            std::thread::spawn(move || {
                let mut line = String::new();
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                if reader.read_line(&mut line).is_err() {
                    return;
                }
                loop {
                    let mut h = String::new();
                    if reader.read_line(&mut h).is_err() || h == "\r\n" || h.is_empty() {
                        break;
                    }
                }
                let path = line
                    .split(' ')
                    .nth(1)
                    .unwrap_or("/")
                    .trim_start_matches('/');
                match files.get(path) {
                    Some(body) => {
                        let _ = write!(
                            stream,
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                            body.len()
                        );
                        for chunk in body.chunks(if slow { 4096 } else { 1 << 20 }) {
                            if stream.write_all(chunk).is_err() {
                                return;
                            }
                            if slow {
                                std::thread::sleep(Duration::from_millis(20));
                            }
                        }
                    }
                    None => {
                        let _ = write!(
                            stream,
                            "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        );
                    }
                }
            });
        }
    });
    format!("http://127.0.0.1:{port}")
}

/// 生成一个发布包：顶层文件夹 + 文件清单（带哈希）。[edit] 可以在打包前篡改。
fn package(
    release: u32,
    extra: &[(&str, &[u8])],
    edit: impl Fn(&mut Vec<(String, Vec<u8>)>),
) -> Vec<u8> {
    let mut files: Vec<(String, Vec<u8>)> = vec![
        ("easypub_desktop.exe".into(), b"new exe".to_vec()),
        ("easypub_updater.exe".into(), b"new updater".to_vec()),
        ("data/app.so".into(), vec![7; 50_000]),
        (
            "version.json".into(),
            format!(r#"{{"release":{release}}}"#).into_bytes(),
        ),
    ];
    let listing: Vec<Value> = files
        .iter()
        .map(|(p, d)| json!({"path":p,"bytes":d.len(),"sha256":sha256_hex(d)}))
        .collect();
    files.push((
        "package-manifest.json".into(),
        json!({"files":listing}).to_string().into_bytes(),
    ));
    for (p, d) in extra {
        files.push(((*p).into(), d.to_vec()));
    }
    edit(&mut files);
    let mut buf = std::io::Cursor::new(Vec::new());
    {
        let mut zip = zip::ZipWriter::new(&mut buf);
        let opts = zip::write::SimpleFileOptions::default();
        for (p, d) in &files {
            let name = if p.starts_with("../") {
                p.clone()
            } else {
                format!("{ROOT}/{p}")
            };
            zip.start_file(name, opts).unwrap();
            zip.write_all(d).unwrap();
        }
        zip.finish().unwrap();
    }
    buf.into_inner()
}

fn manifest(release: u32, zip: &[u8]) -> Manifest {
    Manifest {
        schema: 1,
        product: PRODUCT.into(),
        release,
        tag: format!("v{release}-20261017"),
        date: "2026-10-17".into(),
        package: PackageFile {
            name: ZIP.into(),
            bytes: zip.len() as u64,
            sha256: sha256_hex(zip),
            root: ROOT.into(),
        },
        notes: "本版新增：自动更新".into(),
    }
}

fn source(m: &Manifest, zip: Vec<u8>, slow: bool) -> String {
    let bytes = serde_json::to_vec_pretty(m).unwrap();
    let sig = easypub_updater::hex(&key().sign(&bytes).to_bytes());
    serve(
        HashMap::from([
            (MANIFEST_NAME.into(), bytes),
            (SIGNATURE_NAME.into(), sig.into_bytes()),
            (ZIP.into(), zip),
        ]),
        slow,
    )
}

fn installed(release: u32) -> PathBuf {
    let dir = temp("app");
    fs::write(
        dir.join("version.json"),
        format!(r#"{{"release":{release}}}"#),
    )
    .unwrap();
    fs::write(dir.join(APP_EXE), b"old exe").unwrap();
    fs::write(dir.join(UPDATER_EXE), b"old updater").unwrap();
    dir
}

fn call(v: Value) -> Result<Value, ApiError> {
    run(v).map(|s| serde_json::from_str(&s).unwrap())
}

fn req(action: &str, dir: &Path, base: &str) -> Value {
    json!({"op":"app_update","action":action,"app_dir":dir.to_string_lossy(),"base_url":base,
           "test_public_key":easypub_updater::hex(&key().verifying_key().to_bytes())})
}

fn wait(job: u64) -> Value {
    for _ in 0..500 {
        let s = call(json!({"action":"poll","job_id":job})).unwrap();
        if !matches!(
            s["phase"].as_str(),
            Some("downloading" | "extracting" | "verifying")
        ) {
            return s;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!("download did not finish");
}

#[test]
fn check_reports_newer_signed_release_and_rejects_bad_sources() {
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let zip = package(68, &[], |_| ());
    let base = source(&manifest(68, &zip), zip, false);
    let old = installed(67);
    let r = call(req("check", &old, &base)).unwrap();
    assert_eq!(r["available"], true);
    assert_eq!(r["current_release"], 67);
    assert_eq!(r["latest"]["release"], 68);
    assert_eq!(r["latest"]["notes"], "本版新增：自动更新");
    let same = installed(68);
    assert_eq!(
        call(req("check", &same, &base)).unwrap()["available"],
        false
    );

    // 不带测试公钥：只信任内置发布公钥，测试签名不通过。
    let mut untrusted = req("check", &old, &base);
    untrusted["test_public_key"] = Value::Null;
    assert_eq!(
        call(untrusted).unwrap_err().next_action,
        "update_signature_invalid"
    );
    // 非 GitHub、非本机回环的地址一律拒绝。
    let mut foreign = req("check", &old, &base);
    foreign["base_url"] = json!("https://evil.example/download");
    assert_eq!(
        call(foreign).unwrap_err().next_action,
        "update_source_invalid"
    );
    // 发布页没有清单。
    let empty = serve(HashMap::new(), false);
    assert_eq!(
        call(req("check", &old, &empty)).unwrap_err().next_action,
        "update_not_found"
    );
    // 连不上。
    let closed = {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        format!("http://127.0.0.1:{}", l.local_addr().unwrap().port())
    };
    assert_eq!(
        call(req("check", &old, &closed)).unwrap_err().next_action,
        "update_network"
    );
}

#[test]
fn download_verifies_and_stages_the_package_then_status_reports_it_ready() {
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let zip = package(68, &[], |_| ());
    let base = source(&manifest(68, &zip), zip, false);
    let dir = installed(67);
    call(req("check", &dir, &base)).unwrap();
    let mut start = req("download", &dir, &base);
    start["release"] = json!(67);
    assert_eq!(
        call(start).unwrap_err().next_action,
        "update_check_first",
        "版本不符"
    );
    let mut start = req("download", &dir, &base);
    start["release"] = json!(68);
    let job = call(start).unwrap()["job_id"].as_u64().unwrap();
    let done = wait(job);
    assert_eq!(done["phase"], "completed", "{done}");
    let w = dir.join(WORK_DIR);
    assert_eq!(
        fs::read(w.join("staging").join(APP_EXE)).unwrap(),
        b"new exe"
    );
    assert!(!w.join("download").exists(), "下载的压缩包已删除");
    let s = call(req("status", &dir, &base)).unwrap();
    assert_eq!(s["ready"]["release"], 68);
    assert_eq!(s["current_release"], 67);
    assert_eq!(s["writable"], true);
    // 程序目录本身还没动。
    assert_eq!(fs::read(dir.join(APP_EXE)).unwrap(), b"old exe");
}

#[test]
fn tampered_downloads_and_packages_are_rejected_without_staging() {
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let good = package(68, &[], |_| ());
    let cases: Vec<(Manifest, Vec<u8>, &str)> = vec![
        // 下载内容与清单的 SHA-256 不符。
        (
            manifest(68, &good),
            package(68, &[("x.txt", b"x")], |_| ()),
            "update_checksum_mismatch",
        ),
        // 包内文件与 package-manifest.json 的哈希不符。
        {
            let z = package(68, &[], |f| f[0].1 = b"evil exe".to_vec());
            (manifest(68, &z), z, "update_package_invalid")
        },
        // 越界路径。
        {
            let z = package(68, &[("../evil.txt", b"x")], |_| ());
            (manifest(68, &z), z, "update_package_invalid")
        },
        // 包内版本号与清单不符。
        {
            let z = package(66, &[], |_| ());
            (manifest(68, &z), z, "update_package_invalid")
        },
        // 缺少更新程序（以后就无法再自动更新）。
        {
            let z = package(68, &[], |f| f.retain(|(p, _)| p != "easypub_updater.exe"));
            (manifest(68, &z), z, "update_package_invalid")
        },
    ];
    for (m, served, reason) in cases {
        let base = source(&m, served, false);
        let dir = installed(67);
        call(req("check", &dir, &base)).unwrap();
        let mut start = req("download", &dir, &base);
        start["release"] = json!(68);
        let job = call(start).unwrap()["job_id"].as_u64().unwrap();
        let done = wait(job);
        assert_eq!(done["phase"], "failed", "{reason}: {done}");
        assert_eq!(done["error"], reason);
        let w = dir.join(WORK_DIR);
        assert!(
            !w.join("staging").exists() && !w.join("staging-tmp").exists(),
            "{reason}"
        );
        assert!(!w.join("ready.json").exists(), "{reason}");
        assert!(!dir.join("evil.txt").exists() && !w.join("evil.txt").exists());
    }
}

#[test]
fn download_can_be_cancelled_and_launch_requires_a_ready_package() {
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    // 伪随机内容：压缩不掉，慢速发送时来得及取消。
    let mut x = 0x2545_f491_u32;
    let big: Vec<u8> = (0..3 * 1024 * 1024)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            x as u8
        })
        .collect();
    let zip = package(68, &[("big.bin", &big)], |_| ());
    let base = source(&manifest(68, &zip), zip, true);
    let dir = installed(67);
    call(req("check", &dir, &base)).unwrap();
    let mut start = req("download", &dir, &base);
    start["release"] = json!(68);
    let job = call(start.clone()).unwrap()["job_id"].as_u64().unwrap();
    std::thread::sleep(Duration::from_millis(200));
    assert_eq!(call(start).unwrap_err().next_action, "update_busy");
    call(json!({"action":"cancel","job_id":job})).unwrap();
    assert_eq!(wait(job)["phase"], "cancelled");
    assert!(!dir.join(WORK_DIR).join("download").exists());
    let mut launch = req("launch", &dir, &base);
    launch["mode"] = json!("update");
    assert_eq!(
        call(launch.clone()).unwrap_err().next_action,
        "update_not_ready"
    );
    launch["mode"] = json!("rollback");
    assert_eq!(call(launch).unwrap_err().next_action, "update_no_backup");
}

const PLUGIN_ZIP: &str = "easypub-lvy-booksource-test-win-x64.zip";

/// 插件压缩包：`booksource/` 下是插件文件，顶层另有一份说明（解压时跳过）。
fn plugin_zip(exe: &[u8], listed_sha: &str) -> Vec<u8> {
    let info = json!({"id":"booksource","name":"书源下载","version":"0.2.0",
        "executable":"easypub_plugin_booksource.exe","sha256":listed_sha,
        "permissions":["network"],"protocol":1});
    let mut buf = std::io::Cursor::new(Vec::new());
    {
        let mut zip = zip::ZipWriter::new(&mut buf);
        let opts = zip::write::SimpleFileOptions::default();
        for (name, data) in [
            ("booksource/plugin.json", info.to_string().into_bytes()),
            ("booksource/easypub_plugin_booksource.exe", exe.to_vec()),
            ("readme.txt", b"install notes".to_vec()),
        ] {
            zip.start_file(name, opts).unwrap();
            zip.write_all(&data).unwrap();
        }
        zip.finish().unwrap();
    }
    buf.into_inner()
}

fn plugin_source(release: u32, exe_sha: &str, zip: Vec<u8>) -> String {
    let m = easypub_updater::PluginManifest {
        schema: 1,
        product: PRODUCT.into(),
        release,
        tag: format!("beta{release}-20261110"),
        plugins: vec![easypub_updater::PluginPackage {
            id: "booksource".into(),
            version: "0.2.0".into(),
            executable: "easypub_plugin_booksource.exe".into(),
            exe_sha256: exe_sha.into(),
            permissions: vec!["network".into()],
            name: PLUGIN_ZIP.into(),
            bytes: zip.len() as u64,
            sha256: sha256_hex(&zip),
        }],
    };
    let bytes = serde_json::to_vec_pretty(&m).unwrap();
    let sig = easypub_updater::hex(&key().sign(&bytes).to_bytes());
    serve(
        HashMap::from([
            (PLUGIN_MANIFEST_NAME.into(), bytes),
            (PLUGIN_SIGNATURE_NAME.into(), sig.into_bytes()),
            (PLUGIN_ZIP.into(), zip),
        ]),
        false,
    )
}

#[test]
fn plugin_update_downloads_signed_plugin_and_rejects_tampering() {
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    let dir = installed(8);
    let exe = b"plugin program v2".to_vec();
    let sha = sha256_hex(&exe);
    let base = plugin_source(8, &sha, plugin_zip(&exe, &sha));
    let offer = call(req("plugin_check", &dir, &base)).unwrap();
    assert_eq!(offer["release"], 8);
    assert_eq!(offer["plugins"][0]["id"], "booksource");
    assert_eq!(offer["plugins"][0]["exe_sha256"], sha.as_str());
    assert_eq!(offer["plugins"][0]["permissions"][0], "network");

    let target = temp("plugin").join("staged");
    let mut download = req("plugin_download", &dir, &base);
    download["id"] = json!("booksource");
    download["target"] = json!(target.to_string_lossy());
    let done = call(download.clone()).unwrap();
    assert_eq!(done["folder"], target.to_string_lossy().as_ref());
    assert_eq!(
        fs::read(target.join("easypub_plugin_booksource.exe")).unwrap(),
        exe
    );
    assert!(target.join("plugin.json").is_file());
    assert!(!target.join("readme.txt").exists());
    // 目标已经存在时不覆盖。
    assert_eq!(
        call(download).unwrap_err().next_action,
        "update_package_invalid"
    );

    // 清单签了名，但包里的程序和清单登记的校验值不一样：拒绝，并且不留下文件夹。
    let other = b"swapped program".to_vec();
    let base = plugin_source(8, &sha, plugin_zip(&other, &sha));
    call(req("plugin_check", &dir, &base)).unwrap();
    let target = temp("plugin").join("staged");
    let mut download = req("plugin_download", &dir, &base);
    download["id"] = json!("booksource");
    download["target"] = json!(target.to_string_lossy());
    assert_eq!(
        call(download).unwrap_err().next_action,
        "update_package_invalid"
    );
    assert!(!target.exists());

    // 不带测试公钥：签名不被信任。
    let mut untrusted = req("plugin_check", &dir, &base);
    untrusted.as_object_mut().unwrap().remove("test_public_key");
    assert_eq!(
        call(untrusted).unwrap_err().next_action,
        "update_signature_invalid"
    );

    // 旧 Release 没有插件清单：按“没有可更新的”返回，不算错。
    let zip = package(68, &[], |_| ());
    let base = source(&manifest(68, &zip), zip, false);
    let none = call(req("plugin_check", &dir, &base)).unwrap();
    assert!(none["release"].is_null());
    assert_eq!(none["plugins"].as_array().unwrap().len(), 0);
    let mut download = req("plugin_download", &dir, &base);
    download["id"] = json!("booksource");
    download["target"] = json!(temp("plugin").join("staged").to_string_lossy());
    assert_eq!(
        call(download).unwrap_err().next_action,
        "update_check_first"
    );
}

#[cfg(windows)]
#[test]
fn installed_version_in_registry_follows_version_json() {
    use windows_sys::Win32::System::Registry::{
        HKEY, HKEY_CURRENT_USER, KEY_ALL_ACCESS, REG_SZ, RRF_RT_REG_SZ, RegCloseKey,
        RegCreateKeyExW, RegDeleteKeyW, RegGetValueW, RegSetValueExW,
    };
    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }
    struct Key(HKEY, String);
    impl Key {
        fn set(&self, name: &str, value: &str) {
            let data = wide(value);
            // SAFETY: 数据指针与字节数来自同一个缓冲区。
            let status = unsafe {
                RegSetValueExW(
                    self.0,
                    wide(name).as_ptr(),
                    0,
                    REG_SZ,
                    data.as_ptr().cast(),
                    (data.len() * 2) as u32,
                )
            };
            assert_eq!(status, 0);
        }
        fn get(&self, name: &str) -> String {
            let mut buf = vec![0u16; 512];
            let mut size = (buf.len() * 2) as u32;
            // SAFETY: 缓冲区长度与传入的字节数一致。
            let status = unsafe {
                RegGetValueW(
                    self.0,
                    std::ptr::null(),
                    wide(name).as_ptr(),
                    RRF_RT_REG_SZ,
                    std::ptr::null_mut(),
                    buf.as_mut_ptr().cast(),
                    &mut size,
                )
            };
            assert_eq!(status, 0);
            String::from_utf16_lossy(&buf[..size as usize / 2])
                .trim_end_matches('\0')
                .to_string()
        }
    }
    impl Drop for Key {
        fn drop(&mut self) {
            // SAFETY: 句柄来自 RegCreateKeyExW；删除的是本测试自己建的键。
            unsafe {
                RegCloseKey(self.0);
                RegDeleteKeyW(HKEY_CURRENT_USER, wide(&self.1).as_ptr());
            }
        }
    }
    let subkey = format!(
        "Software\\easypub-lvy-test-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    );
    let mut handle: HKEY = std::ptr::null_mut();
    // SAFETY: 子键名以 0 结尾；句柄由 Key 关闭。
    let status = unsafe {
        RegCreateKeyExW(
            HKEY_CURRENT_USER,
            wide(&subkey).as_ptr(),
            0,
            std::ptr::null(),
            0,
            KEY_ALL_ACCESS,
            std::ptr::null(),
            &mut handle,
            std::ptr::null_mut(),
        )
    };
    assert_eq!(status, 0);
    let key = Key(handle, subkey.clone());
    let dir = installed(8);
    key.set("DisplayVersion", "测试版 6");
    key.set("DisplayName", "easypub-lvy 测试版 6");

    // 登记的安装位置是别处（例如压缩包解压的副本在运行）：不改。
    key.set("InstallLocation", "C:\\somewhere-else\\");
    assert!(!sync_installed_version(&dir, &subkey));
    assert_eq!(key.get("DisplayVersion"), "测试版 6");

    // 登记的位置就是本程序目录（安装程序写的路径带结尾的反斜杠）：改成当前版本。
    key.set(
        "InstallLocation",
        &format!("{}\\", dir.to_string_lossy().to_uppercase()),
    );
    assert!(sync_installed_version(&dir, &subkey));
    assert_eq!(key.get("DisplayVersion"), "测试版 8");
    assert_eq!(key.get("DisplayName"), "easypub-lvy 测试版 8");
    // 已经一致：不重复写。
    assert!(!sync_installed_version(&dir, &subkey));
    // 没有登记项（没用安装包装过）：什么都不做。
    assert!(!sync_installed_version(&dir, &format!("{subkey}-missing")));
}
