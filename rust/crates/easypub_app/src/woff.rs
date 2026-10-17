//! Bounded WOFF 1 reconstruction for inspection only. Keep original resource bytes.
use std::io::Read;
const MAX: usize = 32 * 1024 * 1024;
fn u16_at(b: &[u8], p: usize) -> Option<u16> {
    Some(u16::from_be_bytes(b.get(p..p + 2)?.try_into().ok()?))
}
fn u32_at(b: &[u8], p: usize) -> Option<usize> {
    Some(u32::from_be_bytes(b.get(p..p + 4)?.try_into().ok()?) as usize)
}
fn padded(n: usize) -> usize {
    (n + 3) & !3
}
fn put32(b: &mut [u8], p: usize, n: usize) {
    b[p..p + 4].copy_from_slice(&(n as u32).to_be_bytes());
}

/// Metadata failure does not invalidate font tables; never interpret it as a grant.
pub(crate) fn license_metadata(b: &[u8]) -> Result<Option<(String, Option<String>)>, ()> {
    let offset = u32_at(b, 24).ok_or(())?;
    if offset == 0 {
        return Ok(None);
    }
    let len = u32_at(b, 28).ok_or(())?;
    let original = u32_at(b, 32).ok_or(())?;
    if original == 0 || original > 1024 * 1024 {
        return Err(());
    }
    let input = b
        .get(offset..offset.checked_add(len).ok_or(())?)
        .ok_or(())?;
    let mut decoder = flate2::bufread::ZlibDecoder::new(input);
    let mut bytes = Vec::new();
    decoder
        .by_ref()
        .take(original as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| ())?;
    if bytes.len() != original || decoder.total_in() != len as u64 {
        return Err(());
    }
    let xml = std::str::from_utf8(&bytes).map_err(|_| ())?;
    let doc = roxmltree::Document::parse_with_options(
        xml,
        roxmltree::ParsingOptions {
            allow_dtd: false,
            nodes_limit: 8192,
            ..Default::default()
        },
    )
    .map_err(|_| ())?;
    let root = doc.root_element();
    if root.tag_name().name() != "metadata" || root.attribute("version") != Some("1.0") {
        return Err(());
    }
    let licenses: Vec<_> = root
        .children()
        .filter(|n| n.has_tag_name("license"))
        .collect();
    if licenses.len() > 1 {
        return Err(());
    }
    let Some(license) = licenses.first() else {
        return Ok(None);
    };
    let mut texts = Vec::new();
    for node in license.children().filter(|n| n.has_tag_name("text")) {
        let text = node
            .descendants()
            .filter(|n| n.is_text())
            .filter_map(|n| n.text())
            .collect::<String>();
        if !text.trim().is_empty() {
            let language = node
                .attribute(("http://www.w3.org/XML/1998/namespace", "lang"))
                .unwrap_or("");
            texts.push(if language.is_empty() {
                text
            } else {
                format!("[{language}] {text}")
            });
        }
    }
    let text = texts.join("\n");
    let url = license.attribute("url").map(str::to_owned);
    if text.len() > 65536 || url.as_ref().is_some_and(|v| v.len() > 4096) {
        return Err(());
    }
    Ok(Some((text, url)))
}

