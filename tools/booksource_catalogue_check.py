"""小说第二批：真实插件进程的目录更新、缓存身份、失败恢复与 HTTP 分类。

仅使用隔离目录和本机自拟内容。旧/新两包接收相同目录，统计实际正文请求，
不用网络请求数量或模拟站点耗时冒充真实网站/竞品性能。
"""
import argparse
from collections import Counter
import hashlib
import importlib.util
import json
from pathlib import Path
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

spec = importlib.util.spec_from_file_location("novel", Path(__file__).with_name("booksource_novel_check.py"))
novel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(novel)
Plugin, finish, write_json = novel.perf.Plugin, novel.finish, novel.write_json


class Site:
    def __init__(self):
        self.ids = [f"a{i:03}" for i in range(120)]
        self.revision = {}
        self.blocked = set()
        self.requests = []
        self.counts = Counter()
        self.lock = threading.Lock()

    def response(self, path):
        with self.lock:
            self.requests.append((path, time.monotonic()))
            self.counts[path] += 1
            attempt = self.counts[path]
            if path == "/toc":
                body = "".join(f"<li><a href='/body/{i}' data-rev='{self.revision.get(i, 1)}'>章目 {i}</a></li>" for i in self.ids)
                return 200, body, {}
            if path.startswith("/body/"):
                key = path.rsplit("/", 1)[1]
                if key in self.blocked:
                    return 404, "missing fixture", {}
                return 200, self.content(key), {}
            kind = path.split("/")[2]
            if kind == "challenge":
                return 200, "<title>Just a moment...</title><script src='/cdn-cgi/challenge-platform/fixture'></script>", {}
            if kind == "login":
                return 200, "<div id='content'>请先登录后阅读。</div>", {}
            status = int(kind)
            if status in (429, 503) and attempt > 1:
                return 200, self.content(path), {}
            return status, "self-authored error fixture", {"Retry-After": "1"} if status in (429, 503) else {}

    def content(self, key):
        return f"<div id='content'>自拟编号 {key}，修订 {self.revision.get(key, 1)}。<p>" + "夜色渐深，窗外树叶轻轻晃动，屋里的人收拾了桌上的笔记。" * 30 + "</p></div>"

    def body_requests(self, start):
        return [p for p, _ in self.requests[start:] if p.startswith("/body/")]


def setup(p, root, base):
    path = root / "source.json"
    write_json(path, [{
        "bookSourceUrl": base, "bookSourceName": "目录身份夹具",
        "ruleToc": {"chapterList": "li", "chapterName": "a@text", "chapterUrl": "a@href", "updateTime": "a@data-rev"},
        "ruleContent": {"content": "#content@html"},
    }])
    p.call("network.proxy.set", {"config": {"mode": "none"}})
    p.call("sources.import", {"path": str(path)})


def catalogue_check(exe, root, site, base, candidate):
    site.ids = [f"a{i:03}" for i in range(120)]
    site.revision.clear()
    site.blocked.clear()
    book = {"name": "目录更新自拟样书", "author": "本机夹具", "origin": base,
            "bookUrl": base + "/book", "tocUrl": base + "/toc"}
    options = {"folder": str(root / "downloads"), "threads": 8, "retries": 0, "multiSource": False}
    key = base + "\n" + book["bookUrl"]
    cache = Path(options["folder"]) / ".easypub-cache" / hashlib.sha256(key.encode()).hexdigest()[:16]
    report = {}
    with Plugin(exe, root / "data") as p:
        setup(p, root, base)
        begin = time.monotonic()
        task = p.call("queue.add", {"sourceId": base, "book": book, "options": options})["taskId"]
        first = finish(p, task)
        assert not first["failures"], first
        report["cold120Seconds"] = round(time.monotonic() - begin, 3)
        output = Path(first["path"])

        def update(label, expected_requests, expected_changes):
            start = len(site.requests)
            result = p.call("library.check", {"keys": [key]})
            record = next(r for r in result["records"] if r["key"] == key)
            if candidate:
                assert record["catalogChanges"] == expected_changes, (label, record["catalogChanges"])
                assert record["catalogChanged"] is True
            begin = time.monotonic()
            task = p.call("library.update", {"key": key})["taskId"]
            outcome = finish(p, task)
            assert not outcome["failures"], outcome
            got = site.body_requests(start)
            report[label] = {"requests": len(got), "seconds": round(time.monotonic() - begin, 3),
                             "newChapters": record["newChapters"], "changes": record.get("catalogChanges")}
            if candidate:
                assert sorted(got) == sorted("/body/" + i for i in expected_requests), (label, got)
            text = output.read_text(encoding="utf-8")
            assert [line for line in text.splitlines() if line.startswith("章目 ")] == ["章目 " + i for i in site.ids]
            # 各缓存正文、标题位置及来源地址必须同一章，不能只有整书章数正确。
            provenance = p.call("library.provenance", {"key": key})
            for n, i in enumerate(site.ids):
                assert f"自拟编号 {i}，" in (cache / f"{n:05}.txt").read_text(encoding="utf-8")
                if candidate:
                    assert provenance[n]["url"].endswith("/body/" + i), (label, n, provenance[n])
            return text

        def delta(**kw):
            return {"added": 0, "removed": 0, "modified": 0, "moved": 0, "volumes": 0, **kw}
        site.ids.insert(0, "insert")
        update("insertFront", ["insert"], delta(added=1))
        site.ids[4] = "replacement"
        update("sameCountReplacement", ["replacement"], delta(added=1, removed=1))
        site.ids.reverse()
        update("reverse", [], delta(moved=len(site.ids)-1))
        revised = site.ids[12]
        site.revision[revised] = 2
        text = update("revision", [revised], delta(modified=1))
        report["revision"]["containsNewText"] = f"自拟编号 {revised}，修订 2。" in text
        if candidate:
            assert report["revision"]["containsNewText"]
        site.ids = site.ids[2:]
        update("removeFront", [], delta(removed=2))
        before = novel.perf.sha(output)
        old_toc = p.call("library.list")[0]["toc"]
        site.ids.insert(0, "missing")
        site.blocked.add("missing")
        p.call("library.check", {"keys": [key]})
        task = p.call("library.update", {"key": key})["taskId"]
        outcome = finish(p, task)
        report["failedUpdatePreserved"] = before == novel.perf.sha(output)
        assert len(outcome["failures"]) == 1
        if candidate:
            assert outcome["outputPreserved"] and report["failedUpdatePreserved"]
            assert p.call("library.list")[0]["toc"] == old_toc
            try:
                p.call("library.rebuild", {"key": key})
                raise AssertionError("目录迁移后未完成更新不应按旧索引整理")
            except RuntimeError as e:
                assert "缓存目录已变化" in str(e), str(e)
    # 重新启动真实进程，只补失败章。旧书架的单次重试范围不得污染下一次追更。
    site.blocked.clear()
    with Plugin(exe, root / "data") as p:
        start = len(site.requests)
        p.call("queue.retryFailed", {"taskId": task})
        repaired = finish(p, task)
        assert not repaired["failures"]
        assert site.body_requests(start) == ["/body/missing"]
        report["restartRetryRequests"] = 1
        site.ids.append("after-retry")
        p.call("library.check", {"keys": [key]})
        start = len(site.requests)
        task = p.call("library.update", {"key": key})["taskId"]
        later = finish(p, task)
        report["nextUpdateComplete"] = not later["failures"]
        if candidate:
            assert not later["failures"], later
            assert site.body_requests(start) == ["/body/after-retry"]
        report["finalSha256"] = novel.perf.sha(output)
    return report


