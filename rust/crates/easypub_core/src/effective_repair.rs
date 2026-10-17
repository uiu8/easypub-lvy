//! Safe proposals derived from the effective tree, never from UI-supplied labels.
use crate::{
    ApiError, ErrorCode,
    publication::EffectiveBook,
    structure::{Node, Role},
};
use serde_json::{Value, json};

fn safe_pair(book: &EffectiveBook, previous: &Node, node: &Node) -> bool {
    matches!(node.role, Role::Chapter | Role::Section)
        && previous.role == node.role
        && previous.depth == node.depth
        && previous.parent_id == node.parent_id
        && previous.include_toc == node.include_toc
        && previous.title == node.title
        && previous.end == node.start
        && book.text[previous.body_start..node.start].trim().is_empty()
}

pub fn target<'a>(book: &'a EffectiveBook, entry_id: &str) -> Result<&'a Node, ApiError> {
    book.tree
        .nodes
        .windows(2)
        .find(|pair| pair[1].entry_id == entry_id && safe_pair(book, &pair[0], &pair[1]))
        .map(|pair| &pair[0])
        .ok_or_else(|| {
            ApiError::new(
                ErrorCode::InvalidRule,
                "effective_repair",
                "recheck_duplicate_heading_evidence",
            )
        })
}

/// Proposals include executable commands and a separate recommendation flag.
/// Being selectable is not permission to apply it without a preview.
pub fn candidates(book: &EffectiveBook) -> Value {
    candidates_for(book, None)
}

