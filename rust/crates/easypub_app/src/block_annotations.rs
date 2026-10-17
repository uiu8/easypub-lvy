//! 原位、整行的手工排版标注；指纹失配时停用，不搜索或迁移位置。
use crate::{production, publication_resources, sessions::ImportService};
use easypub_core::{ApiError, ErrorCode, publication::EffectiveBook, structure::Role};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Letter,
    Quote,
    Verse,
    System,
    None,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Annotation {
    pub id: String,
    /// 当前有效书稿 UTF-8 字节坐标，半开区间，包含末行的换行符（如有）。
    pub start: usize,
    pub end: usize,
    pub kind: Kind,
    pub fingerprint: String,
}
fn error(reason: &'static str) -> ApiError {
    ApiError::new(ErrorCode::InvalidRule, "block_annotations", reason)
}
fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn hash_shape(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
pub fn validate(annotations: &[Annotation]) -> Result<(), ApiError> {
    let mut ids = BTreeSet::new();
    let mut ordered: Vec<_> = annotations.iter().collect();
    ordered.sort_by_key(|a| a.start);
    for (index, a) in ordered.iter().enumerate() {
        if index > 0 && ordered[index - 1].end > a.start {
            return Err(error("block_annotation_overlap"));
        }
        if a.start >= a.end
            || !hash_shape(&a.id)
            || !hash_shape(&a.fingerprint)
            || !ids.insert(&a.id)
        {
            return Err(error("block_annotation_invalid"));
        }
    }
    Ok(())
}
fn boundary(text: &str, at: usize) -> bool {
    if at == 0 || at == text.len() {
        return true;
    }
    let bytes = text.as_bytes();
    text.is_char_boundary(at)
        && (bytes[at - 1] == b'\n' || (bytes[at - 1] == b'\r' && bytes[at] != b'\n'))
}
fn range_reason(start: usize, end: usize, book: &EffectiveBook) -> Option<&'static str> {
    if start >= end || end > book.text.len() {
        return Some("block_range_out_of_bounds");
    }
    if !boundary(&book.text, start) || !boundary(&book.text, end) {
        return Some("block_line_boundary_changed");
    }
    if book
        .tree
        .nodes
        .iter()
        .any(|n| n.start >= start && n.start < end && n.role != Role::Body)
    {
        return Some("block_contains_heading");
    }
    if book
        .tree
        .nodes
        .iter()
        .any(|n| n.start > start && n.start < end)
    {
        return Some("block_crosses_section");
    }
    None
}
pub fn invalid_reason(a: &Annotation, book: &EffectiveBook) -> Option<&'static str> {
    range_reason(a.start, a.end, book).or_else(|| {
        (digest(&book.text.as_bytes()[a.start..a.end]) != a.fingerprint)
            .then_some("block_text_changed")
    })
}
/// 与 EffectiveBook::body_preview 的行号相同：正文内从 1 开始，末行包含在内。
pub(crate) fn line_range(
    book: &EffectiveBook,
    entry_id: &str,
    first: usize,
    last: usize,
) -> Result<Value, ApiError> {
    let (mut offset, limit) = if entry_id == "$prefix" {
        (0, book.tree.prefix_end)
    } else {
        let node = book
            .tree
            .nodes
            .iter()
            .find(|n| n.entry_id == entry_id)
            .ok_or_else(|| error("block_annotation_stale"))?;
        (node.body_start, node.end)
    };
    if first == 0 || first > last {
        return Err(error("block_range_out_of_bounds"));
    }
    let mut start = offset;
    let mut index = 1;
    while offset < limit {
        if index == first {
            start = offset;
        }
        let rest = &book.text[offset..limit];
        let length = rest.find(['\r', '\n']).unwrap_or(rest.len());
        let tail = &rest[length..];
        offset += length
            + if tail.starts_with("\r\n") {
                2
            } else if tail.is_empty() {
                0
            } else {
                1
            };
        if index == last {
            if let Some(reason) = range_reason(start, offset, book) {
                return Err(error(reason));
            }
            return Ok(json!({"start": start, "end": offset}));
        }
        index += 1;
    }
    Err(error("block_range_out_of_bounds"))
}
fn create(
    book: &EffectiveBook,
    start: usize,
    end: usize,
    kind: Kind,
) -> Result<Annotation, ApiError> {
    if let Some(reason) = range_reason(start, end, book) {
        return Err(error(reason));
    }
    let fingerprint = digest(&book.text.as_bytes()[start..end]);
    let id = digest(format!("{}:{start}:{end}:{fingerprint}", book.original_source_id).as_bytes());
    Ok(Annotation {
        id,
        start,
        end,
        kind,
        fingerprint,
    })
}
/// 有效标注所在的正文分节与行号（V53，与 line_range 同一编号），供章节页在行号旁画出标注。
pub(crate) fn locate(book: &EffectiveBook, start: usize, end: usize) -> Value {
    let (entry_id, mut offset) = match book
        .tree
        .nodes
        .iter()
        .filter(|n| n.body_start <= start)
        .max_by_key(|n| n.body_start)
    {
        Some(node) => (node.entry_id.as_str(), node.body_start),
        None => ("$prefix", 0),
    };
    let (mut line, mut first) = (1, 0);
    while offset < end {
        if offset == start {
            first = line;
        }
        let rest = &book.text[offset..];
        let length = rest.find(['\r', '\n']).unwrap_or(rest.len());
        let tail = &rest[length..];
        offset += length
            + if tail.starts_with("\r\n") {
                2
            } else if tail.is_empty() {
                0
            } else {
                1
            };
        if offset >= end {
            return if first == 0 {
                Value::Null
            } else {
                json!({"entry_id": entry_id, "first_line": first, "last_line": line})
            };
        }
        line += 1;
    }
    Value::Null
}
pub(crate) fn report(annotations: &[Annotation], book: &EffectiveBook) -> Value {
    json!({"content_id": digest(book.text.as_bytes()), "byte_length": book.text.len(),
        "annotations": annotations.iter().map(|a| {
            let reason = invalid_reason(a, book);
            json!({"annotation": a, "valid": reason.is_none(), "reason": reason,
                "excerpt": if reason.is_none() { book.text[a.start..a.end].chars().take(160).collect::<String>() } else { String::new() },
                "location": if reason.is_none() { locate(book, a.start, a.end) } else { Value::Null }})
        }).collect::<Vec<_>>()})
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum Action {
    List,
    ResolveLines {
        entry_id: String,
        first_line: usize,
        last_line: usize,
        content_id: String,
    },
    Add {
        start: usize,
        end: usize,
        block_kind: Kind,
        content_id: String,
    },
    Update {
        id: String,
        start: usize,
        end: usize,
        block_kind: Kind,
        content_id: String,
    },
    Delete {
        id: String,
    },
    Undo,
    Redo,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    op: String,
    publication: publication_resources::Request,
    targets: Vec<production::Target>,
    action: Action,
}

/// 经现有 production_batch_text 传输，返回同一 ProductionPreview/History 合同。
pub fn run(
    service: &ImportService,
    value: Value,
    apply: bool,
    plan_id: &str,
    confirmed: bool,
) -> Result<String, ApiError> {
    let mut request: Request =
        serde_json::from_value(value.clone()).map_err(|_| error("block_annotation_invalid"))?;
    if request.op != "block_annotations" || request.targets.len() != 1 {
        return Err(error("block_annotation_invalid"));
    }
    let source = service.source(&request.publication.source_id, request.publication.revision)?;
    let (book, settings) = publication_resources::compose(&source, request.publication)?;
    let mut target = request.targets.remove(0);
    target.history.validate(source.summary().line_count)?;
    if !matches!(target.change, production::Change::Inspect {})
        || target.history.source_id != source.summary().source_id
        || target.history.revision != source.summary().revision
        || target.current.as_ref().unwrap_or(target.history.current()) != &settings
    {
        return Err(error("block_annotation_stale"));
    }
    let mut next = settings.block_annotations.clone();
    let mut changed = false;
    let mut selection = Value::Null;
    match request.action {
        Action::List if !apply => {}
        Action::List => return Err(error("block_annotation_invalid")),
        Action::ResolveLines {
            entry_id,
            first_line,
            last_line,
            content_id,
        } => {
            if apply || content_id != digest(book.text.as_bytes()) {
                return Err(error("block_annotation_stale"));
            }
            selection = line_range(&book, &entry_id, first_line, last_line)?;
        }
        Action::Undo => target.change = production::Change::Undo {},
        Action::Redo => target.change = production::Change::Redo {},
        Action::Add {
            start,
            end,
            block_kind,
            content_id,
        } => {
            if content_id != digest(book.text.as_bytes()) {
                return Err(error("block_annotation_stale"));
            }
            next.push(create(&book, start, end, block_kind)?);
            changed = true;
        }
        Action::Update {
            id,
            start,
            end,
            block_kind,
            content_id,
        } => {
            if content_id != digest(book.text.as_bytes()) {
                return Err(error("block_annotation_stale"));
            }
            let old = next
                .iter_mut()
                .find(|a| a.id == id)
                .ok_or_else(|| error("block_annotation_missing"))?;
            *old = Annotation {
                id,
                ..create(&book, start, end, block_kind)?
            };
            changed = true;
        }
        Action::Delete { id } => {
            let index = next
                .iter()
                .position(|a| a.id == id)
                .ok_or_else(|| error("block_annotation_missing"))?;
            next.remove(index);
            changed = true;
        }
    }
    if changed {
        next.sort_by_key(|a| a.start);
        validate(&next)?;
        target.change = production::Change::Patch {
            fields: BTreeMap::from([(
                "block_annotations".into(),
                production::Edit::Set { value: json!(next) },
            )]),
        };
    }
    let inner = serde_json::to_string(&production::Request {
        targets: vec![target],
    })
    .map_err(|_| error("block_annotation_invalid"))?;
    let mut result: Value = serde_json::from_str(&production::run(
        service,
        inner.clone(),
        false,
        String::new(),
        false,
    )?)
    .map_err(|_| error("block_annotation_invalid"))?;
    let inner_id = result["plan_id"].as_str().unwrap().to_owned();
    let id = digest(format!("{value}:{inner_id}:{}", digest(book.text.as_bytes())).as_bytes());
    if apply {
        if !confirmed || plan_id != id {
            return Err(error("block_annotation_stale"));
        }
        result = serde_json::from_str(&production::run(service, inner, true, inner_id, true)?)
            .map_err(|_| error("block_annotation_invalid"))?;
    }
    let after: production::Settings = serde_json::from_value(result["items"][0]["after"].clone())
        .map_err(|_| error("block_annotation_invalid"))?;
    result["plan_id"] = json!(id);
    result["block_annotations"] = report(&after.block_annotations, &book);
    result["block_annotations_before"] = report(&settings.block_annotations, &book);
    if !selection.is_null() {
        result["selection"] = selection;
    }
    Ok(result.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use easypub_core::source::{RULE_ID, SourceSnapshot};
    use std::{
        fs,
        time::{Duration, Instant, SystemTime, UNIX_EPOCH},
    };

    fn settings() -> Value {
        json!({"title":"标注样书", "author":"", "description":"", "language":"zh-CN",
            "cover_fit":"contain", "font_family":"SimSun", "font_size":20, "line_height":1.8,
            "include_toc":true, "illustrations":[], "note_style":"popup", "first_paragraph_style":"large_initial"})
    }
    fn input(source: &SourceSnapshot) -> Value {
        json!({"source_id":source.summary().source_id,"revision":1,"settings":settings()})
    }
    fn book(text: &str) -> (SourceSnapshot, EffectiveBook) {
        let source =
            SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
        let (book, _) = publication_resources::compose(
            &source,
            serde_json::from_value(input(&source)).unwrap(),
        )
        .unwrap();
        (source, book)
    }
    fn mark(book: &EffectiveBook, text: &str, kind: Kind) -> Annotation {
        let start = book.text.find(text).unwrap();
        create(book, start, start + text.len(), kind).unwrap()
    }
    #[test]
    fn locate_inverts_line_range_for_prefix_chapters_and_line_endings() {
        // V53：章节页用 location 在行号旁画标注，必须与 resolveLines 的行号互逆。
        let (_, book) =
            book("卷首语甲\n卷首语乙\n第一章 开始\r\n甲\r\n乙\r\n丙\r\n第二章 下山\n丁\n戊");
        let mut cases = vec![("$prefix".to_owned(), 1, 2)];
        assert_eq!(book.tree.nodes.len(), 2);
        for node in &book.tree.nodes {
            cases.push((node.entry_id.clone(), 1, 1));
            cases.push((node.entry_id.clone(), 1, 2));
        }
        // 第一章 CRLF 三行；第二章末行没有换行符。
        cases.push((book.tree.nodes[0].entry_id.clone(), 2, 3));
        cases.push((book.tree.nodes[1].entry_id.clone(), 2, 2));
        for (entry, first, last) in cases {
            let range = line_range(&book, &entry, first, last).unwrap();
            let (start, end) = (
                range["start"].as_u64().unwrap() as usize,
                range["end"].as_u64().unwrap() as usize,
            );
            assert_eq!(
                locate(&book, start, end),
                json!({"entry_id": entry, "first_line": first, "last_line": last}),
                "{entry} {first}-{last}"
            );
        }
        // 报告里只有有效标注带位置。
        let a = mark(&book, "甲\r\n乙\r\n", Kind::Letter);
        let report = report(&[a], &book);
        assert_eq!(report["annotations"][0]["location"]["first_line"], 1);
        assert_eq!(report["annotations"][0]["location"]["last_line"], 2);
    }

    fn apply(service: &ImportService, request: &mut Value, action: Value) -> Value {
        request["action"] = action;
        let preview: Value =
            serde_json::from_str(&run(service, request.clone(), false, "", false).unwrap())
                .unwrap();
        assert!(preview["items"][0]["history"].is_null());
        assert!(run(service, request.clone(), true, "wrong", true).is_err());
        let result: Value = serde_json::from_str(
            &run(
                service,
                request.clone(),
                true,
                preview["plan_id"].as_str().unwrap(),
                true,
            )
            .unwrap(),
        )
        .unwrap();
        request["publication"]["settings"] = result["items"][0]["after"].clone();
        request["targets"][0]["current"] = result["items"][0]["after"].clone();
        request["targets"][0]["history"] = result["items"][0]["history"].clone();
        result
    }
    #[test]
    fn preview_crud_rejects_overlap_and_project_reopens_with_undo_redo() {
        let root = std::env::temp_dir().join(format!(
            "easypub-v52-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&root).unwrap();
        let path = root.join("书信.txt");
        let text = "第一章 来信\n亲爱的朋友：\n祝一路平安。\n故人\n";
        fs::write(&path, text).unwrap();
        let service = ImportService::new().unwrap();
        let job = service
            .start_import(path.to_string_lossy().into(), RULE_ID.into())
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        let summary = loop {
            let status = service.get_job(job).unwrap();
            if status.terminal() {
                break status.book.unwrap();
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(2));
        };
        let mut request = json!({"op":"block_annotations",
            "publication":{"source_id":summary.source_id,"revision":1,"settings":settings()},
            "targets":[{"book_id":"book", "current":settings(), "change":{"op":"inspect"},
                "history":{"source_id":summary.source_id,"revision":1,"states":[settings()],"cursor":0}}],
            "action":{"kind":"list"}});
        let start = text.find("亲爱的").unwrap();
        let action = json!({"kind":"add","start":start,"end":text.len(),"block_kind":"letter","content_id":digest(text.as_bytes())});
        let result = apply(&service, &mut request, action.clone());
        let id = result["block_annotations"]["annotations"][0]["annotation"]["id"].clone();
        request["action"] = action;
        assert_eq!(
            run(&service, request.clone(), false, "", false)
                .unwrap_err()
                .next_action,
            "block_annotation_overlap"
        );
        let mut saved_book = request["publication"]["settings"].clone();
        for (key, value) in
            json!({"path":path,"source_id":summary.source_id,"revision":1,"selected":true,
            "production_history":request["targets"][0]["history"]})
            .as_object()
            .unwrap()
        {
            saved_book[key] = value.clone();
        }
        let project = json!({"schema":1,"rule_id":RULE_ID,"books":[saved_book],"current_path":path,"output":root,"format":"EPUB"});
        let file = root.join("project.easypub.json");
        crate::project::save(&service, file.to_str().unwrap(), &project.to_string()).unwrap();
        let reopened = ImportService::new().unwrap();
        let restored: Value =
            serde_json::from_str(&crate::project::open(&reopened, file.to_str().unwrap()).unwrap())
                .unwrap();
        let restored = &restored["project"]["books"][0];
        assert_eq!(
            restored["block_annotations"],
            request["publication"]["settings"]["block_annotations"]
        );
        request["targets"][0]["history"] = restored["production_history"].clone();
        let restored_book: crate::project::ProjectBook =
            serde_json::from_value(restored.clone()).unwrap();
        let restored_settings = json!(production::Settings::from(&restored_book));
        request["publication"]["settings"] = restored_settings.clone();
        request["targets"][0]["current"] = restored_settings;
        assert!(apply(&reopened, &mut request, json!({"kind":"undo"}))["block_annotations"]["annotations"].as_array().unwrap().is_empty());
        assert_eq!(apply(&reopened, &mut request, json!({"kind":"redo"}))["block_annotations"]["annotations"].as_array().unwrap().len(), 1);
        let updated = apply(
            &reopened,
            &mut request,
            json!({"kind":"update","id":id,"start":start,"end":text.len(),"block_kind":"quote","content_id":digest(text.as_bytes())}),
        );
        assert_eq!(
            updated["block_annotations"]["annotations"][0]["annotation"]["kind"],
            "quote"
        );
        assert!(apply(&reopened, &mut request, json!({"kind":"delete","id":id}))["block_annotations"]["annotations"].as_array().unwrap().is_empty());
        assert_eq!(fs::read(&path).unwrap(), text.as_bytes());
    }
    #[test]
    fn boundaries_fingerprints_and_headings_invalidate_without_relocation() {
        let (_, original) = book("第一章 起\r\n正文甲。\r\n正文乙。\r尾行");
        let a = mark(&original, "正文甲。\r\n", Kind::Letter);
        let node_id = &original.tree.nodes[0].entry_id;
        assert_eq!(
            line_range(&original, node_id, 1, 1).unwrap(),
            json!({"start":a.start,"end":a.end})
        );
        assert_eq!(
            line_range(&original, node_id, 2, 3).unwrap()["end"],
            original.text.len()
        );
        assert!(line_range(&original, node_id, 0, 1).is_err());
        assert!(line_range(&original, node_id, 1, 4).is_err());
        assert!(invalid_reason(&a, &original).is_none());
        let (_, changed) = book("第一章 起\r\n正文丙。\r\n正文乙。\r尾行");
        assert_eq!(invalid_reason(&a, &changed), Some("block_text_changed"));
        let (_, shifted) = book("第一章 起\r\n新增正文\r\n正文甲。\r\n正文乙。\r尾行");
        assert!(invalid_reason(&a, &shifted).is_some());
        assert!(create(&original, a.start + 1, a.end, Kind::None).is_err());
        assert!(create(&original, a.start, a.end - 1, Kind::None).is_err());
        assert_eq!(
            create(&original, 0, a.end, Kind::Quote)
                .unwrap_err()
                .next_action,
            "block_contains_heading"
        );
        let (source, mut request_book) = book("第一章 起\r\n正文丙。\r\n正文乙。\r尾行");
        let mut request = input(&source);
        request["settings"]["block_annotations"] = json!([a]);
        let prepared =
            publication_resources::prepare(&source, serde_json::from_value(request).unwrap())
                .unwrap();
        assert!(prepared.manifest().block_annotations.is_empty());
        assert!(
            prepared
                .documents()
                .unwrap()
                .pages
                .values()
                .all(|p| !p.contains("letter-block"))
        );
        request_book.text.clear();
        assert_eq!(
            invalid_reason(&a, &request_book),
            Some("block_range_out_of_bounds")
        );
    }
    #[test]
    fn manual_kinds_override_auto_and_combine_with_notes_initials_and_splitting() {
        let text = "第一章 起\n\t　首段①。\n\t　亲爱的朋友：\n愿你归来。\n故人\n【引文不是系统提示】\n自由的诗\n——作者\n自拟提示\n【自动提示】\n【取消自动】\n床前明月光，疑是地上霜。\n＊＊＊\n另一首段。\n①注释。\n";
        let (source, book) = book(text);
        let annotations = vec![
            mark(&book, "\t　亲爱的朋友：\n愿你归来。\n故人\n", Kind::Letter),
            mark(&book, "【引文不是系统提示】\n", Kind::Quote),
            mark(&book, "自由的诗\n——作者\n", Kind::Verse),
            mark(&book, "自拟提示\n", Kind::System),
            mark(&book, "【取消自动】\n", Kind::None),
        ];
        for (system, verse) in [("box", "center"), ("indent", "indent"), ("off", "off")] {
            let mut request = input(&source);
            request["settings"]["block_annotations"] = json!(annotations);
            request["settings"]["system_block_style"] = json!(system);
            request["settings"]["verse_block_style"] = json!(verse);
            let prepared =
                publication_resources::prepare(&source, serde_json::from_value(request).unwrap())
                    .unwrap();
            let mut docs = prepared.documents().unwrap();
            crate::publication_split::split(&mut docs, 400).unwrap();
            let mut restored = String::new();
            let mut blocks = Vec::new();
            let mut first_char = false;
            let mut note = false;
            for name in &docs.reading_order {
                let xml = roxmltree::Document::parse(&docs.pages[name]).unwrap();
                for node in xml.descendants() {
                    let class = node.attribute("class").unwrap_or("");
                    if node.has_tag_name("div") {
                        blocks.push(class.to_owned());
                    }
                    first_char |= class == "first-char";
                    note |= node.has_tag_name("aside");
                    if node.attribute("data-source") == Some("true") {
                        let original = node
                            .attribute("data-original")
                            .map(str::to_owned)
                            .unwrap_or_else(|| {
                                node.descendants()
                                    .filter(|n| n.is_text())
                                    .filter_map(|n| n.text())
                                    .collect()
                            });
                        if original.contains("取消自动") {
                            assert!(!class.contains("system-line"));
                        }
                        restored.push_str(&original);
                        restored.push_str(if node.attribute("data-eol") == Some("lf") {
                            "\n"
                        } else {
                            ""
                        });
                    }
                }
            }
            assert_eq!(restored, text);
            assert!(first_char && note);
            assert_eq!(
                blocks
                    .iter()
                    .filter(|s| s.as_str() == "letter-block")
                    .count(),
                1
            );
            assert_eq!(
                blocks
                    .iter()
                    .filter(|s| s.as_str() == "quote-block")
                    .count(),
                1
            );
            assert_eq!(
                blocks
                    .iter()
                    .filter(|s| s.starts_with("system-block"))
                    .count(),
                if system == "off" { 1 } else { 2 }
            );
            assert_eq!(
                blocks
                    .iter()
                    .filter(|s| s.starts_with("verse-block"))
                    .count(),
                if verse == "off" { 1 } else { 2 }
            );
        }
    }
}
