//! 规则事务返回完整候选快照，由唯一工作区持有者一次发布；不写原稿。
use crate::{production::Settings, publication_resources, sessions::ImportService};
use easypub_core::{ApiError, ErrorCode, chapter_rules::RuleSet};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{collections::BTreeSet, sync::atomic::AtomicBool};

fn invalid(reason: &str) -> ApiError {
    ApiError::new(ErrorCode::InvalidRule, "rule_toggles", reason)
}
fn hash(v: &Value) -> String {
    format!("{:x}", Sha256::digest(v.to_string().as_bytes()))
}
pub(crate) fn pipeline(
    configuration: &Value,
    draft: &Value,
    settings: &Settings,
) -> (Value, &'static str) {
    if let Some(p) = &settings.rule_options.cleanup_pipeline {
        return (json!(p), "book");
    }
    for (v, key, legacy, origin) in [
        (draft, "pipeline", "rules", "book"),
        (
            configuration,
            "automatic_cleanup_pipeline",
            "automatic_cleanup_rules",
            "global",
        ),
    ] {
        if v[key].is_array() {
            return (v[key].clone(), origin);
        }
        if let Some(rules) = v[legacy].as_array() {
            let mut rules = rules.clone();
            if origin == "book" {
                rules.sort_by_key(|r| {
                    [
                        "trim_trailing_spaces",
                        "remove_ad_lines",
                        "collapse_blank_lines",
                    ]
                    .iter()
                    .position(|k| r == k)
                });
            }
            return (
                json!(rules.iter().map(|r| json!({"kind":r})).collect::<Vec<_>>()),
                origin,
            );
        }
    }
    (
        json!([{"kind":"trim_trailing_spaces"},{"kind":"collapse_blank_lines"},{"kind":"remove_ad_lines"}]),
        "builtin",
    )
}
fn base(v: &Value) -> &Value {
    if v["kind"] == "configured" {
        &v["rule"]
    } else {
        v
    }
}
fn matches_cleanup(v: &Value, kind: &str) -> bool {
    let b = base(v);
    match kind {
        "site_notices" => b["kind"] == "remove_ad_lines" || b["kind"] == "notice_lines",
        "repeated_headers" => b["kind"] == "notice_lines",
        _ => b["kind"] == kind,
    }
}
pub(crate) fn cleanup_enabled(pipeline: &Value, id: &str) -> bool {
    let suffix = id.strip_prefix("cleanup.").unwrap_or(id);
    let (kind, option) = suffix
        .split_once('.')
        .map_or((suffix, None), |(k, o)| (k, Some(o)));
    pipeline.as_array().is_some_and(|rows| {
        rows.iter().any(|r| {
            if !matches_cleanup(r, kind) || (r["kind"] == "configured" && r["enabled"] != true) {
                return false;
            }
            let b = base(r);
            match (kind, option) {
                ("repeated_headers", _) => b["options"]["include_headers"] == true,
                ("chinese_punctuation", Some(o)) => b["options"][o] == true,
                ("chinese_punctuation", None) => ["marks", "ellipsis", "dashes", "quotes"]
                    .iter()
                    .any(|o| b["options"][o] == true),
                ("site_notices", _) => {
                    b["kind"] == "remove_ad_lines"
                        || b["options"]["include_defaults"] == true
                        || b["options"]["pattern"].is_object()
                        || b["options"]["keywords"]
                            .as_array()
                            .is_some_and(|a| !a.is_empty())
                }
                _ => true,
            }
        })
    })
}
fn toggle_cleanup(pipeline: &mut Value, id: &str, enabled: bool) -> Result<(), ApiError> {
    let suffix = &id[8..];
    let (kind, option) = suffix
        .split_once('.')
        .map_or((suffix, None), |(k, o)| (k, Some(o)));
    let rows = pipeline
        .as_array_mut()
        .ok_or_else(|| invalid("清理配置无效"))?;
    if !rows.iter().any(|r| matches_cleanup(r, kind)) {
        if !enabled {
            return Ok(());
        }
        rows.push(
            crate::rule_statistics::cleanup::fallback(kind)
                .ok_or_else(|| invalid("请先在清理页配置规则内容，再开启"))?,
        );
    }
    for r in rows.iter_mut().filter(|r| matches_cleanup(r, kind)) {
        if r["kind"] != "configured" {
            *r = json!({"kind":"configured","enabled":true,"scope":"all","rule":r.clone()});
        }
        if kind == "site_notices" && r["rule"]["kind"] == "notice_lines" {
            if !enabled {
                r["original"] = r["rule"].clone();
                r["rule"]["options"]["include_defaults"] = json!(false);
                r["rule"]["options"]["keywords"] = json!([]);
                r["rule"]["options"]["pattern"] = Value::Null;
            } else {
                if r["original"]["kind"] == "notice_lines" {
                    for key in ["include_defaults", "keywords", "pattern"] {
                        r["rule"]["options"][key] = r["original"]["options"][key].clone();
                    }
                } else {
                    r["rule"]["options"]["include_defaults"] = json!(true);
                }
                r["enabled"] = json!(true);
            }
            continue;
        }
        let option = if kind == "repeated_headers" {
            Some("include_headers")
        } else {
            option
        };
        if let Some(o) = option {
            r["rule"]["options"][o] = json!(enabled);
            if enabled {
                r["enabled"] = json!(true);
            }
        } else {
            r["enabled"] = json!(enabled);
        }
    }
    let _: Vec<easypub_core::cleanup_rules::Rule> =
        serde_json::from_value(pipeline.clone()).map_err(|_| invalid("清理配置无效"))?;
    Ok(())
}
pub(crate) fn enabled(row: &Value, rules: &RuleSet, settings: &Settings, pipeline: &Value) -> bool {
    let id = row["id"].as_str().unwrap();
    if let Some(id) = id.strip_prefix("chapter.recognize.") {
        return rules.enabled(id)
            && match id {
                "volume" | "section" => rules.hierarchy,
                "level_chapter" => {
                    rules.hierarchy && !rules.level_chapter_pattern.trim().is_empty()
                }
                "numeric" => rules.numeric,
                "normalize_numeric" => rules.normalize_numeric_titles,
                "number_corrections" => !rules.number_corrections.trim().is_empty(),
                "non_heading" => !rules.non_heading.trim().is_empty(),
                "force_heading" => !rules.force_heading.trim().is_empty(),
                "title_suffixes" => !rules.title_suffixes.trim().is_empty(),
                _ => true,
            };
    }
    if let Some(id) = id.strip_prefix("check.") {
        let (id, sub) = id.split_once('.').map_or((id, None), |(a, b)| (a, Some(b)));
        return rules.check_enabled(id, sub);
    }
    if id.starts_with("cleanup.") {
        return cleanup_enabled(pipeline, id);
    }
    if let Some(symbol) = id.strip_prefix("layout.scene.u") {
        let c = u32::from_str_radix(symbol, 16)
            .ok()
            .and_then(char::from_u32)
            .unwrap();
        return settings.scene_break_style != "off"
            && settings
                .rule_options
                .scene_symbols
                .as_ref()
                .is_none_or(|s| s.contains(c));
    }
    let parent = row["parent"].as_str().unwrap_or(id);
    let parent_on = match parent {
        "layout.scene" => settings.scene_break_style != "off",
        "layout.system" => settings.system_block_style != "off",
        "layout.verse" => settings.verse_block_style != "off",
        "layout.chat" => settings.chat_block_style != "off",
        "layout.inset" => settings.inset_detect == "on",
        "layout.note" => settings.note_style == "popup",
        "layout.first_paragraph" => settings.first_paragraph_style != "normal",
        _ => true,
    };
    parent_on && settings.rule_options.enabled(id)
}
fn disable(list: &mut Vec<String>, id: &str, enabled: bool) {
    list.retain(|v| v != id);
    if !enabled {
        list.push(id.into());
        list.sort();
    }
}
pub(crate) fn toggle(
    row: &Value,
    rules: &mut RuleSet,
    settings: &mut Settings,
    pipeline: &mut Value,
    enabled: bool,
) -> Result<(), ApiError> {
    let id = row["id"].as_str().unwrap();
    if row["locked"] == true {
        return Err(invalid(row["locked_reason"].as_str().unwrap()));
    }
    if let Some(k) = id.strip_prefix("chapter.recognize.") {
        match k {
            "numeric" => rules.numeric = enabled,
            "normalize_numeric" => rules.normalize_numeric_titles = enabled,
            "volume" | "section" | "level_chapter" if enabled => {
                rules.hierarchy = true;
            }
            _ => (),
        }
        if enabled
            && matches!(
                k,
                "level_chapter"
                    | "non_heading"
                    | "force_heading"
                    | "title_suffixes"
                    | "number_corrections"
            )
        {
            let v = serde_json::to_value(&*rules).unwrap();
            let key = if k == "level_chapter" {
                "level_chapter_pattern"
            } else {
                k
            };
            if v[key].as_str().unwrap_or("").trim().is_empty() {
                return Err(invalid("请先配置规则内容，再开启"));
            }
        }
        disable(&mut rules.disabled_recognition, k, enabled);
    } else if let Some(k) = id.strip_prefix("check.") {
        disable(&mut rules.disabled_checks, k, enabled);
    } else if id.starts_with("cleanup.") {
        toggle_cleanup(pipeline, id, enabled)?;
    } else if let Some(symbol) = id.strip_prefix("layout.scene.u") {
        let c = u32::from_str_radix(symbol, 16)
            .ok()
            .and_then(char::from_u32)
            .unwrap();
        let symbols = settings
            .rule_options
            .scene_symbols
            .get_or_insert_with(|| crate::publication_documents::SCENE_SYMBOLS.into());
        symbols.retain(|v| v != c);
        if enabled {
            symbols.push(c);
        }
    } else if !row["off_value"].is_null() {
        let key = row["toggle"]["key"].as_str().unwrap();
        let mut v = serde_json::to_value(&*settings).unwrap();
        if enabled {
            v[key] = settings
                .rule_options
                .restore_values
                .get(id)
                .cloned()
                .unwrap_or_else(|| row["on_value"].clone());
        } else {
            if v[key] != row["off_value"] {
                settings
                    .rule_options
                    .restore_values
                    .insert(id.into(), v[key].clone());
            }
            v[key] = row["off_value"].clone();
        }
        v["rule_options"] = json!(settings.rule_options);
        *settings = serde_json::from_value(v).map_err(|_| invalid("排版设置无效"))?;
    } else {
        disable(&mut settings.rule_options.disabled, id, enabled);
    }
    Ok(())
}

