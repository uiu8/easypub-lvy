//! 手工注释定位于当前有效稿；整行指纹失配后停用，不搜索迁移。
use crate::{block_annotations, production, publication_resources, sessions::ImportService};
use easypub_core::{ApiError, ErrorCode, publication::EffectiveBook, structure::Role};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Anchor {
    pub start: usize,
    pub end: usize,
    /// 行内 UTF-8 字节半开区间；新写注释用相同的起止位置。
    pub from: usize,
    pub to: usize,
    pub fingerprint: String,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Body {
    Pair { definition: Anchor },
    New { text: String },
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Note {
    pub id: String,
    pub reference: Anchor,
    pub body: Body,
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct Selection {
    start: usize,
    end: usize,
    from: usize,
    to: usize,
}
#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum Input {
    Pair {
        reference: Selection,
        definition: Selection,
    },
    New {
        reference: Selection,
        text: String,
    },
}
fn error(reason: &'static str) -> ApiError {
    ApiError::new(ErrorCode::InvalidRule, "manual_notes", reason)
}
fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn hash_shape(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
pub fn validate(notes: &[Note]) -> Result<(), ApiError> {
    let mut ids = BTreeSet::new();
    let mut definitions = BTreeSet::new();
    let mut ranges = BTreeMap::<usize, Vec<(usize, usize)>>::new();
    for n in notes {
        if !hash_shape(&n.id) || !ids.insert(&n.id) {
            return Err(error("note_invalid"));
        }
        let valid_anchor = |a: &Anchor| {
            a.start < a.end
                && a.from <= a.to
                && a.to <= a.end - a.start
                && hash_shape(&a.fingerprint)
        };
        if !valid_anchor(&n.reference) {
            return Err(error("note_invalid"));
        }
        let a = &n.reference;
        let list = ranges.entry(a.start).or_default();
        if list.iter().any(|&(from, to)| {
            (a.from == from)
                || (a.from < to && from < a.to)
                || (a.from == a.to && from < a.from && a.from < to)
                || (from == to && a.from < from && from < a.to)
        }) {
            return Err(error("note_overlap"));
        }
        list.push((a.from, a.to));
        match &n.body {
            Body::Pair { definition } => {
                if a.from == a.to
                    || !valid_anchor(definition)
                    || definition.from != 0
                    || definition.to != 0
                {
                    return Err(error("note_invalid"));
                }
                if !definitions.insert(definition.start) {
                    return Err(error("note_definition_used"));
                }
            }
            Body::New { text } => {
                if a.from != a.to || text.trim().is_empty() || text.chars().count() > 20_000 {
                    return Err(error("note_text_invalid"));
                }
                crate::navigation_documents::escaped(text)
                    .map_err(|_| error("note_text_invalid"))?;
            }
        }
    }
    if definitions.iter().any(|line| ranges.contains_key(line)) {
        return Err(error("note_definition_used"));
    }
    Ok(())
}
fn line_reason(a: &Anchor, book: &EffectiveBook) -> Option<&'static str> {
    let text = &book.text;
    if a.start >= a.end || a.end > text.len() {
        return Some("note_range_out_of_bounds");
    }
    let boundary = |at: usize| {
        at == 0
            || at == text.len()
            || (text.is_char_boundary(at)
                && (text.as_bytes()[at - 1] == b'\n'
                    || (text.as_bytes()[at - 1] == b'\r' && text.as_bytes()[at] != b'\n')))
    };
    if !boundary(a.start) || !boundary(a.end) {
        return Some("note_line_boundary_changed");
    }
    let whole = &text[a.start..a.end];
    let length = whole.find(['\r', '\n']).unwrap_or(whole.len());
    let eol = if whole[length..].starts_with("\r\n") {
        2
    } else {
        usize::from(length < whole.len())
    };
    let line = &whole[..length];
    if length + eol != whole.len()
        || a.to > line.len()
        || a.from > a.to
        || !line.is_char_boundary(a.from)
        || !line.is_char_boundary(a.to)
    {
        return Some("note_line_boundary_changed");
    }
    if book
        .tree
        .nodes
        .iter()
        .any(|n| n.start == a.start && n.role != Role::Body)
    {
        return Some("note_contains_heading");
    }
    if digest(whole.as_bytes()) != a.fingerprint {
        return Some("note_text_changed");
    }
    None
}
fn chapter(book: &EffectiveBook, at: usize) -> usize {
    book.tree
        .nodes
        .iter()
        .rev()
        .find(|n| n.start <= at && matches!(n.role, Role::Chapter | Role::Volume | Role::Front))
        .map_or(0, |n| n.start)
}
pub fn invalid_reason(n: &Note, book: &EffectiveBook) -> Option<&'static str> {
    line_reason(&n.reference, book).or_else(|| match &n.body {
        Body::Pair { definition } => line_reason(definition, book).or_else(|| {
            (chapter(book, n.reference.start) != chapter(book, definition.start))
                .then_some("note_crosses_chapter")
        }),
        Body::New { .. } => None,
    })
}
fn anchor(book: &EffectiveBook, s: Selection) -> Result<Anchor, ApiError> {
    let bytes = book
        .text
        .as_bytes()
        .get(s.start..s.end)
        .ok_or_else(|| error("note_range_out_of_bounds"))?;
    let a = Anchor {
        start: s.start,
        end: s.end,
        from: s.from,
        to: s.to,
        fingerprint: digest(bytes),
    };
    if let Some(reason) = line_reason(&a, book) {
        return Err(error(reason));
    }
    Ok(a)
}
fn create(book: &EffectiveBook, input: Input) -> Result<Note, ApiError> {
    let (reference, body) = match input {
        Input::Pair {
            reference,
            definition,
        } => (
            anchor(book, reference)?,
            Body::Pair {
                definition: anchor(book, definition)?,
            },
        ),
        Input::New { reference, text } => (anchor(book, reference)?, Body::New { text }),
    };
    let n = Note {
        id: digest(format!("{}:{reference:?}", book.original_source_id).as_bytes()),
        reference,
        body,
    };
    validate(std::slice::from_ref(&n))?;
    if let Some(reason) = invalid_reason(&n, book) {
        return Err(error(reason));
    }
    Ok(n)
}
pub(crate) fn location(book: &EffectiveBook, a: &Anchor) -> Value {
    let mut value = block_annotations::locate(book, a.start, a.end);
    if !value.is_null() {
        let line = &book.text[a.start..a.end];
        value["utf16_start"] = json!(line[..a.from].encode_utf16().count());
        value["utf16_end"] = json!(line[..a.to].encode_utf16().count());
    }
    value
}
pub(crate) fn report(settings: &production::Settings, book: &EffectiveBook) -> Value {
    let mut notes: Vec<Value> = settings.manual_notes.iter().map(|n| {
        let reason = invalid_reason(n, book);
        let valid = reason.is_none();
        let (kind, definition, text) = match &n.body {
            Body::Pair { definition } => ("pair", if valid { location(book, definition) } else { Value::Null },
                if valid { book.text[definition.start..definition.end].to_owned() } else { String::new() }),
            Body::New { text } => ("new", Value::Null, text.clone()),
        };
        json!({"id":n.id,"kind":kind,"note":n,"valid":valid,"reason":reason,"enabled":true,
            "location": if valid { location(book, &n.reference) } else { Value::Null },
            "definition_location":definition,"text":text,
            "marker":if valid { &book.text[n.reference.start+n.reference.from..n.reference.start+n.reference.to] } else { "" }})
    }).collect();
    notes.extend(
        crate::publication_notes::Notes::with_manual(book, &settings.manual_notes, true)
            .automatic_report(book, settings.note_style == "popup"),
    );
    json!({"content_id":digest(book.text.as_bytes()),"byte_length":book.text.len(),"notes":notes})
}
#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum Action {
    List,
    Resolve {
        entry_id: String,
        line: usize,
        utf16_start: usize,
        utf16_end: usize,
        content_id: String,
    },
    Add {
        input: Input,
        content_id: String,
    },
    Update {
        id: String,
        input: Input,
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
pub fn run(
    service: &ImportService,
    value: Value,
    apply: bool,
    plan_id: &str,
    confirmed: bool,
) -> Result<String, ApiError> {
    let mut request: Request =
        serde_json::from_value(value.clone()).map_err(|_| error("note_invalid"))?;
    if request.op != "manual_notes" || request.targets.len() != 1 {
        return Err(error("note_invalid"));
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
        return Err(error("note_stale"));
    }
    let mut next = settings.manual_notes.clone();
    let mut changed = false;
    let mut selection = Value::Null;
    let check = |id: &str| {
        if id == digest(book.text.as_bytes()) {
            Ok(())
        } else {
            Err(error("note_stale"))
        }
    };
    match request.action {
        Action::List if !apply => {}
        Action::List => return Err(error("note_invalid")),
        Action::Resolve {
            entry_id,
            line,
            utf16_start,
            utf16_end,
            content_id,
        } => {
            check(&content_id)?;
            if apply {
                return Err(error("note_invalid"));
            }
            selection = block_annotations::line_range(&book, &entry_id, line, line)
                .map_err(|_| error("note_range_out_of_bounds"))?;
            let start = selection["start"].as_u64().unwrap() as usize;
            let end = selection["end"].as_u64().unwrap() as usize;
            let text = book.text[start..end].trim_end_matches(['\r', '\n']);
            let byte_at = |wanted| {
                let mut units = 0;
                for (at, c) in text.char_indices() {
                    if units == wanted {
                        return Ok(at);
                    }
                    units += c.len_utf16();
                }
                if units == wanted {
                    Ok(text.len())
                } else {
                    Err(error("note_character_boundary"))
                }
            };
            if utf16_start > utf16_end {
                return Err(error("note_character_boundary"));
            }
            selection["from"] = json!(byte_at(utf16_start)?);
            selection["to"] = json!(byte_at(utf16_end)?);
        }
        Action::Add { input, content_id } => {
            check(&content_id)?;
            next.push(create(&book, input)?);
            changed = true;
        }
        Action::Update {
            id,
            input,
            content_id,
        } => {
            check(&content_id)?;
            let old = next
                .iter_mut()
                .find(|n| n.id == id)
                .ok_or_else(|| error("note_missing"))?;
            *old = Note {
                id,
                ..create(&book, input)?
            };
            changed = true;
        }
        Action::Delete { id } => {
            let i = next
                .iter()
                .position(|n| n.id == id)
                .ok_or_else(|| error("note_missing"))?;
            next.remove(i);
            changed = true;
        }
        Action::Undo => target.change = production::Change::Undo {},
        Action::Redo => target.change = production::Change::Redo {},
    }
    if changed {
        next.sort_by_key(|n| (n.reference.start, n.reference.from));
        validate(&next)?;
        target.change = production::Change::Patch {
            fields: BTreeMap::from([(
                "manual_notes".into(),
                production::Edit::Set { value: json!(next) },
            )]),
        };
    }
    let inner = serde_json::to_string(&production::Request {
        targets: vec![target],
    })
    .map_err(|_| error("note_invalid"))?;
    let mut result: Value = serde_json::from_str(&production::run(
        service,
        inner.clone(),
        false,
        String::new(),
        false,
    )?)
    .map_err(|_| error("note_invalid"))?;
    let inner_id = result["plan_id"].as_str().unwrap().to_owned();
    let id = digest(format!("{value}:{inner_id}:{}", digest(book.text.as_bytes())).as_bytes());
    if apply {
        if !confirmed || plan_id != id {
            return Err(error("note_stale"));
        }
        result = serde_json::from_str(&production::run(service, inner, true, inner_id, true)?)
            .map_err(|_| error("note_invalid"))?;
    }
    let after = serde_json::from_value(result["items"][0]["after"].clone())
        .map_err(|_| error("note_invalid"))?;
    result["plan_id"] = json!(id);
    result["manual_notes"] = report(&after, &book);
    result["manual_notes_before"] = report(&settings, &book);
    if !selection.is_null() {
        result["selection"] = selection;
    }
    Ok(result.to_string())
}

#[cfg(test)]
#[path = "manual_notes_tests.rs"]
mod tests;
