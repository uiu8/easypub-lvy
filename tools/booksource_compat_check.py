"""V102：只读源文件，在隔离插件目录重跑指定集合；只输出分类计数。

运行需要用户授权访问真实站点；默认 concurrency=8，每源沿用插件 40 秒预算。
"""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import tempfile
import time

from booksource_perf import Plugin


def bucket(check):
    if check.get("ok"):
        return "通过"
    error = check.get("error", "")
    for phrase, label in [("暂只支持文字", "非文字"), ("没有搜索结果", "无搜索结果"),
                          ("没有解析到目录", "无目录"), ("连接失败", "连接失败"),
                          ("超时", "超时"), ("页面不存在", "页面不存在"),
                          ("需要验证", "需要验证"), ("需要网页验证", "需要验证"),
                          ("拒绝访问", "拒绝访问"), ("网站错误", "网站错误"),
                          ("正文", "正文相关失败")]:
        if phrase in error:
            return label
    cause = check.get("cause")
    return {"unsupported": "未支持接口", "connection": "连接失败", "timeout": "超时",
            "not_found": "页面不存在", "challenge": "需要验证", "forbidden": "拒绝访问",
            "server": "网站错误", "rule": "规则失败", "cancelled": "取消"}.get(cause, "其他或未校验")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--collection", default="1315")
    parser.add_argument("--concurrency", type=int, default=8)
    args = parser.parse_args()
    if args.out.exists():
        raise SystemExit("输出已存在，请另选路径，避免覆盖输入或旧证据")
    raw = args.sources.read_bytes()
    sources = [s for s in json.loads(raw) if args.collection in str(s.get("easypub", {}).get("file", ""))]
    if not sources:
        raise SystemExit("没有匹配集合")
    before = Counter("非文字" if int(s.get("bookSourceType", 0)) != 0
                     else bucket(s.get("easypub", {}).get("check") or {}) for s in sources)
    results, kinds, stages, interfaces = Counter(), Counter(), Counter(), Counter()
    completed = 0
    started = time.monotonic()
    original_local = os.environ.get("LOCALAPPDATA")
    original_window = os.environ.get("EASYPUB_WINDOW_STATE")
    try:
        with tempfile.TemporaryDirectory(prefix="easypub-v102-check-") as td:
            folder = Path(td)
            os.environ["LOCALAPPDATA"] = str(folder / "local")
            os.environ["EASYPUB_WINDOW_STATE"] = "v102-isolated-check"
            with Plugin(args.binary.resolve(), folder / "data") as plugin:
                # 每条独立来源，避免同 URL 不同名称在导入时相互覆盖。
                for index, source in enumerate(sources):
                    copy = {k: v for k, v in source.items() if k not in ("easypub", "loginInfo", "loginData", "variable")}
                    plugin.call("__import_body", {"text": json.dumps([copy]), "file": f"isolated-{index}"})
                entries = plugin.call("sources.list")
                assert len(entries) == len(sources), "隔离导入数量不一致"
                text_ids = [s["id"] for s in entries if s["supported"]]
                nontext = len(entries) - len(text_ids)
                results["非文字"] = nontext

                def event(_stamp, value):
                    nonlocal completed
                    if value.get("event") != "check.result":
                        return
                    completed += 1
                    results[bucket(value)] += 1
                    kinds[str(value.get("cause"))] += 1
                    stages[str(value.get("stage"))] += 1
                    name = value.get("unsupportedInterface")
                    if name:
                        interfaces[name] += 1
                    if completed % 25 == 0:
                        print(json.dumps({"done": completed, "total": len(text_ids), "results": dict(results)}, ensure_ascii=False), flush=True)

                plugin.call("sources.check", {"ids": text_ids, "concurrency": args.concurrency},
                            timeout=7200, event=event)
                assert completed == len(text_ids), "校验结果数量不一致"
    finally:
        if original_local is None:
            os.environ.pop("LOCALAPPDATA", None)
        else:
            os.environ["LOCALAPPDATA"] = original_local
        if original_window is None:
            os.environ.pop("EASYPUB_WINDOW_STATE", None)
        else:
            os.environ["EASYPUB_WINDOW_STATE"] = original_window
        assert args.sources.read_bytes() == raw, "用户源文件发生变化"
    report = {"sources": len(sources), "textChecked": completed, "concurrency": args.concurrency,
              "elapsedSeconds": round(time.monotonic() - started),
              "before": dict(before), "after": dict(results), "causes": dict(kinds), "stages": dict(stages),
              "interfaces": dict(interfaces), "inputUnchanged": True, "temporaryDataRemoved": True,
              "binarySha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
              "limits": "旧记录不是同刻同环境对照；无登录状态，默认校验词，最多三个免费章节；非文字不执行"}
    args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    main()
