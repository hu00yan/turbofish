// cmd/main SimStore 场景（NOTES2.md 第 5 节 bench 集成契约，工人 B）。
//
// 数据由 main 生成一次；这里对 SimStore 再 ingest 一次（train_centroids 种子
// 固定 42，两次 ingest 训出的中心一致；再训一次慢几分钟属预期），并复制
// MemStore 的 tombstone（gate 4 已在 MemStore 删 20 ids——两 store 逻辑内容
// 一致，sanity 比对才有意义）。
//
// 流程：
// a. SimStore ingest + tombstone 复制
// b. 正确性 sanity：SimStore 上跑全部 BM25 gate 查询 + 第一个向量 gate 查询
//    （nprobe=8），与 MemStore 同查询的结果 id 列表逐一比对，一致才继续
// c. 场景：三类查询（bm25/vec/hybrid）× cold-data(warm-meta) / all-hot，每类 20 查询：
//    - cold-data(warm-meta)：cold() 清 NVMe（元数据 resident 不清）→ 每查询 open+search
//      total_latency_us / bill_requests_total / s3_gets / bytes_s3_read 增量
//    - all-hot：admit_all() 全量预热（合成上界，不是 workload 可达 warm）→ open 一次 → reset_cost →
//      复用 namespace 仅 search，同样记增量
//    每场景输出一行：延迟 p50/p99（ms，增量排序取分位）+ $/1M 查询 +
//    S3 GET 次/查询 + S3 读 KB/查询
// d. 结尾：月存储费 + 总字节 + 对象数 + turbopuffer $1/PB 参照对照
//    （@simstore.tpu_scan_bill：$1/PB，单查询最低 1.28GB → 最低 $1.28/1M）
//    vs 实际请求费 $/1M
//
// SimStore 已实装三档延迟 + AWS 精确计费；内存/NVMe 命中不计 GET 费。

///|
/// trait 方法跨包点调用可能不解析，走本地泛型分发（同 query 包 wbtest 的做法）。
fn[S : @store.ObjectStore] sim_store_list(
  s : S,
  prefix : String,
) -> Array[String] {
  s.list(prefix)
}

///|
/// SimStore 当前对象数（结尾汇总用；在全部测量之后调用，不污染计量）。
fn[S : @store.ObjectStore] sim_object_count(s : S) -> Int {
  sim_store_list(s, "").length()
}

///|
/// Double 数组均值（空数组返回 0）。
fn avg_d(arr : Array[Double]) -> Double {
  let mut s = 0.0
  for v in arr {
    s += v
  }
  if arr.is_empty() {
    0.0
  } else {
    s / arr.length().to_double()
  }
}

///|
/// 左对齐补空格（对照表列对齐用）。
fn sim_pad(s : String, w : Int) -> String {
  let mut out = s
  while out.length() < w {
    out = out + " "
  }
  out
}

///|
/// 执行第 i 条 SimStore 查询（vec/hybrid 用 nprobe=8，与 MemStore 成本口径一致）。
fn[S : @store.ObjectStore] sim_one_query(
  kind : CostKind,
  n : @query.Namespace[S],
  i : Int,
  bm25_qs : Array[String],
  vec_qvs : Array[Array[Float]],
) -> Array[@query.QueryResult] raise @core.SpndError {
  match kind {
    KindBm25 => @query.bm25_search(n, bm25_qs[i], 10, None)
    KindVec => @query.vec_search(n, vec_qvs[i], 10, 8, None)
    KindHybrid => @query.hybrid_search(n, bm25_qs[i], vec_qvs[i], 10, 8, None)
  }
}

///|
/// 单个（查询类 × 场景）的汇总，供结尾 turbopuffer 参照对照表使用。
struct SimMeasure {
  label : String // 如 "bm25 cold" / "compact bm25 cold"
  avg_s3_bytes : Double // 每查询 S3 读字节均值
  avg_gets : Double // 每查询 S3 GET 数
  bill_per_1m : Double // 实际请求费 $/1M 查询（= 20 查询计费增量合计 × 1e6/20）
}

