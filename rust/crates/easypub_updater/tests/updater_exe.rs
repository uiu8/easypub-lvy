//! 运行真实的 easypub_updater.exe：等“主程序”退出后替换，再回退。
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    time::Instant,
};

fn temp() -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "easypub-updater-exe-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn write(root: &Path, files: &[(&str, &str)]) {
    for (p, t) in files {
        let p = root.join(p);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, t).unwrap();
    }
}

fn read(p: PathBuf) -> String {
    fs::read_to_string(p).unwrap_or_default()
}

#[test]
fn updater_waits_for_the_main_program_replaces_files_and_can_roll_back() {
    let app = temp().join("app");
    write(
        &app,
        &[
            ("easypub_desktop.exe", "old exe"),
            ("a.dll", "old a"),
            ("version.json", r#"{"release":67}"#),
            (
                "package-manifest.json",
                r#"{"files":[{"path":"easypub_desktop.exe"},{"path":"a.dll"},{"path":"version.json"}]}"#,
            ),
            ("用户文件.txt", "keep"),
        ],
    );
    write(
        &app.join(".update/staging"),
        &[
            ("easypub_desktop.exe", "new exe"),
            ("a.dll", "new a"),
            ("version.json", r#"{"release":68}"#),
            ("package-manifest.json", r#"{"files":[]}"#),
        ],
    );
    // “主程序”：约 1.5 秒后退出。
    let mut main = Command::new("cmd")
        .args(["/C", "ping -n 3 127.0.0.1 >NUL"])
        .spawn()
        .unwrap();
    let started = Instant::now();
    let status = Command::new(env!("CARGO_BIN_EXE_easypub_updater"))
        .args([
            "--mode",
            "update",
            "--pid",
            &main.id().to_string(),
            "--app-dir",
        ])
        .arg(&app)
        .status()
        .unwrap();
    assert!(status.success());
    assert!(
        main.try_wait().unwrap().is_some(),
        "更新程序在主程序退出后才开始"
    );
    assert!(started.elapsed().as_millis() >= 1000);
    assert_eq!(read(app.join("easypub_desktop.exe")), "new exe");
    assert_eq!(read(app.join("a.dll")), "new a");
    assert_eq!(read(app.join("用户文件.txt")), "keep");
    assert_eq!(
        read(app.join(".update/backup/easypub_desktop.exe")),
        "old exe"
    );
    assert!(!app.join(".update/staging").exists());
    let state: serde_json::Value =
        serde_json::from_str(&read(app.join(".update/state.json"))).unwrap();
    assert_eq!(state["from"], 67);
    assert_eq!(state["to"], 68);
    assert!(read(app.join(".update/updater.log")).contains("ok update"));

    // 回退：换回上一版；刚才的新版变成备份。
    let status = Command::new(env!("CARGO_BIN_EXE_easypub_updater"))
        .args(["--mode", "rollback", "--pid", "0", "--app-dir"])
        .arg(&app)
        .status()
        .unwrap();
    assert!(status.success());
    assert_eq!(read(app.join("easypub_desktop.exe")), "old exe");
    assert_eq!(read(app.join("version.json")), r#"{"release":67}"#);
    assert_eq!(
        read(app.join(".update/backup/easypub_desktop.exe")),
        "new exe"
    );
    assert_eq!(read(app.join("用户文件.txt")), "keep");

    // 参数不全：什么都不做。
    let status = Command::new(env!("CARGO_BIN_EXE_easypub_updater"))
        .args(["--mode", "update"])
        .status()
        .unwrap();
    assert_eq!(status.code(), Some(2));
    fs::remove_dir_all(app.parent().unwrap()).unwrap();
}
