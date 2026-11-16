// cmd/compactd：后台紧凑合并守护（从 metad 领脏队列，独立进程，与 serve 分离）。
//
// 循环：
//   1. `POST /compact/claim` 领一个脏 namespace（同时拿到 `compact:{ns}` 租约）；
//   2. 走 `@build.compact_optimistic`（乐观 rebase，CommitConflict 最多重试 3 次）；
//   3. 完成后 `POST /leases/release` 释放租约；
//   4. 队列空时 `@async.sleep(200)`，不烧 CPU。
//
// 任何单个 namespace 的失败都只打日志（不退出进程）：租约到期后别的 compactor
// 会重新领到它，不会丢数据。
//
// 环境变量：
//   SPND_META_URL              metad 地址（必填，例如 http://127.0.0.1:8090）
//   SPND_STORE                 fs:PATH（默认 fs:/tmp/spnd-data）| s3 | sim
//   SPND_COMPACD_HOLDER        租约持有者标识（默认 compactd-{pid}-{随机}）
//   SPND_COMPACT_LEASE_TTL_MS  租约 TTL（默认 30000）
//   SPND_COMPACT_IDLE_MS       空闲轮询间隔（默认 200）
//   SPND_COMPACT_PREFIX_SEGS   单次合并的前缀段数上限（默认 8）
//   AWS_* / S3_*               s3 后端的 endpoint/bucket/凭据

///|
fn err_msg(e : Error) -> String {
  match e {
    @core.BadMagic(s) => "BadMagic(\{s})"
    @core.Truncated(s) => "Truncated(\{s})"
    @core.Corrupt(s) => "Corrupt(\{s})"
    @core.NotFound(s) => "NotFound(\{s})"
    @core.CommitConflict(s) => "CommitConflict(\{s})"
    @meta.MetadError::HttpStatus(code, desc) => "MetadHttp(\{code}, \{desc})"
    @meta.MetadError::MalformedResponse(desc) => "MetadMalformed(\{desc})"
    _ => "\{e}"
  }
}