///|
/// 汇总一个场景的每查询增量：延迟排序取 p50/p99（ms）并输出一行，
/// 返回该场景的对照表条目。
fn sim_summarize(
  tag : String,
  kind_label : String,
  scene : String,
  lat : Array[Double],
  bill : Array[Double],
  gets : Array[Int],
  s3bytes : Array[Int],
) -> SimMeasure {
  let sorted = lat.copy()
  sorted.sort()
  let m : SimMeasure = {
    label: "\{tag}\{kind_label} \{scene}",
    avg_s3_bytes: avg_i(s3bytes),
    avg_gets: avg_i(gets),
    bill_per_1m: avg_d(bill) * 1.0e6,
  }
  println(
    "[\{kind_label} sim-\{scene}] p50=\{pct(sorted, 0.5) / 1000.0}ms p99=\{pct(sorted, 0.99) / 1000.0}ms | $\{m.bill_per_1m}/1M 查询 | S3 GET/查询=\{avg_i(gets)} | S3 KB/查询=\{m.avg_s3_bytes / 1024.0}",
  )
  m
}

///|
/// 单类查询的两场景测量（每类 20 查询，与 MemStore 成本口径一致）：
/// cold-data(warm-meta) = cold+reset 后每查询 open+search；all-hot = admit_all
/// 全量预热后 open 一次再 reset、复用 namespace 仅 search。返回（cold, all-hot）汇总。
fn sim_measure(
  store_sim : @simstore.SimStore,
  ns : String,
  kind : CostKind,
  bm25_qs : Array[String],
  vec_qvs : Array[Array[Float]],
  tag : String,
) -> (SimMeasure, SimMeasure) raise @core.SpndError {
  let nq = bm25_qs.length()
  let kind_label = match kind {
    KindBm25 => "bm25"
    KindVec => "vec"
    KindHybrid => "hybrid"
  }
  // ---- cold-data(warm-meta)：cold() 清 NVMe 与已读区间（内存常驻档不动）→ 每查询 open+search
  store_sim.cold()
  store_sim.reset_cost()
  let clat : Array[Double] = Array::new()
  let cbill : Array[Double] = Array::new()
  let cgets : Array[Int] = Array::new()
  let cbytes : Array[Int] = Array::new()
  let mut prev_lat = 0.0
  let mut prev_bill = 0.0
  let mut prev_gets = 0
  let mut prev_bytes : Int64 = 0L
  for i in 0..<nq {
    let n = @query.open(store_sim, ns)
    let _ = sim_one_query(kind, n, i, bm25_qs, vec_qvs)
    let c = store_sim.cost()
    clat.push(c.total_latency_us - prev_lat)
    cbill.push(c.bill_requests_total - prev_bill)
    cgets.push(c.s3_gets - prev_gets)
    cbytes.push((c.bytes_s3_read - prev_bytes).to_int())
    prev_lat = c.total_latency_us
    prev_bill = c.bill_requests_total
    prev_gets = c.s3_gets
    prev_bytes = c.bytes_s3_read
  }
  let cold_m = sim_summarize(
    tag, kind_label, "cold-data(warm-meta)", clat, cbill, cgets, cbytes,
  )
  // ---- all-hot：admit_all 全量进 NVMe（合成上界，不是真实 warm）→ open 一次 →
  // reset_cost → 复用 namespace 仅 search
  store_sim.admit_all()
  let nw = @query.open(store_sim, ns)
  store_sim.reset_cost()
  let wlat : Array[Double] = Array::new()
  let wbill : Array[Double] = Array::new()
  let wgetc : Array[Int] = Array::new()
  let wbytes : Array[Int] = Array::new()
  prev_lat = 0.0
  prev_bill = 0.0
  prev_gets = 0
  prev_bytes = 0
  for i in 0..<nq {
    let _ = sim_one_query(kind, nw, i, bm25_qs, vec_qvs)
    let c = store_sim.cost()
    wlat.push(c.total_latency_us - prev_lat)
    wbill.push(c.bill_requests_total - prev_bill)
    wgetc.push(c.s3_gets - prev_gets)
    wbytes.push((c.bytes_s3_read - prev_bytes).to_int())
    prev_lat = c.total_latency_us
    prev_bill = c.bill_requests_total
    prev_gets = c.s3_gets
    prev_bytes = c.bytes_s3_read
  }
  let warm_m = sim_summarize(
    tag, kind_label, "all-hot", wlat, wbill, wgetc, wbytes,
  )
  (cold_m, warm_m)
}

