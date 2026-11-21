"""Build a machine-readable Kindle screenshot oracle.

The screenshots are the observation source.  This script does not infer a
layout rule from a single case.  It records OCR line boxes, punctuation
locations, page geometry, and the visible Kindle progress result for every
sample, so later rule changes can be compared against the complete corpus.
"""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

import cv2
import numpy as np
from PIL import Image
from rapidocr_onnxruntime import RapidOCR


ROOT = Path(__file__).resolve().parents[1]
SCREENSHOTS = Path(r"D:\software\ziyuanku\我的资源库\Assets\kindle截图用例")
OUTPUT = ROOT / "docs" / "evidence" / "kindle-case-matrix-20261121.json"
REPORT = ROOT / "docs" / "evidence" / "kindle-case-matrix-20261121.md"

CASE_RE = re.compile(r"(?:START|C[O0]\d|P\d{2}|B\d{2}|F\d{2}(?:-\d)?)", re.I)
PUNCTUATION = set("，。！？；：、‘’“”「」『』（）《》【】〔〕〈〉……——,.!?;:()[]{}<>\"'…—-")
EXPECTED_FAMILIES = [
    "START",
    *[f"C{i:02d}" for i in range(1, 5)],
    *[f"P{i:02d}" for i in range(10, 22)],
    *[f"B{i:02d}" for i in range(10, 22)],
    *[f"F{i:02d}" for i in range(5, 16)],
]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def page_rect(image: np.ndarray) -> list[int]:
    height, width = image.shape[:2]
    sample = image[height // 2, width // 2].astype(np.int16)
    distance = np.linalg.norm(image.astype(np.int16) - sample, axis=2)
    mask = (distance < 12).astype(np.uint8)
    count, labels, stats, _ = cv2.connectedComponentsWithStats(mask, 8)
    candidates = []
    for index in range(1, count):
        x, y, w, h, area = stats[index]
        if w > width * 0.45 and h > height * 0.45:
            candidates.append((area, x, y, w, h))
    if candidates:
        _, x, y, w, h = max(candidates)
        return [int(x), int(y), int(w), int(h)]
    return [0, 0, int(width), int(height)]


def group_lines(records: list) -> list[dict]:
    tokens = []
    for record in records or []:
        points, text, confidence = record
        if not text or not points:
            continue
        xs = [float(point[0]) for point in points]
        ys = [float(point[1]) for point in points]
        tokens.append({
            "text": text,
            "confidence": float(confidence),
            "x": min(xs),
            "y": min(ys),
            "right": max(xs),
            "bottom": max(ys),
            "center_y": (min(ys) + max(ys)) / 2,
        })
    tokens.sort(key=lambda token: (token["center_y"], token["x"]))
    lines: list[list[dict]] = []
    for token in tokens:
        if not lines or abs(token["center_y"] - np.mean([item["center_y"] for item in lines[-1]])) > 24:
            lines.append([token])
        else:
            lines[-1].append(token)
    output = []
    for line in lines:
        line.sort(key=lambda token: token["x"])
        text = "".join(token["text"] for token in line)
        x = min(token["x"] for token in line)
        y = min(token["y"] for token in line)
        right = max(token["right"] for token in line)
        bottom = max(token["bottom"] for token in line)
        punctuation = []
        cursor = 0
        for token in line:
            token_width = max(1.0, token["right"] - token["x"])
            length = max(1, len(token["text"]))
            for index, char in enumerate(token["text"]):
                if char in PUNCTUATION:
                    punctuation.append({
                        "char": char,
                        "index": cursor + index,
                        "x": round(token["x"] + token_width * (index + 0.5) / length, 2),
                    })
            cursor += length
        output.append({
            "text": text,
            "bbox": [round(x, 2), round(y, 2), round(right - x, 2), round(bottom - y, 2)],
            "confidence": round(float(np.mean([item["confidence"] for item in line])), 4),
            "punctuation": punctuation,
        })
    return output


def identify(lines: list[dict], filename: str) -> str:
    text = " ".join(line["text"] for line in lines[:3])
    match = CASE_RE.search(text)
    if match:
        return match.group(0).upper().replace("O", "0")
    # A few continuation screenshots do not repeat the heading.  Their order
    # is retained under an explicit unknown id instead of guessing a case.
    return "UNKNOWN"


def progress(lines: list[dict]) -> dict | None:
    text = " ".join(line["text"] for line in lines[-4:])
    position = re.search(r"位置\s*(\d+)", text)
    percent = re.search(r"(\d{1,3})\s*%", text)
    if not position and not percent:
        return None
    return {
        "position": int(position.group(1)) if position else None,
        "percent": int(percent.group(1)) if percent else None,
    }


def main() -> None:
    if not SCREENSHOTS.exists():
        raise SystemExit(f"screenshot directory does not exist: {SCREENSHOTS}")
    ocr = RapidOCR()
    entries = []
    current_case = "UNKNOWN"
    page_index: dict[str, int] = {}
    for path in sorted(SCREENSHOTS.glob("screenshot_*.png")):
        image = np.asarray(Image.open(path).convert("RGB"))
        # OCR at a reduced size.  Kindle screenshots have large whitespace and
        # the reduced image is substantially faster while retaining line and
        # punctuation geometry after the coordinates are scaled back.
        max_side = 900
        scale = min(1.0, max_side / max(image.shape[:2]))
        ocr_image = image if scale == 1 else cv2.resize(
            image, (round(image.shape[1] * scale), round(image.shape[0] * scale)),
            interpolation=cv2.INTER_AREA,
        )
        records, _ = ocr(ocr_image)
        if scale != 1:
            for record in records or []:
                record[0][:] = [[point[0] / scale, point[1] / scale] for point in record[0]]
        lines = group_lines(records)
        detected_case = identify(lines, path.name)
        if detected_case != "UNKNOWN":
            current_case = detected_case
        page_index[current_case] = page_index.get(current_case, 0) + 1
        entries.append({
            "file": path.name,
            "sha256": sha256(path),
            "image_size": [int(image.shape[1]), int(image.shape[0])],
            "page_rect": page_rect(image),
            "case": current_case,
            "case_page": page_index[current_case],
            "progress": progress(lines),
            "lines": lines,
        })
    case_counts: dict[str, int] = {}
    for entry in entries:
        case_counts[entry["case"]] = case_counts.get(entry["case"], 0) + 1
    observed_families = {
        entry["case"].split("-", 1)[0]
        for entry in entries
        if entry["case"] != "UNKNOWN"
    }
    coverage = {
        "expected_families": EXPECTED_FAMILIES,
        "observed_families": sorted(observed_families),
        "missing_families": [
            family for family in EXPECTED_FAMILIES if family not in observed_families
        ],
        "continuation_samples": sum(1 for entry in entries if entry["case_page"] > 1),
        "unknown_samples": sum(1 for entry in entries if entry["case"] == "UNKNOWN"),
    }
    payload = {
        "schema": "kindle-case-matrix/v1",
        "generated_from": str(SCREENSHOTS),
        "generated_at": "2026-11-21",
        "observation_only": True,
        "description": "OCR and image-coordinate oracle. It records observations and does not encode layout rules.",
        "sample_count": len(entries),
        "case_counts": dict(sorted(case_counts.items())),
        "coverage": coverage,
        "samples": entries,
    }
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    lines = [
        "# Kindle 真机截图案例矩阵",
        "",
        "该文件由 `tools/build_kindle_case_matrix.py` 从用户指定的真机截图目录生成。",
        "矩阵记录观察结果，不把任何一个案例直接当作排版规则。",
        "",
        f"- 样本数：{len(entries)}",
        f"- 来源：`{SCREENSHOTS}`",
        "- 每个样本包含 SHA-256、图片尺寸、版心候选矩形、OCR 行框、行文本、标点坐标和 Kindle 进度信息。",
        f"- 覆盖族：{len(coverage['observed_families'])}/{len(EXPECTED_FAMILIES)}；缺失族：{', '.join(coverage['missing_families']) or '无'}。",
        f"- 延续页样本：{coverage['continuation_samples']}；未识别样本：{coverage['unknown_samples']}。",
        "",
        "| 案例 | 页数 | 样本数 |",
        "| --- | ---: | ---: |",
    ]
    for case, count in sorted(case_counts.items()):
        pages = sum(1 for entry in entries if entry["case"] == case)
        lines.append(f"| {case} | {pages} | {count} |")
    lines += ["", f"详细数据见 `{OUTPUT}`。", ""]
    REPORT.write_text("\n".join(lines), encoding="utf-8")
    print(json.dumps({"samples": len(entries), "case_counts": case_counts}, ensure_ascii=False))


if __name__ == "__main__":
    main()
