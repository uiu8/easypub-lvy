//! 连续的同类修改合成一步。
//!
//! 逐步重放时每一步都要重建整本书的索引，一次批量修复留下的几十步就要几秒，而这些修改
//! 彼此几乎无关：删掉 40 个重复标题，本来只需要算出 40 处位置后一次改完。
//!
//! 这里只模拟每一步对节点链的影响，不碰书稿，最后一次性得出结果。书稿、节点身份、行映射
//! 和逐条证据都和逐步重放完全相同（见下方对照测试），所以旧项目的历史不用迁移。
//! 只要有一步不是最简单的情形就返回 `None`，交给逐步重放，报错也由它给出。
use crate::{
    effective_edit::{Action, classify_stage},
    publication::EffectiveBook,
    source::{RULE_ID, SourceSnapshot},
    structure::{Node, Override, Role, Structure},
};
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    DuplicateHeading,
    Demote,
}

fn kind(action: &Action) -> Option<Kind> {
    match action {
        Action::RemoveDuplicateHeading { .. } => Some(Kind::DuplicateHeading),
        Action::Classify {
            role: Role::Body,
            depth: 0,
            include_toc: false,
            ..
        } => Some(Kind::Demote),
        _ => None,
    }
}

pub(crate) fn same_run(left: &Action, right: &Action) -> bool {
    kind(left).is_some() && kind(left) == kind(right)
}

/// 从 `start` 开始、能合成一步的最后位置（不含）；至少是 `start + 1`。
pub(crate) fn run_end(actions: &[Action], start: usize) -> usize {
    let mut end = start + 1;
    while end < actions.len() && same_run(&actions[start], &actions[end]) {
        end += 1;
    }
    end
}

pub(crate) struct Merged {
    /// 节点身份和原始行映射还没接回，由调用方处理。
    pub book: EffectiveBook,
    /// 与动作一一对应，位置都是那一步之前的书稿坐标。
    pub stages: Vec<Value>,
}

pub(crate) fn apply(book: &EffectiveBook, actions: &[Action]) -> Option<Merged> {
    match kind(actions.first()?)? {
        Kind::DuplicateHeading => remove_duplicate_headings(book, actions),
        Kind::Demote => demote(book, actions),
    }
}

/// 节点链：模拟时只摘节点，不动书稿。
struct Chain<'a> {
    nodes: &'a [Node],
    ids: BTreeMap<&'a str, usize>,
    previous: Vec<Option<usize>>,
    following: Vec<Option<usize>>,
    alive: Vec<bool>,
}

impl<'a> Chain<'a> {
    /// 节点必须首尾相接地铺满书稿，身份不重复；否则不是这里能算的情形。
    fn new(book: &'a EffectiveBook) -> Option<Self> {
        let nodes = book.tree.nodes.as_slice();
        if nodes.windows(2).any(|pair| pair[0].end != pair[1].start)
            || nodes.last()?.end != book.text.len()
        {
            return None;
        }
        let ids: BTreeMap<_, _> = nodes
            .iter()
            .enumerate()
            .map(|(i, n)| (n.entry_id.as_str(), i))
            .collect();
        (ids.len() == nodes.len()).then(|| Self {
            nodes,
            ids,
            previous: (0..nodes.len()).map(|i| i.checked_sub(1)).collect(),
            following: (0..nodes.len())
                .map(|i| (i + 1 < nodes.len()).then_some(i + 1))
                .collect(),
            alive: vec![true; nodes.len()],
        })
    }

    fn find(&self, id: &str) -> Option<usize> {
        self.ids.get(id).copied().filter(|&i| self.alive[i])
    }

    /// 没有下级节点：摘掉它不会改变别的节点的上级。
    fn is_leaf(&self, index: usize) -> bool {
        self.following[index].is_none_or(|next| self.nodes[next].depth <= self.nodes[index].depth)
    }

    fn unlink(&mut self, index: usize) {
        let (previous, following) = (self.previous[index], self.following[index]);
        if let Some(p) = previous {
            self.following[p] = following;
        }
        if let Some(f) = following {
            self.previous[f] = previous;
        }
        self.alive[index] = false;
    }
}

