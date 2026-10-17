use kindling::opf::OPFData;

#[test]
fn bibliography_does_not_confuse_package_identity_with_isbn() {
    let dir = std::env::temp_dir().join(format!("easypub-kindling-opf-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("book.opf");
    std::fs::write(&path, r#"<package unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="uid">urn:sha256:internal</dc:identifier>
        <dc:identifier>urn:isbn:9780306406157</dc:identifier>
        <dc:publisher>出版社 &amp; 合作方</dc:publisher>
        <dc:description>简介 &lt;正文&gt;</dc:description>
        <dc:subject>文学</dc:subject>
        <dc:creator>原作者</dc:creator>
        <dc:contributor id="translator">译者甲</dc:contributor>
        <dc:contributor>编辑乙</dc:contributor>
        </metadata><manifest/><spine/></package>"#).unwrap();
    let parsed = OPFData::parse(&path).unwrap();
    assert_eq!(parsed.identifier, "urn:sha256:internal");
    assert_eq!(parsed.isbn, "9780306406157");
    assert_eq!(parsed.publisher, "出版社 & 合作方");
    assert_eq!(parsed.description, "简介 <正文>");
    assert_eq!(parsed.subject, "文学");
    assert_eq!(parsed.author, "原作者");
    assert_eq!(parsed.contributors, ["译者甲", "编辑乙"]);
    std::fs::remove_file(&path).unwrap();
    std::fs::remove_dir(&dir).unwrap();
}
