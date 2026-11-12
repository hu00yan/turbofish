// cmd/serve：最小可用 HTTP API（官方 moonbitlang/async HTTP server，调包）。
//
// 契约 v0（与 sdk/python、sdk/typescript 共享）：
//   POST /v1/namespaces/{ns}/create  {"fts_tokenizer": "word|smartcn|kuromoji|nori"}（可省略）
//                                    → {"ok": true, "ns": "..."}
//   POST /v1/namespaces/{ns}/write   {"rows": [{"id","text","vector","category","ts","public"}],
//                                     "deletes": [id...]} → {"ingested": n, "head": id}
//   POST /v1/namespaces/{ns}/query   {"text"?, "vector"?, "top_k"?, "nprobe"?, "filter_category"?}
//                                    → {"rows": [{"id","score","text","category","ts","public"}], "count": n}
//     v1 富化：rows 完整返回 id + score + text + category + ts + public，对齐 Turbopuffer。
//     text+vector 同给：简单 RRF 合并（1/(60+rank)）。
//   GET  /v1/namespaces/{ns}/health  → {"ns","num_docs","head","fts_tokenizer"}
//   OPTIONS 任意路径 → 204（CORS）。
//
// 存储：SPND_STORE=fs:PATH（默认 fs:/tmp/spnd-data）| s3（S3_* 环境变量）| sim（SimStore 仿真）。
// 端口：SPND_PORT（默认 8080）。鉴权：v0 无。
// namespace 的 fts_tokenizer 落在 namespace.json（init_namespace 写 cfg.fts_tokenizer），
// 写路径以已有 meta 为准（build/query 两侧同一分词器）。

///|
fn err_msg(e : @core.SpndError) -> String {
  match e {
    @core.BadMagic(s) => "BadMagic(\{s})"
    @core.Truncated(s) => "Truncated(\{s})"
    @core.Corrupt(s) => "Corrupt(\{s})"
    @core.NotFound(s) => "NotFound(\{s})"
    @core.CommitConflict(s) => "CommitConflict(\{s})"
  }
}

///|
/// create 意图（首个 write 前记录 tokenizer；namespace 一旦落盘以 meta 为准）。
let created_tokenizers : Map[String, @core.Tokenizer] = Map([])

///|
fn env_or(key : String, dflt : String) -> String {
  match @env.get_env_var(key) {
    Some(v) => v
    None => dflt
  }
}

///|
/// 多后端存储包装：支持 fs:PATH、s3 与 sim (SimStore 仿真)。
pub(all) enum AnyStore {
  FS(@fsstore.FsStore)
  S3(@s3store.S3Store[@s3http.CurlTransport])
  Sim(@simstore.SimStore)
}

///|
pub impl @store.ObjectStore for AnyStore with get(self, key) {
  match self {
    FS(s) => s.get(key)
    S3(s) => s.get(key)
    Sim(s) => s.get(key)
  }
}

///|
pub impl @store.ObjectStore for AnyStore with put(self, key, bs) {
  match self {
    FS(s) => s.put(key, bs)
    S3(s) => s.put(key, bs)
    Sim(s) => s.put(key, bs)
  }
}

///|
pub impl @store.ObjectStore for AnyStore with put_if_match(
  self,
  key,
  expected,
  bs
) {
  match self {
    FS(s) => s.put_if_match(key, expected, bs)
    S3(s) => s.put_if_match(key, expected, bs)
    Sim(s) => s.put_if_match(key, expected, bs)
  }
}

///|
pub impl @store.ObjectStore for AnyStore with get_range(self, key, offset, len) {
  match self {
    FS(s) => s.get_range(key, offset, len)
    S3(s) => s.get_range(key, offset, len)
    Sim(s) => s.get_range(key, offset, len)
  }
}

///|
pub impl @store.ObjectStore for AnyStore with list(self, prefix) {
  match self {
    FS(s) => s.list(prefix)
    S3(s) => s.list(prefix)
    Sim(s) => s.list(prefix)
  }
}

///|
pub impl @store.ObjectStore for AnyStore with delete(self, key) {
  match self {
    FS(s) => s.delete(key)
    S3(s) => s.delete(key)
    Sim(s) => s.delete(key)
  }
}

