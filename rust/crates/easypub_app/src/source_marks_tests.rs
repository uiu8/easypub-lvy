use super::*;
use crate::{epub_import, inline_styles::Style};
use easypub_core::source::{RULE_ID, SourceSnapshot};
use std::io::Write;
use zip::{ZipWriter, write::SimpleFileOptions};

const CSS: &str = ".zhong { font-weight: bold }\nspan.xie { font-style: italic }\n";
const PAGE1: &str = r##"<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><link rel="stylesheet" href="s.css"/></head><body>
<h1>第一章 <b>开始</b></h1>
<p>这里有<b>粗体</b>和<i>斜体</i>，还有 <em>强
调</em> 和<u>下划线</u>。</p>
<p>水是H<sub>2</sub>O，面积是m<sup>2</sup>，<span class="zhong">类粗体</span><span class="xie">类斜体</span>。</p>
<p><b>整行粗体不算</b></p>
<p>看<a href="https://example.com/a?b=1&amp;c=2">这个网站</a>，还有脚注<a epub:type="noteref" href="#n1">[1]</a>和<a href="p2.xhtml#x">跳到别处</a>。</p>
<table><tr><th>名</th><th>值</th></tr><tr><td>甲</td><td>一</td></tr><tr><td colspan="2">合并</td></tr></table>
<table><tr><td>版式表格里的字</td></tr></table>
<aside epub:type="footnote" id="n1"><p>脚注正文<a href="#back">↩</a></p></aside>
</body></html>"##;
const PAGE2: &str = r#"<html xmlns="http://www.w3.org/1999/xhtml"><body><h1 id="x">第二章</h1><p>重复重复<b>重复</b>。</p></body></html>"#;

fn epub(path: &std::path::Path) {
    let mut zip = ZipWriter::new(std::fs::File::create(path).unwrap());
    let options = SimpleFileOptions::default();
    let mut add = |name: &str, body: &str| {
        zip.start_file(name, options).unwrap();
        zip.write_all(body.as_bytes()).unwrap();
    };
    add(
        "META-INF/container.xml",
        r#"<container><rootfiles><rootfile full-path="OEBPS/c.opf"/></rootfiles></container>"#,
    );
    add(
        "OEBPS/c.opf",
        r#"<package xmlns="http://www.idpf.org/2007/opf"><metadata/><manifest>
<item id="a" href="p1.xhtml" media-type="application/xhtml+xml"/><item id="b" href="p2.xhtml" media-type="application/xhtml+xml"/>
<item id="c" href="s.css" media-type="text/css"/></manifest><spine><itemref idref="a"/><itemref idref="b"/></spine></package>"#,
    );
    add("OEBPS/s.css", CSS);
    add("OEBPS/p1.xhtml", PAGE1);
    add("OEBPS/p2.xhtml", PAGE2);
    zip.finish().unwrap();
}

