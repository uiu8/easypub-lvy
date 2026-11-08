//! TXT 的编码（G-114）：判断像不像乱码、试各种编码、按选定的编码转成 UTF-8。
//!
//! 项目、重查、输出都只认能自动判断的编码，所以手动选的编码不进书稿：把原文件
//! 转成一份 UTF-8 工作稿，和 EPUB 一样走“工作稿 + 原文件”，后面的流程都不用变。
use easypub_core::{
    ApiError, ErrorCode,
    encoding::{EncodingKind, EncodingMode, decode, decode_as},
};
use serde_json::{Value, json};
use std::{collections::HashSet, fs, path::Path, sync::LazyLock};

const MAX_BYTES: u64 = 128 * 1024 * 1024;
/// 判断只看开头这么多：够看出来，也不拖慢导入。
const SAMPLE_BYTES: usize = 1024 * 1024;
const PREVIEW_LINES: usize = 30;
const PREVIEW_LINE_CHARS: usize = 200;
/// 汉字少于这个数不下结论。
const MIN_HANZI: usize = 30;
/// 常用字占比低于这个数算像乱码。构造的古文、繁体样本也在这之上。
const SUSPECT_RATIO: f64 = 0.2;

/// 能选的编码，顺序即窗口里的顺序。
pub const ENCODINGS: [(&str, &str); 8] = [
    ("utf-8", "UTF-8"),
    ("cp936", "GBK（简体中文）"),
    ("gb18030", "GB18030（简体中文）"),
    ("big5", "Big5（繁体中文）"),
    ("shift_jis", "Shift_JIS（日文）"),
    ("euc-kr", "EUC-KR（韩文）"),
    ("utf-16le", "UTF-16 LE（无标记）"),
    ("utf-16be", "UTF-16 BE（无标记）"),
];

/// 最常用的汉字，简繁都收。真实中文正文里这些字占三到七成，错解出来的乱码不到一成。
static COMMON: LazyLock<HashSet<char>> = LazyLock::new(|| {
    "的一是不了在人有我他这个们中来上大为和国地到以说时要就出会可也你对生能而子那得于着下自之年过发后作里用道行所然家种事成方多经么去法学如都同现当没动面起看定天分还进好小部其些主样理心她本前开但因只从想实日军者意无力它与长把机十民第公此已工使情明性知全三又关点正业外将两高间由问很最重并物手应战向头文体政美相见被利什二等产或新己制身果加西斯月话合回特代内信表化老给世位次度门任常先海通教儿原东声提立及比员解水名真论处走义各入几口认条平系气题活尔更别打女变四神总何电数安少报才结反受目太量再感建务做接必场件计管期市直德资命山金指克许统区保至队形社便空决治展马科司五基眼书非则听白却界达光放强即像难且权思王象完设式色路记南品住告类求据程北边死张该交规万取拉格望觉术领共确传师观清今切院让识候带导争运笑飞风步改收根干造言联持组每济车亲极林服快办议往元英士证近失转夫令准布始怎呢存未远叫台单影具罗字爱击流备兵连调深商算质团集百需价花党华城石级整府离况亚请技际约示复病息究线似官火断精满支视消越器容照须九增研写称企八功吗包片史委的們個來為國這時說會過後對於發從還進動點學種樣開經裡裏沒將當與無現見長問間聽話頭讓對應實體關機產業"
        .chars()
        .collect()
});

/// 最常用的韩文音节。韩文编码能把日文、中文也解成音节，只看“是不是音节”分不出来。
static COMMON_HANGUL: LazyLock<HashSet<char>> = LazyLock::new(|| {
    "이다의는에을를가은한고하지로서도나있그기어사아리시인들자대해라만게수여부요것으며니했일정과적전장상주성보오제스구내면무모동소"
        .chars()
        .collect()
});

fn invalid(action: &'static str) -> ApiError {
    ApiError::new(ErrorCode::InvalidEncoding, "text_encoding", action)
}

fn read(path: &str) -> Result<Vec<u8>, ApiError> {
    let file = Path::new(path);
    if !file.is_absolute() || path.len() > 32768 {
        return Err(invalid("choose_absolute_text_path"));
    }
    let size = fs::metadata(file)
        .map_err(|_| ApiError::new(ErrorCode::NotFound, "text_encoding", "choose_readable_text"))?
        .len();
    if size > MAX_BYTES {
        return Err(ApiError::new(
            ErrorCode::TooLarge,
            "text_encoding",
            "reduce_text_file_size",
        ));
    }
    fs::read(file).map_err(|_| invalid("choose_readable_text"))
}

