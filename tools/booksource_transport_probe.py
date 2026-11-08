"""只读历史连接失败源，仅 DNS/TCP/TLS 探测；不发 HTTP、不加载规则或凭据。

每个唯一端点在独立子进程内探测，20 秒硬截止（含 DNS），最多并发 8。
输出仅分类计数；失败端点不等同整源已失效，成功握手不等同书源可用。
"""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import time
from urllib.parse import urlsplit


def probe(host, port, tls):
    try:
        addresses = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except socket.gaierror as error:
        return "dns_not_found" if error.errno in (socket.EAI_NONAME, 11001) else "dns_error"
    errors = []
    for family, kind, proto, _, address in addresses:
        try:
            with socket.socket(family, kind, proto) as connection:
                connection.settimeout(4)
                connection.connect(address)
                if tls:
                    with ssl.create_default_context().wrap_socket(connection, server_hostname=host):
                        return "tls_ok"
                return "tcp_ok"
        except ssl.SSLCertVerificationError as error:
            return {9: "certificate_not_yet_valid", 10: "certificate_expired",
                    18: "certificate_self_signed", 19: "certificate_self_signed",
                    62: "certificate_name", 64: "certificate_name"}.get(error.verify_code, "certificate_untrusted")
        except ssl.SSLError:
            errors.append("tls_error")
        except ConnectionRefusedError:
            errors.append("connection_refused")
        except TimeoutError:
            errors.append("timeout")
        except OSError:
            errors.append("connect_error")
    # 多地址失败不猜测单一原因；全部同类才使用该类。
    return errors[0] if errors and len(set(errors)) == 1 else "mixed_address_failure"


def isolated(endpoint):
    try:
        result = subprocess.run([sys.executable, "-X", "utf8", __file__, "--worker"],
                                input=json.dumps(endpoint), capture_output=True, text=True, timeout=20)
        return result.stdout.strip() if result.returncode == 0 else "probe_error"
    except subprocess.TimeoutExpired:
        return "timeout"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--collection", default="1315")
    args = parser.parse_args()
    if args.out.exists():
        raise SystemExit("输出已存在，请另选路径")
    raw = args.sources.read_bytes()
    endpoints = Counter()
    selected = skipped = 0
    for source in json.loads(raw):
        meta = source.get("easypub") or {}
        if args.collection not in str(meta.get("file", "")) or int(source.get("bookSourceType", 0)) != 0:
            continue
        if "连接失败" not in str((meta.get("check") or {}).get("error", "")):
            continue
        selected += 1
        try:
            url = urlsplit(source.get("bookSourceUrl", ""))
            if url.scheme not in ("http", "https") or not url.hostname:
                raise ValueError()
            endpoints[(url.hostname, url.port or (443 if url.scheme == "https" else 80), url.scheme == "https")] += 1
        except ValueError:
            skipped += 1
    started = time.monotonic()
    counts, weighted = Counter(), Counter()
    try:
        with ThreadPoolExecutor(max_workers=8) as pool:
            for endpoint, category in zip(endpoints, pool.map(isolated, endpoints)):
                counts[category] += 1
                weighted[category] += endpoints[endpoint]
        unchanged = args.sources.read_bytes() == raw
        if not unchanged:
            raise RuntimeError("源文件在运行期间发生变化；不生成有效证据")
        summary = {"selectedSources": selected, "skippedInvalidOrigin": skipped,
                   "uniqueEndpoints": len(endpoints), "endpointResults": dict(counts),
                   "sourceResults": dict(weighted), "seconds": round(time.monotonic()-started, 1),
                   "inputUnchanged": unchanged, "httpRequests": 0,
                   "scope": "historical connection failures; origin only; direct connection; no credentials"}
        with args.out.open("x", encoding="utf-8") as output:
            json.dump(summary, output, ensure_ascii=False, indent=2)
        print(json.dumps(summary, ensure_ascii=False))
    finally:
        # 不创建源文件副本、Cookie 罐或网页缓存。
        assert args.sources.read_bytes() == raw, "源文件在运行期间变化"


if __name__ == "__main__":
    if sys.argv[1:] == ["--worker"]:
        try:
            print(probe(*json.loads(sys.stdin.read())))
        except Exception:
            print("probe_error")
    else:
        main()
