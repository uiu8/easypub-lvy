//! EPUB 自带字体还原成可直接嵌入的 TTF / OTF（V123，LAY-179）。
//!
//! 很多 EPUB 按 IDPF 或 Adobe 的办法把字体前 1040 / 1024 字节异或混淆，或者打包成 WOFF；
//! 原样提取出来的文件不能检查、也不能嵌入。这里只按 META-INF/encryption.xml 声明的方式还原，
//! 不破解任何加密，也不改原 EPUB。
use roxmltree::Document;
use std::collections::HashMap;

const IDPF: &str = "http://www.idpf.org/2008/embedding";
const ADOBE: &str = "http://ns.adobe.com/pdf/enc#RC";

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum Obfuscation {
    Idpf,
    Adobe,
}

impl Obfuscation {
    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Idpf => "idpf",
            Self::Adobe => "adobe",
        }
    }
}

/// encryption.xml 里声明了混淆方式的文件（按 ZIP 内路径）；其他加密方式不认，原样列出。
pub(crate) fn obfuscated(xml: &str) -> HashMap<String, Obfuscation> {
    let mut map = HashMap::new();
    let Ok(doc) = Document::parse(xml) else {
        return map;
    };
    for data in doc
        .descendants()
        .filter(|n| n.tag_name().name() == "EncryptedData")
    {
        let algorithm = data
            .descendants()
            .find(|n| n.tag_name().name() == "EncryptionMethod")
            .and_then(|n| n.attribute("Algorithm"));
        let kind = match algorithm {
            Some(IDPF) => Obfuscation::Idpf,
            Some(ADOBE) => Obfuscation::Adobe,
            _ => continue,
        };
        if let Some(uri) = data
            .descendants()
            .find(|n| n.tag_name().name() == "CipherReference")
            .and_then(|n| n.attribute("URI"))
        {
            map.insert(percent_decode(uri.trim_start_matches('/')), kind);
        }
    }
    map
}

/// 包文档里 unique-identifier 指向的标识；IDPF 混淆用它，Adobe 用其中的 UUID。
pub(crate) fn package_identifier(opf: &Document) -> String {
    let root = opf.root_element();
    let wanted = root.attribute("unique-identifier");
    let identifiers = opf
        .descendants()
        .filter(|n| n.is_element() && n.tag_name().name() == "identifier");
    let mut first = None;
    for node in identifiers {
        let text = node.text().unwrap_or("").to_owned();
        if wanted.is_some() && node.attribute("id") == wanted {
            return text;
        }
        first.get_or_insert(text);
    }
    first.unwrap_or_default()
}

/// 按声明的方式还原混淆字体；标识不合用时返回 None。
pub(crate) fn deobfuscate(bytes: &[u8], kind: Obfuscation, identifier: &str) -> Option<Vec<u8>> {
    let (key, span) = match kind {
        Obfuscation::Idpf => {
            let cleaned: String = identifier
                .chars()
                .filter(|c| !matches!(c, ' ' | '\t' | '\r' | '\n'))
                .collect();
            if cleaned.is_empty() {
                return None;
            }
            (sha1(cleaned.as_bytes()).to_vec(), 1040)
        }
        Obfuscation::Adobe => {
            let hex: String = identifier
                .trim()
                .trim_start_matches("urn:uuid:")
                .chars()
                .filter(|c| c.is_ascii_hexdigit())
                .collect();
            if hex.len() != 32 {
                return None;
            }
            let key = (0..16)
                .map(|i| u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).ok())
                .collect::<Option<Vec<_>>>()?;
            (key, 1024)
        }
    };
    let mut out = bytes.to_vec();
    for (i, b) in out.iter_mut().take(span).enumerate() {
        *b ^= key[i % key.len()];
    }
    Some(out)
}

