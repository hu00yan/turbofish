// bench1m：可扩展的「批量构建 + 查询」基准骨架（SimStore，虚拟时钟）。
//
// 目标：用同一份代码从 50k（默认，跑得完）平移到 1M（BENCH_DOCS=1000000），
// 不默认真跑 1M。
//
// 写路径（逐批、不持有全量 docs）：
//   batch 0        : @build.ingest
//   batch 1..N-1   : @build.ingest_delta_opts(store, cfg, batch, 0, false)
//                    ⇒ 只追加 delta，**禁自动合并**（max_deltas=0/auto_compact=false）
//   全部批次后     : 一次 @build.compact_global（把 base + 全部 deltas 折成新 base）
//   可选最后一步   : BENCH_SEG_COMPACT=1 ⇒ 再调一次 @build.compact（把全部段合并成 1 段），
//                    用来量化「段数 ⇒ 查询 GET/q」的收益（默认 0 不做）
//
// 查询路径（样本全部来自第一批 docs，不依赖后续 docs）：
//   cold-metadata : resident 关闭，每查询 @query.open + bm25/vec，逐查询计量后恢复
//   warm-touched  : resident 开；先 burn-in 同数量查询，再 reset_cost 后重放不同样本
//                   （不调用 admit_all：这不是合成 all-hot 上界）
//   BENCH_CONTROL=1 时两档的查询入口改为 @control.ControlPlane acquire→查询→release
//   （namespace 快照按 head TTL 缓存，复用同一 Namespace），档位标签相应改为
//   cold-data(control) / warm-data(control)：cold 档 metadata 链是热的，数据面仍冷。
//   表后追加 control plane 的 hits/misses/reloads/stales/evictions。
//
// 计量口径（SimStore 虚拟时钟，非墙钟）：
//   put_bytes  = 成功 put/put_if_match 的 payload 字节（= S3 PUT 写字节）
//   latency    = SimStore 累加的 S3/NVMe/内存延迟（µs）
//   GET/q      = s3_gets（打到 S3 的 GET 次数）
//   LIST/q     = lists
//   KB/q       = bytes_s3_read / 1024
//   $/1M       = S3 请求费（GET/PUT/LIST/DELETE）× 1e6 / 查询数
//   tpuF $/1M  = 逐查询 @simstore.tpu_scan_bill(逻辑读字节) × 1e6 / 查询数
//
// 环境变量：
//   BENCH_DOCS=50000 BENCH_DIM=128 BENCH_BATCH=1000 BENCH_QUERIES=20 BENCH_SEED=7
//   BENCH_SEG_COMPACT=0|1  （1 = compact_global 之后再 @build.compact 一次）
//   BENCH_CONTROL=0|1      （1 = 查询走 @control.ControlPlane 复用 Namespace）
//   BENCH_NPROBE=8         （vec_search 的 nprobe；默认 8）
//   BENCH_RECALL=0|1       （1 = 查询表之后追加 recall@10 vs nprobe 实验）
//   BENCH_NCLUSTERS=16     （聚簇向量的中心数；默认 16）
//   BENCH_NOISE=0.08       （每维均匀噪声半径；默认 0.08）
//   BENCH_NLIST=64         （IVF nlist；1M 实测建议 256/1024）
//   BENCH_QNOISE=0         （>0 = 查询向量 = doc 向量 + 每维 U(-qn,qn)，消除
//                            query/doc 同向量的乐观偏差）
//   BENCH_EXACT_GT=0|1     （1 = recall 用全量暴搜余弦 top-10，需 docs×dim×4B 内存）
//   BENCH_TTL_MS=1000      （ControlPlane head 检查 TTL；head 变更经 1 GET 指针探测）
//
// 向量数据模型（BENCH_NCLUSTERS / BENCH_NOISE 可调）：
//   聚簇而非均匀随机：n_clusters 个 128 维中心（next_range(-1,1)，不归一化——build 会 normalize），
//   每条 doc = center[(i*2654435761)%n_clusters] + 每维 U(-noise,noise)。
//   查询向量直接复用 batch0 的 doc 向量 ⇒ query/doc 同分布。
//   （旧的均匀随机向量近似正交，会让 IVF recall 系统性偏低，nprobe 结论不可信。）
//
// 运行：
//   moon run cmd/bench1m --target native --release
//   BENCH_DOCS=1000000 BENCH_QUERIES=100 moon run cmd/bench1m --target native --release

///|
fn pad(s : String, w : Int) -> String {
  let mut out = s
  while out.length() < w {
    out = out + " "
  }
  out
}

///|
fn pad_left(s : String, w : Int) -> String {
  let mut out = ""
  let mut i = s.length()
  while i < w {
    out = " " + out
    i += 1
  }
  out + s
}

///|
fn fmt(x : Double, digits : Int) -> String {
  if digits == 0 {
    return (x + 0.5).to_int().to_string()
  }
  let scale = if digits == 1 {
    10.0
  } else if digits == 2 {
    100.0
  } else if digits == 3 {
    1000.0
  } else {
    10000.0
  }
  let n = (x * scale + 0.5).to_int()
  let d = scale.to_int()
  let frac = n % d
  let mut fs = frac.to_string()
  while fs.length() < digits {
    fs = "0" + fs
  }
  "\{n / d}.\{fs}"
}

///|
fn mb(bytes : Int) -> String {
  fmt(bytes.to_double() / 1048576.0, 3)
}

///|
fn kb(bytes : Double) -> String {
  fmt(bytes / 1024.0, 1)
}

///|
/// 解析正整数环境变量；缺失/非法/<=0 一律回退默认值。
fn env_int(name : String, dflt : Int) -> Int {
  match @env.get_env_var(name) {
    Some(s) => {
      let mut n = 0
      let mut ok = true
      for ch in s.iter() {
        let c = ch.to_int()
        if c < 48 || c > 57 {
          ok = false
          break
        }
        n = n * 10 + (c - 48)
      }
      if ok && n > 0 {
        n
      } else {
        dflt
      }
    }
    None => dflt
  }
}

///|
/// 解析正浮点环境变量（只支持 `1`、`0.03` 这类十进制字面量；不引入新 import）。
/// 缺失/非法/<=0 一律回退默认值。
fn env_float(name : String, dflt : Double) -> Double {
  match @env.get_env_var(name) {
    Some(s) => {
      let mut ip = 0.0
      let mut fp = 0.0
      let mut scale = 0.1
      let mut seen_dot = false
      let mut ok = true
      let mut digits = 0
      for ch in s.iter() {
        let c = ch.to_int()
        if c == 46 && !seen_dot {
          seen_dot = true
        } else if c >= 48 && c <= 57 {
          digits += 1
          if seen_dot {
            fp += (c - 48).to_double() * scale
            scale = scale * 0.1
          } else {
            ip = ip * 10.0 + (c - 48).to_double()
          }
        } else {
          ok = false
          break
        }
      }
      let x = ip + fp
      if ok && digits > 0 && x > 0.0 {
        x
      } else {
        dflt
      }
    }
    None => dflt
  }
}

