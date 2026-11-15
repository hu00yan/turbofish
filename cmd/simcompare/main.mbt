// SimStore 多方案对照 + cold/warm/hot 五档基准。
//
// 所有延迟来自 SimStore 的虚拟时钟（S3 TTFB + 带宽 + jitter/spike/retry），
// 不是墙钟；正确性测试才允许把延迟设为 0，性能表必须先过 require_latency()。
//
// 五档：
//   cold-process   : resident 关闭 + 每查询 cold()，元数据链 + 数据面都走 S3
//   cold-metadata  : 数据留 NVMe，resident 关闭（元数据走 S3）
//   warm-touched   : burn-in 查询自然预热，测量段不调用 admit_all
//   hot            : 同一查询重复，元数据/解码缓存/NVMe 都热
//   all-hot        : admit_all() 全量预热；合成上界，不是真实 warm

///|
fn pad(s : String, w : Int) -> String {
  let mut out = s
  while out.length() < w {
    out = out + " "
  }
  out
}

///|
fn fmt(x : Double, digits : Int) -> String {
  if digits == 0 {
    return (x + 0.5).to_int().to_string()
  }
  let scale = if digits == 1 { 10.0 } else if digits == 2 { 100.0 } else { 1000.0 }
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
fn pct(arr : Array[Double], p : Double) -> Double {
  if arr.is_empty() {
    return 0.0
  }
  let s = arr.copy()
  s.sort()
  let i = (p * (s.length() - 1).to_double()).to_int()
  s[i]
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
fn make_docs(n : Int, dim : Int) -> Array[@core.Doc] {
  let rng = @core.Rng::new(4242U)
  let words : Array[String] = [
    "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "index",
    "search", "vector", "object", "storage", "latency", "cost", "查询", "向量",
    "存储", "延迟", "成本",
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
      category: "cat\{i % 5}",
      ts: 1700000000L + i.to_int64(),
      public: i % 2 == 0,
    })
  }
  docs
}

///|
#derive(Eq)
enum Tier {
  TColdProcess
  TColdMetadata
  TWarmTouched
  THot
  TAllHot
}


///|
fn tier_label(t : Tier) -> String {
  match t {
    TColdProcess => "cold-process"
    TColdMetadata => "cold-metadata"
    TWarmTouched => "warm-touched"
    THot => "hot"
    TAllHot => "all-hot"
  }
}

///|
struct Cell {
  tier : String
  cls : String
  n : Int
  p50_ms : Double
  p95_ms : Double
  tail_ms : Double
  tail_label : String
  gets : Double
  lists : Double
  kb_s3 : Double
  kb_nvme : Double
  hit_rate : Double
  bill_per_1m : Double
  tpu_per_1m : Double
  errors : Double
}

///|
/// 单次查询。`cp=None` 走 direct open（每次重新 open）；`cp=Some` 走控制面
/// acquire/release（同一 Namespace 快照，pin 住到查询结束）。
fn run_one(
  store : @simstore.SimStore,
  ns : String,
  cls : String,
  bm25_qs : Array[String],
  vec_qvs : Array[Array[Float]],
  idx : Int,
  cp : @control.ControlPlane[@simstore.SimStore]?,
  reuse : @query.Namespace[@simstore.SimStore]?,
) -> Unit raise @core.SpndError {
  let (n, release_cp) = match reuse {
    Some(hot) => (hot, false)
    None =>
      match cp {
        Some(c) => (c.acquire(ns), true)
        None => (@query.open(store, ns), false)
      }
  }
  if cls == "bm25" {
    let _ = @query.bm25_search(n, bm25_qs[idx], 10, None)
  } else {
    let _ = @query.vec_search(n, vec_qvs[idx], 10, 8, None)
  }
  // acquire 返回的 Namespace 已被 pin，必须 release（MoonBit 无 finally：
  // 这里只保证正常路径；对照场景不故意抛错）。
  if release_cp {
    match cp {
      Some(c) => c.release(ns)
      None => ()
    }
  }
}

