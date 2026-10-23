"""使用隔离目录和假书源测量真实插件 JSON 协议；不访问网络。"""
import argparse
import json
from pathlib import Path
import queue
import statistics
import subprocess
import threading
import time


def measure(executable, root, count):
    data = root / str(count)
    data.mkdir(parents=True, exist_ok=False)
    sources = [{"bookSourceUrl": f"https://fixture-{i}.invalid", "bookSourceName": f"合成书源{i}",
                "searchUrl": "/search?q={{key}}", "ruleSearch": {"bookList": "li", "name": "a@text", "bookUrl": "a@href"},
                "ruleContent": {"content": "#content@html"}} for i in range(count)]
    (data / "sources.json").write_text(json.dumps(sources, ensure_ascii=False), encoding="utf-8")
    process = subprocess.Popen([str(executable), "--data", str(data)], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, encoding="utf-8")
    replies = queue.Queue()
    def read():
        for line in process.stdout:
            replies.put(json.loads(line))
    threading.Thread(target=read, daemon=True).start()
    serial = 0
    def call(method):
        nonlocal serial
        serial += 1
        start = time.perf_counter()
        process.stdin.write(json.dumps({"id": serial, "method": method, "params": {}}) + "\n")
        process.stdin.flush()
        while True:
            response = replies.get(timeout=60)
            if response.get("id") == serial:
                if "error" in response:
                    raise RuntimeError(response["error"])
                return response["result"], (time.perf_counter() - start) * 1000
    try:
        records = {}
        for method in ["sources.list", "sources.groups"]:
            times = []
            for _ in range(9):
                result, elapsed = call(method)
                if method == "sources.list":
                    assert len(result) == count, (count, len(result))
                times.append(elapsed)
            records[method] = {"first_ms": times[0], "warm_ms": times[1:],
                               "median_ms": statistics.median(times[1:]), "p95_ms": max(times[1:])}
        call("exit")
        process.wait(timeout=15)
        return {"count": count, "methods": records}
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugin", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    results = [measure(args.plugin.resolve(), args.out.resolve(), n) for n in (368, 2400)]
    (args.out / "report.json").write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(results, ensure_ascii=False))


if __name__ == "__main__":
    main()