#[derive(Default)]
struct Counts {
    hanzi: usize,
    common: usize,
    kana: usize,
    hangul: usize,
    other: usize,
    control: usize,
}
fn counts(text: &str) -> Counts {
    let mut c = Counts::default();
    for ch in text.chars() {
        match ch {
            '\t' | '\r' | '\n' => {}
            '\0'..='\u{1f}' | '\u{7f}'..='\u{9f}' => c.control += 1,
            '\u{20}'..='\u{7e}' => {}
            '\u{3040}'..='\u{30ff}' => c.kana += 1,
            '\u{ac00}'..='\u{d7a3}' => {
                c.hangul += 1;
                c.common += usize::from(COMMON_HANGUL.contains(&ch));
            }
            '\u{3400}'..='\u{9fff}' | '\u{20000}'..='\u{2ffff}' => {
                c.hanzi += 1;
                c.common += usize::from(COMMON.contains(&ch));
            }
            // 标点不算对错。
            '\u{2000}'..='\u{2fff}' | '\u{3000}'..='\u{303f}' | '\u{ff01}'..='\u{ff5e}' => {}
            _ => c.other += 1,
        }
    }
    c
}
/// 这段文字有多像正常文字，0 到 1。
fn score(text: &str) -> f64 {
    let c = counts(text);
    let total = c.hanzi + c.kana + c.hangul + c.other + c.control;
    if total == 0 {
        return 0.0;
    }
    (c.common + c.kana) as f64 / total as f64
}
fn looks_wrong(text: &str) -> bool {
    let c = counts(text);
    let letters = c.hanzi + c.kana + c.hangul + c.other + c.control;
    if letters >= MIN_HANZI && c.control * 20 > letters {
        return true;
    }
    c.hanzi >= MIN_HANZI && (c.common as f64) < c.hanzi as f64 * SUSPECT_RATIO
}
/// 取开头一段，断在换行上，不切开双字节字。
fn sample(bytes: &[u8]) -> &[u8] {
    if bytes.len() <= SAMPLE_BYTES {
        return bytes;
    }
    let head = &bytes[..SAMPLE_BYTES];
    match head.iter().rposition(|&b| b == b'\n') {
        Some(at) => &head[..=at],
        None => head,
    }
}

/// 自动判断成 GBK 时看一眼像不像乱码。只有 GBK 会把别的编码解成“成功”。
pub fn suspect(path: &str) -> Result<bool, ApiError> {
    let bytes = read(path)?;
    Ok(decode_as(sample(&bytes), "cp936")
        .map(|text| looks_wrong(&text))
        .unwrap_or(false))
}

/// 选编码窗口要的东西：每种编码解不解得开、解出来前 30 行是什么样。
pub fn probe(path: &str) -> Result<String, ApiError> {
    let bytes = read(path)?;
    let auto = decode(&bytes, EncodingMode::Auto).ok();
    let label = auto.as_ref().map(|d| d.encoding.label());
    let wrong = auto.as_ref().is_some_and(|d| {
        d.encoding == EncodingKind::Cp936 && looks_wrong(&d.text[..floor(&d.text, SAMPLE_BYTES)])
    });
    let mut best: Option<(&str, f64)> = None;
    let mut candidates: Vec<Value> = Vec::new();
    for (code, name) in ENCODINGS {
        let text = decode_as(&bytes, code).ok();
        if let Some(text) = &text {
            let value = score(&text[..floor(text, SAMPLE_BYTES)]);
            if best.is_none_or(|(_, top)| value > top) {
                best = Some((code, value));
            }
        }
        let lines: Vec<String> = text
            .as_deref()
            .unwrap_or("")
            .lines()
            .take(PREVIEW_LINES)
            .map(preview_line)
            .collect();
        candidates.push(json!({"label":code,"name":name,"ok":text.is_some(),"lines":lines}));
    }
    let suggested = match (label, wrong) {
        (Some(label), false) => Some(label),
        _ => best.map(|(code, _)| code),
    };
    Ok(
        json!({"auto":label,"suspect":wrong,"suggested":suggested,"candidates":candidates})
            .to_string(),
    )
}
fn floor(text: &str, at: usize) -> usize {
    if at >= text.len() {
        return text.len();
    }
    (0..=at)
        .rev()
        .find(|&i| text.is_char_boundary(i))
        .unwrap_or(0)
}
fn preview_line(line: &str) -> String {
    line.chars()
        .take(PREVIEW_LINE_CHARS)
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect()
}

