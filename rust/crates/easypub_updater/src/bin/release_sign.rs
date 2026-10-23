//! 发布签名工具（V68，只在发布者本机使用，不进发布包）。
//!   release_sign keygen --out <私钥文件>
//!       生成 Ed25519 密钥：私钥以十六进制写入文件（文件已存在则拒绝），公钥打印出来，填进 lib.rs 的 RELEASE_KEY。
//!   release_sign manifest --key <私钥文件> --zip <发布包> --release <批次号> --tag <tag> --date <日期>
//!                         --root <包内顶层文件夹> --notes <说明文本文件> --out <输出目录>
//!       生成 update-manifest.json 与 update-manifest.json.sig；写完后用程序内置公钥复核，不一致就失败。
use easypub_updater::{
    MANIFEST_NAME, Manifest, PRODUCT, PUBLIC_KEYS, PackageFile, SIGNATURE_NAME, hex, sha256_hex,
    unhex, verify_manifest,
};
use ed25519_dalek::{Signer, SigningKey};
use std::{collections::HashMap, fs, path::Path, process::exit};

fn fail(msg: &str) -> ! {
    eprintln!("release_sign: {msg}");
    exit(1)
}

#[cfg(windows)]
fn random32() -> [u8; 32] {
    use windows_sys::Win32::Security::Cryptography::{
        BCRYPT_USE_SYSTEM_PREFERRED_RNG, BCryptGenRandom,
    };
    let mut buf = [0u8; 32];
    // SAFETY: 缓冲区长度与传入长度一致。
    let status = unsafe {
        BCryptGenRandom(
            std::ptr::null_mut(),
            buf.as_mut_ptr(),
            buf.len() as u32,
            BCRYPT_USE_SYSTEM_PREFERRED_RNG,
        )
    };
    if status != 0 {
        fail("system random generator failed");
    }
    buf
}

#[cfg(not(windows))]
fn random32() -> [u8; 32] {
    fail("keygen is only supported on Windows")
}

fn key(path: &str) -> SigningKey {
    let text = fs::read_to_string(path).unwrap_or_else(|_| fail("cannot read key file"));
    let bytes: [u8; 32] = unhex(&text)
        .and_then(|b| b.try_into().ok())
        .unwrap_or_else(|| fail("key file is not 64 hex characters"));
    SigningKey::from_bytes(&bytes)
}

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let Some(command) = argv.first() else {
        fail("usage: keygen | manifest (see source header)")
    };
    let opts: HashMap<&str, &str> = argv[1..]
        .chunks(2)
        .map(|c| {
            if c.len() != 2 || !c[0].starts_with("--") {
                fail("options must be --name value pairs")
            }
            (&c[0][2..], c[1].as_str())
        })
        .collect();
    let get = |k: &str| {
        opts.get(k)
            .copied()
            .unwrap_or_else(|| fail(&format!("missing --{k}")))
    };
    match command.as_str() {
        "keygen" => {
            let out = Path::new(get("out"));
            if out.exists() {
                fail("key file already exists; refusing to overwrite");
            }
            let signing = SigningKey::from_bytes(&random32());
            if let Some(dir) = out.parent() {
                fs::create_dir_all(dir).unwrap_or_else(|_| fail("cannot create key directory"));
            }
            fs::write(out, hex(&signing.to_bytes()))
                .unwrap_or_else(|_| fail("cannot write key file"));
            let public = signing.verifying_key().to_bytes();
            println!("public key (hex): {}", hex(&public));
            println!(
                "RELEASE_KEY = [{}];",
                public
                    .iter()
                    .map(|b| format!("0x{b:02x}"))
                    .collect::<Vec<_>>()
                    .join(", ")
            );
        }
        "manifest" => {
            let signing = key(get("key"));
            let zip = Path::new(get("zip"));
            let data = fs::read(zip).unwrap_or_else(|_| fail("cannot read zip"));
            let notes =
                fs::read_to_string(get("notes")).unwrap_or_else(|_| fail("cannot read notes"));
            let manifest = Manifest {
                schema: 1,
                product: PRODUCT.into(),
                release: get("release")
                    .parse()
                    .unwrap_or_else(|_| fail("bad --release")),
                tag: get("tag").into(),
                date: get("date").into(),
                package: PackageFile {
                    name: zip
                        .file_name()
                        .and_then(|n| n.to_str())
                        .unwrap_or_else(|| fail("bad zip name"))
                        .into(),
                    bytes: data.len() as u64,
                    sha256: sha256_hex(&data),
                    root: get("root").into(),
                },
                notes,
            };
            manifest
                .validate()
                .unwrap_or_else(|e| fail(&format!("manifest invalid: {e}")));
            let bytes = serde_json::to_vec_pretty(&manifest).expect("manifest json");
            let signature = hex(&signing.sign(&bytes).to_bytes());
            verify_manifest(&bytes, &signature, PUBLIC_KEYS).unwrap_or_else(|e| {
                fail(&format!(
                    "signature does not verify with the public key built into the app ({e}); \
                     is RELEASE_KEY in lib.rs the key for this private key?"
                ))
            });
            let out = Path::new(get("out"));
            fs::create_dir_all(out).unwrap_or_else(|_| fail("cannot create --out"));
            fs::write(out.join(MANIFEST_NAME), &bytes).unwrap_or_else(|_| fail("write manifest"));
            fs::write(out.join(SIGNATURE_NAME), &signature)
                .unwrap_or_else(|_| fail("write signature"));
            println!(
                "{} release {} sha256 {}",
                MANIFEST_NAME, manifest.release, manifest.package.sha256
            );
        }
        _ => fail("unknown command"),
    }
}
