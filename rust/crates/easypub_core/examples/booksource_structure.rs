//! 对下载 TXT 运行生产章节检查，只输出统计，不输出正文。
use easypub_core::{
    encoding::EncodingMode,
    source::{RULE_ID, SourceSnapshot},
};
fn main() {
    let path = std::env::args().nth(1).expect("传入 TXT 路径");
    let source = SourceSnapshot::from_bytes(
        std::fs::read(path).expect("读取 TXT"),
        EncodingMode::Auto,
        RULE_ID,
        || false,
    )
    .expect("识别 TXT");
    println!("{}", source.diagnostic_json());
}
