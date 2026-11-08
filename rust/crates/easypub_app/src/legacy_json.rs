//! Legacy .NET app-settings.json uses numeric enums, unlike config.xml.
use crate::layout_presets::Preset;
use crate::legacy_settings::{Item, PresetReport, Report, invalid};
use easypub_core::ApiError;
use serde::de::{self, MapAccess, SeqAccess, Visitor};
use serde::{Deserialize, Deserializer};
use serde_json::{Map, Value, json};
use std::{collections::BTreeMap, fmt};

// serde_json::Value silently keeps the last duplicate key. Migration must not.
struct Unique(Value);
impl<'de> Deserialize<'de> for Unique {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct V;
        impl<'de> Visitor<'de> for V {
            type Value = Unique;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("unambiguous JSON")
            }
            fn visit_map<A: MapAccess<'de>>(self, mut a: A) -> Result<Unique, A::Error> {
                let mut map = Map::new();
                while let Some((k, v)) = a.next_entry::<String, Unique>()? {
                    if map.insert(k, v.0).is_some() {
                        return Err(de::Error::custom("duplicate key"));
                    }
                }
                Ok(Unique(Value::Object(map)))
            }
            fn visit_seq<A: SeqAccess<'de>>(self, mut a: A) -> Result<Unique, A::Error> {
                let mut values = Vec::new();
                while let Some(v) = a.next_element::<Unique>()? {
                    values.push(v.0);
                }
                Ok(Unique(Value::Array(values)))
            }
            fn visit_str<E: de::Error>(self, v: &str) -> Result<Unique, E> {
                Ok(Unique(json!(v)))
            }
            fn visit_bool<E: de::Error>(self, v: bool) -> Result<Unique, E> {
                Ok(Unique(json!(v)))
            }
            fn visit_i64<E: de::Error>(self, v: i64) -> Result<Unique, E> {
                Ok(Unique(json!(v)))
            }
            fn visit_u64<E: de::Error>(self, v: u64) -> Result<Unique, E> {
                Ok(Unique(json!(v)))
            }
            fn visit_f64<E: de::Error>(self, v: f64) -> Result<Unique, E> {
                Ok(Unique(json!(v)))
            }
            fn visit_unit<E: de::Error>(self) -> Result<Unique, E> {
                Ok(Unique(Value::Null))
            }
        }
        d.deserialize_any(V)
    }
}
fn item(source: String) -> Item {
    Item {
        source,
        status: "unsupported",
        reason: "此旧参数尚无迁移映射，未导入",
        target: None,
    }
}
fn candidate(report: &mut Report, mut entry: Item, target: &str, value: Option<Value>) {
    if let Some(value) = value {
        let values = BTreeMap::from([(target.into(), value.clone())]);
        if (Preset {
            name: "migration".into(),
            values,
        })
        .validate()
        .is_ok()
        {
            report.proposed_layout.insert(target.into(), value);
            entry.status = "ready";
            entry.reason = "语义可对应，等待明确选择应用范围";
            entry.target = Some(target.into());
            report.items.push(entry);
            return;
        }
    }
    entry.status = "needs_confirmation";
    entry.reason = "类型、枚举或数值不受支持，未回退或截断";
    report.items.push(entry);
}
fn profile(value: &Value, prefix: &str) -> Result<Report, ApiError> {
    let obj = value.as_object().ok_or_else(invalid)?;
    let options = obj
        .get("Options")
        .and_then(Value::as_object)
        .ok_or_else(invalid)?;
    let mut report = Report {
        proposed_recognition: None,
        proposed_recognition_presets: Vec::new(),
        format: "easypub_app_settings_json",
        proposed_layout: BTreeMap::new(),
        items: Vec::new(),
        proposed_presets: Vec::new(),
        proposed_cleanup_presets: Vec::new(),
    };
    for key in obj.keys().filter(|k| *k != "Options") {
        report.items.push(item(format!("{prefix}/{key}")));
    }
    report.proposed_recognition = recognition_profile(options, &mut report.items, prefix);
    for (key, value) in options {
        let mut entry = item(format!("{prefix}/Options/{key}"));
        match key.as_str() {
            "ParagraphIndentEm" => {
                candidate(&mut report, entry, "paragraph_indent", Some(value.clone()))
            }
            "ParagraphSpacingEm" => {
                candidate(&mut report, entry, "paragraph_spacing", Some(value.clone()))
            }
            "LineHeightPercent" => candidate(
                &mut report,
                entry,
                "line_height",
                value.as_i64().map(|v| json!(v as f64 / 100.0)),
            ),
            "TextAlignment" => candidate(
                &mut report,
                entry,
                "text_alignment",
                match value.as_u64() {
                    Some(0) => Some(json!("start")),
                    Some(1) => Some(json!("justify")),
                    Some(2) => Some(json!("left")),
                    Some(3) => Some(json!("center")),
                    Some(4) => Some(json!("right")),
                    _ => None,
                },
            ),
            "TocHierarchy" => {
                let toc = value.as_object().ok_or_else(invalid)?;
                for (name, v) in toc {
                    let sub = item(format!("{prefix}/Options/TocHierarchy/{name}"));
                    match name.as_str() {
                        "IncludeHtmlTocPage" => {
                            candidate(&mut report, sub, "visible_toc", Some(v.clone()))
                        }
                        "IncludeChapterTopNavigation" => {
                            candidate(&mut report, sub, "chapter_navigation", Some(v.clone()))
                        }
                        "Enabled"
                        | "Level1Pattern"
                        | "Level2Pattern"
                        | "Level3Pattern"
                        | "RecognizeNumericHeadings"
                        | "NumericHeadingMinimumBodyLines"
                        | "NumericHeadingPattern"
                        | "HeadingNumberCorrections" => {}
                        _ => report.items.push(sub),
                    }
                }
            }
            "FontSizePercent" => {
                entry.status = "needs_confirmation";
                entry.reason = "旧字号为百分比，需要明确逻辑字号基准，未静默换算";
                report.items.push(entry);
            }
            "PageMarginTopPx" | "PageMarginBottomPx" | "PageMarginLeftPx" | "PageMarginRightPx" => {
                let target = match key.as_str() {
                    "PageMarginTopPx" => "margin_top",
                    "PageMarginRightPx" => "margin_right",
                    "PageMarginBottomPx" => "margin_bottom",
                    _ => "margin_left",
                };
                candidate(
                    &mut report,
                    entry,
                    target,
                    value
                        .as_f64()
                        .filter(|v| (0.0..=1000.0).contains(v))
                        .map(|v| json!(v)),
                );
                if report.proposed_layout.contains_key(target) {
                    report
                        .proposed_layout
                        .insert(format!("{target}_unit"), json!("px"));
                }
            }
            "AdditionalCss" | "CoverImagePath" | "Illustrations" | "Metadata" => {
                entry.status = "needs_confirmation";
                entry.reason =
                    "旧资源/元数据只读记录，需逐项确认来源路径、存在性和书籍范围，不自动复制";
                report.items.push(entry);
            }
            "TextCleanup" => cleanup(&mut report, value, &format!("{prefix}/Options/TextCleanup"))?,
            "ChapterPattern" => {}
            "RemoveBlankLines" | "AddFullWidthIndent" | "FullWidthIndentCount" => {
                entry.status = "needs_confirmation";
                entry.reason = "影响正文或识别，需独立迁移及预览，未自动启用";
                report.items.push(entry);
            }
            _ => report.items.push(entry),
        }
    }
    Ok(report)
}

