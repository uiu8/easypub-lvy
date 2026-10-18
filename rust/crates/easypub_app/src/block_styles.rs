//! 系统提示块样式（V77，LAY-132）：单行提示与多行面板各一组样式参数。
//!
//! 内置样式只是预设好的参数；V78 的样式编辑器改的也是同一组参数。CSS 由参数生成，
//! 只用边框、极浅灰底、字号、粗细与对齐，不写文字颜色，不用表格（Kindle 夜间模式与 KFX 兼容）。
//! 公开类名：`.blk`、`.blk-note`、`.blk-panel`、`.blk-has-title`、`.blk-panel-title`、`.blk-key`。
use easypub_core::{ApiError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "block_styles",
        "review_layout_settings",
    )
}

/// 一类块的样式参数。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BlockStyle {
    /// none / left / full / top_bottom
    pub border: String,
    /// single / double
    pub line: String,
    /// thin / thick
    pub weight: String,
    /// none / light / medium
    pub shade: String,
    /// start / center
    pub align: String,
    /// 字号百分比：90 / 100
    pub size: u8,
    /// 整块文字加粗
    pub bold: bool,
    /// 面板首行标题：none / shaded / underline / bold（单行提示固定为 none）
    pub title: String,
    /// “键：值”的键名加粗
    pub key_bold: bool,
    /// 成品里括号：keep / remove（原文不改）
    pub brackets: String,
    /// 与前后正文的距离：tight / medium / loose
    pub spacing: String,
}

/// 单行提示与多行面板的样式。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SystemStyles {
    pub note: BlockStyle,
    pub panel: BlockStyle,
}

fn style(v: Value) -> BlockStyle {
    serde_json::from_value(v).expect("constant block style")
}

/// “我的样式”（V78，LAY-133）：用户保存的一组参数，存在全局设置里，所有书可用。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SavedStyle {
    pub name: String,
    /// note / panel
    pub kind: String,
    pub style: BlockStyle,
}

/// 校验“我的样式”：最多 60 条；名称 1–24 字、同类不重名；参数合法。
pub fn validate_library(items: &[SavedStyle]) -> Result<(), ApiError> {
    if items.len() > 60 {
        return Err(invalid());
    }
    let mut seen = std::collections::BTreeSet::new();
    for item in items {
        let n = item.name.trim().chars().count();
        if n == 0
            || n > 24
            || item.name.contains(['\r', '\n', '\0'])
            || !matches!(item.kind.as_str(), "note" | "panel")
            || !seen.insert((item.kind.clone(), item.name.trim().to_owned()))
        {
            return Err(invalid());
        }
        item.style.validate(item.kind == "panel")?;
    }
    Ok(())
}

/// 内置预设：(编号, 名称, 适用的类, 参数)。
pub fn presets() -> Vec<(&'static str, &'static str, &'static str, BlockStyle)> {
    vec![
        (
            "bar",
            "提示条",
            "note",
            style(
                json!({"border":"left","line":"single","weight":"thick","shade":"light","align":"start","size":90,"bold":false,"title":"none","key_bold":false,"brackets":"keep","spacing":"medium"}),
            ),
        ),
        (
            "center",
            "居中强调",
            "note",
            style(
                json!({"border":"none","line":"single","weight":"thin","shade":"none","align":"center","size":90,"bold":true,"title":"none","key_bold":false,"brackets":"keep","spacing":"medium"}),
            ),
        ),
        (
            "titled",
            "标题面板",
            "panel",
            style(
                json!({"border":"full","line":"single","weight":"thin","shade":"none","align":"start","size":90,"bold":false,"title":"shaded","key_bold":true,"brackets":"remove","spacing":"medium"}),
            ),
        ),
        (
            "rules",
            "上下双线",
            "panel",
            style(
                json!({"border":"top_bottom","line":"double","weight":"thick","shade":"none","align":"start","size":90,"bold":false,"title":"none","key_bold":false,"brackets":"keep","spacing":"medium"}),
            ),
        ),
    ]
}

pub fn preset(id: &str) -> Option<BlockStyle> {
    presets().into_iter().find(|p| p.0 == id).map(|p| p.3)
}

/// 新书的默认：单行“提示条”，面板“标题面板”。
pub fn default_styles() -> SystemStyles {
    SystemStyles {
        note: preset("bar").expect("bar"),
        panel: preset("titled").expect("titled"),
    }
}

