use super::*;
use easypub_updater::{PRODUCT, PackageFile, sha256_hex};
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
