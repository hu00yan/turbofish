/**
 * turbofish HTTP API v0 minimal TypeScript client.
 *
 * Uses the global `fetch` API (Node >= 18, modern browsers). No dependencies.
 * Method and parameter names intentionally mirror the Python SDK verbatim
 * (`create_namespace`, `top_k`, `filter_category`, ...) — the two SDKs share
 * the same contract surface.
 *
 * Contract v0 (JSON, no auth):
 *   POST {endpoint}/v1/namespaces/{ns}/create  {"fts_tokenizer"?: string}
 *     -> {"ok": true, "ns": string}
 *   POST {endpoint}/v1/namespaces/{ns}/write   {"rows": [...], "deletes"?: [...]}
 *     -> {"ingested": number, "head": string}
 *   POST {endpoint}/v1/namespaces/{ns}/query   {"text"?, "vector"?, "top_k"?, "nprobe"?, "filter_category"?}
 *     -> {"rows": [{"id","score","text","category"}...], "count": number}
 *   GET  {endpoint}/v1/namespaces/{ns}/health
 *     -> {"ns", "num_docs", "head", "fts_tokenizer"}
 */

export class TurboFishError extends Error {
  /** HTTP status code, or null when no response was received (transport failure / timeout / invalid reply). */
  readonly status: number | null;
  /** Raw response body text, or null when there is none. */
  readonly body: string | null;

  constructor(message: string, status: number | null = null, body: string | null = null) {
    super(message);
    this.name = "TurboFishError";
    this.status = status;
    this.body = body;
  }
}

/** One row of a `write` call: contract field names passed through verbatim; the server validates them. */
export interface TurboFishRow {
  id: number;
  text?: string;
  vector?: number[];
  category?: string;
  ts?: number;
  public?: boolean;
}

export interface CreateNamespaceResult {
  ok: boolean;
  ns: string;
}

export interface WriteResult {
  ingested: number;
  head: string;
}

export interface QueryResultRow {
  id: number;
  score: number;
  text?: string;
  category?: string;
  ts?: number;
  public?: boolean;
  [key: string]: unknown;
}

export interface QueryResult {
  rows: QueryResultRow[];
  count: number;
}

export interface BatchUpsertResult {
  ingested: number;
  head: string;
  batches: number;
}

export interface BatchDeleteResult {
  deleted: number;
  head: string;
  batches: number;
}

export interface HealthResult {
  ns: string;
  num_docs: number;
  head: string;
  fts_tokenizer: string;
}

export class TurboFishClient {
  readonly endpoint: string;
  /** Per-request timeout in seconds (default 30). */
  readonly timeout: number;

  constructor(endpoint: string, timeout = 30) {
    if (!endpoint) throw new Error("endpoint must be a non-empty URL");
    this.endpoint = endpoint.replace(/\/+$/, "");
    this.timeout = timeout;
  }

  /** Create a namespace. `fts_tokenizer`: "word" | "smartcn" | "kuromoji" | "nori". */
  async create_namespace(ns: string, fts_tokenizer?: string): Promise<CreateNamespaceResult> {
    const payload: Record<string, unknown> = {};
    if (fts_tokenizer !== undefined && fts_tokenizer !== null) {
      payload.fts_tokenizer = fts_tokenizer;
    }
    return this.request<CreateNamespaceResult>("POST", this.nsUrl(ns, "create"), payload);
  }

  /** Write rows and/or delete ids. Returns `{"ingested": n, "head": ...}`. */
  async write(ns: string, rows: readonly TurboFishRow[], deletes?: readonly number[]): Promise<WriteResult> {
    const payload: Record<string, unknown> = { rows: [...rows] };
    if (deletes !== undefined && deletes !== null) {
      payload.deletes = [...deletes];
    }
    return this.request<WriteResult>("POST", this.nsUrl(ns, "write"), payload);
  }

  /** Upsert documents in batches of `batchSize`. */
  async batch_upsert(
    ns: string,
    rows: readonly TurboFishRow[],
    batchSize = 1000,
  ): Promise<BatchUpsertResult> {
    if (batchSize <= 0) throw new Error("batchSize must be positive");
    if (!rows || rows.length === 0) {
      return { ingested: 0, head: "", batches: 0 };
    }
    let totalIngested = 0;
    let lastHead = "";
    let batches = 0;
    for (let i = 0; i < rows.length; i += batchSize) {
      const chunk = rows.slice(i, i + batchSize);
      const res = await this.write(ns, chunk);
      totalIngested += res.ingested ?? chunk.length;
      lastHead = res.head ?? "";
      batches++;
    }
    return { ingested: totalIngested, head: lastHead, batches };
  }

