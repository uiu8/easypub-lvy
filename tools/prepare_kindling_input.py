"""Development adapter probe: preserve original EPUB; require an existing cover.

Not the application adapter. Keeps every original resource and changes only the
cover spine entry plus a compatibility NCX derived from the actual EPUB nav.
"""
import hashlib
import json
import posixpath
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

source, target = map(Path, sys.argv[1:3])
ns = {'o': 'http://www.idpf.org/2007/opf', 'x': 'http://www.w3.org/1999/xhtml',
      'c': 'urn:oasis:names:tc:opendocument:xmlns:container', 'dc': 'http://purl.org/dc/elements/1.1/'}
ncx_ns = 'http://www.daisy.org/z3986/2005/ncx/'
before = hashlib.sha256(source.read_bytes()).hexdigest()
with zipfile.ZipFile(source) as archive:
    files = {n: archive.read(n) for n in archive.namelist()}
container = ET.fromstring(files['META-INF/container.xml'])
opf_path = container.find('c:rootfiles/c:rootfile', ns).attrib['full-path']
base = posixpath.dirname(opf_path)
opf = ET.fromstring(files[opf_path])
manifest = opf.find('o:manifest', ns)
spine = opf.find('o:spine', ns)
items = {n.attrib['id']: n for n in manifest}
covers = [n for n in items.values() if 'cover-image' in n.attrib.get('properties', '').split()]
if len(covers) != 1:
    raise ValueError('Kindling input requires an explicitly selected cover; no cover is invented')
removed = []
for itemref in list(spine):
    item = items[itemref.attrib['idref']]
    if item.attrib['href'] == 'cover.xhtml':
        spine.remove(itemref)
        removed.append(item.attrib['href'])
navitem = next(n for n in items.values() if 'nav' in n.attrib.get('properties', '').split())
navpath = posixpath.normpath(posixpath.join(base, navitem.attrib['href']))
nav = ET.fromstring(files[navpath])
toc = next(n for n in nav.findall('.//x:nav', ns) if 'toc' in n.attrib.get('{http://www.idpf.org/2007/ops}type', '').split())
root = ET.Element('ncx', {'xmlns': ncx_ns, 'version': '2005-1'})
head = ET.SubElement(root, 'head')
metadata = opf.find('o:metadata', ns)
uid = next(n.text for n in metadata if n.attrib.get('id') == opf.attrib['unique-identifier'])
ET.SubElement(head, 'meta', {'name': 'dtb:uid', 'content': uid})
ET.SubElement(ET.SubElement(root, 'docTitle'), 'text').text = metadata.find('dc:title', ns).text
navmap = ET.SubElement(root, 'navMap')
counter = 0
depth_max = 0
def append_list(ol, parent, depth):
    global counter, depth_max
    depth_max = max(depth_max, depth)
    for li in ol.findall('x:li', ns):
        a = li.find('x:a', ns)
        if a is None:
            raise ValueError('Unsupported unlinked nav item')
        counter += 1
        point = ET.SubElement(parent, 'navPoint', {'id': f'n{counter}', 'playOrder': str(counter)})
        ET.SubElement(ET.SubElement(point, 'navLabel'), 'text').text = ''.join(a.itertext())
        href = a.attrib['href']
        file, marker, fragment = href.partition('#')
        absolute = posixpath.normpath(posixpath.join(posixpath.dirname(navpath), file))
        if absolute not in files:
            raise ValueError('Missing navigation file')
        ET.SubElement(point, 'content', {'src': posixpath.relpath(absolute, base) + (marker + fragment if marker else '')})
        child = li.find('x:ol', ns)
        if child is not None:
            append_list(child, point, depth + 1)
append_list(toc.find('x:ol', ns), navmap, 1)
ET.SubElement(head, 'meta', {'name': 'dtb:depth', 'content': str(depth_max)})
for name in ('totalPageCount', 'maxPageNumber'):
    ET.SubElement(head, 'meta', {'name': 'dtb:' + name, 'content': '0'})
ncx_id = 'easypub-kindling-ncx'
if ncx_id in items or posixpath.join(base, 'kindling.ncx') in files:
    raise ValueError('Compatibility navigation already exists')
ET.SubElement(manifest, '{'+ns['o']+'}item', {'id': ncx_id, 'href': 'kindling.ncx', 'media-type': 'application/x-dtbncx+xml'})
spine.set('toc', ncx_id)
ET.register_namespace('', ns['o'])
ET.register_namespace('dc', ns['dc'])
files[opf_path] = ET.tostring(opf, encoding='utf-8', xml_declaration=True)
files[posixpath.join(base, 'kindling.ncx')] = ET.tostring(root, encoding='utf-8', xml_declaration=True)
with zipfile.ZipFile(target, 'x') as archive:
    archive.writestr('mimetype', files.pop('mimetype'), compress_type=zipfile.ZIP_STORED)
    for name, data in files.items():
        archive.writestr(name, data, compress_type=zipfile.ZIP_DEFLATED)
assert hashlib.sha256(source.read_bytes()).hexdigest() == before
print(json.dumps({'source_unchanged': True, 'output': str(target), 'removed_cover_spine': removed, 'ncx_entries': counter}))