/// 见 `effective_repair::safe_pair`；正文是否空白由调用方按合并后的结果给出。
fn same_heading(previous: &Node, node: &Node) -> bool {
    matches!(node.role, Role::Chapter | Role::Section)
        && previous.role == node.role
        && previous.depth == node.depth
        && previous.parent_id == node.parent_id
        && previous.include_toc == node.include_toc
        && previous.title == node.title
}

/// 已删除的标题行（原坐标，起点、字节数、行号）。
struct Removed(Vec<(usize, usize, u32)>);

impl Removed {
    fn offset(&self, position: usize) -> usize {
        position
            - self
                .0
                .iter()
                .filter(|r| r.0 < position)
                .map(|r| r.1)
                .sum::<usize>()
    }

    fn line(&self, line: u32) -> u32 {
        line - self.0.iter().filter(|r| r.2 < line).count() as u32
    }

    /// 这个节点在“这一步之前”的书稿里的样子。
    fn node(&self, node: &Node) -> Node {
        Node {
            source_line: self.line(node.source_line),
            start: self.offset(node.start),
            body_start: self.offset(node.body_start),
            end: self.offset(node.end),
            ..node.clone()
        }
    }
}

fn remove_duplicate_headings(book: &EffectiveBook, actions: &[Action]) -> Option<Merged> {
    let mut chain = Chain::new(book)?;
    let source = SourceSnapshot::from_text(book.text.clone(), RULE_ID).ok()?;
    let lines = source.decoded_line_ranges();
    // 被并入的节点，它的正文归前一个节点，所以“正文是否空白”要跟着合并。
    let mut blank: Vec<bool> = chain
        .nodes
        .iter()
        .map(|n| book.text[n.body_start..n.end].trim().is_empty())
        .collect();
    let mut removed = Removed(Vec::with_capacity(actions.len()));
    let mut stages = Vec::with_capacity(actions.len());
    for action in actions {
        let Action::RemoveDuplicateHeading { entry_id } = action else {
            return None;
        };
        let index = chain.find(entry_id)?;
        let previous = chain.previous[index]?;
        let (root, target) = (&chain.nodes[index], &chain.nodes[previous]);
        // 标题必须正好是一整行，这样行号才能按删掉的行数换算。
        let line = lines.get(root.source_line.checked_sub(1)? as usize)?;
        let next_line = lines
            .get(root.source_line as usize)
            .map_or(book.text.len(), |l| l.0);
        if !same_heading(target, root)
            || !blank[previous]
            || !chain.is_leaf(index)
            || line.0 != root.start
            || next_line != root.body_start
        {
            return None;
        }
        let end = chain.following[index].map_or(book.text.len(), |n| chain.nodes[n].start);
        let mut stage = crate::effective_merge::into_stage(
            &removed.node(root),
            &removed.node(target),
            removed.offset(end),
            removed.offset(root.start),
        );
        crate::effective_merge::mark_duplicate_heading(&mut stage);
        stages.push(stage);
        blank[previous] &= blank[index];
        removed
            .0
            .push((root.start, root.body_start - root.start, root.source_line));
        chain.unlink(index);
    }
    let mut cuts = removed.0;
    cuts.sort_unstable();
    let mut spans = Vec::with_capacity(cuts.len() + 1);
    let mut from = 0;
    for &(start, bytes, _) in &cuts {
        spans.push((from, start));
        from = start + bytes;
    }
    spans.push((from, book.text.len()));
    let settings: Vec<_> = chain
        .nodes
        .iter()
        .enumerate()
        .filter(|(i, _)| chain.alive[*i])
        .map(|(_, n)| keep(n))
        .collect();
    let mut next = crate::effective_move::recompose(
        book,
        &source,
        &spans,
        &settings,
        cuts.iter().map(|c| c.2).collect(),
    )
    .ok()?;
    carry_recognition(book, &mut next);
    Some(Merged { book: next, stages })
}

fn keep(node: &Node) -> Override {
    Override {
        source_line: node.source_line,
        role: node.role.clone(),
        depth: node.depth,
        include_toc: node.include_toc,
    }
}

fn carry_recognition(book: &EffectiveBook, next: &mut EffectiveBook) {
    next.tree.recognition_rules = book.tree.recognition_rules.clone();
    next.tree.recognition_decisions = book.tree.recognition_decisions.clone();
}

