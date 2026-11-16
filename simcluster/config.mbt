// simcluster 配置：CPU 算子成本画像 + 集群拓扑 + 负载规格。
//
// 所有时间单位：配置里 CPU 画像用 ns/µs（实测口径，见 cmd/calibrate），
// 仿真内部统一换算成微秒的虚拟时钟。

///|
/// CPU 算子成本画像。由 `cmd/calibrate` 用 @bench 单调时钟实测后写入 JSON，
/// 也可以手工给一组保守值跑敏感性分析。
pub(all) struct CpuProfile {
  vec_dot_ns_per_dim : Double // dot_f32 / l2sq_f32：每维纳秒
  bm25_posting_ns : Double // 每篇扫描文档的 postings 遍历
  slab_decode_ns_per_kb : Double // Slab 解码（含 index + 组件切片）每 KB
  ingest_doc_us : Double // 摄取一篇文档（编码 + 追加）
  compact_doc_us : Double // 压缩合并一篇文档（读 + 合并 + 重编码）
}

///|
/// 保守默认值（一台普通 x86/ARM 云主机上的数量级），仅用于没有校准文件的场景。
pub fn CpuProfile::default_profile() -> CpuProfile {
  {
    vec_dot_ns_per_dim: 2.0,
    bm25_posting_ns: 20.0,
    slab_decode_ns_per_kb: 200.0,
    ingest_doc_us: 40.0,
    compact_doc_us: 300.0,
  }
}

///|
/// CPU 画像 → JSON（cmd/calibrate 落盘/打印用；字段顺序固定）。
pub fn CpuProfile::to_json_string(self : CpuProfile) -> String {
  let b = StringBuilder()
  b.write_string("{\n")
  b.write_string(
    "  \"vec_dot_ns_per_dim\": " + fmt_fixed(self.vec_dot_ns_per_dim, 4) + ",\n",
  )
  b.write_string(
    "  \"bm25_posting_ns\": " + fmt_fixed(self.bm25_posting_ns, 4) + ",\n",
  )
  b.write_string(
    "  \"slab_decode_ns_per_kb\": " +
    fmt_fixed(self.slab_decode_ns_per_kb, 4) +
    ",\n",
  )
  b.write_string(
    "  \"ingest_doc_us\": " + fmt_fixed(self.ingest_doc_us, 4) + ",\n",
  )
  b.write_string(
    "  \"compact_doc_us\": " + fmt_fixed(self.compact_doc_us, 4) + "\n",
  )
  b.write_string("}\n")
  b.to_string()
}

///|
/// 集群拓扑与 IO 模型。老架构 = 1 进程 + 同步 IO + 无组提交 + 无 compactd；
/// 新架构 = N 进程 + 异步 IO + 组提交 + 独立 compactd。
pub(all) struct ClusterSimConfig {
  serve_processes : Int // 查询/摄取进程数（每个独占 1 vCPU）
  ram_cache_mb_per_proc : Double // 每进程 RAM 缓存（影响 cache_hit_ratio 的上限口径，仅报告）
  s3_slots_per_proc : Int // 每进程可同时在飞行的 S3 请求数
  dedicated_compactd : Bool // true：压缩在独立进程时间线（不阻塞 serve CPU）
  async_io : Bool // true：S3 等待只占 slot，CPU 可插入热查询；false：S3 等待霸占 CPU
  group_commit_window_us : Double // >0：该窗口内的写合并成一次 3-PUT Slab；0 = 每写一次 PUT
  cpu : CpuProfile
  s3_get_ttfb_p50_us : Double
  s3_put_ttfb_p50_us : Double
  s3_ttfb_sigma : Double // 对数正态形状参数（GET/PUT 共用）
  s3_bw_mbps : Double // 单流带宽（bytes/mbps = 微秒）
  rates : @simstore.BillRates
  vcpu_price_per_hour : Double
}

///|
/// 新架构默认参数（4 进程 / 异步 IO / 25ms 组提交 / 独立 compactd）。
pub fn ClusterSimConfig::modern(rates : @simstore.BillRates) -> ClusterSimConfig {
  {
    serve_processes: 4,
    ram_cache_mb_per_proc: 2048.0,
    s3_slots_per_proc: 16,
    dedicated_compactd: true,
    async_io: true,
    group_commit_window_us: 25000.0,
    cpu: CpuProfile::default_profile(),
    s3_get_ttfb_p50_us: 30000.0,
    s3_put_ttfb_p50_us: 60000.0,
    s3_ttfb_sigma: 0.47,
    s3_bw_mbps: 100.0,
    rates,
    vcpu_price_per_hour: 0.0416,
  }
}

///|
/// 老架构：单进程、同步 IO（S3 等待霸占 CPU）、每次写一次 PUT、压缩跑在 serve 进程上。
pub fn ClusterSimConfig::legacy(rates : @simstore.BillRates) -> ClusterSimConfig {
  let base = ClusterSimConfig::modern(rates)
  {
    ..base,
    serve_processes: 1,
    s3_slots_per_proc: 1,
    dedicated_compactd: false,
    async_io: false,
    group_commit_window_us: 0.0,
  }
}

///|
/// 混合读写负载规格。
pub(all) struct WorkloadSpec {
  duration_sec : Double
  query_qps : Double // offered 查询速率（开环：不因拥塞降速，超时算 dropped）
  write_rps : Double
  rows_per_write : Int
  total_docs : Int
  dim : Int
  nprobe : Int // 每次查询探测的 IVF 聚类数
  num_tenants : Int // 分区数（扫描量 = total_docs * SCAN_FRACTION / num_tenants）
  cache_hit_ratio : Double // 期望命中 RAM/NVMe 的比例（会被 ram_cache_mb_per_proc 容量上限打折）
  l0_delta_count : Int // 攒够多少个 L0 delta 触发一次压缩（<=0 表示不压缩）
}

///|
/// 默认混合负载：30s、400 qps 读 + 20 rps 写、100 万文档、128 维、4 租户。
pub fn WorkloadSpec::kv_mixed() -> WorkloadSpec {
  {
    duration_sec: 30.0,
    query_qps: 400.0,
    write_rps: 20.0,
    rows_per_write: 10,
    total_docs: 1000000,
    dim: 128,
    nprobe: 8,
    num_tenants: 4,
    cache_hit_ratio: 0.7,
    l0_delta_count: 6,
  }
}

///|
/// 只读、全部命中缓存的纯 CPU 负载（吞吐线性扩展测试用）。
pub fn WorkloadSpec::cpu_bound_reads(
  duration_sec : Double,
  qps : Double,
  total_docs : Int,
) -> WorkloadSpec {
  {
    ..WorkloadSpec::kv_mixed(),
    duration_sec,
    query_qps: qps,
    write_rps: 0.0,
    total_docs,
    cache_hit_ratio: 1.0,
  }
}

///|
/// 写密集负载（组提交计费对比用）。
pub fn WorkloadSpec::write_heavy(
  duration_sec : Double,
  write_rps : Double,
  rows_per_write : Int,
) -> WorkloadSpec {
  {
    ..WorkloadSpec::kv_mixed(),
    duration_sec,
    query_qps: 0.0,
    write_rps,
    rows_per_write,
    l0_delta_count: 8,
  }
}
