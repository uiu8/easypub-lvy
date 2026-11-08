//! 性能样本（V83）：同一本确定性合成长稿，测规则统计、场景识别、成品文档与 EPUB 写出。
//! 默认不运行；手动执行：`cargo test --release -p easypub_app perf_samples -- --ignored --nocapture`。
use crate::publication_resources::{self, Request};
use easypub_core::source::{RULE_ID, SourceSnapshot};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::io::Cursor;
use std::sync::atomic::AtomicBool;
use std::time::Instant;

/// 约 6MB、3000 章：每章有正文、系统提示、诗句、场景分隔、注释、聊天与诏书。
fn long_book() -> String {
    let mut text = String::new();
    for n in 1..=3000 {
        text.push_str(&format!("第{n}章 标题{n}\n"));
        for p in 0..12 {
            text.push_str(&format!(
                "　　这是第{n}章第{p}段确定性正文，用来测量统计与生成的耗时，内容足够长以接近真实小说的段落长度。\n"
            ));
        }
        text.push_str("【叮！获得经验+120】\n【攻击力：20-25】\n【防御：12】\n");
        text.push_str("床前明月光，疑是地上霜。\n举头望明月，低头思故乡。\n");
        text.push_str("＊＊＊\n正文①继续。\n①注释内容。\n");
        if n % 10 == 0 {
            text.push_str("四：以雕像作为封印阵法。\n一：眉心开裂？\n四：有可能。\n");
            text.push_str("奉天承运 皇帝诏曰\n着即晋封国公。\n钦此\n");
        }
    }
    text
}

fn request(source: &SourceSnapshot, annotations: Value) -> Value {
    json!({"source_id": source.summary().source_id, "revision": 1,
        "settings": {"title":"性能样本", "author":"作者", "description":"", "language":"zh-CN",
            "cover_fit":"contain", "font_family":"SimSun", "font_size":20, "line_height":1.8,
            "include_toc":true, "illustrations":[],
            "scene_break_style":"keep", "first_paragraph_style":"no_indent", "system_block_style":"styled",
            "verse_block_style":"center", "note_style":"popup", "chat_block_style":"window",
            "letter_block_style":"ruled", "inset_detect":"on",
            "rule_options": {"disabled": ["layout.verse.five", "layout.inset.forum"]},
            "block_annotations": annotations}})
}

/// 200 条手工场景标注：每 15 章一条，标在每章第 1–3 段。
fn annotations(text: &str) -> Value {
    let mut out = Vec::new();
    for n in (1..=3000).step_by(15) {
        let head = format!("第{n}章 标题{n}\n");
        let start = text.find(&head).unwrap() + head.len();
        let rest = &text[start..];
        let end = start + rest.match_indices('\n').nth(2).unwrap().0 + 1;
        let piece = &text[start..end];
        out.push(
            json!({"id": format!("{:x}", Sha256::digest(format!("{n}").as_bytes())),
            "start": start, "end": end, "kind": "inset", "variant": "classic",
            "fingerprint": format!("{:x}", Sha256::digest(piece.as_bytes()))}),
        );
    }
    json!(out)
}

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(f64::total_cmp);
    v[v.len() / 2]
}

#[test]
#[ignore = "手动记录 V83 性能样本"]
fn perf_samples() {
    let text = long_book();
    let source = SourceSnapshot::from_utf8(text.clone().into_bytes(), RULE_ID, || false).unwrap();
    let marks = annotations(&text);
    let input = request(&source, marks);
    let parse = || -> Request { serde_json::from_value(input.clone()).unwrap() };
    let runs = 5;
    let mut timings = serde_json::Map::new();
    let mut time = |name: &str, f: &mut dyn FnMut()| {
        f(); // 预热
        let mut v = Vec::new();
        for _ in 0..runs {
            let t = Instant::now();
            f();
            v.push(t.elapsed().as_secs_f64() * 1000.0);
        }
        timings.insert(
            name.into(),
            json!({"median_ms": median(v.clone()), "runs_ms": v}),
        );
    };
    time("rule_statistics", &mut || {
        let r =
            crate::rule_statistics::calculate(&source, parse(), json!([]), &AtomicBool::new(false))
                .unwrap();
        assert!(r["rules"].as_array().unwrap().len() > 100);
    });
    let (book, settings) = publication_resources::compose(&source, parse()).unwrap();
    time("inset_plan", &mut || {
        let rules =
            crate::insets::Rules::from_settings(&settings.inset_detect, &settings.rule_options);
        let p = crate::insets::plan(
            &book.text,
            &book.tree.nodes,
            &settings.block_annotations,
            true,
            &rules,
        );
        assert!(p.len() > 1000);
    });
    time("prepare_documents", &mut || {
        let prepared = publication_resources::prepare(&source, parse()).unwrap();
        assert!(prepared.documents().unwrap().pages.len() > 2);
    });
    let prepared = publication_resources::prepare(&source, parse()).unwrap();
    time("epub_write", &mut || {
        let bytes = crate::epub::write(&prepared, Cursor::new(Vec::new()))
            .unwrap()
            .into_inner();
        assert!(bytes.len() > 100_000);
    });
    time("epub_write_preview", &mut || {
        let bytes = crate::epub::write_unpacked_preview(&prepared, Cursor::new(Vec::new()))
            .unwrap()
            .into_inner();
        assert!(bytes.len() > 100_000);
    });
    println!(
        "V83_PERF {}",
        json!({"bytes": text.len(), "chapters": 3000, "annotations": 200, "runs": runs, "timings": timings})
    );
}
