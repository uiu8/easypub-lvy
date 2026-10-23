use super::*;
use easypub_core::source::{RULE_ID, SourceSnapshot};
use std::{collections::BTreeMap, sync::Arc};

fn fixture() -> (ImportService, Value) {
    let source = Arc::new(SourceSnapshot::from_utf8("第一章 开始\n正文①\n***\n【系统通知】\n床前明月光，疑是地上霜。\n①说明\n第三章 结束\n正文\n".as_bytes().to_vec(),RULE_ID,||false).unwrap());
    let s = source.summary();
    let service = ImportService::new().unwrap();
    service
        .replace_sources(BTreeMap::from([(s.source_id.clone(), source)]))
        .unwrap();
    let settings = json!({"title":"样书","author":"","description":"","language":"zh-CN","cover_path":null,"cover_fit":"contain","font_family":"SimSun","font_size":20,"line_height":1.8,"include_toc":true,"illustrations":[]});
    let settings: Settings = serde_json::from_value(settings).unwrap();
    (
        service,
        json!({"book_id":"book","scope":"book","publication":{"source_id":s.source_id,"revision":s.revision,"settings":settings},"base":{"structure":null,"manual":null,"cleanup":null},"configuration":{},"effective_history":null,"production_history":null,"cleanup_draft":null,"history":null}),
    )
}
fn call(service: &ImportService, input: &Value, action: &str) -> Result<Value, ApiError> {
    let mut v = input.clone();
    v["action"] = json!(action);
    run(service, v).map(|s| serde_json::from_str(&s).unwrap())
}
fn install(input: &mut Value, result: &Value) {
    let next = &result["snapshot"];
    input["publication"]["settings"] = next["settings"].clone();
    input["effective_history"] = next["effective_history"].clone();
    input["production_history"] = next["production_history"].clone();
    input["history"] = result["history"].clone();
    let h = &input["effective_history"];
    input["publication"]["post_edits"] = if h.is_null() {
        Value::Null
    } else {
        h["history"][h["cursor"].as_u64().unwrap() as usize]["request"].clone()
    };
}
#[test]
fn restore_keeps_undone_edits_but_rejects_applied_edits() {
    let (service, mut input) = fixture();
    input["changes"] = json!([{"id":"layout.scene.u002a","enabled":false}]);
    let preview = call(&service, &input, "preview_toggles").unwrap();
    input["plan_id"] = preview["plan_id"].clone();
    let applied = call(&service, &input, "apply_toggles").unwrap();
    install(&mut input, &applied);
    let source_id = input["publication"]["source_id"]
        .as_str()
        .unwrap()
        .to_owned();
    let raw = service
        .effective_structure_text(source_id.clone(), 1, String::new(), String::new(), 0)
        .unwrap();
    let tree: Value = serde_json::from_str(&raw).unwrap();
    let edit = |history: String, command: Value| -> Value {
        serde_json::from_str(
            &crate::effective_draft::edit(
                &service,
                source_id.clone(),
                1,
                input["base"].to_string(),
                history,
                command.to_string(),
            )
            .unwrap(),
        )
        .unwrap()
    };
    let renamed = edit(
        String::new(),
        json!({"op":"append","action":{"kind":"rename","entry_id":tree["nodes"][0]["entry_id"],"title":"第一章 已编辑"}}),
    );
    let undone = edit(renamed["history"].to_string(), json!({"op":"undo"}));
    input["effective_history"] = renamed["history"].clone();
    input["undo"] = json!(true);
    assert!(call(&service, &input, "restore_toggles").is_err());
    input["effective_history"] = undone["history"].clone();
    let rollback = call(&service, &input, "restore_toggles").unwrap();
    install(&mut input, &rollback);
    assert!(input["effective_history"].is_null());
    input["undo"] = json!(false);
    let redo = call(&service, &input, "restore_toggles").unwrap();
    install(&mut input, &redo);
    assert_eq!(input["effective_history"], undone["history"]);
}
#[test]
fn groups_preview_apply_undo_atomic_stale_and_global() {
    let (service, mut input) = fixture();
    let original = input.clone();
    input["changes"] = json!([
        {"id":"check.number_gap","enabled":false},
        {"id":"chapter.recognize.author_note","enabled":false},
        {"id":"layout.scene.u002a","enabled":false},
        {"id":"layout.verse.five","enabled":false},
        {"id":"layout.note.bracket","enabled":false},
        {"id":"cleanup.trim_trailing_spaces","enabled":false},
        {"id":"catalog_check.missing","enabled":false},
        {"id":"preflight.language","enabled":false}
    ]);
    let preview = call(&service, &input, "preview_toggles").unwrap();
    assert_eq!(preview["applied"], false);
    assert_eq!(
        preview["impact"]["before"]["content_id"],
        preview["impact"]["after"]["content_id"]
    );
    assert!(preview["history"].is_null());
    input["plan_id"] = preview["plan_id"].clone();
    let mut stale = input.clone();
    stale["configuration"]["check_after_import"] = json!(false);
    assert!(call(&service, &stale, "apply_toggles").is_err());
    let mut broken = input.clone();
    broken["changes"]
        .as_array_mut()
        .unwrap()
        .push(json!({"id":"preflight.title","enabled":false}));
    assert!(call(&service, &broken, "preview_toggles").is_err());
    let applied = call(&service, &input, "apply_toggles").unwrap();
    install(&mut input, &applied);
    let settings = call(&service, &input, "settings").unwrap();
    for change in original_changes(&input) {
        let row = settings["rules"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["id"] == change["id"])
            .unwrap();
        assert_eq!(row["enabled"], false, "{row}");
    }
    input["undo"] = json!(true);
    let undone = call(&service, &input, "restore_toggles").unwrap();
    install(&mut input, &undone);
    assert_eq!(
        input["publication"]["settings"],
        original["publication"]["settings"]
    );
    assert!(input["effective_history"].is_null());
    input["undo"] = json!(false);
    let redone = call(&service, &input, "restore_toggles").unwrap();
    assert_eq!(redone["snapshot"], applied["snapshot"]);
    let mut global = original.clone();
    global["scope"] = json!("global");
    global["changes"] = json!([{"id":"check.number_gap","enabled":false}]);
    let p = call(&service, &global, "preview_toggles").unwrap();
    global["plan_id"] = p["plan_id"].clone();
    let a = call(&service, &global, "apply_toggles").unwrap();
    assert!(a["snapshot"]["effective_history"].is_null());
    assert_eq!(
        a["defaults"]["rules"]["disabled_checks"],
        json!(["number_gap"])
    );
    assert_eq!(
        call(&service, &original, "settings").unwrap()["rules"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["id"] == "check.number_gap")
            .unwrap()["enabled"],
        true
    );
}
fn original_changes(v: &Value) -> Vec<Value> {
    v["changes"].as_array().unwrap().clone()
}

