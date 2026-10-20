"""小说优化的真实插件进程对照：隔离数据、自拟正文、不访问外网。

比较旧包和候选包的空搜索恢复、任务写入、失败重试与重启、离线大书合成。
计时是同机夹具结果，不代表真实站点或竞品的下载速度。
"""
import argparse
import ctypes
from ctypes import wintypes
import hashlib
import importlib.util
import json
from pathlib import Path
import queue
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

spec = importlib.util.spec_from_file_location("perf", Path(__file__).with_name("booksource_perf.py"))
perf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(perf)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")


class Memory(ctypes.Structure):
    _fields_ = [("cb", wintypes.DWORD), ("faults", wintypes.DWORD)] + [
        (name, ctypes.c_size_t) for name in (
            "peak", "working", "peakPaged", "paged", "peakNonPaged",
            "nonPaged", "pagefile", "peakPagefile")]


class IO(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint64) for name in (
        "reads", "writes", "other", "readBytes", "writeBytes", "otherBytes")]


def counters(plugin):
    memory, io = Memory(), IO()
    memory.cb = ctypes.sizeof(memory)
    handle = wintypes.HANDLE(int(plugin.p._handle))
    if not ctypes.windll.psapi.GetProcessMemoryInfo(handle, ctypes.byref(memory), memory.cb):
        raise ctypes.WinError()
    if not ctypes.windll.kernel32.GetProcessIoCounters(handle, ctypes.byref(io)):
        raise ctypes.WinError()
    return {"peakWorkingSetBytes": memory.peak, "processWriteBytes": io.writeBytes,
            "processWriteOperations": io.writes}


def finish(plugin, task, timeout=180):
    end = time.monotonic() + timeout
    events = list(plugin.events)
    plugin.events.clear()
    while time.monotonic() < end:
        if events:
            _, event = events.pop(0)
        else:
            try:
                _, event = plugin.lines.get(timeout=max(.01, end - time.monotonic()))
            except queue.Empty:
                break
        if event.get("event") == "download.done" and event.get("taskId") == task:
            assert "error" not in event, event
            return event["result"]["outcome"]
    raise TimeoutError("下载任务没有结束")


def search_check(exe, root, candidate):
    source = root / "source.js"
    source.parent.mkdir(parents=True)
    source.write_text("""
var config={bookSourceUrl:"http://127.0.0.1:19777",bookSourceName:"搜索健康夹具"};
function search(key,page){
 if(key==="空") return [];
 if(key==="故障") throw Error("DNS lookup failed");
 return [{name:"命中样书",author:"自拟",bookUrl:"http://127.0.0.1:19777/book"}];
}
function getBookInfo(b){return b;}
function getChapters(b){return [];}
function getContent(c,b,n){return "";}
""", encoding="utf-8")
    with perf.Plugin(exe, root / "data") as p:
        p.call("sources.import", {"path": str(source)})
        source_id = p.call("sources.list")[0]["id"]
        empty = [p.call("search", {"key": "空", "filterTitle": False}) for _ in range(3)]
        recovered = p.call("search", {"key": "命中", "filterTitle": False})
        report = {"emptyFailed": [r["failed"] for r in empty],
                  "afterEmptyFound": recovered["found"], "afterEmptySkipped": recovered["skipped"]}
        if candidate:
            assert report["emptyFailed"] == [0, 0, 0] and recovered["found"] == 1, report
            for _ in range(3):
                r = p.call("search", {"key": "故障", "filterTitle": False})
                assert r["failed"] == 1
            assert p.call("search", {"key": "命中", "filterTitle": False})["skipped"] == 1
            assert p.call("search", {"key": "命中", "filterTitle": False,
                                     "sourceIds": [source_id]})["found"] == 1
            for _ in range(3):
                p.call("search", {"key": "故障", "filterTitle": False})
            p.call("network.proxy.set", {"config": {"mode": "none"}})
            assert p.call("search", {"key": "命中", "filterTitle": False})["found"] == 1
            report["explicitAndNetworkRecovery"] = True
    return report


