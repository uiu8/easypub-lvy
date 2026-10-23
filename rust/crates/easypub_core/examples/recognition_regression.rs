//! 只读目录识别探针；输出导入结构中的全部节点，供回归工具保留顺序与重复标题。
use easypub_core::{
    encoding::EncodingMode,
    source::{RULE_ID, SourceSnapshot},
    structure::Structure,
};
use serde_json::json;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = std::env::args_os().nth(1).ok_or("需要 TXT 路径")?;
    let bytes = std::fs::read(path)?;
    let source = SourceSnapshot::from_bytes(bytes, EncodingMode::Auto, RULE_ID, || false)
        .map_err(|e| format!("{e:?}"))?;
    let tree = Structure::recognized(&source)
        .tree(&source)
        .map_err(|e| format!("{e:?}"))?;
    println!("{}", json!({"nodes": tree.nodes}));
    Ok(())
}