///|
/// 解析布尔环境变量："1"/"true" = 开，其它值 = 关，缺失 = 默认。
/// （env_int 把 "0" 折回默认值，无法表达默认开启的开关，故用本函数。）
fn env_bool(name : String, dflt : Bool) -> Bool {
  match @env.get_env_var(name) {
    Some(s) => s == "1" || s == "true"
    None => dflt
  }
}

///|
fn max_d(arr : Array[Double]) -> Double {
  let mut m = 0.0
  for v in arr {
    if v > m {
      m = v
    }
  }
  m
}

///|
fn pct(arr : Array[Double], p : Double) -> Double {
  if arr.is_empty() {
    return 0.0
  }
  let s = arr.copy()
  s.sort()
  s[(p * (s.length() - 1).to_double()).to_int()]
}

///|
fn avg_i(arr : Array[Int]) -> Double {
  if arr.is_empty() {
    return 0.0
  }
  let mut sum = 0
  for v in arr {
    sum += v
  }
  sum.to_double() / arr.length().to_double()
}

///|
/// 计量包装：SimStore 不暴露 put 字节数，这里累计成功写入的 payload 字节；
/// 其余（延迟/计费/NVMe/CAS/range/list/delete）全部原样委托，语义不变。
priv struct CountingStore {
  inner : @simstore.SimStore
  mut put_bytes : Int
}

///|
fn CountingStore::new(seed : UInt) -> CountingStore {
  {
    inner: @simstore.SimStore::new(@simstore.SimConfig::aws_default(seed)),
    put_bytes: 0,
  }
}

///|
fn CountingStore::reset_writes(self : CountingStore) -> Unit {
  self.put_bytes = 0
}

///|
impl @store.ObjectStore for CountingStore with fn get(
  self : CountingStore,
  key : String,
) -> Bytes? {
  self.inner.get(key)
}

///|
impl @store.ObjectStore for CountingStore with fn put(
  self : CountingStore,
  key : String,
  value : Bytes,
) -> Unit {
  self.put_bytes += value.length()
  self.inner.put(key, value)
}

///|
impl @store.ObjectStore for CountingStore with fn put_if_match(
  self : CountingStore,
  key : String,
  e : @store.Expected,
  value : Bytes,
) -> Bool {
  let @store.Expected(expected) = e
  let ok = self.inner.put_if_match(key, @store.Expected(expected), value)
  if ok {
    // CAS 失败不落字节（真 S3 也只产生一次失败请求，不产生新数据字节）。
    self.put_bytes += value.length()
  }
  ok
}

///|
impl @store.ObjectStore for CountingStore with fn get_range(
  self : CountingStore,
  key : String,
  br : @store.ByteRange,
) -> Bytes? {
  let offset = br.off
  let len = br.len
  self.inner.get_range(key, @store.ByteRange::{ off: offset, len: len })
}

///|
impl @store.ObjectStore for CountingStore with fn list(
  self : CountingStore,
  prefix : String,
) -> Array[String] {
  self.inner.list(prefix)
}

///|
impl @store.ObjectStore for CountingStore with fn delete(
  self : CountingStore,
  key : String,
) -> Unit {
  self.inner.delete(key)
}

///|
impl @store.ObjectStore for CountingStore with fn head_version(
  self : CountingStore,
  key : String
) -> String? {
  self.inner.head_version(key)
}

///|
/// 逐批确定性文档生成器：同一个 rng 实例跨批推进，因此
/// (seed, docs, dim, batch) 固定 ⇒ 文档序列固定；任一时刻只持有当前批。
///
/// 向量分布 = **聚簇**（贴近真实 embedding），不是均匀随机：
///   - n_clusters 个 dim 维中心，`next_range(-1,1)` 生成（不归一化，build 侧会 normalize）；
///   - 每条 doc 取 cluster = (i * 2654435761) % n_clusters（固定循环，分布均匀）；
///   - 向量 = center[cluster] + 每维 `next_range(-noise, noise)` 小噪声。
/// 查询向量仍直接复用 batch0 的 doc 向量 ⇒ query/doc 同分布。
priv struct DocGen {
  rng : @core.Rng
  dim : Int
  n_clusters : Int
  noise : Double
  centers : Array[Float]
  words : Array[String]
  mut next_index : Int
}

///|
fn DocGen::new(
  seed : UInt,
  dim : Int,
  n_clusters : Int,
  noise : Double,
) -> DocGen {
  let rng = @core.Rng::new(seed)
  // 中心先于 doc 生成 ⇒ 中心只由 (seed, dim, n_clusters) 决定，跨批稳定。
  let centers : Array[Float] = Array(capacity=n_clusters * dim)
  for _c in 0..<n_clusters {
    for _d in 0..<dim {
      centers.push(Float::from_double(rng.next_range(-1.0, 1.0)))
    }
  }
  {
    rng,
    dim,
    n_clusters,
    noise,
    centers,
    // 固定小词表：BM25 的 term 分布稳定，跨规模可比。
    words: [
      "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "index", "search",
      "vector", "object", "storage", "latency", "cost", "query", "segment",
      "manifest",
    ],
    next_index: 0,
  }
}

///|
fn DocGen::next_batch(self : DocGen, n : Int) -> Array[@core.Doc] {
  let docs : Array[@core.Doc] = Array(capacity=n)
  for _ in 0..<n {
    let i = self.next_index
    self.next_index += 1
    // 固定循环选簇：2654435761 为 2^32 的黄金比例乘子；与 n_clusters 互质时均匀遍历。
    // （MoonBit Int 是 32 位，乘子超限 ⇒ 用 Int64 算。）
    let cluster = ((i.to_int64() * 2654435761L) %
      self.n_clusters.to_int64()).to_int()
    let base = cluster * self.dim
    let v : Array[Float] = Array(capacity=self.dim)
    for d in 0..<self.dim {
      let x = self.centers[base + d].to_double() +
        self.rng.next_range(-self.noise, self.noise)
      v.push(Float::from_double(x))
    }
    let mut text = ""
    let nw = 6 + self.rng.next_range(0.0, 6.0).to_int()
    for j in 0..<nw {
      let w = self.words[self.rng.next_range(
        0.0,
        self.words.length().to_double(),
      ).to_int()]
      if j > 0 {
        text = text + " "
      }
      text = text + w
    }
    docs.push({
      id: 1000UL + i.to_uint64(),
      text,
      vector: v,
      category: "cat\{i % 4}",
      ts: 1700000000L + i.to_int64(),
      public: i % 3 != 0,
    })
  }
  docs
}

