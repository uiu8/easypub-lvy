"""V57: compare note containers, retaining popup semantics in candidate fixes.

Pass the EPUB actually staged for Bokai (no unsupported navigation landmarks).
The no-note-control variant removes semantics for diagnosis only, never as a fix.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--bokai', default='D:/software/EasyPub-RustFlutter/artifacts/engines/bokai.exe')
    parser.add_argument('--calibre', default='C:/Program Files/Calibre2/ebook-convert.exe')
    parser.add_argument('--dump', help='Existing kfx-dump executable; optional raw Ion evidence')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    def run(name, command):
        result = subprocess.run(command, capture_output=True, text=True, encoding='utf-8', errors='replace')
        log = result.stdout + result.stderr
        (args.output / (name + '.log')).write_text(log, encoding='utf-8')
        return result.returncode, log

    results = []
    for name in ['aside-footnote', 'div-footnote', 'section-footnote', 'aside-endnote', 'div-endnote', 'no-note-control']:
        target = args.output / (name + '.epub')
        with zipfile.ZipFile(args.source) as zin, zipfile.ZipFile(target, 'w') as zout:
            for info in zin.infolist():
                data = zin.read(info)
                if info.filename.endswith('.xhtml'):
                    text = data.decode('utf-8')
                    if name == 'no-note-control':
                        text = re.sub(r'<aside\b[^>]*>', '', text).replace('</aside>', '').replace(' epub:type="noteref"', '')
                    else:
                        tag, semantic = name.split('-')
                        text = text.replace('<aside ', '<' + tag + ' ').replace('</aside>', '</' + tag + '>')
                        text = text.replace('epub:type="footnote"', 'epub:type="' + semantic + '"')
                    data = text.encode('utf-8')
                zout.writestr(info, data)
        kfx = target.with_suffix('.kfx')
        converted, _ = run(name + '-convert', [args.bokai, 'convert', str(target), str(kfx)])
        checked, _ = run(name + '-validate', [args.bokai, 'validate', 'all', str(target), str(kfx)])
        decoded, _ = run(name + '-readback', [args.bokai, 'convert', str(kfx), str(args.output / (name + '-roundtrip.epub'))])
        read, log = run(name + '-calibre', [args.calibre, str(kfx), str(args.output / (name + '-calibre.epub'))])
        result = {'variant': name, 'bokai': converted, 'validation': checked, 'readback': decoded, 'calibre': read,
                  'errors': [line for line in log.splitlines() if line.startswith('ERROR:')]}
        if args.dump:
            code, ion = run(name + '-ion', [args.dump, str(kfx), '--field', 'raw_storylines'])
            result.update(dump=code, footnotes=ion.count("yj.classification: 'footnote'"),
                          popups=ion.count("yj.display: 'yj.note'"), footers=ion.count("position: 'footer'"),
                          sidebars=ion.count("type: 'sidebar'"))
        results.append(result)
        print(json.dumps(result, ensure_ascii=False), flush=True)
    report = {'source': str(args.source.resolve()), 'source_sha256': hashlib.sha256(args.source.read_bytes()).hexdigest(),
              'tools': {name: {'path': str(Path(path).resolve()), 'sha256': hashlib.sha256(Path(path).read_bytes()).hexdigest()}
                        for name, path in [('bokai', args.bokai), ('calibre', args.calibre)]}, 'variants': results}
    (args.output / 'results.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
