//! 只读调研探针：对一本 TXT 输出检查问题的全部条目和每条内置清理规则单独执行的结果。
use easypub_core::{
    cleanup,
    encoding::EncodingMode,
    review::{Review, ReviewEvidence},
    source::{RULE_ID, SourceSnapshot},
};
use serde_json::{Value, json};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = std::env::args_os().nth(1).ok_or("需要 TXT 路径")?;
    let bytes = std::fs::read(path)?;
    let size = bytes.len();
    let source = SourceSnapshot::from_bytes(bytes, EncodingMode::Auto, RULE_ID, || false)
        .map_err(|e| format!("{e:?}"))?;
    let evidence = ReviewEvidence::new(&source).map_err(|e| format!("{e:?}"))?;
    let items = Review::default()
        .all_using(&evidence)
        .map_err(|e| format!("{e:?}"))?;
    let rules: Vec<(&str, Value)> = vec![
        ("trim", json!({"kind":"trim_trailing_spaces"})),
        ("blank", json!({"kind":"collapse_blank_lines"})),
        ("ads", json!({"kind":"remove_ad_lines"})),
        ("invisible", json!({"kind":"remove_invisible"})),
        ("width", json!({"kind":"normalize_width"})),
        ("compat", json!({"kind":"normalize_punctuation"})),
        (
            "cnpunct",
            json!({"kind":"chinese_punctuation","options":{"marks":true,"ellipsis":true,"dashes":true,"quotes":true}}),
        ),
        ("ocrspace", json!({"kind":"ocr_han_spaces"})),
        ("ocrdots", json!({"kind":"ocr_ellipsis"})),
        (
            "wraps",
            json!({"kind":"join_hard_wraps","mode":"chinese","min_chars":12}),
        ),
        ("dups", json!({"kind":"remove_duplicate_titles"})),
        ("promo", json!({"kind":"inline_promotion"})),
        ("tail", json!({"kind":"heading_tail"})),
        ("notes", json!({"kind":"author_notes"})),
        ("paging", json!({"kind":"paging_residue"})),
        (
            "notices",
            json!({"kind":"notice_lines","options":{"include_defaults":true,"include_headers":true,"ignore_case":true,"keywords":[],"preserve_keywords":[],"pattern":null,"preserve_pattern":null}}),
        ),
    ];
    let mut cleanup_out = serde_json::Map::new();
    for (id, rule) in rules {
        let request = json!({"kind":"cleanup","pipeline":[{"kind":"configured","enabled":true,"scope":"all","rule":rule}]});
        match cleanup::prepare(&source, &request.to_string()) {
            Ok(plan) => {
                let preview: Value = serde_json::from_str(&plan.preview())?;
                cleanup_out.insert(
                    id.to_owned(),
                    json!({
                        "change_count": preview["change_count"],
                        "candidate_count": preview["candidate_count"],
                        "stage_count": preview["stage_count"],
                        "actions": preview["actions"],
                        "candidates": preview["candidates"],
                    }),
                );
            }
            Err(e) => {
                cleanup_out.insert(id.to_owned(), json!({"error": format!("{e:?}")}));
            }
        }
    }
    let headings = source
        .headings()
        .iter()
        .map(|h| json!([h.source_line, h.title]))
        .collect::<Vec<_>>();
    println!(
        "{}",
        json!({
            "bytes": size,
            "encoding": source.summary().encoding,
            "lines": source.summary().line_count,
            "chapters": source.summary().chapter_count,
            "headings": headings,
            "items": items,
            "causes": Review::default()
                .report_using(&evidence, 0, None, None)
                .map_err(|e| format!("{e:?}"))?["diagnostic"]["review_causes"],
            "cleanup": cleanup_out,
        })
    );
    Ok(())
}
