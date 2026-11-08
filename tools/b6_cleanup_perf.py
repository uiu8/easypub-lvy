"""交替测量两个本地构建的 100 MiB 清理预览；只读取样本。"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import statistics
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('before', type=Path)
parser.add_argument('after', type=Path)
parser.add_argument('sample', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
out = root / 'artifacts' / ('b6-cleanup-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
out.mkdir(parents=True)
original = hashlib.sha256(args.sample.read_bytes()).hexdigest()
rows = []
for iteration in range(3):
    for version in (['before', 'after'] if iteration % 2 == 0 else ['after', 'before']):
        exe = getattr(args, version).resolve()
        result = subprocess.run([str(exe), 'cleanup', str(args.sample.resolve())], capture_output=True,
                                text=True, encoding='utf-8', timeout=180, check=True)
        report = json.loads(result.stdout)
        rows.append(dict(version=version, iteration=iteration + 1, edits=report['edits']))
        (out / f'{version}-{iteration + 1}.json').write_text(result.stdout, encoding='utf-8')
assert hashlib.sha256(args.sample.read_bytes()).hexdigest() == original
report = dict(sample_bytes=args.sample.stat().st_size, source_sha256=original, source_unchanged=True,
              versions={name: hashlib.sha256(getattr(args, name).read_bytes()).hexdigest() for name in ['before', 'after']},
              cold_median_ms={name: statistics.median(row['edits'][0]['ms'] for row in rows if row['version'] == name)
                              for name in ['before', 'after']}, runs=rows)
(out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
print(out)
print(json.dumps(report, ensure_ascii=False))