def errors_check(exe, root, site, base):
    report = {}
    with Plugin(exe, root / "data") as p:
        setup(p, root, base)
        p.call("sources.crawlProfile.set", {"id": base, "profile": {"concurrency": 1, "retries": 1}})
        for code, kind in [("401", "login_required"), ("403", "access_denied"), ("407", "proxy_auth"),
                           ("challenge", "verification"), ("login", "login_required"),
                           ("404", "missing"), ("500", "server"), ("503", None), ("429", None)]:
            action = code in ("401", "403", "407", "challenge", "login")
            book = {"name": "错误分类 " + code, "origin": base, "bookUrl": base + "/errors/" + code}
            toc = [{"index": i, "title": f"第{i+1}章", "url": base + f"/error/{code}/{i}"} for i in range(5 if action else 1)]
            start = len(site.requests)
            begin = time.monotonic()
            task = p.call("queue.add", {"sourceId": base, "book": book, "toc": toc,
                         "options": {"folder": str(root / "downloads"), "retries": 1, "multiSource": False}})["taskId"]
            outcome = finish(p, task, timeout=40)
            records = next(t for t in p.call("queue.list")["tasks"] if t["id"] == task)["chapters"]
            hits = site.requests[start:]
            report[code] = {"requests": len(hits), "failed": len(outcome["failures"]),
                            "seconds": round(time.monotonic() - begin, 3),
                            "kinds": sorted({r.get("errorKind") or "complete" for r in records})}
            if action:
                assert len(hits) == 1 and len(outcome["failures"]) == 5, report[code]
                assert all(r["errorKind"] == kind and r["action"] for r in records), records
            elif kind:
                assert len(hits) == (2 if code == "500" else 1), report[code]
                assert records[0]["errorKind"] == kind
            else:
                assert len(hits) == 2 and not outcome["failures"], report[code]
                assert hits[1][1] - hits[0][1] >= 1, hits
            if code.isdigit() and kind:
                assert records[0]["httpStatus"] == int(code), records
        diagnostics = p.call("download.diagnose", {})
        report["diagnostics"] = diagnostics
        assert sum(h["httpLimited"] for h in diagnostics["hosts"]) == 1, diagnostics
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    site = Site()
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            status, text, headers = site.response(self.path)
            body = text.encode()
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            for k, v in headers.items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *_):
            pass
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    report = {"baselineSha256": novel.perf.sha(args.baseline),
              "candidateSha256": novel.perf.sha(args.candidate),
              "scope": "本机自拟 HTTP 内容；真实插件进程；不代表外网站点或竞品速度"}
    try:
        for label, exe in [("baseline", args.baseline), ("candidate", args.candidate)]:
            report[label] = catalogue_check(exe, args.out / label, site, base, label == "candidate")
            write_json(args.out / "report.json", report)
            print(json.dumps({label: report[label]}, ensure_ascii=False), flush=True)
        report["errors"] = errors_check(args.candidate, args.out / "errors", site, base)
        report["passed"] = True
    finally:
        write_json(args.out / "report.json", report)
        server.shutdown()
        server.server_close()
    print(json.dumps(report, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
