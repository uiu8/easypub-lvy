//! Explicit source decoding for the R1 compatibility gate.
//!
//! This module deliberately separates detection from decoding.  Detection is
//! only a policy choice; every decoder is strict and never replaces malformed
//! input with U+FFFD.  The original bytes remain owned by `SourceSnapshot`, so
//! an unedited source can be written back byte-for-byte without re-encoding it.

use crate::{ApiError, ErrorCode};
use encoding_rs::GBK;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EncodingKind {
    Utf8,
    Utf16Le,
    Utf16Be,
    Utf32Le,
    Utf32Be,
    Cp936,
}

impl EncodingKind {
    pub fn label(self) -> &'static str {
        match self {
            Self::Utf8 => "utf-8",
            Self::Utf16Le => "utf-16le",
            Self::Utf16Be => "utf-16be",
            Self::Utf32Le => "utf-32le",
            Self::Utf32Be => "utf-32be",
            Self::Cp936 => "cp936",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EncodingMode {
    Auto,
    Utf8,
    Utf16Le,
    Utf16Be,
    Utf32Le,
    Utf32Be,
    Cp936,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DecodedText {
    pub text: String,
    pub encoding: EncodingKind,
    pub bom: Vec<u8>,
}

impl DecodedText {
    pub fn has_bom(&self) -> bool {
        !self.bom.is_empty()
    }
}

/// Encode an edited copy without replacement characters or newline normalization.
/// Unedited snapshots must use their original bytes to preserve legacy mappings.
pub fn encode(text: &str, kind: EncodingKind, with_bom: bool) -> Result<Vec<u8>, ApiError> {
    let bom: &[u8] = match kind {
        EncodingKind::Utf8 => &[0xef, 0xbb, 0xbf],
        EncodingKind::Utf16Le => &[0xff, 0xfe],
        EncodingKind::Utf16Be => &[0xfe, 0xff],
        EncodingKind::Utf32Le => &[0xff, 0xfe, 0, 0],
        EncodingKind::Utf32Be => &[0, 0, 0xfe, 0xff],
        EncodingKind::Cp936 => &[],
    };
    if kind == EncodingKind::Cp936 && with_bom {
        return Err(ApiError::new(
            ErrorCode::InvalidEncoding,
            "encode_cp936",
            "remove_bom_or_choose_utf8",
        ));
    }
    let mut bytes = if with_bom { bom.to_vec() } else { Vec::new() };
    match kind {
        EncodingKind::Utf8 => bytes.extend_from_slice(text.as_bytes()),
        EncodingKind::Utf16Le | EncodingKind::Utf16Be => {
            for unit in text.encode_utf16() {
                let encoded = if kind == EncodingKind::Utf16Le {
                    unit.to_le_bytes()
                } else {
                    unit.to_be_bytes()
                };
                bytes.extend_from_slice(&encoded);
            }
        }
        EncodingKind::Utf32Le | EncodingKind::Utf32Be => {
            for scalar in text.chars() {
                let encoded = if kind == EncodingKind::Utf32Le {
                    (scalar as u32).to_le_bytes()
                } else {
                    (scalar as u32).to_be_bytes()
                };
                bytes.extend_from_slice(&encoded);
            }
        }
        EncodingKind::Cp936 => bytes.extend_from_slice(&encode_cp936(text)?),
    }
    Ok(bytes)
}

#[cfg(test)]
mod output_tests {
    use super::*;

    #[test]
    fn cp936_matches_frozen_dotnet_decode_and_encode_oracle() {
        let oracle: serde_json::Value =
            serde_json::from_str(include_str!("../../../../fixtures/r1-2/cp936-oracle.json"))
                .unwrap();
        for (i, expected) in oracle["decoded"].as_array().unwrap().iter().enumerate() {
            let bytes = if i < 256 {
                vec![i as u8]
            } else {
                vec![((i - 256) >> 8) as u8, (i - 256) as u8]
            };
            let actual = decode(&bytes, EncodingMode::Cp936).ok().map(|d| d.text);
            assert_eq!(actual.as_deref(), expected.as_str(), "decode {bytes:02x?}");
        }
        for (scalar, expected) in oracle["encoded"].as_array().unwrap().iter().enumerate() {
            let actual = char::from_u32(scalar as u32)
                .and_then(|c| encode(&c.to_string(), EncodingKind::Cp936, false).ok())
                .map(|bytes| bytes.iter().map(|b| format!("{b:02X}")).collect::<String>());
            assert_eq!(
                actual.as_deref(),
                expected.as_str(),
                "encode U+{scalar:04X}"
            );
        }
    }

    #[test]
    fn cp936_mixed_mapping_spans_do_not_consume_invalid_trails() {
        let text = "正文\u{f8f5}\u{e7c7}\r\n尾€";
        let bytes = encode(text, EncodingKind::Cp936, false).unwrap();
        assert_eq!(decode(&bytes, EncodingMode::Cp936).unwrap().text, text);
        assert!(decode(&[b'a', 0x81, 0xff, b'b'], EncodingMode::Cp936).is_err());
        assert!(decode(&[0xff, 0x81], EncodingMode::Cp936).is_err());
    }

    #[test]
    fn edited_unicode_roundtrips_bom_endianness_and_mixed_newlines() {
        for (kind, mode) in [
            (EncodingKind::Utf8, EncodingMode::Utf8),
            (EncodingKind::Utf16Le, EncodingMode::Utf16Le),
            (EncodingKind::Utf16Be, EncodingMode::Utf16Be),
            (EncodingKind::Utf32Le, EncodingMode::Utf32Le),
            (EncodingKind::Utf32Be, EncodingMode::Utf32Be),
        ] {
            for text in ["", "\u{feff}第一章😀𠮷\r\n正文e\u{301}\n末行\r尾"] {
                for bom in [false, true] {
                    let encoded = encode(text, kind, bom).unwrap();
                    // A leading content FEFF with no BOM is inherently ambiguous on decode.
                    if !bom && text.starts_with('\u{feff}') {
                        continue;
                    }
                    let decoded = decode(&encoded, mode).unwrap();
                    assert_eq!(decoded.text, text);
                    assert_eq!(decoded.has_bom(), bom);
                    assert_eq!(encode(&decoded.text, kind, bom).unwrap(), encoded);
                }
            }
        }
    }

    #[test]
    fn cp936_rejects_unrepresentable_edits_without_returning_replacement_bytes() {
        let text = "第一章 修改\r\n正文\n尾";
        let bytes = encode(text, EncodingKind::Cp936, false).unwrap();
        assert_eq!(decode(&bytes, EncodingMode::Cp936).unwrap().text, text);
        for text in ["正文😀", "正文𠮷", "e\u{301}"] {
            let error = encode(text, EncodingKind::Cp936, false).unwrap_err();
            assert_eq!(error.code, ErrorCode::InvalidEncoding);
        }
        assert!(encode("", EncodingKind::Cp936, true).is_err());
    }
}

pub fn decode(bytes: &[u8], mode: EncodingMode) -> Result<DecodedText, ApiError> {
    let (kind, bom_length) = match mode {
        EncodingMode::Auto => detect(bytes),
        EncodingMode::Utf8 => (EncodingKind::Utf8, utf8_bom_length(bytes)),
        EncodingMode::Utf16Le => (EncodingKind::Utf16Le, bom_length(bytes, &[0xff, 0xfe])),
        EncodingMode::Utf16Be => (EncodingKind::Utf16Be, bom_length(bytes, &[0xfe, 0xff])),
        EncodingMode::Utf32Le => (
            EncodingKind::Utf32Le,
            bom_length(bytes, &[0xff, 0xfe, 0, 0]),
        ),
        EncodingMode::Utf32Be => (
            EncodingKind::Utf32Be,
            bom_length(bytes, &[0, 0, 0xfe, 0xff]),
        ),
        EncodingMode::Cp936 => (EncodingKind::Cp936, 0),
    };
    let payload = &bytes[bom_length..];
    let text = match kind {
        EncodingKind::Utf8 => std::str::from_utf8(payload)
            .map(str::to_owned)
            .map_err(|_| {
                ApiError::new(
                    ErrorCode::InvalidUtf8,
                    "decode_utf8",
                    "choose_valid_utf8_or_auto",
                )
            })?,
        EncodingKind::Utf16Le => decode_utf16(payload, false)?,
        EncodingKind::Utf16Be => decode_utf16(payload, true)?,
        EncodingKind::Utf32Le => decode_utf32(payload, false)?,
        EncodingKind::Utf32Be => decode_utf32(payload, true)?,
        EncodingKind::Cp936 => decode_cp936(payload)?,
    };
    Ok(DecodedText {
        text,
        encoding: kind,
        bom: bytes[..bom_length].to_vec(),
    })
}

fn detect(bytes: &[u8]) -> (EncodingKind, usize) {
    // Match the longer UTF-32 prefixes before UTF-16, as the first two bytes
    // of a UTF-32 BOM are also a UTF-16 BOM.
    if bytes.starts_with(&[0xff, 0xfe, 0, 0]) {
        return (EncodingKind::Utf32Le, 4);
    }
    if bytes.starts_with(&[0, 0, 0xfe, 0xff]) {
        return (EncodingKind::Utf32Be, 4);
    }
    if bytes.starts_with(&[0xef, 0xbb, 0xbf]) {
        return (EncodingKind::Utf8, 3);
    }
    if bytes.starts_with(&[0xff, 0xfe]) {
        return (EncodingKind::Utf16Le, 2);
    }
    if bytes.starts_with(&[0xfe, 0xff]) {
        return (EncodingKind::Utf16Be, 2);
    }
    if std::str::from_utf8(bytes).is_ok() {
        (EncodingKind::Utf8, 0)
    } else {
        (EncodingKind::Cp936, 0)
    }
}

fn utf8_bom_length(bytes: &[u8]) -> usize {
    if bytes.starts_with(&[0xef, 0xbb, 0xbf]) {
        3
    } else {
        0
    }
}

fn bom_length(bytes: &[u8], bom: &[u8]) -> usize {
    if bytes.starts_with(bom) { bom.len() } else { 0 }
}

fn decode_utf16(bytes: &[u8], big_endian: bool) -> Result<String, ApiError> {
    if !bytes.len().is_multiple_of(2) {
        return Err(ApiError::new(
            ErrorCode::InvalidEncoding,
            "decode_utf16",
            "choose_complete_utf16_file",
        ));
    }
    let mut units = Vec::with_capacity(bytes.len() / 2);
    for chunk in bytes.as_chunks::<2>().0 {
        units.push(if big_endian {
            u16::from_be_bytes([chunk[0], chunk[1]])
        } else {
            u16::from_le_bytes([chunk[0], chunk[1]])
        });
    }
    String::from_utf16(&units).map_err(|_| {
        ApiError::new(
            ErrorCode::InvalidEncoding,
            "decode_utf16",
            "choose_valid_utf16_file",
        )
    })
}

fn decode_utf32(bytes: &[u8], big_endian: bool) -> Result<String, ApiError> {
    if !bytes.len().is_multiple_of(4) {
        return Err(ApiError::new(
            ErrorCode::InvalidEncoding,
            "decode_utf32",
            "choose_complete_utf32_file",
        ));
    }
    let mut text = String::new();
    for chunk in bytes.as_chunks::<4>().0 {
        let value = if big_endian {
            u32::from_be_bytes([chunk[0], chunk[1], chunk[2], chunk[3]])
        } else {
            u32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]])
        };
        let Some(ch) = char::from_u32(value) else {
            return Err(ApiError::new(
                ErrorCode::InvalidEncoding,
                "decode_utf32",
                "choose_valid_utf32_file",
            ));
        };
        text.push(ch);
    }
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn utf16(text: &str, big_endian: bool) -> Vec<u8> {
        let mut bytes = if big_endian {
            vec![0xfe, 0xff]
        } else {
            vec![0xff, 0xfe]
        };
        for unit in text.encode_utf16() {
            bytes.extend(if big_endian {
                unit.to_be_bytes()
            } else {
                unit.to_le_bytes()
            });
        }
        bytes
    }