def download_check(exe, root, base, chapter_count, requests, available, candidate):
    root.mkdir(parents=True)
    rule = {"bookSourceUrl": base, "bookSourceName": "下载检查点夹具",
            "searchUrl": "/search", "ruleSearch": {"bookList": "a", "name": "@text", "bookUrl": "@href"},
            "ruleContent": {"content": "#content@text"}}
    source_path = root / "source.json"
    write_json(source_path, [rule])
    book = {"name": "小说下载夹具", "author": "自拟", "origin": base, "bookUrl": base + "/book"}
    toc = [{"index": i, "title": f"第{i+1}章 自拟{i+1}", "url": base + f"/c/{i}"}
           for i in range(chapter_count)]
    params = {"sourceId": base, "book": book, "toc": toc,
              "options": {"folder": str(root / "downloads"), "threads": 8, "retries": 0,
                          "multiSource": False}}
    available.clear()
    begin_requests = len(requests)
    with perf.Plugin(exe, root / "data") as p:
        p.call("network.proxy.set", {"config": {"mode": "none"}})
        p.call("sources.import", {"path": str(source_path)})
        before = counters(p)
        begin = time.monotonic()
        task = p.call("queue.add", params)["taskId"]
        outcome = finish(p, task)
        elapsed = time.monotonic() - begin
        after = counters(p)
        state = p.call("queue.list")
        assert len(outcome["failures"]) == 1 and outcome["failures"][0]["index"] == 1, outcome
        assert len(state["tasks"][0]["chapters"]) == chapter_count
        out = Path(outcome["path"])
        report = {"seconds": round(elapsed, 3), "chapters": chapter_count,
                  "requests": len(requests) - begin_requests, "outputSha256": perf.sha(out),
                  "outputBytes": out.stat().st_size, "peakWorkingSetBytes": after["peakWorkingSetBytes"],
                  "processWriteBytes": after["processWriteBytes"] - before["processWriteBytes"],
                  "processWriteOperations": after["processWriteOperations"] - before["processWriteOperations"],
                  "checkpointWrites": state.get("checkpointWrites"),
                  "checkpointBytes": state.get("checkpointBytes")}
        if candidate:
            assert state["checkpointWrites"] <= 6 + elapsed * 2.1, state["checkpointWrites"]
    # 完成检查点必须能重开，且只补失败章节；健康章不重新请求。
    before_retry = len(requests)
    available.set()
    with perf.Plugin(exe, root / "data") as p:
        assert len(p.call("queue.list")["tasks"][0]["chapters"]) == chapter_count
        p.call("queue.retryFailed", {"taskId": task})
        repaired = finish(p, task)
        assert not repaired["failures"]
        assert requests[before_retry:] == ["/c/0"], requests[before_retry:]
        assert "（本章未下载）" not in out.read_text(encoding="utf-8")
        report["restartRetryRequests"] = len(requests) - before_retry
        report["repairedSha256"] = perf.sha(out)
    return report


