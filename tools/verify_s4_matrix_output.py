"""Independent six-volume body/ownership verifier, not production recognition."""
import hashlib
import json
from pathlib import Path
import re
import argparse

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--scenario", choices=["S3", "S4", "MIX"], default="S4")
parser.add_argument("--evidence", help="Explicit receipt filename under docs/evidence")
parser.add_argument("--report", help="Explicit output report filename under docs/evidence")
args = parser.parse_args()
scenario = args.scenario
evidence_name = ("r4-matrix-mix-composition.json" if scenario == "MIX"
                 else f"r4-matrix-{scenario.lower()}-widget.json")
if args.evidence:
    evidence_name = args.evidence
evidence = json.loads((ROOT / "docs/evidence" / evidence_name).read_text(encoding="utf-8"))
fixture_dir = (ROOT / "samples/六卷690章修复验收" if scenario == "MIX"
               else ROOT / "samples/章节独立场景" / scenario)
truth = json.loads((fixture_dir / "真值清单.json").read_text(encoding="utf-8"))
for name, expected_hash in truth["hashes"].items():
    assert hashlib.sha256((fixture_dir / name).read_bytes()).hexdigest() == expected_hash
chapters = {chapter["id"]: chapter for chapter in truth["chapters"]}
lines = Path(evidence["output"]).read_text(encoding="utf-8").splitlines()
found, volume, heading = [], None, None
seen_volumes, seen_titles = [], []
for i, line in enumerate(lines):
    if match := re.fullmatch(r"第(\d+)卷 旅程\1", line):
        volume = int(match[1])
        seen_volumes.append(volume)
    if re.fullmatch(r"第\d+章 卷\d+的旅程\d+", line):
        heading = line
        seen_titles.append(line)
    if match := re.fullmatch(r"这一天，第(\d+)条旅途的第(\d+)段故事在晨光中展开。", line):
        identity = f"v{match[1]}-c{match[2]}"
        chapter = chapters[identity]
        body = "\n".join(lines[i:i + 3])
        assert hashlib.sha256(body.encode("utf-8")).hexdigest() == chapter["body_sha256"], identity
        assert heading == chapter["title"], (identity, "wrong heading", heading)
        assert volume == chapter["volume"], (identity, "wrong volume", volume)
        found.append(identity)
present = [chapter for chapter in truth["chapters"] if not chapter["missing_body"]]
assert found == [chapter["id"] for chapter in present]
assert seen_titles == [chapter["title"] for chapter in present]
assert seen_volumes == list(range(1, 7))
assert len(found) == len(set(found)) == (679 if scenario == "MIX" else 690)
report = {
    "passed_partial": True,
    "scenario": scenario, "mode": evidence.get("mode", "explicit manual composition"),
    "unique_bodies": len(set(found)), "body_instances": len(found),
    "body_hashes_order_and_ownership": f"matched all {len(present)} present independent truth records",
    "missing_bodies": len(truth["chapters"]) - len(present),
    "output_sha256": hashlib.sha256(Path(evidence["output"]).read_bytes()).hexdigest(),
    "output": evidence["output"],
    "not_verified": evidence["not_verified"],
}
(ROOT / "docs/evidence" / (args.report or f"r4-matrix-{scenario.lower()}-independent.json")).write_text(
    json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(report, ensure_ascii=True))