fn recognition_profile(
    options: &Map<String, Value>,
    items: &mut Vec<Item>,
    prefix: &str,
) -> Option<easypub_core::chapter_rules::RuleSet> {
    let mut values = serde_json::to_value(easypub_core::chapter_rules::RuleSet::default())
        .ok()?
        .as_object()?
        .clone();
    values.insert("origin".into(), json!("import_default"));
    let mut sources = Vec::new();
    if let Some(value) = options.get("ChapterPattern") {
        values.insert(
            "chapter_pattern".into(),
            value
                .as_str()
                .map(|s| json!(legacy_pattern(s)))
                .unwrap_or_else(|| value.clone()),
        );
        sources.push(format!("{prefix}/Options/ChapterPattern"));
    }
    if let Some(toc) = options.get("TocHierarchy").and_then(Value::as_object) {
        for (old, new) in [
            ("Enabled", "hierarchy"),
            ("Level1Pattern", "volume_pattern"),
            ("Level2Pattern", "level_chapter_pattern"),
            ("Level3Pattern", "section_pattern"),
            ("RecognizeNumericHeadings", "numeric"),
            ("NumericHeadingPattern", "numeric_pattern"),
            (
                "NumericHeadingMinimumBodyLines",
                "numeric_minimum_body_lines",
            ),
            ("HeadingNumberCorrections", "number_corrections"),
        ] {
            if let Some(value) = toc.get(old) {
                let value = if new.ends_with("pattern") && new != "numeric_pattern" {
                    value
                        .as_str()
                        .map(|s| json!(legacy_pattern(s)))
                        .unwrap_or_else(|| value.clone())
                } else {
                    value.clone()
                };
                values.insert(new.into(), value);
                sources.push(format!("{prefix}/Options/TocHierarchy/{old}"));
            }
        }
    }
    if sources.is_empty() {
        return None;
    }
    let candidate =
        serde_json::from_value::<easypub_core::chapter_rules::RuleSet>(Value::Object(values))
            .ok()
            .filter(|r| r.compile().is_ok());
    for source in sources {
        items.push(Item {
            source,
            status: if candidate.is_some() {
                "recognition_ready"
            } else {
                "unsupported"
            },
            reason: if candidate.is_some() {
                "可迁移识别规则；已知旧内置规则升级为校正后的内置规则，已有书不重建"
            } else {
                "这组识别规则含不兼容语法、类型或错字表；整组未启用，不回退默认"
            },
            target: Some("recognition_defaults".into()),
        });
    }
    candidate
}
pub(crate) fn legacy_pattern(pattern: &str) -> String {
    let numerals = "0-9０-９零〇一二两兩三四五六七八九十百千万萬壹贰貳叁參肆伍陆陸柒捌玖拾佰仟";
    let start = r"^\s*[【\[（(]?\s*";
    let number = format!(r"(?:第\s*)?[{numerals}]+\s*");
    let special =
        r"(?:序章|序言|前言|后记|後記|尾声|尾聲|终章|終章|番外(?:篇)?)(?:$|[\s:：、（(【\[]).*";
    let marker = r"(?:章|回(?!头|頭|到|来|來|去|事|答|忆|憶))";
    let known = [
        r"^\s*[第卷][0123456789一二三四五六七八九十零〇百千两]*[章回部节集卷].*".to_owned(),
        r"^\s*第[0123456789一二三四五六七八九十零〇百千两]+[卷部篇集].*".into(),
        r"^\s*第[0123456789一二三四五六七八九十零〇百千两]+[章回].*".into(),
        r"^\s*第[0123456789一二三四五六七八九十零〇百千两]+节.*".into(),
        format!(r"{start}(?:{number}{marker}.*|第\s*[{numerals}]+\s*[卷部篇集节].*|{special})"),
        format!(r"{start}{number}[卷部篇集].*"),
        format!(r"{start}(?:{number}{marker}.*|{special})"),
        format!(r"{start}{number}节.*"),
    ];
    if known.iter().any(|v| v == pattern) {
        String::new()
    } else {
        pattern.into()
    }
}

