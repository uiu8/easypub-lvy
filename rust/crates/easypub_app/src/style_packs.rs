//! 章节样式包（V74，LAY-130）：章头图（按章轮换）、标题下装饰线、章末装饰、卷页边框、封面背景。
//!
//! 书里只记图片的绝对路径（与章首图相同）；样式包文件放在调用方给的目录里：
//! * 内置样式包由程序画的 SVG 栅格化为 PNG；
//! * 导入的 `.zip` 含 `style.json` 与图片，按内容哈希解到独立子目录，不覆盖已有文件；
//! * 导出把当前书的样式与图片写成同样格式的 `.zip`。
use easypub_core::{ApiError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
};

pub const VOLUME_FRAMES: [&str; 3] = ["none", "single", "double"];
const MAX_HEAD_IMAGES: usize = 12;
const MAX_ZIP_BYTES: u64 = 64 * 1024 * 1024;
const MAX_IMAGE_BYTES: u64 = 16 * 1024 * 1024;

fn invalid() -> ApiError {
    ApiError::new(ErrorCode::InvalidRule, "chapter_style", "review_style_pack")
}
fn io() -> ApiError {
    ApiError::new(
        ErrorCode::OutputConflict,
        "chapter_style",
        "choose_new_writable_path",
    )
}

fn default_frame() -> String {
    "none".into()
}

/// 一本书使用的章节样式。图片都是绝对路径。
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ChapterStyle {
    pub name: String,
    #[serde(default)]
    pub head_images: Vec<String>,
    #[serde(default)]
    pub title_rule: Option<String>,
    #[serde(default)]
    pub chapter_end: Option<String>,
    #[serde(default = "default_frame")]
    pub volume_frame: String,
    #[serde(default)]
    pub cover_background: Option<String>,
}

impl ChapterStyle {
    pub fn validate(
        &self,
        image_path: impl Fn(&str) -> Result<(), ApiError>,
    ) -> Result<(), ApiError> {
        if self.name.trim().is_empty()
            || self.name.chars().count() > 64
            || self.name.contains(['\r', '\n', '\0'])
            || self.head_images.len() > MAX_HEAD_IMAGES
            || !VOLUME_FRAMES.contains(&self.volume_frame.as_str())
        {
            return Err(invalid());
        }
        for path in self.paths() {
            image_path(path)?;
        }
        Ok(())
    }
    pub fn paths(&self) -> impl Iterator<Item = &String> {
        self.head_images
            .iter()
            .chain(self.title_rule.iter())
            .chain(self.chapter_end.iter())
            .chain(self.cover_background.iter())
    }
}

/// 成品里使用的样式资源 ID（V74）。
#[derive(Clone, Debug, Serialize)]
pub struct StyleIds {
    pub head_ids: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title_rule_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chapter_end_id: Option<String>,
    pub volume_frame: String,
}

/// 样式包文件里的 `style.json`：图片用包内文件名。
#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PackFile {
    schema_version: u32,
    name: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    author: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    head_images: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    title_rule: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    chapter_end: Option<String>,
    #[serde(default = "default_frame")]
    volume_frame: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cover_background: Option<String>,
    /// 系统提示块样式（V78，LAY-133）：应用样式包时一并套用。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    blocks: Option<crate::block_styles::SystemStyles>,
    /// 场景样式（V82，LAY-136）：应用样式包时一并套用。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    insets: Option<PackInsets>,
}

/// 样式包里的场景样式：聊天记录样式、书信样式与改过的各场景参数。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PackInsets {
    pub chat_block_style: String,
    pub letter_block_style: String,
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub styles: std::collections::BTreeMap<String, crate::inset_styles::InsetStyle>,
}

impl PackInsets {
    fn validate(&self) -> Result<(), ApiError> {
        if !crate::insets::CHAT_BLOCK_STYLES.contains(&self.chat_block_style.as_str())
            || !crate::insets::LETTER_BLOCK_STYLES.contains(&self.letter_block_style.as_str())
        {
            return Err(invalid());
        }
        crate::inset_styles::validate_book(&self.styles)
    }
}

/// 包内图片文件名：只允许一层的字母数字文件名与常见图片扩展名。
fn member_name(name: &str) -> Result<&str, ApiError> {
    let ok = !name.is_empty()
        && name.len() <= 64
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
        && !name.starts_with('.')
        && matches!(
            name.rsplit_once('.')
                .map(|(_, e)| e.to_ascii_lowercase())
                .as_deref(),
            Some("png" | "jpg" | "jpeg")
        );
    if ok { Ok(name) } else { Err(invalid()) }
}

