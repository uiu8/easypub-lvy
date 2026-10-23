//! V68 自动更新（SET-071–073）：更新清单与签名校验、程序目录替换。
//! 主程序（easypub_app::app_update）用前半部分检查和下载；easypub_updater.exe 用后半部分替换文件。
use ed25519_dalek::{Signature, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    fs,
    io::Write,
    path::{Path, PathBuf},
    thread,
    time::Duration,
};

pub const PRODUCT: &str = "easypub-lvy";
pub const MANIFEST_NAME: &str = "update-manifest.json";
pub const SIGNATURE_NAME: &str = "update-manifest.json.sig";
pub const UPDATER_EXE: &str = "easypub_updater.exe";
pub const APP_EXE: &str = "easypub_desktop.exe";
/// 程序目录下的更新工作区：下载、解压、备份、日志都在这里，替换时不会被移走。
pub const WORK_DIR: &str = ".update";

/// 发布签名公钥（Ed25519）。私钥只在发布者本机（见 docs/V68 说明），不进仓库。
pub const PUBLIC_KEYS: &[[u8; 32]] = &[RELEASE_KEY];
/// 2026-10-17 生成；私钥在发布者的 %USERPROFILE%\.easypub-lvy\release-signing.key。
const RELEASE_KEY: [u8; 32] = [
    0xf5, 0x91, 0xce, 0xdb, 0xf0, 0x11, 0x36, 0x5b, 0xad, 0xb4, 0x22, 0x58, 0xb1, 0x7d, 0xe4, 0xed,
    0xf2, 0xfe, 0x31, 0x4d, 0x18, 0x8a, 0x2f, 0x34, 0x03, 0xbf, 0xd3, 0xe3, 0x7c, 0xbd, 0x99, 0x60,
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpdateError(pub &'static str);

impl std::fmt::Display for UpdateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PackageFile {
    /// Release 附件名，例如 easypub-lvy-v68-20261017-win-x64.zip。
    pub name: String,
    pub bytes: u64,
    pub sha256: String,
    /// 压缩包内的顶层文件夹名。
    pub root: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub schema: u32,
    pub product: String,
    /// 批次号，新旧版本按它比较。
    pub release: u32,
    pub tag: String,
    pub date: String,
    pub package: PackageFile,
    /// 本版更新说明（纯文本）。
    pub notes: String,
}

fn safe_name(s: &str, max: usize) -> bool {
    !s.is_empty()
        && s.len() <= max
        && s != "."
        && s != ".."
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

fn is_sha256(s: &str) -> bool {
    s.len() == 64
        && s.chars()
            .all(|c| c.is_ascii_digit() || matches!(c, 'a'..='f'))
}

impl Manifest {
    pub fn validate(&self) -> Result<(), UpdateError> {
        let p = &self.package;
        if self.schema != 1
            || self.product != PRODUCT
            || self.release == 0
            || !safe_name(&self.tag, 64)
            || !safe_name(&self.date, 32)
            || !safe_name(&p.name, 128)
            || !p.name.ends_with(".zip")
            || !safe_name(&p.root, 128)
            || !is_sha256(&p.sha256)
            || p.bytes == 0
            || p.bytes > 1024 * 1024 * 1024
            || self.notes.len() > 64 * 1024
        {
            return Err(UpdateError("update_manifest_invalid"));
        }
        Ok(())
    }
}

pub fn sha256_hex(data: &[u8]) -> String {
    hex(&Sha256::digest(data))
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub fn unhex(s: &str) -> Option<Vec<u8>> {
    let s = s.trim();
    if !s.len().is_multiple_of(2) {
        return None;
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(s.get(i..i + 2)?, 16).ok())
        .collect()
}

/// 校验清单签名（任一公钥通过即可），再解析并检查字段。签名覆盖清单文件的原始字节。
pub fn verify_manifest(
    bytes: &[u8],
    signature_hex: &str,
    keys: &[[u8; 32]],
) -> Result<Manifest, UpdateError> {
    if bytes.len() > 128 * 1024 {
        return Err(UpdateError("update_manifest_invalid"));
    }
    let signature = unhex(signature_hex)
        .and_then(|b| <[u8; 64]>::try_from(b).ok())
        .map(|b| Signature::from_bytes(&b))
        .ok_or(UpdateError("update_signature_invalid"))?;
    let trusted = keys.iter().any(|k| {
        VerifyingKey::from_bytes(k).is_ok_and(|key| key.verify_strict(bytes, &signature).is_ok())
    });
    if !trusted {
        return Err(UpdateError("update_signature_invalid"));
    }
    let manifest: Manifest =
        serde_json::from_slice(bytes).map_err(|_| UpdateError("update_manifest_invalid"))?;
    manifest.validate()?;
    Ok(manifest)
}

/// 本机版本号：version.json 的 release 字段；V68 之前的包没有这个字段，从包名里的 “-vNN-” 取。
pub fn release_of(version: &serde_json::Value) -> Option<u32> {
    if let Some(n) = version["release"].as_u64() {
        return u32::try_from(n).ok();
    }
    let name = version["package"]
        .as_str()
        .or_else(|| version["version"].as_str())?;
    name.split('-').find_map(|part| {
        part.strip_prefix('v')
            .filter(|d| !d.is_empty() && d.chars().all(|c| c.is_ascii_digit()))
            .and_then(|d| d.parse().ok())
    })
}

pub fn read_release(dir: &Path) -> Option<u32> {
    let text = fs::read_to_string(dir.join("version.json")).ok()?;
    release_of(&serde_json::from_str(&text).ok()?)
}

/// 本次替换要移走的旧顶层项与要移入的新顶层项。旧项取自旧版 package-manifest.json 的文件清单，
/// 不在清单里的（用户自己放的文件）不动；没有清单时只替换新版里同名的项。
pub fn plan_swap(app_dir: &Path, source: &Path) -> Result<(Vec<String>, Vec<String>), UpdateError> {
    let mut incoming = BTreeSet::new();
    for entry in fs::read_dir(source).map_err(|_| UpdateError("update_staging_missing"))? {
        let name = entry
            .map_err(|_| UpdateError("update_staging_missing"))?
            .file_name()
            .into_string()
            .map_err(|_| UpdateError("update_staging_invalid"))?;
        if name != WORK_DIR {
            incoming.insert(name);
        }
    }
    if !incoming.contains(APP_EXE) {
        return Err(UpdateError("update_staging_invalid"));
    }
    let mut old: BTreeSet<String> = incoming.clone();
    if let Ok(text) = fs::read_to_string(app_dir.join("package-manifest.json"))
        && let Ok(v) = serde_json::from_str::<serde_json::Value>(&text)
    {
        old.insert("package-manifest.json".into());
        for f in v["files"].as_array().into_iter().flatten() {
            if let Some(top) = f["path"]
                .as_str()
                .and_then(|p| p.split(['/', '\\']).next())
                .filter(|t| !t.is_empty() && *t != WORK_DIR && *t != "." && *t != "..")
            {
                old.insert(top.into());
            }
        }
    }
    let outgoing = old
        .into_iter()
        .filter(|n| app_dir.join(n).symlink_metadata().is_ok())
        .collect();
    Ok((outgoing, incoming.into_iter().collect()))
}

/// 改名；杀毒软件或资源管理器可能短暂占用，重试几次。
fn rename(from: &Path, to: &Path) -> std::io::Result<()> {
    let mut last = None;
    for _ in 0..25 {
        match fs::rename(from, to) {
            Ok(()) => return Ok(()),
            Err(e) => last = Some(e),
        }
        thread::sleep(Duration::from_millis(200));
    }
    Err(last.expect("rename error"))
}

#[derive(Serialize, Deserialize, Default)]
struct Journal {
    moves: Vec<(PathBuf, PathBuf)>,
}

fn save_journal(log: &Journal, journal: &Path) -> Result<(), UpdateError> {
    let temporary = journal.with_extension("json.tmp");
    let result = (|| {
        let mut file = fs::File::create(&temporary)?;
        file.write_all(&serde_json::to_vec(log).expect("journal"))?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temporary, journal)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result.map_err(|_| UpdateError("update_journal_failed"))
}

/// 用 [source] 里的内容替换 [app_dir] 的程序文件，旧文件移到 [backup]（不能已存在）。
/// 每一步先写日志；中途失败时按日志倒序撤回，程序目录恢复原样。
pub fn swap(
    app_dir: &Path,
    source: &Path,
    backup: &Path,
    journal: &Path,
) -> Result<(), UpdateError> {
    swap_with(app_dir, source, backup, journal, |_| Ok(()))
}

/// [fail] 供测试在第 N 步注入失败。
pub fn swap_with(
    app_dir: &Path,
    source: &Path,
    backup: &Path,
    journal: &Path,
    fail: impl Fn(usize) -> Result<(), ()>,
) -> Result<(), UpdateError> {
    let (outgoing, incoming) = plan_swap(app_dir, source)?;
    if backup.exists() {
        return Err(UpdateError("update_backup_exists"));
    }
    fs::create_dir_all(backup).map_err(|_| UpdateError("update_backup_failed"))?;
    let mut log = Journal::default();
    let mut steps = outgoing
        .iter()
        .map(|n| (app_dir.join(n), backup.join(n)))
        .chain(incoming.iter().map(|n| (source.join(n), app_dir.join(n))))
        .enumerate();
    let result = steps.try_for_each(|(i, (from, to))| {
        log.moves.push((from.clone(), to.clone()));
        save_journal(&log, journal)?;
        fail(i).map_err(|_| UpdateError("update_replace_failed"))?;
        rename(&from, &to).map_err(|_| UpdateError("update_replace_failed"))?;
        Ok(())
    });
    if let Err(e) = result {
        if undo(&mut log, journal) {
            let _ = fs::remove_file(journal);
            let _ = fs::remove_dir(backup);
        }
        return Err(e);
    }
    let _ = fs::remove_file(journal);
    Ok(())
}

fn undo(log: &mut Journal, journal: &Path) -> bool {
    while let Some((from, to)) = log.moves.last() {
        // 未执行的预写记录，或回滚移动后尚未来得及更新日志。
        if (to.exists() || !from.exists()) && (from.exists() || rename(to, from).is_err()) {
            return false;
        }
        log.moves.pop();
        // 每撤回一步都持久化进度，避免重试时把已恢复的旧文件当成新版。
        if save_journal(log, journal).is_err() {
            return false;
        }
    }
    true
}

/// 更新程序上次中途退出（例如断电）留下的日志：倒序撤回，恢复旧版本。
pub fn recover(journal: &Path) -> bool {
    let Ok(bytes) = fs::read(journal) else {
        return false;
    };
    let Ok(mut log) = serde_json::from_slice::<Journal>(&bytes) else {
        return false;
    };
    if !undo(&mut log, journal) {
        return false;
    }
    let _ = fs::remove_file(journal);
    true
}

#[cfg(test)]
mod tests;
