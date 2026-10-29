"""Validate the R0 delivery artifacts without touching the legacy application."""
from __future__ import annotations

import json
from pathlib import Path
import re
from datetime import datetime, timezone
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = ["README.md", "docs/交接文档链/00_总索引_先读这里.md",
    "docs/37_前端深度重构计划_编辑台.md", "docs/39_正式版打磨计划.md",
    "docs/templates/每轮反馈模板.md", "contracts/README.md", "design/tokens.json",
    "docs/research/2026-09-25_Flutter技术与设计调研.md",
    "docs/research/2026-09-25_Rust与桥接调研.md"]
# 2026-10-24 移出仓库的历史文档（备份在本机），旧证据里指向它们的链接只计数，不算失效。
ARCHIVED = ROOT / "docs/交接文档链/archived.json"


def luminance(hex_color: str) -> float:
    rgb = [int(hex_color[i:i+2], 16) / 255 for i in (1, 3, 5)]
    linear = [v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4 for v in rgb]
    return sum(v * w for v, w in zip(linear, (.2126, .7152, .0722)))


def contrast(a: str, b: str) -> float:
    light, dark = sorted((luminance(a), luminance(b)), reverse=True)
    return (light + .05) / (dark + .05)


def main() -> None:
    errors = ["Missing artifact: " + path for path in REQUIRED if not (ROOT / path).is_file()]
    links_checked = 0
    # artifacts/ 是 git 忽略的本机输出（测试日志、截图、发布包），会按需清理，新克隆里也没有；
    # 指向它的链接只计数，不算失效。
    artifact_links = 0
    artifacts_root = (ROOT / "artifacts").resolve()
    archived = {(ROOT / p).resolve() for p in json.loads(ARCHIVED.read_text(encoding="utf-8"))["paths"]}
    archived_links = 0
    docs =[ROOT / "README.md", ROOT / "DEVELOPMENT.md", *sorted((ROOT / "docs").rglob("*.md")), ROOT / "contracts/README.md"]
    for path in docs:
        text = path.read_text(encoding="utf-8", errors="strict")
        if "\ufffd" in text:
            errors.append("Replacement character: " + str(path.relative_to(ROOT)))
        for destination in re.findall(r"\]\(([^)]+)\)", text):
            destination = destination.strip().strip("<>")
            if destination.startswith(("http://", "https://", "#", "mailto:")):
                continue
            destination = unquote(destination.split("#", 1)[0])
            destination = re.sub(r":\d+$", "", destination)
            if not destination:
                continue
            target = Path(destination)
            if not target.is_absolute():
                target = path.parent / target
            if artifacts_root in target.resolve().parents:
                artifact_links += 1
                continue
            if target.resolve() in archived:
                archived_links += 1
                continue
            links_checked += 1
            if not target.exists():
                errors.append(f"Broken local link in {path.relative_to(ROOT)}: {destination}")
    tokens = json.loads((ROOT / "design/tokens.json").read_text(encoding="utf-8"))
    colors = tokens["colors"]
    checks = []
    for foreground in ("ink", "muted_text", "warning", "error", "success"):
        for background in ("canvas", "surface"):
            checks.append({"pair": f"{foreground}/{background}",
                           "ratio": contrast(colors[foreground], colors[background]), "minimum": 4.5})
    checks.append({"pair": "control_border/surface", "ratio": contrast(colors["control_border"], colors["surface"]), "minimum": 3.0})
    for index, stop in enumerate(colors["primary_gradient"]):
        checks.append({"pair": f"primary_text/gradient-{index}", "ratio": contrast(colors["primary_text"], stop), "minimum": 4.5})
    for check in checks:
        if check["ratio"] < check["minimum"]:
            errors.append("Contrast failed: " + check["pair"])
    # 原 docs/05 场景矩阵（S1–S9）随旧计划一起归档，不再在这里校验。
    report = {"checked_at": datetime.now(timezone.utc).isoformat(), "passed": not errors,
              "markdown_files": len(docs), "local_links_checked": links_checked,
              "artifact_links_skipped": artifact_links,
              "archived_links_skipped": archived_links,
              "contrast_math_only": checks, "errors": errors,
              "not_verified": ["Flutter runtime", "Rust build", "visual approval", "performance", "device"]}
    (ROOT / "docs/evidence/document-check.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=True))
    if errors:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
