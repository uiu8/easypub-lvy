//! 只读调研探针：对一本 TXT 按成片的原因整批应用修复方案（只在内存里），报告耗时和前后问题数。
use easypub_core::{
    effective_edit::{self, Action, Request},
    effective_repair::candidates_for,
    encoding::EncodingMode,
    publication::compose,
    review::{Review, ReviewEvidence},
    source::{RULE_ID, SourceSnapshot},
    structure::Structure,
};
use std::time::Instant;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args_os().skip(1);
    let path = args.next().ok_or("需要 TXT 路径")?;
    let kinds = args
        .map(|a| a.to_string_lossy().into_owned())
        .collect::<Vec<_>>();
    let source = SourceSnapshot::from_bytes(std::fs::read(path)?, EncodingMode::Auto, RULE_ID, || false)
        .map_err(|e| format!("{e:?}"))?;
    let mut book = compose(&source, &Structure::new(&source), None).map_err(|e| format!("{e:?}"))?;
    let count = |book: &easypub_core::publication::EffectiveBook| -> Result<String, String> {
        let view = SourceSnapshot::for_effective_diagnostics(book).map_err(|e| format!("{e:?}"))?;
        let evidence = ReviewEvidence::new(&view).map_err(|e| format!("{e:?}"))?;
        let report = Review::default()
            .report_using(&evidence, 0, None, None)
            .map_err(|e| format!("{e:?}"))?;
        let d = &report["diagnostic"];
        Ok(format!(
            "共 {} 条 {} 原因 {}",
            d["review_unfiltered_total"],
            d["review_categories"],
            d["review_causes"]
                .as_array()
                .map(|c| c
                    .iter()
                    .map(|c| format!("{}:{}", c["kind"].as_str().unwrap_or(""), c["total"]))
                    .collect::<Vec<_>>()
                    .join(","))
                .unwrap_or_default()
        ))
    };
    println!("开始 {}", count(&book)?);
    for kind in kinds {
        // 一次最多 1000 条，剩下的再取。
        for round in 1..=5 {
            let started = Instant::now();
            let proposals = candidates_for(&book, Some(&format!("cause:{kind}:")));
            let listed = started.elapsed();
            let actions: Vec<Action> = proposals["items"]
                .as_array()
                .unwrap()
                .iter()
                .flat_map(|v| serde_json::from_value::<Vec<Action>>(v["actions"].clone()).unwrap())
                .collect();
            if actions.is_empty() {
                break;
            }
            let n = actions.len();
            let request = Request {
                base_id: effective_edit::base_id(&book),
                actions,
            };
            let started = Instant::now();
            match effective_edit::apply(book.clone(), &request) {
                Ok((next, _)) => {
                    if std::env::var_os("COMPARE").is_some() {
                        let slow = Instant::now();
                        let (step, _) = effective_edit::apply_stepwise(book.clone(), &request)
                            .map_err(|e| format!("{e:?}"))?;
                        println!(
                            "  逐个应用 {:?}；书稿相同 {}，结构相同 {}，行映射相同 {}",
                            slow.elapsed(),
                            step.text == next.text,
                            serde_json::to_value(&step.tree.nodes)? == serde_json::to_value(&next.tree.nodes)?,
                            step.source_to_output_lines == next.source_to_output_lines
                        );
                    }
                    book = next;
                    println!(
                        "{kind} 第 {round} 轮：{n} 项（共 {}），取方案 {listed:?}，应用 {:?}；之后 {}",
                        proposals["total"],
                        started.elapsed(),
                        count(&book)?
                    );
                }
                Err(e) => {
                    println!("{kind} 第 {round} 轮：{n} 项应用失败 {e:?}（{:?}）", started.elapsed());
                    break;
                }
            }
        }
    }
    Ok(())
}
