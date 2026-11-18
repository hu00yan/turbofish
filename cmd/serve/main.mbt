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
// 写路径只有 @build 一套（无 mtree 双写）；查询读 build manifest/segments，进程内只有
// 小容量 LRU 缓存（active_ns / seg_cache / doc_cache），不落盘。
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
/// metad 客户端（纯 MoonBit 异步 HTTP，持久连接槽位池）。
/// `SPND_META_URL` 为空时保持 None：所有元数据操作短路，行为与旧版一致
/// （元数据仍然回源对象存储）。
let meta_client : Ref[@meta.MetadClient?] = { val: None }

///|
/// 依当前 `meta_url` / `meta_prefix` 准备 metad 客户端（幂等）。
fn init_meta_client() -> Unit {
  if meta_url.val == "" {
    meta_client.val = None
    return
  }
  match meta_client.val {
    Some(_) => ()
    None =>
      meta_client.val = Some(@meta.MetadClient::new(meta_url.val, max_inflight=8))
  }
}

///|
pub fn reset_meta_client_for_test() -> Unit {
  match meta_client.val {
    Some(c) => c.close()
    None => ()
  }
  meta_client.val = None
}

///|
fn meta_enabled() -> Bool {
  meta_url.val != "" && meta_client.val is Some(_)
}

///|
async fn meta_get(key : String) -> Bytes? {
  if !meta_enabled() || !@meta.is_metadata_key(key) {
    return None
  }
  match meta_client.val {
    None => None
    Some(c) =>
      (c.get_kv(meta_key(key))) catch {
        _ => None
      }
  }
}

///|
async fn meta_put(key : String, bs : Bytes) -> Unit {
  if !meta_enabled() || !@meta.is_metadata_key(key) {
    return
  }
  match meta_client.val {
    None => ()
    Some(c) =>
      (c.put_kv(meta_key(key), bs)) catch {
        _ => ()
      }
  }
}

///|
async fn meta_delete(key : String) -> Unit {
  if !meta_enabled() || !@meta.is_metadata_key(key) {
    return
  }
  match meta_client.val {
    None => ()
    Some(c) =>
      (c.delete_kv(meta_key(key))) catch {
        _ => ()
      }
  }
}

