//! Pinned offline dictionaries, shared lazily per direction across all books.
use crate::{ApiError, ErrorCode};
use ferrous_opencc::{OpenCC, config::BuiltinConfig};
use serde::{Deserialize, Serialize};
use std::sync::OnceLock;

pub const DICTIONARY_VERSION: &str = "ferrous-opencc-0.4.0";

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Direction {
    S2t,
    T2s,
    /// V113：台湾正体、香港繁体，及含台湾常用词（如“软件 ↔ 軟體”）的转换。
    S2tw,
    S2twp,
    S2hk,
    Tw2s,
    Tw2sp,
    Hk2s,
}

impl Direction {
    /// 转成简体的方向（繁→简、台湾→简、香港→简）。
    pub(crate) fn to_simplified(&self) -> bool {
        matches!(self, Self::T2s | Self::Tw2s | Self::Tw2sp | Self::Hk2s)
    }
}

/// 是否为 GB2312 里的汉字（简体常用字表，GBK 编码首字节 0xB0–0xF7、次字节 0xA1–0xFE）。
fn gb2312_hanzi(c: char) -> bool {
    if (c as u32) < 0x4E00 {
        return false;
    }
    let mut buf = [0u8; 4];
    let (bytes, _, unmappable) = encoding_rs::GBK.encode(c.encode_utf8(&mut buf));
    !unmappable
        && bytes.len() == 2
        && (0xB0..=0xF7).contains(&bytes[0])
        && (0xA1..=0xFE).contains(&bytes[1])
}

/// 繁→简时保护已是简体的字（V116）：这一行基本是简体（GB2312 以外的汉字不到一成）时，
/// 原本就在 GB2312 简体字表里的字保持原样，只换真正的繁体字。例如简体书里的“覆上了”
/// 不会被改成“复上了”，混进来的“機”仍换成“机”。整行是繁体时照常全部转换；
/// 字数有变化的词组转换（极少）也照常。
pub(crate) fn protect_simplified(input: &str, output: String) -> String {
    if input == output {
        return output;
    }
    let hanzi: Vec<char> = input.chars().filter(|&c| c as u32 >= 0x4E00).collect();
    let traditional = hanzi.iter().filter(|&&c| !gb2312_hanzi(c)).count();
    if hanzi.is_empty() || traditional * 10 >= hanzi.len() {
        return output;
    }
    if input.chars().count() != output.chars().count() {
        return output;
    }
    input
        .chars()
        .zip(output.chars())
        .map(|(a, b)| if a != b && gb2312_hanzi(a) { a } else { b })
        .collect()
}

pub(crate) fn converter(direction: &Direction, version: &str) -> Result<&'static OpenCC, ApiError> {
    if version != DICTIONARY_VERSION {
        return Err(ApiError::new(
            ErrorCode::UnsupportedRule,
            "chinese_variant_dictionary",
            "review_dictionary_version",
        ));
    }
    static S2T: OnceLock<Result<OpenCC, ApiError>> = OnceLock::new();
    static T2S: OnceLock<Result<OpenCC, ApiError>> = OnceLock::new();
    static S2TW: OnceLock<Result<OpenCC, ApiError>> = OnceLock::new();
    static S2TWP: OnceLock<Result<OpenCC, ApiError>> = OnceLock::new();
    static S2HK: OnceLock<Result<OpenCC, ApiError>> = OnceLock::new();
    static TW2S: OnceLock<Result<OpenCC, ApiError>> = OnceLock::new();
    static TW2SP: OnceLock<Result<OpenCC, ApiError>> = OnceLock::new();
    static HK2S: OnceLock<Result<OpenCC, ApiError>> = OnceLock::new();
    let (slot, config) = match direction {
        Direction::S2t => (&S2T, BuiltinConfig::S2t),
        Direction::T2s => (&T2S, BuiltinConfig::T2s),
        Direction::S2tw => (&S2TW, BuiltinConfig::S2tw),
        Direction::S2twp => (&S2TWP, BuiltinConfig::S2twp),
        Direction::S2hk => (&S2HK, BuiltinConfig::S2hk),
        Direction::Tw2s => (&TW2S, BuiltinConfig::Tw2s),
        Direction::Tw2sp => (&TW2SP, BuiltinConfig::Tw2sp),
        Direction::Hk2s => (&HK2S, BuiltinConfig::Hk2s),
    };
    slot.get_or_init(|| {
        OpenCC::from_config(config).map_err(|_| {
            ApiError::new(
                ErrorCode::Internal,
                "chinese_variant_dictionary",
                "check_dictionary_installation",
            )
        })
    })
    .as_ref()
    .map_err(Clone::clone)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn phrase_disambiguation_and_shared_instances() {
        let s2t = converter(&Direction::S2t, DICTIONARY_VERSION).unwrap();
        let t2s = converter(&Direction::T2s, DICTIONARY_VERSION).unwrap();
        let simple = "头发发展，皇后后来，干燥干活。ASCII e\u{301} 😀𠀀\r\n";
        let traditional = "頭髮發展，皇后後來，乾燥幹活。ASCII e\u{301} 😀𠀀\r\n";
        assert_eq!(s2t.convert(simple), traditional);
        assert_eq!(t2s.convert(traditional), simple);
        assert!(std::ptr::eq(
            s2t,
            converter(&Direction::S2t, DICTIONARY_VERSION).unwrap()
        ));
        assert!(converter(&Direction::S2t, "future-dictionary").is_err());
        // V116：简体行里的“覆”不被改成“复”，混进来的繁体“機”照常换成“机”；整行繁体照常转换。
        let raw = "他一边機械地迈动步子，直接低头覆上了她的唇。";
        assert_eq!(
            protect_simplified(raw, t2s.convert(raw)),
            "他一边机械地迈动步子，直接低头覆上了她的唇。"
        );
        assert_eq!(
            protect_simplified(traditional, t2s.convert(traditional)),
            simple
        );
        // V113：台湾用词转换会改词，不只改字形。
        let twp = converter(&Direction::S2twp, DICTIONARY_VERSION).unwrap();
        assert_eq!(twp.convert("软件"), "軟體");
        let back = converter(&Direction::Tw2sp, DICTIONARY_VERSION).unwrap();
        assert_eq!(back.convert("軟體"), "软件");
        for d in [
            Direction::S2tw,
            Direction::S2hk,
            Direction::Tw2s,
            Direction::Hk2s,
        ] {
            assert!(
                !converter(&d, DICTIONARY_VERSION)
                    .unwrap()
                    .convert("头发")
                    .is_empty()
            );
        }
        std::thread::scope(|scope| {
            for _ in 0..4 {
                scope.spawn(|| assert_eq!(s2t.convert(simple), traditional));
            }
        });
    }
}
