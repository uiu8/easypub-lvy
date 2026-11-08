"""Isolated Kindle language experiment; never modifies the product output."""
import hashlib
import csv
import json
from pathlib import Path
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
evidence = json.loads((ROOT / 'docs/evidence/r4-matrix-mix-epub.json').read_text(encoding='utf-8-sig'))
source = Path(evidence['epub']).resolve()
before = hashlib.sha256(source.read_bytes()).hexdigest()
run = ROOT / 'artifacts/r5-kindle-language-zh'
run.mkdir(exist_ok=False)
target = run / 'MIX-zh.epub'
with zipfile.ZipFile(source) as src, zipfile.ZipFile(target, 'w') as dst:
    for entry in src.infolist():
        data = src.read(entry.filename)
        if entry.filename.endswith('.opf'):
            old = b'<dc:language>und</dc:language>'
            assert data.count(old) == 1
            data = data.replace(old, b'<dc:language>zh</dc:language>')
        dst.writestr(entry, data)
exe = Path.home() / 'AppData/Local/Amazon/Kindle Previewer 3/Kindle Previewer 3.exe'
result = subprocess.run([str(exe), str(target), '-convert', '-output', str(run)],
                        capture_output=True, timeout=180)
(run / 'console.bin').write_bytes(result.stdout + result.stderr)
assert hashlib.sha256(source.read_bytes()).hexdigest() == before
summary = list(csv.DictReader((run / 'Summary_Log.csv').read_text(encoding='utf-8-sig').splitlines()))
assert len(summary) == 1 and summary[0]['转码状态'] == '成功', summary
assert summary[0]['错误数'] == '0', summary
assert (run / 'KPF/MIX-zh.kpf').is_file()
(run / 'probe.json').write_text(json.dumps({
    'source': str(source), 'source_sha256': before, 'source_unchanged': True,
    'experiment_only': True, 'only_change': 'OPF dc:language und -> zh',
    'exit_code': result.returncode, 'converter': str(exe),
    'converter_sha256': hashlib.sha256(exe.read_bytes()).hexdigest(),
    'visual_verified': False, 'kindle_device_verified': False,
}, ensure_ascii=False, indent=2), encoding='utf-8')
print(run)