    fn utf32(text: &str, big_endian: bool) -> Vec<u8> {
        let mut bytes = if big_endian {
            vec![0, 0, 0xfe, 0xff]
        } else {
            vec![0xff, 0xfe, 0, 0]
        };
        for ch in text.chars() {
            let value = ch as u32;
            bytes.extend(if big_endian {
                value.to_be_bytes()
            } else {
                value.to_le_bytes()
            });
        }
        bytes
    }

    #[test]
    fn auto_decodes_strict_bom_variants_without_losing_the_bom() {
        let text = "第一章 😀\r\n尾行";
        for (bytes, expected) in [
            (utf16(text, false), EncodingKind::Utf16Le),
            (utf16(text, true), EncodingKind::Utf16Be),
            (utf32(text, false), EncodingKind::Utf32Le),
            (utf32(text, true), EncodingKind::Utf32Be),
        ] {
            let decoded = decode(&bytes, EncodingMode::Auto).unwrap();
            assert_eq!(decoded.text, text);
            assert_eq!(decoded.encoding, expected);
            assert!(!decoded.bom.is_empty());
        }
        let utf8 = decode("\u{feff}第一章".as_bytes(), EncodingMode::Auto).unwrap();
        assert_eq!(utf8.text, "第一章");
        assert_eq!(utf8.encoding, EncodingKind::Utf8);
        assert_eq!(utf8.bom, [0xef, 0xbb, 0xbf]);
    }