/// 把标题降成正文：书稿不变，只改结构。
fn demote(book: &EffectiveBook, actions: &[Action]) -> Option<Merged> {
    let mut chain = Chain::new(book)?;
    let source = SourceSnapshot::from_text(book.text.clone(), RULE_ID).ok()?;
    let mut stages = Vec::with_capacity(actions.len());
    let mut decided = Vec::new();
    for action in actions {
        let Action::Classify {
            entry_id,
            role,
            depth,
            include_toc,
        } = action
        else {
            return None;
        };
        let index = chain.find(entry_id)?;
        if !chain.is_leaf(index) {
            return None;
        }
        let node = &chain.nodes[index];
        stages.push(classify_stage(node, role, *depth, *include_toc));
        if book.tree.recognition_rules.is_some()
            && let Some((&original, _)) = book
                .source_to_output_lines
                .iter()
                .find(|(_, line)| **line == node.source_line)
        {
            decided.push(original);
        }
        chain.unlink(index);
    }
    let mut structure = Structure::new(&source);
    structure.overrides = chain
        .nodes
        .iter()
        .enumerate()
        .map(|(i, n)| {
            if chain.alive[i] {
                keep(n)
            } else {
                Override {
                    source_line: n.source_line,
                    role: Role::Body,
                    depth: 0,
                    include_toc: false,
                }
            }
        })
        .collect();
    let known: std::collections::BTreeSet<_> = chain.nodes.iter().map(|n| n.source_line).collect();
    for n in Structure::new(&source).tree(&source).ok()?.nodes {
        if !known.contains(&n.source_line) {
            structure.overrides.push(Override {
                source_line: n.source_line,
                role: Role::Body,
                depth: 0,
                include_toc: false,
            });
        }
    }
    structure.overrides.sort_by_key(|o| o.source_line);
    let mut next = crate::publication::compose(&source, &structure, None).ok()?;
    carry_recognition(book, &mut next);
    next.tree
        .recognition_decisions
        .extend(decided.into_iter().map(|line| (line, false)));
    Some(Merged { book: next, stages })
}

#[cfg(test)]
mod tests {
    use crate::{
        effective_edit::{self, Action, MERGED_RUNS, Request, apply, apply_stepwise},
        publication::{self, EffectiveBook},
        source::{RULE_ID, SourceSnapshot},
        structure::{Override, Role, Structure},
    };

    fn book_of(text: &str) -> EffectiveBook {
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        publication::compose(&source, &Structure::new(&source), None).unwrap()
    }

    fn request(book: &EffectiveBook, actions: Vec<Action>) -> Request {
        Request {
            base_id: effective_edit::base_id(book),
            actions,
        }
    }

    fn remove(book: &EffectiveBook, index: usize) -> Action {
        Action::RemoveDuplicateHeading {
            entry_id: book.tree.nodes[index].entry_id.clone(),
        }
    }

    fn demote(book: &EffectiveBook, index: usize) -> Action {
        Action::Classify {
            entry_id: book.tree.nodes[index].entry_id.clone(),
            role: Role::Body,
            depth: 0,
            include_toc: false,
        }
    }

    /// 书稿、结构、行映射、证据都要和逐步重放一字不差。返回走了几段合并。
    fn assert_same(book: &EffectiveBook, request: &Request) -> (EffectiveBook, usize) {
        let (step, step_evidence) = apply_stepwise(book.clone(), request).unwrap();
        MERGED_RUNS.with(|runs| runs.set(0));
        let (fast, fast_evidence) = apply(book.clone(), request).unwrap();
        let merged = MERGED_RUNS.with(|runs| runs.get());
        assert_eq!(fast.text, step.text);
        assert_eq!(
            serde_json::to_value(&fast.tree).unwrap(),
            serde_json::to_value(&step.tree).unwrap()
        );
        assert_eq!(fast.source_to_output_lines, step.source_to_output_lines);
        assert_eq!(fast.removed_structure_lines, step.removed_structure_lines);
        assert_eq!(fast.text_changed, step.text_changed);
        assert_eq!(fast.original_source_id, step.original_source_id);
        assert_eq!(fast_evidence, step_evidence);
        (fast, merged)
    }

