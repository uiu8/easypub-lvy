use easypub_core::{
    cleanup,
    source::{RULE_ID, SourceSnapshot},
};
use serde_json::json;
use std::time::Instant;

fn main() {
    let line = "这是连续排版的一行文字";
    let raw = format!(
        "第一章 性能样本\r\n{}",
        format!("{line}\r\n").repeat(20_000)
    );
    let source = SourceSnapshot::from_utf8(raw.as_bytes().to_vec(), RULE_ID, || false).unwrap();
    let request = r#"{"kind":"cleanup","pipeline":[{"kind":"join_hard_wraps","mode":"chinese","min_chars":8}]}"#;
    let started = Instant::now();
    let plan = cleanup::prepare(&source, request).unwrap();
    let bytes = plan.output(&source).unwrap();
    let milliseconds = started.elapsed().as_secs_f64() * 1000.0;
    let expected = format!("第一章 性能样本\r\n{}\r\n", line.repeat(20_000));
    assert_eq!(bytes, expected.as_bytes());
    assert_eq!(source.original_bytes(), raw.as_bytes());
    let evidence: serde_json::Value = serde_json::from_slice(&plan.evidence()).unwrap();
    assert_eq!(evidence["changes"][0]["source_line"], 2);
    assert_eq!(evidence["changes"][0]["source_end_line"], 20_001);
    assert_eq!(
        evidence["source_to_output_lines"].as_array().unwrap().len(),
        20_001
    );
    println!(
        "{}",
        json!({"passed":true,"profile":"release","fixture":"synthetic single paragraph with 20000 wrapped source lines","source_bytes":raw.len(),"output_bytes":bytes.len(),"prepare_and_encode_ms":milliseconds,"source_lines":20001,"output_lines":2,"exact_output":true,"source_unchanged":true,"peak_memory_measured":false,"not_verified":"128MiB whole-book performance and general cross-line regex"})
    );
}
