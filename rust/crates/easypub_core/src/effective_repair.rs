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
                "truncated":book.text[n.start..n.end].chars().count()>2000,"recommended":n.title.trim()==group.title.trim(),
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
                "truncated":false,"recommended":true,"actions":[action]}));
        }
    }
    misplaced_proposal(book, &view, &mut items);
    misnumbered_proposals(book, &view, &mut items);
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
            let ids = std::iter::once(&p["finding_id"])
                .chain(p["also_for"].as_array().into_iter().flatten());
            ids.into_iter().any(|v| {
                v == id || (id.ends_with(':') && v.as_str().is_some_and(|v| v.starts_with(id)))
            })
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

/// 一条方案是否覆盖某个问题：自己的 finding_id 或 also_for 里列出的（V133）。
pub fn covers(proposal: &Value, id: &Value) -> bool {
    &proposal["finding_id"] == id
        || proposal["also_for"]
            .as_array()
            .is_some_and(|ids| ids.iter().any(|v| v == id))
}

/// 放错位置的章整体归位（V133）：所有可归位的章合成一条方案，按章号从大到小依次移动，
/// 每章移到“全部归位后紧跟它的那一章”之前，所以整体执行后顺序正确。只移动没有下级的章。
fn misplaced_proposal(
    book: &EffectiveBook,
    view: &crate::source::SourceSnapshot,
    items: &mut Vec<Value>,
) {
    let all = view.misplaced_chapters();
    let nodes = &book.tree.nodes;
    let has_children = |id: &str| nodes.iter().any(|c| c.parent_id.as_deref() == Some(id));
    let movable = |id: &str| {
        nodes
            .iter()
            .any(|n| n.entry_id == id && n.role == Role::Chapter && !has_children(id))
    };
    let found: Vec<_> = all.iter().filter(|m| movable(&m.entry_id)).collect();
    if found.is_empty() {
        return;
    }
    let misplaced: std::collections::BTreeSet<&str> =
        all.iter().map(|m| m.entry_id.as_str()).collect();
    // 主体最后一章（含下级）之后第一个不是放错章的节点；没有就移到全书末尾。
    let after_tail = |tail: &str| -> Option<String> {
        let i = nodes.iter().position(|n| n.entry_id == tail)?;
        let depth = nodes[i].depth;
        nodes[i + 1..]
            .iter()
            .find(|n| n.depth <= depth && !misplaced.contains(n.entry_id.as_str()))
            .map(|n| n.entry_id.clone())
    };
    let mut actions = Vec::new();
    let mut ordered = found.clone();
    ordered.sort_by_key(|m| std::cmp::Reverse(m.number));
    for m in &ordered {
        // 紧跟它的章若也放错了却不能移动，就顺着找下一个。
        let mut next = m.next.clone();
        while let Some(id) = next.clone() {
            match all.iter().find(|x| x.entry_id == id) {
                Some(x) if !found.iter().any(|f| f.entry_id == id) => next = x.next.clone(),
                _ => break,
            }
        }
        let before_id = next.or_else(|| after_tail(&m.tail));
        actions.push(json!({"kind":"move","entry_id":m.entry_id,"before_id":before_id}));
    }
    let first = found[0];
    let line = found.iter().map(|m| m.source_line).min().unwrap();
    let before = found
        .iter()
        .map(|m| {
            format!(
                "{}（现在在{}）",
                m.title,
                m.current_after
                    .as_ref()
                    .map(|t| format!("“{t}”之后"))
                    .unwrap_or_else(|| "最前面".into())
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    let after = found
        .iter()
        .map(|m| match &m.anchor {
            Some((_, t, _)) => format!("{} → 移到“{t}”之后", m.title),
            None => format!("{} → 移到“{}”之前", m.title, m.first.1),
        })
        .collect::<Vec<_>>()
        .join("\n");
    items.push(json!({"finding_id":format!("chapter-misplaced:{}",first.entry_id),
        "also_for":found.iter().skip(1).map(|m|format!("chapter-misplaced:{}",m.entry_id)).collect::<Vec<_>>(),
        "entry_id":first.entry_id,"title":format!("把放错位置的 {} 章移回原位（标题和正文不变）",found.len()),
        "line":line,"kept_line":line,"before":before,"after":after,"truncated":false,"recommended":true,
        "actions":actions}));
}

/// 按原来的写法（阿拉伯数字、全角数字或汉字）把标题里的章号改成 [number]。
fn renumbered_title(title: &str, number: u32) -> Option<String> {
    let (_, unit) = crate::source::numbered_heading(title)?;
    let start = match title.find('第') {
        Some(i) => i + '第'.len_utf8(),
        None => {
            title.len()
                - title
                    .trim_start_matches(['【', '[', '（', '(', ' ', '\u{3000}'])
                    .len()
        }
    };
    let end = start + title[start..].find(unit)?;
    let lead = &title[start..end];
    let numeral = lead.trim();
    if numeral.is_empty() {
        return None;
    }
    let written = if numeral.chars().all(|c| c.is_ascii_digit()) {
        number.to_string()
    } else if numeral.chars().all(|c| ('０'..='９').contains(&c)) {
        number
            .to_string()
            .chars()
            .map(|c| char::from_u32(c as u32 - '0' as u32 + '０' as u32).unwrap())
            .collect()
    } else if numeral
        .chars()
        .any(|c| c.is_ascii_digit() || ('０'..='９').contains(&c))
    {
        return None;
    } else {
        crate::cleanup_numbers::chinese(number)
    };
    let lead_space = &lead[..lead.len() - lead.trim_start().len()];
    let tail_space = &lead[lead.trim_end().len()..];
    let renamed = format!(
        "{}{lead_space}{written}{tail_space}{}",
        &title[..start],
        &title[end..]
    );
    (crate::source::numbered_heading(&renamed) == Some((number, unit))).then_some(renamed)
}

/// 编号写错的标题改回应有的章号（V133）：前后两章编号差 2、中间这一号一章都没有。
/// 写错的号与别的章重复时推荐；不重复时只提议。
fn misnumbered_proposals(
    book: &EffectiveBook,
    view: &crate::source::SourceSnapshot,
    items: &mut Vec<Value>,
) {
    for m in view.misnumbered_chapters() {
        let Some(node) = book
            .tree
            .nodes
            .iter()
            .find(|n| n.entry_id == m.entry_id && n.role == Role::Chapter)
        else {
            continue;
        };
        let Some(title) = renumbered_title(&node.title, m.expected) else {
            continue;
        };
        // 已经有别的方案用了这个问题编号（如“临时分卷”），就不再占用。
        let ids: Vec<_> = [
            format!("number-gap:{}", m.entry_id),
            format!("number-reset:{}", m.entry_id),
            format!("number-gap:{}", m.next.entry_id),
            format!("number-reset:{}", m.next.entry_id),
        ]
        .into_iter()
        .filter(|id| !items.iter().any(|p| p["finding_id"] == id.as_str()))
        .collect();
        let Some((first, rest)) = ids.split_first() else {
            continue;
        };
        items.push(json!({"finding_id":first,"also_for":rest,"entry_id":node.entry_id,
            "title":format!("把章号改成第{}{}（前一章“{}”，后一章“{}”）",m.expected,m.unit,m.previous.title,m.next.title),
            "line":node.source_line,"kept_line":node.source_line,"before":node.title,"after":title,
            "truncated":false,"recommended":m.duplicated,
            "actions":[{"kind":"rename","entry_id":node.entry_id,"title":title}]}));
    }
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
        assert!(
            book.tree
                .nodes
                .iter()
                .any(|n| n.title.starts_with("两章合一章"))
        );
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
            // V133：编号错字与整章重复改为推荐。
            assert_eq!(candidate["recommended"], category != "unrecognized-heading");
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

    fn chapters(numbers: &[(u32, &str)]) -> String {
        numbers
            .iter()
            .map(|(n, name)| format!("第{n}章 {name}\n{name}的正文第一段\n{name}的正文第二段\n"))
            .collect()
    }

    fn apply_all(book: &EffectiveBook, items: &Value) -> EffectiveBook {
        let actions = items
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|v| serde_json::from_value::<Vec<Action>>(v["actions"].clone()).unwrap())
            .collect();
        let request = Request {
            base_id: effective_edit::base_id(book),
            actions,
        };
        effective_edit::apply(book.clone(), &request).unwrap().0
    }

    fn numbers(book: &EffectiveBook) -> Vec<u32> {
        book.tree
            .nodes
            .iter()
            .filter_map(|n| crate::source::numbered_heading(&n.title).map(|v| v.0))
            .collect()
    }

    /// V133：网页“最新章节”栏倒序放在第一章前、最新一章夹在中间——合成一条“归位”，一键移回。
    #[test]
    fn misplaced_chapters_merge_into_one_recommended_move() {
        let mut order: Vec<(u32, &str)> = vec![(22, "二二"), (21, "二一")];
        let names = [
            "一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "十一", "十二", "十三",
            "十四", "十五", "十六", "十七", "十八", "十九", "二十",
        ];
        for (i, name) in names.iter().enumerate() {
            order.push((i as u32 + 1, name));
            if i == 4 {
                order.push((23, "二三"));
            }
        }
        let text = chapters(&order);
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let diagnostic: Value = serde_json::from_str(&source.diagnostic_json()).unwrap();
        let ids: Vec<_> = diagnostic["findings"]
            .as_array()
            .unwrap()
            .iter()
            .map(|f| f["id"].as_str().unwrap().to_owned())
            .collect();
        assert!(ids.contains(&"chapter-misplaced".to_owned()), "{ids:?}");
        assert!(!ids.contains(&"number-reset".to_owned()), "{ids:?}");
        assert!(!ids.contains(&"number-gap".to_owned()), "{ids:?}");
        let book = compose(&source, &Structure::new(&source), None).unwrap();
        let proposals = candidates_for(&book, None);
        let moves: Vec<_> = proposals["items"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|p| {
                p["finding_id"]
                    .as_str()
                    .unwrap()
                    .starts_with("chapter-misplaced:")
            })
            .cloned()
            .collect();
        assert_eq!(moves.len(), 1);
        assert_eq!(moves[0]["recommended"], true);
        assert_eq!(moves[0]["also_for"].as_array().unwrap().len(), 2);
        // 从任何一章的问题进入，都看到同一条方案。
        let report = book.check_page(0, None).unwrap();
        let items = report["report"]["diagnostic"]["review_items"]
            .as_array()
            .unwrap();
        let misplaced: Vec<_> = items
            .iter()
            .filter(|i| i["finding_id"] == "chapter-misplaced")
            .collect();
        assert_eq!(misplaced.len(), 3);
        for item in &misplaced {
            assert_eq!(item["auto_applicable"], true);
            let focus = item["id"].as_str().unwrap();
            assert_eq!(candidates_for(&book, Some(focus))["total"], 1);
        }
        let fixed = apply_all(&book, &json!(moves));
        assert_eq!(numbers(&fixed), (1..=23).collect::<Vec<_>>());
        assert_eq!(fixed.text.len(), book.text.len());
        assert!(
            fixed
                .text
                .contains("第23章 二三\n二三的正文第一段\n二三的正文第二段\n")
        );
        assert_eq!(
            candidates_for(&fixed, Some("chapter-misplaced:"))["total"],
            0
        );
        assert_eq!(source.original_bytes(), text.as_bytes());
    }

    /// 分卷各自编号、原位已有同号章、空位正好补上的，都不当成放错位置。
    #[test]
    fn misplaced_is_not_reported_for_restarts_duplicates_or_gap_fillers() {
        let mut order: Vec<(u32, String)> = (1..=12).map(|n| (n, format!("甲{n}"))).collect();
        order.insert(6, (3, "又一个三".into()));
        let text = chapters(
            &order
                .iter()
                .map(|(n, s)| (*n, s.as_str()))
                .collect::<Vec<_>>(),
        );
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        assert!(source.misplaced_chapters().is_empty());
        // 第五章写成了第五十章：交给改标题，不移到最后。
        let order: Vec<(u32, String)> = (1..=12)
            .map(|n| (if n == 5 { 50 } else { n }, format!("乙{n}")))
            .collect();
        let text = chapters(
            &order
                .iter()
                .map(|(n, s)| (*n, s.as_str()))
                .collect::<Vec<_>>(),
        );
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        assert!(source.misplaced_chapters().is_empty());
        let wrong = source.misnumbered_chapters();
        assert_eq!(wrong.len(), 1);
        assert_eq!(
            (wrong[0].number, wrong[0].expected, wrong[0].duplicated),
            (50, 5, false)
        );
        let book = compose(&source, &Structure::new(&source), None).unwrap();
        let proposal = &candidates_for(&book, Some("number-gap:"))["items"][0];
        assert_eq!(proposal["after"], "第5章 乙5");
        assert_eq!(proposal["recommended"], false);
    }

    /// 两个“第五章”、缺第六章：后一个改成第六章，推荐；按原来的数字写法改。
    #[test]
    fn duplicated_number_with_empty_slot_is_renamed() {
        let names = ["一", "二", "三", "四", "五", "五", "七", "八", "九", "十"];
        let text: String = names
            .iter()
            .enumerate()
            .map(|(i, n)| format!("第{n}章 标题{i}\n正文{i}\n"))
            .collect();
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let book = compose(&source, &Structure::new(&source), None).unwrap();
        let report = book.check_page(0, None).unwrap();
        let items = report["report"]["diagnostic"]["review_items"]
            .as_array()
            .unwrap();
        let numbering: Vec<_> = items
            .iter()
            .filter(|i| {
                matches!(
                    i["finding_id"].as_str(),
                    Some("number-gap" | "number-reset")
                )
            })
            .collect();
        assert_eq!(numbering.len(), 2);
        assert!(numbering.iter().all(|i| i["auto_applicable"] == true));
        let proposals = candidates_for(&book, Some(numbering[0]["id"].as_str().unwrap()));
        assert_eq!(proposals["total"], 1);
        assert_eq!(proposals["items"][0]["after"], "第六章 标题5");
        let fixed = apply_all(&book, &proposals["items"]);
        assert_eq!(numbers(&fixed), (1..=10).collect::<Vec<_>>());
        let after = fixed.check_page(0, None).unwrap();
        assert!(
            after["report"]["diagnostic"]["review_items"]
                .as_array()
                .unwrap()
                .iter()
                .all(|i| !matches!(
                    i["finding_id"].as_str(),
                    Some("number-gap" | "number-reset")
                ))
        );
        // 上、下篇分段不改。
        let text = "第1章 甲\n文\n第2章 乙\n文\n第3章 丙（上）\n文\n第3章 丙（下）\n文\n第5章 戊\n文\n第6章 己\n文\n";
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        assert!(source.misnumbered_chapters().is_empty());
        assert_eq!(
            renumbered_title("第１２章 甲", 13).as_deref(),
            Some("第１３章 甲")
        );
        assert_eq!(
            renumbered_title("第一百零九章 甲", 110).as_deref(),
            Some("第一百一十章 甲")
        );
        assert_eq!(renumbered_title("12章 甲", 13).as_deref(), Some("13章 甲"));
    }
}
