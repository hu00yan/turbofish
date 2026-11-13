# turbofish-client (Python)

Minimal Python client for the **turbofish HTTP API** (JSON, optional Bearer auth).
Single file, pure standard library (`urllib.request` + `json`) — zero dependencies.

## Contract covered

| Method | HTTP | Path | Request body | Response |
|---|---|---|---|---|
| `create_namespace(ns, fts_tokenizer=None, distance_metric=None)` | POST | `/v1/namespaces/{ns}/create` | `{"fts_tokenizer": "word\|smartcn\|kuromoji\|nori"}`, `{"distance_metric": "cosine\|euclidean\|cosine_distance\|euclidean_squared"}` (均可省略) | `{"ok": true, "ns": ...}` |
| `write(ns, rows, deletes=None, distance_metric=None)` | POST | `/v1/namespaces/{ns}/write` | `{"rows": [...], "deletes": [...]}`; `distance_metric` 在请求体顶层 | `{"ingested": n, "head": ...}` |
| `batch_upsert(ns, rows, batch_size=1000, distance_metric=None)` / `upsert(...)` | POST (batch) | `/v1/namespaces/{ns}/write` | 分批写入 | `{"ingested": n, "head": ..., "batches": b}` |
| `batch_delete(ns, ids, batch_size=1000)` / `delete(...)` | POST (batch) | `/v1/namespaces/{ns}/write` | 分批删除 | `{"deleted": n, "head": ..., "batches": b}` |
| `delete_by_filter(ns, filter)` | POST | `/v1/namespaces/{ns}/delete_by_filter` | `{"filter": [...]}` | `{"deleted": n}` |
| `copy_namespace(source_ns, dest_ns)` | POST | `/v1/namespaces/{source_ns}/copy` | `{"destination": "dest_ns"}` | `{"ok": true}` |
| `branch_namespace(source_ns, dest_ns)` | POST | `/v1/namespaces/{source_ns}/branch` | `{"destination": "dest_ns"}` | `{"ok": true}` |
| `query(ns, text=None, vector=None, top_k=10, limit=None, nprobe=None, filter_category=None, attributes=None, filter=None, offset=None, aggregations=None, rank_constant=None, fusion=None, weights=None, include_attributes=None, exclude_attributes=None, consistency=None)` | POST | `/v1/namespaces/{ns}/query` | 未设置的参数省略 | `{"rows": [...], "count": n}`；`aggregations` 支持 `Count` 与 `Sum` |
| `count(ns, filter=None, consistency=None)` | POST | `/v1/namespaces/{ns}/query` | `aggregations=["Count"]` 便捷封装，返回 `int` | `int` |
| `hybrid_search(ns, text, vector, top_k=10, nprobe=None, filter_category=None, attributes=None, filter=None, rank_constant=None, fusion=None, weights=None)` | POST | `/v1/namespaces/{ns}/query` | 混合检索与属性投影 | `{"rows": [...], "count": n}` |
| `health(ns)` | GET | `/v1/namespaces/{ns}/health` | — | `{"ns", "num_docs", "head", "fts_tokenizer"}` |

A row is `{"id": <uint64>, "text": str, "vector": [f32...], "category": str,
"ts": <int64>, "public": bool}`. Field names are passed through verbatim; the
server validates them. Query results return enriched attributes (`id`, `score`, `text`,
`category`, `ts`, `public`), and `attributes` parameter controls field projection.

API Key: pass `api_key="..."` in `TurboFishClient(..., api_key=...)` to send
`Authorization: Bearer <key>`.

v1 query 参数（全部可选、向后兼容）：`filter` 接收已构造好的 turbopuffer
数组语法并原样透传 —— 叶子 `["attr", "Eq", value]`（op ∈
Eq/NotEq/In/NotIn/Lt/Lte/Gt/Gte/Glob）、两元糖 `["attr", value]`（等于 Eq）、组合
`["And", [...]]` / `["Or", [...]]` / `["Not", filter]`，value 为数字/字符串/布尔
（`In` 的 value 是数组）；`weights` 为 `{"bm25": .., "vector": ..}` dict 原样透传。
`rank_constant` / `fusion` / `weights` 仅 hybrid（text+vector 同时给）查询生效。
`consistency` 为 `"strong"` 或 `"eventual"`。`create_namespace` / `write`
支持可选 `distance_metric`（`"cosine" | "euclidean" | "cosine_distance" | "euclidean_squared"`）。

## 5 分钟上手

```bash
# From the repo root: editable install (or just copy turbofish_client.py next to your code)
pip install -e sdk/python
```

```python
from turbofish_client import TurboFishClient, TurboFishError

client = TurboFishClient("http://127.0.0.1:8080", timeout=10, api_key="my-key")

# 1. create a namespace with a Japanese FTS tokenizer
client.create_namespace("demo", fts_tokenizer="kuromoji", distance_metric="cosine_distance")

# 2. batch upsert rows (4-dim vectors in this example)
client.batch_upsert("demo", rows=[
    {"id": 1, "text": "今日は寿司を食べました", "vector": [1.0, 0.0, 0.0, 0.0],
     "category": "food", "ts": 1700000000, "public": True},
    {"id": 2, "text": "新しい服装が欲しい", "vector": [0.0, 1.0, 0.0, 0.0],
     "category": "clothing", "ts": 1700000100, "public": True},
    {"id": 3, "text": "美味しいラーメン屋を探す", "vector": [0.707, 0.707, 0.0, 0.0],
     "category": "food", "ts": 1700000200, "public": False},
])

# 3. hybrid search combining lexical BM25 relevance and vector cosine
res = client.hybrid_search(
    "demo",
    text="寿司",
    vector=[1.0, 0.0, 0.0, 0.0],
    top_k=2,
    attributes=["text", "category"],
)
print("hits:", res["count"])
for r in res["rows"]:
    print(r["id"], r["score"], r["text"], r.get("category"))

# 4. delete by filter
client.delete_by_filter("demo", ["category", "Eq", "clothing"])

# 5. copy / branch namespace
client.branch_namespace("demo", "demo_staging")

# 6. check health
print(client.health("demo"))
```