///|
pub fn make_store() -> AnyStore raise @core.SpndError {
  let spec = env_or("SPND_STORE", "fs:/tmp/spnd-data")
  if spec.has_prefix("fs:") {
    return FS(@fsstore.FsStore::new(spec[3:].to_owned()))
  }
  if spec == "s3" {
    let transport = @s3http.CurlTransport::new()
    return S3(
      @s3store.S3Store::new(
        env_or("S3_ENDPOINT", "http://127.0.0.1:9000"),
        env_or("S3_BUCKET", "seekpond"),
        env_or("S3_REGION", "us-east-1"),
        {
          access_key: env_or("S3_ACCESS_KEY", "minioadmin"),
          secret_key: env_or("S3_SECRET_KEY", "minioadmin"),
        },
        transport,
        fn() { @s3http.now_amz_date() },
      ),
    )
  }
  if spec == "sim" || spec.has_prefix("sim:") {
    let seed_str = env_or("SPND_SIM_SEED", "42")
    let mut seed = 42U
    let mut s_val = 0UL
    let mut valid = true
    for c in seed_str {
      if c >= '0' && c <= '9' {
        s_val = s_val * 10UL + (c.to_int() - '0'.to_int()).to_uint64()
      } else {
        valid = false
        break
      }
    }
    if valid && s_val > 0UL {
      seed = s_val.to_uint()
    }
    let sim_cfg = @simstore.SimConfig::aws_default(seed)
    return Sim(@simstore.SimStore::new(sim_cfg))
  }
  raise @core.Corrupt("SPND_STORE must be fs:PATH, s3, or sim, got \{spec}")
}

///|
struct NamespaceState {
  engine : @mtree.MergeTreeEngine[AnyStore]
  compactor : @mtree.Compactor[AnyStore]
}

///|
let active_ns : Map[String, NamespaceState] = Map([])

///|
fn get_or_create_ns_state(
  store : AnyStore,
  ns : String,
  dim : Int,
) -> NamespaceState raise @core.SpndError {
  match active_ns.get(ns) {
    Some(state) => state
    None => {
      let engine = @mtree.MergeTreeEngine::new(store, ns, dim, false, None)
      let config : @mtree.CompactionTriggerConfig = {
        l0_threshold: 4,
        tombstone_ratio_threshold: 0.20,
        idle_fallback_ms: 5000L,
        max_merge_parts: 16,
      }
      let policy = @mtree.TieredMergePolicy::new(config)
      let compactor = @mtree.Compactor::new(engine, policy, config)
      let state : NamespaceState = { engine, compactor }
      active_ns.set(ns, state)
      state
    }
  }
}

///|
async fn background_compactor_loop() -> Unit {
  for ;; {
    @async.sleep(200)
    let now = @async.now()
    for ns, state in active_ns {
      try {
        let res = state.compactor.tick(now)
        match res {
          Some(r) =>
            println(
              "[compactor] ns=\{ns} compacted parts=\{r.merged_parts_count} -> \{r.output_part_id} rows=\{r.output_row_count} tombstones_purged=\{r.tombstones_purged} new_seq=\{r.new_seq}",
            )
          None => ()
        }
      } catch {
        e => println("[compactor] error compacting ns=\{ns}: \{err_msg(e)}")
      }
    }
  }
}

///|
struct DocAttributes {
  text : String
  category : String
  ts : Int64
  public : Bool
}

///|
struct SegmentCache {
  ids : Array[UInt64]
  texts : Array[String]
  cats : Array[String]
  tss : Array[Int64]
  pubs : Array[Bool]
}

///|
let seg_cache : Map[String, SegmentCache] = Map([])

///|
fn[T : @store.ObjectStore] load_segment_cache(
  store : T,
  ns : String,
  seg_id : String,
) -> SegmentCache? raise @core.SpndError {
  let base = "\{ns}/_segments/\{seg_id}"
  let id_bs = match store.get("\{base}/rows/id.bin") {
    Some(b) => b
    None => return None
  }
  let ids = match @format.decode_col(id_bs) {
    @format.ColU64(a) => a
    _ => return None
  }
  let texts = match store.get("\{base}/rows/text.bin") {
    Some(b) =>
      match @format.decode_col(b) {
        @format.ColStr(a) => a
        _ => []
      }
    None => []
  }
  let cats = match store.get("\{base}/rows/category.bin") {
    Some(b) =>
      match @format.decode_col(b) {
        @format.ColStr(a) => a
        _ => []
      }
    None => []
  }
  let tss = match store.get("\{base}/rows/ts.bin") {
    Some(b) =>
      match @format.decode_col(b) {
        @format.ColI64(a) => a
        _ => []
      }
    None => []
  }
  let pubs = match store.get("\{base}/rows/public.bin") {
    Some(b) =>
      match @format.decode_col(b) {
        @format.ColBool(a) => a
        _ => []
      }
    None => []
  }
  let sc : SegmentCache = { ids, texts, cats, tss, pubs }
  seg_cache.set(seg_id, sc)
  Some(sc)
}