/// 测试用的临时目录，用完删掉。
struct Temp(std::path::PathBuf);
impl Temp {
    fn new() -> Self {
        static NEXT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!("easypub-marks-{}-{n}", std::process::id()));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn path(&self) -> &std::path::Path {
        &self.0
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

struct Fixture {
    _dir: Temp,
    text: String,
    report: Value,
    data: Data,
    selection: Selection,
}
fn fixture() -> Fixture {
    let dir = Temp::new();
    let source = dir.path().join("书.epub");
    epub(&source);
    let source = source.to_str().unwrap();
    let text_path = dir.path().join("book.txt");
    epub_import::extract(source, text_path.to_str().unwrap(), true).unwrap();
    let resources = dir.path().join("res");
    let report: Value = serde_json::from_str(
        &epub_import::extract_resources(source, resources.to_str().unwrap(), true).unwrap(),
    )
    .unwrap();
    let report = report["source_marks"].clone();
    let data = serde_json::from_slice(&fs::read(resources.join(FILE_NAME)).unwrap()).unwrap();
    let selection = Selection {
        path: report["path"].as_str().unwrap().to_owned(),
        sha256: report["sha256"].as_str().unwrap().to_owned(),
        marks: 0,
        tables: 0,
        styles_off: false,
        removed: Vec::new(),
    };
    Fixture {
        text: fs::read_to_string(text_path).unwrap(),
        report,
        data,
        selection,
        _dir: dir,
    }
}
fn settings(selection: Option<&Selection>) -> Value {
    json!({"title":"书", "author":"作者", "description":"", "language":"zh-CN", "cover_fit":"contain",
        "font_family":"SimSun", "font_size":20, "line_height":1.8, "include_toc":true,
        "illustrations":[], "fullwidth_indent":2, "source_marks": selection})
}
fn request(source: &SourceSnapshot, settings: Value) -> crate::publication_resources::Request {
    serde_json::from_value(
        json!({"source_id":source.summary().source_id,"revision":1,"settings":settings}),
    )
    .unwrap()
}
fn resolved(text: &str, selection: &Selection) -> (Resolved, EffectiveBook) {
    let source = SourceSnapshot::from_utf8(text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
    let (book, settings) =
        crate::publication_resources::compose(&source, request(&source, settings(Some(selection))))
            .unwrap();
    (resolve(&settings, &book).unwrap(), book)
}
fn styled<'a>(result: &'a Resolved, book: &'a EffectiveBook, style: Style) -> Vec<&'a str> {
    result
        .styles
        .iter()
        .filter(|a| a.style == style)
        .map(|a| &book.text[a.anchor.start + a.anchor.from..a.anchor.start + a.anchor.to])
        .collect()
}

#[test]
fn import_reads_styles_links_notes_and_tables_without_touching_text() {
    let f = fixture();
    assert!(f.text.contains("这里有粗体和斜体，还有 强 调 和下划线。"));
    assert!(f.text.contains("〔表格：3 行 2 列〕\n"));
    assert!(f.text.contains("版式表格里的字"));
    assert_eq!(f.report["tables"], 1);
    assert_eq!(f.report["notes"], 1);
    assert_eq!(f.report["links"], 1);
    // “跳到别处”不是脚注；脚注里的返回链接不算。
    assert_eq!(f.report["dropped_links"], 1);
    let table = &f.data.tables[0];
    assert_eq!((table.rows.len(), table.columns), (3, 2));
    assert!(table.rows[0][0].head);
    assert_eq!(table.rows[2][0].columns, 2);

    let (result, book) = resolved(&f.text, &f.selection);
    // 标题里的粗体、整行粗体都不要。
    assert_eq!(
        styled(&result, &book, Style::Bold),
        ["粗体", "类粗体", "重复"]
    );
    assert_eq!(
        styled(&result, &book, Style::Italic),
        ["斜体", "强 调", "类斜体"]
    );
    assert_eq!(styled(&result, &book, Style::Underline), ["下划线"]);
    assert_eq!(styled(&result, &book, Style::Sub), ["2"]);
    assert_eq!(styled(&result, &book, Style::Sup), ["2"]);
    let link = result
        .styles
        .iter()
        .find(|a| a.style == Style::Link)
        .unwrap();
    assert_eq!(link.href.as_deref(), Some("https://example.com/a?b=1&c=2"));
    assert_eq!(result.notes.len(), 1);
    assert_eq!(result.tables.len(), 1);
    // “重复”第 3 次出现才是粗体。
    let repeat = result.styles.iter().find(|a| {
        a.style == Style::Bold
            && &book.text[a.anchor.start + a.anchor.from..a.anchor.start + a.anchor.to] == "重复"
    });
    assert_eq!(repeat.unwrap().anchor.from, "重复重复".len());
    // 全部能过手工样式的校验规则。
    for a in &result.styles {
        assert_eq!(crate::inline_styles::invalid_reason(a, &book), None);
    }
}

#[test]
fn marks_survive_edits_elsewhere_and_only_the_edited_ones_stop() {
    let f = fixture();
    // 模拟改了前面的内容：同样的行数，前面的字节变长。
    let changed = f
        .text
        .replacen("这里有粗体和斜体", "这里有很多很多字，粗体和斜体", 1);
    let (result, book) = resolved(&changed, &f.selection);
    assert_eq!(
        styled(&result, &book, Style::Bold),
        ["粗体", "类粗体", "重复"]
    );
    // 被改掉的文字那一条停用，其余不受影响。
    let changed = f.text.replacen("下划线", "画线", 1);
    let (result, book) = resolved(&changed, &f.selection);
    assert!(styled(&result, &book, Style::Underline).is_empty());
    assert_eq!(styled(&result, &book, Style::Italic).len(), 3);
    // 占位行被改掉就不是表格了。
    let changed = f.text.replacen("〔表格：3 行 2 列〕", "这里原来有张表", 1);
    assert!(resolved(&changed, &f.selection).0.tables.is_empty());
}

#[test]
fn removing_one_or_all_keeps_tables() {
    let f = fixture();
    let (result, _) = resolved(&f.text, &f.selection);
    let total = result.styles.len();
    let mut selection = f.selection.clone();
    selection.removed.push(result.styles[0].id.clone());
    assert_eq!(resolved(&f.text, &selection).0.styles.len(), total - 1);
    selection.styles_off = true;
    let (off, _) = resolved(&f.text, &selection);
    assert!(off.styles.is_empty() && off.notes.is_empty());
    assert_eq!(off.tables.len(), 1);
}

#[test]
fn generated_book_has_styles_links_notes_and_a_real_table() {
    let f = fixture();
    let source = SourceSnapshot::from_utf8(f.text.as_bytes().to_vec(), RULE_ID, || false).unwrap();
    let prepared = crate::publication_resources::prepare(
        &source,
        request(&source, settings(Some(&f.selection))),
    )
    .unwrap();
    let pages = crate::publication_documents::prepare(&prepared)
        .unwrap()
        .pages;
    let body = pages
        .values()
        .map(String::as_str)
        .collect::<Vec<_>>()
        .join("\n");
    for piece in [
        "<span class=\"inline-bold\">粗体</span>",
        "<span class=\"inline-italic\">斜体</span>",
        "H<span class=\"inline-sub\">2</span>O",
        "m<span class=\"inline-sup\">2</span>",
        "<a class=\"inline-link\" href=\"https://example.com/a?b=1&amp;c=2\">这个网站</a>",
        "<table class=\"book-table\" data-source=\"true\" data-original=\"〔表格：3 行 2 列〕\"",
        "<th>名</th>",
        "<td colspan=\"2\">合并</td>",
    ] {
        assert!(body.contains(piece), "{piece}\n{body}");
    }
    assert!(body.contains("noteref"));
    assert!(prepared.manifest().stylesheet.css.contains(".inline-bold"));
    assert!(prepared.manifest().stylesheet.css.contains(".note-ref"));
    assert!(prepared.manifest().stylesheet.css.contains(".book-table"));
    assert!(prepared.manifest().stylesheet.css.contains(".inline-sup"));
    assert!(!body.contains(">〔表格"));
}

#[test]
fn switching_off_reads_exactly_like_before() {
    let dir = Temp::new();
    let source = dir.path().join("a.epub");
    epub(&source);
    let source = source.to_str().unwrap();
    let plain = dir.path().join("plain.txt");
    epub_import::extract(source, plain.to_str().unwrap(), false).unwrap();
    let text = fs::read_to_string(&plain).unwrap();
    assert!(text.contains("名值\n甲一\n合并\n"));
    let report: Value = serde_json::from_str(
        &epub_import::extract_resources(source, dir.path().join("r").to_str().unwrap(), false)
            .unwrap(),
    )
    .unwrap();
    assert!(report["source_marks"].is_null());
    assert!(!dir.path().join("r").join(FILE_NAME).exists());
}

#[test]
fn old_books_can_read_marks_when_the_text_still_matches() {
    let dir = Temp::new();
    let source = dir.path().join("a.epub");
    epub(&source);
    let source = source.to_str().unwrap();
    let text = dir.path().join("old.txt");
    epub_import::extract(source, text.to_str().unwrap(), false).unwrap();
    let target = dir.path().join("marks");
    let report: Value = serde_json::from_str(
        &epub_import::reread_marks(source, text.to_str().unwrap(), target.to_str().unwrap())
            .unwrap(),
    )
    .unwrap();
    // 旧书的表格已经是文字，不补。
    assert_eq!(report["tables"], 0);
    assert_eq!(report["notes"], 1);
    fs::write(&text, "不一样的文字\n").unwrap();
    let error = epub_import::reread_marks(source, text.to_str().unwrap(), target.to_str().unwrap())
        .unwrap_err();
    assert_eq!(error.next_action, "source_marks_text_mismatch");
}

#[test]
fn a_missing_file_is_reported_not_ignored() {
    let f = fixture();
    let mut selection = f.selection.clone();
    selection.sha256 = "0".repeat(64);
    assert_eq!(
        selection.inspect().unwrap_err().next_action,
        "restore_source_marks"
    );
}

#[test]
fn output_text_keeps_table_cells_apart() {
    let dir = Temp::new();
    let source = dir.path().join("a.epub");
    epub(&source);
    let (text, ..) =
        epub_import::text_from_epub(fs::read(&source).unwrap(), epub_import::Reading::Output)
            .unwrap();
    assert!(text.contains("名 值\n甲 一\n合并\n"));
}

/// 导入和列表耗时，开关前后交替测：`cargo test --release -p easypub_app --lib big_book -- --ignored --nocapture`。
#[test]
#[ignore]
fn big_book_timing() {
    use std::time::Instant;
    let dir = Temp::new();
    let source = dir.path().join("big.epub");
    let mut zip = ZipWriter::new(std::fs::File::create(&source).unwrap());
    let options = SimpleFileOptions::default();
    let mut add = |name: &str, body: &str| {
        zip.start_file(name, options).unwrap();
        zip.write_all(body.as_bytes()).unwrap();
    };
    add(
        "META-INF/container.xml",
        r#"<container><rootfiles><rootfile full-path="OEBPS/c.opf"/></rootfiles></container>"#,
    );
    let (mut items, mut spine) = (String::new(), String::new());
    for i in 0..800 {
        items.push_str(&format!(
            r#"<item id="p{i}" href="p{i}.xhtml" media-type="application/xhtml+xml"/>"#
        ));
        spine.push_str(&format!(r#"<itemref idref="p{i}"/>"#));
    }
    add(
        "OEBPS/c.opf",
        &format!(
            r#"<package xmlns="http://www.idpf.org/2007/opf"><metadata/><manifest>{items}<item id="c" href="s.css" media-type="text/css"/></manifest><spine>{spine}</spine></package>"#
        ),
    );
    add("OEBPS/s.css", CSS);
    for i in 0..800 {
        let mut page = format!(
            r#"<html xmlns="http://www.w3.org/1999/xhtml"><head><link rel="stylesheet" href="s.css"/></head><body><h1>第{i}章 标题</h1>"#
        );
        for j in 0..120 {
            page.push_str(&format!("<p>这是第{j}段正文，用来撑起篇幅，大约有一行多的字数，<b>这里加粗</b>，后面还有一些<i>斜体</i>文字。</p>"));
        }
        page.push_str("</body></html>");
        add(&format!("OEBPS/p{i}.xhtml"), &page);
    }
    zip.finish().unwrap();
    let source = source.to_str().unwrap();
    let (mut plain, mut marks) = (Vec::new(), Vec::new());
    for round in 0..5 {
        for keep in [false, true] {
            let text = dir.path().join(format!("{round}{keep}.txt"));
            let res = dir.path().join(format!("r{round}{keep}"));
            let at = Instant::now();
            epub_import::extract(source, text.to_str().unwrap(), keep).unwrap();
            epub_import::extract_resources(source, res.to_str().unwrap(), keep).unwrap();
            let ms = at.elapsed().as_secs_f64() * 1000.0;
            if keep { marks.push(ms) } else { plain.push(ms) }
        }
    }
    println!("导入 关 {plain:.0?} ms\n导入 开 {marks:.0?} ms");
    let res = dir.path().join("r0true");
    let bytes = fs::read(res.join(FILE_NAME)).unwrap();
    println!("文件 {} 字节", bytes.len());
    let selection = Selection {
        path: res.join(FILE_NAME).to_str().unwrap().to_owned(),
        sha256: digest(&bytes),
        marks: 0,
        tables: 0,
        styles_off: false,
        removed: Vec::new(),
    };
    let text = fs::read_to_string(dir.path().join("0true.txt")).unwrap();
    println!("正文 {} 字节", text.len());
    let snapshot = SourceSnapshot::from_utf8(text.into_bytes(), RULE_ID, || false).unwrap();
    let (book, settings) = crate::publication_resources::compose(
        &snapshot,
        request(&snapshot, settings(Some(&selection))),
    )
    .unwrap();
    for _ in 0..3 {
        let at = Instant::now();
        let resolved = resolve(&settings, &book).unwrap();
        let resolve_ms = at.elapsed().as_secs_f64() * 1000.0;
        let at = Instant::now();
        let report = crate::inline_styles::report(&settings, &book);
        let report_ms = at.elapsed().as_secs_f64() * 1000.0;
        println!(
            "{} 条：算位置 {resolve_ms:.0} ms，列表 {report_ms:.0} ms，JSON {} 字节",
            resolved.styles.len(),
            report.to_string().len()
        );
    }
    let at = Instant::now();
    let prepared = crate::publication_resources::prepare(
        &snapshot,
        request(&snapshot, self::settings(Some(&selection))),
    )
    .unwrap();
    let plan = at.elapsed().as_secs_f64() * 1000.0;
    let at = Instant::now();
    let pages = crate::publication_documents::prepare(&prepared)
        .unwrap()
        .pages;
    println!(
        "计划 {plan:.0} ms，生成页面 {:.0} ms，{} 页",
        at.elapsed().as_secs_f64() * 1000.0,
        pages.len()
    );
}
