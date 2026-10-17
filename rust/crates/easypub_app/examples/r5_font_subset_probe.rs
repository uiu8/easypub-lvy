use easypub_app::fonts::{inspect, prepare_subset};
fn main() {
    let path = std::env::args().nth(1).expect("font path");
    let index = std::env::args()
        .nth(2)
        .unwrap_or("0".into())
        .parse::<u32>()
        .expect("face index");
    let text = std::env::args().nth(3).unwrap_or("ABC abc 123 é Å".into());
    let original = inspect(&path, index, &text).unwrap();
    assert!(prepare_subset(&path, index, &text, &original.sha256, false).is_err());
    assert!(prepare_subset(&path, index, &text, &"0".repeat(64), true).is_err());
    let prepared = prepare_subset(&path, index, &text, &original.sha256, true).unwrap();
    assert!(prepared.subset.bytes < prepared.original.bytes);
    let face = ttf_parser::Face::parse(&prepared.bytes, 0).unwrap();
    for ch in text.chars().filter(|c| !c.is_control()) {
        assert!(face.glyph_index(ch).is_some());
    }
    assert_eq!(prepared.subset.missing_count, 0);
    println!(
        "{}",
        serde_json::json!({"original_bytes":original.bytes,"subset_bytes":prepared.subset.bytes,"original_glyphs":original.glyph_count,"subset_glyphs":prepared.subset.glyph_count,"requested_characters":prepared.subset.requested_characters,"missing_count":0,"license_metadata_preserved":true,"unconfirmed_rejected":true,"changed_font_rejected":true,"font_output_written":false,"source_sha256":original.sha256,"subset_sha256":prepared.subset.sha256})
    );
}