const BUILTIN: [(&str, &str); 2] = [("plain", "素雅"), ("classic", "古典")];

/// 内置样式包的 SVG（程序画的线条与几何装饰，不含外部素材）。
fn builtin_svgs(id: &str) -> Option<Vec<(&'static str, String, &'static str)>> {
    let (ink, soft) = match id {
        "plain" => ("#6f6a63", "#b7aa94"),
        "classic" => ("#8a5a3c", "#c9a98c"),
        _ => return None,
    };
    let rule = match id {
        "plain" => format!(
            r#"<svg xmlns="http://www.w3.org/2000/svg" width="400" height="24" viewBox="0 0 400 24"><line x1="40" y1="12" x2="360" y2="12" stroke="{ink}" stroke-width="2"/><rect x="194" y="6" width="12" height="12" transform="rotate(45 200 12)" fill="{ink}"/></svg>"#
        ),
        _ => format!(
            r#"<svg xmlns="http://www.w3.org/2000/svg" width="400" height="28" viewBox="0 0 400 28"><line x1="30" y1="10" x2="370" y2="10" stroke="{ink}" stroke-width="2"/><line x1="30" y1="17" x2="370" y2="17" stroke="{ink}" stroke-width="4"/><circle cx="200" cy="14" r="8" fill="white" stroke="{ink}" stroke-width="3"/></svg>"#
        ),
    };
    let end = match id {
        "plain" => format!(
            r#"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="30" viewBox="0 0 120 30"><circle cx="38" cy="15" r="5" fill="{ink}"/><circle cx="60" cy="15" r="7" fill="{ink}"/><circle cx="82" cy="15" r="5" fill="{ink}"/></svg>"#
        ),
        _ => format!(
            r#"<svg xmlns="http://www.w3.org/2000/svg" width="160" height="40" viewBox="0 0 160 40"><path d="M10 20 H62 M98 20 H150" stroke="{ink}" stroke-width="2"/><rect x="68" y="8" width="24" height="24" transform="rotate(45 80 20)" fill="none" stroke="{ink}" stroke-width="3"/><circle cx="80" cy="20" r="4" fill="{ink}"/></svg>"#
        ),
    };
    let head = |a: f32| {
        format!(
            r#"<svg xmlns="http://www.w3.org/2000/svg" width="600" height="140" viewBox="0 0 600 140"><path d="M40 110 Q{p} 30 300 90 T560 70" fill="none" stroke="{soft}" stroke-width="3"/><path d="M80 120 Q{q} 70 360 106 T540 100" fill="none" stroke="{soft}" stroke-width="2" opacity="0.7"/><circle cx="300" cy="90" r="6" fill="{ink}"/></svg>"#,
            p = 120.0 + a,
            q = 200.0 - a
        )
    };
    // 封面背景：远山、波纹与圆月，上半部留白放书名（文字封面在上面加浅底与深色文字）。
    let (sky, hill, far) = match id {
        "plain" => ("#ece7dc", "#b9b0a0", "#d3ccbe"),
        _ => ("#efe4d0", "#b48c6a", "#d6bea2"),
    };
    let cover = format!(
        r#"<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="1600" viewBox="0 0 1200 1600"><rect width="1200" height="1600" fill="{sky}"/><circle cx="930" cy="330" r="110" fill="white" opacity="0.8"/><path d="M0 1120 Q300 960 600 1090 T1200 1010 V1600 H0Z" fill="{far}"/><path d="M0 1300 Q400 1150 800 1290 T1200 1250 V1600 H0Z" fill="{hill}"/><path d="M80 1480 Q360 1430 640 1470 T1120 1460" fill="none" stroke="{ink}" stroke-width="4" opacity="0.5"/></svg>"#
    );
    Some(vec![
        ("cover-background.png", cover, "cover"),
        ("chapter-head-01.png", head(0.0), "head"),
        ("chapter-head-02.png", head(60.0), "head"),
        ("title-rule.png", rule, "title_rule"),
        ("chapter-end.png", end, "chapter_end"),
    ])
}

fn write_new(path: &Path, bytes: &[u8]) -> Result<(), ApiError> {
    if path.exists() {
        // 同名文件内容相同就复用，不同就拒绝（目录按内容哈希命名，正常不会发生）。
        return if fs::read(path).map_err(|_| io())? == bytes {
            Ok(())
        } else {
            Err(io())
        };
    }
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|_| io())?;
    file.write_all(bytes).map_err(|_| io())?;
    file.sync_all().map_err(|_| io())
}

