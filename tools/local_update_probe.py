"""B9: 用本地包副本演练 V94 → V95 → V94，不下载、不启动应用。"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('release_root', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
run = root / 'artifacts' / ('b9-update-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
run.mkdir(parents=True)
name = 'easypub-lvy-v95-20261021-win-x64'
manifest = args.release_root / (name + '-update') / 'update-manifest.json'
meta = json.loads(manifest.read_text('utf-8'))
package = args.release_root / meta['package']['name']
assert package.stat().st_size == meta['package']['bytes']
assert hashlib.sha256(package.read_bytes()).hexdigest() == meta['package']['sha256']
staging = run / 'extracted'
with zipfile.ZipFile(package) as archive:
    for entry in archive.infolist():
        dest = (staging / entry.filename).resolve()
        assert dest.is_relative_to(staging.resolve()), entry.filename
    archive.extractall(staging)
app = run / 'app-copy'
shutil.copytree(args.release_root / 'easypub-lvy-v94-20261021-win-x64', app)
probe = root / 'target/debug/examples/local_update_probe.exe'
result = subprocess.run([str(probe), str(app), str(staging / meta['package']['root']), str(manifest), str(package)],
                        capture_output=True, text=True, encoding='utf-8', timeout=180)
(run / 'probe.log').write_text(result.stdout + result.stderr, encoding='utf-8')
result.check_returncode()
report = json.loads(result.stdout)
report['artifact_root'] = str(run)
report['scope'] = '本地包副本、签名与替换/回退库；未启动真实窗口，非打包发布'
(run / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps(report, ensure_ascii=False))
