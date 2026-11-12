# @turbofish/client (TypeScript)

Minimal TypeScript client for the **turbofish HTTP API v0** (JSON, no auth).
Uses the global `fetch` (Node >= 18, modern browsers) — no runtime dependencies.

> Naming note: method and parameter names mirror the Python SDK verbatim
> (`create_namespace`, `write`, `query`, `health`, `top_k`, `filter_category`,
> ...) so both SDKs share one contract surface. TS-conventional camelCase
> aliases can be added later if the mainline asks for them.

## Contract v0 covered

| Method | HTTP | Path | Request body | Response |
|---|---|---|---|---|
| `create_namespace(ns, fts_tokenizer?)` | POST | `/v1/namespaces/{ns}/create` | `{"fts_tokenizer": "word\|smartcn\|kuromoji\|nori"}` (可省略) | `{"ok": true, "ns": ...}` |
| `write(ns, rows, deletes?)` | POST | `/v1/namespaces/{ns}/write` | `{"rows": [...], "deletes": [...]}` | `{"ingested": n, "head": ...}` |
| `batch_upsert(ns, rows, batchSize=1000)` / `upsert(...)` | POST (batch) | `/v1/namespaces/{ns}/write` | 分批写入 | `{"ingested": n, "head": ..., "batches": b}` |
| `batch_delete(ns, ids, batchSize=1000)` / `delete(...)` | POST (batch) | `/v1/namespaces/{ns}/write` | 分批删除 | `{"deleted": n, "head": ..., "batches": b}` |
| `query(ns, text?, vector?, top_k=10, nprobe?, filter_category?, attributes?)` | POST | `/v1/namespaces/{ns}/query` | 未设置的参数省略 | `{"rows": [...], "count": n}` |
| `hybrid_search(ns, text, vector, top_k=10, nprobe?, filter_category?, attributes?)` | POST | `/v1/namespaces/{ns}/query` | 混合检索与属性投影 | `{"rows": [...], "count": n}` |
| `health(ns)` | GET | `/v1/namespaces/{ns}/health` | — | `{"ns", "num_docs", "head", "fts_tokenizer"}` |

A row is `{ id: number, text?: string, vector?: number[], category?: string,
ts?: number, public?: boolean }`. Field names pass through verbatim; the
server validates them. Query results return enriched attributes (`id`, `score`, `text`,
`category`, `ts`, `public`), and `attributes` parameter controls field projection.

## 5 分钟上手

```bash
cd sdk/typescript
npm install        # dev-only: typescript for `npm run build`
npm run build      # emits dist/client.js + dist/client.d.ts
```

```ts
import { TurboFishClient, TurboFishError } from "@turbofish/client";

const client = new TurboFishClient("http://127.0.0.1:8080", 10); // timeout in seconds

// 1. create a namespace with a Japanese FTS tokenizer
await client.create_namespace("demo", "kuromoji");

// 2. write rows (4-dim vectors in this example)
await client.write("demo", [
  { id: 1, text: "今日は寿司を食べました", vector: [1, 0, 0, 0],
    category: "food", ts: 1700000000, public: true },
  { id: 2, text: "新しい服装が欲しい", vector: [0, 1, 0, 0],
    category: "clothing", ts: 1700000100, public: true },
], [99]);

// 3. hybrid query: FTS + vector, category filter
const res = await client.query("demo", "食べる", [1, 0, 0, 0], 10, 8, "food");
for (const row of res.rows) {
  console.log(row.id, row.score, row.text, row.category);
}

// 4. namespace health
console.log(await client.health("demo"));
// { ns: "demo", num_docs: 2, head: "...", fts_tokenizer: "kuromoji" }

// Error handling: any non-2xx, transport failure, or invalid JSON throws
try {
  await client.query("missing", "x");
} catch (e) {
  if (e instanceof TurboFishError) {
    console.log(e.status, e.body); // HTTP status (null if transport failure) and raw body
  }
}
```

## Tests

```bash
cd sdk/typescript
npm test                          # unit tests (node:test, mock HTTP via node:http)
node test/e2e.mts http://127.0.0.1:8080 [namespace]   # e2e against a running server
```

`test/e2e.mts` creates a uniquely-named namespace (kuromoji), writes 3 rows
(Japanese text + 4-dim vectors), asserts an FTS hit for `食べる`, asserts a
vector query hits id 1, and checks `health` reports `num_docs == 3`.

### Running TypeScript directly (no build step)

`node --test` and `test/e2e.mts` run `.ts`/`.mts` sources via Node's built-in
type stripping:

- Node >= 23.6 (or 22.18+ LTS): works as-is — `node test/e2e.mts <endpoint>`.
- Node 22.x older / Node 20.x: add the flag —
  `node --experimental-strip-types test/e2e.mts <endpoint>`.
- Alternatively `npm i -g tsx` and run `tsx test/e2e.mts <endpoint>`.