/// 按选定的编码转成 UTF-8 工作稿。解不开就报错，不留替换字符。
pub fn transcode(source: &str, encoding: &str, output: &str) -> Result<(), ApiError> {
    let bytes = read(source)?;
    if !Path::new(output).is_absolute() {
        return Err(invalid("choose_absolute_text_path"));
    }
    let text = decode_as(&bytes, encoding)?;
    fs::write(output, text.as_bytes()).map_err(|_| invalid("write_text_copy"))
}

#[cfg(test)]
mod tests {
    use super::*;

    const PROSE: &str = "第一章 回家\n他走到门口，看见院子里的那棵老树还在。这是他小时候常常爬上去玩的地方，现在已经长得很高了。\n“你回来了。”母亲从屋里出来，手里还拿着没有洗完的菜。他没有说话，只是点了点头。\n";
    const TRAD: &str = "第一章 回家\n他走到門口，看見院子裡的那棵老樹還在。這是他小時候常常爬上去玩的地方，現在已經長得很高了。\n「你回來了。」母親從屋裡出來，手裡還拿著沒有洗完的菜。他沒有說話，只是點了點頭。\n";
    const JA: &str = "第一章 帰郷\n彼は門の前に立って、庭の古い木がまだそこにあるのを見た。子供の頃によく登って遊んだ場所だが、今ではとても高くなっている。\n「おかえり」と母が家から出てきた。\n";
    const KO: &str = "제1장 귀향\n그는 문 앞에 서서 마당의 오래된 나무가 아직 그 자리에 있는 것을 보았다. 어렸을 때 자주 올라가 놀던 곳이었는데 이제는 아주 높이 자랐다.\n";

    fn long(text: &str) -> String {
        text.repeat(20)
    }
    fn file(name: &str, bytes: &[u8]) -> String {
        let path =
            std::env::temp_dir().join(format!("easypub-encoding-{}-{name}", std::process::id()));
        fs::write(&path, bytes).unwrap();
        path.to_str().unwrap().to_owned()
    }
    fn encoded(text: &str, encoding: &'static encoding_rs::Encoding) -> Vec<u8> {
        encoding.encode(text).0.into_owned()
    }
    fn report(name: &str, bytes: &[u8]) -> Value {
        let path = file(name, bytes);
        let value = serde_json::from_str(&probe(&path).unwrap()).unwrap();
        fs::remove_file(path).unwrap();
        value
    }

    #[test]
    fn real_chinese_is_not_flagged() {
        for text in [
            PROSE,
            TRAD,
            "子曰：學而時習之，不亦說乎？有朋自遠方來，不亦樂乎？人不知而不慍，不亦君子乎？",
        ] {
            let bytes = encoded(&long(text), encoding_rs::GBK);
            let path = file("plain.txt", &bytes);
            assert!(!suspect(&path).unwrap(), "{text}");
            fs::remove_file(path).unwrap();
        }
    }

    #[test]
    fn other_encodings_read_as_gbk_are_flagged_and_the_right_one_is_suggested() {
        for (name, text, encoding, label) in [
            ("big5.txt", TRAD, encoding_rs::BIG5, "big5"),
            ("sjis.txt", JA, encoding_rs::SHIFT_JIS, "shift_jis"),
            ("euckr.txt", KO, encoding_rs::EUC_KR, "euc-kr"),
        ] {
            let bytes = encoded(&long(text), encoding);
            let result = report(name, &bytes);
            assert_eq!(result["suggested"], label, "{name} {result}");
            let row = result["candidates"]
                .as_array()
                .unwrap()
                .iter()
                .find(|c| c["label"] == label)
                .unwrap();
            assert_eq!(row["ok"], true);
            assert!(row["lines"].as_array().unwrap().len() <= PREVIEW_LINES);
        }
    }

