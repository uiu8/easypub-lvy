//! V68 自动更新（SET-071–073）：检查 GitHub 发布页、后台下载并校验、启动 easypub_updater.exe。
//! 文件都放在程序目录下的 `.update\`（与程序同盘，替换只需改名）：
//!   download\  下载中的压缩包；staging\  校验通过、待替换的新版本；ready.json  待替换的版本；
//!   backup\    上一版（回退用）；run\  更新程序副本；state.json / updater.log  更新程序写的结果。
use easypub_core::{ApiError, ErrorCode};
use easypub_updater::{
    APP_EXE, MANIFEST_NAME, Manifest, PUBLIC_KEYS, SIGNATURE_NAME, UPDATER_EXE, WORK_DIR, hex,
    read_release, verify_manifest,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::Duration,
};

const DEFAULT_BASE: &str = "https://github.com/uiu8/easypub-lvy/releases/latest/download";
const RELEASES: &str = "https://github.com/uiu8/easypub-lvy/releases";

fn error(code: ErrorCode, reason: &str) -> ApiError {
    ApiError::new(code, "app_update", reason)
}

struct Job {
    id: u64,
    phase: &'static str,
    received: Arc<AtomicU64>,
    total: u64,
    cancel: Arc<AtomicBool>,
    error: Option<String>,
}

#[derive(Default)]
struct State {
    /// 最近一次检查得到并已校验签名的清单，下载只认它。
    checked: Option<(Manifest, String)>,
    job: Option<Job>,
    sequence: u64,
}

fn state() -> &'static Mutex<State> {
    static STATE: OnceLock<Mutex<State>> = OnceLock::new();
    STATE.get_or_init(Mutex::default)
}

fn app_dir(value: &Value) -> Result<PathBuf, ApiError> {
    if let Some(dir) = value["app_dir"].as_str() {
        return Ok(PathBuf::from(dir));
    }
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(Path::to_path_buf))
        .ok_or_else(|| error(ErrorCode::Io, "update_not_packaged"))
}

/// 只允许默认的 GitHub 地址，或测试用的本机回环地址。
fn base_url(value: &Value) -> Result<String, ApiError> {
    match value["base_url"].as_str() {
        None => Ok(DEFAULT_BASE.into()),
        Some(b) if b.starts_with("http://127.0.0.1:") && !b.contains('@') => {
            Ok(b.trim_end_matches('/').into())
        }
        Some(_) => Err(error(ErrorCode::InvalidRule, "update_source_invalid")),
    }
}

fn package_url(base: &str, m: &Manifest) -> String {
    if base == DEFAULT_BASE {
        format!("{RELEASES}/download/{}/{}", m.tag, m.package.name)
    } else {
        format!("{base}/{}", m.package.name)
    }
}

fn client(timeout: Duration) -> Result<reqwest::blocking::Client, ApiError> {
    reqwest::blocking::Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .timeout(timeout)
        .user_agent("easypub-lvy-updater")
        // GitHub 附件会跳转到 githubusercontent 下载域；只跟随这两个域名和本机回环地址。
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            let ok = attempt.previous().len() < 6
                && match attempt.url().host_str() {
                    Some("127.0.0.1") => attempt.url().scheme() == "http",
                    Some(h) => {
                        attempt.url().scheme() == "https"
                            && (h == "github.com" || h.ends_with(".githubusercontent.com"))
                    }
                    None => false,
                };
            if ok { attempt.follow() } else { attempt.stop() }
        }))
        .build()
        .map_err(|_| error(ErrorCode::Io, "update_network"))
}

fn fetch_small(client: &reqwest::blocking::Client, url: &str) -> Result<Vec<u8>, ApiError> {
    let response = client
        .get(url)
        .send()
        .map_err(|_| error(ErrorCode::Io, "update_network"))?;
    if response.status() == reqwest::StatusCode::NOT_FOUND {
        return Err(error(ErrorCode::NotFound, "update_not_found"));
    }
    if !response.status().is_success() {
        return Err(error(ErrorCode::Io, "update_network"));
    }
    let mut body = Vec::new();
    response
        .take(256 * 1024)
        .read_to_end(&mut body)
        .map_err(|_| error(ErrorCode::Io, "update_network"))?;
    Ok(body)
}

