"""只读统计书源中的 Java 类/调用写法；不输出书源名、地址、常量或脚本。"""
import argparse
from collections import Counter
import json
from pathlib import Path
import re

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('files', nargs='+', type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    reports = []
    pattern = re.compile(r'\b(?:Packages\.)?((?:java|javax|android)\.(?:[A-Za-z_$][\w$]*\.)*[A-Za-z_$][\w$]*)')
    for index, path in enumerate(args.files):
        data = json.loads(path.read_text(encoding='utf-8-sig'))
        sources = data if isinstance(data, list) else [data]
        calls, hits = Counter(), Counter()
        for source in sources:
            # 仅输出已知命名空间的标识符，不输出字面量、参数、URL 或名称。
            code = json.dumps({k:v for k,v in source.items() if k in ('jsLib','mainJs','searchUrl','exploreUrl','loginUrl','loginCheckJs','loginAction') or k.startswith('rule')}, ensure_ascii=False)
            names = pattern.findall(code)
            calls.update(names)
            hits.update(set(names))
        reports.append({'input_index':index,'sources':len(sources),'syntax_mentions':calls.most_common(), 'source_hits':hits.most_common(),
                        'limits':'词法命中包含注释与字符串，不等于可执行调用；禁止据此放宽校验'})
    args.out.write_text(json.dumps(reports, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps([{'input_index':r['input_index'],'sources':r['sources'],'distinct_syntax':len(r['source_hits'])} for r in reports]))

if __name__ == '__main__':
    main()
