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
    assert_eq!(ids.len(), 111);
    assert_eq!(ids.len(), rows.len());
    for (prefix, expected) in [
        ("chapter.recognize.", 12),
        ("check.", 11),
        ("cleanup.", 21),
        ("layout.scene.", 27),
        ("layout.manual_block.", 6),
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
            [
                "chapter_recognition",
                "chapter_check",
                "cleanup",
                "layout",
                "catalog_check",
                "preflight",
                "manual"
            ]
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

/// 同一本确定性合成长稿、同一请求；直接计算跳过跨请求缓存。
#[test]
#[ignore = "手动记录 V67 修改前后统计耗时"]
fn hypothetical_timing_sample() {
    let text: String = (1..=300)
        .map(|n| {
            format!(
                "第{}章 标题\n{}\n＊＊＊\n床前明月光，疑是地上霜。\n正文①\n①注释内容\n",
                n * 2,
                "这是用于统计耗时的确定性正文。\n".repeat(80)
            )
        })
        .collect();
    let source = SourceSnapshot::from_utf8(text.into_bytes(), RULE_ID, || false).unwrap();
    let mut req = request(&source);
    let rule_set = RuleSet {
        disabled_checks: vec!["number_gap".into()],
        disabled_recognition: vec!["prose".into()],
        ..Default::default()
    };
    let mut structure = easypub_core::structure::Structure::recognized(&source);
    structure.recognition_rules = Some(rule_set);
    req["structure"] = json!(structure);
    req["settings"]["verse_block_style"] = json!("center");
    req["settings"]["scene_break_style"] = json!("keep");
    req["settings"]["rule_options"] =
        json!({"scene_symbols":"*", "disabled":["layout.verse.five"]});
    let mut times = Vec::new();
    let mut counts = Value::Null;
    for i in 0..6 {
        let r = calculate(
            &source,
            serde_json::from_value(req.clone()).unwrap(),
            json!([]),
            &AtomicBool::new(false),
        )
        .unwrap();
        if i > 0 {
            times.push(r["elapsed_ms"].as_f64().unwrap());
        }
        let rows = rules(&r);
        counts = json!({"gap":rows["check.number_gap"]["count"],"five":rows["layout.verse.five"]["count"],"scene":rows["layout.scene.uff0a"]["count"]});
    }
    println!(
        "V67_TIMING {}",
        json!({"bytes":source.decoded_text().len(),"content_sha256":digest(source.original_bytes()),"elapsed_ms":times,"counts":counts})
    );
}

#[test]
fn hypothetical_counts_and_locations_preserve_other_filters_and_original_state() {
    let source = SourceSnapshot::from_utf8(
        (fixture() + "第三章 重复\n正文不同。\n三章更新完毕\n第三卷还差几页。\n序幕\n正文。\n＊＊＊\n第一百一十八章 前\n正文。\n第一百一十久章 疑似错字\n正文。\n第一百二十章 后\n正文。\n第六章 后记（求月票）\n正文。\n").into_bytes(),
        RULE_ID,
        || false,
    )
    .unwrap();
    let mut input = request(&source);
    input["settings"]["scene_break_style"] = json!("keep");
    input["settings"]["verse_block_style"] = json!("center");
    input["settings"]["system_block_style"] = json!("box");
    input["settings"]["note_style"] = json!("popup");
    let base_rules = RuleSet {
        force_heading: "序幕".into(),
        title_suffixes: "（求月票）".into(),
        non_heading: "第五章 结尾".into(),
        ..Default::default()
    };
    let mut structure = easypub_core::structure::Structure::recognized(&source);
    structure.recognition_rules = Some(base_rules.clone());
    input["structure"] = json!(structure);
    let pipeline = json!([{"kind":"collapse_blank_lines"}]);
    let invoke = |req: Value| {
        calculate(
            &source,
            serde_json::from_value(req).unwrap(),
            pipeline.clone(),
            &AtomicBool::new(false),
        )
        .unwrap()
    };
    let before = invoke(input.clone());
    let catalog = crate::rule_catalog::catalog();
    for id in [
        "check.number_gap",
        "check.number_reset.repeated_number",
        "layout.verse",
        "layout.verse.five",
        "layout.verse.seven",
        "layout.verse.attribution",
        "layout.scene",
        "layout.scene.uff0a",
        "layout.note.circled",
        "layout.note.bracket",
        "layout.note.definition_prefix",
        "chapter.recognize.force_heading",
        "chapter.recognize.title_suffixes",
        "chapter.recognize.number_corrections",
        "chapter.recognize.non_heading",
        "chapter.recognize.author_note",
        "chapter.recognize.prose",
    ] {
        let row = catalog["rules"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["id"] == id)
            .unwrap();
        let mut ruleset = base_rules.clone();
        let mut settings = serde_json::from_value(input["settings"].clone()).unwrap();
        crate::rule_toggles::toggle(
            row,
            &mut ruleset,
            &mut settings,
            &mut pipeline.clone(),
            false,
        )
        .unwrap();
        let mut disabled = input.clone();
        disabled["structure"]["recognition_rules"] = json!(ruleset);
        disabled["settings"] = json!(settings);
        let saved = disabled.clone();
        let after = invoke(disabled.clone());
        let a = rules(&before)[id];
        let b = rules(&after)[id];
        assert!(
            a["count"].as_u64().unwrap() > 0,
            "sample must hit {id}: {a}"
        );
        assert_eq!(b["enabled"], false, "{id}");
        assert_eq!(b["hypothetical"], true, "{id}");
        assert_eq!(b["count"], a["count"], "{id}");
        assert_eq!(b["unit"], a["unit"], "{id}");
        let offsets = |r: &Value| {
            r["locations"]
                .as_array()
                .unwrap()
                .iter()
                .map(|p| p["utf8_start"].clone())
                .collect::<Vec<_>>()
        };
        assert_eq!(offsets(b), offsets(a), "{id}");
        assert_eq!(disabled, saved);
        assert_eq!(after["content_id"], before["content_id"]);
        if id == "check.number_gap" {
            let (book, _) =
                publication_resources::compose(&source, serde_json::from_value(disabled).unwrap())
                    .unwrap();
            let view = SourceSnapshot::for_effective_diagnostics(&book).unwrap();
            let plan: Value =
                serde_json::from_str(&view.repair_plan_json("[\"number-gap\"]").unwrap()).unwrap();
            assert!(
                plan["actions"].as_array().unwrap().is_empty(),
                "actual checks remain disabled"
            );
        }
    }
    // A child simulation restores its parent, but must not enable the disabled sibling.
    let mut siblings = input.clone();
    siblings["settings"]["verse_block_style"] = json!("off");
    siblings["settings"]["rule_options"] =
        json!({"disabled":["layout.verse.five","layout.verse.seven"]});
    let r = invoke(siblings);
    assert_eq!(rules(&r)["layout.verse.five"]["count"], 1);
    assert_eq!(rules(&r)["layout.verse.seven"]["count"], 1);
    assert_eq!(rules(&r)["layout.verse"]["count"], 0);
    assert_eq!(rules(&r)["layout.verse.attribution"]["count"], 0);
}

#[test]
fn hypothetical_catalog_counts_require_a_reference_and_keep_real_locations() {
    let source = SourceSnapshot::from_utf8(
        "第一章 开始\n正文。\n第三章 后来\n正文乙。\n第五章 结尾\n正文丙。\n"
            .as_bytes()
            .to_vec(),
        RULE_ID,
        || false,
    )
    .unwrap();
    let reference = crate::catalog::parse_text(
        "第三章 改名\n第一章 开始\n第二章 缺少",
        "样书",
        "",
        "paste",
        Some(3),
    )
    .unwrap();
    let mut req = request(&source);
    let invoke = |req: Value, catalog: Value| {
        let mut result = calculate(
            &source,
            serde_json::from_value(req.clone()).unwrap(),
            json!([]),
            &AtomicBool::new(false),
        )
        .unwrap();
        enrich(
            &source,
            &json!({"publication":req,"reference_catalog":catalog}),
            &mut result,
        )
        .unwrap();
        result
    };
    let before = invoke(req.clone(), json!(reference));
    req["settings"]["rule_options"] = json!({"disabled":["catalog_check.missing","catalog_check.extra","catalog_check.title","catalog_check.order"]});
    let after = invoke(req.clone(), json!(reference));
    for id in [
        "catalog_check.missing",
        "catalog_check.extra",
        "catalog_check.title",
        "catalog_check.order",
    ] {
        assert_eq!(rules(&before)[id]["count"], 1, "{id}");
        assert_eq!(rules(&after)[id]["count"], 1, "{id}");
        assert_eq!(rules(&after)[id]["enabled"], false);
        assert_eq!(rules(&after)[id]["hypothetical"], true);
        assert_eq!(
            rules(&after)[id]["locations"],
            rules(&before)[id]["locations"]
        );
    }
    let unavailable = invoke(req, Value::Null);
    assert_eq!(
        rules(&unavailable)["catalog_check.missing"]["count"],
        Value::Null
    );
    assert_eq!(
        rules(&unavailable)["catalog_check.missing"]["hypothetical"],
        false
    );
}

/// V104（LAY-148）：按当前设置逐行列出系统提示与诗词，行号是本节正文行号，手工标注单独标出；关闭识别时不列。
#[test]
fn layout_lines_follow_current_settings_and_mark_manual_blocks() {
    let source = SourceSnapshot::from_utf8(fixture().into_bytes(), RULE_ID, || false).unwrap();
    let mut publication = request(&source);
    let off = calculate(
        &source,
        serde_json::from_value(publication.clone()).unwrap(),
        json!([]),
        &AtomicBool::new(false),
    )
    .unwrap();
    assert_eq!(off["layout_lines"], json!({}));

    publication["settings"]["system_block_style"] = json!("styled");
    publication["settings"]["verse_block_style"] = json!("center");
    let text = source.decoded_text();
    let start = text.find("广告：样书").unwrap();
    let end = start + text[start..].find('\n').unwrap() + 1;
    publication["settings"]["block_annotations"] = json!([{"id":"4".repeat(64),"start":start,"end":end,"kind":"quote","fingerprint":digest(&text.as_bytes()[start..end])}]);
    let on = calculate(
        &source,
        serde_json::from_value(publication).unwrap(),
        json!([]),
        &AtomicBool::new(false),
    )
    .unwrap();
    let lines = on["layout_lines"].as_object().unwrap();
    assert_eq!(lines.len(), 1, "{lines:?}");
    let chapter = lines.values().next().unwrap().as_array().unwrap();
    let rows: Vec<(u64, &str, bool)> = chapter
        .iter()
        .map(|r| {
            (
                r[0].as_u64().unwrap(),
                r[1].as_str().unwrap(),
                r[3].as_bool().unwrap(),
            )
        })
        .collect();
    assert_eq!(
        rows,
        [
            (3, "system", false),
            (4, "system", false),
            (5, "verse", false),
            (6, "verse", false),
            (7, "verse", false),
            (10, "quote", true),
        ]
    );
    assert_eq!(chapter[4][2], "verse-by");
}