/// 字体文件的格式：TTF / OTF / TTC 可直接用，WOFF 可解包，WOFF2 暂不支持。
pub(crate) fn format(bytes: &[u8]) -> &'static str {
    match bytes.get(..4) {
        Some(b"OTTO") => "otf",
        Some([0, 1, 0, 0]) | Some(b"true") => "ttf",
        Some(b"ttcf") => "ttc",
        Some(b"wOFF") => "woff",
        Some(b"wOF2") => "woff2",
        _ => "unknown",
    }
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%'
            && i + 2 < b.len()
            && let Some(v) = std::str::from_utf8(&b[i + 1..i + 3])
                .ok()
                .and_then(|h| u8::from_str_radix(h, 16).ok())
        {
            out.push(v);
            i += 3;
            continue;
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn sha1(data: &[u8]) -> [u8; 20] {
    let mut h: [u32; 5] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0];
    let mut msg = data.to_vec();
    let bits = (data.len() as u64).wrapping_mul(8);
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bits.to_be_bytes());
    for chunk in msg.chunks(64) {
        let mut w = [0u32; 80];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([
                chunk[i * 4],
                chunk[i * 4 + 1],
                chunk[i * 4 + 2],
                chunk[i * 4 + 3],
            ]);
        }
        for i in 16..80 {
            w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotate_left(1);
        }
        let [mut a, mut b, mut c, mut d, mut e] = h;
        for (i, &wi) in w.iter().enumerate() {
            let (f, k) = match i {
                0..=19 => ((b & c) | (!b & d), 0x5A827999),
                20..=39 => (b ^ c ^ d, 0x6ED9EBA1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1BBCDC),
                _ => (b ^ c ^ d, 0xCA62C1D6),
            };
            let t = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(wi);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = t;
        }
        for (x, y) in h.iter_mut().zip([a, b, c, d, e]) {
            *x = x.wrapping_add(y);
        }
    }
    let mut out = [0u8; 20];
    for (i, v) in h.iter().enumerate() {
        out[i * 4..i * 4 + 4].copy_from_slice(&v.to_be_bytes());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha1_matches_known_digests() {
        let hex = |d: [u8; 20]| d.iter().map(|b| format!("{b:02x}")).collect::<String>();
        assert_eq!(
            hex(sha1(b"abc")),
            "a9993e364706816aba3e25717850c26c9cd0d89d"
        );
        assert_eq!(hex(sha1(b"")), "da39a3ee5e6b4b0d3255bfef95601890afd80709");
    }

    #[test]
    fn obfuscation_round_trips_and_reads_declarations() {
        let mut font = (0..3000u32)
            .map(|i| (i * 7 % 251) as u8)
            .collect::<Vec<_>>();
        font[..4].copy_from_slice(&[0, 1, 0, 0]);
        for (kind, id) in [
            (Obfuscation::Idpf, " urn:isbn:978 7\n"),
            (
                Obfuscation::Adobe,
                "urn:uuid:0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0",
            ),
        ] {
            let hidden = deobfuscate(&font, kind, id).unwrap();
            assert_ne!(format(&hidden), "ttf");
            assert_eq!(deobfuscate(&hidden, kind, id).unwrap(), font);
        }
        assert!(deobfuscate(&font, Obfuscation::Adobe, "urn:isbn:1").is_none());
        let map = obfuscated(
            r#"<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#"><enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/><enc:CipherData><enc:CipherReference URI="OEBPS/Fonts/%E5%AE%8B.ttf"/></enc:CipherData></enc:EncryptedData><enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/><enc:CipherData><enc:CipherReference URI="OEBPS/a.xhtml"/></enc:CipherData></enc:EncryptedData></encryption>"#,
        );
        assert_eq!(map.len(), 1);
        assert_eq!(map["OEBPS/Fonts/宋.ttf"], Obfuscation::Idpf);
        let opf = Document::parse(r#"<package unique-identifier="bid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="x">a</dc:identifier><dc:identifier id="bid">urn:uuid:1</dc:identifier></metadata></package>"#).unwrap();
        assert_eq!(package_identifier(&opf), "urn:uuid:1");
    }
}