///|
fn[T : @store.ObjectStore] lookup_doc_attrs(
  store : T,
  ns : String,
  n : @query.Namespace[T],
  doc_id : UInt64,
) -> DocAttributes {
  match active_ns.get(ns) {
    Some(state) => {
      let live = (state.engine.read_live_docs()) catch { _ => [] }
      for d in live {
        if d.id == doc_id {
          return {
            text: d.text,
            category: d.category,
            ts: d.ts,
            public: d.public,
          }
        }
      }
    }
    None => ()
  }
  let mut s_idx = n.manifest.segments.length() - 1
  while s_idx >= 0 {
    let seg = n.manifest.segments[s_idx]
    if doc_id >= seg.min_id && doc_id <= seg.max_id {
      let sc = match seg_cache.get(seg.id) {
        Some(sc) => Some(sc)
        None => (load_segment_cache(store, ns, seg.id)) catch { _ => None }
      }
      match sc {
        Some(c) =>
          for i in 0..<c.ids.length() {
            if c.ids[i] == doc_id {
              let text = if i < c.texts.length() { c.texts[i] } else { "" }
              let category = if i < c.cats.length() { c.cats[i] } else { "" }
              let ts = if i < c.tss.length() { c.tss[i] } else { 0L }
              let public = if i < c.pubs.length() { c.pubs[i] } else { true }
              return { text, category, ts, public }
            }
          }
        None => ()
      }
    }
    s_idx -= 1
  }
  { text: "", category: "", ts: 0L, public: true }
}

///|
async fn respond(
  conn : @http.ServerConnection,
  code : Int,
  body : String,
) -> Unit {
  let headers : @http.Headers = Map([])
  headers.set(
    @http.CaseInsensitiveString("access-control-allow-origin"),
    "*",
  )
  headers.set(
    @http.CaseInsensitiveString("content-type"),
    "application/json",
  )
  let reason = match code {
    200 => "OK"
    204 => "No Content"
    400 => "Bad Request"
    404 => "Not Found"
    405 => "Method Not Allowed"
    _ => "Internal Server Error"
  }
  conn.send_response(code, reason, extra_headers=headers)
  if code != 204 {
    conn.write_string(body)
  }
  conn.end_response()
}

///|
/// ns 从 /v1/namespaces/{ns}/{action} 提取；v0 不做 percent-decode（简单名）。
fn split_ns_path(path : String) -> (String, String)? {
  let prefix = "/v1/namespaces/"
  if !path.has_prefix(prefix) {
    return None
  }
  let rest = path[prefix.length():]
  match rest.find("/") {
    Some(i) => Some((rest[:i].to_owned(), rest[i + 1:].to_owned()))
    None => Some((rest.to_owned(), ""))
  }
}

///|
/// namespace meta（namespace.json 缺失/损坏 → None）。
fn[T : @store.ObjectStore] ns_meta(
  store : T,
  ns : String,
) -> @format.NamespaceMeta? raise @core.SpndError {
  match store.get("\{ns}/_meta/namespace.json") {
    Some(bs) => {
      let j = @json.parse(@utf8.decode(bs.view())) catch {
        _ => return None
      }
      (try {
        Some(@format.namespace_from_json(j))
      } catch {
        _ => None
      })
    }
    None => None
  }
}

///|
struct WriteReq {
  docs : Array[@core.Doc]
  deletes : Array[UInt64]
  tokenizer : @core.Tokenizer?
  has_vector : Bool
}

///|
fn parse_row_vector(arr : Array[Json]) -> Array[Float] raise @core.SpndError {
  let v : Array[Float] = Array::new(capacity=arr.length())
  for x in arr {
    match x {
      Number(d, ..) => v.push(Float::from_double(d))
      _ => raise @core.Corrupt("vector element must be number")
    }
  }
  v
}