///|
/// 从一批 docs 抽取 2*`nq` 个查询样本（前 nq 用于 burn-in，后 nq 用于测量）。
/// bm25 取首个 term，vec 直接复用该 doc 的向量（query 侧会自行归一化）。
/// `qnoise > 0` 时 vec 查询 = doc 向量 + 每维 U(-qnoise, qnoise)（用 gen.rng
/// 保证确定性；仅在 qnoise>0 时消耗 rng，默认 0 不改变既有数据序列）。
fn collect_queries(
  docs : Array[@core.Doc],
  nq : Int,
  gen : DocGen,
  qnoise : Double,
) -> (Array[String], Array[Array[Float]]) {
  let bm : Array[String] = Array(capacity=nq * 2)
  let vecs : Array[Array[Float]] = Array(capacity=nq * 2)
  let n = docs.length()
  for i in 0..<(nq * 2) {
    let d = docs[(i * 37 + 11) % n]
    let toks = @core.tokenize(d.text)
    bm.push(if toks.is_empty() { "alpha" } else { toks[0] })
    if qnoise > 0.0 {
      let v : Array[Float] = Array(capacity=gen.dim)
      for x in d.vector {
        v.push(Float::from_double(
          x.to_double() + gen.rng.next_range(-qnoise, qnoise),
        ))
      }
      vecs.push(v)
    } else {
      vecs.push(d.vector)
    }
  }
  (bm, vecs)
}

///|
/// 单批计量。
priv struct BatchStat {
  batch : Int
  docs : Int
  put_bytes : Int
  puts : Int
  latency_ms : Double
  storage_bytes : Int
}

///|
fn batch_row(b : BatchStat) -> String {
  "\{pad_left(b.batch.to_string(), 6)}\{pad_left(b.docs.to_string(), 8)}\{pad_left(mb(b.put_bytes), 14)}\{pad_left(b.puts.to_string(), 8)}\{pad_left(fmt(b.latency_ms, 1), 14)}\{pad_left(mb(b.storage_bytes), 16)}"
}

///|
fn build_cfg(ns : String, dim : Int) -> @build.BuildConfig {
  // single_copy = global IVF 单副本 + normalize_vecs + fts bloom（delta 前提）。
  let base = @build.BuildConfig::single_copy(ns)
  {
    ..base,
    segment_rows: 2000,
    nlist: env_int("BENCH_NLIST", 64),
    vector_dim: dim,
    use_f16: env_bool("BENCH_F16", true),
    id_dense: true,
    write_blockmax: true,
    global_pack_size: env_int("BENCH_PACK", 1),
  }
}

///|
/// 单查询档位的聚合结果。
priv struct Cell {
  cls : String
  tier : String
  n : Int
  p50_ms : Double
  p95_ms : Double
  tail_ms : Double
  tail_label : String
  gets : Double
  lists : Double
  kb_s3 : Double
  bill_per_1m : Double
  tpu_per_1m : Double
  errors : Double
}

///|
/// 档位标签：control 开启时 metadata 链是热的，标签不再叫 cold-metadata。
fn tier_label(cold_meta : Bool, ctrl : Bool) -> String {
  if ctrl {
    if cold_meta {
      "cold-data(control)"
    } else {
      "warm-data(control)"
    }
  } else if cold_meta {
    "cold-metadata"
  } else {
    "warm-touched"
  }
}

///|
fn has_cp(cp : @control.ControlPlane[CountingStore]?) -> Bool {
  match cp {
    Some(_) => true
    None => false
  }
}

///|
/// control plane 计数快照 (hits, misses, reloads, stales, evictions, probes, probe_hits)；
/// 未启用时全 0，便于统一做差分。
fn ctrl_stat(
  cp : @control.ControlPlane[CountingStore]?,
) -> (Int, Int, Int, Int, Int, Int, Int) {
  match cp {
    Some(c) => {
      let (h, m, r, s, e) = c.stats()
      let (p, ph) = c.probe_stats()
      (h, m, r, s, e, p, ph)
    }
    None => (0, 0, 0, 0, 0, 0, 0)
  }
}

///|
/// 单次查询入口。`cp=None` ⇒ 每查询重新 `@query.open`（cold-metadata 基线）；
/// `cp=Some` ⇒ `acquire`（TTL 内命中缓存、pin 住快照）→ 查询 → `release`。
/// acquire 返回的 Namespace 已被 pin，正常路径必须 release（MoonBit 无 finally，
/// 失败路径会漏一次 pin；本基准不故意抛错）。
async fn run_one(
  store : CountingStore,
  ns : String,
  cls : String,
  bm25_qs : Array[String],
  vec_qvs : Array[Array[Float]],
  idx : Int,
  nprobe : Int,
  cp : @control.ControlPlane[CountingStore]?,
) -> Unit {
  let n = match cp {
    Some(c) => c.acquire(ns)
    None => @query.open(store, ns)
  }
  if cls == "bm25" {
    let _ = @query.bm25_search(n, bm25_qs[idx], 10, None)
  } else {
    let _ = @query.vec_search(n, vec_qvs[idx], 10, nprobe, None)
  }
  match cp {
    Some(c) => c.release(ns)
    None => ()
  }
}

