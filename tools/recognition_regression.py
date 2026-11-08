"""只读 TXT 回归：有序标题哈希、源哈希、逐条差异；报告仅写 artifacts。"""
import argparse
from datetime import datetime
import difflib
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def compare(old, new):
    changes = []
    for tag, a, b, c, d in difflib.SequenceMatcher(a=old, b=new, autojunk=False).get_opcodes():
        if tag != 'equal':
            changes.append({'kind': tag, 'old_index': a, 'new_index': c,
                            'removed': old[a:b], 'added': new[c:d]})
    return changes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--baseline', type=Path)
    args = parser.parse_args()
    source = args.input.resolve(strict=True)
    paths = sorted((p for p in source.rglob('*') if p.is_file() and p.suffix.lower() == '.txt'),
                   key=lambda p: p.relative_to(source).as_posix())
    if not paths:
        parser.error('输入目录没有 TXT，不能创建空基线')
    output = ROOT / 'artifacts' / ('recognition-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    if output.resolve().is_relative_to(source):
        parser.error('输出不能位于只读样书目录内')
    output.mkdir(parents=True)
    baseline = json.loads(args.baseline.read_text(encoding='utf-8')) if args.baseline else None
    if baseline and (baseline.get('version') != 1 or baseline.get('metric') != 'recognized_tree_nodes' or baseline.get('errors')):
        parser.error('基线版本或统计口径不兼容')
    books, errors = {}, []
    for path in paths:
        key = path.relative_to(source).as_posix()
        before = sha(path)
        try:
            run = subprocess.run([str(args.probe.resolve()), str(path)], capture_output=True,
                                 encoding='utf-8', timeout=180)
        except subprocess.TimeoutExpired:
            errors.append({'book': key, 'error': '识别超时，请单独检查此样本'})
            continue
        after = sha(path)
        if run.returncode or before != after:
            errors.append({'book': key, 'error': '识别失败' if run.returncode else '输入在测量时发生变化'})
            continue
        nodes = json.loads(run.stdout)['nodes']
        titles = [node['title'] for node in nodes]
        encoded = json.dumps(titles, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
        books[key] = {'count': len(titles), 'source_sha256': before,
                      'titles_sha256': hashlib.sha256(encoded).hexdigest(), 'titles': titles}
    differences = []
    if baseline:
        old_books = baseline['books']
        for key in sorted(set(old_books) | set(books)):
            old, new = old_books.get(key), books.get(key)
            if old != new:
                differences.append({'book': key, 'source_changed': old is None or new is None or
                                    old['source_sha256'] != new['source_sha256'],
                                    'changes': compare(old['titles'] if old else [], new['titles'] if new else [])})
    report = {'version': 1, 'metric': 'recognized_tree_nodes', 'book_count': len(books),
              'total': sum(b['count'] for b in books.values()), 'books': books,
              'baseline': str(args.baseline) if args.baseline else None,
              'differences': differences, 'errors': errors,
              'probe_sha256': sha(args.probe)}
    (output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'output': str(output), 'books': len(books), 'total': report['total'],
                      'differences': len(differences), 'errors': len(errors)}, ensure_ascii=True))
    return 1 if errors else 2 if differences else 0


if __name__ == '__main__':
    raise SystemExit(main())
