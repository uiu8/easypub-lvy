"""V90 脱敏语义样本：record / replay / collect / fixtures。

正文尾部只保存长度占位，回放扩展为自拟文字；不用于证明原文逐字一致。
原始合集只读。录制失败或回放不符的样本留在 artifacts，不冒充验收成功。
"""
from __future__ import annotations
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import importlib.util
import json
import re
from pathlib import Path
import shutil
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / "rust/crates/easypub_booksource/tests/corpus"
spec = importlib.util.spec_from_file_location("perf", Path(__file__).with_name("booksource_perf.py"))
perf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(perf)


def dump(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")


def coverage(s):
    def compact(value):
        if isinstance(value,dict):return {k:compact(v) for k,v in value.items() if v not in (None,"",{},[])}
        if isinstance(value,list):return [compact(v) for v in value]
        return value
    active={k:s.get(k) for k in ["searchUrl","jsLib","mainJs","html","ruleSearch","ruleBookInfo","ruleToc","ruleContent"]}
    text = json.dumps(compact(active), ensure_ascii=False)
    tags = [name for pattern, name in [
        ("@css:", "CSS"), ("@xpath:", "XPath"), ("$.", "JSONPath"), ("##", "正则"),
        ("<js>", "<js>"), ("@js:", "@js:"), ("{{", "{{}}"), ("@put", "@put/@get"),
        ("java.get(", "put/get"), ("nextTocUrl", "目录分页"),
        ("nextContentUrl", "正文分页"), ("gbk", "GBK"), ("POST", "POST"),
        ("webView", "WebView"), ("webJs", "webJs"), ("mainJs", "mainJs"),
        ("contentBatch", "contentBatch"), ("getContentBatch", "contentBatch"),
    ] if pattern in text]
    if re.search(r'"\s*/(?!https?)(?:/|html)',text):tags.append("XPath")
    return sorted(set(["jsoup默认规则"] + tags))


def record(plugin, source, key, folder, origin, tags):
    result = plugin.call("corpus.record", {
        "source": source, "key": key, "folder": str(folder.resolve()),
        "origin": origin, "coverage": tags,
    }, timeout=180)
    if len(result["chars"]) != 3:
        raise RuntimeError("只有不足三个免费章节，保留录制材料但不计入三章样本")
    checked = plugin.call("corpus.replay", {"folder": str(folder.resolve())}, timeout=180)
    return {**result, "replay": checked}


def collect(args, plugin):
    # 旧校验只用于选择候选；每份样本必须重新录制并在离线服务器回放。
    stored = json.loads((args.previous / "data/sources.json").read_text(encoding="utf-8"))
    results = [json.loads(s) for s in (args.previous / "results.jsonl").read_text(encoding="utf-8").splitlines()]
    good = {r["id"]:r for r in results if r.get("ok")}
    candidates = [s for s in stored if s.get("easypub", {}).get("id") in good and
                  any(x in s.get("easypub", {}).get("file", "") for x in ["1315-", "1316-"])]
    # 先录无需登录、脚本较少的匿名公开网页；缺少的协议用注明手写的样本补齐。
    candidates.sort(key=lambda s: ("$." in json.dumps(s.get("ruleContent",{})),
                                   bool(s.get("jsLib") or s.get("mainJs") or s.get("html")),
                                   "java." in json.dumps(s.get("ruleContent",{})),
                                   good[s["easypub"]["id"]].get("ms",999999), s["bookSourceUrl"]))
    args.output.mkdir(parents=True, exist_ok=True)
    staging = args.work / "recordings"
    staging.mkdir(parents=True, exist_ok=True)
    success, sites, distinct = [], set(), []
    for folder in sorted(args.output.glob("real-*")):
        source=json.loads((folder/"source.json").read_text(encoding="utf-8"))
        recorded=json.loads((folder/"exchanges.json").read_text(encoding="utf-8"))
        sites.add(urlsplit(source["bookSourceUrl"]).hostname)
        if len(recorded["expected"]["chars"])==3:
            success.append({"ok":True,"id":folder.name,"existing":True,"sourceUrl":source["bookSourceUrl"]})
    for s in candidates:
        host=urlsplit(s["bookSourceUrl"]).hostname
        if host not in sites:
            distinct.append(s);sites.add(host)

    def one(source):
        sid=source["bookSourceUrl"]
        number="real-"+hashlib.sha256(sid.encode()).hexdigest()[:10]
        attempt=staging/number
        origin = source.get("easypub", {}).get("file", "")
        try:
            with perf.Plugin(args.exe,args.work/"workers"/number) as worker:
                worker.call("network.proxy.set",{"config":{"mode":args.network,"scope":"all","bypassLocal":True}})
                result = record(worker, source, args.key, attempt, origin, coverage(source))
            shutil.copytree(attempt, args.output / number)
            return {"ok":True,"id":number,"source":source["bookSourceName"],"sourceUrl":sid,"origin":origin,**result}
        except (RuntimeError, TimeoutError) as e:
            return {"ok":False,"source":source["bookSourceName"],"error":str(e)}
    workers=min(6,max(1,args.count-len(success)))
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for at in range(0,len(distinct),workers):
            if len(success)>=args.count:break
            for future in as_completed([pool.submit(one,s) for s in distinct[at:at+workers]]):
                status=future.result()
                if status["ok"]:success.append(status)
                print(json.dumps({"count":len(success),**status},ensure_ascii=False),flush=True)
                with (args.work/"attempts.jsonl").open("a",encoding="utf-8") as f:
                    f.write(json.dumps(status,ensure_ascii=False)+"\n")
            if len(success)>=args.count:break
    dump(args.work / "collected.json", success)
    if len(success) < args.count:
        raise RuntimeError(f"只录制成功 {len(success)} / {args.count}，不得宣称样本量达标")


def manual_sources(base):
    html = {
        "bookSourceUrl": base, "bookSourceName": "手写 CSS 分页与 GBK",
        "searchUrl": '/search?q={{key}},{"charset":"gbk"}',
        "ruleSearch": {"bookList": "class.book", "name": "a@text", "author": "span@text", "bookUrl": "a@href"},
        "ruleBookInfo": {"tocUrl": "a.toc@href"},
        "ruleToc": {"chapterList": "li", "chapterName": "a@text", "chapterUrl": "a@href", "nextTocUrl": "a:contains(下一页)@href"},
        "ruleContent": {"content": "@css:#content@html", "nextContentUrl": "a:contains(下一页)@href", "replaceRegex": "##广告##"},
    }
    yield "manual-html", html, ["手写", "jsoup默认规则", "CSS", ":contains", "{{}}", "GBK", "正则", "目录分页", "正文分页"]
    xpath = json.loads(json.dumps(html))
    xpath["bookSourceName"] = "手写 XPath"
    xpath["ruleSearch"].update({"bookList": "//div[@class='book']", "name": "@xpath:.//a/text()", "author": "@xpath:.//span/text()", "bookUrl": "@xpath:.//a/@href"})
    xpath["ruleContent"] = {"content": "//div[@id='content']/text()"}
    yield "manual-xpath", xpath, ["手写", "XPath"]
    api = {
        "bookSourceUrl": base, "bookSourceName": "手写 JSON POST 与变量",
        "searchUrl": "@js:'/api/search,'+JSON.stringify({method:'POST',body:JSON.stringify({kw:key})})",
        "ruleSearch": {"bookList": "$.data", "name": "$.name", "author": "$.author", "bookUrl": "/api/book/{{$.bid}}@put:{bid:$.bid}"},
        "ruleBookInfo": {"tocUrl": "@js:baseUrl.replace('/book/','/toc/')"},
        "ruleToc": {"chapterList": "$.list", "chapterName": "$.title", "chapterUrl": "<js>'/api/c/'+java.get('bid')+'/'+java.getString('$.id')</js>"},
        "ruleContent": {"content": "$.content"},
    }
    yield "manual-json", api, ["手写", "JSONPath", "POST", "@js:", "<js>", "{{}}", "@put/@get", "put/get"]
    batch = json.loads(json.dumps(api))
    batch["ruleContent"]["contentBatch"] = "@js:chapters.forEach(function(c){java.cacheContent(c.url,JSON.parse(java.ajax(c.url)).content);})"
    yield "manual-batch", batch, ["手写", "contentBatch"]
    script = '''
      var config={bookSourceUrl:"BASE",bookSourceName:"手写单文件 JS",maxBatchSize:50};
      function search(key,page){return JSON.parse(java.ajax("BASE/main/search"));}
      function getBookInfo(book){return {tocUrl:"BASE/main/toc"};}
      function getChapters(book){return JSON.parse(java.ajax("BASE/main/toc"));}
      function getContent(chapter){return JSON.parse(java.ajax(chapter.url)).content;}
      function getContentBatch(chapters,book){JSON.parse(java.post("BASE/main/batch",JSON.stringify(chapters),{}).body()).forEach(function(c){java.cacheContent(c.url,c.content);});}
    '''.replace("BASE", base)
    yield "manual-mainjs", script, ["手写", "mainJs", "contentBatch", "POST"]
    web = json.loads(json.dumps(html))
    web["searchUrl"] = '/search,{"webView":true,"webJs":"document.querySelector(\'.book\') ? document.documentElement.outerHTML : \'\'"}'
    web["ruleContent"] = {"content": "#content@text", "webJs": "document.querySelector('#content') ? document.documentElement.outerHTML : ''"}
    yield "manual-webview", web, ["手写", "WebView", "webJs"]
    sonovel = {
        "url": base, "name": "手写 so-novel 格式", "search": {"url": "/search?q=%s", "result": ".book a", "bookName": "@text"},
        "toc": {"item": "li a", "nextPage": "a.next"}, "chapter": {"content": "#content"},
    }
    yield "manual-sonovel", sonovel, ["手写", "so-novel"]
    qysg = {"bookSourceUrl": base, "bookSourceName": "手写轻悦 HTML", "html": """
      <script>
      async function req(path){let r=await flutter_inappwebview.callHandler("http","GET","BASE"+path,"","{}",true,"");return JSON.parse(r.data);}
      async function search(key,page){return await req("/qysg/search");}
      async function info(url){return await req("/qysg/book");}
      async function chapter(url){return await req("/qysg/toc");}
      async function content(url){return (await req(url.replace("BASE",""))).content;}
      </script>""".replace("BASE", base)}
    yield "manual-qysg", qysg, ["手写", "轻悦HTML", "桥接HTTP"]


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_POST(self): self.do_GET()
    def do_GET(self):
        path = urlsplit(self.path).path
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        base = f"http://127.0.0.1:{self.server.server_port}"
        text = "自拟章节内容用于验证离线协议与分页。" * 70
        data = None
        if path == "/search":
            data = '<div class="book"><a href="/book">西游记</a><span>自拟作者</span></div>'
        elif path == "/book":
            data = '<a class="toc" href="/toc">目录</a><li><a href="/c/1">第一章</a></li><li><a href="/c/2">第二章</a></li><li><a href="/c/3">第三章</a></li>'
        elif path in ["/toc", "/toc2"]:
            data = ('<li><a href="/c/1">第一章</a></li><li><a href="/c/2">第二章</a></li><a class="next" href="/toc2">下一页</a>'
                    if path == "/toc" else '<li><a href="/c/3">第三章</a></li>')
        elif path.startswith("/c/"):
            data = f'<div id="content">{text}</div>' + ('<a href="/c/1b">下一页</a>' if path == "/c/1" else '')
        elif path == "/api/search":
            assert self.command == "POST" and json.loads(body)["kw"] == "西游记"
            data = {"data": [{"name": "西游记", "author": "自拟作者", "bid": 7}]}
        elif path == "/api/book/7": data = {}
        elif path == "/api/toc/7": data = {"list": [{"title": f"第{i}章", "id": i} for i in range(1, 4)]}
        elif path.startswith("/api/c/"): data = {"content": text}
        elif path in ["/main/search", "/qysg/search"]:
            data = [{"name": "西游记", "author": "自拟作者", "bookUrl": base+"/book", "tocUrl": base+"/main/toc", "url":base+"/qysg/book"}]
        elif path == "/qysg/book": data = {"name":"西游记","author":"自拟作者","tocUrl":base+"/qysg/toc"}
        elif path in ["/main/toc", "/qysg/toc"]:
            data = [{"title": f"第{i}章", "name": f"第{i}章", "url": base+f"/api/c/7/{i}", "chapterId":base+f"/api/c/7/{i}"} for i in range(1, 4)]
        elif path == "/main/batch": data = [{"url": c["url"], "content": text} for c in json.loads(body)]
        encoded = (json.dumps(data, ensure_ascii=False) if not isinstance(data, str) else data or "").encode("gbk")
        self.send_response(200 if data is not None else 404)
        self.send_header("Content-Type", "text/html; charset=gbk")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Set-Cookie", "fixture=EP_FAKE_COOKIE_90; Path=/")
        self.end_headers()
        self.wfile.write(encoded)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("mode", choices=["record", "replay", "collect", "fixtures"])
    p.add_argument("--exe", type=Path, required=True)
    p.add_argument("--work", type=Path, required=True)
    p.add_argument("--source", type=Path)
    p.add_argument("--index", type=int, default=0)
    p.add_argument("--key", default="斗破苍穹")
    p.add_argument("--output", type=Path, default=CORPUS)
    p.add_argument("--previous", type=Path)
    p.add_argument("--count", type=int, default=40)
    p.add_argument("--network", choices=["none","system"], default="system",help="只修改独立验收数据目录的插件配置")
    args = p.parse_args()
    args.work.mkdir(parents=True, exist_ok=True)
    with perf.Plugin(args.exe, args.work / "data") as plugin:
        plugin.call("network.proxy.set",{"config":{"mode":args.network,"scope":"all","bypassLocal":True}})
        dump(args.work/"network.json",plugin.call("network.proxy.get"))
        if args.mode == "collect": collect(args, plugin)
        elif args.mode == "record":
            source = json.loads(args.source.read_text(encoding="utf-8-sig"))
            if isinstance(source, list): source = source[args.index]
            print(record(plugin, source, args.key, args.output, str(args.source), coverage(source)))
        elif args.mode == "replay":
            results = [plugin.call("corpus.replay", {"folder": str(f.resolve())}) for f in sorted(args.output.iterdir()) if (f/"source.json").exists()]
            dump(args.work / "replay.json", results)
            print(json.dumps({"passed": len(results)}))
        else:
            server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                for name, source, tags in manual_sources(f"http://127.0.0.1:{server.server_port}"):
                    destination = args.output / name
                    if destination.exists():
                        plugin.call("corpus.replay",{"folder":str(destination.resolve())})
                        print(json.dumps({"existingReplayed": name})); continue
                    result = record(plugin, source, "西游记", destination, "手写夹具；自拟内容", tags)
                    print(json.dumps({"id": name, **result}, ensure_ascii=False), flush=True)
            finally: server.shutdown()


if __name__ == "__main__":
    main()
