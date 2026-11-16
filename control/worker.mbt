// control/worker.mbt：无状态查询 Worker 抽象与带 TTL（默认 5 分钟）的热分级缓存。
//
// 3-Tier 云原生架构 Worker 层：
// - 不定数量的 Worker，由 Coordinator 管理节点调度；
// - 每个 Worker 维护带 TTL（默认 5 分钟 / 300_000ms）的热缓存池与严格内存预算（LRU）；
// - 缓存命中时：0 次 S3 请求，亚毫秒计算；
// - 缓存未命中或过期：从底层 S3 拉取分区并写入热缓存。

///|
pub struct WorkerCacheEntry {
  part : @format.GlobalVecPart
  created_at_ms : UInt64
  mut last_accessed_ms : UInt64
  byte_size : Int
}

///|
pub struct WorkerTieredCache {
  ttl_ms : UInt64
  max_bytes : Int
  entries : Map[String, WorkerCacheEntry]
  mut current_bytes : Int
  mut hits : Int
  mut misses : Int
  mut evictions : Int
  mut expirations : Int
}

///|
/// 创建 Worker 热缓存，默认 5 分钟过期（300,000ms），内存预算 64MB。
pub fn WorkerTieredCache::new(
  ttl_ms? : UInt64,
  max_bytes? : Int,
) -> WorkerTieredCache {
  {
    ttl_ms: match ttl_ms { Some(t) => t; None => 300_000UL },
    max_bytes: match max_bytes { Some(b) => b; None => 67_108_864 }, // 64 MB
    entries: Map([]),
    current_bytes: 0,
    hits: 0,
    misses: 0,
    evictions: 0,
    expirations: 0,
  }
}

///|
pub fn WorkerTieredCache::get(
  self : WorkerTieredCache,
  key : String,
) -> @format.GlobalVecPart? {
  let now = @env.now()
  match self.entries.get(key) {
    Some(e) =>
      if now - e.created_at_ms >= self.ttl_ms {
        // 过期淘汰
        self.entries.remove(key)
        self.current_bytes -= e.byte_size
        self.expirations += 1
        self.misses += 1
        None
      } else {
        e.last_accessed_ms = now
        self.hits += 1
        Some(e.part)
      }
    None => {
      self.misses += 1
      None
    }
  }
}

///|
pub fn WorkerTieredCache::put(
  self : WorkerTieredCache,
  key : String,
  part : @format.GlobalVecPart,
) -> Unit {
  let now = @env.now()
  let part_size = part.rows.length() * 8 + part.data.length() * 2 + 128
  // 1. 先淘汰已过期的条目
  self.evict_expired(now)
  // 2. 超出内存预算时，按 LRU 淘汰最旧未访问项
  while self.current_bytes + part_size > self.max_bytes && !(self.entries.is_empty()) {
    let mut victim_key : String? = None
    let mut victim_time : UInt64 = 0UL
    let mut victim_size = 0
    for kv in self.entries.iter() {
      let (k, e) = kv
      match victim_key {
        None => {
          victim_key = Some(k)
          victim_time = e.last_accessed_ms
          victim_size = e.byte_size
        }
        Some(_) =>
          if e.last_accessed_ms < victim_time {
            victim_key = Some(k)
            victim_time = e.last_accessed_ms
            victim_size = e.byte_size
          }
      }
    }
    match victim_key {
      Some(k) => {
        self.entries.remove(k)
        self.current_bytes -= victim_size
        self.evictions += 1
      }
      None => break
    }
  }
  self.entries.set(key, {
    part,
    created_at_ms: now,
    last_accessed_ms: now,
    byte_size: part_size,
  })
  self.current_bytes += part_size
}

///|
fn WorkerTieredCache::evict_expired(
  self : WorkerTieredCache,
  now : UInt64,
) -> Unit {
  let expired_keys : Array[(String, Int)] = []
  for kv in self.entries.iter() {
    let (k, e) = kv
    if now - e.created_at_ms >= self.ttl_ms {
      expired_keys.push((k, e.byte_size))
    }
  }
  for item in expired_keys {
    let (k, sz) = item
    self.entries.remove(k)
    self.current_bytes -= sz
    self.expirations += 1
  }
}