///|
/// 跑一个查询档位（`cold_meta=true` ⇒ cold-metadata；否则 warm-touched）。
async fn measure(
  store : CountingStore,
  ns : String,
  cls : String,
  bm25_qs : Array[String],
  vec_qvs : Array[Array[Float]],
  cold_meta : Bool,
  n : Int,
  burn : Int,
  nprobe : Int,
  cp : @control.ControlPlane[CountingStore]?,
) -> Cell {
  store.inner.require_latency()
  let cold_each = cold_meta && env_int("BENCH_COLD_PER_QUERY", 1) != 0
  if cold_meta && !cold_each {
    // 只冷一次：用于“cold-start 后进入稳态”的旧口径。
    store.inner.cold()
  }
  store.inner.set_resident_enabled(!cold_meta)
  if !cold_meta {
    // warm-touched burn-in：自然预热（不 admit_all）。
    for i in 0..<burn {
      run_one(store, ns, cls, bm25_qs, vec_qvs, i, nprobe, cp)
    }
  }
  store.inner.reset_cost()
  let lat : Array[Double] = Array(capacity=n)
  let gets : Array[Int] = Array(capacity=n)
  let lists : Array[Int] = Array(capacity=n)
  let s3b : Array[Int] = Array(capacity=n)
  let logical : Array[Int] = Array(capacity=n)
  let mut errs = 0
  let mut prev_lat = 0.0
  let mut prev_gets = 0
  let mut prev_lists = 0
  let mut prev_s3 : Int64 = 0L
  let mut prev_log : Int64 = 0L
  let mut prev_err = 0
  for i in 0..<n {
    let idx = if cold_meta { i } else { burn + i }
    if cold_each {
      // 真正的 cold-start：每条查询前清数据面 NVMe/ranges；ControlPlane 的
      // Namespace/metadata 缓存仍保留（control 模式下 metadata 热、数据冷）。
      store.inner.cold()
    }
    run_one(store, ns, cls, bm25_qs, vec_qvs, idx, nprobe, cp)
    let c = store.inner.cost()
    lat.push(c.total_latency_us - prev_lat)
    gets.push(c.s3_gets - prev_gets)
    lists.push(c.lists - prev_lists)
    // 累计计数器已扩为 Int64（大 pack 单对象 >130MB，100 查询累计会溢出 32 位）；
    // 单查询差值仍 < 2^31，转回 Int 保持下游不变。
    s3b.push((c.bytes_s3_read - prev_s3).to_int())
    logical.push((c.bytes_logical_read - prev_log).to_int())
    prev_lat = c.total_latency_us
    prev_gets = c.s3_gets
    prev_lists = c.lists
    prev_s3 = c.bytes_s3_read
    prev_log = c.bytes_logical_read
    errs += c.errors - prev_err
    prev_err = c.errors
  }
  store.inner.set_resident_enabled(true)
  let c = store.inner.cost()
  let mut tpu = 0.0
  for b in logical {
    tpu += @simstore.tpu_scan_bill(b.to_int64())
  }
  {
    cls,
    tier: tier_label(cold_meta, has_cp(cp)),
    n,
    p50_ms: pct(lat, 0.5) / 1000.0,
    p95_ms: pct(lat, 0.95) / 1000.0,
    tail_ms: if n >= 100 { pct(lat, 0.99) / 1000.0 } else { max_d(lat) / 1000.0 },
    tail_label: if n >= 100 { "p99" } else { "max" },
    gets: avg_i(gets),
    lists: avg_i(lists),
    kb_s3: avg_i(s3b) / 1024.0,
    bill_per_1m: c.bill_requests_total / n.to_double() * 1.0e6,
    tpu_per_1m: tpu / n.to_double() * 1.0e6,
    errors: errs.to_double() / n.to_double(),
  }
}

///|
fn cell_row(c : Cell) -> String {
  "\{pad(c.cls, 6)}\{pad(c.tier, 19)}\{pad(c.n.to_string(), 5)}\{pad("\{fmt(c.p50_ms, 1)}/\{fmt(c.p95_ms, 1)}/\{fmt(c.tail_ms, 1)} \{c.tail_label}", 24)}\{pad(fmt(c.gets, 1), 9)}\{pad(fmt(c.lists, 1), 8)}\{pad(kb(c.kb_s3 * 1024.0), 10)}\{pad(fmt(c.bill_per_1m, 2), 10)}\{pad(fmt(c.tpu_per_1m, 2), 12)}\{fmt(c.errors, 2)}"
}

///|
fn print_query_header() -> Unit {
  println(
    "  \{pad("class", 6)}\{pad("tier", 19)}\{pad("n", 5)}\{pad("p50/p95/tail", 24)}\{pad("GET/q", 9)}\{pad("LIST/q", 8)}\{pad("KB/q", 10)}\{pad("$/1M", 10)}\{pad("tpuF $/1M", 12)}err",
  )
}

///|
/// 单个档位的 control plane 计数差分。
priv struct CtrlRow {
  cls : String
  tier : String
  hits : Int
  misses : Int
  reloads : Int
  stales : Int
  evictions : Int
  probes : Int
  probe_hits : Int
}

///|
fn ctrl_row(r : CtrlRow) -> String {
  "  \{pad(r.cls, 6)}\{pad(r.tier, 19)}\{pad("hits=\{r.hits}", 12)}\{pad("misses=\{r.misses}", 12)}\{pad("reloads=\{r.reloads}", 14)}\{pad("stales=\{r.stales}", 12)}\{pad("evictions=\{r.evictions}", 14)}\{pad("probes=\{r.probes}", 12)}probe_hits=\{r.probe_hits}"
}

///|
/// 读 head manifest（公开 API：@store.read_head_state + @format.manifest_from_json），
/// 输出 segments/num_docs/global_gen 状态。任何一步不可用都打印 key 是否存在，不抛错。
async fn manifest_line(store : CountingStore, ns : String) -> String {
  let (head, _newer) = @store.read_head_state(store, ns, "")
  if head == "" {
    return "none (no published head)"
  }
  let key = "\{ns}/_manifest/\{head}.json"
  let body = match store.get(key) {
    Some(bs) =>
      @utf8.decode(bs.exact_view()) catch {
        _ => return "head=\{head}: manifest is not utf8 (key exists)"
      }
    None => return "head=\{head}: manifest key MISSING (\{key})"
  }
  let j = @json.parse(body) catch {
    _ => return "head=\{head}: manifest is not json (key exists)"
  }
  let m = @format.manifest_from_json(j) catch {
    _ => return "head=\{head}: manifest parse failed (key exists)"
  }
  let vg = match m.vec_global_version {
    Some(v) => v
    None => "<none>"
  }
  let gen = match m.global_gen {
    Some(g) =>
      "global_gen=Some(base=\{g.base}, deltas=\{g.deltas.length()})"
    None => "global_gen=None (single full base)"
  }
  "head=\{head} segments=\{m.segments.length()} num_docs=\{m.num_docs} \{gen} vec_global_version=\{vg}"
}

///|
/// `{ns}/vec/global/` 下的物理代目录数（含 grace 期内未回收的旧代）。
async fn global_version_count(store : CountingStore, ns : String) -> Int {
  let prefix = "\{ns}/vec/global/"
  let seen : Set[String] = Set([])
  for key in store.list(prefix) {
    if key.has_prefix(prefix) {
      let rest = key[prefix.length():]
      match rest.find("/") {
        Some(i) => seen.add(rest[:i].to_owned())
        None => ()
      }
    }
  }
  seen.length()
}

