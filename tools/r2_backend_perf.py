"""R2 合成样本测量：100 MiB 导入/取消、1000 与 10000 章编辑。不读用户书库。"""
import argparse
import ctypes
import hashlib
import json
import subprocess
import time
from datetime import datetime
from pathlib import Path


class MemoryCounters(ctypes.Structure):
    _fields_ = [("cb", ctypes.c_ulong), ("PageFaultCount", ctypes.c_ulong)] + [
        (name, ctypes.c_size_t) for name in (
            "PeakWorkingSetSize", "WorkingSetSize", "QuotaPeakPagedPoolUsage",
            "QuotaPagedPoolUsage", "QuotaPeakNonPagedPoolUsage", "QuotaNonPagedPoolUsage",
            "PagefileUsage", "PeakPagefileUsage")]


def digest_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, default=Path("target/release/examples/r2_backend_perf.exe"))
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    out = args.out or Path("artifacts") / ("r2-backend-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
    out = out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    for count in (1000, 10000):
        with (out / f"chapters-{count}.txt").open("w", encoding="utf-8", newline="\n") as stream:
            for index in range(1, count + 1):
                stream.write(f"第{index}章 样本\n第一行正文。\n第二行正文。\n第三行正文。\n")
    large = out / "100MiB.txt"
    block = ("第一章 样本\n" + "合成测量正文，不含个人资料。\n" * 1024).encode()
    with large.open("wb") as stream:
        while stream.tell() + len(block) <= 100 * 1024 * 1024:
            stream.write(block)
        stream.write(b" " * (100 * 1024 * 1024 - stream.tell()))
    counters = ctypes.WinDLL("psapi").GetProcessMemoryInfo
    counters.argtypes = [ctypes.c_void_p, ctypes.POINTER(MemoryCounters), ctypes.c_ulong]
    counters.restype = ctypes.c_int
    reports = []
    for mode, source in [("import", large), ("cancel", large)] + [
        ("chapters", out / f"chapters-{count}.txt") for count in (1000, 10000)
    ]:
        digest = digest_file(source)
        report = out / f"{mode}-{source.stem}.json"
        peak = 0
        with report.open("w", encoding="utf-8") as stdout, report.with_suffix(".stderr").open("w") as stderr:
            process = subprocess.Popen([str(args.exe.resolve()), mode, str(source)], stdout=stdout, stderr=stderr)
            started = time.monotonic()
            while process.poll() is None:
                memory = MemoryCounters()
                memory.cb = ctypes.sizeof(memory)
                if counters(int(process._handle), ctypes.byref(memory), memory.cb):
                    peak = max(peak, memory.PeakWorkingSetSize)
                if time.monotonic() - started > 240:
                    process.kill()
                    process.wait()
                    raise TimeoutError(mode)
                time.sleep(.01)
        if process.returncode:
            raise RuntimeError(f"{mode} failed, see {report.with_suffix('.stderr')}")
        assert digest_file(source) == digest, "source changed"
        data = json.loads(report.read_text(encoding="utf-8"))
        data.update(peak_working_set_bytes=peak, source_bytes=source.stat().st_size, source_sha256=digest)
        report.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        reports.append({"report":str(report), "peak_working_set_bytes":peak})
        print(report, flush=True)
    (out / "summary.json").write_text(json.dumps(reports, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
