#!/usr/bin/env python3
"""TCP 连通性探测（e2e 冒烟脚本的就绪判断，避免依赖 HTTP 状态码语义）。"""
import socket
import sys

port = int(sys.argv[1])
host = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1"
s = socket.socket()
s.settimeout(0.5)
try:
    s.connect((host, port))
    sys.exit(0)
except Exception:
    sys.exit(1)
finally:
    s.close()
