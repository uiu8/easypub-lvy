//! R1 的唯一规则目录；只描述现有能力，不新增设置或改变算法。
use serde_json::{Value, json};

pub fn catalog() -> Value {
    let mut rows = Vec::new();
    let mut add = |id: &str,
                   group: &str,
                   parent: Option<&str>,
                   label: &str,
                   description: &str,
                   effect: &str,
                   toggle: Value,
                   default: bool,
                   order: u32,
                   category: &str| {
        rows.push(
            json!({"id":id,"group":group,"parent":parent,"label":label,"description":description,
            "effect":effect,"toggle":toggle,"default":default,"order":order,"category":category}),
        );
    };
    let chapter_toggle =
        |key: &str, on: Value| json!({"key":format!("recognition_rules.{key}"),"on":on});
    for (id, label, description, key, on, default) in [
        (
            "chapter",
            "章标题",
            "按当前常规标题规则识别章标题；未填写表达式时使用内置识别。",
            "",
            Value::Null,
            true,
        ),
        (
            "volume",
            "卷标题",
            "按层级设置识别卷、部、篇、集标题。",
            "hierarchy",
            json!(true),
            true,
        ),
        (
            "section",
            "节标题",
            "按内置节标题或自定义表达式识别节标题。",
            "hierarchy",
            json!(true),
            true,
        ),
        (
            "level_chapter",
            "分级章标题",
            "使用层级内的自定义章标题表达式。",
            "level_chapter_pattern",
            json!("非空表达式"),
            false,
        ),
        (
            "numeric",
            "纯数字标题",
            "识别数字标题，保留最少正文行数条件。",
            "numeric",
            json!(true),
            false,
        ),
        (
            "normalize_numeric",
            "数字标题统一格式",
            "对识别出的数字标题采用统一标题形式。",
            "normalize_numeric_titles",
            json!(true),
            false,
        ),
        (
            "author_note",
            "作者说明过滤",
            "排除两章合一、更新说明等作者说明式标题。",
            "",
            Value::Null,
            true,
        ),
        (
            "prose",
            "正文句子过滤",
            "使用现有标点、长度与全书编号类型判断正文句子。",
            "",
            Value::Null,
            true,
        ),
        (
            "number_corrections",
            "编号错字表",
            "按当前错字表发现需要核对的章节编号。",
            "number_corrections",
            json!("非空错字表"),
            true,
        ),
        (
            "non_heading",
            "非标题词库",
            "命中词库的行不作为标题。",
            "non_heading",
            json!("非空词库"),
            false,
        ),
        (
            "force_heading",
            "标题词库",
            "命中词库的行优先作为标题，非标题词库仍优先。",
            "force_heading",
            json!("非空词库"),
            false,
        ),
        (
            "title_suffixes",
            "标题后缀清理",
            "在标题展示中去掉配置的后缀，不改正文。",
            "title_suffixes",
            json!("非空后缀表"),
            false,
        ),
    ] {
        add(
            &format!("chapter.recognize.{id}"),
            "chapter_recognition",
            None,
            label,
            description,
            "structure",
            if key.is_empty() {
                Value::Null
            } else {
                chapter_toggle(key, on)
            },
            default,
            20,
            "automatic",
        );
    }
    for (id, label) in [
        ("duplicate_content", "整章正文重复"),
        ("prose_heading", "正文被当成标题"),
        ("unrecognized_heading", "漏识别的标题"),
        ("duplicate_title", "连续重复标题"),
        ("number_reset", "编号回退或重复"),
        ("number_gap", "编号跳跃"),
        ("no_headings", "全书未识别标题"),
        ("missing_heading_prefix", "缺少章节前缀"),
        ("heading_number_typo", "章节编号疑误"),
    ] {
        add(
            &format!("check.{id}"),
            "chapter_check",
            None,
            label,
            "列出当前有效稿中的问题，保留现有白名单与人工决定。",
            "report",
            Value::Null,
            true,
            30,
            "automatic",
        );
    }
    for (id, label) in [
        ("repeated_number", "编号重复"),
        ("number_reversal", "编号回退"),
    ] {
        add(
            &format!("check.number_reset.{id}"),
            "chapter_check",
            Some("check.number_reset"),
            label,
            "编号回退或重复的细分问题。",
            "report",
            Value::Null,
            true,
            30,
            "automatic",
        );
    }
    for (id, label, description, default) in [
        (
            "remove_invisible",
            "删除不可见字符",
            "删除现有规则列明的零宽和控制字符。",
            false,
        ),
        ("trim_trailing_spaces", "行尾空白", "清除行末空白。", true),
        (
            "collapse_blank_lines",
            "合并连续空行",
            "将相邻空行合并，保留段落间隔。",
            true,
        ),
        (
            "normalize_width",
            "全角字母与数字",
            "将全角字母、数字和空格转为半角。",
            false,
        ),
        (
            "normalize_punctuation",
            "兼容标点",
            "统一兼容字符形式的标点。",
            false,
        ),
        (
            "chinese_punctuation",
            "中文标点",
            "按中文上下文处理标点，保留数字和网址。",
            false,
        ),
        (
            "ocr_han_spaces",
            "OCR 汉字间空格",
            "去掉扫描识别产生的汉字间空格。",
            false,
        ),
        (
            "ocr_ellipsis",
            "OCR 省略号",
            "统一现有规则可确认的省略号识别痕迹。",
            false,
        ),
        (
            "join_hard_wraps",
            "合并句中换行",
            "按配置长度和中文或空格模式合并句中硬换行。",
            false,
        ),
        (
            "chinese_variant",
            "简繁转换",
            "按当前方向与字典版本转换简繁文字。",
            false,
        ),
        (
            "chapter_numbers",
            "章节编号样式",
            "按当前样式转换标题编号，可包含裸数字标题。",
            false,
        ),
        (
            "remove_duplicate_titles",
            "连续重复标题",
            "仅合并相邻且中间没有正文的相同标题。",
            false,
        ),
        (
            "site_notices",
            "网站广告与下载说明",
            "按当前关键词和保留词列出候选，需逐项确认。",
            true,
        ),
        (
            "repeated_headers",
            "重复页眉与页码",
            "列出页眉和页码候选，需逐项确认。",
            false,
        ),
        (
            "literal_replace",
            "文字替换",
            "按用户提供的查找文字与替换内容计算。",
            false,
        ),
        (
            "regex_replace",
            "逐行正则替换",
            "按用户提供的逐行正则计算。",
            false,
        ),
        (
            "multiline_regex_replace",
            "跨行正则替换",
            "按用户提供的跨行正则计算。",
            false,
        ),
    ] {
        let toggle = match id {
            "site_notices" => {
                json!({"key":"cleanup.pipeline","kinds":["remove_ad_lines","notice_lines"],"enabled_key":"enabled","wrapper_kind":"configured","on":true,"options":["include_defaults","pattern","keywords"]})
            }
            "repeated_headers" => {
                json!({"key":"cleanup.pipeline[].rule.options.include_headers","rule":"notice_lines","on":true})
            }
            _ => {
                json!({"key":"cleanup.pipeline","kind":id,"enabled_key":"enabled","wrapper_kind":"configured","on":true})
            }
        };
        add(
            &format!("cleanup.{id}"),
            "cleanup",
            None,
            label,
            description,
            "modify",
            toggle,
            default,
            10,
            "automatic",
        );
    }
    for (id, label) in [
        ("marks", "中文标点"),
        ("ellipsis", "省略号"),
        ("dashes", "破折号"),
        ("quotes", "引号"),
    ] {
        add(
            &format!("cleanup.chinese_punctuation.{id}"),
            "cleanup",
            Some("cleanup.chinese_punctuation"),
            label,
            "中文标点规则的可独立配置选项。",
            "modify",
            json!({"key":format!("cleanup.pipeline[].rule.options.{id}"),"rule":"chinese_punctuation","on":true}),
            false,
            10,
            "automatic",
        );
    }
    for (id, label, key, on, default) in [
        (
            "scene",
            "场景分隔",
            "scene_break_style",
            json!(["keep", "stars", "diamonds", "line"]),
            true,
        ),
        (
            "first_paragraph",
            "章首段落",
            "first_paragraph_style",
            json!(["no_indent", "large_initial"]),
            false,
        ),
        (
            "system",
            "系统提示",
            "system_block_style",
            json!(["box", "indent"]),
            true,
        ),
        (
            "verse",
            "诗词",
            "verse_block_style",
            json!(["center", "indent"]),
            true,
        ),
        (
            "note",
            "自动弹出注释",
            "note_style",
            json!(["popup"]),
            false,
        ),
    ] {
        add(
            &format!("layout.{id}"),
            "layout",
            None,
            label,
            "使用当前排版识别规则，只影响成品。",
            "render",
            json!({"key":key,"enabled_values":on}),
            default,
            40,
            "automatic",
        );
    }
    for c in crate::publication_documents::SCENE_SYMBOLS.chars() {
        add(
            &format!("layout.scene.u{:04x}", c as u32),
            "layout",
            Some("layout.scene"),
            &format!("分隔符 {c}"),
            "符合场景分隔整行规则且含此符号；混用符号会分别计入各细分项。",
            "render",
            Value::Null,
            true,
            40,
            "automatic",
        );
    }
    for (id, parent, label, default) in [
        ("verse.five", "verse", "五言对句", true),
        ("verse.seven", "verse", "七言对句", true),
        ("verse.attribution", "verse", "诗词署名", true),
        ("note.circled", "note", "圆圈数字注释 ①", false),
        ("note.bracket", "note", "方括号数字注释 [1]", false),
        ("note.fullwidth", "note", "全角方括号注释 ［1］", false),
        ("note.tortoise", "note", "六角括号注释 〔1〕", false),
        ("note.annotated", "note", "带注字括号注释 [注1]", false),
        ("note.definition_prefix", "note", "注字开头的注释行", false),
    ] {
        add(
            &format!("layout.{id}"),
            "layout",
            Some(&format!("layout.{parent}")),
            label,
            "沿用所属规则；当前没有独立开关。",
            "render",
            Value::Null,
            default,
            40,
            "automatic",
        );
    }
    for (id, label) in [("manual_block", "手工标注块"), ("manual_note", "手工注释")] {
        add(
            &format!("layout.{id}"),
            "layout",
            None,
            label,
            "统计当前有效的手工记录，失效记录单独计数。",
            "render",
            Value::Null,
            true,
            50,
            "manual",
        );
    }
    for (id, label) in [
        ("letter", "书信"),
        ("quote", "引文"),
        ("verse", "诗词"),
        ("system", "系统提示"),
        ("none", "取消自动标注"),
    ] {
        add(
            &format!("layout.manual_block.{id}"),
            "layout",
            Some("layout.manual_block"),
            label,
            "手工块标注优先于自动识别。",
            "render",
            Value::Null,
            true,
            50,
            "manual",
        );
    }
    for (id, label) in [("pair", "补配对"), ("new", "新写注释")] {
        add(
            &format!("layout.manual_note.{id}"),
            "layout",
            Some("layout.manual_note"),
            label,
            "手工注释不受自动识别开关控制。",
            "render",
            Value::Null,
            true,
            50,
            "manual",
        );
    }
    for (id, group, label) in [
        ("catalog_check.missing", "catalog_check", "目录缺少的章节"),
        ("catalog_check.extra", "catalog_check", "目录多出的章节"),
        ("catalog_check.title", "catalog_check", "目录标题不一致"),
        ("catalog_check.order", "catalog_check", "目录顺序不同"),
        ("preflight.title", "preflight", "书名"),
        ("preflight.language", "preflight", "书籍语言"),
        ("preflight.cover", "preflight", "封面与文字封面"),
        ("preflight.converter", "preflight", "转换器"),
        ("preflight.imported_images", "preflight", "待确认的导入图片"),
        ("manual.invalid", "manual", "失效的手工标注与注释"),
    ] {
        add(
            id,
            group,
            None,
            label,
            "按当前书稿检查；缺少检查前提时不提供计数。",
            "report",
            Value::Null,
            true,
            60,
            if id == "manual.invalid" {
                "manual"
            } else {
                "automatic"
            },
        );
    }
    for row in &mut rows {
        let id = row["id"].as_str().unwrap().to_owned();
        let locked = id == "chapter.recognize.chapter"
            || row["category"] == "manual"
            || matches!(id.as_str(), "preflight.title" | "preflight.converter");
        row["locked"] = json!(locked);
        row["locked_reason"] = if locked {
            json!(if id.starts_with("preflight.") {
                "成品生成所必需，不能关闭"
            } else if id == "chapter.recognize.chapter" {
                "基础章标题识别，不能关闭"
            } else {
                "手工记录只读统计，请在手工标注或注释中编辑"
            })
        } else {
            Value::Null
        };
        if let Some(k) = id.strip_prefix("check.") {
            row["toggle"] = json!({"key":"recognition_rules.disabled_checks","item":k});
        } else if let Some(k) = id.strip_prefix("chapter.recognize.") {
            if row["toggle"].is_null() {
                row["toggle"] = json!({"key":"recognition_rules.disabled_recognition","item":k});
            }
        } else if !locked && row["toggle"].is_null() {
            row["toggle"] = json!({"key":if id.starts_with("layout.scene.u") { "rule_options.scene_symbols" } else { "rule_options.disabled" },"item":id});
        }
        let on = match id.as_str() {
            "layout.scene" => Some("keep"),
            "layout.system" => Some("box"),
            "layout.verse" => Some("center"),
            "layout.note" => Some("popup"),
            "layout.first_paragraph" => Some("no_indent"),
            _ => None,
        };
        if let Some(on) = on {
            row["off_value"] = json!(if id == "layout.first_paragraph" {
                "normal"
            } else {
                "off"
            });
            row["on_value"] = json!(on);
        }
        if id.starts_with("layout.verse.") || id.starts_with("layout.note.") {
            row["description"] = json!("可独立关闭；所属规则关闭时，此细分不生效。");
        }
    }
    json!({"schema":2,"rules":rows})
}
