//! Read-only migration assessment; never executes paths or silently substitutes defaults.
use crate::layout_presets::Preset;
use easypub_core::{ApiError, ErrorCode};
use serde::Serialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::io::Read;
use std::path::Path;

#[derive(Debug, Serialize)]
pub struct FileReport {
    pub source_sha256: String,
    pub encoding: &'static str,
    pub report: Report,
}

/// Bounded read of an explicitly selected file. The report is an immutable snapshot.
pub fn inspect_file(path: &Path) -> Result<FileReport, ApiError> {
    if !path.is_absolute() {
        return Err(invalid());
    }
    let file = std::fs::File::open(path).map_err(|_| invalid())?;
    if !file.metadata().map_err(|_| invalid())?.is_file() {
        return Err(invalid());
    }
    let mut bytes = Vec::new();
    file.take(1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| invalid())?;
    if bytes.len() > 1024 * 1024 {
        return Err(invalid());
    }
    let source_sha256 = format!("{:x}", Sha256::digest(&bytes));
    let (text, encoding) = if bytes.starts_with(&[0xff, 0xfe]) || bytes.starts_with(&[0xfe, 0xff]) {
        if bytes.len() % 2 != 0 {
            return Err(invalid());
        }
        let little = bytes[0] == 0xff;
        let units = bytes[2..]
            .as_chunks::<2>().0.iter()
            .map(|b| {
                if little {
                    u16::from_le_bytes([b[0], b[1]])
                } else {
                    u16::from_be_bytes([b[0], b[1]])
                }
            })
            .collect::<Vec<_>>();
        (
            String::from_utf16(&units).map_err(|_| invalid())?,
            if little { "utf-16le" } else { "utf-16be" },
        )
    } else {
        let raw = bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(&bytes);
        (
            std::str::from_utf8(raw).map_err(|_| invalid())?.to_owned(),
            "utf-8",
        )
    };
    // Do not guess encodings or accept an encoding declaration contradicting the bytes.
    if text.starts_with("<?xml") {
        let end = text.find("?>").ok_or_else(invalid)?;
        let declaration = &text[..end];
        let re = regex::Regex::new(r#"encoding\s*=\s*['"]([^'"]+)['"]"#).expect("constant regex");
        if let Some(capture) = re.captures(declaration) {
            let declared = capture[1].to_ascii_lowercase();
            if declared != encoding && !(declared == "utf-16" && encoding.starts_with("utf-16")) {
                return Err(invalid());
            }
        }
    }
    Ok(FileReport {
        source_sha256,
        encoding,
        report: if text.trim_start().starts_with('{') {
            crate::legacy_json::inspect(&text)?
        } else {
            inspect_xml(&text)?
        },
    })
}

#[derive(Debug, Serialize)]
pub struct Item {
    pub source: String,
    pub status: &'static str,
    pub reason: &'static str,
    pub target: Option<String>,
}
#[derive(Debug, Serialize)]
pub struct Report {
    pub proposed_recognition: Option<easypub_core::chapter_rules::RuleSet>,
    pub proposed_recognition_presets: Vec<easypub_core::chapter_rules::Preset>,
    pub format: &'static str,
    pub proposed_layout: BTreeMap<String, Value>,
    pub items: Vec<Item>,
    pub proposed_presets: Vec<PresetReport>,
    pub proposed_cleanup_presets: Vec<crate::cleanup_presets::Preset>,
}
#[derive(Debug, Serialize)]
pub struct PresetReport {
    pub name: String,
    pub values: BTreeMap<String, Value>,
    pub items: Vec<Item>,
}
pub(crate) fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "legacy_settings",
        "review_legacy_configuration",
    )
}

