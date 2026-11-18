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
//   每批写入后     : 一次 @build.maybe_cutover（IVF 重分区：num_docs/nlist >
//                    2×target_rows 时以 nlist'=ceil(num_docs/target_rows) 重训
//                    新中心、全量重写段分区并乐观 rebase 发布；cutover 批单独计）
//                    + 一次 @build.maybe_compact_segments（size-tiered 同档合并：
//                    同 tier 段数 ≥ fanout（默认 3，BENCH_FANOUT 可覆盖）时合并
//                    该档最旧 fanout 段；安全阀段数
//                    > tiers×fanout×2 退回一次前缀合并；合并批的 PUT/耗时单独计；
//                    本轮结束后 GC 回收 superseded 段）
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
//   BENCH_CONTROL=0|1      （1 = 查询走 @control.ControlPlane 复用 Namespace）
//   BENCH_NPROBE=8         （vec_search 的 nprobe；默认 8）
//   BENCH_FANOUT=3         （size-tiered 同档合并 fanout，仅测量透传；默认
//                            @build.SEGMENT_TIER_FANOUT=3，不改产品默认值）
//   BENCH_RECALL=0|1       （1 = 查询表之后追加 recall@10 vs nprobe 实验；
//                           表含「探测比例 nprobe/nlist」与「每查询实测 KB/q」两列）
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
/// 合并批合计：(puts, put_bytes, latency_ms)。
fn merge_totals(rows : Array[MergeStat]) -> (Int, Int, Double) {
  let mut puts = 0
  let mut bytes = 0
  let mut ms = 0.0
  for r in rows {
    puts += r.puts
    bytes += r.put_bytes
    ms += r.latency_ms
  }
  (puts, bytes, ms)
}

///|
/// 计量包装：SimStore 不暴露 put 字节数，这里累计成功写入的 payload 字节；
/// 其余（延迟/计费/NVMe/CAS/range/list/delete）全部原样委托，语义不变。
priv struct CountingStore {
  inner : @simstore.SimStore
  mut put_bytes : Int
  reads : Array[ReadEvent]
}

///|
/// 读事件（仅测量输出用）：key + 区间起点（off = -1 表示整对象 get）+
/// 其中计进 bytes_s3_read 的字节（NVMe/常驻命中为 0）。
/// KB/q 分解按事件事后归因，不影响读路径本身。
priv struct ReadEvent {
  key : String
  off : Int
  s3 : Int
}

///|
/// KB/q 分解桶（纯归因，不改读路径）：
/// 0=probe 分区（vec/part-* 组件与 vec/global part|pack）；1=id 列（rows/id）；
/// 2=中心表（_centroids/）；3=slab 索引（segment.slab 的 header/index 预读）；
/// 4=meta（json/manifest/head 指针）；5=other。
const BRK_PROBE : Int = 0
const BRK_IDCOL : Int = 1
const BRK_CENT : Int = 2
const BRK_SLABIDX : Int = 3
const BRK_META : Int = 4
const BRK_OTHER : Int = 5
const BRK_COUNT : Int = 6

///|
fn str_has(s : String, sub : String) -> Bool {
  s.find(sub) is Some(_)
}

///|
/// 读事件归因到分解桶。segment.slab 的区间读按区间起点命中 SlabEntry 组件名
/// 归类（组件精确 Range GET 与 entry 起点对齐）；命中不了的区间是 header/index
/// 预读 ⇒ slab 索引桶。其余按 key 语义分类。仅测量用。
fn attribute_read(
  ev : ReadEvent,
  slab_map : Map[String, Array[(Int, Int, String)]],
) -> Int {
  let key = ev.key
  if key.has_suffix(".slab") {
    let mut bucket = BRK_SLABIDX
    match slab_map.get(key) {
      Some(entries) =>
        for e in entries {
          let (off, len, name) = e
          if ev.off >= off && ev.off < off + len {
            if name.has_prefix("vec/part") ||
              name == "vector" ||
              name == "rows/vector.bin" {
              bucket = BRK_PROBE
            } else if name == "id" || name == "rows/id.bin" {
              bucket = BRK_IDCOL
            } else if name == "meta" || name == "meta.json" {
              bucket = BRK_META
            } else {
              bucket = BRK_OTHER
            }
          }
        }
      None => ()
    }
    return bucket
  }
  if str_has(key, "/_centroids/") {
    return BRK_CENT
  }
  if str_has(key, "/vec/global/") {
    return if key.has_suffix(".json") { BRK_META } else { BRK_PROBE }
  }
  if str_has(key, "vec/part-") {
    return BRK_PROBE
  }
  if str_has(key, "rows/id") {
    return BRK_IDCOL
  }
  if key.has_suffix(".json") || str_has(key, "/_meta/") ||
    str_has(key, "/_manifest/") || str_has(key, "/_head") {
    return BRK_META
  }
  BRK_OTHER
}

