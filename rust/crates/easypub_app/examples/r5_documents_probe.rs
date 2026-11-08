//! Development fixture: production EPUB profiles, semantic pages and sidecars.
use easypub_app::publication_resources::{self, Request};
use easypub_core::source::{RULE_ID, SourceSnapshot};
use serde_json::json;
use std::{fs, io::Write, path::PathBuf};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let output = PathBuf::from(args.next().ok_or("new output directory required")?);
    fs::create_dir(&output)?;
    let output = output.canonicalize()?;
    let text = if let Some(path) = args.next() {
        fs::read_to_string(path)?
    } else {
        "卷前说明 <script> & 引用\r\n第一卷 起点\n卷首正文\n第一章 初遇\n  正文甲😀\n\n第二章 告别\n正文乙".into()
    };
    let source = SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false)
        .map_err(|e| format!("{e:?}"))?;
    let image_path = output.join("fixture.png");
    image::RgbImage::from_fn(1600, 2560, |x, y| {
        image::Rgb([if x < 800 { 190 } else { 90 }, (y / 16) as u8, 160])
    })
    .save(&image_path)?;
    let illustration_path = output.join("illustration.png");
    image::RgbImage::from_fn(900, 600, |x, y| {
        image::Rgb([(x / 4) as u8, 120, (y / 3) as u8])
    })
    .save(&illustration_path)?;
    let request: Request = serde_json::from_value(
        json!({"source_id":source.summary().source_id,"revision":1,
      "settings":{"title":"页面验证样书", "author":"测试作者", "translator":"测试译者", "description":"简介与排版验证",
      "publisher":"测试出版社", "category":"测试分类", "publication_date":"2026-09-28", "isbn":"9780306406157",
      "language":"zh-CN", "cover_path":image_path, "cover_fit":"contain", "font_family":"SimSun", "font_size":20,
      "line_height":1.8, "include_toc":true, "visible_toc":true, "chapter_navigation":true,
      "additional_css":".book-title { letter-spacing: 0.1em; }",
      "illustrations":[{"path":illustration_path,"caption":"行后插图 <&>","alt":"合成色块","source_line":2}]}}),
    )?;
    let prepared =
        publication_resources::prepare(&source, request).map_err(|e| format!("{e:?}"))?;
    let epub = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(output.join("sample.epub"))?;
    easypub_app::epub::write(&prepared, epub)
        .map_err(|e| format!("{e:?}"))?
        .sync_all()?;
    let kindling_input = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(output.join("kindling-input.epub"))?;
    easypub_app::epub::write_kindling_input(&prepared, kindling_input)
        .map_err(|e| format!("{e:?}"))?
        .sync_all()?;
    let documents = prepared.documents().map_err(|e| format!("{e:?}"))?;
    let write = |name: &str, bytes: &[u8]| -> std::io::Result<()> {
        fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(output.join(name))?
            .write_all(bytes)
    };
    for (name, content) in &documents.pages {
        write(name, content.as_bytes())?;
    }
    let m = prepared.manifest();
    write(&m.stylesheet.id, m.stylesheet.css.as_bytes())?;
    for resource in &m.resources {
        write(
            &resource.id,
            prepared.image_bytes(&resource.id).ok_or("missing image")?,
        )?;
    }
    for resource in &m.css_dependencies.resources {
        write(
            &resource.id,
            prepared
                .css_resource_bytes(&resource.id)
                .ok_or("missing CSS")?,
        )?;
    }
    write("final-text.txt", prepared.book().text.as_bytes())?;
    write("manifest.json", &serde_json::to_vec_pretty(m)?)?;
    write(
        "reading-order.json",
        &serde_json::to_vec_pretty(&documents.reading_order)?,
    )?;
    Ok(())
}
