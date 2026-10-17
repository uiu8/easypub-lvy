//! User-authored front/back matter. Never part of the manuscript/source map.
use crate::{production, sessions::ImportService};
use easypub_core::{ApiError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Copyright,
    Dedication,
    AuthorNote,
    Afterword,
    AboutAuthor,
    Custom,
}
impl Kind {
    pub fn label(self) -> &'static str {
        match self {
            Self::Copyright => "版权页",
            Self::Dedication => "献词",
            Self::AuthorNote => "作者的话",
            Self::Afterword => "后记",
            Self::AboutAuthor => "关于作者",
            Self::Custom => "附页",
        }
    }
    pub fn default_position(self) -> Option<Position> {
        match self {
            Self::Copyright | Self::Dedication | Self::AuthorNote => Some(Position::Front),
            Self::Afterword | Self::AboutAuthor => Some(Position::Back),
            Self::Custom => None,
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Position {
    Front,
    Back,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Content {
    pub kind: Kind,
    pub position: Position,
    #[serde(default)]
    pub title: String,
    pub body: String,
    #[serde(default)]
    pub include_toc: bool,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Page {
    pub id: String,
    pub content: Content,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Template {
    pub id: String,
    pub name: String,
    pub content: Content,
}
fn error(reason: &str) -> ApiError {
    ApiError::new(ErrorCode::InvalidRule, "supplemental_pages", reason)
}
fn invalid() -> ApiError {
    error("supplemental_page_invalid")
}
fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn valid_id(id: &str) -> bool {
    id.len() == 64
        && id
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}
impl Content {
    pub fn validate(&self) -> Result<(), ApiError> {
        if self.body.chars().count() > 20_000 {
            return Err(error("supplemental_body_too_long"));
        }
        if self.title.chars().count() > 200 || self.title.contains(['\r', '\n']) {
            return Err(error("supplemental_title_too_long"));
        }
        for text in [&self.title, &self.body] {
            crate::navigation_documents::escaped(text).map_err(|_| invalid())?;
        }
        Ok(())
    }
    pub fn label(&self) -> &str {
        if self.title.trim().is_empty() {
            self.kind.label()
        } else {
            &self.title
        }
    }
}
impl Page {
    pub fn filename(&self) -> String {
        format!("matter-{}.xhtml", self.id)
    }
}
pub fn validate(pages: &[Page]) -> Result<(), ApiError> {
    if pages.len() > 20 {
        return Err(error("supplemental_page_limit"));
    }
    let mut ids = BTreeSet::new();
    for page in pages {
        if !valid_id(&page.id) || !ids.insert(&page.id) {
            return Err(invalid());
        }
        page.content.validate()?;
    }
    Ok(())
}
pub fn validate_templates(templates: &[Template]) -> Result<(), ApiError> {
    let mut ids = BTreeSet::new();
    let mut names = BTreeSet::new();
    for template in templates {
        if !valid_id(&template.id)
            || !ids.insert(&template.id)
            || template.name.trim().is_empty()
            || template.name.chars().count() > 128
            || template.name.contains(['\0', '\r', '\n'])
        {
            return Err(error("supplemental_template_invalid"));
        }
        if !names.insert(template.name.trim().to_lowercase()) {
            return Err(error("supplemental_template_duplicate"));
        }
        template.content.validate()?;
    }
    Ok(())
}

/// Substitution is a single pass over the template, never over inserted metadata.
fn substitute(text: &str, fields: &BTreeMap<&str, &str>, unknown: &mut BTreeSet<String>) -> String {
    let mut result = String::new();
    let mut rest = text;
    while let Some(start) = rest.find('{') {
        result.push_str(&rest[..start]);
        rest = &rest[start..];
        let Some(end) = rest.find('}') else { break };
        let key = &rest[1..end];
        if let Some(value) = fields.get(key) {
            result.push_str(value);
        } else {
            result.push_str(&rest[..=end]);
            unknown.insert(format!("{{{key}}}"));
        }
        rest = &rest[end + 1..];
    }
    result.push_str(rest);
    result
}
pub fn expand(
    content: &Content,
    settings: &production::Settings,
    year: u16,
) -> Result<(Content, BTreeSet<String>), ApiError> {
    if !(1..=9999).contains(&year) {
        return Err(invalid());
    }
    content.validate()?;
    let year = year.to_string();
    let fields = BTreeMap::from([
        ("书名", settings.title.as_str()),
        ("作者", settings.author.as_str()),
        ("译者", settings.translator.as_str()),
        ("年份", &year),
        ("出版社", settings.publisher.as_str()),
        ("出版日期", settings.publication_date.as_str()),
        ("ISBN", settings.isbn.as_str()),
        ("分类", settings.category.as_str()),
        ("系列", settings.series.as_str()),
        ("系列序号", settings.series_index.as_str()),
        ("主题", settings.subjects.as_str()),
        ("语言", settings.language.as_str()),
        ("简介", settings.description.as_str()),
    ]);
    let mut unknown = BTreeSet::new();
    let mut expanded = content.clone();
    expanded.title = substitute(&content.title, &fields, &mut unknown);
    expanded.body = substitute(&content.body, &fields, &mut unknown);
    expanded.validate()?;
    Ok((expanded, unknown))
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum Action {
    List,
    Add {
        content: Content,
    },
    Update {
        id: String,
        content: Content,
    },
    Delete {
        id: String,
    },
    Reorder {
        ids: Vec<String>,
    },
    /// 拖到另一组：改位置并按 `ids` 重排，一步历史（V56）。
    Move {
        id: String,
        position: Position,
        ids: Vec<String>,
    },
    ApplyTemplate {
        template: Template,
        year: u16,
    },
    Undo,
    Redo,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    op: String,
    targets: Vec<production::Target>,
    action: Action,
}
fn reordered(pages: &[Page], ids: &[String]) -> Result<Vec<Page>, ApiError> {
    if ids.len() != pages.len() || ids.iter().collect::<BTreeSet<_>>().len() != ids.len() {
        return Err(error("supplemental_order_invalid"));
    }
    ids.iter()
        .map(|id| {
            pages
                .iter()
                .find(|p| &p.id == id)
                .cloned()
                .ok_or_else(|| error("supplemental_order_invalid"))
        })
        .collect()
}
pub fn run(
    service: &ImportService,
    value: Value,
    apply: bool,
    plan_id: &str,
    confirmed: bool,
) -> Result<String, ApiError> {
    let mut request: Request = serde_json::from_value(value.clone()).map_err(|_| invalid())?;
    if request.op != "supplemental_pages" || request.targets.len() != 1 {
        return Err(invalid());
    }
    let mut target = request.targets.remove(0);
    let source = service.source(&target.history.source_id, target.history.revision)?;
    target.history.validate(source.summary().line_count)?;
    if !matches!(target.change, production::Change::Inspect {}) {
        return Err(invalid());
    }
    let settings = target.current.as_ref().unwrap_or(target.history.current());
    settings.validate(source.summary().line_count)?;
    let before = settings.supplemental_pages.clone();
    let mut next = before.clone();
    let mut unknown = BTreeSet::new();
    let id = digest(format!("{value}").as_bytes());
    let mut changed = true;
    match request.action {
        Action::List if !apply => changed = false,
        Action::List => return Err(invalid()),
        Action::Add { content } => next.push(Page { id, content }),
        Action::ApplyTemplate { template, year } => {
            validate_templates(std::slice::from_ref(&template))?;
            let (content, warnings) = expand(&template.content, settings, year)?;
            unknown = warnings;
            next.push(Page { id, content });
        }
        Action::Update { id, content } => {
            next.iter_mut()
                .find(|p| p.id == id)
                .ok_or_else(|| error("supplemental_page_missing"))?
                .content = content;
        }
        Action::Delete { id } => {
            let index = next
                .iter()
                .position(|p| p.id == id)
                .ok_or_else(|| error("supplemental_page_missing"))?;
            next.remove(index);
        }
        Action::Reorder { ids } => next = reordered(&next, &ids)?,
        Action::Move { id, position, ids } => {
            next.iter_mut()
                .find(|p| p.id == id)
                .ok_or_else(|| error("supplemental_page_missing"))?
                .content
                .position = position;
            next = reordered(&next, &ids)?;
        }
        Action::Undo => {
            changed = false;
            target.change = production::Change::Undo {};
        }
        Action::Redo => {
            changed = false;
            target.change = production::Change::Redo {};
        }
    }
    if changed {
        validate(&next)?;
        target.change = production::Change::Patch {
            fields: BTreeMap::from([(
                "supplemental_pages".into(),
                production::Edit::Set { value: json!(next) },
            )]),
        };
    }
    let inner = serde_json::to_string(&production::Request {
        targets: vec![target],
    })
    .map_err(|_| invalid())?;
    let mut result: Value = serde_json::from_str(&production::run(
        service,
        inner.clone(),
        false,
        String::new(),
        false,
    )?)
    .map_err(|_| invalid())?;
    let inner_id = result["plan_id"].as_str().ok_or_else(invalid)?.to_owned();
    let id = digest(format!("{value}:{inner_id}").as_bytes());
    if apply {
        if !confirmed || plan_id != id {
            return Err(error("supplemental_page_stale"));
        }
        result = serde_json::from_str(&production::run(service, inner, true, inner_id, true)?)
            .map_err(|_| invalid())?;
    }
    result["plan_id"] = json!(id);
    result["supplemental_pages_before"] = json!(before);
    result["supplemental_pages"] = result["items"][0]["after"]
        .get("supplemental_pages")
        .cloned()
        .unwrap_or(json!([]));
    result["warnings"] = json!(
        unknown
            .into_iter()
            .map(|placeholder| json!({
                "reason":"supplemental_unknown_placeholder", "placeholder":placeholder
            }))
            .collect::<Vec<_>>()
    );
    Ok(result.to_string())
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum TemplateAction {
    List,
    Save {
        id: Option<String>,
        name: String,
        content: Content,
    },
    Delete {
        id: String,
    },
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct TemplateRequest {
    op: String,
    templates: Vec<Template>,
    action: TemplateAction,
}
/// Pure settings edit. The caller persists the result with its captured settings token.
pub fn templates(value: Value) -> Result<String, ApiError> {
    let mut request: TemplateRequest =
        serde_json::from_value(value.clone()).map_err(|_| invalid())?;
    if request.op != "supplemental_templates" {
        return Err(invalid());
    }
    validate_templates(&request.templates)?;
    match request.action {
        TemplateAction::List => {}
        TemplateAction::Save { id, name, content } => {
            let template = Template {
                id: id
                    .clone()
                    .unwrap_or_else(|| digest(value.to_string().as_bytes())),
                name: name.trim().into(),
                content,
            };
            if let Some(id) = id {
                *request
                    .templates
                    .iter_mut()
                    .find(|t| t.id == id)
                    .ok_or_else(|| error("supplemental_template_missing"))? = template;
            } else {
                request.templates.push(template);
            }
        }
        TemplateAction::Delete { id } => {
            let index = request
                .templates
                .iter()
                .position(|t| t.id == id)
                .ok_or_else(|| error("supplemental_template_missing"))?;
            request.templates.remove(index);
        }
    }
    validate_templates(&request.templates)?;
    Ok(json!({"templates":request.templates}).to_string())
}

pub(crate) fn body(page: &Page) -> Result<String, ApiError> {
    use crate::navigation_documents::escaped;
    let content = &page.content;
    let compact = matches!(content.kind, Kind::Copyright | Kind::Dedication);
    let class = if compact {
        "supplement-page supplement-compact"
    } else {
        "supplement-page"
    };
    let mut body = format!("<div class=\"{class}\">");
    if !content.title.trim().is_empty() {
        body.push_str(&format!(
            "<h1 class=\"supplement-title\">{}</h1>",
            escaped(&content.title)?
        ));
    }
    let normalized = content.body.replace("\r\n", "\n").replace('\r', "\n");
    for line in normalized.split('\n') {
        body.push_str(&format!(
            "<p class=\"text-line\">{}</p>",
            if line.is_empty() {
                "<br/>".into()
            } else {
                escaped(line)?
            }
        ));
    }
    body.push_str("</div>");
    Ok(body)
}

#[cfg(test)]
#[path = "supplemental_pages_tests.rs"]
mod tests;