fn work(dir: &Path) -> PathBuf {
    dir.join(WORK_DIR)
}

fn writable(dir: &Path) -> bool {
    let w = work(dir);
    let probe = w.join(".write-test");
    fs::create_dir_all(&w).is_ok()
        && fs::write(&probe, b"ok").is_ok()
        && fs::remove_file(&probe).is_ok()
}

fn read_json(path: &Path) -> Value {
    fs::read_to_string(path)
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or(Value::Null)
}

fn status(dir: &Path) -> Value {
    let w = work(dir);
    let ready = read_json(&w.join("ready.json"));
    // 开发版本（例如测试时的 flutter_tester 目录）不试写，避免在别处建 .update。
    let packaged = dir.join("version.json").is_file() && dir.join(UPDATER_EXE).is_file();
    json!({
        "app_dir": dir.to_string_lossy(),
        "packaged": packaged,
        "writable": packaged && writable(dir),
        "current_release": read_release(dir),
        "ready": if w.join("staging").join(APP_EXE).is_file() { ready } else { Value::Null },
        "backup_release": read_release(&w.join("backup")),
        "last": read_json(&w.join("state.json")),
        "releases_url": RELEASES,
    })
}

fn check(value: &Value) -> Result<Value, ApiError> {
    let dir = app_dir(value)?;
    let base = base_url(value)?;
    let c = client(Duration::from_secs(30))?;
    let bytes = fetch_small(&c, &format!("{base}/{MANIFEST_NAME}"))?;
    let signature = fetch_small(&c, &format!("{base}/{SIGNATURE_NAME}"))?;
    let signature = String::from_utf8(signature)
        .map_err(|_| error(ErrorCode::InvalidRule, "update_signature_invalid"))?;
    let manifest = verify_manifest(&bytes, &signature, &keys(value))
        .map_err(|e| error(ErrorCode::InvalidRule, e.0))?;
    let current = read_release(&dir);
    let available = current.is_none_or(|c| manifest.release > c);
    let response = json!({
        "current_release": current,
        "available": available,
        "latest": {"release":manifest.release,"tag":manifest.tag,"date":manifest.date,
                   "notes":manifest.notes,"bytes":manifest.package.bytes},
    });
    state().lock().expect("update state").checked = Some((manifest, base));
    Ok(response)
}

/// 测试可以额外信任一把公钥（十六进制）；只在本机回环地址的测试源上生效。
fn keys(value: &Value) -> Vec<[u8; 32]> {
    let mut keys = PUBLIC_KEYS.to_vec();
    if value["base_url"]
        .as_str()
        .is_some_and(|b| b.starts_with("http://127.0.0.1:"))
        && let Some(k) = value["test_public_key"]
            .as_str()
            .and_then(easypub_updater::unhex)
            .and_then(|b| <[u8; 32]>::try_from(b).ok())
    {
        keys.push(k);
    }
    keys
}