pub fn candidates_for(book: &EffectiveBook, focus: Option<&str>) -> Value {
    let mut items = Vec::new();
    // 用户在识别规则中允许重复的标题不提议移除（CH-258）。
    let rules = book
        .tree
        .recognition_rules
        .as_ref()
        .and_then(|r| r.compile().ok());
    for pair in book.tree.nodes.windows(2).filter(|p| {
        safe_pair(book, &p[0], &p[1])
            && !rules
                .as_ref()
                .is_some_and(|r| r.allows_duplicate_title(&p[1].title))
    }) {
        let before = &book.text[pair[0].start..pair[1].body_start];
        items.push(
            json!({"finding_id":format!("duplicate-title:{}",pair[1].entry_id),
            "entry_id":pair[1].entry_id,"title":format!("移除重复标题：{}",pair[1].title),
            "line":pair[1].source_line,"kept_line":pair[0].source_line,
            "before":before.chars().take(2000).collect::<String>(),
            "after":book.text[pair[0].start..pair[1].start].chars().take(2000).collect::<String>(),
            "truncated":before.chars().count()>2000,"recommended":true,
            "actions":[{"kind":"remove_duplicate_heading","entry_id":pair[1].entry_id}]}),
        );
    }
    let view = crate::source::SourceSnapshot::for_effective_diagnostics(book)
        .expect("valid effective text");
    for group in crate::duplicate_blocks::find(&view).expect("bounded effective headings") {
        for occurrence in group.occurrences.iter().skip(1) {
            let n = book
                .tree
                .nodes
                .iter()
                .find(|n| n.entry_id == occurrence.entry_id)
                .unwrap();
            if n.role != Role::Chapter
                || book
                    .tree
                    .nodes
                    .iter()
                    .any(|child| child.parent_id.as_deref() == Some(n.entry_id.as_str()))
            {
                continue;
            }
            let kept = &group.occurrences[0];
            items.push(json!({"finding_id":format!("duplicate-content:{}",n.entry_id),"entry_id":n.entry_id,
                "title":format!("保留第{}行一份，排除第{}行重复章及正文",kept.start_line,n.source_line),
                "line":n.source_line,"kept_line":kept.start_line,"before":book.text[n.start..n.end].chars().take(2000).collect::<String>(),
                "after":format!("排除本章第{}—{}行；保留第{}行开始的完整副本",occurrence.start_line,occurrence.end_line,kept.start_line),
                "truncated":book.text[n.start..n.end].chars().count()>2000,"recommended":false,
                "actions":[{"kind":"exclude_duplicate_chapter","entry_id":n.entry_id,"kept_id":kept.entry_id}]}));
        }
    }
    let diagnostic: Value = serde_json::from_str(
        &view
            .repair_plan_json(r#"["number-reset"]"#)
            .expect("diagnostic plan"),
    )
    .unwrap();
    for finding in diagnostic["actions"].as_array().unwrap() {
        if let Some(n) = book.tree.nodes.iter().find(|n| {
            Some(n.entry_id.as_str()) == finding["entry_id"].as_str()
                && n.role == Role::Chapter
                && n.depth == 0
        }) {
            let number = crate::source::numbered_heading(&n.title).map(|v| v.0);
            let previous = finding["before_title"]
                .as_str()
                .and_then(crate::source::numbered_heading)
                .map(|v| v.0);
            // A small typo or an author note is not evidence of a new volume.
            // A restart near one following a substantial run is only a proposal.
            if crate::recognition::is_author_note_heading(&n.title)
                || !matches!((previous, number), (Some(old), Some(new)) if old >= 10 && (1..=3).contains(&new))
            {
                continue;
            }
            let position = book
                .tree
                .nodes
                .iter()
                .position(|node| node.entry_id == n.entry_id)
                .expect("selected node");
            let sequence = book
                .tree
                .nodes
                .iter()
                .skip(position + 1)
                .take(2)
                .enumerate()
                .all(|(i, node)| {
                    node.role == Role::Chapter
                        && node.depth == n.depth
                        && node.parent_id == n.parent_id
                        && crate::source::numbered_heading(&node.title).map(|v| v.0)
                            == number.and_then(|n| n.checked_add(i as u32 + 1))
                });
            if !sequence || book.tree.nodes.len().saturating_sub(position + 1) < 2 {
                continue;
            }
            items.push(json!({"finding_id":finding["id"],"entry_id":n.entry_id,"line":n.source_line,"kept_line":n.source_line,
                "title":"编号重新开始：核对是否新卷","before":n.title,"after":format!("在《{}》前建立临时分卷；需确认新卷起点",n.title),
                "recommended":false,"truncated":false,"actions":[{"kind":"insert_volume","entry_id":n.entry_id,"title":format!("临时分卷（从{}开始）",n.title)}]}));
        }
    }
    for n in view.prose_headings() {
        items.push(json!({"finding_id":format!("prose-heading:{}",n.entry_id),"entry_id":n.entry_id,
            "title":"还原为正文（保留整句文字）","line":n.source_line,"kept_line":n.source_line,
            "before":format!("目录中的标题：{}",n.title),"after":format!("正文：{}",n.title),
            "truncated":false,"recommended":false,
            "actions":[{"kind":"classify","entry_id":n.entry_id,"role":"body","depth":0,"include_toc":false}]}));
    }
    for (line, title) in view.unrecognized_headings() {
        if let Some(action) = boundary_action(book, line, None) {
            items.push(json!({"finding_id":format!("unrecognized-heading:{line}"),
                "entry_id":action["entry_id"].as_str().unwrap_or("$prefix"),"title":"从这行建立章节",
                "line":line,"kept_line":line,"before":format!("正文中的一行：{title}"),
                "after":format!("章节标题：{title}\n正文内容保持不变"),"truncated":false,"recommended":false,"actions":[action]}));
        }
    }
    for c in crate::heading_typos::find(&view) {
        if let Some(action) = boundary_action(book, c.source_line, Some(c.title.clone())) {
            items.push(json!({"finding_id":format!("heading-number-typo:{}",c.source_line),
                "entry_id":action["entry_id"].as_str().unwrap_or("$prefix"),"title":"修订这行标题并收入目录",
                "line":c.source_line,"kept_line":c.source_line,"before":c.before,"after":c.title,
                "truncated":false,"recommended":false,"actions":[action]}));
        }
    }
    let missing_prefix: std::collections::BTreeSet<u32> = view
        .missing_prefix_chapters()
        .iter()
        .map(|c| c.source_line)
        .collect();
    for n in &book.tree.nodes {
        if crate::source::missing_heading_prefix(&n.title)
            && missing_prefix.contains(&n.source_line)
        {
            items.push(json!({"finding_id":format!("missing-heading-prefix:{}",n.entry_id),
                "entry_id":n.entry_id,"title":"给标题补上“第”（也可保留原写法）", "line":n.source_line,"kept_line":n.source_line,
                "before":n.title,"after":format!("第{}",n.title),"truncated":false,"recommended":false,
                "actions":[{"kind":"rename","entry_id":n.entry_id,"title":format!("第{}",n.title)}]}));
        }
    }
    if let Some(id) = focus {
        items.retain(|p| {
            p["finding_id"] == id
                || (id.ends_with(':')
                    && p["finding_id"].as_str().is_some_and(|v| v.starts_with(id)))
        });
    }
    let total = items.len();
    items.truncate(if focus == Some("unrecognized-heading:") {
        1000
    } else {
        100
    });
    json!({"total":total,"items":items})
}

/// Locate a real line in the current manuscript; never manufacture a body range.
pub fn boundary_action(book: &EffectiveBook, line: u32, title: Option<String>) -> Option<Value> {
    if book.tree.nodes.iter().any(|n| n.source_line == line) {
        return None;
    }
    let node = book.tree.nodes.iter().rev().find(|n| n.source_line < line);
    let (id, start, depth) = node
        .map(|n| {
            (
                Some(n.entry_id.as_str()),
                n.source_line,
                if n.role == Role::Volume {
                    n.depth + 1
                } else {
                    n.depth
                },
            )
        })
        .unwrap_or((None, 0, 0));
    Some(if let Some(title) = title {
        json!({"kind":"restore_heading","entry_id":id,"line_offset":line-start,"title":title,"depth":depth})
    } else {
        json!({"kind":"create_boundary","entry_id":id,"line_offset":line-start,"role":"chapter","depth":depth,"include_toc":true})
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        effective_edit::{self, Action, Request},
        publication::compose,
        source::{RULE_ID, SourceSnapshot},
        structure::Structure,
    };

    #[test]
    fn numeric_run_is_found_even_with_an_unnumbered_bonus_chapter() {
        let text = "番外：生日\n正文\n238：以命换伤！\n甲正文\n第二段\n第三段\n239：“新的开始”\n乙正文\n第二段\n第三段\n240：一切结束。\n丙正文\n第二段\n第三段\n1 条目甲\n2 条目乙\n3 条目丙\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let book = compose(&source, &Structure::new(&source), None).unwrap();
        let proposals = candidates_for(&book, Some("unrecognized-heading:"));
        assert_eq!(proposals["total"], 3);
        let actions = proposals["items"]
            .as_array()
            .unwrap()
            .iter()
            .rev()
            .flat_map(|v| serde_json::from_value::<Vec<Action>>(v["actions"].clone()).unwrap())
            .collect();
        let request = Request {
            base_id: effective_edit::base_id(&book),
            actions,
        };
        let partial = Request {
            base_id: request.base_id.clone(),
            actions: request.actions[..2].to_vec(),
        };
        let (partly_changed, _) = effective_edit::apply(book.clone(), &partial).unwrap();
        assert_eq!(
            candidates_for(&partly_changed, Some("unrecognized-heading:"))["total"],
            1
        );
        let changed = effective_edit::apply(book, &request).unwrap().0;
        assert_eq!(changed.tree.nodes.len(), 4);
        assert_eq!(
            candidates_for(&changed, Some("unrecognized-heading:"))["total"],
            0
        );
        assert_eq!(source.original_bytes(), text.as_bytes());
    }

    #[test]
    fn author_note_in_toc_is_not_offered_a_heading_prefix() {
        // 作者说明被收进目录时：只建议还原为正文，不再建议改名为“第两章合一章”。
        let text = "第137章 前章\n正文\n两章合一章，更比两章强！\n感谢支持\n第138章 后章\n正文\n12章 无前缀的真标题\n正文\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let mut structure = Structure::new(&source);
        structure
            .put(
                &source,
                crate::structure::Override {
                    source_line: 3,
                    role: crate::structure::Role::Chapter,
                    depth: 0,
                    include_toc: true,
                },
            )
            .unwrap();
        let book = compose(&source, &structure, None).unwrap();
        assert!(book.tree.nodes.iter().any(|n| n.title.starts_with("两章合一章")));
        let prefix = candidates_for(&book, Some("missing-heading-prefix:"));
        let titles: Vec<_> = prefix["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|i| i["before"].as_str().unwrap().to_owned())
            .collect();
        assert_eq!(titles, ["12章 无前缀的真标题"]);
        assert_eq!(candidates_for(&book, Some("prose-heading:"))["total"], 1);
    }

    #[test]
    fn author_notes_and_small_backsteps_never_propose_volumes() {
        for note in [
            "（两章加起来5400多字的超大杯，已经差不多等于三更了！）",
            "（两章加起来依旧5000字以上！）",
        ] {
            assert!(crate::recognition::is_author_note_heading(note));
            let text = format!("第133章 前章\n正文\n{note}\n第132章 后章\n正文\n");
            let source =
                SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
            let book = compose(&source, &Structure::new(&source), None).unwrap();
            assert_eq!(candidates_for(&book, Some("number-reset:"))["total"], 0);
            assert_eq!(source.original_bytes(), text.as_bytes());
        }
        assert!(!crate::recognition::is_author_note_heading(
            "（第二章 月光）"
        ));
        assert!(!crate::recognition::is_author_note_heading(
            "（第二章 系统更新）"
        ));
        let text =
            "第20章 旧卷结束\n正文\n第1章 新的开始\n正文\n第2章 继续\n正文\n第3章 新卷继续\n正文\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let book = compose(&source, &Structure::new(&source), None).unwrap();
        let proposals = candidates_for(&book, Some("number-reset:"));
        assert_eq!(proposals["total"], 1);
        assert_eq!(proposals["items"][0]["recommended"], false);
    }

    #[test]
    fn optional_repairs_execute_real_ranges_and_recheck() {
        for (text, category, expected) in [
            (
                "第一百一十八章 前\n正文\n第一百一十久章 后续久字保留\n正文\n第一百二十章 后\n正文\n",
                "heading-number-typo",
                "第一百一十九章 后续久字保留",
            ),
            (
                "第1章 开始\n甲文\n2 中间\n乙文\n第3章 结束\n丙文\n",
                "unrecognized-heading",
                "2 中间",
            ),
            (
                "第1章 相同\n相同正文\n第1章 相同\n相同正文\n第2章 结束\n丙文\n",
                "duplicate-content",
                "第2章 结束",
            ),
        ] {
            let source =
                SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
            let book = compose(&source, &Structure::new(&source), None).unwrap();
            let proposals = candidates_for(&book, Some(&format!("{category}:")));
            let candidate = &proposals["items"][0];
            assert_eq!(candidate["recommended"], false);
            let request = Request {
                base_id: effective_edit::base_id(&book),
                actions: serde_json::from_value(candidate["actions"].clone()).unwrap(),
            };
            let changed = effective_edit::apply(book, &request).unwrap().0;
            assert!(changed.tree.nodes.iter().any(|n| n.title == expected));
            assert_eq!(
                candidates_for(&changed, Some(&format!("{category}:")))["total"],
                0
            );
            if category == "unrecognized-heading" {
                assert!(
                    changed.check_page(0, None).unwrap()["report"]["diagnostic"]["review_items"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .all(|i| i["finding_id"] != "number-gap")
                );
            }
            assert_eq!(source.original_bytes(), text.as_bytes());
        }
    }

    #[test]
    fn repeated_heading_chain_preserves_body_whitespace_and_first_identity() {
        let text = "第一章 甲\r\n\r\n第一章 甲\r\n第一章 甲\r\n唯一正文\r\n第三章 丙\r\n丙文";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let book = compose(&source, &Structure::new(&source), None).unwrap();
        let plan = candidates(&book);
        assert_eq!(plan["total"], 2);
        let first = book.tree.nodes[0].entry_id.clone();
        let request = Request {
            base_id: effective_edit::base_id(&book),
            actions: plan["items"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| Action::RemoveDuplicateHeading {
                    entry_id: v["entry_id"].as_str().unwrap().into(),
                })
                .collect(),
        };
        let (changed, evidence) = effective_edit::apply(book, &request).unwrap();
        assert_eq!(
            changed.text,
            "第一章 甲\r\n\r\n唯一正文\r\n第三章 丙\r\n丙文"
        );
        assert_eq!(changed.tree.nodes[0].entry_id, first);
        assert_eq!(evidence.len(), 2);
        assert_eq!(candidates(&changed)["total"], 0);
        assert_eq!(
            changed.check_page(0, None).unwrap()["report"]["diagnostic"]["review_items"][0]["finding_id"],
            "number-gap"
        );
        assert_eq!(source.original_bytes(), text.as_bytes());
    }

    #[test]
    fn rejects_same_title_with_body_or_different_structure_settings() {
        for (text, change_toc) in [
            ("第一章 甲\n保留这段正文\n第一章 甲\n另一段", false),
            ("第一章 甲\n第一章 甲\n正文", true),
        ] {
            let source =
                SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
            let mut book = compose(&source, &Structure::new(&source), None).unwrap();
            if change_toc {
                book.tree.nodes[1].include_toc = false;
            }
            assert_eq!(candidates(&book)["total"], 0);
            let request = Request {
                base_id: effective_edit::base_id(&book),
                actions: vec![Action::RemoveDuplicateHeading {
                    entry_id: book.tree.nodes[1].entry_id.clone(),
                }],
            };
            assert!(effective_edit::apply(book, &request).is_err());
            assert_eq!(source.original_bytes(), text.as_bytes());
        }
    }
}
