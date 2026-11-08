use super::*;
use easypub_core::source::{RULE_ID, SourceSnapshot};
use std::{
    fs,
    io::{Cursor, Read},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

fn settings() -> Value {
    json!({"title":"远行", "author":"林舟", "translator":"译者甲", "publisher":"海岸出版社",
        "description":"简介", "language":"zh-CN", "cover_fit":"contain", "font_family":"SimSun",
        "font_size":20, "line_height":1.8, "include_toc":true, "visible_toc":true, "illustrations":[]})
}
fn content(kind: Kind, title: &str, body: &str) -> Content {
    Content {
        kind,
        position: kind.default_position().unwrap_or(Position::Back),
        title: title.into(),
        body: body.into(),
        include_toc: true,
    }
}
fn root() -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!(
        "easypub-v55-{}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir(&path).unwrap();
    path
}
fn apply(service: &ImportService, request: &mut Value, action: Value) -> Value {
    request["action"] = action;
    let preview: Value =
        serde_json::from_str(&run(service, request.clone(), false, "", false).unwrap()).unwrap();
    assert!(preview["items"][0]["history"].is_null());
    assert!(run(service, request.clone(), true, "wrong", true).is_err());
    let result: Value = serde_json::from_str(
        &run(
            service,
            request.clone(),
            true,
            preview["plan_id"].as_str().unwrap(),
            true,
        )
        .unwrap(),
    )
    .unwrap();
    request["targets"][0]["current"] = result["items"][0]["after"].clone();
    request["targets"][0]["history"] = result["items"][0]["history"].clone();
    result
}

#[test]
fn crud_reorder_history_project_and_template_snapshot() {
    let root = root();
    let path = root.join("远行.txt");
    let text = "第一章 启程\n正文甲。\n第二章 归来\n正文乙。\n";
    fs::write(&path, text).unwrap();
    let service = ImportService::new().unwrap();
    let job = service
        .start_import(path.to_string_lossy().into(), RULE_ID.into())
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let summary = loop {
        let job = service.get_job(job).unwrap();
        if job.terminal() {
            break job.book.unwrap();
        }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(2));
    };
    let mut request = json!({"op":"supplemental_pages", "targets":[{"book_id":"book", "current":settings(),
        "history":{"source_id":summary.source_id,"revision":1,"states":[settings()],"cursor":0},"change":{"op":"inspect"}}],"action":{"kind":"list"}});
    let template = Template {
        id: digest(b"template"),
        name: "版权".into(),
        content: content(
            Kind::Copyright,
            "{书名}版权",
            "{年份} {作者} / {译者} / {出版社}\n{未知}",
        ),
    };
    let result = apply(
        &service,
        &mut request,
        json!({"kind":"apply_template", "template":template, "year":2026}),
    );
    assert_eq!(result["warnings"][0]["placeholder"], "{未知}");
    let copyright = result["supplemental_pages"][0].clone();
    assert_eq!(
        copyright["content"]["body"],
        "2026 林舟 / 译者甲 / 海岸出版社\n{未知}"
    );
    // Metadata changes do not re-expand the already stored page.
    request["targets"][0]["current"]["title"] = json!("新书名");
    let afterword = content(Kind::Afterword, "后记", "后记正文");
    let added = apply(
        &service,
        &mut request,
        json!({"kind":"add", "content":afterword}),
    );
    assert_eq!(added["supplemental_pages"][0], copyright);
    let back = added["supplemental_pages"][1]["id"].clone();
    let front = copyright["id"].clone();
    let reordered = apply(
        &service,
        &mut request,
        json!({"kind":"reorder", "ids":[back, front]}),
    );
    assert_eq!(reordered["supplemental_pages"][0]["id"], back);
    // V56：拖到另一组一次完成改位置与重排；撤销一步即回到原位置。
    let moved = apply(
        &service,
        &mut request,
        json!({"kind":"move", "id":back, "position":"front", "ids":[front, back]}),
    );
    assert_eq!(moved["supplemental_pages"][1]["id"], back);
    assert_eq!(
        moved["supplemental_pages"][1]["content"]["position"],
        "front"
    );
    assert!(
        run(
            &service,
            {
                let mut r = request.clone();
                r["action"] = json!({"kind":"move", "id":back, "position":"back", "ids":[back]});
                r
            },
            false,
            "",
            false
        )
        .is_err(),
        "ids 必须是完整排列"
    );
    let undone = apply(&service, &mut request, json!({"kind":"undo"}));
    assert_eq!(undone["supplemental_pages"][0]["id"], back);
    assert_eq!(
        undone["supplemental_pages"][0]["content"]["position"],
        "back"
    );
    apply(
        &service,
        &mut request,
        json!({"kind":"update", "id":back, "content":content(Kind::Afterword, "终章之后", "修订后记")}),
    );
    apply(&service, &mut request, json!({"kind":"delete", "id":front}));
    assert_eq!(
        apply(&service, &mut request, json!({"kind":"undo"}))["supplemental_pages"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert_eq!(
        apply(&service, &mut request, json!({"kind":"redo"}))["supplemental_pages"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let mut saved = request["targets"][0]["current"].clone();
    for (key, value) in
        json!({"path":path,"source_id":summary.source_id,"revision":1,"selected":true,
        "production_history":request["targets"][0]["history"]})
        .as_object()
        .unwrap()
    {
        saved[key] = value.clone();
    }
    let project = json!({"schema":1,"rule_id":RULE_ID,"books":[saved],"current_path":path,"output":root,"format":"EPUB"});
    let file = root.join("book.easypub.json");
    crate::project::save(&service, file.to_str().unwrap(), &project.to_string()).unwrap();
    let reopened = ImportService::new().unwrap();
    let opened: Value =
        serde_json::from_str(&crate::project::open(&reopened, file.to_str().unwrap()).unwrap())
            .unwrap();
    let book: crate::project::ProjectBook =
        serde_json::from_value(opened["project"]["books"][0].clone()).unwrap();
    assert_eq!(json!(book.supplemental_pages), saved["supplemental_pages"]);
    request["targets"][0]["history"] = json!(book.production_history);
    request["targets"][0]["current"] = json!(production::Settings::from(&book));
    assert_eq!(
        apply(&reopened, &mut request, json!({"kind":"undo"}))["supplemental_pages"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert_eq!(fs::read(path).unwrap(), text.as_bytes());
}

#[test]
fn limits_unicode_expansion_and_large_global_templates_roundtrip() {
    let mut c = content(Kind::Copyright, "版权", &"𠮷".repeat(20_000));
    let pages: Vec<_> = (0..20)
        .map(|i| Page {
            id: digest(i.to_string().as_bytes()),
            content: c.clone(),
        })
        .collect();
    validate(&pages).unwrap();
    let mut too_many = pages.clone();
    too_many.push(Page {
        id: digest(b"extra"),
        content: c.clone(),
    });
    assert_eq!(
        validate(&too_many).unwrap_err().next_action,
        "supplemental_page_limit"
    );
    c.body.push('字');
    assert_eq!(
        c.validate().unwrap_err().next_action,
        "supplemental_body_too_long"
    );
    c.body = "{简介}".repeat(20_000 / 4);
    assert_eq!(
        expand(&c, &serde_json::from_value(settings()).unwrap(), 2026)
            .unwrap()
            .0
            .body
            .chars()
            .count(),
        10_000
    );
    c.body = "{出版社}{出版社}{出版社}".into();
    let mut metadata: production::Settings = serde_json::from_value(settings()).unwrap();
    metadata.publisher = "长".repeat(10_000);
    assert_eq!(
        expand(&c, &metadata, 2026).unwrap_err().next_action,
        "supplemental_body_too_long"
    );
    let mut s: production::Settings = serde_json::from_value(settings()).unwrap();
    s.supplemental_pages = pages;
    // Full legal Unicode pages and all 51 history states must remain representable.
    let history = production::History {
        source_id: digest(b"source"),
        revision: 1,
        states: vec![s; 51],
        cursor: 50,
    };
    history.validate(10).unwrap();
    let templates: Vec<_> = (0..3)
        .map(|i| Template {
            id: digest(i.to_string().as_bytes()),
            name: format!("模板{i}"),
            content: content(Kind::Copyright, "", &"版".repeat(20_000)),
        })
        .collect();
    let directory = root();
    let config = serde_json::from_value(json!({"supplemental_templates":templates})).unwrap();
    let saved = crate::settings_store::save(&directory, None, config).unwrap();
    let reopened = crate::settings_store::load(&directory).unwrap();
    assert_eq!(reopened.configuration.supplemental_templates, templates);
    assert_eq!(reopened.token, saved.token);
    assert!(
        fs::metadata(directory.join("00000000000000000001.json"))
            .unwrap()
            .len()
            < 65536
    );
    let changed: Value = serde_json::from_str(&templates_edit(
        json!({"kind":"delete","id":templates[0].id}),
        &templates,
    ))
    .unwrap();
    assert_eq!(changed["templates"].as_array().unwrap().len(), 2);
    let duplicate = json!({"op":"supplemental_templates", "templates":templates, "action":{"kind":"save","id":null,"name":"模板1","content":templates[0].content}});
    assert_eq!(
        super::templates(duplicate).unwrap_err().next_action,
        "supplemental_template_duplicate"
    );
    let blob = fs::read_dir(directory.join("template-records"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    fs::write(blob, b"[]").unwrap();
    assert!(crate::settings_store::load(&directory).is_err());
}
fn templates_edit(action: Value, templates: &[Template]) -> String {
    super::templates(json!({"op":"supplemental_templates", "templates":templates, "action":action}))
        .unwrap()
}

#[test]
fn reading_order_tocs_source_map_and_kindle_start_target() {
    let text = "第一章 启程\r\n　正文<&>。\n第二章 归来\r末行";
    let source = SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
    let pages: Vec<_> = [
        Kind::Copyright,
        Kind::Dedication,
        Kind::AuthorNote,
        Kind::Afterword,
        Kind::AboutAuthor,
        Kind::Custom,
    ]
    .iter()
    .enumerate()
    .map(|(i, &kind)| {
        let mut content = content(
            kind,
            if i == 1 { "" } else { kind.label() },
            "独立附页<&>\n第二段",
        );
        content.include_toc = i != 4;
        Page {
            id: digest(&[i as u8]),
            content,
        }
    })
    .collect();
    let dir = root();
    let cover = dir.join("cover.png");
    image::RgbImage::from_pixel(40, 60, image::Rgb([200, 210, 220]))
        .save(&cover)
        .unwrap();
    let mut settings = settings();
    settings["supplemental_pages"] = json!(pages);
    settings["fullwidth_indent"] = json!(2);
    settings["cover_path"] = json!(cover);
    // 合并 V54：统一章首图只放在原正文章节，不进附页。
    settings["chapter_head_image"] = json!(cover);
    settings["chapter_head_scope"] = json!("both");
    let request = serde_json::from_value(
        json!({"source_id":source.summary().source_id,"revision":1,"settings":settings}),
    )
    .unwrap();
    let prepared = crate::publication_resources::prepare(&source, request).unwrap();
    let docs = prepared.documents().unwrap();
    let front: Vec<_> = pages
        .iter()
        .filter(|p| p.content.position == Position::Front)
        .map(Page::filename)
        .collect();
    let back: Vec<_> = pages
        .iter()
        .filter(|p| p.content.position == Position::Back)
        .map(Page::filename)
        .collect();
    assert_eq!(&docs.reading_order[2..5], front);
    assert_eq!(docs.reading_order[5], "toc.xhtml");
    assert_eq!(&docs.reading_order[7..], back);
    for (name, page) in &docs.pages {
        let heads = page.matches("class=\"chapter-head-image").count();
        if name.starts_with("matter-") {
            assert_eq!(heads, 0, "{name}");
        } else if name.starts_with("body") {
            assert_eq!(heads, 2, "{name}");
        }
    }
    let mut restored = String::new();
    for name in &docs.reading_order {
        let doc = roxmltree::Document::parse(&docs.pages[name]).unwrap();
        for node in doc
            .descendants()
            .filter(|n| n.attribute("data-source") == Some("true"))
        {
            assert!(name.starts_with("body"));
            restored.push_str(
                &node
                    .attribute("data-original")
                    .map(str::to_owned)
                    .unwrap_or_else(|| {
                        node.descendants()
                            .filter(|n| n.is_text())
                            .filter_map(|n| n.text())
                            .collect()
                    }),
            );
            restored.push_str(match node.attribute("data-eol").unwrap() {
                "crlf" => "\r\n",
                "cr" => "\r",
                "lf" => "\n",
                _ => "",
            });
        }
    }
    assert_eq!(restored, text);
    for bytes in [
        crate::epub::write(&prepared, Cursor::new(Vec::new()))
            .unwrap()
            .into_inner(),
        crate::epub::write_kindling_input(&prepared, Cursor::new(Vec::new()))
            .unwrap()
            .into_inner(),
        crate::epub::write_bokai_input(&prepared, Cursor::new(Vec::new()))
            .unwrap()
            .into_inner(),
    ] {
        let mut zip = zip::ZipArchive::new(Cursor::new(bytes)).unwrap();
        for name in ["EPUB/nav.xhtml", "EPUB/toc.xhtml", "EPUB/kindling.ncx"] {
            let mut xml = String::new();
            zip.by_name(name).unwrap().read_to_string(&mut xml).unwrap();
            roxmltree::Document::parse(&xml).unwrap();
            for p in &pages {
                assert_eq!(xml.contains(&p.filename()), p.content.include_toc);
            }
        }
        let mut xml = String::new();
        zip.by_name("EPUB/package.opf")
            .unwrap()
            .read_to_string(&mut xml)
            .unwrap();
        let opf = roxmltree::Document::parse(&xml).unwrap();
        let start = opf
            .descendants()
            .find(|n| n.attribute("type") == Some("text"))
            .unwrap()
            .attribute("href")
            .unwrap();
        // V47 guide 指向第一章所在文件，章节锚点用于目录而非 guide。
        assert!(start.starts_with("body"), "{start}");
        let mut body = String::new();
        zip.by_name(&format!("EPUB/{start}"))
            .unwrap()
            .read_to_string(&mut body)
            .unwrap();
        let doc = roxmltree::Document::parse(&body).unwrap();
        let chapter = doc
            .descendants()
            .find(|n| n.attribute("class") == Some("chapter-start"))
            .unwrap();
        let heading = chapter
            .descendants()
            .find(|n| n.attribute("id") == Some("node-0"))
            .unwrap();
        assert_eq!(
            heading
                .descendants()
                .filter(|n| n.is_text())
                .filter_map(|n| n.text())
                .collect::<String>(),
            "第一章 启程"
        );
    }
}