fn download(
    dir: &Path,
    manifest: &Manifest,
    base: &str,
    received: &AtomicU64,
    cancel: &AtomicBool,
    phase: &dyn Fn(&'static str),
) -> Result<(), ApiError> {
    let w = work(dir);
    if !writable(dir) {
        return Err(error(ErrorCode::Io, "update_app_dir_not_writable"));
    }
    let downloads = w.join("download");
    let _ = fs::remove_dir_all(&downloads);
    fs::create_dir_all(&downloads)
        .map_err(|_| error(ErrorCode::Io, "update_app_dir_not_writable"))?;
    let zip_path = downloads.join(&manifest.package.name);
    let part = downloads.join(format!("{}.part", manifest.package.name));
    {
        let c = client(Duration::from_secs(60 * 60))?;
        let mut response = c
            .get(package_url(base, manifest))
            .send()
            .map_err(|_| error(ErrorCode::Io, "update_network"))?;
        if !response.status().is_success() {
            return Err(error(ErrorCode::Io, "update_download_failed"));
        }
        let mut file = fs::File::create(&part)
            .map_err(|_| error(ErrorCode::Io, "update_app_dir_not_writable"))?;
        let mut hasher = Sha256::new();
        let mut buf = vec![0u8; 64 * 1024];
        let mut total = 0u64;
        loop {
            if cancel.load(Ordering::Relaxed) {
                drop(file);
                let _ = fs::remove_dir_all(&downloads);
                return Err(error(ErrorCode::Cancelled, "update_cancelled"));
            }
            let n = response
                .read(&mut buf)
                .map_err(|_| error(ErrorCode::Io, "update_download_failed"))?;
            if n == 0 {
                break;
            }
            total += n as u64;
            if total > manifest.package.bytes {
                return Err(error(ErrorCode::InvalidRule, "update_checksum_mismatch"));
            }
            hasher.update(&buf[..n]);
            file.write_all(&buf[..n])
                .map_err(|_| error(ErrorCode::Io, "update_disk_write_failed"))?;
            received.store(total, Ordering::Relaxed);
        }
        file.sync_all()
            .map_err(|_| error(ErrorCode::Io, "update_disk_write_failed"))?;
        if total != manifest.package.bytes || hex(&hasher.finalize()) != manifest.package.sha256 {
            let _ = fs::remove_dir_all(&downloads);
            return Err(error(ErrorCode::InvalidRule, "update_checksum_mismatch"));
        }
    }
    fs::rename(&part, &zip_path).map_err(|_| error(ErrorCode::Io, "update_disk_write_failed"))?;
    phase("extracting");
    let staging_tmp = w.join("staging-tmp");
    let _ = fs::remove_dir_all(&staging_tmp);
    let result = extract(&zip_path, &manifest.package.root, &staging_tmp, cancel).and_then(|()| {
        phase("verifying");
        verify_package(&staging_tmp, manifest, cancel)
    });
    let _ = fs::remove_dir_all(&downloads);
    if let Err(e) = result {
        let _ = fs::remove_dir_all(&staging_tmp);
        return Err(e);
    }
    let staging = w.join("staging");
    let _ = fs::remove_file(w.join("ready.json"));
    let _ = fs::remove_dir_all(&staging);
    fs::rename(&staging_tmp, &staging)
        .map_err(|_| error(ErrorCode::Io, "update_disk_write_failed"))?;
    fs::write(
        w.join("ready.json"),
        json!({"release":manifest.release,"tag":manifest.tag,"date":manifest.date,"notes":manifest.notes})
            .to_string(),
    )
    .map_err(|_| error(ErrorCode::Io, "update_disk_write_failed"))?;
    Ok(())
}

/// 解压压缩包的顶层文件夹 [root] 到 [out]；拒绝越界路径、链接和超大内容。
pub(crate) fn extract(
    zip: &Path,
    root: &str,
    out: &Path,
    cancel: &AtomicBool,
) -> Result<(), ApiError> {
    let invalid = || error(ErrorCode::InvalidRule, "update_package_invalid");
    let file = fs::File::open(zip).map_err(|_| invalid())?;
    let mut archive = zip::ZipArchive::new(file).map_err(|_| invalid())?;
    let mut total = 0u64;
    for i in 0..archive.len() {
        if cancel.load(Ordering::Relaxed) {
            return Err(error(ErrorCode::Cancelled, "update_cancelled"));
        }
        let mut entry = archive.by_index(i).map_err(|_| invalid())?;
        let name = entry.enclosed_name().ok_or_else(invalid)?;
        let rel = name
            .strip_prefix(root)
            .map_err(|_| invalid())?
            .to_path_buf();
        if rel.as_os_str().is_empty() {
            continue;
        }
        if rel
            .components()
            .any(|c| !matches!(c, std::path::Component::Normal(_)))
            || rel.starts_with(WORK_DIR)
            || entry.is_symlink()
        {
            return Err(invalid());
        }
        let target = out.join(&rel);
        if entry.is_dir() {
            fs::create_dir_all(&target).map_err(|_| invalid())?;
            continue;
        }
        total += entry.size();
        if total > 4 * 1024 * 1024 * 1024 {
            return Err(invalid());
        }
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)
                .map_err(|_| error(ErrorCode::Io, "update_disk_write_failed"))?;
        }
        let mut f = fs::File::create(&target)
            .map_err(|_| error(ErrorCode::Io, "update_disk_write_failed"))?;
        std::io::copy(&mut entry, &mut f).map_err(|_| invalid())?;
    }
    Ok(())
}

