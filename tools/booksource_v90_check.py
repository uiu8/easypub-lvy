"""V90 插件进程级夹具：订阅事务、设置保留、回退、重启、翻页和局部重试。"""
from __future__ import annotations
import argparse
import copy
import importlib.util
import json
from pathlib import Path
import threading
import time
from http.server import ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

spec=importlib.util.spec_from_file_location("corpus",Path(__file__).with_name("booksource_corpus.py"))
corpus=importlib.util.module_from_spec(spec)
spec.loader.exec_module(corpus)

class Handler(corpus.Fixture):
    version=1
    failures=0
    requests=[]
    def do_GET(self):
        path=urlsplit(self.path).path
        Handler.requests.append(path)
        if path=="/subscription":
            base=f"http://127.0.0.1:{self.server.server_port}"
            sources=[]
            for name in (["a","b","c"] if Handler.version==1 else ["a","b","d"]):
                s=copy.deepcopy(next(corpus.manual_sources(base))[1])
                s.update({"bookSourceUrl":base+"#"+name,"bookSourceName":name,"bookSourceGroup":"供应商分组"})
                s["ruleSearch"]["checkKeyWord"]="西游记"
                if Handler.version==2:
                    if name=="a":s["bookSourceName"]="新版 a"
                    if name=="b":s["ruleContent"]["content"]=".missing@text"
                sources.append(s)
            data=json.dumps(sources,ensure_ascii=False).encode()
            self.send_response(200);self.send_header("Content-Length",str(len(data)))
            self.end_headers();self.wfile.write(data);return
        if path.startswith("/pages/"):
            kind=path.rsplit("/",1)[-1]
            page=int(parse_qs(urlsplit(self.path).query).get("page",["1"])[0])
            if kind=="fail" and Handler.failures==0:
                Handler.failures+=1
                self.send_response(503);self.end_headers();return
            if kind=="slow":time.sleep(.8)
            data=[] if (kind=="many" and page>3) else [{"name":f"样书 {page if kind=='many' else 1}","author":"作者","url":f"/book/{page if kind=='many' else 1}"}]
            body=json.dumps(data,ensure_ascii=False).encode()
            self.send_response(200);self.send_header("Content-Length",str(len(body)));self.end_headers();self.wfile.write(body);return
        super().do_GET()