///|
fn env_or(key : String, dflt : String) -> String {
  match @env.get_env_var(key) {
    Some(v) => if v.trim() == "" { dflt } else { v }
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

// ---------- 存储后端（compactd 只需要对象存储，不需要 metad 缓存/分支） ----------

///|
pub(all) enum CompactStore {
  FS(@fsstore.FsStore)
  S3Async(@s3client.S3Client)
  Sim(@simstore.SimStore)
}

///|
pub impl @store.ObjectStore for CompactStore with get(self, key) {
  match self {
    FS(s) => s.get(key)
    S3Async(s) => @s3client.S3Client::get(s, key)
    Sim(s) => s.get(key)
  }
}

///|
pub impl @store.ObjectStore for CompactStore with put(self, key, bs) {
  match self {
    FS(s) => s.put(key, bs)
    S3Async(s) => @s3client.S3Client::put(s, key, bs)
    Sim(s) => s.put(key, bs)
  }
}

///|
pub impl @store.ObjectStore for CompactStore with put_if_match(self, key, expected : @store.Expected, bs) {
  match self {
    FS(s) => s.put_if_match(key, expected, bs)
    S3Async(s) => @s3client.S3Client::conditional_put(s, key, bs, expected.0)
    Sim(s) => s.put_if_match(key, expected, bs)
  }
}

///|
pub impl @store.ObjectStore for CompactStore with get_range(self, key, br : @store.ByteRange) {
  let offset = br.off
  let len = br.len
  match self {
    FS(s) => s.get_range(key, @store.ByteRange::{ off: offset, len: len })
    S3Async(s) => @s3client.S3Client::fetch_range(s, key, offset, len)
    Sim(s) => s.get_range(key, @store.ByteRange::{ off: offset, len: len })
  }
}

///|
pub impl @store.ObjectStore for CompactStore with list(self, prefix) {
  match self {
    FS(s) => s.list(prefix)
    S3Async(s) => @s3client.S3Client::list(s, prefix)
    Sim(s) => s.list(prefix)
  }
}

///|
pub impl @store.ObjectStore for CompactStore with delete(self, key) {
  match self {
    FS(s) => s.delete(key)
    S3Async(s) => @s3client.S3Client::delete(s, key)
    Sim(s) => s.delete(key)
  }
}

///|
pub impl @store.ObjectStore for CompactStore with head_version(self, key) {
  match self {
    FS(s) => s.head_version(key)
    S3Async(s) => @s3client.S3Client::head_version(s, key)
    Sim(s) => s.head_version(key)
  }
}

// ---------- metad 镜像层 ----------
//
// 与 cmd/serve 的 AnyStore 同一语义：metadata 小对象（namespace.json /
// manifest / head 指针 / segment meta / centroids / tombstone）在 metad 上
// 是权威副本，compactd 作为写者必须同时更新两边，否则读者（serve）会看到
// 旧的 head。数据大对象（segment.slab、vec/part 等）不经过 metad。

///|
pub struct MdsBackend {
  raw : CompactStore
  meta : @meta.MetadClient?
  prefix : String
}

///|
fn MdsBackend::new(
  raw : CompactStore,
  meta : @meta.MetadClient?,
  prefix : String,
) -> MdsBackend {
  { raw, meta, prefix }
}

///|
fn MdsBackend::key(self : MdsBackend, key : String) -> String {
  self.prefix + key
}

///|
async fn MdsBackend::meta_get(self : MdsBackend, key : String) -> Bytes? {
  match self.meta {
    None => None
    Some(c) =>
      (c.get_kv(self.key(key))) catch {
        _ => None
      }
  }
}

///|
async fn MdsBackend::meta_put(self : MdsBackend, key : String, bs : Bytes) -> Unit {
  match self.meta {
    None => ()
    Some(c) =>
      (c.put_kv(self.key(key), bs)) catch {
        _ => ()
      }
  }
}

///|
async fn MdsBackend::meta_delete(self : MdsBackend, key : String) -> Unit {
  match self.meta {
    None => ()
    Some(c) =>
      (c.delete_kv(self.key(key))) catch {
        _ => ()
      }
  }
}

///|
pub impl @store.ObjectStore for MdsBackend with get(self, key) {
  if !@meta.is_metadata_key(key) {
    return self.raw.get(key)
  }
  match self.meta_get(key) {
    Some(bs) => Some(bs)
    None =>
      match self.raw.get(key) {
        Some(bs) => {
          self.meta_put(key, bs)
          Some(bs)
        }
        None => None
      }
  }
}

///|
pub impl @store.ObjectStore for MdsBackend with put(self, key, bs) {
  self.raw.put(key, bs)
  if @meta.is_metadata_key(key) {
    self.meta_put(key, bs)
  }
}

///|
pub impl @store.ObjectStore for MdsBackend with put_if_match(self, key, expected : @store.Expected, bs) {
  let ok = self.raw.put_if_match(key, expected, bs)
  if ok && @meta.is_metadata_key(key) {
    self.meta_put(key, bs)
  }
  ok
}

///|
pub impl @store.ObjectStore for MdsBackend with get_range(self, key, br : @store.ByteRange) {
  let offset = br.off
  let len = br.len
  if @meta.is_metadata_key(key) {
    match MdsBackend::get(self, key) {
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
    self.raw.get_range(key, @store.ByteRange::{ off: offset, len: len })
  }
}

///|
pub impl @store.ObjectStore for MdsBackend with list(self, prefix) {
  self.raw.list(prefix)
}

///|
pub impl @store.ObjectStore for MdsBackend with delete(self, key) {
  self.raw.delete(key)
  if @meta.is_metadata_key(key) {
    self.meta_delete(key)
  }
}

///|
pub impl @store.ObjectStore for MdsBackend with head_version(self, key) {
  self.raw.head_version(key)
}

///|
/// 构造后端存储（与 cmd/serve 完全同一套环境变量语义）。
pub fn make_store() -> CompactStore raise @core.SpndError {
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
    return S3Async(
      @s3client.S3Client::new(
        endpoint,
        bucket,
        region,
        env_or("AWS_ACCESS_KEY_ID", env_or("S3_ACCESS_KEY", "minioadmin")),
        env_or("AWS_SECRET_ACCESS_KEY", env_or("S3_SECRET_KEY", "minioadmin")),
        max_inflight=env_int("SPND_S3_MAX_INFLIGHT", 32, 1),
      ),
    )
  }
  if spec == "sim" || spec.has_prefix("sim:") {
    return Sim(@simstore.SimStore::new(@simstore.SimConfig::aws_default(42U)))
  }
  raise @core.Corrupt("SPND_STORE must be fs:PATH, s3, or sim, got \{spec}")
}

// ---------- 合并参数 ----------

///|
/// 由 namespace.json 推导合并配置（metric/tokenizer/dim 都不可随意改）。
async fn cfg_for_ns(
  store : MdsBackend,
  ns : String,
) -> @build.BuildConfig {
  let cfg = @build.BuildConfig::single_copy(ns)
  let key = "\{ns}/_meta/namespace.json"
  let bs_opt = store.get(key)
  let meta = match bs_opt {
    Some(bs) => {
      let j = (try {
        Ok(@json.parse(@utf8.decode(bs.exact_view())))
      } catch {
        _ => Err(())
      })
      match j {
        Err(_) => None
        Ok(json) =>
          try {
            Some(@format.namespace_from_json(json))
          } catch {
            _ => None
          }
      }
    }
    None => None
  }
  match meta {
    None => cfg
    Some(m) => {
      let tok = match m.fts_tokenizer {
        Some(s) =>
          match @core.parse_tokenizer(s) {
            Some(t) => t
            None => @core.Word
          }
        None => @core.Word
      }
      let metric = if m.distance_metric == "" {
        "cosine"
      } else {
        m.distance_metric
      }
      {
        ..cfg,
        vector_dim: m.vector_dim,
        fts_tokenizer: tok,
        distance_metric: metric,
        normalize_vecs: metric != "euclidean",
      }
    }
  }
}

///|
/// 一个 namespace 的合并（CommitConflict 最多重试 3 次，指数退避）。
/// 返回 true 表示合并发布成功（或本来就无需合并）。
async fn compact_one(
  store : MdsBackend,
  ns : String,
  holder : String,
  meta : @meta.MetadClient,
  max_prefix : Int,
) -> Bool {
  let mut attempt = 0
  while attempt < 3 {
    attempt += 1
    let cfg = cfg_for_ns(store, ns) catch {
      e => {
        println("[compactd] ns=\{ns} cfg failed: \{err_msg(e)}")
        return false
      }
    }
    let res = try {
      Ok(@build.compact_optimistic(store, cfg, max_prefix_segments=max_prefix))
    } catch {
      e => Err(e)
    }
    match res {
      Ok(head) =>
        match head {
          Some(h) => {
            println("[compactd] ns=\{ns} compacted -> \{h} (attempt \{attempt})")
            return true
          }
          None => {
            // 无需合并（段数 <= 1 且无 tombstone，或 CAS 连续冲突）
            println("[compactd] ns=\{ns} nothing to compact")
            return true
          }
        }
      Err(e) => {
        let retryable = match e {
          @core.CommitConflict(_) => true
          _ => false
        }
        if retryable && attempt < 3 {
          println("[compactd] ns=\{ns} commit conflict, retrying (\{err_msg(e)})")
          @async.sleep(attempt * 20)
        } else {
          println("[compactd] ns=\{ns} compact failed: \{err_msg(e)}")
          return false
        }
      }
    }
  }
  let _ = (holder, meta)
  false
}

///|
/// 领一轮脏队列并合并（返回本轮是否真的处理了一个 namespace）。
async fn drain_once(
  store : MdsBackend,
  meta : @meta.MetadClient,
  holder : String,
  ttl_ms : Int,
  max_prefix : Int,
) -> Bool {
  let claimed = (meta.claim_dirty(holder, ttl_ms)) catch {
    e => {
      println("[compactd] claim failed: \{err_msg(e)}")
      return false
    }
  }
  match claimed {
    @meta.ClaimResult::Empty => false
    @meta.ClaimResult::Claimed(ns, _epoch) => {
      let _ = compact_one(store, ns, holder, meta, max_prefix)
      // 无论成败都释放租约：失败时让别的 compactor 尽快重试，而不是等 TTL 过期。
      let released = (meta.release_lease("compact:\{ns}", holder)) catch {
        e => {
          println("[compactd] release lease failed ns=\{ns}: \{err_msg(e)}")
          true
        }
      }
      let _ = released
      true
    }
  }
}

///|
async fn main {
  let meta_url = env_or("SPND_META_URL", "")
  if meta_url == "" {
    println(
      "compactd: SPND_META_URL is required (e.g. http://127.0.0.1:8090); exiting",
    )
    return
  }
  let holder = env_or(
    "SPND_COMPACD_HOLDER",
    "compactd-\{@env.now()}-\{env_int("SPND_COMPACD_SEQ", 0, 0)}",
  )
  let ttl_ms = env_int("SPND_COMPACT_LEASE_TTL_MS", 30000, 1000)
  let idle_ms = env_int("SPND_COMPACT_IDLE_MS", 200, 1)
  let max_prefix = env_int("SPND_COMPACT_PREFIX_SEGS", 8, 1)
  let raw = make_store() catch {
    e => {
      println("compactd: store init failed: \{err_msg(e)}")
      return
    }
  }
  let meta = @meta.MetadClient::new(meta_url, max_inflight=4)
  let store = MdsBackend::new(raw, Some(meta), env_or("SPND_META_PREFIX", ""))
  let oneshot = env_or("SPND_COMPACD_ONESHOT", "0") == "1"
  println(
    "compactd holder=\{holder} metad=\{meta_url} ttl=\{ttl_ms}ms oneshot=\{oneshot}",
  )
  if oneshot {
    // 冒烟/单测用：把当前脏队列跑干后退出（不做常驻轮询）。
    let mut processed = 0
    for _ in 0..<64 {
      if drain_once(store, meta, holder, ttl_ms, max_prefix) {
        processed += 1
      } else {
        break
      }
    }
    println("compactd oneshot done: processed=\{processed}")
    return
  }
  for ;; {
    let did_work = drain_once(store, meta, holder, ttl_ms, max_prefix)
    if !did_work {
      @async.sleep(idle_ms)
    }
  }
}

// 便捷方法转发：`store.get(...)` 直接可用。
pub extend CompactStore with @store.ObjectStore::{
  get,
  put,
  put_if_match,
  get_range,
  list,
  delete,
  head_version,
}

// 便捷方法转发。
pub extend MdsBackend with @store.ObjectStore::{
  get,
  get_range,
  put,
  put_if_match,
  list,
  delete,
  head_version,
}
