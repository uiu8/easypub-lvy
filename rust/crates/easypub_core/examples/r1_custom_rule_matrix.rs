use easypub_core::{ErrorCode, recognition::NumericRule};
use serde_json::json;

struct Case {
    name: &'static str,
    pattern: &'static str,
    line: &'static str,
    expected_compile: Option<ErrorCode>,
    expected_match: Option<(u32, &'static str)>,
}

fn main() {
    let cases = [
        Case {
            name: "dotnet_named_groups",
            pattern: r"^第(?<number>\d{1,6})章\s+(?<title>.+)$",
            line: "第12章 自定义标题",
            expected_compile: None,
            expected_match: Some((12, "自定义标题")),
        },
        Case {
            name: "unicode_letter_title",
            pattern: r"^(?<number>\d+)[、:_-]\s*(?<title>.+)$",
            line: "7、𠮷和组合字符 é",
            expected_compile: None,
            expected_match: Some((7, "𠮷和组合字符 é")),
        },
        Case {
            name: "unicode_property_title",
            pattern: r"^(?<number>\d+)\s+(?<title>[\p{L}].*)$",
            line: "8 跨语言标题",
            expected_compile: None,
            expected_match: Some((8, "跨语言标题")),
        },
        Case {
            name: "out_of_range_is_not_heading",
            pattern: r"^(?<number>\d+)\s+(?<title>.+)$",
            line: "10000 标题",
            expected_compile: None,
            expected_match: None,
        },
        Case {
            name: "missing_named_group",
            pattern: r"^(\d+)\s+(?<title>.+)$",
            line: "9 标题",
            expected_compile: Some(ErrorCode::InvalidRule),
            expected_match: None,
        },
        Case {
            name: "syntax_error",
            pattern: "[",
            line: "9 标题",
            expected_compile: Some(ErrorCode::InvalidRule),
            expected_match: None,
        },
        Case {
            name: "lookahead_rejected",
            pattern: r"^(?<number>\d+)(?!\d)(?<title>.+)$",
            line: "9 标题",
            expected_compile: Some(ErrorCode::UnsupportedRule),
            expected_match: None,
        },
        Case {
            name: "backreference_rejected",
            pattern: r"^(?<number>\d+)\s+(?<title>.+)\1$",
            line: "9 标题9",
            expected_compile: Some(ErrorCode::UnsupportedRule),
            expected_match: None,
        },
    ];

    let mut results = Vec::new();
    let mut failures = Vec::new();
    for case in cases {
        let compiled = NumericRule::compile(Some(case.pattern));
        let (compile_code, actual_match) = match compiled {
            Ok(rule) => {
                let actual = rule
                    .matches(case.line)
                    .map(|heading| json!({"number": heading.number, "title": heading.title}));
                (None, actual)
            }
            Err(error) => (Some(format!("{:?}", error.code)), None),
        };
        let expected_code = case
            .expected_compile
            .as_ref()
            .map(|code| format!("{code:?}"));
        let expected_match = case
            .expected_match
            .map(|(number, title)| json!({"number": number, "title": title}));
        let passed = compile_code == expected_code && actual_match == expected_match;
        if !passed {
            failures.push(case.name);
        }
        results.push(json!({
            "name": case.name,
            "pattern": case.pattern,
            "line": case.line,
            "compile": compile_code,
            "match": actual_match,
            "passed": passed,
        }));
    }

    let report = json!({
        "scope": "R1 custom numeric rule support and explicit failure policy",
        "engine": "Rust regex linear-time subset; no .NET runtime dependency",
        "cases": results.len(),
        "passed_cases": results.iter().filter(|item| item["passed"] == true).count(),
        "failures": failures,
        "passed": failures.is_empty(),
        "policy": {
            "supported": ["Rust regex linear-time syntax", ".NET named groups (?<name>...) normalized", "number/title named captures", "Unicode scalar titles"],
            "invalid": "syntax or missing required named groups => InvalidRule",
            "unsupported": "lookaround/backreference => UnsupportedRule",
            "fallback": "never silently fall back to the builtin rule",
        },
        "results": results,
    });
    println!("{}", serde_json::to_string_pretty(&report).unwrap());
    if !failures.is_empty() {
        std::process::exit(1);
    }
}