    #[test]
    fn utf8_stays_auto_and_transcoding_writes_utf8() {
        let result = report("utf8.txt", long(PROSE).as_bytes());
        assert_eq!(result["auto"], "utf-8");
        assert_eq!(result["suggested"], "utf-8");
        assert_eq!(result["suspect"], false);

        let bytes = encoded(&long(TRAD), encoding_rs::BIG5);
        let source = file("to-utf8.txt", &bytes);
        let output = format!("{source}.out");
        transcode(&source, "big5", &output).unwrap();
        assert_eq!(fs::read_to_string(&output).unwrap(), long(TRAD));
        fs::remove_file(&output).unwrap();
        // 解不开就报错，不留替换字符。
        assert!(transcode(&source, "utf-8", &output).is_err());
        assert!(transcode(&source, "no-such", &output).is_err());
        assert!(!Path::new(&output).exists());
        fs::remove_file(source).unwrap();
    }

    #[test]
    fn gb18030_four_byte_characters_survive_transcoding() {
        let text = "第一章 扩展汉字\n𠮷与𠀀不能被替换。\n";
        let bytes = encoded(text, encoding_rs::GB18030);
        assert!(bytes.windows(4).any(|v| v[0] >= 0x81
            && v[1].is_ascii_digit()
            && v[2] >= 0x81
            && v[3].is_ascii_digit()));
        let source = file("gb18030-four.txt", &bytes);
        let output = format!("{source}.out");
        transcode(&source, "gb18030", &output).unwrap();
        assert_eq!(fs::read_to_string(&output).unwrap(), text);
        assert_eq!(fs::read(&source).unwrap(), bytes);
        fs::remove_file(output).unwrap();
        fs::remove_file(source).unwrap();
    }

    #[test]
    fn utf16_without_a_mark_can_be_chosen() {
        let mut bytes = Vec::new();
        for unit in long(PROSE).encode_utf16() {
            bytes.extend_from_slice(&unit.to_le_bytes());
        }
        let path = file("utf16.txt", &bytes);
        let output = format!("{path}.out");
        transcode(&path, "utf-16le", &output).unwrap();
        assert_eq!(fs::read_to_string(&output).unwrap(), long(PROSE));
        fs::remove_file(output).unwrap();
        fs::remove_file(path).unwrap();
    }

    /// 真实书的误报：`EASYPUB_NOVEL_DIR=目录 cargo test -p easypub_app --lib real_books -- --ignored --nocapture`。
    /// 只读那个目录，把每本 UTF-8 的 TXT 换成 GBK 看会不会被标出来。
    #[test]
    #[ignore]
    fn real_books_are_not_flagged() {
        let root = std::env::var("EASYPUB_NOVEL_DIR").unwrap();
        let mut stack = vec![std::path::PathBuf::from(root)];
        let (mut books, mut flagged, mut lowest) = (0, 0, 1.0f64);
        while let Some(path) = stack.pop() {
            for entry in fs::read_dir(path).unwrap().flatten() {
                let path = entry.path();
                if path.is_dir() {
                    stack.push(path);
                    continue;
                }
                if path.extension().is_none_or(|e| e != "txt") {
                    continue;
                }
                let Ok(text) = fs::read_to_string(&path) else {
                    continue;
                };
                let bytes = encoded(&text, encoding_rs::GBK);
                let head = decode_as(sample(&bytes), "cp936").unwrap();
                let c = counts(&head);
                if c.hanzi < MIN_HANZI {
                    continue;
                }
                books += 1;
                let ratio = c.common as f64 / c.hanzi as f64;
                lowest = lowest.min(ratio);
                if looks_wrong(&head) {
                    flagged += 1;
                    println!("标出 {} {ratio:.3}", path.display());
                }
            }
        }
        println!("{books} 本，标出 {flagged} 本，常用字占比最低 {lowest:.3}");
        assert_eq!(flagged, 0);
    }

    #[test]
    fn a_long_sample_stops_on_a_line_end() {
        let mut bytes = vec![b'a'; SAMPLE_BYTES - 10];
        bytes.push(b'\n');
        bytes.extend_from_slice(&[0xb0; 40]);
        assert_eq!(sample(&bytes).len(), SAMPLE_BYTES - 9);
    }
}
