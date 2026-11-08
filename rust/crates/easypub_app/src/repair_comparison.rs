//! Bounded, real before/after evidence. Coordinates are resolved in Rust from
//! the reviewed snapshots; a missing source mapping is never guessed.
use easypub_core::publication::EffectiveBook;
use serde_json::{Value, json};
use std::collections::BTreeMap;

fn original_at(book: &EffectiveBook, line: u32) -> Option<u32> {
    let mut matches = book.source_to_output_lines.iter().filter(|(_, out)| **out == line);
    let first = matches.next().map(|(source, _)| *source);
    if matches.next().is_some() { None } else { first }
}

fn side(book: &EffectiveBook, focus: Option<u32>, offset: usize, char_offset: usize, whole_node: bool) -> Value {
    let Some(focus) = focus else {
        return json!({"title":"位置已移除","rows":[],"nodes":[],"total_rows":0,"offset":0,
            "focus_line":null,"range_start":null,"range_end":null,"next_offset":null,"next_char_offset":0});
    };
    let lines = book.text.lines().collect::<Vec<_>>();
    let count = lines.len() as u32;
    let focus = focus.clamp(1, count.max(1));
    let position = book.tree.nodes.partition_point(|n|n.source_line<=focus).checked_sub(1);
    let node = position.map(|i| &book.tree.nodes[i]);
    let node_end = position.and_then(|i| book.tree.nodes.get(i+1))
        .map(|n|n.source_line.saturating_sub(1)).unwrap_or(count);
    let start = if whole_node { node.map(|n|n.source_line).unwrap_or(1) }
        else { focus.saturating_sub(4).max(1) };
    let end = if whole_node { node_end }
        else { node_end.saturating_add(4).max(focus.saturating_add(16)).min(count) };
    let total = end.saturating_sub(start).saturating_add(1) as usize;
    let mut original = BTreeMap::<u32, Option<u32>>::new();
    for (&input, &output) in &book.source_to_output_lines {
        if output >= start && output <= end {
            original.entry(output).and_modify(|v|*v=None).or_insert(Some(input));
        }
    }
    let mut rows = Vec::new();
    let mut next_offset = None;
    let mut next_char_offset = 0;
    for (step, (i, text)) in lines.iter().enumerate().skip(start as usize - 1 + offset)
        .take(total.saturating_sub(offset).min(80)).enumerate() {
        let line = i as u32 + 1;
        let skip = if step == 0 { char_offset } else { 0 };
        let mut chars = text.chars().skip(skip);
        let chunk = chars.by_ref().take(2000).collect::<String>();
        let continues = chars.next().is_some();
        rows.push(json!({"line":line,"text":chunk,"char_offset":skip,
            "original_line":original.get(&line).copied().flatten(),
            "anchor":format!("{}:{line}",book.tree.source_id),"truncated":continues,"continues":continues}));
        if continues {
            next_offset = Some(offset + step);
            next_char_offset = skip + 2000;
            break;
        }
        if offset + step + 1 < total { next_offset = Some(offset + step + 1); }
        else { next_offset = None; }
    }
    let first_node = position.unwrap_or(0).saturating_sub(1);
    json!({"title":node.map(|n|n.title.as_str()).unwrap_or("卷前正文"),"rows":rows,
        "nodes":book.tree.nodes.iter().skip(first_node).take(3).collect::<Vec<_>>(),
        "focus_line":focus,"range_start":start,"range_end":end,"offset":offset,"total_rows":total,
        "next_offset":next_offset,"next_char_offset":next_char_offset})
}

// 参数各有独立含义，改成结构体会牵动所有调用者；V21 保留现状。
#[allow(clippy::too_many_arguments)]
pub fn compare(before: &EffectiveBook, after: &EffectiveBook, entry_id: &str,
    line: u32, kept_line: Option<u32>, before_offset: usize, after_offset: usize,
    before_char_offset: usize, after_char_offset: usize) -> Value {
    let removed_copy = kept_line.is_some_and(|kept| kept != line);
    let target = kept_line.filter(|_|removed_copy).unwrap_or(line);
    let after_focus = if removed_copy {
        original_at(before, target).and_then(|original|after.source_to_output_lines.get(&original).copied())
    } else {
        after.tree.nodes.iter().find(|n|n.entry_id==entry_id).map(|n|n.source_line)
            .or_else(||original_at(before, target).and_then(|original|after.source_to_output_lines.get(&original).copied()))
    };
    json!({"before":side(before,Some(line),before_offset,before_char_offset,removed_copy),
        "after":side(after,after_focus,after_offset,after_char_offset,removed_copy),"retained_copy":removed_copy,
        "before_composition":easypub_core::effective_edit::base_id(before),
        "after_composition":easypub_core::effective_edit::base_id(after)})
}

#[cfg(test)]
mod tests {
    use super::*;
    use easypub_core::{effective_edit::{self, Action, Request}, source::{SourceSnapshot, RULE_ID}, structure::{Structure, Role}};
    #[test]
    fn comparison_uses_real_snapshots_and_preserves_paged_context_after_demotion() {
        let text = format!("第一章 起\n甲正文\n第一节课是历史。\n{}第二章 续\n乙正文\n", (0..100).map(|i|format!("段落{i}\n")).collect::<String>());
        let source=SourceSnapshot::from_utf8(text.as_bytes().to_vec(),RULE_ID,||false).unwrap();
        let before=easypub_core::publication::compose(&source,&Structure::new(&source),None).unwrap();
        let target=before.tree.nodes.iter().find(|n|n.title=="第一节课是历史。").unwrap();
        let id=target.entry_id.clone();
        let line=target.source_line;
        let request=Request {base_id:effective_edit::base_id(&before),actions:vec![Action::Classify {
            entry_id:id.clone(),role:Role::Body,depth:0,include_toc:false}]};
        let after=effective_edit::apply(before.clone(),&request).unwrap().0;
        let result=compare(&before,&after,&id,line,Some(line),0,0,0,0);
        assert_eq!(result["before"]["rows"].as_array().unwrap().len(),80);
        assert_eq!(result["after"]["rows"].as_array().unwrap().len(),80);
        assert_eq!(result["after"]["focus_line"],line);
        assert!(result["before"]["nodes"].as_array().unwrap().iter().any(|n|n["title"]=="第一节课是历史。"));
        assert!(!result["after"]["nodes"].as_array().unwrap().iter().any(|n|n["title"]=="第一节课是历史。"));
        let next=compare(&before,&after,&id,line,Some(line),80,80,0,0);
        assert_eq!(next["after"]["rows"][0]["line"],81);
        assert_eq!(result["after"]["rows"][2]["text"],"第一节课是历史。");
        assert_eq!(before.text,after.text);
        let mut long = after.clone();
        long.text = format!("{}\n", "春".repeat(4501));
        long.tree.nodes.clear();
        let first=side(&long,Some(1),0,0,false);
        let second=side(&long,Some(1),0,2000,false);
        let last=side(&long,Some(1),0,4000,false);
        assert_eq!(first["next_offset"],0);
        assert_eq!(second["next_char_offset"],4000);
        assert_eq!(last["next_offset"],Value::Null);
        assert_eq!([first,second,last].iter().map(|p|p["rows"][0]["text"].as_str().unwrap()).collect::<String>(),"春".repeat(4501));
    }
}