    #[test]
    fn cp936_is_strict_and_auto_falls_back_only_after_utf8_fails() {
        let bytes = vec![
            0xb5, 0xda, 0xd2, 0xbb, 0xd5, 0xc2, 0x20, 0xbf, 0xaa, 0xca, 0xbc,
        ];
        let decoded = decode(&bytes, EncodingMode::Auto).unwrap();
        assert_eq!(decoded.encoding, EncodingKind::Cp936);
        assert_eq!(decoded.text, "第一章 开始");
        assert_eq!(
            decode(&[0x81], EncodingMode::Cp936).unwrap_err().code,
            ErrorCode::InvalidEncoding
        );
    }

    #[test]
    fn malformed_utf16_utf32_are_errors_instead_of_replacement_text() {
        assert_eq!(
            decode(&[0xff, 0xfe, 0x00], EncodingMode::Auto)
                .unwrap_err()
                .code,
            ErrorCode::InvalidEncoding
        );
        assert_eq!(
            decode(&[0xff, 0xfe, 0x00, 0xd8], EncodingMode::Auto)
                .unwrap_err()
                .code,
            ErrorCode::InvalidEncoding
        );
        assert_eq!(
            decode(&[0xff, 0xfe, 0, 0, 0, 0, 0, 0x11], EncodingMode::Auto)
                .unwrap_err()
                .code,
            ErrorCode::InvalidEncoding
        );
    }
}

