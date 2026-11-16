// delta_bench：global IVF「全量重写」vs「delta 链」的写字节对照（SimStore 计量）。
//
// 这不是查询基准，只做 10 批 ingest 的写放大（write amplification）对照：
//   full  : 每批 @build.ingest(store, cfg, batch)
//           ⇒ 每次把整个 namespace 的 global parts 重写一遍（O(n²) 累计写字节）
//   delta : 首批 @build.ingest + 后续每批 @build.ingest_delta
//           ⇒ 每批只写本批新段的 global parts（+ 阈值触发的 compact_global）
//
// 计量口径（每批前 reset，批后读）：
//   put_bytes    本轮 put/put_if_match **成功写入**的 payload 字节（= S3 PUT 写字节）
//   puts         本轮 PUT 请求数（含 CAS，来自 SimSnapshot.puts）
//   total_bytes  批后 SimStore 里全部对象的存活字节（cost().storage_bytes，
//                含 grace 期内尚未 GC 的旧 global 代）
//   global_objs  list("{ns}/vec/global/") 的对象数（= 各代 part + meta）
//
// 注 1：SimSnapshot 没有 put_bytes 字段（只有 puts 次数 / storage_bytes），且本任务
// 不允许改 simstore/，所以这里用一层 `CountingStore` 薄包装累计 put 字节，其余
// 全部原样委托给 SimStore（延迟、费用、NVMe 写透、CAS 版本语义都不变）。
// 注 2：LIST 会产生 LIST 费用，所以 global_objs 的 list() 一律放在 cost() 快照之后，
// 不污染本轮的写字节/PUT 计数。
// 注 3：head manifest 用公开 API @store.read_head_state（_heads/ 字典序最大）
// + @format.manifest_from_json 读，不新增 @build 公开 API、不碰包内私有函数。
//
// 运行：
//   moon run cmd/delta_bench --target native --release
//   SIM_DELTA_BATCHES=10 SIM_DELTA_DOCS=2000 moon run cmd/delta_bench --target native --release
// 默认 5 批 × 1000 docs（名义配置 10 × 2000，可用上面两个 env 复现），
// 保证整轮 < 3 分钟。

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
  } else {
    1000.0
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
/// 计量包装：SimStore 不暴露 put 字节数，这里累计成功写入的 payload 字节。
/// 延迟/计费/NVMe 写透/CAS 版本语义全部由 inner SimStore 负责，包装不改变语义。
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
    // CAS 失败不落字节（真 S3 只产生一次失败请求，不产生新数据字节）。
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
/// 确定性生成 n 条 docs（同 seed ⇒ 两个策略吃完全相同的输入）。
fn make_docs(n : Int, dim : Int) -> Array[@core.Doc] {
  let rng = @core.Rng::new(4242U)
  let words : Array[String] = [
    "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "index", "search",
    "vector", "object", "storage", "latency",
  ]
  let docs : Array[@core.Doc] = Array(capacity=n)
  for i in 0..<n {
    let v : Array[Float] = Array(capacity=dim)
    for _ in 0..<dim {
      v.push(Float::from_double(rng.next_range(-1.0, 1.0)))
    }
    let mut text = ""
    let nw = 6 + rng.next_range(0.0, 6.0).to_int()
    for j in 0..<nw {
      let w = words[rng.next_range(0.0, words.length().to_double()).to_int()]
      if j > 0 {
        text = text + " "
      }
      text = text + w
    }
    docs.push({
      id: 1000UL + i.to_uint64(),
      text,
      vector: v,
      category: "cat\{i % 3}",
      ts: (1700000000 + i).to_int64(),
      public: i % 3 != 0,
    })
  }
  docs
}

///|
/// 单批切片的浅拷贝（docs 是只读输入，浅拷贝足够）。
fn batch_slice(
  all : Array[@core.Doc],
  start : Int,
  n : Int,
) -> Array[@core.Doc] {
  let out : Array[@core.Doc] = Array(capacity=n)
  for i in 0..<n {
    out.push(all[start + i])
  }
  out
}

///|
/// 单批计量结果（两个策略各一条，按 batch 对齐打印）。
priv struct BatchStat {
  batch : Int
  put_bytes : Int
  puts : Int
  total_bytes : Int
  global_objs : Int
  gen_base : String // "" = manifest 无 global_gen（单代全量 base）
  gen_deltas : Int
  // 本批由 maybe_compact_global 把链压成新 base：compact_global 的新 manifest
  // 同时是 vec_global_version（新 base 代）；正常 delta 路径两者必然不等。
  compacted : Bool
}

///|
/// 读 head manifest：head 用公开的 @store.read_head_state 取 _heads/ 最大 id，
/// manifest JSON 用公开 @format.manifest_from_json 解析（不改 build 的私有 API）。
async fn read_head_manifest(
  store : CountingStore,
  ns : String,
) -> @format.ManifestData? {
  let (head, _newer) = @store.read_head_state(store, ns, "")
  if head == "" {
    return None
  }
  let key = "\{ns}/_manifest/\{head}.json"
  match store.get(key) {
    Some(bs) => {
      let s = @utf8.decode(bs.exact_view()) catch {
        _ => raise @core.Corrupt("manifest is not utf8: \{key}")
      }
      let j = @json.parse(s) catch {
        _ => raise @core.Corrupt("manifest is not json: \{key}")
      }
      Some(@format.manifest_from_json(j))
    }
    None => raise @core.NotFound(key)
  }
}

///|
fn make_cfg(ns : String) -> @build.BuildConfig {
  // single_copy：global IVF 单副本 + normalize_vecs + fts bloom（delta 路径的前提）。
  let base = @build.BuildConfig::single_copy(ns)
  { ..base, segment_rows: 500, nlist: 8, vector_dim: 64, use_f16: true }
}

///|
/// 跑一个策略的全部批次，返回逐批计量。
/// `full=true` 每批都全量 ingest；`full=false` 首批 ingest，后续 ingest_delta。
async fn run_strategy(
  full : Bool,
  ns : String,
  batches : Int,
  docs_per_batch : Int,
  all_docs : Array[@core.Doc],
) -> Array[BatchStat] {
  let store = CountingStore::new(4242U)
  let cfg = make_cfg(ns)
  let stats : Array[BatchStat] = Array(capacity=batches)
  for b in 0..<batches {
    let docs = batch_slice(all_docs, b * docs_per_batch, docs_per_batch)
    store.reset_writes()
    store.inner.reset_cost()
    if full || b == 0 {
      @build.ingest(store, cfg, docs)
    } else {
      @build.ingest_delta(store, cfg, docs)
    }
    // 先取快照（延迟/费用/PUT 数/存活字节），再做 LIST 统计 global 对象数。
    let snap = store.inner.cost()
    let put_bytes = store.put_bytes
    let total_bytes = snap.storage_bytes
    let global_objs = store.list("\{ns}/vec/global/").length()
    let head = read_head_manifest(store, ns)
    let (gen_base, gen_deltas, is_compact_base) = match head {
      Some(m) => {
        let (b, ds) = match m.global_gen {
          Some(g) => (g.base, g.deltas.length())
          None => ("", 0)
        }
        let compact_base = match m.vec_global_version {
          Some(v) => v == m.id
          None => false
        }
        (b, ds, compact_base)
      }
      None => ("", 0, false)
    }
    let compacted = !full && b > 0 && is_compact_base
    stats.push({
      batch: b + 1,
      put_bytes,
      puts: snap.puts,
      total_bytes,
      global_objs,
      gen_base,
      gen_deltas,
      compacted,
    })
  }
  stats
}

///|
fn row(i : Int, f : BatchStat, d : BatchStat) -> String {
  let chain = if d.compacted {
    "compacted -> new base"
  } else if d.gen_base == "" {
    "base (single)"
  } else {
    "base+\{d.gen_deltas}d"
  }
  "\{pad_left(i.to_string(), 6)}\{pad_left(mb(f.put_bytes), 14)}\{pad_left(mb(d.put_bytes), 14)}\{pad_left(f.global_objs.to_string(), 12)}\{pad_left(d.global_objs.to_string(), 12)}\{pad_left(mb(f.total_bytes), 14)}\{pad_left(mb(d.total_bytes), 14)}  \{chain}\{if d.compacted { " (compact)" } else { "" }}"
}

///|
fn sum_put(stats : Array[BatchStat]) -> Int {
  let mut total = 0
  for s in stats {
    total += s.put_bytes
  }
  total
}

///|
fn sum_puts(stats : Array[BatchStat]) -> Int {
  let mut total = 0
  for s in stats {
    total += s.puts
  }
  total
}

///|
fn compaction_batches(stats : Array[BatchStat]) -> String {
  let hits : Array[String] = Array()
  for s in stats {
    if s.compacted {
      hits.push(s.batch.to_string())
    }
  }
  if hits.is_empty() {
    "none"
  } else {
    hits.join(",")
  }
}

///|
async fn run() -> Unit {
  // 名义配置是 10 批 × 2000 docs（dim=64 / segment_rows=500 / nlist=8）；
  // 默认跑 5 × 1000 以控制运行时（< 3 分钟），可用 env 覆盖回名义配置。
  let batches = env_int("SIM_DELTA_BATCHES", 5)
  let docs_per_batch = env_int("SIM_DELTA_DOCS", 1000)
  let dim = 64
  let all_docs = make_docs(batches * docs_per_batch, dim)
  let vector_bytes = batches * docs_per_batch * dim * 2 // f16 ⇒ 2 字节/维

  println("== simstore write-amplification: global IVF full rewrite vs delta chain ==")
  println(
    "batches=\{batches} docs_per_batch=\{docs_per_batch} dim=\{dim} segment_rows=500 nlist=8 use_f16=true",
  )
  println(
    "vector payload (f16) = \{mb(vector_bytes)} MB; put bytes = successful put/put_if_match payload",
  )
  println("")

  let full_stats = run_strategy(true, "delta-bench-full", batches, docs_per_batch, all_docs)
  let delta_stats = run_strategy(false, "delta-bench-delta", batches, docs_per_batch, all_docs)

  println(
    pad("batch", 6) +
    pad_left("full put MB", 14) +
    pad_left("delta put MB", 14) +
    pad_left("full gobjs", 12) +
    pad_left("delta gobjs", 12) +
    pad_left("full total MB", 14) +
    pad_left("delta total MB", 14) +
    "  delta chain",
  )
  for i in 0..<batches {
    println(row(i + 1, full_stats[i], delta_stats[i]))
  }
  println("")

  let full_put = sum_put(full_stats)
  let delta_put = sum_put(delta_stats)
  let full_final = full_stats[batches - 1]
  let delta_final = delta_stats[batches - 1]

  println("== summary ==")
  println(
    "full  total put = \{mb(full_put)} MB (\{full_put} bytes, \{sum_puts(full_stats)} PUTs)",
  )
  println(
    "delta total put = \{mb(delta_put)} MB (\{delta_put} bytes, \{sum_puts(delta_stats)} PUTs)",
  )
  let ratio = if delta_put > 0 {
    full_put.to_double() / delta_put.to_double()
  } else {
    0.0
  }
  println("full/delta put ratio = \{fmt(ratio, 2)}x")
  println(
    "write_amp_full  = \{fmt(full_put.to_double() / vector_bytes.to_double(), 2)}x vector_bytes",
  )
  println(
    "write_amp_delta = \{fmt(delta_put.to_double() / vector_bytes.to_double(), 2)}x vector_bytes",
  )
  println("global_objs_final = \{delta_final.global_objs} (full: \{full_final.global_objs})")
  println("delta_deltas_final = \{delta_final.gen_deltas}")
  println(
    "delta chain final = base+\{delta_final.gen_deltas}d (base_id_empty=\{delta_final.gen_base == ""})",
  )
  println(
    "delta auto-compact at batch = \{compaction_batches(delta_stats)} (ingest_delta 默认 max_deltas=8)",
  )
  println(
    "  trigger = deltas>=8 OR (deltas>=4 AND delta_bytes/base_bytes>=0.5); 等批量 batch 下比例阈值会先命中，",
  )
  println(
    "  所以早期 delta 批反而比 full 更贵（delta 写入 + 立即全量 compact），累计 base 变大后 delta 才变便宜。",
  )
  println(
    "total bytes final: full = \{mb(full_final.total_bytes)} MB, delta = \{mb(delta_final.total_bytes)} MB (incl. grace-retained generations)",
  )
}

///|
async fn main {
  run() catch {
    _ => println("delta_bench failed (SpndError; see build/query logs for details)")
  }
}


extend CountingStore with @turbofish/store.ObjectStore::{get, list}
