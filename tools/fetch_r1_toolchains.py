"""Fetch the R1 Windows toolchain from publisher endpoints into D:/software.

Does not execute installers or change PATH. Existing downloads are reused only
after checking the publisher digest, where one is supplied.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TOOLS = Path("D:/software/EasyPub-Toolchains")
DOWNLOADS = TOOLS / "downloads"


def fetch(url: str, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        print(f"Already present: {path}", flush=True)
        return
    request = urllib.request.Request(url, headers={"User-Agent": "EasyPub-R1-toolchain"})
    print(f"Downloading {url}", flush=True)
    with urllib.request.urlopen(request, timeout=60) as response, path.with_suffix(path.suffix + ".partial").open("wb") as out:
        while block := response.read(4 * 1024 * 1024):
            out.write(block)
    path.with_suffix(path.suffix + ".partial").replace(path)


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main() -> None:
    artifacts = [
        ("flutter", "https://storage.googleapis.com/flutter_infra_release/flutter/releases/stable/windows/flutter_windows_3.47.3-stable.zip", "flutter_windows_3.47.3-stable.zip"),
        ("frb", "https://github.com/fzyzcjy/flutter_rust_bridge/releases/download/v2.13.0/flutter_rust_bridge_codegen-x86_64-pc-windows-msvc-v2.13.0.zip", "flutter_rust_bridge_codegen-x86_64-pc-windows-msvc-v2.13.0.zip"),
        ("vs_buildtools", "https://aka.ms/vs/17/release/vs_buildtools.exe", "vs_buildtools.exe"),
    ]
    report = []
    for name, url, filename in artifacts:
        try:
            path = DOWNLOADS / filename
            fetch(url, path)
            actual = digest(path)
            row = {"name": name, "url": url, "path": str(path), "sha256": actual, "bytes": path.stat().st_size}
            if name == "frb":
                checksum = path.with_suffix(path.suffix + ".sha256")
                fetch(url + ".sha256", checksum)
                expected = checksum.read_text().split()[0].lower()
                if actual != expected:
                    raise ValueError("FRB publisher checksum mismatch")
                row["publisher_sha256_verified"] = True
            report.append(row)
            print(json.dumps(row), flush=True)
        except Exception as exc:
            row = {"name": name, "url": url, "error": str(exc)}
            report.append(row)
            print(json.dumps(row), flush=True)
    (ROOT / "docs/evidence/r1-toolchain-downloads.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if any("error" in row for row in report):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
