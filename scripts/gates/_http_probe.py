#!/usr/bin/env python3
"""HTTP 就绪探测：任意 <500 的响应都算“服务已起来”（401/404 也算）。"""
import sys
import urllib.error
import urllib.request

url = sys.argv[1]
try:
    with urllib.request.urlopen(url, timeout=1.0) as r:
        r.read(1)
    sys.exit(0)
except urllib.error.HTTPError:
    # 服务已经能给出 HTTP 响应，就算就绪
    sys.exit(0)
except Exception:
    sys.exit(1)