fn path_string(path: PathBuf) -> Result<String, ApiError> {
    path.into_os_string().into_string().map_err(|_| io())
}

/// 内置样式包配套的块样式：素雅配提示条与标题面板，古典配居中强调与上下双线。
fn builtin_blocks(id: &str) -> crate::block_styles::SystemStyles {
    let (note, panel) = if id == "classic" {
        ("center", "rules")
    } else {
        ("bar", "titled")
    };
    crate::block_styles::SystemStyles {
        note: crate::block_styles::preset(note).expect("note"),
        panel: crate::block_styles::preset(panel).expect("panel"),
    }
}

fn builtin(id: &str, dir: &Path) -> Result<ChapterStyle, ApiError> {
    let svgs = builtin_svgs(id).ok_or_else(invalid)?;
    let name = BUILTIN
        .iter()
        .find(|(k, _)| *k == id)
        .ok_or_else(invalid)?
        .1;
    let target = dir.join(format!("builtin-{id}-v1"));
    fs::create_dir_all(&target).map_err(|_| io())?;
    let mut style = ChapterStyle {
        name: name.into(),
        head_images: Vec::new(),
        title_rule: None,
        chapter_end: None,
        volume_frame: if id == "classic" { "double" } else { "single" }.into(),
        cover_background: None,
    };
    for (file, svg, role) in svgs {
        let (png, _, _) = crate::kindle_images::rasterize_svg(svg.as_bytes())?;
        let path = target.join(file);
        write_new(&path, &png)?;
        let path = path_string(path)?;
        match role {
            "head" => style.head_images.push(path),
            "title_rule" => style.title_rule = Some(path),
            "cover" => style.cover_background = Some(path),
            _ => style.chapter_end = Some(path),
        }
    }
    Ok(style)
}

type Imported = (
    ChapterStyle,
    Option<crate::block_styles::SystemStyles>,
    Option<PackInsets>,
);

fn import(zip_path: &Path, dir: &Path) -> Result<Imported, ApiError> {
    let bytes = {
        let file = fs::File::open(zip_path).map_err(|_| invalid())?;
        let mut data = Vec::new();
        file.take(MAX_ZIP_BYTES + 1)
            .read_to_end(&mut data)
            .map_err(|_| invalid())?;
        if data.len() as u64 > MAX_ZIP_BYTES {
            return Err(invalid());
        }
        data
    };
    let digest = format!("{:x}", Sha256::digest(&bytes));
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(&bytes)).map_err(|_| invalid())?;
    let mut read = |name: &str, limit: u64| -> Result<Vec<u8>, ApiError> {
        let entry = archive.by_name(name).map_err(|_| invalid())?;
        if entry.size() > limit {
            return Err(invalid());
        }
        let mut data = Vec::new();
        entry
            .take(limit + 1)
            .read_to_end(&mut data)
            .map_err(|_| invalid())?;
        if data.len() as u64 > limit {
            return Err(invalid());
        }
        Ok(data)
    };
    let pack: PackFile =
        serde_json::from_slice(&read("style.json", 64 * 1024)?).map_err(|_| invalid())?;
    if pack.schema_version != 1 || pack.head_images.len() > MAX_HEAD_IMAGES {
        return Err(invalid());
    }
    if let Some(blocks) = &pack.blocks {
        blocks.validate()?;
    }
    if let Some(insets) = &pack.insets {
        insets.validate()?;
    }
    let blocks = pack.blocks.clone();
    let insets = pack.insets.clone();
    let target = dir.join(format!("pack-{}", &digest[..16]));
    fs::create_dir_all(&target).map_err(|_| io())?;
    let mut extract = |name: &str| -> Result<String, ApiError> {
        let name = member_name(name)?;
        let data = read(name, MAX_IMAGE_BYTES)?;
        // 必须是能解码的图片。
        image::load_from_memory(&data).map_err(|_| invalid())?;
        let path = target.join(name);
        write_new(&path, &data)?;
        path_string(path)
    };
    let style = ChapterStyle {
        name: pack.name.trim().into(),
        head_images: pack
            .head_images
            .iter()
            .map(|n| extract(n))
            .collect::<Result<_, _>>()?,
        title_rule: pack.title_rule.as_deref().map(&mut extract).transpose()?,
        chapter_end: pack.chapter_end.as_deref().map(&mut extract).transpose()?,
        volume_frame: pack.volume_frame,
        cover_background: pack
            .cover_background
            .as_deref()
            .map(&mut extract)
            .transpose()?,
    };
    style.validate(|_| Ok(()))?;
    Ok((style, blocks, insets))
}