impl BlockStyle {
    pub fn validate(&self, panel: bool) -> Result<(), ApiError> {
        let ok = matches!(
            self.border.as_str(),
            "none" | "left" | "full" | "top_bottom"
        ) && matches!(self.line.as_str(), "single" | "double")
            && matches!(self.weight.as_str(), "thin" | "thick")
            && matches!(self.shade.as_str(), "none" | "light" | "medium")
            && matches!(self.align.as_str(), "start" | "center")
            && matches!(self.size, 90 | 100)
            && matches!(
                self.title.as_str(),
                "none" | "shaded" | "underline" | "bold"
            )
            && (panel || self.title == "none")
            && matches!(self.brackets.as_str(), "keep" | "remove")
            && matches!(self.spacing.as_str(), "tight" | "medium" | "loose");
        if ok { Ok(()) } else { Err(invalid()) }
    }

    fn css(&self, class: &str) -> String {
        let width = if self.line == "double" || self.weight == "thick" {
            3
        } else {
            1
        };
        let rule = format!(
            "{width}px {}",
            if self.line == "double" {
                "double"
            } else {
                "solid"
            }
        );
        let border = match self.border.as_str() {
            "left" => format!("border: 0; border-left: {rule};"),
            "full" => format!("border: {rule};"),
            "top_bottom" => format!("border: 0; border-top: {rule}; border-bottom: {rule};"),
            _ => "border: 0;".into(),
        };
        let boxed = self.border != "none" || self.shade != "none";
        let shade = match self.shade.as_str() {
            "light" => " background-color: #ececec;",
            "medium" => " background-color: #dcdcdc;",
            _ => "",
        };
        let margin = match self.spacing.as_str() {
            "tight" => "0.4em",
            "loose" => "1.2em",
            _ => "0.8em",
        };
        let pad = if boxed { "0.3em 0" } else { "0" };
        let mut css = format!(
            ".{class} {{ margin: {margin} 0; padding: {pad}; {border}{shade} font-size: {}%;{}{} }}\n",
            self.size,
            if self.align == "center" {
                " text-align: center;"
            } else {
                ""
            },
            if self.bold { " font-weight: bold;" } else { "" },
        );
        let side = if boxed { "0.6em" } else { "0" };
        css.push_str(&format!(
            ".{class} .system-line {{ margin: 0; padding: 0 {side}; text-indent: 0; }}\n"
        ));
        match self.title.as_str() {
            "shaded" => css.push_str(&format!(
                ".{class}.blk-has-title {{ padding-top: 0; }}\n.{class} .blk-panel-title {{ font-weight: bold; background-color: #e4e4e4; padding: 0.15em {side}; margin-bottom: 0.2em;{} }}\n",
                if self.border == "full" { format!(" border-bottom: {rule};") } else { String::new() }
            )),
            "underline" => css.push_str(&format!(
                ".{class} .blk-panel-title {{ font-weight: bold; border-bottom: 1px solid; margin-bottom: 0.2em; }}\n"
            )),
            "bold" => css.push_str(&format!(".{class} .blk-panel-title {{ font-weight: bold; }}\n")),
            _ => {}
        }
        if self.key_bold {
            css.push_str(&format!(".{class} .blk-key {{ font-weight: bold; }}\n"));
        }
        css
    }
}

impl SystemStyles {
    pub fn validate(&self) -> Result<(), ApiError> {
        self.note.validate(false)?;
        self.panel.validate(true)
    }
    pub fn css(&self) -> String {
        let mut css = self.note.css("blk-note");
        css.push_str(&self.panel.css("blk-panel"));
        css
    }
}

/// 单独一行的“叮！”“叮~”“叮咚！”：分类样式下并入紧跟的系统提示。
pub fn is_ding_line(line: &str) -> bool {
    let t = line.trim();
    let rest = t.strip_prefix("叮咚").or_else(|| t.strip_prefix('叮'));
    rest.is_some_and(|r| r.chars().count() <= 2 && r.chars().all(|c| "！!～~，,。…".contains(c)))
}

/// 成品里去掉整行外层的【】（多段时换成全角空格）；不是整行【】时原样返回。
pub fn strip_brackets(inner: &str) -> String {
    let t = inner.trim();
    match t.strip_prefix('【').and_then(|s| s.strip_suffix('】')) {
        Some(body) => {
            let mut out = String::new();
            for (i, part) in body.split('】').enumerate() {
                let part = part.trim_start().trim_start_matches('【');
                if i > 0 {
                    out.push('　');
                }
                out.push_str(part);
            }
            out
        }
        None => inner.to_owned(),
    }
}