fn cp936_error(operation: &'static str) -> ApiError {
    ApiError::new(
        ErrorCode::InvalidEncoding,
        operation,
        "choose_utf8_or_cancel",
    )
}
fn decode_cp936(bytes: &[u8]) -> Result<String, ApiError> {
    let mut text = String::with_capacity(bytes.len());
    let mut index = 0;
    let mut start = 0;
    while index < bytes.len() {
        let first = bytes[index];
        let (width, replacement) = if first == 0xff {
            (1, Some('\u{f8f5}'))
        } else if (0x81..=0xfe).contains(&first) {
            let second = *bytes
                .get(index + 1)
                .ok_or_else(|| cp936_error("decode_cp936"))?;
            if !(0x40..=0xfe).contains(&second) || second == 0x7f {
                return Err(cp936_error("decode_cp936"));
            }
            let pair = u16::from_be_bytes([first, second]);
            let mapped = crate::cp936_table::OVERRIDES
                .binary_search_by_key(&pair, |(b, _)| *b)
                .ok()
                .map(|i| crate::cp936_table::OVERRIDES[i].1);
            (2, mapped)
        } else {
            (1, None)
        };
        if let Some(ch) = replacement {
            let decoded = GBK
                .decode_without_bom_handling_and_without_replacement(&bytes[start..index])
                .ok_or_else(|| cp936_error("decode_cp936"))?;
            text.push_str(&decoded);
            text.push(ch);
            start = index + width;
        }
        index += width;
    }
    let decoded = GBK
        .decode_without_bom_handling_and_without_replacement(&bytes[start..])
        .ok_or_else(|| cp936_error("decode_cp936"))?;
    text.push_str(&decoded);
    Ok(text)
}
fn encode_cp936(text: &str) -> Result<Vec<u8>, ApiError> {
    let mut bytes = Vec::with_capacity(text.len());
    for ch in text.chars() {
        if ch == '\u{f8f5}' {
            bytes.push(0xff);
            continue;
        }
        if let Some((pair, _)) = crate::cp936_table::OVERRIDES
            .iter()
            .find(|(_, mapped)| *mapped == ch)
        {
            bytes.extend_from_slice(&pair.to_be_bytes());
            continue;
        }
        let mut buffer = [0; 4];
        let scalar = ch.encode_utf8(&mut buffer);
        let (encoded, _, errors) = GBK.encode(scalar);
        if errors {
            return Err(cp936_error("encode_cp936"));
        }
        bytes.extend_from_slice(&encoded);
    }
    if decode_cp936(&bytes)? != text {
        return Err(cp936_error("encode_cp936"));
    }
    Ok(bytes)
}
