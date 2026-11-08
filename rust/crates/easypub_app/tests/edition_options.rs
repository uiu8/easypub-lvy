use easypub_app::{
    edition_options::OutputOptions,
    kindle_images::{Options, kindle_ready_with},
    publication_resources,
};
use easypub_core::{
    source::{RULE_ID, SourceSnapshot},
    structure::Structure,
};
use serde_json::json;
use std::io::{Cursor, Read};

fn book(extra: serde_json::Value) -> publication_resources::Prepared {
    let source = SourceSnapshot::from_utf8(
        "第一章 开始\n这是正文。\n第二章 后记\n这是后记。\n"
            .as_bytes()
            .to_vec(),
        RULE_ID,
        || false,
    )
    .unwrap();
    let mut settings = json!({"title":"测试书", "author":"张三", "description":"简介", "language":"zh-CN", "cover_fit":"contain", "font_family":"SimSun", "font_size":18, "line_height":1.8, "include_toc":true, "visible_toc":true, "chapter_navigation":false, "illustrations":[]});
    settings
        .as_object_mut()
        .unwrap()
        .extend(extra.as_object().unwrap().clone());
    publication_resources::prepare(&source, serde_json::from_value(json!({"source_id":source.summary().source_id, "revision":1, "structure":Structure::recognized(&source), "settings":settings})).unwrap()).unwrap()
}
fn read(zip: &mut zip::ZipArchive<Cursor<Vec<u8>>>, name: &str) -> String {
    let mut text = String::new();
    zip.by_name(name)
        .unwrap()
        .read_to_string(&mut text)
        .unwrap();
    text
}
#[test]
fn edition_epub2_has_ncx_filtered_toc_and_selected_start() {
    let sample = book(
        json!({"navigation_options":{"toc_title":"章节列表", "toc_position":"back", "toc_filter":"后记", "start":"specific", "start_chapter":""}, "output_options":{"epub_version":2}}),
    );
    let id = sample.book().tree.nodes[0].entry_id.clone();
    let prepared = book(
        json!({"title_sort":"ceshi", "author_sort":"zhang san", "book_producer":"制作测试", "navigation_options":{"toc_title":"章节列表", "toc_position":"back", "toc_filter":"后记", "start":"specific", "start_chapter":id}, "output_options":{"epub_version":2}}),
    );
    let bytes = easypub_app::epub::write(&prepared, Cursor::new(Vec::new()))
        .unwrap()
        .into_inner();
    let mut zip = zip::ZipArchive::new(Cursor::new(bytes)).unwrap();
    let opf = read(&mut zip, "EPUB/package.opf");
    let doc = roxmltree::Document::parse(&opf).unwrap();
    assert_eq!(doc.root_element().attribute("version"), Some("2.0"));
    assert!(
        doc.descendants()
            .any(|n| n.tag_name().name() == "spine" && n.attribute("toc").is_some())
    );
    assert!(!opf.contains("properties="));
    assert!(opf.contains("制作测试") && opf.contains("ceshi") && opf.contains("zhang san"));
    let toc = read(&mut zip, "EPUB/toc.xhtml");
    assert!(toc.contains("章节列表") && !toc.contains("第二章"));
    assert!(read(&mut zip, "EPUB/kindling.ncx").contains("第一章"));
    let text = doc
        .descendants()
        .find(|n| n.tag_name().name() == "reference" && n.attribute("type") == Some("text"))
        .unwrap();
    assert!(text.attribute("href").unwrap().contains("#node-0"));
    assert_eq!(
        prepared.documents().unwrap().reading_order.last().unwrap(),
        "toc.xhtml"
    );
}
#[test]
fn edition_defaults_do_not_serialize_new_options() {
    let prepared = book(json!({}));
    let manifest = serde_json::to_value(prepared.manifest()).unwrap();
    for key in [
        "image_options",
        "navigation_options",
        "output_options",
        "title_sort",
        "author_sort",
        "book_producer",
    ] {
        assert!(manifest.get(key).is_none(), "{key}");
    }
}
#[test]
fn edition_txt_encoding_is_strict_and_newlines_are_explicit() {
    for encoding in ["gbk", "big5"] {
        let options = OutputOptions {
            txt_encoding: encoding.into(),
            txt_newline: "windows".into(),
            ..Default::default()
        };
        let text = "中文\n第二行\r\n末行\r";
        let bytes = options.text(text.into()).unwrap();
        let decoder = if encoding == "gbk" {
            encoding_rs::GBK
        } else {
            encoding_rs::BIG5
        };
        assert_eq!(decoder.decode(&bytes).0, "中文\r\n第二行\r\n末行\r\n");
        assert!(options.text("中文😀".into()).is_err());
    }
}
#[test]
fn edition_image_options_keep_transparency_and_small_original_bytes() {
    use easypub_app::assets::{ImageEvidence, ImageSnapshot};
    use image::{DynamicImage, ImageBuffer, ImageFormat, Rgba};
    let image = DynamicImage::ImageRgba8(ImageBuffer::from_fn(100, 60, |x, _| {
        Rgba([180, 80, 40, if x < 50 { 100 } else { 255 }])
    }));
    let mut bytes = Cursor::new(Vec::new());
    image.write_to(&mut bytes, ImageFormat::Png).unwrap();
    let bytes = bytes.into_inner();
    let snapshot = || ImageSnapshot {
        evidence: ImageEvidence {
            path: "fixture.png".into(),
            sha256: String::new(),
            bytes: bytes.len() as u64,
            width: 100,
            height: 60,
            format: "png".into(),
        },
        bytes: bytes.clone(),
    };
    assert_eq!(
        kindle_ready_with(snapshot(), &Options::default(), false)
            .unwrap()
            .0
            .bytes,
        bytes
    );
    let options = Options {
        max_long: 50,
        max_short: 30,
        png_to_jpeg: true,
        grayscale: true,
        ..Default::default()
    };
    let (out, _) = kindle_ready_with(snapshot(), &options, false).unwrap();
    assert_eq!(
        (
            out.evidence.width,
            out.evidence.height,
            out.evidence.format.as_str()
        ),
        (50, 30, "png")
    );
    assert!(
        image::load_from_memory(&out.bytes)
            .unwrap()
            .to_rgba8()
            .pixels()
            .any(|p| p.0[3] < 255)
    );
    assert_eq!(
        kindle_ready_with(snapshot(), &options, true)
            .unwrap()
            .0
            .bytes,
        bytes
    );
}

