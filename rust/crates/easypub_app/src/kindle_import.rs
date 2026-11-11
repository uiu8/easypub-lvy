//! AZW3 / MOBI 导入：读取没有 DRM 的 Kindle 文件，转成一个结构简单的 EPUB，
//! 之后与导入 EPUB 完全相同（正文成为 TXT 工作稿，封面、图片、样式、字体另存为资源）。
//!
//! 支持：KF8（AZW3，以及新版 MOBI 里的 KF8 部分）与旧式 MOBI；PalmDOC 与 HUFF/CDIC 两种压缩。
//! 带 DRM 的文件直接拒绝，不尝试解密。格式参照公开的 MOBI / KF8 文件结构说明。
use easypub_core::{ApiError, ErrorCode};
use scraper::{Html, Node};
use serde_json::json;
use std::{
    collections::HashMap,
    fs,
    io::{Cursor, Write},
    path::Path,
};
use zip::{CompressionMethod, ZipWriter, write::SimpleFileOptions};

const MAX_BYTES: usize = 256 * 1024 * 1024;
const MAX_TEXT: usize = 512 * 1024 * 1024;
const NONE: u32 = 0xFFFF_FFFF;

fn invalid(action: &'static str) -> ApiError {
    ApiError::new(ErrorCode::InvalidRule, "kindle_import", action)
}

fn u16_at(b: &[u8], at: usize) -> Option<u16> {
    Some(u16::from_be_bytes(b.get(at..at + 2)?.try_into().ok()?))
}
fn u32_at(b: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_be_bytes(b.get(at..at + 4)?.try_into().ok()?))
}

/// PalmDB 记录表。
struct Records<'a> {
    data: &'a [u8],
    offsets: Vec<usize>,
}
impl<'a> Records<'a> {
    fn parse(data: &'a [u8]) -> Result<Self, ApiError> {
        if data.get(60..68) != Some(b"BOOKMOBI".as_slice()) {
            return Err(invalid("choose_azw3_or_mobi_file"));
        }
        let count = u16_at(data, 76).ok_or_else(|| invalid("choose_valid_kindle_file"))? as usize;
        let mut offsets = Vec::with_capacity(count + 1);
        for i in 0..count {
            let at = u32_at(data, 78 + i * 8).ok_or_else(|| invalid("choose_valid_kindle_file"))?;
            offsets.push(at as usize);
        }
        offsets.push(data.len());
        if offsets.windows(2).any(|w| w[0] > w[1]) || offsets.last() > Some(&data.len()) {
            return Err(invalid("choose_valid_kindle_file"));
        }
        Ok(Self { data, offsets })
    }
    fn len(&self) -> usize {
        self.offsets.len() - 1
    }
    fn get(&self, i: usize) -> Option<&'a [u8]> {
        if i >= self.len() {
            return None;
        }
        self.data.get(self.offsets[i]..self.offsets[i + 1])
    }
}

/// 一段 MOBI 头（旧式 MOBI 或 KF8）。所有记录号都已换成整个文件里的绝对记录号。
struct Header {
    start: usize,
    compression: u16,
    text_length: usize,
    text_records: usize,
    encoding: u32,
    version: u32,
    first_resource: Option<usize>,
    huff: Option<(usize, usize)>,
    extra_flags: u16,
    fdst: Option<usize>,
    skel: Option<usize>,
    frag: Option<usize>,
    exth: HashMap<u32, Vec<Vec<u8>>>,
    full_name: String,
}

fn header(records: &Records, start: usize) -> Result<Header, ApiError> {
    let r = records
        .get(start)
        .ok_or_else(|| invalid("choose_valid_kindle_file"))?;
    if r.get(16..20) != Some(b"MOBI".as_slice()) {
        return Err(invalid("choose_valid_kindle_file"));
    }
    if u16_at(r, 12).unwrap_or(0) != 0 {
        return Err(invalid("kindle_file_has_drm"));
    }
    let len = u32_at(r, 20).unwrap_or(0) as usize;
    let field =
        |at: usize| -> Option<u32> { (at + 4 <= 16 + len).then(|| u32_at(r, at)).flatten() };
    let rel = |v: Option<u32>| {
        v.filter(|&v| v != NONE && v != 0)
            .map(|v| start + v as usize)
    };
    let mut exth = HashMap::new();
    if field(0x80).unwrap_or(0) & 0x40 != 0 {
        let at = 16 + len;
        if r.get(at..at + 4) == Some(b"EXTH".as_slice()) {
            let count = u32_at(r, at + 8).unwrap_or(0) as usize;
            let mut p = at + 12;
            for _ in 0..count.min(4096) {
                let (Some(kind), Some(size)) = (u32_at(r, p), u32_at(r, p + 4)) else {
                    break;
                };
                let size = size as usize;
                if size < 8 || p + size > r.len() {
                    break;
                }
                exth.entry(kind)
                    .or_insert_with(Vec::new)
                    .push(r[p + 8..p + size].to_vec());
                p += size;
            }
        }
    }
    let full_name = match (field(0x54), field(0x58)) {
        (Some(off), Some(n)) => r
            .get(off as usize..off as usize + n as usize)
            .map(|b| String::from_utf8_lossy(b).into_owned())
            .unwrap_or_default(),
        _ => String::new(),
    };
    let huff = match (field(0x70), field(0x74)) {
        (Some(off), Some(n)) if off != NONE && n > 0 => Some((start + off as usize, n as usize)),
        _ => None,
    };
    let version = field(0x24).unwrap_or(0);
    Ok(Header {
        start,
        compression: u16_at(r, 0).unwrap_or(0),
        text_length: u32_at(r, 4).unwrap_or(0) as usize,
        text_records: u16_at(r, 8).unwrap_or(0) as usize,
        encoding: field(0x1C).unwrap_or(65001),
        version,
        first_resource: field(0x6C).filter(|&v| v != NONE).map(|v| v as usize),
        huff,
        extra_flags: if len >= 0xE4 {
            u16_at(r, 0xF2).unwrap_or(0)
        } else {
            0
        },
        fdst: if version >= 8 { rel(field(0xC0)) } else { None },
        frag: if version >= 8 { rel(field(0xF8)) } else { None },
        skel: if version >= 8 { rel(field(0xFC)) } else { None },
        exth,
        full_name,
    })
}

