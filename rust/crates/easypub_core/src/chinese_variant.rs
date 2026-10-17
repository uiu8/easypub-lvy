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
    let (slot, config) = match direction {
        Direction::S2t => (&S2T, BuiltinConfig::S2t),
        Direction::T2s => (&T2S, BuiltinConfig::T2s),
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
        std::thread::scope(|scope| {
            for _ in 0..4 {
                scope.spawn(|| assert_eq!(s2t.convert(simple), traditional));
            }
        });
    }
}
