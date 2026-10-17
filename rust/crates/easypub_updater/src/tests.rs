use super::*;
use ed25519_dalek::{Signer, SigningKey};
use std::collections::BTreeMap;

fn temp(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "easypub-updater-{name}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn manifest() -> Manifest {
    Manifest {
        schema: 1,
        product: PRODUCT.into(),
        release: 68,
        tag: "v68-20261017".into(),
        date: "2026-10-17".into(),
        package: PackageFile {
            name: "easypub-lvy-v68-20261017-win-x64.zip".into(),
            bytes: 42,
            sha256: sha256_hex(b"zip"),
            root: "easypub-lvy-v68-20261017-win-x64".into(),
        },
        notes: "本版新增：自动更新".into(),
    }
}

fn signed(m: &Manifest, key: &SigningKey) -> (Vec<u8>, String) {
    let bytes = serde_json::to_vec_pretty(m).unwrap();
    let sig = hex(&key.sign(&bytes).to_bytes());
    (bytes, sig)
}

#[test]
fn manifest_signature_accepts_only_trusted_untampered_and_valid_manifests() {
    let key = SigningKey::from_bytes(&[7; 32]);
    let other = SigningKey::from_bytes(&[9; 32]);
    let trusted = [key.verifying_key().to_bytes()];
    let (bytes, sig) = signed(&manifest(), &key);
    assert_eq!(verify_manifest(&bytes, &sig, &trusted).unwrap(), manifest());
    // 多把公钥时任一通过即可（换钥过渡期）。
    let both = [other.verifying_key().to_bytes(), trusted[0]];
    assert!(verify_manifest(&bytes, &sig, &both).is_ok());

    let mut tampered = bytes.clone();
    let i = tampered.iter().position(|b| *b == b'6').unwrap();
    tampered[i] = b'9';
    assert_eq!(
        verify_manifest(&tampered, &sig, &trusted),
        Err(UpdateError("update_signature_invalid"))
    );
    let (_, foreign) = signed(&manifest(), &other);
    assert_eq!(
        verify_manifest(&bytes, &foreign, &trusted),
        Err(UpdateError("update_signature_invalid"))
    );
    for bad in ["", "zz", &sig[..126]] {
        assert_eq!(
            verify_manifest(&bytes, bad, &trusted),
            Err(UpdateError("update_signature_invalid"))
        );
    }
    // 签名正确但字段越界：仍然拒绝。
    for edit in [
        |m: &mut Manifest| m.product = "other".into(),
        |m: &mut Manifest| m.release = 0,
        |m: &mut Manifest| m.package.name = "../evil.zip".into(),
        |m: &mut Manifest| m.package.root = "a/b".into(),
        |m: &mut Manifest| m.package.sha256 = "ABC".into(),
        |m: &mut Manifest| m.tag = "v68 x".into(),
    ] {
        let mut m = manifest();
        edit(&mut m);
        let (b, s) = signed(&m, &key);
        assert_eq!(
            verify_manifest(&b, &s, &trusted),
            Err(UpdateError("update_manifest_invalid"))
        );
    }
    // 未知字段也拒绝。
    let mut v = serde_json::to_value(manifest()).unwrap();
    v["url"] = serde_json::json!("https://evil.example/");
    let b = serde_json::to_vec(&v).unwrap();
    let s = hex(&key.sign(&b).to_bytes());
    assert_eq!(
        verify_manifest(&b, &s, &trusted),
        Err(UpdateError("update_manifest_invalid"))
    );
}

#[test]
fn release_numbers_come_from_version_json_or_old_package_names() {
    use serde_json::json;
    assert_eq!(release_of(&json!({"release":68,"version":"x"})), Some(68));
    assert_eq!(
        release_of(&json!({"package":"easypub-lvy-v63-20261016-win-x64"})),
        Some(63)
    );
    assert_eq!(
        release_of(&json!({"version":"easypub-lvy-v61-20261015-win-x64"})),
        Some(61)
    );
    assert_eq!(release_of(&json!({"version":"desk-r2"})), None);
    assert_eq!(release_of(&json!({})), None);
}

fn write(root: &Path, files: &[(&str, &str)]) {
    for (path, text) in files {
        let p = root.join(path);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, text).unwrap();
    }
}

fn listing(root: &Path) -> BTreeMap<String, String> {
    fn walk(base: &Path, dir: &Path, out: &mut BTreeMap<String, String>) {
        for e in fs::read_dir(dir).unwrap() {
            let p = e.unwrap().path();
            if p.is_dir() {
                walk(base, &p, out);
            } else {
                out.insert(
                    p.strip_prefix(base)
                        .unwrap()
                        .to_string_lossy()
                        .replace('\\', "/"),
                    fs::read_to_string(&p).unwrap(),
                );
            }
        }
    }
    let mut out = BTreeMap::new();
    walk(root, root, &mut out);
    out
}

