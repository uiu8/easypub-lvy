"""Inspect the full-resource fixture, including raw final EXTH metadata."""
from pathlib import Path
import hashlib
import json
import struct
import xml.etree.ElementTree as ET
import zipfile
import sys

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('artifacts/r5-kindle-full-resources')
manifest = json.loads((root / 'manifest.json').read_text(encoding='utf-8'))
extracted = root / 'extracted'
ns = {'o': 'http://www.idpf.org/2007/opf'}
opf = ET.parse(extracted / 'metadata.opf').getroot()
cover = next(n.attrib['href'] for n in opf.findall('o:guide/o:reference', ns)
             if n.attrib['type'] == 'cover')
assert (extracted / cover).read_bytes() == (root / manifest['cover']).read_bytes()
with zipfile.ZipFile(root / 'kindling-input.epub') as z:
    original = ET.fromstring(z.read('EPUB/body.xhtml'))
# Scope is body illustration placement. calibre's extracted visible TOC may
# contain an unbound epub prefix; do not normalize or count it as validated.
documents = [ET.parse(p).getroot() for p in sorted((extracted / 'text').glob('*.html'))
             if 'data-source=' in p.read_text(encoding='utf-8')]
all_pages = [ET.parse(p).getroot() for p in (extracted / 'text').glob('*.html')
             if 'book-translator' in p.read_text(encoding='utf-8')]
translator_nodes = [n for page in all_pages for n in page.iter()
                    if 'book-translator' in n.attrib.get('class', '').split()]
assert len(translator_nodes) == 1
assert ''.join(translator_nodes[0].itertext()) == manifest['translator']
def figures(docs):
    result = []
    previous = ''
    for doc in docs:
        for node in doc.iter():
            if node.attrib.get('data-source') == 'true':
                previous = ''.join(node.itertext())
            if node.tag.endswith('}figure'):
                children = list(node)
                img = next(n for n in children if n.tag.endswith('}img'))
                caption = next(n for n in children if n.tag.endswith('}figcaption'))
                result.append((previous, img.attrib['alt'], ''.join(caption.itertext()), img.attrib['src']))
    return result
before, after = figures([original]), figures(documents)
assert len(before) == len(after) == 1
assert before[0][:3] == after[0][:3]
assert (root / before[0][3]).read_bytes() == (extracted / 'text' / after[0][3]).read_bytes()
data = (root / 'sample.azw3').read_bytes()
u32 = lambda pos: struct.unpack_from('>I', data, pos)[0]
record = u32(78)
assert data[record+16:record+20] == b'MOBI'
offset = record + 16 + u32(record+20)
assert data[offset:offset+4] == b'EXTH'
count, end = u32(offset+8), offset + u32(offset+4)
offset += 12
records = {}
for _ in range(count):
    kind, size = u32(offset), u32(offset+4)
    assert size >= 8 and offset + size <= end
    records.setdefault(kind, []).append(data[offset+8:offset+size])
    offset += size
fields = {'author':100, 'publisher':101, 'description':103, 'isbn':104,
          'category':105, 'publication_date':106, 'title':503, 'language':524,
          'translator':108}
checks = {key: manifest[key].encode('utf-8') in records.get(code, []) for key, code in fields.items()}
assert all(checks[key] for key in ('author','publication_date','title','language'))
if '--require-bibliography' in sys.argv:
    assert all(checks.values()), checks
report = {'passed_partial': True, 'fixture': str(root),
          'azw3_sha256': hashlib.sha256(data).hexdigest(),
          'cover_exact': True, 'illustration_exact': True,
          'illustration_caption_alt_and_source_position_exact': True,
          'raw_exth_fields': checks, 'missing_exth_fields': [k for k,v in checks.items() if not v],
          'translator_contributor_verified': checks['translator'],
          'translator_role_in_exth': False, 'visual_verified': False,
          'translator_title_page_exact': True,
          'kindle_device_verified': False}
report_path = Path(sys.argv[2]) if len(sys.argv) > 2 else Path('docs/evidence/r5-kindle-full-resources.json')
report_path.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(report,ensure_ascii=True))
