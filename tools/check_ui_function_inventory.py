"""Check the maintained UI inventory; --refresh records a manually reviewed baseline."""
from pathlib import Path
from datetime import date
import argparse
import hashlib
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs/功能对照表"
MANIFEST = DOCS / "source_manifest.json"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refresh", action="store_true")
    args = parser.parse_args()
    documents = sorted(DOCS.glob("0[1-4]_*.md"))
    errors = []
    if len(documents) != 4:
        errors.append(f"Expected 4 inventory documents, found {len(documents)}")
    texts = {str(p.relative_to(ROOT)).replace('\\', '/'): p.read_text(encoding="utf-8-sig") for p in documents}
    identifiers = {}
    for name, content in texts.items():
        ids = re.findall(r"^\|\s*([A-Z][A-Z0-9-]*-\d+)\s*\|", content, re.M)
        for identifier in ids:
            if identifier in identifiers:
                errors.append(f"Duplicate ID: {identifier}")
            identifiers[identifier] = name
    if not identifiers:
        errors.append("No stable function IDs found")
    files = set((ROOT / "flutter/lib/frontend_rewrite").rglob("*.dart"))
    files.add(ROOT / "flutter/lib/frontend_rewrite_main.dart")
    files |= set((ROOT / "flutter/lib/desk").rglob("*.dart"))
    for content in texts.values():
        for relative in re.findall(r"flutter/lib/(?:application|infrastructure)/[\w/.-]+\.dart", content):
            cited = ROOT / relative
            if cited.exists():
                files.add(cited)
            else:
                errors.append(f"Missing cited source: {relative}")
    records = []
    for file in sorted(files):
        relative = file.relative_to(ROOT).as_posix()
        owners = [name for name, content in texts.items() if relative in content]
        if not owners:
            errors.append(f"Undocumented source file: {relative}")
        records.append({"file": relative, "sha256": hashlib.sha256(file.read_bytes()).hexdigest(), "inventory": owners})
    result = {"schema": 1, "review_date": date.today().isoformat(), "scope": "Production Flutter frontend, entrypoint and cited Dart services; source coverage is not interaction acceptance", "function_count": len(identifiers), "source_count": len(records), "functions": identifiers, "sources": records}
    if not args.refresh and MANIFEST.exists():
        previous = json.loads(MANIFEST.read_text(encoding="utf-8"))
        old = {r["file"]: r["sha256"] for r in previous["sources"]}
        new = {r["file"]: r["sha256"] for r in records}
        for name in sorted(old.keys() | new.keys()):
            if old.get(name) != new.get(name):
                errors.append(f"Review source drift: {name}")
        if previous["functions"] != identifiers:
            errors.append("Function IDs changed: review inventory and refresh baseline")
    elif not args.refresh:
        errors.append("Missing source baseline; manually review documents before --refresh")
    if errors:
        print("\n".join(errors))
        return 1
    if args.refresh:
        MANIFEST.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Inventory: {len(identifiers)} unique IDs, {len(records)} production files, {len(documents)} documents. " + ("Baseline recorded." if args.refresh else "No source drift."))
    return 0


if __name__ == "__main__":
    sys.exit(main())
