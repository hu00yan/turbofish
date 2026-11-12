/**
 * Unit tests for the turbofish TypeScript client.
 *
 * Mock HTTP: a local node:http server on an ephemeral port records each
 * request (method / path / JSON body) and replies with canned payloads.
 *
 * Run: node --test test/   (from sdk/typescript; runs client.test.ts only —
 * e2e.mts skips itself when no endpoint is given)
 */
import assert from "node:assert/strict";
import { createServer, type AddressInfo, type IncomingHttpHeaders, type Server, type ServerResponse } from "node:http";
import { test } from "node:test";
import { TurboFishClient, TurboFishError } from "../src/client.ts";

interface ReqRec {
  method: string;
  url: string;
  body: string;
  headers: IncomingHttpHeaders;
}

type Handler = (rec: ReqRec, res: ServerResponse) => void;

function jsonReply(res: ServerResponse, status: number, payload: unknown): void {
  const data = Buffer.from(JSON.stringify(payload));
  res.writeHead(status, { "content-type": "application/json", "content-length": String(data.length) });
  res.end(data);
}

interface MockServer {
  url: string;
  requests: ReqRec[];
  close: () => Promise<void>;
}

function startMock(handler: Handler): Promise<MockServer> {
  const requests: ReqRec[] = [];
  const server: Server = createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => chunks.push(chunk));
    req.on("end", () => {
      const rec: ReqRec = {
        method: req.method ?? "",
        url: req.url ?? "",
        body: Buffer.concat(chunks).toString("utf8"),
        headers: req.headers,
      };
      requests.push(rec);
      handler(rec, res);
    });
  });
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address() as AddressInfo;
      resolve({
        url: `http://127.0.0.1:${port}`,
        requests,
        close: () => new Promise((done) => server.close(() => done())),
      });
    });
  });
}

/** Route-only mock implementing the contract v0 defaults. */
function contractHandler(): Handler {
  return (rec, res) => {
    const parts = rec.url.split("/"); // ["", "v1", "namespaces", ns, action]
    if (parts.length >= 5 && parts[1] === "v1" && parts[2] === "namespaces") {
      const ns = parts[3];
      const action = parts[4];
      const body = rec.body ? JSON.parse(rec.body) : {};
      if (rec.method === "POST" && action === "create") {
        jsonReply(res, 200, { ok: true, ns });
        return;
      }
      if (rec.method === "POST" && action === "write") {
        jsonReply(res, 200, { ingested: (body.rows ?? []).length, head: "feedface" });
        return;
      }
      if (rec.method === "POST" && action === "query") {
        jsonReply(res, 200, {
          rows: [
            {
              id: 1,
              score: 0.5,
              text: body.text ?? "今日は寿司を食べました",
              category: "food",
              ts: 1700000000,
              public: true,
            },
          ],
          count: 1,
        });
        return;
      }
      if (rec.method === "GET" && action === "health") {
        jsonReply(res, 200, { ns, num_docs: 3, head: "feedface", fts_tokenizer: "kuromoji" });
        return;
      }
    }
    jsonReply(res, 404, { error: `no route for ${rec.method} ${rec.url}` });
  };
}

const ROWS = [
  { id: 1, text: "今日は寿司を食べました", vector: [1, 0, 0, 0], category: "food", ts: 1700000000, public: true },
  { id: 2, text: "新しい服装が欲しい", vector: [0, 1, 0, 0], category: "clothing", ts: 1700000100, public: true },
];

test("create_namespace posts to the create route with the tokenizer", async () => {
  const mock = await startMock(contractHandler());
  try {
    const client = new TurboFishClient(mock.url);
    const out = await client.create_namespace("ns-a", "kuromoji");
    assert.equal(out.ok, true);
    assert.equal(out.ns, "ns-a");
    const rec = mock.requests[mock.requests.length - 1];
    assert.equal(rec.method, "POST");
    assert.equal(rec.url, "/v1/namespaces/ns-a/create");
    assert.deepEqual(JSON.parse(rec.body), { fts_tokenizer: "kuromoji" });
    assert.equal(rec.headers["content-type"], "application/json");
  } finally {
    await mock.close();
  }
});

