"""Read-only V55 fixture verifier, including source restoration for original EPUB."""
import argparse
import hashlib
import json
from pathlib import Path
import posixpath
import xml.etree.ElementTree as ET
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('file', type=Path)
    parser.add_argument('--source', type=Path)
    args = parser.parse_args()
    with zipfile.ZipFile(args.file) as archive:
        container = ET.fromstring(archive.read('META-INF/container.xml'))
        package = next(n.get('full-path') for n in container.iter() if n.tag.endswith('rootfile'))
        opf = ET.fromstring(archive.read(package))
        items = {n.get('id'): posixpath.normpath(posixpath.join(posixpath.dirname(package), n.get('href')))
                 for n in opf.iter() if n.tag.endswith('}item')}
        names = [items[n.get('idref')] for n in opf.iter() if n.tag.endswith('}itemref')]
        pages = []
        for name in names:
            markup = archive.read(name).decode('utf-8')
            # Only converter roundtrips may omit the namespace on retained attributes.
            if not args.source and 'epub:type=' in markup and 'xmlns:epub=' not in markup:
                markup = markup.replace('<html ', '<html xmlns:epub="http://www.idpf.org/2007/ops" ', 1)
            pages.append(ET.fromstring(markup))
        bodies = [next(n for n in page.iter() if n.tag.endswith('}body')) for page in pages]
        text = [''.join(page.itertext()) for page in bodies]
        front = next(i for i, value in enumerate(text) if '版权正文' in value)
        back = next(i for i, value in enumerate(text) if '后记正文' in value)
        chapter1 = next(i for i, value in enumerate(text) if '首段保持原文' in value)
        chapter2 = next(i for i, value in enumerate(text) if '末行保持' in value)
        assert front < chapter1 <= chapter2 < back, names
        assert '远行' in text[front] and '新书名' not in text[front]
        assert '{未知}' in text[front] and '纯文本 <附页> & 保留' in text[front]
        assert '更新后的第二段' in text[back]
        navs = [archive.read(path).decode('utf-8') for path in archive.namelist() if path.endswith('.ncx')]
        navs += [archive.read(items[n.get('id')]).decode('utf-8') for n in opf.iter()
                 if n.tag.endswith('}item') and 'nav' in n.get('properties', '').split()]
        assert navs and all('版权声明' in nav and '后记' in nav for nav in navs)
        for i in [front, back]:
            assert not any(n.get('data-source') is not None for n in bodies[i].iter())
        if args.source:
            toc = names.index('EPUB/toc.xhtml')
            assert front < toc < chapter1
            assert len([n for n in names if '/matter-' in n]) == 2
            restored = ''.join((n.get('data-original') if n.get('data-original') is not None else ''.join(n.itertext()))
                              + {'lf': '\n', 'cr': '\r', 'crlf': '\r\n', 'none': ''}[n.get('data-eol')]
                              for page in bodies for n in page.iter() if n.get('data-source') == 'true')
            assert restored.encode('utf-8') == args.source.read_bytes(), (repr(restored), repr(args.source.read_bytes().decode('utf-8')))
    print(json.dumps({'file': str(args.file), 'front': front, 'body': [chapter1, chapter2], 'back': back,
                      'toc_documents': len(navs), 'source_restored': bool(args.source),
                      'sha256': hashlib.sha256(args.file.read_bytes()).hexdigest()}, ensure_ascii=False))


if __name__ == '__main__':
    main()
