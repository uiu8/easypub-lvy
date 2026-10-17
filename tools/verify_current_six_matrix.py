"""Read actual EPUB bodies against fixture hashes, independently of EasyPub parsing."""
import argparse
import hashlib
import json
import re
import zipfile
from collections import Counter
from pathlib import Path
from xml.etree import ElementTree as ET

parser = argparse.ArgumentParser()
parser.add_argument('directory', type=Path)
args = parser.parse_args()
results = []
for receipt in sorted(args.directory.glob('*/evidence.json')):
    e = json.loads(receipt.read_text(encoding='utf-8-sig'))
    truth = json.loads((Path(e['fixture']) / '真值清单.json').read_text(encoding='utf-8-sig'))
    for name, digest in truth['hashes'].items():
        assert hashlib.sha256((Path(e['fixture']) / name).read_bytes()).hexdigest() == digest
    path = next(o['path'] for o in e['outputs'] if o['format'] == 'EPUB')
    with zipfile.ZipFile(path) as z:
        ns = {'o': 'http://www.idpf.org/2007/opf'}
        package_name = next(n for n in z.namelist() if n.endswith('.opf'))
        package = ET.fromstring(z.read(package_name))
        manifest = {n.attrib['id']: n.attrib['href'] for n in package.findall('o:manifest/o:item', ns)}
        lines = []
        heading = volume = None
        for item in package.findall('o:spine/o:itemref', ns):
            page = (Path(package_name).parent / manifest[item.attrib['idref']]).as_posix()
            for n in ET.fromstring(z.read(page)).iter():
                if n.attrib.get('data-source') == 'true':
                    text = ''.join(n.itertext()).strip()
                    if n.tag.rsplit('}', 1)[-1] in ['h1','h2','h3','h4','h5','h6']:
                        heading = text
                        if re.fullmatch(r'第\d+卷 旅程\d+', text):
                            volume = int(re.search(r'第(\d+)卷', text)[1])
                    lines.append((text, heading, volume))
    chapters = {c['id']: c for c in truth['chapters']}
    bodies = []
    mismatches = []
    for index, (line, heading, volume) in enumerate(lines):
        m = re.fullmatch(r'这一天，第(\d+)条旅途的第(\d+)段故事在晨光中展开。', line)
        if not m:
            continue
        identity = f'v{m[1]}-c{m[2]}'
        c = chapters[identity]
        actual = '\n'.join(row[0] for row in lines[index:index+3])
        assert hashlib.sha256(actual.encode()).hexdigest() == c['body_sha256'], (receipt, identity, 'body changed')
        bodies.append(identity)
        if heading != c['title'] or volume != c['volume']:
            mismatches.append({'id': identity, 'heading': heading, 'volume': volume})
    expected = [i['id'] for i in truth['instances'] if not i.get('duplicate', False)]
    assert Counter(bodies) == Counter(expected), (receipt, 'lost or duplicate bodies', Counter(bodies)-Counter(expected), Counter(expected)-Counter(bodies))
    reference = e['mode'] in [2,4]
    # Local-only repairs cannot establish the true volume/order of S1/S3/MIX.
    if reference and e['scenario'] in ['S1','S3']:
        assert bodies == [c['id'] for c in truth['chapters'] if not c['missing_body']], (receipt, 'order')
    elif not reference:
        assert bodies == expected, (receipt, 'unrequested reorder')
    if e['scenario'] in ['S0','S2','S4','S6','S7','S9'] or (reference and e['scenario'] in ['S1','S3','S8']):
        assert not mismatches, (receipt, 'wrong heading or volume', mismatches[:3])
    if 'copy' in e:
        copied = Path(e['copy']).read_text(encoding='utf-8-sig')
        assert Counter(re.findall(r'这一天，第(\d+)条旅途的第(\d+)段故事在晨光中展开。', copied)) == Counter(tuple(i[1:].split('-c')) for i in bodies)
    results.append({'case':receipt.parent.name,'body_instances':len(bodies),'unique_bodies':len(set(bodies)),
                    'body_hashes_unchanged':True,'unresolved_heading_or_volume':len(mismatches),
                    'remaining_checks':e['remaining']['total'],'epub':path})
assert len(results) == 44, f'Expected 40 defect combinations plus 4 clean controls; found {len(results)}'
report = {'passed':True,'cells':results,'limitations':['S5 missing headings require manual boundary selection; S6 missing bodies remain absent.', 'Local-only S1/S3/MIX does not infer true volumes or order.', 'Physical Kindle rendering not checked.']}
(args.directory / 'independent-verification.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({'passed':True,'combinations':len(results),'body_instances_checked':sum(r['body_instances'] for r in results)}))
