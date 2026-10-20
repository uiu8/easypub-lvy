"""插件真实进程：代理路由、草稿隔离、凭据持久化、轻悦 HTML 四入口与嵌套 WebView。
仅使用本机自拟内容；外网对照由 --online 单独启用。不写用户插件数据。
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("perf", ROOT / "tools/booksource_perf.py")
perf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(perf)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--online", action="store_true")
    parser.add_argument("--baseline", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    os.environ["EASYPUB_WEBVIEW_DATA"] = str(args.output.resolve() / "webview")
    seen = []
    normal = "本章由程序生成，用于验证书源的网络调用、目录和文字提取。" * 20
    rules = {}
    html = ""

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            seen.append(self.path)
            if self.path.endswith("/slow-body"):
                self.send_response(200)
                self.send_header("Content-Length", "65536")
                self.end_headers()
                self.wfile.write(b"x" * 16384)
                self.wfile.flush()
                time.sleep(2)
                try:
                    self.wfile.write(b"x" * 49152)
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                    pass
                return
            if self.path.endswith("/page"):
                assert self.headers.get("X-WebView-Fixture") == "passed"
            if self.path.endswith("/remote.json"):
                body = json.dumps(rules, ensure_ascii=False)
            elif self.path.endswith("/source.html"):
                body = html
            elif self.path.endswith("/dependency.js"):
                body = "window.dependencyReady = true;"
            elif self.path.endswith("/s"):
                # 双重 JSON 头的兼容必须真的到达网络层。
                assert self.headers.get("X-Fixture") == "passed"
                body = json.dumps([{"name": "自拟书", "bookUrl": base + "/b", "type": 0}])
            elif self.path.endswith("/content"):
                body = normal
            else:
                body = "<html><body><div id='c'>" + normal + "</div></body></html>"
            raw = body.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    html = """<!DOCTYPE html><script src="/dependency.js"></script><script>
    const bridge = window.flutter_inappwebview;
    async function search(key, page) {
      if (!window.dependencyReady) throw Error('dependency');
      const r = await bridge.callHandler('http','get','BASE/s','',JSON.stringify(JSON.stringify({'X-Fixture':'passed'})),true,'');
      if (typeof r.headers['content-type'][0] !== 'string' || !r.body || r.statusCode !== 200) throw Error('shape');
      await bridge.callHandler('cache.set','proof','present');
      return r.data;
    }
    async function info(url) {
      if(await bridge.callHandler('cache.get','proof') !== 'present') throw Error('cache');
      return JSON.stringify({bookUrl:url,name:'自拟书',tocUrl:'BASE/toc',latestChapterTitle:'第一章'});
    }
    async function chapter(url) {
      return JSON.stringify([{name:'第一章',chapterId:'BASE/content',isPay:false,isVolume:false}]);
    }
    async function content(url) {
      return await bridge.callHandler('webview','BASE/page',"document.querySelector('#c').innerText",'','',JSON.stringify({'X-WebView-Fixture':'passed'}),'','');
    }
    </script>""".replace("BASE", base)
    rules = {"bookSourceUrl": base, "bookSourceName": "轻悦协议夹具", "html": base + "/source.html", "enabled": True}
    report = {"exeSha256": perf.sha(args.exe), "fixture": {}}
    try:
        if args.baseline:
            with perf.Plugin(args.baseline, args.output / "baseline-data") as old:
                old.call("network.proxy.set", {"config": {"mode": "manual", "url": base}})
                start = len(seen)
                try:
                    old.call("sources.importUrl", {"url": "http://proxy-fixture.invalid/remote.json"})
                    imported = True
                except RuntimeError:
                    imported = False
                reached = any("proxy-fixture.invalid" in path for path in seen[start:])
                report["baseline"] = {"sha256": perf.sha(args.baseline), "importSucceeded": imported, "proxyReached": reached}
                assert not imported and not reached, "指定旧基线未复现网址导入忽略代理"
        with perf.Plugin(args.exe, args.output / "data") as plugin:
            before = plugin.call("network.proxy.get")
            draft = {"mode": "manual", "url": base, "scope": "marked", "connectTimeoutMs": 1000}
            diag = plugin.call("network.proxy.test", {"config": draft, "url": "http://proxy-fixture.invalid/test"})
            assert plugin.call("network.proxy.get") == before, "测试草稿不得改设置"
            assert not diag["samples"][0]["ok"] and diag["samples"][1]["ok"]
            report["fixture"]["draftComparison"] = diag
            plugin.call("network.proxy.set", {"config": {**draft, "url": base.replace("://", "://fixture:secret@", 1)}})
            shown = plugin.call("network.proxy.get")
            assert "secret" not in json.dumps(shown) and shown["credentialsInMemory"]
            plugin.call("network.proxy.set", {"config": {**shown, "keepCredentials": True}})
            assert plugin.call("network.proxy.get")["credentialsInMemory"], "保存其他选项不能抹掉内存认证"
            persisted = (args.output / "data/network.json").read_text(encoding="utf-8")
            assert "secret" not in persisted and "fixture@" not in persisted
            imported = plugin.call("sources.importUrl", {"url": "http://proxy-fixture.invalid/remote.json"})
            assert imported["added"] == 1
            assert any(p.startswith("http://proxy-fixture.invalid/remote.json") for p in seen), "网址导入必须经过代理"
            # 测试网站为本机，绕过不可达代理；之后用显式禁用测试失败，证明绕过确实生效。
            invalid = {"mode": "manual", "url": "http://127.0.0.1:1", "connectTimeoutMs": 1000}
            local = plugin.call("network.proxy.test", {"config": invalid, "url": base + "/probe"})
            blocked = plugin.call("network.proxy.test", {"config": {**invalid, "bypassLocal": False}, "url": base + "/probe"})
            assert local["samples"][1]["ok"] and not blocked["samples"][1]["ok"]
            report["fixture"]["localBypass"] = True
            sampled = plugin.call("network.proxy.test", {"config": {"mode": "none"}, "url": base + "/slow-body"})
            assert all(r["ok"] and r["sampledBytes"] == 8192 and r["ms"] < 1500 for r in sampled["samples"])
            report["fixture"]["boundedResponseTest"] = sampled
            plugin.call("network.proxy.set", {"config": {"mode": "none"}})
            items = plugin.call("sources.list")
            assert items[0]["format"].startswith("轻悦")
            events = []
            check = plugin.call("sources.check", {"ids": [items[0]["id"]], "key": "自拟", "concurrency": 1},
                                event=lambda _, e: events.append(e))
            assert check["ok"] == 1, str([e for e in events if e.get("event") == "check.result"])
            report["fixture"]["htmlCheck"] = [e for e in events if e.get("event") == "check.result"]
            # 原生接口失败不能被脚本吞掉成“没有搜索结果”。
            broken = {**rules, "bookSourceUrl": base + "/broken",
                      "html": "<script>async function search(){try{await flutter_inappwebview.callHandler('unsupported');}catch(e){}return '[]';}</script>"}
            plugin.call("__import_body", {"text": json.dumps(broken), "file": "native-error.json"})
            events = []
            plugin.call("sources.check", {"ids": [broken["bookSourceUrl"]], "concurrency": 1},
                        event=lambda _, e: events.append(e))
            error = [e for e in events if e.get("event") == "check.result"][0]["error"]
            assert "不支持" in error or "尚未适配" in error, error
            assert [e for e in events if e.get("event") == "check.result"][0]["cause"]=="unsupported"
            report["fixture"]["nativeFailurePreserved"] = True
            # HTML 宿主只允许通过受控桥接联网，导航 / 新窗口不能绕开代理路径。
            navigation={**rules,"bookSourceUrl":base+"/navigation","html":
                "<script>window.open('BASE/forbidden-popup');location.href='BASE/forbidden-navigation';async function search(){return [];}</script>".replace("BASE",base)}
            plugin.call("__import_body",{"text":json.dumps(navigation),"file":"navigation.json"})
            at=len(seen)
            plugin.call("search",{"key":"自拟","sourceIds":[navigation["bookSourceUrl"]],"includeWebView":True})
            assert not any("forbidden-" in path for path in seen[at:]), seen[at:]
            report["fixture"]["htmlNavigationBlocked"]=True
            report["fixturePassed"] = True
            if args.online:
                report["environment"] = {"tun": "用户确认已关闭", "proxySoftware": "仍开启"}
                report["system"] = plugin.call("network.proxy.refresh")["system"]
                report["online"] = {}
                for url in [
                    "https://www.yckceo.com/qysg/shuyuans/json/id/1.json",
                    "https://www.yckceo.com/yuedu/shuyuans/json/id/1315.json",
                    "https://www.yckceo.com/yuedu/shuyuans/json/id/1316.json",
                    "http://svip.langge.cf/zgr.html",
                ]:
                    report["online"][url] = plugin.call("network.proxy.test", {"config": {"mode": "system"}, "url": url})
                    (args.output / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
                plugin.call("network.proxy.set", {"config": {"mode": "system"}})
                try:
                    imported = plugin.call("sources.importUrl", {"url": "https://www.yckceo.com/qysg/shuyuans/json/id/1.json"})
                    report["qysgImport"] = {"ok": True, **imported}
                    qysg = [s for s in plugin.call("sources.list") if s["file"].startswith("https://")]
                    report["qysgCount"] = len(qysg)
                    assert len(qysg) == 21
                except RuntimeError as error:
                    report["qysgImport"] = {"ok": False, "error": str(error)}
        # 真正关闭重开，HTML 和脱敏配置仍能加载。
        with perf.Plugin(args.exe, args.output / "data") as plugin:
            items = plugin.call("sources.list")
            assert all(s["format"].startswith("轻悦") for s in items)
            report["reopenCount"] = len(items)
        report["passed"] = True
    finally:
        server.shutdown()
        (args.output / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"passed": report["passed"], "output": str(args.output)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
