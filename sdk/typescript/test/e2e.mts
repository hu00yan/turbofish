/**
 * End-to-end smoke test for the turbofish HTTP API v0 (TypeScript SDK).
 *
 * Usage:
 *   node test/e2e.mts http://127.0.0.1:8080 [namespace]
 *   (Node >= 23.6 / 22.18 runs .mts via built-in type stripping; older Node:
 *    node --experimental-strip-types test/e2e.mts ...; or use tsx)
 *
 * Scenario (same as sdk/python/test_e2e.py):
 *   1. create namespace with the kuromoji tokenizer
 *   2. write 3 rows (Japanese text incl. 食べました / 服装 + 4-dim vectors)
 *   3. query text=食べる  -> assert FTS hits (id 1 among them)
 *   4. query vector [1,0,0,0] -> assert nearest id is 1
 *   5. health -> assert num_docs == 3, fts_tokenizer == kuromoji
 *
 * A uniquely-named namespace is used by default so the script is safe to
 * re-run; pass argv[2] to pin a namespace instead.
 * Exit code 0 = PASS, non-zero = FAIL.
 * When swept up by `node --test` without an endpoint, it exits 0 without
 * running (unit tests are in client.test.ts).
 */
import assert from "node:assert/strict";
import { TurboFishClient, TurboFishError } from "../src/client.ts";

const endpoint = process.argv[2] ?? process.env.TURBOFISH_ENDPOINT ?? "";
if (!endpoint) {
  console.error("usage: node test/e2e.mts <endpoint> [namespace]");
  if (process.env.NODE_TEST_CONTEXT) {
    process.exit(0); // running under `node --test` with no endpoint: skip
  }
  process.exit(2);
}
const ns = process.argv[3] ?? process.env.TURBOFISH_NS ?? `e2e_ts_${Math.floor(Date.now() / 1000)}`;
const client = new TurboFishClient(endpoint, 15);

try {
  console.log(`[1/7] create namespace ${ns} with fts_tokenizer=kuromoji ...`);
  const created = await client.create_namespace(ns, "kuromoji");
  assert.equal(created.ok, true, `create_namespace: expected ok=true, got ${JSON.stringify(created)}`);
  assert.equal(created.ns, ns, `create_namespace: expected ns=${ns}, got ${JSON.stringify(created)}`);

  const rows = [
    {
      id: 1,
      text: "今日は寿司を食べました",
      vector: [1, 0, 0, 0],
      category: "food",
      ts: 1700000000,
      public: true,
    },
    {
      id: 2,
      text: "新しい服装が欲しい",
      vector: [0, 1, 0, 0],
      category: "clothing",
      ts: 1700000100,
      public: true,
    },
    {
      id: 3,
      text: "ラーメンを食べに行きました",
      vector: [0.9, 0.1, 0, 0],
      category: "food",
      ts: 1700000200,
      public: true,
    },
  ];
  console.log(`[2/7] write ${rows.length} rows (食べました / 服装 / 食べに行きました, 4-dim vectors) ...`);
  const wout = await client.write(ns, rows);
  assert.equal(wout.ingested, 3, `write: expected ingested=3, got ${JSON.stringify(wout)}`);
  assert.ok(typeof wout.head === "string" && wout.head.length > 0, `write: missing head, got ${JSON.stringify(wout)}`);

  console.log("[3/7] query text=食べる (kuromoji FTS) & assert enriched attributes ...");
  const qout = await client.query(ns, "食べる", undefined, 5);
  const ids = (qout.rows ?? []).map((r) => r.id);
  assert.ok((qout.count ?? 0) >= 1 && (qout.rows ?? []).length >= 1, `query text=食べる: no hits, got ${JSON.stringify(qout)}`);
  assert.ok(ids.includes(1), `query text=食べる: expected id 1 (食べました) among hits, got ids=${JSON.stringify(ids)}`);
  const hit1 = (qout.rows ?? []).find((r) => r.id === 1);
  assert.ok(hit1, "expected id 1 among hits");
  assert.equal(hit1.text, "今日は寿司を食べました", `expected text, got ${hit1.text}`);
  assert.equal(hit1.category, "food", `expected category food, got ${hit1.category}`);

  console.log("[4/7] query vector=[1,0,0,0] top_k=1 & assert enriched attributes ...");
  const vout = await client.query(ns, undefined, [1, 0, 0, 0], 1);
  assert.ok(
    (vout.rows ?? []).length >= 1 && vout.rows[0].id === 1,
    `query vector: expected nearest id 1, got ${JSON.stringify(vout)}`,
  );
  assert.equal(vout.rows[0].text, "今日は寿司を食べました", `expected text, got ${vout.rows[0].text}`);
  assert.equal(vout.rows[0].category, "food", `expected category food, got ${vout.rows[0].category}`);

  console.log("[5/7] hybrid_search with attribute projection ...");
  const houtProj = await client.hybrid_search(
    ns,
    "食べる",
    [1, 0, 0, 0],
    2,
    undefined,
    undefined,
    ["text", "category"],
  );
  assert.ok((houtProj.rows ?? []).length >= 1, "expected hybrid_search hits");
  for (const hr of houtProj.rows) {
    assert.ok(hr.id !== undefined && hr.score !== undefined);
    assert.ok(hr.text !== undefined || hr.category !== undefined);
    assert.equal(hr.ts, undefined, `ts should not be present in projected row: ${JSON.stringify(hr)}`);
    assert.equal(hr.public, undefined, `public should not be present in projected row: ${JSON.stringify(hr)}`);
  }

  console.log("[6/7] batch_upsert and batch_delete helpers ...");
  const extraRows = [
    {
      id: 100,
      text: "うどんを食べました",
      vector: [0.8, 0.2, 0, 0],
      category: "food",
      ts: 1700000300,
      public: true,
    },
    {
      id: 101,
      text: "スニーカーを買いました",
      vector: [0, 0.8, 0.2, 0],
      category: "clothing",
      ts: 1700000400,
      public: true,
    },
  ];
  const upRes = await client.batch_upsert(ns, extraRows, 1);
  assert.equal(upRes.ingested, 2);
  assert.equal(upRes.batches, 2);

  const delRes = await client.batch_delete(ns, [100, 101], 1);
  assert.equal(delRes.deleted, 2);
  assert.equal(delRes.batches, 2);

  console.log("[7/7] health ...");
  const hout = await client.health(ns);
  assert.equal(hout.ns, ns, `health: expected ns=${ns}, got ${JSON.stringify(hout)}`);
  assert.equal(hout.num_docs, 3, `health: expected num_docs=3, got ${JSON.stringify(hout)}`);
  assert.equal(hout.fts_tokenizer, "kuromoji", `health: expected kuromoji, got ${JSON.stringify(hout)}`);

  console.log(`PASS: e2e OK against ${endpoint} (ns=${ns}, num_docs=${hout.num_docs}, head=${hout.head})`);
  process.exit(0);
} catch (err) {
  if (err instanceof TurboFishError) {
    console.error(`E2E FAILED: TurboFishError status=${err.status} body=${err.body}`);
  } else if (err instanceof Error) {
    console.error(`E2E FAILED: ${err.message}`);
  } else {
    console.error(`E2E FAILED: ${String(err)}`);
  }
  process.exit(1);
}
