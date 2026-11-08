"""从上次证据挑选网络失败样本对照路径，不生成书源筛选合集。
同一规则、同一校验词；每种路径使用独立插件目录，保留失败和路线。
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("perf", ROOT / "tools/booksource_perf.py")
perf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(perf)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--exe", type=Path, required=True)
    p.add_argument("--previous", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--qysg", type=Path, required=True)
    a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=False)
    sources = json.loads((a.previous / "data/sources.json").read_text(encoding="utf-8"))
    records = {r["id"]: r for r in map(json.loads, (a.previous / "results.jsonl").read_text(encoding="utf-8").splitlines())}
    selected, hosts = [], set()
    for s in sources:
        host = urlsplit(s["bookSourceUrl"]).hostname
        r = records.get(s.get("easypub", {}).get("id", s["bookSourceUrl"]), {})
        if host not in hosts and r.get("error") == "连接失败" and not s.get("loginUrl"):
            selected.append(s)
            hosts.add(host)
            if len(selected) == 4:
                break
    for host in ["m.b5200.net", "www.shuzhaige.com"]:
        candidates = [s for s in sources if urlsplit(s["bookSourceUrl"]).hostname == host]
        if candidates:
            selected.append(candidates[0])
    qysg = json.loads(a.qysg.read_text(encoding="utf-8-sig"))
    # 一条外链模板、一条内嵌模板：诊断适配层及依赖，不遍历全部重复失效域名。
    selected += [qysg[0], next(s for s in qysg if s["html"].lstrip().startswith("<"))]
    selected = [{k: v for k, v in s.items() if k != "easypub"} for s in selected]
    sample = a.output / "sample.json"
    sample.write_text(json.dumps(selected, ensure_ascii=False), encoding="utf-8")
    result = {"exeSha256": perf.sha(a.exe), "tun": "用户确认关闭", "cases": [
        {"name": s["bookSourceName"], "id": s["bookSourceUrl"]} for s in selected
    ], "runs": {}}
    for mode in ["none", "system"]:
        os.environ["EASYPUB_WEBVIEW_DATA"] = str(a.output.resolve() / mode / "webview")
        with perf.Plugin(a.exe, a.output / mode / "data") as plugin:
            plugin.call("network.proxy.set", {"config": {"mode": mode}})
            plugin.call("sources.import", {"path": str(sample.resolve())})
            events = []
            summary = plugin.call("sources.check", {"key": "我的", "concurrency": 2},
                                  event=lambda _, e: events.append(e))
            checks = [{k: v for k, v in e.items() if k not in ("event", "health")}
                      for e in events if e.get("event") == "check.result"]
            result["runs"][mode] = {"summary": summary, "checks": checks}
            (a.output / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
            print(json.dumps({"mode": mode, **summary}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
