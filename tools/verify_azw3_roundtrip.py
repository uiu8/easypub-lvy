"""Read final AZW3 with calibre, then verify text and navigation independently."""
import hashlib
import json
import re
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET
from urllib.parse import unquote
import zipfile

report_file, destination = map(Path, sys.argv[1:3])
receipt = json.loads(report_file.read_text(encoding='utf-8-sig'))
azw3 = Path(receipt['output'])
before = hashlib.sha256(azw3.read_bytes()).hexdigest()
assert not destination.exists(), 'Use a new extraction directory'
calibre = Path('C:/Program Files/Calibre2/calibre-debug.exe')
version = subprocess.check_output([str(calibre), '--version'], text=True, encoding='utf-8').strip()
result = subprocess.run([str(calibre), '-x', str(azw3), str(destination)],
                        capture_output=True, text=True, encoding='utf-8', errors='replace',
                        timeout=120, creationflags=subprocess.CREATE_NO_WINDOW)
assert result.returncode == 0, result.stdout + result.stderr
assert hashlib.sha256(azw3.read_bytes()).hexdigest() == before
ns = {'o': 'http://www.idpf.org/2007/opf', 'n': 'http://www.daisy.org/z3986/2005/ncx/'}
opf = ET.parse(destination / 'metadata.opf').getroot()
items = {n.attrib['id']: n.attrib for n in opf.findall('o:manifest/o:item', ns)}
spine = [items[n.attrib['idref']]['href'] for n in opf.findall('o:spine/o:itemref', ns)]
documents = {name: ET.parse(destination / name).getroot() for name in spine}
eol = {'lf': '\n', 'cr': '\r', 'crlf': '\r\n', 'none': ''}
lines = [n for name in spine for n in documents[name].iter() if n.attrib.get('data-source') == 'true']
restored = ''.join(''.join(n.itertext()) + eol[n.attrib['data-eol']] for n in lines).encode('utf-8')
expected = Path(receipt['expected_text']).read_bytes()
assert restored == expected, 'Final AZW3 text differs'


def tree(parent, resolve):
    result = []
    for point in parent.findall('n:navPoint', ns):
        label = point.find('n:navLabel/n:text', ns).text or ''
        target = point.find('n:content', ns).attrib['src']
        node = resolve(target)
        # Compare where each entry lands, not only its displayed label.
        landed = ''.join(node.itertext())
        result.append((label, landed, tree(point, resolve)))
    return result


def find_target(target, docs):
    name, _, fragment = unquote(target).partition('#')
    doc = docs[name]
    return next(n for n in doc.iter() if n.attrib.get('id') == fragment) if fragment else doc


with zipfile.ZipFile(Path(receipt['input_epub'])) as archive:
    input_opf = ET.fromstring(archive.read('EPUB/package.opf'))
    dc = '{http://purl.org/dc/elements/1.1/}'
    input_title = input_opf.find('o:metadata/' + dc + 'title', ns).text
    assert opf.find('o:metadata/' + dc + 'title', ns).text == input_title
    input_language = input_opf.find('o:metadata/' + dc + 'language', ns).text
    final_language = opf.find('o:metadata/' + dc + 'language', ns).text
    # Matrix books are explicitly Chinese. calibre exposes ISO 639-3 zho.
    assert input_language == 'zh-CN' and final_language in ('zh-CN', 'zh', 'zho'), (input_language, final_language)
    input_cover = next(n for n in input_opf.findall('o:manifest/o:item', ns)
                       if 'cover-image' in n.attrib.get('properties', '').split())
    cover_bytes = archive.read('EPUB/' + input_cover.attrib['href'])
    cover_ref = next(n for n in opf.findall('o:guide/o:reference', ns)
                     if n.attrib['type'] == 'cover')
    final_cover = (destination / unquote(cover_ref.attrib['href'])).read_bytes()
    assert final_cover == cover_bytes, 'Synthetic cover bytes changed'
    input_docs = {name[5:]: ET.fromstring(archive.read(name)) for name in archive.namelist()
                  if name.startswith('EPUB/') and name.endswith('.xhtml')}
    original_ncx = ET.fromstring(archive.read('EPUB/kindling.ncx'))
    original_tree = tree(original_ncx.find('n:navMap', ns), lambda target: find_target(target, input_docs))
# Self-service without explicit edits must not invent missing volume names.
self_source_order = receipt['scenario'] in ('S1', 'S3') and receipt['mode'] == 'M1'
if receipt['scenario'] == 'S1' and self_source_order:
    assert expected == Path(receipt['source']).read_bytes()
    headings = [line for line in expected.decode('utf-8').splitlines()
                if re.fullmatch(r'第\d+章 卷\d+的旅程\d+', line)]
    assert len(headings) == 690
    assert [node[0] for node in original_tree] == headings
    assert all(not children for _, _, children in original_tree)
