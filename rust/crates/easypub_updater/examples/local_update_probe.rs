//! 仅对调用者准备的副本进行离线升级/回退，不启动应用、不访问网络。
use easypub_updater::{PUBLIC_KEYS, read_release, sha256_hex, swap, verify_manifest};
use std::{collections::BTreeMap, fs, path::Path};

fn hashes(root: &Path) -> BTreeMap<String, String> {
    fn walk(root: &Path, dir: &Path, out: &mut BTreeMap<String, String>) {
        for entry in fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            if path == root.join(".update") {
                continue;
            }
            if path.is_dir() {
                walk(root, &path, out);
            } else {
                out.insert(
                    path.strip_prefix(root)
                        .unwrap()
                        .to_string_lossy()
                        .into_owned(),
                    sha256_hex(&fs::read(path).unwrap()),
                );
            }
        }
    }
    let mut result = BTreeMap::new();
    walk(root, root, &mut result);
    result
}

fn main() {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    assert_eq!(args.len(), 4, "app-copy staging manifest zip");
    let (app, staging, manifest, zip) = (
        Path::new(&args[0]),
        Path::new(&args[1]),
        Path::new(&args[2]),
        Path::new(&args[3]),
    );
    let signed = verify_manifest(
        &fs::read(manifest).unwrap(),
        &fs::read_to_string(manifest.with_extension("json.sig")).unwrap(),
        PUBLIC_KEYS,
    )
    .unwrap();
    let bytes = fs::read(zip).unwrap();
    assert_eq!(bytes.len() as u64, signed.package.bytes);
    assert_eq!(sha256_hex(&bytes), signed.package.sha256);
    assert_eq!(read_release(app), Some(94));
    assert_eq!(read_release(staging), Some(95));
    let old = hashes(app);
    let new = hashes(staging);
    let work = app.join(".update");
    let backup = work.join("backup");
    let journal = work.join("journal.json");
    swap(app, staging, &backup, &journal).unwrap();
    assert_eq!(hashes(app), new);
    assert_eq!(read_release(app), Some(95));
    swap(app, &backup, &work.join("rollback-backup"), &journal).unwrap();
    assert_eq!(hashes(app), old);
    assert_eq!(read_release(app), Some(94));
    println!(
        "{}",
        serde_json::json!({"signature_verified":true,"zip_sha256":signed.package.sha256,"old_files":old.len(),"new_files":new.len(),"upgrade_hashes_equal":true,"rollback_hashes_equal":true,"app_launched":false})
    );
}