/// PalmDOC（LZ77 变体）解压。
fn palmdoc(input: &[u8], out: &mut Vec<u8>) {
    let mut i = 0;
    while i < input.len() {
        let c = input[i];
        i += 1;
        match c {
            0x00 | 0x09..=0x7F => out.push(c),
            0x01..=0x08 => {
                let end = (i + c as usize).min(input.len());
                out.extend_from_slice(&input[i..end]);
                i = end;
            }
            0x80..=0xBF => {
                let Some(&next) = input.get(i) else { break };
                i += 1;
                let pair = (((c as usize) << 8) | next as usize) & 0x3FFF;
                let distance = pair >> 3;
                let length = (pair & 7) + 3;
                if distance == 0 || distance > out.len() {
                    continue;
                }
                let from = out.len() - distance;
                for k in 0..length {
                    let b = out[from + k];
                    out.push(b);
                }
            }
            _ => {
                out.push(b' ');
                out.push(c ^ 0x80);
            }
        }
    }
}

/// HUFF/CDIC 解压（大书用的压缩）。
struct Huff {
    dict1: Vec<(u32, bool, u64)>,
    mincode: Vec<u64>,
    maxcode: Vec<u64>,
    dictionary: Vec<Option<(Vec<u8>, bool)>>,
}
impl Huff {
    fn load(records: &Records, first: usize, count: usize) -> Result<Self, ApiError> {
        let bad = || invalid("choose_valid_kindle_file");
        let huff = records.get(first).ok_or_else(bad)?;
        if huff.get(0..8) != Some(b"HUFF\x00\x00\x00\x18".as_slice()) {
            return Err(bad());
        }
        let off1 = u32_at(huff, 8).ok_or_else(bad)? as usize;
        let off2 = u32_at(huff, 12).ok_or_else(bad)? as usize;
        let mut dict1 = Vec::with_capacity(256);
        for i in 0..256 {
            let v = u32_at(huff, off1 + i * 4).ok_or_else(bad)?;
            let codelen = v & 0x1F;
            let term = v & 0x80 != 0;
            let maxcode = (((v >> 8) as u64 + 1) << (32 - codelen.min(32))).wrapping_sub(1);
            if codelen == 0 {
                return Err(bad());
            }
            dict1.push((codelen, term, maxcode));
        }
        let mut mincode = vec![0u64];
        let mut maxcode = vec![0u64];
        for codelen in 1..=32u32 {
            let min = u32_at(huff, off2 + (codelen as usize - 1) * 8).ok_or_else(bad)? as u64;
            let max = u32_at(huff, off2 + (codelen as usize - 1) * 8 + 4).ok_or_else(bad)? as u64;
            mincode.push(min << (32 - codelen));
            maxcode.push(((max + 1) << (32 - codelen)).wrapping_sub(1));
        }
        let mut dictionary = Vec::new();
        for k in 1..count {
            let cdic = records.get(first + k).ok_or_else(bad)?;
            if cdic.get(0..8) != Some(b"CDIC\x00\x00\x00\x10".as_slice()) {
                return Err(bad());
            }
            let phrases = u32_at(cdic, 8).ok_or_else(bad)? as usize;
            let bits = u32_at(cdic, 12).ok_or_else(bad)?;
            let n = (1usize << bits.min(30)).min(phrases.saturating_sub(dictionary.len()));
            for j in 0..n {
                let off = u16_at(cdic, 16 + j * 2).ok_or_else(bad)? as usize;
                let blen = u16_at(cdic, 16 + off).ok_or_else(bad)? as usize;
                let slice = cdic
                    .get(18 + off..18 + off + (blen & 0x7FFF))
                    .ok_or_else(bad)?
                    .to_vec();
                dictionary.push(Some((slice, blen & 0x8000 != 0)));
            }
        }
        Ok(Self {
            dict1,
            mincode,
            maxcode,
            dictionary,
        })
    }
    fn unpack(&mut self, data: &[u8], depth: usize) -> Vec<u8> {
        let mut out = Vec::new();
        if depth > 32 {
            return out;
        }
        let mut bitsleft = data.len() as i64 * 8;
        let mut padded = data.to_vec();
        padded.extend_from_slice(&[0; 8]);
        let q = |pos: usize| u64::from_be_bytes(padded[pos..pos + 8].try_into().unwrap());
        let mut pos = 0;
        let mut x = q(pos);
        let mut n: i64 = 32;
        loop {
            if n <= 0 {
                pos += 4;
                if pos + 8 > padded.len() {
                    break;
                }
                x = q(pos);
                n += 32;
            }
            let code = (x >> n) & 0xFFFF_FFFF;
            let (mut codelen, term, mut maxcode) = self.dict1[(code >> 24) as usize];
            if !term {
                while (codelen as usize) < 32 && code < self.mincode[codelen as usize] {
                    codelen += 1;
                }
                maxcode = self.maxcode[codelen as usize];
            }
            n -= codelen as i64;
            bitsleft -= codelen as i64;
            if bitsleft < 0 {
                break;
            }
            let r = ((maxcode.wrapping_sub(code)) >> (32 - codelen)) as usize;
            let Some(entry) = self.dictionary.get(r).cloned() else {
                break;
            };
            let Some((slice, done)) = entry else { break };
            if done {
                out.extend_from_slice(&slice);
            } else {
                self.dictionary[r] = None;
                let expanded = self.unpack(&slice, depth + 1);
                out.extend_from_slice(&expanded);
                self.dictionary[r] = Some((expanded, true));
            }
        }
        out
    }
}

