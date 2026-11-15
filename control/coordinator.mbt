// control/coordinator.mbt：元数据与管理节点（Coordinator / Master）抽象。
//
// 职责：
// - 负责租户（Tenant / Namespace）元数据、active manifest 仲裁与状态注册；
// - 管理 Worker 池生命周期（创建、调度、负载分发）；
// - 与底层的物理存储（S3）解耦，保证未来分布式部署时 Coordinator 与 Worker 可以跨节点拆分。

///|
pub struct TenantMetadata {
  tenant_id : String
  mut head_manifest_id : String
  vector_dim : Int
  distance_metric : String
  fts_tokenizer : String
  mut num_docs : Int
  mut updated_at_ms : UInt64
}

///|
pub struct Coordinator[S] {
  store : S
  tenants : Map[String, TenantMetadata]
  workers : Array[QueryWorker[S]]
  next_worker_idx : Int
}

///|
pub fn[S] Coordinator::new(
  store : S,
  worker_count? : Int,
  worker_cache_ttl_ms? : UInt64,
  worker_max_bytes? : Int,
) -> Coordinator[S] {
  let count = match worker_count {
    Some(c) => if c < 1 { 1 } else { c }
    None => 2
  }
  let workers : Array[QueryWorker[S]] = []
  for i in 0..<count {
    workers.push(
      QueryWorker::new(
        "worker-\{i}",
        store,
        cache_ttl_ms?=worker_cache_ttl_ms,
        max_cache_bytes?=worker_max_bytes,
      ),
    )
  }
  {
    store,
    tenants: Map([]),
    workers,
    next_worker_idx: 0,
  }
}

///|
pub fn[S] Coordinator::register_tenant(
  self : Coordinator[S],
  tenant_id : String,
  head_manifest_id : String,
  vector_dim : Int,
  distance_metric : String,
  fts_tokenizer : String,
  num_docs : Int,
) -> Unit {
  let now = @env.now()
  self.tenants.set(tenant_id, {
    tenant_id,
    head_manifest_id,
    vector_dim,
    distance_metric,
    fts_tokenizer,
    num_docs,
    updated_at_ms: now,
  })
}

///|
pub fn[S] Coordinator::update_tenant_head(
  self : Coordinator[S],
  tenant_id : String,
  new_head : String,
  num_docs : Int,
) -> Unit {
  match self.tenants.get(tenant_id) {
    Some(t) => {
      t.head_manifest_id = new_head
      t.num_docs = num_docs
      t.updated_at_ms = @env.now()
    }
    None => ()
  }
}

///|
pub fn[S] Coordinator::get_tenant(
  self : Coordinator[S],
  tenant_id : String,
) -> TenantMetadata? {
  self.tenants.get(tenant_id)
}

///|
/// 选择一个 Worker（租户一致性哈希或轮询）。
pub fn[S] Coordinator::select_worker(
  self : Coordinator[S],
  tenant_id : String,
) -> QueryWorker[S] {
  if self.workers.is_empty() {
    QueryWorker::new("default", self.store)
  } else {
    // 简单租户哈希选择，保证同一租户优先命中同一 Worker 的 5 分钟热缓存
    let mut h = 0
    for c in tenant_id.to_array() {
      h = h * 31 + c.to_int()
    }
    let idx = (h & 0x7fffffff) % self.workers.length()
    self.workers[idx]
  }
}

///|
/// 调度向量查询任务至 Worker 执行。
pub fn[S : @store.ObjectStore] Coordinator::dispatch_vector_query(
  self : Coordinator[S],
  tenant_id : String,
  n : @query.Namespace[S],
  qv : Array[Float],
  top_k : Int,
  nprobe : Int,
  filter : @query.Filter?,
) -> Array[@query.QueryResult] raise @core.SpndError {
  let worker = self.select_worker(tenant_id)
  worker.execute_vector_query(n, qv, top_k, nprobe, filter)
}

///|
/// 调度 BM25 全文检索任务至 Worker 执行。
pub fn[S : @store.ObjectStore] Coordinator::dispatch_bm25_query(
  self : Coordinator[S],
  tenant_id : String,
  n : @query.Namespace[S],
  text : String,
  top_k : Int,
  filter : @query.Filter?,
) -> Array[@query.QueryResult] raise @core.SpndError {
  let worker = self.select_worker(tenant_id)
  worker.execute_bm25_query(n, text, top_k, filter)
}

///|
/// 调度混合检索任务至 Worker 执行。
pub fn[S : @store.ObjectStore] Coordinator::dispatch_hybrid_query(
  self : Coordinator[S],
  tenant_id : String,
  n : @query.Namespace[S],
  text : String,
  qv : Array[Float],
  top_k : Int,
  nprobe : Int,
  filter : @query.Filter?,
  opts : @query.HybridOpts?,
) -> Array[@query.QueryResult] raise @core.SpndError {
  let worker = self.select_worker(tenant_id)
  worker.execute_hybrid_query(n, text, qv, top_k, nprobe, filter, opts)
}
