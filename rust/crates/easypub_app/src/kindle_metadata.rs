//! Bounded final KF8 metadata check before publishing a converted file.
use easypub_core::{ApiError, ErrorCode};

fn invalid() -> ApiError {
    ApiError::new(
        ErrorCode::InvalidRule,
        "kindle_metadata",
        "engine_metadata_mismatch",
    )
}
fn u32_at(bytes: &[u8], offset: usize) -> Result<usize, ApiError> {
    let slice = bytes
        .get(offset..offset.checked_add(4).ok_or_else(invalid)?)
        .ok_or_else(invalid)?;
    Ok(u32::from_be_bytes(slice.try_into().unwrap()) as usize)
}
pub(crate) fn verify(
    bytes: &[u8],
    expected: &[(u32, &str, &str)],
) -> Result<Vec<String>, ApiError> {
    if bytes.get(60..68) != Some(b"BOOKMOBI") {
        return Err(invalid());
    }
    let count = bytes.get(76..78).ok_or_else(invalid)?;
    let count = u16::from_be_bytes(count.try_into().unwrap()) as usize;
    if count == 0 {
        return Err(invalid());
    }
    verify_record(bytes, expected, count, 0, 8).map(|(checked, _)| checked)
}
pub(crate) fn verify_format(
    bytes: &[u8],
    dual: bool,
    expected: &[(u32, &str, &str)],
) -> Result<Vec<String>, ApiError> {
    if !dual {
        return verify(bytes, expected);
    }
    if bytes.get(60..68) != Some(b"BOOKMOBI") {
        return Err(invalid());
    }
    let count =
        u16::from_be_bytes(bytes.get(76..78).ok_or_else(invalid)?.try_into().unwrap()) as usize;
    let (checked, boundary) = verify_record(bytes, expected, count, 0, 6)?;
    let boundary = boundary.ok_or_else(invalid)?;
    if boundary == 0 {
        return Err(invalid());
    }
    verify_record(bytes, expected, count, boundary, 8)?;
    Ok(checked)
}

/// Validate every Palm record boundary as well as the required Kindle headers.
/// This does not decode text, images or navigation and is not reader acceptance.
pub(crate) fn inspect_container(bytes: &[u8], dual: bool) -> Result<usize, ApiError> {
    let count =
        u16::from_be_bytes(bytes.get(76..78).ok_or_else(invalid)?.try_into().unwrap()) as usize;
    if count == 0 {
        return Err(invalid());
    }
    let table_end = 78 + count * 8;
    let mut previous = None;
    for index in 0..count {
        let offset = u32_at(bytes, 78 + index * 8)?;
        if offset < table_end || offset >= bytes.len() || previous.is_some_and(|p| offset <= p) {
            return Err(invalid());
        }
        previous = Some(offset);
    }
    verify_format(bytes, dual, &[])?;
    Ok(count)
}

#[derive(Debug, Default)]
pub(crate) struct Details {
    pub title: Option<String>,
    pub author: Option<String>,
    pub language: Option<String>,
    pub content_type: Option<String>,
    pub content_id: Option<String>,
    pub cover_metadata_present: bool,
}