/// Input is decoded XML, not a file path. Missing fields never introduce old defaults.
pub fn inspect_xml(input: &str) -> Result<Report, ApiError> {
    if input.len() > 1024 * 1024 || input.contains("<!DOCTYPE") {
        return Err(invalid());
    }
    let doc = roxmltree::Document::parse_with_options(
        input,
        roxmltree::ParsingOptions {
            allow_dtd: false,
            nodes_limit: 8192,
            ..Default::default()
        },
    )
    .map_err(|_| invalid())?;
    let root = doc.root_element();
    if !root.has_tag_name("EasyPubConfig") || root.tag_name().namespace().is_some() {
        return Err(invalid());
    }
    let mut sections = BTreeSet::new();
    let mut report = Report {
        proposed_recognition: None,
        proposed_recognition_presets: Vec::new(),
        format: "easypub_config_xml",
        proposed_layout: BTreeMap::new(),
        items: Vec::new(),
        proposed_presets: Vec::new(),
        proposed_cleanup_presets: Vec::new(),
    };
    for section in root.children().filter(|n| n.is_element()) {
        let name = section.tag_name().name();
        if section.tag_name().namespace().is_some() || !sections.insert(name) {
            return Err(invalid());
        }
        if !matches!(name, "RecentOptions" | "AdvancedOptions") {
            report.items.push(Item {
                source: name.into(),
                status: "unsupported",
                reason: "未知配置区段，未导入",
                target: None,
            });
            continue;
        }
        let mut fields = BTreeMap::new();
        for field in section.children().filter(|n| n.is_element()) {
            if field.tag_name().namespace().is_some()
                || field.children().any(|n| n.is_element())
                || field.attributes().len() != 0
                || fields
                    .insert(field.tag_name().name(), field.text().unwrap_or("").trim())
                    .is_some()
            {
                return Err(invalid());
            }
        }
        for (&key, &raw) in &fields {
            let mut item = Item {
                source: format!("{name}/{key}"),
                status: "unsupported",
                reason: "此旧参数尚无迁移映射，未导入",
                target: None,
            };
            let mut candidate: Option<(&str, Value)> = None;
            if name == "RecentOptions" {
                match key {
                    "textalign" => {
                        candidate = match raw {
                            "0" => Some(("text_alignment", json!("start"))),
                            "1" => Some(("text_alignment", json!("justify"))),
                            "2" => Some(("text_alignment", json!("left"))),
                            "3" => Some(("text_alignment", json!("right"))),
                            "4" => Some(("text_alignment", json!("center"))),
                            _ => None,
                        };
                        item.status = "needs_confirmation";
                        item.reason = "未知对齐枚举，未回退默认值";
                    }
                    "indent" | "lineheight" => {
                        let target = if key == "indent" {
                            "paragraph_indent"
                        } else {
                            "line_height"
                        };
                        candidate = raw.parse::<f64>().ok().filter(|v| v.is_finite()).map(|v| {
                            (
                                target,
                                json!(if key == "lineheight" { v / 100.0 } else { v }),
                            )
                        });
                        item.status = "needs_confirmation";
                        item.reason = "数值无效，未采用旧默认值";
                    }
                    "margintop" | "top" | "bottom" | "left" | "right" => {
                        let (target, unit) = match key {
                            "margintop" => ("paragraph_spacing", "margintopunit"),
                            "top" => ("margin_top", "pagetopunit"),
                            "bottom" => ("margin_bottom", "pagebottomunit"),
                            "left" => ("margin_left", "pageleftunit"),
                            _ => ("margin_right", "pagerightunit"),
                        };
                        item.status = "needs_confirmation";
                        item.reason = "单位缺失或不是已确认的 em/px，未自动换算";
                        if key == "margintop" && fields.get(unit) == Some(&"2") {
                            candidate = raw
                                .parse::<f64>()
                                .ok()
                                .filter(|v| v.is_finite())
                                .map(|v| (target, json!(v)));
                            item.reason = "段间距单位为 em，等待明确选择应用范围";
                        } else if key != "margintop" && fields.get(unit) == Some(&"0") {
                            candidate = raw
                                .parse::<f64>()
                                .ok()
                                .filter(|v| (0.0..=1000.0).contains(v))
                                .map(|v| (target, json!(v)));
                            if candidate.is_some() {
                                report
                                    .proposed_layout
                                    .insert(format!("{target}_unit"), json!("px"));
                            } else {
                                item.reason = "px 边距数值无效或超出范围，数值和单位均未导入";
                            }
                            item.reason = "旧配置明确为 px，等待明确选择应用范围";
                        }
                    }
                    "fontsize" => {
                        item.status = "needs_confirmation";
                        item.reason = "字号百分比无效";
                        if let Ok(v) = raw.parse::<f64>()
                            && (50.0..=200.0).contains(&v) {
                                report.proposed_layout.insert("font_size".into(), json!(v));
                                report
                                    .proposed_layout
                                    .insert("font_size_unit".into(), json!("%"));
                                item.status = "ready";
                                item.reason = "保留旧版相对字号";
                                item.target = Some("font_size".into());
                            }
                    }
                    "addspace" => {
                        if matches!(raw, "0" | "1") {
                            let count = if raw == "0" {
                                Some(0)
                            } else {
                                fields
                                    .get("addspacecount")
                                    .and_then(|v| v.parse::<u8>().ok())
                                    .filter(|v| *v <= 8)
                            };
                            candidate = count.map(|n| ("fullwidth_indent", json!(n)));
                        }
                    }
                    "removeblankline" => {
                        if matches!(raw, "0" | "1") {
                            candidate = Some(("remove_blank_lines", json!(raw == "1")));
                        }
                    }
                    "full_reg" => {
                        let rules = easypub_core::chapter_rules::RuleSet {
                            chapter_pattern: crate::legacy_json::legacy_pattern(raw),
                            origin: "import_default".into(),
                            ..Default::default()
                        };
                        if rules.compile().is_ok() {
                            report.proposed_recognition = Some(rules);
                            item.status = "recognition_ready";
                            item.reason = "章节识别规则可迁移为导入默认，已有书需单独预览";
                            item.target = Some("recognition_defaults".into());
                        } else {
                            item.status = "unsupported";
                            item.reason = "章节正则含未支持语法，未回退默认；请在识别规则中调整";
                        }
                    }
                    "addspacecount" => {
                        item.status = "needs_confirmation";
                        item.reason = "影响正文或章节识别，须单独预览，不作为排版默认自动启用";
                    }
                    _ => {}
                }
            }
            if let Some((target, value)) = candidate {
                let values = BTreeMap::from([(target.into(), value.clone())]);
                if (Preset {
                    name: "legacy".into(),
                    values,
                })
                .validate()
                .is_ok()
                {
                    report.proposed_layout.insert(target.into(), value);
                    item.status = "ready";
                    item.reason = "语义可对应，等待明确选择应用范围";
                    item.target = Some(target.into());
                } else {
                    item.status = "needs_confirmation";
                    item.reason = "超出新字段支持范围，未截断或替换";
                }
            }
            report.items.push(item);
        }
    }
    if !sections.contains("RecentOptions") || !sections.contains("AdvancedOptions") {
        return Err(invalid());
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn legacy_single_and_compact_line_heights_keep_their_ratios() {
        for ratio in [100, 120, 130, 230] {
            let report = inspect_xml(&format!("<EasyPubConfig><RecentOptions><lineheight>{ratio}</lineheight></RecentOptions><AdvancedOptions/></EasyPubConfig>")).unwrap();
            assert_eq!(
                report.proposed_layout["line_height"],
                json!(ratio as f64 / 100.0)
            );
        }
        for ratio in [0, 99, 231] {
            let report = inspect_xml(&format!("<EasyPubConfig><RecentOptions><lineheight>{ratio}</lineheight></RecentOptions><AdvancedOptions/></EasyPubConfig>")).unwrap();
            assert!(!report.proposed_layout.contains_key("line_height"));
            assert_eq!(report.items[0].status, "needs_confirmation");
        }
    }

    #[test]
    fn file_encodings_are_strict_and_source_is_unchanged() {
        let dir = std::env::temp_dir().join(format!(
            "easypub-legacy-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("config.xml");
        for (encoding, bom) in [
            ("utf-8", vec![0xef, 0xbb, 0xbf]),
            ("utf-16le", vec![0xff, 0xfe]),
            ("utf-16be", vec![0xfe, 0xff]),
        ] {
            let input = format!(
                "<?xml version='1.0' encoding='{encoding}'?>{}",
                xml("<indent>2</indent>")
            );
            let mut bytes = bom;
            if encoding == "utf-8" {
                bytes.extend(input.as_bytes());
            } else {
                for unit in input.encode_utf16() {
                    bytes.extend(if encoding == "utf-16le" {
                        unit.to_le_bytes()
                    } else {
                        unit.to_be_bytes()
                    });
                }
            }
            std::fs::write(&path, &bytes).unwrap();
            let result = inspect_file(&path).unwrap();
            assert_eq!(result.encoding, encoding);
            assert_eq!(
                result.report.proposed_layout["paragraph_indent"],
                json!(2.0)
            );
            assert_eq!(
                result.source_sha256,
                format!("{:x}", Sha256::digest(&bytes))
            );
            assert_eq!(std::fs::read(&path).unwrap(), bytes);
        }
        for bytes in [
            vec![0xff, 0xfe, 0x00, 0xd8],
            vec![0xff, 0xfe, 0x41],
            vec![0xff],
            vec![b'x'; 1024 * 1024 + 1],
            format!("<?xml version='1.0' encoding='gbk'?>{}", xml("")).into_bytes(),
        ] {
            std::fs::write(&path, bytes).unwrap();
            assert!(inspect_file(&path).is_err());
        }
        assert!(inspect_file(Path::new("config.xml")).is_err());
        assert!(inspect_file(&dir).is_err());
        std::fs::remove_file(&path).unwrap();
        std::fs::remove_dir(&dir).unwrap();
    }
    fn xml(recent: &str) -> String {
        format!(
            "<EasyPubConfig><RecentOptions>{recent}</RecentOptions><AdvancedOptions><kindlegenoption>do not execute</kindlegenoption></AdvancedOptions></EasyPubConfig>"
        )
    }
    #[test]
    fn invalid_pixel_values_never_leave_detached_units() {
        for raw in ["-1", "1001", "NaN", "abc"] {
            let report = inspect_xml(&xml(&format!(
                "<left>{raw}</left><pageleftunit>0</pageleftunit>"
            )))
            .unwrap();
            assert!(report.proposed_layout.is_empty());
        }
        for value in [json!(-1), json!(1001), json!("3"), Value::Null] {
            let report = crate::legacy_json::inspect(
                &json!({"LastProfile":{"Options":{"PageMarginLeftPx":value}}}).to_string(),
            )
            .unwrap();
            assert!(report.proposed_layout.is_empty());
        }
        for value in [0, 3, 1000] {
            let report = crate::legacy_json::inspect(
                &json!({"LastProfile":{"Options":{"PageMarginLeftPx":value}}}).to_string(),
            )
            .unwrap();
            assert_eq!(report.proposed_layout["margin_left"], json!(value as f64));
            assert_eq!(report.proposed_layout["margin_left_unit"], json!("px"));
        }
    }

    #[test]
    fn preserves_units_and_does_not_invent_missing_defaults() {
        let r = inspect_xml(&xml("<indent>2</indent><lineheight>180</lineheight><textalign>1</textalign><margintop>0.6</margintop><margintopunit>2</margintopunit><fontsize>110</fontsize><left>3</left><pageleftunit>0</pageleftunit>")).unwrap();
        assert_eq!(r.proposed_layout.len(), 8);
        assert_eq!(r.proposed_layout["line_height"], json!(1.8));
        assert_eq!(r.proposed_layout["text_alignment"], json!("justify"));
        assert_eq!(r.proposed_layout["font_size"], json!(110.0));
        assert_eq!(r.proposed_layout["font_size_unit"], json!("%"));
        assert_eq!(r.proposed_layout["margin_left"], json!(3.0));
        assert_eq!(r.proposed_layout["margin_left_unit"], json!("px"));
        assert!(inspect_xml(&xml("")).unwrap().proposed_layout.is_empty());
        let serialized = serde_json::to_string(&r).unwrap();
        assert!(!serialized.contains("do not execute"));
    }
    #[test]
    fn invalid_values_are_reported_without_clamping() {
        let r = inspect_xml(&xml("<indent>99</indent><lineheight>99</lineheight><textalign>9</textalign><margintop>NaN</margintop><margintopunit>2</margintopunit>")).unwrap();
        assert!(r.proposed_layout.is_empty());
        assert_eq!(
            r.items
                .iter()
                .filter(|i| i.status == "needs_confirmation")
                .count(),
            4
        );
    }
    #[test]
    fn rejects_ambiguous_or_unbounded_xml() {
        for input in [
            xml("<indent>1</indent><indent>2</indent>"),
            xml("<indent><value>1</value></indent>"),
            xml("<indent unit='em'>1</indent>"),
            format!("<!DOCTYPE EasyPubConfig []>{}", xml("")),
            xml("").replace("<RecentOptions>", "<RecentOptions xmlns='other'>"),
            "x".repeat(1024 * 1024 + 1),
        ] {
            assert!(inspect_xml(&input).is_err());
        }
    }
}
