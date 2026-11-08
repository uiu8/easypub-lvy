"""通过真实插件校验书源合集；独立数据目录，只保存状态、阶段、字数，不保存正文或脚本日志。

python -I -X utf8 tools/booksource_bundle_check.py --exe 插件.exe --output 新目录 合集.json ...
同规则的跨合集重复项只请求一次，结果映射回各合集。默认使用书源自己的校验词。
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import importlib.util
import json
from pathlib import Path
import time

spec = importlib.util.spec_from_file_location("booksource_perf", Path(__file__).with_name("booksource_perf.py"))
perf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(perf)


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")


def fingerprint(source):
    # 排序、健康和显示标签不影响执行；实际请求/规则/脚本保留在指纹中。
    ignored = {"easypub", "enabled", "enabledExplore", "bookSourceName", "bookSourceGroup",
               "bookSourceComment", "customOrder", "weight", "lastUpdateTime", "respondTime"}
    rule = {k: v for k, v in source.items() if k not in ignored}
    return hashlib.sha256(json.dumps(rule, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--concurrency", type=int, default=16)
    parser.add_argument("--network", choices=["none","system"], default="system")
    parser.add_argument("--ids", type=Path, help="可选：仅复验给定 ID 数组")
    parser.add_argument("bundles", type=Path, nargs="+")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    started = time.monotonic()
    with perf.Plugin(args.exe, args.output / "data") as plugin:
        plugin.call("network.proxy.set",{"config":{"mode":args.network,"scope":"all","bypassLocal":True}})
        write(args.output/"network.json",plugin.call("network.proxy.get"))
        imports = {}
        for path in args.bundles:
            imports[str(path.resolve())] = plugin.call("sources.import", {"path": str(path.resolve())})
        sources = plugin.call("sources.list")
        # 插件持久化文件已经去掉静态认证信息；原始下载文件不改动。
        stored = json.loads((args.output / "data" / "sources.json").read_text(encoding="utf-8"))
        canonical, aliases = {}, {}
        wanted = set(json.loads(args.ids.read_text(encoding="utf-8"))) if args.ids else None
        for source in stored:
            sid = source["easypub"]["id"]
            if wanted is not None and sid not in wanted:
                continue
            fp = fingerprint(source)
            aliases[sid] = canonical.setdefault(fp, sid)
        by_id = {s["id"]: s for s in sources}
        ids = [sid for sid in canonical.values() if by_id[sid]["supported"]]
        manifest = {
            "pluginSha256": perf.sha(args.exe),
            "imports": imports,
            "sources": [{k: s.get(k) for k in ("id", "name", "file", "supported", "reasons", "webView", "login", "cause", "unsupported")}
                        for s in sources],
            "aliases": aliases,
            "uniqueRunnable": len(ids),
            "concurrency": args.concurrency,
        }
        write(args.output / "manifest.json", manifest)
        print(json.dumps({"entries": len(sources), "uniqueRunnable": len(ids),
                          "unsupported": sum(not s["supported"] for s in sources)}, ensure_ascii=False), flush=True)
        results = {}
        events = args.output / "results.jsonl"

        def receive(_stamp, event):
            if event.get("event") != "check.result":
                return
            value = {k: v for k, v in event.items() if k not in ("health", "event")}
            results[event["id"]] = value
            with events.open("a", encoding="utf-8") as stream:
                stream.write(json.dumps(value, ensure_ascii=False) + "\n")
            if len(results) % 25 == 0:
                print(json.dumps({"done": len(results), "total": len(ids),
                                  "ok": sum(r["ok"] for r in results.values()),
                                  "seconds": round(time.monotonic() - started)}, ensure_ascii=False), flush=True)

        response = plugin.call("sources.check", {"ids": ids, "concurrency": args.concurrency},
                               timeout=max(120, len(ids) * 45), event=receive)
        groups = {}
        for path in imports:
            selected = [s for s in sources if s["file"] == path]
            mapped = [results[aliases[s["id"]]] for s in selected
                      if s["id"] in aliases and aliases[s["id"]] in results]
            groups[path] = {"imported": len(selected), "unsupported": sum(not s["supported"] for s in selected),
                            "tested": len(mapped), "ok": sum(r["ok"] for r in mapped),
                            "errors": dict(Counter(r["error"] for r in mapped if not r["ok"])),
                            "causes": dict(Counter([r.get("cause") or "unclassified" for r in mapped if not r["ok"]] +
                                                  [s.get("cause") or "unsupported" for s in selected if not s["supported"]]))}
        summary = {"response": response, "seconds": round(time.monotonic() - started, 3),
                   "groups": groups, "uniqueTested": len(results),
                   "uniqueOk": sum(r["ok"] for r in results.values()),
                   "unsupportedRanking": plugin.call("sources.causes")["unsupported"]}
        write(args.output / "summary.json", summary)
        print(json.dumps(summary, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