/// 去掉文字记录末尾的附加数据（多字节字符补位、索引等）。
fn trim_trailing(mut data: &[u8], flags: u16) -> &[u8] {
    let mut f = flags >> 1;
    while f != 0 {
        if f & 1 != 0 {
            let tail = &data[data.len().saturating_sub(4)..];
            let mut size = 0usize;
            for &b in tail {
                if b & 0x80 != 0 {
                    size = 0;
                }
                size = (size << 7) | (b & 0x7F) as usize;
            }
            data = &data[..data.len().saturating_sub(size)];
        }
        f >>= 1;
    }
    if flags & 1 != 0 {
        if let Some(&last) = data.last() {
            let n = (last & 3) as usize + 1;
            data = &data[..data.len().saturating_sub(n)];
        }
    }
    data
}

fn raw_text(records: &Records, h: &Header) -> Result<Vec<u8>, ApiError> {
    let mut huff = match (h.compression, h.huff) {
        (17480, Some((first, count))) => Some(Huff::load(records, first, count)?),
        (17480, None) => return Err(invalid("choose_valid_kindle_file")),
        (1 | 2, _) => None,
        _ => return Err(invalid("kindle_compression_not_supported")),
    };
    let mut out = Vec::with_capacity(h.text_length);
    for i in 1..=h.text_records {
        let record = records
            .get(h.start + i)
            .ok_or_else(|| invalid("choose_valid_kindle_file"))?;
        let data = trim_trailing(record, h.extra_flags);
        match (h.compression, huff.as_mut()) {
            (1, _) => out.extend_from_slice(data),
            (2, _) => palmdoc(data, &mut out),
            (_, Some(huff)) => {
                let text = huff.unpack(data, 0);
                out.extend_from_slice(&text);
            }
            _ => {}
        }
        if out.len() > MAX_TEXT {
            return Err(invalid("reduce_kindle_file_size"));
        }
    }
    if h.text_length > 0 && out.len() > h.text_length {
        out.truncate(h.text_length);
    }
    Ok(out)
}

/// INDX 索引表的一条：名字与各标签的值。
type IndexEntry = (Vec<u8>, HashMap<u8, Vec<u64>>);

fn varint_forward(data: &[u8], at: usize) -> (usize, u64) {
    let mut value = 0u64;
    let mut used = 0;
    while let Some(&b) = data.get(at + used) {
        used += 1;
        value = (value << 7) | (b & 0x7F) as u64;
        if b & 0x80 != 0 || used >= 9 {
            break;
        }
    }
    (used.max(1), value)
}

fn index(records: &Records, first: usize) -> Result<Vec<IndexEntry>, ApiError> {
    let bad = || invalid("choose_valid_kindle_file");
    let head = records.get(first).ok_or_else(bad)?;
    if head.get(0..4) != Some(b"INDX".as_slice()) {
        return Err(bad());
    }
    let header_len = u32_at(head, 4).ok_or_else(bad)? as usize;
    let count = u32_at(head, 24).ok_or_else(bad)? as usize;
    let mut tags = Vec::new();
    let mut control_bytes = 0usize;
    if head.get(header_len..header_len + 4) == Some(b"TAGX".as_slice()) {
        let entry_off = u32_at(head, header_len + 4).ok_or_else(bad)? as usize;
        control_bytes = u32_at(head, header_len + 8).ok_or_else(bad)? as usize;
        let mut i = 12;
        while i + 4 <= entry_off {
            let at = header_len + i;
            let t = head.get(at..at + 4).ok_or_else(bad)?;
            tags.push((t[0], t[1] as usize, t[2], t[3]));
            i += 4;
        }
    }
    let mut out = Vec::new();
    for k in 1..=count.min(65535) {
        let data = records.get(first + k).ok_or_else(bad)?;
        if data.get(0..4) != Some(b"INDX".as_slice()) {
            return Err(bad());
        }
        let idxt = u32_at(data, 20).ok_or_else(bad)? as usize;
        let entries = u32_at(data, 24).ok_or_else(bad)? as usize;
        let mut positions = Vec::with_capacity(entries + 1);
        for j in 0..entries {
            positions.push(u16_at(data, idxt + 4 + j * 2).ok_or_else(bad)? as usize);
        }
        positions.push(idxt);
        for j in 0..entries {
            let start = positions[j];
            let end = positions[j + 1];
            let len = *data.get(start).ok_or_else(bad)? as usize;
            let name = data
                .get(start + 1..start + 1 + len)
                .ok_or_else(bad)?
                .to_vec();
            let control = start + 1 + len;
            let mut cursor = control + control_bytes;
            let mut found = Vec::new();
            let mut control_index = 0;
            for &(tag, per_entry, mask, end_flag) in &tags {
                if end_flag == 1 {
                    control_index += 1;
                    continue;
                }
                let cbyte = *data.get(control + control_index).ok_or_else(bad)?;
                let mut value = cbyte & mask;
                if value == 0 {
                    continue;
                }
                if value == mask {
                    if mask.count_ones() > 1 {
                        let (used, v) = varint_forward(data, cursor);
                        cursor += used;
                        found.push((tag, None, Some(v as usize), per_entry));
                    } else {
                        found.push((tag, Some(1usize), None, per_entry));
                    }
                } else {
                    let mut m = mask;
                    while m & 1 == 0 {
                        m >>= 1;
                        value >>= 1;
                    }
                    found.push((tag, Some(value as usize), None, per_entry));
                }
            }
            let mut map = HashMap::new();
            for (tag, value_count, value_bytes, per_entry) in found {
                let mut values = Vec::new();
                if let Some(n) = value_count {
                    for _ in 0..n * per_entry {
                        let (used, v) = varint_forward(data, cursor);
                        cursor += used;
                        values.push(v);
                    }
                } else if let Some(total) = value_bytes {
                    let mut consumed = 0;
                    while consumed < total && cursor < end {
                        let (used, v) = varint_forward(data, cursor);
                        cursor += used;
                        consumed += used;
                        values.push(v);
                    }
                }
                map.insert(tag, values);
            }
            out.push((name, map));
        }
    }
    Ok(out)
}

