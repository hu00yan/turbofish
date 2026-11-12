# turbofish-client (Python)

Minimal Python client for the **turbofish HTTP API v0** (JSON, no auth).
Single file, pure standard library (`urllib.request` + `json`) — zero dependencies.

## Contract v0 covered

| Method | HTTP | Path | Request body | Response |
|---|---|---|---|---|
| `create_namespace(ns, fts_tokenizer=None)` | POST | `/v1/namespaces/{ns}/create` | `{"fts_tokenizer": "word\|smartcn\|kuromoji\|nori"}` (可省略) | `{"ok": true, "ns": ...}` |
| `write(ns, rows, deletes=None)` | POST | `/v1/namespaces/{ns}/write` | `{"rows": [...], "deletes": [...]}` | `{"ingested": n, "head": ...}` |
| `batch_upsert(ns, rows, batch_size=1000)` / `upsert(...)` | POST (batch) | `/v1/namespaces/{ns}/write` | 分批写入 | `{"ingested": n, "head": ..., "batches": b}` |
| `batch_delete(ns, ids, batch_size=1000)` / `delete(...)` | POST (batch) | `/v1/namespaces/{ns}/write` | 分批删除 | `{"deleted": n, "head": ..., "batches": b}` |
| `query(ns, text=None, vector=None, top_k=10, nprobe=None, filter_category=None, attributes=None)` | POST | `/v1/namespaces/{ns}/query` | `{"text", "vector", "top_k", "nprobe", "filter_category", "attributes"}` | `{"rows": [...], "count": n}` |
| `hybrid_search(ns, text, vector, top_k=10, nprobe=None, filter_category=None, attributes=None)` | POST | `/v1/namespaces/{ns}/query` | 混合检索与属性投影 | `{"rows": [...], "count": n}` |
| `health(ns)` | GET | `/v1/namespaces/{ns}/health` | — | `{"ns", "num_docs", "head", "fts_tokenizer"}` |

A row is `{"id": <uint64>, "text": str, "vector": [f32...], "category": str,
"ts": <int64>, "public": bool}`. Field names are passed through verbatim; the
server validates them. Query results return enriched attributes (`id`, `score`, `text`,
`category`, `ts`, `public`), and `attributes` parameter controls field projection.

## 5 分钟上手

```bash
# From the repo root: editable install (or just copy turbofish_client.py next to your code)
pip install -e sdk/python
```

```python
from turbofish_client import TurboFishClient, TurboFishError

client = TurboFishClient("http://127.0.0.1:8080", timeout=10)

# 1. create a namespace with a Japanese FTS tokenizer
client.create_namespace("demo", fts_tokenizer="kuromoji")

# 2. batch upsert rows (4-dim vectors in this example)
client.batch_upsert("demo", rows=[
    {"id": 1, "text": "今日は寿司を食べました", "vector": [1.0, 0.0, 0.0, 0.0],
     "category": "food", "ts": 1700000000, "public": True},
    {"id": 2, "text": "新しい服装が欲しい", "vector": [0.0, 1.0, 0.0, 0.0],
     "category": "clothing", "ts": 1700000100, "public": True},
], batch_size=100)

# 3. hybrid query with attribute projection
res = client.hybrid_search("demo", text="食べる", vector=[1.0, 0.0, 0.0, 0.0],
                           top_k=10, nprobe=8, filter_category="food",
                           attributes=["text", "category"])
for row in res["rows"]:
    print(row["id"], row["score"], row.get("text"), row.get("category"))

# 4. batch delete
client.batch_delete("demo", ids=[99], batch_size=100)

# 5. namespace health
print(client.health("demo"))   # {"ns": "demo", "num_docs": 2, "head": "...", "fts_tokenizer": "kuromoji"}

# Error handling: any non-2xx, transport failure, or invalid JSON raises
try:
    client.query("missing", text="x")
except TurboFishError as e:
    print(e.status, e.body)    # HTTP status (None if transport failure) and raw body
```

## API

- `TurboFishClient(endpoint, timeout=30)` — `timeout` is per-request, in seconds.
- All methods return the parsed JSON response as a `dict` and are synchronous.
- `TurboFishError(message, status=None, body=None)` — `status` is the HTTP
  status code or `None` (transport failure / timeout / malformed reply);
  `body` is the raw response text or `None`.

## Tests

```bash
# unit tests (mock HTTP served by a local http.server on an ephemeral port)
python3 -m unittest discover sdk/python

# end-to-end against a running turbofish server
python3 sdk/python/test_e2e.py http://127.0.0.1:8080 [namespace]
```

`test_e2e.py` creates a uniquely-named namespace (kuromoji), writes 3 rows
(Japanese text + 4-dim vectors), asserts an FTS hit for `食べる`, asserts a
vector query hits id 1, and checks `health` reports `num_docs == 3`.
Pass a namespace as the second argv to pin one instead.
