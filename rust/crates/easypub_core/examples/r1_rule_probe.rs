use easypub_core::recognition::{NumericRule, is_default_heading};

fn main() {
    let headings = [
        ("chapter_with_di", "第一章 开始", true),
        ("chapter_without_di", "八百三十章 赌徒", true),
        ("volume_requires_di", "第十卷 上卷", true),
        ("bare_volume_is_prose", "十卷货物", false),
        ("special_heading", "序章", true),
        ("bare_section_is_prose", "九节鞭、三节棍", false),
        ("回_prose_prefix", "九回头看向门口", false),
    ];
    let mut heading_output = String::new();
    for (index, (name, line, expected)) in headings.iter().enumerate() {
        let actual = is_default_heading(line);
        assert_eq!(actual, *expected, "{name}");
        if index != 0 {
            heading_output.push(',');
        }
        heading_output.push_str(&format!("{{\"case\":\"{name}\",\"matched\":{actual}}}"));
    }

    let default_rule = NumericRule::compile(None).unwrap();
    assert_eq!(default_rule.matches("1. 第一章").unwrap().number, 1);
    assert!(default_rule.matches("1.2 不是标题").is_none());
    let custom = NumericRule::compile(Some(r"^第(?<number>\d+)章\s+(?<title>.+)$")).unwrap();
    assert_eq!(custom.matches("第12章 自定义").unwrap().number, 12);
    let invalid = NumericRule::compile(Some("[")).unwrap_err();
    let unsupported =
        NumericRule::compile(Some(r"^(?<number>\d+)(?!\d)(?<title>.+)$")).unwrap_err();

    println!(
        "{{\"default_heading\":[{heading_output}],\"numeric\":{{\"default_dot_guard\":true,\"custom_named_groups\":true,\"invalid_code\":\"{:?}\",\"unsupported_code\":\"{:?}\"}}}}",
        invalid.code, unsupported.code
    );
}