fn export(
    style: &ChapterStyle,
    blocks: Option<&crate::block_styles::SystemStyles>,
    insets: Option<&PackInsets>,
    zip_path: &Path,
) -> Result<(), ApiError> {
    if let Some(b) = blocks {
        b.validate()?;
    }
    if let Some(i) = insets {
        i.validate()?;
    }
    style.validate(|_| Ok(()))?;
    let mut names = std::collections::BTreeMap::<String, String>::new();
    let mut name_for = |path: &str, base: &str| -> Result<String, ApiError> {
        if let Some(n) = names.get(path) {
            return Ok(n.clone());
        }
        let ext = Path::new(path)
            .extension()
            .and_then(|e| e.to_str())
            .map(str::to_ascii_lowercase)
            .filter(|e| matches!(e.as_str(), "png" | "jpg" | "jpeg"))
            .ok_or_else(invalid)?;
        let name = format!("{base}.{ext}");
        names.insert(path.to_owned(), name.clone());
        Ok(name)
    };
    let pack = PackFile {
        schema_version: 1,
        name: style.name.clone(),
        author: String::new(),
        head_images: style
            .head_images
            .iter()
            .enumerate()
            .map(|(i, p)| name_for(p, &format!("chapter-head-{:02}", i + 1)))
            .collect::<Result<_, _>>()?,
        title_rule: style
            .title_rule
            .as_deref()
            .map(|p| name_for(p, "title-rule"))
            .transpose()?,
        chapter_end: style
            .chapter_end
            .as_deref()
            .map(|p| name_for(p, "chapter-end"))
            .transpose()?,
        volume_frame: style.volume_frame.clone(),
        cover_background: style
            .cover_background
            .as_deref()
            .map(|p| name_for(p, "cover-background"))
            .transpose()?,
        blocks: blocks.cloned(),
        insets: insets.cloned(),
    };
    let file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(zip_path)
        .map_err(|_| io())?;
    let mut zip = zip::ZipWriter::new(file);
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);
    zip.start_file("style.json", options).map_err(|_| io())?;
    zip.write_all(&serde_json::to_vec_pretty(&pack).map_err(|_| invalid())?)
        .map_err(|_| io())?;
    for (path, name) in &names {
        let data = fs::read(path).map_err(|_| invalid())?;
        zip.start_file(name.as_str(), options).map_err(|_| io())?;
        zip.write_all(&data).map_err(|_| io())?;
    }
    zip.finish().map_err(|_| io())?;
    Ok(())
}