/// KF8 正文：按 SKEL / FRAG 索引把片段插回骨架，得到各个 XHTML 文件；另外返回样式等其他数据流。
fn kf8_parts(
    records: &Records,
    h: &Header,
    raw: &[u8],
) -> Result<(Vec<Vec<u8>>, Vec<Vec<u8>>), ApiError> {
    let mut flows = Vec::new();
    if let Some(fdst) = h.fdst.and_then(|i| records.get(i))
        && fdst.get(0..4) == Some(b"FDST".as_slice())
    {
        let count = u32_at(fdst, 8).unwrap_or(0) as usize;
        for i in 0..count.min(4096) {
            let (Some(a), Some(b)) = (u32_at(fdst, 12 + i * 8), u32_at(fdst, 16 + i * 8)) else {
                break;
            };
            let (a, b) = (a as usize, (b as usize).min(raw.len()));
            flows.push(raw.get(a.min(b)..b).unwrap_or_default().to_vec());
        }
    }
    if flows.is_empty() {
        flows.push(raw.to_vec());
    }
    let text = flows[0].clone();
    let others = flows.split_off(1);
    let (Some(skel), Some(frag)) = (h.skel, h.frag) else {
        return Ok((vec![text], others));
    };
    let skeletons = index(records, skel)?;
    let fragments = index(records, frag)?;
    let mut parts = Vec::new();
    let mut next = 0usize;
    for (_, tags) in &skeletons {
        let count = tags.get(&1).and_then(|v| v.first()).copied().unwrap_or(0) as usize;
        let (Some(&pos), Some(&len)) = (
            tags.get(&6).and_then(|v| v.first()),
            tags.get(&6).and_then(|v| v.get(1)),
        ) else {
            continue;
        };
        let (pos, len) = (pos as usize, len as usize);
        let mut skeleton = text.get(pos..pos + len).unwrap_or_default().to_vec();
        let mut base = pos + len;
        for _ in 0..count {
            let Some((name, ftags)) = fragments.get(next) else {
                break;
            };
            next += 1;
            let insert = std::str::from_utf8(name)
                .ok()
                .and_then(|s| s.trim().parse::<usize>().ok())
                .unwrap_or(pos);
            let flen = ftags.get(&6).and_then(|v| v.get(1)).copied().unwrap_or(0) as usize;
            let slice = text.get(base..base + flen).unwrap_or_default().to_vec();
            let at = insert.saturating_sub(pos).min(skeleton.len());
            skeleton.splice(at..at, slice);
            base += flen;
        }
        parts.push(skeleton);
    }
    if parts.is_empty() {
        parts.push(text);
    }
    Ok((parts, others))
}

/// 资源区开头的记录：图片、字体或 Kindle 文件里其他已知的辅助记录。
fn is_resource_record(r: &[u8]) -> bool {
    matches!(
        r.get(0..4),
        Some(
            [0xFF, 0xD8, 0xFF, _]
                | [0x89, b'P', b'N', b'G']
                | [b'G', b'I', b'F', b'8']
                | [b'B', b'M', _, _]
        )
    ) || [
        b"FONT", b"RESC", b"FLIS", b"FCIS", b"BOUN", b"DATP", b"SRCS", b"CMET", b"PAGE", b"CRES",
        b"kind",
    ]
    .iter()
    .any(|m| r.get(0..4) == Some(m.as_slice()))
}

/// 资源记录：图片按原格式，字体记录（FONT）解开；返回 记录序号（从 1 起，对应 kindle:embed 与 recindex）→（文件名, 媒体类型, 数据）。
fn resources(records: &Records, first: usize) -> HashMap<usize, (String, String, Vec<u8>)> {
    let mut out = HashMap::new();
    for i in first..records.len() {
        let Some(r) = records.get(i) else { break };
        let n = i - first + 1;
        let image = match r.get(0..4) {
            Some([0xFF, 0xD8, 0xFF, _]) => Some(("jpg", "image/jpeg")),
            Some([0x89, b'P', b'N', b'G']) => Some(("png", "image/png")),
            Some([b'G', b'I', b'F', b'8']) => Some(("gif", "image/gif")),
            Some([b'B', b'M', _, _]) => Some(("bmp", "image/bmp")),
            _ => None,
        };
        if let Some((ext, media)) = image {
            out.insert(
                n,
                (
                    format!("images/img{n:04}.{ext}"),
                    media.to_owned(),
                    r.to_vec(),
                ),
            );
        } else if r.get(0..4) == Some(b"FONT".as_slice())
            && let Some(font) = font_record(r)
        {
            let (ext, media) = if font.get(0..4) == Some(b"OTTO".as_slice()) {
                ("otf", "font/otf")
            } else {
                ("ttf", "font/ttf")
            };
            out.insert(
                n,
                (format!("fonts/font{n:04}.{ext}"), media.to_owned(), font),
            );
        }
    }
    out
}

