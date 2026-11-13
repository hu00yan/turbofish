/**
 * turbofish HTTP API v0 minimal TypeScript client.
 *
 * Uses the global `fetch` API (Node >= 18, modern browsers). No dependencies.
 * Method and parameter names intentionally mirror the Python SDK verbatim
 * (`create_namespace`, `top_k`, `filter_category`, ...) — the two SDKs share
 * the same contract surface.
 *
 * Contract v0 (JSON):
 *   POST {endpoint}/v1/namespaces/{ns}/create  {"fts_tokenizer"?, "distance_metric"?}
 *     -> {"ok": true, "ns": string}
 *   POST {endpoint}/v1/namespaces/{ns}/write   {"rows": [...], "deletes"?, "distance_metric"?}
 *     -> {"ingested": number, "head": string}
 *   POST {endpoint}/v1/namespaces/{ns}/query   {"text"?, "vector"?, "top_k"?, "limit"?, "nprobe"?,
 *                                              "filter_category"?, "filter"?, "offset"?,
 *                                              "aggregations"?, "rank_constant"?, "fusion"?,
 *                                              "weights"?, "include_attributes"?, "exclude_attributes"?,
 *                                              "consistency"?}
 *     -> {"rows": [{"id","score","text","category"}...], "count": number}
 *        (aggregations=["Count"] -> {"count": number, "rows": []})
 *        (aggregations=[{"Sum":"field"}] -> {"count": number, "aggregations": {"field":{"sum":S}}, "rows": []})
 *   GET  {endpoint}/v1/namespaces/{ns}/health
 *     -> {"ns", "num_docs", "head", "fts_tokenizer"}
 *   POST {endpoint}/v1/namespaces/{ns}/delete_by_filter {"filter": [...]}
 *     -> {"deleted": number}
 *   POST {endpoint}/v1/namespaces/{ns}/copy   {"destination": string}
 *     -> {"ok": true}
 *   POST {endpoint}/v1/namespaces/{ns}/branch {"destination": string}
 *     -> {"ok": true}
 *
 * Authentication: if `apiKey` is supplied in options, every request carries
 * `Authorization: Bearer <key>`.
 */

/** distance_metric for `create_namespace` / `write`. */
export type DistanceMetric =
  | "cosine"
  | "euclidean"
  | "cosine_distance"
  | "euclidean_squared";

/** Query read consistency. */
export type Consistency = "strong" | "eventual";

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
  aggregations?: Record<string, Record<string, number>>;
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

export interface DeleteByFilterResult {
  deleted: number;
}

export interface CopyBranchResult {
  ok: boolean;
}

export interface TurboFishPatch {
  id: number;
  text?: string;
  category?: string;
  ts?: number;
  public?: boolean;
  [key: string]: unknown;
}

export interface PatchRowsResult {
  patched: number;
  head: string;
}

/** Options passed to the `TurboFishClient` constructor. */
export interface TurboFishClientOptions {
  /** Per-request timeout in seconds (default 30). */
  timeout?: number;
  /**
   * Optional API key. When provided, every request carries
   * `Authorization: Bearer <apiKey>`.
   */
  apiKey?: string;
}

export class TurboFishClient {
  readonly endpoint: string;
  /** Per-request timeout in seconds (default 30). */
  readonly timeout: number;
  /** Optional API key for Bearer auth. */
  readonly apiKey: string | undefined;

  constructor(endpoint: string, timeoutOrOptions: number | TurboFishClientOptions = 30) {
    if (!endpoint) throw new Error("endpoint must be a non-empty URL");
    this.endpoint = endpoint.replace(/\/+$/, "");
    if (typeof timeoutOrOptions === "number") {
      this.timeout = timeoutOrOptions;
      this.apiKey = undefined;
    } else {
      this.timeout = timeoutOrOptions.timeout ?? 30;
      this.apiKey = timeoutOrOptions.apiKey;
    }
  }

  /** Create a namespace. `fts_tokenizer`: "word" | "smartcn" | "kuromoji" | "nori"; `distance_metric`: see DistanceMetric. */
  async create_namespace(
    ns: string,
    fts_tokenizer?: string,
    distance_metric?: DistanceMetric,
  ): Promise<CreateNamespaceResult> {
    const payload: Record<string, unknown> = {};
    if (fts_tokenizer !== undefined && fts_tokenizer !== null) {
      payload.fts_tokenizer = fts_tokenizer;
    }
    if (distance_metric !== undefined && distance_metric !== null) {
      payload.distance_metric = distance_metric;
    }
    return this.request<CreateNamespaceResult>("POST", this.nsUrl(ns, "create"), payload);
  }

