//! Portable scalar layout presets. Applying one is an explicit production edit.
use crate::production::Edit;
use easypub_core::{ApiError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Preset {
    pub name: String,
    pub values: BTreeMap<String, Value>,
}
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "layout_presets",
        "review_preset_name_and_layout_fields",
    )
}
impl Preset {
    pub fn validate(&self) -> Result<(), ApiError> {
        if self.name.trim().is_empty()
            || self.name.len() > 128
            || self.name.chars().any(char::is_control)
            || self.values.is_empty()
            || self.values.len() > crate::layout_settings::factory().len()
        {
            return Err(invalid());
        }
        for (key, value) in &self.values {
            let valid = match key.as_str() {
                "font_size" => value.as_f64().is_some_and(|v| {
                    crate::production::valid_font_size(
                        v,
                        self.values
                            .get("font_size_unit")
                            .and_then(Value::as_str)
                            .unwrap_or("px"),
                    )
                }),
                "font_size_unit" => matches!(value.as_str(), Some("px" | "%")),
                "fullwidth_indent" => value.as_u64().is_some_and(|v| v <= 8),
                "remove_blank_lines" => value.is_boolean(),
                "line_height" => value.as_f64().is_some_and(|v| (1.0..=2.3).contains(&v)),
                "paragraph_indent" | "paragraph_spacing" => {
                    value.as_f64().is_some_and(|v| (0.0..=6.0).contains(&v))
                }
                "margin_top" | "margin_right" | "margin_bottom" | "margin_left" => {
                    value.as_f64().is_some_and(|v| (0.0..=1000.0).contains(&v))
                }
                "margin_top_unit" | "margin_right_unit" | "margin_bottom_unit"
                | "margin_left_unit" => matches!(value.as_str(), Some("em" | "px")),
                "text_alignment" => matches!(
                    value.as_str(),
                    Some("start" | "left" | "right" | "center" | "justify")
                ),
                "font_family" => matches!(
                    value.as_str(),
                    Some("Microsoft YaHei" | "SimSun" | "Segoe UI")
                ),
                "include_toc" | "visible_toc" | "chapter_navigation" => value.is_boolean(),
                "writing_mode" => matches!(value.as_str(), Some("horizontal" | "vertical")),
                "vertical_digits" => value.as_u64().is_some_and(|v| v <= 4),
                "heading_style" => value
                    .as_str()
                    .is_some_and(|v| crate::production::HEADING_STYLES.contains(&v)),
                "scene_break_style" => value
                    .as_str()
                    .is_some_and(|v| crate::production::SCENE_BREAK_STYLES.contains(&v)),
                "note_style" => value
                    .as_str()
                    .is_some_and(|v| crate::production::NOTE_STYLES.contains(&v)),
                "chapter_head_scope" => value
                    .as_str()
                    .is_some_and(|v| crate::production::CHAPTER_HEAD_SCOPES.contains(&v)),
                "chapter_head_width" => value
                    .as_str()
                    .is_some_and(|v| crate::production::CHAPTER_HEAD_WIDTHS.contains(&v)),
                "first_paragraph_style" => value
                    .as_str()
                    .is_some_and(|v| crate::production::FIRST_PARAGRAPH_STYLES.contains(&v)),
                "rare_char_ruby" => value
                    .as_str()
                    .is_some_and(|v| crate::production::RARE_CHAR_RUBY_MODES.contains(&v)),
                "rare_char_scope" => value
                    .as_str()
                    .is_some_and(|v| crate::production::RARE_CHAR_SCOPES.contains(&v)),
                "system_block_style" => value
                    .as_str()
                    .is_some_and(|v| crate::production::SYSTEM_BLOCK_STYLES.contains(&v)),
                "verse_block_style" => value
                    .as_str()
                    .is_some_and(|v| crate::production::VERSE_BLOCK_STYLES.contains(&v)),
                "system_styles" => {
                    value.is_null()
                        || serde_json::from_value::<crate::block_styles::SystemStyles>(
                            value.clone(),
                        )
                        .is_ok_and(|s| s.validate().is_ok())
                }
                _ => false,
            };
            if !valid {
                return Err(invalid());
            }
        }
        Ok(())
    }
    pub fn edits(&self) -> Result<BTreeMap<String, Edit>, ApiError> {
        self.validate()?;
        let mut edits: BTreeMap<String, Edit> = self
            .values
            .iter()
            .map(|(k, v)| (k.clone(), Edit::Set { value: v.clone() }))
            .collect();
        if self.values.contains_key("font_size") && !self.values.contains_key("font_size_unit") {
            edits.insert(
                "font_size_unit".into(),
                Edit::Set {
                    value: Value::String("px".into()),
                },
            );
        }
        Ok(edits)
    }
}
pub fn validate(presets: &[Preset]) -> Result<(), ApiError> {
    if presets.len() > 64 {
        return Err(invalid());
    }
    let mut names = BTreeSet::new();
    for preset in presets {
        preset.validate()?;
        if !names.insert(preset.name.trim().to_lowercase()) {
            return Err(invalid());
        }
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn preset(name: &str, values: Value) -> Preset {
        Preset {
            name: name.into(),
            values: serde_json::from_value(values).unwrap(),
        }
    }
    #[test]
    fn portable_profiles_reject_book_identity_resources_permissions_and_wrong_types() {
        let valid = preset(
            "小说",
            json!({"font_size":20,"visible_toc":true,"text_alignment":"justify"}),
        );
        assert!(valid.validate().is_ok());
        for values in [
            json!({"title":"别的书"}),
            json!({"font_resource":null}),
            json!({"css_font_permissions":[]}),
            json!({"additional_css":"url(secret.png)"}),
            json!({"font_size":27}),
            json!({"visible_toc":"true"}),
            json!({}),
        ] {
            assert!(preset("名称", values).validate().is_err());
        }
        assert!(
            validate(&[
                preset(" Novel ", json!({"font_size":18})),
                preset("novel", json!({"font_size":20}))
            ])
            .is_err()
        );
        assert!(
            preset("坏\n名称", json!({"font_size":18}))
                .validate()
                .is_err()
        );
    }
}