///|
fn measure_tier(
  store : @simstore.SimStore,
  cfg : @build.BuildConfig,
  cls : String,
  bm25_qs : Array[String],
  vec_qvs : Array[Array[Float]],
  tier : Tier,
  n : Int,
  burn : Int,
  cp : @control.ControlPlane[@simstore.SimStore]?,
) -> Cell raise @core.SpndError {
  store.require_latency()
  if tier == TColdMetadata {
    run_one(store, cfg.ns, cls, bm25_qs, vec_qvs, 0, cp, None)
  }
  let mut hot_ns : @query.Namespace[@simstore.SimStore]? = None
  if tier == THot {
    run_one(store, cfg.ns, cls, bm25_qs, vec_qvs, 0, cp, None)
    hot_ns = Some(@query.open(store, cfg.ns))
  } else if tier == TAllHot {
    store.admit_all()
  } else if tier == TWarmTouched {
    for i in 0..<burn {
      run_one(store, cfg.ns, cls, bm25_qs, vec_qvs, i, cp, None)
    }
  }
  store.reset_cost()
  let lat : Array[Double] = Array(capacity=n)
  let gets : Array[Int] = Array(capacity=n)
  let lists : Array[Int] = Array(capacity=n)
  let s3b : Array[Int] = Array(capacity=n)
  let nvb : Array[Int] = Array(capacity=n)
  let logical : Array[Int] = Array(capacity=n)
  let hits : Array[Int] = Array(capacity=n)
  let mut prev_lat = 0.0
  let mut prev_gets = 0
  let mut prev_lists = 0
  let mut prev_s3 : Int64 = 0L
  let mut prev_nv : Int64 = 0L
  let mut prev_log : Int64 = 0L
  let mut prev_hits = 0
  for i in 0..<n {
    let idx = if tier == TWarmTouched { burn + i } else if tier == THot { 0 } else { i }
    match tier {
      TColdProcess => {
        store.set_resident_enabled(false)
        store.cold()
      }
      TColdMetadata => store.set_resident_enabled(false)
      _ => ()
    }
    run_one(store, cfg.ns, cls, bm25_qs, vec_qvs, idx, cp, hot_ns)
    let c = store.cost()
    lat.push(c.total_latency_us - prev_lat)
    gets.push(c.s3_gets - prev_gets)
    lists.push(c.lists - prev_lists)
    s3b.push((c.bytes_s3_read - prev_s3).to_int())
    nvb.push((c.bytes_nvme_read - prev_nv).to_int())
    logical.push((c.bytes_logical_read - prev_log).to_int())
    hits.push(c.nvme_hits - prev_hits)
    prev_lat = c.total_latency_us
    prev_gets = c.s3_gets
    prev_lists = c.lists
    prev_s3 = c.bytes_s3_read
    prev_nv = c.bytes_nvme_read
    prev_log = c.bytes_logical_read
    prev_hits = c.nvme_hits
  }
  store.set_resident_enabled(true)
  let c = store.cost()
  let mut tpu = 0.0
  for b in logical {
    tpu += @simstore.tpu_scan_bill(b.to_int64())
  }
  let total_hits = avg_i(hits) * n.to_double()
  let total_gets = avg_i(gets) * n.to_double()
  let hit_rate = if total_hits + total_gets > 0.0 {
    total_hits / (total_hits + total_gets)
  } else {
    0.0
  }
  {
    tier: tier_label(tier),
    cls,
    n,
    p50_ms: pct(lat, 0.5) / 1000.0,
    p95_ms: pct(lat, 0.95) / 1000.0,
    tail_ms: if n >= 100 { pct(lat, 0.99) / 1000.0 } else { max_d(lat) / 1000.0 },
    tail_label: if n >= 100 { "p99" } else { "max" },
    gets: avg_i(gets),
    lists: avg_i(lists),
    kb_s3: avg_i(s3b) / 1024.0,
    kb_nvme: avg_i(nvb) / 1024.0,
    hit_rate,
    bill_per_1m: c.bill_requests_total / n.to_double() * 1.0e6,
    tpu_per_1m: tpu / n.to_double() * 1.0e6,
    errors: c.errors.to_double() / n.to_double(),
  }
}