///|
/// 构建结果汇总（compact 前后 + 写放大）。
priv struct BuildSummary {
  docs : Int
  batches : Int
  put_bytes : Int
  puts : Int
  build_ms : Double
  compact_put_bytes : Int
  compact_ms : Double
  seg_compact : Bool
  segc_put_bytes : Int
  segc_puts : Int
  segc_ms : Double
  segc_before : String
  storage_before : Int
  storage_after : Int
  global_objs_before : Int
  global_objs_after : Int
  global_versions_before : Int
  global_versions_after : Int
  gen : String
}

///|
/// 召回实验的 nprobe 扫描点：基础 [1,2,3,4,8,16]，nlist≥256 时补 [24,32,48,64]，
/// 去掉 > nlist 的点，并保证包含 BENCH_NPROBE。
fn recall_probe_list(nprobe_cfg : Int, nlist : Int) -> Array[Int] {
  let raw : Array[Int] = [1, 2, 3, 4, 8, 16]
  if nlist >= 64 {
    // nlist=64 时 nprobe=64 = 全扫（应=1.0），是关键的完整性锚点。
    for p in [24, 32, 48, 64] {
      if p <= nlist {
        raw.push(p)
      }
    }
  }
  if nprobe_cfg <= nlist {
    let mut has = false
    for p in raw {
      if p == nprobe_cfg {
        has = true
      }
    }
    if !has {
      raw.push(nprobe_cfg)
    }
  }
  // nprobe > nlist 无意义；升序输出（同值只出现一次：raw 元素互不相同）。
  let out : Array[Int] = []
  for p in raw {
    if p <= nlist {
      out.push(p)
    }
  }
  out.sort()
  out
}

///|
priv struct RecallRow {
  nprobe : Int
  recall : Double
  hits : Int
  total : Int
  getq_est : Double
  measured : Bool
}

///|
fn recall_row(r : RecallRow) -> String {
  "\{pad_left(r.nprobe.to_string(), 7)}\{pad_left(fmt(r.recall, 4), 12)}\{pad_left("\{r.hits}/\{r.total}", 10)}\{pad_left(fmt(r.getq_est, 2), 12)}\{if r.measured { "  (BENCH_NPROBE, 实测 cold GET/q)" } else { "" }}"
}

///|
/// 暴力精确 top-10（BENCH_EXACT_GT=1）：对一条查询在全部 (id, f32 向量) 上做
/// 归一化余弦，返回 top-10 id 集合。docs 侧也归一化（与 build 的 normalize_vecs
/// 语义一致：余弦相似度）。gt_vecs 行主序：doc j 的第 d 维 = gt_vecs[j*dim+d]。
fn exact_top10(
  qv : Array[Float],
  gt_ids : Array[UInt64],
  gt_vecs : Array[Float],
  dim : Int,
) -> Set[UInt64] {
  let n = gt_ids.length()
  let mut qn = 0.0
  for x in qv {
    qn += x.to_double() * x.to_double()
  }
  qn = qn.sqrt()
  // 10 槽 (score, id) 最小堆语义用有序数组近似：score 升序，[0] 为当前最差。
  let top_s : Array[Double] = Array(capacity=10)
  let top_i : Array[Int] = Array(capacity=10)
  for j in 0..<n {
    let base = j * dim
    let mut dot = 0.0
    let mut vn = 0.0
    for d in 0..<dim {
      let x = gt_vecs[base + d].to_double()
      dot += qv[d].to_double() * x
      vn += x * x
    }
    if vn > 0.0 {
      let score = dot / (qn * vn.sqrt())
      if top_s.length() < 10 {
        // 插入保序。
        let mut pos = top_s.length()
        top_s.push(score)
        top_i.push(j)
        while pos > 0 && top_s[pos - 1] > score {
          top_s[pos] = top_s[pos - 1]
          top_i[pos] = top_i[pos - 1]
          top_s[pos - 1] = score
          top_i[pos - 1] = j
          pos -= 1
        }
      } else if score > top_s[0] {
        // 替换最差并重排。
        let mut pos = 0
        top_s[0] = score
        top_i[0] = j
        while pos + 1 < 10 && top_s[pos + 1] < score {
          top_s[pos] = top_s[pos + 1]
          top_i[pos] = top_i[pos + 1]
          pos += 1
        }
        top_s[pos] = score
        top_i[pos] = j
      }
    }
  }
  let s : Set[UInt64] = Set([])
  for j in top_i {
    s.add(gt_ids[j])
  }
  s
}

///|
/// recall@10 vs nprobe（BENCH_RECALL=1）。
/// - 样本：vec_qvs[0..<nq]，即 cold 档使用的**测量集**（不是 warm-touched 的 burn-in）。
/// - ground truth：BENCH_EXACT_GT=1 ⇒ 全量暴搜余弦 top-10；否则 nprobe=nlist
///   （= 扫全部 list 的索引结果）近似。
/// - recall@10：逐 query 的 |top10 ∩ gt_top10| / 10，再按 query 平均。
/// - 预计 GET/q：cold vec 实测 GET/q = C（nprobe=BENCH_NPROBE），
///   扣掉 N 个 part GET 得常数项 const=C-N，再按 const+nprobe 近似；仅近似值。
async fn run_recall(
  store : CountingStore,
  ns : String,
  vec_qvs : Array[Array[Float]],
  nq : Int,
  nprobe_cfg : Int,
  cold_getq : Double,
  nlist : Int,
  exact_gt : Bool,
  gt_ids : Array[UInt64],
  gt_vecs : Array[Float],
  dim : Int,
) -> Unit {
  let gt_nprobe = nlist
  let probes = recall_probe_list(nprobe_cfg, nlist)
  let gts : Array[Set[UInt64]] = Array(capacity=nq)
  let mut gt_min = 10
  if exact_gt {
    for i in 0..<nq {
      let s = exact_top10(vec_qvs[i], gt_ids, gt_vecs, dim)
      if s.length() < gt_min {
        gt_min = s.length()
      }
      gts.push(s)
    }
  } else {
    // ground truth 与候选查询共享同一个打开的 Namespace 快照。
    let n = @query.open(store, ns)
    for i in 0..<nq {
      let s : Set[UInt64] = Set([])
      let res = @query.vec_search(n, vec_qvs[i], 10, gt_nprobe, None)
      for r in res {
        s.add(r.id)
      }
      if res.length() < gt_min {
        gt_min = res.length()
      }
      gts.push(s)
    }
  }
  let mut const_get = cold_getq - nprobe_cfg.to_double()
  if const_get < 0.0 {
    const_get = 0.0
  }
  // 候选查询与 GT 共享同一个 Namespace 快照（exact 模式下 GT 不走索引，
  // 但候选仍走索引，因此这里统一 open）。
  let n = @query.open(store, ns)
  let rows : Array[RecallRow] = Array(capacity=probes.length())
  for np in probes {
    let mut hits = 0
    for i in 0..<nq {
      for r in @query.vec_search(n, vec_qvs[i], 10, np, None) {
        if gts[i].contains(r.id) {
          hits += 1
        }
      }
    }
    rows.push({
      nprobe: np,
      recall: hits.to_double() / (nq * 10).to_double(),
      hits,
      total: nq * 10,
      getq_est: const_get + np.to_double(),
      measured: np == nprobe_cfg,
    })
  }
  println("")
  println("== recall@10 vs nprobe (BENCH_RECALL=1) ==")
  if exact_gt {
    println(
      "samples=\{nq} vec queries（batch0 测量集，非 burn-in）；ground truth = 全量 \{gt_ids.length()} docs 暴力余弦 top-10（独立精确，非索引近似）；recall@10 = |交集|/10 逐 query 平均",
    )
  } else {
    println(
      "samples=\{nq} vec queries（batch0 测量集，非 burn-in）；ground truth = nprobe=\{gt_nprobe}（= nlist，近似暴搜）的 top-10；recall@10 = |交集|/10 逐 query 平均",
    )
  }
  if gt_min < 10 {
    println(
      "  WARNING: ground truth 至少一次只返回 \{gt_min} 条（<10）；recall 仍按 /10 计算，偏低。",
    )
  }
  println(
    "cold vec 实测 GET/q=\{fmt(cold_getq, 2)} @ nprobe=\{nprobe_cfg} ⇒ 近似 GET/q ≈ const(\{fmt(const_get, 2)}) + nprobe（const 为 metadata/其他 GET，按实测反推，非精确值）",
  )
  println(
    "  \{pad_left("nprobe", 7)}\{pad_left("recall@10", 12)}\{pad_left("hits", 10)}\{pad_left("预计GET/q", 12)}",
  )
  for r in rows {
    println(recall_row(r))
  }
}

