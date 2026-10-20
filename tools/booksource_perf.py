"""V88/V89 插件级联网对照，以及只操作副本的离线重建验收。

例：python -I -X utf8 tools/booksource_perf.py --mode all
输出为逐行 JSON 统计，不记录正文、Cookie、脚本日志或请求头。
每次用独立数据和下载目录；下载固定同源同书同目录前 120 章，交替两轮。
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import shutil
import statistics
import subprocess
import threading
import time
import urllib.request
from html.parser import HTMLParser

ROOT = Path(__file__).resolve().parents[1]


class Plugin:
    def __init__(self, exe, data):
        data.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ, EASYPUB_WEBVIEW_NONINTERACTIVE="1")
        self.p = subprocess.Popen([str(exe), "--data", str(data)], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                  text=True, encoding="utf-8", env=env,
                                  creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        self.lines = queue.Queue()
        self.serial = 0
        self.events = []
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.p.stdout:
            try:
                self.lines.put((time.monotonic(), json.loads(line)))
            except json.JSONDecodeError:
                pass

    def request(self, method, params):
        self.serial += 1
        self.p.stdin.write(json.dumps({"id": self.serial, "method": method, "params": params}, ensure_ascii=False) + "\n")
        self.p.stdin.flush()
        return self.serial

    def call(self, method, params=None, timeout=420, event=None):
        serial = self.request(method, params or {})
        end = time.monotonic() + timeout
        while True:
            stamp, reply = self.lines.get(timeout=max(.01, end - time.monotonic()))
            if reply.get("id") == serial:
                if "error" in reply:
                    raise RuntimeError(reply["error"])
                return reply.get("result")
            if "event" in reply:
                if event:
                    event(stamp, reply)
                else:
                    self.events.append((stamp, reply))

    def close(self):
        if self.p.poll() is None:
            try:
                self.call("exit", timeout=3)
                self.p.wait(timeout=5)
            except (queue.Empty, BrokenPipeError, subprocess.TimeoutExpired):
                self.p.terminate()
                self.p.wait(timeout=10)
        self.p.stdin.close()
        self.p.stdout.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def manifest(folder):
    return {p.relative_to(folder).as_posix(): sha(p) for p in sorted(folder.rglob("*")) if p.is_file()}


def emit(args, value):
    text = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    print(text, flush=True)
    with args.output.open("a", encoding="utf-8") as f:
        f.write(text + "\n")


def search_measure(args, exe, version, run, quick=False, defaults=False):
    with Plugin(exe, run / "data") as p:
        p.call("sources.import", {"path": str(args.sources)})
        sources = p.call("sources.list")
        enabled = [s for s in sources if s["enabled"]]
        pinned_ids = []
        if version == "V89":
            pinned_ids = [s["id"] for s in sources if args.download_source in s["name"]][:1]
            if pinned_ids:
                p.call("sources.pin", {"ids": pinned_ids})
        first_pinned = None
        begin = time.monotonic()
        first_result = first_found = None
        marks = {}

        def on_event(stamp, item):
            nonlocal first_result, first_found, first_pinned
            elapsed = stamp - begin
            if item["event"] == "search.result" and item.get("items") and item.get("sourceId") in pinned_ids and first_pinned is None:
                first_pinned = elapsed
            if item["event"] == "search.result" and item.get("items") and first_result is None:
                first_result = elapsed
            if item["event"] == "search.progress":
                if item.get("found", 0) and first_found is None:
                    first_found = elapsed
                for percent in [25, 50, 75, 90, 100]:
                    if item.get("done", 0) * 100 >= item.get("total", len(enabled)) * percent:
                        marks.setdefault(percent, round(elapsed, 3))

        result = p.call("search", {"key": args.keyword, "searchId": "perf", "stream": True,
                                  "quick": quick, "limit": 60, "concurrency": 8 if version == "V87" else 24,
                                  "includeWebView": False, "skipUnhealthy": defaults or quick},
                        event=on_event)
        elapsed = time.monotonic() - begin
        summary = {k: v for k, v in result.items() if k != "results"}
        emit(args, {"kind": "search", "version": version, "round": run.name,
                    "mode": "quick60" if quick else "default-cold" if defaults else "full-cold", "enabled": len(enabled),
                    "seconds": round(elapsed, 3), "firstVisible": round(first_result if first_result is not None else elapsed, 3),
                    "firstFound": round(first_found, 3) if first_found is not None else None,
                    "firstPinned": round(first_pinned, 3) if first_pinned is not None else None,
                    "progressPercentSeconds": marks, "summary": summary})
        return result


def ping_measure(args, run):
    with Plugin(args.candidate, run / "data") as p:
        p.call("sources.import", {"path": str(args.sources)})
        begin = time.monotonic()
        times, errors = [], Counter()

        def on_event(stamp, item):
            if item["event"] == "ping.result":
                times.append(stamp - begin)
                if not item.get("ok"):
                    errors[item.get("error", "未知")] += 1

        result = p.call("sources.ping", event=on_event)
        emit(args, {"kind": "ping", "seconds": round(time.monotonic() - begin, 3),
                    "firstVisible": round(times[0], 3) if times else None,
                    "events": len(times), "summary": result, "failureKinds": dict(errors)})


def diagnose_measure(args, run):
    """只统计 b5200 正文容器，不落地 HTML、正文或请求头。"""
    _, _, toc = common_book(args, run)

    class Content(HTMLParser):
        def __init__(self):
            super().__init__()
            self.depth = self.script = 0
            self.parts = []

        def handle_starttag(self, tag, attrs):
            if tag in ("script", "style"):
                self.script += 1
            if tag == "div":
                if self.depth:
                    self.depth += 1
                elif dict(attrs).get("id") == "content":
                    self.depth = 1

        def handle_endtag(self, tag):
            if tag in ("script", "style") and self.script:
                self.script -= 1
            if tag == "div" and self.depth:
                self.depth -= 1

        def handle_data(self, data):
            if self.depth and not self.script:
                self.parts.append(data)

    def probe(group, chapter):
        begin = time.monotonic()
        try:
            request = urllib.request.Request(toc[chapter - 1]["url"], headers={
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36"})
            with urllib.request.urlopen(request, timeout=20) as response:
                raw = response.read(8 * 1024 * 1024)
                try:
                    html = raw.decode("utf-8")
                except UnicodeDecodeError:
                    html = raw.decode("gb18030", errors="replace")
                parser = Content()
                parser.feed(html)
                content = "".join("".join(parser.parts).split())
                emit(args, {"kind": "diagnose", "group": group, "chapter": chapter,
                            "status": response.status, "chars": len(content),
                            "hash8": hashlib.sha256(content.encode()).hexdigest()[:8],
                            "seconds": round(time.monotonic() - begin, 3),
                            "throttlePhrase": any(x in content for x in
                                ("访问太频繁", "请稍后再试", "操作过快", "频率过高", "稍后刷新", "30秒后")),
                            "responseBytes": len(raw)})
        except Exception as error:
            emit(args, {"kind": "diagnose", "group": group, "chapter": chapter,
                        "errorType": type(error).__name__, "seconds": round(time.monotonic() - begin, 3)})

    for chapter in range(80, 91):
        probe("sequential", chapter)
    for remaining in (120, 90, 60, 30):
        emit(args, {"kind": "diagnose-idle", "remainingSeconds": remaining})
        time.sleep(30)
    probe("after-idle-120s", 84)
    for chapter in range(84, 91):
        time.sleep(3)
        probe("interval-3s", chapter)


def common_book(args, run):
    with Plugin(args.candidate, run / "prepare") as p:
        p.call("sources.import", {"path": str(args.sources)})
        sources = p.call("sources.list")
        src = next(s for s in sources if (s["id"] == args.source_id if args.source_id else args.download_source in s["name"]))
        found = p.call("search", {"key": args.keyword, "sourceIds": [src["id"]], "skipUnhealthy": False})
        matches = found.get("results", [])
        match = next((b for b in matches if b["name"] == args.keyword and
                      (not args.book_url or any(s["book"]["bookUrl"] == args.book_url for s in b["sources"]))), None)
        if not match:
            raise RuntimeError("对照书源没有检索到指定书籍")
        book = p.call("book.info", {"sourceId": src["id"], "book": match["sources"][0]["book"]})
        toc = p.call("book.toc", {"sourceId": src["id"], "book": book})
        emit(args, {"kind": "download-plan", "source": src["name"], "sourceId":src["id"],"book": book["name"], "author":book["author"],
                    "bookUrlHash":hashlib.sha256(book["bookUrl"].encode()).hexdigest(),
                    "tocCount": len(toc), "from": 1, "to": args.chapters, "alternates": False})
        return src, book, toc


def download_measure(args, exe, version, run, src, book, toc, alternates=None, extra_options=None):
    if args.settle_seconds:
        emit(args, {"kind": "benchmark-idle", "version": version, "round": run.name,
                    "seconds": args.settle_seconds})
        time.sleep(args.settle_seconds)
    with Plugin(exe, run / "data") as p:
        p.call("sources.import", {"path": str(args.sources)})
        start = time.monotonic()
        threads = 4 if version == "V87" else 16
        options = {"folder": str(run / "downloads"), "threads": threads, "from": 1, "to": args.chapters}
        options.update(extra_options or {})
        task = p.call("download.start", {"sourceId": src["id"], "book": book, "toc": toc,
                                        "alternates": alternates or [], "options": options})["taskId"]
        latencies, concurrencies = [], []
        throttled, retrying = False, 0
        result = None
        source_count = 1
        hosts = {}
        deadline = start + args.download_timeout
        while result is None:
            if p.events:
                stamp, item = p.events.pop(0)
            else:
                stamp, item = p.lines.get(timeout=max(.01, deadline - time.monotonic()))
            if item.get("taskId") != task:
                continue
            if item.get("event") == "download.progress":
                progress = item.get("progress", {})
                source_count = max(source_count, progress.get("sourceCount", 1))
                for host in progress.get("hosts", []):
                    hosts[host["host"]] = host
                if progress.get("chapterMs"):
                    latencies.append(progress["chapterMs"])
                if progress.get("concurrency"):
                    concurrencies.append(progress["concurrency"])
                throttled |= bool(progress.get("throttled"))
                retrying = max(retrying, progress.get("retrying", 0))
            if item.get("event") == "download.done":
                if item.get("error"):
                    raise RuntimeError(item["error"])
                result = item["result"]["outcome"]
        elapsed = time.monotonic() - start
        count, failed = result["chapters"], len(result.get("failures", []))
        emit(args, {"kind": "download", "version": version, "round": run.name, "threads": threads,
                    "settleSeconds":args.settle_seconds,
                    "chapters": count, "success": count - failed, "failures": failed, "fromCache": result["fromCache"],
                    "seconds": round(elapsed, 3), "chaptersPerSecond": round((count - failed) / elapsed, 3),
                    "secondsPerSuccess": round(elapsed / max(1, count - failed), 3),
                    "chapterMsMedian": statistics.median(latencies) if latencies else None,
                    "chapterMsP90": sorted(latencies)[min(len(latencies)-1, int(len(latencies)*.9))] if latencies else None,
                    "throttled": throttled, "maxRetryQueue": retrying,
                    "concurrencyMin": min(concurrencies) if concurrencies else None,
                    "concurrencyMax": max(concurrencies) if concurrencies else None,
                    "failureKinds": dict(Counter(f["reason"] for f in result.get("failures", []))),
                    "quality": result.get("quality"), "sourceCount": source_count,
                    "hosts": list(hosts.values()), "multiSource": options.get("multiSource", False)})
        return result


def recovery_measure(args, run):
    """在已有失败运行的缓存副本上验证换源；不把这次有缓存的数据当吞吐对照。"""
    previous = args.previous
    if previous is None or args.health_data is None:
        raise ValueError("recovery 需要 --previous 下载轮次目录和 --health-data 搜索数据目录")
    params = json.loads((previous / "data/tasks.json").read_text(encoding="utf-8"))["tasks"][0]["params"]
    book, toc = params["book"], params["toc"]
    probe_data = run / "probe"
    probe_data.mkdir(parents=True)
    shutil.copy2(args.health_data / "sources.json", probe_data / "sources.json")

    def title_key(text):
        return re.sub(r"\s", "", re.sub(r"^第[^章回节]+[章回节]", "", text)).strip()

    expected = [title_key(c["title"]) for c in toc if not c.get("isVolume")][:12]
    alternates, checked = [], []
    with Plugin(args.candidate, probe_data) as p:
        sources = p.call("sources.list")
        primary = next(s for s in sources if s["id"] == params["sourceId"])
        healthy = [s for s in sources if s["enabled"] and s["id"] != primary["id"]
                   and s.get("health", {}).get("lastOk") and not s.get("webView")]
        healthy.sort(key=lambda s: sum(s["health"]["ms"]) / max(1, len(s["health"]["ms"])))
        found = p.call("search", {"key": book["name"], "sourceIds": [s["id"] for s in healthy[:16]],
                                  "skipUnhealthy": False, "filterTitle": True})
        candidates = [s for b in found.get("results", []) if b["name"] == book["name"] for s in b["sources"]]
        candidates.sort(key=lambda s: s.get("ms", 100000))
        for candidate in candidates[:6]:
            try:
                info = p.call("book.info", {"sourceId": candidate["sourceId"], "book": candidate["book"]})
                chapters = p.call("book.toc", {"sourceId": candidate["sourceId"], "book": info})
                names = [title_key(c["title"]) for c in chapters if not c.get("isVolume")][:50]
                positions = [names.index(name) for name in expected if name and names.count(name) == 1]
                matches = len(positions) if positions == sorted(positions) else 0
                accepted = len(expected) == 12 and matches >= 10
                checked.append({"source": candidate["sourceName"], "author": info["author"],
                                "tocCount": len(chapters), "matchedFirst12": matches, "accepted": accepted})
                if accepted:
                    alternates.append({"sourceId": candidate["sourceId"], "book": info})
            except RuntimeError:
                checked.append({"source": candidate["sourceName"], "error": "详情或目录未取得"})
            if len(alternates) >= 2:
                break
    emit(args, {"kind": "recovery-plan", "previous": str(previous), "candidates": checked,
                "alternates": len(alternates), "priorPrimaryRetries": params.get("options", {}).get("retries", 3), "additionalPrimaryRetries": 0,
                "scope": "沿用已补抓三轮的缓存副本；先再试缺章一次，再按目录前12章核对过的候选换源，不用于吞吐对照"})
    if not alternates:
        return
    destination = run / "recovery"
    shutil.copytree(previous / "downloads/.easypub-cache", destination / "downloads/.easypub-cache")
    download_measure(args, args.v88, "V88", destination, primary, book, toc, alternates, {"retries": 0})


def rebuild_measure(args, run):
    library = Path(os.environ["LOCALAPPDATA"]) / "EasyPub-RustFlutter/plugin-data/booksource/library.json"
    records = json.loads(library.read_text(encoding="utf-8-sig"))
    record = next(r for r in records if "电诈风云" in r["book"]["name"])
    original = Path(record["path"])
    key = hashlib.sha256((record["book"]["origin"] + "\n" + record["book"]["bookUrl"]).encode()).hexdigest()[:16]
    oldcache = Path(record["options"]["folder"]) / ".easypub-cache" / key
    before_txt, before_cache = sha(original), manifest(oldcache)
    folder = run / "copy"
    folder.mkdir(parents=True)
    copied = folder / original.name
    shutil.copy2(original, copied)
    shutil.copytree(oldcache, folder / ".easypub-cache" / key)
    record["path"], record["options"]["folder"] = str(copied), str(folder)
    data = run / "data"
    data.mkdir()
    (data / "library.json").write_text(json.dumps([record], ensure_ascii=False), encoding="utf-8")
    checker = ROOT / "target/release/examples/booksource_structure.exe"

    def check(path):
        r = subprocess.run([str(checker), str(path)], capture_output=True, text=True, encoding="utf-8", check=True)
        return json.loads(r.stdout)

    before = check(copied)
    with Plugin(args.candidate, data) as p:
        begin = time.monotonic()
        result = p.call("library.rebuild", {"key": record["key"]})
        elapsed = time.monotonic() - begin
    after = check(copied)
    unchanged = before_txt == sha(original) and before_cache == manifest(oldcache)
    backup_exact = sha(Path(result["backup"])) == before_txt
    emit(args, {"kind": "rebuild", "before": before, "after": after, "quality": result["quality"],
                "seconds": round(elapsed, 3),
                "copy": str(copied), "originalSha256": before_txt, "cacheFiles": len(before_cache),
                "originalsUnchanged": unchanged, "backupEqualsOriginal": backup_exact})
    assert unchanged and backup_exact


def multi_measure(args, run):
    """选源阶段不测下载速度；复用下载器对齐，再做冷缓存对照。"""
    if args.plan:
        plan = json.loads(args.plan.read_text(encoding="utf-8"))
    else:
        with Plugin(args.candidate, run / "plan-data") as p:
            p.call("sources.import", {"path":str(args.sources)})
            if args.catalogs:
                checked=json.loads(args.catalogs.read_text(encoding="utf-8"))
            else:
                sources = {s["id"]:s for s in p.call("sources.list")}
                found = p.call("search", {"key":args.keyword,"includeWebView":False,"skipUnhealthy":True})
                candidates = [s for b in found.get("results",[]) if b["name"]==args.keyword for s in b["sources"]]
                candidates.sort(key=lambda s:s.get("ms",999999))
                (run/"search-candidates.json").write_text(json.dumps(candidates,ensure_ascii=False),encoding="utf-8")
                checked=[]
                for item in candidates[:24]:
                    try:
                        b=p.call("book.info",{"sourceId":item["sourceId"],"book":item["book"]},timeout=50)
                        chapters=p.call("book.toc",{"sourceId":item["sourceId"],"book":b},timeout=80)
                        if len(chapters)>=args.chapters:
                            checked.append({"source":sources[item["sourceId"]],"book":b,"toc":chapters})
                            emit(args,{"kind":"multi-candidate","source":sources[item["sourceId"]]["name"],"author":b["author"],"tocCount":len(chapters)})
                    except (RuntimeError, queue.Empty):
                        emit(args,{"kind":"multi-candidate","source":item["sourceName"],"error":"详情或目录未取得"})
            (run/"catalog-candidates.json").write_text(json.dumps(checked,ensure_ascii=False),encoding="utf-8")
            plan=None
            for primary in checked:
                equivalents=[]
                for candidate in checked:
                    if candidate is primary or candidate["book"]["author"]!=primary["book"]["author"]:
                        continue
                    check=p.call("download.diagnose",{"toc":primary["toc"],"otherToc":candidate["toc"]})["alignment"]
                    emit(args,{"kind":"multi-alignment","primary":primary["source"]["name"],
                               "other":candidate["source"]["name"],**check})
                    if check["equivalent"] and check["independentSites"]:
                        equivalents.append(candidate)
                if equivalents:
                    plan={"primary":primary,"alternates":equivalents[:2]}
                    break
            if plan is None:
                emit(args,{"kind":"multi-unavailable","reason":"没有找到同名同作者且目录满足 2% / 抽样95% 的独立站点","checked":len(checked)})
                return
        (run/"multi-plan.json").write_text(json.dumps(plan,ensure_ascii=False),encoding="utf-8")
    primary=plan["primary"]
    emit(args,{"kind":"multi-plan","source":primary["source"]["name"],"book":primary["book"]["name"],
               "tocCount":len(primary["toc"]),"alternates":[c["source"]["name"] for c in plan["alternates"]],
               "plan":str(run/"multi-plan.json" if not args.plan else args.plan)})
    if args.mode=="plan":
        return
    alts=[{"sourceId":c["source"]["id"],"book":c["book"],"toc":c["toc"]} for c in plan["alternates"]]
    for i in range(args.rounds):
        download_measure(args,args.v88,"V88",run/f"multi-{i+1}-V88",primary["source"],primary["book"],primary["toc"],extra_options={"multiSource":False})
        download_measure(args,args.v89,"V89",run/f"multi-{i+1}-V89",primary["source"],primary["book"],primary["toc"],alts,{"multiSource":True,"maxAlternates":2})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["all", "search", "download", "rebuild", "health", "recovery", "diagnose", "multi", "plan"], default="all")
    parser.add_argument("--v87", type=Path, default=None)
    parser.add_argument("--v88", type=Path, default=ROOT / "artifacts/v89-baseline/v88.exe")
    parser.add_argument("--v89", type=Path, default=ROOT / "target/release/easypub_plugin_booksource.exe")
    parser.add_argument("--search-rounds", type=int, default=3)
    parser.add_argument("--plan", type=Path)
    parser.add_argument("--catalogs", type=Path, help="复用选源阶段取得的目录；正文缓存仍为空")
    parser.add_argument("--sources", type=Path, default=Path.home() / "Downloads/shareBookSource.json")
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts/v89-perf.jsonl")
    parser.add_argument("--keyword", default="剑来")
    parser.add_argument("--download-source", default="b5200")
    parser.add_argument("--source-id", help="固定确切书源 ID，防止同名规则混入")
    parser.add_argument("--book-url", help="固定确切书籍地址，避免同名不同作者候选变化")
    parser.add_argument("--chapters", type=int, default=120)
    parser.add_argument("--rounds", type=int, default=2)
    parser.add_argument("--download-timeout", type=int, default=1500)
    parser.add_argument("--settle-seconds", type=int, default=0, help="每次下载测量前统一空闲，减少上一轮站点限流残留")
    parser.add_argument("--previous", type=Path, help="recovery：已有下载轮次目录（只复制其缓存）")
    parser.add_argument("--health-data", type=Path, help="recovery：已有搜索数据目录（只复制 sources.json）")
    args = parser.parse_args()
    args.candidate = args.v88 if args.v87 else args.v89
    versions = [("V87", args.v87), ("V88", args.v88)] if args.v87 else [("V88", args.v88), ("V89", args.v89)]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    run = ROOT / "artifacts" / ("v89-perf-" + time.strftime("%Y%m%d-%H%M%S"))
    run.mkdir()
    emit(args, {"kind": "run", "mode": args.mode, "path": str(run), "v87Sha256": sha(args.v87) if args.v87 else None, "v89Sha256": sha(args.v89),
                "v88Sha256": sha(args.v88), "sourcesSha256": sha(args.sources)})
    if args.mode in ("all", "rebuild"):
        rebuild_measure(args, run / "rebuild")
    if args.mode in ("all", "download"):
        src, book, toc = common_book(args, run)
        for i in range(args.rounds):
            for version, exe in versions:
                download_measure(args, exe, version, run / f"download-{i+1}-{version}", src, book, toc, extra_options={"multiSource":False})
    if args.mode in ("all", "search"):
        for i in range(args.search_rounds):
            for version, exe in versions:
                search_measure(args, exe, version, run / f"search-{i+1}-{version}", defaults=True)
        search_measure(args, args.candidate, "V89" if not args.v87 else "V88", run / "search-quick", quick=True)
    if args.mode == "health":
        ping_measure(args, run / "ping")
        search_measure(args, args.candidate, "V89" if not args.v87 else "V88", run / "search-default", defaults=True)
    if args.mode == "recovery":
        recovery_measure(args, run)
    if args.mode in ("multi", "plan"):
        multi_measure(args, run)
    if args.mode == "diagnose":
        diagnose_measure(args, run)


if __name__ == "__main__":
    main()
