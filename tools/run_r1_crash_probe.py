"""Kill only owned worker processes at explicit R1-only checkpoints."""
from pathlib import Path
import datetime
import hashlib
import json
import os
import subprocess
import time

root = Path(__file__).resolve().parents[1]
worker = root / 'target/debug/examples/r1_crash_worker.exe'
run_root = root / 'artifacts' / ('r1-crash-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
run_root.mkdir(parents=True)
payload = '第一章 开始😀\r\n源文件禁止覆盖\n尾'.encode('utf-8')
rows = []
flags = subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0

def invoke(*args):
    return subprocess.run([str(worker), *map(str, args)], capture_output=True,
                          text=True, encoding='utf-8', timeout=10, creationflags=flags)

for point in ('prepared', 'manifest_partial', 'staged', 'published_before_manifest', 'external_output'):
    case = run_root / point
    case.mkdir()
    source, output = case / 'source.txt', case / 'output.txt'
    txn = case / '.output.txt.easypub-txn'
    source.write_bytes(payload)
    env = os.environ.copy()
    env['EASYPUB_R1_CRASH_POINT'] = 'staged' if point == 'external_output' else point
    process = subprocess.Popen([str(worker), 'apply', str(source), str(output)],
                               env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               creationflags=flags)
    try:
        deadline = time.monotonic() + 10
        while not (txn / 'checkpoint').exists():
            if process.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError(f'{point}: worker did not reach checkpoint')
            time.sleep(0.01)
        manifest_before = json.loads((txn / 'manifest.json').read_text('utf-8'))
        # A live owner must exclude recovery in an independent process.
        contender = invoke('recover', txn)
        assert contender.returncode == 2 and 'Busy' in contender.stdout, contender.stdout
        if point == 'external_output':
            output.write_bytes(b'external-output-preserve')
        process.kill()
        process.communicate(timeout=5)
        assert process.returncode != 0
        first = invoke('recover', txn)
        second = invoke('recover', txn)
        assert source.read_bytes() == payload
        if point == 'prepared':
            assert first.returncode == second.returncode == 2
            assert 'Transaction' in first.stdout and not output.exists()
            outcome = 'prepared manifest retained; no staged data to publish'
        elif point == 'external_output':
            assert first.returncode == second.returncode == 2
            assert 'OutputConflict' in first.stdout
            assert output.read_bytes() == b'external-output-preserve'
            outcome = 'external output retained; conflict reported'
        else:
            assert first.returncode == second.returncode == 0, (first.stdout, second.stdout)
            a, b = json.loads(first.stdout), json.loads(second.stdout)
            assert a['source_unchanged'] and b['source_unchanged']
            assert a['output_sha256'] == b['output_sha256'] == hashlib.sha256(payload).hexdigest()
            assert output.read_bytes() == payload
            outcome = 'recovered and idempotent'
        rows.append(dict(checkpoint=point, live_recovery_blocked=True,
                         killed_exit_code=process.returncode, source_unchanged=True,
                         manifest_stage_before_kill=manifest_before['stage'], outcome=outcome))
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate(timeout=5)

report = dict(passed=True, recorded_at=datetime.datetime.now().astimezone().isoformat(),
              worker_sha256=hashlib.sha256(worker.read_bytes()).hexdigest(),
              scope='Windows owned worker process termination, not hardware power loss',
              artifact_root=str(run_root), cases=rows,
              limitations=['storage-controller power-loss durability not measured',
                           'publication requires same-volume hard-link support',
                           'only minimal new-copy transaction, not multi-file EPUB commit'])
(root / 'docs/evidence/r1-process-crash.json').write_text(
    json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(json.dumps(report, ensure_ascii=False))
