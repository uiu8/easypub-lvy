//! R2 开发探针：真实导入、取消，以及有效稿编辑/撤销/重做；只读取传入样本。
use easypub_app::{effective_draft, sessions::ImportService};
use easypub_core::source::RULE_ID;
use serde_json::{Value, json};
use std::{
    thread,
    time::{Duration, Instant},
};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    assert_eq!(
        args.len(),
        3,
        "usage: r2_backend_perf import|cancel|chapters|diagnostics|cleanup FILE"
    );
    let service = ImportService::new().expect("import service");
    let started = Instant::now();
    let job = service
        .start_import(args[2].clone(), RULE_ID.into())
        .expect("start");
    let mut progress = Vec::new();
    let mut last = (String::new(), 0);
    let mut cancelled_at = None;
    let summary = loop {
        assert!(
            started.elapsed() < Duration::from_secs(180),
            "import timeout"
        );
        let state = service.get_job(job).expect("status");
        let point = (format!("{:?}", state.phase), state.processed_bytes);
        if point != last {
            progress.push(json!({"ms":started.elapsed().as_secs_f64()*1000.0,
                "phase":point.0,"processed_bytes":point.1}));
            last = point;
        }
        if args[1] == "cancel"
            && cancelled_at.is_none()
            && state.processed_bytes > 0
            && !state.terminal()
        {
            cancelled_at = Some(Instant::now());
            service.cancel_job(job).expect("cancel");
        }
        if state.terminal() {
            if args[1] == "cancel" {
                assert_eq!(state.phase, easypub_app::sessions::JobPhase::Cancelled);
                println!(
                    "{}",
                    json!({"mode":"cancel","progress":progress,
                    "cancel_ms":cancelled_at.expect("cancellation sent").elapsed().as_secs_f64()*1000.0})
                );
                return;
            }
            assert_eq!(
                state.phase,
                easypub_app::sessions::JobPhase::Completed,
                "{:?}",
                state.error
            );
            break state.book.expect("book");
        }
        thread::sleep(Duration::from_millis(1));
    };
    let import_ms = started.elapsed().as_secs_f64() * 1000.0;
    let mut edits = Vec::new();
    if args[1] == "cleanup" {
        let request = json!({"kind":"cleanup","rules":["trim_trailing_spaces","collapse_blank_lines","remove_ad_lines"]});
        let mut first = String::new();
        for stage in ["cold", "repeat"] {
            let watch = Instant::now();
            let result = service
                .preview_repair_plan(
                    summary.source_id.clone(),
                    summary.revision,
                    request.to_string(),
                )
                .expect("cleanup preview");
            edits.push(json!({"operation":"cleanup_preview","stage":stage,"ms":watch.elapsed().as_secs_f64()*1000.0}));
            if stage == "cold" {
                first = result;
            } else {
                assert_eq!(result, first);
            }
        }
    }
    if args[1] == "diagnostics" {
        let mut key = Value::Null;
        let mut actions = None;
        for stage in ["cold", "cached"] {
            let watch = Instant::now();
            let raw = service.effective_structure_text(summary.source_id.clone(), summary.revision,
                String::new(), json!({"kind":"publication","composition_key":key,"effective_check":{"offset":0}}).to_string(), 0).expect("check and repair candidates");
            let result: Value = serde_json::from_str(&raw).unwrap();
            actions = result["effective_check"]["repairs"]["items"]
                .as_array()
                .and_then(|items| items.iter().find(|item| item["recommended"] == true))
                .map(|item| item["actions"].clone());
            edits.push(
                json!({"operation":"check_and_repair_candidates","stage":stage,
                "ms":watch.elapsed().as_secs_f64()*1000.0,
                "findings":result["effective_check"]["report"]["diagnostic"]["review_total"],
                "repairs":result["effective_check"]["repairs"]["total"]}),
            );
            key = result["composition_key"].clone();
        }
        if let Some(actions) = actions {
            let watch = Instant::now();
            effective_draft::edit(
                &service,
                summary.source_id.clone(),
                summary.revision,
                json!({"structure":null,"manual":null,"cleanup":null}).to_string(),
                String::new(),
                json!({"op":"append_batch","actions":actions}).to_string(),
            )
            .expect("apply safe repair");
            edits.push(json!({"operation":"apply_first_safe_repair","ms":watch.elapsed().as_secs_f64()*1000.0}));
        }
    }
    if args[1] == "chapters" {
        let raw = service
            .effective_structure_text(
                summary.source_id.clone(),
                summary.revision,
                String::new(),
                String::new(),
                0,
            )
            .expect("tree");
        let tree: Value = serde_json::from_str(&raw).expect("tree JSON");
        let first = &tree["nodes"][0]["entry_id"];
        let second = &tree["nodes"][1]["entry_id"];
        let third = &tree["nodes"][2]["entry_id"];
        let base = json!({"structure":null,"manual":null,"cleanup":null}).to_string();
        let operations = [
            (
                "rename",
                json!({"kind":"rename","entry_id":first,"title":"第一章 新标题"}),
            ),
            (
                "split",
                json!({"kind":"split","entry_id":first,"line_offset":2,"title":"第10001章 新章节"}),
            ),
            (
                "merge",
                json!({"kind":"merge_into","entry_id":second,"target_id":first}),
            ),
            (
                "move",
                json!({"kind":"move_subtree","entry_id":first,"before_id":third}),
            ),
            (
                "delete_body",
                json!({"kind":"exclude_body_lines","entry_id":first,"first_offset":1,"last_offset":2}),
            ),
            (
                "demote_heading",
                json!({"kind":"classify","entry_id":second,"role":"body","depth":0,"include_toc":false}),
            ),
        ];
        for (name, action) in operations {
            let mut history = String::new();
            for (stage, command) in [
                ("apply", json!({"op":"append","action":action})),
                ("undo", json!({"op":"undo"})),
                ("redo", json!({"op":"redo"})),
            ] {
                let watch = Instant::now();
                let raw = effective_draft::edit(
                    &service,
                    summary.source_id.clone(),
                    summary.revision,
                    base.clone(),
                    history,
                    command.to_string(),
                )
                .expect(name);
                let elapsed_ms = watch.elapsed().as_secs_f64() * 1000.0;
                let result: Value = serde_json::from_str(&raw).expect("history JSON");
                assert_eq!(
                    result["history"]["cursor"],
                    if stage == "undo" { 0 } else { 1 }
                );
                history = result["history"].to_string();
                edits.push(json!({"operation":name,"stage":stage,"ms":elapsed_ms}));
            }
        }
    }
    println!(
        "{}",
        json!({"mode":args[1],"import_ms":import_ms,"chapters":summary.chapter_count,
            "lines":summary.line_count,"progress":progress,"edits":edits})
    );
}