/// Read bounded EXTH display metadata from the first validated Kindle section.
/// This is metadata evidence only; it does not decode Kindle HTML or certify a reader.
pub(crate) fn inspect_details(bytes: &[u8], dual: bool) -> Result<Details, ApiError> {
    let count = inspect_container(bytes, dual)?;
    let start = u32_at(bytes, 78)?;
    let end = if count > 1 {
        u32_at(bytes, 86)?
    } else {
        bytes.len()
    };
    let record = bytes.get(start..end).ok_or_else(invalid)?;
    let header = u32_at(record, 20)?;
    let exth = record.get(16 + header..).ok_or_else(invalid)?;
    if exth.get(..4) != Some(b"EXTH") {
        return Err(invalid());
    }
    let length = u32_at(exth, 4)?;
    let count = u32_at(exth, 8)?;
    if !(12..=64 * 1024).contains(&length) || count > 4096 {
        return Err(invalid());
    }
    let exth = exth.get(..length).ok_or_else(invalid)?;
    let mut details = Details::default();
    let mut offset = 12usize;
    for _ in 0..count {
        let kind = u32_at(exth, offset)?;
        let size = u32_at(exth, offset + 4)?;
        if size < 8 {
            return Err(invalid());
        }
        let end = offset.checked_add(size).ok_or_else(invalid)?;
        let value = exth.get(offset + 8..end).ok_or_else(invalid)?;
        let text = || {
            String::from_utf8(value.to_vec())
                .ok()
                .filter(|s| !s.is_empty())
        };
        match kind {
            100 => details.author = text(),
            503 => details.title = text(),
            524 => details.language = text(),
            501 => details.content_type = text(),
            113 => details.content_id = text(),
            201 => details.cover_metadata_present = !value.is_empty(),
            _ => {}
        }
        offset = end;
    }
    Ok(details)
}
fn verify_record(
    bytes: &[u8],
    expected: &[(u32, &str, &str)],
    count: usize,
    index: usize,
    version: usize,
) -> Result<(Vec<String>, Option<usize>), ApiError> {
    if index >= count {
        return Err(invalid());
    }
    let start = u32_at(bytes, 78 + index * 8)?;
    let end = if index + 1 < count {
        u32_at(bytes, 78 + (index + 1) * 8)?
    } else {
        bytes.len()
    };
    if start < 78 + count * 8 || end <= start {
        return Err(invalid());
    }
    let record = bytes.get(start..end).ok_or_else(invalid)?;
    if record.get(16..20) != Some(b"MOBI") || u32_at(record, 36)? != version {
        return Err(invalid());
    }
    let header = u32_at(record, 20)?;
    if header < 24 {
        return Err(invalid());
    }
    let exth = record.get(16 + header..).ok_or_else(invalid)?;
    if exth.get(..4) != Some(b"EXTH") {
        return Err(invalid());
    }
    let length = u32_at(exth, 4)?;
    let count = u32_at(exth, 8)?;
    if length < 12 || count > 4096 {
        return Err(invalid());
    }
    let exth = exth.get(..length).ok_or_else(invalid)?;
    let mut offset = 12;
    let mut records = Vec::new();
    for _ in 0..count {
        let kind = u32_at(exth, offset)?;
        let size = u32_at(exth, offset + 4)?;
        if size < 8 {
            return Err(invalid());
        }
        let value = exth
            .get(offset + 8..offset.checked_add(size).ok_or_else(invalid)?)
            .ok_or_else(invalid)?;
        records.push((kind, value));
        offset += size;
    }
    let mut checked = Vec::new();
    for &(kind, name, value) in expected {
        if !value.is_empty() {
            if !records
                .iter()
                .any(|&(k, v)| k == kind as usize && v == value.as_bytes())
            {
                return Err(invalid());
            }
            checked.push(name.to_string());
        }
    }
    let boundary = records
        .iter()
        .find(|(k, _)| *k == 121)
        .map(|(_, value)| u32_at(value, 0))
        .transpose()?;
    Ok((checked, boundary))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dual_requires_both_sections_and_valid_boundary() {
        fn header(version: u32, boundary: Option<u32>) -> Vec<u8> {
            let mut r = vec![0; 40];
            r[16..20].copy_from_slice(b"MOBI");
            r[20..24].copy_from_slice(&24u32.to_be_bytes());
            r[36..40].copy_from_slice(&version.to_be_bytes());
            r.extend_from_slice(b"EXTH");
            r.extend_from_slice(&(if boundary.is_some() { 24u32 } else { 12u32 }).to_be_bytes());
            r.extend_from_slice(&(if boundary.is_some() { 1u32 } else { 0u32 }).to_be_bytes());
            if let Some(b) = boundary {
                r.extend_from_slice(&121u32.to_be_bytes());
                r.extend_from_slice(&12u32.to_be_bytes());
                r.extend_from_slice(&b.to_be_bytes());
            }
            r
        }
        let mut bytes = vec![0; 94];
        bytes[60..68].copy_from_slice(b"BOOKMOBI");
        bytes[76..78].copy_from_slice(&2u16.to_be_bytes());
        bytes[78..82].copy_from_slice(&94u32.to_be_bytes());
        let first = header(6, Some(1));
        let second = 94 + first.len();
        bytes[86..90].copy_from_slice(&(second as u32).to_be_bytes());
        bytes.extend(first);
        bytes.extend(header(8, None));
        assert!(verify_format(&bytes, true, &[]).is_ok());
        assert_eq!(inspect_container(&bytes, true).unwrap(), 2);
        assert!(verify_format(&bytes, false, &[]).is_err());
        for n in 0..bytes.len() {
            assert!(verify_format(&bytes[..n], true, &[]).is_err());
            assert!(inspect_container(&bytes[..n], true).is_err());
        }
        bytes[second + 36..second + 40].copy_from_slice(&6u32.to_be_bytes());
        assert!(verify_format(&bytes, true, &[]).is_err());
        bytes[second + 36..second + 40].copy_from_slice(&8u32.to_be_bytes());
        bytes[second - 4..second].copy_from_slice(&999u32.to_be_bytes());
        assert!(verify_format(&bytes, true, &[]).is_err());
    }
    #[test]
    fn container_rejects_invalid_non_header_record_offsets() {
        let mut bytes = vec![0; 170];
        bytes[60..68].copy_from_slice(b"BOOKMOBI");
        bytes[76..78].copy_from_slice(&3u16.to_be_bytes());
        bytes[78..82].copy_from_slice(&102u32.to_be_bytes());
        bytes[86..90].copy_from_slice(&154u32.to_be_bytes());
        bytes[94..98].copy_from_slice(&160u32.to_be_bytes());
        bytes[118..122].copy_from_slice(b"MOBI");
        bytes[122..126].copy_from_slice(&24u32.to_be_bytes());
        bytes[138..142].copy_from_slice(&8u32.to_be_bytes());
        bytes[142..146].copy_from_slice(b"EXTH");
        bytes[146..150].copy_from_slice(&12u32.to_be_bytes());
        assert_eq!(inspect_container(&bytes, false).unwrap(), 3);
        assert!(inspect_container(&bytes, true).is_err());
        for offset in [0u32, 100, 154, 153, 170, u32::MAX] {
            bytes[94..98].copy_from_slice(&offset.to_be_bytes());
            assert!(inspect_container(&bytes, false).is_err());
        }
    }
    #[test]
    fn truncated_or_missing_or_different_metadata_is_rejected() {
        let mut bytes = vec![0; 86 + 16 + 24 + 12];
        bytes[60..68].copy_from_slice(b"BOOKMOBI");
        bytes[76..78].copy_from_slice(&1u16.to_be_bytes());
        bytes[78..82].copy_from_slice(&86u32.to_be_bytes());
        bytes[102..106].copy_from_slice(b"MOBI");
        bytes[106..110].copy_from_slice(&24u32.to_be_bytes());
        bytes[122..126].copy_from_slice(&8u32.to_be_bytes());
        bytes[126..130].copy_from_slice(b"EXTH");
        bytes[130..134].copy_from_slice(&12u32.to_be_bytes());
        assert!(verify(&bytes, &[(101, "publisher", "出版社")]).is_err());
        bytes[130..134].copy_from_slice(&29u32.to_be_bytes());
        bytes[134..138].copy_from_slice(&1u32.to_be_bytes());
        bytes.extend_from_slice(&101u32.to_be_bytes());
        bytes.extend_from_slice(&17u32.to_be_bytes());
        bytes.extend_from_slice("出版社".as_bytes());
        assert_eq!(
            verify(&bytes, &[(101, "publisher", "出版社")]).unwrap(),
            ["publisher"]
        );
        assert!(verify(&bytes, &[(101, "publisher", "不同出版社")]).is_err());
        for length in 0..bytes.len() {
            assert!(verify(&bytes[..length], &[(101, "publisher", "出版社")]).is_err());
        }
    }

    #[test]
    fn details_read_only_extracts_bounded_exth_display_fields() {
        let mut record = vec![0u8; 40];
        record[16..20].copy_from_slice(b"MOBI");
        record[20..24].copy_from_slice(&24u32.to_be_bytes());
        record[36..40].copy_from_slice(&8u32.to_be_bytes());
        let entries: [(u32, &[u8]); 6] = [
            (503, "书名".as_bytes()),
            (100, "作者".as_bytes()),
            (524, "zh-CN".as_bytes()),
            (201, &[0, 0, 0, 1]),
            (501, b"EBOK"),
            (113, b"74ac8170-cfc7-86db-99f9-195fb560e778"),
        ];
        let exth_len = 12
            + entries
                .iter()
                .map(|(_, value)| 8 + value.len())
                .sum::<usize>();
        record.extend_from_slice(b"EXTH");
        record.extend_from_slice(&(exth_len as u32).to_be_bytes());
        record.extend_from_slice(&(entries.len() as u32).to_be_bytes());
        for (kind, value) in entries {
            record.extend_from_slice(&kind.to_be_bytes());
            record.extend_from_slice(&((8 + value.len()) as u32).to_be_bytes());
            record.extend_from_slice(value);
        }
        let mut bytes = vec![0u8; 86];
        bytes[60..68].copy_from_slice(b"BOOKMOBI");
        bytes[76..78].copy_from_slice(&1u16.to_be_bytes());
        bytes[78..82].copy_from_slice(&86u32.to_be_bytes());
        bytes.extend(record);
        let details = inspect_details(&bytes, false).unwrap();
        assert_eq!(details.title.as_deref(), Some("书名"));
        assert_eq!(details.author.as_deref(), Some("作者"));
        assert_eq!(details.language.as_deref(), Some("zh-CN"));
        assert_eq!(details.content_type.as_deref(), Some("EBOK"));
        assert_eq!(
            details.content_id.as_deref(),
            Some("74ac8170-cfc7-86db-99f9-195fb560e778")
        );
        assert!(details.cover_metadata_present);
    }
}
