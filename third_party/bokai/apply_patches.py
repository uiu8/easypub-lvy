"""Apply the shipped, exact Bokai compatibility edits (idempotent)."""
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
for edit in json.loads(Path(__file__).with_name("patches.json").read_text(encoding="utf-8")):
    path = root / edit["file"]
    text = path.read_text(encoding="utf-8")
    if text.count(edit["after"]) == 1:
        continue
    if text.count(edit["before"]) != 1:
        raise SystemExit(f"Patch source mismatch: {path}")
    path.write_text(text.replace(edit["before"], edit["after"], 1), encoding="utf-8")
