//! 桥接第 2 批测速（手动运行）：大书组合一遍与复制一份已组合结果各要多久。
//! EASYPUB_COMPOSE_PROBE=<txt> cargo test -p easypub_app --release --test compose_timing_probe -- --ignored --nocapture
#[test]
#[ignore]
fn compose_versus_clone() {
    let Ok(path) = std::env::var("EASYPUB_COMPOSE_PROBE") else { return };
    let source = easypub_core::source::SourceSnapshot::from_utf8(
        std::fs::read(path).unwrap(),
        easypub_core::source::RULE_ID,
        || false,
    )
    .unwrap();
    let structure = easypub_core::structure::Structure::new(&source);
    for _ in 0..3 {
        let t = std::time::Instant::now();
        let book = easypub_core::publication::compose_with_cleanup(&source, &structure, None, None).unwrap();
        let compose = t.elapsed();
        let t = std::time::Instant::now();
        let copy = book.clone();
        let clone = t.elapsed();
        let t = std::time::Instant::now();
        let json = serde_json::to_string(&structure).unwrap();
        let ser = t.elapsed();
        println!("compose={compose:?} clone={clone:?} structure_json={ser:?} ({} bytes) nodes={}", json.len(), copy.tree.nodes.len());
    }
}

#[test]
#[ignore]
fn base_id_parts() {
    use sha2::Digest;
    let Ok(path) = std::env::var("EASYPUB_COMPOSE_PROBE") else { return };
    let source = easypub_core::source::SourceSnapshot::from_utf8(
        std::fs::read(path).unwrap(), easypub_core::source::RULE_ID, || false).unwrap();
    let structure = easypub_core::structure::Structure::new(&source);
    let book = easypub_core::publication::compose_with_cleanup(&source, &structure, None, None).unwrap();
    for _ in 0..2 {
        let t = std::time::Instant::now();
        let id = easypub_core::effective_edit::base_id(&book);
        let total = t.elapsed();
        let t = std::time::Instant::now();
        let mut h = sha2::Sha256::new(); h.update(book.text.as_bytes()); let _ = h.finalize();
        let text = t.elapsed();
        let t = std::time::Instant::now();
        let tree = serde_json::to_vec(&book.tree).unwrap();
        let tree_ser = t.elapsed();
        let t = std::time::Instant::now();
        let map = serde_json::to_vec(&book.source_to_output_lines).unwrap();
        let map_ser = t.elapsed();
        println!("base_id={total:?} text_sha={text:?} ({}B) tree_json={tree_ser:?} ({}B) map_json={map_ser:?} ({}B) {}", book.text.len(), tree.len(), map.len(), &id[..8]);
    }
}