///|
/// 通知 metad 这个 namespace 变脏（紧凑合并由独立进程 cmd/compactd 消费）。
async fn meta_mark_dirty(ns : String) -> Unit {
  if !meta_enabled() {
    return
  }
  match meta_client.val {
    None => ()
    Some(c) => {
      let _ = (c.mark_dirty(ns)) catch {
        _ => false
      }
    }
  }
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
///
/// 多后端存储包装：支持 fs:PATH、s3（纯 MoonBit 异步 S3Client）与 sim
/// (SimStore 仿真)。所有后端都已实现 `@store.ObjectStore` 的 async 契约，
/// 这里只做一层同步外观的委托（impl 体内直接 await-free 调用后端异步方法）。
pub(all) enum AnyStore {
  FS(@fsstore.FsStore)
  S3Async(@s3client.S3Client)
  Sim(@simstore.SimStore)
}

// ---------- io_uring 完成引擎（FsStore 读路径） ----------
//
// `SPND_FS_IO=uring`（native 默认）时，fs 后端的整读/范围读走完成引擎
// （Linux 内核 io_uring，macOS 走 pread worker pool）；
// `SPND_FS_IO=pread` 回退到 FsStore 自己的同步 POSIX 读。
//
// 写路径保持 FsStore::put：它还要原子 rename + `.ver` 版本 sidecar + 索引
// 维护，语义不能被绕过（读路径才是随机 IO 的热点）。

///|
let fs_io_engine : Ref[@uring.UringEngine?] = { val: None }

///|
/// 当前 fs IO 模式："uring"（默认）或 "pread"。
fn fs_io_mode() -> String {
  let v = env_or("SPND_FS_IO", "uring").trim().to_lower()
  if v == "pread" || v == "sync" || v == "direct" {
    "pread"
  } else {
    "uring"
  }
}

///|
/// native 启动时准备完成引擎（幂等；失败则保持 None 并退回 pread）。
async fn init_fs_io() -> Unit {
  if fs_io_engine.val is Some(_) {
    return
  }
  if fs_io_mode() == "pread" {
    return
  }
  let eng = @uring.UringEngine::new() catch {
    e => {
      println("[serve] uring init failed, falling back to pread: \{e}")
      return
    }
  }
  fs_io_engine.val = Some(eng)
}

///|
fn fs_io_backend() -> String {
  match fs_io_engine.val {
    Some(e) => e.backend_kind()
    None => "pread"
  }
}

///|
async fn fs_read_path(
  s : @fsstore.FsStore,
  eng : @uring.UringEngine,
  key : String,
) -> Bytes? {
  let path = (s.file_path(key)) catch {
    _ => return @store.ObjectStore::get(s, key)
  }
  eng.read_file(path)
}

///|
async fn fs_read_range_path(
  s : @fsstore.FsStore,
  eng : @uring.UringEngine,
  key : String,
  offset : Int,
  len : Int,
) -> Bytes? {
  let path = (s.file_path(key)) catch {
    _ => return s.get_range(key, @store.ByteRange::{ off: offset, len: len })
  }
  eng.read_range(path, offset, len)
}

///|
async fn raw_get(store : AnyStore, key : String) -> Bytes? {
  match store {
    FS(s) =>
      match fs_io_engine.val {
        Some(eng) => fs_read_path(s, eng, key)
        None => s.get(key)
      }
    S3Async(s) => @s3client.S3Client::get(s, key)
    Sim(s) => s.get(key)
  }
}

///|
async fn raw_get_range(
  store : AnyStore,
  key : String,
  offset : Int,
  len : Int,
) -> Bytes? {
  match store {
    FS(s) =>
      match fs_io_engine.val {
        Some(eng) => fs_read_range_path(s, eng, key, offset, len)
        None => s.get_range(key, @store.ByteRange::{ off: offset, len: len })
      }
    S3Async(s) => @s3client.S3Client::fetch_range(s, key, offset, len)
    Sim(s) => s.get_range(key, @store.ByteRange::{ off: offset, len: len })
  }
}

///|
async fn raw_list(store : AnyStore, prefix : String) -> Array[String] {
  match store {
    FS(s) => s.list(prefix)
    S3Async(s) => @s3client.S3Client::list(s, prefix)
    Sim(s) => s.list(prefix)
  }
}

///|
async fn raw_head_version(store : AnyStore, key : String) -> String? {
  match store {
    FS(s) => s.head_version(key)
    S3Async(s) => @s3client.S3Client::head_version(s, key)
    Sim(s) => s.head_version(key)
  }
}

///|
/// 批量读取内部存储（S3 走连接池并发 multi，FS/Sim 走默认顺序 fallback）。
async fn raw_get_many(store : AnyStore, keys : Array[String]) -> Array[Bytes?] {
  match store {
    FS(s) => @store.ObjectStore::get_many(s, keys)
    S3Async(s) => {
      // S3Client 的批量读走连接槽位池并发（ObjectStore impl 在 s3client 包内
      // 私有，这里显式并发调用公开方法，语义与 get_many 一致）。
      let jobs : Array[async () -> Bytes?] = Array(capacity=keys.length())
      for k in keys {
        let key = k
        jobs.push(async fn () { @s3client.S3Client::get(s, key) })
      }
      @async.all(jobs)
    }
    Sim(s) => @store.ObjectStore::get_many(s, keys)
  }
}

///|
/// 批量查 metad；只对 metadata key 发请求，未命中不视为错误。
/// 这一步让冷查询的段 meta / 列元数据也走并发 multi，而不是逐 key 串行。
async fn meta_get_many(keys : Array[String]) -> Map[String, Bytes] {
  let out : Map[String, Bytes] = Map([])
  if !meta_enabled() {
    return out
  }
  let client = match meta_client.val {
    Some(c) => c
    None => return out
  }
  let req_keys : Array[String] = Array()
  let seen : Set[String] = Set([])
  for key in keys {
    if !@meta.is_metadata_key(key) || seen.contains(key) {
      continue
    }
    seen.add(key)
    req_keys.push(key)
  }
  if req_keys.is_empty() {
    return out
  }
  let prefixed : Array[String] = Array(capacity=req_keys.length())
  for k in req_keys {
    prefixed.push(meta_key(k))
  }
  let res = (client.get_kv_many(prefixed)) catch {
    _ => return out
  }
  for i in 0..<req_keys.length() {
    match res[i] {
      Some(bs) => out.set(req_keys[i], bs)
      None => ()
    }
  }
  out
}

///|
/// SlabV2 单文件段的内嵌 meta 组件读取。
///
/// `@build.ingest_l0_slab`（写路径默认入口）把六列 + 倒排 + **meta** 全部塞进
/// 一个 `segment.slab` 对象，不再单独写 `_segments/{id}/meta.json`；而查询层
/// 打开一个 namespace 时需要每段的 meta（row_count / min_id / partitions）。
/// 存储层在这里补一个兼容读：`.../meta.json` 未命中且段是 L0 slab 段时，从
/// slab 里切片还原。读到的结果会像其它 metadata key 一样被回填 metad。
async fn slab_embedded_meta(store : AnyStore, key : String) -> Bytes? {
  let suffix = "/_segments/"
  let tail = "/meta.json"
  if !key.has_suffix(tail) {
    return None
  }
  let idx = match key.find(suffix) {
    Some(i) => i
    None => return None
  }
  let ns = key[:idx].to_owned()
  let rest = key[idx + suffix.length():]
  let seg_id = match rest.find("/") {
    Some(j) => rest[:j].to_owned()
    None => return None
  }
  if !@build.is_l0_slab_segment(seg_id) {
    return None
  }
  let slab_key = @build.segment_slab_key(ns, seg_id)
  let slab = match raw_get(store, slab_key) {
    Some(bs) => bs
    None => return None
  }
  let decoded = try {
    Ok(@format.decode_slab_file(slab))
  } catch {
    _ => Err(())
  }
  match decoded {
    Err(_) => None
    Ok(pair) => {
      let (_ver, index) = pair
      index.get_slice(slab, "meta")
    }
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
    None =>
      match slab_embedded_meta(self, key) {
        Some(bs) => {
          if @meta.is_metadata_key(key) {
            meta_put(key, bs)
          }
          Some(bs)
        }
        None => resolve_branch_get(self, key)
      }
  }
}

///|
/// 批量读：先并发查 metad，未命中的再按底层后端批量回源，保持原下标。
/// 对 metadata key 的回填仍走 meta_put；branch fallback 只对 miss 逐项处理。
pub impl @store.ObjectStore for AnyStore with get_many(self, keys) {
  let out : Array[Bytes?] = Array(capacity=keys.length())
  for _ in keys {
    out.push(None)
  }
  let hits = meta_get_many(keys)
  let missing_keys : Array[String] = Array()
  let missing_idx : Array[Int] = Array()
  for i in 0..<keys.length() {
    match hits.get(keys[i]) {
      Some(bs) => out[i] = Some(bs)
      None => {
        missing_keys.push(keys[i])
        missing_idx.push(i)
      }
    }
  }
  if missing_keys.is_empty() {
    return out
  }
  let raw = raw_get_many(self, missing_keys)
  for j in 0..<missing_keys.length() {
    let key = missing_keys[j]
    match raw[j] {
      Some(bs) => {
        if @meta.is_metadata_key(key) {
          meta_put(key, bs)
        }
        out[missing_idx[j]] = Some(bs)
      }
      None =>
        match slab_embedded_meta(self, key) {
          Some(bs) => {
            if @meta.is_metadata_key(key) {
              meta_put(key, bs)
            }
            out[missing_idx[j]] = Some(bs)
          }
          None =>
            match resolve_branch_get(self, key) {
              Some(bs) => out[missing_idx[j]] = Some(bs)
              None => ()
            }
        }
    }
  }
  out
}

///|
pub impl @store.ObjectStore for AnyStore with put(self, key, bs) {
  match self {
    FS(s) => s.put(key, bs)
    S3Async(s) => @s3client.S3Client::put(s, key, bs)
    Sim(s) => s.put(key, bs)
  }
  meta_put(key, bs)
}

///|
pub impl @store.ObjectStore for AnyStore with put_if_match(self, key, expected : @store.Expected, bs) {
  let ok = match self {
    FS(s) => s.put_if_match(key, expected, bs)
    S3Async(s) => @s3client.S3Client::conditional_put(s, key, bs, expected.0)
    Sim(s) => s.put_if_match(key, expected, bs)
  }
  if ok {
    meta_put(key, bs)
  }
  ok
}

///|
pub impl @store.ObjectStore for AnyStore with get_range(self, key, br : @store.ByteRange) {
  let offset = br.off
  let len = br.len
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
    S3Async(s) => @s3client.S3Client::delete(s, key)
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
/// 构造存储后端。
/// `SPND_STORE=fs:PATH`（默认）| `s3`（AWS_*/S3_* 环境变量）| `sim`。
pub fn make_store() -> AnyStore raise @core.SpndError {
  let spec = env_or("SPND_STORE", "fs:/tmp/spnd-data")
  if spec.has_prefix("fs:") {
    return FS(@fsstore.FsStore::new(spec[3:].to_owned()))
  }
  if spec == "s3" {
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
    let inflight = env_int("SPND_S3_MAX_INFLIGHT", 32, 1)
    return S3Async(
      @s3client.S3Client::new(
        endpoint,
        bucket,
        region,
        access_key,
        secret_key,
        max_inflight=inflight,
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
/// 简单进程内 LRU：条目数与总权重双上限，超限时淘汰最久未使用的条目。
/// 只存在进程内存，不落盘（不做 SSD 缓存，也不新增持久化层）。
struct LruEntry[V] {
  mut value : V
  mut used : UInt64
  mut weight : Int
}

///|
struct LruCache[V] {
  entries : Map[String, LruEntry[V]]
  capacity : Int
  max_weight : Int
  mut total_weight : Int
  mut tick : UInt64
  weigh : (V) -> Int
}

///|
fn[V] LruCache::new(
  capacity : Int,
  max_weight : Int,
  weigh : (V) -> Int,
) -> LruCache[V] {
  {
    entries: Map([]),
    capacity: if capacity < 1 { 1 } else { capacity },
    max_weight,
    total_weight: 0,
    tick: 0UL,
    weigh,
  }
}

///|
fn[V] LruCache::length(self : LruCache[V]) -> Int {
  self.entries.length()
}

///|
fn[V] LruCache::get(self : LruCache[V], key : String) -> V? {
  match self.entries.get(key) {
    Some(e) => {
      self.tick = self.tick + 1UL
      e.used = self.tick
      Some(e.value)
    }
    None => None
  }
}

///|
fn[V] LruCache::remove(self : LruCache[V], key : String) -> Unit {
  match self.entries.remove_and_get(key) {
    Some(e) => self.total_weight = self.total_weight - e.weight
    None => ()
  }
}

///|
fn[V] LruCache::set(self : LruCache[V], key : String, value : V) -> Unit {
  let w = (self.weigh)(value)
  self.tick = self.tick + 1UL
  match self.entries.get(key) {
    Some(e) => {
      self.total_weight = self.total_weight - e.weight + w
      e.value = value
      e.weight = w
      e.used = self.tick
    }
    None => {
      self.entries.set(key, { value, used: self.tick, weight: w })
      self.total_weight = self.total_weight + w
    }
  }
  self.trim()
}

///|
fn[V] LruCache::evict_one(self : LruCache[V]) -> Bool {
  let mut victim : String? = None
  let mut victim_used = 0UL
  let mut first = true
  for k, e in self.entries {
    if first || e.used < victim_used {
      first = false
      victim = Some(k)
      victim_used = e.used
    }
  }
  match victim {
    Some(k) => {
      self.remove(k)
      true
    }
    None => false
  }
}

///|
fn[V] LruCache::trim(self : LruCache[V]) -> Unit {
  while self.entries.length() > self.capacity ||
    (self.max_weight > 0 && self.total_weight > self.max_weight) {
    if !self.evict_one() {
      break
    }
  }
}

///|
fn env_int(key : String, dflt : Int, min_v : Int) -> Int {
  let v = match @env.get_env_var(key) {
    Some(s) =>
      match parse_int_str(s.trim().to_owned()) {
        Some(n) => n
        None => dflt
      }
    None => dflt
  }
  if v < min_v { min_v } else { v }
}

///|
/// MB -> bytes，避免 `MB * 1024 * 1024` 在 Int32 上溢出后变成负值（会让 LRU
/// 误以为“不限字节”）。
fn env_mb(key : String, dflt : Int) -> Int {
  let mb = env_int(key, dflt, 0)
  let capped = if mb > 2047 { 2047 } else { mb }
  capped * 1024 * 1024
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
fn SegmentCache::weight(self : SegmentCache) -> Int {
  let mut n = self.ids.length() * 8 + self.tss.length() * 8 + self.pubs.length()
  // 按 UTF-8 上界保守估算：MoonBit String.length() 不是字节数，CJK 会低估。
  for s in self.texts {
    n = n + s.length() * 3 + 8
  }
  for s in self.cats {
    n = n + s.length() * 3 + 8
  }
  n
}

///|
/// 内存中的 namespace 状态：只有 build 读快照与小容量缓存，没有 mtree 写引擎。
struct NamespaceState {
  mut build_head : String
  mut query_ns : @query.Namespace[AnyStore]?
  mut meta : @format.NamespaceMeta?
  doc_cache : LruCache[DocAttributes]
  doc_full_cache : LruCache[@core.Doc]
  mut last_write_ms : Int64
  mut live_segments : Int
  mut manifest_num_docs : Int
  mut manifest_deleted : Int
}

///|
/// 活跃 namespace 上限（LRU）：默认 2048，适合大量小用户，避免无限增长。
let active_ns : LruCache[NamespaceState] = LruCache::new(
  env_int("SPND_ACTIVE_NS_MAX", 2048, 1),
  0,
  fn(_s : NamespaceState) -> Int { 1 },
)

///|
let global_coordinator : Ref[@control.Coordinator[AnyStore]?] = { val: None }

///|
fn get_coordinator(store : AnyStore) -> @control.Coordinator[AnyStore] {
  match global_coordinator.val {
    Some(coord) => coord
    None => {
      // 每进程单份 LRU：进程内不再复制 N 份 worker 缓存（多进程模式由
      // SO_REUSEPORT 在进程间分摊）。SPND_QUERY_WORKERS 仅保留分片探测语义。
      let worker_count_str = env_or("SPND_QUERY_WORKERS", "1")
      let count = match parse_int_str(worker_count_str) {
        Some(c) => if c < 1 { 1 } else { c }
        None => 1
      }
      let cache_mb_str = env_or("SPND_CACHE_MB", "64")
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
async fn NamespaceState::get_query_ns(
  self : NamespaceState,
  store : AnyStore,
  ns : String,
) -> @query.Namespace[AnyStore] {
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
      self.live_segments = snap.manifest.segments.length()
      self.manifest_num_docs = snap.manifest.num_docs
      self.manifest_deleted = snap.manifest.deleted.length()
      self.last_write_ms = @async.now()
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
async fn NamespaceState::update_after_write(
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
  self.live_segments = manifest.segments.length()
  self.manifest_num_docs = manifest.num_docs
  self.manifest_deleted = manifest.deleted.length()
  self.last_write_ms = @async.now()
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
  // 只继承新 manifest 里仍然存在的段/代，避免 compact 后把被合并掉的
  // CachedSeg（含 ids/doc_len/vec_parts）和旧 global parts 变成永久孤儿。
  let keep_seg_ids : Set[String] = Set([])
  for seg in manifest.segments {
    keep_seg_ids.add(seg.id)
  }
  let keep_vers : Set[String] = Set([])
  match manifest.vec_global_version {
    Some(v) => if v != "" { keep_vers.add(v) }
    None => ()
  }
  match self.meta {
    Some(m) =>
      match m.vec_global_version {
        Some(v) => if v != "" { keep_vers.add(v) }
        None => ()
      }
    None => ()
  }
  match manifest.global_gen {
    Some(g) => {
      if g.base != "" {
        keep_vers.add(g.base)
      }
      for d in g.deltas {
        keep_vers.add(d)
      }
    }
    None => ()
  }
  let old_cache : Map[String, @query.CachedSeg] = Map([])
  match self.query_ns {
    Some(old) => {
      for seg in manifest.segments {
        match old.cache.get(seg.id) {
          Some(cs) => old_cache.set(seg.id, cs)
          None => ()
        }
      }
    }
    None => ()
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
  let global_gen_cids : Map[String, Array[Int]] = Map([])
  let global_gen_packs : Map[String, Int] = Map([])
  match self.query_ns {
    Some(old) => {
      for ver, cids in old.global_gen_cids {
        if keep_vers.contains(ver) {
          global_gen_cids.set(ver, cids)
        }
      }
      for ver, ps in old.global_gen_packs {
        if keep_vers.contains(ver) {
          global_gen_packs.set(ver, ps)
        }
      }
    }
    None => ()
  }
  let global_parts : Map[String, @format.GlobalVecPart] = Map([])
  match self.query_ns {
    Some(old) => {
      for key, gp in old.global_parts {
        let ver = match key.find("/") {
          Some(i) => key[:i].to_owned()
          None => key
        }
        if keep_vers.contains(ver) {
          global_parts.set(key, gp)
        }
      }
    }
    None => ()
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
/// 取（或创建）内存状态。**不初始化任何写引擎/compactor**：写路径统一走 @build。
fn get_or_create_ns_state(
  _store : AnyStore,
  ns : String,
  _dim : Int,
) -> NamespaceState {
  match active_ns.get(ns) {
    Some(state) => state
    None => {
      let state : NamespaceState = {
        build_head: "",
        query_ns: None,
        meta: None,
        doc_cache: LruCache::new(
          env_int("SPND_DOC_CACHE_MAX", 8192, 1),
          env_mb("SPND_DOC_CACHE_MB", 16),
          fn(a : DocAttributes) -> Int {
            a.text.length() * 3 + a.category.length() * 3 + 64
          },
        ),
        doc_full_cache: LruCache::new(
          env_int("SPND_DOC_FULL_CACHE_MAX", 2048, 1),
          env_mb("SPND_DOC_FULL_CACHE_MB", 32),
          fn(d : @core.Doc) -> Int {
            d.text.length() * 3 + d.vector.length() * 4 + 64
          },
        ),
        last_write_ms: 0L,
        live_segments: 0,
        manifest_num_docs: 0,
        manifest_deleted: 0,
      }
      active_ns.set(ns, state)
      state
    }
  }
}

///|
async fn get_or_load_ns_state(
  store : AnyStore,
  ns : String,
) -> NamespaceState {
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
      state.live_segments = snap.manifest.segments.length()
      state.manifest_num_docs = snap.manifest.num_docs
      state.manifest_deleted = snap.manifest.deleted.length()
      state.last_write_ms = @async.now()
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
/// 显式合并一个 namespace（`POST /compact` 用）：后台合并已经下线到独立进程
/// `cmd/compactd`，serve 只保留一次同步合并入口以便运维手动触发。
/// 失败只保留旧 head，绝不退化成 mtree 双写。
///
/// 返回合并后的新 head（无变化时返回旧 head）。
async fn compact_namespace_state(
  store : AnyStore,
  state : NamespaceState,
  ns : String,
) -> String {
  let cfg = cfg_for(store, ns, false, None, 0)
  // 与 cmd/compactd 用同一个合并器：乐观 rebase（读 slab/legacy 两种段布局，
  // CAS 发布新 manifest，不重传已上传的合并段）。
  let merged = @build.compact_optimistic(store, cfg)
  let head = match merged {
    Some(h) => h
    None =>
      match @store.read_head_pointer(store, ns) {
        Some(h) => h
        None => @store.read_head(store, ns, "")
      }
  }
  if head != "" {
    store.put(@store.head_pointer_key(ns), @utf8.encode(head))
    state.update_after_write(store, ns, head)
  }
  head
}

///|
/// 查询所读 segment 的小容量内存缓存（条目 + 字节上限，LRU 淘汰）。
/// 每进程只有这一份（多进程模式下不再在进程内复制 N 份 worker 缓存），
/// 字节上限由 `SPND_CACHE_MB`（默认 64）统一控制。
let seg_cache : LruCache[SegmentCache] = LruCache::new(
  env_int("SPND_SEG_CACHE_MAX", 4096, 1),
  env_mb("SPND_CACHE_MB", 64),
  fn(sc : SegmentCache) -> Int { sc.weight() },
)

///|
/// 每段的完整 Doc 数组缓存（SlabV2 单文件段与 legacy 多文件段统一入口）。
/// 属性补全/补丁命中时只读一次段对象，后续行走内存。
let seg_docs_cache : LruCache[Array[@core.Doc]] = LruCache::new(
  env_int("SPND_SEG_DOCS_CACHE_MAX", 1024, 1),
  0,
  fn(docs : Array[@core.Doc]) -> Int { docs.length() },
)

///|
/// 读一段的全部行（自动派发 SlabV2 单文件 / Legacy 多文件布局），带进程内缓存。
async fn load_seg_docs(
  store : AnyStore,
  ns : String,
  seg : @format.SegmentMeta,
  preloaded : Array[Float]?,
  preloaded_dim : Int,
) -> Array[@core.Doc] {
  match preloaded {
    Some(_) =>
      // 全局 IVF：向量不落段内，按代际链预读的 flat 数组重建（不缓存，
      // 因为不同 manifest 的段坐标可能变化）。
      @build.load_segment_docs(store, ns, seg, preloaded, preloaded_dim)
    None =>
      match seg_docs_cache.get(seg.id) {
        Some(docs) => docs
        None => {
          let docs = @build.load_segment_docs(store, ns, seg, None, 0)
          seg_docs_cache.set(seg.id, docs)
          docs
        }
      }
  }
}

///|
/// 列缓存：legacy 段读 rows/*.bin，SlabV2 单文件段从段内六列还原。
async fn load_segment_cache(
  store : AnyStore,
  ns : String,
  seg : @format.SegmentMeta,
) -> SegmentCache? {
  let seg_id = seg.id
  if @build.is_l0_slab_segment(seg_id) {
    let docs = load_seg_docs(store, ns, seg, None, 0)
    let ids : Array[UInt64] = Array(capacity=docs.length())
    let texts : Array[String] = Array(capacity=docs.length())
    let cats : Array[String] = Array(capacity=docs.length())
    let tss : Array[Int64] = Array(capacity=docs.length())
    let pubs : Array[Bool] = Array(capacity=docs.length())
    for d in docs {
      ids.push(d.id)
      texts.push(d.text)
      cats.push(d.category)
      tss.push(d.ts)
      pubs.push(d.public)
    }
    let sc : SegmentCache = { ids, texts, cats, tss, pubs }
    seg_cache.set(seg_id, sc)
    return Some(sc)
  }
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
/// build 段是 append-only；被 delete/覆盖的旧行仍在列里，属性补全/补丁必须
/// 先看 manifest tombstone，否则已删除文档会被 lookup 复活。
fn[T] doc_is_deleted(n : @query.Namespace[T], doc_id : UInt64) -> Bool {
  for d in n.manifest.deleted {
    if d == doc_id {
      return true
    }
  }
  false
}

///|
/// 读一条全局 IVF 代（base 或 delta）的全部 part（含 pack 布局）。
/// 返回 (dim, parts)；代不存在或没有 part 时返回 (0, [])。
async fn read_global_gen_all(
  store : AnyStore,
  ns : String,
  ver : String,
) -> (Int, Array[@format.GlobalVecPart]) {
  let meta_key = "\{ns}/vec/global/\{ver}/meta.json"
  let meta_bs_opt = (store.get(meta_key)) catch {
    _ => None
  }
  let meta_bs = match meta_bs_opt {
    Some(bs) => bs
    None => return (0, [])
  }
  let j = (@json.parse(@utf8.decode_lossy(meta_bs.exact_view()))) catch {
    _ => return (0, [])
  }
  let m = match j {
    Object(mm) => mm
    _ => return (0, [])
  }
  let dim = match m.get("dim") {
    Some(Number(d, ..)) => d.to_int()
    _ => 0
  }
  let cids : Array[Int] = Array()
  match m.get("cids") {
    Some(Array(a)) =>
      for x in a {
        match x {
          Number(d, ..) => cids.push(d.to_int())
          _ => ()
        }
      }
    _ => ()
  }
  let pack_size = match m.get("pack_size") {
    Some(Number(d, ..)) => if d.to_int() < 1 { 1 } else { d.to_int() }
    _ => 1
  }
  let parts : Array[@format.GlobalVecPart] = Array()
  if cids.is_empty() {
    return (dim, parts)
  }
  if pack_size <= 1 {
    let keys : Array[String] = Array(capacity=cids.length())
    for cid in cids {
      keys.push("\{ns}/vec/global/\{ver}/part-\{cid}.bin")
    }
    let got = @store.ObjectStore::get_many(store, keys)
    for i in 0..<got.length() {
      match got[i] {
        Some(bs) => {
          let p = (@format.decode_global_part(bs)) catch {
            _ => continue
          }
          parts.push(p)
        }
        None => ()
      }
    }
  } else {
    let packs : Set[Int] = Set([])
    for cid in cids {
      packs.add(cid / pack_size)
    }
    let pack_ids : Array[Int] = Array()
    for p in packs {
      pack_ids.push(p)
    }
    pack_ids.sort_by(fn(a, b) { a.compare(b) })
    for pk in pack_ids {
      let pkey = "\{ns}/vec/global/\{ver}/pack-\{pk}.bin"
      let bs_opt = (store.get(pkey)) catch {
        _ => None
      }
      let bs = match bs_opt {
        Some(b) => b
        None => continue
      }
      let idx = (@format.decode_global_pack_index(bs)) catch {
        _ => continue
      }
      for item in idx {
        let (_c, off, len) = item
        let p = (@format.decode_global_part_at(bs, off, len)) catch {
          _ => continue
        }
        parts.push(p)
      }
    }
  }
  (dim, parts)
}

///|
/// manifest 钉住的全局 IVF 代际链 → `"{seg_idx}:{row}"` 的向量表。
/// compact 会重建全量 base（段序随之重排），所以 base + deltas 的行坐标
/// 始终与“当前 manifest 的段序”一致。
let global_vec_table_cache : Ref[(String, Map[String, Array[Float]], Int)?] = {
  val: None
}

///|
async fn cached_global_vec_table(
  store : AnyStore,
  ns : String,
  manifest : @format.ManifestData,
) -> (Map[String, Array[Float]], Int) {
  match global_vec_table_cache.val {
    Some((mid, tbl, dim)) =>
      if mid == manifest.id {
        return (tbl, dim)
      }
    None => ()
  }
  let versions : Array[String] = Array()
  match manifest.global_gen {
    Some(g) => {
      if g.base != "" {
        versions.push(g.base)
      }
      for d in g.deltas {
        versions.push(d)
      }
    }
    None =>
      match manifest.vec_global_version {
        Some(v) => if v != "" {
          versions.push(v)
        }
        None => ()
      }
  }
  let tbl : Map[String, Array[Float]] = Map([])
  let mut dim = 0
  let seen : Set[String] = Set([])
  for ver in versions {
    if seen.contains(ver) {
      continue
    }
    seen.add(ver)
    let (vdim, parts) = (read_global_gen_all(store, ns, ver)) catch {
      _ => (0, [])
    }
    if dim == 0 && vdim > 0 {
      dim = vdim
    }
    for gp in parts {
      for gi in 0..<gp.rows.length() {
        let (si, ri) = gp.rows[gi]
        let v : Array[Float] = Array(capacity=gp.dim)
        let off = gi * gp.dim
        for d in 0..<gp.dim {
          v.push(gp.data[off + d])
        }
        tbl.set("\{si}:\{ri}", v)
      }
    }
  }
  global_vec_table_cache.val = Some((manifest.id, tbl, dim))
  (tbl, dim)
}

///|
/// 把某段整段向量拼成 flat 数组（全局 IVF 模式给 load_segment_docs 用）；
/// 任何一行缺失都返回 None（宁可回退也不伪造向量）。
fn flat_seg_vectors(
  tbl : Map[String, Array[Float]],
  s_idx : Int,
  row_count : Int,
  dim : Int,
) -> Array[Float]? {
  if dim <= 0 || row_count <= 0 {
    return None
  }
  let out : Array[Float] = Array(capacity=row_count * dim)
  for r in 0..<row_count {
    match tbl.get("\{s_idx}:\{r}") {
      Some(v) =>
        if v.length() != dim {
          return None
        } else {
          for x in v {
            out.push(x)
          }
        }
      None => return None
    }
  }
  Some(out)
}

///|
/// 取完整 Doc（含向量）。两条段布局统一走 `@build.load_segment_docs`：
/// - SlabV2 单文件段（L0 delta / compact 输出）：六列打包在一个对象里；
/// - legacy 多文件段：六列来自 `rows/*.bin`，向量来自 `vec/part-*`。
/// 全局 IVF 单副本模式（段内不存向量）时先按代际链把整段向量预读成 flat
/// 数组传进去，语义与 compact/query 的全局向量路径一致。
async fn lookup_doc_full(
  store : AnyStore,
  ns : String,
  n : @query.Namespace[AnyStore],
  doc_id : UInt64,
) -> @core.Doc? {
  if doc_is_deleted(n, doc_id) {
    return None
  }
  match active_ns.get(ns) {
    Some(state) =>
      match state.doc_full_cache.get(doc_id.to_string()) {
        Some(d) => return Some(d)
        None => ()
      }
    None => ()
  }
  let has_global = n.manifest.vec_global_version is Some(_) ||
    n.manifest.global_gen is Some(_)
  let mut vtbl : Map[String, Array[Float]] = Map([])
  let mut gdim = 0
  if has_global {
    let (tbl, dim) = cached_global_vec_table(store, ns, n.manifest)
    vtbl = tbl
    gdim = dim
  }
  let mut s_idx = n.manifest.segments.length() - 1
  while s_idx >= 0 {
    let seg = n.manifest.segments[s_idx]
    if doc_id >= seg.min_id && doc_id <= seg.max_id {
      let pre : Array[Float]? = if has_global {
        flat_seg_vectors(vtbl, s_idx, seg.row_count, gdim)
      } else {
        None
      }
      let docs = (load_seg_docs(store, ns, seg, pre, gdim)) catch {
        _ => []
      }
      for i in 0..<docs.length() {
        if docs[i].id == doc_id {
          let mut doc = docs[i]
          if doc.vector.is_empty() {
            match vtbl.get("\{s_idx}:\{i}") {
              Some(v) => doc = { ..doc, vector: v }
              None => ()
            }
          }
          match active_ns.get(ns) {
            Some(state) => state.doc_full_cache.set(doc_id.to_string(), doc)
            None => ()
          }
          return Some(doc)
        }
      }
    }
    s_idx -= 1
  }
  None
}

///|
async fn lookup_doc_attrs(
  store : AnyStore,
  ns : String,
  n : @query.Namespace[AnyStore],
  doc_id : UInt64,
) -> DocAttributes {
  if doc_is_deleted(n, doc_id) {
    return { text: "", category: "", ts: 0L, public: true }
  }
  match active_ns.get(ns) {
    Some(state) =>
      match state.doc_cache.get(doc_id.to_string()) {
        Some(attr) => return attr
        None => ()
      }
    None => ()
  }
  let mut s_idx = n.manifest.segments.length() - 1
  while s_idx >= 0 {
    let seg = n.manifest.segments[s_idx]
    if doc_id >= seg.min_id && doc_id <= seg.max_id {
      let sc = match seg_cache.get(seg.id) {
        Some(sc) => Some(sc)
        None => (load_segment_cache(store, ns, seg)) catch { _ => None }
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
                Some(state) => state.doc_cache.set(doc_id.to_string(), attr)
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
async fn[T : @store.ObjectStore] ns_meta(
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
  metric : String? // distance_metric 意图（cosine|euclidean）
  /// 持久化语义：true = strict（默认，等刷盘后响应）；false = lazy（立即 200）
  durability_lazy : Bool
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
/// JSON → u64 id（精确）：字符串（十进制 / 0x hex）u64 全范围精确；兼容旧
/// 客户端的 JSON number，但只接受 ≤ 2^53 的整数，超界**报错**不静默截断。
fn u64_from_json(j : Json) -> UInt64 raise @core.SpndError {
  match j {
    String(s) =>
      match @format.parse_u64_str(s) {
        Some(v) => v
        None => raise @core.Corrupt("id must be a decimal/hex u64 string: \{s}")
      }
    Number(d, ..) => @format.u64_from_legacy_num(d)
    _ => raise @core.Corrupt("id must be a decimal string or number")
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
  // durability：默认 strict（等组提交刷盘后响应）；"lazy" 立即 200。
  let durability_lazy = match m.get("durability") {
    Some(String("lazy")) => true
    Some(String("strict")) => false
    Some(String(other)) =>
      raise @core.Corrupt("durability must be strict|lazy, got \{other}")
    Some(_) => raise @core.Corrupt("durability must be a string")
    None => false
  }
  let _ = has_vector
  { docs, deletes, tokenizer, metric, durability_lazy }
}

///|
async fn[T : @store.ObjectStore] cfg_for(
  store : T,
  ns : String,
  rows_have_vector : Bool,
  tok_override : @core.Tokenizer?,
  vector_dim : Int,
) -> @build.BuildConfig {
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
  // consistency：读请求默认读进程内权威 build 快照；`strong`（及
  // `strong_nocache`）额外用 metad 的 bundle 对账一次 head（单次 RTT，
  // 命中时服务端返回 304），保证跨进程立刻可见。
  let consistency = match m.get("consistency") {
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
  if consistency != "eventual" {
    reconcile_head_with_metad(store, ns, state)
  }
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
    row_map.set("id", Json::string(r.id.to_string()))
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

// ---------- 写路径：每 namespace 组提交（Group Commit） ----------

///|
/// 一次写请求的提交结果。
pub(all) enum WriteOutcome {
  /// 严格模式：已刷盘，携带（本次写入行数, 新 head manifest id）。
  Committed(Int, String)
  /// lazy 模式：已进入当前批次立即返回，不保证已经持久化。
  AckedLazy(Int)
  /// 反压：namespace 的活跃 L0 批次已达上限（对应 HTTP 429）。
  Backpressured
}

///|
/// 全局组提交管理器：内部按 namespace 维护 pending 缓冲 / 等待者 / 计时器与
/// 活跃 L0 批次计数，即「每个 namespace 一个组提交状态」。它必须在 serve 的
/// task group 内创建（计时与刷盘协程挂在该 group 上）。
/// wbtest 里保持 None 时写路径直接落盘，便于纯逻辑单测。
let global_group_commit : Ref[@groupcommit.GroupCommitManager?] = { val: None }

///|
pub fn reset_group_commit_for_test() -> Unit {
  global_group_commit.val = None
}

///|
pub fn group_commit_installed_for_test() -> Bool {
  global_group_commit.val is Some(_)
}

///|
/// 组提交配置：25ms / 2048 行 / 8MB / 12 个活跃 L0 批次。
/// （`GroupCommitConfig` 由 groupcommit 包导出为只读，统一用它的默认值。）
fn group_commit_config() -> @groupcommit.GroupCommitConfig {
  @groupcommit.GroupCommitConfig::default()
}

///|
/// rows/deletes → 组提交 payload（JSON，可被 `parse_write` 原样解回）。
fn encode_rows_body(
  docs : Array[@core.Doc],
  deletes : Array[UInt64],
) -> String {
  let rows : Array[Json] = Array(capacity=docs.length())
  for d in docs {
    let m : Map[String, Json] = Map([])
    m.set("id", Json::string(d.id.to_string()))
    m.set("text", Json::string(d.text))
    m.set("category", Json::string(d.category))
    m.set("ts", Json::number(d.ts.to_double()))
    m.set("public", Json::boolean(d.public))
    if !d.vector.is_empty() {
      let v : Array[Json] = Array(capacity=d.vector.length())
      for x in d.vector {
        v.push(Json::number(x.to_double()))
      }
      m.set("vector", Json::array(v))
    }
    rows.push(Json::object(m))
  }
  let del : Array[Json] = Array(capacity=deletes.length())
  for id in deletes {
    del.push(Json::string(id.to_string()))
  }
  let root : Map[String, Json] = Map([])
  root.set("rows", Json::array(rows))
  root.set("deletes", Json::array(del))
  Json::object(root).stringify()
}

///|
/// 把本批写入后的进程内 ns state 与元数据对齐（缓存 + head）。
async fn commit_ns_state(
  store : AnyStore,
  ns : String,
  head : String,
  docs : Array[@core.Doc],
  deletes : Array[UInt64],
  dim : Int,
) -> Unit {
  let state = get_or_create_ns_state(store, ns, dim)
  if head != "" {
    state.update_after_write(store, ns, head)
  }
  for d in docs {
    state.doc_cache.set(d.id.to_string(), {
      text: d.text,
      category: d.category,
      ts: d.ts,
      public: d.public,
    })
    state.doc_full_cache.set(d.id.to_string(), d)
  }
  for id in deletes {
    state.doc_cache.remove(id.to_string())
    state.doc_full_cache.remove(id.to_string())
  }
}

///|
/// 直接落盘（没有组提交器时的单测路径）：一次 `ingest_l0_slab`。
async fn direct_ingest(
  store : AnyStore,
  ns : String,
  docs : Array[@core.Doc],
  deletes : Array[UInt64],
) -> String {
  let mut dim = 0
  if docs.length() > 0 {
    dim = docs[0].vector.length()
  }
  let cfg = cfg_for(store, ns, dim > 0, None, dim)
  let head = @build.ingest_l0_slab(store, cfg, docs, deletes)
  store.put(@store.head_pointer_key(ns), @utf8.encode(head))
  commit_ns_state(store, ns, head, docs, deletes, dim)
  meta_mark_dirty(ns)
  head
}

///|
/// 组提交 flush_fn：把本批所有 payload 解码聚合，一次 `ingest_l0_slab` 落盘，
/// 返回新的 head manifest id。成功后同步刷新进程内 ns state、head 指针与
/// metad 元数据，并 `mark_dirty`（后台合并由 cmd/compactd 消费）。
/// flush 之后调一次 `maybe_cutover`（IVF 重分区：num_docs/nlist > 2×target_rows
/// 时重训新中心、全量重写段分区）与一次 `maybe_compact_segments`：size-tiered 同档
/// 合并（同 tier
/// 段数 ≥ fanout=3 时合并该档最旧 3 段；安全阀段数 > tiers×fanout×2 退回
/// 一次前缀合并，把读放大压回 nprobe × 段数的低段数区）并回收 superseded 段。
async fn flush_batch(
  store : AnyStore,
  ns : String,
  payloads : Array[Bytes],
) -> String {
  let docs : Array[@core.Doc] = Array()
  let deletes : Array[UInt64] = Array()
  let mut dim = 0
  for p in payloads {
    let text = @utf8.decode_lossy(p.exact_view())
    let parsed = try {
      Ok(parse_write(text))
    } catch {
      e => Err(e)
    }
    match parsed {
      Ok(w) => {
        for d in w.docs {
          if dim == 0 && !d.vector.is_empty() {
            dim = d.vector.length()
          }
          docs.push(d)
        }
        for id in w.deletes {
          deletes.push(id)
        }
      }
      Err(_) => println("[serve] group commit: dropping malformed batch payload")
    }
  }
  if docs.is_empty() && deletes.is_empty() {
    // 空批：返回当前 head，避免无意义的 manifest 写入。
    return match @store.read_head_pointer(store, ns) {
      Some(h) => h
      None => @store.read_head(store, ns, "")
    }
  }
  let cfg = cfg_for(store, ns, dim > 0, None, dim)
  let head = @build.ingest_l0_slab(store, cfg, docs, deletes)
  store.put(@store.head_pointer_key(ns), @utf8.encode(head))
  commit_ns_state(store, ns, head, docs, deletes, dim)
  meta_mark_dirty(ns)
  // 组提交 flush 之后：IVF 重分区（cutover）——num_docs/nlist > 2×target_rows
  // 时以 nlist'=ceil(num_docs/target_rows) 重训新中心、全量重写段分区并乐观
  // rebase 发布；head 前移时同步 head 指针与 ns state。在段压力合并之前跑：
  // cutover 重写全部段，先合并会白费合并写放大。
  let cut_head = match @build.maybe_cutover(store, cfg) {
    Some(o) => o.head
    None => ""
  }
  if cut_head != "" {
    store.put(@store.head_pointer_key(ns), @utf8.encode(cut_head))
    commit_ns_state(store, ns, cut_head, [], [], dim)
    meta_mark_dirty(ns)
  }
  // 组提交 flush 之后：段数压力触发的前缀合并（段数 ≤ 8 时恒 no-op）。
  // 合并后 head 前移时同步 head 指针与 ns state（同 POST /compact 口径）。
  let outcome = @build.maybe_compact_segments(store, cfg)
  if outcome.head != "" && outcome.head != head {
    store.put(@store.head_pointer_key(ns), @utf8.encode(outcome.head))
    commit_ns_state(store, ns, outcome.head, [], [], dim)
    meta_mark_dirty(ns)
  }
  head
}

///|
/// 提交一批写：有组提交器时按 durability 语义合并刷盘，否则直接落盘。
async fn submit_batch(
  store : AnyStore,
  ns : String,
  docs : Array[@core.Doc],
  deletes : Array[UInt64],
  durability_strict : Bool,
) -> WriteOutcome {
  let payload_text = encode_rows_body(docs, deletes)
  let payload = @utf8.encode(payload_text)
  let rows = docs.length() + deletes.length()
  match global_group_commit.val {
    None => {
      let head = direct_ingest(store, ns, docs, deletes)
      WriteOutcome::Committed(docs.length(), head)
    }
    Some(gc) => {
      let res = (gc.submit(
        ns,
        rows,
        payload.length(),
        payload,
        durability_strict=durability_strict,
      )) catch {
        @groupcommit.GroupCommitError::Backpressure(_) =>
          return WriteOutcome::Backpressured
        e => raise e
      }
      match res {
        @groupcommit.AckedLazy => WriteOutcome::AckedLazy(docs.length())
        @groupcommit.Flushed(h) => WriteOutcome::Committed(docs.length(), h)
      }
    }
  }
}

// ---------- 多进程读写分离：写亲和路由 ----------

///|
/// worker 进程数（`SPND_WORKER_COUNT`，默认 1 = 单进程全兼容）。
fn worker_count() -> Int {
  env_int("SPND_WORKER_COUNT", 1, 1)
}

///|
/// 本进程 worker id（`SPND_WORKER_ID`，默认 0；越界时回落 0）。
fn worker_id() -> Int {
  let n = worker_count()
  let id = env_int("SPND_WORKER_ID", 0, 0)
  if id >= n {
    0
  } else {
    id
  }
}

///|
/// worker 内部端口基数（定向请求用，`SPND_INTERNAL_BASE_PORT`）。
fn internal_base_port() -> Int {
  env_int("SPND_INTERNAL_BASE_PORT", 19080, 1)
}

///|
/// FNV-1a 64-bit（UTF-8 字节）。与 `cmd/supervise` 的
/// `writer_owner_for_ns` 完全同源（纯函数副本，避免 serve 依赖 supervise）。
pub fn fnv1a64(s : String) -> UInt64 {
  let b = Buffer()
  b.write_string_utf8(s)
  let bs = b.to_bytes()
  let mut h : UInt64 = 0xcbf29ce484222325UL
  for i in 0..<bs.length() {
    h = h ^ bs[i].to_uint64()
    h = h * 0x100000001b3UL
  }
  h
}

///|
/// namespace 的写者归属（确定性 FNV-1a 64 % worker_count）；`worker_count <= 1`
/// 时恒为 0。任意进程都能算出同一结果，不需要额外协调。
pub fn writer_owner_for_ns(ns : String, worker_count : Int) -> Int {
  if worker_count <= 1 {
    return 0
  }
  (fnv1a64(ns) % worker_count.to_uint64()).to_int()
}

///|
/// worker 的内部端口 = base + worker_id（worker 间定向转发用）。
pub fn worker_internal_port(base_internal_port : Int, worker_id : Int) -> Int {
  if worker_id < 0 {
    base_internal_port
  } else {
    base_internal_port + worker_id
  }
}

///|
/// 是否是需要写亲和的 action（必须落到 namespace 的 owner 进程）。
fn is_write_action(action : String) -> Bool {
  action == "write" || action == "patch" || action == "delete_by_filter"
}

///|
/// 本进程要不要把该写请求转发给 owner。
fn needs_forwarding(ns : String, action : String) -> Bool {
  let n = worker_count()
  if n <= 1 {
    return false
  }
  if !is_write_action(action) {
    return false
  }
  writer_owner_for_ns(ns, n) != worker_id()
}

///|
/// 把写请求转发到 owner worker 的内部端口，透传状态码与响应体。
async fn forward_to_owner(
  ns : String,
  action : String,
  body : String,
) -> (Int, String) {
  let owner = writer_owner_for_ns(ns, worker_count())
  let port = worker_internal_port(internal_base_port(), owner)
  let bytes = @utf8.encode(body)
  let headers : @http.Headers = Map([])
  headers.set(
    @http.CaseInsensitiveString("content-length"),
    bytes.length().to_string(),
  )
  headers.set(
    @http.CaseInsensitiveString("content-type"),
    "application/json",
  )
  let client = @http.Client::Client("http://127.0.0.1:\{port}")
  let res = try {
    client.request(
      @http.Post,
      "/v1/namespaces/\{ns}/\{action}",
      extra_headers=headers,
    )
    if bytes.length() > 0 {
      client.write(bytes)
    }
    let resp = client.end_request()
    let data = client.read_all()
    Ok((resp.code, data.text()))
  } catch {
    e => Err(e)
  }
  client.close()
  match res {
    Ok(pair) => pair
    Err(e) =>
      (
        502,
        "{\"error\":\"forward to writer worker \{owner} failed: \{e}\"}",
      )
  }
}

///|
/// `consistency=strong` 时用 metad 的 bundle 对账 head（单次 RTT）：
/// 服务端 304 表示没变；否则用返回的 head 刷新进程内快照。
async fn reconcile_head_with_metad(
  store : AnyStore,
  ns : String,
  state : NamespaceState,
) -> Unit {
  if !meta_enabled() {
    return
  }
  let client = match meta_client.val {
    Some(c) => c
    None => return
  }
  let known : String? = if state.build_head == "" {
    None
  } else {
    Some(state.build_head)
  }
  let r = (client.get_bundle(ns, known_head=known)) catch {
    _ => return
  }
  match r {
    @meta.BundleResult::NotModified => ()
    @meta.BundleResult::Bundle(head, _ns_json) =>
      if head != "" && head != state.build_head {
        let man = (store.get("\{ns}/_manifest/\{head}.json")) catch {
          _ => None
        }
        match man {
          Some(_) => state.update_after_write(store, ns, head)
          None => ()
        }
      }
  }
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
  if w.docs.length() == 0 && w.deletes.is_empty() {
    let out : Map[String, Json] = Map([])
    out.set("ingested", Json::number(0.0))
    out.set("head", Json::string(""))
    respond(conn, 200, Json::object(out).stringify())
    return
  }
  // 记录新 namespace 的 tokenizer 意图（首次 write 时生效）
  match w.tokenizer {
    Some(t) => created_tokenizers.set(ns, t)
    None => ()
  }
  // 写路径：交给每 namespace 组提交（strict 等刷盘后返回 head / lazy 立即 200 /
  // 反压返回 429）。所有 rows+deletes 在同一 flush 里合并成一次 ingest_l0_slab。
  let outcome = submit_batch(store, ns, w.docs, w.deletes, !w.durability_lazy)
  match outcome {
    WriteOutcome::Backpressured =>
      respond(conn, 429, "{\"error\":\"backpressure\"}")
    WriteOutcome::AckedLazy(n) => {
      let out : Map[String, Json] = Map([])
      out.set("ingested", Json::number(n.to_double()))
      out.set("head", Json::string(""))
      out.set("durability", Json::string("lazy"))
      respond(conn, 200, Json::object(out).stringify())
    }
    WriteOutcome::Committed(n, head) => {
      let out : Map[String, Json] = Map([])
      out.set("ingested", Json::number(n.to_double()))
      out.set("head", Json::string(head))
      respond(conn, 200, Json::object(out).stringify())
    }
  }
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
/// 读出被 patch 的旧行并把未给出的属性补全（保留原 vector）。
async fn resolve_patches(
  store : AnyStore,
  ns : String,
  patches : Array[RowPatch],
) -> Array[@core.Doc] {
  if patches.is_empty() {
    return []
  }
  let state = get_or_load_ns_state(store, ns)
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
  updated_docs
}

///|
/// 部分更新：读出旧行（补全未给出的属性）后走同一套组提交落盘。
/// 返回（本次更新行数, 新 head）。空 patch 直接返回当前 head，不产生写入。
pub async fn patch_rows_core(
  store : AnyStore,
  ns : String,
  patches : Array[RowPatch],
) -> (Int, String) {
  match submit_patches(store, ns, patches, true) {
    PatchOutcome::Backpressured =>
      raise @core.CommitConflict("namespace \{ns} is under write backpressure")
    PatchOutcome::Done(n, head, _) => (n, head)
  }
}

///|
/// patch 提交结果（含 lazy 语义）。
pub(all) enum PatchOutcome {
  Done(Int, String, Bool)
  Backpressured
}

///|
/// 带 durability 语义的 patch 提交（HTTP 层用）。
async fn submit_patches(
  store : AnyStore,
  ns : String,
  patches : Array[RowPatch],
  durability_strict : Bool,
) -> PatchOutcome {
  let updated_docs = resolve_patches(store, ns, patches)
  if updated_docs.is_empty() {
    return PatchOutcome::Done(0, "", false)
  }
  let outcome = submit_batch(store, ns, updated_docs, [], durability_strict)
  match outcome {
    WriteOutcome::Backpressured => PatchOutcome::Backpressured
    WriteOutcome::AckedLazy(n) => PatchOutcome::Done(n, "", true)
    WriteOutcome::Committed(n, head) => PatchOutcome::Done(n, head, false)
  }
}

///|
/// 读请求体里的 durability 字段（默认 strict）。
fn parse_durability(body : String) -> Bool raise @core.SpndError {
  let j = @json.parse(body) catch {
    _ => return false
  }
  match j {
    Object(m) =>
      match m.get("durability") {
        Some(String("lazy")) => true
        Some(String("strict")) => false
        Some(String(other)) =>
          raise @core.Corrupt("durability must be strict|lazy, got \{other}")
        Some(_) => raise @core.Corrupt("durability must be a string")
        None => false
      }
    _ => false
  }
}

///|
async fn handle_patch(
  store : AnyStore,
  ns : String,
  body : String,
  conn : @http.ServerConnection,
) -> Unit raise {
  let patches = parse_patch(body)
  let wants_lazy = parse_durability(body)
  let outcome = submit_patches(store, ns, patches, !wants_lazy)
  match outcome {
    PatchOutcome::Backpressured =>
      respond(conn, 429, "{\"error\":\"backpressure\"}")
    PatchOutcome::Done(count, head, was_lazy) => {
      let out : Map[String, Json] = Map([])
      out.set("patched", Json::number(count.to_double()))
      out.set("head", Json::string(head))
      if was_lazy {
        out.set("durability", Json::string("lazy"))
      }
      respond(conn, 200, Json::object(out).stringify())
    }
  }
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
  out.set("segments", Json::number(state.live_segments.to_double()))
  out.set("manifest_num_docs", Json::number(state.manifest_num_docs.to_double()))
  out.set("last_write_ms", Json::number(state.last_write_ms.to_double()))
  out.set("deleted", Json::number(state.manifest_deleted.to_double()))
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
async fn delete_by_filter_core(
  store : AnyStore,
  ns : String,
  filter : @query.Filter,
) -> Int {
  let state = get_or_load_ns_state(store, ns)
  let n = state.get_query_ns(store, ns)
  let ids = @query.matching_ids(n, filter)
  if ids.length() > 0 {
    // 删除也走组提交（同一 namespace 的 rows/deletes 会被合并成一次落盘）
    let outcome = submit_batch(store, ns, [], ids, true)
    match outcome {
      WriteOutcome::Backpressured =>
        raise @core.CommitConflict("namespace \{ns} is under write backpressure")
      WriteOutcome::AckedLazy(_) => ()
      WriteOutcome::Committed(_, _) => ()
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
async fn copy_namespace_data(
  store : AnyStore,
  ns : String,
  dest_ns : String,
) -> Unit {
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

      // 写亲和：/write、/patch、/delete_by_filter 落到非 owner 进程时，
      // 透传到 owner worker 的内部端口（SPND_INTERNAL_BASE_PORT + owner），
      // 由 owner 统一持锁/组提交，避免同 namespace 跨进程写竞争。
      if needs_forwarding(ns, action) && req.meth is Post {
        let body = (reader.read_all()).text() catch {
          _ => ""
        }
        let (code, resp_body) = forward_to_owner(ns, action, body)
        respond(conn, code, resp_body)
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
          let state = get_or_load_ns_state(store, ns) catch {
            _ => {
              respond(conn, 500, "{\"error\":\"compact failed\"}")
              return
            }
          }
          let new_head = (compact_namespace_state(store, state, ns)) catch {
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
              return
            }
          }
          let out : Map[String, Json] = Map([])
          out.set("ok", Json::boolean(true))
          out.set("ns", Json::string(ns))
          out.set("head", Json::string(new_head))
          respond(conn, 200, Json::object(out).stringify())
        }
        (_, _) => respond(conn, 405, "{\"error\":\"method not allowed\"}")
      }
    }
    None => respond(conn, 404, "{\"error\":\"not found\"}")
  }
}

///|
/// 存储后端的人类可读描述（启动日志用）。
fn store_kind(store : AnyStore) -> String {
  match store {
    FS(_) => "fs"
    S3Async(_) => "s3(async)"
    Sim(_) => "sim"
  }
}

///|
/// serve 主入口。
///
/// 单进程（`SPND_WORKER_COUNT<=1`，默认）：一个 `@http.Server` 处理全部请求。
/// 多进程（`SPND_WORKER_COUNT>1`）：每个 worker 在 `SPND_PORT` 上用
/// `SO_REUSEPORT` 监听同一地址（内核按连接分发），并在
/// `SPND_INTERNAL_BASE_PORT + SPND_WORKER_ID` 上开一个内部端口接收写亲和转发。
async fn main {
  let port = env_or("SPND_PORT", "8080")
  meta_url.val = env_or("SPND_META_URL", "")
  meta_prefix.val = env_or("SPND_META_PREFIX", "")
  init_meta_client()
  init_fs_io()
  let store = make_store() catch {
    e => {
      println("store init failed: \{err_msg(e)}")
      return
    }
  }
  let workers = worker_count()
  let wid = worker_id()
  let kind = store_kind(store)
  @async.with_task_group(async fn (group : @async.TaskGroup[Unit]) {
    // 组提交管理器：生命周期覆盖所有写入协程（内部按 namespace 分状态）
    let gc = @groupcommit.GroupCommitManager::new(
      group,
      async fn (ns : String, payloads : Array[Bytes]) -> String {
        flush_batch(store, ns, payloads)
      },
      config=group_commit_config(),
    )
    global_group_commit.val = Some(gc)
    let handler = async fn (
      req : @http.Request,
      reader : &@io.Reader,
      conn : @http.ServerConnection,
    ) -> Unit {
      dispatch(store, req, reader, conn) catch {
        e => {
          println("[serve] request failed: \{e}")
          respond(conn, 500, "{\"error\":\"internal error\"}")
        }
      }
    }
    if workers <= 1 {
      let addr = @socket.Addr::parse("0.0.0.0:\{port}")
      let server = @http.Server::Server(addr, reuse_addr=true)
      println(
        "turbofish serve on 0.0.0.0:\{port} (store=\{kind}, fs_io=\{fs_io_backend()}, workers=1)",
      )
      server.run_forever(handler)
    } else {
      // 外部端口：SO_REUSEPORT，多进程共享同一监听地址、由内核负载均衡
      let ext = @netutil.ReusePortServer::bind(
        @socket.Addr::parse("0.0.0.0:\{port}"),
        headers=Map([]),
      )
      let inner_port = worker_internal_port(internal_base_port(), wid)
      let inner = @netutil.ReusePortServer::bind(
        @socket.Addr::parse("127.0.0.1:\{inner_port}"),
        reuse_port=false,
        headers=Map([]),
      )
      println(
        "turbofish serve worker \{wid}/\{workers} on 0.0.0.0:\{port} (internal :\{inner_port}, store=\{kind}, fs_io=\{fs_io_backend()})",
      )
      group.spawn_bg(
        no_wait=true,
        allow_failure=true,
        async fn () {
          inner.run_forever(handler)
        },
      )
      ext.run_forever(handler)
    }
  })
}

// 便捷方法转发：`store.get(...)`/`store.put(...)` 直接可用（不再依赖隐式提升）。
pub extend AnyStore with @store.ObjectStore::{
  get,
  get_many,
  get_range,
  put,
  put_if_match,
  list,
  delete,
  head_version,
}