/// `op: chapter_style`：`builtin {id, dir}`、`import {path, dir}`、`export {style, path}`、`list`。
pub fn run(value: Value) -> Result<String, ApiError> {
    let text = |key: &str| {
        value[key]
            .as_str()
            .filter(|s| !s.is_empty())
            .ok_or_else(invalid)
    };
    let absolute = |key: &str| -> Result<PathBuf, ApiError> {
        let p = PathBuf::from(text(key)?);
        if p.is_absolute() {
            Ok(p)
        } else {
            Err(invalid())
        }
    };
    let out = match value["action"].as_str() {
        Some("list") => {
            json!({"builtin": BUILTIN.iter().map(|(id, name)| json!({"id": id, "name": name})).collect::<Vec<_>>()})
        }
        Some("builtin") => {
            let id = text("id")?;
            json!({"style": builtin(id, &absolute("dir")?)?, "blocks": builtin_blocks(id)})
        }
        Some("import") => {
            let (style, blocks, insets) = import(&absolute("path")?, &absolute("dir")?)?;
            json!({"style": style, "blocks": blocks, "insets": insets})
        }
        Some("export") => {
            let style: ChapterStyle =
                serde_json::from_value(value["style"].clone()).map_err(|_| invalid())?;
            let blocks: Option<crate::block_styles::SystemStyles> =
                serde_json::from_value(value["blocks"].clone()).map_err(|_| invalid())?;
            let insets: Option<PackInsets> =
                serde_json::from_value(value["insets"].clone()).map_err(|_| invalid())?;
            export(&style, blocks.as_ref(), insets.as_ref(), &absolute("path")?)?;
            json!({"exported": true})
        }
        _ => return Err(invalid()),
    };
    serde_json::to_string(&out).map_err(|_| invalid())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "easypub-style-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn builtin_import_export_roundtrip_and_limits() {
        let dir = temp("roundtrip");
        let classic = builtin("classic", &dir).unwrap();
        assert_eq!(classic.name, "古典");
        assert_eq!(classic.head_images.len(), 2);
        assert_eq!(classic.volume_frame, "double");
        assert!(
            classic
                .cover_background
                .as_deref()
                .unwrap()
                .ends_with("cover-background.png")
        );
        for p in classic.paths() {
            assert!(image::open(p).is_ok(), "{p}");
        }
        // 再次生成复用同样的文件。
        assert_eq!(builtin("classic", &dir).unwrap(), classic);
        let zip_path = dir.join("古典.zip");
        let blocks = builtin_blocks("classic");
        let mut scroll = crate::inset_styles::default_for("scroll", "off");
        scroll.rods = false;
        let insets = PackInsets {
            chat_block_style: "script".into(),
            letter_block_style: "ruled".into(),
            styles: [("scroll".to_owned(), scroll)].into(),
        };
        export(&classic, Some(&blocks), Some(&insets), &zip_path).unwrap();
        assert!(
            export(&classic, None, None, &zip_path).is_err(),
            "不覆盖已有文件"
        );
        let (imported, imported_blocks, imported_insets) =
            import(&zip_path, &dir.join("installed")).unwrap();
        assert_eq!(imported_blocks.as_ref(), Some(&blocks), "块样式随包往返");
        assert_eq!(imported_insets.as_ref(), Some(&insets), "场景样式随包往返");
        // 场景样式非法时导出被拒绝。
        let mut bad = insets.clone();
        bad.chat_block_style = "bubble".into();
        assert!(export(&classic, None, Some(&bad), &dir.join("坏.zip")).is_err());
        assert_eq!(blocks.panel, crate::block_styles::preset("rules").unwrap());
        assert_eq!(imported.name, "古典");
        assert_eq!(imported.head_images.len(), 2);
        assert_eq!(imported.volume_frame, "double");
        assert!(
            imported
                .title_rule
                .as_deref()
                .unwrap()
                .ends_with("title-rule.png")
        );
        for (a, b) in classic.paths().zip(imported.paths()) {
            assert_eq!(fs::read(a).unwrap(), fs::read(b).unwrap());
        }
        // 再次导入同一个包：复用。
        assert_eq!(
            import(&zip_path, &dir.join("installed")).unwrap().0,
            imported
        );
        assert!(builtin("nope", &dir).is_err());
        // 不安全的包内文件名、坏图片、错误版本。
        for (json, files) in [
            (
                r#"{"schema_version":1,"name":"坏","title_rule":"../x.png"}"#,
                vec![],
            ),
            (
                r#"{"schema_version":1,"name":"坏","title_rule":"a.png"}"#,
                vec![("a.png", b"not png".to_vec())],
            ),
            (r#"{"schema_version":2,"name":"坏"}"#, vec![]),
            (
                r#"{"schema_version":1,"name":"坏","volume_frame":"wavy"}"#,
                vec![],
            ),
            (r#"{"schema_version":1,"name":"坏","extra":1}"#, vec![]),
            (
                r#"{"schema_version":1,"name":"坏","blocks":{"note":{"border":"wavy"}}}"#,
                vec![],
            ),
        ] {
            let bad = dir.join(format!("bad-{}.zip", json.len()));
            let mut zip = zip::ZipWriter::new(fs::File::create(&bad).unwrap());
            let o = zip::write::SimpleFileOptions::default();
            zip.start_file("style.json", o).unwrap();
            zip.write_all(json.as_bytes()).unwrap();
            for (n, d) in files {
                zip.start_file(n, o).unwrap();
                zip.write_all(&d).unwrap();
            }
            zip.finish().unwrap();
            assert!(import(&bad, &dir.join("bad")).is_err(), "{json}");
        }
        // 请求入口。
        let listed: Value = serde_json::from_str(&run(json!({"action":"list"})).unwrap()).unwrap();
        assert_eq!(listed["builtin"].as_array().unwrap().len(), 2);
        assert!(run(json!({"action":"builtin","id":"plain","dir":"relative"})).is_err());
        let _ = fs::remove_dir_all(dir);
    }
}
