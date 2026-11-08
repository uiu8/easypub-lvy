use easypub_app::fonts::{Mode, Selection, inspect, prepare_selected};
use write_fonts::read::FontRef;
fn main() {
    let path = std::env::args().nth(1).expect("font path");
    let index = std::env::args()
        .nth(2)
        .unwrap_or("0".into())
        .parse()
        .unwrap();
    let original = inspect(&path, index, "ABC").unwrap();
    let selection = Selection {
        path: path.clone(),
        face_index: index,
        sha256: original.sha256,
        license_confirmed: true,
        mode: Mode::Full,
    };
    let result = prepare_selected(&selection, "ABC").unwrap();
    let bytes = std::fs::read(&path).unwrap();
    let before = FontRef::from_index(&bytes, index).unwrap();
    let after = FontRef::from_index(&result.bytes, 0).unwrap();
    let mut compared = 0;
    for record in before.table_directory().table_records() {
        let tag = record.tag();
        if tag == write_fonts::types::Tag::new(b"DSIG") {
            continue;
        }
        let a = before.table_data(tag).unwrap();
        let b = after.table_data(tag).unwrap();
        if tag == write_fonts::types::Tag::new(b"head") {
            assert_eq!(&a.as_bytes()[..8], &b.as_bytes()[..8]);
            assert_eq!(&a.as_bytes()[12..], &b.as_bytes()[12..]);
        } else {
            assert_eq!(a.as_bytes(), b.as_bytes(), "table {tag}");
        }
        compared += 1;
    }
    assert_eq!(result.original.glyph_count, result.subset.glyph_count);
    let mut no_subset_and_restricted_checked = false;
    if !bytes.starts_with(b"ttcf") && index == 0 {
        let record = before
            .table_directory()
            .table_records()
            .iter()
            .find(|r| r.tag() == write_fonts::types::Tag::new(b"OS/2"))
            .unwrap();
        let start = record.offset() as usize;
        // Synthetic policy counterexamples only; never modify the installed font.
        let mut fixture = bytes.clone();
        assert!(u16::from_be_bytes([fixture[start], fixture[start + 1]]) >= 2);
        fixture[start + 8..start + 10].copy_from_slice(&0x0108u16.to_be_bytes());
        let temp =
            std::env::temp_dir().join(format!("easypub-font-policy-{}.ttf", std::process::id()));
        std::fs::write(&temp, &fixture).unwrap();
        let report = inspect(temp.to_str().unwrap(), 0, "ABC").unwrap();
        assert!(!report.embedding.subset_allowed);
        let mut chosen = Selection {
            path: temp.to_string_lossy().into(),
            face_index: 0,
            sha256: report.sha256,
            license_confirmed: true,
            mode: Mode::Full,
        };
        assert!(prepare_selected(&chosen, "ABC").is_ok());
        chosen.mode = Mode::Subset;
        assert!(prepare_selected(&chosen, "ABC").is_err());
        fixture[start + 8..start + 10].copy_from_slice(&2u16.to_be_bytes());
        std::fs::write(&temp, &fixture).unwrap();
        chosen.sha256 = inspect(temp.to_str().unwrap(), 0, "ABC").unwrap().sha256;
        chosen.mode = Mode::Full;
        assert!(prepare_selected(&chosen, "ABC").is_err());
        std::fs::remove_file(temp).unwrap();
        no_subset_and_restricted_checked = true;
    }
    println!(
        "{}",
        serde_json::json!({"face_index":index,"tables_preserved":compared,
        "glyph_count":result.subset.glyph_count,"output_bytes":result.bytes.len(),
        "original_bytes":bytes.len(),"font_output_written":false,"synthetic_policy_restrictions_verified":no_subset_and_restricted_checked})
    );
}
