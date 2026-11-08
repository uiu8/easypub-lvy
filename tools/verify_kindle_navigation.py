"""Read-only OUT-085 verifier: PalmDOC, guide INDX/CNCX, and rendered positions.

Usage: python -I -X utf8 tools/verify_kindle_navigation.py book.azw3 [--expect-start TEXT]
The decoder is independent of Kindling and also accepts KindleGen dual MOBI.
"""
import argparse
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import struct


def u32(data, at=0):
    return struct.unpack_from('>I', data, at)[0]


def u16(data, at=0):
    return struct.unpack_from('>H', data, at)[0]


def vwi(data, at):
    value = 0
    while True:
        byte = data[at]
        at += 1
        value = (value << 7) | (byte & 127)
        if byte & 128:
            return value, at


def decompress(raw):
    out, at = bytearray(), 0
    while at < len(raw):
        value = raw[at]
        at += 1
        if 1 <= value <= 8:
            out.extend(raw[at:at + value])
            at += value
        elif value < 128:
            out.append(value)
        elif value >= 192:
            out.extend((32, value ^ 128))
        else:
            pair = (value << 8) | raw[at]
            at += 1
            distance, length = (pair >> 3) & 2047, (pair & 7) + 3
            assert 0 < distance <= len(out)
            for _ in range(length):
                out.append(out[-distance])
    return bytes(out)


def text_flow(records, base):
    header, chunks = records[base], []
    compression, flags = u16(header), u32(header, 240)
    assert compression in (1, 2), 'This verifier supports uncompressed / PalmDOC text'
    for raw in records[base + 1:base + 1 + u16(header, 8)]:
        for bit in range(1, 32):
            if flags & (1 << bit):
                size, shift = 0, 0
                for byte in reversed(raw):
                    size |= (byte & 127) << shift
                    shift += 7
                    if byte & 128:
                        break
                assert 0 < size <= len(raw)
                raw = raw[:-size]
        if flags & 1:
            raw = raw[:-((raw[-1] & 3) + 1)]
        chunks.append(decompress(raw) if compression == 2 else raw)
    text = b''.join(chunks)
    assert len(text) == u32(header, 4)
    return text


def exth(header):
    raw = header[16 + u32(header, 20):]
    assert raw[:4] == b'EXTH'
    at, result = 12, {}
    for _ in range(u32(raw, 8)):
        kind, size = u32(raw, at), u32(raw, at + 4)
        result.setdefault(kind, []).append(raw[at + 8:at + size])
        at += size
    return result


