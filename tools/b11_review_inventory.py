"""生成遗留依赖与错误出口静态审阅清单；不修改产品代码，不删除文件。"""
import argparse
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    lib = ROOT / "flutter/lib"
    package = re.search(r"^name:\s*(\S+)", (ROOT / "flutter/pubspec.yaml").read_text(encoding="utf-8"), re.M)[1]
    texts = {p.resolve(): p.read_text(encoding="utf-8") for base in (lib, ROOT / "flutter/test") for p in base.rglob("*.dart")}
    graph = {}
    for path, text in texts.items():
        dependencies = set()
        for match in re.finditer(r"(?:import|export|part)\s+([^;]+);", text):
            for target in re.findall(r"['\"]([^'\"]+\.dart)['\"]", match[1]):
                if target.startswith(f"package:{package}/"):
                    resolved = lib / target.split("/", 1)[1]
                elif ":" not in target:
                    resolved = path.parent / target
                else:
                    continue
                dependencies.add(resolved.resolve())
        graph[path] = dependencies
    def reachable(roots):
        visited = set()
        stack = list(roots)
        while stack:
            path = stack.pop()
            if path not in visited:
                visited.add(path)
                stack.extend(graph.get(path, ()))
        return visited
    production = reachable([(lib / "frontend_rewrite_main.dart").resolve()])
    tests = reachable([p for p in texts if "test" in p.relative_to(ROOT).parts])
    candidates = []
    for path in sorted(texts):
        relative = path.relative_to(ROOT).as_posix()
        if relative.startswith("flutter/lib/") and ("/prototype/" in relative or path.name.startswith("legacy_")) and path not in production:
            candidates.append({"path": relative, "test_reachable": path in tests,
                "direct_users": [p.relative_to(ROOT).as_posix() for p, deps in graph.items() if path in deps]})
    errors = []
    for base, suffix, pattern in [(ROOT / "rust/crates", "*.rs", r"ApiError::new\s*\("),
                                  (lib, "*.dart", r"throw\s+(?:const\s+)?(?:FormatException|\w*Exception)\s*\(")]:
        for path in sorted(base.rglob(suffix)):
            if "desk" in path.parts or "generated" in path.name:
                continue
            text = path.read_text(encoding="utf-8")
            for match in re.finditer(pattern, text):
                end = text.find(";", match.start())
                errors.append({"path": path.relative_to(ROOT).as_posix(),
                    "line": text.count("\n", 0, match.start()) + 1,
                    "snippet": text[match.start():min(end + 1 if end >= 0 else len(text), match.start() + 600)]})
    report = {"production_entry": "flutter/lib/frontend_rewrite_main.dart", "production_reachable_files": len(production),
              "deletion_executed": False, "legacy_candidates": candidates, "error_constructor_sites": errors,
              "limits": "静态 import/export/part 闭包；非删除证明。错误清单含测试及动态参数，需人工检查，非所有运行时错误穷举。"}
    args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"legacy_candidates": candidates, "error_sites": len(errors)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
