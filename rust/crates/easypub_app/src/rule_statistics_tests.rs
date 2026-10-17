use super::*;
use easypub_core::{chapter_rules::RuleSet, source::RULE_ID};

fn request(source: &SourceSnapshot) -> Value {
    json!({"source_id":source.summary().source_id,"revision":source.summary().revision,
        "settings":{"title":"规则统计","author":"作者","description":"","language":"zh-CN",
        "cover_fit":"contain","font_family":"SimSun","font_size":20,"line_height":1.8,"include_toc":true,"illustrations":[],
        "scene_break_style":"off","first_paragraph_style":"normal","system_block_style":"off","verse_block_style":"off","note_style":"off"}})
}
fn rules(result: &Value) -> BTreeMap<&str, &Value> {
    result["rules"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| (r["id"].as_str().unwrap(), r))
        .collect()
}
fn fixture() -> String {
    "第一章 开始\r\n正文①和[2]。\r\n***\r\n【系统提示一】\r\n【系统提示二】\r\n床前明月光，疑是地上霜。\r\n春风又绿江南岸，明月何时照我还。\r\n——作者\r\n①第一条注释。\r\n注2：第二条注释。\r\n广告：样书\r\n".to_owned()
        + &"行尾有空白。  \r\n".repeat(66) + "第三章 后来\n第三章 后来\n尾段正文。\n第五章 结尾\n结尾正文。\n"
}

#[test]
fn catalog_covers_handoff_and_statistics_match_engines_without_mutation() {
    let catalog = crate::rule_catalog::catalog();
    let rows = catalog["rules"].as_array().unwrap();
    let ids: std::collections::BTreeSet<_> =
        rows.iter().map(|r| r["id"].as_str().unwrap()).collect();
    assert_eq!(ids.len(), 94);
    assert_eq!(ids.len(), rows.len());
    for (prefix, expected) in [
        ("chapter.recognize.", 12),
        ("check.", 11),
        ("cleanup.", 21),
        ("layout.scene.", 27),
        ("layout.manual_block.", 5),
        ("layout.manual_note.", 2),
    ] {
        assert_eq!(
            ids.iter().filter(|k| k.starts_with(prefix)).count(),
            expected,
            "{prefix}"
        );
    }
    for id in [
        "layout.note.circled",
        "layout.note.bracket",
        "layout.note.fullwidth",
        "layout.note.tortoise",
        "layout.note.annotated",
        "layout.note.definition_prefix",
        "layout.verse.five",
        "layout.verse.seven",
        "layout.verse.attribution",
        "layout.first_paragraph",
        "cleanup.join_hard_wraps",
        "cleanup.chinese_variant",
        "cleanup.chapter_numbers",
        "cleanup.multiline_regex_replace",
    ] {
        assert!(ids.contains(id), "{id}");
    }
    for row in rows {
        if let Some(parent) = row["parent"].as_str() {
            assert!(ids.contains(parent));
        }
        assert!(
            ["chapter_recognition", "chapter_check", "cleanup", "layout"]
                .contains(&row["group"].as_str().unwrap())
        );
    }
    assert_eq!(
        rows.iter()
            .find(|r| r["id"] == "cleanup.repeated_headers")
            .unwrap()["default"],
        false
    );
    let source = SourceSnapshot::from_utf8(fixture().into_bytes(), RULE_ID, || false).unwrap();
    let original = source.original_bytes().to_vec();
    let request = request(&source);
    let pipeline = json!([{"kind":"trim_trailing_spaces"},{"kind":"remove_ad_lines"}]);
    let result = calculate(
        &source,
        serde_json::from_value(request.clone()).unwrap(),
        pipeline.clone(),
        &AtomicBool::new(false),
    )
    .unwrap();
    let r = rules(&result);
    for (id, count) in [
        ("layout.system", 1),
        ("layout.verse", 1),
        ("layout.verse.five", 1),
        ("layout.verse.seven", 1),
        ("layout.verse.attribution", 1),
        ("layout.scene", 1),
        ("layout.scene.u002a", 1),
        ("layout.note", 2),
        ("layout.note.circled", 1),
        ("layout.note.bracket", 1),
        ("layout.note.definition_prefix", 1),
        ("cleanup.trim_trailing_spaces", 66),
        ("cleanup.site_notices", 1),
        ("check.duplicate_title", 1),
        ("check.number_gap", 2),
    ] {
        assert_eq!(r[id]["count"], count, "{id}");
        assert_eq!(r[id]["status"], "complete", "{id}: {}", r[id]);
    }
    for id in [
        "layout.system",
        "layout.verse",
        "layout.scene",
        "layout.note",
    ] {
        assert_eq!(r[id]["enabled"], false);
    }
    assert_eq!(r["cleanup.literal_replace"]["status"], "unconfigured");
    assert_eq!(
        r["cleanup.trim_trailing_spaces"]["locations"]
            .as_array()
            .unwrap()
            .len(),
        50
    );
    assert_eq!(
        r["cleanup.trim_trailing_spaces"]["changed_ranges"],
        json!([[12, 77]])
    );
    assert_eq!(r["layout.system"]["locations"][0]["first_line"], 3);
    let expected = RuleSet::default()
        .compile()
        .unwrap()
        .recognize(&source)
        .len();
    assert_eq!(r["chapter.recognize.chapter"]["count"], expected);
    let mut on = request.clone();
    for (key, value) in [
        ("system_block_style", "box"),
        ("verse_block_style", "center"),
        ("scene_break_style", "keep"),
        ("note_style", "popup"),
    ] {
        on["settings"][key] = json!(value);
    }
    let documents = publication_resources::prepare(&source, serde_json::from_value(on).unwrap())
        .unwrap()
        .documents()
        .unwrap();
    let body = &documents.pages["body.xhtml"];
    let xml = roxmltree::Document::parse(body).unwrap();
    for (id, class) in [
        ("layout.system", "system-block"),
        ("layout.verse", "verse-block"),
        ("layout.scene", "scene-break"),
    ] {
        let count = xml
            .descendants()
            .filter(|n| {
                n.attribute("class")
                    .is_some_and(|v| v.split_whitespace().any(|c| c == class))
            })
            .count();
        assert_eq!(r[id]["count"], count, "{id}");
    }
    assert_eq!(source.original_bytes(), original);
    assert_eq!(request["settings"]["note_style"], "off");
    let mut blank_configuration = request.clone();
    let mut structure = easypub_core::structure::Structure::new(&source);
    structure.recognition_rules = Some(RuleSet {
        non_heading: " \n\t".into(),
        chapter_pattern: "  ".into(),
        ..RuleSet::default()
    });
    blank_configuration["structure"] = json!(structure);
    let blank = calculate(
        &source,
        serde_json::from_value(blank_configuration).unwrap(),
        pipeline,
        &AtomicBool::new(false),
    )
    .unwrap();
    let blank_rules = rules(&blank);
    assert_eq!(
        blank_rules["chapter.recognize.non_heading"]["enabled"],
        false
    );
    assert_eq!(
        blank_rules["chapter.recognize.non_heading"]["status"],
        "unconfigured"
    );
    assert_eq!(
        blank_rules["chapter.recognize.author_note"]["enabled"],
        true
    );
}

