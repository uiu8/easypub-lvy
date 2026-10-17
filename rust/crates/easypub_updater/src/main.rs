//! easypub_updater.exe（V68，SET-073）：主程序退出后替换程序文件，再打开程序。
//! 由主程序从 `.update\run\` 启动（不在被替换的目录里运行，避免锁住自己）：
//!   easypub_updater.exe --mode update|rollback --pid <主程序进程号> --app-dir <程序目录>
//! update：用 `.update\staging` 替换；rollback：用 `.update\backup` 换回上一版。
//! 任一步失败都撤回，程序目录恢复原样，并照常打开（旧版）程序。
#![cfg_attr(not(test), windows_subsystem = "windows")]
use easypub_updater::{APP_EXE, WORK_DIR, read_release, recover, swap};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

struct Args {
    mode: String,
    pid: u32,
    app_dir: PathBuf,
}

fn args() -> Option<Args> {
    let mut it = std::env::args().skip(1);
    let (mut mode, mut pid, mut app_dir) = (None, None, None);
    while let Some(k) = it.next() {
        let v = it.next()?;
        match k.as_str() {
            "--mode" => mode = Some(v),
            "--pid" => pid = v.parse().ok(),
            "--app-dir" => app_dir = Some(PathBuf::from(v)),
            _ => return None,
        }
    }
    let mode = mode.filter(|m| m == "update" || m == "rollback")?;
    Some(Args {
        mode,
        pid: pid?,
        app_dir: app_dir?,
    })
}

fn log(work: &Path, line: &str) {
    if let Ok(mut f) = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(work.join("updater.log"))
    {
        let _ = writeln!(
            f,
            "{} {line}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_secs())
        );
    }
}

/// 等主程序退出，最多 2 分钟。
#[cfg(windows)]
fn wait_for(pid: u32) -> bool {
    use windows_sys::Win32::{
        Foundation::{CloseHandle, WAIT_OBJECT_0},
        System::Threading::{OpenProcess, PROCESS_SYNCHRONIZE, WaitForSingleObject},
    };
    // SAFETY: 只对按进程号打开的句柄做等待并关闭。
    unsafe {
        let handle = OpenProcess(PROCESS_SYNCHRONIZE, 0, pid);
        if handle.is_null() {
            return true; // 已经退出
        }
        let done = WaitForSingleObject(handle, 120_000) == WAIT_OBJECT_0;
        CloseHandle(handle);
        done
    }
}

#[cfg(not(windows))]
fn wait_for(_pid: u32) -> bool {
    true
}

fn launch(app_dir: &Path) {
    let mut cmd = std::process::Command::new(app_dir.join(APP_EXE));
    cmd.current_dir(app_dir);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        cmd.creation_flags(DETACHED_PROCESS);
    }
    let _ = cmd.spawn();
}

/// 执行替换；返回写入日志的结果说明。
pub fn run(mode: &str, app_dir: &Path) -> Result<String, String> {
    let work = app_dir.join(WORK_DIR);
    let journal = work.join("journal.json");
    if recover(&journal) {
        log(&work, "recovered an interrupted replacement");
    }
    let (source, backup) = (
        work.join(if mode == "update" {
            "staging"
        } else {
            "backup"
        }),
        work.join("backup-new"),
    );
    let _ = fs::remove_dir_all(&backup);
    let from = read_release(app_dir);
    let to = read_release(&source);
    swap(app_dir, &source, &backup, &journal).map_err(|e| e.0.to_owned())?;
    // 只保留上一版一份：新备份取代旧备份。
    let _ = fs::remove_dir_all(&source);
    let old = work.join("backup");
    let _ = fs::remove_dir_all(&old);
    if fs::rename(&backup, &old).is_err() {
        log(
            &work,
            "backup rename failed; previous version kept in backup-new",
        );
    }
    let _ = fs::remove_file(work.join("ready.json"));
    let _ = fs::write(
        work.join("state.json"),
        serde_json::json!({"mode":mode,"from":from,"to":to}).to_string(),
    );
    Ok(format!("{mode} {from:?} -> {to:?}"))
}

fn main() {
    let Some(a) = args() else {
        std::process::exit(2);
    };
    let work = a.app_dir.join(WORK_DIR);
    let _ = fs::create_dir_all(&work);
    let started = Instant::now();
    if !wait_for(a.pid) {
        log(
            &work,
            "main program did not exit within 2 minutes; nothing replaced",
        );
        std::process::exit(3);
    }
    // 进程句柄结束后，文件锁可能还要片刻才释放。
    std::thread::sleep(Duration::from_millis(300));
    match run(&a.mode, &a.app_dir) {
        Ok(msg) => log(
            &work,
            &format!("ok {msg} in {} ms", started.elapsed().as_millis()),
        ),
        Err(e) => {
            log(&work, &format!("failed {e}; previous version restored"));
            let _ = fs::write(
                work.join("state.json"),
                serde_json::json!({"mode":a.mode,"error":e}).to_string(),
            );
        }
    }
    launch(&a.app_dir);
}