///|
fn print_cell(c : Cell) -> Unit {
  println(
    "  \{pad(c.cls, 6)}\{pad(c.tier, 28)}\{pad(c.n.to_string(), 5)}\{pad("\{fmt(c.p50_ms, 1)}/\{fmt(c.p95_ms, 1)}/\{fmt(c.tail_ms, 1)} \{c.tail_label}", 26)}\{pad(fmt(c.gets, 1), 9)}\{pad(fmt(c.lists, 1), 8)}\{pad(fmt(c.kb_s3, 1), 10)}\{pad(fmt(c.kb_nvme, 1), 10)}\{pad(fmt(c.hit_rate * 100.0, 0), 8)}\{pad(fmt(c.bill_per_1m, 2), 10)}\{pad(fmt(c.tpu_per_1m, 2), 10)}\{fmt(c.errors, 2)}",
  )
}

///|
fn print_header() -> Unit {
  println(
    "  \{pad("class", 6)}\{pad("tier", 28)}\{pad("n", 5)}\{pad("p50/p95/tail(label)", 26)}\{pad("GET/q", 9)}\{pad("LIST/q", 8)}\{pad("KB s3", 10)}\{pad("KB nvme", 10)}\{pad("NVMe%", 8)}\{pad("$/1M", 10)}\{pad("tpuF $/1M", 10)}err",
  )
}

///|
fn build_store(
  cfg : @build.BuildConfig,
  docs : Array[@core.Doc],
) -> @simstore.SimStore raise @core.SpndError {
  let store = @simstore.SimStore::new(@simstore.SimConfig::aws_default(7U))
  store.require_latency()
  @build.ingest(store, cfg, docs)
  store
}

