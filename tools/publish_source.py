# -*- coding: utf-8 -*-
"""把当前提交里的程序源码导出到公开仓库的工作区（只导出、扫描、暂存，不提交不推送）。

用法：python -I -X utf8 tools/publish_source.py <公开仓库的本地克隆目录>

只导出 INCLUDE 里的路径；docs、design、design_preview、contracts、DEVELOPMENT.md 等
与程序运行无关的内容不公开。导出后扫描个人信息和凭据，有命中就失败，不暂存。
"""
from __future__ import annotations

import io
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INCLUDE = [
    ".gitignore", "Cargo.toml", "Cargo.lock", "rust-toolchain.toml", "LICENSE", "README.md",
    "rust", "flutter", "plugins", "third_party", "tools", "samples", "fixtures",
]
# 只输出路径和规则名，不输出命中的值。个人信息拆开写，免得本脚本自己命中。
_USER = b"131" + b"68"
_QQ = b"13168" + b"61954"
FORBIDDEN = {
    "user_dir": re.compile(rb"(?i)users[\\/]+" + _USER + rb"(?![0-9])"),
    "qq_email": re.compile(_QQ),
    "qidian_cookie": re.compile(rb"(_csrfToken|ywguid|ywkey|ywopenid)\s*[=:]\s*(?!QwErTy)[A-Za-z0-9%_\-]{8,}"),
    "github_token": re.compile(rb"gh[pousr]_[A-Za-z0-9]{30,}"),
    "private_key": re.compile(rb"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
}


def git(*args: str, cwd: Path) -> bytes:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True).stdout


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    out = Path(sys.argv[1]).resolve()
    if not (out / ".git").is_dir() or out == ROOT:
        print(f"不是公开仓库的克隆目录：{out}")
        return 2
    head = git("rev-parse", "--short", "HEAD", cwd=ROOT).decode().strip()
    archive = git("archive", "--format=tar", "HEAD", "--", *INCLUDE, cwd=ROOT)
    for entry in out.iterdir():
        if entry.name == ".git":
            continue
        shutil.rmtree(entry) if entry.is_dir() else entry.unlink()
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        tar.extractall(out, filter="data")
    hits = []
    files = [p for p in out.rglob("*") if p.is_file() and ".git" not in p.relative_to(out).parts[:1]]
    for path in files:
        data = path.read_bytes()
        for name, pattern in FORBIDDEN.items():
            if pattern.search(data):
                hits.append(f"{name}\t{path.relative_to(out).as_posix()}")
    if hits:
        print("发现不应公开的内容，未暂存：")
        print("\n".join(hits))
        return 1
    git("add", "-A", cwd=out)
    print(f"已导出提交 {head}：{len(files)} 个文件，扫描无命中，已暂存。")
    print(git("diff", "--cached", "--shortstat", cwd=out).decode().strip() or "（与公开仓库相同，没有变化）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
