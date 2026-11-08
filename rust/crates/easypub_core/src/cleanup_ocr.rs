//! Explicit OCR artefact cleanup; never guesses replacement words.
fn han(c: char) -> bool {
    matches!(c as u32, 0x3400..=0x4dbf | 0x4e00..=0x9fff | 0xf900..=0xfaff | 0x20000..=0x323af)
}
pub(crate) fn remove_han_spaces(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut chars = input.char_indices().peekable();
    let mut previous = None;
    while let Some((offset, c)) = chars.next() {
        if matches!(c, ' ' | '\t') {
            let mut end = offset + c.len_utf8();
            while let Some(&(i, next)) = chars.peek() {
                if !matches!(next, ' ' | '\t') {
                    break;
                }
                end = i + next.len_utf8();
                chars.next();
            }
            if !previous.is_some_and(han) || !chars.peek().is_some_and(|&(_, next)| han(next)) {
                out.push_str(&input[offset..end]);
            }
            previous = Some(c);
        } else {
            out.push(c);
            previous = Some(c);
        }
    }
    out
}
pub(crate) fn normalize_ellipsis(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();
    while let Some(c) = chars.next() {
        if matches!(c, '．' | '。') {
            let mut count = 1;
            while chars.peek() == Some(&c) {
                chars.next();
                count += 1;
            }
            if count == 6 {
                out.push_str("……");
            } else {
                out.extend(std::iter::repeat_n(c, count));
            }
        } else {
            out.push(c);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_han_gaps_and_exact_ellipsis_runs_change() {
        assert_eq!(
            remove_han_spaces(
                "  正 文 中\t间𠀀 \t𠀁 English words 12 34 甲 A 乙\r\n　保 留　缩进\t"
            ),
            "  正文中间𠀀𠀁 English words 12 34 甲 A 乙\r\n　保留　缩进\t"
        );
        assert_eq!(
            normalize_ellipsis("．．．．．．。。。。。。．。。。。。。。 1.25 ... www.example.com"),
            "…………．。。。。。。。 1.25 ... www.example.com"
        );
    }
}
