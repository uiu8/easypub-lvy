# -*- coding: utf-8 -*-
"""编辑台一致性扫描（R0，正式版打磨）。

扫描 flutter/lib/desk 下的生产界面代码，列出各类与编辑台规范不一致、或可能导致卡顿的写法，
输出一份 Markdown 报告。这是给审视报告用的线索清单，不是闸门：命中不等于一定有问题，要人工核对。

用法：python -I -X utf8 tools/scan_desk_consistency.py [--out 报告.md]
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DESK = ROOT / 'flutter' / 'lib' / 'desk'

# 令牌与主题定义处允许直接写颜色、字号。
TOKEN_FILES = {'tokens.dart', 'controls.dart', 'grain.dart', 'fonts.dart'}

CHECKS = [
    ('material-dialog', 'Material AlertDialog（应改用 DeskDialog）',
     re.compile(r'\bAlertDialog\s*\('), None),
    ('popup-menu', 'PopupMenuButton（命令菜单应改用 DeskMenuButton）',
     re.compile(r'\bPopupMenuButton\s*<'), None),
    ('dropdown', 'DropdownButton / DropdownButtonFormField（选择框应改用 DeskChoice）',
     re.compile(r'\bDropdownButton(FormField)?\s*<'), None),
    ('raw-color', '写死的颜色 Color(0x…)（应取 context.desk 令牌）',
     re.compile(r'\bColor\(0x[0-9A-Fa-f]{6,8}\)'), TOKEN_FILES),
    ('material-colors', 'Colors.xxx 具名颜色（透明色除外，应取令牌）',
     re.compile(r'\bColors\.(?!transparent\b)[a-z]\w*'), TOKEN_FILES),
    ('raw-textstyle', 'TextStyle(fontSize: …)（应用 ui()/serif()/mono() 字体助手）',
     re.compile(r'TextStyle\(\s*fontSize\s*:'), TOKEN_FILES),
    ('generic-error', '通用错误句（应给出原因与下一步）',
     re.compile(r"'[^'\n]*(失败，请重试|操作失败|出错了|发生错误|未知错误)[^'\n]*'"), None),
    ('sync-io', '同步文件读写（在 build 或频繁调用的路径上会卡界面）',
     re.compile(r'\.(readAsBytesSync|readAsStringSync|readAsLinesSync|writeAsStringSync|writeAsBytesSync|existsSync|listSync|statSync|lengthSync)\('), None),
    ('glyph-icon', '用文字符号代替图标（▾ ▼ ▸ ✓ ✕ 等，缺字时显示成方框）',
     re.compile(r"'[^'\n]*[▾▼▸▶✓✕✔✖↻][^'\n]*'"), None),
    ('raw-duration', '动画时长写死毫秒（应用 DeskMotion，并尊重“减少动画”）',
     re.compile(r'\b(AnimatedContainer|AnimatedOpacity|AnimatedSize|AnimatedAlign|AnimatedSwitcher|AnimationController)\b[^;]*?duration:\s*const\s+Duration\(milliseconds:', re.S), None),
    ('snackbar', 'SnackBar 提示（核对文案与撤销入口是否统一）',
     re.compile(r'\bSnackBar\s*\('), None),
    ('english-ui', '界面里的英文文案（核对是否应译成中文）',
     re.compile(r"Text\(\s*'[A-Za-z][A-Za-z ]{3,}'"), None),
]


def scan():
    results = {key: [] for key, *_ in CHECKS}
    files = sorted(DESK.rglob('*.dart'))
    for path in files:
        text = path.read_text(encoding='utf-8')
        rel = path.relative_to(ROOT).as_posix()
        for key, _title, pattern, skip in CHECKS:
            if skip and path.name in skip:
                continue
            for m in pattern.finditer(text):
                line = text.count('\n', 0, m.start()) + 1
                snippet = text.splitlines()[line - 1].strip()
                results[key].append((rel, line, snippet[:120]))
    return files, results


def report(files, results):
    out = ['# 编辑台一致性扫描', '',
           f'范围：`flutter/lib/desk`，{len(files)} 个文件。命中只是线索，要人工核对；不是闸门。', '',
           '| 类别 | 命中 | 涉及文件 |', '| --- | --- | --- |']
    for key, title, *_ in CHECKS:
        hits = results[key]
        out.append(f'| {title} | {len(hits)} | {len({h[0] for h in hits})} |')
    for key, title, *_ in CHECKS:
        hits = results[key]
        if not hits:
            continue
        out += ['', f'## {title}（{len(hits)}）', '']
        by_file = {}
        for rel, line, snippet in hits:
            by_file.setdefault(rel, []).append((line, snippet))
        for rel, items in sorted(by_file.items(), key=lambda kv: -len(kv[1])):
            out.append(f'- `{rel}`（{len(items)}）')
            for line, snippet in items[:6]:
                out.append(f'  - {line}：`{snippet.replace("`", "")}`')
            if len(items) > 6:
                out.append(f'  - …另 {len(items) - 6} 处')
    return '\n'.join(out) + '\n'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out')
    args = parser.parse_args()
    files, results = scan()
    text = report(files, results)
    if args.out:
        pathlib.Path(args.out).write_text(text, encoding='utf-8')
        print(f'报告：{args.out}')
    else:
        sys.stdout.write(text)
    for key, title, *_ in CHECKS:
        print(f'{len(results[key]):5d}  {title}', file=sys.stderr)


if __name__ == '__main__':
    main()
