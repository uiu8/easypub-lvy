"""Validate the R0 delivery artifacts without touching the legacy application."""
from __future__ import annotations

import json
from pathlib import Path
import re
from datetime import datetime, timezone
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = ["README.md", *[f"docs/{name}.md" for name in (
    "01_整体开发方案", "02_技术选型与验证闸门", "03_前端体验与设计规范",
    "04_后端架构与数据契约", "05_迁移与验收矩阵", "06_实施记录")],
    "docs/templates/每轮反馈模板.md", "contracts/README.md", "design/tokens.json",
    "docs/research/2026-09-25_Flutter技术与设计调研.md",
    "docs/research/2026-09-25_Rust与桥接调研.md"]


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
    docs = [ROOT / "README.md", ROOT / "DEVELOPMENT.md", *sorted((ROOT / "docs").rglob("*.md")), ROOT / "contracts/README.md"]
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
    matrix = (ROOT / "docs/05_迁移与验收矩阵.md").read_text(encoding="utf-8")
    scenarios = re.findall(r"^\| S[1-9] .*", matrix, re.M)
    # R0 起矩阵为 9 个场景 × 4 个样本（M1–M4）。实施后单元格从“待实施”改写为实际进度，
    # 因此这里校验结构与状态词，而不再要求全部为“待实施”。
    statuses = ("待实施", "部分", "通过", "完成", "未通过", "阻塞")
    cells = 0
    status_counts = {}
    for row in scenarios:
        values = [c.strip() for c in row.strip().strip("|").split("|")][2:]
        if len(values) != 4 or not all(v.startswith(statuses) for v in values):
            errors.append("Scenario row malformed: " + row[:24])
        for v in values:
            key = next((x for x in statuses if v.startswith(x)), "其他")
            status_counts[key] = status_counts.get(key, 0) + 1
        cells += sum(v.startswith("待实施") for v in values)
    if len(scenarios) != 9:
        errors.append("Scenario matrix is not nine rows")
    report = {"checked_at": datetime.now(timezone.utc).isoformat(), "passed": not errors,
              "markdown_files": len(docs), "local_links_checked": links_checked,
              "scenarios": len(scenarios), "pending_matrix_cells": cells,
              "matrix_status_counts": status_counts,
              "contrast_math_only": checks, "errors": errors,
              "not_verified": ["Flutter runtime", "Rust build", "visual approval", "performance", "device"]}
    (ROOT / "docs/evidence/document-check.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=True))
    if errors:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
