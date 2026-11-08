use easypub_core::{
    cleanup,
    source::{RULE_ID, SourceSnapshot},
};
use serde_json::json;
use std::time::Instant;

fn main() {
    let mut raw = String::new();
    let mut expected = String::new();
    for n in 1..=1000 {
        let heading = format!("第{n}章 性能样本\r\n");
        let unchanged = "不参与替换的完整正文段落。\n".repeat(20);
        raw.push_str(&format!("{heading}甲上\r\n甲下\n{unchanged}"));
        expected.push_str(&format!("{heading}合并\n新增\n第三行\n{unchanged}"));
    }
    let source = SourceSnapshot::from_utf8(raw.as_bytes().to_vec(), RULE_ID, || false).unwrap();
    let request = json!({"kind":"cleanup","pipeline":[{"kind":"multiline_regex_replace","pattern":r"甲上\r\n甲下","replace":r"合并\n新增\n第三行  "},{"kind":"trim_trailing_spaces"}]}).to_string();
    let start = Instant::now();
    let plan = cleanup::prepare(&source, &request).unwrap();
    let bytes = plan.output(&source).unwrap();
    let processing_ms = start.elapsed().as_secs_f64() * 1000.0;
    let evidence = plan.evidence();
    let processing_with_evidence_ms = start.elapsed().as_secs_f64() * 1000.0;
    assert_eq!(bytes, expected.as_bytes());
    assert_eq!(source.original_bytes(), raw.as_bytes());
    let doc: serde_json::Value = serde_json::from_slice(&evidence).unwrap();
    assert_eq!(doc["changes"].as_array().unwrap().len(), 1000);
    assert_eq!(
        doc["source_to_output_ranges"].as_array().unwrap().len(),
        22_000
    );
    assert_eq!(doc["source_to_output_ranges"][1]["mapping"], "region");
    println!(
        "{}",
        json!({"passed":true,"profile":"release","fixture":"1000 synthetic chapters, mixed endings and two-to-three body-line replacement", "source_bytes":raw.len(),"source_lines":23_000,"output_bytes":bytes.len(),"output_lines":24_000,"changes":1000,"prepare_encode_ms":processing_ms,"including_evidence_ms":processing_with_evidence_ms,"evidence_bytes":evidence.len(),"exact_output":true,"source_unchanged":true,"peak_memory_measured":false,"not_verified":"import, bridge, disk IO, complete history validation and whole-book 128 MiB performance"})
    );
}