/// FONT 记录：可选异或混淆与 zlib 压缩。
fn font_record(r: &[u8]) -> Option<Vec<u8>> {
    let size = u32_at(r, 4)? as usize;
    let flags = u32_at(r, 8)?;
    let data_off = u32_at(r, 12)? as usize;
    let key_len = u32_at(r, 16)? as usize;
    let key_off = u32_at(r, 20)? as usize;
    let mut data = r.get(data_off..)?.to_vec();
    if flags & 2 != 0 && key_len > 0 {
        let key = r.get(key_off..key_off + key_len)?.to_vec();
        for (i, b) in data.iter_mut().take(1040).enumerate() {
            *b ^= key[i % key_len];
        }
    }
    if flags & 1 != 0 {
        let mut out = Vec::new();
        std::io::Read::read_to_end(&mut flate2::read::ZlibDecoder::new(&data[..]), &mut out)
            .ok()?;
        data = out;
    }
    (data.len() == size || size == 0).then_some(data)
}

fn base32(s: &str) -> Option<usize> {
    usize::from_str_radix(s, 32).ok()
}

fn escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

/// 把（可能不规范的）HTML 片段整理成结构简单、一定合法的 XHTML：标题、段落、图片。
fn clean_xhtml(html: &str, image_src: &dyn Fn(&str) -> Option<String>) -> String {
    let doc = Html::parse_document(html);
    let mut out = String::new();
    let mut text = Line::default();
    /// 当前一行：行内样式和网址链接留着，后面导入时读。
    #[derive(Default)]
    struct Line {
        html: String,
        has_text: bool,
        open: Vec<(String, String)>,
    }
    fn flush(line: &mut Line, out: &mut String, tag: &str) {
        for (name, _) in line.open.iter().rev() {
            line.html.push_str(&format!("</{name}>"));
        }
        if line.has_text {
            out.push_str(&format!("<{tag}>{}</{tag}>\n", line.html));
        }
        line.has_text = false;
        // 跨段的样式在下一段接着开，否则标签不成对。
        line.html = line.open.iter().map(|(_, tag)| tag.as_str()).collect();
    }
    /// 行内元素的开标签；不保留的返回空。
    fn inline_tag(e: &scraper::node::Element) -> Option<String> {
        let name = e.name();
        let href = e.attr("href").map(str::trim).filter(|href| {
            let lower = href.to_ascii_lowercase();
            lower.starts_with("http://")
                || lower.starts_with("https://")
                || lower.starts_with("mailto:")
        });
        let styled = e.attr("class").is_some() || e.attr("style").is_some();
        let keep = match name {
            "b" | "strong" | "i" | "em" | "u" | "ins" | "sup" | "sub" | "cite" | "dfn" | "var" => {
                true
            }
            "a" => href.is_some(),
            "span" => styled,
            _ => false,
        };
        if !keep {
            return None;
        }
        let mut tag = format!("<{name}");
        for key in ["class", "style"] {
            if let Some(value) = e.attr(key) {
                tag.push_str(&format!(" {key}=\"{}\"", escape(value)));
            }
        }
        if let (Some(href), "a") = (href, name) {
            tag.push_str(&format!(" href=\"{}\"", escape(href)));
        }
        tag.push('>');
        Some(tag)
    }
    /// 规整的表格原样带过去：格子里只留文字。带图、嵌套的按普通文字走。
    fn table_xhtml(node: ego_tree::NodeRef<'_, Node>) -> Option<String> {
        let tagged = |n: &ego_tree::NodeRef<'_, Node>, names: &[&str]| {
            n.value()
                .as_element()
                .is_some_and(|e| names.contains(&e.name()))
        };
        let text = |n: ego_tree::NodeRef<'_, Node>| {
            n.descendants()
                .filter_map(|c| c.value().as_text().map(|t| t.to_string()))
                .collect::<String>()
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ")
        };
        if node
            .descendants()
            .skip(1)
            .any(|n| tagged(&n, &["table", "img", "image"]))
        {
            return None;
        }
        let mut html = String::from("<table>");
        if let Some(caption) = node.children().find(|n| tagged(n, &["caption"])) {
            html.push_str(&format!("<caption>{}</caption>", escape(&text(caption))));
        }
        let mut rows = 0;
        for row in node.descendants().filter(|n| tagged(n, &["tr"])) {
            rows += 1;
            html.push_str("<tr>");
            for cell in row.children().filter(|n| tagged(n, &["td", "th"])) {
                let element = cell.value().as_element()?;
                let name = element.name();
                html.push_str(&format!("<{name}"));
                for key in ["colspan", "rowspan"] {
                    if let Some(value) =
                        element.attr(key).and_then(|v| v.trim().parse::<u32>().ok())
                    {
                        html.push_str(&format!(" {key}=\"{value}\""));
                    }
                }
                html.push_str(&format!(">{}</{name}>", escape(&text(cell))));
            }
            html.push_str("</tr>");
        }
        html.push_str("</table>\n");
        (rows > 0).then_some(html)
    }
    fn walk(
        node: ego_tree::NodeRef<'_, Node>,
        out: &mut String,
        text: &mut Line,
        image_src: &dyn Fn(&str) -> Option<String>,
    ) {
        match node.value() {
            Node::Text(t) => {
                text.html.push_str(&escape(t));
                text.has_text |= !t.trim().is_empty();
            }
            Node::Element(e) => {
                let name = e.name();
                if matches!(name, "head" | "script" | "style" | "title") {
                    return;
                }
                if name == "img" || name == "image" {
                    let src = e
                        .attr("src")
                        .or_else(|| e.attr("recindex"))
                        .or_else(|| e.attr("xlink:href"))
                        .or_else(|| e.attr("href"))
                        .and_then(image_src);
                    if let Some(src) = src {
                        flush(text, out, "p");
                        let alt = e.attr("alt").unwrap_or("");
                        out.push_str(&format!(
                            "<div><img src=\"{}\" alt=\"{}\"/></div>\n",
                            escape(&src),
                            escape(alt)
                        ));
                    }
                    return;
                }
                if name == "table"
                    && let Some(table) = table_xhtml(node)
                {
                    flush(text, out, "p");
                    out.push_str(&table);
                    return;
                }
                let heading = matches!(name, "h1" | "h2" | "h3" | "h4" | "h5" | "h6");
                let block = heading
                    || matches!(
                        name,
                        "p" | "div"
                            | "li"
                            | "blockquote"
                            | "pre"
                            | "section"
                            | "article"
                            | "figure"
                            | "tr"
                            | "dt"
                            | "dd"
                            | "body"
                            | "table"
                    );
                if block || name == "br" || name == "mbp:pagebreak" {
                    flush(text, out, "p");
                }
                let inline = inline_tag(e);
                if let Some(tag) = &inline {
                    text.html.push_str(tag);
                    text.open.push((name.to_owned(), tag.clone()));
                }
                for child in node.children() {
                    walk(child, out, text, image_src);
                }
                if inline.is_some() {
                    text.open.pop();
                    text.html.push_str(&format!("</{name}>"));
                }
                if heading {
                    flush(text, out, name);
                } else if block {
                    flush(text, out, "p");
                }
            }
            _ => {
                for child in node.children() {
                    walk(child, out, text, image_src);
                }
            }
        }
    }
    walk(doc.tree.root(), &mut out, &mut text, image_src);
    flush(&mut text, &mut out, "p");
    out
}

