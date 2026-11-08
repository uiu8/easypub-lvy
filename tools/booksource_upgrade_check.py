"""用两个实际插件进程验证 V88 数据升级；只在独立夹具目录写入。"""
import argparse
import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import threading
import time

spec = importlib.util.spec_from_file_location("booksource_perf", Path(__file__).with_name("booksource_perf.py"))
perf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(perf)
Plugin, ROOT = perf.Plugin, perf.ROOT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--v88", type=Path, required=True)
    parser.add_argument("--v89", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    run = args.output or ROOT / "artifacts" / ("v89-upgrade-" + time.strftime("%Y%m%d-%H%M%S"))
    run.mkdir()
    requests = []
    available = False

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            requests.append(self.path)
            ok = self.path != "/3" or available
            body = (f"<div id='content'>本章标识{self.path}。" + "这是自拟夹具正文，不含任何真实书稿。" * 40 + "</div>").encode()
            self.send_response(200 if ok else 404)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    source = {"bookSourceUrl": base, "bookSourceName": "升级夹具", "searchUrl": "/search",
              "ruleSearch": {"bookList": "a", "name": "@text", "bookUrl": "@href"},
              "ruleContent": {"content": "#content@text"}, "customOrder": 17}
    source_path = run / "fixture.json"
    source_path.write_text(json.dumps([source], ensure_ascii=False), encoding="utf-8")
    book = {"name": "升级夹具", "author": "自拟", "bookUrl": base + "/book", "origin": base}
    toc = [{"index": i - 1, "title": f"第{i}章 自拟{i}", "url": base + f"/{i}"} for i in range(1, 4)]
    params = {"sourceId": base, "book": book, "toc": toc[:2],
              "options": {"folder": str(run / "downloads"), "retries": 0}}

    def finish(p, task):
        end = time.monotonic() + 20
        while time.monotonic() < end:
            row = next(t for t in p.call("queue.list")["tasks"] if t["id"] == task)
            if row["status"] in ("done", "failed", "cancelled"):
                assert row.get("result") is not None, row
                return row
            time.sleep(.05)
        raise TimeoutError("夹具下载未完成")

    with Plugin(args.v88.resolve(), run / "data") as p:
        p.call("sources.import", {"path": str(source_path)})
        old = finish(p, p.call("download.start", params)["taskId"])
        assert not old["result"]["outcome"]["failures"]
    before = len(requests)
    params["requestConfig"] = {"headers": {"Cookie": "v89-fake-cookie"},
                               "proxy": "http://fake:v89-fake-password@localhost:1"}
    with Plugin(args.v89.resolve(), run / "data") as p:
        assert p.call("queue.list")["tasks"][0]["id"] == old["id"]
        assert p.call("sources.list")[0]["customOrder"] == 17
        new = finish(p, p.call("download.start", params)["taskId"])
        assert new["result"]["outcome"]["fromCache"] == 2
        assert len(requests) == before, "旧缓存应无需再请求正文"
        params["toc"] = list(reversed(toc[:2]))
        moved = finish(p, p.call("download.start", params)["taskId"])
        assert moved["result"]["outcome"]["fromCache"] == 2
        assert len(requests) == before, "旧版缓存换序也不应重新请求正文"
        moved_text = Path(moved["result"]["outcome"]["path"]).read_text(encoding="utf-8")
        assert moved_text.index("第2章 自拟2") < moved_text.index("第1章 自拟1")
        p.call("sources.pin", {"ids": [base]})
        p.call("sources.rate", {"ids": [base], "rating": 2})
        params["toc"] = toc
        params["options"]["folder"] = str(run / "retry")
        retry = finish(p, p.call("download.start", params)["taskId"])
        assert [c["index"] for c in retry["chapters"] if c["status"] == "failed"] == [3]
        available = True
        before_retry = len(requests)
        p.call("queue.retryFailed", {"taskId": retry["id"]})
        repaired = finish(p, retry["id"])
        assert requests[before_retry:] == ["/3"], "只补抓失败章节"
        assert not repaired["result"]["outcome"]["failures"]
        assert len(repaired["chapters"]) == 3
        persisted = (run / "data/tasks.json").read_text(encoding="utf-8")
        assert "v89-fake-cookie" not in persisted and "v89-fake-password" not in persisted
    with Plugin(args.v89.resolve(), run / "data") as p:
        source = p.call("sources.list")[0]
        assert source["pinned"] and source["rating"] == 2
        task = next(t for t in p.call("queue.list")["tasks"] if t["id"] == retry["id"])
        assert all(c["status"] == "completed" for c in task["chapters"])
    server.shutdown()
    result = {"passed": True, "v88CacheReused": 2, "retryRequests": ["/3"],
              "oldCacheReorderedWithoutRequests": True,
              "baselineSha256": perf.sha(args.v88), "candidateSha256": perf.sha(args.v89),
              "queueAndPreferencesSurviveRestart": True, "directory": str(run)}
    (run / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
