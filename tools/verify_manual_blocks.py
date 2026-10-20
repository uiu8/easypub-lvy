"""Inspect V52 fixture output; source checks use original bytes, never rendered spacing."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import posixpath
import re
import xml.etree.ElementTree as ET
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('file', type=Path)
    parser.add_argument('--source', type=Path)
    parser.add_argument('--invalidated', action='store_true')
    parser.add_argument('--roundtrip', action='store_true', help='Bokai 回读：允许补回其省略的 EPUB 命名空间，仅在内存中处理')
    args = parser.parse_args()
    if args.file.suffix == '.mobi':
        spec = importlib.util.spec_from_file_location('nav', Path(__file__).with_name('verify_kindle_navigation.py'))
        nav = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(nav)
        data = args.file.read_bytes()
        offsets = [nav.u32(data, 78 + 8 * i) for i in range(nav.u16(data, 76))] + [len(data)]
        records = [data[a:b] for a, b in zip(offsets, offsets[1:])]
        text = nav.text_flow(records, 0).decode('utf-8')
        # 新书的书信默认信笺格线（V81），类名多一个 letter-ruled。
        assert len(re.findall(r'class="letter-block(?: letter-ruled)?"', text)) == 1
        assert len(re.findall(r'\bsystem-line\b', text)) == 1
        print(json.dumps({'mobi7_letter_blocks': 1, 'mobi7_system_lines': 1}))
        return
    with zipfile.ZipFile(args.file) as archive:
        container = ET.fromstring(archive.read('META-INF/container.xml'))
        package = next(n.get('full-path') for n in container.iter() if n.tag.endswith('rootfile'))
        opf = ET.fromstring(archive.read(package))
        items = {n.get('id'): posixpath.normpath(posixpath.join(posixpath.dirname(package), n.get('href'))) for n in opf.iter() if n.tag.endswith('}item')}
        pages = []
        namespaces_restored = 0
        for item in opf.iter():
            if not item.tag.endswith('itemref'):
                continue
            markup = archive.read(items[item.get('idref')]).decode('utf-8')
            # Bokai 的 KF8 -> EPUB 会保留 epub:type，却省略根节点的声明。
            # 严格检查 EasyPub 原始 EPUB；只为显式指定的回读副本补解析上下文。
            if args.roundtrip and 'epub:type=' in markup and 'xmlns:epub=' not in markup:
                markup = markup.replace('<html ', '<html xmlns:epub="http://www.idpf.org/2007/ops" ', 1)
                namespaces_restored += 1
            pages.append(ET.fromstring(markup))
        css = '\n'.join(archive.read(n).decode('utf-8') for n in archive.namelist() if n.endswith('.css'))
    nodes = [n for p in pages for n in p.iter()]
    letter = [n for n in nodes if 'letter-block' in n.get('class', '').split()]
    if not letter and args.roundtrip and not args.invalidated:
        # 书信带两个类（V81 信笺格线：letter-block letter-ruled）时，Bokai 回读把它们合成一个类（如 s7），
        # 按内容找最内层的书信块，下面仍按它实际的 CSS 检查对齐与边距。
        letter = [n for n in nodes if n.tag.endswith('}div') and '亲爱的友人：' in ''.join(n.itertext()) and '林舟' in ''.join(n.itertext())][-1:]
    assert len(letter) == (0 if args.invalidated else 1), [n.attrib for n in letter]
    if not args.invalidated:
        assert '亲爱的友人：' in ''.join(letter[0].itertext())
        assert '林舟' in ''.join(letter[0].itertext())
        # KFX 会把 letter-by 合并为 sA 等样式类，检查对应 CSS 的实际对齐。
        signature = next(n for n in letter[0].iter() if n.tag.endswith('}p') and ''.join(n.itertext()).strip() == '林舟')
        assert any(re.search(r'\.' + re.escape(c) + r'\s*\{[^}]*text-align:\s*right', css) for c in signature.get('class', '').split())
        names = [c for c in letter[0].get('class', '').split() if c != 'letter-ruled']
        letter_css = next(body for selector, body in re.findall(r'([^{}]+)\{([^}]*)\}', css) if any(re.search(r'\.' + re.escape(c) + r'(?:\s*,|\s*$)', selector) for c in names))
        assert re.search(r'margin:\s*0\.8em\s+2em', letter_css) or all(re.search(r'margin-' + side + r':\s*2em', letter_css) for side in ['left', 'right']), letter_css
    # “取消标注”的行不可重新落入系统提示块。
    for node in nodes:
        if any(c in node.get('class', '').split() for c in ['system-block', 'system-line']):
            assert args.invalidated or '【误判是普通文字】' not in ''.join(node.itertext())
    if args.source:
        restored = ''.join((n.get('data-original') if n.get('data-original') is not None else ''.join(n.itertext())) + {'lf':'\n','cr':'\r','crlf':'\r\n','none':''}[n.get('data-eol')] for n in nodes if n.get('data-source') == 'true')
        assert restored.encode('utf-8') == args.source.read_bytes()
    print(json.dumps({'file': str(args.file.resolve()), 'letter_blocks': len(letter), 'source_restored': bool(args.source), 'roundtrip_namespaces_restored': namespaces_restored, 'sha256': hashlib.sha256(args.file.read_bytes()).hexdigest()}, ensure_ascii=False))


if __name__ == '__main__':
    main()
