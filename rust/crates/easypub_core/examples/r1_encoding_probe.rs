use easypub_core::{
    encoding::{EncodingMode, decode},
    source::{RULE_ID, SourceSnapshot},
};
use std::{env, fs, path::PathBuf};

fn main() {
    let root = env::var_os("EASYPUB_R1_ENCODING_FIXTURES")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../fixtures/r1-2")
        });
    let cases = [
        ("utf16le.txt", "utf-16le"),
        ("utf16be.txt", "utf-16be"),
        ("utf32le.txt", "utf-32le"),
        ("utf32be.txt", "utf-32be"),
        ("cp936.txt", "cp936"),
    ];
    println!("{{\"cases\":[");
    for (index, (name, expected)) in cases.iter().enumerate() {
        let path = root.join(name);
        let bytes = fs::read(&path).unwrap_or_else(|error| panic!("{}: {error}", path.display()));
        let decoded = decode(&bytes, EncodingMode::Auto).unwrap();
        assert_eq!(decoded.encoding.label(), *expected, "{}", path.display());
        let source =
            SourceSnapshot::from_bytes(bytes.clone(), EncodingMode::Auto, RULE_ID, || false)
                .unwrap();
        assert_eq!(source.original_bytes(), bytes.as_slice());
        let summary = source.summary();
        if index != 0 {
            print!(",");
        }
        print!(
            "{{\"file\":\"{}\",\"encoding\":\"{}\",\"bom_bytes\":{},\"line_count\":{},\"chapter_count\":{}}}",
            name, summary.encoding, summary.bom_length, summary.line_count, summary.chapter_count
        );
    }
    println!("]}}\n");
}
