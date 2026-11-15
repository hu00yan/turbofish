// cmd/serve：最小可用 HTTP API（官方 moonbitlang/async HTTP server，调包）。
//
// 契约 v1（与 sdk/python、sdk/typescript 共享）：
//   POST /v1/namespaces/{ns}/create  {"fts_tokenizer"?, "distance_metric"?: "cosine"|"euclidean"}
//                                    → {"ok": true, "ns": "..."}
//   POST /v1/namespaces/{ns}/write   {"rows": [{"id","text","vector","category","ts","public"}],
//                                     "deletes": [id...], "distance_metric"?}
//                                    → {"ingested": n, "head": id}
//   POST /v1/namespaces/{ns}/query   {
//       "text"?, "vector"?, "top_k"?, "nprobe"?,
//       "filter"?: tpf 数组语法（见下）, "filter_category"?（旧参数，与 filter 互斥）,
//       "offset"?: ≥0（默认 0，top_k+offset ≤ 10000）,
//       "aggregations"?: ["Count"]（与 text/vector 互斥；"aggregate":"count" 等价简写）,
//       "rank_constant"?, "fusion"?: "rrf"|"linear", "weights"?: {"bm25","vector"},  // hybrid
//       "include_attributes"? / "exclude_attributes"?: [字段...]（id/score 恒返回）,
//       "consistency"?: "strong"（默认，直读 head）|"eventual"（进程级 metadata cache）}
//     → {"rows": [{"id","score",...attrs}], "count": n} 或聚合 → {"count": N, "rows": []}
//     filter 数组语法（对齐 Turbopuffer v2）：
//       ["attr", "Eq", v]（op: Eq/NotEq/In/NotIn/Lt/Lte/Gt/Gte；["attr", v] 是 Eq 糖）
//       ["And", [f...]] / ["Or", [f...]] / ["Not", f]，任意嵌套。
//     v1 富化：rows 完整返回 id + score + 请求的属性子集；text+vector 同给走
//     RRF/linear 混合（rank_constant/weights 可调）。
//   GET  /v1/namespaces/{ns}/health  → {"ns","num_docs","head","fts_tokenizer"}
//   OPTIONS 任意路径 → 204（CORS）。
//
// 存储：SPND_STORE=fs:PATH（默认 fs:/tmp/spnd-data）| s3（S3_* 环境变量）| sim（SimStore 仿真）。
// 端口：SPND_PORT（默认 8080）。鉴权：v0 无。
// namespace 的 fts_tokenizer / distance_metric 落在 namespace.json（首次 write 时由
// init_namespace 按 cfg 写入；namespace 一旦落盘以 meta 为准，metric 不可再改）。

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
/// create 意图（首个 write 前记录 tokenizer / distance_metric；namespace 一旦落盘以 meta 为准）。
let created_tokenizers : Map[String, @core.Tokenizer] = Map([])

///|
let created_metrics : Map[String, String] = Map([])

///|
/// 进程级 metadata cache（consistency="eventual" 时走 open_cached，head TTL 1s）。
let meta_cache : @query.MetadataCache[AnyStore] = @query.MetadataCache::new()

///|
/// 元数据服务地址（SPND_META_URL，例如 http://127.0.0.1:8090）。
/// 为空时所有元数据仍回源对象存储，行为与旧版一致。
let meta_url : Ref[String] = { val: "" }

///|
/// 元数据 key 前缀（SPND_META_PREFIX）。多个 bucket 共用一个 metad 时用它隔离，
/// 例如 bucket 名加 "/"。
let meta_prefix : Ref[String] = { val: "" }

///|
fn meta_key(key : String) -> String {
  meta_prefix.val + key
}

///|
/// 元数据服务使用独立的短连接 transport；只在冷启动加载元数据时使用，
/// 热查询路径命中进程内缓存后不会再访问它。
let meta_http : @s3http.CurlTransport = @s3http.CurlTransport::new()

///|
fn meta_get(key : String) -> Bytes? {
  if meta_url.val == "" || !@meta.is_metadata_key(key) {
    return None
  }
  let (status, _headers, body) : (Int, Array[(String, String)], Bytes) = meta_http.execute(
    "GET",
    meta_url.val + @meta.METAD_KV_PREFIX + meta_key(key),
    [],
    b"",
  )
  if status == 200 {
    Some(body)
  } else {
    None
  }
}

///|
fn meta_put(key : String, bs : Bytes) -> Unit {
  if meta_url.val == "" || !@meta.is_metadata_key(key) {
    return
  }
  let (_status, _headers, _body) : (Int, Array[(String, String)], Bytes) = meta_http.execute(
    "PUT",
    meta_url.val + @meta.METAD_KV_PREFIX + meta_key(key),
    [],
    bs,
  )
}

///|
fn meta_delete(key : String) -> Unit {
  if meta_url.val == "" || !@meta.is_metadata_key(key) {
    return
  }
  let (_status, _headers, _body) : (Int, Array[(String, String)], Bytes) = meta_http.execute(
    "DELETE",
    meta_url.val + @meta.METAD_KV_PREFIX + meta_key(key),
    [],
    b"",
  )
}

///|
/// 校验 distance_metric 取值。支持 Turbopuffer 规范名 cosine_distance / euclidean_squared。
fn parse_metric(j : Json) -> String? {
  match j {
    String(s) =>
      if s == "cosine" || s == "cosine_distance" {
        Some("cosine")
      } else if s == "euclidean" || s == "euclidean_squared" {
        Some("euclidean")
      } else {
        None
      }
    _ => None
  }
}

///|
fn env_or(key : String, dflt : String) -> String {
  match @env.get_env_var(key) {
    Some(v) => v
    None => dflt
  }
}

///|
fn parse_int_str(s : String) -> Int? {
  if s == "" {
    return None
  }
  let mut n = 0
  for ch in s.iter() {
    let c = ch.to_int()
    if c < 48 || c > 57 {
      return None
    }
    n = n * 10 + (c - 48)
  }
  Some(n)
}

///|
/// 多后端存储包装：支持 fs:PATH、s3 与 sim (SimStore 仿真)。
pub(all) enum AnyStore {
  FS(@fsstore.FsStore)
  S3(@s3store.S3Store[@s3http.CurlTransport])
  Sim(@simstore.SimStore)
}

///|
fn raw_get(store : AnyStore, key : String) -> Bytes? {
  match store {
    FS(s) => s.get(key)
    S3(s) => s.get(key)
    Sim(s) => s.get(key)
  }
}

///|
fn raw_get_range(
  store : AnyStore,
  key : String,
  offset : Int,
  len : Int,
) -> Bytes? {
  match store {
    FS(s) => s.get_range(key, offset, len)
    S3(s) => s.get_range(key, offset, len)
    Sim(s) => s.get_range(key, offset, len)
  }
}

///|
fn raw_list(store : AnyStore, prefix : String) -> Array[String] {
  match store {
    FS(s) => s.list(prefix)
    S3(s) => s.list(prefix)
    Sim(s) => s.list(prefix)
  }
}

///|
fn raw_head_version(store : AnyStore, key : String) -> String? {
  match store {
    FS(s) => s.head_version(key)
    S3(s) => s.head_version(key)
    Sim(s) => s.head_version(key)
  }
}

