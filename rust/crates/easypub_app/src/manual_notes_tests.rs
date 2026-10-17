use super::*;
use easypub_core::source::{RULE_ID, SourceSnapshot};

fn settings() -> Value {
    json!({"title":"手工注释", "author":"作者", "description":"", "language":"zh-CN",
        "cover_fit":"contain", "font_family":"SimSun", "font_size":20, "line_height":1.8,
        "include_toc":true,"illustrations":[],"fullwidth_indent":2})
}
fn compose(text: &str) -> (SourceSnapshot, EffectiveBook) {
    let source = SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
    let (book, _) = publication_resources::compose(
        &source,
        serde_json::from_value(json!({
        "source_id":source.summary().source_id,"revision":1,"settings":settings()}))
        .unwrap(),
    )
    .unwrap();
    (source, book)
}
fn select(book: &EffectiveBook, line: &str, marker: &str) -> Selection {
    let start = book.text.find(line).unwrap();
    let from = line.find(marker).unwrap();
    Selection {
        start,
        end: start + line.len(),
        from,
        to: from + marker.len(),
    }
}
#[test]
fn fingerprints_coordinates_conflicts_and_source_restore() {
    let text = "第一章 雾港\r\n　😀词（甲）还有①。\r\n作者注：旧注释。\r\n①自动注释。\r\n第二章 航行\n没有注释。\n";
    let (source, book) = compose(text);
    let reference = select(&book, "　😀词（甲）还有①。\r\n", "（甲）");
    let pair = create(
        &book,
        Input::Pair {
            reference: reference.clone(),
            definition: select(&book, "作者注：旧注释。\r\n", ""),
        },
    )
    .unwrap();
    let mut caret = reference.clone();
    caret.from = caret.to;
    let new = create(
        &book,
        Input::New {
            reference: caret.clone(),
            text: "自拟注释<&>。\n第二段。".into(),
        },
    )
    .unwrap();
    assert_eq!(location(&book, &pair.reference)["utf16_start"], 4);
    assert!(validate(&[pair.clone(), pair.clone()]).is_err());
    let other = create(
        &book,
        Input::Pair {
            reference: select(&book, "没有注释。\n", "没有"),
            definition: select(&book, "作者注：旧注释。\r\n", ""),
        },
    );
    assert_eq!(other.unwrap_err().next_action, "note_crosses_chapter");
    let (_, changed) = compose(&text.replace("旧注释", "新注释"));
    assert_eq!(invalid_reason(&pair, &changed), Some("note_text_changed"));
    assert!(invalid_reason(&new, &changed).is_none());
    for auto in [false, true] {
        let mut current = settings();
        current["manual_notes"] = json!([pair, new]);
        current["note_style"] = json!(if auto { "popup" } else { "off" });
        let request =
            json!({"source_id":source.summary().source_id,"revision":1,"settings":current});
        let mut docs =
            publication_resources::prepare(&source, serde_json::from_value(request).unwrap())
                .unwrap()
                .documents()
                .unwrap();
        let body = &docs.pages["body.xhtml"];
        // 新增内容不能插在正文中间；换章时输出，原注释行仍按来源顺序保留。
        assert!(body.find("自拟注释&lt;&amp;&gt;。").unwrap() > body.find("①自动注释。").unwrap());
        assert!(body.find("自拟注释&lt;&amp;&gt;。").unwrap() < body.find("第二章 航行").unwrap());
        assert!(!body.contains("返回正文"));
        crate::publication_split::split(&mut docs, 400).unwrap();
        let mut restored = String::new();
        let mut refs = 0;
        let mut generated = 0;
        for name in &docs.reading_order {
            let xml = roxmltree::Document::parse(&docs.pages[name]).unwrap();
            for n in xml.descendants() {
                if n.attribute("data-source") == Some("true") {
                    restored.push_str(n.attribute("data-original").unwrap());
                    restored.push_str(match n.attribute("data-eol").unwrap() {
                        "crlf" => "\r\n",
                        "lf" => "\n",
                        "cr" => "\r",
                        _ => "",
                    });
                }
                if n.attribute(("http://www.idpf.org/2007/ops", "type")) == Some("noteref") {
                    refs += 1;
                    let (file, id) = n.attribute("href").unwrap().split_once('#').unwrap();
                    let target = roxmltree::Document::parse(&docs.pages[file]).unwrap();
                    let note = target
                        .descendants()
                        .find(|n| n.attribute("id") == Some(id))
                        .unwrap();
                    let backlink = note.descendants().find(|n| n.has_tag_name("a")).unwrap();
                    assert_eq!(
                        backlink.attribute("href").unwrap(),
                        format!("{name}#{}", n.attribute("id").unwrap())
                    );
                    assert!(n.parent().unwrap().has_tag_name("sup"));
                    assert!(backlink.text().unwrap().chars().count() <= 3);
                    if n.text() == Some("1") {
                        generated += 1;
                        assert!(
                            n.descendants()
                                .all(|n| n.attribute("data-source").is_none())
                        );
                        assert!(
                            note.descendants()
                                .all(|n| n.attribute("data-source").is_none())
                        );
                        assert!(
                            note.descendants()
                                .filter_map(|n| n.text())
                                .any(|s| s.contains("第二段"))
                        );
                    }
                }
            }
        }
        assert_eq!(restored, text);
        assert_eq!(refs, if auto { 3 } else { 2 });
        assert_eq!(generated, 1);
    }
    // 手工占用自动标记后，旧自动定义不再连接；不误替换同行另一段文字。
    let replacement = create(
        &book,
        Input::Pair {
            reference: select(&book, "　😀词（甲）还有①。\r\n", "①"),
            definition: select(&book, "作者注：旧注释。\r\n", ""),
        },
    )
    .unwrap();
    assert!(
        crate::publication_notes::Notes::with_manual(&book, &[replacement], true)
            .automatic_report(&book, true)
            .is_empty()
    );
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
fn both_kinds_crud_share_history_and_reject_stale_unicode_positions() {
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
    let root = std::env::temp_dir().join(format!(
        "easypub-v58-{}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir(&root).unwrap();
    let path = root.join("手工.txt");
    let text = "第一章 起\n😀词（1）。\n作者注：解释。\n备用注释。\n";
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
    let mut request = json!({"op":"manual_notes","publication":{"source_id":source.source_id,"revision":1,"settings":settings()},
        "targets":[{"book_id":"book","current":settings(),"change":{"op":"inspect"},"history":{"source_id":source.source_id,"revision":1,"states":[settings()],"cursor":0}}],"action":{"kind":"list"}});
    request["action"] = json!({"kind":"resolve","entry_id":book.tree.nodes[0].entry_id,"line":1,"utf16_start":1,"utf16_end":1,"content_id":digest(text.as_bytes())});
    assert_eq!(
        run(&service, request.clone(), false, "", false)
            .unwrap_err()
            .next_action,
        "note_character_boundary"
    );
    let sel = |line, marker| {
        let s = select(&book, line, marker);
        json!({"start":s.start,"end":s.end,"from":s.from,"to":s.to})
    };
    for kind in ["pair", "new"] {
        let mut input = if kind == "pair" {
            json!({"kind":"pair","reference":sel("😀词（1）。\n","（1）"),"definition":sel("作者注：解释。\n","")})
        } else {
            json!({"kind":"new","reference":sel("😀词（1）。\n",""),"text":"新增注释。"})
        };
        let added = apply(
            &service,
            &mut request,
            json!({"kind":"add","input":input,"content_id":digest(text.as_bytes())}),
        );
        let id = added["manual_notes"]["notes"][0]["id"].clone();
        assert_eq!(
            apply(&service, &mut request, json!({"kind":"undo"}))["manual_notes"]["notes"],
            json!([])
        );
        apply(&service, &mut request, json!({"kind":"redo"}));
        if kind == "pair" {
            input["definition"] = sel("备用注释。\n", "");
        } else {
            input["text"] = json!("改写\n第二段。");
        }
        let changed = apply(
            &service,
            &mut request,
            json!({"kind":"update","id":id,"input":input,"content_id":digest(text.as_bytes())}),
        );
        assert_eq!(changed["manual_notes"]["notes"][0]["id"], id);
        assert_eq!(
            changed["manual_notes"]["notes"][0]["text"],
            if kind == "pair" {
                "备用注释。\n"
            } else {
                "改写\n第二段。"
            }
        );
        assert_eq!(
            apply(&service, &mut request, json!({"kind":"delete","id":id}))["manual_notes"]["notes"],
            json!([])
        );
    }
    assert_eq!(std::fs::read(path).unwrap(), text.as_bytes());
}
