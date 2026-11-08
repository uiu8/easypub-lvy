//! OUT-085: inspect actual compressed/uncompressed outputs, including both
//! sections of dual MOBI. Positions must land on the named element, not merely
//! somewhere inside the right chapter.
mod common;

use common::*;
use std::{fs, io::Write, path::PathBuf, process::Command};

fn fixture(name: &str, guide: &str, landmarks: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("kindling-v47-{}-{name}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let input = dir.join("导航.epub");
    let opf = format!(
        r#"<package version="3.0" unique-identifier="uid" xmlns="http://www.idpf.org/2007/opf">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>导航</dc:title><dc:creator>测试</dc:creator><dc:language>zh</dc:language><dc:identifier id="uid">v47</dc:identifier></metadata>
      <manifest><item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>
      <item id="image" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/>
      <item id="toc" href="toc.xhtml" media-type="application/xhtml+xml"/>
      <item id="body" href="正文%20章.xhtml" media-type="application/xhtml+xml"/>
      <item id="nav" href="导航/nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest>
      <spine><itemref idref="cover"/><itemref idref="toc"/><itemref idref="body"/></spine>{guide}</package>"#
    );
    let opf = if name == "outside" {
        opf.replace(r#"<itemref idref="cover"/>"#, "")
            .replace(r#"<itemref idref="toc"/>"#, "")
    } else {
        opf
    };
    let cover = if name == "outside" {
        r#"<html><head><title>封面</title></head><body id="封面"><svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><title>封面</title><image width="600" height="800" xlink:href="cover.jpg"/></svg></body></html>"#
    } else {
        r#"<html><head><title>封面</title></head><body id="封面"><img src="cover.jpg" alt="封面"/></body></html>"#
    };
    let nav = format!(
        r#"<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>导航</title></head><body>
      <nav epub:type="toc"><ol><li><a href="../正文%20章.xhtml#正文">第一章 雾起</a></li></ol></nav>
      <nav epub:type="landmarks"><ol>{landmarks}</ol></nav></body></html>"#
    );
    let mut zip = zip::ZipWriter::new(fs::File::create(&input).unwrap());
    for (path, content) in [
        ("mimetype", "application/epub+zip"),
        (
            "META-INF/container.xml",
            r#"<container><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#,
        ),
        ("OPS/package.opf", &opf),
        ("OPS/导航/nav.xhtml", &nav),
        ("OPS/cover.xhtml", cover),
        (
            "OPS/toc.xhtml",
            r#"<html><head><title>目录</title></head><body><h1 id="目录">目录</h1><a href="正文%20章.xhtml#%E6%AD%A3%E6%96%87">第一章 雾起</a></body></html>"#,
        ),
        (
            "OPS/正文 章.xhtml",
            r#"<html><head><title>正文</title></head><body><h1 id="序">序</h1><p>中文前言。不得作为起点。</p><h1 id="正文">第一章 雾起</h1><p>正文甲。</p><a href="toc.xhtml#目录">返回目录</a></body></html>"#,
        ),
    ] {
        zip.start_file(path, zip::write::SimpleFileOptions::default())
            .unwrap();
        zip.write_all(content.as_bytes()).unwrap();
    }
    zip.start_file("OPS/cover.jpg", zip::write::SimpleFileOptions::default())
        .unwrap();
    zip.write_all(include_bytes!("fixtures/parity/simple_book/cover.jpg"))
        .unwrap();
    zip.finish().unwrap();
    input
}

const GUIDE: &str = r#"<guide>
  <reference type="cover" title="封面" href="cover.xhtml#封面"/>
  <reference type="toc" title="目录 &amp; 导航" href="toc.xhtml#目录"/>
  <reference type="text" title="正文" href="正文%20章.xhtml#%E6%AD%A3%E6%96%87"/>
</guide>"#;
const LANDMARKS: &str = r#"<li><a epub:type="cover" href="../cover.xhtml#封面">封面</a></li>
  <li><a epub:type="toc" href="../toc.xhtml#目录">目录 &amp; 导航</a></li>
  <li><a epub:type="bodymatter" href="../正文%20章.xhtml#%E6%AD%A3%E6%96%87"><span>正文</span></a></li>"#;

fn build(input: &std::path::Path, legacy: bool, raw: bool) -> ParsedMobi {
    let out = input.with_file_name(format!("{legacy}-{raw}.mobi"));
    let mut cmd = Command::new(kindling_bin());
    cmd.arg("build")
        .arg(input)
        .args(["--no-validate", "-o"])
        .arg(&out);
    if legacy {
        cmd.arg("--legacy-mobi");
    }
    if raw {
        cmd.arg("--no-compress");
    }
    let result = cmd.output().unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    parse_mobi_file(&fs::read(out).unwrap()).unwrap()
}

fn element_text(bytes: &[u8], offset: usize) -> &str {
    let tail = std::str::from_utf8(&bytes[offset..]).unwrap();
    assert!(tail.starts_with('<'), "offset lands inside markup: {tail}");
    let text = &tail[tail.find('>').unwrap() + 1..];
    &text[..text.find('<').unwrap_or(text.len())]
}

fn verify(parsed: &ParsedMobi) {
    let section = parsed.kf8_or_kf7();
    let header = parsed.palmdb.record(&parsed.raw, section.record_idx);
    let guide_index = u32_be(header, 260);
    assert_ne!(guide_index, u32::MAX);
    let guide = parse_indx(parsed, section.record_idx + guide_index as usize).unwrap();
    assert_eq!(
        guide
            .entries
            .iter()
            .map(|e| e.label.as_slice())
            .collect::<Vec<_>>(),
        [b"cover".as_slice(), b"text", b"toc"]
    );
    let fragments = parse_indx(
        parsed,
        section.record_idx + section.header.fragment_index as usize,
    )
    .unwrap();
    let rendered = reconstruct_parts_from_mobi(parsed).unwrap().concat();
    let start = u32_be(section.exth_first(116).expect("KF8 StartReading"), 0) as usize;
    assert_eq!(element_text(&rendered, start), "第一章 雾起");
    for entry in guide.entries {
        assert!(entry.tag_value(1, 0).is_some(), "missing CNCX title");
        let fid = entry.tag_value(6, 0).unwrap() as usize;
        let off = entry.tag_value(6, 1).unwrap() as usize;
        let insert: usize = std::str::from_utf8(&fragments.entries[fid].label)
            .unwrap()
            .parse()
            .unwrap();
        let at = insert + off;
        match entry.label.as_slice() {
            b"text" => {
                assert_eq!(at, start);
                assert_eq!(element_text(&rendered, at), "第一章 雾起");
            }
            b"toc" => assert_eq!(element_text(&rendered, at), "目录"),
            b"cover" => assert!(
                std::str::from_utf8(&rendered[at..])
                    .unwrap()
                    .trim_start()
                    .starts_with("<img")
            ),
            _ => unreachable!(),
        }
    }
    if parsed.is_kf8_only() {
        return;
    }
    let legacy = extract_text_blob(parsed, &parsed.kf7);
    let html = std::str::from_utf8(&legacy).unwrap();
    let start = u32_be(parsed.kf7.exth_first(116).expect("MOBI StartReading"), 0) as usize;
    assert_eq!(element_text(&legacy, start), "第一章 雾起");
    let refs =
        regex::Regex::new(r#"<reference type="(cover|toc|text)" title="[^"]*" filepos=(\d{10})"#)
            .unwrap();
    assert_eq!(refs.captures_iter(html).count(), 3);
    for cap in refs.captures_iter(html) {
        let at: usize = cap[2].parse().unwrap();
        match &cap[1] {
            "text" => assert_eq!(at, start),
            "toc" => assert_eq!(element_text(&legacy, at), "目录"),
            "cover" => assert!(html[at..].starts_with("<img")),
            _ => unreachable!(),
        }
    }
    // Adding a guide moves every body; ordinary hyperlinks must move with it.
    let links = regex::Regex::new(r#"<a filepos=(\d{10})[^>]*>([^<]+)</a>"#).unwrap();
    assert_eq!(links.captures_iter(html).count(), 2);
    for cap in links.captures_iter(html) {
        let expected = if &cap[2] == "返回目录" {
            "目录"
        } else {
            "第一章 雾起"
        };
        assert_eq!(element_text(&legacy, cap[1].parse().unwrap()), expected);
    }
}

#[test]
fn guide_and_landmarks_point_to_real_elements_in_both_formats() {
    for (name, guide, landmarks) in [
        (
            "guide",
            GUIDE,
            r#"<li><a epub:type="bodymatter" href="../正文%20章.xhtml#序">错误的备用起点</a></li>"#,
        ),
        ("landmarks", "", LANDMARKS),
        ("outside", GUIDE, ""),
    ] {
        let input = fixture(name, guide, landmarks);
        for legacy in [false, true] {
            for raw in [false, true] {
                verify(&build(&input, legacy, raw));
            }
        }
    }
}

#[test]
fn absent_or_unresolved_navigation_does_not_invent_a_start() {
    for (name, guide) in [
        ("absent", ""),
        (
            "missing",
            r#"<guide><reference type="text" href="正文%20章.xhtml#不存在"/><reference type="toc" href="missing.xhtml"/></guide>"#,
        ),
    ] {
        let input = fixture(name, guide, "");
        for legacy in [false, true] {
            let parsed = build(&input, legacy, false);
            assert!(parsed.kf7.exth_first(116).is_none());
            let section = parsed.kf8_or_kf7();
            assert!(section.exth_first(116).is_none());
            let header = parsed.palmdb.record(&parsed.raw, section.record_idx);
            assert_eq!(u32_be(header, 260), u32::MAX);
        }
    }
}