///|
pub impl @store.ObjectStore for AnyStore with get(self, key) {
  let cached = meta_get(key)
  let bs = match cached {
    Some(bs) => Some(bs)
    None => raw_get(self, key)
  }
  match bs {
    Some(bs) => {
      if cached is None && @meta.is_metadata_key(key) {
        meta_put(key, bs)
      }
      Some(bs)
    }
    None => resolve_branch_get(self, key)
  }
}

///|
pub impl @store.ObjectStore for AnyStore with put(self, key, bs) {
  match self {
    FS(s) => s.put(key, bs)
    S3(s) => s.put(key, bs)
    Sim(s) => s.put(key, bs)
  }
  meta_put(key, bs)
}

///|
pub impl @store.ObjectStore for AnyStore with put_if_match(
  self,
  key,
  expected,
  bs
) {
  let ok = match self {
    FS(s) => s.put_if_match(key, expected, bs)
    S3(s) => s.put_if_match(key, expected, bs)
    Sim(s) => s.put_if_match(key, expected, bs)
  }
  if ok {
    meta_put(key, bs)
  }
  ok
}

///|
pub impl @store.ObjectStore for AnyStore with get_range(self, key, offset, len) {
  if @meta.is_metadata_key(key) {
    match AnyStore::get(self, key) {
      Some(bs) =>
        if offset < 0 || len < 0 || offset > bs.length() {
          Some(b"")
        } else {
          let end = if offset + len > bs.length() {
            bs.length()
          } else {
            offset + len
          }
          Some(bs[offset:end].to_owned())
        }
      None => None
    }
  } else {
    match raw_get_range(self, key, offset, len) {
      Some(bs) => Some(bs)
      None => resolve_branch_get_range(self, key, offset, len)
    }
  }
}

///|
pub impl @store.ObjectStore for AnyStore with list(self, prefix) {
  let local_keys = raw_list(self, prefix)
  resolve_branch_list(self, prefix, local_keys)
}

///|
pub impl @store.ObjectStore for AnyStore with delete(self, key) {
  match self {
    FS(s) => s.delete(key)
    S3(s) => s.delete(key)
    Sim(s) => s.delete(key)
  }
  meta_delete(key)
}

