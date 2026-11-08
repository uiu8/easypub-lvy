//! 场景样式参数（V82，LAY-136）：每种场景一组参数，内置预设就是参数；V82 的编辑器改的也是这组参数。
//!
//! CSS 由参数生成，只用线条、浅灰底色、字号、字距、对齐与字体；文字块的背景图只有“淡纸纹”
//! （平均亮度约 245，Kindle 深色模式实测会随页面反转）。背景放在内层、边框放在外层，
//! 避开 KFX 里同一元素有背景图时边框消失。各场景特有的部分（聊天名字与时间、动态转评赞、
//! 论坛楼层、日记日期、剪报报头等）保持固定写法。
use easypub_core::{ApiError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeMap;

fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "inset_styles",
        "review_layout_settings",
    )
}

/// 一种场景的样式参数。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InsetStyle {
    /// none / left / top_bottom / full / frame（外粗内细的双框，古籍“文武边栏”）
    pub border: String,
    /// solid / double / dashed
    pub line: String,
    /// thin（1px）/ thick（2px）/ heavy（5px）；双线固定 3px
    pub weight: String,
    /// square / round（只对四周边框生效）
    pub corner: String,
    /// none / light / medium / paper（淡纸纹）
    pub shade: String,
    /// 首行标题：plain / bold / spaced（居中拉开字距）/ underline（居中加下划线）/ big（居中大字）
    pub head: String,
    /// 标题两侧饰纹：none / diamond（◆）/ mark（※）/ lenticular（〖〗）
    pub ornament: String,
    /// 正文对齐：start / center
    pub align: String,
    /// 字号百分比：85 / 90 / 100
    pub size: u8,
    /// 正文首行缩进两字
    pub indent: bool,
    /// 第一行正文首字放大
    pub drop: bool,
    /// body / kai / mono
    pub font: String,
    /// 上下加卷轴杆
    pub rods: bool,
    /// 聊天名字的位置：block（发言上方小字）/ center（居中，剧本）/ inline（同一行“名字 ▷”）
    pub names: String,
}

fn style(v: Value) -> InsetStyle {
    serde_json::from_value(v).expect("constant inset style")
}

fn base() -> Value {
    json!({"border":"none","line":"solid","weight":"thin","corner":"square","shade":"none","head":"plain",
           "ornament":"none","align":"start","size":100,"indent":true,"drop":false,"font":"body","rods":false,"names":"block"})
}

fn with(changes: Value) -> InsetStyle {
    let mut v = base();
    for (k, x) in changes.as_object().expect("object") {
        v[k] = x.clone();
    }
    style(v)
}

/// 内置预设：(编号, 名称, 场景, 参数)。每种场景第一个是默认。
pub fn presets() -> Vec<(&'static str, &'static str, &'static str, InsetStyle)> {
    vec![
        (
            "window",
            "群聊窗口",
            "chat",
            with(json!({"border":"full","head":"spaced","indent":false,"names":"block"})),
        ),
        (
            "script",
            "剧本对白",
            "chat",
            with(json!({"head":"bold","indent":false,"names":"center"})),
        ),
        (
            "channel",
            "通讯频道",
            "chat",
            with(
                json!({"border":"top_bottom","line":"dashed","size":85,"indent":false,"font":"mono","names":"inline"}),
            ),
        ),
        (
            "card",
            "动态卡片",
            "post",
            with(json!({"border":"full","corner":"round","head":"bold","indent":false})),
        ),
        ("floors", "楼层", "forum", with(json!({"indent":false}))),
        (
            "notebook",
            "日记本",
            "diary",
            with(json!({"border":"left","line":"double"})),
        ),
        (
            "frame",
            "文武边栏",
            "classic",
            with(
                json!({"border":"frame","weight":"thick","head":"underline","ornament":"diamond","font":"kai"}),
            ),
        ),
        (
            "bars",
            "上下粗杆",
            "edict",
            with(json!({"border":"top_bottom","weight":"heavy","head":"spaced","font":"kai"})),
        ),
        (
            "parchment",
            "羊皮纸卷",
            "scroll",
            with(
                json!({"border":"full","line":"double","shade":"paper","head":"spaced","ornament":"mark","drop":true,"rods":true}),
            ),
        ),
        (
            "poster",
            "告示",
            "notice",
            with(
                json!({"border":"full","weight":"thick","head":"big","align":"center","indent":false}),
            ),
        ),
        ("clipping", "剪报", "news", with(json!({"border":"full"}))),
    ]
}

