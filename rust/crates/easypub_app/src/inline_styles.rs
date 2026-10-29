//! V105：有效稿上的非破坏性单行样式。
use crate::{
    block_annotations,
    manual_notes::{self, Anchor},
    production, publication_resources,
    sessions::ImportService,
};
use easypub_core::{ApiError, ErrorCode, publication::EffectiveBook};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Style {
    Bold,
    Italic,
    EmDot,
    Underline,
    Wavy,
    Kai,
    FangSong,
}
impl Style {
    pub fn format_notes(self) -> &'static [&'static str] {
        match self {
            Self::Wavy => &["kfx_underline_fallback"],
            Self::Kai | Self::FangSong => &["azw3_mobi_font_fallback", "reader_font_required"],
            _ => &[],
        }
    }
    pub fn class(self) -> &'static str {
        match self {
            Self::Bold => "inline-bold",
            Self::Italic => "inline-italic",
            Self::EmDot => "em-dot",
            Self::Underline => "inline-underline",
            Self::Wavy => "inline-wavy",
            Self::Kai => "inline-kai",
            Self::FangSong => "inline-fang-song",
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Annotation {
    pub id: String,
    pub anchor: Anchor,
    pub style: Style,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Input {
    anchor: Anchor,
    style: Style,
}
fn digest(b: &[u8]) -> String {
    format!("{:x}", Sha256::digest(b))
}
fn hash_shape(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn error(reason: &str) -> ApiError {
    ApiError::new(ErrorCode::InvalidRule, "inline_styles", reason)
}
pub fn validate(items: &[Annotation]) -> Result<(), ApiError> {
    let mut ids = BTreeSet::new();
    for (i, a) in items.iter().enumerate() {
        let r = &a.anchor;
        if !hash_shape(&a.id)
            || !ids.insert(&a.id)
            || !hash_shape(&r.fingerprint)
            || r.start >= r.end
            || r.from > r.to
            || r.to > r.end - r.start
        {
            return Err(error("inline_style_invalid"));
        }
        if r.from == r.to {
            return Err(error("inline_style_empty"));
        }
        for b in &items[..i] {
            let q = &b.anchor;
            if r.start == q.start && r.fingerprint == q.fingerprint {
                let cross = r.from < q.from && q.from < r.to && r.to < q.to
                    || q.from < r.from && r.from < q.to && q.to < r.to;
                if cross {
                    return Err(error("inline_style_overlap"));
                }
                if r.from == q.from && r.to == q.to && a.style == b.style {
                    return Err(error("inline_style_duplicate"));
                }
                if r.from < q.to
                    && q.from < r.to
                    && matches!(a.style, Style::Kai | Style::FangSong)
                    && matches!(b.style, Style::Kai | Style::FangSong)
                    && a.style != b.style
                {
                    return Err(error("inline_style_font_conflict"));
                }
            }
        }
    }
    Ok(())
}
pub(crate) fn invalid_reason(a: &Annotation, book: &EffectiveBook) -> Option<&'static str> {
    anchor_reason(&a.anchor, book)
}
fn anchor_reason(a: &Anchor, book: &EffectiveBook) -> Option<&'static str> {
    if a.from == a.to {
        return Some("inline_style_empty");
    }
    if let Some(reason) = manual_notes::line_reason(a, book) {
        return Some(match reason {
            "note_text_changed" => "line_changed",
            "note_range_out_of_bounds" => "inline_style_range_out_of_bounds",
            "note_contains_heading" => "inline_style_contains_heading",
            _ => "inline_style_character_boundary",
        });
    }
    let line = &book.text[a.start..a.end];
    if crate::inline_markup::splits_markup(line, a.from)
        || crate::inline_markup::splits_markup(line, a.to)
    {
        return Some("inline_style_markup_boundary");
    }
    None
}
fn check_anchor(a: &Anchor, book: &EffectiveBook) -> Result<(), ApiError> {
    if let Some(reason) = anchor_reason(a, book) {
        return Err(error(reason));
    }
    Ok(())
}
fn create(book: &EffectiveBook, input: Input) -> Result<Annotation, ApiError> {
    check_anchor(&input.anchor, book)?;
    let a = Annotation {
        id: digest(
            format!(
                "{}:{:?}:{:?}",
                book.original_source_id, input.anchor, input.style
            )
            .as_bytes(),
        ),
        anchor: input.anchor,
        style: input.style,
    };
    validate(std::slice::from_ref(&a))?;
    Ok(a)
}
pub(crate) fn report(settings: &production::Settings, book: &EffectiveBook) -> Value {
    let items:Vec<_>=settings.inline_styles.iter().map(|a| {
        let reason=invalid_reason(a,book); let valid=reason.is_none();
        json!({"id":a.id,"annotation":a,"valid":valid,"reason":reason,"format_notes":a.style.format_notes(),"location":if valid {manual_notes::location(book,&a.anchor)} else {Value::Null},"text":if valid {&book.text[a.anchor.start+a.anchor.from..a.anchor.start+a.anchor.to]} else {""}})
    }).collect();
    let invalid = items.iter().filter(|a| a["valid"] == false).count();
    json!({"content_id":digest(book.text.as_bytes()),"items":items,"total":items.len(),"invalid_count":invalid})
}
/// 注释链接可切分区间，分段重复 span，不切 XHTML 标签。
pub(crate) fn render(
    text: &str,
    start: usize,
    styles: &[&Annotation],
    digits: Option<u8>,
) -> Result<String, ApiError> {
    if styles.is_empty() {
        return crate::inline_markup::render(text, digits);
    }
    let end = start + text.len();
    let mut cuts = vec![start, end];
    for a in styles {
        for at in [a.anchor.from, a.anchor.to] {
            if start < at && at < end {
                cuts.push(at);
            }
        }
    }
    cuts.sort_unstable();
    cuts.dedup();
    let mut html = String::new();
    for pair in cuts.windows(2) {
        let (from, to) = (pair[0], pair[1]);
        let active: Vec<_> = styles
            .iter()
            .filter(|a| a.anchor.from <= from && to <= a.anchor.to)
            .collect();
        for a in &active {
            html.push_str(&format!("<span class=\"{}\">", a.style.class()));
        }
        html.push_str(&crate::inline_markup::render(
            &text[from - start..to - start],
            digits,
        )?);
        for _ in &active {
            html.push_str("</span>");
        }
    }
    Ok(html)
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
    /// 跨行选择拆成的逐行条目：一次校验、一次写入、一次撤销。
    AddMany {
        inputs: Vec<Input>,
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
        serde_json::from_value(value.clone()).map_err(|_| error("inline_style_invalid"))?;
    if request.op != "inline_styles" || request.targets.len() != 1 {
        return Err(error("inline_style_invalid"));
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
        return Err(error("inline_style_stale"));
    }
    let mut next = settings.inline_styles.clone();
    let mut changed = false;
    let mut selection = Value::Null;
    let check = |id: &str| {
        if id == digest(book.text.as_bytes()) {
            Ok(())
        } else {
            Err(error("inline_style_stale"))
        }
    };
    match request.action {
        Action::List if !apply => {}
        Action::List => return Err(error("inline_style_invalid")),
        Action::Resolve {
            entry_id,
            line,
            utf16_start,
            utf16_end,
            content_id,
        } => {
            check(&content_id)?;
            if apply {
                return Err(error("inline_style_invalid"));
            }
            selection = block_annotations::line_range(&book, &entry_id, line, line)
                .map_err(|_| error("inline_style_range_out_of_bounds"))?;
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
                    Err(error("inline_style_character_boundary"))
                }
            };
            if utf16_start > utf16_end {
                return Err(error("inline_style_character_boundary"));
            }
            selection["from"] = json!(byte_at(utf16_start)?);
            selection["to"] = json!(byte_at(utf16_end)?);
            selection["fingerprint"] = json!(digest(&book.text.as_bytes()[start..end]));
            let a: Anchor = serde_json::from_value(selection.clone())
                .map_err(|_| error("inline_style_invalid"))?;
            check_anchor(&a, &book)?;
        }
        Action::Add { input, content_id } => {
            check(&content_id)?;
            next.push(create(&book, input)?);
            changed = true;
        }
        Action::AddMany { inputs, content_id } => {
            check(&content_id)?;
            if inputs.is_empty() {
                return Err(error("inline_style_empty"));
            }
            for input in inputs {
                next.push(create(&book, input)?);
            }
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
                .ok_or_else(|| error("inline_style_missing"))?;
            *old = Annotation {
                id,
                ..create(&book, input)?
            };
            changed = true;
        }
        Action::Delete { id } => {
            let i = next
                .iter()
                .position(|n| n.id == id)
                .ok_or_else(|| error("inline_style_missing"))?;
            next.remove(i);
            changed = true;
        }
        Action::Undo => target.change = production::Change::Undo {},
        Action::Redo => target.change = production::Change::Redo {},
    }
    if changed {
        next.sort_by_key(|n| (n.anchor.start, n.anchor.from));
        validate(&next)?;
        target.change = production::Change::Patch {
            fields: BTreeMap::from([(
                "inline_styles".into(),
                production::Edit::Set { value: json!(next) },
            )]),
        };
    }
    let inner = serde_json::to_string(&production::Request {
        targets: vec![target],
    })
    .map_err(|_| error("inline_style_invalid"))?;
    let mut result: Value = serde_json::from_str(&production::run(
        service,
        inner.clone(),
        false,
        String::new(),
        false,
    )?)
    .map_err(|_| error("inline_style_invalid"))?;
    let inner_id = result["plan_id"].as_str().unwrap().to_owned();
    let id = digest(format!("{value}:{inner_id}:{}", digest(book.text.as_bytes())).as_bytes());
    if apply {
        if !confirmed || plan_id != id {
            return Err(error("inline_style_stale"));
        }
        result = serde_json::from_str(&production::run(service, inner, true, inner_id, true)?)
            .map_err(|_| error("inline_style_invalid"))?;
    }
    let after = serde_json::from_value(result["items"][0]["after"].clone())
        .map_err(|_| error("inline_style_invalid"))?;
    result["plan_id"] = json!(id);
    result["inline_styles"] = report(&after, &book);
    result["inline_styles_before"] = report(&settings, &book);
    if !selection.is_null() {
        result["selection"] = selection;
    }
    Ok(result.to_string())
}

#[cfg(test)]
#[path = "inline_styles_tests.rs"]
mod tests;
