//! Read-only recognition previews. Applying uses the normal effective-edit history.
use crate::{edit_checkpoint, effective_draft::Base, sessions::ImportService};
use easypub_core::{
    ApiError, ErrorCode,
    chapter_rules::{RuleSet, rebuild},
    effective_edit,
};
use serde::Deserialize;
use serde_json::{Value, json};
fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "chapter_rules",
        "请重新读取本书并检查规则",
    )
}
// 每次调用只反序列化一个请求，变体大小差异不影响内存占用。
#[allow(clippy::large_enum_variant)]
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Request {
    Defaults,
    /// Read-only description of the built-in rules (CH-248).
    Builtin,
    Validate {
        rules: RuleSet,
    },
    Sample {
        rules: RuleSet,
        text: String,
    },
    Preview {
        source_id: String,
        revision: u32,
        base: Base,
        post_edits: Option<edit_checkpoint::EditRequest>,
        rules: RuleSet,
        #[serde(default = "yes")]
        preserve_decisions: bool,
    },
}
fn yes() -> bool {
    true
}
pub fn request(service: &ImportService, raw: &str) -> Result<String, ApiError> {
    if raw.len() > 4 * 1024 * 1024 {
        return Err(invalid());
    }
    let result = match serde_json::from_str(raw).map_err(|_| invalid())? {
        Request::Defaults => {
            json!({"rules":RuleSet::default(),"compatibility":"支持Rust正则及number/title命名组；内置规则使用等价实现。自定义环视、反向引用不受支持。"})
        }
        Request::Builtin => easypub_core::recognition::builtin_description(),
        Request::Validate { rules } => {
            rules.compile()?;
            json!({"rules":rules,"fingerprint":rules.fingerprint()})
        }
        Request::Sample { rules, text } => {
            if text.len() > 8192 || text.contains(['\r', '\n']) {
                return Err(invalid());
            }
            let compiled = rules.compile()?;
            json!({"match":compiled.matched(&text),"fingerprint":rules.fingerprint(),"note":"单行只判断格式；数字候选还需核对正文证据。"})
        }
        Request::Preview {
            source_id,
            revision,
            base,
            post_edits,
            rules,
            preserve_decisions,
        } => {
            let source = service.source(&source_id, revision)?;
            let mut before = base.compose(&source)?;
            if let Some(edits) = post_edits {
                before = edit_checkpoint::apply(before, &edits)?.0;
            }
            let base_id = effective_edit::base_id(&before);
            let original_text = before.text.clone();
            let text_lines: Vec<_> = original_text.lines().collect();
            let excerpt = |line: u32| {
                text_lines
                    .iter()
                    .skip((line as usize).saturating_sub(2))
                    .take(6)
                    .map(|s| s.chars().take(250).collect::<String>())
                    .collect::<Vec<_>>()
                    .join("\n")
            };
            let old = before
                .tree
                .nodes
                .iter()
                .map(|n| (n.source_line, n.clone()))
                .collect::<std::collections::BTreeMap<_, _>>();
            // 例外规则（V17）改变的是检查结果而不是目录，单独列出前后数量。
            let counts = |book: &easypub_core::publication::EffectiveBook| {
                easypub_core::source::SourceSnapshot::for_effective_diagnostics(book)
                    .map(|view| view.exception_finding_counts())
            };
            let checks_before = counts(&before)?;
            let (after, summary) = rebuild(before, &rules, preserve_decisions)?;
            let checks_after = counts(&after)?;
            let check_changes = [
                ("duplicate-title", "连续重复标题", checks_before.0, checks_after.0),
                ("number-gap", "章节编号跳跃", checks_before.1, checks_after.1),
            ]
            .into_iter()
            .filter(|(_, _, a, b)| a != b)
            .map(|(id, title, a, b)| json!({"id":id,"title":title,"before":a,"after":b}))
            .collect::<Vec<_>>();
            let new = after
                .tree
                .nodes
                .iter()
                .map(|n| (n.source_line, n))
                .collect::<std::collections::BTreeMap<_, _>>();
            let mut changes = Vec::<Value>::new();
            for (line, node) in &new {
                match old.get(line) {
                    None=>changes.push(json!({"kind":"added","line":line,"after":node.title,"role":node.role,"depth":node.depth,"include_toc":node.include_toc})),
                    Some(previous) if previous.title!=node.title||previous.role!=node.role||previous.depth!=node.depth||previous.include_toc!=node.include_toc=>changes.push(json!({"kind":"changed","line":line,"before":previous.title,"after":node.title,"before_role":previous.role,"role":node.role,"before_depth":previous.depth,"depth":node.depth,"before_include_toc":previous.include_toc,"include_toc":node.include_toc})),
                    _=>{}
                }
            }
            for (line, node) in &old {
                if !new.contains_key(line) {
                    changes.push(json!({"kind":"removed","line":line,"before":node.title}));
                }
            }
            changes.sort_by_key(|v| v["line"].as_u64());
            for change in &mut changes {
                change["excerpt"] = json!(excerpt(change["line"].as_u64().unwrap_or(1) as u32));
            }
            let matches=after.tree.nodes.iter().map(|node|json!({"line":node.source_line,"after":node.title,"role":node.role,"excerpt":excerpt(node.source_line)})).collect::<Vec<_>>();
            json!({"base_id":base_id,"rules":rules,"fingerprint":rules.fingerprint(),"summary":summary,"total":new.len(),"changes":changes,"check_changes":check_changes,"matches":matches,"source_unchanged":true})
        }
    };
    serde_json::to_string(&result).map_err(|_| invalid())
}
