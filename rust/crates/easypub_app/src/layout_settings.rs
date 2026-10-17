//! Resolve explicit scalar layout layers. Existing books keep a saved snapshot.
use crate::layout_presets::Preset;
use easypub_core::{ApiError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeMap;

/// Evidence of the last explicit assignment, frozen with the book. Not a live link.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Origin {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preset_name: Option<String>,
    pub source: OriginSource,
    pub value: Value,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OriginSource {
    Factory,
    Global,
    Preset,
    Book,
    RestoredDefault,
    RestoredFactory,
    RestoredGlobal,
    FolderRule,
}
pub type Origins = BTreeMap<String, Origin>;

pub fn validate_origins(origins: &Origins, settings: &Value) -> Result<(), ApiError> {
    let fields = factory();
    if origins.values().any(|origin| {
        origin.preset_name.as_ref().is_some_and(|name| {
            origin.source != OriginSource::Preset
                || name.trim().is_empty()
                || name.len() > 128
                || name.chars().any(char::is_control)
        })
    }) {
        return Err(ApiError::new(
            ErrorCode::InvalidRule,
            "layout_origins",
            "review_saved_layout_origins",
        ));
    }
    if origins.iter().any(|(key, origin)| {
        !fields.contains_key(key)
            || !settings.get(key).is_some_and(|value| {
                value == &origin.value
                    || (value.is_number()
                        && origin.value.is_number()
                        && value.as_f64() == origin.value.as_f64())
            })
    }) {
        return Err(ApiError::new(
            ErrorCode::InvalidRule,
            "layout_origins",
            "review_saved_layout_origins",
        ));
    }
    Ok(())
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Layers {
    #[serde(default)]
    pub global: BTreeMap<String, Value>,
    #[serde(default)]
    pub preset: BTreeMap<String, Value>,
    #[serde(default)]
    pub book: BTreeMap<String, Value>,
}
#[derive(Debug, Serialize)]
pub struct Resolved {
    pub values: BTreeMap<String, Value>,
    pub origins: BTreeMap<String, &'static str>,
}
pub fn factory() -> BTreeMap<String, Value> {
    serde_json::from_value(json!({
        "font_size":110.0,"font_size_unit":"%","fullwidth_indent":2,"remove_blank_lines":true,"line_height":1.2,"text_alignment":"start",
        "font_family":"Microsoft YaHei","paragraph_indent":0.0,"paragraph_spacing":0.6,
        "margin_top":0.0,"margin_right":3.0,"margin_bottom":0.0,"margin_left":3.0,
        "margin_top_unit":"px","margin_right_unit":"px","margin_bottom_unit":"px","margin_left_unit":"px",
        "include_toc":true,"visible_toc":false,"chapter_navigation":false,
        "writing_mode":"horizontal","vertical_digits":2,"heading_style":"classic",
        "scene_break_style":"keep","first_paragraph_style":"normal","chapter_head_scope":"chapter","chapter_head_width":"half","system_block_style":"box","verse_block_style":"center","note_style":"off"
    }))
    .expect("constant layout defaults")
}
impl Layers {
    pub fn resolve(&self) -> Result<Resolved, ApiError> {
        let mut values = factory();
        let mut origins = values
            .keys()
            .map(|k| (k.clone(), "factory"))
            .collect::<BTreeMap<_, _>>();
        for (name, layer) in [
            ("global", &self.global),
            ("preset", &self.preset),
            ("book", &self.book),
        ] {
            if !layer.is_empty() {
                Preset {
                    name: name.into(),
                    values: layer.clone(),
                }
                .validate()?;
            }
            // Older saved profiles expressed font_size in pixels.
            if layer.contains_key("font_size") && !layer.contains_key("font_size_unit") {
                values.insert("font_size_unit".into(), json!("px"));
                origins.insert("font_size_unit".into(), name);
            }
            for (key, value) in layer {
                values.insert(key.clone(), value.clone());
                origins.insert(key.clone(), name);
            }
        }
        for side in ["top", "right", "bottom", "left"] {
            let key = format!("margin_{side}");
            let unit = values[&format!("{key}_unit")].as_str().unwrap_or("");
            let max = if unit == "px" { 1000.0 } else { 6.0 };
            if !values[&key]
                .as_f64()
                .is_some_and(|v| (0.0..=max).contains(&v))
            {
                return Err(ApiError::new(
                    ErrorCode::InvalidRule,
                    "layout_settings",
                    "review_margin_value_and_unit",
                ));
            }
        }
        Ok(Resolved { values, origins })
    }
}
pub fn restore_fields(
    defaults: &BTreeMap<String, Value>,
    fields: &[String],
) -> Result<BTreeMap<String, crate::production::Edit>, ApiError> {
    let invalid = || {
        ApiError::new(
            ErrorCode::InvalidRule,
            "layout_settings",
            "select_default_fields",
        )
    };
    Preset {
        name: "defaults".into(),
        values: defaults.clone(),
    }
    .validate()?;
    if fields.is_empty() || fields.len() > factory().len() {
        return Err(invalid());
    }
    let mut edits = BTreeMap::new();
    for field in fields {
        let value = defaults.get(field).ok_or_else(invalid)?;
        if edits
            .insert(
                field.clone(),
                crate::production::Edit::Set {
                    value: value.clone(),
                },
            )
            .is_some()
        {
            return Err(invalid());
        }
    }
    if fields.iter().any(|f| f == "font_size") {
        edits.insert(
            "font_size_unit".into(),
            crate::production::Edit::Set {
                value: defaults
                    .get("font_size_unit")
                    .cloned()
                    .unwrap_or(json!("px")),
            },
        );
    }
    Ok(edits)
}

pub fn resolve_text(input: &str) -> Result<String, ApiError> {
    let invalid = || {
        ApiError::new(
            ErrorCode::InvalidRule,
            "layout_settings",
            "review_layout_layers",
        )
    };
    if input.len() > 32768 {
        return Err(invalid());
    }
    let layers: Layers = serde_json::from_str(input).map_err(|_| invalid())?;
    serde_json::to_string(&layers.resolve()?).map_err(|_| invalid())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn saved_origin_must_name_scalar_and_match_value_without_number_format_dependency() {
        let mut origins = Origins::new();
        origins.insert(
            "font_size".into(),
            Origin {
                preset_name: None,
                source: OriginSource::Global,
                value: json!(22),
            },
        );
        assert!(validate_origins(&origins, &json!({"font_size":22.0})).is_ok());
        assert!(validate_origins(&origins, &json!({"font_size":20.0})).is_err());
        origins.insert(
            "title".into(),
            Origin {
                preset_name: None,
                source: OriginSource::Book,
                value: json!("甲"),
            },
        );
        assert!(validate_origins(&origins, &json!({"font_size":22,"title":"甲"})).is_err());
        assert!(serde_json::from_value::<Origin>(json!({"source":"guessed","value":22})).is_err());
        assert!(validate_origins(&Origins::new(), &json!({})).is_ok());
    }
    #[test]
    fn book_wins_even_when_equal_to_factory_and_removal_restores_parent() {
        let mut layers = Layers {
            global: serde_json::from_value(json!({"font_size":22,"visible_toc":true})).unwrap(),
            preset: serde_json::from_value(json!({"font_size":20})).unwrap(),
            book: serde_json::from_value(json!({"font_size":18,"visible_toc":false})).unwrap(),
        };
        let frozen = layers.resolve().unwrap();
        assert_eq!(frozen.values["font_size"], 18);
        assert_eq!(frozen.values["visible_toc"], false);
        assert_eq!(frozen.origins["font_size"], "book");
        layers.book.remove("font_size");
        assert_eq!(layers.resolve().unwrap().values["font_size"], 20);
        layers.preset.clear();
        assert_eq!(layers.resolve().unwrap().values["font_size"], 22);
        layers.global.insert("font_size".into(), json!(24));
        assert_eq!(frozen.values["font_size"], 18);
        assert_eq!(layers.resolve().unwrap().values["font_size"], 24);
        assert_eq!(layers.resolve().unwrap().origins["line_height"], "factory");
    }
    #[test]
    fn invalid_parent_cannot_hide_behind_valid_override() {
        assert!(resolve_text(r#"{"global":{"font_size":99},"book":{"font_size":18}}"#).is_err());
        assert!(resolve_text(r#"{"global":{"title":"不能传播书名"}}"#).is_err());
        assert!(resolve_text(r#"{"book":{"visible_toc":null}}"#).is_err());
        assert!(resolve_text("{}").is_ok());
    }
}
