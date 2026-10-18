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
    /// 系统提示自定义识别（V78，LAY-134）：整行匹配的正则；空时不写入，旧书不变。
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub system_patterns: Vec<String>,
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
        if self.system_patterns.len() > 20
            || self
                .system_patterns
                .iter()
                .any(|p| p.trim().is_empty() || p.chars().count() > 200)
            || (!self.system_patterns.is_empty() && self.system_set().is_none())
        {
            return Err(easypub_core::ApiError::new(
                easypub_core::ErrorCode::InvalidRule,
                "rule_options",
                "系统提示自定义识别规则无效",
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
    /// 自定义识别规则编译成一组整行匹配；没有规则或有规则编译失败时为 None。
    pub fn system_set(&self) -> Option<regex::RegexSet> {
        if self.system_patterns.is_empty() {
            return None;
        }
        regex::RegexSetBuilder::new(self.system_patterns.iter().map(|p| format!("^(?:{p})$")))
            .size_limit(1 << 20)
            .build()
            .ok()
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