///|
fn CountingStore::new(seed : UInt) -> CountingStore {
  {
    inner: @simstore.SimStore::new(@simstore.SimConfig::aws_default(seed)),
    put_bytes: 0,
    reads: Array(),
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
  let b0 = self.inner.cost().bytes_s3_read
  let r = self.inner.get(key)
  let s3 = (self.inner.cost().bytes_s3_read - b0).to_int()
  self.reads.push({ key, off: -1, s3 })
  r
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
  let b0 = self.inner.cost().bytes_s3_read
  let r = self.inner.get_range(key, @store.ByteRange::{ off: offset, len: len })
  let s3 = (self.inner.cost().bytes_s3_read - b0).to_int()
  self.reads.push({ key, off: offset, s3 })
  r
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
/// 合并批单独计量（常规批只含 ingest 的 PUT；合并批 = maybe_compact_segments
/// 触发的 size-tiered 合并/安全阀前缀合并 + superseded 段 GC 的 PUT/耗时）。
priv struct MergeStat {
  batch : Int
  merges : Int
  put_bytes : Int
  puts : Int
  latency_ms : Double
  segs_before : Int
  segs_after : Int
  gc_deleted : Int
  gc_kept_in_grace : Int
}

///|
/// 逐次合并明细（批次号 + @build.SegMergeInfo 的观测口径）。
priv struct MergeDetail {
  batch : Int
  tier : Int
  segs_in : Int
  rows_in : Int
  rows_out : Int
  fallback : Bool
}

///|
/// cutover 批单独计量（常规批只含 ingest 的 PUT；cutover 批 = maybe_cutover
/// 的全量重分区：重训中心 + 重写全部段 + 乐观 rebase 发布 + superseded 段 GC）。
priv struct CutoverStat {
  batch : Int
  puts : Int
  put_bytes : Int
  latency_ms : Double
  outcome : @build.CutoverOutcome
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
  seg_count : Int
  centroid_version : String
}

///|
fn batch_row(b : BatchStat) -> String {
  "\{pad_left(b.batch.to_string(), 6)}\{pad_left(b.docs.to_string(), 8)}\{pad_left(mb(b.put_bytes), 14)}\{pad_left(b.puts.to_string(), 8)}\{pad_left(fmt(b.latency_ms, 1), 14)}\{pad_left(mb(b.storage_bytes), 16)}\{pad_left(b.seg_count.to_string(), 6)} \{pad(b.centroid_version, 26)}"
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
  ev0 : Int
  ev1 : Int
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
  // 本档测量的读事件区间（burn-in 不计入；归因在 slab 组件表建好后回填）。
  let ev_mark = store.reads.length()
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
    ev0: ev_mark,
    ev1: store.reads.length(),
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
/// 逐批 manifest 观测：(manifest.segments.length(), manifest.centroid_version)。
/// 任何一步不可用返回 (-1, "<n/a>")，不抛错（只作统计，不参与计量）。
async fn batch_manifest_info(
  store : CountingStore,
  ns : String,
) -> (Int, String) {
  let (head, _newer) = @store.read_head_state(store, ns, "")
  if head == "" {
    return (-1, "<n/a>")
  }
  let body = match store.get("\{ns}/_manifest/\{head}.json") {
    Some(bs) =>
      @utf8.decode(bs.exact_view()) catch {
        _ => return (-1, "<n/a>")
      }
    None => return (-1, "<n/a>")
  }
  let j = @json.parse(body) catch {
    _ => return (-1, "<n/a>")
  }
  let m = @format.manifest_from_json(j) catch {
    _ => return (-1, "<n/a>")
  }
  (m.segments.length(), m.centroid_version)
}

///|
/// head manifest 的 (num_docs, centroid_version)（IVF 结束态报告用）。
/// 任何一步不可用返回 (-1, "<n/a>")，不抛错。
async fn manifest_ivf_info(
  store : CountingStore,
  ns : String,
) -> (Int, String) {
  let (head, _newer) = @store.read_head_state(store, ns, "")
  if head == "" {
    return (-1, "<n/a>")
  }
  let body = match store.get("\{ns}/_manifest/\{head}.json") {
    Some(bs) =>
      @utf8.decode(bs.exact_view()) catch {
        _ => return (-1, "<n/a>")
      }
    None => return (-1, "<n/a>")
  }
  let j = @json.parse(body) catch {
    _ => return (-1, "<n/a>")
  }
  let m = @format.manifest_from_json(j) catch {
    _ => return (-1, "<n/a>")
  }
  (m.num_docs, m.centroid_version)
}

///|
/// 写入结束时的 tier 分布（每 tier 段数/行数）与段数上界（tiers × fanout）。
async fn tier_dist_lines(
  store : CountingStore,
  ns : String,
  base_rows : Int,
  fanout : Int,
) -> Array[String] {
  let out : Array[String] = Array()
  let (head, _newer) = @store.read_head_state(store, ns, "")
  if head == "" {
    out.push("<no head>")
    return out
  }
  let body = match store.get("\{ns}/_manifest/\{head}.json") {
    Some(bs) =>
      @utf8.decode(bs.exact_view()) catch {
        _ => return out
      }
    None => return out
  }
  let j = @json.parse(body) catch {
    _ => return out
  }
  let m = @format.manifest_from_json(j) catch {
    _ => return out
  }
  let tier_keys : Array[Int] = Array()
  let segs_of : Map[Int, Int] = Map([])
  let rows_of : Map[Int, Int] = Map([])
  for s in m.segments {
    let t = @build.segment_tier(s.row_count, base_rows)
    match segs_of.get(t) {
      Some(n) => {
        segs_of.set(t, n + 1)
        match rows_of.get(t) {
          Some(r) => rows_of.set(t, r + s.row_count)
          None => rows_of.set(t, s.row_count)
        }
      }
      None => {
        segs_of.set(t, 1)
        rows_of.set(t, s.row_count)
        tier_keys.push(t)
      }
    }
  }
  tier_keys.sort()
  for t in tier_keys {
    let ns_ = match segs_of.get(t) {
      Some(n) => n
      None => 0
    }
    let rows = match rows_of.get(t) {
      Some(r) => r
      None => 0
    }
    out.push(
      "tier \{pad_left(t.to_string(), 4)}: \{pad_left(ns_.to_string(), 4)} segs, \{pad_left(rows.to_string(), 8)} rows",
    )
  }
  let tiers = tier_keys.length()
  out.push(
    "tier 数 = \{tiers}，段数上界 tiers × fanout = \{tiers} × \{fanout} = \{tiers * fanout}（安全阀阈值 ×\{2} = \{tiers * fanout * 2}）",
  )
  out
}

///|
/// 逐批 segs 轨迹（≤ 60 批全量，否则前后各 15 批 + 省略段数）。
fn seg_traj(stats : Array[BatchStat]) -> String {
  let n = stats.length()
  if n == 0 {
    return "n/a"
  }
  let mut mn = stats[0].seg_count
  let mut mx = stats[0].seg_count
  for b in stats {
    if b.seg_count < mn {
      mn = b.seg_count
    }
    if b.seg_count > mx {
      mx = b.seg_count
    }
  }
  let mut s = "min=\{mn} max=\{mx} end=\{stats[n - 1].seg_count}："
  if n <= 60 {
    for i in 0..<n {
      s = s + (if i > 0 { "," } else { "" }) + stats[i].seg_count.to_string()
    }
  } else {
    for i in 0..<15 {
      s = s + (if i > 0 { "," } else { "" }) + stats[i].seg_count.to_string()
    }
    s = s + ",…(\{n - 30} 批省略)…"
    for i in (n - 15)..<n {
      s = s + "," + stats[i].seg_count.to_string()
    }
  }
  s
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
  merge_batches : Int
  merge_put_bytes : Int
  merge_puts : Int
  merge_ms : Double
  storage_before : Int
  storage_after : Int
  global_objs_before : Int
  global_objs_after : Int
  global_versions_before : Int
  global_versions_after : Int
  gen : String
}

///|
/// 等探测比例黄金锚点：旧黄金基线 nprobe=3/nlist=64 的探测比例 3/64 ≈ 0.047。
/// ANN 召回只随探测比例（nprobe/nlist）变，字节/查询 = 比例 × N × 行字节
/// （必然随 N 线性）；跨规模对齐只看等比例行。
const RECALL_RATIO_ANCHOR : Double = 0.047

///|
fn recall_ratio_anchor(nlist : Int) -> Int {
  let a = (RECALL_RATIO_ANCHOR * nlist.to_double() + 0.5).to_int()
  if a < 1 {
    1
  } else if a > nlist {
    nlist
  } else {
    a
  }
}

///|
fn arr_has(arr : Array[Int], v : Int) -> Bool {
  for x in arr {
    if x == v {
      return true
    }
  }
  false
}

///|
/// 召回实验的 nprobe 扫描点：基础 [1,2,3,4,8,16]，nlist≥64 时补 [24,32,48,64]，
/// 去掉 > nlist 的点，并保证包含 BENCH_NPROBE 与等比例锚点
/// round(RECALL_RATIO_ANCHOR × nlist)。
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
  if nprobe_cfg <= nlist && !arr_has(raw, nprobe_cfg) {
    raw.push(nprobe_cfg)
  }
  let anchor = recall_ratio_anchor(nlist)
  if anchor <= nlist && !arr_has(raw, anchor) {
    raw.push(anchor)
  }
  // nprobe > nlist 无意义；升序输出（同值只出现一次）。
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
  ratio : Double
  recall : Double
  hits : Int
  total : Int
  kb_q : Double
  getq : Double
  measured : Bool
}

///|
fn recall_row(r : RecallRow, anchor : Int) -> String {
  let mut mark = ""
  if r.measured {
    mark = mark + "  (BENCH_NPROBE, 实测 cold)"
  }
  if r.nprobe == anchor {
    mark = mark + "  ←等比例锚点 0.047"
  }
  "\{pad_left(r.nprobe.to_string(), 7)}\{pad_left(fmt(r.ratio, 4), 10)}\{pad_left(fmt(r.recall, 4), 12)}\{pad_left("\{r.hits}/\{r.total}", 10)}\{pad_left(fmt(r.kb_q, 1), 10)}\{pad_left(fmt(r.getq, 2), 10)}\{mark}"
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
/// - KB/q / GET/q：**实测**（非估算）：逐 query cold 重放（关 resident + 清
///   NVMe/区间缓存）`open + vec_search`，差分 bytes_s3_read / s3_gets；与查询表
///   cold-metadata 档同口径（KB/q = bytes_s3_read/1024）。
/// - 探测比例 = nprobe/nlist：召回只随探测比例变；跨规模对比只看等比例行
///   （锚点 RECALL_RATIO_ANCHOR = 旧黄金基线 3/64 ≈ 0.047）。
async fn run_recall(
  store : CountingStore,
  ns : String,
  vec_qvs : Array[Array[Float]],
  nq : Int,
  nprobe_cfg : Int,
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
  // 逐探测点 cold 实测：每 query 独立 open + 查询（与 cold-metadata 档同口径）。
  // resident 关闭 + 每查询前 cold()（清 NVMe/区间缓存）⇒ KB/q 不含缓存命中。
  store.inner.set_resident_enabled(false)
  let rows : Array[RecallRow] = Array(capacity=probes.length())
  for np in probes {
    let mut hits = 0
    let mut s3 = 0
    let mut gets = 0
    for i in 0..<nq {
      store.inner.cold()
      let c0 = store.inner.cost()
      let n = @query.open(store, ns)
      for r in @query.vec_search(n, vec_qvs[i], 10, np, None) {
        if gts[i].contains(r.id) {
          hits += 1
        }
      }
      let c1 = store.inner.cost()
      s3 += (c1.bytes_s3_read - c0.bytes_s3_read).to_int()
      gets += c1.s3_gets - c0.s3_gets
    }
    rows.push({
      nprobe: np,
      ratio: np.to_double() / nlist.to_double(),
      recall: hits.to_double() / (nq * 10).to_double(),
      hits,
      total: nq * 10,
      kb_q: s3.to_double() / nq.to_double() / 1024.0,
      getq: gets.to_double() / nq.to_double(),
      measured: np == nprobe_cfg,
    })
  }
  store.inner.set_resident_enabled(true)
  println("")
  println("== recall@10 vs nprobe/探测比例 (BENCH_RECALL=1) ==")
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
    "  口径:每行逐 query cold 重放（关 resident + 清 NVMe/区间）@ open+vec_search；KB/q = bytes_s3_read/1024、GET/q = s3_gets（实测非估算）；探测比例 = nprobe/nlist（召回只随探测比例变，等 nprobe 跨规模对比无意义）",
  )
  let anchor = recall_ratio_anchor(nlist)
  println(
    "  \{pad_left("nprobe", 7)}\{pad_left("探测比例", 10)}\{pad_left("recall@10", 12)}\{pad_left("hits", 10)}\{pad_left("KB/q", 10)}\{pad_left("GET/q", 10)}备注",
  )
  for r in rows {
    println(recall_row(r, anchor))
  }
  for r in rows {
    if r.nprobe == anchor {
      println(
        "等探测比例锚点 \{fmt(RECALL_RATIO_ANCHOR, 3)}（= 3/64 旧黄金基线比例）@ nprobe=\{anchor}/\{nlist}（ratio=\{fmt(r.ratio, 4)}）: recall@10=\{fmt(r.recall, 4)} KB/q=\{fmt(r.kb_q, 1)} GET/q=\{fmt(r.getq, 2)}",
      )
    }
  }
}

///|
/// 查询档位 KB/q 分解：按 ReadEvent 事后归因（s3 口径 = bytes_s3_read，与
/// KB/q 列同源）；warm 档缓存命中计 0 字节，故各行合计 ≈ KB/q 列。
fn print_breakdown(
  cells : Array[Cell],
  reads : Array[ReadEvent],
  slab_map : Map[String, Array[(Int, Int, String)]],
) -> Unit {
  println(
    "== KB/q 分解（每查询读取字节逐项归因，s3 口径；probe=vec/part-*+global part|pack，idcol=rows/id 列，cent=_centroids/ 中心表，slabidx=segment.slab header/index 预读，meta=json/manifest/head）==",
  )
  println(
    "  \{pad("class", 6)}\{pad("tier", 19)}\{pad("probe", 10)}\{pad("idcol", 10)}\{pad("cent", 10)}\{pad("slabidx", 10)}\{pad("meta", 10)}\{pad("other", 10)}\{pad("合计", 10)}KB/q列(校验)",
  )
  for c in cells {
    let buckets : Array[Double] = Array()
    for _ in 0..<BRK_COUNT {
      buckets.push(0.0)
    }
    for i in c.ev0..<c.ev1 {
      let ev = reads[i]
      let b = attribute_read(ev, slab_map)
      buckets[b] = buckets[b] + ev.s3.to_double() / 1024.0 / c.n.to_double()
    }
    let mut total = 0.0
    for v in buckets {
      total += v
    }
    println(
      "  \{pad(c.cls, 6)}\{pad(c.tier, 19)}\{pad(fmt(buckets[BRK_PROBE], 1), 10)}\{pad(fmt(buckets[BRK_IDCOL], 1), 10)}\{pad(fmt(buckets[BRK_CENT], 1), 10)}\{pad(fmt(buckets[BRK_SLABIDX], 1), 10)}\{pad(fmt(buckets[BRK_META], 1), 10)}\{pad(fmt(buckets[BRK_OTHER], 1), 10)}\{pad(fmt(total, 1), 10)}\{fmt(c.kb_s3, 1)}",
    )
  }
}

///|
/// id 列解码（SPNDCOL1 u64 列，20B 头 + u64 LE payload）。
fn decode_id_col(bs : Bytes) -> Array[UInt64] raise @core.SpndError {
  match @format.decode_col(bs) {
    @format.ColU64(a) => a
    _ => raise @core.Corrupt("id column is not u64")
  }
}

///|
/// 解析非负十进制整数（从组件名 "vec/part-{cid}" 提取 cid）；非法返回 None。
fn parse_uint(s : String) -> Int? {
  if s.length() == 0 {
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
/// vec/part-* 组件的行数（PQ/sq8/f16/f32 一律按 rows 数）。
fn part_row_count(bs : Bytes) -> Int {
  if @format.is_pq_shared_part(bs) {
    try {
      @format.decode_pq_part_shared(bs).rows.length()
    } catch {
      _ => 0
    }
  } else if @format.is_pq_part(bs) {
    try {
      @format.decode_pq_part(bs).rows.length()
    } catch {
      _ => 0
    }
  } else {
    try {
      @format.decode_part(bs).rows.length()
    } catch {
      _ => 0
    }
  }
}

///|
/// 拉取并解码某段的 SlabIndex（与 query/ 的 load_slab_index 同款探测：先 4K
/// 头预读，index 在尾部时补读 64K；仅测量用，不改读路径）。
async fn slab_index_of(
  store : CountingStore,
  key : String,
) -> @format.SlabIndex? {
  let hdr = match store.get_range(key, @store.ByteRange::{ off: 0, len: 4096 }) {
    Some(b) => b
    None => return None
  }
  let io = try {
    let (_v, o) = @format.decode_slab_header(hdr)
    o.to_int()
  } catch {
    _ => return None
  }
  if io < 0 {
    return None
  }
  if io < hdr.length() {
    let idx = try {
      Some(@format.decode_slab_index(hdr, io))
    } catch {
      _ => None
    }
    if idx is Some(_) {
      return idx
    }
  }
  let tail = match store.get_range(key, @store.ByteRange::{ off: io, len: 65536 }) {
    Some(b) => b
    None => return None
  }
  try {
    Some(@format.decode_slab_index(tail, 0))
  } catch {
    _ => None
  }
}

///|
/// manifest 活段 id 集合。只认活段：grace 期内未回收的 superseded 段仍在桶里，
/// 计进来会让组件行数/簇规模重复翻倍。
async fn live_seg_ids(store : CountingStore, ns : String) -> Set[String] {
  let out : Set[String] = Set([])
  let (head, _newver) = @store.read_head_state(store, ns, "")
  if head == "" {
    return out
  }
  let body = match store.get("\{ns}/_manifest/\{head}.json") {
    Some(bs) => bs
    None => return out
  }
  let text = @utf8.decode(body.exact_view()) catch {
    _ => return out
  }
  let j = @json.parse(text) catch {
    _ => return out
  }
  let m = @format.manifest_from_json(j) catch {
    _ => return out
  }
  for s in m.segments {
    out.add(s.id)
  }
  out
}

///|
/// segment.slab 组件表：key → [(off, len, name)]。仅测量归因用；只收 manifest
/// 活段（superseded 段会让行数/簇规模重复计数）。
async fn build_slab_map(
  store : CountingStore,
  ns : String,
) -> Map[String, Array[(Int, Int, String)]] {
  let map : Map[String, Array[(Int, Int, String)]] = Map([])
  let live = live_seg_ids(store, ns)
  let prefix = "\{ns}/_segments/"
  for key in store.list(prefix) {
    if !key.has_suffix(".slab") {
      continue
    }
    if live.length() > 0 {
      if !live.contains(seg_id_of_key(key, ns)) {
        continue
      }
    }
    match slab_index_of(store, key) {
      Some(idx) => {
        let out : Array[(Int, Int, String)] = Array()
        for e in idx.entries {
          out.push((e.offset.to_int(), e.length.to_int(), e.name))
        }
        map.set(key, out)
      }
      None => ()
    }
  }
  map
}

///|
/// 从 segment.slab key 提取段 id：`{ns}/_segments/{seg_id}/segment.slab`。
fn seg_id_of_key(key : String, ns : String) -> String {
  let prefix = "\{ns}/_segments/"
  let rest = key[prefix.length():].to_owned()
  rest[0:rest.length() - "/segment.slab".length()].to_owned()
}

///|
/// 段是否 dense_u64（meta.json 的 id_encoding 标记；dense 段读侧 row→id =
/// min_id+row，id 组件不进查询读）。仅测量用。
async fn seg_is_dense(
  store : CountingStore,
  ns : String,
  seg_id : String,
) -> Bool {
  match store.get("\{ns}/_segments/\{seg_id}/meta.json") {
    Some(bs) => {
      let text = @utf8.decode(bs.exact_view()) catch {
        _ => return false
      }
      str_has(text, "\"dense_u64\"")
    }
    None => false
  }
}

///|
/// KB/q 静态分解支撑数据（一次只读扫描 slab 组件）：
/// - 簇规模分布（cid → 跨段 rows 之和）：max/mean、E[s²]/E[s]、行字节；
///   balanced k-means（簇等大小）把每 probe 字节从 size 偏置期望压到 mean×行字节。
/// - id 列 runs 数：空洞合并段（合并非相邻 id 段）的行数/runs 数，估计
///   runs 编码 (min_id u64, start_row u32, len u32) 的残余字节。
async fn static_decomposition(
  store : CountingStore,
  ns : String,
  slab_map : Map[String, Array[(Int, Int, String)]],
) -> Unit {
  let cid_rows : Map[Int, Int] = Map([])
  let mut part_rows = 0
  let mut part_bytes = 0
  let mut id_rows = 0
  let mut id_runs = 0
  let mut id_bytes = 0
  let mut dense_id_rows = 0
  let mut dense_id_bytes = 0
  for kv in slab_map.iter() {
    let (key, entries) = kv
    for e in entries {
      let (off, len, name) = e
      if name == "id" || name == "rows/id.bin" {
        match store.get_range(key, @store.ByteRange::{ off: off, len: len }) {
          Some(bs) => {
            let ids = try {
              Some(decode_id_col(bs))
            } catch {
              _ => None
            }
            match ids {
              Some(arr) => {
                let seg_id = seg_id_of_key(key, ns)
                if seg_is_dense(store, ns, seg_id) {
                  // dense_u64 段：读侧 row→id = min_id+row，id 组件不进查询读。
                  dense_id_rows += arr.length()
                  dense_id_bytes += len
                } else {
                  id_rows += arr.length()
                  id_bytes += len
                  let mut prev = 0UL
                  for i in 0..<arr.length() {
                    let v = arr[i]
                    if i == 0 || v != prev + 1UL {
                      id_runs += 1
                    }
                    prev = v
                  }
                }
              }
              None => ()
            }
          }
          None => ()
        }
      } else if name.has_prefix("vec/part") {
        match store.get_range(key, @store.ByteRange::{ off: off, len: len }) {
          Some(bs) => {
            part_bytes += len
            let rows = part_row_count(bs)
            part_rows += rows
            match parse_uint(name[9:].to_owned()) {
              Some(cid) =>
                match cid_rows.get(cid) {
                  Some(v) => cid_rows.set(cid, v + rows)
                  None => cid_rows.set(cid, rows)
                }
              None => ()
            }
          }
          None => ()
        }
      }
    }
  }
  let mut ncid = 0
  let mut s_max = 0
  let mut s_sum = 0
  let mut s_sq = 0.0
  for kv in cid_rows.iter() {
    let (_cid, s) = kv
    ncid += 1
    s_sum += s
    if s > s_max {
      s_max = s
    }
    s_sq += s.to_double() * s.to_double()
  }
  println("== KB/q 静态分解（组件大小/簇分布/id runs；只读扫描，非每查询口径）==")
  if ncid > 0 && part_rows > 0 {
    let mean = s_sum.to_double() / ncid.to_double()
    let size_biased = s_sq / s_sum.to_double() // E[s²]/E[s]
    let rowb = part_bytes.to_double() / part_rows.to_double()
    println(
      "  簇规模分布:有行 cid=\{ncid} 总 rows=\{part_rows} mean=\{fmt(mean, 1)} max=\{s_max} max/mean=\{fmt(s_max.to_double() / mean, 2)} E[s²]/E[s]=\{fmt(size_biased, 1)}",
    )
    println(
      "  part 行字节 = \{fmt(rowb, 1)}（rows u32 + payload 实测均值）；probe 分区每 probe 字节:均匀探测 = mean×rowb = \{fmt(mean * rowb, 0)} B；size 偏置（查询落大簇）≈ E[s²]/E[s]×rowb = \{fmt(size_biased * rowb, 0)} B",
    )
    println(
      "  balanced k-means（簇等大小）理论:每 probe 字节从 \{fmt(size_biased * rowb, 0)} B 压到 \{fmt(mean * rowb, 0)} B（≈\{fmt(size_biased / mean, 2)}x）",
    )
  } else {
    println("  簇规模分布:无 vec/part-* 组件（数据不在这条路径）")
  }
  if id_rows > 0 {
    println(
      "  id 列（非 dense 空洞合并段，逐查询必读）: rows=\{id_rows} runs=\{id_runs} 现 u64 定长（8 B/row + 20B 头）实测 = \{fmt(id_bytes.to_double() / 1024.0, 1)} KB/查询（另 dense 段 id 组件 \{fmt(dense_id_bytes.to_double() / 1024.0, 1)} KB/\{dense_id_rows} rows，读侧免读）",
    )
    println(
      "  runs 编码 (min_id u64, start_row u32, len u32) 16 B/run = \{fmt(id_runs.to_double() * 16.0 / 1024.0, 1)} KB/查询（压 \{fmt(id_bytes.to_double() / (id_runs.to_double() * 16.0), 1)}x）",
    )
  } else {
    println("  id 列:无非 dense id 列（全部 dense_u64 或无 rows/id 组件）")
  }
}

///|
async fn run() -> Unit {
  let docs_n = env_int("BENCH_DOCS", 50000)
  let dim = env_int("BENCH_DIM", 128)
  let batch_size = env_int("BENCH_BATCH", 1000)
  let nq = env_int("BENCH_QUERIES", 20)
  let seed = env_int("BENCH_SEED", 7)
  // 写路径：legacy（ingest + ingest_delta_opts，历史多对象写）或 slab（serve 线上路径）。
  let write_slab = env_int("BENCH_WRITE_SLAB", 0) != 0
  // 同理：BENCH_CONTROL 默认 0（关）；!0 即开启 ControlPlane 复用 Namespace。
  let bench_control = env_int("BENCH_CONTROL", 0) != 0
  let nprobe = env_int("BENCH_NPROBE", 8)
  // size-tiered 合并 fanout：仅 bench 测量透传给 @build.maybe_compact_segments；
  // 缺省/非法值回退产品默认 @build.SEGMENT_TIER_FANOUT（=3）。
  let fanout = env_int("BENCH_FANOUT", @build.SEGMENT_TIER_FANOUT)
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
  if write_slab {
    println("write path: 每批 ingest_l0_slab（serve 线上路径，单对象 slab），then 1x compact_global")
  } else {
    println(
      "write path: batch0=ingest, batch1..=ingest_delta_opts(max_deltas=0, auto_compact=false), then 1x compact_global",
    )
  }
  println(
    "  每批写入后 @build.maybe_compact_segments：size-tiered 同档合并（同 tier 段数 ≥ fanout=\{fanout} 时合并该档最旧 \{fanout} 段；合并批单独计）+ superseded 段 GC",
  )
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
  // 合并批单独计量 + superseded 段 GC 观测（(seg_id, 被合并时刻)）。
  let merge_rows : Array[MergeStat] = Array()
  let merge_details : Array[MergeDetail] = Array()
  // cutover 批单独计量（常规批 PUT 不含 cutover 开销）。
  let cutover_rows : Array[CutoverStat] = Array()
  let superseded_log : Array[(String, UInt64)] = Array()
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
    if write_slab {
      let _ = @build.ingest_l0_slab(store, cfg, docs, [])
    } else if stats.is_empty() {
      @build.ingest(store, cfg, docs)
    } else {
      // 禁自动合并：链长由 bench 自己控制，最后一次性 compact_global。
      @build.ingest_delta_opts(store, cfg, docs, 0, false)
    }
    let snap = store.inner.cost()
    let put_bytes = store.put_bytes
    let batch_us = snap.total_latency_us
    // IVF 重分区（cutover）：触发批单独计量（常规批 PUT 不含 cutover 开销）。
    // 在段压力合并之前跑：cutover 全量重写所有段，先合并再 cutover 会白费
    // 合并写放大；cutover 产出的 segment_rows 小段由紧随其后的合并收拢。
    // superseded 时刻取 cutover 前（同合并的口径，判定只会偏安全）。
    let cut_at = @env.now()
    store.reset_writes()
    store.inner.reset_cost()
    let cut = @build.maybe_cutover(store, cfg)
    let cusnap = store.inner.cost()
    match cut {
      Some(o) => {
        for id in o.superseded {
          superseded_log.push((id, cut_at))
        }
        cutover_rows.push({
          batch: stats.length() + 1,
          puts: cusnap.puts,
          put_bytes: store.put_bytes,
          latency_ms: cusnap.total_latency_us / 1000.0,
          outcome: o,
        })
      }
      None => ()
    }
    // 段数压力触发的前缀合并（单独计量：合并批的 PUT/耗时不混进常规批）。
    // superseded 时刻取合并前（≤ 最后引用该段的 manifest 时刻），保证
    // 「grace 期内旧段数」的口径 ⊇ GC 的保留口径（判定只会偏安全）。
    let superseded_at = @env.now()
    store.reset_writes()
    store.inner.reset_cost()
    let outcome = @build.maybe_compact_segments(store, cfg, fanout=fanout)
    let msnap = store.inner.cost()
    if outcome.merges > 0 {
      for info in outcome.merge_log {
        merge_details.push({
          batch: stats.length() + 1,
          tier: info.tier,
          segs_in: info.segs_in,
          rows_in: info.rows_in,
          rows_out: info.rows_out,
          fallback: info.prefix_fallback,
        })
      }
      for id in outcome.superseded {
        superseded_log.push((id, superseded_at))
      }
      merge_rows.push({
        batch: stats.length() + 1,
        merges: outcome.merges,
        put_bytes: store.put_bytes,
        puts: msnap.puts,
        latency_ms: msnap.total_latency_us / 1000.0,
        segs_before: outcome.segs_before,
        segs_after: outcome.segs_after,
        gc_deleted: outcome.gc_deleted,
        gc_kept_in_grace: outcome.gc_kept_in_grace,
      })
    }
    // 逐批 manifest 观测（段数 / centroid_version，供后续步骤断言）。只读且
    // 放在计量快照之后：不计入本批 puts/延迟，下一批开头的 reset 清掉这批 GET。
    let (seg_count, centroid_version) = batch_manifest_info(store, ns)
    stats.push({
      batch: stats.length() + 1,
      docs: take,
      put_bytes,
      puts: snap.puts,
      latency_ms: batch_us / 1000.0,
      storage_bytes: snap.storage_bytes,
      seg_count,
      centroid_version,
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
  let storage_after = csnap.storage_bytes

  // ---- 逐批表（批次数多时省略中段）----
  println(
    pad("batch", 6) +
    pad("docs", 8) +
    pad_left("put MB", 14) +
    pad_left("puts", 8) +
    pad_left("virt ms", 14) +
    pad_left("storage MB", 16) +
    pad_left("segs", 6) +
    pad(" centroid_version", 26),
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
  // ---- 合并批表（段数 > 8 触发的前缀合并 + superseded 段 GC，单独计）----
  if merge_rows.is_empty() {
    println("merge batches      = none（未触发 size-tiered 合并）")
  } else {
    println(
      "merge batches（常规批 PUT 不含下列合并开销；每行 = 该批写入后的 maybe_compact_segments：size-tiered 同档合并/安全阀前缀合并 + superseded 段 GC）:",
    )
    println(
      pad("batch", 6) + pad("merges", 8) + pad_left("put MB", 14) +
      pad_left("puts", 8) + pad_left("virt ms", 14) + pad(" segs", 14) +
      pad("gc(del/keep)", 14),
    )
    for r in merge_rows {
      let segs = "\{r.segs_before} -> \{r.segs_after}"
      let gc = "\{r.gc_deleted}/\{r.gc_kept_in_grace}"
      println(
        "\{pad_left(r.batch.to_string(), 6)}\{pad_left(r.merges.to_string(), 8)}\{pad_left(mb(r.put_bytes), 14)}\{pad_left(r.puts.to_string(), 8)}\{pad_left(fmt(r.latency_ms, 1), 14)}\{pad(segs, 14)}\{pad(gc, 14)}",
      )
    }
    let (mt_puts, mt_bytes, mt_ms) = merge_totals(merge_rows)
    println(
      "merge total        = \{merge_rows.length()} 合并批, \{mt_puts} PUTs, \{mb(mt_bytes)} MB, virt \{fmt(mt_ms, 1)} ms",
    )
  }
  // ---- 逐次合并明细（tier / 输入段数 / 输入行 → 输出行）----
  if !merge_details.is_empty() {
    println("merge detail（每次合并：tier / 输入段数 / 输入行 → 输出行）:")
    println(
      pad("batch", 6) + pad("kind", 8) + pad_left("tier", 6) +
        pad_left("segs_in", 9) + pad_left("rows_in", 12) +
        pad_left("rows_out", 12),
    )
    let mut rows_in_total = 0
    let mut rows_out_total = 0
    for d in merge_details {
      let kind = if d.fallback { "prefix" } else { "tiered" }
      rows_in_total += d.rows_in
      rows_out_total += d.rows_out
      println(
        "\{pad_left(d.batch.to_string(), 6)}\{pad(kind, 8)}\{pad_left(d.tier.to_string(), 6)}\{pad_left(d.segs_in.to_string(), 9)}\{pad_left(d.rows_in.to_string(), 12)}\{pad_left(d.rows_out.to_string(), 12)}",
      )
    }
    println(
      "merge rows total   = \{merge_details.length()} 次合并, 输入 \{rows_in_total} rows, 输出 \{rows_out_total} rows（写入放大分子）",
    )
  }
  println("")
  // ---- cutover 批（IVF 全量重分区；常规批 PUT 不含下列开销）----
  println(
    "== cutover（IVF 重分区；每批之后 maybe_cutover；触发条件 num_docs/nlist > 2×target_rows）==",
  )
  if cutover_rows.is_empty() {
    println("cutover batches   = none（未触发重分区）")
  } else {
    println(
      "cutover batches（常规批 PUT 不含下列开销；每行 = 该批的 maybe_cutover：重训中心 + 全段重写 + 乐观 rebase 发布 + superseded 段 GC）:",
    )
    println(
      pad("batch", 6) + pad("nlist", 13) + pad_left("target", 8) +
        pad_left("rows", 10) + pad("segs", 13) + pad_left("puts", 8) +
        pad_left("put MB", 12) + pad_left("virt ms", 12) +
        pad_left("cent KB", 10) + pad_left("tries", 7) + pad("gc(del/keep)", 14),
    )
    for r in cutover_rows {
      let o = r.outcome
      let nlist_s = "\{o.nlist_old} -> \{o.nlist_new}"
      let segs_s = "\{o.segs_in} -> \{o.segs_out}"
      let gc_s = "\{o.gc_deleted}/\{o.gc_kept_in_grace}"
      println(
        "\{pad_left(r.batch.to_string(), 6)}\{pad(nlist_s, 13)}\{pad_left(o.target_rows.to_string(), 8)}\{pad_left(o.rows.to_string(), 10)}\{pad(segs_s, 13)}\{pad_left(r.puts.to_string(), 8)}\{pad_left(mb(r.put_bytes), 12)}\{pad_left(fmt(r.latency_ms, 1), 12)}\{pad_left(fmt(o.centroid_bytes.to_double() / 1024.0, 1), 10)}\{pad_left(o.attempts.to_string(), 7)}\{pad(gc_s, 14)}",
      )
    }
    let mut cut_puts = 0
    let mut cut_bytes = 0
    let mut cut_ms = 0.0
    let mut cut_rows = 0
    for r in cutover_rows {
      cut_puts += r.puts
      cut_bytes += r.put_bytes
      cut_ms += r.latency_ms
      cut_rows += r.outcome.rows
    }
    println(
      "cutover total     = \{cutover_rows.length()} 次, \{cut_puts} PUTs, \{mb(cut_bytes)} MB, virt \{fmt(cut_ms, 1)} ms, 重写 \{cut_rows} rows（cutover 批口径，不含后续段合并）",
    )
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
  // ---- KB/q 分解（读事件事后归因；slab 组件表在全部查询计量之后才建，不污染计量）----
  let slab_map = build_slab_map(store, ns)
  print_breakdown(cells, store.reads, slab_map)
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
  // 探测比例的分母必须是**实际中心数**（cutover 结束态），不是 cfg 初始值：
  // cutover 把 nlist 重设为 ≈num_docs/target_rows（50k→129，500k→1059），
  // 用 cfg.nlist=64 会把比例与锚点算错，GT 也不是全扫。
  let (_rec_docs, rec_cv) = manifest_ivf_info(store, ns)
  let rec_cent : @format.Centroids? = try {
    Some(@build.load_centroids(store, ns, rec_cv))
  } catch {
    _ => None
  }
  let rec_nlist = match rec_cent {
    Some(c) => if c.dim > 0 && c.k() > 0 { c.k() } else { nlist }
    None => nlist
  }
  if bench_recall {
    run_recall(
      store, ns, vec_qvs, nq, nprobe, rec_nlist, exact_gt, gt_ids, gt_vecs,
      dim,
    )
  }
  // ---- KB/q 分解支撑数据（组件大小/簇分布/id runs；只读扫描）----
  static_decomposition(store, ns, slab_map)
  println("")

  // ---- 汇总（manifest/LIST 放在查询之后，避免预热缓存影响查询档位）----
  let (merge_puts_total, merge_bytes_total, merge_ms_total) = merge_totals(merge_rows)
  let summary : BuildSummary = {
    docs: docs_done,
    batches: stats.length(),
    put_bytes: put_bytes_total,
    puts: puts_total,
    build_ms: build_us / 1000.0,
    compact_put_bytes: compact_put,
    compact_ms,
    merge_batches: merge_rows.length(),
    merge_put_bytes: merge_bytes_total,
    merge_puts: merge_puts_total,
    merge_ms: merge_ms_total,
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
  // total put / write_amp 含：逐批写入 + 合并批（前缀合并 + 段 GC）+ compact_global。
  let total_put = s.put_bytes + s.merge_put_bytes + s.compact_put_bytes
  let total_ms = s.build_ms + s.merge_ms + s.compact_ms
  println("== summary ==")
  println("total docs           = \{s.docs} (dim=\{dim}, batches=\{s.batches})")
  println(
    "tier fanout          = \{fanout} (BENCH_FANOUT 透传 maybe_compact_segments；产品默认 @build.SEGMENT_TIER_FANOUT=\{@build.SEGMENT_TIER_FANOUT})",
  )
  println(
    "build put            = \{mb(s.put_bytes)} MB (\{s.put_bytes} bytes, \{s.puts} PUTs, virt \{fmt(s.build_ms, 1)} ms)",
  )
  println(
    "merge put            = \{mb(s.merge_put_bytes)} MB (\{s.merge_puts} PUTs, virt \{fmt(s.merge_ms, 1)} ms) (\{s.merge_batches} 合并批)",
  )
  println(
    "compact put          = \{mb(s.compact_put_bytes)} MB (\{s.compact_put_bytes} bytes, virt \{fmt(s.compact_ms, 1)} ms)",
  )
  println(
    "total put            = \{mb(total_put)} MB (\{total_put} bytes; build+merge+compact_global; virt total \{fmt(total_ms, 1)} ms)",
  )
  println(
    "write_amp            = \{fmt(total_put.to_double() / vector_bytes.to_double(), 2)}x vector_bytes (f16 \{mb(vector_bytes)} MB)",
  )
  println(
    "write_amp (build)    = \{fmt(s.put_bytes.to_double() / vector_bytes.to_double(), 2)}x (excl. merge & final compact)",
  )
  println(
    "global objects       = before compact \{s.global_objs_before}, after compact \{s.global_objs_after} (list(\{ns}/vec/global/)，含 grace 期内旧代)",
  )
  println(
    "global versions      = before compact \{s.global_versions_before}, after compact \{s.global_versions_after} (live=1 代：global_gen=None)",
  )
  println("manifest             = \{s.gen}")
  println(
    "  (每批写入后的段数压力合并走 @build.maybe_compact_segments → compact_optimistic（size-tiered 同档合并 + 安全阀前缀合并）；compact_global 在 slab 写路径下恒 no-op)",
  )
  println(
    "storage bytes        = before compact \{mb(s.storage_before)} MB -> after compact \{mb(s.storage_after)} MB",
  )
  println(
    "  (compact 后 storage 含 grace 期内未回收的旧 base + deltas；live 向量面 = compact put 的新 base，",
  )
  println(
    "   旧代在 GLOBAL_GC_GRACE_MS 后由后续 ingest/compact 的 grace GC 回收)",
  )
  // ---- IVF 分区规模（cutover 结束态；判据：nlist 与 num_docs/target_rows 偏差 ≤ 2x）----
  let (end_docs, end_cv) = manifest_ivf_info(store, ns)
  let end_cent : @format.Centroids? = try {
    Some(@build.load_centroids(store, ns, end_cv))
  } catch {
    _ => None
  }
  let end_k = match end_cent {
    Some(c) => if c.dim > 0 { c.k() } else { 0 }
    None => 0
  }
  let cent_bytes = @build.centroid_table_bytes(store, ns, end_cv)
  let target_end = @build.cutover_target_rows(cfg, end_docs, dim)
  let want_k = if target_end > 0 && end_docs > 0 {
    (end_docs + target_end - 1) / target_end
  } else {
    0
  }
  let dev = if end_k > 0 && want_k > 0 {
    let a = end_k.to_double() / want_k.to_double()
    let b = want_k.to_double() / end_k.to_double()
    if a > b {
      a
    } else {
      b
    }
  } else {
    0.0
  }
  let target_src = if cfg.target_rows > 0 {
    "BuildConfig.target_rows 覆盖值"
  } else {
    "target_rows_for(num_docs, dim, nprobe=\{@build.CUTOVER_NPROBE}) 公式值"
  }
  let dev_v = if dev <= 2.0 {
    "≤ 2x ✓"
  } else {
    "> 2x ✗"
  }
  println("== IVF 分区规模（cutover 结束态）==")
  println("target_rows        = \{target_end}（\{target_src}）")
  println(
    "nlist              = \{end_k}（centroid_version=\{end_cv}）；num_docs/target_rows = \{fmt(want_k.to_double(), 1)}，偏差 \{fmt(dev, 2)}x \{dev_v}",
  )
  println("中心表字节         = \{cent_bytes}（\{end_k} 中心 × \{dim} 维 f32 + 头）")
  println(
    "cutover 触发次数   = \{cutover_rows.length()}（每批之后 maybe_cutover；阈值 num_docs/nlist > 2×target_rows）",
  )
  println("")
  // ---- size-tiered 段分布与段数轨迹（写入结束时点；只读 GET 放查询之后）----
  println("== size-tiered 段分布（写入结束时点）==")
  for line in tier_dist_lines(store, ns, cfg.segment_rows, fanout) {
    println("\{line}")
  }
  println("segs 轨迹（逐批）   = \{seg_traj(stats)}")
  // ---- superseded 段 GC 计数（50k 档结束时点；只读 LIST/GET 放查询之后）----
  let seg_prefix = "\{ns}/_segments/"
  let dir_seen : Set[String] = Set([])
  for key in store.list(seg_prefix) {
    if key.has_prefix(seg_prefix) {
      let rest = key[seg_prefix.length():]
      match rest.find("/") {
        Some(i) => {
          let id = rest[:i].to_owned()
          if id.has_prefix(@build.SLAB_SEG_PREFIX + "-") {
            dir_seen.add(id)
          }
        }
        None => ()
      }
    }
  }
  let (segs_end, _cv) = batch_manifest_info(store, ns)
  let now_ms = @env.now()
  let grace_ms = @build.SEGMENT_GC_GRACE_MS
  let mut in_grace = 0
  let mut gc_deleted_total = 0
  for kv in superseded_log {
    let (_id, t) = kv
    if t + grace_ms > now_ms {
      in_grace += 1
    }
  }
  for r in merge_rows {
    gc_deleted_total += r.gc_deleted
  }
  let dirs = dir_seen.length()
  let verdict = if dirs <= segs_end + in_grace {
    "OK"
  } else {
    "VIOLATION"
  }
  println("== superseded 段 GC（50k 档结束时点）==")
  println("slabseg-* 目录数     = \{dirs}（桶里 _segments/ 下的 slabseg 段目录）")
  println("live 段数            = \{segs_end}（manifest.segments.length()）")
  println(
    "grace 期内旧段数     = \{in_grace}（被合并掉 < \{grace_ms / 1000UL}s 的旧段；GC 保留，宽限在途读者）",
  )
  println(
    "GC 判定              = \{verdict}（要求：slabseg-* 目录数 ≤ live 段数 + grace 期内旧段数）",
  )
  println(
    "GC 累计              = 合并路径回收 \{gc_deleted_total} 个 superseded 段目录（grace 到期后删段 slab + meta.json + vec/part-* 等全部对象）",
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



extend CountingStore with @turbofish/store.ObjectStore::{get, get_range, list}