pub fn preset(id: &str) -> Option<InsetStyle> {
    presets().into_iter().find(|p| p.0 == id).map(|p| p.3)
}

/// 场景的默认样式；聊天按“聊天记录”设置选的样式（不识别时为群聊窗口）。
pub fn default_for(scene: &str, chat_look: &str) -> InsetStyle {
    if scene == "chat" {
        return preset(if chat_look == "off" {
            "window"
        } else {
            chat_look
        })
        .expect("chat preset");
    }
    presets()
        .into_iter()
        .find(|p| p.2 == scene)
        .map(|p| p.3)
        .expect("scene preset")
}

/// 本书某场景实际使用的样式：改过的优先，否则内置默认。
pub fn effective(
    styles: Option<&BTreeMap<String, InsetStyle>>,
    scene: &str,
    chat_look: &str,
) -> InsetStyle {
    styles
        .and_then(|s| s.get(scene))
        .cloned()
        .unwrap_or_else(|| default_for(scene, chat_look))
}

impl InsetStyle {
    pub fn validate(&self) -> Result<(), ApiError> {
        let ok = matches!(
            self.border.as_str(),
            "none" | "left" | "top_bottom" | "full" | "frame"
        ) && matches!(self.line.as_str(), "solid" | "double" | "dashed")
            && matches!(self.weight.as_str(), "thin" | "thick" | "heavy")
            && matches!(self.corner.as_str(), "square" | "round")
            && matches!(self.shade.as_str(), "none" | "light" | "medium" | "paper")
            && matches!(
                self.head.as_str(),
                "plain" | "bold" | "spaced" | "underline" | "big"
            )
            && matches!(
                self.ornament.as_str(),
                "none" | "diamond" | "mark" | "lenticular"
            )
            && matches!(self.align.as_str(), "start" | "center")
            && matches!(self.size, 85 | 90 | 100)
            && matches!(self.font.as_str(), "body" | "kai" | "mono")
            && matches!(self.names.as_str(), "block" | "center" | "inline");
        if ok { Ok(()) } else { Err(invalid()) }
    }

    /// 标题两侧的饰纹字符。
    pub fn ornament_char(&self) -> Option<&'static str> {
        match self.ornament.as_str() {
            "diamond" => Some("◆"),
            "mark" => Some("※"),
            "lenticular" => Some("〖"),
            _ => None,
        }
    }
    pub fn ornament_close(&self) -> Option<&'static str> {
        match self.ornament.as_str() {
            "diamond" => Some("◆"),
            "mark" => Some("※"),
            "lenticular" => Some("〗"),
            _ => None,
        }
    }

    /// 本场景的框线、底色、标题、正文与字体规则。`paper` 为淡纸纹资源编号；`kai` 为假时楷体退回正文字体。
    fn css(&self, scene: &str, paper: Option<&str>, kai: bool) -> String {
        let c = format!(".inset-{scene}");
        let width = if self.line == "double" {
            "3px"
        } else {
            match self.weight.as_str() {
                "thick" => "2px",
                "heavy" => "5px",
                _ => "1px",
            }
        };
        let rule = format!("{width} {}", self.line);
        let mut css = String::new();
        let (outer, inner_border) = match self.border.as_str() {
            "left" => (format!("border-left: {rule}; padding-left: 0.8em;"), ""),
            "top_bottom" => (format!("border-top: {rule}; border-bottom: {rule};"), ""),
            "full" => (
                format!(
                    "border: {rule};{}",
                    if self.corner == "round" {
                        " border-radius: 0.4em;"
                    } else {
                        ""
                    }
                ),
                "",
            ),
            "frame" => (
                format!("border: {rule}; padding: 2px;"),
                " border: 1px solid;",
            ),
            _ => (String::new(), ""),
        };
        let size = if self.size == 100 {
            String::new()
        } else {
            format!(" font-size: {}%;", self.size)
        };
        let font = match self.font.as_str() {
            "kai" if kai => " font-family: \"STKai\", \"楷体\", KaiTi, serif;",
            "mono" => " font-family: monospace;",
            _ => "",
        };
        css.push_str(&format!("{c} {{ {outer}{size}{font} }}\n"));
        let boxed =
            matches!(self.border.as_str(), "full" | "frame" | "top_bottom") || self.shade != "none";
        let shade = match self.shade.as_str() {
            "light" => " background-color: #ececec;".to_owned(),
            "medium" => " background-color: #dcdcdc;".to_owned(),
            "paper" => paper
                .map(|id| format!(" background-image: url(\"{id}\");"))
                .unwrap_or_default(),
            _ => String::new(),
        };
        let pad = if boxed {
            if self.border == "top_bottom" {
                "0.4em 0.6em"
            } else {
                "0.4em 0.9em"
            }
        } else {
            "0"
        };
        css.push_str(&format!(
            "{c} .inset-inner {{ padding: {pad};{inner_border}{shade} }}\n"
        ));
        let head = match self.head.as_str() {
            "bold" => "font-weight: bold;",
            "spaced" => "text-align: center; letter-spacing: 0.3em;",
            "underline" => {
                "text-align: center; letter-spacing: 0.3em; border-bottom: 1px solid; margin-bottom: 0.3em;"
            }
            "big" => {
                "text-align: center; letter-spacing: 0.6em; font-weight: bold; font-size: 1.6em;"
            }
            _ => "",
        };
        if !head.is_empty() {
            css.push_str(&format!("{c} .inset-head {{ {head} }}\n"));
        }
        if self.align == "center" {
            css.push_str(&format!("{c} .inset-body {{ text-align: center; }}\n"));
        }
        if !self.indent || self.align == "center" {
            css.push_str(&format!("{c} .inset-body {{ text-indent: 0; }}\n"));
        }
        css
    }
}