#[test]
fn check_subtypes_fingerprint_and_cleanup_options_are_independent() {
    let text =
        "第一章 甲\n正文甲。\n第一章 乙\n正文乙。\n第三章 丙\n正文丙。\n第二章 丁\n正文丁。\n";
    let source = SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
    let mut rules = RuleSet::default();
    let structure = easypub_core::structure::Structure::recognized(&source);
    let before = easypub_core::publication::compose(&source, &structure, None).unwrap();
    let fingerprint = easypub_core::effective_edit::base_id(&before);
    rules.disabled_checks = vec!["number_reset.repeated_number".into()];
    let (after, _) = easypub_core::chapter_rules::rebuild(before.clone(), &rules, true).unwrap();
    assert_ne!(easypub_core::effective_edit::base_id(&after), fingerprint);
    assert_eq!(json!(before.tree.nodes), json!(after.tree.nodes));
    let view = SourceSnapshot::for_effective_diagnostics(&after).unwrap();
    let plan: Value =
        serde_json::from_str(&view.repair_plan_json("[\"number-reset\"]").unwrap()).unwrap();
    assert_eq!(plan["actions"].as_array().unwrap().len(), 1);
    assert_eq!(plan["actions"][0]["subtype"], "number-reversal");
    let mut p = json!([{"kind":"notice_lines","options":{"include_defaults":true,"include_headers":true,"keywords":["特定广告"]}}]);
    toggle_cleanup(&mut p, "cleanup.site_notices", false).unwrap();
    assert!(!cleanup_enabled(&p, "cleanup.site_notices"));
    assert!(cleanup_enabled(&p, "cleanup.repeated_headers"));
    toggle_cleanup(&mut p, "cleanup.site_notices", true).unwrap();
    assert_eq!(p[0]["rule"]["options"]["keywords"], json!(["特定广告"]));
    toggle_cleanup(&mut p, "cleanup.repeated_headers", false).unwrap();
    assert!(cleanup_enabled(&p, "cleanup.site_notices"));
    assert!(!cleanup_enabled(&p, "cleanup.repeated_headers"));
}

