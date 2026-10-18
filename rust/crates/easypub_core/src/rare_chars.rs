//! 生僻字判断与读音（V73，LAY-129）。
//!
//! 字表：《通用规范汉字表》8105 字，按表中字序分级（1–3500 一级，3501–6500 二级，6501–8105 三级），
//! 读音取字表数据；表外字读音取 Unihan kMandarin（只取第一个读音）。
//! 繁体字先按 OpenCC 转成简体再判断：简体在表内时按简体的级别算，这样繁体书不会满篇注音。
//! 数据来源与许可见 third_party/pinyin_data/provenance.json。
use crate::chinese_variant::{DICTIONARY_VERSION, Direction, converter};
use std::{collections::HashMap, sync::OnceLock};

const TABLE: &str =
    include_str!("../../../../third_party/pinyin_data/general_table/characters.csv");
const UNIHAN: &str = include_str!("../../../../third_party/pinyin_data/kMandarin.txt");

/// 哪些字算生僻字。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scope {
    /// 只有表外字。
    Outside,
    /// 三级字和表外字。
    LevelThree,
}

impl Scope {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "outside" => Some(Self::Outside),
            "level3" => Some(Self::LevelThree),
            _ => None,
        }
    }
}

/// 每个字的有效级别（0 表示表外）与读音。
struct Entry {
    level: u8,
    reading: &'static str,
}

fn table() -> &'static HashMap<char, Entry> {
    static MAP: OnceLock<HashMap<char, Entry>> = OnceLock::new();
    MAP.get_or_init(|| {
        let mut map = HashMap::with_capacity(48_000);
        for (index, line) in TABLE.lines().skip(1).enumerate() {
            let Some((ch, reading)) = line.split_once(',') else {
                continue;
            };
            let mut chars = ch.chars();
            let (Some(c), None) = (chars.next(), chars.next()) else {
                continue;
            };
            let level = match index + 1 {
                1..=3500 => 1,
                3501..=6500 => 2,
                _ => 3,
            };
            map.insert(
                c,
                Entry {
                    level,
                    reading: reading.trim(),
                },
            );
        }
        assert_eq!(map.len(), 8105, "通用规范汉字表应为 8105 字");
        let t2s = converter(&Direction::T2s, DICTIONARY_VERSION).ok();
        let mut outside = Vec::new();
        for line in UNIHAN.lines() {
            let Some(rest) = line.strip_prefix("U+") else {
                continue;
            };
            let Some((hex, tail)) = rest.split_once(':') else {
                continue;
            };
            let Some(c) = u32::from_str_radix(hex.trim(), 16)
                .ok()
                .and_then(char::from_u32)
            else {
                continue;
            };
            if map.contains_key(&c) {
                continue;
            }
            let reading = tail.split('#').next().unwrap_or("").trim();
            let reading = reading.split(',').next().unwrap_or("").trim();
            if reading.is_empty() {
                continue;
            }
            outside.push((c, reading));
        }
        for (c, reading) in outside {
            // 繁体字：转成简体后在表内，就按简体的级别算。
            let level = t2s
                .map(|t| t.convert(&c.to_string()))
                .and_then(|s| {
                    let mut it = s.chars();
                    match (it.next(), it.next()) {
                        (Some(simple), None) if simple != c => map.get(&simple).map(|e| e.level),
                        _ => None,
                    }
                })
                .unwrap_or(0);
            map.insert(c, Entry { level, reading });
        }
        map
    })
}

/// 这个字在给定范围内是生僻字时返回读音。
pub fn reading(c: char, scope: Scope) -> Option<&'static str> {
    let entry = table().get(&c)?;
    let rare = entry.level == 0 || (scope == Scope::LevelThree && entry.level == 3);
    rare.then_some(entry.reading)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn levels_readings_and_traditional_forms() {
        // 表外字。
        assert_eq!(reading('龘', Scope::Outside), Some("dá"));
        assert_eq!(reading('囧', Scope::Outside), Some("jiǒng"));
        // 三级字：只在 level3 范围内算。
        assert_eq!(reading('喆', Scope::Outside), None);
        assert_eq!(reading('喆', Scope::LevelThree), Some("zhé"));
        assert_eq!(reading('鼗', Scope::LevelThree), Some("táo"));
        // 一级、二级字从不算。
        for c in "一山饕餮魑魅耄耋觊觎".chars() {
            assert_eq!(reading(c, Scope::LevelThree), None, "{c}");
        }
        // 繁体字按简体判断。
        for c in "這裏燈與歲".chars() {
            assert_eq!(reading(c, Scope::LevelThree), None, "{c}");
        }
        // 非汉字。
        for c in "a1，。 😀".chars() {
            assert_eq!(reading(c, Scope::LevelThree), None);
        }
        assert_eq!(Scope::parse("level3"), Some(Scope::LevelThree));
        assert_eq!(Scope::parse("x"), None);
    }
}