def index(records, at):
    primary = records[at]
    assert primary[:4] == b'INDX'
    tagx = u32(primary, 180)
    assert primary[tagx:tagx + 4] == b'TAGX'
    controls = u32(primary, tagx + 8)
    specs = [tuple(primary[p:p + 4]) for p in range(tagx + 12, tagx + u32(primary, tagx + 4), 4)]
    entries = []
    count = u32(primary, 24)
    for record in records[at + 1:at + 1 + count]:
        idxt = u32(record, 20)
        assert record[idxt:idxt + 4] == b'IDXT'
        for i in range(u32(record, 24)):
            pos = u16(record, idxt + 4 + i * 2)
            length = record[pos]
            label = record[pos + 1:pos + 1 + length].decode('utf-8')
            pos += 1 + length
            cb = record[pos:pos + controls]
            pos += controls
            control, tags = 0, {}
            for tag, per_entry, mask, end in specs:
                if end:
                    control += 1
                    continue
                value = cb[control] & mask
                if value == mask and mask & (mask - 1):
                    size, pos = vwi(record, pos)
                    stop = pos + size
                    values = []
                    while pos < stop:
                        item, pos = vwi(record, pos)
                        values.append(item)
                else:
                    n = (value // (mask & -mask)) * per_entry
                    values = []
                    for _ in range(n):
                        item, pos = vwi(record, pos)
                        values.append(item)
                if values:
                    tags[tag] = values
            entries.append((label, tags))
    strings = {}
    for i, raw in enumerate(records[at + 1 + count:at + 1 + count + u32(primary, 52)]):
        pos = 0
        while pos < len(raw) and raw[pos]:
            key = i * 0x10000 + pos
            size, pos = vwi(raw, pos)
            strings[key] = raw[pos:pos + size].decode('utf-8')
            pos += size
    return entries, strings


class PlainText(HTMLParser):
    def __init__(self, text):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.feed(text)

    def handle_data(self, data):
        self.parts.append(data)


def preview(blob, at):
    assert 0 <= at < len(blob)
    tail = blob[at:].decode('utf-8')
    assert tail.lstrip().startswith('<'), f'Position {at} lands inside markup/text'
    return ' '.join(''.join(PlainText(tail[:4096]).parts).split())[:160]


def inspect(path, expected=None, required=()):
    data = Path(path).read_bytes()
    assert data[60:68] == b'BOOKMOBI'
    offsets = [u32(data, 78 + 8 * i) for i in range(u16(data, 76))] + [len(data)]
    records = [data[a:b] for a, b in zip(offsets, offsets[1:])]
    bases = [0]
    first = exth(records[0])
    if 121 in first:
        bases.append(u32(first[121][0]))
    report = []
    for base in bases:
        header = records[base]
        metadata = exth(header)
        starts = [u32(v) for v in metadata.get(116, [])]
        assert starts, f'Missing EXTH 116 in section {base}'
        blob = text_flow(records, base)
        version = u32(header, 36)
        guide = {}
        if version >= 8:
            skels, _ = index(records, base + u32(header, 252))
            frags, _ = index(records, base + u32(header, 248))
            parts, fragment_no = [], 0
            for _, tags in skels:
                start, length = tags[6][:2]
                shell = blob[start:start + length]
                cursor = start + length
                for _ in range(tags[1][0]):
                    insert, frag = frags[fragment_no]
                    fragment_no += 1
                    size = frag[6][1]
                    at = int(insert) - start
                    shell = shell[:at] + blob[cursor:cursor + size] + shell[at:]
                    cursor += size
                parts.append(shell)
            rendered = b''.join(parts)
            refs, titles = index(records, base + u32(header, 260))
            for kind, tags in refs:
                # Calibre emits tag 6 (fid, offset); KindleGen also uses tag 3.
                fid, off = tags[6] if 6 in tags else (tags[3][0], 0)
                at = int(frags[fid][0]) + off
                guide[kind] = {'offset': at, 'title': titles[tags[1][0]], 'text': preview(rendered, at)}
        else:
            rendered = blob
            for tag in re.findall(rb'<reference\b[^>]*>', blob):
                kind = re.search(rb'type=["\']([^"\']+)', tag)[1].decode()
                at = int(re.search(rb'filepos=["\']?(\d+)', tag)[1])
                guide[kind] = {'offset': at, 'text': preview(rendered, at)}
        start = starts[-1]
        if 'cover' in guide:
            at = guide['cover']['offset']
            end = rendered.find(b'</body', at)
            cover_html = rendered[at:end if end >= 0 else len(rendered)]
            image = re.search(rb'<img\b[^>]*>', cover_html)
            if image:
                resource_header = records[0] if base else header
                if version >= 8:
                    ref = re.search(rb'kindle:embed:([0-9A-V]+)', image[0])
                    number = int(ref[1], 32)
                else:
                    ref = re.search(rb'recindex=["\']?(\d+)', image[0])
                    number = int(ref[1])
                record = u32(resource_header, 108) + number - 1
                assert records[record].startswith((b'\xff\xd8', b'\x89PNG', b'GIF'))
                guide['cover']['image_record'] = record
                guide['cover']['image_bytes'] = len(records[record])
        for text in required:
            assert text.encode('utf-8') in rendered, f'Missing text in section {base}: {text}'
        start_text = preview(rendered, start)
        assert 'text' in guide, f'Missing text guide in section {base}'
        assert guide['text']['offset'] == start, (guide['text'], starts)
        if expected:
            assert start_text.startswith(expected), (start_text, expected)
        report.append({'version': version, 'start': start, 'start_text': start_text, 'guide': guide})
    return {'file': str(Path(path).resolve()), 'sha256': hashlib.sha256(data).hexdigest(), 'sections': report}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('book')
    parser.add_argument('--expect-start')
    parser.add_argument('--require-text', action='append', default=[])
    args = parser.parse_args()
    print(json.dumps(inspect(args.book, args.expect_start, args.require_text), ensure_ascii=False, indent=2))
