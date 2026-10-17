"""清理 artifacts/ 中的测试临时目录与旧回归日志（V21）。

默认只预览：列出将删除的目录数量与大小，不删除任何东西。加 --apply 才删除。

保留：
- 最近 N 次（默认 20）Flutter 回归（completion-regression-*）与 Rust 测试（rust-tests-*）；
- docs/ 与 tools/ 中引用过的目录（如证据里写的 artifacts/xxx）；
- release、engines 以及所有不是目录的条目；
- 名字不像测试临时目录的目录（测试用 Directory.createTemp 生成“前缀 + 随机十六进制”，
  只认后缀含 a–f 字母的，避免把带日期的目录当成临时目录）。

用法：python tools/clean_artifacts.py [--keep 20] [--apply]
"""
import argparse
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ARTIFACTS = ROOT / "artifacts"
PROTECTED = {"release", "engines"}
FAMILIES = ("completion-regression-", "rust-tests-")
TEMP = re.compile(r"^[a-z0-9][a-z0-9_-]*?-?(?=[0-9a-f]*[a-f])[0-9a-f]{6,8}$")
REFERENCE = re.compile(r"artifacts(?:/|\\\\|\\)+([A-Za-z0-9._-]+)")


def referenced() -> set[str]:
    names = set()
    for base in (ROOT / "docs", ROOT / "tools"):
        for path in base.rglob("*"):
            if path.is_file() and path.suffix in {".md", ".json", ".txt", ".ps1", ".py"}:
                try:
                    names.update(REFERENCE.findall(path.read_text(encoding="utf-8", errors="ignore")))
                except OSError:
                    pass
    return names


def size_of(path: Path) -> int:
    total = 0
    for item in path.rglob("*"):
        try:
            if item.is_file():
                total += item.stat().st_size
        except OSError:
            pass
    return total


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep", type=int, default=20)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    if not ARTIFACTS.is_dir():
        print("artifacts/ 不存在")
        return 0
    refs = referenced()
    entries = sorted(p for p in ARTIFACTS.iterdir() if p.is_dir())
    keep_recent = set()
    for family in FAMILIES:
        runs = sorted((p.name for p in entries if p.name.startswith(family)), reverse=True)
        keep_recent.update(runs[: args.keep])
    plan = []
    for p in entries:
        name = p.name
        if name in PROTECTED or name in refs or name in keep_recent:
            continue
        if name.startswith(FAMILIES) or TEMP.match(name):
            plan.append(p)
    groups: dict[str, list[Path]] = {}
    for p in plan:
        key = next((f for f in FAMILIES if p.name.startswith(f)), "测试临时目录")
        groups.setdefault(key, []).append(p)
    total = 0
    for key, items in sorted(groups.items()):
        size = sum(size_of(p) for p in items)
        total += size
        print(f"{key}: {len(items)} 个目录，{size / 1024 / 1024:.1f} MB")
    print(f"合计将删除 {len(plan)} 个目录，{total / 1024 / 1024:.1f} MB；"
          f"保留最近 {args.keep} 次回归与 {len(refs)} 个被引用的名称。")
    if not args.apply:
        print("（预览：未删除任何内容。确认后加 --apply 执行。）")
        return 0
    failed = 0
    for p in plan:
        try:
            shutil.rmtree(p)
        except OSError as error:
            failed += 1
            print(f"未能删除 {p.name}：{error}", file=sys.stderr)
    print(f"已删除 {len(plan) - failed} 个目录，失败 {failed} 个。")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
