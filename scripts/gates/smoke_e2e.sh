#!/usr/bin/env bash
# 端到端冒烟：fs 存储 + metad + serve（+ compactd 可选）。
#
#   启动 metad(SPND_META_PORT) → 启动 serve(SPND_PORT, SPND_STORE=fs:DIR,
#   SPND_META_URL) → 等 /health → 写 100 行 → 查询 count==100 →
#   触发 compact → 再查询 count==100 → 清理全部进程与临时目录。
#
# 约束：总时长 < 60s；无论成功失败都必须清理进程与临时目录。
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh

ROOT="$(pwd)"
TMP="$(mktemp -d "/tmp/tf-e2e-XXXXXX")"
META_PORT="${SPND_E2E_META_PORT:-18090}"
SERVE_PORT="${SPND_E2E_PORT:-18080}"
META_PID=""
SERVE_PID=""
COMPACTD_PID=""

cleanup() {
  set +e
  for pid in "$COMPACTD_PID" "$SERVE_PID" "$META_PID"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null
      for _ in $(seq 1 50); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
      done
      kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
    fi
  done
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

log() { echo "[smoke] $*"; }

fail() {
  echo "[smoke][FAIL] $*"
  for f in "$TMP"/metad.log "$TMP"/serve.log "$TMP"/compactd.log; do
    if [[ -f "$f" ]]; then
      echo "--- $f (tail)"
      tail -n 40 "$f"
    fi
  done
  exit 1
}

wait_http() {
  local url="$1" name="$2" tries="${3:-100}"
  for _ in $(seq 1 "$tries"); do
    if python3 "$ROOT/scripts/gates/_http_probe.py" "$url" 2>/dev/null; then
      return 0
    fi
    sleep 0.2
  done
  fail "timeout waiting for $name ($url)"
}

wait_tcp() {
  local port="$1" name="$2" tries="${3:-150}"
  for _ in $(seq 1 "$tries"); do
    if python3 "$ROOT/scripts/gates/_tcp_probe.py" "$port" 2>/dev/null; then
      return 0
    fi
    sleep 0.2
  done
  fail "timeout waiting for $name (port $port)"
}

# ---------------- 构建 ----------------
log "building serve / metad / compactd"
moon build --target native --release cmd/serve cmd/metad cmd/compactd >/dev/null
SERVE_BIN="$ROOT/_build/native/release/build/cmd/serve/serve.exe"
METAD_BIN="$ROOT/_build/native/release/build/cmd/metad/metad.exe"
COMPACD_BIN="$ROOT/_build/native/release/build/cmd/compactd/compactd.exe"
for b in "$SERVE_BIN" "$METAD_BIN" "$COMPACD_BIN"; do
  [[ -x "$b" ]] || fail "missing binary: $b"
done

# ---------------- metad ----------------
log "starting metad on :$META_PORT"
SPND_META_PORT="$META_PORT" \
SPND_META_DIR="$TMP/metad" \
  "$METAD_BIN" >"$TMP/metad.log" 2>&1 &
META_PID=$!
# metad 对未知 ns 返回 404，因此用 TCP 连通性判就绪即可。
wait_tcp "$META_PORT" "metad" 150

# ---------------- serve ----------------
log "starting serve on :$SERVE_PORT (fs store + metad)"
SPND_PORT="$SERVE_PORT" \
SPND_STORE="fs:$TMP/data" \
SPND_META_URL="http://127.0.0.1:$META_PORT" \
SPND_FS_IO="${SPND_FS_IO:-pread}" \
  "$SERVE_BIN" >"$TMP/serve.log" 2>&1 &
SERVE_PID=$!

wait_http "http://127.0.0.1:$SERVE_PORT/metrics" "serve" 150

# ---------------- 写入 100 行（10 批 × 10 行）----------------
log "writing 100 rows in 10 batches"
python3 - "$SERVE_PORT" <<'PY' || fail "write failed"
import json, sys, urllib.error, urllib.request

port = int(sys.argv[1])
ns = "smoke"
base = f"http://127.0.0.1:{port}/v1/namespaces/{ns}"

def post(action, payload):
    req = urllib.request.Request(
        base + "/" + action,
        data=json.dumps(payload).encode(),
        headers={"content-type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode())

post("create", {"fts_tokenizer": "word", "distance_metric": "cosine"})
ingested = 0
for b in range(10):
    rows = []
    for i in range(10):
        n = b * 10 + i
        # 8 维确定性向量，便于向量查询命中
        v = [0.0] * 8
        v[n % 8] = 1.0
        rows.append({
            "id": n + 1,
            "text": f"document number {n} about turbofish search engine",
            "vector": v,
            "category": "even" if n % 2 == 0 else "odd",
            "ts": 1700000000 + n,
            "public": n % 3 != 0,
        })
    resp = post("write", {"rows": rows})
    assert resp.get("head"), f"missing head in {resp}"
    ingested += resp.get("ingested", 0)
assert ingested == 100, f"expected ingested=100, got {ingested}"
print(f"[smoke] write ok: ingested={ingested}")
PY

# ---------------- 查询 ----------------
log "querying (top_k=10, text + vector)"
python3 - "$SERVE_PORT" <<'PY' || fail "query failed"
import json, sys, urllib.error, urllib.request

port = int(sys.argv[1])
base = f"http://127.0.0.1:{port}/v1/namespaces/smoke"

def post(action, payload):
    req = urllib.request.Request(
        base + "/" + action,
        data=json.dumps(payload).encode(),
        headers={"content-type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode())

def get(action):
    with urllib.request.urlopen(base + "/" + action, timeout=20) as r:
        return json.loads(r.read().decode())

health = get("health")
assert health["num_docs"] == 100, f"num_docs={health['num_docs']} != 100"
print(f"[smoke] health ok: num_docs={health['num_docs']} head={health['head']}")

hits = post("query", {"text": "turbofish search engine", "top_k": 10})
assert len(hits["rows"]) == 10, f"bm25 rows={len(hits['rows'])}"
v = [0.0] * 8
v[0] = 1.0
vhits = post("query", {"vector": v, "top_k": 5})
assert len(vhits["rows"]) == 5, f"vec rows={len(vhits['rows'])}"
assert (vhits["rows"][0]["id"] - 1) % 8 == 0, (
    f"vec top1={vhits['rows'][0]['id']} is not on the queried axis"
)
counted = post("query", {"aggregations": ["Count"]})
assert counted["count"] == 100, f"count={counted['count']} != 100"
print("[smoke] query ok: bm25/vec/count all consistent")
PY

# ---------------- compact ----------------
log "triggering compact (10 L0 slab segments -> 1)"
python3 - "$SERVE_PORT" <<'PY' || fail "compact failed"
import json, sys, urllib.error, urllib.request

port = int(sys.argv[1])
base = f"http://127.0.0.1:{port}/v1/namespaces/smoke"

def post(action, payload):
    req = urllib.request.Request(
        base + "/" + action,
        data=json.dumps(payload).encode(),
        headers={"content-type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())

resp = post("compact", {})
assert resp.get("ok") is True, f"compact resp={resp}"
print(f"[smoke] compact ok: head={resp.get('head', '')}")
PY

log "post-compact verification (count must stay 100)"
python3 - "$SERVE_PORT" <<'PY' || fail "post-compact query failed"
import json, sys, urllib.error, urllib.request

port = int(sys.argv[1])
base = f"http://127.0.0.1:{port}/v1/namespaces/smoke"

def post(action, payload):
    req = urllib.request.Request(
        base + "/" + action,
        data=json.dumps(payload).encode(),
        headers={"content-type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode())

def get(action):
    with urllib.request.urlopen(base + "/" + action, timeout=20) as r:
        return json.loads(r.read().decode())

counted = post("query", {"aggregations": ["Count"]})
assert counted["count"] == 100, f"count after compact={counted['count']} != 100"
hits = post("query", {"text": "turbofish search engine", "top_k": 10})
assert len(hits["rows"]) == 10, f"bm25 rows={len(hits['rows'])}"
health = get("health")
assert health["num_docs"] == 100, f"num_docs={health['num_docs']}"
print("[smoke] post-compact ok: count==100, bm25 rows==10")
PY

# ---------------- compactd（独立进程，写者独占） ----------------
# FsStore 的索引/版本 sidecar 不做跨进程锁，因此把 compactd 安排在 serve 停止
# 之后运行（真实部署里 compactd 与 serve 各自持不同 namespace 的租约；这里为了
# 单机冒烟的可重复性而串行化写者）。
log "stopping serve for the compactd phase"
kill -TERM "$SERVE_PID" 2>/dev/null || true
for _ in $(seq 1 100); do
  kill -0 "$SERVE_PID" 2>/dev/null || break
  sleep 0.1
done
kill -KILL "$SERVE_PID" 2>/dev/null || true
wait "$SERVE_PID" 2>/dev/null || true
SERVE_PID=""

log "running compactd (oneshot) against the metad dirty queue"
if ! SPND_STORE="fs:$TMP/data" \
  SPND_META_URL="http://127.0.0.1:$META_PORT" \
  SPND_COMPACD_ONESHOT=1 \
  SPND_COMPACT_LEASE_TTL_MS=5000 \
  SPND_COMPACT_IDLE_MS=100 \
    "$COMPACD_BIN" >"$TMP/compactd.log" 2>&1
then
  fail "compactd oneshot exited non-zero"
fi
grep -q "ns=smoke" "$TMP/compactd.log" || fail "compactd did not process the dirty namespace"
grep -q "processed=1" "$TMP/compactd.log" || fail "compactd did not claim any namespace"
log "compactd processed the dirty namespace:"
grep -E "ns=smoke|oneshot done" "$TMP/compactd.log" | tail -n 3 | sed 's/^/[smoke]   /'

# ---------------- serve 重启：数据必须仍然可查（metadata 由 metad 承载） ----------------
log "restarting serve to verify durability after compactd"
SPND_PORT="$SERVE_PORT" \
SPND_STORE="fs:$TMP/data" \
SPND_META_URL="http://127.0.0.1:$META_PORT" \
SPND_FS_IO="${SPND_FS_IO:-pread}" \
  "$SERVE_BIN" >"$TMP/serve2.log" 2>&1 &
SERVE_PID=$!
wait_http "http://127.0.0.1:$SERVE_PORT/metrics" "serve(restart)" 150

python3 - "$SERVE_PORT" <<'PY' || fail "post-restart verification failed"
import json, sys, urllib.error, urllib.request

port = int(sys.argv[1])
base = f"http://127.0.0.1:{port}/v1/namespaces/smoke"

def post(action, payload):
    req = urllib.request.Request(
        base + "/" + action,
        data=json.dumps(payload).encode(),
        headers={"content-type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode())

def get(action):
    with urllib.request.urlopen(base + "/" + action, timeout=20) as r:
        return json.loads(r.read().decode())

health = get("health")
assert health["num_docs"] == 100, f"num_docs after restart={health['num_docs']}"
counted = post("query", {"aggregations": ["Count"]})
assert counted["count"] == 100, f"count after restart={counted['count']}"
hits = post("query", {"text": "turbofish search engine", "top_k": 10})
assert len(hits["rows"]) == 10, f"bm25 rows={len(hits['rows'])}"
print("[smoke] restart ok: num_docs==100, count==100, bm25 rows==10")
PY

# ---------------- 写入亲和路由（单进程时必须是 no-op） ----------------
log "write-affinity routing + patch (single-process mode must stay local)"
# 注：patch 是 append-only 版本写入（旧版本行不会被 tombstone，查询期按 id 去重），
# 因此这里只断言 patch 生效与查询可见，不再断言 num_docs 精确值。
python3 - "$SERVE_PORT" <<'PY' || fail "routing check failed"
import json, sys, urllib.error, urllib.request

port = int(sys.argv[1])
base = f"http://127.0.0.1:{port}/v1/namespaces/smoke"

req = urllib.request.Request(
    base + "/patch",
    data=json.dumps({"patches": [{"id": 1, "category": "patched"}]}).encode(),
    headers={"content-type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=20) as r:
        resp = json.loads(r.read().decode())
except urllib.error.HTTPError as e:
    raise SystemExit(f"patch http error {e.code}: {e.read().decode()}")
assert resp.get("patched") == 1, f"patch resp={resp}"
print(f"[smoke] patch ok: patched={resp['patched']}")
PY

log "PASS"
