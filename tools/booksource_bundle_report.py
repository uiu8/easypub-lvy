"""整理合集校验记录，导出已抽查通过的规则（从插件脱敏存储读取，不下载正文）。

python -I -X utf8 tools/booksource_bundle_report.py 本轮目录 --before 原版目录 --output 新的导出目录
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def rows(run):
    return {row["id"]: row for row in
            (json.loads(line) for line in (run / "results.jsonl").read_text(encoding="utf-8").splitlines())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", type=Path)
    parser.add_argument("--before", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    manifest = read(args.run / "manifest.json")
    summary = read(args.run / "summary.json")
    results = rows(args.run)
    aliases = manifest["aliases"]
    stored = read(args.run / "data" / "sources.json")
    by_id = {s["easypub"]["id"]: s for s in stored}
    args.output.mkdir(parents=True, exist_ok=False)
    groups = {}
    combined = {}
    for origin in manifest["imports"]:
        selected = [s for s in manifest["sources"] if s["file"] == origin]
        passed = [s for s in selected if results.get(aliases.get(s["id"]), {}).get("ok")]
        exported = []
        for item in passed:
            value = {k: v for k, v in by_id[item["id"]].items() if k != "easypub"}
            value["enabled"] = True
            exported.append(value)
            # 插件同文件按 bookSourceUrl 更新；同地址的不同规则保留已通过的最新版本，
            # 同一更新时间再取这轮较快的，避免导入合并文件时后项静默覆盖前项。
            rank = (int(value.get("lastUpdateTime", 0)), -results[aliases[item["id"]]]["ms"])
            key = value["bookSourceUrl"]
            if key not in combined or rank > combined[key][0]:
                combined[key] = (rank, value)
        name = Path(origin).stem + "-正文抽查通过.json"
        target = args.output / name
        write(target, exported)
        measured = [results[aliases[s["id"]]] for s in selected if aliases.get(s["id"]) in results]
        groups[origin] = {
            **summary["groups"][origin],
            "file": name,
            "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
            "failureStages": dict(Counter(r.get("stage", "legacy") for r in measured if not r["ok"])),
            "sampledMoreThanOne": sum(r.get("sampled", 0) > 1 and r["ok"] for r in measured),
            "minAcceptedChars": min((r["chars"] for r in measured if r["ok"]), default=0),
        }
    write(args.output / "两合集-去重-正文抽查通过.json", [value for _, value in combined.values()])
    report = {"pluginSha256": manifest["pluginSha256"], "groups": groups,
              "uniqueTested": len(results), "uniquePassedRules": sum(r["ok"] for r in results.values()),
              "mergedSources": len(combined),
              "unsupportedReasons": dict(Counter(reason for s in manifest["sources"] if not s["supported"]
                                                for reason in s["reasons"])),
              "scope": "默认校验词、搜索第一本、详情、目录、至多三个免费章节；只证明此次抽查，不能保证整本和长期可用。"}
    if args.before:
        previous = rows(args.before)
        common = results.keys() & previous.keys()
        report["comparison"] = {
            "commonRules": len(common),
            "passedBoth": sum(results[i]["ok"] and previous[i]["ok"] for i in common),
            "newPass": sum(results[i]["ok"] and not previous[i]["ok"] for i in common),
            "noLongerPass": sum(not results[i]["ok"] and previous[i]["ok"] for i in common),
            "noLongerPassReasons": dict(Counter(results[i]["error"] for i in common
                                                if previous[i]["ok"] and not results[i]["ok"])),
            "newlyRunnable": len(results.keys() - previous.keys()),
        }
    write(args.output / "测试汇总.json", report)
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    main()
