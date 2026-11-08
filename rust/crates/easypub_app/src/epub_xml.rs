//! 读 EPUB 里的 XML。
//!
//! 出版物的 XHTML 大多带 `<!DOCTYPE>`，解析库默认不接受，所有读 EPUB 的地方都走
//! 这里。声明本身不生效，也不访问外部文件；自定义实体（`<!ENTITY`）继续拒绝，
//! 避免恶意文件靠实体膨胀耗尽内存。
use roxmltree::{Document, Error, ParsingOptions};
use std::borrow::Cow;

pub(crate) fn parse(text: &str) -> Result<Document<'_>, Error> {
    parse_limited(text, u32::MAX)
}

pub(crate) fn parse_limited(text: &str, nodes_limit: u32) -> Result<Document<'_>, Error> {
    Document::parse_with_options(
        text,
        ParsingOptions {
            allow_dtd: !text.contains("<!ENTITY"),
            nodes_limit,
            ..Default::default()
        },
    )
}

/// `&nbsp;` 这类 HTML 命名字符换成数字写法：XML 解析不认识它们，XHTML 里却很常见。
/// 只用于读内容，不要拿换过的文字的位置去改原文件。
pub(crate) fn named_entities(text: &str) -> Cow<'_, str> {
    if !text.contains('&') {
        return Cow::Borrowed(text);
    }
    let mut out = String::new();
    let mut copied = 0;
    let mut search = 0;
    while let Some(found) = text[search..].find('&') {
        let at = search + found;
        search = at + 1;
        let rest = &text[at + 1..];
        let Some(length) = rest.bytes().take(32).position(|b| b == b';') else {
            continue;
        };
        let name = &rest[..length];
        if name.is_empty()
            || !name.bytes().all(|b| b.is_ascii_alphanumeric())
            || matches!(name, "amp" | "lt" | "gt" | "quot" | "apos")
        {
            continue;
        }
        let Some(&(first, second)) = markup5ever::data::NAMED_ENTITIES.get(&rest[..=length]) else {
            continue;
        };
        out.push_str(&text[copied..at]);
        out.push_str(&format!("&#{first};"));
        if second != 0 {
            out.push_str(&format!("&#{second};"));
        }
        copied = at + 1 + length + 1;
        search = copied;
    }
    if copied == 0 {
        return Cow::Borrowed(text);
    }
    out.push_str(&text[copied..]);
    Cow::Owned(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    const DOCTYPE: &str = "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \
        \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\">";

    #[test]
    fn doctypes_are_accepted_but_custom_entities_are_not() {
        for head in [DOCTYPE, "<!DOCTYPE html>"] {
            let xml = format!("{head}<html><body>文字</body></html>");
            assert!(Document::parse(&xml).is_err(), "解析库默认不接受");
            assert!(parse(&xml).is_ok());
        }
        let bomb = "<!DOCTYPE r [<!ENTITY a \"aaaa\"><!ENTITY b \"&a;&a;&a;\">]><r>&b;</r>";
        assert!(parse(bomb).is_err());
    }

    #[test]
    fn named_characters_become_numbers() {
        let xml = named_entities("<p>甲&nbsp;乙&mdash;丙 &amp; 丁 &#160; &unknown; A&B; &</p>");
        assert_eq!(
            xml,
            "<p>甲&#160;乙&#8212;丙 &amp; 丁 &#160; &unknown; A&B; &</p>"
        );
        let plain = "<p>没有要换的 &amp; 字符</p>";
        assert!(matches!(named_entities(plain), Cow::Borrowed(_)));
        let doc = parse("<p>甲&#160;乙</p>").unwrap();
        assert_eq!(doc.root_element().text(), Some("甲\u{a0}乙"));
    }
}
