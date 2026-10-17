"""Independently validate S3 modes or S1 catalog modes from widget receipts."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument('--scenario', choices=['S1', 'S2', 'S3', 'S4', 'S5', 'S6', 'S7', 'S8', 'S9'], default='S3')
parser.add_argument('--evidence-prefix', default='r4-matrix')
parser.add_argument('--modes', nargs='+', choices=['M1', 'M2', 'M3', 'M4'], default=['M1', 'M2', 'M3', 'M4'])
args = parser.parse_args()
scenario = args.scenario
slug = scenario.lower()
modes = args.modes
for mode in modes:
    name = f'r4-matrix-{slug}-widget.json' if mode == 'M4' and scenario in ['S1', 'S3'] else f'r4-matrix-{slug}-{mode.lower()}-widget.json'
    name = name.replace('r4-matrix', args.evidence_prefix, 1)
    data = json.loads((Path('docs/evidence') / name).read_text(encoding='utf-8-sig'))
    assert data['mode'] == mode and data['scenario'] == scenario
    if scenario == 'S4':
        assert data['explicit_duplicate_title_removals'] == 11 and data['project_cleanup_restored']
        assert data['catalog_reconfirmed_after_reopen'] == (mode in ['M2', 'M4'])
        truth = json.loads(Path('samples/章节独立场景/S4/真值清单.json').read_text(encoding='utf-8-sig'))
        selected = [i for i in truth['instances'] if i['id'] in {f'v3-c{n}' for n in range(70, 81)}]
        source_lines = Path(data['source']).read_bytes().splitlines(keepends=True)
        removed = {i['start_line'] + 1 for i in selected}
        assert len(removed) == 11
        for i in removed:
            assert source_lines[i].strip() == source_lines[i-2].strip()
            assert source_lines[i].decode('utf-8').startswith('第')
        exact = b''.join(line for i, line in enumerate(source_lines) if i not in removed)
        assert Path(data['expected_text']).read_bytes() == exact
    if scenario == 'S2':
        assert data['explicit_duplicate_blocks'] == 11 and data['undo_save_reopen_redo']
        assert data['catalog_reconfirmed_after_reopen'] == (mode in ['M2', 'M4'])
        assert Path(data['expected_text']).read_bytes() == Path('samples/章节独立场景/S2/完整原稿.txt').read_bytes()
    if scenario in ['S7', 'S9']:
        assert data['explicit_heading_repairs'] == (6 if scenario == 'S7' else 1)
        assert data['undo_save_reopen_redo']
        assert data['catalog_reconfirmed_after_reopen'] == (mode in ['M2', 'M4'])
        expected = Path(f'samples/章节独立场景/{scenario}/完整原稿.txt').read_bytes()
        if scenario == 'S9':
            expected = expected.replace('第119章 卷5的旅程119'.encode(), '第一百一十九章 卷5的旅程119'.encode(), 1)
        assert Path(data['expected_text']).read_bytes() == expected
    if scenario == 'S8':
        assert data['explicit_numeric_title_conversions'] == 6 and data['project_cleanup_restored']
        assert data['catalog_reconfirmed_after_reopen'] == (mode in ['M2', 'M4'])
        assert Path(data['expected_text']).read_bytes() == Path('samples/章节独立场景/S8/完整原稿.txt').read_bytes()
    if scenario == 'S5':
        assert data['explicit_manual_headings'] == 11 and data['undo_save_reopen_redo']
        assert data['catalog_reconfirmed_after_reopen'] == (mode in ['M2', 'M4'])
    if mode in ['M3', 'M4']:
        assert not data['no_intermediate_txt']
        assert Path(data['output']).read_bytes() == Path(data['expected_text']).read_bytes()
    if scenario == 'S6':
        assert Path(data['expected_text']).read_bytes() == Path(data['source']).read_bytes()
        if mode in ['M3', 'M4']:
            assert data['explicit_unchanged_copy'] and data['project_reopened']
            assert data['old_preview_and_no_opt_in_rejected']
            assert data['catalog_reconfirmed_after_reopen'] == (mode == 'M4')
            if mode == 'M4':
                alignment = data['catalog_alignment']
                assert alignment['matched'] == 679 and not alignment['edits']
                assert [e['title'] for e in alignment['unresolved']] == [f'第{n}章 卷4的旅程{n}' for n in range(50, 61)]
        if mode == 'M2':
            assert data['matched'] == 679 and not data['catalog_edits']
            assert [e['title'] for e in data['unresolved']] == [f'第{n}章 卷4的旅程{n}' for n in range(50, 61)]
            assert all(e['reason'] == 'not_located_no_body_created' for e in data['unresolved'])
    if mode == 'M2':
        assert data['output'] is None and data['receipt'] is None and data['no_intermediate_txt']
    if mode == 'M1':
        assert data['no_catalog'] and data['no_intermediate_txt']
    if mode == 'M3':
        assert data['no_catalog']
        if scenario not in ['S4', 'S6', 'S8']:
            assert data['undo_save_reopen_redo']
        if scenario == 'S1':
            assert data['explicit_manual_volumes'] == 6
        elif scenario == 'S5':
            assert data['explicit_manual_headings'] == 11
        elif scenario == 'S2':
            assert data['explicit_duplicate_blocks'] == 11
        elif scenario in ['S7', 'S9']:
            assert data['explicit_heading_repairs'] == (6 if scenario == 'S7' else 1)
        elif scenario == 'S8':
            assert data['explicit_numeric_title_conversions'] == 6
        elif scenario == 'S6':
            assert data['explicit_unchanged_copy']
        elif scenario == 'S4':
            assert data['explicit_duplicate_title_removals'] == 11
        else:
            assert data['explicit_manual_moves'] == 21
        assert Path(data['output']).read_bytes() == Path(data['expected_text']).read_bytes()
    book = Path(data['products']['AZW3'])
    transaction = book.parent / ('.' + book.name + '.easypub-txn')
    evidence = json.loads((transaction / 'edit-evidence.json').read_text(encoding='utf-8-sig'))
    prefix = f'r4-{slug}-{mode.lower()}' if args.evidence_prefix == 'r4-matrix' else f'{args.evidence_prefix}-{slug}-{mode.lower()}'
    receipt = {'scenario': scenario, 'mode': mode, 'output': str(book),
               'input_epub': str(Path(evidence['conversion_directory']) / 'input.epub'),
               'expected_text': data['expected_text'], 'source': data['source'], 'full_widget_export': True}
    receipt_path = Path('docs/evidence') / f'{prefix}-widget-kindling.json'
    receipt_path.write_text(json.dumps(receipt, ensure_ascii=False, indent=2), encoding='utf-8')
    for profile, path in [('epub', data['products']['EPUB']), ('kindling', receipt['input_epub'])]:
        subprocess.run([sys.executable, 'tools/verify_epub_output.py', str(Path(path)),
                        data['expected_text'], f'docs/evidence/{prefix}-{profile}-independent.json'],
                       check=True, stdout=subprocess.DEVNULL)
        subprocess.run(['java', '-jar', 'D:/software/epubcheck-5.4.0/epubcheck.jar', str(Path(path)),
                        '--json', f'docs/evidence/{prefix}-{profile}-epubcheck.json', '--failonwarnings'],
                       check=True, stdout=subprocess.DEVNULL)
    subprocess.run([sys.executable, 'tools/verify_azw3_roundtrip.py', str(receipt_path),
                    f'artifacts/{slug}-{mode.lower()}-products-{time.time_ns()}',
                    f'docs/evidence/{prefix}-azw3-roundtrip.json'],
                   check=True, stdout=subprocess.DEVNULL)
    print(scenario, mode, 'exact text, mode-specific hierarchy, links and EPUBCheck passed', flush=True)