elif self_source_order:
    assert [node[0] for node in original_tree] == [f'第{i}卷 旅程{i}' for i in range(1, 7)]
    # No catalog or explicit move: independently derive the hierarchy from
    # the source's visible volume boundaries, including its misplaced chapters.
    assert Path(receipt['source']).read_bytes() == expected
    expected_groups = []
    for line in expected.decode('utf-8').splitlines():
        if re.fullmatch(r'第\d+卷 旅程\d+', line):
            expected_groups.append((line, []))
        elif re.fullmatch(r'第\d+章 卷\d+的旅程\d+', line):
            expected_groups[-1][1].append(line)
    actual_groups = [(label, [c[0] for c in chapters]) for label, _, chapters in original_tree]
    assert actual_groups == expected_groups
    assert all(not child[2] for _, _, children in original_tree for child in children)
elif receipt['scenario'] == 'workspace':
    assert expected == Path(receipt['source']).read_bytes()
    assert [n[0] for n in original_tree] == ['第一卷 测试']
    assert [n[0] for n in original_tree[0][2]] == ['第一章 起点', '第二章 终点']
    assert all(not n[2] for n in original_tree[0][2])
else:
    assert [node[0] for node in original_tree] == [f'第{i}卷 旅程{i}' for i in range(1, 7)]
    for volume, (_, _, chapters) in enumerate(original_tree, 1):
        assert chapters
        for label, _, children in chapters:
            match = re.search(r' 卷(\d+)的旅程\d+$', label)
            assert match and int(match[1]) == volume and not children, (volume, label)
ncx = ET.parse(destination / 'toc.ncx').getroot()
if receipt['scenario'] == 'S6':
    assert expected == Path(receipt['source']).read_bytes()
    actual = [child[0] for _, _, children in original_tree for child in children]
    source_headings = [line for line in expected.decode('utf-8').splitlines()
                       if re.fullmatch(r'第\d+章 卷\d+的旅程\d+', line)]
    assert actual == source_headings and len(actual) == 679
    assert not set(actual).intersection(f'第{n}章 卷4的旅程{n}' for n in range(50, 61))
final_tree = tree(ncx.find('n:navMap', ns), lambda target: find_target(target, documents))
added_title_entry = None
if len(final_tree) == len(original_tree) + 1:
    first = ncx.find('n:navMap/n:navPoint', ns)
    target = first.find('n:content', ns).attrib['src']
    page, _, fragment = unquote(target).partition('#')
    title = opf.find('o:metadata/{http://purl.org/dc/elements/1.1/}title', ns).text
    assert final_tree[0][0] == title and not final_tree[0][2]
    assert not any(n.attrib.get('data-source') == 'true' for n in documents[page].iter())
    added_title_entry = {'label': final_tree[0][0], 'target': target, 'non_source_page': True}
    final_tree = final_tree[1:]
if final_tree != original_tree:
    def mismatch(a, b):
        if len(a) != len(b): return {'counts': [len(a), len(b)]}
        for left, right in zip(a,b):
            if left[:2] != right[:2]: return {'original':left[:2], 'final':right[:2]}
            nested = mismatch(left[2], right[2])
            if nested: return nested
    print(json.dumps(mismatch(original_tree, final_tree), ensure_ascii=True)[:1800])
    raise AssertionError('NCX label, hierarchy or landing text changed')
report = {'passed': True, 'scenario': receipt['scenario'], 'mode': receipt['mode'],
          'azw3': str(azw3), 'azw3_sha256': before, 'calibre': version,
          'calibre_executable_sha256': hashlib.sha256(calibre.read_bytes()).hexdigest(),
          'extraction_directory': str(destination), 'source_lines': len(lines),
          'exact_final_text': True, 'text_sha256': hashlib.sha256(restored).hexdigest(),
          'navigation_entries': len(ncx.findall('.//n:navPoint', ns)),
          'navigation_labels_hierarchy_and_landing_text': True,
          'additional_title_page_entry': added_title_entry,
          'input_navigation_root_entries': len(original_tree),
          'input_hierarchy_semantic_correctness_verified': not self_source_order,
          'source_hierarchy_preserved_without_catalog_guess': self_source_order,
          'azw3_file_unchanged': True, 'visual_reader_verified': False,
          'metadata_and_images_verified': False}
report.update({'title_exact': True, 'input_language': input_language,
               'final_language': final_language, 'chinese_language_preserved': True,
               'regional_language_tag_preserved': final_language == input_language,
               'synthetic_cover_exact': True,
               'cover_sha256': hashlib.sha256(cover_bytes).hexdigest()})
path = Path(sys.argv[3]) if len(sys.argv) > 3 else Path('docs/evidence') / f"r4-{receipt['scenario'].lower()}-azw3-roundtrip.json"
path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps(report, ensure_ascii=True))
