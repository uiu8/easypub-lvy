#[cfg(windows)]
fn main() {
    use easypub_app::kindling_export::{self, Control};
    use easypub_core::{
        ErrorCode,
        source::{RULE_ID, SourceSnapshot},
    };
    use serde_json::{Value, json};
    use std::{
        fs,
        path::PathBuf,
        sync::Arc,
        time::{Duration, Instant},
    };
    let args: Vec<_> = std::env::args().collect();
    let root = PathBuf::from(&args[1]);
    fs::create_dir(&root).unwrap();
    let root = root.canonicalize().unwrap();
    let engine = PathBuf::from(&args[2]).canonicalize().unwrap();
    let original = fs::read(&args[3]).unwrap();
    let source_path = root.join("source.txt");
    fs::write(&source_path, &original).unwrap();
    let source = SourceSnapshot::from_utf8(original.clone(), RULE_ID, || false).unwrap();
    let cover = root.join("cover.png");
    image::RgbaImage::from_pixel(600, 900, image::Rgba([190, 180, 160, 255]))
        .save(&cover)
        .unwrap();
    let format = args.get(4).map(String::as_str).unwrap_or("azw3");
    let output = root.join(format!("book.{format}"));
    let mut request = json!({"op":"preview","format":format,"source_path":source_path,"output_path":output,"engine_path":engine,
      "publication":{"source_id":source.summary().source_id,"revision":1,"settings":{"title":"受控转换验证","author":"测试",
      "description":"中文简介","language":"zh-CN","publisher":"青石书局","translator":"译者","isbn":"9781234567897","category":"小说","publication_date":"2026-09-30","cover_path":cover,"cover_fit":"contain","font_family":"SimSun","font_size":18,
      "line_height":1.8,"include_toc":true,"visible_toc":true,"illustrations":[]}}});
    let execute = |request: &Value, control: &Control| {
        kindling_export::execute(
            &source,
            kindling_export::parse(&request.to_string()).unwrap(),
            control,
        )
    };
    let initial_count = fs::read_dir(&root).unwrap().count();
    let preview = execute(&request, &Control::default()).unwrap();
    assert_eq!(fs::read_dir(&root).unwrap().count(), initial_count);
    request["op"] = json!("commit");
    request["plan_id"] = preview["plan_id"].clone();
    assert_eq!(
        execute(&request, &Control::default()).unwrap_err().code,
        ErrorCode::InvalidRule
    );
    request["confirmed"] = json!(true);
    let mut stale = request.clone();
    stale["publication"]["settings"]["title"] = json!("changed");
    assert_eq!(
        execute(&stale, &Control::default()).unwrap_err().code,
        ErrorCode::StaleRevision
    );
    stale = request.clone();
    stale["output_path"] = json!(root.join(format!("changed.{format}")));
    assert_eq!(
        execute(&stale, &Control::default()).unwrap_err().code,
        ErrorCode::StaleRevision
    );
    let control = Control::default();
    assert!(control.cancel());
    assert_eq!(
        execute(&request, &control).unwrap_err().code,
        ErrorCode::Cancelled
    );
    assert_eq!(fs::read_dir(&root).unwrap().count(), initial_count);
    fs::write(&source_path, b"changed").unwrap();
    assert_eq!(
        execute(&request, &Control::default()).unwrap_err().code,
        ErrorCode::SourceChanged
    );
    fs::write(&source_path, &original).unwrap();
    // Cancel at the process stage, after input staging. No final file may appear.
    let control = Arc::new(Control::default());
    let other = control.clone();
    let watcher = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let snapshot = other.snapshot();
            if snapshot["phase"] == "converting" {
                assert!(other.cancel());
                break;
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(1));
        }
    });
    assert_eq!(
        execute(&request, &control).unwrap_err().code,
        ErrorCode::Cancelled
    );
    watcher.join().unwrap();
    assert!(!output.exists());
    let control = Control::default();
    let result = execute(&request, &control).unwrap();
    assert!(result["committed"].as_bool().unwrap());
    assert!(!control.cancel());
    assert_eq!(control.snapshot()["phase"], "completed");
    assert_eq!(fs::read(&source_path).unwrap(), original);
    let txn = PathBuf::from(result["transaction"]["transaction_dir"].as_str().unwrap());
    assert_eq!(fs::read(txn.join("source-backup.bin")).unwrap(), original);
    assert!(txn.join("edit-evidence.json").is_file());
    let bytes = fs::read(&output).unwrap();
    assert_eq!(
        execute(&request, &Control::default()).unwrap_err().code,
        ErrorCode::OutputConflict
    );
    assert_eq!(fs::read(&output).unwrap(), bytes);
    // The same export request runs asynchronously and exposes terminal results.
    let manager = easypub_app::kindling_jobs::Manager::default();
    let job_source =
        Arc::new(SourceSnapshot::from_utf8(original.clone(), RULE_ID, || false).unwrap());
    let wait = |id| {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let status = manager.status(id).unwrap();
            if status["terminal"] == true {
                break status;
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        }
    };
    request["op"] = json!("preview");
    request["output_path"] = json!(root.join(format!("job.{format}")));
    let id = manager
        .start(
            job_source.clone(),
            kindling_export::parse(&request.to_string()).unwrap(),
        )
        .unwrap();
    let status = wait(id);
    assert_eq!(status["phase"], "completed");
    request["plan_id"] = status["result"]["plan_id"].clone();
    request["op"] = json!("commit");
    assert!(!manager.cancel(id).unwrap());
    manager.forget(id).unwrap();
    assert_eq!(manager.status(id).unwrap_err().code, ErrorCode::NotFound);
    let id = manager
        .start(
            job_source.clone(),
            kindling_export::parse(&request.to_string()).unwrap(),
        )
        .unwrap();
    assert_eq!(manager.forget(id).unwrap_err().code, ErrorCode::Busy);
    assert!(manager.cancel(id).unwrap());
    assert_eq!(wait(id)["phase"], "cancelled");
    assert!(!root.join(format!("job.{format}")).exists());
    manager.forget(id).unwrap();
    let id = manager
        .start(
            job_source,
            kindling_export::parse(&request.to_string()).unwrap(),
        )
        .unwrap();
    let status = wait(id);
    assert_eq!(status["phase"], "completed");
    assert_eq!(status["result"]["committed"], true);
    manager.forget(id).unwrap();
    let report = json!({"passed":true,"preview_zero_write":true,"requires_confirmation":true,"stale_title_and_path":true,
        "source_change_rejected":true,"pre_cancel_zero_write":true,"conversion_cancel_no_publication":true,
        "source_and_backup_unchanged":true,"existing_output_unchanged":true,"transaction_evidence":true,
        "late_cancel_rejected":true,"async_preview_commit_cancel_forget":true,"result":result,"reader_verified":false});
    fs::write(
        root.join("report.json"),
        serde_json::to_vec_pretty(&report).unwrap(),
    )
    .unwrap();
    println!("{report}");
}
#[cfg(not(windows))]
fn main() {
    panic!("Windows only");
}
