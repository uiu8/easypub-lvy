//! Header bounds check, independent of the external converter. Full fidelity is
//! checked by Bokai against the exact staged EPUB before publication.
pub fn valid_header(bytes: &[u8]) -> bool {
    if bytes.len() < 18 || &bytes[..4] != b"CONT" {
        return false;
    }
    let number =
        |offset| u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap()) as usize;
    let header = number(6);
    let info = number(10);
    let length = number(14);
    header >= 18
        && header < bytes.len()
        && info >= 18
        && length > 0
        && info.checked_add(length).is_some_and(|end| end <= header)
}