///|
fn u64_from_json(j : Json) -> UInt64 raise @core.SpndError {
  match j {
    Number(d, ..) => {
      if d < 0.0 || d >= 18446744073709551616.0 {
        raise @core.Corrupt("id out of uint64 range")
      }
      d.to_int64().to_uint64()
    }
    _ => raise @core.Corrupt("id must be number")
  }
}

///|
fn parse_write(body : String) -> WriteReq raise @core.SpndError {
  let j = @json.parse(body) catch {
    _ => raise @core.Corrupt("body is not valid JSON")
  }
  let m = match j {
    Object(mm) => mm
    _ => raise @core.Corrupt("body must be a JSON object")
  }
  let docs : Array[@core.Doc] = Array::new()
  let mut has_vector = false
  let mut has_no_vector = false
  match m.get("rows") {
    Some(Array(rows)) =>
      for r in rows {
        let rm = match r {
          Object(rm) => rm
          _ => raise @core.Corrupt("row must be object")
        }
        let id = u64_from_json(
          match rm.get("id") {
            Some(v) => v
            None => raise @core.Corrupt("row missing id")
          },
        )
        let text = match rm.get("text") {
          Some(String(s)) => s
          _ => ""
        }
        let category = match rm.get("category") {
          Some(String(s)) => s
          _ => ""
        }
        let ts = match rm.get("ts") {
          Some(Number(d, ..)) => d.to_int64()
          _ => 0L
        }
        let public = match rm.get("public") {
          Some(True) => true
          Some(False) => false
          _ => true
        }
        let vector : Array[Float] = match rm.get("vector") {
          Some(Array(a)) => {
            has_vector = true
            parse_row_vector(a)
          }
          _ => {
            has_no_vector = true
            []
          }
        }
        docs.push({ id, text, vector, category, ts, public })
      }
    _ => ()
  }
  if has_vector && has_no_vector {
    raise @core.Corrupt(
      "rows must be homogeneous: all rows need vector or none",
    )
  }
  let deletes : Array[UInt64] = Array::new()
  match m.get("deletes") {
    Some(Array(a)) =>
      for x in a {
        deletes.push(u64_from_json(x))
      }
    _ => ()
  }
  let tokenizer = match m.get("fts_tokenizer") {
    Some(String(s)) =>
      match @core.parse_tokenizer(s) {
        Some(t) => Some(t)
        None => raise @core.Corrupt("unknown fts_tokenizer \{s}")
      }
    _ => None
  }
  { docs, deletes, tokenizer, has_vector }
}

///|
fn[T : @store.ObjectStore] cfg_for(
  store : T,
  ns : String,
  rows_have_vector : Bool,
  tok_override : @core.Tokenizer?,
  vector_dim : Int,
) -> @build.BuildConfig raise @core.SpndError {
  let cfg = @build.BuildConfig::single_copy(ns)
  match ns_meta(store, ns) {
    Some(meta) => {
      let tok = match meta.fts_tokenizer {
        Some(s) =>
          match @core.parse_tokenizer(s) {
            Some(t) => t
            None => @core.Word
          }
        None => @core.Word
      }
      { ..cfg, vector_dim: meta.vector_dim, fts_tokenizer: tok }
    }
    None => {
      let tok = match tok_override {
        Some(t) => t
        None =>
          match created_tokenizers.get(ns) {
            Some(t) => t
            None => @core.Word
          }
      }
      if not(rows_have_vector) {
        raise @core.Corrupt("first write of a namespace must include vector")
      }
      { ..cfg, fts_tokenizer: tok, vector_dim }
    }
  }
}

