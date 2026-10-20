use super::*;
use crate::{
    block_annotations, manual_notes, production::Settings, publication_documents as render,
    publication_notes::Notes,
};
use easypub_core::structure::Role;
use std::collections::{BTreeMap, BTreeSet};

fn render_insets(
    book: &EffectiveBook,
    annotations: &[&block_annotations::Annotation],
    chat: bool,
    rules: &crate::insets::Rules,
) -> BTreeMap<usize, crate::insets::Line> {
    let owned: Vec<_> = annotations.iter().map(|a| (*a).clone()).collect();
    crate::insets::plan(&book.text, &book.tree.nodes, &owned, chat, rules)
}

pub(super) fn collect(
    book: &EffectiveBook,
    settings: &Settings,
    loc: &Locations<'_>,
    stats: &mut Statistics,
    cancel: &AtomicBool,
) -> Result<(), ApiError> {
    for (id, enabled) in [
        ("scene", settings.scene_break_style != "off"),
        (
            "first_paragraph",
            settings.first_paragraph_style != "normal",
        ),
        ("system", settings.system_block_style != "off"),
        ("verse", settings.verse_block_style != "off"),
        ("chat", settings.chat_block_style != "off"),
        ("inset", settings.inset_detect == "on"),
        ("note", settings.note_style == "popup"),
        ("rare_char", settings.rare_char_ruby != "off"),
    ] {
        for (key, r) in stats.iter_mut().filter(|(key, _)| {
            **key == format!("layout.{id}") || key.starts_with(&format!("layout.{id}."))
        }) {
            r.enabled = enabled;
            if key.starts_with("layout.note") {
                r.unit = "pairs";
            }
        }
    }
    let mut annotations = Vec::new();
    for a in &settings.block_annotations {
        checkpoint(cancel)?;
        let subtype = serde_json::to_value(a.kind)
            .expect("kind")
            .as_str()
            .expect("kind")
            .to_owned();
        let invalid = block_annotations::invalid_reason(a, book).is_some();
        for key in [
            "layout.manual_block".to_owned(),
            format!("layout.manual_block.{subtype}"),
        ] {
            let r = stats.get_mut(&key).expect("rule");
            if invalid {
                r.invalid_count += 1;
            } else {
                r.hit(loc.byte(a.start));
            }
        }
        if !invalid {
            annotations.push(a);
        }
    }
    annotations.sort_by_key(|a| a.start);
    let mut manual = Vec::new();
    for n in &settings.manual_notes {
        checkpoint(cancel)?;
        let subtype = match n.body {
            manual_notes::Body::Pair { .. } => "pair",
            manual_notes::Body::New { .. } => "new",
        };
        let invalid = manual_notes::invalid_reason(n, book).is_some();
        for key in [
            "layout.manual_note".to_owned(),
            format!("layout.manual_note.{subtype}"),
        ] {
            let r = stats.get_mut(&key).expect("rule");
            r.unit = "pairs";
            if invalid {
                r.invalid_count += 1;
            } else {
                r.hit(loc.byte(n.reference.start));
            }
        }
        if !invalid {
            manual.push(n.clone());
        }
    }
    let notes = Notes::with_options(book, &manual, true, &settings.rule_options);
    for pair in notes.automatic_report(book, settings.note_style == "popup") {
        checkpoint(cancel)?;
        let location = loc.byte(pair["reference_start"].as_u64().expect("reference") as usize);
        stats
            .get_mut("layout.note")
            .expect("rule")
            .hit(location.clone());
        let marker = pair["marker"].as_str().expect("marker");
        let family = if marker.contains('注') {
            "annotated"
        } else if marker.starts_with('[') {
            "bracket"
        } else if marker.starts_with('［') {
            "fullwidth"
        } else if marker.starts_with('〔') {
            "tortoise"
        } else {
            "circled"
        };
        stats
            .get_mut(&format!("layout.note.{family}"))
            .expect("rule")
            .hit(location.clone());
        if pair["definition_marker"]
            .as_str()
            .expect("definition")
            .starts_with('注')
        {
            stats
                .get_mut("layout.note.definition_prefix")
                .expect("rule")
                .hit(location);
        }
    }
    let manual_only =
        (settings.note_style != "popup").then(|| Notes::with_manual(book, &manual, false));
    let current_notes = manual_only.as_ref().unwrap_or(&notes);
    let (mut ai, mut ni) = (0, 0);
    let (mut previous, mut current_previous) = (None, None);
    let mut block = None;
    let mut verse_kinds = BTreeSet::new();
    let mut first_pending = false;
    // 系统提示自定义识别（V78）：统计与正文生成用同一组规则。
    let custom = settings.rule_options.system_set();
    // 场景样式（V81）：自动识别的聊天记录按开启时统计（与系统提示用 box 统计相同），并优先于系统提示。
    // 规则识别（V82）按开启时统计：内置项与自定义规则都计入，便于在规则页看到“开启会命中”。
    let mut all_on = settings.rule_options.clone();
    all_on
        .disabled
        .retain(|id| !id.starts_with("layout.inset."));
    let rules = crate::insets::Rules::from_settings("on", &all_on);
    let current_rules =
        crate::insets::Rules::from_settings(&settings.inset_detect, &settings.rule_options);
    let insets = render_insets(book, &annotations, true, &rules);
    let current_insets = render_insets(
        book,
        &annotations,
        settings.chat_block_style != "off",
        &current_rules,
    );
    let rare_scope = easypub_core::rare_chars::Scope::parse(&settings.rare_char_scope)
        .unwrap_or(easypub_core::rare_chars::Scope::Outside);
    for (i, &(start, content_end)) in loc.lines.iter().enumerate() {
        if i % 256 == 0 {
            checkpoint(cancel)?;
        }
        let end = loc.lines.get(i + 1).map_or(book.text.len(), |v| v.0);
        let line = &book.text[start..content_end];
        while annotations.get(ai).is_some_and(|a| a.end <= start) {
            ai += 1;
        }
        let annotation = annotations.get(ai).copied().filter(|a| a.start <= start);
        while book.tree.nodes.get(ni).is_some_and(|n| n.start < start) {
            ni += 1;
        }
        let node = book.tree.nodes.get(ni).filter(|n| n.start == start);
        let next_line = loc.lines.get(i + 1).map(|&(s, e)| &book.text[s..e]);
        let classified = render::custom_system(
            render::classify_block(
                line,
                node.is_some(),
                annotation,
                (start, end),
                previous,
                next_line,
                "box",
                "center",
            ),
            line,
            node.is_some() || annotation.is_some(),
            "box",
            custom.as_ref(),
        );
        let classified = if annotation.is_none() {
            settings.rule_options.verse(line, classified)
        } else {
            classified
        };
        let classified = match insets.get(&start) {
            Some(l) if l.source == "chat" => Some(("chat", "inset-line")),
            Some(l) if l.automatic() => Some(("inset", "inset-line")),
            _ => classified,
        };
        // 规则识别的块：每块计一次所属细分（诏书、论坛楼层、自定义）。
        if let Some(l) = insets.get(&start)
            && l.automatic()
            && l.source != "chat"
            && l.block == start
        {
            stats
                .get_mut(&format!("layout.inset.{}", l.source))
                .expect("inset rule")
                .hit(loc.byte(start));
        }
        previous = if annotation.is_none() {
            classified.map(|(_, c)| c)
        } else {
            None
        };
        let next = classified.map(|(kind, _)| (kind, annotation.map(|a| a.id.as_str())));
        if block != next || node.is_some() {
            verse_kinds.clear();
            if let Some((kind, None)) = next {
                stats
                    .get_mut(&format!("layout.{kind}"))
                    .expect("automatic block")
                    .hit(loc.byte(start));
            }
        }
        block = next;
        if annotation.is_none() && classified.is_some_and(|(k, _)| k == "verse") {
            let sub = if classified == Some(("verse", "verse-by")) {
                "attribution"
            } else if line
                .trim()
                .split(['，', ','])
                .next()
                .expect("verse")
                .chars()
                .count()
                == 5
            {
                "five"
            } else {
                "seven"
            };
            if verse_kinds.insert(sub) {
                stats
                    .get_mut(&format!("layout.verse.{sub}"))
                    .expect("rule")
                    .hit(loc.byte(start));
            }
        }
        // First-paragraph eligibility depends on the currently enabled surrounding layout rules.
        let current = render::custom_system(
            render::classify_block(
                line,
                node.is_some(),
                annotation,
                (start, end),
                current_previous,
                next_line,
                &settings.system_block_style,
                &settings.verse_block_style,
            ),
            line,
            node.is_some() || annotation.is_some(),
            &settings.system_block_style,
            custom.as_ref(),
        );
        let current = if annotation.is_none() {
            settings.rule_options.verse(line, current)
        } else {
            current
        };
        let current = match current_insets.get(&start) {
            Some(l) if l.source == "chat" => Some(("chat", "inset-line")),
            Some(l) if l.automatic() => Some(("inset", "inset-line")),
            _ => current,
        };
        current_previous = if annotation.is_none() {
            current.map(|(_, c)| c)
        } else {
            None
        };
        let heading = node.is_some_and(|n| n.role != Role::Body);
        let scene = annotation.is_none()
            && node.is_none()
            && !current_notes.has_line(start)
            && settings.rule_options.scene(line);
        if scene {
            stats
                .get_mut("layout.scene")
                .expect("rule")
                .hit(loc.byte(start));
            for c in line
                .chars()
                .filter(|c| !c.is_whitespace())
                .collect::<BTreeSet<_>>()
            {
                stats
                    .get_mut(&format!("layout.scene.u{:04x}", c as u32))
                    .expect("symbol")
                    .hit(loc.byte(start));
            }
        }
        let visible_scene = scene && settings.scene_break_style != "off";
        if !heading
            && !line.trim().is_empty()
            && !visible_scene
            && first_pending
            && current.is_none()
        {
            stats
                .get_mut("layout.first_paragraph")
                .expect("rule")
                .hit(loc.byte(start));
        }
        // 生僻字注音（V73，LAY-129）：含生僻字的正文行；关闭时仍统计，供“开启会命中”显示。
        if !heading
            && !scene
            && line
                .chars()
                .any(|c| easypub_core::rare_chars::reading(c, rare_scope).is_some())
        {
            stats
                .get_mut("layout.rare_char")
                .expect("rule")
                .hit(loc.byte(start));
        }
        if heading || visible_scene {
            first_pending = true;
        } else if !line.trim().is_empty() {
            first_pending = false;
        }
    }
    Ok(())
}
