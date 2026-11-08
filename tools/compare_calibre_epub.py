"""本地同源 TXT 分别经 EasyPub/Calibre 转 EPUB，输出结构差异；不评判视觉优劣。"""
import argparse
import hashlib
import json
from pathlib import Path
import posixpath
import re
import subprocess
import xml.etree.ElementTree as ET
import zipfile

NS = {'c': 'urn:oasis:names:tc:opendocument:xmlns:container',
      'o': 'http://www.idpf.org/2007/opf', 'd': 'http://purl.org/dc/elements/1.1/',
      'h': 'http://www.w3.org/1999/xhtml', 'n': 'http://www.daisy.org/z3986/2005/ncx/'}


def inspect(path):
    with zipfile.ZipFile(path) as z:
        assert z.testzip() is None
        container = ET.fromstring(z.read('META-INF/container.xml'))
        opf_path = container.find('c:rootfiles/c:rootfile', NS).attrib['full-path']
        opf = ET.fromstring(z.read(opf_path))
        base = posixpath.dirname(opf_path)
        items = {i.attrib['id']: i.attrib for i in opf.findall('o:manifest/o:item', NS)}
        resolve = lambda href: posixpath.normpath(posixpath.join(base, href))
        for item in items.values():
            assert resolve(item['href']) in z.namelist(), item['href']
        nav = next((i for i in items.values() if 'nav' in i.get('properties', '').split()), None)
        if nav:
            tree = ET.fromstring(z.read(resolve(nav['href'])))
            toc = next((n for n in tree.findall('.//h:nav', NS) if 'toc' in n.attrib.get('{http://www.idpf.org/2007/ops}type', '').split()), tree)
            titles = [''.join(n.itertext()).strip() for n in toc.findall('.//h:a', NS)]
        else:
            ncx = next(i for i in items.values() if i['media-type'] == 'application/x-dtbncx+xml')
            tree = ET.fromstring(z.read(resolve(ncx['href'])))
            titles = [n.text or '' for n in tree.findall('.//n:navPoint/n:navLabel/n:text', NS)]
        metadata = {key: [n.text or '' for n in opf.findall(f'o:metadata/d:{key}', NS)]
                    for key in ['title', 'creator', 'language', 'publisher', 'description', 'subject']}
        covers = [i for i in items.values() if 'cover-image' in i.get('properties', '').split()]
        if not covers:
            marker = opf.find("o:metadata/o:meta[@name='cover']", NS)
            if marker is not None and marker.get('content') in items:
                covers = [items[marker.get('content')]]
        cover = [{'media_type': c['media-type'], 'bytes': len(z.read(resolve(c['href']))),
                  'sha256': hashlib.sha256(z.read(resolve(c['href']))).hexdigest()} for c in covers]
        css = '\n'.join(z.read(resolve(i['href'])).decode('utf-8') for i in items.values() if i['media-type'] == 'text/css')
        styles = sorted(set(re.findall(r'([\w-]+)\s*:\s*([^;{}]+)', re.sub(r'/\*.*?\*/', '', css, flags=re.S))))
        return {'toc': titles, 'metadata': metadata, 'covers': cover,
                'style_declarations': styles, 'spine_items': len(opf.findall('o:spine/o:itemref', NS))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('batch_report', type=Path)
    parser.add_argument('--calibre', default=r'C:\Program Files\Calibre2\ebook-convert.exe')
    args = parser.parse_args()
    rows = json.loads(args.batch_report.read_text('utf-8'))['representative']
    out = args.batch_report.parent / 'calibre-comparison'
    out.mkdir(exist_ok=False)
    results = []
    for index, row in enumerate(rows):
        source = Path(row['source'])
        before = hashlib.sha256(source.read_bytes()).hexdigest()
        target = out / f'{index}.epub'
        command = [args.calibre, str(source), str(target), '--title', row['title'], '--authors', '合成作者', '--language', 'zh-CN']
        with (out / f'{index}.log').open('w', encoding='utf-8') as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=120, check=True)
        assert hashlib.sha256(source.read_bytes()).hexdigest() == before
        easy, calibre = inspect(row['epub']), inspect(target)
        results.append({'title': row['title'], 'source_sha256': before, 'source_unchanged': True,
                        'easypub': easy, 'calibre': calibre,
                        'different_fields': [key for key in easy if easy[key] != calibre[key]]})
    report = {'scope': '普通中文、混合 Unicode、分卷三份合成 TXT；比较文件结构，非视觉或真机验收', 'books': results}
    (out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(out / 'report.json')


if __name__ == '__main__':
    main()
