//! Map user intent to explicit current rules, without inheriting legacy deletion defaults.
use crate::legacy_settings::{Item, Report};
use easypub_core::cleanup_rules::Rule;
use serde_json::{Map, Value, json};

pub(crate) const KEYS: &[&str] = &[
    "RemoveInvisibleCharacters",
    "NormalizeFullWidthSpaces",
    "NormalizeChapterNumbers",
    "ChineseVariant",
    "NormalizePunctuation",
    "ApplyOcrCorrections",
    "RepairParagraphBoundaries",
    "RemoveSiteNotices",
    "RemoveRepeatedHeaders",
    "RemoveDuplicateChapterTitles",
    "RepairHardWraps",
    "CollapseBlankLines",
];

pub(crate) fn inspect(obj: &Map<String, Value>, prefix: &str, report: &mut Report) -> Vec<Rule> {
    let mut pipeline = Vec::new();
    for &key in KEYS {
        let Some(value) = obj.get(key) else {
            continue;
        };
        let mut item = Item {
            source: format!("{prefix}/{key}"),
            status: "needs_confirmation",
            reason: "类型、参数或自定义覆盖尚不能映射，未启用旧默认算法",
            target: None,
        };
        if let Some(customizations) = obj.get("BuiltinOverrides") {
            let Some(map) = customizations.as_object() else {
                report.items.push(item);
                continue;
            };
            if let Some(custom) = map.get(key) {
                let usable = custom.as_object().is_some_and(|m| {
                    m.keys()
                        .all(|k| matches!(k.as_str(), "UseDefaultAlgorithm" | "Rules"))
                }) && custom["UseDefaultAlgorithm"].is_boolean()
                    && custom["Rules"].as_array().is_some_and(Vec::is_empty);
                if !usable {
                    report.items.push(item);
                    continue;
                }
                if custom["UseDefaultAlgorithm"] == false && value.is_boolean() {
                    item.status = "cleanup_ready";
                    item.reason = "覆盖配置明确关闭默认算法，未新增默认步骤";
                    report.items.push(item);
                    continue;
                }
            }
        }
        let enabled = if key == "ChineseVariant" {
            match value.as_u64() {
                Some(0) => {
                    item.status = "cleanup_ready";
                    item.reason = "旧简繁转换关闭，未新增转换步骤";
                    report.items.push(item);
                    continue;
                }
                Some(1 | 2) => true,
                _ => {
                    report.items.push(item);
                    continue;
                }
            }
        } else if let Some(v) = value.as_bool() {
            v
        } else {
            report.items.push(item);
            continue;
        };
        let mut scope = "all";
        let rules = match key {
            "RemoveInvisibleCharacters" => vec![json!({"kind":"remove_invisible"})],
            "NormalizeFullWidthSpaces" => vec![
                json!({"kind":"literal_replace","find":"\u{a0}","replace":" "}),
                json!({"kind":"regex_replace","pattern":"^　+","replace":"　　"}),
                json!({"kind":"regex_replace","pattern":"([^　])　+","replace":"${1} "}),
                json!({"kind":"trim_trailing_spaces"}),
            ],
            "NormalizeChapterNumbers" => {
                vec![json!({"kind":"chapter_numbers","style":"chinese","bare_titles":true})]
            }
            "ChineseVariant" => vec![
                json!({"kind":"chinese_variant","direction":if value==1 {"t2s"} else {"s2t"},"dictionary_version":easypub_core::cleanup_rules::DICTIONARY_VERSION}),
            ],
            "NormalizePunctuation" => {
                scope = "body";
                vec![
                    json!({"kind":"chinese_punctuation","options":{"marks":true,"ellipsis":true,"dashes":true,"quotes":true}}),
                ]
            }
            "ApplyOcrCorrections" => {
                scope = "body";
                vec![
                    json!({"kind":"ocr_han_spaces"}),
                    json!({"kind":"ocr_ellipsis"}),
                ]
            }
            "RepairParagraphBoundaries" => {
                scope = "body";
                vec![
                    json!({"kind":"multiline_regex_replace","pattern":"([。！？!?])　{2,}","replace":"${1}\\n　　"}),
                ]
            }
            "RemoveRepeatedHeaders" => vec![
                json!({"kind":"notice_lines","options":{"include_defaults":false,"include_headers":true,"ignore_case":true,"keywords":[],"preserve_keywords":[]}}),
            ],
            "RemoveSiteNotices" => match advertisement(obj.get("Advertisement")) {
                Ok(rule) => vec![rule],
                Err(reason) => {
                    item.reason = reason;
                    report.items.push(item);
                    continue;
                }
            },
            "RemoveDuplicateChapterTitles" => vec![json!({"kind":"remove_duplicate_titles"})],
            "RepairHardWraps" => {
                let Some(min) = obj
                    .get("HardWrapMinimumLength")
                    .and_then(Value::as_u64)
                    .filter(|n| (1..=1000).contains(n))
                else {
                    report.items.push(item);
                    continue;
                };
                scope = "body";
                vec![json!({"kind":"join_hard_wraps","min_chars":min,"mode":"chinese"})]
            }
            "CollapseBlankLines" => vec![json!({"kind":"collapse_blank_lines"})],
            _ => {
                report.items.push(item);
                continue;
            }
        };
        let converted: Result<Vec<Rule>, _> = rules
            .into_iter()
            .map(|rule| {
                serde_json::from_value(
                    json!({"kind":"configured","enabled":enabled,"scope":scope,"rule":rule}),
                )
            })
            .collect();
        if let Ok(converted) = converted
            && easypub_core::cleanup_rules::validate_pipeline(&converted).is_ok() {
                pipeline.extend(converted);
                item.status = "cleanup_ready";
                item.reason = "转换为当前清理算法候选：标点/OCR/分段/硬换行限正文，页眉仅列候选不自动删除；范围与保护行为须预览";
                if key == "RemoveSiteNotices" {
                    item.reason = "广告匹配和优先保留条件整体转换；启发式使用新算法，仅列候选，逐项选择才排除，须预览核对";
                }
            }
        report.items.push(item);
    }
    pipeline
}

