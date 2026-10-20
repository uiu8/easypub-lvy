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
    /// 场景自定义识别（V82，LAY-137）：开头、结尾（正则）与最多行数；空时不写入，旧书不变。
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub inset_rules: Vec<InsetRule>,
}

/// 一条场景识别规则：从“开头”匹配的行起，到“结尾”匹配的行止（不超过最多行数），整段标为该场景。
/// 结尾为空时只标开头这一行。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InsetRule {
    pub scene: String,
    pub start: String,
    #[serde(default)]
    pub end: String,
    pub max_lines: u16,
}

impl InsetRule {
    /// 编译开头（锚定行首）与结尾（锚定行尾）；结尾为空时为 None。
    pub fn compile(&self) -> Option<(regex::Regex, Option<regex::Regex>)> {
        let build = |p: String| {
            regex::RegexBuilder::new(&p)
                .size_limit(1 << 20)
                .build()
                .ok()
        };
        let start = build(format!("^(?:{})", self.start))?;
        let end = if self.end.is_empty() {
            None
        } else {
            Some(build(format!("(?:{})$", self.end))?)
        };
        Some((start, end))
    }
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
        if self.inset_rules.len() > 20
            || self.inset_rules.iter().any(|r| {
                !crate::insets::is_type(&r.scene)
                    || r.start.trim().is_empty()
                    || r.start.chars().count() > 200
                    || r.end.chars().count() > 200
                    || !(1..=60).contains(&r.max_lines)
                    || r.compile().is_none()
            })
        {
            return Err(easypub_core::ApiError::new(
                easypub_core::ErrorCode::InvalidRule,
                "rule_options",
                "场景识别规则无效",
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
