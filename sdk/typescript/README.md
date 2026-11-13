# @turbofish/client (TypeScript)

Minimal TypeScript / JavaScript client for the **turbofish HTTP API** (JSON, optional Bearer auth).
Uses the global `fetch` (Node >= 18, modern browsers) — no runtime dependencies.

Method names and parameters mirror the Python SDK verbatim so docs and concepts
transfer 1:1.

## Contract covered

| Method | HTTP | Path | Request body | Response |
|---|---|---|---|---|
| `create_namespace(ns, fts_tokenizer?, distance_metric?)` | POST | `/v1/namespaces/{ns}/create` | `{"fts_tokenizer": "word\|smartcn\|kuromoji\|nori"}`, `{"distance_metric": "cosine\|euclidean\|cosine_distance\|euclidean_squared"}` (均可省略) | `{"ok": true, "ns": ...}` |
| `write(ns, rows, deletes?, distance_metric?)` | POST | `/v1/namespaces/{ns}/write` | `{"rows": [...], "deletes": [...]}`; `distance_metric` 在请求体顶层 | `{"ingested": n, "head": ...}` |
| `batch_upsert(ns, rows, batchSize=1000, distance_metric?)` / `upsert(...)` | POST (batch) | `/v1/namespaces/{ns}/write` | 分批写入 | `{"ingested": n, "head": ..., "batches": b}` |
| `batch_delete(ns, ids, batchSize=1000)` / `delete(...)` | POST (batch) | `/v1/namespaces/{ns}/write` | 分批删除 | `{"deleted": n, "head": ..., "batches": b}` |
| `deleteByFilter(ns, filter)` | POST | `/v1/namespaces/{ns}/delete_by_filter` | `{"filter": [...]}` | `{"deleted": number}` |
| `copyNamespace(sourceNs, destNs)` | POST | `/v1/namespaces/{sourceNs}/copy` | `{"destination": destNs}` | `{"ok": true}` |
| `branchNamespace(sourceNs, destNs)` | POST | `/v1/namespaces/{sourceNs}/branch` | `{"destination": destNs}` | `{"ok": true}` |
| `query(ns, text?, vector?, top_k=10, nprobe?, filter_category?, attributes?, filter?, offset?, aggregations?, rank_constant?, fusion?, weights?, include_attributes?, exclude_attributes?, consistency?, limit?)` | POST | `/v1/namespaces/{ns}/query` | 未设置的参数省略 | `{"rows": [...], "count": n}`；`aggregations` 支持 `Count` 与 `Sum` |
| `count(ns, filter?, consistency?)` | POST | `/v1/namespaces/{ns}/query` | `aggregations=["Count"]` 便捷封装，返回 `number` | `number` |
| `hybrid_search(ns, text, vector, top_k=10, nprobe?, filter_category?, attributes?, filter?, rank_constant?, fusion?, weights?)` | POST | `/v1/namespaces/{ns}/query` | 混合检索与属性投影 | `{"rows": [...], "count": n}` |
| `health(ns)` | GET | `/v1/namespaces/{ns}/health` | — | `{"ns", "num_docs", "head", "fts_tokenizer"}` |

A row is `{ id: number, text?: string, vector?: number[], category?: string,
ts?: number, public?: boolean }`. Field names pass through verbatim; the
server validates them. Query results return enriched attributes (`id`, `score`, `text`,
`category`, `ts`, `public`), and `attributes` parameter controls field projection.

API Key: pass `{ apiKey: "..." }` in options: `new TurboFishClient(endpoint, { apiKey: "..." })`
to send `Authorization: Bearer <key>`.

v1 query 参数（全部可选、向后兼容）：`filter` 接收已构造好的 turbopuffer
数组语法并原样透传 —— 叶子 `["attr", "Eq", value]`（op ∈
Eq/NotEq/In/NotIn/Lt/Lte/Gt/Gte/Glob）、两元糖 `["attr", value]`（等于 Eq）、组合
`["And", [...]]` / `["Or", [...]]` / `["Not", filter]`，value 为数字/字符串/布尔
（`In` 的 value 是数组）；`weights` 为 `{ bm25, vector }` object 原样透传。
`rank_constant` / `fusion` / `weights` 仅 hybrid（text+vector 同时给）查询生效。
`consistency` 为 `"strong"` 或 `"eventual"`。`create_namespace` / `write`
支持可选 `distance_metric`（`"cosine" | "euclidean" | "cosine_distance" | "euclidean_squared"`）。

## 5 分钟上手

```bash
cd sdk/typescript
npm install
npm run build
```

```typescript
import { TurboFishClient } from "@turbofish/client";

const client = new TurboFishClient("http://127.0.0.1:8080", { timeout: 10, apiKey: "my-key" });

// 1. create namespace
await client.create_namespace("demo", "kuromoji", "cosine_distance");

// 2. batch upsert rows (4-dim vectors)
await client.batch_upsert("demo", [
  { id: 1, text: "今日は寿司を食べました", vector: [1, 0, 0, 0], category: "food", ts: 1700000000, public: true },
  { id: 2, text: "新しい服装が欲しい", vector: [0, 1, 0, 0], category: "clothing", ts: 1700000100, public: true },
]);

// 3. hybrid search
const res = await client.hybrid_search("demo", "寿司", [1, 0, 0, 0], 2, undefined, undefined, ["text", "category"]);
console.log("hits:", res.count);

// 4. delete by filter
await client.deleteByFilter("demo", ["category", "Eq", "clothing"]);

// 5. copy / branch namespace
await client.branchNamespace("demo", "demo_staging");

// 6. health
console.log(await client.health("demo"));
```