#[test]
fn edition_image_estimate_equals_both_export_paths() {
    use image::{DynamicImage, ImageBuffer, Rgb};
    let dir = std::env::temp_dir().join(format!("easypub-edition-images-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("illustration.png");
    DynamicImage::ImageRgb8(ImageBuffer::from_fn(400, 300, |x, y| {
        Rgb([(x % 251) as u8, (y % 251) as u8, 90])
    }))
    .save(&path)
    .unwrap();
    let options = json!({"max_long":200,"max_short":150,"png_to_jpeg":true,"quality":55,"preserve_cover":false});
    let prepared = book(json!({"cover_path":path,"image_options":options}));
    let estimate: serde_json::Value = serde_json::from_str(
        &easypub_app::kindle_images::estimate(
            json!({"options":options,"paths":[path],"cover":path}),
        )
        .unwrap(),
    )
    .unwrap();
    let actual: usize = prepared
        .manifest()
        .resources
        .iter()
        .map(|r| r.byte_length)
        .sum();
    assert_eq!(estimate["after"].as_u64().unwrap(), actual as u64);
    let original = book(json!({"cover_path":path}));
    let bytes = easypub_app::epub::write(&original, Cursor::new(Vec::new()))
        .unwrap()
        .into_inner();
    let epub = dir.join("source.epub");
    std::fs::write(&epub, &bytes).unwrap();
    let estimate: serde_json::Value = serde_json::from_str(
        &easypub_app::kindle_images::estimate(json!({"options":options,"original_epub":epub}))
            .unwrap(),
    )
    .unwrap();
    let (output, _) = easypub_app::epub_passthrough::rebuild(
        &bytes,
        &easypub_app::epub_passthrough::Overrides::from_prepared(&prepared, false, false),
    )
    .unwrap();
    let mut zip = zip::ZipArchive::new(Cursor::new(output)).unwrap();
    let total: u64 = (0..zip.len())
        .map(|i| {
            let f = zip.by_index(i).unwrap();
            if f.name().ends_with(".jpg") || f.name().ends_with(".png") {
                f.size()
            } else {
                0
            }
        })
        .sum();
    assert_eq!(estimate["after"].as_u64().unwrap(), total);
}

#[test]
fn edition_standard_epub_fixtures() {
    let dir = std::env::var_os("EASYPUB_EPUBCHECK_FIXTURES")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| {
            std::env::temp_dir().join(format!("easypub-standard-{}", std::process::id()))
        });
    std::fs::create_dir_all(&dir).unwrap();
    for version in [2, 3] {
        let prepared = book(
            json!({"output_options":{"epub_version":version},"title_sort":"ceshi","author_sort":"zhang san"}),
        );
        let bytes = easypub_app::epub::write(&prepared, Cursor::new(Vec::new()))
            .unwrap()
            .into_inner();
        std::fs::write(dir.join(format!("software-{version}.epub")), &bytes).unwrap();
        let mut archive = zip::ZipArchive::new(Cursor::new(bytes.clone())).unwrap();
        let opf = read(&mut archive, "EPUB/package.opf");
        assert!(!opf.contains("<dc:title xmlns:opf=\"http://www.idpf.org/2007/opf\" opf:file-as="));
        if version == 3 {
            assert!(opf.contains("property=\"file-as\""));
        }
        let (rebuilt, _) = easypub_app::epub_passthrough::rebuild(
            &bytes,
            &easypub_app::epub_passthrough::Overrides::from_prepared(&prepared, false, false),
        )
        .unwrap();
        std::fs::write(dir.join(format!("original-{version}.epub")), rebuilt).unwrap();
    }
}

#[test]
fn edition_image_plan_includes_crop_dedup_and_css() {
    let dir = std::env::temp_dir().join(format!("easypub-image-plan-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("cover.png");
    image::ImageBuffer::from_fn(40, 30, |x, y| image::Rgb([x as u8, y as u8, 90u8]))
        .save(&path)
        .unwrap();
    let duplicate = dir.join("duplicate.png");
    std::fs::copy(&path, &duplicate).unwrap();
    let css_image = dir.join("background.png");
    image::ImageBuffer::from_pixel(12, 10, image::Rgb([1u8, 2, 3]))
        .save(&css_image)
        .unwrap();
    let source =
        SourceSnapshot::from_utf8("第一章 开始\n正文".as_bytes().to_vec(), RULE_ID, || false)
            .unwrap();
    let options = json!({"max_long":20,"max_short":15,"preserve_cover":false});
    let input = json!({"source_id":source.summary().source_id,"revision":1,"structure":Structure::recognized(&source),"settings":{
        "title":"测试", "author":"甲","language":"zh-CN","cover_path":path, "description":"", "cover_fit":"contain", "font_family":"SimSun", "font_size":18, "line_height":1.8, "include_toc":true,"visible_toc":true,"chapter_navigation":false,"illustrations":[],
        "cover_crop":{"x":0.0,"y":0.0,"width":0.5,"height":0.5},
        "chapter_head_image":duplicate,"additional_css":"body{background-image:url(background.png)}", "additional_css_base":dir,
        "image_options":options
    }});
    let estimate: serde_json::Value = serde_json::from_str(
        &easypub_app::kindle_images::estimate_publication(&source, input.clone(), options).unwrap(),
    )
    .unwrap();
    let prepared =
        publication_resources::prepare(&source, serde_json::from_value(input).unwrap()).unwrap();
    let bytes = easypub_app::epub::write(&prepared, Cursor::new(Vec::new()))
        .unwrap()
        .into_inner();
    let mut zip = zip::ZipArchive::new(Cursor::new(bytes)).unwrap();
    let mut total = 0;
    let mut count = 0;
    for i in 0..zip.len() {
        let f = zip.by_index(i).unwrap();
        if f.name().ends_with(".png") {
            total += f.size();
            count += 1;
        }
    }
    assert_eq!(estimate["after"], total);
    assert_eq!(estimate["count"], count);
    assert_eq!(count, 3);
}

#[test]
fn original_navigation_rewrites_real_links_without_changing_body() {
    let dir = std::env::var_os("EASYPUB_EPUBCHECK_FIXTURES")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| {
            std::env::temp_dir().join(format!("easypub-nav-{}", std::process::id()))
        });
    std::fs::create_dir_all(&dir).unwrap();
    for version in [2, 3] {
        let original = book(json!({"output_options":{"epub_version":version}}));
        let bytes = easypub_app::epub::write(&original, Cursor::new(Vec::new()))
            .unwrap()
            .into_inner();
        let path = dir.join(format!("nav-input-{version}.epub"));
        std::fs::write(&path, &bytes).unwrap();
        let inspected: serde_json::Value = serde_json::from_str(
            &easypub_app::original_navigation::inspect(path.to_str().unwrap()).unwrap(),
        )
        .unwrap();
        let selected = inspected["entries"]
            .as_array()
            .unwrap()
            .iter()
            .find(|e| e["title"].as_str().unwrap().contains("后记"))
            .unwrap()["id"]
            .as_str()
            .unwrap();
        let mut settings = book(
            json!({"output_options":{"epub_version":version},"navigation_options":{"apply_to_original":true,"toc_title":"新目录 & 章节","toc_position":"back","toc_filter":"后记","start":"specific","original_start":selected}}),
        );
        let overrides =
            easypub_app::epub_passthrough::Overrides::from_prepared(&settings, false, false);
        let (out, _) = easypub_app::epub_passthrough::rebuild(&bytes, &overrides).unwrap();
        let mut original_zip = zip::ZipArchive::new(Cursor::new(bytes.clone())).unwrap();
        let body = read(&mut original_zip, "EPUB/body.xhtml");
        let mut zip = zip::ZipArchive::new(Cursor::new(out.clone())).unwrap();
        assert_eq!(read(&mut zip, "EPUB/body.xhtml"), body);
        let opf = read(&mut zip, "EPUB/package.opf");
        let doc = roxmltree::Document::parse(&opf).unwrap();
        let spine = doc.descendants().find(|n| n.has_tag_name("spine")).unwrap();
        let last = spine
            .children()
            .filter(|n| n.has_tag_name("itemref"))
            .last()
            .unwrap()
            .attribute("idref")
            .unwrap();
        let item = doc
            .descendants()
            .find(|n| n.has_tag_name("item") && n.attribute("id") == Some(last))
            .unwrap();
        let nav = read(
            &mut zip,
            &format!("EPUB/{}", item.attribute("href").unwrap()),
        );
        assert!(nav.contains("新目录 &amp; 章节") && !nav.contains("第二章 后记"));
        let start = doc
            .descendants()
            .find(|n| n.has_tag_name("reference") && n.attribute("type") == Some("text"))
            .unwrap();
        assert_eq!(
            format!("EPUB/{}", start.attribute("href").unwrap()),
            selected
        );
        std::fs::write(dir.join(format!("navigation-{version}.epub")), &out).unwrap();
        // A second rewrite must not create a second nav property or break chapter links.
        easypub_app::epub_passthrough::rebuild(
            &out,
            &easypub_app::epub_passthrough::Overrides::from_prepared(
                &book(json!({"navigation_options":{"apply_to_original":true,"start":"toc"}})),
                false,
                false,
            ),
        )
        .unwrap();
        settings = book(
            json!({"navigation_options":{"apply_to_original":true,"start":"specific","original_start":"EPUB/body.xhtml#missing"}}),
        );
        assert!(
            easypub_app::epub_passthrough::rebuild(
                &bytes,
                &easypub_app::epub_passthrough::Overrides::from_prepared(&settings, false, false)
            )
            .is_err()
        );
    }
}