///|
fn main_impl() -> Unit raise @core.SpndError {
  let n = env_int("SIMCOMPARE_DOCS", 500)
  let samples = env_int("SIMCOMPARE_SAMPLES", 50)
  let burn = samples
  let dim = 128
  println(
    "== SimStore benchmark（\{n} docs, \{dim}d, segment_rows=250, nlist=8, samples=\{samples}）==",
  )
  if samples < 100 {
    println("  WARNING: samples<100，不输出 p99（tail 列是 max）；性能结论请用 SIMCOMPARE_SAMPLES>=1000。")
  }
  println(
    "  延迟=SimStore 虚拟时钟（S3 GET 30ms p50 + 100MB/s；非墙钟）；$/1M=S3 请求费；tpuF=逐查询 $1/PB 最低 1.28GB。",
  )
  let docs = make_docs(n, dim)
  let bm25_qs : Array[String] = Array()
  let vec_qvs : Array[Array[Float]] = Array()
  for i in 0..<(samples * 2) {
    bm25_qs.push(@core.tokenize(docs[(i * 17) % n].text)[0])
    vec_qvs.push(docs[(i * 31) % n].vector)
  }
  let base = { ..@build.BuildConfig::default("simcmp"), segment_rows: 250, nlist: 8 }
  let variants : Array[(String, @build.BuildConfig)] = [
    ("per-seg", base),
    ("global", { ..base, global_vec_parts: true }),
    ("global+norm", { ..@build.BuildConfig::single_copy("simcmp"), segment_rows: 250, nlist: 8 }),
  ]
  println("== 布局对照（cold-metadata；bm25/vec 分开）==")
  print_header()
  for v in variants {
    let (name, cfg) = v
    for cls in ["bm25", "vec"] {
      // 每个查询类单独建库：避免 bm25 留下的 NVMe/ranges 把 vec 行预热成假热。
      let store = build_store(cfg, docs)
      let c = measure_tier(
        store,
        cfg,
        cls,
        bm25_qs,
        vec_qvs,
        TColdMetadata,
        samples,
        burn,
        None,
      )
      print_cell({ ..c, tier: "\{tier_label(TColdMetadata)}/\{name}" })
    }
  }
  let cfg = { ..@build.BuildConfig::single_copy("simcmp"), segment_rows: 250, nlist: 8 }
  let tiers : Array[Tier] = [TColdProcess, TColdMetadata, TWarmTouched, THot, TAllHot]
  println("== 五档（global+norm；每档单独建库，避免互相污染）==")
  print_header()
  for tier in tiers {
    for cls in ["bm25", "vec"] {
      let store = build_store(cfg, docs)
      let c = measure_tier(
        store,
        cfg,
        cls,
        bm25_qs,
        vec_qvs,
        tier,
        samples,
        burn,
        None,
      )
      print_cell(c)
    }
  }
  println("  注：all-hot = admit_all() 合成上界，不是真实 warm；hot 仅是 I/O 下界（无 CPU 模型）。")
  // ---- 追加：control plane 对照（不改动上面五档的语义/输出）----
  // 同一份 global+norm 库、同一个 SimStore：先 direct open（cold-metadata）基线，
  // 再让 ControlPlane 缓存 Namespace 快照，逐查询 acquire → bm25/vec → release。
  println(
    "== control plane 对照（cold-metadata 数据面，bm25/vec 各 \{samples} 查询）==",
  )
  print_header()
  let store = build_store(cfg, docs)
  for cls in ["bm25", "vec"] {
    let c = measure_tier(
      store,
      cfg,
      cls,
      bm25_qs,
      vec_qvs,
      TColdMetadata,
      samples,
      burn,
      None,
    )
    print_cell({ ..c, tier: "cold-metadata/direct" })
  }
  let cp = @control.ControlPlane::new(store, @control.CtrlConfig::new())
  for cls in ["bm25", "vec"] {
    let s0 = cp.stats()
    let c = measure_tier(
      store,
      cfg,
      cls,
      bm25_qs,
      vec_qvs,
      TColdMetadata,
      samples,
      burn,
      Some(cp),
    )
    let s1 = cp.stats()
    print_cell({ ..c, tier: "control-plane" })
    println(
      "    control-plane stats (\{cls}, TTL=\{cp_ttl_ms()}ms): \{cp_stats_line(s0, s1)}",
    )
  }
  println(
    "  注：control-plane 只缓存 Namespace 快照（省掉每次 open 的 namespace.json/manifest GET +",
  )
  println(
    "      head 检查，TTL 内 acquire 直接命中且已 pin，release 后 pin 归零）；segmeta/dir 等字节",
  )
  println(
    "      仍走 SimStore 的 resident/NVMe 路径——真正的 NVMe/segmeta 缓存是 C2，不在本节。",
  )
}

///|
/// CtrlConfig::new() 的默认 TTL（ms），只用于输出说明。
fn cp_ttl_ms() -> UInt64 {
  @control.CtrlConfig::new().head_ttl_ms
}

///|
/// (hits, misses, reloads, stales, evictions) 的差分文字。
fn cp_stats_line(
  before : (Int, Int, Int, Int, Int),
  after : (Int, Int, Int, Int, Int),
) -> String {
  let (h0, m0, r0, s0, e0) = before
  let (h1, m1, r1, s1, e1) = after
  "hits=\{h1 - h0} misses=\{m1 - m0} reloads=\{r1 - r0} stales=\{s1 - s0} evictions=\{e1 - e0}"
}

///|
fn main {
  main_impl() catch {
    _ => println("simcompare failed")
  }
}