  /**
   * Write rows and/or delete ids. Returns `{"ingested": n, "head": ...}`.
   * `distance_metric` is sent at the top level of the write payload; rows themselves never carry it.
   */
  async write(
    ns: string,
    rows: readonly TurboFishRow[],
    deletes?: readonly number[],
    distance_metric?: DistanceMetric,
  ): Promise<WriteResult> {
    const payload: Record<string, unknown> = { rows: [...rows] };
    if (deletes !== undefined && deletes !== null) {
      payload.deletes = [...deletes];
    }
    if (distance_metric !== undefined && distance_metric !== null) {
      payload.distance_metric = distance_metric;
    }
    return this.request<WriteResult>("POST", this.nsUrl(ns, "write"), payload);
  }

  /** Upsert documents in batches of `batchSize`; `distance_metric` is forwarded to every `write`. */
  async batch_upsert(
    ns: string,
    rows: readonly TurboFishRow[],
    batchSize = 1000,
    distance_metric?: DistanceMetric,
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
      const res = await this.write(ns, chunk, undefined, distance_metric);
      totalIngested += res.ingested ?? chunk.length;
      lastHead = res.head ?? "";
      batches++;
    }
    return { ingested: totalIngested, head: lastHead, batches };
  }

  /** Convenience alias for `batch_upsert`. */
  async upsert(
    ns: string,
    rows: readonly TurboFishRow[],
    batchSize = 1000,
    distance_metric?: DistanceMetric,
  ): Promise<BatchUpsertResult> {
    return this.batch_upsert(ns, rows, batchSize, distance_metric);
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

  /**
   * Delete all documents matching `filter` via a server-side filter delete.
   *
   * Sends `POST /v1/namespaces/{ns}/delete_by_filter` with body `{"filter": filter}`.
   * Returns `{"deleted": count}`.
   */
  async deleteByFilter(ns: string, filter: readonly unknown[]): Promise<DeleteByFilterResult> {
    return this.request<DeleteByFilterResult>(
      "POST",
      this.nsUrl(ns, "delete_by_filter"),
      { filter },
    );
  }

  /**
   * Copy `sourceNs` to `destNs` (full copy, independent data).
   *
   * Sends `POST /v1/namespaces/{sourceNs}/copy` with body `{"destination": destNs}`.
   */
  async copyNamespace(sourceNs: string, destNs: string): Promise<CopyBranchResult> {
    return this.request<CopyBranchResult>(
      "POST",
      this.nsUrl(sourceNs, "copy"),
      { destination: destNs },
    );
  }

  /**
   * Branch `sourceNs` to `destNs` (copy-on-write branch).
   *
   * Sends `POST /v1/namespaces/{sourceNs}/branch` with body `{"destination": destNs}`.
   */
  async branchNamespace(sourceNs: string, destNs: string): Promise<CopyBranchResult> {
    return this.request<CopyBranchResult>(
      "POST",
      this.nsUrl(sourceNs, "branch"),
      { destination: destNs },
    );
  }

  /**
   * Apply partial attribute/field updates to documents in `ns`.
   * Sends `POST /v1/namespaces/{ns}/patch` with body `{"patches": patches}`.
   * Returns `{"patched": count, "head": manifest_id}`.
   */
  async patchRows(
    ns: string,
    patches: readonly TurboFishPatch[],
  ): Promise<PatchRowsResult> {
    if (!patches) throw new Error("patches is required");
    return this.request<PatchRowsResult>(
      "POST",
      this.nsUrl(ns, "patch"),
      { patches: [...patches] },
    );
  }

  /**
   * Query by FTS `text` and/or `vector` with optional attribute projection.
   *
   * v1 parameters (all optional, backward compatible):
   * - `filter`: a pre-built turbopuffer filter expression, passed through
   *   verbatim — leaf `["attr", "Eq", value]` (op in Eq/NotEq/In/NotIn/Lt/
   *   Lte/Gt/Gte/Glob), two-element sugar `["attr", value]` (= Eq), and
   *   combinators `["And", [...]]` / `["Or", [...]]` / `["Not", filter]`.
   * - `offset`: skip the first `offset` results.
   * - `limit`: alias for top_k (sent as "limit" in the payload).
   * - `aggregations`: e.g. `["Count"]` or `[{"Sum":"ts"}]`; the server then
   *   replies `{"count": N, "aggregations": {...}, "rows": []}`.
   * - `rank_constant`, `fusion`, `weights`: hybrid-ranking controls, only
   *   effective when both `text` and `vector` are given; `weights` is an
   *   object like `{ bm25: 1.0, vector: 1.0 }` passed through verbatim.
   * - `include_attributes` / `exclude_attributes`: server-side row attribute projection.
   * - `consistency`: "strong" | "eventual".
   */
  async query(
    ns: string,
    text?: string | null,
    vector?: readonly number[] | null,
    top_k = 10,
    nprobe?: number | null,
    filter_category?: string | null,
    attributes?: readonly string[] | null,
    filter?: readonly unknown[] | null,
    offset?: number | null,
    aggregations?: readonly unknown[] | null,
    rank_constant?: number | null,
    fusion?: string | null,
    weights?: Record<string, number> | null,
    include_attributes?: readonly string[] | null,
    exclude_attributes?: readonly string[] | null,
    consistency?: Consistency | null,
    limit?: number | null,
  ): Promise<QueryResult> {
    const payload: Record<string, unknown> = { top_k };
    if (limit !== undefined && limit !== null) payload.limit = limit;
    if (text !== undefined && text !== null) payload.text = text;
    if (vector !== undefined && vector !== null) payload.vector = [...vector];
    if (nprobe !== undefined && nprobe !== null) payload.nprobe = nprobe;
    if (filter_category !== undefined && filter_category !== null) payload.filter_category = filter_category;
    if (attributes !== undefined && attributes !== null) payload.attributes = [...attributes];
    if (filter !== undefined && filter !== null) payload.filter = filter;
    if (offset !== undefined && offset !== null) payload.offset = offset;
    if (aggregations !== undefined && aggregations !== null) payload.aggregations = [...aggregations];
    if (rank_constant !== undefined && rank_constant !== null) payload.rank_constant = rank_constant;
    if (fusion !== undefined && fusion !== null) payload.fusion = fusion;
    if (weights !== undefined && weights !== null) payload.weights = { ...weights };
    if (include_attributes !== undefined && include_attributes !== null) {
      payload.include_attributes = [...include_attributes];
    }
    if (exclude_attributes !== undefined && exclude_attributes !== null) {
      payload.exclude_attributes = [...exclude_attributes];
    }
    if (consistency !== undefined && consistency !== null) payload.consistency = consistency;
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

  /** Count documents matching `filter` via the server-side `Count` aggregation. */
  async count(
    ns: string,
    filter?: readonly unknown[] | null,
    consistency?: Consistency | null,
  ): Promise<number> {
    const res = await this.query(
      ns,
      undefined,
      undefined,
      10,
      undefined,
      undefined,
      undefined,
      filter,
      undefined,
      ["Count"],
      undefined,
      undefined,
      undefined,
      undefined,
      undefined,
      consistency,
    );
    return res.count;
  }

  /**
   * Perform hybrid BM25 full-text + vector search with optional attribute projection.
   * `rank_constant`, `fusion` and `weights` only take effect for hybrid
   * (text+vector) queries; `filter` accepts a pre-built turbopuffer filter
   * expression passed through verbatim (see `query`).
   */
  async hybrid_search(
    ns: string,
    text: string,
    vector: readonly number[],
    top_k = 10,
    nprobe?: number | null,
    filter_category?: string | null,
    attributes?: readonly string[] | null,
    filter?: readonly unknown[] | null,
    rank_constant?: number | null,
    fusion?: string | null,
    weights?: Record<string, number> | null,
  ): Promise<QueryResult> {
    return this.query(
      ns,
      text,
      vector,
      top_k,
      nprobe,
      filter_category,
      attributes,
      filter,
      undefined,
      undefined,
      rank_constant,
      fusion,
      weights,
      undefined,
      undefined,
      undefined,
    );
  }

  /** Namespace health. Returns `{"ns", "num_docs", "head", "fts_tokenizer"}`. */
  async health(ns: string): Promise<HealthResult> {
    return this.request<HealthResult>("GET", this.nsUrl(ns, "health"));
  }

  private nsUrl(ns: string, action: string): string {
    return `${this.endpoint}/v1/namespaces/${encodeURIComponent(ns)}/${action}`;
  }

  private async request<T>(method: string, url: string, payload?: Record<string, unknown>): Promise<T> {
    const headers: Record<string, string> = { accept: "application/json" };
    if (this.apiKey) {
      headers["authorization"] = `Bearer ${this.apiKey}`;
    }
    const init: RequestInit = { method, headers };
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