def run(args):
    args.output.mkdir(parents=True,exist_ok=False)
    server=ThreadingHTTPServer(("127.0.0.1",0),Handler)
    server.daemon_threads=True
    threading.Thread(target=server.serve_forever,daemon=True).start()
    base=f"http://127.0.0.1:{server.server_port}";url=base+"/subscription"
    report={"pluginSha256":corpus.perf.sha(args.exe)}
    try:
        with corpus.perf.Plugin(args.exe,args.output/"data") as p:
            p.call("sources.importUrl",{"url":url})
            initial=p.call("subscriptions.list")[0]
            assert not initial["startup"] and initial["days"]==0
            ids=[base+"#"+s for s in ["a","b","c"]]
            p.call("sources.check",{"ids":ids,"key":"西游记","concurrency":1})
            checked=p.call("sources.list")
            assert all(s["check"]["ok"] for s in checked), checked
            p.call("sources.pin",{"ids":ids[:2],"pinned":True})
            p.call("sources.rate",{"id":ids[0],"rating":2})
            p.call("sources.crawlProfile.set",{"id":ids[0],"profile":{"concurrency":3,"proxyMode":"direct"}})
            p.call("sources.setEnabledMany",{"ids":[ids[0]],"enabled":False})
            before=json.loads((args.output/"data/sources.json").read_text(encoding="utf-8"))
            Handler.version=2
            preview=p.call("subscriptions.preview",{"url":url})
            diff=preview["preview"]["diff"]
            assert [len(diff[k]) for k in ["added","removed","changed"]]==[1,1,2], diff
            assert p.call("sources.list")==checked or json.loads((args.output/"data/sources.json").read_text(encoding="utf-8"))==before
            applied=p.call("subscriptions.apply",{"url":url,"previewId":preview["preview"]["id"]})
            assert [x["id"] for x in applied["reverted"]]==[ids[1]], applied
            after=json.loads((args.output/"data/sources.json").read_text(encoding="utf-8"))
            old=next(s for s in before if s["bookSourceUrl"]==ids[0])
            new=next(s for s in after if s["bookSourceUrl"]==ids[0])
            for key in ["enabled","customOrder","weight","bookSourceGroup"]:
                assert old[key]==new[key],key
            for key in ["pinned","rating","crawl","health"]:
                assert old["easypub"][key]==new["easypub"][key],key
            assert next(s for s in after if s["bookSourceUrl"]==ids[1])["ruleContent"]==next(s for s in before if s["bookSourceUrl"]==ids[1])["ruleContent"]
            p.call("subscriptions.configure",{"url":url,"startup":False,"days":7})
            report["subscription"]={"diff":diff,"reverted":applied["reverted"],"settingsPreserved":True}
        with corpus.perf.Plugin(args.exe,args.output/"data") as p:
            persisted=p.call("subscriptions.list")[0]
            assert len(persisted["versions"])==2 and persisted["days"]==7
            p.call("subscriptions.rollback",{"url":url})
            restored=p.call("sources.list")
            assert sorted(s["name"] for s in restored)==["a","b","c"]
            assert next(s for s in restored if s["id"]==ids[0])["rating"]==2
            report["subscription"].update({"restart":True,"manualRollback":True})
        with corpus.perf.Plugin(args.exe,args.output/"local-data") as p:
            local=args.output/"local-source.json"
            source={"bookSourceUrl":base+"#local","bookSourceName":"本地旧规则",
                    "searchUrl":"/pages/one?page={{page}}",
                    "ruleSearch":{"bookList":"$","name":"$.name","bookUrl":"$.url"},
                    "ruleContent":{"content":"#content@text"}}
            corpus.dump(local,[source])
            p.call("sources.import",{"path":str(local.resolve())})
            corpus.dump(local,[{**source,"bookSourceName":"本地新规则"}])
            preview=p.call("sources.updateFile",{"file":str(local.resolve())})
            assert p.call("sources.list")[0]["name"]=="本地旧规则"
            assert preview["preview"]["diff"]["changed"][0]["fields"]==["bookSourceName"]
            p.call("subscriptions.apply",{"url":str(local.resolve()),"previewId":preview["preview"]["id"]})
            assert p.call("sources.list")[0]["name"]=="本地新规则"
            p.call("subscriptions.rollback",{"url":str(local.resolve())})
            assert p.call("sources.list")[0]["name"]=="本地旧规则"
            report["localFile"]={"preview":True,"confirm":True,"rollback":True}
        with corpus.perf.Plugin(args.exe,args.output/"pages") as p:
            sources=[{"bookSourceUrl":base+"#"+kind,"bookSourceName":kind,
                      "searchUrl":"/pages/"+kind+"?page={{page}}",
                      "ruleSearch":{"bookList":"$","name":"$.name","author":"$.author","bookUrl":"$.url"},
                      "ruleContent":{"content":"#content@text"}} for kind in ["many","fail","one","slow"]]
            f=args.output/"pages.json";corpus.dump(f,sources)
            p.call("sources.import",{"path":str(f.resolve())})
            source_ids=[base+"#"+s for s in ["many","fail","one"]]
            first=p.call("search",{"key":"样书","sourceIds":source_ids,"searchId":"original","filterTitle":False,"skipUnhealthy":False})
            assert first["failed"]==1,first
            retried=p.call("search.retry",{"searchId":"original","sourceId":base+"#fail"})
            assert len(retried["results"])==1 and len(retried["results"][0]["sources"])==3,retried
            second=p.call("search.more",{"searchId":"original"})
            assert len(second["results"])==2,second
            third=p.call("search.more",{"searchId":"original"})
            assert len(third["results"])==3,third
            end=p.call("search.more",{"searchId":"original"})
            assert all(s["ended"] for s in end["pages"]),end
            assert Handler.requests.count("/pages/one")==2,Handler.requests
            serial=p.request("search",{"key":"样书","sourceIds":[base+"#slow"],"searchId":"cancel","filterTitle":False})
            time.sleep(.15)
            p.call("search.cancel",{"searchId":"cancel"})
            deadline=time.monotonic()+4
            while True:
                _,item=p.lines.get(timeout=max(.01,deadline-time.monotonic()))
                if item.get("id")==serial:
                    assert item["result"]["cancelled"];break
            new=p.call("search",{"key":"样书","sourceIds":[base+"#one"],"searchId":"new","filterTitle":False})
            try:p.call("search.more",{"searchId":"original"})
            except RuntimeError as e:assert "过期" in str(e)
            else:raise AssertionError("旧搜索不能继续")
            report["search"]={"threePages":True,"retryOne":True,"repeatedPageStopped":True,"cancel":True,"staleSession":True}
        corpus.dump(args.output/"result.json",report)
        print(json.dumps(report,ensure_ascii=False),flush=True)
    finally:server.shutdown()

if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe",type=Path,required=True)
    parser.add_argument("--output",type=Path,required=True)
    run(parser.parse_args())