    /// 固定种子的小随机数：失败时可以复现。
    struct Dice(u64);
    impl Dice {
        fn next(&mut self, range: usize) -> usize {
            self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1);
            ((self.0 >> 33) as usize) % range
        }
    }

    #[test]
    fn removing_duplicates_in_any_order_equals_stepwise_replay() {
        let text = "前言\n第一章 甲\n\n第一章 甲\n第一章 甲\n甲文\n第二章 乙\n乙文\n第二章 乙\n乙二文\n第三章 丙\n第三章 丙\n";
        let book = book_of(text);
        let titles: Vec<_> = book.tree.nodes.iter().map(|n| n.title.as_str()).collect();
        assert_eq!(titles.len(), 8, "{titles:?}");
        // 由下往上（实际批量修复的顺序）、由上往下、打乱。
        for order in [[7, 3, 2], [2, 3, 7], [3, 7, 2]] {
            let actions = order.iter().map(|&i| remove(&book, i)).collect();
            let (done, merged) = assert_same(&book, &request(&book, actions));
            assert_eq!(merged, 1, "整段合成一步");
            assert_eq!(
                done.text,
                "前言\n第一章 甲\n\n甲文\n第二章 乙\n乙文\n第二章 乙\n乙二文\n第三章 丙\n"
            );
        }
    }

    #[test]
    fn line_endings_and_a_last_line_without_newline_are_kept() {
        for text in [
            "第一章 甲\r\n\r\n第一章 甲\r\n第一章 甲\r\n唯一正文\r\n第三章 丙\r\n丙文",
            "第一章 甲\n第一章 甲\n第一章 甲",
            "第一章 甲\n\n第一章 甲\n第二章 乙\n第二章 乙",
        ] {
            let book = book_of(text);
            let actions: Vec<_> = (1..book.tree.nodes.len())
                .rev()
                .filter(|&i| book.tree.nodes[i].title == book.tree.nodes[i - 1].title)
                .map(|i| remove(&book, i))
                .collect();
            assert!(actions.len() >= 2, "{text:?}");
            assert_same(&book, &request(&book, actions));
        }
    }

    #[test]
    fn a_duplicate_with_children_or_a_body_falls_back_with_the_same_result() {
        let source =
            "第一卷 起\n第一章 甲\n第一章 甲\n第一节 子\n子文\n第二章 乙\n第二章 乙\n乙文\n"
                .as_bytes()
                .to_vec();
        let source = SourceSnapshot::from_utf8(source, RULE_ID, || false).unwrap();
        let mut structure = Structure::new(&source);
        for (line, role, depth) in [
            (1, Role::Volume, 0),
            (2, Role::Chapter, 1),
            (3, Role::Chapter, 1),
            (4, Role::Section, 2),
            (6, Role::Chapter, 1),
            (7, Role::Chapter, 1),
        ] {
            structure.overrides.push(Override {
                source_line: line,
                role,
                depth,
                include_toc: true,
            });
        }
        let book = publication::compose(&source, &structure, None).unwrap();
        // 第 2 个重复标题下面有小节：不是最简单的情形，整段走逐步重放，结果照样相同。
        assert_same(
            &book,
            &request(&book, vec![remove(&book, 5), remove(&book, 2)]),
        );
        // 有正文的同名章不是重复标题：两边都拒绝，错误相同。
        let body = book_of("第一章 甲\n有正文\n第一章 甲\n第二章 乙\n第二章 乙\n");
        let bad = request(&body, vec![remove(&body, 3), remove(&body, 1)]);
        let (fast, step) = (
            apply(body.clone(), &bad).err().unwrap(),
            apply_stepwise(body.clone(), &bad).err().unwrap(),
        );
        assert_eq!(fast.next_action, step.next_action);
    }

    #[test]
    fn demoting_headings_equals_stepwise_replay() {
        let book =
            book_of("序\n第一章 甲\n甲文\n第二章 乙\n乙文\n第三章 丙\n丙文\n第四章 丁\n丁文\n");
        for order in [vec![1, 3], vec![3, 1, 0], vec![0, 1, 2, 3]] {
            let actions = order.iter().map(|&i| demote(&book, i)).collect();
            assert_same(&book, &request(&book, actions));
        }
    }

    #[test]
    fn recognition_rules_and_decisions_are_carried_the_same_way() {
        let mut book = book_of("第一章 甲\n甲文\n第二章 乙\n乙文\n第三章 丙\n丙文\n");
        book.tree.recognition_rules = Some(Default::default());
        book.tree.recognition_decisions.insert(1, true);
        let (done, _) = assert_same(
            &book,
            &request(&book, vec![demote(&book, 2), demote(&book, 1)]),
        );
        assert_eq!(done.tree.recognition_decisions.len(), 3);
        let twice = book_of("第一章 甲\n第一章 甲\n第一章 甲\n第二章 乙\n");
        let mut kept = twice.clone();
        kept.tree.recognition_rules = Some(Default::default());
        assert_same(
            &kept,
            &request(&kept, vec![remove(&kept, 2), remove(&kept, 1)]),
        );
    }

    #[test]
    fn identities_of_later_inserted_nodes_are_unchanged() {
        let book = book_of("第一章 甲\n第一章 甲\n第一章 甲\n甲文\n第二段\n第二章 乙\n乙文\n");
        let kept = book.tree.nodes[0].entry_id.clone();
        let mut actions = vec![remove(&book, 2), remove(&book, 1)];
        actions.push(Action::Split {
            entry_id: kept.clone(),
            line_offset: 2,
            title: "第一章下".into(),
        });
        actions.push(demote(&book, 3));
        actions.push(Action::Rename {
            entry_id: kept,
            title: "第一章上".into(),
        });
        assert_same(&book, &request(&book, actions));
    }

    #[test]
    fn continuing_a_replay_equals_replaying_from_the_start() {
        let book = book_of(
            "第一章 甲\n第一章 甲\n第二章 乙\n第二章 乙\n第三章 丙\n第三章 丙\n丙文\n第四章 丁\n丁文\n",
        );
        let full = request(
            &book,
            vec![
                remove(&book, 5),
                remove(&book, 3),
                remove(&book, 1),
                demote(&book, 6),
            ],
        );
        let (whole, evidence) = apply_stepwise(book.clone(), &full).unwrap();
        for done in 1..full.actions.len() {
            let head = Request {
                base_id: full.base_id.clone(),
                actions: full.actions[..done].to_vec(),
            };
            let (partial, mut seen) = apply(book.clone(), &head).unwrap();
            let (rest, more) = effective_edit::apply_remaining(partial, &full, done).unwrap();
            seen.extend(more);
            assert_eq!(rest.text, whole.text, "{done}");
            assert_eq!(
                serde_json::to_value(&rest.tree).unwrap(),
                serde_json::to_value(&whole.tree).unwrap(),
                "{done}"
            );
            assert_eq!(rest.source_to_output_lines, whole.source_to_output_lines);
            assert_eq!(seen, evidence, "{done}");
        }
    }

    #[test]
    fn random_books_and_orders_equal_stepwise_replay() {
        let mut dice = Dice(20261106);
        let mut merged = 0;
        for round in 0..300 {
            let mut text = String::new();
            if dice.next(3) == 0 {
                text.push_str("序言\n");
            }
            let ending = if dice.next(4) == 0 { "\r\n" } else { "\n" };
            for chapter in 1..=(3 + dice.next(10)) {
                for _ in 0..=dice.next(4) {
                    text.push_str(&format!("第{chapter}章 题{}{ending}", chapter % 3));
                    if dice.next(5) == 0 {
                        text.push_str(ending);
                    }
                }
                if dice.next(3) != 0 {
                    text.push_str(&format!("正文{chapter}{ending}"));
                }
            }
            if dice.next(2) == 0 {
                text.truncate(text.trim_end().len());
            }
            let book = book_of(&text);
            let mut duplicates: Vec<_> = (1..book.tree.nodes.len())
                .filter(|&i| {
                    let (a, b) = (&book.tree.nodes[i - 1], &book.tree.nodes[i]);
                    a.title == b.title && book.text[a.body_start..a.end].trim().is_empty()
                })
                .collect();
            for i in (1..duplicates.len()).rev() {
                duplicates.swap(i, dice.next(i + 1));
            }
            if duplicates.len() >= 2 {
                let actions = duplicates.iter().map(|&i| remove(&book, i)).collect();
                let picked = request(&book, actions);
                if apply_stepwise(book.clone(), &picked).is_ok() {
                    merged += usize::from(assert_same(&book, &picked).1 == 1);
                } else {
                    assert!(apply(book.clone(), &picked).is_err(), "{round}");
                }
            }
            let mut heads: Vec<_> = (0..book.tree.nodes.len()).collect();
            for i in (1..heads.len()).rev() {
                heads.swap(i, dice.next(i + 1));
            }
            heads.truncate(1 + dice.next(heads.len()));
            let actions = heads.iter().map(|&i| demote(&book, i)).collect();
            let picked = request(&book, actions);
            if apply_stepwise(book.clone(), &picked).is_ok() {
                merged += usize::from(assert_same(&book, &picked).1 == 1);
            }
        }
        // 确认测到的确实是合并路径，不是全部退回逐步重放。
        assert!(merged > 200, "{merged}");
    }

    fn cleaned(text: &str, cleanup: Option<&str>) -> EffectiveBook {
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        publication::compose_with_cleanup(&source, &Structure::new(&source), None, cleanup).unwrap()
    }

    fn replace(find: &str, with: &str) -> String {
        format!(
            r#"{{"kind":"cleanup","pipeline":[{{"kind":"literal_replace","find":"{find}","replace":"{with}"}}]}}"#
        )
    }

    /// 换算结果要和逐步换算一字不差，再重放一遍也要得到同一本书。返回走了几段合并。
    fn assert_same_rebase(
        old: &EffectiveBook,
        new: &EffectiveBook,
        request: &Request,
    ) -> (effective_edit::Rebased, usize) {
        let step = effective_edit::rebase_stepwise(old.clone(), new.clone(), request).unwrap();
        MERGED_RUNS.with(|runs| runs.set(0));
        let fast = effective_edit::rebase(old.clone(), new.clone(), request).unwrap();
        let merged = MERGED_RUNS.with(|runs| runs.get());
        assert_eq!(fast.book.text, step.book.text);
        assert_eq!(
            serde_json::to_value(&fast.book.tree).unwrap(),
            serde_json::to_value(&step.book.tree).unwrap()
        );
        assert_eq!(
            fast.book.source_to_output_lines,
            step.book.source_to_output_lines
        );
        assert_eq!(
            fast.book.removed_structure_lines,
            step.book.removed_structure_lines
        );
        assert_eq!(fast.book.cleanup_evidence, step.book.cleanup_evidence);
        assert_eq!(fast.book.cleanup_evidence, new.cleanup_evidence);
        assert_eq!(fast.kept, step.kept);
        assert_eq!(fast.skipped, step.skipped);
        assert_eq!(
            fast.request.as_ref().map(|r| (&r.base_id, &r.actions)),
            step.request.as_ref().map(|r| (&r.base_id, &r.actions))
        );
        if let Some(request) = &fast.request {
            let replayed = apply(new.clone(), request).unwrap().0;
            assert_eq!(replayed.text, fast.book.text);
            assert_eq!(
                effective_edit::base_id(&replayed),
                effective_edit::base_id(&fast.book)
            );
        }
        (fast, merged)
    }

    #[test]
    fn rebasing_a_run_merges_on_the_new_book() {
        let text =
            "第一章 甲\n第一章 甲\n第一章 甲\n正文\n第二章 乙\n第二章 乙\n正文\n第三章 丙\n正文\n";
        let old = cleaned(text, None);
        let new = cleaned(text, Some(&replace("正文", "内容")));
        let request = request(
            &old,
            vec![remove(&old, 4), remove(&old, 2), remove(&old, 1)],
        );
        let (moved, merged) = assert_same_rebase(&old, &new, &request);
        assert_eq!(merged, 1);
        assert_eq!(moved.kept, vec![0, 1, 2]);
        assert!(moved.skipped.is_empty());
    }

    #[test]
    fn an_edit_that_no_longer_fits_is_skipped_and_the_rest_still_move() {
        // 清理后第二章上面的标题下多了正文，这一处不再是重复标题。
        let text = "第一章 甲\n第一章 甲\n第二章 乙\n待填\n第二章 乙\n第三章 丙\n第三章 丙\n第四章 丁\n第四章 丁\n正文\n";
        let old = cleaned(text, Some(&replace("待填", "")));
        let new = cleaned(text, None);
        assert_ne!(old.text, new.text);
        let picked = [7, 5, 3, 1]
            .into_iter()
            .filter(|&i| {
                let (a, b) = (&old.tree.nodes[i - 1], &old.tree.nodes[i]);
                a.title == b.title
            })
            .collect::<Vec<_>>();
        assert_eq!(picked.len(), 4);
        let actions = picked.iter().map(|&i| remove(&old, i)).collect();
        let (moved, _) = assert_same_rebase(&old, &new, &request(&old, actions));
        assert_eq!(moved.kept, vec![0, 1, 3]);
        assert_eq!(moved.skipped.len(), 1);
        assert_eq!(moved.skipped[0]["index"], 2);
        assert_eq!(moved.skipped[0]["reason"], "apply_failed");
    }

    #[test]
    fn line_based_edits_between_runs_see_the_right_old_book() {
        let text = "第一章 甲\n第一章 甲\n第一章 甲\n甲文\n第二段\n第二章 乙\n乙文\n第三章 丙\n丙文\n第四章 丁\n丁文\n";
        let old = cleaned(text, None);
        let new = cleaned(text, Some(&replace("甲文", "新文")));
        let kept = old.tree.nodes[0].entry_id.clone();
        let mut actions = vec![remove(&old, 2), remove(&old, 1)];
        actions.push(Action::Split {
            entry_id: kept.clone(),
            line_offset: 2,
            title: "第一章下".into(),
        });
        actions.push(demote(&old, 4));
        actions.push(demote(&old, 3));
        actions.push(Action::Rename {
            entry_id: kept,
            title: "第一章上".into(),
        });
        let request = request(&old, actions);
        let (moved, _) = assert_same_rebase(&old, &new, &request);
        assert_eq!(moved.kept.len(), 6);
    }

    #[test]
    fn edits_on_removed_lines_are_reported_the_same_way() {
        let text = "第一章 甲\n甲文\n删掉这行\n第二段\n第二章 乙\n乙文\n";
        let old = cleaned(text, None);
        let cleanup = r#"{"kind":"cleanup","pipeline":[{"kind":"literal_replace","find":"删掉这行\n","replace":""}]}"#;
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let Ok(new) = publication::compose_with_cleanup(
            &source,
            &Structure::new(&source),
            None,
            Some(cleanup),
        ) else {
            return;
        };
        let request = request(
            &old,
            vec![Action::Split {
                entry_id: old.tree.nodes[0].entry_id.clone(),
                line_offset: 2,
                title: "分出来".into(),
            }],
        );
        assert_same_rebase(&old, &new, &request);
    }

    #[test]
    fn random_rebases_equal_stepwise() {
        let mut dice = Dice(20261107);
        let mut merged = 0;
        let mut skipped = 0;
        for _ in 0..200 {
            let mut text = String::new();
            for chapter in 1..=(3 + dice.next(8)) {
                for _ in 0..=dice.next(3) {
                    text.push_str(&format!("第{chapter}章 题{}\n", chapter % 3));
                    if dice.next(3) == 0 {
                        text.push_str("待填\n");
                    }
                }
                if dice.next(2) == 0 {
                    text.push_str(&format!("正文{chapter}\n第二段\n"));
                }
            }
            let old = cleaned(&text, Some(&replace("待填", "")));
            let new = cleaned(&text, Some(&replace("正文", "内容")));
            let mut picked: Vec<_> = (1..old.tree.nodes.len())
                .filter(|&i| {
                    let (a, b) = (&old.tree.nodes[i - 1], &old.tree.nodes[i]);
                    a.title == b.title && old.text[a.body_start..a.end].trim().is_empty()
                })
                .collect();
            picked.reverse();
            let mut actions: Vec<_> = picked.iter().map(|&i| remove(&old, i)).collect();
            if dice.next(2) == 0 {
                let node = &old.tree.nodes[dice.next(old.tree.nodes.len())];
                actions.push(Action::Rename {
                    entry_id: node.entry_id.clone(),
                    title: "第九章 新名".into(),
                });
            }
            if actions.len() < 2 {
                continue;
            }
            let picked = request(&old, actions);
            if apply_stepwise(old.clone(), &picked).is_err() {
                continue;
            }
            let (moved, runs) = assert_same_rebase(&old, &new, &picked);
            merged += usize::from(runs > 0);
            skipped += usize::from(!moved.skipped.is_empty());
        }
        assert!(merged > 50, "{merged}");
        assert!(skipped > 10, "要测到有修改搬不动的情形：{skipped}");
    }
}