/// 按包内 package-manifest.json 逐个核对文件大小与 SHA-256，并检查版本号与必需文件。
pub(crate) fn verify_package(
    dir: &Path,
    manifest: &Manifest,
    cancel: &AtomicBool,
) -> Result<(), ApiError> {
    let invalid = || error(ErrorCode::InvalidRule, "update_package_invalid");
    let listing = read_json(&dir.join("package-manifest.json"));
    let files = listing["files"].as_array().ok_or_else(invalid)?;
    if files.is_empty() {
        return Err(invalid());
    }
    for f in files {
        if cancel.load(Ordering::Relaxed) {
            return Err(error(ErrorCode::Cancelled, "update_cancelled"));
        }
        let rel = f["path"].as_str().ok_or_else(invalid)?;
        let path = Path::new(rel);
        if path
            .components()
            .any(|c| !matches!(c, std::path::Component::Normal(_)))
        {
            return Err(invalid());
        }
        let data = fs::read(dir.join(path)).map_err(|_| invalid())?;
        if f["bytes"].as_u64() != Some(data.len() as u64)
            || f["sha256"].as_str() != Some(hex(&Sha256::digest(&data)).as_str())
        {
            return Err(invalid());
        }
    }
    if read_release(dir) != Some(manifest.release)
        || !dir.join(APP_EXE).is_file()
        || !dir.join(UPDATER_EXE).is_file()
    {
        return Err(invalid());
    }
    Ok(())
}

fn snapshot(job: &Job) -> Value {
    json!({"job_id":job.id,"phase":job.phase,"received":job.received.load(Ordering::Relaxed),
           "total":job.total,"error":job.error})
}

fn start_download(value: &Value) -> Result<Value, ApiError> {
    let dir = app_dir(value)?;
    let mut shared = state().lock().expect("update state");
    if shared
        .job
        .as_ref()
        .is_some_and(|j| matches!(j.phase, "downloading" | "extracting" | "verifying"))
    {
        return Err(error(ErrorCode::Busy, "update_busy"));
    }
    let (manifest, base) = shared
        .checked
        .clone()
        .ok_or_else(|| error(ErrorCode::NotFound, "update_check_first"))?;
    if value["release"].as_u64() != Some(u64::from(manifest.release)) {
        return Err(error(ErrorCode::StaleRevision, "update_check_first"));
    }
    shared.sequence += 1;
    let id = shared.sequence;
    let job = Job {
        id,
        phase: "downloading",
        received: Arc::new(AtomicU64::new(0)),
        total: manifest.package.bytes,
        cancel: Arc::new(AtomicBool::new(false)),
        error: None,
    };
    let (received, cancel) = (Arc::clone(&job.received), Arc::clone(&job.cancel));
    let response = snapshot(&job);
    shared.job = Some(job);
    drop(shared);
    let set_phase = move |p: &'static str| {
        if let Some(j) = state().lock().expect("update state").job.as_mut()
            && j.id == id
        {
            j.phase = p;
        }
    };
    std::thread::Builder::new()
        .name("app-update-download".into())
        .spawn(move || {
            let result = download(&dir, &manifest, &base, &received, &cancel, &set_phase);
            let mut shared = state().lock().expect("update state");
            if let Some(j) = shared.job.as_mut().filter(|j| j.id == id) {
                match result {
                    Ok(()) => j.phase = "completed",
                    Err(e) if e.next_action == "update_cancelled" => j.phase = "cancelled",
                    Err(e) => {
                        j.phase = "failed";
                        j.error = Some(e.next_action);
                    }
                }
            }
        })
        .map_err(|_| error(ErrorCode::Internal, "update_busy"))?;
    Ok(response)
}

