"""统计功能对照表中“新版承接”仍为“待核对”的功能 ID（v37 逐项细节设计的批次闸门）。

用法：python tools/check_v37_coverage.py [--require 01,02]
--require 列出的表必须为 0 个待核对，否则退出码为 1。
"""
from pathlib import Path
import argparse
import re
import sys

DOCS = Path(__file__).resolve().parents[1] / "docs/功能对照表"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require", default="")
    args = parser.parse_args()
    required = {x.strip() for x in args.require.split(",") if x.strip()}
    failed = False
    total = done = 0
    for doc in sorted(DOCS.glob("0[1-4]_*.md")):
        rows = re.findall(r"^\|\s*([A-Z][A-Z0-9-]*-\d+)\s*\|.*\|\s*([^|]*?)\s*\|\s*$", doc.read_text(encoding="utf-8-sig"), re.M)
        pending = [i for i, status in rows if status == "待核对"]
        total += len(rows)
        done += len(rows) - len(pending)
        print(f"{doc.name}: {len(rows) - len(pending)}/{len(rows)} 已承接，待核对 {len(pending)}")
        if doc.name[:2] in required and pending:
            failed = True
            print("  未承接：" + ", ".join(pending[:30]) + (" …" if len(pending) > 30 else ""))
    print(f"合计：{done}/{total}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