#[test]
fn manual_priority_invalid_records_and_read_only_job_cache_and_cancellation() {
    let source =
        Arc::new(SourceSnapshot::from_utf8(fixture().into_bytes(), RULE_ID, || false).unwrap());
    let service = ImportService::new().unwrap();
    service
        .replace_sources(BTreeMap::from([(
            source.summary().source_id.clone(),
            Arc::clone(&source),
        )]))
        .unwrap();
    let mut publication = request(&source);
    let text = source.decoded_text();
    let start = text.find("床前").unwrap();
    let end = start + text[start..].find('\n').unwrap() + 1;
    publication["settings"]["block_annotations"] = json!([{"id":"1".repeat(64),"start":start,"end":end,"kind":"none","fingerprint":digest(&text.as_bytes()[start..end])}]);
    let note_start = text.find("尾段正文").unwrap();
    let note_end = note_start + "尾段正文。\n".len();
    publication["settings"]["manual_notes"] = json!([{"id":"2".repeat(64),"reference":{"start":note_start,"end":note_end,"from":0,"to":0,"fingerprint":digest(&text.as_bytes()[note_start..note_end])},"body":{"kind":"new","text":"手工注释"}},
        {"id":"3".repeat(64),"reference":{"start":note_start,"end":note_end,"from":3,"to":3,"fingerprint":"0".repeat(64)},"body":{"kind":"new","text":"失效注释"}}]);
    let invoke = |v: Value| -> Value { serde_json::from_str(&run(&service, v).unwrap()).unwrap() };
    let poll = |id: u64| -> Value {
        let deadline = Instant::now();
        loop {
            let job = invoke(json!({"action":"poll","job_id":id}));
            if job["phase"] != "running" && job["phase"] != "cancelling" {
                return job;
            }
            assert!(deadline.elapsed().as_secs() < 20);
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    };
    let input = json!({"op":"rule_catalog","action":"start","publication":publication,"cleanup_pipeline":[]});
    let id = invoke(input.clone())["job_id"].as_u64().unwrap();
    let job = poll(id);
    assert_eq!(job["phase"], "completed", "{job}");
    let r = rules(&job["result"]);
    assert_eq!(r["layout.manual_block.none"]["count"], 1);
    assert_eq!(r["layout.verse.five"]["count"], 0);
    assert_eq!(r["layout.manual_note.new"]["count"], 1);
    assert_eq!(r["layout.manual_note"]["invalid_count"], 1);
    invoke(json!({"action":"release","job_id":id}));
    let cached = invoke(input.clone());
    assert_eq!(cached["phase"], "completed");
    assert_eq!(cached["result"]["cache_hit"], true);
    invoke(json!({"action":"release","job_id":cached["job_id"]}));
    let mut changed = input.clone();
    changed["publication"]["settings"]["verse_block_style"] = json!("indent");
    let next = invoke(changed);
    assert_eq!(next["phase"], "running");
    invoke(json!({"action":"cancel","job_id":next["job_id"]}));
    let cancelled = poll(next["job_id"].as_u64().unwrap());
    assert_eq!(cancelled["phase"], "cancelled");
    assert!(cancelled["result"].is_null());
    invoke(json!({"action":"release","job_id":next["job_id"]}));
    assert!(
        crate::production::run(&service, input.to_string(), true, String::new(), true).is_err()
    );
    assert_eq!(source.original_bytes(), fixture().as_bytes());
}