  /** Convenience alias for `batch_upsert`. */
  async upsert(ns: string, rows: readonly TurboFishRow[], batchSize = 1000): Promise<BatchUpsertResult> {
    return this.batch_upsert(ns, rows, batchSize);
  }

  /** Delete document IDs in batches of `batchSize`. */
  async batch_delete(
    ns: string,
    ids: readonly number[],
    batchSize = 1000,
  ): Promise<BatchDeleteResult> {
    if (batchSize <= 0) throw new Error("batchSize must be positive");
    if (!ids || ids.length === 0) {
      return { deleted: 0, head: "", batches: 0 };
    }
    let totalDeleted = 0;
    let lastHead = "";
    let batches = 0;
    for (let i = 0; i < ids.length; i += batchSize) {
      const chunk = ids.slice(i, i + batchSize);
      const res = await this.write(ns, [], chunk);
      totalDeleted += chunk.length;
      lastHead = res.head ?? "";
      batches++;
    }
    return { deleted: totalDeleted, head: lastHead, batches };
  }

  /** Convenience alias for `batch_delete`. */
  async delete(ns: string, ids: readonly number[], batchSize = 1000): Promise<BatchDeleteResult> {
    return this.batch_delete(ns, ids, batchSize);
  }

  /** Query by FTS `text` and/or `vector` with optional attribute projection. */
  async query(
    ns: string,
    text?: string | null,
    vector?: readonly number[] | null,
    top_k = 10,
    nprobe?: number | null,
    filter_category?: string | null,
    attributes?: readonly string[] | null,
  ): Promise<QueryResult> {
    const payload: Record<string, unknown> = { top_k };
    if (text !== undefined && text !== null) payload.text = text;
    if (vector !== undefined && vector !== null) payload.vector = [...vector];
    if (nprobe !== undefined && nprobe !== null) payload.nprobe = nprobe;
    if (filter_category !== undefined && filter_category !== null) payload.filter_category = filter_category;
    if (attributes !== undefined && attributes !== null) payload.attributes = [...attributes];
    const res = await this.request<QueryResult>("POST", this.nsUrl(ns, "query"), payload);
    if (attributes !== undefined && attributes !== null && Array.isArray(res.rows)) {
      const allowed = new Set([...attributes, "id", "score"]);
      res.rows = res.rows.map((row) => {
        const out: QueryResultRow = { id: row.id, score: row.score };
        for (const [k, v] of Object.entries(row)) {
          if (allowed.has(k)) {
            (out as Record<string, unknown>)[k] = v;
          }
        }
        return out;
      });
    }
    return res;
  }

  /** Perform hybrid BM25 full-text + vector search with optional attribute projection. */
  async hybrid_search(
    ns: string,
    text: string,
    vector: readonly number[],
    top_k = 10,
    nprobe?: number | null,
    filter_category?: string | null,
    attributes?: readonly string[] | null,
  ): Promise<QueryResult> {
    return this.query(ns, text, vector, top_k, nprobe, filter_category, attributes);
  }

  /** Namespace health. Returns `{"ns", "num_docs", "head", "fts_tokenizer"}`. */
  async health(ns: string): Promise<HealthResult> {
    return this.request<HealthResult>("GET", this.nsUrl(ns, "health"));
  }

  private nsUrl(ns: string, action: string): string {
    return `${this.endpoint}/v1/namespaces/${encodeURIComponent(ns)}/${action}`;
  }

  private async request<T>(method: string, url: string, payload?: Record<string, unknown>): Promise<T> {
    const init: RequestInit = { method, headers: { accept: "application/json" } };
    if (payload !== undefined) {
      init.body = JSON.stringify(payload);
      (init.headers as Record<string, string>)["content-type"] = "application/json";
    }
    if (typeof AbortSignal !== "undefined" && typeof AbortSignal.timeout === "function") {
      init.signal = AbortSignal.timeout(this.timeout * 1000);
    }

    let res: Response;
    try {
      res = await fetch(url, init);
    } catch (err) {
      const reason = err instanceof Error ? err.message : String(err);
      throw new TurboFishError(`turbofish request failed: ${method} ${url}: ${reason}`);
    }

    const text = await res.text().catch(() => "");
    if (!res.ok) {
      throw new TurboFishError(
        `turbofish request failed: HTTP ${res.status} ${res.statusText}: ${text.slice(0, 200)}`,
        res.status,
        text,
      );
    }
    try {
      return JSON.parse(text) as T;
    } catch {
      throw new TurboFishError(
        `turbofish returned invalid JSON (HTTP ${res.status}): ${text.slice(0, 200)}`,
        res.status,
        text,
      );
    }
  }
}