/// “键：值”的键名包进 `.blk-key`：冒号在前 12 个字以内、键名里没有标签与标点。
pub fn mark_key(inner: &str) -> String {
    let Some((pos, sep)) = inner
        .char_indices()
        .take(13)
        .find(|(_, c)| matches!(c, '：' | ':'))
    else {
        return inner.to_owned();
    };
    let key = &inner[..pos];
    if key.is_empty()
        || key.contains(['<', '>', '&', '，', '。', '！', '？', '“', '”'])
        || key.trim().is_empty()
    {
        return inner.to_owned();
    }
    format!(
        "<span class=\"blk-key\">{key}</span>{}",
        &inner[pos..pos + sep.len_utf8()]
    ) + &inner[pos + sep.len_utf8()..]
}

/// 面板首行能否作标题：短（不超过 16 字）且不含冒号。
pub fn is_title(text: &str) -> bool {
    let t = strip_brackets(text);
    t.chars().count() <= 16 && !t.contains(['：', ':'])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn presets_validate_css_and_helpers() {
        let all = default_styles();
        all.validate().unwrap();
        for (id, _, kind, s) in presets() {
            s.validate(kind == "panel")
                .unwrap_or_else(|_| panic!("{id}"));
        }
        let css = all.css();
        assert!(css.contains(".blk-note { margin: 0.8em 0; padding: 0.3em 0; border: 0; border-left: 3px solid; background-color: #ececec; font-size: 90%;"));
        assert!(css.contains(
            ".blk-panel { margin: 0.8em 0; padding: 0.3em 0; border: 1px solid; font-size: 90%;"
        ));
        assert!(css.contains(
            ".blk-panel .blk-panel-title { font-weight: bold; background-color: #e4e4e4;"
        ));
        assert!(css.contains(".blk-panel .blk-key { font-weight: bold; }"));
        assert!(
            !css.contains(" color:") && !css.contains(";color:"),
            "不写文字颜色"
        );
        let rules = preset("rules").unwrap().css("blk-panel");
        assert!(rules.contains("border-top: 3px double; border-bottom: 3px double;"));
        let center = preset("center").unwrap().css("blk-note");
        assert!(center.contains("text-align: center; font-weight: bold;"));
        // 单行提示不能有标题；未知值拒绝。
        let mut bad = preset("bar").unwrap();
        bad.title = "shaded".into();
        assert!(bad.validate(false).is_err());
        bad.title = "none".into();
        bad.size = 80;
        assert!(bad.validate(false).is_err());

        for yes in ["叮！", "叮~", "叮咚！", " 叮 ", "叮……"] {
            assert!(is_ding_line(yes), "{yes}");
        }
        for no in ["叮，一声脆响传来", "叮咚叮咚叮叮咚……", "叮叮当当", ""] {
            assert!(!is_ding_line(no), "{no}");
        }
        assert_eq!(
            strip_brackets("【力量：10】 【敏捷：8】"),
            "力量：10　敏捷：8"
        );
        assert_eq!(strip_brackets("【苍白的正义】"), "苍白的正义");
        assert_eq!(strip_brackets("叮！"), "叮！");
        assert_eq!(
            mark_key("攻击力：20-25"),
            "<span class=\"blk-key\">攻击力</span>：20-25"
        );
        assert_eq!(
            mark_key("他说：好"),
            "<span class=\"blk-key\">他说</span>：好"
        );
        assert_eq!(
            mark_key("这是一句很长很长很长很长的话：后面"),
            "这是一句很长很长很长很长的话：后面"
        );
        assert_eq!(mark_key("<ruby>龘</ruby>：x"), "<ruby>龘</ruby>：x");
        let saved = SavedStyle {
            name: "我的提示".into(),
            kind: "note".into(),
            style: preset("center").unwrap(),
        };
        validate_library(std::slice::from_ref(&saved)).unwrap();
        assert!(
            validate_library(&[saved.clone(), saved.clone()]).is_err(),
            "同类重名"
        );
        let mut panel_title = saved.clone();
        panel_title.style.title = "shaded".into();
        assert!(
            validate_library(&[panel_title]).is_err(),
            "单行提示不能有标题"
        );
        let mut blank = saved;
        blank.name = " ".into();
        assert!(validate_library(&[blank]).is_err());
        assert!(is_title("【苍白的正义】"));
        assert!(!is_title("【攻击力：20-25】"));
        assert!(!is_title("【这是一行超过十六个字的很长很长的说明文字】"));
    }
}
