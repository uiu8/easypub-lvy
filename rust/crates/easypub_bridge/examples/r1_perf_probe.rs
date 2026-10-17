use easypub_bridge::api::{
    cancel_job_text, job_status_text, read_chapter_page_text, read_source_page_text,
    start_cancellation_probe, start_import,
};
use easypub_core::source::RULE_ID;
use std::{
    fs::{self, File},
    io::Write,
    path::Path,
    time::{Duration, Instant},
};

fn make_fixture(path: &Path, target: usize) -> usize {
    let mut block = Vec::with_capacity(1024 * 1024);
    for line in 0..20_000_u32 {
        let text = if line % 1_000 == 0 {
            format!("第{}章 性能样本内容😀\r\n", line / 1_000 + 1)
        } else {
            "正文内容包含汉字𠮷和组合字符 é。\n".to_owned()
        };
        if block.len() + text.len() > 1024 * 1024 {
            break;
        }
        block.extend_from_slice(text.as_bytes());
    }
    let mut file = File::create(path).unwrap();
    let mut written = 0;
    while written + block.len() <= target {
        file.write_all(&block).unwrap();
        written += block.len();
    }
    let tail = "尾行\n".as_bytes();
    while written + tail.len() <= target {
        file.write_all(tail).unwrap();
        written += tail.len();
    }
    file.flush().unwrap();
    written
}

fn field(status: &str, key: &str) -> String {
    status
        .split(';')
        .find_map(|part| part.strip_prefix(&format!("{key}=")).map(str::to_owned))
        .unwrap_or_default()
}

fn terminal(status: &str) -> bool {
    status.contains("phase=Completed")
        || status.contains("phase=Failed")
        || status.contains("phase=Cancelled")
}

fn run_case(path: &Path, target: usize) -> String {
    let actual = make_fixture(path, target);
    let started = Instant::now();
    let job = start_import(path.display().to_string(), RULE_ID.to_owned()).unwrap();
    let mut status = String::new();
    while started.elapsed() < Duration::from_secs(120) {
        status = job_status_text(job).unwrap();
        if terminal(&status) {
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(status.contains("phase=Completed"), "{status}");
    let import_ms = started.elapsed().as_secs_f64() * 1000.0;
    let source_id = field(&status, "source_id");
    let revision = field(&status, "revision").parse::<u32>().unwrap();
    let page_started = Instant::now();
    let mut cursor_line = 0_u32;
    let mut page_count = 0_u32;
    let mut max_response = 0_usize;
    while page_count < 100 {
        let page = read_source_page_text(source_id.clone(), revision, cursor_line, 0, 200).unwrap();
        max_response = max_response.max(page.len());
        page_count += 1;
        if page.contains("next=None") {
            break;
        }
        cursor_line += 200;
    }
    let page_ms = page_started.elapsed().as_secs_f64() * 1000.0;
    let chapter_started = Instant::now();
    let chapter_response_bytes = read_chapter_page_text(source_id.clone(), revision, 0, 200)
        .unwrap()
        .len();
    let chapter_ms = chapter_started.elapsed().as_secs_f64() * 1000.0;
    assert!(
        max_response < 512 * 1024,
        "bridge response exceeded limit: {max_response}"
    );
    format!(
        "{{\"target_bytes\":{target},\"actual_bytes\":{actual},\"import_ms\":{import_ms:.3},\"source_id\":\"{source_id}\",\"lines\":{},\"chapters\":{},\"page_count\":{page_count},\"page_ms\":{page_ms:.3},\"chapter_page_ms\":{chapter_ms:.3},\"max_bridge_response_bytes\":{max_response},\"chapter_response_bytes\":{chapter_response_bytes}}}",
        field(&status, "lines"),
        field(&status, "chapters"),
    )
}

fn main() {
    let root = std::env::temp_dir().join(format!("easypub-r1-perf-{}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let small = run_case(&root.join("sample-20m.txt"), 20 * 1024 * 1024);
    let large = run_case(&root.join("sample-100m.txt"), 100 * 1024 * 1024);
    let cancel_started = Instant::now();
    let cancel_job = start_cancellation_probe().unwrap();
    let _ = cancel_job_text(cancel_job).unwrap();
    let mut cancel_status = job_status_text(cancel_job).unwrap();
    while !terminal(&cancel_status) && cancel_started.elapsed() < Duration::from_secs(5) {
        std::thread::sleep(Duration::from_millis(2));
        cancel_status = job_status_text(cancel_job).unwrap();
    }
    assert!(cancel_status.contains("phase=Cancelled"));
    let cancel_ms = cancel_started.elapsed().as_secs_f64() * 1000.0;
    println!(
        "{{\"scope\":\"R1-2c G6 in-process FRB API throughput probe (codec excluded)\",\"cases\":[{small},{large}],\"cancel_probe_ms\":{cancel_ms:.3},\"cancel_phase\":\"Cancelled\"}}"
    );
    let _ = fs::remove_dir_all(root);
}
