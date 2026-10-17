//! 单本书冻结的细分开关。默认不禁用任何细分，旧项目行为不变。
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Options {
    pub cleanup_pipeline: Option<Vec<Value>>,
    pub scene_symbols: Option<String>,
    pub disabled: Vec<String>,
    pub restore_values: BTreeMap<String, Value>,
}
impl Options {
    pub fn validate(&self) -> Result<(), easypub_core::ApiError> {
        let catalog = crate::rule_catalog::catalog();
        let rows = catalog["rules"].as_array().unwrap();
        if self.disabled.iter().any(|id| {
            !rows.iter().any(|r| {
                r["id"] == *id
                    && r["locked"] != true
                    && r["group"] != "chapter_recognition"
                    && r["group"] != "chapter_check"
            })
        }) || self.scene_symbols.as_ref().is_some_and(|s| {
            s.chars()
                .any(|c| !crate::publication_documents::SCENE_SYMBOLS.contains(c))
        }) {
            return Err(easypub_core::ApiError::new(
                easypub_core::ErrorCode::InvalidRule,
                "rule_options",
                "规则细分配置无效",
            ));
        }
        if let Some(p) = &self.cleanup_pipeline {
            let request = serde_json::json!({"kind":"cleanup","pipeline":p});
            let r: easypub_core::cleanup::Request =
                serde_json::from_value(request).map_err(|_| {
                    easypub_core::ApiError::new(
                        easypub_core::ErrorCode::InvalidRule,
                        "rule_options",
                        "清理配置无效",
                    )
                })?;
            r.ordered_rules()?;
        }
        Ok(())
    }
    pub fn enabled(&self, id: &str) -> bool {
        !self.disabled.iter().any(|s| s == id)
    }
    pub fn scene(&self, text: &str) -> bool {
        crate::publication_documents::is_scene_break(text)
            && self.scene_symbols.as_ref().is_none_or(|symbols| {
                text.chars()
                    .all(|c| c.is_whitespace() || symbols.contains(c))
            })
    }
    pub fn verse(
        &self,
        line: &str,
        class: Option<(&'static str, &'static str)>,
    ) -> Option<(&'static str, &'static str)> {
        let Some(("verse", css)) = class else {
            return class;
        };
        let kind = if css == "verse-by" {
            "attribution"
        } else if line
            .trim()
            .split(['，', ','])
            .next()
            .unwrap_or("")
            .chars()
            .count()
            == 5
        {
            "five"
        } else {
            "seven"
        };
        self.enabled(&format!("layout.verse.{kind}"))
            .then_some(("verse", css))
    }
    pub fn note_family(marker: &str) -> &'static str {
        if marker.contains('注') {
            "annotated"
        } else if marker.starts_with('[') {
            "bracket"
        } else if marker.starts_with('［') {
            "fullwidth"
        } else if marker.starts_with('〔') {
            "tortoise"
        } else {
            "circled"
        }
    }
    pub fn note(&self, reference: &str, definition: &str) -> bool {
        self.enabled(&format!("layout.note.{}", Self::note_family(reference)))
            && (!definition.starts_with('注') || self.enabled("layout.note.definition_prefix"))
    }
}