test("create_namespace omits fts_tokenizer when not given", async () => {
  const mock = await startMock(contractHandler());
  try {
    const client = new TurboFishClient(mock.url);
    await client.create_namespace("ns-b");
    const rec = mock.requests[mock.requests.length - 1];
    assert.deepEqual(JSON.parse(rec.body), {});
  } finally {
    await mock.close();
  }
});

test("write posts rows and deletes", async () => {
  const mock = await startMock(contractHandler());
  try {
    const client = new TurboFishClient(mock.url);
    const out = await client.write("ns", ROWS, [2]);
    assert.equal(out.ingested, 2);
    assert.equal(out.head, "feedface");
    const rec = mock.requests[mock.requests.length - 1];
    assert.equal(rec.method, "POST");
    assert.equal(rec.url, "/v1/namespaces/ns/write");
    const body = JSON.parse(rec.body);
    assert.deepEqual(body.rows, ROWS);
    assert.deepEqual(body.deletes, [2]);
  } finally {
    await mock.close();
  }
});

test("write omits deletes when not given", async () => {
  const mock = await startMock(contractHandler());
  try {
    const client = new TurboFishClient(mock.url);
    await client.write("ns", ROWS);
    const body = JSON.parse(mock.requests[mock.requests.length - 1].body);
    assert.ok(!("deletes" in body));
    assert.deepEqual(body.rows, ROWS);
  } finally {
    await mock.close();
  }
});

test("query sends every parameter that was set", async () => {
  const mock = await startMock(contractHandler());
  try {
    const client = new TurboFishClient(mock.url);
    await client.query("ns", "hello", [1, 2, 3, 4], 5, 2, "rs");
    const rec = mock.requests[mock.requests.length - 1];
    assert.equal(rec.url, "/v1/namespaces/ns/query");
    assert.deepEqual(JSON.parse(rec.body), {
      text: "hello",
      vector: [1, 2, 3, 4],
      top_k: 5,
      nprobe: 2,
      filter_category: "rs",
    });
  } finally {
    await mock.close();
  }
});

test("batch_upsert splits rows across batches", async () => {
  const mock = await startMock(contractHandler());
  try {
    const client = new TurboFishClient(mock.url);
    const rows = [
      { id: 1, text: "doc1", vector: [1, 0, 0, 0] },
      { id: 2, text: "doc2", vector: [0, 1, 0, 0] },
      { id: 3, text: "doc3", vector: [0, 0, 1, 0] },
    ];
    const res = await client.batch_upsert("ns", rows, 2);
    assert.equal(res.ingested, 3);
    assert.equal(res.batches, 2);
    assert.equal(mock.requests.length, 2);
  } finally {
    await mock.close();
  }
});

test("batch_delete splits ids across batches", async () => {
  const mock = await startMock(contractHandler());
  try {
    const client = new TurboFishClient(mock.url);
    const ids = [1, 2, 3, 4, 5];
    const res = await client.batch_delete("ns", ids, 2);
    assert.equal(res.deleted, 5);
    assert.equal(res.batches, 3);
    assert.equal(mock.requests.length, 3);
    const d0 = JSON.parse(mock.requests[0].body);
    assert.deepEqual(d0.deletes, [1, 2]);
  } finally {
    await mock.close();
  }
});

test("query returns enriched attributes", async () => {
  const mock = await startMock(contractHandler());
  try {
    const client = new TurboFishClient(mock.url);
    const res = await client.query("ns", "sushi");
    assert.equal(res.count, 1);
    const row = res.rows[0];
    assert.equal(row.id, 1);
    assert.equal(row.score, 0.5);
    assert.equal(row.text, "sushi");
    assert.equal(row.category, "food");
    assert.equal(row.ts, 1700000000);
    assert.equal(row.public, true);
  } finally {
    await mock.close();
  }
});

test("query with attribute projection", async () => {
  const mock = await startMock(contractHandler());
  try {
    const client = new TurboFishClient(mock.url);
    const res = await client.query("ns", "sushi", undefined, 10, undefined, undefined, ["text", "category"]);
    const row = res.rows[0];
    assert.equal(row.id, 1);
    assert.equal(row.score, 0.5);
    assert.equal(row.text, "sushi");
    assert.equal(row.category, "food");
    assert.equal(row.ts, undefined);
    assert.equal(row.public, undefined);
  } finally {
    await mock.close();
  }
});