///|
pub fn WorkerTieredCache::stats(
  self : WorkerTieredCache,
) -> (Int, Int, Int, Int, Int) {
  (self.hits, self.misses, self.evictions, self.expirations, self.current_bytes)
}

///|
/// 查询 Worker 抽象：每个 Worker 具备独立缓存池与租户执行管道。
pub struct QueryWorker[S] {
  id : String
  store : S
  cache : WorkerTieredCache
}

///|
pub fn[S] QueryWorker::new(
  id : String,
  store : S,
  cache_ttl_ms? : UInt64,
  max_cache_bytes? : Int,
) -> QueryWorker[S] {
  {
    id,
    store,
    cache: WorkerTieredCache::new(ttl_ms?=cache_ttl_ms, max_bytes?=max_cache_bytes),
  }
}

///|
/// Worker 执行单次向量查询请求（结合 5 分钟热缓存）。
pub async fn[S : @store.ObjectStore] QueryWorker::execute_vector_query(
  self : QueryWorker[S],
  n : @query.Namespace[S],
  qv : Array[Float],
  top_k : Int,
  nprobe : Int,
  filter : @query.Filter?,
) -> Array[@query.QueryResult] {
  let ver = match n.manifest.vec_global_version {
    Some(v) => v
    None =>
      match n.meta.vec_global_version {
        Some(v) => v
        None => return @query.vec_search(n, qv, top_k, nprobe, filter)
      }
  }
  // 检查当前分区是否已在 Worker 5 分钟缓存中；若已在，注入 n.global_parts
  let prefix = "\{ver}/"
  for kv in self.cache.entries.iter() {
    let (ckey, _) = kv
    if ckey.has_prefix(prefix) {
      match self.cache.get(ckey) {
        Some(p) => n.global_parts.set(ckey, p)
        None => ()
      }
    }
  }
  let res = @query.vec_search(n, qv, top_k, nprobe, filter)
  // 将执行过程中载入 n.global_parts 的新分区写回 Worker 5 分钟热缓存
  for kv in n.global_parts.iter() {
    let (k, p) = kv
    if self.cache.entries.get(k) is None {
      self.cache.put(k, p)
    }
  }
  res
}

///|
/// Worker 执行单次 BM25 全文检索。
pub async fn[S : @store.ObjectStore] QueryWorker::execute_bm25_query(
  self : QueryWorker[S],
  n : @query.Namespace[S],
  text : String,
  top_k : Int,
  filter : @query.Filter?,
) -> Array[@query.QueryResult] {
  let _ = self
  @query.bm25_search(n, text, top_k, filter)
}

///|
/// Worker 执行单次混合检索请求（结合 5 分钟向量热缓存）。
pub async fn[S : @store.ObjectStore] QueryWorker::execute_hybrid_query(
  self : QueryWorker[S],
  n : @query.Namespace[S],
  text : String,
  qv : Array[Float],
  top_k : Int,
  nprobe : Int,
  filter : @query.Filter?,
  opts : @query.HybridOpts?,
) -> Array[@query.QueryResult] {
  let ver_opt = match n.manifest.vec_global_version {
    Some(v) => Some(v)
    None => n.meta.vec_global_version
  }
  match ver_opt {
    Some(ver) => {
      let prefix = "\{ver}/"
      for kv in self.cache.entries.iter() {
        let (ckey, _) = kv
        if ckey.has_prefix(prefix) {
          match self.cache.get(ckey) {
            Some(p) => n.global_parts.set(ckey, p)
            None => ()
          }
        }
      }
    }
    None => ()
  }
  let res = match opts {
    Some(o) => @query.hybrid_search_opts(n, text, qv, top_k, nprobe, filter, o)
    None => @query.hybrid_search(n, text, qv, top_k, nprobe, filter)
  }
  for kv in n.global_parts.iter() {
    let (k, p) = kv
    if self.cache.entries.get(k) is None {
      self.cache.put(k, p)
    }
  }
  res
}
