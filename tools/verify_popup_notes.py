"""LAY-120: independently check paired EPUB / KF8 / MOBI7 note destinations."""
import argparse
import hashlib
import html
import importlib.util
import json
from pathlib import Path
import posixpath
import re
from urllib.parse import unquote
import xml.etree.ElementTree as ET
import zipfile

EPUB_TYPE = '{http://www.idpf.org/2007/ops}type'
XHTML = '{http://www.w3.org/1999/xhtml}'


def resolve(file, href):
    path, _, fragment = unquote(href).partition('#')
    return posixpath.normpath(posixpath.join(posixpath.dirname(file), path)) if path else file, fragment


def epub(path, expected, source, kfx_roundtrip=False, calibre_roundtrip=False):
    with zipfile.ZipFile(path) as archive:
        container = ET.fromstring(archive.read('META-INF/container.xml'))
        package = next(n.get('full-path') for n in container.iter() if n.tag.endswith('rootfile'))
        opf = ET.fromstring(archive.read(package))
        manifest = {n.get('id'): resolve(package, n.get('href'))[0] for n in opf.iter() if n.tag.endswith('}item')}
        spine = [manifest[n.get('idref')] for n in opf.iter() if n.tag.endswith('itemref')]
        pages = {file: ET.fromstring(archive.read(file)) for file in spine}
    targets = {(file, n.get('id')): n for file, doc in pages.items() for n in doc.iter() if n.get('id')}
    pairs, restored = [], []
    for file, doc in pages.items():
        parents = {child: parent for parent in doc.iter() for child in parent}
        for node in doc.iter():
            if node.get('data-source') == 'true':
                restored.append(node.get('data-original') if node.get('data-original') is not None else ''.join(node.itertext()))
                restored.append({'lf': '\n', 'cr': '\r', 'crlf': '\r\n', 'none': ''}[node.get('data-eol')])
            if calibre_roundtrip:
                # Calibre 默认输出 EPUB 2，去掉 epub:type，并可能把引用 ID
                # 放在紧邻链接的空 span 上；仍必须逐对验证精确的往返目标。
                if node.tag != XHTML + 'a' or '#' not in node.get('href', ''):
                    continue
                reference_ids = {n.get('id') for n in node.iter() if n.get('id')}
                siblings = list(parents[node])
                index = siblings.index(node)
                if index and siblings[index - 1].tag == XHTML + 'span':
                    previous = siblings[index - 1]
                    if previous.get('id') and not ''.join(previous.itertext()).strip() and not (previous.tail or '').strip():
                        reference_ids.add(previous.get('id'))
                if not reference_ids:
                    continue
                destination = resolve(file, node.get('href'))
                note = targets[destination]
                backlinks = [n for n in note.iter() if n.tag == XHTML + 'a' and n.get('href')]
                assert any(resolve(destination[0], n.get('href')) in {(file, id) for id in reference_ids} for n in backlinks), 'Calibre note lost its exact return link'
                pairs.append({'reference': ''.join(node.itertext()), 'note': ''.join(note.itertext()), 'destination': '#'.join(destination)})
                continue
            if node.get(EPUB_TYPE) != 'noteref':
                continue
            destination = resolve(file, node.get('href'))
            note = targets[destination]
            assert note.get(EPUB_TYPE) == 'footnote'
            assert note.tag == XHTML + 'aside' or (kfx_roundtrip and note.tag == XHTML + 'div')
            backlink = next(n for n in note.iter() if n.tag == XHTML + 'a')
            reference_ids = {n.get('id') for n in node.iter() if n.get('id')}
            return_file, return_id = resolve(destination[0], backlink.get('href'))
            assert return_file == file and return_id in reference_ids
            pairs.append({'reference': ''.join(node.itertext()), 'note': ''.join(note.itertext()), 'destination': '#'.join(destination)})
    assert len(pairs) == expected, (len(pairs), expected)
    if source:
        assert ''.join(restored).encode('utf-8') == Path(source).read_bytes(), 'Source reconstruction differs'
    return {'pairs': pairs, 'source_restored': bool(source)}


def mobi(path, expected):
    spec = importlib.util.spec_from_file_location('navigation', Path(__file__).with_name('verify_kindle_navigation.py'))
    nav = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(nav)
    data = Path(path).read_bytes()
    offsets = [nav.u32(data, 78 + 8 * i) for i in range(nav.u16(data, 76))] + [len(data)]
    records = [data[a:b] for a, b in zip(offsets, offsets[1:])]
    metadata = nav.exth(records[0])
    bases = [0] + ([nav.u32(metadata[121][0])] if 121 in metadata else [])
    sections = []
    for base in bases:
        header, text = records[base], nav.text_flow(records, base)
        version = nav.u32(header, 36)
        if version >= 8:
            skels, _ = nav.index(records, base + nav.u32(header, 252))
            frags, _ = nav.index(records, base + nav.u32(header, 248))
            chunks, fid = [], 0
            for _, tags in skels:
                start, length = tags[6][:2]
                chunk, cursor = text[start:start + length], start + length
                for _ in range(tags[1][0]):
                    insert, fragment = frags[fid]
                    fid += 1
                    size, at = fragment[6][1], int(insert) - start
                    chunk = chunk[:at] + text[cursor:cursor + size] + chunk[at:]
                    cursor += size
                chunks.append(chunk)
            text = b''.join(chunks)

        def target(tag):
            if version >= 8:
                match = re.search(rb'kindle:pos:fid:([0-9A-V]+):off:([0-9A-V]+)', tag)
                return int(frags[int(match[1], 32)][0]) + int(match[2], 32) if match else None
            match = re.search(rb'\bfilepos=["\']?(\d+)', tag)
            return int(match[1]) if match else None

        pairs = []
        for link in re.finditer(rb'<a\b[^>]*>', text):
            if not re.search(rb'epub:type=["\']noteref["\']', link[0]):
                continue
            at = target(link[0])
            assert at is not None
            start = re.match(rb'<aside\b[^>]*>', text[at:])
            assert start and b'footnote' in start[0], (version, at, text[at:at + 100])
            end = text.index(b'</aside>', at)
            backlink = re.search(rb'<a\b[^>]*>', text[at:end])
            assert backlink and target(backlink[0]) == link.start(), (version, link[0], backlink[0] if backlink else None)
            note = html.unescape(re.sub('<[^>]+>', '', text[at:end].decode('utf-8')))
            pairs.append({'reference_offset': link.start(), 'note_offset': at, 'note': note})
        assert len(pairs) == expected, (version, len(pairs), expected)
        sections.append({'version': version, 'pairs': pairs})
    return {'sections': sections}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('file', type=Path)
    parser.add_argument('--expected', type=int, default=2)
    parser.add_argument('--source', type=Path)
    parser.add_argument('--kfx-roundtrip', action='store_true')
    parser.add_argument('--calibre-roundtrip', action='store_true')
    args = parser.parse_args()
    report = epub(args.file, args.expected, args.source, args.kfx_roundtrip, args.calibre_roundtrip) if args.file.suffix.lower() == '.epub' else mobi(args.file, args.expected)
    report.update(file=str(args.file.resolve()), sha256=hashlib.sha256(args.file.read_bytes()).hexdigest())
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
