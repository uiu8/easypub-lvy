"""Create deterministic 20/100 MiB fixtures with exactly 10000 headings."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[1] / 'artifacts' / 'r1-bridge-perf'
root.mkdir(parents=True, exist_ok=True)
records = []
for size in (20, 100):
    path = root / f'sample-{size}.txt'
    target = size * 1024 * 1024
    body = ('正文含汉字𠮷、emoji😀与组合字符e\u0301。\n').encode()
    headers = [f'第{i}章 合成标题\n'.encode() for i in range(1, 10001)]
    per_chapter = (target - sum(map(len, headers))) // 10000
    block = body * (per_chapter // len(body))
    with path.open('wb') as f:
        for heading in headers:
            f.write(heading)
            f.write(block)
        remaining = target - f.tell()
        # Short padding lines keep paging representative and non-heading.
        f.write(b'x\n' * (remaining // 2))
        if remaining % 2:
            f.write(b'x')
    records.append({'path': str(path), 'bytes': path.stat().st_size,
                    'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                    'chapters': 10000})
(root / 'fixtures.json').write_text(json.dumps(records, indent=2), encoding='utf-8')
print(json.dumps(records))
