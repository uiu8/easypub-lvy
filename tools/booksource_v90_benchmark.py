"""V90 三版本真实站点对照；目录固定，冷缓存，轮前静默 30 秒，不改系统网络设置。

旧二进制没有 HTTP 请求计数接口，分别保存可观察的章节尝试数与缺测原因，不混称精确 HTTP 数。
"""
from __future__ import annotations
import argparse
from collections import Counter
import ctypes
from ctypes import wintypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import queue
import shutil
import time
from urllib.parse import urlsplit

spec=importlib.util.spec_from_file_location("corpus",Path(__file__).with_name("booksource_corpus.py"))
corpus=importlib.util.module_from_spec(spec);spec.loader.exec_module(corpus)
ROOT=Path(__file__).resolve().parents[1]
V88=ROOT/"artifacts/release/easypub-lvy-v88-20261019-win-x64/plugins/booksource/easypub_plugin_booksource.exe"
NOVEL2=ROOT/"artifacts/release/easypub-lvy-v89-20261020-novel2-win-x64/plugins/booksource/easypub_plugin_booksource.exe"

def emit(args,v):
    print(json.dumps(v,ensure_ascii=False),flush=True)
    with (args.work/"measurements.jsonl").open("a",encoding="utf-8") as f:f.write(json.dumps(v,ensure_ascii=False)+"\n")

def configure(p,version):
    if version!="V88":p.call("network.proxy.set",{"config":{"mode":"system","scope":"all","bypassLocal":True}})

def prepare(args):
    data=json.loads(args.sources.read_text(encoding="utf-8"))
    # 选候选只用既有全链校验，不按本轮吞吐挑赢家。优先已有现场书源，随后按旧延迟。
    good=[s for s in data if (s.get("easypub",{}).get("check") or {}).get("ok")]
    good.sort(key=lambda s:(not any(x in s["bookSourceName"] for x in ["天域","书斋阁","香书","笔趣阁","笔趣阁5200"]),
                            s.get("easypub",{}).get("check",{}).get("ms",999999)))
    selected=[];hosts=set()
    for s in good:
        host=urlsplit(s["bookSourceUrl"].strip()).hostname
        if host in hosts or s.get("html") or s.get("mainJs"):continue
        hosts.add(host);selected.append(s)
        if len(selected)>=70:break
    corpus.dump(args.work/"sources.json",selected)
    plans=[]
    with corpus.perf.Plugin(args.candidate,args.work/"prepare-data") as p:
        configure(p,"V90")
        p.call("sources.import",{"path":str((args.work/"sources.json").resolve())})
        listed={s["id"]:s for s in p.call("sources.list")}
        for title in args.books:
            found=p.call("search",{"key":title,"skipUnhealthy":False,"includeWebView":False,"concurrency":16},timeout=180)
            sources=[s for b in found.get("results",[]) if b["name"]==title for s in b["sources"]]
            sources.sort(key=lambda s:s["ms"])
            checked=[]
            for s in sources[:20]:
                try:
                    book=p.call("book.info",{"sourceId":s["sourceId"],"book":s["book"]},timeout=90)
                    toc=p.call("book.toc",{"sourceId":s["sourceId"],"book":book},timeout=120)
                    free=[c for c in toc if not c["isVolume"] and not c["isPay"] and not c["isVip"]]
                    if len(free)<125:continue
                    item={"source":listed[s["sourceId"]],"book":book,"toc":free[:125],"fullCount":len(toc)}
                    for other in checked:
                        alignment=p.call("download.diagnose",{"toc":other["toc"][:120],"otherToc":item["toc"][:120]})["alignment"]
                        if alignment["independentSites"] and alignment["equivalent"] and other["book"]["author"]==book["author"]:
                            plans.append({"title":title,"primary":other,"alternate":item,"alignment":alignment})
                            break
                    if len(plans)>0 and plans[-1]["title"]==title:break
                    checked.append(item)
                except (RuntimeError,queue.Empty) as e:emit(args,{"kind":"candidate-error","book":title,"source":s["sourceName"],"error":str(e)})
            corpus.dump(args.work/f"candidates-{len(plans)}.json",checked)
            emit(args,{"kind":"plan","book":title,"ready":bool(plans and plans[-1]["title"]==title),"matches":len(sources)})
    corpus.dump(args.work/"plans.json",plans)
    if len(plans)<2:raise RuntimeError("未获得两本书的双站目录，保留候选证据后补充来源")

class Memory(ctypes.Structure):
    _fields_=[("cb",wintypes.DWORD),("PageFaultCount",wintypes.DWORD)]+[(s,ctypes.c_size_t) for s in
        ["PeakWorkingSetSize","WorkingSetSize","QuotaPeakPagedPoolUsage","QuotaPagedPoolUsage","QuotaPeakNonPagedPoolUsage","QuotaNonPagedPoolUsage","PagefileUsage","PeakPagefileUsage"]]

def peak(pid):
    kernel=ctypes.WinDLL("kernel32",use_last_error=True)
    kernel.OpenProcess.restype=wintypes.HANDLE
    kernel.CloseHandle.argtypes=[wintypes.HANDLE]
    psapi=ctypes.WinDLL("psapi",use_last_error=True)
    psapi.GetProcessMemoryInfo.argtypes=[wintypes.HANDLE,ctypes.POINTER(Memory),wintypes.DWORD]
    h=kernel.OpenProcess(0x410,False,pid)
    try:
        m=Memory();m.cb=ctypes.sizeof(m)
        return m.PeakWorkingSetSize if h and psapi.GetProcessMemoryInfo(h,ctypes.byref(m),m.cb) else None
    finally:
        if h:kernel.CloseHandle(h)