#[test]
fn layout_reenable_restores_previous_value_and_missing_catalog_is_unavailable() {
    let (service, mut v) = fixture();
    v["publication"]["settings"]["verse_block_style"] = json!("indent");
    v["changes"] = json!([{"id":"layout.verse","enabled":false}]);
    let p = call(&service, &v, "preview_toggles").unwrap();
    assert!(
        p["impact"]["before"]["rules"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|r| r["id"].as_str().unwrap().starts_with("catalog_check."))
            .all(|r| r["status"] == "unavailable" && r["count"].is_null())
    );
    v["plan_id"] = p["plan_id"].clone();
    let a = call(&service, &v, "apply_toggles").unwrap();
    install(&mut v, &a);
    assert_eq!(v["publication"]["settings"]["verse_block_style"], "off");
    v["changes"][0]["enabled"] = json!(true);
    let p = call(&service, &v, "preview_toggles").unwrap();
    assert_eq!(p["snapshot"]["settings"]["verse_block_style"], "indent");
}

#[test]
fn real_simulations_cover_four_interaction_families_and_render_toggles() {
    let cases = [
        (
            "第一章 起\n床前明月光，疑是地上霜\n春风又绿江南岸，明月何时照我还。\n",
            json!([{"kind":"join_hard_wraps","min_chars":1,"mode":"chinese"}]),
            "cleanup.join_hard_wraps",
            "layout.verse",
            json!({}),
        ),
        (
            "第一章 起\n【请收藏本站】\n正文。\n",
            json!([{"kind":"notice_lines","options":{"keywords":["请收藏"],"include_defaults":false,"include_headers":false}}]),
            "cleanup.site_notices",
            "layout.system",
            json!({}),
        ),
        (
            "第一章 起\n＃＃＃\n正文。\n",
            json!([{"kind":"normalize_width"}]),
            "cleanup.normalize_width",
            "layout.scene",
            json!({"scene_symbols":"＃"}),
        ),
        (
            "第一章 起\n﹡﹡﹡\n正文。\n",
            json!([{"kind":"normalize_punctuation"}]),
            "cleanup.normalize_punctuation",
            "layout.scene",
            json!({"scene_symbols":"﹡"}),
        ),
    ];
    for (text, pipeline, id, target, options) in cases {
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let (_, mut v) = fixture();
        v["publication"]["source_id"] = json!(source.summary().source_id);
        v["publication"]["settings"]["rule_options"] = options;
        let r = crate::rule_statistics::calculate(
            &source,
            decode(&v["publication"]).unwrap(),
            pipeline,
            &AtomicBool::new(false),
        )
        .unwrap();
        let row = r["rules"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["id"] == id)
            .unwrap();
        if id == "cleanup.normalize_width" || id == "cleanup.normalize_punctuation" {
            assert!(
                row["affects"].as_array().unwrap().is_empty(),
                "当前转换字符表不包含场景符号：{row}"
            );
        } else {
            assert!(
                row["affects"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|a| a["rule"] == target && a["count"].as_u64().unwrap() > 0),
                "{id}: {row}"
            );
        }
    }
    let source = SourceSnapshot::from_utf8(
        "第一章 起\n正文[1]。\n[1]说明\n【系统提示】\n正文\n"
            .as_bytes()
            .to_vec(),
        RULE_ID,
        || false,
    )
    .unwrap();
    let (_, mut v) = fixture();
    v["publication"]["source_id"] = json!(source.summary().source_id);
    let rules = RuleSet {
        force_heading: "[1]说明\n【系统提示】".into(),
        ..Default::default()
    };
    let mut structure = easypub_core::structure::Structure::new(&source);
    structure.recognition_rules = Some(rules.clone());
    structure.overrides = rules.compile().unwrap().recognize(&source);
    v["publication"]["structure"] = json!(structure);
    let r = crate::rule_statistics::calculate(
        &source,
        decode(&v["publication"]).unwrap(),
        json!([]),
        &AtomicBool::new(false),
    )
    .unwrap();
    let row = r["rules"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["id"] == "chapter.recognize.force_heading")
        .unwrap();
    for target in ["layout.system", "layout.note"] {
        assert!(
            row["affects"]
                .as_array()
                .unwrap()
                .iter()
                .any(|a| a["rule"] == target),
            "{row}"
        );
    }
    let (service, mut input) = fixture();
    input["publication"]["settings"]["note_style"] = json!("popup");
    input["changes"] = json!([{"id":"layout.scene.u002a","enabled":false},{"id":"layout.verse.five","enabled":false},{"id":"layout.note.circled","enabled":false}]);
    let p = call(&service, &input, "preview_toggles").unwrap();
    input["publication"]["settings"] = p["snapshot"]["settings"].clone();
    let src = service
        .source(input["publication"]["source_id"].as_str().unwrap(), 1)
        .unwrap();
    let documents = publication_resources::prepare(&src, decode(&input["publication"]).unwrap())
        .unwrap()
        .documents()
        .unwrap();
    let html = &documents.pages["body.xhtml"];
    assert!(!html.contains("class=\"verse-block"));
    assert!(!html.contains("epub:type=\"noteref\""));
    assert!(html.contains("***"));
}
