"""Independently inspect dual MOBI headers and decompress the UI fixture's MOBI7 text."""
from pathlib import Path
import hashlib
import json
import struct

root = Path(__file__).resolve().parent.parent
ui = json.loads((root / 'docs/evidence/conversion-workspace-mobi.json').read_text(encoding='utf-8'))
data = Path(ui['mobi']).read_bytes()
u32 = lambda b, p: struct.unpack_from('>I', b, p)[0]
u16 = lambda b, p: struct.unpack_from('>H', b, p)[0]
assert data[60:68] == b'BOOKMOBI'
count = u16(data, 76)
offsets = [u32(data, 78 + i * 8) for i in range(count)] + [len(data)]
assert offsets[0] >= 78 + 8 * count
assert all(a < b for a, b in zip(offsets, offsets[1:]))
records = [data[a:b] for a, b in zip(offsets, offsets[1:])]


def metadata(record, version):
    assert record[16:20] == b'MOBI' and u32(record, 36) == version
    exth = record[16 + u32(record, 20):]
    assert exth[:4] == b'EXTH'
    result, pos = {}, 12
    for _ in range(u32(exth, 8)):
        kind, size = u32(exth, pos), u32(exth, pos + 4)
        assert size >= 8 and pos + size <= u32(exth, 4)
        result[kind] = exth[pos + 8:pos + size]
        pos += size
    return result


legacy = metadata(records[0], 6)
modern = metadata(records[u32(legacy[121], 0)], 8)
for values in (legacy, modern):
    assert values[503].decode('utf-8') == '转换验证'
    assert values[524].decode('utf-8') == 'zh-CN'


def palmdoc(raw):
    out, pos = bytearray(), 0
    while pos < len(raw):
        value = raw[pos]
        pos += 1
        if 1 <= value <= 8:
            out.extend(raw[pos:pos + value])
            pos += value
        elif value < 128:
            out.append(value)
        elif value >= 192:
            out.extend((32, value ^ 128))
        else:
            pair = (value << 8) | raw[pos]
            pos += 1
            distance, length = (pair >> 3) & 2047, (pair & 7) + 3
            assert 0 < distance <= len(out)
            for _ in range(length):
                out.append(out[-distance])
    return out


assert u16(records[0], 0) == 2
def strip_trailers(raw):
    flags = u32(records[0], 240)
    for bit in range(1, 32):
        if flags & (1 << bit):
            size, shift = 0, 0
            for value in reversed(raw):
                size |= (value & 127) << shift
                shift += 7
                if value & 128:
                    break
            assert 0 < size <= len(raw)
            raw = raw[:-size]
    if flags & 1:
        raw = raw[:-((raw[-1] & 3) + 1)]
    return raw


text = b''.join(palmdoc(strip_trailers(r)) for r in records[1:1 + u16(records[0], 8)])
for fragment in ('第一卷 测试', '第一章 起点', '第一段正文。', '第二章 终点', '第二段正文。'):
    assert fragment.encode('utf-8') in text, fragment
report = {'dual_headers': True, 'metadata_both_sections': True,
          'legacy_text_decompressed': True, 'fixture_chapters_and_body_present': True,
          'sha256': hashlib.sha256(data).hexdigest(), 'kindle_device_verified': False}
(root / 'docs/evidence/mobi-independent.json').write_text(
    json.dumps(report, indent=2) + '\n', encoding='utf-8')
print(json.dumps(report))