pub(crate) fn decode(b: &[u8]) -> Option<Vec<u8>> {
    if b.len() < 44
        || b.len() > MAX
        || b.get(..4)? != b"wOFF"
        || u32_at(b, 8)? != b.len()
        || u16_at(b, 14)? != 0
    {
        return None;
    }
    let flavor = b.get(4..8)?;
    if flavor != [0, 1, 0, 0] && flavor != b"OTTO" && flavor != b"true" {
        return None;
    }
    let n = u16_at(b, 12)? as usize;
    if n == 0 || n > 4095 {
        return None;
    }
    let total = u32_at(b, 16)?;
    if total > MAX || total < 12 + 16 * n || total % 4 != 0 {
        return None;
    }
    let directory_end = 44 + 20 * n;
    b.get(..directory_end)?;
    let mut entries = Vec::with_capacity(n);
    let mut previous = None;
    let mut expected = 12 + 16 * n;
    for i in 0..n {
        let p = 44 + i * 20;
        let tag = b.get(p..p + 4)?;
        if previous.is_some_and(|old| old >= tag) {
            return None;
        }
        previous = Some(tag);
        let offset = u32_at(b, p + 4)?;
        let compressed = u32_at(b, p + 8)?;
        let original = u32_at(b, p + 12)?;
        if compressed > original || original > MAX || offset % 4 != 0 {
            return None;
        }
        expected = expected.checked_add(padded(original))?;
        if expected > total {
            return None;
        }
        b.get(offset..offset.checked_add(compressed)?)?;
        entries.push((offset, compressed, original, i));
    }
    if expected != total {
        return None;
    }
    entries.sort_by_key(|e| e.0);
    let mut cursor = directory_end;
    for &(offset, len, _, _) in &entries {
        if offset != cursor {
            return None;
        }
        let end = offset.checked_add(len)?;
        cursor = padded(end);
        if b.get(end..cursor)?.iter().any(|v| *v != 0) {
            return None;
        }
    }
    // Metadata is not required for rendering; preserve it in the WOFF resource.
    let meta = u32_at(b, 24)?;
    let meta_len = u32_at(b, 28)?;
    let meta_orig = u32_at(b, 32)?;
    if meta == 0 {
        if meta_len != 0 || meta_orig != 0 {
            return None;
        }
    } else {
        if meta != cursor || meta_len == 0 || meta_orig == 0 || meta_orig > MAX {
            return None;
        }
        cursor = meta.checked_add(meta_len)?;
        b.get(..cursor)?;
    }
    let private = u32_at(b, 36)?;
    let private_len = u32_at(b, 40)?;
    if private == 0 {
        if private_len != 0 {
            return None;
        }
    } else {
        if private != padded(cursor)
            || private_len == 0
            || b.get(cursor..private)?.iter().any(|v| *v != 0)
        {
            return None;
        }
        cursor = private.checked_add(private_len)?;
        b.get(..cursor)?;
    }
    if cursor != b.len() {
        return None;
    }
    let mut out = vec![0; total];
    out[..4].copy_from_slice(flavor);
    out[4..6].copy_from_slice(&(n as u16).to_be_bytes());
    let power = 1usize << n.ilog2();
    out[6..8].copy_from_slice(&((power * 16) as u16).to_be_bytes());
    out[8..10].copy_from_slice(&(n.ilog2() as u16).to_be_bytes());
    out[10..12].copy_from_slice(&((n * 16 - power * 16) as u16).to_be_bytes());
    let mut dst = 12 + 16 * n;
    for (offset, len, original, i) in entries {
        let input = &b[offset..offset + len];
        let bytes = if len == original {
            input.to_vec()
        } else {
            let mut decoder = flate2::bufread::ZlibDecoder::new(input);
            let mut data = Vec::new();
            decoder
                .by_ref()
                .take(original as u64 + 1)
                .read_to_end(&mut data)
                .ok()?;
            if data.len() != original || decoder.total_in() != len as u64 {
                return None;
            }
            data
        };
        let src = 44 + i * 20;
        let table = 12 + i * 16;
        out[table..table + 4].copy_from_slice(&b[src..src + 4]);
        out[table + 4..table + 8].copy_from_slice(&b[src + 16..src + 20]);
        put32(&mut out, table + 8, dst);
        put32(&mut out, table + 12, original);
        out[dst..dst + original].copy_from_slice(&bytes);
        dst += padded(original);
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    #[test]
    fn metadata_is_bounded_and_does_not_confuse_invalid_xml_with_license() {
        let pack = |xml: &str| {
            let mut b = sample(true);
            let mut z = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
            z.write_all(xml.as_bytes()).unwrap();
            let data = z.finish().unwrap();
            let offset = b.len();
            put32(&mut b, 24, offset);
            put32(&mut b, 28, data.len());
            put32(&mut b, 32, xml.len());
            b.extend(data);
            let len = b.len();
            put32(&mut b, 8, len);
            b
        };
        let b = pack(
            r#"<metadata version="1.0"><license url="https://example.invalid/license"><text xml:lang="zh">仅供<span>测试</span></text></license></metadata>"#,
        );
        assert_eq!(
            license_metadata(&b).unwrap().unwrap(),
            (
                "[zh] 仅供测试".into(),
                Some("https://example.invalid/license".into())
            )
        );
        for xml in [
            "<broken",
            "<!DOCTYPE metadata [<!ENTITY x 'abc'>]><metadata version='1.0'>&x;</metadata>",
            "<metadata version='1.0'><license/><license/></metadata>",
        ] {
            let b = pack(xml);
            assert!(decode(&b).is_some());
            assert!(license_metadata(&b).is_err());
        }
        let mut b = b;
        put32(&mut b, 32, 1024 * 1024 + 1);
        assert!(license_metadata(&b).is_err());
    }
    fn sample(compress: bool) -> Vec<u8> {
        let raw = vec![0; 128];
        let data = if compress {
            let mut z = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
            z.write_all(&raw).unwrap();
            z.finish().unwrap()
        } else {
            raw
        };
        let mut out = vec![0; 64];
        out[..4].copy_from_slice(b"wOFF");
        out[4..8].copy_from_slice(&[0, 1, 0, 0]);
        out[12..14].copy_from_slice(&1u16.to_be_bytes());
        put32(&mut out, 16, 156);
        out[44..48].copy_from_slice(b"test");
        put32(&mut out, 48, 64);
        put32(&mut out, 52, data.len());
        put32(&mut out, 56, 128);
        out.extend(data);
        out.resize(padded(out.len()), 0);
        let len = out.len();
        put32(&mut out, 8, len);
        out
    }
    #[test]
    fn bounded_tables_reconstruct_and_invalid_ranges_never_decode() {
        let a = sample(false);
        let b = sample(true);
        assert_eq!(decode(&a), decode(&b));
        assert_eq!(decode(&b).unwrap().len(), 156);
        for (offset, value) in [(8, 1), (16, MAX + 4), (48, 60), (52, 129), (56, 129)] {
            let mut bad = b.clone();
            put32(&mut bad, offset, value);
            assert!(decode(&bad).is_none());
        }
        let mut bad = b.clone();
        bad[14] = 1;
        assert!(decode(&bad).is_none());
        let mut bad = b.clone();
        bad[65] ^= 255;
        assert!(decode(&bad).is_none());
        let mut bad = b.clone();
        bad.extend([0; 4]);
        let len = bad.len();
        put32(&mut bad, 8, len);
        assert!(decode(&bad).is_none());
        for end in 0..b.len() {
            assert!(decode(&b[..end]).is_none());
        }
    }
}