test("hybrid_search helper with attribute projection", async () => {
  const mock = await startMock(contractHandler());
  try {
    const client = new TurboFishClient(mock.url);
    const res = await client.hybrid_search("ns", "sushi", [1, 0, 0, 0], 5, 4, "food", ["text"]);
    const rec = mock.requests[mock.requests.length - 1];
    const body = JSON.parse(rec.body);
    assert.equal(body.text, "sushi");
    assert.deepEqual(body.vector, [1, 0, 0, 0]);
    assert.equal(body.top_k, 5);
    assert.equal(body.nprobe, 4);
    assert.equal(body.filter_category, "food");
    assert.deepEqual(body.attributes, ["text"]);
    const row = res.rows[0];
    assert.equal(row.id, 1);
    assert.equal(row.text, "sushi");
    assert.equal(row.category, undefined);
  } finally {
    await mock.close();
  }
});

test("query defaults top_k to 10 and omits unset parameters", async () => {
  const mock = await startMock(contractHandler());
  try {
    const client = new TurboFishClient(mock.url);
    await client.query("ns", "hi");
    const body = JSON.parse(mock.requests[mock.requests.length - 1].body);
    assert.deepEqual(body, { text: "hi", top_k: 10 });
  } finally {
    await mock.close();
  }
});

test("health sends GET and parses the reply", async () => {
  const mock = await startMock(contractHandler());
  try {
    const client = new TurboFishClient(mock.url);
    const out = await client.health("ns");
    assert.equal(out.ns, "ns");
    assert.equal(out.num_docs, 3);
    assert.equal(out.fts_tokenizer, "kuromoji");
    const rec = mock.requests[mock.requests.length - 1];
    assert.equal(rec.method, "GET");
    assert.equal(rec.url, "/v1/namespaces/ns/health");
    assert.equal(rec.body, "");
  } finally {
    await mock.close();
  }
});

test("non-2xx response raises TurboFishError with status and body", async () => {
  const mock = await startMock((rec, res) => jsonReply(res, 404, { error: "namespace not found" }));
  try {
    const client = new TurboFishClient(mock.url);
    await assert.rejects(
      () => client.health("ns"),
      (err: unknown) =>
        err instanceof TurboFishError && err.status === 404 && (err.body ?? "").includes("namespace not found"),
    );
  } finally {
    await mock.close();
  }
});

test("invalid JSON response raises TurboFishError", async () => {
  const mock = await startMock((_rec, res) => {
    res.writeHead(200, { "content-type": "text/plain" });
    res.end("<html>oops</html>");
  });
  try {
    const client = new TurboFishClient(mock.url);
    await assert.rejects(
      () => client.health("ns"),
      (err: unknown) => err instanceof TurboFishError && err.status === 200 && (err.body ?? "").includes("oops"),
    );
  } finally {
    await mock.close();
  }
});

test("connection failure raises TurboFishError with null status", async () => {
  const client = new TurboFishClient("http://127.0.0.1:9", 2); // discard port: nothing listens
  await assert.rejects(
    () => client.health("ns"),
    (err: unknown) => err instanceof TurboFishError && err.status === null,
  );
});

test("namespace is URL-encoded", async () => {
  const mock = await startMock(contractHandler());
  try {
    const client = new TurboFishClient(mock.url);
    await client.create_namespace("a b/c");
    const rec = mock.requests[mock.requests.length - 1];
    assert.equal(rec.url, "/v1/namespaces/a%20b%2Fc/create");
  } finally {
    await mock.close();
  }
});

test("trailing slash in endpoint is tolerated", async () => {
  const mock = await startMock(contractHandler());
  try {
    const client = new TurboFishClient(`${mock.url}/`);
    const out = await client.health("ns");
    assert.equal(out.ns, "ns");
    const rec = mock.requests[mock.requests.length - 1];
    assert.equal(rec.url, "/v1/namespaces/ns/health");
  } finally {
    await mock.close();
  }
});