#[test]
#[ignore]
fn inspect_with_recognized_structure() {
    let Ok(path) = std::env::var("EASYPUB_COMPOSE_PROBE") else { return };
    let service = easypub_app::sessions::ImportService::new().unwrap();
    let job = service.start_import(path, easypub_core::source::RULE_ID.into()).unwrap();
    let book = loop {
        let s = service.get_job(job).unwrap();
        if s.terminal() { break s.book.unwrap(); }
        std::thread::sleep(std::time::Duration::from_millis(20));
    };
    let t = std::time::Instant::now();
    let recognized: serde_json::Value = serde_json::from_str(&easypub_app::structure_draft::edit(
        &service, book.source_id.clone(), book.revision, String::new(), r#"{"op":"recognize"}"#.into()).unwrap()).unwrap();
    println!("recognize={:?}", t.elapsed());
    let structure = recognized["history"][0].clone();
    println!("structure_json_bytes={}", structure.to_string().len());
    let parsed: easypub_core::structure::Structure = serde_json::from_value(structure.clone()).unwrap();
    let source = easypub_core::source::SourceSnapshot::from_utf8(
        std::fs::read(std::env::var("EASYPUB_COMPOSE_PROBE").unwrap()).unwrap(), easypub_core::source::RULE_ID, || false).unwrap();
    for _ in 0..2 {
        let t = std::time::Instant::now();
        let b = easypub_core::publication::compose_with_cleanup(&source, &parsed, None, None).unwrap();
        let c = t.elapsed();
        let t = std::time::Instant::now();
        let _ = easypub_core::effective_edit::base_id(&b);
        println!("compose={c:?} base_id={:?}", t.elapsed());
    }
    let base = serde_json::json!({"structure":structure,"manual":null,"cleanup":null}).to_string();
    for _ in 0..3 {
        let t = std::time::Instant::now();
        easypub_app::effective_draft::edit(&service, book.source_id.clone(), book.revision, base.clone(), String::new(), r#"{"op":"inspect"}"#.into()).unwrap();
        println!("inspect={:?}", t.elapsed());
    }
}

fn check_timing(label: &str, source: &easypub_core::source::SourceSnapshot) {
    use easypub_core::{effective_repair, publication, review, source::SourceSnapshot, structure::Structure};
    let structure = Structure::new(source);
    let book = publication::compose_with_cleanup(source, &structure, None, None).unwrap();
    let t = std::time::Instant::now();
    let diagnostics = SourceSnapshot::for_effective_diagnostics(&book).unwrap();
    let first_diag = t.elapsed();
    let t = std::time::Instant::now();
    let repairs = effective_repair::candidates(&book);
    let first_repairs = t.elapsed();
    let t = std::time::Instant::now();
    let evidence = review::ReviewEvidence::new(&diagnostics).unwrap();
    let first_evidence = t.elapsed();
    let reviews = review::Review::default();
    let lines = std::sync::OnceLock::new();
    for _ in 0..3 {
        let t = std::time::Instant::now();
        let report = reviews.report_using(&evidence, 0, None, None).unwrap();
        let report_ms = t.elapsed();
        let t = std::time::Instant::now();
        book.check_page_using(&diagnostics, &evidence, &repairs, &lines, 0, None, None, None, &reviews).unwrap();
        let page_ms = t.elapsed();
        println!(
            "{label}: report_using={report_ms:?} check_page_using={page_ms:?} items={} repairs={} map={} | first diag={first_diag:?} repairs={first_repairs:?} evidence={first_evidence:?}",
            report["diagnostic"]["review_total"], repairs["items"].as_array().map_or(0, Vec::len), book.source_to_output_lines.len(),
        );
    }
}

#[test]
#[ignore]
fn check_report_parts() {
    let Ok(path) = std::env::var("EASYPUB_COMPOSE_PROBE") else { return };
    let source = easypub_core::source::SourceSnapshot::from_utf8(
        std::fs::read(path).unwrap(), easypub_core::source::RULE_ID, || false).unwrap();
    check_timing("sample", &source);
    // 章节号跳跃、重复标题：一万章全有问题。
    let mut text = String::new();
    for i in 1..=10000 {
        text.push_str(&format!("第{}章 同名标题\n", i * 2));
        for _ in 0..80 { text.push_str("正文含汉字的一行，用来撑起书的大小。\n"); }
    }
    let source = easypub_core::source::SourceSnapshot::from_utf8(
        text.into_bytes(), easypub_core::source::RULE_ID, || false).unwrap();
    check_timing("many-findings", &source);
}

#[test]
#[ignore]
fn open_project_timing() {
    let Ok(path) = std::env::var("EASYPUB_PROJECT_PROBE") else { return };
    let service = easypub_app::sessions::ImportService::new().unwrap();
    let t = std::time::Instant::now();
    let r = easypub_app::project::open(&service, &path);
    println!("OPEN {:?} ok={}", t.elapsed(), r.is_ok());
    if let Err(e) = r { println!("{e:?}"); }
}

#[test]
#[ignore]
fn replay_step_parts() {
    use easypub_core::{source::{SourceSnapshot, RULE_ID}, structure::Structure};
    let Ok(path) = std::env::var("EASYPUB_REPLAY_PROBE") else { return };
    let bytes = std::fs::read(path).unwrap();
    println!("bytes={}", bytes.len());
    let t = std::time::Instant::now();
    let first = SourceSnapshot::from_bytes(bytes, easypub_core::encoding::EncodingMode::Auto, RULE_ID, || false).unwrap();
    println!("from_bytes={:?} chapters={}", t.elapsed(), first.summary().chapter_count);
    let text: Vec<u8> = first.original_bytes().to_vec();
    let text = String::from_utf8(text).unwrap_or_default();
    let structure = Structure::new(&first);
    let book = easypub_core::publication::compose_with_cleanup(&first, &structure, None, None).unwrap();
    println!("text_len={} nodes={}", book.text.len(), book.tree.nodes.len());
    let _ = text;
    for _ in 0..2 {
        let t = std::time::Instant::now();
        let source = SourceSnapshot::from_utf8(book.text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let a = t.elapsed();
        let t = std::time::Instant::now();
        let s = Structure::new(&source);
        let b = t.elapsed();
        let t = std::time::Instant::now();
        let tree = s.tree(&source).unwrap();
        let c = t.elapsed();
        let t = std::time::Instant::now();
        let _ = easypub_core::publication::compose(&source, &s, None).unwrap();
        let d = t.elapsed();
        let t = std::time::Instant::now();
        let id = easypub_core::effective_edit::base_id(&book);
        let e = t.elapsed();
        let t = std::time::Instant::now();
        let cl = book.clone();
        let f = t.elapsed();
        println!("from_utf8={a:?} structure_new={b:?} tree={c:?} compose={d:?} base_id={e:?} clone={f:?} nodes={} {}", tree.nodes.len(), &id[..6]);
        drop(cl);
    }
}