///|
async fn run() -> Unit {
  let docs_n = env_int("BENCH_DOCS", 50000)
  let dim = env_int("BENCH_DIM", 128)
  let batch_size = env_int("BENCH_BATCH", 1000)
  let nq = env_int("BENCH_QUERIES", 20)
  let seed = env_int("BENCH_SEED", 7)
  // env_int 把 "0"/非法/缺失都折回默认值 0 ⇒ 这里 !0 即“开关打开”。
  let seg_compact = env_int("BENCH_SEG_COMPACT", 0) != 0
  // 同理：BENCH_CONTROL 默认 0（关）；!0 即开启 ControlPlane 复用 Namespace。
  let bench_control = env_int("BENCH_CONTROL", 0) != 0
  let nprobe = env_int("BENCH_NPROBE", 8)
  let bench_recall = env_int("BENCH_RECALL", 0) != 0
  // 聚簇数据生成参数：n_clusters=16 中心 + 每维 ±0.08 噪声（默认即真实 embedding 近似）。
  let n_clusters = env_int("BENCH_NCLUSTERS", 16)
  let noise = env_float("BENCH_NOISE", 0.08)
  // 查询扰动（BENCH_QNOISE，默认 0 = 查询即 doc 向量）：>0 时查询向量 =
  // doc 向量 + 每维 U(-qn, qn)，消除「query 向量 = 文档向量本身」的乐观偏差。
  let qnoise = env_float("BENCH_QNOISE", 0.0)
  // 精确 ground truth（BENCH_EXACT_GT=1）：构建期间保留全量 (id, f32 向量)，
  // recall 用暴力余弦扫描，不再用 nprobe=nlist 的索引结果近似。内存 ≈ docs×dim×4B。
  let exact_gt = env_int("BENCH_EXACT_GT", 0) != 0
  // ControlPlane head 检查 TTL（ms）；配合 head 指针探测，拉长可摊薄探测 GET。
  let ttl_ms = env_int("BENCH_TTL_MS", 1000)
  let ns = "bench1m"
  let cfg = build_cfg(ns, dim)
  let nlist = cfg.nlist
  let batches = (docs_n + batch_size - 1) / batch_size

  println("== bench1m: batched build + query (SimStore virtual clock) ==")
  println(
    "docs=\{docs_n} dim=\{dim} batch=\{batch_size} queries=\{nq} seed=\{seed} => batches=\{batches}",
  )
  println(
    "cfg: single_copy(global IVF, normalize_vecs) segment_rows=2000 nlist=\{nlist} vector_dim=\{dim} use_f16=\{cfg.use_f16} pack=\{cfg.global_pack_size}",
  )
  println("vec nprobe=\{nprobe} (BENCH_NPROBE)")
  println(
    "vec data: clustered, n_clusters=\{n_clusters} centers (next_range(-1,1), unormalized) + per-dim noise U(-\{fmt(noise, 3)},\{fmt(noise, 3)}); cluster=(i*2654435761)%n_clusters; queries = batch0 doc vectors\{if qnoise > 0.0 { " + per-dim U(-\{fmt(qnoise, 3)},\{fmt(qnoise, 3)}) (BENCH_QNOISE)" } else { "" }}",
  )
  if exact_gt {
    println("ground truth: EXACT brute-force cosine over all \{docs_n} docs (BENCH_EXACT_GT=1, ~\{mb(docs_n * dim * 4)} MB extra RAM)")
  } else {
    println("ground truth: nprobe=\{nlist} index result (BENCH_EXACT_GT=0 近似；设 1 用暴搜)")
  }
  println(
    "write path: batch0=ingest, batch1..=ingest_delta_opts(max_deltas=0, auto_compact=false), then 1x compact_global",
  )
  if seg_compact {
    println(
      "  then 1x @build.compact (BENCH_SEG_COMPACT=1: 全部段合并成 1 段，重建 global base)",
    )
  }
  if bench_control {
    println(
      "  query entry: @control.ControlPlane acquire/release (BENCH_CONTROL=1, TTL=\{ttl_ms}ms via BENCH_TTL_MS, head 指针 GET 探测) ⇒ 复用 Namespace 快照",
    )
  } else {
    println("  query entry: @query.open per query (BENCH_CONTROL=0)")
  }
  if nq * 2 > batch_size {
    println(
      "  WARNING: 2*BENCH_QUERIES > BENCH_BATCH，查询样本会重复（cold/warm 各取一半）。",
    )
  }
  println("")

  let store = CountingStore::new(seed.reinterpret_as_uint())
  store.inner.require_latency()
  let gen = DocGen::new(seed.reinterpret_as_uint(), dim, n_clusters, noise)
  let stats : Array[BatchStat] = Array(capacity=batches)
  let bm25_qs : Array[String] = Array()
  let vec_qvs : Array[Array[Float]] = Array()
  // 精确 GT 的工作集（BENCH_EXACT_GT=1 才填充）：全量 id + 原始 f32 向量。
  let gt_ids : Array[UInt64] = Array(capacity=docs_n)
  let gt_vecs : Array[Float] = Array(capacity=docs_n * dim)
  let mut docs_done = 0
  let mut put_bytes_total = 0
  let mut puts_total = 0
  let mut build_us = 0.0
  while docs_done < docs_n {
    let take = if docs_n - docs_done < batch_size {
      docs_n - docs_done
    } else {
      batch_size
    }
    // 本批 docs 只在循环体存活：不把全量 docs 一次性放进内存。
    let docs = gen.next_batch(take)
    if stats.is_empty() {
      // 查询样本只依赖第一批 docs。
      let (bm, vqs) = collect_queries(docs, nq, gen, qnoise)
      bm25_qs.append(bm)
      vec_qvs.append(vqs)
    }
    if exact_gt {
      for d in docs {
        gt_ids.push(d.id)
        for x in d.vector {
          gt_vecs.push(x)
        }
      }
    }
    store.reset_writes()
    store.inner.reset_cost()
    if stats.is_empty() {
      @build.ingest(store, cfg, docs)
    } else {
      // 禁自动合并：链长由 bench 自己控制，最后一次性 compact_global。
      @build.ingest_delta_opts(store, cfg, docs, 0, false)
    }
    let snap = store.inner.cost()
    let put_bytes = store.put_bytes
    let batch_us = snap.total_latency_us
    stats.push({
      batch: stats.length() + 1,
      docs: take,
      put_bytes,
      puts: snap.puts,
      latency_ms: batch_us / 1000.0,
      storage_bytes: snap.storage_bytes,
    })
    put_bytes_total += put_bytes
    puts_total += snap.puts
    build_us += batch_us
    docs_done += take
  }

  // ---- compact 前后（单次全局合并）----
  let storage_before = store.inner.cost().storage_bytes
  let global_objs_before = store.list("\{ns}/vec/global/").length()
  let versions_before = global_version_count(store, ns)
  store.reset_writes()
  store.inner.reset_cost()
  @build.compact_global(store, cfg, ns)
  let csnap = store.inner.cost()
  let compact_put = store.put_bytes
  let compact_ms = csnap.total_latency_us / 1000.0
  let mut storage_after = csnap.storage_bytes

  // ---- 可选：最后做一次 segment 级 compact（BENCH_SEG_COMPACT=1）----
  // 消除 per-segment 局部性放大：vec 读 part 数 = nprobe × 段数，bm25 读 = 段数 × 列文件。
  // 计量口径与 compact_global 一致：reset_writes/reset_cost 后单独统计，
  // 但 total put / write_amp 会把这次写入算进去。
  let mut segc_put = 0
  let mut segc_puts = 0
  let mut segc_ms = 0.0
  let mut segc_before = ""
  if seg_compact {
    // 先记 compact 前的段状态（这一步只有 GET，不含写；放在查询前，
    // 查询档位各自 reset_cost / burn-in，不会污染计量）。
    segc_before = manifest_line(store, ns)
    store.reset_writes()
    store.inner.reset_cost()
    @build.compact(store, cfg, ns)
    let ssnap = store.inner.cost()
    segc_put = store.put_bytes
    segc_puts = ssnap.puts
    segc_ms = ssnap.total_latency_us / 1000.0
    storage_after = ssnap.storage_bytes
  }

  // ---- 逐批表（批次数多时省略中段）----
  println(
    pad("batch", 6) +
    pad("docs", 8) +
    pad_left("put MB", 14) +
    pad_left("puts", 8) +
    pad_left("virt ms", 14) +
    pad_left("storage MB", 16),
  )
  let nb = stats.length()
  for i in 0..<nb {
    let show = nb <= 24 || i < 5 || i >= nb - 5
    if show {
      println(batch_row(stats[i]))
    } else if i == 5 {
      println("  ... (\{nb - 10} batches elided)")
    }
  }
  println("")

  // ---- 查询档位 ----
  // control=1 时先建 ControlPlane（store 已建完），后续逐查询 acquire → 查询 → release。
  let cp : @control.ControlPlane[CountingStore]? = if bench_control {
    let ctrl_cfg : @control.CtrlConfig = {
      head_ttl_ms: ttl_ms.to_uint64(),
      stale_ok: false,
      max_entries: 64,
    }
    Some(@control.ControlPlane::new(store, ctrl_cfg))
  } else {
    None
  }
  println(
    "== query tiers (\{nq} queries/class；样本取自 batch0；$1M=S3 请求费，tpuF=$1/PB 最低 1.28GB) ==",
  )
  print_query_header()
  let cells : Array[Cell] = Array(capacity=4)
  let ctrl_rows : Array[CtrlRow] = Array(capacity=4)
  for cold_meta in [true, false] {
    let burn = if cold_meta { 0 } else { nq }
    for cls in ["bm25", "vec"] {
      let (h0, m0, r0, s0, e0, p0, ph0) = ctrl_stat(cp)
      cells.push(
        measure(
          store, ns, cls, bm25_qs, vec_qvs, cold_meta, nq, burn, nprobe, cp,
        ),
      )
      let (h1, m1, r1, s1, e1, p1, ph1) = ctrl_stat(cp)
      ctrl_rows.push({
        cls,
        tier: tier_label(cold_meta, has_cp(cp)),
        hits: h1 - h0,
        misses: m1 - m0,
        reloads: r1 - r0,
        stales: s1 - s0,
        evictions: e1 - e0,
        probes: p1 - p0,
        probe_hits: ph1 - ph0,
      })
    }
  }
  for c in cells {
    println(cell_row(c))
  }
  if nq < 100 {
    println(
      "  NOTE: n<100，tail 列是 max（不是 p99）；要 p99 请设 BENCH_QUERIES>=100。",
    )
  }
  if bench_control {
    println(
      "  NOTE: cold-data(control) = ControlPlane 复用 Namespace（metadata 链热）+ resident 关闭（数据面仍冷）；warm-data(control) = 同上 + burn-in \{nq} 次。",
    )
  } else {
    println(
      "  NOTE: cold-metadata = resident 关闭 + 每查询重新 open（元数据走 S3）；warm-touched = burn-in \{nq} 次后重放不同样本，未用 admit_all。",
    )
  }
  // ---- control plane 统计（查询表后；hits = TTL 内命中，reloads = 重新 open）----
  if bench_control {
    println("")
    println(
      "== control plane stats (BENCH_CONTROL=1, TTL=\{ttl_ms}ms, 逐档差分) ==",
    )
    println(
      "  \{pad("class", 6)}\{pad("tier", 19)}\{pad("hits", 12)}\{pad("misses", 12)}\{pad("reloads", 14)}\{pad("stales", 12)}\{pad("evictions", 14)}\{pad("probes", 12)}probe_hits",
    )
    for r in ctrl_rows {
      println(ctrl_row(r))
    }
    let (th, tm, tr, ts, te, tp, tph) = ctrl_stat(cp)
    println(
      "  total: hits=\{th} misses=\{tm} reloads=\{tr} stales=\{ts} evictions=\{te} probes=\{tp} probe_hits=\{tph}（reload=全量 open（GET+LIST+GET）；probe=TTL 过期后 1 次 GET 指针探测，命中即免 open）",
    )
  }
  // ---- recall@10 vs nprobe（BENCH_RECALL=1；查询表之后，不影响上面的计量）----
  if bench_recall {
    let cold_tier = tier_label(true, has_cp(cp))
    let mut cold_getq = 0.0
    for c in cells {
      if c.cls == "vec" && c.tier == cold_tier {
        cold_getq = c.gets
      }
    }
    run_recall(
      store, ns, vec_qvs, nq, nprobe, cold_getq, nlist, exact_gt, gt_ids,
      gt_vecs, dim,
    )
  }
  println("")

  // ---- 汇总（manifest/LIST 放在查询之后，避免预热缓存影响查询档位）----
  let summary : BuildSummary = {
    docs: docs_done,
    batches: stats.length(),
    put_bytes: put_bytes_total,
    puts: puts_total,
    build_ms: build_us / 1000.0,
    compact_put_bytes: compact_put,
    compact_ms,
    seg_compact,
    segc_put_bytes: segc_put,
    segc_puts,
    segc_ms,
    segc_before,
    storage_before,
    storage_after,
    global_objs_before,
    global_objs_after: store.list("\{ns}/vec/global/").length(),
    global_versions_before: versions_before,
    global_versions_after: global_version_count(store, ns),
    gen: manifest_line(store, ns),
  }
  let s = summary
  let vector_bytes = s.docs * dim * 2 // use_f16 ⇒ 2 字节/维
  // total put / write_amp 含：逐批写入 + compact_global + （可选）segment compact。
  let total_put = s.put_bytes + s.compact_put_bytes + s.segc_put_bytes
  let total_ms = s.build_ms + s.compact_ms + s.segc_ms
  println("== summary ==")
  println("total docs           = \{s.docs} (dim=\{dim}, batches=\{s.batches})")
  println(
    "build put            = \{mb(s.put_bytes)} MB (\{s.put_bytes} bytes, \{s.puts} PUTs, virt \{fmt(s.build_ms, 1)} ms)",
  )
  println(
    "compact put          = \{mb(s.compact_put_bytes)} MB (\{s.compact_put_bytes} bytes, virt \{fmt(s.compact_ms, 1)} ms)",
  )
  if s.seg_compact {
    println(
      "seg compact put      = \{mb(s.segc_put_bytes)} MB (\{s.segc_put_bytes} bytes, \{s.segc_puts} PUTs, virt \{fmt(s.segc_ms, 1)} ms)",
    )
  } else {
    println("seg compact          = skipped (BENCH_SEG_COMPACT=0)")
  }
  let total_line = if s.seg_compact {
    "total put            = \{mb(total_put)} MB (build+compact_global+seg compact; virt total \{fmt(total_ms, 1)} ms)"
  } else {
    "total put            = \{mb(total_put)} MB (build+compact; virt total \{fmt(total_ms, 1)} ms)"
  }
  println(total_line)
  println(
    "write_amp            = \{fmt(total_put.to_double() / vector_bytes.to_double(), 2)}x vector_bytes (f16 \{mb(vector_bytes)} MB)",
  )
  println(
    "write_amp (build)    = \{fmt(s.put_bytes.to_double() / vector_bytes.to_double(), 2)}x (excl. final compact)",
  )
  if s.seg_compact {
    println(
      "write_amp (no segc)  = \{fmt((s.put_bytes + s.compact_put_bytes).to_double() / vector_bytes.to_double(), 2)}x (excl. segment compact)",
    )
  }
  println(
    "global objects       = before compact \{s.global_objs_before}, after compact \{s.global_objs_after} (list(\{ns}/vec/global/)，含 grace 期内旧代)",
  )
  println(
    "global versions      = before compact \{s.global_versions_before}, after compact \{s.global_versions_after} (live=1 代：global_gen=None)",
  )
  println("manifest             = \{s.gen}")
  if s.seg_compact {
    println("  seg compact: before = \{s.segc_before}")
    println(
      "  seg compact: after  = \{s.gen}  (上面 manifest 行即 seg compact 后的 head)",
    )
    println(
      "  (compact_global 只折 global 链；BENCH_SEG_COMPACT=1 之后额外一次 @build.compact 把段合并成 1)",
    )
  } else {
    println(
      "  (compact_global 只把 base+全部 deltas 折成一个新 base；segment 级合并是 @build.compact，不在本骨架内)",
    )
  }
  println(
    "storage bytes        = before compact \{mb(s.storage_before)} MB -> after compact \{mb(s.storage_after)} MB",
  )
  println(
    "  (compact 后 storage 含 grace 期内未回收的旧 base + deltas；live 向量面 = compact put 的新 base，",
  )
  println(
    "   旧代在 GLOBAL_GC_GRACE_MS 后由后续 ingest/compact 的 grace GC 回收)",
  )
  println(
    "  (1M: BENCH_DOCS=1000000 BENCH_QUERIES=100 moon run cmd/bench1m --target native --release)",
  )
}

///|
fn err_msg(e : Error) -> String {
  match e {
    @core.BadMagic(s) => "BadMagic(\{s})"
    @core.Truncated(s) => "Truncated(\{s})"
    @core.Corrupt(s) => "Corrupt(\{s})"
    @core.NotFound(s) => "NotFound(\{s})"
    @core.CommitConflict(s) => "CommitConflict(\{s})"
    _ => "\{e}"
  }
}

///|
async fn main {
  run() catch {
    e => println("bench1m failed: \{err_msg(e)}")
  }
}



extend CountingStore with @turbofish/store.ObjectStore::{get, list}
