use easypub_app::transaction::{InjectFault, apply_new_file, recover};
use std::{
    fs,
    path::PathBuf,
    time::{SystemTime, UNIX_EPOCH},
};

fn main() {
    let id = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!("easypub-r1-txn-probe-{id}"));
    fs::create_dir_all(&root).unwrap();
    let source = root.join("source.txt");
    let output = root.join("output.txt");
    let contents = "第一章 开始\r\n正文\n";
    fs::write(&source, contents.as_bytes()).unwrap();
    let fault = apply_new_file(&source, &output, InjectFault::AfterStage).unwrap_err();
    assert_eq!(format!("{:?}", fault.code), "Transaction");
    let transaction_dir = root.join(".output.txt.easypub-txn");
    let recovered = recover(&transaction_dir).unwrap();
    let recovered_again = recover(&transaction_dir).unwrap();
    assert!(recovered.output_exists && recovered.source_unchanged);
    assert_eq!(recovered.output_sha256, recovered_again.output_sha256);
    assert_eq!(fs::read(&output).unwrap(), contents.as_bytes());
    let source_after = fs::read(&source).unwrap();
    assert_eq!(source_after, contents.as_bytes());
    let conflict = apply_new_file(&source, &output, InjectFault::None).unwrap_err();
    println!(
        "{{\"fault_code\":\"{:?}\",\"recovered\":{},\"recovered_idempotent\":{},\"source_unchanged\":{},\"output_exists\":{},\"conflict_code\":\"{:?}\",\"transaction_dir\":\"{}\"}}",
        fault.code,
        recovered.recovered,
        recovered.output_sha256 == recovered_again.output_sha256,
        recovered.source_unchanged,
        recovered.output_exists,
        conflict.code,
        PathBuf::from(&recovered.transaction_dir).display()
    );
    let _ = fs::remove_dir_all(root);
}
