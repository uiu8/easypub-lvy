//! 按完整轮廓建立字体指纹，不根据 cmap 的编号猜测文字。
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use ttf_parser::{Face, GlyphId, OutlineBuilder};

pub const MAX_FONT: usize = 16 * 1024 * 1024;
const MAX_POINTS: usize = 2_000_000;
struct Outline {
    hash: Sha256,
    points: usize,
}
impl Outline {
    fn add(&mut self, op: u8, values: &[f32]) {
        self.points += 1;
        if self.points > MAX_POINTS {
            return;
        }
        self.hash.update([op]);
        for value in values {
            self.hash.update(value.to_bits().to_be_bytes());
        }
    }
}
impl OutlineBuilder for Outline {
    fn move_to(&mut self, x: f32, y: f32) {
        self.add(0, &[x, y]);
    }
    fn line_to(&mut self, x: f32, y: f32) {
        self.add(1, &[x, y]);
    }
    fn quad_to(&mut self, x: f32, y: f32, x1: f32, y1: f32) {
        self.add(2, &[x, y, x1, y1]);
    }
    fn curve_to(&mut self, x: f32, y: f32, x1: f32, y1: f32, x2: f32, y2: f32) {
        self.add(3, &[x, y, x1, y1, x2, y2]);
    }
    fn close(&mut self) {
        self.add(4, &[]);
    }
}
pub fn decode(value: &Value) -> Result<Vec<u8>, String> {
    if let Some(s) = value.as_str() {
        if s.len() > MAX_FONT * 2 {
            return Err("字体数据超过上限".into());
        }
        let data = crate::crypto::unb64(s).ok_or("字体 Base64 无效")?;
        if data.len() > MAX_FONT {
            return Err("字体数据超过上限".into());
        }
        return Ok(data);
    }
    value
        .as_array()
        .filter(|a| a.len() <= MAX_FONT)
        .ok_or("字体须为 Base64 或字节数组")?
        .iter()
        .map(|v| {
            v.as_i64()
                .filter(|v| (-128..=255).contains(v))
                .map(|v| v as u8)
                .ok_or("字体字节无效".into())
        })
        .collect()
}
pub fn query(data: &[u8]) -> Result<Value, String> {
    if data.len() > MAX_FONT {
        return Err("字体数据超过上限".into());
    }
    // Only standalone TrueType glyf fonts, no collections/CFF/WOFF/variable fonts.
    if !data.starts_with(&[0, 1, 0, 0]) {
        return Err("不支持的字体格式，仅支持静态 TrueType".into());
    }
    let face = Face::parse(data, 0).map_err(|_| "字体结构无效")?;
    if face.tables().glyf.is_none()
        || face.tables().cmap.is_none()
        || face
            .raw_face()
            .table(ttf_parser::Tag::from_bytes(b"fvar"))
            .is_some()
    {
        return Err("不支持的字体表结构".into());
    }
    let context = crate::control::current();
    let mut glyphs = serde_json::Map::new();
    let mut fingerprints = HashMap::<u16, Option<String>>::new();
    let mut remaining = MAX_POINTS;
    // Bounded Unicode scalar iteration avoids untrusted cmap ranges invoking an
    // unbounded callback loop. Each outline is expanded at most once per glyph.
    for cp in 0..=0x10ffff {
        if cp % 1024 == 0 {
            context.check()?;
        }
        let Some(ch) = char::from_u32(cp) else {
            continue;
        };
        let Some(id) = face.glyph_index(ch).filter(|id| id.0 != 0) else {
            continue;
        };
        if let std::collections::hash_map::Entry::Vacant(e) = fingerprints.entry(id.0) {
            let mut outline = Outline {
                hash: Sha256::new(),
                points: 0,
            };
            outline.hash.update(face.units_per_em().to_be_bytes());
            let valid = face.outline_glyph(GlyphId(id.0), &mut outline).is_some();
            if outline.points > remaining {
                return Err("字体轮廓复杂度超过上限".into());
            }
            remaining -= outline.points;
            e.insert((valid && outline.points > 0).then(|| hex::encode(outline.hash.finalize())));
        }
        if let Some(Some(hash)) = fingerprints.get(&id.0) {
            if glyphs.len() >= 65536 {
                return Err("字体映射数超过上限".into());
            }
            glyphs.insert(ch.to_string(), json!(hash));
        }
    }
    if glyphs.is_empty() {
        return Err("字体没有可用的 Unicode 轮廓映射".into());
    }
    Ok(Value::Object(glyphs))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        engine::{Engine, SourceRt},
        source::BookSource,
    };
    #[test]
    fn synthetic_outlines_and_unicode_mapping() {
        let context = crate::control::Context {
            pure_compute: true,
            ..Default::default()
        };
        let _guard = context.enter();
        let correct = include_bytes!("../tests/fonts/correct.ttf");
        let scrambled = include_bytes!("../tests/fonts/scrambled.ttf");
        let ambiguous = include_bytes!("../tests/fonts/ambiguous.ttf");
        let different = include_bytes!("../tests/fonts/different.ttf");
        let engine = Engine::new(SourceRt::new(BookSource::default())).unwrap();
        let fixtures = json!(
            [
                correct.as_slice(),
                scrambled.as_slice(),
                ambiguous.as_slice(),
                different.as_slice()
            ]
            .map(crate::crypto::b64)
        );
        engine.run(|s| {
            let script = format!(
                "var fonts={fixtures};\n{}",
                include_str!("font_compat_tests.js")
            );
            assert_eq!(s.eval_js_string(&script, &[]).unwrap(), "font-ok");
        });
        for len in [0, 4, 12, 100, correct.len() / 2] {
            assert!(query(&correct[..len]).is_err());
        }
        assert!(decode(&json!([256])).is_err());
        assert!(decode(&json!([0.5])).is_err());
        let context = crate::control::Context::default();
        context
            .cancel
            .store(true, std::sync::atomic::Ordering::Relaxed);
        let _guard = context.enter();
        assert!(query(correct).is_err());
    }
}
