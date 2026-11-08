"""Package a local test font using Python zlib; never modify or ship system fonts."""
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]
source = Path('C:/Windows/Fonts/marlett.ttf').read_bytes()
n = struct.unpack_from('>H', source, 4)[0]
out = bytearray(44 + 20 * n)
total = 12 + 16 * n
compressed_tables = 0
for i in range(n):
    tag, checksum, offset, length = struct.unpack_from('>4sIII', source, 12 + i * 16)
    raw = source[offset:offset + length]
    compressed = zlib.compress(raw)
    data = compressed if len(compressed) < len(raw) else raw
    compressed_tables += len(data) < len(raw)
    struct.pack_into('>4sIIII', out, 44 + i * 20, tag, len(out), len(data), len(raw), checksum)
    out.extend(data)
    out.extend(b'\0' * (-len(out) % 4))
    total += (length + 3) & ~3
struct.pack_into('>4s4sIHHIHHIIIII', out, 0, b'wOFF', source[:4], len(out), n, 0, total, 1, 0, 0, 0, 0, 0, 0)
target = ROOT / 'artifacts/woff-fixture/sample.woff'
target.parent.mkdir(parents=True, exist_ok=True)
target.write_bytes(out)
assert compressed_tables > 0
print(f'{target}: {len(out)} bytes; {compressed_tables} compressed tables')