fn old_app(root: &Path) {
    let manifest = serde_json::json!({"files":[
        {"path":"easypub_desktop.exe"},{"path":"a.dll"},{"path":"old_only.dll"},
        {"path":"data/app.so"},{"path":"converters/kindling.exe"},{"path":"version.json"}
    ]});
    write(
        root,
        &[
            ("easypub_desktop.exe", "old exe"),
            ("a.dll", "old a"),
            ("old_only.dll", "old only"),
            ("data/app.so", "old so"),
            ("converters/kindling.exe", "old kindling"),
            ("version.json", r#"{"release":67}"#),
            ("package-manifest.json", &manifest.to_string()),
            ("用户自己的笔记.txt", "keep me"),
            (".update/updater.log", "log"),
        ],
    );
}

fn new_package(root: &Path) {
    write(
        root,
        &[
            ("easypub_desktop.exe", "new exe"),
            ("a.dll", "new a"),
            ("new_only.dll", "new only"),
            ("data/app.so", "new so"),
            ("converters/kindling.exe", "new kindling"),
            ("version.json", r#"{"release":68}"#),
            ("package-manifest.json", r#"{"files":[]}"#),
        ],
    );
}

#[test]
fn swap_replaces_package_files_keeps_user_files_and_backs_up_old_version() {
    let root = temp("swap");
    let (app, staging) = (root.join("app"), root.join("app/.update/staging"));
    old_app(&app);
    new_package(&staging);
    let backup = app.join(".update/backup-new");
    swap(&app, &staging, &backup, &app.join(".update/journal.json")).unwrap();
    let after = listing(&app);
    assert_eq!(after["easypub_desktop.exe"], "new exe");
    assert_eq!(after["a.dll"], "new a");
    assert_eq!(after["new_only.dll"], "new only");
    assert_eq!(after["data/app.so"], "new so");
    assert_eq!(
        after["用户自己的笔记.txt"], "keep me",
        "不在旧清单里的文件不动"
    );
    assert!(!after.contains_key("old_only.dll"), "旧版独有文件移到备份");
    assert_eq!(read_release(&app), Some(68));
    let saved = listing(&backup);
    assert_eq!(saved["easypub_desktop.exe"], "old exe");
    assert_eq!(saved["old_only.dll"], "old only");
    assert_eq!(saved["converters/kindling.exe"], "old kindling");
    assert!(!saved.contains_key("用户自己的笔记.txt"));
    assert!(!app.join(".update/journal.json").exists());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn failure_at_any_step_restores_the_old_version_exactly() {
    let probe = temp("probe");
    old_app(&probe.join("app"));
    new_package(&probe.join("app/.update/staging"));
    let (out, inc) = plan_swap(&probe.join("app"), &probe.join("app/.update/staging")).unwrap();
    let steps = out.len() + inc.len();
    fs::remove_dir_all(probe).unwrap();
    for k in 0..steps {
        let root = temp("fail");
        let (app, staging) = (root.join("app"), root.join("app/.update/staging"));
        old_app(&app);
        new_package(&staging);
        let before = listing(&app);
        let backup = app.join(".update/backup-new");
        let result = swap_with(
            &app,
            &staging,
            &backup,
            &app.join(".update/journal.json"),
            |i| {
                if i == k { Err(()) } else { Ok(()) }
            },
        );
        assert_eq!(
            result,
            Err(UpdateError("update_replace_failed")),
            "step {k}"
        );
        assert_eq!(listing(&app), before, "step {k}: 程序目录恢复原样");
        assert!(!backup.exists(), "step {k}");
        fs::remove_dir_all(root).unwrap();
    }
}

#[test]
fn interrupted_replacement_is_undone_from_the_journal() {
    let root = temp("recover");
    let (app, staging) = (root.join("app"), root.join("app/.update/staging"));
    old_app(&app);
    new_package(&staging);
    let before = listing(&app);
    // 模拟断电：已经移走两项、移入一项，日志还在。
    let backup = app.join(".update/backup-new");
    fs::create_dir_all(&backup).unwrap();
    let moves = vec![
        (app.join("a.dll"), backup.join("a.dll")),
        (
            app.join("easypub_desktop.exe"),
            backup.join("easypub_desktop.exe"),
        ),
        (
            staging.join("easypub_desktop.exe"),
            app.join("easypub_desktop.exe"),
        ),
    ];
    for (from, to) in &moves {
        fs::rename(from, to).unwrap();
    }
    let journal = app.join(".update/journal.json");
    fs::write(&journal, serde_json::to_vec(&Journal { moves }).unwrap()).unwrap();
    assert!(recover(&journal));
    assert_eq!(listing(&app), before);
    assert!(!recover(&journal), "日志已清除");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn staging_without_the_main_program_is_rejected() {
    let root = temp("bad-staging");
    let (app, staging) = (root.join("app"), root.join("app/.update/staging"));
    old_app(&app);
    write(&staging, &[("a.dll", "new a")]);
    let before = listing(&app);
    assert_eq!(
        swap(
            &app,
            &staging,
            &app.join(".update/b"),
            &app.join(".update/j.json")
        ),
        Err(UpdateError("update_staging_invalid"))
    );
    assert_eq!(listing(&app), before);
    fs::remove_dir_all(root).unwrap();
}