fn decode(bytes: &[u8], encoding: u32) -> String {
    if encoding == 1252 {
        bytes.iter().map(|&b| b as char).collect()
    } else {
        String::from_utf8_lossy(bytes).into_owned()
    }
}

fn exth_text(h: &Header, kind: u32, encoding: u32) -> Vec<String> {
    h.exth
        .get(&kind)
        .map(|v| {
            v.iter()
                .map(|b| decode(b, encoding).trim().to_owned())
                .filter(|s| !s.is_empty())
                .collect()
        })
        .unwrap_or_default()
}

/// 读出的书：各章 XHTML 正文、资源、元数据。
struct Book {
    title: String,
    authors: Vec<String>,
    language: String,
    parts: Vec<String>,
    styles: Vec<String>,
    resources: Vec<(String, String, Vec<u8>)>,
    cover: Option<String>,
    kind: &'static str,
}

fn read_book(data: &[u8]) -> Result<Book, ApiError> {
    let records = Records::parse(data)?;
    let first = header(&records, 0)?;
    // 新版 MOBI 同时带旧式与 KF8 两份：EXTH 121 给出 KF8 头所在的记录。
    let kf8 = if first.version >= 8 {
        Some(header(&records, 0)?)
    } else {
        first
            .exth
            .get(&121)
            .and_then(|v| v.first())
            .and_then(|b| u32_at(b, 0))
            .and_then(|b| {
                let b = b as usize;
                header(&records, b)
                    .ok()
                    .or_else(|| header(&records, b + 1).ok())
            })
    };
    let main = kf8.as_ref().unwrap_or(&first);
    let raw = raw_text(&records, main)?;
    // 资源：先按记录号原样找；新版 MOBI 里 KF8 头的记录号可能相对 KF8 部分，第一条不是资源时换成相对位置。
    let resource_start = [
        main.first_resource,
        main.first_resource.map(|v| v + main.start),
        first.first_resource,
    ]
    .into_iter()
    .flatten()
    .find(|&i| records.get(i).is_some_and(is_resource_record))
    .unwrap_or(records.len());
    let found = resources(&records, resource_start);
    let src_for = |key: usize| found.get(&key).map(|(name, _, _)| name.clone());
    let mut styles = Vec::new();
    let encoding = main.encoding;
    let parts: Vec<String> = if kf8.is_some() {
        let (parts, flows) = kf8_parts(&records, main, &raw)?;
        let embed =
            regex::Regex::new(r#"kindle:embed:([0-9A-Va-v]{4})(\?mime=[^"')\s]*)?"#).unwrap();
        for flow in flows {
            let css = decode(&flow, encoding);
            if css.trim_start().starts_with('<') {
                continue;
            }
            styles.push(
                embed
                    .replace_all(&css, |c: &regex::Captures| {
                        base32(&c[1])
                            .and_then(src_for)
                            .map(|s| format!("../{s}"))
                            .unwrap_or_default()
                    })
                    .into_owned(),
            );
        }
        parts
            .into_iter()
            .map(|p| {
                let html = decode(&p, encoding);
                clean_xhtml(&html, &|src| {
                    let key = embed.captures(src).and_then(|c| base32(&c[1]))?;
                    src_for(key).map(|s| format!("../{s}"))
                })
            })
            .collect()
    } else {
        let html = decode(&raw, encoding);
        // 旧式 MOBI 是一整篇 HTML：按分页标记切成几个文件（第一段之后的每段先去掉标记本身的剩余部分）。
        html.split("<mbp:pagebreak")
            .enumerate()
            .map(|(i, chunk)| {
                let chunk = if i == 0 {
                    chunk
                } else {
                    chunk.split_once('>').map_or(chunk, |(_, rest)| rest)
                };
                clean_xhtml(chunk, &|src| {
                    src.trim()
                        .parse::<usize>()
                        .ok()
                        .and_then(src_for)
                        .map(|s| format!("../{s}"))
                })
            })
            .collect()
    };
    let parts: Vec<String> = parts.into_iter().filter(|p| !p.trim().is_empty()).collect();
    if parts.is_empty() {
        return Err(invalid("choose_kindle_file_with_text"));
    }
    let cover = main
        .exth
        .get(&201)
        .or_else(|| first.exth.get(&201))
        .and_then(|v| v.first())
        .and_then(|b| u32_at(b, 0))
        .and_then(|i| found.get(&(i as usize + 1)))
        .filter(|(_, media, _)| media.starts_with("image/"))
        .map(|(name, _, _)| name.clone());
    let mut title = exth_text(main, 503, encoding)
        .into_iter()
        .next()
        .unwrap_or_default();
    if title.is_empty() {
        title = main.full_name.trim().to_owned();
    }
    let mut authors = exth_text(main, 100, encoding);
    if authors.is_empty() {
        authors = exth_text(&first, 100, encoding);
    }
    let language = exth_text(main, 524, encoding)
        .into_iter()
        .next()
        .unwrap_or_default();
    let mut resources: Vec<_> = found.into_values().collect();
    resources.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(Book {
        title,
        authors,
        language,
        parts,
        styles,
        resources,
        cover,
        kind: if kf8.is_some() { "kf8" } else { "mobi" },
    })
}

fn write_epub(book: &Book) -> Result<Vec<u8>, ApiError> {
    let io = |_| ApiError::new(ErrorCode::Io, "kindle_import", "retry_kindle_import");
    let mut zip = ZipWriter::new(Cursor::new(Vec::new()));
    let stored = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
    let deflated = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
    zip.start_file("mimetype", stored)
        .map_err(|_| invalid("retry_kindle_import"))?;
    zip.write_all(b"application/epub+zip").map_err(io)?;
    zip.start_file("META-INF/container.xml", deflated)
        .map_err(|_| invalid("retry_kindle_import"))?;
    zip.write_all(br#"<?xml version="1.0" encoding="UTF-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#).map_err(io)?;
    let mut manifest = String::new();
    let mut spine = String::new();
    let style_links: String = (0..book.styles.len())
        .map(|i| {
            format!(
                "<link rel=\"stylesheet\" type=\"text/css\" href=\"../styles/style{i:02}.css\"/>"
            )
        })
        .collect();
    for (i, css) in book.styles.iter().enumerate() {
        let name = format!("styles/style{i:02}.css");
        zip.start_file(format!("OEBPS/{name}"), deflated)
            .map_err(|_| invalid("retry_kindle_import"))?;
        zip.write_all(css.as_bytes()).map_err(io)?;
        manifest.push_str(&format!(
            "<item id=\"css{i}\" href=\"{name}\" media-type=\"text/css\"/>"
        ));
    }
    for (i, part) in book.parts.iter().enumerate() {
        let name = format!("text/part{i:04}.xhtml");
        zip.start_file(format!("OEBPS/{name}"), deflated)
            .map_err(|_| invalid("retry_kindle_import"))?;
        let page = format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>{}</title>{style_links}</head><body>\n{part}</body></html>\n",
            escape(&book.title)
        );
        zip.write_all(page.as_bytes()).map_err(io)?;
        manifest.push_str(&format!(
            "<item id=\"p{i}\" href=\"{name}\" media-type=\"application/xhtml+xml\"/>"
        ));
        spine.push_str(&format!("<itemref idref=\"p{i}\"/>"));
    }
    for (i, (name, media, data)) in book.resources.iter().enumerate() {
        zip.start_file(format!("OEBPS/{name}"), stored)
            .map_err(|_| invalid("retry_kindle_import"))?;
        zip.write_all(data).map_err(io)?;
        let cover = book.cover.as_deref() == Some(name.as_str());
        manifest.push_str(&format!(
            "<item id=\"{}\" href=\"{name}\" media-type=\"{media}\"{}/>",
            if cover {
                "cover-image".to_owned()
            } else {
                format!("r{i}")
            },
            if cover {
                " properties=\"cover-image\""
            } else {
                ""
            }
        ));
    }
    let authors: String = book
        .authors
        .iter()
        .map(|a| format!("<dc:creator>{}</dc:creator>", escape(a)))
        .collect();
    let language = if book.language.is_empty() {
        "und"
    } else {
        &book.language
    };
    let opf = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"id\">easypub-kindle-import</dc:identifier><dc:title>{}</dc:title>{authors}<dc:language>{}</dc:language>{}</metadata><manifest>{manifest}</manifest><spine>{spine}</spine></package>\n",
        escape(&book.title),
        escape(language),
        if book.cover.is_some() {
            "<meta name=\"cover\" content=\"cover-image\"/>"
        } else {
            ""
        }
    );
    zip.start_file("OEBPS/content.opf", deflated)
        .map_err(|_| invalid("retry_kindle_import"))?;
    zip.write_all(opf.as_bytes()).map_err(io)?;
    Ok(zip
        .finish()
        .map_err(|_| invalid("retry_kindle_import"))?
        .into_inner())
}

