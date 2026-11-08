use easypub_core::encoding::{EncodingKind, EncodingMode, decode, encode};
use serde_json::{Value, json};
fn main() {
    let input = std::fs::read_to_string("fixtures/r1-2/cp936-oracle.json").unwrap();
    let oracle: Value = serde_json::from_str(&input).unwrap();
    let mut decoding = Vec::new();
    let mut encoding = Vec::new();
    for (i, expected) in oracle["decoded"].as_array().unwrap().iter().enumerate() {
        let bytes = if i < 256 {
            vec![i as u8]
        } else {
            vec![((i - 256) >> 8) as u8, (i - 256) as u8]
        };
        let actual = decode(&bytes, EncodingMode::Cp936).ok().map(|d| d.text);
        if actual.as_deref() != expected.as_str() {
            decoding.push(json!({"bytes":bytes,"dotnet":expected,"rust":actual}));
        }
    }
    for (scalar, expected) in oracle["encoded"].as_array().unwrap().iter().enumerate() {
        let actual = char::from_u32(scalar as u32)
            .and_then(|c| encode(&c.to_string(), EncodingKind::Cp936, false).ok())
            .map(|b| b.iter().map(|v| format!("{v:02X}")).collect::<String>());
        if actual.as_deref() != expected.as_str() {
            encoding.push(json!({"scalar":scalar,"dotnet":expected,"rust":actual}));
        }
    }
    let report = json!({"runtime":oracle["runtime"],"decode_cases":65792,"encode_cases":65536,"decode_difference_count":decoding.len(),"encode_difference_count":encoding.len(),"decode_differences":decoding,"encode_differences":encoding});
    let path = std::env::args()
        .nth(1)
        .unwrap_or("docs/evidence/r1-cp936-diff.json".to_owned());
    std::fs::write(path, serde_json::to_string_pretty(&report).unwrap()).unwrap();
    println!(
        "decode_differences={} encode_differences={}",
        decoding.len(),
        encoding.len()
    );
    if !decoding.is_empty() || !encoding.is_empty() {
        std::process::exit(1);
    }
}