fn cleanup(report: &mut Report, value: &Value, prefix: &str) -> Result<(), ApiError> {
    let obj = value.as_object().ok_or_else(invalid)?;
    let mut normalized = obj.clone();
    let mut rules: Vec<(Value, String)> = match obj.get("CustomRules") {
        Some(value) => value
            .as_array()
            .ok_or_else(invalid)?
            .iter()
            .enumerate()
            .map(|(i, r)| (r.clone(), format!("{prefix}/CustomRules/{i}")))
            .collect(),
        None => Vec::new(),
    };
    let mut overrides_valid = true;
    let mut has_overrides = false;
    if let Some(value) = obj.get("BuiltinOverrides") {
        if let Some(overrides) = value.as_object() {
            has_overrides = !overrides.is_empty();
            for (key, value) in overrides {
                let valid = key != "ChineseVariant"
                    && crate::legacy_cleanup_builtins::KEYS.contains(&key.as_str())
                    && obj.get(key).is_some_and(Value::is_boolean)
                    && value.as_object().is_some_and(|m| {
                        m.keys()
                            .all(|k| matches!(k.as_str(), "UseDefaultAlgorithm" | "Rules"))
                    })
                    && value["UseDefaultAlgorithm"].is_boolean()
                    && value["Rules"].is_array();
                if !valid {
                    overrides_valid = false;
                    continue;
                }
                let parent_enabled = obj[key] == true;
                for (i, rule) in value["Rules"].as_array().unwrap().iter().enumerate() {
                    let mut rule = rule.clone();
                    if rule.get("Enabled").is_some_and(Value::is_boolean) {
                        rule["Enabled"] = json!(parent_enabled && rule["Enabled"] == true);
                    }
                    rules.push((rule, format!("{prefix}/BuiltinOverrides/{key}/Rules/{i}")));
                }
                normalized["BuiltinOverrides"][key]["Rules"] = json!([]);
            }
        } else {
            overrides_valid = false;
            has_overrides = true;
        }
    }
    if rules.len() > 32 {
        return Err(invalid());
    }
    let mut builtin_pipeline = crate::legacy_cleanup_builtins::inspect(&normalized, prefix, report);
    for key in obj.keys().filter(|k| {
        *k != "CustomRules" && !crate::legacy_cleanup_builtins::KEYS.contains(&k.as_str())
    }) {
        let mut entry = item(format!("{prefix}/{key}"));
        entry.status = "needs_confirmation";
        entry.reason = "内置算法、广告、排除坐标等需分别核对；本次清理预设不包含此项";
        if key == "BuiltinOverrides" && obj[key].as_object().is_some_and(serde_json::Map::is_empty)
        {
            continue;
        }
        if key == "HardWrapMinimumLength"
            && report.items.iter().any(|i| {
                i.source == format!("{prefix}/RepairHardWraps") && i.status == "cleanup_ready"
            })
        {
            entry.status = "cleanup_ready";
            entry.reason = "已作为硬换行步骤的最小长度参数保留";
        }
        if key == "Advertisement"
            && report.items.iter().any(|i| {
                i.source == format!("{prefix}/RemoveSiteNotices") && i.status == "cleanup_ready"
            })
        {
            entry.status = "cleanup_ready";
            entry.reason = "广告匹配、关键词及优先保留条件已整体纳入候选步骤，不自动删除";
        }
        report.items.push(entry);
    }
    // Legacy ties are sorted using the current culture, so never guess tie order.
    let mut orders = std::collections::BTreeSet::new();
    let ordering_known = rules.iter().all(|(r, _)| {
        r.get("Order")
            .and_then(Value::as_i64)
            .is_some_and(|v| orders.insert(v))
    });
    let mut converted = Vec::new();
    for (rule, source) in &rules {
        let mut entry = item(source.clone());
        entry.status = "needs_confirmation";
        let Some(obj) = rule.as_object() else {
            entry.reason = "清理规则类型错误，未转换";
            report.items.push(entry);
            continue;
        };
        entry.reason =
            "未转换：需明确唯一顺序、启停与范围；正则、跨行、忽略大小写或未知字段需另行核对";
        let known = obj.keys().all(|k| {
            matches!(
                k.as_str(),
                "Id" | "Name"
                    | "Pattern"
                    | "Replacement"
                    | "IsRegex"
                    | "Scope"
                    | "IgnoreCase"
                    | "Multiline"
                    | "Order"
                    | "Enabled"
            )
        });
        let scope = match rule["Scope"].as_u64() {
            Some(0) => Some("all"),
            Some(1) => Some("body"),
            Some(2) => Some("headings"),
            _ => None,
        };
        if known && ordering_known && rule["Multiline"].is_boolean()
            && let (Some(scope), Some(enabled), Some(find), Some(replace)) = (
                scope,
                rule["Enabled"].as_bool(),
                rule["Pattern"].as_str(),
                rule["Replacement"].as_str(),
            ) {
                if find.is_empty() {
                    entry.reason = "旧规则匹配内容为空，未转换为可匹配空串的正则";
                    report.items.push(entry);
                    continue;
                }
                let multiline = rule["Multiline"] == true;
                let inner = if !multiline && rule["IsRegex"] == false && rule["IgnoreCase"] == false
                {
                    Some(json!({"kind":"literal_replace","find":find,"replace":replace}))
                } else if rule["IsRegex"].is_boolean() {
                    if let Some(ignore_case) = rule["IgnoreCase"].as_bool() {
                        let translated = if rule["IsRegex"] == true {
                            crate::legacy_regex::translate(find, replace, ignore_case)
                        } else {
                            let pattern = regex::escape(find);
                            Ok((
                                if ignore_case {
                                    format!("(?i:{pattern})")
                                } else {
                                    pattern
                                },
                                replace.replace('$', "$$"),
                            ))
                        };
                        match translated {
                            Ok((pattern, replace)) => {
                                // Legacy multiline regex used both m and s. Keep source line
                                // endings and explicit scope, instead of its global LF rewrite.
                                let pattern = if multiline {
                                    format!("(?ms:{pattern})")
                                } else {
                                    pattern
                                };
                                let replace = if multiline {
                                    replace.replace('\\', "\\\\")
                                } else {
                                    replace
                                };
                                Some(
                                    json!({"kind":if multiline {"multiline_regex_replace"} else {"regex_replace"},"pattern":pattern,"replace":replace}),
                                )
                            }
                            Err(reason) => {
                                entry.reason = reason;
                                None
                            }
                        }
                    } else {
                        None
                    }
                } else {
                    None
                };
                let Some(inner) = inner else {
                    report.items.push(entry);
                    continue;
                };
                let candidate =
                    json!({"kind":"configured", "enabled":enabled, "scope":scope, "rule":inner});
                if let Ok(rule) =
                    serde_json::from_value::<easypub_core::cleanup_rules::Rule>(candidate)
                    && easypub_core::cleanup_rules::validate_pipeline(std::slice::from_ref(&rule))
                        .is_ok()
                    {
                        converted.push((obj["Order"].as_i64().unwrap(), rule));
                        entry.status = "cleanup_ready";
                        entry.reason = "逐行替换候选；保留顺序、范围与启停，捕获引用已转换；应用前须核对新识别与 Unicode 匹配结果";
                        if multiline {
                            entry.reason = "跨行候选：保留明确范围和原稿换行，不继承旧忽略范围及全篇转 LF 的行为；正则启用跨行锚点及点号跨行，替换引用/反斜杠已转换，须核对预览";
                        }
                    }
            }
        report.items.push(entry);
    }
    if has_overrides && (!overrides_valid || converted.len() != rules.len()) {
        for entry in report.items.iter_mut().filter(|i| {
            i.source.starts_with(&format!("{prefix}/"))
                && (i.status == "cleanup_ready" || i.source.ends_with("/BuiltinOverrides"))
        }) {
            entry.status = "needs_confirmation";
            entry.reason = "自定义覆盖存在未知条件、不可转换规则或联合顺序冲突，未生成清理预设，避免只迁移部分覆盖行为";
        }
        return Ok(());
    }
    if has_overrides
        && let Some(entry) = report
            .items
            .iter_mut()
            .find(|i| i.source == format!("{prefix}/BuiltinOverrides"))
        {
            entry.status = "cleanup_ready";
            entry.reason = "覆盖与普通自定义规则按唯一 Order 联合排序；父开关关闭则子规则停用，关闭的默认算法不恢复";
        }
    converted.sort_by_key(|(order, _)| *order);
    builtin_pipeline.extend(converted.into_iter().map(|(_, rule)| rule));
    if builtin_pipeline.len() > 32 {
        for item in report
            .items
            .iter_mut()
            .filter(|i| i.source.starts_with(prefix) && i.status == "cleanup_ready")
        {
            item.status = "needs_confirmation";
            item.reason = "组合超过 32 步，未生成清理预设；请精简或拆分旧规则后再迁移";
        }
        return Ok(());
    }
    if !builtin_pipeline.is_empty() {
        let preset = crate::cleanup_presets::Preset {
            name: "旧设置清理".into(),
            pipeline: builtin_pipeline,
        };
        preset.validate()?;
        report.proposed_cleanup_presets.push(preset);
    }
    Ok(())
}
pub(crate) fn inspect(text: &str) -> Result<Report, ApiError> {
    if text.len() > 1024 * 1024 {
        return Err(invalid());
    }
    let root = serde_json::from_str::<Unique>(text)
        .map_err(|_| invalid())?
        .0;
    let obj = root.as_object().ok_or_else(invalid)?;
    let mut report = profile(obj.get("LastProfile").ok_or_else(invalid)?, "LastProfile")?;
    if let Some(defaults) = obj.get("NumericHeadingDefaults").and_then(Value::as_object) {
        let mut options = Map::new();
        options.insert("TocHierarchy".into(), Value::Object(defaults.clone()));
        if let Some(numeric) =
            recognition_profile(&options, &mut report.items, "NumericHeadingDefaults")
        {
            let invalid_base = report.items.iter().any(|item| {
                item.source.starts_with("LastProfile/")
                    && item.target.as_deref() == Some("recognition_defaults")
                    && item.status == "unsupported"
            });
            if !invalid_base {
                let target = report
                    .proposed_recognition
                    .get_or_insert_with(Default::default);
                target.numeric = numeric.numeric;
                target.numeric_pattern = numeric.numeric_pattern;
                target.numeric_minimum_body_lines = numeric.numeric_minimum_body_lines;
                target.number_corrections = numeric.number_corrections;
            }
        }
    }
    if let Some(presets) = obj.get("NumericHeadingPresets").and_then(Value::as_array) {
        for (i, preset) in presets.iter().enumerate() {
            let name = preset["Name"].as_str().unwrap_or("");
            let mut fields =
                serde_json::to_value(easypub_core::chapter_rules::RuleSet::default()).unwrap();
            fields["origin"] = json!("preset");
            for (old, new) in [
                ("Enabled", "numeric"),
                ("Pattern", "numeric_pattern"),
                ("MinimumBodyLines", "numeric_minimum_body_lines"),
                ("HeadingNumberCorrections", "number_corrections"),
            ] {
                if let Some(value) = preset.get(old) {
                    fields[new] = value.clone();
                }
            }
            let rules = serde_json::from_value::<easypub_core::chapter_rules::RuleSet>(fields)
                .ok()
                .filter(|r| r.compile().is_ok());
            let valid = !name.trim().is_empty() && name.len() <= 256 && rules.is_some();
            report.items.push(Item {
                source: format!("NumericHeadingPresets/{i}"),
                status: if valid {
                    "recognition_ready"
                } else {
                    "unsupported"
                },
                reason: if valid {
                    "数字规则可迁移为命名预设"
                } else {
                    "表达式或错字表不兼容，保留旧配置并人工调整"
                },
                target: Some("recognition_presets".into()),
            });
            if valid {
                report
                    .proposed_recognition_presets
                    .push(easypub_core::chapter_rules::Preset {
                        name: name.into(),
                        rules: rules.unwrap(),
                    });
            }
        }
    }
    for key in obj.keys().filter(|k| {
        !matches!(
            k.as_str(),
            "LastProfile" | "Presets" | "NumericHeadingDefaults" | "NumericHeadingPresets"
        )
    }) {
        report.items.push(item(key.clone()));
    }
    if let Some(presets) = obj.get("Presets") {
        let presets = presets.as_array().ok_or_else(invalid)?;
        if presets.len() > 64 {
            return Err(invalid());
        }
        let mut names = std::collections::BTreeSet::new();
        for (i, preset) in presets.iter().enumerate() {
            let name = preset
                .get("Name")
                .and_then(Value::as_str)
                .ok_or_else(invalid)?;
            if name.trim().is_empty()
                || name.len() > 128
                || name.chars().any(char::is_control)
                || !names.insert(name.trim().to_lowercase())
            {
                return Err(invalid());
            }
            let mut converted = profile(
                preset.get("Profile").ok_or_else(invalid)?,
                &format!("Presets/{i}/Profile"),
            )?;
            for key in preset
                .as_object()
                .ok_or_else(invalid)?
                .keys()
                .filter(|k| !matches!(k.as_str(), "Name" | "Profile"))
            {
                converted.items.push(item(format!("Presets/{i}/{key}")));
            }
            report.proposed_presets.push(PresetReport {
                name: name.into(),
                values: converted.proposed_layout,
                items: converted.items,
            });
            if let Some(rules) = converted.proposed_recognition {
                report
                    .proposed_recognition_presets
                    .push(easypub_core::chapter_rules::Preset {
                        name: name.into(),
                        rules,
                    });
            }
            for mut p in converted.proposed_cleanup_presets {
                p.name = name.to_owned();
                report.proposed_cleanup_presets.push(p);
            }
        }
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn chapter_rules_migrate_supported_groups_without_silent_default_fallback() {
        let options = json!({"ChapterPattern":r"^第(?<number>\d+)话\s+(?<title>.+)$", "TocHierarchy":{"Enabled":false,"HeadingNumberCorrections":"久=九","NumericHeadingMinimumBodyLines":5}});
        let report=inspect(&json!({"LastProfile":{"Options":options},"NumericHeadingPresets":[{"Name":"数字","Enabled":true,"Pattern":"","MinimumBodyLines":5}]}).to_string()).unwrap();
        let rule = report.proposed_recognition.unwrap();
        assert_eq!(
            rule.compile()
                .unwrap()
                .matched("第12话 起点")
                .unwrap()
                .number,
            Some(12)
        );
        assert_eq!(report.proposed_recognition_presets.len(), 1);
        for bad in [json!(42), json!(r"^第(?=\d)\d+章")] {
            let report=inspect(&json!({"LastProfile":{"Options":{"ChapterPattern":bad}},"NumericHeadingDefaults":{"RecognizeNumericHeadings":true,"NumericHeadingMinimumBodyLines":5},"NumericHeadingPresets":[{"Name":"坏类型","MinimumBodyLines":"五"}]}).to_string()).unwrap();
            assert!(report.proposed_recognition.is_none());
            assert!(report.proposed_recognition_presets.is_empty());
            assert!(
                report
                    .items
                    .iter()
                    .any(|i| i.source == "LastProfile/Options/ChapterPattern"
                        && i.status == "unsupported")
            );
        }
        let old = r"^\s*[第卷][0123456789一二三四五六七八九十零〇百千两]*[章回部节集卷].*";
        let report =
            inspect(&json!({"LastProfile":{"Options":{"ChapterPattern":old}}}).to_string())
                .unwrap();
        assert!(
            !report
                .proposed_recognition
                .unwrap()
                .compile()
                .unwrap()
                .matched("两章合一章，更比两章强！")
                .is_some()
        );
    }
    #[test]
    fn overrides_share_order_and_preserve_parent_disablement_or_refuse_partial_migration() {
        let rule = |order, from, to| {
            json!({"Order":order,"Pattern":from,"Replacement":to,
            "Enabled":true,"Scope":1,"IsRegex":false,"IgnoreCase":false,"Multiline":false})
        };
        let base = json!({"RemoveInvisibleCharacters":true,"CollapseBlankLines":false,
            "BuiltinOverrides":{
                "RemoveInvisibleCharacters":{"UseDefaultAlgorithm":false,"Rules":[rule(1,"甲","乙")]},
                "CollapseBlankLines":{"UseDefaultAlgorithm":true,"Rules":[rule(3,"丙","丁")]}
            },"CustomRules":[rule(2,"乙","丙")]});
        let read = |options| {
            inspect(
                &json!({"LastProfile":{"Options":{"TextAlignment":3,"TextCleanup":options}}})
                    .to_string(),
            )
            .unwrap()
        };
        let report = read(base.clone());
        let p = serde_json::to_value(&report.proposed_cleanup_presets[0].pipeline).unwrap();
        assert_eq!(p.as_array().unwrap().len(), 4);
        assert_eq!(p[0]["rule"]["kind"], "collapse_blank_lines");
        assert_eq!(p[0]["enabled"], false);
        assert_eq!(p[1]["rule"]["find"], "甲");
        assert_eq!(p[2]["rule"]["find"], "乙");
        assert_eq!(p[3]["enabled"], false);
        for problem in ["order", "invalid", "unknown", "parent"] {
            let mut options = base.clone();
            match problem {
                "order" => options["CustomRules"][0]["Order"] = json!(1),
                "invalid" => {
                    options["BuiltinOverrides"]["RemoveInvisibleCharacters"]["Rules"][0] = json!(1)
                }
                "unknown" => {
                    options["BuiltinOverrides"]["RemoveInvisibleCharacters"]["Extra"] = json!(true)
                }
                _ => {
                    options
                        .as_object_mut()
                        .unwrap()
                        .remove("RemoveInvisibleCharacters");
                }
            }
            let report = read(options);
            assert!(report.proposed_cleanup_presets.is_empty(), "{problem}");
            assert_eq!(report.proposed_layout["text_alignment"], "center");
            assert!(
                report
                    .items
                    .iter()
                    .any(|i| i.reason.contains("未生成清理预设"))
            );
        }
    }
    #[test]
    fn oversized_migrated_pipeline_has_explicit_report_without_losing_layout() {
        let rules: Vec<_> = (0..32).map(|i| json!({"Order":i,"Scope":0,"Enabled":true,"IsRegex":false,"IgnoreCase":false,"Multiline":false,"Pattern":"甲","Replacement":"乙"})).collect();
        let report = inspect(&json!({"LastProfile":{"Options":{"TextAlignment":3,"TextCleanup":{"CollapseBlankLines":true,"CustomRules":rules}}}}).to_string()).unwrap();
        assert_eq!(report.proposed_layout["text_alignment"], "center");
        assert!(report.proposed_cleanup_presets.is_empty());
        assert_eq!(
            report
                .items
                .iter()
                .filter(|i| i.reason.contains("32 步"))
                .count(),
            33
        );
    }
    #[test]
    fn custom_literal_cleanup_preserves_order_scope_and_disabled_rules_without_coordinates() {
        let rule = |order, scope, enabled| json!({"Name":"替换", "Pattern":"甲", "Replacement":"乙", "IsRegex":false,"IgnoreCase":false,"Multiline":false,"Enabled":enabled,"Scope":scope,"Order":order});
        let inspect_rules = |rules| {
            inspect(&json!({"LastProfile":{"Options":{"TextCleanup":{"CustomRules":rules,"ExcludedChangeKeys":["private-location"]}}}}).to_string()).unwrap()
        };
        let report = inspect_rules(json!([rule(2, 0, true), rule(1, 1, false)]));
        let p = &report.proposed_cleanup_presets[0];
        let pipeline = serde_json::to_value(&p.pipeline).unwrap();
        assert_eq!(pipeline[0]["enabled"], false);
        assert_eq!(pipeline[0]["scope"], "body");
        assert_eq!(pipeline[1]["scope"], "all");
        assert!(
            !serde_json::to_string(&report)
                .unwrap()
                .contains("private-location")
        );
        assert!(
            inspect_rules(json!([rule(1, 0, true), rule(1, 1, true)]))
                .proposed_cleanup_presets
                .is_empty()
        );
        for key in ["IgnoreCase", "Multiline", "Unknown"] {
            let mut r = rule(1, 0, true);
            r[key] = json!("invalid");
            assert!(
                inspect_rules(json!([r]))
                    .proposed_cleanup_presets
                    .is_empty()
            );
        }
    }
    #[test]
    fn multiline_migration_preserves_scope_flags_and_literal_replacement_bytes() {
        for regex in [true, false] {
            let report = inspect(
                &json!({"LastProfile":{"Options":{"TextCleanup":{"CustomRules":[{
                    "Pattern":if regex {"(?<first>甲).+乙"} else {"甲\n乙"},
                    "Replacement":"${first}\\n\n$", "IsRegex":regex,"IgnoreCase":true,
                    "Multiline":true,"Enabled":false,"Scope":1,"Order":0
                }]}}}})
                .to_string(),
            )
            .unwrap();
            let pipeline =
                serde_json::to_value(&report.proposed_cleanup_presets[0].pipeline).unwrap();
            assert_eq!(pipeline[0]["enabled"], false);
            assert_eq!(pipeline[0]["scope"], "body");
            assert_eq!(pipeline[0]["rule"]["kind"], "multiline_regex_replace");
            assert!(
                pipeline[0]["rule"]["pattern"]
                    .as_str()
                    .unwrap()
                    .starts_with("(?ms:(?i:")
            );
            assert_eq!(
                pipeline[0]["rule"]["replace"],
                if regex {
                    "${1}\\\\n\n$$"
                } else {
                    "$${first}\\\\n\n$$"
                }
            );
            assert!(
                report
                    .items
                    .iter()
                    .any(|i| i.reason.contains("保留明确范围和原稿换行"))
            );
        }
    }
    #[test]
    fn json_enums_are_not_xml_enums_and_explicit_false_survives() {
        let report = inspect(&json!({"LastProfile":{"Options":{"TextAlignment":3,"TocHierarchy":{"IncludeHtmlTocPage":false}}},
            "Presets":[{"Name":"自选", "Profile":{"Options":{"TextAlignment":4,"ParagraphIndentEm":0}}}]}).to_string()).unwrap();
        assert_eq!(report.proposed_layout["text_alignment"], json!("center"));
        assert_eq!(report.proposed_layout["visible_toc"], json!(false));
        assert_eq!(
            report.proposed_presets[0].values["text_alignment"],
            json!("right")
        );
        assert_eq!(
            report.proposed_presets[0].values["paragraph_indent"],
            json!(0)
        );
    }
    #[test]
    fn resource_and_metadata_fields_never_become_silent_layout_defaults() {
        let report = inspect(r#"{"LastProfile":{"Options":{"AdditionalCss":"p{}","CoverImagePath":"cover.png","Illustrations":[],"Metadata":{"Title":"x"}}},"Presets":[]}"#).unwrap();
        let items = report
            .items
            .iter()
            .filter(|i| i.source.contains("Options/"))
            .collect::<Vec<_>>();
        assert_eq!(items.len(), 4);
        assert!(items.iter().all(|i| i.status == "needs_confirmation"));
        assert!(report.proposed_layout.is_empty());
    }

    #[test]
    fn preserves_unknowns_without_values_and_rejects_ambiguous_json() {
        let report = inspect(r#"{"LastProfile":{"Options":{"FontSizePercent":110,"LineHeightPercent":99,"TextAlignment":"3","AdditionalCss":"private-value"}},"Presets":[]}"#).unwrap();
        assert!(report.proposed_layout.is_empty());
        assert_eq!(report.items.len(), 4);
        assert!(
            !serde_json::to_string(&report)
                .unwrap()
                .contains("private-value")
        );
        for invalid in [
            r#"{"LastProfile":{"Options":{"TextAlignment":3,"TextAlignment":4}}}"#,
            r#"{"LastProfile":{"Options":{}},"LastProfile":{"Options":{}}}"#,
            r#"{"LastProfile":null}"#,
            r#"{"LastProfile":{"Options":{}},"Presets":null}"#,
        ] {
            assert!(inspect(invalid).is_err());
        }
    }
}
