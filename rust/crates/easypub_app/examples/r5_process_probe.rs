#[cfg(windows)]
fn main() {
    use easypub_app::managed_process::{Outcome, run};
    use std::{
        ffi::OsStr,
        fs,
        io::Write,
        path::PathBuf,
        process::Command,
        time::{Duration, Instant},
    };
    use windows_sys::Win32::{Foundation::*, System::Threading::*};
    let args: Vec<_> = std::env::args().collect();
    let exe = std::env::current_exe().unwrap();
    if let Some(mode) = args.get(1).filter(|s| s.starts_with("worker-")) {
        match mode.as_str() {
            "worker-echo" => println!("{}", serde_json::to_string(&args[2..]).unwrap()),
            "worker-exit" => std::process::exit(7),
            "worker-flood" => {
                std::io::stdout()
                    .write_all(&vec![b'x'; 17 * 1024 * 1024])
                    .unwrap();
                std::io::stdout().flush().unwrap();
                std::thread::sleep(Duration::from_secs(60));
            }
            "worker-sleep" => std::thread::sleep(Duration::from_secs(60)),
            "worker-tree" | "worker-orphan" => {
                // 探针故意留下子进程（孤儿进程场景），不等待它结束。
                #[allow(clippy::zombie_processes)]
                let child = Command::new(&exe).arg("worker-sleep").spawn().unwrap();
                println!("child:{}", child.id());
                std::io::stdout().flush().unwrap();
                if mode == "worker-tree" {
                    std::thread::sleep(Duration::from_secs(60));
                }
            }
            _ => panic!("unknown mode"),
        }
        return;
    }
    let root = PathBuf::from(&args[1]);
    fs::create_dir(&root).unwrap();
    let root = root.canonicalize().unwrap();
    let timeout = Duration::from_secs(10);
    let log = root.join("pre-cancel.log");
    assert_eq!(
        run(&exe, &[], &root, &log, timeout, || true).unwrap(),
        Outcome::Cancelled
    );
    assert!(!log.exists());
    let log = root.join("echo.log");
    let values = ["", "中文 空格", "trailing\\", "a\\\"b", "&$(nothing)"];
    let mut argv = vec![OsStr::new("worker-echo")];
    argv.extend(values.iter().map(OsStr::new));
    assert_eq!(
        run(&exe, &argv, &root, &log, timeout, || false).unwrap(),
        Outcome::Exited(0)
    );
    assert_eq!(
        serde_json::from_str::<Vec<String>>(fs::read_to_string(&log).unwrap().trim()).unwrap(),
        values
    );
    let original_log = fs::read(&log).unwrap();
    assert!(run(&exe, &argv, &root, &log, timeout, || false).is_err());
    assert_eq!(fs::read(&log).unwrap(), original_log);
    assert_eq!(
        run(
            &exe,
            &[OsStr::new("worker-flood")],
            &root,
            &root.join("flood.log"),
            timeout,
            || false
        )
        .unwrap(),
        Outcome::LogLimit
    );
    assert_eq!(
        run(
            &exe,
            &[OsStr::new("worker-exit")],
            &root,
            &root.join("exit.log"),
            timeout,
            || false
        )
        .unwrap(),
        Outcome::Exited(7)
    );
    assert_eq!(
        run(
            &exe,
            &[OsStr::new("worker-sleep")],
            &root,
            &root.join("timeout.log"),
            Duration::from_millis(100),
            || false
        )
        .unwrap(),
        Outcome::TimedOut
    );
    let mut pids = Vec::new();
    for mode in ["worker-tree", "worker-orphan"] {
        let log = root.join(format!("{mode}.log"));
        let start = Instant::now();
        let outcome = run(&exe, &[OsStr::new(mode)], &root, &log, timeout, || {
            mode == "worker-tree"
                && fs::read_to_string(&log)
                    .unwrap_or_default()
                    .contains("child:")
        })
        .unwrap();
        assert_eq!(
            outcome,
            if mode == "worker-tree" {
                Outcome::Cancelled
            } else {
                Outcome::Exited(0)
            }
        );
        assert!(start.elapsed() < timeout);
        let text = fs::read_to_string(&log).unwrap();
        let pid: u32 = text.trim().strip_prefix("child:").unwrap().parse().unwrap();
        unsafe {
            let handle = OpenProcess(
                PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
                0,
                pid,
            );
            if !handle.is_null() {
                assert_eq!(WaitForSingleObject(handle, 0), WAIT_OBJECT_0);
                CloseHandle(handle);
            } else {
                assert_eq!(GetLastError(), ERROR_INVALID_PARAMETER);
            }
        }
        pids.push(pid);
    }
    let mut actual_kindling = serde_json::Value::Null;
    if args.len() > 3 {
        use sha2::{Digest, Sha256};
        let engine = PathBuf::from(&args[2]).canonicalize().unwrap();
        let input = PathBuf::from(&args[3]).canonicalize().unwrap();
        let output = root.join("kindling-output.azw3");
        let log = root.join("kindling.log");
        let outcome = run(
            &engine,
            &[
                OsStr::new("build"),
                input.as_os_str(),
                OsStr::new("-o"),
                output.as_os_str(),
            ],
            &root,
            &log,
            Duration::from_secs(120),
            || false,
        )
        .unwrap();
        assert_eq!(outcome, Outcome::Exited(0));
        let bytes = fs::read(&output).unwrap();
        assert_eq!(&bytes[60..68], b"BOOKMOBI");
        assert!(
            fs::read_to_string(&log)
                .unwrap()
                .contains("19 P0 checks passed")
        );
        actual_kindling = serde_json::json!({"output":output,"bytes":bytes.len(),"sha256":format!("{:x}",Sha256::digest(&bytes)),"log":log});
    }
    let report = serde_json::json!({"passed":true,"pre_cancel_no_write":true,"argument_roundtrip":true,
        "existing_log_preserved":true,"log_budget_termination":true,"nonzero_exit":true,"timeout":true,"cancelled_tree":true,
        "orphan_descendant_terminated":true,"checked_child_pids":pids,"artifact_directory":root,"actual_kindling":actual_kindling});
    fs::write(
        root.join("report.json"),
        serde_json::to_vec_pretty(&report).unwrap(),
    )
    .unwrap();
    println!("{report}");
}
#[cfg(not(windows))]
fn main() {
    panic!("Windows process probe requires Windows");
}