///|
async fn handle_query(
  store : AnyStore,
  ns : String,
  body : String,
  conn : @http.ServerConnection,
) -> Unit raise {
  let j = @json.parse(body) catch {
    _ => raise @core.Corrupt("body is not valid JSON")
  }
  let m = match j {
    Object(mm) => mm
    _ => raise @core.Corrupt("body must be object")
  }
  let text = match m.get("text") {
    Some(String(s)) => Some(s)
    _ => None
  }
  let qv : Array[Float]? = match m.get("vector") {
    Some(Array(a)) => Some(parse_row_vector(a))
    _ => None
  }
  let top_k = match m.get("top_k") {
    Some(Number(d, ..)) => d.to_int()
    _ => 10
  }
  let nprobe = match m.get("nprobe") {
    Some(Number(d, ..)) => d.to_int()
    _ => 8
  }
  let filter : @query.Filter? = match m.get("filter_category") {
    Some(String(s)) => Some(@query.FStr("category", s))
    _ => None
  }
  let n = @query.open(store, ns)
  let rows_json : Array[Json] = Array::new()

  let format_row = fn(r : @query.QueryResult) -> Json {
    let attr = lookup_doc_attrs(store, ns, n, r.id)
    let row_map : Map[String, Json] = Map([])
    row_map.set("id", Json::number(r.id.to_double()))
    row_map.set("score", Json::number(r.score))
    row_map.set("text", Json::string(attr.text))
    row_map.set("category", Json::string(attr.category))
    row_map.set("ts", Json::number(attr.ts.to_double()))
    row_map.set("public", Json::boolean(attr.public))
    Json::object(row_map)
  }

  match (text, qv) {
    (Some(t), Some(v)) =>
      for r in @query.hybrid_search(n, t, v, top_k, nprobe, filter) {
        rows_json.push(format_row(r))
      }
    (Some(t), None) =>
      for r in @query.bm25_search(n, t, top_k, filter) {
        rows_json.push(format_row(r))
      }
    (_, Some(v)) =>
      for r in @query.vec_search(n, v, top_k, nprobe, filter) {
        rows_json.push(format_row(r))
      }
    (None, None) => raise @core.Corrupt("query needs text or vector")
  }
  let out : Map[String, Json] = Map([])
  out.set("rows", Json::array(rows_json))
  out.set("count", Json::number(rows_json.length().to_double()))
  respond(conn, 200, Json::object(out).stringify())
}

///|
async fn handle_write(
  store : AnyStore,
  ns : String,
  body : String,
  conn : @http.ServerConnection,
) -> Unit raise {
  let w = parse_write(body)
  let mut dim = 0
  if w.docs.length() > 0 {
    dim = w.docs[0].vector.length()
  }
  let cfg = cfg_for(store, ns, w.has_vector, w.tokenizer, dim)
  if w.docs.length() > 0 {
    if ns_meta(store, ns) is Some(_) {
      let _ = @build.ingest_delta_opts(store, cfg, w.docs, 8, true)
    } else {
      let _ = @build.ingest(store, cfg, w.docs)
    }
  }
  if w.deletes.length() > 0 {
    @build.delete_docs(store, cfg, w.deletes)
  }
  let build_head = @store.read_head(store, ns, "")

  // 同步推进 MergeTreeEngine 并通知 in-process Compactor
  try {
    let state = get_or_create_ns_state(store, ns, dim)
    if w.docs.length() > 0 && state.engine.get_manifest().parts.is_empty() {
      let _ = state.engine.append_base_part(w.docs)
    } else if w.docs.length() > 0 && w.deletes.length() > 0 {
      let _ = state.engine.mutate_rows(w.docs, w.deletes)
    } else if w.docs.length() > 0 {
      let _ = state.engine.append_l0_delta_part(w.docs)
    } else if w.deletes.length() > 0 {
      state.engine.soft_delete(w.deletes)
    }
    if w.docs.length() > 0 || w.deletes.length() > 0 {
      state.engine.publish_manifest()
      let now = @async.now()
      state.compactor.notify_mutation(now)
    }
  } catch {
    _ => ()
  }
  if build_head != "" {
    store.put(@store.head_pointer_key(ns), @utf8.encode(build_head))
  }

  let head = build_head
  let out : Map[String, Json] = Map([])
  out.set("ingested", Json::number(w.docs.length().to_double()))
  out.set("head", Json::string(head))
  respond(conn, 200, Json::object(out).stringify())
}

