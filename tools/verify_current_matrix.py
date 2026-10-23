"""复核当前 Flutter 36 格回执和 EPUB 正文；沿用 S4 独立真值哈希口径。"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile


def body_ids(text, chapters):
    # EPUB 默认排版给正文补全角缩进，哈希口径还原这层排版空白。
    lines, found = [line.lstrip('\u3000') for line in text.splitlines()], []
    for i, line in enumerate(lines):
        match = re.fullmatch(r'这一天，第(\d+)条旅途的第(\d+)段故事在晨光中展开。', line)
        if match:
            key = f'v{match[1]}-c{match[2]}'
            digest = hashlib.sha256('\n'.join(lines[i:i+3]).encode('utf-8')).hexdigest()
            assert digest == chapters[key]['body_sha256'], (key, '正文被改写')
            found.append(key)
    return found


def epub_text(path):
    ns = {'o': 'http://www.idpf.org/2007/opf'}
    with zipfile.ZipFile(path) as archive:
        opf = ET.fromstring(archive.read('EPUB/package.opf'))
        items = {n.attrib['id']: n.attrib['href'] for n in opf.findall('o:manifest/o:item', ns)}
        output = []
        for item in opf.findall('o:spine/o:itemref', ns):
            doc = ET.fromstring(archive.read('EPUB/' + items[item.attrib['idref']]))
            for node in doc.iter():
                if node.attrib.get('data-source') == 'true':
                    output.append(''.join(node.itertext()) + {'lf':'\n','cr':'\r','crlf':'\r\n','none':''}[node.attrib['data-eol']])
        return ''.join(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('matrix', type=Path)
    args = parser.parse_args()
    results = []
    for scenario in range(1, 10):
        for mode in range(1, 5):
            folder = args.matrix / f'S{scenario}-M{mode}'
            receipt = json.loads((folder / 'evidence.json').read_text(encoding='utf-8'))
            assert receipt['scenario'] == f'S{scenario}' and receipt['mode'] == mode
            assert all(receipt[k] for k in ('source_unchanged','preview_unchanged','project_reopened'))
            fixture = Path(receipt['fixture'])
            truth = json.loads((fixture / '真值清单.json').read_text(encoding='utf-8-sig'))
            checkout_eols = []
            for name, digest in truth['hashes'].items():
                data = (fixture / name).read_bytes()
                if hashlib.sha256(data).hexdigest() != digest:
                    assert hashlib.sha256(data.replace(b'\r\n', b'\n')).hexdigest() == digest, (fixture, name)
                    checkout_eols.append(name)
            chapters = {c['id']: c for c in truth['chapters']}
            products = {p['format']: Path(p['path']) for p in receipt['outputs']}
            assert products['AZW3'].is_file() and products['AZW3'].stat().st_size > 0
            text = epub_text(products['EPUB'])
            found = body_ids(text, chapters)
            expected = [c['id'] for c in truth['chapters'] if not c['missing_body']]
            assert Counter(found) == Counter(expected), (folder.name, '正文缺失或重复')
            original = body_ids((fixture / '缺陷样书.txt').read_text(encoding='utf-8'), chapters)
            reordered = any(c['id'] == 'catalog-reorder' for c in receipt['selected'])
            expected_order = expected if reordered else list(dict.fromkeys(original))
            assert found == expected_order, (folder.name, '正文顺序变化')
            if mode >= 3:
                assert body_ids(Path(receipt['copy']).read_text(encoding='utf-8'), chapters) == found
            extracted = folder / 'independent-text.txt'
            extracted.write_bytes(text.encode('utf-8'))
            subprocess.run([sys.executable, '-I', '-X', 'utf8', 'tools/verify_epub_output.py',
                            str(products['EPUB']), str(extracted), str(folder / 'independent-epub.json')],
                           check=True, stdout=subprocess.DEVNULL)
            results.append({'scenario':scenario,'mode':mode,'bodies':len(found),
                            'canonical_fixture_hashes':True,'checkout_crlf_files':checkout_eols,
                            'body_hashes_counts_order':True,'epub_structure':True,
                            'copy_body_matches_epub':mode>=3,'project_reopened':True})
    report = {'passed':True,'cells':results,'not_verified':['真实窗口与视觉：Claude / 用户','Kindle 真机：用户','AZW3 本工具只检查文件存在，转换成功由 Flutter 回执证明']}
    (args.matrix / 'independent-summary.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(f'{len(results)}/36 后端矩阵独立复核通过')


if __name__ == '__main__':
    main()