/// “我的场景样式”（V82，LAY-136）：存在全局设置里，所有书可用。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SavedInset {
    pub name: String,
    pub scene: String,
    pub style: InsetStyle,
}

/// 校验“我的场景样式”：最多 60 条；名称 1–24 字、同场景不重名；参数合法。
pub fn validate_library(items: &[SavedInset]) -> Result<(), ApiError> {
    if items.len() > 60 {
        return Err(invalid());
    }
    let mut seen = std::collections::BTreeSet::new();
    for item in items {
        let n = item.name.trim().chars().count();
        if n == 0
            || n > 24
            || item.name.contains(['\r', '\n', '\0'])
            || !crate::insets::is_type(&item.scene)
            || !seen.insert((item.scene.clone(), item.name.trim().to_owned()))
        {
            return Err(invalid());
        }
        item.style.validate()?;
    }
    Ok(())
}

/// 本书改过的场景样式：键必须是场景编号，参数合法。
pub fn validate_book(styles: &BTreeMap<String, InsetStyle>) -> Result<(), ApiError> {
    for (scene, style) in styles {
        if !crate::insets::is_type(scene) {
            return Err(invalid());
        }
        style.validate()?;
    }
    Ok(())
}

/// 全部场景的样式表：通用规则、各场景特有的固定规则，再加每个场景按参数生成的规则。
pub fn css(
    styles: Option<&BTreeMap<String, InsetStyle>>,
    chat_look: &str,
    paper: Option<&str>,
    kai: bool,
) -> String {
    let mut css = String::from(
        "/* 场景样式（V81、V82） */\n\
.inset { margin: 0.8em 0; }\n\
.inset .inset-line { text-indent: 0; margin: 0; }\n\
.inset .inset-body { text-indent: 2em; }\n\
.inset .inset-head { text-indent: 0; }\n\
.inset .inset-end { text-align: right; }\n\
.inset-drop { font-size: 1.8em; font-weight: bold; line-height: 1; }\n\
.inset-rod { text-indent: 0; margin: 0; text-align: center; }\n\
.inset-rod img { width: 100%; }\n\
.inset-chat .inset-time { font-size: 0.75em; text-align: center; }\n\
.inset-names-block .inset-who { font-size: 0.8em; font-weight: bold; text-indent: 0; margin: 0.3em 0 0; }\n\
.inset-names-block .inset-say { margin: 0 0 0.3em 1em; }\n\
.inset-names-center .inset-who { text-align: center; letter-spacing: 0.4em; font-weight: bold; text-indent: 0; margin: 0.5em 0 0; }\n\
.inset-names-center .inset-say { margin: 0 3em; }\n\
.inset-names-inline .inset-who { font-weight: bold; }\n\
.inset-post .inset-count { font-size: 0.75em; border-top: 1px solid; letter-spacing: 0.1em; }\n\
.inset-post .inset-reply { font-size: 0.8em; border-left: 2px solid; padding-left: 0.5em; margin-top: 0.2em; }\n\
.inset-forum .inset-floor { font-size: 0.8em; font-weight: bold; border-bottom: 1px solid; margin-top: 0.4em; }\n\
.inset-forum .inset-body { margin-bottom: 0.3em; }\n\
.inset-diary .inset-date { font-size: 0.8em; font-weight: bold; letter-spacing: 0.1em; }\n\
.inset-edict .inset-end { letter-spacing: 0.4em; font-weight: bold; }\n\
.inset-notice .inset-end { font-size: 0.8em; }\n\
.inset-news .inset-mast { text-align: center; letter-spacing: 0.3em; border-bottom: 3px double; }\n\
.inset-news .inset-headline { font-weight: bold; font-size: 1.1em; margin-top: 0.3em; }\n\
.inset-news .inset-by { font-size: 0.75em; }\n\
.letter-ruled .letter-line, .letter-ruled .letter-by { border-bottom: 1px dotted; line-height: 1.9; }\n",
    );
    if kai {
        css.push_str(".letter-ruled { font-family: \"STKai\", \"楷体\", KaiTi, serif; }\n");
    }
    for (scene, _) in crate::insets::TYPES {
        css.push_str(&effective(styles, scene, chat_look).css(scene, paper, kai));
    }
    css
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn presets_validate_css_and_library() {
        for (id, _, scene, s) in presets() {
            s.validate().unwrap_or_else(|_| panic!("{id}"));
            assert!(crate::insets::is_type(scene));
        }
        for (scene, _) in crate::insets::TYPES {
            default_for(scene, "off").validate().unwrap();
        }
        assert_eq!(default_for("chat", "channel").names, "inline");
        let all = css(None, "window", Some("p.png"), true);
        assert!(all.contains(".inset-classic { border: 2px solid; padding: 2px; font-family: \"STKai\", \"楷体\", KaiTi, serif; }"));
        assert!(
            all.contains(
                ".inset-classic .inset-inner { padding: 0.4em 0.9em; border: 1px solid; }"
            )
        );
        assert!(all.contains(
            ".inset-scroll .inset-inner { padding: 0.4em 0.9em; background-image: url(\"p.png\"); }"
        ));
        assert!(all.contains(".inset-edict { border-top: 5px solid; border-bottom: 5px solid;"));
        assert!(all.contains(".inset-post { border: 1px solid; border-radius: 0.4em; }"));
        assert!(all.contains(".inset-notice .inset-head { text-align: center; letter-spacing: 0.6em; font-weight: bold; font-size: 1.6em; }"));
        assert!(all.contains(".inset-diary { border-left: 3px double; padding-left: 0.8em; }"));
        assert!(!all.contains(" color:"), "不写文字颜色");
        let body = css(None, "window", None, false);
        assert!(!body.contains("STKai") && !body.contains("background-image"));
        // 本书改过的样式优先。
        let mut mine = BTreeMap::new();
        let mut s = default_for("classic", "off");
        s.border = "left".into();
        s.shade = "light".into();
        mine.insert("classic".to_owned(), s.clone());
        let custom = css(Some(&mine), "window", None, true);
        assert!(custom.contains(".inset-classic { border-left: 2px solid; padding-left: 0.8em;"));
        assert!(custom.contains(
            ".inset-classic .inset-inner { padding: 0.4em 0.9em; background-color: #ececec; }"
        ));
        validate_book(&mine).unwrap();
        mine.insert("nope".into(), s.clone());
        assert!(validate_book(&mine).is_err());
        let mut bad = s.clone();
        bad.size = 80;
        assert!(bad.validate().is_err());
        let saved = SavedInset {
            name: "我的古籍".into(),
            scene: "classic".into(),
            style: s,
        };
        validate_library(std::slice::from_ref(&saved)).unwrap();
        assert!(
            validate_library(&[saved.clone(), saved.clone()]).is_err(),
            "同场景重名"
        );
        let mut other = saved.clone();
        other.scene = "edict".into();
        validate_library(&[saved.clone(), other]).unwrap();
        let mut wrong = saved;
        wrong.scene = "letter".into();
        assert!(validate_library(&[wrong]).is_err());
    }
}