def rebuild_check(exe, root, mib):
    data, folder = root / "data", root / "downloads"
    book = {"name": "离线长篇夹具", "author": "自拟", "intro": "测试逐章输出，不含外网书稿。",
            "origin": "local-fixture", "bookUrl": "local-fixture/book"}
    key = book["origin"] + "\n" + book["bookUrl"]
    cache = folder / ".easypub-cache" / hashlib.sha256(key.encode()).hexdigest()[:16]
    cache.mkdir(parents=True)
    line = "这是完整保留的自拟正文，用来核对合成结果与峰值内存。" * 100 + "\n"
    body = line * max(1, mib * 1024 * 1024 // 128 // len(line.encode()))
    toc = [{"index": i, "title": f"第{i+1}章 离线{i+1}", "url": f"local-fixture/{i}"}
           for i in range(128)]
    for i in range(len(toc)):
        (cache / f"{i:05}.txt").write_text(body, encoding="utf-8")
    write_json(cache / "toc.json", toc)
    output = folder / "离线长篇夹具.txt"
    output.write_text("需要保留的旧成品\n", encoding="utf-8")
    write_json(data / "library.json", [{"key": key, "book": book, "toc": toc,
               "path": str(output), "options": {"folder": str(folder)}, "chapters": len(toc)}])
    with perf.Plugin(exe, data) as p:
        begin = time.monotonic()
        result = p.call("library.rebuild", {"key": key})
        elapsed = time.monotonic() - begin
        metrics = counters(p)
        assert Path(result["backup"]).read_text(encoding="utf-8") == "需要保留的旧成品\n"
        # 缺缓存时不得替换已完成的 TXT 或已有备份。
        original = perf.sha(output)
        (cache / "00003.txt").unlink()
        try:
            p.call("library.rebuild", {"key": key})
            raise AssertionError("缺失缓存应拒绝覆盖")
        except RuntimeError as e:
            assert "缓存缺失" in str(e), str(e)
        assert perf.sha(output) == original
        assert Path(result["backup"]).read_text(encoding="utf-8") == "需要保留的旧成品\n"
    return {"seconds": round(elapsed, 3), "outputBytes": output.stat().st_size,
            "outputSha256": original, "peakWorkingSetBytes": metrics["peakWorkingSetBytes"],
            "missingCachePreservedOutput": True}


def interrupted_check(exe, root, base, slow):
    root.mkdir(parents=True)
    source_path = root / "source.json"
    write_json(source_path, [{"bookSourceUrl": base, "bookSourceName": "中断恢复夹具",
                             "ruleContent": {"content": "#content@text"}}])
    book = {"name": "中断恢复样书", "author": "自拟", "origin": base, "bookUrl": base + "/interrupted"}
    toc = [{"index": i, "title": f"第{i+1}章 自拟{i+1}", "url": base + f"/c/{i}"} for i in range(120)]
    slow.set()
    try:
        with perf.Plugin(exe, root / "data") as p:
            p.call("sources.import", {"path": str(source_path)})
            task = p.call("queue.add", {"sourceId": base, "book": book, "toc": toc,
                          "options": {"folder": str(root / "downloads"), "threads": 4, "retries": 0}})["taskId"]
            end = time.monotonic() + 30
            while time.monotonic() < end:
                _, e = p.lines.get(timeout=10)
                if e.get("event") == "download.progress" and e.get("progress", {}).get("done", 0) >= 12:
                    break
            else:
                raise TimeoutError("中断夹具未产生进度")
            p.p.terminate()  # 模拟插件崩溃，不走正常 exit 的最终保存。
            p.p.wait(timeout=10)
    finally:
        slow.clear()
    key = book["origin"] + "\n" + book["bookUrl"]
    cache = root / "downloads/.easypub-cache" / hashlib.sha256(key.encode()).hexdigest()[:16]
    cached = len(list(cache.glob("*.txt")))
    assert 0 < cached < len(toc), cached
    with perf.Plugin(exe, root / "data") as p:
        row = p.call("queue.list")["tasks"][0]
        assert row["status"] == "paused", row["status"]
        p.call("queue.resume", {"taskId": task})
        outcome = finish(p, task)
        assert not outcome["failures"] and outcome["fromCache"] == cached, outcome
        text = Path(outcome["path"]).read_text(encoding="utf-8")
        assert all(f"本章唯一标识/c/{i}。" in text for i in range(len(toc)))
    return {"chapters": len(toc), "cachedBeforeRestart": cached,
            "reusedAfterRestart": outcome["fromCache"], "complete": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--chapters", type=int, default=600)
    parser.add_argument("--mib", type=int, default=64)
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    requests, available, slow = [], threading.Event(), threading.Event()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            requests.append(self.path)
            if slow.is_set():
                time.sleep(.02)
            ok = self.path != "/c/0" or available.is_set()
            raw = (f"<div id='content'>本章唯一标识{self.path}。\n"
                   + "风吹过山坡，旅人记下当天的见闻，准备在清晨继续前行。" * 100 + "</div>").encode()
            self.send_response(200 if ok else 404)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            try:
                self.wfile.write(raw)
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                pass  # 中断夹具故意在请求进行中终止插件。

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    report = {"scope": "同机本地自拟夹具，非真实站点或竞品测速"}
    try:
        for label, exe in [("baseline", args.baseline), ("candidate", args.candidate)]:
            exe = exe.resolve()
            root = args.output / label
            report[label] = {"exeSha256": perf.sha(exe),
                             "search": search_check(exe, root / "search", label == "candidate"),
                             "download": download_check(exe, root / "download", base,
                                                        args.chapters, requests, available, label == "candidate"),
                             "rebuild": rebuild_check(exe, root / "rebuild", args.mib)}
            write_json(args.output / "report.json", report)
            print(json.dumps({label: report[label]}, ensure_ascii=False), flush=True)
        for kind in ["download", "rebuild"]:
            assert report["baseline"][kind]["outputSha256"] == report["candidate"][kind]["outputSha256"]
        assert report["baseline"]["download"]["repairedSha256"] == report["candidate"]["download"]["repairedSha256"]
        report["identicalOutput"] = True
        report["interrupted"] = interrupted_check(args.candidate.resolve(), args.output / "interrupted", base, slow)
        write_json(args.output / "report.json", report)
        print(json.dumps({"interrupted": report["interrupted"]}, ensure_ascii=False), flush=True)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
