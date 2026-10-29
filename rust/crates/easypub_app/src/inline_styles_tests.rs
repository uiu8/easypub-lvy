use super::*;
use easypub_core::source::{RULE_ID, SourceSnapshot};
fn settings() -> Value {
    json!({"title":"行内样式", "author":"作者", "description":"", "language":"zh-CN", "cover_fit":"contain", "font_family":"SimSun", "font_size":20, "line_height":1.8, "include_toc":true,"illustrations":[],"fullwidth_indent":2})
}
fn compose(text: &str) -> (SourceSnapshot, EffectiveBook) {
    let source = SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
    let (book, _) = publication_resources::compose(
        &source,
        serde_json::from_value(
            json!({"source_id":source.summary().source_id,"revision":1,"settings":settings()}),
        )
        .unwrap(),
    )
    .unwrap();
    (source, book)
}
fn anchor(book: &EffectiveBook, line: &str, selected: &str) -> Anchor {
    let start = book.text.find(line).unwrap();
    let from = line.find(selected).unwrap();
    Anchor {
        start,
        end: start + line.len(),
        from,
        to: from + selected.len(),
        fingerprint: digest(line.as_bytes()),
    }
}
#[test]
fn composition_unicode_conflicts_invalidation_and_notes() {
    let text = "第一章 开始\r\n　😀甲乙丙丁｜汉《hàn》重点。\r\n";
    let (source, book) = compose(text);
    let line = text.split_once("\r\n").unwrap().1;
    let make = |selected, style| {
        create(
            &book,
            Input {
                anchor: anchor(&book, line, selected),
                style,
            },
        )
        .unwrap()
    };
    let a = make("甲乙丙", Style::Bold);
    let b = make("乙", Style::Italic);
    validate(&[a.clone(), b.clone()]).unwrap();
    assert!(validate(&[a.clone(), make("丙丁", Style::Underline)]).is_err());
    assert!(validate(&[a.clone(), a.clone()]).is_err());
    assert!(
        create(
            &book,
            Input {
                anchor: anchor(&book, line, "汉"),
                style: Style::Bold
            }
        )
        .is_err()
    );
    let mut bad = a.clone();
    bad.anchor.from += 1;
    assert_eq!(
        invalid_reason(&bad, &book),
        Some("inline_style_character_boundary")
    );
    let (_, changed) = compose(&text.replace("重点", "终点"));
    assert_eq!(invalid_reason(&a, &changed), Some("line_changed"));
    let styles = vec![
        a,
        b,
        make("｜汉《hàn》", Style::Kai),
        make("重点", Style::EmDot),
    ];
    let mut cfg = settings();
    cfg["inline_styles"] = json!(styles);
    let mut caret = anchor(&book, line, "丙");
    caret.to = caret.from;
    cfg["manual_notes"] =
        json!([{"id":"a".repeat(64),"reference":caret,"body":{"kind":"new","text":"测试注释"}}]);
    let prepared = publication_resources::prepare(
        &source,
        serde_json::from_value(
            json!({"source_id":source.summary().source_id,"revision":1,"settings":cfg}),
        )
        .unwrap(),
    )
    .unwrap();
    let docs = prepared.documents().unwrap();
    let body = &docs.pages["body.xhtml"];
    roxmltree::Document::parse(body).unwrap();
    for class in [
        "inline-bold",
        "inline-italic",
        "inline-kai",
        "em-dot",
        "note-ref",
    ] {
        assert!(body.contains(class), "{class}: {body}");
    }
    assert!(body.contains("<ruby>汉<rp>"));
    assert!(body.contains("data-original="));
    assert!(prepared.manifest().stylesheet.css.contains("STKai"));
    let mut bytes = std::io::Cursor::new(Vec::new());
    bytes = crate::epub::write_bokai_input(&prepared, bytes).unwrap();
    let mut zip = zip::ZipArchive::new(bytes).unwrap();
    use std::io::Read;
    let mut css = String::new();
    zip.by_name(&format!("EPUB/{}", prepared.manifest().stylesheet.id))
        .unwrap()
        .read_to_string(&mut css)
        .unwrap();
    assert!(!css.contains("text-decoration-style"));
    // Source bytes remain immutable; output styles are separate metadata.
    assert_eq!(book.text, text);
}
fn apply(service: &ImportService, request: &mut Value, action: Value) -> Value {
    request["action"] = action;
    let preview: Value =
        serde_json::from_str(&run(service, request.clone(), false, "", false).unwrap()).unwrap();
    assert!(preview["items"][0]["history"].is_null());
    assert!(run(service, request.clone(), true, "wrong", true).is_err());
    let result: Value = serde_json::from_str(
        &run(
            service,
            request.clone(),
            true,
            preview["plan_id"].as_str().unwrap(),
            true,
        )
        .unwrap(),
    )
    .unwrap();
    request["publication"]["settings"] = result["items"][0]["after"].clone();
    request["targets"][0]["current"] = result["items"][0]["after"].clone();
    request["targets"][0]["history"] = result["items"][0]["history"].clone();
    result
}

