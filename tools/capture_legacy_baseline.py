"""Read the legacy working tree and record a reproducible, local-only reference.

This tool never builds, checks out, or writes into the source directory.
The archive is a reference artifact, not the new application's source tree.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
from datetime import datetime, timezone
import zipfile

SOURCE = Path(r"D:\software\DeepSeek-Harness\workspace\easypub-branch")
ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "docs/evidence/legacy-baseline.json"
ARCHIVE = ROOT / "reference/v1.65.0-working-tree.zip"
IGNORED = {"bin", "obj", ".git", "node_modules", "assets", "test-results", "__pycache__"}
SUFFIXES = {".cs", ".csproj", ".xaml", ".slnx", ".md", ".props", ".targets", ".ps1", ".py", ".json", ".txt", ".xml", ".iss"}


def git(*args: str) -> str:
    environment = dict(os.environ, GIT_OPTIONAL_LOCKS="0")
    return subprocess.check_output(
        ["git", "-c", "core.quotePath=false", "-C", str(SOURCE), *args],
        env=environment,
    ).decode("utf-8").rstrip()


def files() -> list[Path]:
    result = []
    for directory in ("src", "tests", "docs", "tools", "installer"):
        for current, directories, names in os.walk(SOURCE / directory):
            directories[:] = sorted(d for d in directories if d not in IGNORED)
            for name in sorted(names):
                path = Path(current) / name
                if path.suffix.lower() in SUFFIXES:
                    result.append(path)
    result.extend(p for p in SOURCE.iterdir() if p.is_file() and
                  (p.name.startswith(("README", "LICENSE", "Directory.")) or p.suffix == ".slnx"))
    fixture_root = SOURCE / "samples/六卷690章修复验收"
    result.extend(p for p in fixture_root.iterdir() if p.is_file() and p.suffix in SUFFIXES)
    return sorted(set(result))


def rows() -> list[dict]:
    result = []
    for path in files():
        data = path.read_bytes()
        result.append({"path": path.relative_to(SOURCE).as_posix(), "bytes": len(data),
                       "lines": len(data.splitlines()), "sha256": hashlib.sha256(data).hexdigest()})
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    current = rows()
    if args.verify:
        baseline = json.loads(MANIFEST.read_text(encoding="utf-8"))
        passed = current == baseline["files"] and git("status", "--short") == baseline["git_status"]
        evidence = {"verified_at": datetime.now(timezone.utc).isoformat(), "unchanged": passed,
                    "file_count": len(current), "scope": "listed legacy source, tests, docs, tools and synthetic fixtures"}
        (ROOT / "docs/evidence/legacy-unchanged.json").write_text(
            json.dumps(evidence, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(evidence))
        if not passed:
            raise SystemExit("Legacy reference changed; inspect differences, never revert automatically.")
        return
    if MANIFEST.exists() or ARCHIVE.exists():
        raise SystemExit("Reference already exists; use --verify. Never silently replace the baseline.")
    ARCHIVE.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(ARCHIVE, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for row in current:
            archive.write(SOURCE / row["path"], row["path"])
    with zipfile.ZipFile(ARCHIVE) as archive:
        for row in current:
            if hashlib.sha256(archive.read(row["path"])).hexdigest() != row["sha256"]:
                raise SystemExit("Source changed during capture; baseline needs review.")
    manifest = {"captured_at": datetime.now(timezone.utc).isoformat(), "source_root": str(SOURCE),
                "product_version": "1.65.0", "head": git("rev-parse", "HEAD"),
                "git_status": git("status", "--short"), "origin_is_dirty_working_tree": True,
                "archive": ARCHIVE.relative_to(ROOT).as_posix(),
                "archive_sha256": hashlib.sha256(ARCHIVE.read_bytes()).hexdigest(),
                "not_captured": ["outputs", "work", "personal settings", "real-book corpus", "Git history"],
                "files": current}
    MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"file_count": len(current), "archive_bytes": ARCHIVE.stat().st_size,
                      "archive_sha256": manifest["archive_sha256"], "head": manifest["head"]}))


if __name__ == "__main__":
    main()
