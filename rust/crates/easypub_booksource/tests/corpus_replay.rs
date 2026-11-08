#[test]
fn corpus_replay() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/corpus");
    let mut paths: Vec<_> = std::fs::read_dir(root)
        .unwrap()
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.join("exchanges.json").exists())
        .collect();
    paths.sort();
    assert!(
        paths
            .iter()
            .filter(|p| {
                let data: serde_json::Value =
                    serde_json::from_slice(&std::fs::read(p.join("exchanges.json")).unwrap())
                        .unwrap();
                p.file_name()
                    .unwrap()
                    .to_string_lossy()
                    .starts_with("real-")
                    && data["expected"]["chars"]
                        .as_array()
                        .is_some_and(|c| c.len() == 3)
            })
            .count()
            >= 40,
        "至少 40 份实际录制了三个免费章节的真实合集样本"
    );
    for path in paths {
        let result = easypub_booksource::corpus::replay(&path);
        assert!(result.is_ok(), "{}: {result:?}", path.display());
    }
}
