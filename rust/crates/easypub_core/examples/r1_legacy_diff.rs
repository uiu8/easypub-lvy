use easypub_core::recognition::{NumericRule, is_default_heading};
use serde_json::{Value, json};
fn main() {
    let input = std::fs::read_to_string("fixtures/r1-2/legacy-rule-oracle.json").unwrap();
    let oracle: Value = serde_json::from_str(input.trim_start_matches('\u{feff}')).unwrap();
    let rule = NumericRule::compile(None).unwrap();
    let mut differences = Vec::new();
    let cases = oracle["cases"].as_array().unwrap();
    for case in cases {
        let line = case["line"].as_str().unwrap();
        let heading = is_default_heading(line);
        let numeric = rule.matches(line).is_some();
        if heading != case["heading"].as_bool().unwrap()
            || numeric != case["numeric"].as_bool().unwrap()
        {
            differences.push(json!({"line":line,"legacy_heading":case["heading"],"rust_heading":heading,"legacy_numeric":case["numeric"],"rust_numeric":numeric}));
        }
    }
    let report = json!({"cases":cases.len(),"differences":differences,"passed":differences.is_empty(),"oracle_runtime":oracle["runtime"],"heading_sha256":oracle["heading_sha256"],"numeric_sha256":oracle["numeric_sha256"]});
    let output = std::env::args()
        .nth(1)
        .unwrap_or("docs/evidence/r1-legacy-rule-diff.json".to_owned());
    std::fs::write(output, serde_json::to_string_pretty(&report).unwrap()).unwrap();
    println!("cases={} differences={}", cases.len(), differences.len());
    if !differences.is_empty() {
        std::process::exit(1);
    }
}