///|
pub impl @store.ObjectStore for AnyStore with head_version(self, key) {
  match raw_head_version(self, key) {
    Some(v) => Some(v)
    None => resolve_branch_head_version(self, key)
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
    let endpoint = env_or(
      "AWS_ENDPOINT_URL_S3",
      env_or("AWS_ENDPOINT_URL", env_or("S3_ENDPOINT", "http://127.0.0.1:9000")),
    )
    let bucket = env_or("AWS_S3_BUCKET", env_or("S3_BUCKET", "seekpond"))
    let region = env_or(
      "AWS_REGION",
      env_or("AWS_DEFAULT_REGION", env_or("S3_REGION", "us-east-1")),
    )
    let access_key = env_or(
      "AWS_ACCESS_KEY_ID",
      env_or("S3_ACCESS_KEY", "minioadmin"),
    )
    let secret_key = env_or(
      "AWS_SECRET_ACCESS_KEY",
      env_or("S3_SECRET_KEY", "minioadmin"),
    )
    return S3(
      @s3store.S3Store::new(
        endpoint,
        bucket,
        region,
        {
          access_key,
          secret_key,
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
  mut build_head : String
  mut query_ns : @query.Namespace[AnyStore]?
  mut meta : @format.NamespaceMeta?
  doc_cache : Map[UInt64, DocAttributes]
  doc_full_cache : Map[UInt64, @core.Doc]
}

///|
let active_ns : Map[String, NamespaceState] = Map([])

///|
let global_coordinator : Ref[@control.Coordinator[AnyStore]?] = { val: None }

///|
fn get_coordinator(store : AnyStore) -> @control.Coordinator[AnyStore] {
  match global_coordinator.val {
    Some(coord) => coord
    None => {
      let worker_count_str = env_or("SPND_WORKERS", "4")
      let count = match parse_int_str(worker_count_str) {
        Some(c) => if c < 1 { 1 } else { c }
        None => 4
      }
      let cache_mb_str = env_or("SPND_WORKER_CACHE_MB", "64")
      let cache_mb = match parse_int_str(cache_mb_str) {
        Some(m) => if m < 1 { 1 } else { m }
        None => 64
      }
      let max_bytes = cache_mb * 1024 * 1024
      let ttl_sec_str = env_or("SPND_WORKER_CACHE_TTL_SEC", "300")
      let ttl_sec = match parse_int_str(ttl_sec_str) {
        Some(s) => if s < 1 { 1 } else { s }
        None => 300
      }
      let coord = @control.Coordinator::new(
        store,
        worker_count=count,
        worker_cache_ttl_ms=ttl_sec.to_uint64() * 1000UL,
        worker_max_bytes=max_bytes,
      )
      global_coordinator.val = Some(coord)
      coord
    }
  }
}

///|
pub fn reset_coordinator_for_test() -> Unit {
  global_coordinator.val = None
}

///|
/// 取得活跃的内存命名空间快照；已在内存中则零 I/O 返回，未加载时仅冷启动 open 一次。
fn NamespaceState::get_query_ns(
  self : NamespaceState,
  store : AnyStore,
  ns : String,
) -> @query.Namespace[AnyStore] raise @core.SpndError {
  let n = match self.query_ns {
    Some(existing) => existing
    None => {
      let snap = @query.open(store, ns)
      let _ = (try { @query.warm_namespace(snap) } catch { _ => () })
      self.query_ns = Some(snap)
      self.meta = Some(snap.meta)
      if self.build_head == "" {
        self.build_head = snap.manifest.id
      }
      meta_cache.entries.set(ns, snap)
      snap
    }
  }
  let coord = get_coordinator(store)
  if coord.get_tenant(ns) is None {
    coord.register_tenant(
      ns,
      n.manifest.id,
      n.meta.vector_dim,
      n.meta.distance_metric,
      n.meta.fts_tokenizer.unwrap_or(""),
      n.manifest.num_docs,
    )
  }
  n
}

///|
/// 写、补丁、Compaction 提交后立即更新协调者节点的内存元数据与快照，
/// 查询路径立即可见且无需发起任何 S3 元数据请求。
fn NamespaceState::update_after_write(
  self : NamespaceState,
  store : AnyStore,
  ns : String,
  new_head : String,
) -> Unit {
  self.build_head = new_head
  let man_key = "\{ns}/_manifest/\{new_head}.json"
  let man_bs = match store.get(man_key) {
    Some(bs) => bs
    None => return
  }
  let j = (@json.parse(@utf8.decode(man_bs.exact_view()))) catch {
    _ => return
  }
  let manifest = (@format.manifest_from_json(j)) catch {
    _ => return
  }
  let meta = match self.meta {
    Some(m) => { ..m, head_manifest: new_head }
    None =>
      match ns_meta(store, ns) {
        Some(m) => {
          let updated_m = { ..m, head_manifest: new_head }
          self.meta = Some(updated_m)
          updated_m
        }
        None => {
          let fallback_m : @format.NamespaceMeta = {
            format: "seekpond/v1",
            ns_name: ns,
            head_manifest: new_head,
            vec_global_version: None,
            distance_metric: "cosine",
            vector_dim: 0,
            vector_dtype: "f32",
            k1: @core.K1,
            b: @core.BM25_B,
            fts_tokenizer: None,
          }
          self.meta = Some(fallback_m)
          fallback_m
        }
      }
  }
  let old_cache : Map[String, @query.CachedSeg] = match self.query_ns {
    Some(old) => old.cache
    None => Map([])
  }
  let cent : @format.Centroids? = match self.query_ns {
    Some(old) =>
      if old.manifest.centroid_version == manifest.centroid_version {
        old.centroids
      } else {
        None
      }
    None => None
  }
  let global_gen_cids = match self.query_ns {
    Some(old) => old.global_gen_cids
    None => Map([])
  }
  let global_gen_packs = match self.query_ns {
    Some(old) => old.global_gen_packs
    None => Map([])
  }
  let global_parts = match self.query_ns {
    Some(old) => old.global_parts
    None => Map([])
  }
  let new_ns : @query.Namespace[AnyStore] = {
    store,
    ns,
    meta,
    manifest,
    centroids: cent,
    cache: old_cache,
    tombstones: None,
    vec_global_cids: None,
    global_gen_cids,
    global_gen_packs,
    global_parts,
    head_checked_ms: @env.now(),
  }
  let _ = (try { @query.warm_namespace(new_ns) } catch { _ => () })
  self.query_ns = Some(new_ns)
  meta_cache.entries.set(ns, new_ns)
  let coord = get_coordinator(store)
  coord.update_tenant_head(ns, new_head, manifest.num_docs)
}

///|
/// Prometheus 计数器。
let prom_requests_total : Ref[Int] = { val: 0 }

///|
let prom_queries_total : Ref[Int] = { val: 0 }

///|
let prom_writes_total : Ref[Int] = { val: 0 }

///|
/// 请求级别的鉴权检查：API key 验证（SPND_API_KEY 环境变量）。
/// 返回 true 表示请求已授权，false 表示需要返回 401。
fn check_auth(req : @http.Request) -> Bool {
  let api_key = match @env.get_env_var("SPND_API_KEY") {
    Some(k) => if k.trim() == "" { "" } else { k }
    None => ""
  }
  if api_key == "" {
    // 未配置 API key，全部放行
    return true
  }
  // 从 Authorization 头提取 Bearer token
  let auth_header = match req.headers.get(
    @http.CaseInsensitiveString("authorization"),
  ) {
    Some(v) => v
    None => return false
  }
  let prefix = "Bearer "
  if !auth_header.has_prefix(prefix) {
    return false
  }
  let token = auth_header[prefix.length():]
  token == api_key
}

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
      let state : NamespaceState = {
        engine,
        compactor,
        build_head: "",
        query_ns: None,
        meta: None,
        doc_cache: Map([]),
        doc_full_cache: Map([]),
      }
      active_ns.set(ns, state)
      state
    }
  }
}

///|
fn get_or_load_ns_state(
  store : AnyStore,
  ns : String,
) -> NamespaceState raise @core.SpndError {
  match active_ns.get(ns) {
    Some(state) => state
    None => {
      let snap = @query.open(store, ns)
      let _ = (try { @query.warm_namespace(snap) } catch { _ => () })
      let dim = snap.meta.vector_dim
      let state = get_or_create_ns_state(store, ns, dim)
      state.query_ns = Some(snap)
      state.meta = Some(snap.meta)
      state.build_head = snap.manifest.id
      meta_cache.entries.set(ns, snap)
      let coord = get_coordinator(store)
      if coord.get_tenant(ns) is None {
        coord.register_tenant(
          ns,
          snap.manifest.id,
          snap.meta.vector_dim,
          snap.meta.distance_metric,
          snap.meta.fts_tokenizer.unwrap_or(""),
          snap.manifest.num_docs,
        )
      }
      state
    }
  }
}

///|
async fn background_compactor_loop(store : AnyStore) -> Unit {
  for ;; {
    @async.sleep(200)
    let now = @async.now()
    for ns, state in active_ns {
      try {
        let res = state.compactor.tick(now)
        match res {
          Some(r) => {
            println(
              "[compactor] ns=\{ns} compacted parts=\{r.merged_parts_count} -> \{r.output_part_id} rows=\{r.output_row_count} tombstones_purged=\{r.tombstones_purged} new_seq=\{r.new_seq}",
            )
            if state.build_head != "" {
              store.put(@store.head_pointer_key(ns), @utf8.encode(state.build_head))
            }
          }
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
fn[T : @store.ObjectStore] lookup_doc_full(
  store : T,
  ns : String,
  n : @query.Namespace[T],
  doc_id : UInt64,
) -> @core.Doc? {
  match active_ns.get(ns) {
    Some(state) => {
      match state.doc_full_cache.get(doc_id) {
        Some(d) => return Some(d)
        None => ()
      }
      let live = (state.engine.read_live_docs()) catch { _ => [] }
      for d in live {
        if d.id == doc_id {
          state.doc_full_cache.set(doc_id, d)
          return Some(d)
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
              let mut vec : Array[Float] = []
              let vec_keys = store.list("\{ns}/_segments/\{seg.id}/vec/")
              for pkey in vec_keys {
                if pkey.has_prefix("\{ns}/_segments/\{seg.id}/vec/part-") &&
                  pkey.has_suffix(".bin") {
                  match store.get(pkey) {
                    Some(bs) =>
                      if !@format.is_pq_part(bs) &&
                        !@format.is_pq_shared_part(bs) {
                        let part = (@format.decode_part(bs)) catch {
                          _ => continue
                        }
                        for pi in 0..<part.rows.length() {
                          if part.rows[pi] == i {
                            vec = Array(capacity=part.dim)
                            let off = pi * part.dim
                            for vj in 0..<part.dim {
                              vec.push(part.data[off + vj])
                            }
                            break
                          }
                        }
                        if !vec.is_empty() {
                          break
                        }
                      }
                    None => ()
                  }
                }
              }
              if vec.is_empty() {
                let gvers = store.list("\{ns}/vec/global/")
                for gv in gvers {
                  if gv.has_suffix("/meta.json") {
                    let vdir = gv[:gv.length() - 10]
                    let gparts = store.list("\{vdir}/")
                    for gpk in gparts {
                      if gpk.has_prefix("\{vdir}/part-") &&
                        gpk.has_suffix(".bin") {
                        match store.get(gpk) {
                          Some(bs) => {
                            let gp = (@format.decode_global_part(bs)) catch {
                              _ => continue
                            }
                            for gi in 0..<gp.rows.length() {
                              let (si, ri) = gp.rows[gi]
                              if si == s_idx && ri == i {
                                vec = Array(capacity=gp.dim)
                                let off = gi * gp.dim
                                for vj in 0..<gp.dim {
                                  vec.push(gp.data[off + vj])
                                }
                                break
                              }
                            }
                            if !vec.is_empty() {
                              break
                            }
                          }
                          None => ()
                        }
                      }
                    }
                  }
                  if !vec.is_empty() {
                    break
                  }
                }
              }
              let doc : @core.Doc = { id: doc_id, text, category, ts, public, vector: vec }
              match active_ns.get(ns) {
                Some(state) => state.doc_full_cache.set(doc_id, doc)
                None => ()
              }
              return Some(doc)
            }
          }
        None => ()
      }
    }
    s_idx -= 1
  }
  None
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
      match state.doc_cache.get(doc_id) {
        Some(attr) => return attr
        None => ()
      }
      let live = (state.engine.read_live_docs()) catch { _ => [] }
      for d in live {
        if d.id == doc_id {
          let attr : DocAttributes = { text: d.text, category: d.category, ts: d.ts, public: d.public }
          state.doc_cache.set(doc_id, attr)
          return attr
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
              let attr : DocAttributes = { text, category, ts, public }
              match active_ns.get(ns) {
                Some(state) => state.doc_cache.set(doc_id, attr)
                None => ()
              }
              return attr
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
    401 => "Unauthorized"
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
/// 以纯文本响应（Prometheus /metrics 端点用）。
async fn respond_text(
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
    "text/plain; version=0.0.4; charset=utf-8",
  )
  let reason = if code == 200 { "OK" } else { "Internal Server Error" }
  conn.send_response(code, reason, extra_headers=headers)
  conn.write_string(body)
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
/// namespace meta（优先从内存 active_ns 获取，缺失时从 store 读并缓存）。
fn[T : @store.ObjectStore] ns_meta(
  store : T,
  ns : String,
) -> @format.NamespaceMeta? {
  match active_ns.get(ns) {
    Some(state) =>
      match state.meta {
        Some(m) => return Some(m)
        None => ()
      }
    None => ()
  }
  match store.get("\{ns}/_meta/namespace.json") {
    Some(bs) => {
      let j = @json.parse(@utf8.decode(bs.exact_view())) catch {
        _ => return None
      }
      let m = (try {
        Some(@format.namespace_from_json(j))
      } catch {
        _ => None
      })
      match (m, active_ns.get(ns)) {
        (Some(meta), Some(state)) => state.meta = Some(meta)
        _ => ()
      }
      m
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
  metric : String? // distance_metric 意图（cosine|euclidean）
}

///|
fn parse_row_vector(arr : Array[Json]) -> Array[Float] raise @core.SpndError {
  let v : Array[Float] = Array(capacity=arr.length())
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
      d.to_int64().reinterpret_as_uint64()
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
  let docs : Array[@core.Doc] = Array()
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
  let deletes : Array[UInt64] = Array()
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
  let metric : String? = match m.get("distance_metric") {
    Some(j) =>
      match parse_metric(j) {
        Some(v) => Some(v)
        None => raise @core.Corrupt("distance_metric must be cosine|euclidean")
      }
    None => None
  }
  { docs, deletes, tokenizer, has_vector, metric }
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
      let metric = if meta.distance_metric == "" {
        "cosine"
      } else {
        meta.distance_metric
      }
      {
        ..cfg,
        vector_dim: meta.vector_dim,
        fts_tokenizer: tok,
        distance_metric: metric,
        normalize_vecs: metric != "euclidean",
      }
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
      let metric = match created_metrics.get(ns) {
        Some(m) => m
        None => "cosine"
      }
      if !(rows_have_vector) {
        raise @core.Corrupt("first write of a namespace must include vector")
      }
      {
        ..cfg,
        fts_tokenizer: tok,
        vector_dim,
        distance_metric: metric,
        normalize_vecs: metric != "euclidean",
      }
    }
  }
}

///|
/// JSON 值 → FVal（bool 配范围 op 在解析层即拒绝）。
fn parse_fval(j : Json) -> @query.FVal raise @core.SpndError {
  match j {
    String(s) => @query.S(s)
    True => @query.B(true)
    False => @query.B(false)
    Number(d, ..) => @query.I(d.to_int64())
    _ => raise @core.Corrupt("filter value must be string/bool/number")
  }
}

///|
/// tpf 数组语法 → Filter AST：
/// ["attr", "Eq", v]；["attr", v]（Eq 糖）；["And", [f..]] / ["Or", [f..]] / ["Not", f]。
fn parse_filter_json(j : Json) -> @query.Filter raise @core.SpndError {
  let arr = match j {
    Array(a) => a
    _ => raise @core.Corrupt("filter must be an array")
  }
  if arr.is_empty() {
    raise @core.Corrupt("filter must not be empty")
  }
  let head = match arr[0] {
    String(s) => s
    _ => raise @core.Corrupt("filter head must be a string")
  }
  if head == "And" || head == "Or" {
    if arr.length() != 2 {
      raise @core.Corrupt("\{head} takes exactly one array argument")
    }
    let children : Array[@query.Filter] = Array()
    match arr[1] {
      Array(cs) =>
        if cs.is_empty() {
          raise @core.Corrupt("\{head} needs at least one child filter")
        } else {
          for c in cs {
            children.push(parse_filter_json(c))
          }
        }
      _ => raise @core.Corrupt("\{head} argument must be an array of filters")
    }
    return if head == "And" {
      @query.And(children)
    } else {
      @query.Or(children)
    }
  }
  if head == "Not" {
    if arr.length() != 2 {
      raise @core.Corrupt("Not takes exactly one filter")
    }
    return @query.Not(parse_filter_json(arr[1]))
  }
  // 叶子：["field", value] 或 ["field", op, value]
  if arr.length() == 2 {
    return @query.Eq(head, parse_fval(arr[1]))
  }
  if arr.length() != 3 {
    raise @core.Corrupt(
      "filter leaf must be [field, value] or [field, op, value]",
    )
  }
  let op = match arr[1] {
    String(s) => s
    _ => raise @core.Corrupt("filter op must be a string")
  }
  match op {
    "Eq" => @query.Eq(head, parse_fval(arr[2]))
    "NotEq" => @query.Neq(head, parse_fval(arr[2]))
    "Lt" | "Lte" | "Gt" | "Gte" => {
      let v = parse_fval(arr[2])
      match v {
        @query.B(_) =>
          raise @core.Corrupt("range comparison not supported for bool value")
        _ => ()
      }
      match op {
        "Lt" => @query.Lt(head, v)
        "Lte" => @query.Lte(head, v)
        "Gt" => @query.Gt(head, v)
        _ => @query.Gte(head, v)
      }
    }
    "Glob" => {
      let pattern = match arr[2] {
        String(s) => s
        _ => raise @core.Corrupt("Glob pattern must be a string")
      }
      @query.Glob(head, pattern)
    }
    "In" | "NotIn" => {
      let vals : Array[@query.FVal] = Array()
      match arr[2] {
        Array(vs) =>
          if vs.is_empty() {
            raise @core.Corrupt("In/NotIn needs at least one value")
          } else {
            for v in vs {
              vals.push(parse_fval(v))
            }
          }
        _ => raise @core.Corrupt("In/NotIn value must be an array")
      }
      let kind = match vals[0] {
        @query.S(_) => 0
        @query.B(_) => 1
        @query.I(_) => 2
      }
      for v in vals {
        let k2 = match v {
          @query.S(_) => 0
          @query.B(_) => 1
          @query.I(_) => 2
        }
        if k2 != kind {
          raise @core.Corrupt("In/NotIn values must be homogeneous")
        }
      }
      if op == "In" {
        @query.In(head, vals)
      } else {
        @query.NotIn(head, vals)
      }
    }
    _ => raise @core.Corrupt("unknown filter op \{op}")
  }
}

///|
/// 属性投影：include/exclude 作用于 text/category/ts/public（id/score 恒返回）。
fn attr_wanted(
  include_attrs : Array[String]?,
  exclude : Array[String]?,
  field : String,
) -> Bool {
  match include_attrs {
    Some(list) => {
      let mut hit = false
      for x in list {
        if x == field {
          hit = true
          break
        }
      }
      hit
    }
    None =>
      match exclude {
        Some(list) => {
          let mut hit = false
          for x in list {
            if x == field {
              hit = true
              break
            }
          }
          !(hit)
        }
        None => true
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
  let text : String? = match m.get("text") {
    Some(String(s)) => Some(s)
    _ => None
  }
  let qv : Array[Float]? = match m.get("vector") {
    Some(Array(a)) => Some(parse_row_vector(a))
    _ => None
  }
  let top_k = match m.get("top_k") {
    Some(Number(d, ..)) => d.to_int()
    _ =>
      match m.get("limit") {
        Some(Number(d, ..)) => d.to_int()
        _ => 10
      }
  }
  let nprobe = match m.get("nprobe") {
    Some(Number(d, ..)) => d.to_int()
    _ => 8
  }
  let offset = match m.get("offset") {
    Some(Number(d, ..)) => d.to_int()
    _ => 0
  }
  if offset < 0 {
    raise @core.Corrupt("offset must be >= 0")
  }
  if top_k < 1 || top_k + offset > 10000 {
    raise @core.Corrupt("top_k must be 1..10000 (incl. offset)")
  }
  // filter：新数组语法与旧 filter_category 互斥
  let has_new_filter = m.get("filter") is Some(_)
  let filter : @query.Filter? = if has_new_filter {
    match m.get("filter_category") {
      Some(_) =>
        raise @core.Corrupt("filter and filter_category are mutually exclusive")
      None => ()
    }
    match m.get("filter") {
      Some(fj) => Some(parse_filter_json(fj))
      None => None
    }
  } else {
    match m.get("filter_category") {
      Some(String(s)) => Some(@query.f_str("category", s))
      _ => None
    }
  }
  // 聚合：["Count"] 或 [{"Sum": "field"}] 或 ["Sum", "field"] 组合
  let mut aggregate_count = false
  let sum_fields : Array[String] = Array()
  match m.get("aggregations") {
    Some(Array(aggs)) => {
      for a in aggs {
        match a {
          String("Count") => aggregate_count = true
          // {"Sum": "field"} 形式
          Object(obj) =>
            match obj.get("Sum") {
              Some(String(field)) => sum_fields.push(field)
              Some(_) =>
                raise @core.Corrupt(
                  "Sum aggregation field must be a string",
                )
              None =>
                raise @core.Corrupt(
                  "unsupported aggregation object (only {\"Sum\": \"field\"})",
                )
            }
          // ["Sum", "field"] 形式：此时 a 是 String("Sum")，field 在下一项
          String("Sum") =>
            raise @core.Corrupt(
              "Sum aggregation must be {\"Sum\": \"field\"} or [\"Sum\",\"field\"] not \"Sum\" alone",
            )
          String(other) =>
            raise @core.Corrupt(
              "unsupported aggregation \{other} (only Count, Sum)",
            )
          Array(pair) =>
            // ["Sum", "field"] 子数组形式
            if pair.length() == 2 {
              match (pair[0], pair[1]) {
                (String("Sum"), String(field)) => sum_fields.push(field)
                _ =>
                  raise @core.Corrupt(
                    "aggregation array must be [\"Sum\", \"field\"]",
                  )
              }
            } else {
              raise @core.Corrupt("aggregation array must be [\"Sum\", \"field\"]")
            }
          _ => raise @core.Corrupt("aggregation must be \"Count\" or {\"Sum\": \"field\"}")
        }
      }
      if aggs.is_empty() {
        raise @core.Corrupt("aggregations must not be empty")
      }
    }
    Some(_) => raise @core.Corrupt("aggregations must be an array")
    None => ()
  }
  match m.get("aggregate") {
    Some(String("count")) => aggregate_count = true
    Some(String(other)) =>
      raise @core.Corrupt("unsupported aggregate \{other} (only count)")
    Some(_) => raise @core.Corrupt("aggregate must be \"count\"")
    None => ()
  }
  if aggregate_count && (text is Some(_) || qv is Some(_)) {
    raise @core.Corrupt("aggregations cannot be combined with text/vector")
  }
  let do_aggregation = aggregate_count || !(sum_fields.is_empty())
  // hybrid 参数（任一给出即走 hybrid_search_opts）
  let rank_constant : Double? = match m.get("rank_constant") {
    Some(Number(d, ..)) => Some(d)
    Some(_) => raise @core.Corrupt("rank_constant must be a number")
    None => None
  }
  let fusion : String? = match m.get("fusion") {
    Some(String(s)) =>
      if s == "rrf" || s == "linear" {
        Some(s)
      } else {
        raise @core.Corrupt("fusion must be rrf or linear")
      }
    Some(_) => raise @core.Corrupt("fusion must be a string")
    None => None
  }
  let mut w_bm25 : Double? = None
  let mut w_vec : Double? = None
  match m.get("weights") {
    Some(Object(w)) => {
      w_bm25 = match w.get("bm25") {
        Some(Number(d, ..)) => Some(d)
        _ => None
      }
      w_vec = match w.get("vector") {
        Some(Number(d, ..)) => Some(d)
        _ => None
      }
    }
    Some(_) => raise @core.Corrupt("weights must be an object {bm25, vector}")
    None => ()
  }
  let include_attrs : Array[String]? = match m.get("include_attributes") {
    Some(Array(a)) => {
      let l : Array[String] = Array()
      for x in a {
        match x {
          String(s) => l.push(s)
          _ => raise @core.Corrupt("include_attributes must be strings")
        }
      }
      Some(l)
    }
    Some(_) => raise @core.Corrupt("include_attributes must be an array")
    None => None
  }
  let exclude : Array[String]? = match m.get("exclude_attributes") {
    Some(Array(a)) => {
      let l : Array[String] = Array()
      for x in a {
        match x {
          String(s) => l.push(s)
          _ => raise @core.Corrupt("exclude_attributes must be strings")
        }
      }
      Some(l)
    }
    Some(_) => raise @core.Corrupt("exclude_attributes must be an array")
    None => None
  }
  if include_attrs is Some(_) && exclude is Some(_) {
    raise @core.Corrupt(
      "include_attributes and exclude_attributes are mutually exclusive",
    )
  }
  let _consistency = match m.get("consistency") {
    Some(String(s)) =>
      if s == "strong" || s == "eventual" || s == "strong_nocache" {
        s
      } else {
        raise @core.Corrupt("consistency must be strong or eventual")
      }
    Some(_) => raise @core.Corrupt("consistency must be a string")
    None => "eventual"
  }
  // 协调者节点作为权威内存拥有者：直接使用活跃的 NamespaceState 快照，消除 S3 元数据轮询与 GET
  let state = get_or_load_ns_state(store, ns)
  let n = state.get_query_ns(store, ns)
  // 聚合 Count / Sum：与检索互斥
  if do_aggregation {
    let cnt = @query.count_docs(n, filter)
    let out : Map[String, Json] = Map([])
    out.set("count", Json::number(cnt.to_double()))
    // Sum aggregations
    if !(sum_fields.is_empty()) {
      let agg_map : Map[String, Json] = Map([])
      for field in sum_fields {
        let s = @query.sum_field(n, field, filter)
        let field_map : Map[String, Json] = Map([])
        field_map.set("sum", Json::number(s))
        agg_map.set(field, Json::object(field_map))
      }
      out.set("aggregations", Json::object(agg_map))
    }
    out.set("rows", Json::array([]))
    respond(conn, 200, Json::object(out).stringify())
    return
  }
  let fetch_k = top_k + offset
  let has_hybrid_opts = rank_constant is Some(_) ||
    fusion is Some(_) ||
    w_bm25 is Some(_) ||
    w_vec is Some(_)
  let coord = get_coordinator(store)
  let results : Array[@query.QueryResult] = match (text, qv) {
    (Some(t), Some(v)) =>
      if has_hybrid_opts {
        coord.dispatch_hybrid_query(
          ns,
          n,
          t,
          v,
          fetch_k,
          nprobe,
          filter,
          Some({
            rank_constant: match rank_constant {
              Some(x) => if x > 0.0 { x } else { 60.0 }
              None => 60.0
            },
            fusion: fusion.unwrap_or("rrf"),
            weight_bm25: w_bm25.unwrap_or(1.0),
            weight_vec: w_vec.unwrap_or(1.0),
          }),
        )
      } else {
        coord.dispatch_hybrid_query(ns, n, t, v, fetch_k, nprobe, filter, None)
      }
    (Some(t), None) => coord.dispatch_bm25_query(ns, n, t, fetch_k, filter)
    (_, Some(v)) => coord.dispatch_vector_query(ns, n, v, fetch_k, nprobe, filter)
    (None, None) => raise @core.Corrupt("query needs text or vector")
  }
  // offset 分页：检索 top-(offset+top_k) 后切片
  let rows = if offset < results.length() {
    results[offset:]
  } else {
    []
  }
  let rows_json : Array[Json] = Array()
  for r in rows {
    let attr = lookup_doc_attrs(store, ns, n, r.id)
    let row_map : Map[String, Json] = Map([])
    row_map.set("id", Json::number(r.id.to_double()))
    row_map.set("score", Json::number(r.score))
    if attr_wanted(include_attrs, exclude, "text") {
      row_map.set("text", Json::string(attr.text))
    }
    if attr_wanted(include_attrs, exclude, "category") {
      row_map.set("category", Json::string(attr.category))
    }
    if attr_wanted(include_attrs, exclude, "ts") {
      row_map.set("ts", Json::number(attr.ts.to_double()))
    }
    if attr_wanted(include_attrs, exclude, "public") {
      row_map.set("public", Json::boolean(attr.public))
    }
    rows_json.push(Json::object(row_map))
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
  // distance_metric 意图：已存在 namespace 校验一致（不可改），新 namespace 记录
  match w.metric {
    Some(m) =>
      match ns_meta(store, ns) {
        Some(meta) =>
          if meta.distance_metric != "" && meta.distance_metric != m {
            raise @core.Corrupt(
              "distance_metric mismatch: namespace uses \{meta.distance_metric}",
            )
          }
        None => created_metrics.set(ns, m)
      }
    None => ()
  }
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
  let build_head = match @store.read_head_pointer(store, ns) {
    Some(h) => h
    None => @store.read_head(store, ns, "")
  }

  // 同步推进 MergeTreeEngine 并通知 in-process Compactor
  let state = get_or_create_ns_state(store, ns, dim)
  try {
    if build_head != "" {
      state.build_head = build_head
    }
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
    state.update_after_write(store, ns, build_head)
  }
  for d in w.docs {
    state.doc_cache.set(d.id, { text: d.text, category: d.category, ts: d.ts, public: d.public })
    state.doc_full_cache.set(d.id, d)
  }
  for id in w.deletes {
    state.doc_cache.remove(id)
    state.doc_full_cache.remove(id)
  }

  let head = build_head
  let out : Map[String, Json] = Map([])
  out.set("ingested", Json::number(w.docs.length().to_double()))
  out.set("head", Json::string(head))
  respond(conn, 200, Json::object(out).stringify())
}

///|
struct RowPatch {
  id : UInt64
  text : String?
  category : String?
  ts : Int64?
  public : Bool?
}

///|
fn parse_patch(body : String) -> Array[RowPatch] raise @core.SpndError {
  let j = @json.parse(body) catch {
    _ => raise @core.Corrupt("body is not valid JSON")
  }
  let m = match j {
    Object(mm) => mm
    _ => raise @core.Corrupt("body must be object")
  }
  let patches_j = match m.get("patches") {
    Some(Array(arr)) => arr
    _ => raise @core.Corrupt("missing patches array")
  }
  let patches : Array[RowPatch] = Array()
  for p in patches_j {
    let pm = match p {
      Object(obj) => obj
      _ => raise @core.Corrupt("patch element must be object")
    }
    let id_j = match pm.get("id") {
      Some(id) => id
      None => raise @core.Corrupt("patch missing id")
    }
    let id = u64_from_json(id_j)
    let text = match pm.get("text") {
      Some(String(s)) => Some(s)
      _ => None
    }
    let category = match pm.get("category") {
      Some(String(s)) => Some(s)
      _ => None
    }
    let ts = match pm.get("ts") {
      Some(Number(d, ..)) => Some(d.to_int64())
      _ => None
    }
    let public = match pm.get("public") {
      Some(True) => Some(true)
      Some(False) => Some(false)
      _ => None
    }
    patches.push({ id, text, category, ts, public })
  }
  patches
}

///|
fn patch_rows_core(
  store : AnyStore,
  ns : String,
  patches : Array[RowPatch],
) -> (Int, String) raise @core.SpndError {
  let state = get_or_load_ns_state(store, ns)
  if patches.is_empty() {
    let head = if state.build_head != "" {
      state.build_head
    } else {
      match @store.read_head_pointer(store, ns) {
        Some(h) => h
        None => @store.read_head(store, ns, "")
      }
    }
    return (0, head)
  }
  let n = state.get_query_ns(store, ns)
  let updated_docs : Array[@core.Doc] = Array()
  for patch in patches {
    let existing = match lookup_doc_full(store, ns, n, patch.id) {
      Some(d) => d
      None => raise @core.NotFound("document id \{patch.id} not found")
    }
    let text = match patch.text {
      Some(t) => t
      None => existing.text
    }
    let category = match patch.category {
      Some(c) => c
      None => existing.category
    }
    let ts = match patch.ts {
      Some(t) => t
      None => existing.ts
    }
    let public = match patch.public {
      Some(p) => p
      None => existing.public
    }
    updated_docs.push({
      id: patch.id,
      text,
      category,
      ts,
      public,
      vector: existing.vector,
    })
  }

  let mut dim = 0
  if updated_docs.length() > 0 {
    dim = updated_docs[0].vector.length()
  }
  let cfg = cfg_for(store, ns, dim > 0, None, dim)
  if state.meta is Some(_) || ns_meta(store, ns) is Some(_) {
    let _ = @build.ingest_delta_opts(store, cfg, updated_docs, 8, true)
  } else {
    let _ = @build.ingest(store, cfg, updated_docs)
  }
  let build_head = match @store.read_head_pointer(store, ns) {
    Some(h) => h
    None => @store.read_head(store, ns, "")
  }

  try {
    if build_head != "" {
      state.build_head = build_head
    }
    if state.engine.get_manifest().parts.is_empty() {
      let _ = state.engine.append_base_part(updated_docs)
    } else {
      let _ = state.engine.append_l0_delta_part(updated_docs)
    }
    state.engine.publish_manifest()
    let now = @async.now()
    state.compactor.notify_mutation(now)
  } catch {
    _ => ()
  }
  if build_head != "" {
    store.put(@store.head_pointer_key(ns), @utf8.encode(build_head))
    state.update_after_write(store, ns, build_head)
  }
  for d in updated_docs {
    state.doc_cache.set(d.id, { text: d.text, category: d.category, ts: d.ts, public: d.public })
    state.doc_full_cache.set(d.id, d)
  }
  (updated_docs.length(), build_head)
}

///|
async fn handle_patch(
  store : AnyStore,
  ns : String,
  body : String,
  conn : @http.ServerConnection,
) -> Unit raise {
  let patches = parse_patch(body)
  let (count, head) = patch_rows_core(store, ns, patches)
  let out : Map[String, Json] = Map([])
  out.set("patched", Json::number(count.to_double()))
  out.set("head", Json::string(head))
  respond(conn, 200, Json::object(out).stringify())
}

///|
async fn handle_health(
  store : AnyStore,
  ns : String,
  conn : @http.ServerConnection,
) -> Unit raise {
  let state = get_or_load_ns_state(store, ns)
  let n = state.get_query_ns(store, ns)
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
  let coord = get_coordinator(store)
  let worker = coord.select_worker(ns)
  let (hits, misses, evictions, expirations, cache_bytes) = worker.cache.stats()
  let cache_m : Map[String, Json] = Map([])
  cache_m.set("hits", Json::number(hits.to_double()))
  cache_m.set("misses", Json::number(misses.to_double()))
  cache_m.set("evictions", Json::number(evictions.to_double()))
  cache_m.set("expirations", Json::number(expirations.to_double()))
  cache_m.set("bytes", Json::number(cache_bytes.to_double()))
  cache_m.set("worker_id", Json::string(worker.id))
  out.set("worker_cache", Json::object(cache_m))
  respond(conn, 200, Json::object(out).stringify())
}

///|
fn delete_by_filter_core(
  store : AnyStore,
  ns : String,
  filter : @query.Filter,
) -> Int raise @core.SpndError {
  let state = get_or_load_ns_state(store, ns)
  let n = state.get_query_ns(store, ns)
  let ids = @query.matching_ids(n, filter)
  if ids.length() > 0 {
    let cfg = cfg_for(store, ns, false, None, 0)
    @build.delete_docs(store, cfg, ids)
    let build_head = match @store.read_head_pointer(store, ns) {
      Some(h) => h
      None => @store.read_head(store, ns, "")
    }
    try {
      if build_head != "" {
        state.build_head = build_head
      }
      state.engine.soft_delete(ids)
      state.engine.publish_manifest()
      let now = @async.now()
      state.compactor.notify_mutation(now)
    } catch {
      _ => ()
    }
    if build_head != "" {
      store.put(@store.head_pointer_key(ns), @utf8.encode(build_head))
      state.update_after_write(store, ns, build_head)
    }
    for id in ids {
      state.doc_cache.remove(id)
      state.doc_full_cache.remove(id)
    }
  }
  ids.length()
}

///|
async fn handle_delete_by_filter(
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
  let filter_j = match m.get("filter") {
    Some(fj) => fj
    None => raise @core.Corrupt("missing filter")
  }
  let filter = parse_filter_json(filter_j)
  let deleted_count = delete_by_filter_core(store, ns, filter)
  let out : Map[String, Json] = Map([])
  out.set("deleted", Json::number(deleted_count.to_double()))
  respond(conn, 200, Json::object(out).stringify())
}

///|
fn copy_namespace_data(
  store : AnyStore,
  ns : String,
  dest_ns : String,
) -> Unit raise @core.SpndError {
  if dest_ns.length() == 0 {
    raise @core.Corrupt("destination cannot be empty")
  }
  let prefix = ns + "/"
  let keys = store.list(prefix)
  if keys.is_empty() {
    raise @core.NotFound("source namespace \{ns} not found")
  }
  for k in keys {
    if k.has_prefix(prefix) {
      let sub = k[ns.length():]
      let dest_key = "\{dest_ns}\{sub}"
      match store.get(k) {
        Some(b) => store.put(dest_key, b)
        None => ()
      }
    }
  }
  match created_tokenizers.get(ns) {
    Some(t) => created_tokenizers.set(dest_ns, t)
    None => ()
  }
  match created_metrics.get(ns) {
    Some(m) => created_metrics.set(dest_ns, m)
    None => ()
  }
}

///|
async fn handle_copy_branch(
  store : AnyStore,
  ns : String,
  body : String,
  _is_branch : Bool,
  conn : @http.ServerConnection,
) -> Unit raise {
  let j = @json.parse(body) catch {
    _ => raise @core.Corrupt("body is not valid JSON")
  }
  let m = match j {
    Object(mm) => mm
    _ => raise @core.Corrupt("body must be object")
  }
  let dest_ns = match m.get("destination") {
    Some(String(s)) => s
    _ => raise @core.Corrupt("missing destination")
  }
  copy_namespace_data(store, ns, dest_ns)
  let out : Map[String, Json] = Map([])
  out.set("ok", Json::boolean(true))
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
  prom_requests_total.val += 1

  // OPTIONS：CORS preflight，豁免鉴权
  if req.meth is Options {
    respond(conn, 204, "")
    return
  }

  // GET /metrics：Prometheus 端点，豁免鉴权
  if path == "/metrics" && req.meth is Get {
    let active_count = active_ns.length()
    let body = "# HELP spnd_requests_total Total HTTP requests\n" +
      "# TYPE spnd_requests_total counter\n" +
      "spnd_requests_total \{prom_requests_total.val}\n" +
      "# HELP spnd_queries_total Total query requests\n" +
      "# TYPE spnd_queries_total counter\n" +
      "spnd_queries_total \{prom_queries_total.val}\n" +
      "# HELP spnd_writes_total Total write requests\n" +
      "# TYPE spnd_writes_total counter\n" +
      "spnd_writes_total \{prom_writes_total.val}\n" +
      "# HELP spnd_active_namespaces Active in-process namespaces\n" +
      "# TYPE spnd_active_namespaces gauge\n" +
      "spnd_active_namespaces \{active_count}\n"
    respond_text(conn, 200, body)
    return
  }

  // 路由：/v1/namespaces/{ns}/{action}
  match split_ns_path(path) {
    Some((ns, action)) => {
      if ns.length() == 0 {
        respond(conn, 404, "{\"error\":\"missing namespace\"}")
        return
      }

      // 鉴权检查（GET health 豁免）
      let is_health_get = action == "health" && req.meth is Get
      if !is_health_get && !check_auth(req) {
        respond(conn, 401, "{\"error\":\"Unauthorized\"}")
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
            // distance_metric 意图（首个 write 前生效）
            match j {
              Object(m2) =>
                match m2.get("distance_metric") {
                  Some(metric_j) =>
                    match parse_metric(metric_j) {
                      Some(v) => created_metrics.set(ns, v)
                      None => {
                        respond(
                          conn,
                          400,
                          "{\"error\":\"distance_metric must be cosine|euclidean\"}",
                        )
                        return
                      }
                    }
                  _ => ()
                }
              _ => ()
            }
          }

          let out : Map[String, Json] = Map([])
          out.set("ok", Json::boolean(true))
          out.set("ns", Json::string(ns))
          respond(conn, 200, Json::object(out).stringify())
        }
        ("write", Post) => {
          prom_writes_total.val += 1
          let body = (reader.read_all()).text() catch {
            _ => ""
          }
          handle_write(store, ns, body, conn) catch {
            _ => respond(conn, 400, "{\"error\":\"write failed (see server log)\"}")
          }
        }
        ("query", Post) => {
          prom_queries_total.val += 1
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
        ("patch", Post) => {
          prom_writes_total.val += 1
          let body = (reader.read_all()).text() catch {
            _ => ""
          }
          handle_patch(store, ns, body, conn) catch {
            e => {
              let msg = match e {
                @core.Corrupt(s) => "Corrupt(\{s})"
                @core.NotFound(s) => "NotFound(\{s})"
                @core.Truncated(s) => "Truncated(\{s})"
                @core.BadMagic(s) => "BadMagic(\{s})"
                @core.CommitConflict(s) => "CommitConflict(\{s})"
                _ => "\{e}"
              }
              respond(conn, 400, "{\"error\":\"patch failed: \{msg}\"}")
            }
          }
        }
        ("delete_by_filter", Post) => {
          let body = (reader.read_all()).text() catch {
            _ => ""
          }
          handle_delete_by_filter(store, ns, body, conn) catch {
            e => {
              let msg = match e {
                @core.Corrupt(s) => "Corrupt(\{s})"
                @core.NotFound(s) => "NotFound(\{s})"
                @core.Truncated(s) => "Truncated(\{s})"
                @core.BadMagic(s) => "BadMagic(\{s})"
                @core.CommitConflict(s) => "CommitConflict(\{s})"
                _ => "\{e}"
              }
              respond(conn, 400, "{\"error\":\"delete_by_filter failed: \{msg}\"}")
            }
          }
        }
        ("copy", Post) => {
          let body = (reader.read_all()).text() catch {
            _ => ""
          }
          handle_copy_branch(store, ns, body, false, conn) catch {
            e => {
              let msg = match e {
                @core.Corrupt(s) => "Corrupt(\{s})"
                @core.NotFound(s) => "NotFound(\{s})"
                @core.Truncated(s) => "Truncated(\{s})"
                @core.BadMagic(s) => "BadMagic(\{s})"
                @core.CommitConflict(s) => "CommitConflict(\{s})"
                _ => "\{e}"
              }
              respond(conn, 400, "{\"error\":\"copy failed: \{msg}\"}")
            }
          }
        }
        ("branch", Post) => {
          let body = (reader.read_all()).text() catch {
            _ => ""
          }
          handle_branch(store, ns, body, conn) catch {
            e => {
              let msg = match e {
                @core.Corrupt(s) => "Corrupt(\{s})"
                @core.NotFound(s) => "NotFound(\{s})"
                @core.Truncated(s) => "Truncated(\{s})"
                @core.BadMagic(s) => "BadMagic(\{s})"
                @core.CommitConflict(s) => "CommitConflict(\{s})"
                _ => "\{e}"
              }
              respond(conn, 400, "{\"error\":\"branch failed: \{msg}\"}")
            }
          }
        }
        ("snapshot", Post) => {
          let body = (reader.read_all()).text() catch {
            _ => ""
          }
          handle_snapshot(store, ns, body, conn) catch {
            e => {
              let msg = match e {
                @core.Corrupt(s) => "Corrupt(\{s})"
                @core.NotFound(s) => "NotFound(\{s})"
                @core.Truncated(s) => "Truncated(\{s})"
                @core.BadMagic(s) => "BadMagic(\{s})"
                @core.CommitConflict(s) => "CommitConflict(\{s})"
                _ => "\{e}"
              }
              respond(conn, 400, "{\"error\":\"snapshot failed: \{msg}\"}")
            }
          }
        }
        ("restore", Post) => {
          let body = (reader.read_all()).text() catch {
            _ => ""
          }
          handle_restore(store, ns, body, conn) catch {
            e => {
              let msg = match e {
                @core.Corrupt(s) => "Corrupt(\{s})"
                @core.NotFound(s) => "NotFound(\{s})"
                @core.Truncated(s) => "Truncated(\{s})"
                @core.BadMagic(s) => "BadMagic(\{s})"
                @core.CommitConflict(s) => "CommitConflict(\{s})"
                _ => "\{e}"
              }
              respond(conn, 400, "{\"error\":\"restore failed: \{msg}\"}")
            }
          }
        }
        ("snapshots", Get) =>
          handle_list_snapshots(store, ns, conn) catch {
            _ => respond(conn, 500, "{\"error\":\"list snapshots failed\"}")
          }
        ("snapshots", Post) => {
          let body = (reader.read_all()).text() catch {
            _ => ""
          }
          handle_snapshot(store, ns, body, conn) catch {
            e => {
              let msg = match e {
                @core.Corrupt(s) => "Corrupt(\{s})"
                @core.NotFound(s) => "NotFound(\{s})"
                @core.Truncated(s) => "Truncated(\{s})"
                @core.BadMagic(s) => "BadMagic(\{s})"
                @core.CommitConflict(s) => "CommitConflict(\{s})"
                _ => "\{e}"
              }
              respond(conn, 400, "{\"error\":\"snapshot failed: \{msg}\"}")
            }
          }
        }
        ("compact", Post) => {
          try {
            let state = get_or_load_ns_state(store, ns)
            let cfg = cfg_for(store, ns, false, None, 0)
            @build.compact_global(store, cfg, ns)
            let new_head = match @store.read_head_pointer(store, ns) {
              Some(h) => h
              None => @store.read_head(store, ns, "")
            }
            if new_head != "" {
              state.update_after_write(store, ns, new_head)
            }
            let out : Map[String, Json] = Map([])
            out.set("ok", Json::boolean(true))
            out.set("ns", Json::string(ns))
            respond(conn, 200, Json::object(out).stringify())
          } catch {
            e => {
              let msg = match e {
                @core.Corrupt(s) => "Corrupt(\{s})"
                @core.NotFound(s) => "NotFound(\{s})"
                @core.Truncated(s) => "Truncated(\{s})"
                @core.BadMagic(s) => "BadMagic(\{s})"
                @core.CommitConflict(s) => "CommitConflict(\{s})"
                _ => "\{e}"
              }
              respond(conn, 500, "{\"error\":\"compact failed: \{msg}\"}")
            }
          }
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
  meta_url.val = env_or("SPND_META_URL", "")
  meta_prefix.val = env_or("SPND_META_PREFIX", "")
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
        background_compactor_loop(store)
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

pub extend AnyStore with @turbofish/store.ObjectStore::{get, list, put}