// Never salvage a deletion matcher after losing any preservation condition.
fn advertisement(value: Option<&Value>) -> Result<Value, &'static str> {
    const INVALID: &str = "广告配置缺少明确参数、含未知字段或条件超限，整条广告规则未迁移";
    let obj = value.and_then(Value::as_object).ok_or(INVALID)?;
    if obj.keys().any(|key| {
        !matches!(
            key.as_str(),
            "Pattern"
                | "IsRegex"
                | "PreservePattern"
                | "PreserveIsRegex"
                | "UsePromotionHeuristics"
                | "MatchKeywords"
                | "PreserveKeywords"
        )
    }) {
        return Err(INVALID);
    }
    let pattern = |name: &str, flag: &str| -> Result<Value, &'static str> {
        let text = obj.get(name).and_then(Value::as_str).ok_or(INVALID)?;
        let regex = obj.get(flag).and_then(Value::as_bool).ok_or(INVALID)?;
        if text.is_empty() {
            return Ok(Value::Null);
        }
        let text = if regex {
            crate::legacy_regex::translate(text, "", false)
                .map_err(|_| "广告匹配或保留正则不受支持，整条广告规则未迁移，未丢弃保留条件")?
                .0
        } else {
            text.to_owned()
        };
        Ok(json!({"text":text,"regex":regex}))
    };
    let words = |key: &str| -> Result<Vec<String>, &'static str> {
        obj.get(key)
            .and_then(Value::as_array)
            .ok_or(INVALID)?
            .iter()
            .map(|v| v.as_str().map(str::to_owned).ok_or(INVALID))
            .collect()
    };
    let rule = json!({"kind":"notice_lines","options":{
        "include_defaults":obj.get("UsePromotionHeuristics").and_then(Value::as_bool).ok_or(INVALID)?,
        "include_headers":false,"ignore_case":true,
        "pattern":pattern("Pattern","IsRegex")?,
        "preserve_pattern":pattern("PreservePattern","PreserveIsRegex")?,
        "keywords":words("MatchKeywords")?,"preserve_keywords":words("PreserveKeywords")?
    }});
    let parsed: Rule = serde_json::from_value(rule.clone()).map_err(|_| INVALID)?;
    easypub_core::cleanup_rules::validate_pipeline(&[parsed]).map_err(|_| INVALID)?;
    Ok(rule)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn inspect_options(options: Value) -> Report {
        crate::legacy_json::inspect(
            &json!({"LastProfile":{"Options":{"TextCleanup":options}}}).to_string(),
        )
        .unwrap()
    }
    #[test]
    fn advertisement_is_atomic_preserves_conditions_and_disabled_state() {
        let base = json!({"RemoveSiteNotices":false,"CollapseBlankLines":true,
            "Advertisement":{"Pattern":"广告","IsRegex":false,
                "PreservePattern":"^对话：","PreserveIsRegex":true,
                "UsePromotionHeuristics":false,"MatchKeywords":["推广"],
                "PreserveKeywords":["引用"]}});
        let report = inspect_options(base.clone());
        let pipeline = serde_json::to_value(&report.proposed_cleanup_presets[0].pipeline).unwrap();
        assert_eq!(pipeline[0]["enabled"], false);
        assert_eq!(
            pipeline[0]["rule"]["options"]["preserve_pattern"]["text"],
            "^对话："
        );
        assert_eq!(
            pipeline[0]["rule"]["options"]["preserve_keywords"],
            json!(["引用"])
        );
        assert!(
            report
                .items
                .iter()
                .any(|i| i.source.ends_with("/Advertisement") && i.status == "cleanup_ready")
        );
        for (key, value) in [
            ("PreservePattern", json!("(?<=广告)引用")),
            ("PreserveKeywords", json!([1])),
            ("Unknown", json!(true)),
            ("IsRegex", Value::Null),
        ] {
            let mut options = base.clone();
            options["Advertisement"][key] = value;
            let report = inspect_options(options);
            let pipeline =
                serde_json::to_value(&report.proposed_cleanup_presets[0].pipeline).unwrap();
            assert_eq!(pipeline.as_array().unwrap().len(), 1);
            assert_eq!(pipeline[0]["rule"]["kind"], "collapse_blank_lines");
            assert!(
                report
                    .items
                    .iter()
                    .any(|i| i.source.ends_with("/RemoveSiteNotices")
                        && i.status == "needs_confirmation")
            );
        }
        let mut options = base;
        options["BuiltinOverrides"] =
            json!({"RemoveSiteNotices":{"UseDefaultAlgorithm":false,"Rules":[]}});
        assert_eq!(
            inspect_options(options).proposed_cleanup_presets[0]
                .pipeline
                .len(),
            1
        );
    }
    #[test]
    fn explicit_builtin_intents_keep_order_disable_and_reject_unknown_overrides() {
        let mut options = json!({"HardWrapMinimumLength":8,"BuiltinOverrides":{}});
        for &key in KEYS {
            if key != "RemoveSiteNotices" {
                options[key] = if key == "ChineseVariant" {
                    json!(1)
                } else {
                    json!(true)
                };
            }
        }
        options["CollapseBlankLines"] = json!(false);
        let report = inspect_options(options.clone());
        let pipeline = serde_json::to_value(&report.proposed_cleanup_presets[0].pipeline).unwrap();
        assert_eq!(pipeline[0]["rule"]["kind"], "remove_invisible");
        assert_eq!(
            pipeline.as_array().unwrap().last().unwrap()["enabled"],
            false
        );
        assert!(
            pipeline
                .as_array()
                .unwrap()
                .iter()
                .any(|r| r["rule"]["direction"] == "t2s")
        );
        assert!(
            report
                .items
                .iter()
                .filter(|i| KEYS.iter().any(|key| i.source.ends_with(key)))
                .all(|i| i.status == "cleanup_ready")
        );
        options["BuiltinOverrides"] =
            json!({"RemoveInvisibleCharacters":{"UseDefaultAlgorithm":false,"Rules":[]}});
        let report = inspect_options(options);
        assert!(report.items.iter().any(
            |i| i.source.ends_with("RemoveInvisibleCharacters") && i.status == "cleanup_ready"
        ));
        assert!(
            !serde_json::to_value(&report.proposed_cleanup_presets[0].pipeline)
                .unwrap()
                .as_array()
                .unwrap()
                .iter()
                .any(|r| r["rule"]["kind"] == "remove_invisible")
        );
    }
}
