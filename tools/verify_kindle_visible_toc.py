"""Check actual converted visible TOC and every extracted XHTML link."""
from pathlib import Path
import subprocess
import json
import hashlib
import xml.etree.ElementTree as ET
from urllib.parse import unquote

root = Path('artifacts/r5-kindle-toc-resources').resolve()
dest = root / 'extracted'
assert not dest.exists()
subprocess.run(['C:/Program Files/Calibre2/calibre-debug.exe', '-x',
                str(root / 'sample.azw3'), str(dest)], check=True, capture_output=True)
docs = {p.resolve(): ET.parse(p).getroot() for p in (dest / 'text').glob('*.html')}
toc = [(path, node) for path, doc in docs.items() for node in doc.iter()
       if node.attrib.get('role') == 'doc-toc']
assert len(toc) == 1
path, toc_node = toc[0]
labels = [''.join(n.itertext()) for n in toc_node.iter() if n.tag.endswith('}a')]
assert labels == ['第一卷 起点', '第一章 初遇', '第二章 告别'], labels
links = 0
for path, doc in docs.items():
    for n in doc.iter():
        if n.tag.endswith('}a') and 'href' in n.attrib:
            filename, _, anchor = unquote(n.attrib['href']).partition('#')
            target = (path.parent / filename).resolve() if filename else path
            target_doc = docs[target]
            assert not anchor or any(e.attrib.get('id') == anchor for e in target_doc.iter())
            links += 1
assert links >= 7
report = {'passed': True, 'azw3': str(root / 'sample.azw3'),
          'sha256': hashlib.sha256((root / 'sample.azw3').read_bytes()).hexdigest(),
          'all_extracted_pages_well_formed': True, 'visible_toc_labels': labels,
          'resolved_links': links, 'visual_verified': False, 'kindle_device_verified': False}
Path('docs/evidence/r5-kindle-visible-toc.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(report,ensure_ascii=True))