///|
/// SimStore 场景主入口（NOTES2.md 第 5 节）。MemStore 流程保持原样不动；
/// 这里对 SimStore 独立 ingest 一次后做 sanity + 两场景测量 + 对照表。
fn run_sim(
  store_mem : @store.MemStore,
  store_sim : @simstore.SimStore,
  ns : String,
  docs : Array[@core.Doc],
  bm25_gate_qs : Array[String],
  vec_gate_qvs : Array[Array[Float]],
  bm25_cost_qs : Array[String],
  vec_cost_qvs : Array[Array[Float]],
) -> Unit raise @core.SpndError {
  // 性能结论前提：延迟注入必须开启；零延迟只允许用于正确性测试。
  store_sim.require_latency()
  // ---- a. SimStore ingest（train_centroids 种子固定，两次 ingest 中心一致）
  let sim_build_cfg = @build.BuildConfig::default(ns)
  println(
    "== SimStore 场景：ingest（会再训一次 centroids，慢几分钟属预期）...",
  )
  @build.ingest(store_sim, sim_build_cfg, docs)
  // 复制 MemStore 的 tombstone（gate 4 已删 20 ids；两 store 逻辑内容一致）
  let n_mem = @query.open(store_mem, ns)
  let deleted = n_mem.manifest.deleted
  if deleted.length() > 0 {
    @build.delete_docs(store_sim, sim_build_cfg, deleted)
  }
  println(
    "  ingest 完成: bytes=\{store_sim.total_object_bytes()} objects=\{sim_object_count(store_sim)} tombstone=\{deleted.length()} ids（复制自 MemStore）",
  )
  // ---- b. 正确性 sanity：SimStore 与 MemStore 同查询结果 id 列表逐一比对
  println(
    "== sanity: SimStore vs MemStore（\{bm25_gate_qs.length()} 个 BM25 gate 查询 + 1 个向量 gate 查询 nprobe=8）==",
  )
  let n_sim = @query.open(store_sim, ns)
  let mut mism = 0
  for i in 0..<bm25_gate_qs.length() {
    let got = sorted_ids_of(
      @query.bm25_search(n_sim, bm25_gate_qs[i], 10, None),
    )
    let want = sorted_ids_of(
      @query.bm25_search(n_mem, bm25_gate_qs[i], 10, None),
    )
    if got != want {
      mism += 1
      println(
        "  FAIL q\{i} [\{bm25_gate_qs[i]}]: sim=[\{show_ids(got)}] mem=[\{show_ids(want)}]",
      )
    }
  }
  let gv = sorted_ids_of(@query.vec_search(n_sim, vec_gate_qvs[0], 10, 8, None))
  let wv = sorted_ids_of(@query.vec_search(n_mem, vec_gate_qvs[0], 10, 8, None))
  if gv != wv {
    mism += 1
    println(
      "  FAIL vec[0] nprobe=8: sim=[\{show_ids(gv)}] mem=[\{show_ids(wv)}]",
    )
  }
  if mism > 0 {
    println(
      "FAIL: SimStore 与 MemStore 结果不一致（\{mism} 处），跳过 SimStore 场景",
    )
    return
  }
  println("  sanity 全部一致，继续场景测量")
  // ---- c. 三类查询 × 两场景（每类 20 查询）
  println(
    "== SimStore 场景表（延迟 = 模拟器虚拟时钟累计；计费 = 真正打到 S3 的请求）==",
  )
  let measures : Array[SimMeasure] = Array::new()
  let kinds : Array[CostKind] = [KindBm25, KindVec, KindHybrid]
  for kind in kinds {
    let (m_cold, m_warm) = sim_measure(
      store_sim, ns, kind, bm25_cost_qs, vec_cost_qvs, "",
    )
    measures.push(m_cold)
    measures.push(m_warm)
  }
  // ---- d. compact 收益：合并 5 段 → 1 段后重跑同一批场景
  let n_before = @query.open(store_sim, ns)
  let segs_before = n_before.manifest.segments.length()
  let docs_before = n_before.manifest.num_docs
  println(
    "== compact：合并 \{segs_before} 段 → 1 段（tombstone 物理化）...",
  )
  @build.compact(store_sim, sim_build_cfg, ns)
  let n_after = @query.open(store_sim, ns)
  println(
    "  compact 后 segments=\{n_after.manifest.segments.length()} num_docs=\{n_after.manifest.num_docs}（before \{docs_before}）",
  )
  let measures2 : Array[SimMeasure] = Array::new()
  for kind in kinds {
    let (m_cold, m_warm) = sim_measure(
      store_sim, ns, kind, bm25_cost_qs, vec_cost_qvs, "compact ",
    )
    measures2.push(m_cold)
    measures2.push(m_warm)
  }
  println(
    "== compact 前后对照（每类冷/温；GET/查询、KB/查询、$/1M 查询）==",
  )
  println(
    "  \{sim_pad("scenario", 20)}\{sim_pad("GET/q before→after", 22)}\{sim_pad("KB/q before→after", 22)}\{sim_pad("$/1M before→after", 24)}",
  )
  for i in 0..<measures.length() {
    let a = measures[i]
    let b = measures2[i]
    println(
      "  \{sim_pad(a.label, 20)}\{sim_pad("\{r2_fmt(a.avg_gets, 1)}→\{r2_fmt(b.avg_gets, 1)}", 22)}\{sim_pad("\{r2_fmt(a.avg_s3_bytes / 1024.0, 1)}→\{r2_fmt(b.avg_s3_bytes / 1024.0, 1)}", 22)}\{sim_pad("\{r2_fmt(a.bill_per_1m, 2)}→\{r2_fmt(b.bill_per_1m, 2)}", 24)}",
    )
  }
  // ---- e. 月存储费 + 总字节 + 对象数 + turbopuffer $1/PB 参照对照
  println(
    "== SimStore 存储: \{store_sim.total_object_bytes()} bytes, \{sim_object_count(store_sim)} objects, 月存储费 $\{store_sim.storage_monthly_bill()}（$0.023/GB-month）",
  )
  println(
    "== turbopuffer 参照对照（tpuF 列 = $1/PB，单查询最低 1.28GB → 最低 $1.28/1M；SimStore 列 = 实际请求费 $/1M 查询）==",
  )
  println(
    "  \{sim_pad("scenario", 16)}\{sim_pad("SimStore $/1M", 20)}\{sim_pad("tpuF $1/PB $/1M", 20)}",
  )
  for m in measures {
    let tpu = @simstore.tpu_scan_bill(m.avg_s3_bytes.to_int64()) * 1.0e6
    println(
      "  \{sim_pad(m.label, 16)}\{sim_pad(r2_fmt(m.bill_per_1m, 2), 20)}\{sim_pad(tpu.to_string(), 20)}",
    )
  }
  for m in measures2 {
    let tpu = @simstore.tpu_scan_bill(m.avg_s3_bytes.to_int64()) * 1.0e6
    println(
      "  \{sim_pad(m.label, 20)}\{sim_pad(r2_fmt(m.bill_per_1m, 2), 20)}\{sim_pad(tpu.to_string(), 20)}",
    )
  }
}