fn decode<T: serde::de::DeserializeOwned>(v: &Value) -> Result<T, ApiError> {
    serde_json::from_value(v.clone()).map_err(|_| invalid("规则请求无效，请重新读取本书"))
}
// 只比较已应用前缀；保留完整历史供跨规则事务往返时恢复重做分支。
fn applied_snapshot(
    snapshot: &Value,
    base: &Value,
    source: &easypub_core::source::SourceSnapshot,
) -> Result<Value, ApiError> {
    let mut result = snapshot.clone();
    if !snapshot["effective_history"].is_null() {
        let h: crate::effective_draft::History = decode(&snapshot["effective_history"])?;
        h.validate(source)?;
        if h.cursor == 0 && h.current().request.is_empty() && json!(h.current().base) == *base {
            result["effective_history"] = Value::Null;
        } else {
            result["effective_history"]["history"] = json!(&h.history[..=h.cursor]);
        }
    }
    if !snapshot["production_history"].is_null() {
        let h: crate::production::History = decode(&snapshot["production_history"])?;
        h.validate(source.summary().line_count)?;
        if h.source_id != source.summary().source_id || h.revision != source.summary().revision {
            return Err(invalid("历史来源已变化，请重新读取本书"));
        }
        if h.cursor == 0 && json!(h.states[0]) == snapshot["settings"] {
            result["production_history"] = Value::Null;
        } else {
            result["production_history"]["states"] = json!(&h.states[..=h.cursor]);
        }
    }
    Ok(result)
}
pub(crate) fn run(service: &ImportService, value: Value) -> Result<String, ApiError> {
    let scope = value["scope"]
        .as_str()
        .ok_or_else(|| invalid("请选择本书或新书默认"))?;
    if !matches!(scope, "book" | "global") {
        return Err(invalid("请选择本书或新书默认"));
    }
    let publication: publication_resources::Request = decode(&value["publication"])?;
    let source = service.source(&publication.source_id, publication.revision)?;
    if value["action"] == "restore_toggles" {
        let mut history = value["history"].clone();
        validate_history(&history)?;
        let cursor = history["cursor"]
            .as_u64()
            .ok_or_else(|| invalid("规则历史无效"))? as usize;
        let undo = value["undo"]
            .as_bool()
            .ok_or_else(|| invalid("恢复方向无效"))?;
        let index = if undo { cursor } else { cursor + 1 };
        let entry = history["states"]
            .get(index)
            .ok_or_else(|| invalid("没有可恢复的规则记录"))?;
        if index == 0 {
            return Err(invalid("没有可撤销的规则记录"));
        }
        let expected = &entry[if undo { "after" } else { "before" }];
        let current = json!({"settings":value["publication"]["settings"],"effective_history":value["effective_history"],"production_history":value["production_history"]});
        if applied_snapshot(&current, &value["base"], &source)?
            != applied_snapshot(expected, &value["base"], &source)?
        {
            return Err(invalid("规则之后还有修改，请先撤销后续修改"));
        }
        let next = entry[if undo { "before" } else { "after" }].clone();
        history["states"][index][if undo { "after" } else { "before" }] = current;
        let mut request = value["publication"].clone();
        request["settings"] = next["settings"].clone();
        let effective = &next["effective_history"];
        if !effective.is_null() {
            let h: crate::effective_draft::History = decode(effective)?;
            h.validate(&source)?;
            request["post_edits"] = if h.current().request.is_empty() {
                Value::Null
            } else {
                json!(h.current().request)
            };
        } else {
            request["post_edits"] = Value::Null;
        }
        publication_resources::compose(&source, decode(&request)?)?;
        history["cursor"] = json!(if undo { cursor - 1 } else { cursor + 1 });
        return Ok(json!({"snapshot":next,"history":history,"applied":true}).to_string());
    }
    let (book, mut settings) = publication_resources::compose(&source, publication)?;
    let mut rules = book.tree.recognition_rules.clone().unwrap_or_default();
    let (mut pipeline, origin) =
        pipeline(&value["configuration"], &value["cleanup_draft"], &settings);
    let mut defaults_settings = settings.clone();
    let factory_layout = crate::layout_settings::factory();
    let mut default_json = json!(defaults_settings);
    for (k, v) in &factory_layout {
        default_json[k] = v.clone();
    }
    default_json["rule_options"] = json!(crate::rule_options::Options::default());
    default_json["layout_origins"] = json!({});
    let factory_settings: Settings = decode(&default_json)?;
    for (k, v) in value["configuration"]["layout_defaults"]
        .as_object()
        .into_iter()
        .flatten()
    {
        default_json[k] = v.clone();
    }
    defaults_settings = decode(&default_json)?;
    let mut default_rules: RuleSet = if value["configuration"]["recognition_defaults"].is_object() {
        decode(&value["configuration"]["recognition_defaults"])?
    } else {
        RuleSet::default()
    };
    let (mut default_pipeline, _) =
        pipeline_fn(&value["configuration"], &Value::Null, &defaults_settings);
    let defaults = &value["configuration"]["rule_defaults"];
    if defaults.is_object() {
        default_rules = decode(&defaults["rules"])?;
        defaults_settings.rule_options = decode(&defaults["rule_options"])?;
        let mut v = json!(defaults_settings);
        for (k, val) in defaults["layout"].as_object().into_iter().flatten() {
            v[k] = val.clone();
        }
        defaults_settings = decode(&v)?;
        default_pipeline = defaults["pipeline"].clone();
    }
    if scope == "global" {
        rules = default_rules.clone();
        settings = defaults_settings.clone();
        pipeline = default_pipeline.clone();
    }
    let catalog = crate::rule_catalog::catalog();
    let rows = catalog["rules"].as_array().unwrap();
    if value["action"] == "settings" {
        let factory_pipeline = pipeline_fn(&json!({}), &Value::Null, &factory_settings).0;
        return Ok(json!({"scope":scope,"rules":rows.iter().map(|r| {
            let mut r = r.clone();
            r["enabled"] = json!(enabled(&r,&rules,&settings,&pipeline));
            r["factory_default"] = json!(enabled(&r,&RuleSet::default(),&factory_settings,&factory_pipeline));
            r["new_book_default"] = json!(enabled(&r,&default_rules,&defaults_settings,&default_pipeline));
            let configured = defaults.is_object() || match r["group"].as_str() {
                Some("chapter_recognition"|"chapter_check") => value["configuration"]["recognition_defaults"].is_object(),
                Some("cleanup") => value["configuration"]["automatic_cleanup_pipeline"].is_array() || value["configuration"]["automatic_cleanup_rules"].is_array(),
                Some("layout") => value["configuration"]["layout_defaults"].get(r["toggle"]["key"].as_str().unwrap_or("")).is_some(),
                _ => false,
            };
            r["origin"] = json!(if scope == "global" { if configured { "global" } else { "builtin" } } else if r["group"] == "cleanup" { origin } else { "book" });
            if let Some(restored) = settings.rule_options.restore_values.get(r["id"].as_str().unwrap()) { r["on_value"] = restored.clone(); }
            r
        }).collect::<Vec<_>>()}).to_string());
    }
    let before_settings = settings.clone();
    let before_rules = rules.clone();
    let before_pipeline = pipeline.clone();
    let changes = value["changes"]
        .as_array()
        .ok_or_else(|| invalid("没有规则改动"))?;
    let mut seen = BTreeSet::new();
    let mut changed = Vec::new();
    for change in changes {
        let id = change["id"]
            .as_str()
            .ok_or_else(|| invalid("规则编号无效"))?;
        if !seen.insert(id) {
            return Err(invalid("同一规则不能重复提交"));
        }
        let row = rows
            .iter()
            .find(|r| r["id"] == id)
            .ok_or_else(|| invalid("未知规则"))?;
        let on = change["enabled"]
            .as_bool()
            .ok_or_else(|| invalid("开关值无效"))?;
        let before = json!({"rules":rules,"settings":settings,"pipeline":pipeline});
        toggle(row, &mut rules, &mut settings, &mut pipeline, on)?;
        let after = json!({"rules":rules,"settings":settings,"pipeline":pipeline});
        let mut fields = Vec::new();
        field_changes("", &before, &after, &mut fields);
        changed.push(json!({"id":id,"key":row["toggle"]["key"],"before":enabled(row,&before_rules,&before_settings,&before_pipeline),"after":enabled(row,&rules,&settings,&pipeline),"fields":fields}));
    }
    rules.compile()?;
    let settings_value = json!(settings);
    settings
        .layout_origins
        .retain(|key, origin| settings_value[key] == origin.value);
    settings.validate(source.summary().line_count)?;
    let mut effective_history = value["effective_history"].clone();
    let mut next_publication = value["publication"].clone();
    let before_snapshot = json!({"settings":value["publication"]["settings"],"effective_history":effective_history,"production_history":value["production_history"]});
    if scope == "book" && rules != before_rules {
        let result: Value = serde_json::from_str(&crate::effective_draft::edit(service, source.summary().source_id, source.summary().revision,
            value["base"].to_string(), if effective_history.is_null() { String::new() } else { effective_history.to_string() },
            json!({"op":"append_batch","actions":[{"kind":"recognize","rules":rules,"preserve_decisions":true}]}).to_string())?).map_err(|_| invalid("章节预览失败"))?;
        effective_history = result["history"].clone();
        let cursor = effective_history["cursor"].as_u64().unwrap() as usize;
        next_publication["post_edits"] = effective_history["history"][cursor]["request"].clone();
    }
    if pipeline != before_pipeline {
        settings.rule_options.cleanup_pipeline = Some(decode(&pipeline)?);
    }
    let mut production_history = value["production_history"].clone();
    if scope == "book" && settings != before_settings {
        let old = json!(before_settings);
        let new = json!(settings);
        let fields: serde_json::Map<String, Value> = new
            .as_object()
            .unwrap()
            .iter()
            .filter(|(k, v)| {
                !matches!(k.as_str(), "layout_origins" | "metadata_origins") && old[*k] != **v
            })
            .map(|(k, v)| (k.clone(), json!({"op":"set","value":v})))
            .collect();
        let history = if production_history.is_null() {
            json!({"source_id":source.summary().source_id,"revision":source.summary().revision,"states":[old],"cursor":0})
        } else {
            production_history.clone()
        };
        let request = json!({"targets":[{"book_id":value["book_id"],"current":old,"history":history,"change":{"op":"patch","fields":fields}}]}).to_string();
        let preview: Value = serde_json::from_str(&crate::production::run(
            service,
            request.clone(),
            false,
            String::new(),
            false,
        )?)
        .unwrap();
        let applied: Value = serde_json::from_str(&crate::production::run(
            service,
            request,
            true,
            preview["plan_id"].as_str().unwrap().into(),
            true,
        )?)
        .unwrap();
        production_history = applied["items"][0]["history"].clone();
        settings = decode(&applied["items"][0]["after"])?;
    }
    next_publication["settings"] = json!(settings);
    let after_snapshot = json!({"settings":settings,"effective_history":effective_history,"production_history":production_history});
    let identity = json!([
        "rule-toggles-v1",
        value["book_id"],
        scope,
        value["publication"],
        value["base"],
        value["effective_history"],
        value["production_history"],
        value["cleanup_draft"],
        value["configuration"],
        value["history"],
        changes
    ]);
    let plan_id = hash(&identity);
    let apply = value["action"] == "apply_toggles";
    if apply && value["plan_id"] != plan_id {
        return Err(invalid("书稿或设置已变化，请重新预览"));
    }
    let mut history = value["history"].clone();
    if history.is_null() {
        history = json!({"states":[before_snapshot],"cursor":0});
    }
    validate_history(&history)?;
    if apply && scope == "book" {
        let cursor = history["cursor"]
            .as_u64()
            .ok_or_else(|| invalid("规则历史无效"))? as usize;
        let states = history["states"]
            .as_array_mut()
            .ok_or_else(|| invalid("规则历史无效"))?;
        states.truncate(cursor + 1);
        // 其他页面也能改变设置，保留当前真实基线用于本次撤销。
        states.push(json!({"before":before_snapshot,"after":after_snapshot}));
        history["cursor"] = json!(states.len() - 1);
        validate_history(&history)?;
    }
    let mut layout = serde_json::Map::new();
    for key in factory_layout.keys() {
        layout.insert(key.clone(), json!(settings)[key].clone());
    }
    let defaults = json!({"rules":rules,"layout":layout,"rule_options":settings.rule_options,"pipeline":pipeline});
    let impact = if apply {
        Value::Null
    } else {
        let cancel = AtomicBool::new(false);
        let mut before = crate::rule_statistics::calculate(
            &source,
            decode(&value["publication"])?,
            before_pipeline.clone(),
            &cancel,
        )?;
        crate::rule_statistics::enrich(&source, &value, &mut before)?;
        let after = if scope == "global" {
            Value::Null
        } else {
            let mut r = crate::rule_statistics::calculate(
                &source,
                decode(&next_publication)?,
                pipeline.clone(),
                &cancel,
            )?;
            let mut context = value.clone();
            context["publication"] = next_publication.clone();
            crate::rule_statistics::enrich(&source, &context, &mut r)?;
            r
        };
        let (_, changes) = if scope == "book" {
            chapter_changes(&book, &source, &next_publication)?
        } else {
            (0, vec![])
        };
        json!({"scope":scope,"before":before,"after":after,"chapter_changes_total":changes.len(),"chapter_changes":changes.into_iter().take(50).collect::<Vec<_>>(),"writes_body":false})
    };
    let conflicts: Vec<_> = impact["after"]["rules"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|r| {
            r["affects"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|a| json!({"rule":r["id"],"affects":a}))
        })
        .collect();
    Ok(json!({"plan_id":plan_id,"applied":apply,"scope":scope,"changes":changed,"impact":impact,"conflicts":conflicts,"snapshot":after_snapshot,"history":if apply {history} else {Value::Null},"defaults":defaults,"writes_source":false}).to_string())
}