#[test]
fn crud_history_resolve_and_preview_guards() {
    use std::time::{Duration, Instant};
    let root = std::env::temp_dir().join(format!(
        "easypub-v105-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir(&root).unwrap();
    let path = root.join("稿.txt");
    let text = "第一章 开始\n😀甲乙丙丁。\n";
    std::fs::write(&path, text).unwrap();
    let service = ImportService::new().unwrap();
    let job = service
        .start_import(path.to_string_lossy().into(), RULE_ID.into())
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let source = loop {
        let status = service.get_job(job).unwrap();
        if status.terminal() {
            break status.book.unwrap();
        }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(2));
    };
    let (_, book) = compose(text);
    let mut request = json!({"op":"inline_styles","publication":{"source_id":source.source_id,"revision":1,"settings":settings()},"targets":[{"book_id":"book","current":settings(),"change":{"op":"inspect"},"history":{"source_id":source.source_id,"revision":1,"states":[settings()],"cursor":0}}],"action":{"kind":"resolve","entry_id":book.tree.nodes[0].entry_id,"line":1,"utf16_start":0,"utf16_end":2,"content_id":digest(text.as_bytes())}});
    let resolved: Value =
        serde_json::from_str(&run(&service, request.clone(), false, "", false).unwrap()).unwrap();
    assert_eq!(resolved["selection"]["to"], 4);
    let input = json!({"anchor":resolved["selection"],"style":"bold"});
    let added = apply(
        &service,
        &mut request,
        json!({"kind":"add","input":input,"content_id":digest(text.as_bytes())}),
    );
    let id = added["inline_styles"]["items"][0]["id"].clone();
    assert_eq!(
        apply(&service, &mut request, json!({"kind":"undo"}))["inline_styles"]["total"],
        0
    );
    assert_eq!(
        apply(&service, &mut request, json!({"kind":"redo"}))["inline_styles"]["total"],
        1
    );
    let updated = apply(
        &service,
        &mut request,
        json!({"kind":"update","id":id,"input":{"anchor":resolved["selection"],"style":"italic"},"content_id":digest(text.as_bytes())}),
    );
    assert_eq!(
        updated["inline_styles"]["items"][0]["annotation"]["style"],
        "italic"
    );
    assert_eq!(
        apply(&service, &mut request, json!({"kind":"delete","id":id}))["inline_styles"]["total"],
        0
    );
    assert_eq!(std::fs::read_to_string(path).unwrap(), text);
}

#[test]
fn add_many_is_one_history_step_and_all_or_nothing() {
    use std::time::{Duration, Instant};
    let root = std::env::temp_dir().join(format!(
        "easypub-v106-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir(&root).unwrap();
    let path = root.join("稿.txt");
    let text = "第一章 开始\n甲乙丙丁。\n戊己庚辛。\n壬癸子丑。\n";
    std::fs::write(&path, text).unwrap();
    let service = ImportService::new().unwrap();
    let job = service
        .start_import(path.to_string_lossy().into(), RULE_ID.into())
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let source = loop {
        let status = service.get_job(job).unwrap();
        if status.terminal() {
            break status.book.unwrap();
        }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(2));
    };
    let (_, book) = compose(text);
    let content = digest(text.as_bytes());
    let mut request = json!({"op":"inline_styles","publication":{"source_id":source.source_id,"revision":1,"settings":settings()},"targets":[{"book_id":"book","current":settings(),"change":{"op":"inspect"},"history":{"source_id":source.source_id,"revision":1,"states":[settings()],"cursor":0}}]});
    let resolve = |request: &Value, line: usize, from: usize, to: usize| {
        let mut request = request.clone();
        request["action"] = json!({"kind":"resolve","entry_id":book.tree.nodes[0].entry_id,"line":line,"utf16_start":from,"utf16_end":to,"content_id":content});
        let v: Value =
            serde_json::from_str(&run(&service, request, false, "", false).unwrap()).unwrap();
        v["selection"].clone()
    };
    // 第 1 行从“丙”到行尾，第 2 行整行，第 3 行到“癸”。
    let inputs = json!([
        {"anchor":resolve(&request, 1, 2, 5),"style":"underline"},
        {"anchor":resolve(&request, 2, 0, 5),"style":"underline"},
        {"anchor":resolve(&request, 3, 0, 2),"style":"underline"},
    ]);
    let added = apply(
        &service,
        &mut request,
        json!({"kind":"add_many","inputs":inputs,"content_id":content}),
    );
    assert_eq!(added["inline_styles"]["total"], 3);
    let texts: Vec<_> = added["inline_styles"]["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["text"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(texts, ["丙丁。", "戊己庚辛。", "壬癸"]);
    // 有一行与已有样式交叉时整批拒绝。
    request["action"] = json!({"kind":"add_many","inputs":[
        {"anchor":resolve(&request, 2, 0, 1),"style":"bold"},
        {"anchor":resolve(&request, 3, 1, 3),"style":"bold"},
    ],"content_id":content});
    assert!(run(&service, request.clone(), false, "", false).is_err());
    request["action"] = json!({"kind":"add_many","inputs":[],"content_id":content});
    assert!(run(&service, request.clone(), false, "", false).is_err());
    // 一次撤销撤掉整批。
    assert_eq!(
        apply(&service, &mut request, json!({"kind":"undo"}))["inline_styles"]["total"],
        0
    );
    assert_eq!(std::fs::read_to_string(path).unwrap(), text);
}
