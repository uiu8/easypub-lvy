"""Produce diagnostic overlays without changing the approved reference image.

This command never grants visual acceptance. Matching fixtures, interactions,
font environment and performance gates must be reviewed separately.
"""
import argparse
import hashlib
import json
from pathlib import Path
from PIL import Image, ImageChops, ImageEnhance


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", type=Path)
    parser.add_argument("actual", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--fixture-note", required=True)
    args = parser.parse_args()
    reference = args.reference.resolve(strict=True)
    actual = args.actual.resolve(strict=True)
    destination = args.destination.resolve()
    targets = [destination / name for name in ("overlay.png", "difference.png", "comparison.json")]
    if any(path in (reference, actual) for path in targets):
        raise ValueError("Comparison outputs must not overwrite source images")
    with Image.open(reference) as source, Image.open(actual) as captured:
        if source.size != captured.size:
            raise ValueError(f"Image dimensions differ: {source.size} != {captured.size}; no resizing permitted")
        baseline, rendered = source.convert("RGB"), captured.convert("RGB")
    delta = ImageChops.difference(baseline, rendered)
    channels = delta.split()
    maximum = ImageChops.lighter(ImageChops.lighter(channels[0], channels[1]), channels[2])
    histogram = maximum.histogram()
    pixels = baseline.width * baseline.height
    destination.mkdir(parents=True, exist_ok=True)
    Image.blend(baseline, rendered, .5).save(targets[0])
    ImageEnhance.Brightness(delta).enhance(4).save(targets[1])
    report = {
        "status": "diagnostic_only_not_accepted",
        "reference": str(reference), "actual": str(actual),
        "reference_sha256": hashlib.sha256(reference.read_bytes()).hexdigest(),
        "actual_sha256": hashlib.sha256(actual.read_bytes()).hexdigest(),
        "size": list(baseline.size), "fixture_note": args.fixture_note,
        "exact_changed_fraction": 1 - histogram[0] / pixels,
        "max_channel_difference_above_16_fraction": sum(histogram[17:]) / pixels,
        "difference_display_brightness": 4,
        "resized": False,
        "acceptance": "Not evaluated; metrics are diagnostic and do not establish acceptance",
    }
    targets[2].write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"output": str(destination), "changed_fraction": report["exact_changed_fraction"], "status": report["status"]}))


if __name__ == "__main__":
    main()