#[cfg(test)]
#[path = "rule_toggles_tests.rs"]
mod tests;
use pipeline as pipeline_fn;
pub(crate) fn validate_defaults(v: &Value) -> Result<(), ApiError> {
    let rules: RuleSet = decode(&v["rules"])?;
    rules.compile()?;
    let options: crate::rule_options::Options = decode(&v["rule_options"])?;
    options.validate()?;
    let _: Vec<easypub_core::cleanup_rules::Rule> = decode(&v["pipeline"])?;
    let layout: std::collections::BTreeMap<String, Value> = decode(&v["layout"])?;
    crate::layout_settings::Layers {
        global: layout,
        ..Default::default()
    }
    .resolve()?;
    Ok(())
}
pub(crate) fn validate_history(history: &Value) -> Result<(), ApiError> {
    let states = history["states"]
        .as_array()
        .ok_or_else(|| invalid("规则历史无效"))?;
    if states.is_empty()
        || states.len() > 51
        || history["cursor"]
            .as_u64()
            .is_none_or(|c| c as usize >= states.len())
        || history.to_string().len() > 96 * 1024 * 1024
    {
        return Err(invalid("规则历史超过限制，请另存项目"));
    }
    for s in states
        .iter()
        .skip(1)
        .flat_map(|s| [&s["before"], &s["after"]])
    {
        let settings: Settings = decode(&s["settings"])?;
        settings.validate(u32::MAX)?;
        if !s["effective_history"].is_null() {
            decode::<crate::effective_draft::History>(&s["effective_history"])?.validate_shape()?;
        }
        if !s["production_history"].is_null() {
            decode::<crate::production::History>(&s["production_history"])?.validate(u32::MAX)?;
        }
    }
    Ok(())
}
fn chapter_changes(
    before: &easypub_core::publication::EffectiveBook,
    source: &easypub_core::source::SourceSnapshot,
    publication: &Value,
) -> Result<(usize, Vec<Value>), ApiError> {
    let (after, _) = publication_resources::compose(source, decode(publication)?)?;
    let mut changes = Vec::new();
    let old: std::collections::BTreeMap<_, _> = before
        .tree
        .nodes
        .iter()
        .map(|n| (n.source_line, n))
        .collect();
    let new: BTreeSet<_> = after.tree.nodes.iter().map(|n| n.source_line).collect();
    for n in &after.tree.nodes {
        match old.get(&n.source_line) {
            None => changes.push(json!({"kind":"added","line":n.source_line,"title":n.title,"role":n.role})),
            Some(o) if o.role != n.role || o.depth != n.depth || o.title != n.title => changes.push(json!({"kind":"changed","line":n.source_line,"before":o.title,"after":n.title,"before_role":o.role,"role":n.role,"before_depth":o.depth,"depth":n.depth})),
            _ => (),
        }
    }
    for o in &before.tree.nodes {
        if !new.contains(&o.source_line) {
            changes.push(json!({"kind":"removed","line":o.source_line,"title":o.title}));
        }
    }
    Ok((after.tree.nodes.len(), changes))
}
fn field_changes(path: &str, before: &Value, after: &Value, out: &mut Vec<Value>) {
    if before == after {
        return;
    }
    if let (Some(a), Some(b)) = (before.as_object(), after.as_object()) {
        for key in a.keys().chain(b.keys()).collect::<BTreeSet<_>>() {
            field_changes(
                &if path.is_empty() {
                    key.clone()
                } else {
                    format!("{path}.{key}")
                },
                &before[key],
                &after[key],
                out,
            );
        }
    } else {
        out.push(json!({"key":path,"before":before,"after":after}));
    }
}