fn job_action(value: &Value, cancel: bool) -> Result<Value, ApiError> {
    let mut shared = state().lock().expect("update state");
    let job = shared
        .job
        .as_mut()
        .filter(|j| Some(j.id) == value["job_id"].as_u64())
        .ok_or_else(|| error(ErrorCode::NotFound, "update_job_missing"))?;
    if cancel && matches!(job.phase, "downloading" | "extracting" | "verifying") {
        job.cancel.store(true, Ordering::Relaxed);
    }
    Ok(snapshot(job))
}

/// 复制更新程序到 `.update\run\` 并启动；主程序随后自行退出。
fn launch(value: &Value) -> Result<Value, ApiError> {
    let dir = app_dir(value)?;
    let w = work(&dir);
    let mode = match value["mode"].as_str() {
        Some(m @ ("update" | "rollback")) => m,
        _ => return Err(error(ErrorCode::InvalidRule, "update_mode_invalid")),
    };
    let source = w.join(if mode == "update" {
        "staging"
    } else {
        "backup"
    });
    if !source.join(APP_EXE).is_file() {
        return Err(error(
            ErrorCode::NotFound,
            if mode == "update" {
                "update_not_ready"
            } else {
                "update_no_backup"
            },
        ));
    }
    if state()
        .lock()
        .expect("update state")
        .job
        .as_ref()
        .is_some_and(|j| matches!(j.phase, "downloading" | "extracting" | "verifying"))
    {
        return Err(error(ErrorCode::Busy, "update_busy"));
    }
    let installed = dir.join(UPDATER_EXE);
    if !installed.is_file() {
        return Err(error(ErrorCode::NotFound, "update_updater_missing"));
    }
    let run = w.join("run");
    fs::create_dir_all(&run).map_err(|_| error(ErrorCode::Io, "update_app_dir_not_writable"))?;
    let copy = run.join(UPDATER_EXE);
    fs::copy(&installed, &copy).map_err(|_| error(ErrorCode::Io, "update_app_dir_not_writable"))?;
    let mut cmd = std::process::Command::new(&copy);
    cmd.args([
        "--mode",
        mode,
        "--pid",
        &std::process::id().to_string(),
        "--app-dir",
        &dir.to_string_lossy(),
    ])
    .current_dir(&run);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(DETACHED_PROCESS | CREATE_NO_WINDOW);
    }
    cmd.spawn()
        .map_err(|_| error(ErrorCode::Io, "update_launch_failed"))?;
    Ok(json!({"launched":true,"mode":mode}))
}

pub(crate) fn run(value: Value) -> Result<String, ApiError> {
    let response = match value["action"].as_str() {
        Some("status") => status(&app_dir(&value)?),
        Some("check") => check(&value)?,
        Some("download") => start_download(&value)?,
        Some("poll") => job_action(&value, false)?,
        Some("cancel") => job_action(&value, true)?,
        Some("launch") => launch(&value)?,
        _ => return Err(error(ErrorCode::InvalidRule, "update_action_invalid")),
    };
    Ok(response.to_string())
}

#[cfg(test)]
#[path = "app_update_tests.rs"]
mod tests;
