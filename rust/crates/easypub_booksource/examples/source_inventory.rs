//! cargo run -p easypub_booksource --example source_inventory -- INPUT OUTPUT
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 3 {
        return Err("用法：source_inventory 输入JSON 输出JSON".into());
    }
    let raw = std::fs::read(&args[1])?;
    let values: Vec<serde_json::Value> =
        serde_json::from_slice(&raw).map_err(|_| "输入必须是书源 JSON 数组")?;
    let report = easypub_booksource::inventory::analyze(&values)?;
    if std::path::Path::new(&args[2]).exists() {
        return Err("输出已存在，请另选路径，避免覆盖输入或旧证据".into());
    }
    std::fs::write(&args[2], serde_json::to_vec_pretty(&report)?)?;
    println!(
        "原始 {}，去重 {}，文字 {}，写法 {}",
        report.input_sources,
        report.unique_sources,
        report.text_sources,
        report.rows.len()
    );
    Ok(())
}