def cause(f):
    if f.get("cause"):return f["cause"]
    r=f.get("reason","")
    if any(x in r for x in ["登录","验证"]):return "verification"
    if any(x in r for x in ["连接","超时","DNS","代理"]):return "network"
    if any(x in r for x in ["不支持","尚未适配"]):return "unsupported"
    if any(x in r for x in ["限流","占位","暂缺","过短","网站","页面不存在"]):return "site"
    return "rule"

def measure(args,exe,version,plan,scene,index,seed=None):
    run=args.work/f"{index:02}-{scene}-{version}"
    run.mkdir()
    primary=plan["primary"];alt=plan["alternate"]
    if seed is not None:
        shutil.copytree(seed/"downloads",run/"downloads")
    emit(args,{"kind":"idle","version":version,"scene":scene,"book":plan["title"],"seconds":30})
    time.sleep(30)
    with corpus.perf.Plugin(exe,run/"data") as p:
        configure(p,version)
        p.call("sources.import",{"path":str((args.work/"sources.json").resolve())})
        old=scene=="update"
        toc=primary["toc"][:125 if old else 120]
        options={"folder":str((run/"downloads").resolve()),"threads":16,"from":1,"to":len(toc),"multiSource":scene=="multi","maxAlternates":1}
        if old:options["preserveExisting"]=True
        start=time.monotonic()
        request={"sourceId":primary["source"]["id"],"book":primary["book"],"toc":toc,"options":options,
                 "alternates":[{"sourceId":alt["source"]["id"],"book":alt["book"],"toc":alt["toc"][:120]}] if scene=="multi" else []}
        corpus.dump(run/"request.json",request)
        task=p.call("download.start",request)["taskId"]
        attempts={};hosts={};out=None;source_count=1
        until=start+1200
        while out is None:
            try:_,event=p.events.pop(0) if p.events else p.lines.get(timeout=max(.01,until-time.monotonic()))
            except queue.Empty:
                p.call("download.cancel",{"taskId":task})
                raise RuntimeError("本轮超时，保留任务记录")
            if event.get("taskId")!=task:continue
            if event.get("event")=="download.progress":
                progress=event["progress"];c=progress.get("chapter")
                if c:attempts[c["index"]]=max(attempts.get(c["index"],0),c.get("attempts",0))
                source_count=max(source_count,progress.get("sourceCount",1))
                for h in progress.get("hosts",[]):hosts[h["host"]]=h
            if event.get("event")=="download.done":
                if event.get("error"):raise RuntimeError(event["error"])
                out=event["result"]["outcome"]
        seconds=time.monotonic()-start
        new_success=out["chapters"]-len(out["failures"])-out["fromCache"]
        changed=len(toc)-out["fromCache"]
        record={"kind":"measurement","version":version,"sha256":corpus.perf.sha(exe),"book":plan["title"],"scene":scene,
                "directorySnapshotSha256":hashlib.sha256(json.dumps(toc,sort_keys=True,ensure_ascii=False).encode()).hexdigest(),
                "requested":changed,"success":new_success,"failed":len(out["failures"]),"failureCauses":dict(Counter(cause(f) for f in out["failures"])),
                "seconds":round(seconds,3),"chaptersPerSecond":round(new_success/seconds,6),"fromCache":out["fromCache"],
                "chapterAttempts":sum(attempts.values()) or None,
                "attemptsByChapter":attempts,"httpRequests":None,
                "httpRequestNote":"固定旧插件无精确 HTTP 计数接口；章节尝试不含重定向和分页，不将其冒充 HTTP 次数。",
                "peakWorkingSetBytes":peak(p.p.pid),"sourceCount":source_count,"hosts":list(hosts.values()),"result":out,
                "route":"V88 使用原请求栈的环境代理；novel2/V90 在隔离数据目录设 system；系统网络未改变"}
        corpus.dump(run/"result.json",record);emit(args,record)
        return run

def run(args):
    plans=json.loads((args.work/"plans.json").read_text(encoding="utf8"))
    variants=[("V88",V88),("novel2",NOVEL2),("V90",args.candidate)]
    assert corpus.perf.sha(V88).startswith("e91deb01") and corpus.perf.sha(NOVEL2).startswith("a664a898")
    corpus.dump(args.work/"versions.json",{v:{"path":str(exe),"sha256":corpus.perf.sha(exe)} for v,exe in variants})
    index=0
    for book_index,plan in enumerate(plans):
        seeds={}
        order=variants[book_index:]+variants[:book_index]
        for scene in ["single","multi","update"]:
            for version,exe in order:
                index+=1
                folder=measure(args,exe,version,plan,scene,index,seeds.get(version) if scene=="update" else None)
                if scene=="single":seeds[version]=folder

if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("mode",choices=["prepare","run"])
    p.add_argument("--candidate",type=Path,required=True)
    p.add_argument("--work",type=Path,required=True)
    p.add_argument("--sources",type=Path,default=ROOT/"artifacts/yckceo-check-fixed-20261020/data/sources.json")
    p.add_argument("--books",nargs="+",default=["斗破苍穹","凡人修仙传"])
    a=p.parse_args();a.work=a.work.resolve();a.work.mkdir(parents=True,exist_ok=True)
    (prepare if a.mode=="prepare" else run)(a)