///|
async fn handle_health(
  store : AnyStore,
  ns : String,
  conn : @http.ServerConnection,
) -> Unit raise {
  let n = @query.open(store, ns)
  let live_count = n.manifest.num_docs - n.manifest.deleted.length()
  let out : Map[String, Json] = Map([])
  out.set("ns", Json::string(ns))
  out.set("num_docs", Json::number(live_count.to_double()))
  out.set("head", Json::string(n.manifest.id))
  out.set(
    "fts_tokenizer",
    match n.meta.fts_tokenizer {
      Some(s) => Json::string(s)
      None => Json::string("word")
    },
  )
  match store {
    Sim(s) => {
      let cost = s.cost()
      let cost_m : Map[String, Json] = Map([])
      cost_m.set("bill_total", Json::number(cost.bill_total))
      cost_m.set("total_latency_us", Json::number(cost.total_latency_us))
      cost_m.set("s3_gets", Json::number(cost.s3_gets.to_double()))
      cost_m.set("puts", Json::number(cost.puts.to_double()))
      cost_m.set("lists", Json::number(cost.lists.to_double()))
      out.set("sim_cost", Json::object(cost_m))
    }
    _ => ()
  }
  respond(conn, 200, Json::object(out).stringify())
}

///|
async fn dispatch(
  store : AnyStore,
  req : @http.Request,
  reader : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  let path = req.path
  if req.meth is Options {
    respond(conn, 204, "")
    return
  }
  match split_ns_path(path) {
    Some((ns, action)) => {
      if ns.length() == 0 {
        respond(conn, 404, "{\"error\":\"missing namespace\"}")
        return
      }
      match (action, req.meth) {
        ("create", Post) => {
          let body = (reader.read_all()).text() catch {
            _ => ""
          }
          if body.trim() != "" && body.trim() != "{}" {
            let j = @json.parse(body) catch {
              _ => {
                respond(conn, 400, "{\"error\":\"body must be object\"}")
                return
              }
            }
            match j {
              Object(m) =>
                match m.get("fts_tokenizer") {
                  Some(String(s)) =>
                    match @core.parse_tokenizer(s) {
                      Some(t) => created_tokenizers.set(ns, t)
                      None => {
                        respond(
                          conn,
                          400,
                          "{\"error\":\"unknown fts_tokenizer\"}",
                        )
                        return
                      }
                    }
                  _ => ()
                }
              _ => {
                respond(conn, 400, "{\"error\":\"body must be object\"}")
                return
              }
            }
          }

          let out : Map[String, Json] = Map([])
          out.set("ok", Json::boolean(true))
          out.set("ns", Json::string(ns))
          respond(conn, 200, Json::object(out).stringify())
        }
        ("write", Post) => {
          let body = (reader.read_all()).text() catch {
            _ => ""
          }
          handle_write(store, ns, body, conn) catch {
            _ => respond(conn, 400, "{\"error\":\"write failed (see server log)\"}")
          }
        }
        ("query", Post) => {
          let body = (reader.read_all()).text() catch {
            _ => ""
          }
          handle_query(store, ns, body, conn) catch {
            e => {
              let msg = match e {
                @core.Corrupt(s) => "Corrupt(\{s})"
                @core.NotFound(s) => "NotFound(\{s})"
                @core.Truncated(s) => "Truncated(\{s})"
                @core.BadMagic(s) => "BadMagic(\{s})"
                @core.CommitConflict(s) => "CommitConflict(\{s})"
                _ => "\{e}"
              }
              println("[serve query error] \{msg}")
              respond(conn, 400, "{\"error\":\"query failed: \{msg}\"}")
            }
          }
        }
        ("health", Get) =>
          handle_health(store, ns, conn) catch {
            _ => respond(conn, 404, "{\"error\":\"namespace not found\"}")
          }
        (_, _) => respond(conn, 405, "{\"error\":\"method not allowed\"}")
      }
    }
    None => respond(conn, 404, "{\"error\":\"not found\"}")
  }
}

///|
async fn main {
  let port = env_or("SPND_PORT", "8080")
  let store = make_store() catch {
    e => {
      println("store init failed: \{err_msg(e)}")
      return
    }
  }
  let addr = @socket.Addr::parse("0.0.0.0:\{port}")
  let server = @http.Server::Server(addr, reuse_addr=true)
  println("turbofish serve on 0.0.0.0:\{port}")
  @async.with_task_group(async fn (group) {
    let _ = group.spawn(
      async fn () {
        background_compactor_loop()
      },
      no_wait=true,
      allow_failure=true,
    )
    server.run_forever(
      async fn (req, reader, conn) {
        dispatch(store, req, reader, conn) catch {
          _ => respond(conn, 500, "{\"error\":\"internal error\"}")
        }
      },
    )
  })
}