/// 把 AZW3 / MOBI 转成 EPUB，写到 output_path（必须是新的 .epub 文件）。原文件不改。
pub fn to_epub(source_path: &str, output_path: &str) -> Result<String, ApiError> {
    let source = Path::new(source_path);
    let output = Path::new(output_path);
    let ext = |p: &Path| {
        p.extension()
            .and_then(|v| v.to_str())
            .unwrap_or("")
            .to_ascii_lowercase()
    };
    if !source.is_absolute()
        || !output.is_absolute()
        || !matches!(ext(source).as_str(), "azw3" | "mobi" | "azw")
        || ext(output) != "epub"
    {
        return Err(invalid("choose_absolute_kindle_and_epub_paths"));
    }
    if output.exists() {
        return Err(invalid("choose_new_kindle_import_output"));
    }
    let data = fs::read(source).map_err(|_| invalid("choose_readable_kindle_file"))?;
    if data.is_empty() || data.len() > MAX_BYTES {
        return Err(ApiError::new(
            ErrorCode::TooLarge,
            "kindle_import",
            "reduce_kindle_file_size",
        ));
    }
    let book = read_book(&data)?;
    let epub = write_epub(&book)?;
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent)
            .map_err(|_| invalid("choose_writable_kindle_import_directory"))?;
    }
    fs::write(output, &epub).map_err(|_| invalid("write_kindle_import_copy"))?;
    Ok(json!({"source_path":source_path,"output_path":output_path,"kind":book.kind,"parts":book.parts.len(),
        "resources":book.resources.len(),"has_cover":book.cover.is_some(),"title":book.title}).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn palmdoc_decodes_literals_runs_and_back_references() {
        let mut out = Vec::new();
        // "abc" + 回溯 3 字节复制 3 字节 + 空格加 'x' + 两个原样字节。
        palmdoc(
            &[b'a', b'b', b'c', 0x80, 0x18, 0xF8, 0x02, 0x01, 0x02],
            &mut out,
        );
        assert_eq!(out, b"abcabc x\x01\x02");
    }

    #[test]
    fn trailing_entries_are_trimmed() {
        // 一个 2 字节的附加项（大小编码在末尾，含自身）+ 多字节补位 1 字节。
        let data = [b'h', b'i', 0x00, 0xAA, 0x82];
        assert_eq!(trim_trailing(&data, 0b10), &[b'h', b'i', 0x00]);
        let data = [b'h', b'i', 0x00];
        assert_eq!(trim_trailing(&data, 0b01), &[b'h', b'i']);
    }

    #[test]
    fn messy_html_becomes_well_formed_xhtml() {
        let x = clean_xhtml(
            "<html><body><h2>第一章 开始</h2><p>正文<b>加粗</b>&nbsp;后面<br>换行<p>没闭合<img recindex=\"00001\"><font>字</font></body>",
            &|s| (s == "00001").then(|| "../images/img0001.jpg".to_owned()),
        );
        let page = format!("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>{x}</body></html>");
        roxmltree::Document::parse(&page).unwrap();
        assert!(x.contains("<h2>第一章 开始</h2>"));
        assert!(x.contains("<img src=\"../images/img0001.jpg\""));
        assert!(x.contains("没闭合"));
        let styled = clean_xhtml(
            "<p>一<b class=\"x\">二<br/>三</b><a href=\"kindle:pos:fid:0001\">内部</a>\
             <a href=\"https://a.b/?c=1&amp;d=2\">网址</a></p>\
             <table><caption>说明</caption><tr><th colspan=\"2\">头</th></tr><tr><td>甲</td><td>乙</td></tr></table>\
             <table><tr><td><img src=\"kindle:embed:0001\"/>图</td></tr></table>",
            &|_| None,
        );
        assert!(
            styled.contains("<p>一<b class=\"x\">二</b></p>"),
            "{styled}"
        );
        assert!(
            styled.contains(
                "<p><b class=\"x\">三</b>内部<a href=\"https://a.b/?c=1&amp;d=2\">网址</a></p>"
            ),
            "{styled}"
        );
        assert!(styled.contains("<table><caption>说明</caption><tr><th colspan=\"2\">头</th></tr><tr><td>甲</td><td>乙</td></tr></table>"), "{styled}");
        assert!(styled.contains("<p>图</p>"), "{styled}");
        assert!(roxmltree::Document::parse(&format!("<r>{styled}</r>")).is_ok());
    }

    #[test]
    fn non_kindle_and_drm_files_are_rejected() {
        assert_eq!(
            read_book(b"not a book").err().unwrap().next_action,
            "choose_azw3_or_mobi_file"
        );
        // 最小的 PalmDB：一条记录，PalmDOC 头里的加密标志为 2。
        let mut data = vec![0u8; 78 + 8 + 2];
        data[60..68].copy_from_slice(b"BOOKMOBI");
        data[76..78].copy_from_slice(&1u16.to_be_bytes());
        data[78..82].copy_from_slice(&(88u32).to_be_bytes());
        let mut record = vec![0u8; 0xF8];
        record[0..2].copy_from_slice(&2u16.to_be_bytes());
        record[12..14].copy_from_slice(&2u16.to_be_bytes());
        record[16..20].copy_from_slice(b"MOBI");
        record[20..24].copy_from_slice(&0xE8u32.to_be_bytes());
        data.truncate(88);
        data.extend_from_slice(&record);
        assert_eq!(
            read_book(&data).err().unwrap().next_action,
            "kindle_file_has_drm"
        );
    }
}
