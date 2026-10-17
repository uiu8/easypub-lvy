//! Cleanup presets contain only ordered rule configuration, never source coordinates.
use easypub_core::{
    ApiError, ErrorCode,
    cleanup::Request,
    cleanup_rules::{Rule, validate_pipeline},
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Preset {
    pub name: String,
    pub pipeline: Vec<Rule>,
}
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "cleanup_presets",
        "review_cleanup_preset",
    )
}
impl Preset {
    pub fn validate(&self) -> Result<(), ApiError> {
        if self.name.trim().is_empty()
            || self.name.len() > 128
            || self.name.chars().any(char::is_control)
            || serde_json::to_vec(self).map_err(|_| invalid())?.len() > 262144
        {
            return Err(invalid());
        }
        validate_pipeline(&self.pipeline)
    }
    pub fn capture(name: String, request: &Request) -> Result<Self, ApiError> {
        let preset = Self {
            name,
            pipeline: request.ordered_rules()?,
        };
        preset.validate()?;
        Ok(preset)
    }
    pub fn template(&self) -> Result<Request, ApiError> {
        self.validate()?;
        Request::apply_rules(None, &self.pipeline, false, &BTreeSet::new())
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
pub fn capture_text(name: String, request: &str) -> Result<String, ApiError> {
    if request.len() > 1048576 {
        return Err(invalid());
    }
    let request: Request = serde_json::from_str(request).map_err(|_| invalid())?;
    serde_json::to_string(&Preset::capture(name, &request)?).map_err(|_| invalid())
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn capture_omits_every_source_bound_choice_and_preserves_rule_order() {
        let request: Request = serde_json::from_value(json!({"kind":"cleanup", "pipeline":[{"kind":"trim_trailing_spaces"},{"kind":"remove_ad_lines"}],"remove_lines":[2],"skip_lines":[3],"start_line":2,"end_line":8,"protected_lines":[4],"step_exclusions":[{"step_index":0,"source_line":5}]})).unwrap();
        let preset = Preset::capture("正文清理".into(), &request).unwrap();
        let value = serde_json::to_value(&preset).unwrap();
        assert_eq!(value.as_object().unwrap().len(), 2);
        let template = serde_json::to_value(preset.template().unwrap()).unwrap();
        for key in ["remove_lines", "skip_lines"] {
            assert_eq!(template[key], json!([]));
        }
        assert!(template["start_line"].is_null());
        assert!(template["end_line"].is_null());
        assert!(template["protected_lines"].is_null() || template["protected_lines"] == json!([]));
        assert!(template["step_exclusions"].is_null() || template["step_exclusions"] == json!([]));
        assert_eq!(template["pipeline"], value["pipeline"]);
        assert!(
            serde_json::from_value::<Preset>(
                json!({"name":"bad","pipeline":[],"remove_lines":[2]})
            )
            .is_err()
        );
    }
    #[test]
    fn invalid_regex_and_duplicate_names_cannot_be_saved() {
        let p: Preset = serde_json::from_value(
            json!({"name":"bad", "pipeline":[{"kind":"regex_replace","pattern":"[","replace":""}]}),
        )
        .unwrap();
        assert!(p.validate().is_err());
        let p: Preset = serde_json::from_value(
            json!({"name":"valid", "pipeline":[{"kind":"trim_trailing_spaces"}]}),
        )
        .unwrap();
        assert!(validate(&[p.clone(), p]).is_err());
    }
}
