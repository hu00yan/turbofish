// 扩展 bench：compact / stats 跳过 / 量化 / decode 缓存。
//
// 在 cmd/main 主 bench 之后运行；所有场景追加输出，不改默认参数与既有表。
// 数字口径与 main.mbt 一致：MemStore 的 cold() + reset_cost() 后按查询累计
// 请求数/字节数；延迟用 @bench 单调时钟（µs）。

///|
/// 定点格式化（正数，digits ∈ {1,2,3}）。
fn extra_fmt(x : Double, digits : Int) -> String {
  let scale = if digits == 1 {
    10.0
  } else if digits == 2 {
    100.0
  } else {
    1000.0
  }
  let neg = x < 0.0
  let ax = if neg { -x } else { x }
  let n = (ax * scale + 0.5).to_int()
  let d = scale.to_int()
  let frac = if digits == 1 {
    n % 10
  } else if digits == 2 {
    n % 100
  } else {
    n % 1000
  }
  let mut fs = frac.to_string()
  while fs.length() < digits {
    fs = "0" + fs
  }
  let out = "\{n / d}.\{fs}"
  if neg {
    "-" + out
  } else {
    out
  }
}

///|
/// 取 docs 前 n 条（数组拷贝）。
fn take_docs(docs : Array[@core.Doc], n : Int) -> Array[@core.Doc] {
  let out : Array[@core.Doc] = Array(capacity=n)
  for i in 0..<n {
    if i < docs.length() {
      out.push(docs[i])
    }
  }
  out
}

///|
/// 小数据集构建配置：单段（segment_rows = n）、nlist=16、按 variant 选择存储。
fn small_cfg(
  ns : String,
  nlist : Int,
  vs : @build.VecStorage,
  seg_rows : Int,
) -> @build.BuildConfig {
  let base = @build.BuildConfig::default(ns)
  { ..base, segment_rows: seg_rows, nlist, vec_storage: vs }
}

///|
/// 单条向量查询的 top-10 id 集合命中率（相对暴力）。
fn recall_of(
  n : @query.Namespace[@store.MemStore],
  store : @store.MemStore,
  qv : Array[Float],
  nprobe : Int,
) -> Double raise @core.SpndError {
  let want = vec_bruteforce(store, n.ns, n.manifest, qv, 10)
  let want_set : Set[UInt64] = Set([])
  for id in want {
    want_set.add(id)
  }
  let got = @query.vec_search(n, qv, 10, nprobe, None)
  let mut inter = 0
  for r in got {
    if want_set.contains(r.id) {
      inter += 1
    }
  }
  inter.to_double() / 10.0
}

///|
/// 单条向量查询的 top-10 命中率（PQ 精排实验路径）。
fn[S : @store.ObjectStore] recall_of_rerank(
  n : @query.Namespace[S],
  store : @store.MemStore,
  qv : Array[Float],
  nprobe : Int,
) -> Double raise @core.SpndError {
  let want = vec_bruteforce(store, n.ns, n.manifest, qv, 10)
  let want_set : Set[UInt64] = Set([])
  for id in want {
    want_set.add(id)
  }
  let got = @query.vec_search_rerank(n, qv, 10, nprobe, None)
  let mut inter = 0
  for r in got {
    if want_set.contains(r.id) {
      inter += 1
    }
  }
  inter.to_double() / 10.0
}

///|
/// 单条查询的冷读请求/字节（cold + reset 后 open+search）。
fn cold_cost_query(
  store : @store.MemStore,
  run : () -> Unit raise @core.SpndError,
) -> (Int, Int) raise @core.SpndError {
  store.cold()
  store.reset_cost()
  run()
  let c = store.cost()
  (c.total_requests(), c.total_read_bytes())
}

///|
/// C：量化收益（VF16 / VSq8 / VPq16）：recall@10 + 冷读 KB/查询。
/// 用 10k docs、单段（segment_rows=10000），让 PQ 共享码本被摊薄；
/// PQ 为 MVP 的纯 ADC（无 f16 精排），簇内精确 top-10 会被量化噪声重排。
fn run_extra_quant(docs : Array[@core.Doc]) -> Unit raise @core.SpndError {
  println(
    "== 量化收益（10000 docs, 768 维, 单段, nlist=16, 10 个向量查询）==",
  )
  println(
    "  storage   recall@10(np=8)  recall@10(np=all)  冷读 KB/查询  写对象数",
  )
  let rng = @core.Rng::new(77U)
  let qvs = gen_vec_queries(rng, docs, 10)
  let variants : Array[(String, @build.VecStorage)] = [
    ("VF16", @build.VF16),
    ("VSq8", @build.VSq8),
    ("VPq16", @build.VPq16),
  ]
  for v in variants {
    let (label, vs) = v
    let store = @store.MemStore::new()
    let ns = "r2q"
    let cfg = small_cfg(ns, 16, vs, 10000)
    @build.ingest(store, cfg, docs)
    let n = @query.open(store, ns)
    let mut r8 = 0.0
    let mut rall = 0.0
    for qv in qvs {
      r8 += recall_of(n, store, qv, 8)
      rall += recall_of(n, store, qv, 16)
    }
    r8 = r8 / qvs.length().to_double()
    rall = rall / qvs.length().to_double()
    let mut bytes = 0
    for qv in qvs {
      store.cold()
      store.reset_cost()
      let nn = @query.open(store, ns)
      let _ = @query.vec_search(nn, qv, 10, 8, None)
      bytes += store.cost().total_read_bytes()
    }
    let kb = bytes.to_double() / qvs.length().to_double() / 1024.0
    println(
      "  \{sim_pad(label, 9)}\{sim_pad(extra_fmt(r8, 3), 18)}\{sim_pad(extra_fmt(rall, 3), 19)}\{sim_pad(extra_fmt(kb, 1), 14)}\{store.object_count()}",
    )
    if label == "VPq16" {
      let mut rr8 = 0.0
      let mut rrall = 0.0
      for qv in qvs {
        rr8 += recall_of_rerank(n, store, qv, 8)
        rrall += recall_of_rerank(n, store, qv, 16)
      }
      rr8 = rr8 / qvs.length().to_double()
      rrall = rrall / qvs.length().to_double()
      let mut rbytes = 0
      for qv in qvs {
        store.cold()
        store.reset_cost()
        let nn = @query.open(store, ns)
        let _ = @query.vec_search_rerank(nn, qv, 10, 8, None)
        rbytes += store.cost().total_read_bytes()
      }
      let rkb = rbytes.to_double() / qvs.length().to_double() / 1024.0
      println(
        "  \{sim_pad("VPq16+rr", 9)}\{sim_pad(extra_fmt(rr8, 3), 18)}\{sim_pad(extra_fmt(rrall, 3), 19)}\{sim_pad(extra_fmt(rkb, 1), 14)}\{store.object_count()}",
      )
    }
  }
  println(
    "  注：PQ16 默认纯 ADC。紧簇数据上簇内近邻差 < 量化误差，ADC top-50 不含真 top-10；",
  )
  println(
    "      f16 精排实验（VPq16+rr）在本数据上 recall 仍低且块读使 KB 反超 VF16，故默认关闭。",
  )
  println(
    "      结论：PQ 适合「簇间可分 + 需要高压缩」的大数据集；紧簇精确 top-10 需要更宽的候选集或 SQ8。",
  )
}

///|
/// b：stats 跳过收益（off / seg-stats / seg+block-stats），同一批 filter 查询。
fn run_extra_stats(
  small : Array[@core.Doc],
  bm25_qs : Array[String],
) -> Unit raise @core.SpndError {
  println(
    "== Stats 跳过收益（2000 docs, 4 段；同 filter 查询，冷读请求/KB）==",
  )
  let mk = fn(
    stats : Bool,
    block_stats : Bool,
  ) -> @store.MemStore raise @core.SpndError {
    let store = @store.MemStore::new()
    let ns = "r2s"
    let base = small_cfg(ns, 16, @build.VF16, 500)
    let cfg = { ..base, write_stats: stats, write_block_stats: block_stats }
    @build.ingest(store, cfg, small)
    store
  }
  let off = mk(false, false)
  let on = mk(true, false)
  let onb = mk(true, true)
  let filters : Array[(String, @query.Filter)] = [
    ("ts=1700001500", @query.f_i64("ts", 1700001500L)),
    ("category=cat3", @query.f_str("category", "cat3")),
  ]
  println(
    "  filter              off req/KB        seg-stats req/KB    +block req/KB      KB 降幅",
  )
  for fv in filters {
    let (flabel, f) = fv
    let mut off_req = 0
    let mut off_kb = 0.0
    let mut on_req = 0
    let mut on_kb = 0.0
    let mut onb_req = 0
    let mut onb_kb = 0.0
    for q in bm25_qs {
      let (r0, b0) = cold_cost_query(off, fn() raise @core.SpndError {
        let nn = @query.open(off, "r2s")
        let _ = @query.bm25_search(nn, q, 10, Some(f))
      })
      off_req += r0
      off_kb += b0.to_double() / 1024.0
      let (r1, b1) = cold_cost_query(on, fn() raise @core.SpndError {
        let nn = @query.open(on, "r2s")
        let _ = @query.bm25_search(nn, q, 10, Some(f))
      })
      on_req += r1
      on_kb += b1.to_double() / 1024.0
      let (r2, b2) = cold_cost_query(onb, fn() raise @core.SpndError {
        let nn = @query.open(onb, "r2s")
        let _ = @query.bm25_search(nn, q, 10, Some(f))
      })
      onb_req += r2
      onb_kb += b2.to_double() / 1024.0
    }
    let nq = bm25_qs.length().to_double()
    let off_avg = off_kb / nq
    let on_avg = on_kb / nq
    let onb_avg = onb_kb / nq
    let drop = if off_avg > 0.0 {
      (1.0 - onb_avg / off_avg) * 100.0
    } else {
      0.0
    }
    println(
      "  \{sim_pad(flabel, 19)}\{sim_pad("\{extra_fmt(off_req.to_double() / nq, 1)}/\{extra_fmt(off_avg, 1)}", 20)}\{sim_pad("\{extra_fmt(on_req.to_double() / nq, 1)}/\{extra_fmt(on_avg, 1)}", 20)}\{sim_pad("\{extra_fmt(onb_req.to_double() / nq, 1)}/\{extra_fmt(onb_avg, 1)}", 20)}\{extra_fmt(drop, 1)}%",
    )
  }
  // 结果一致性：stats / block-stats 开关不影响 top-k 集合
  let n_off = @query.open(off, "r2s")
  let n_on = @query.open(on, "r2s")
  let n_onb = @query.open(onb, "r2s")
  let mut bad = 0
  for q in bm25_qs {
    for fv in filters {
      let (_, f) = fv
      let a = sorted_ids_of(@query.bm25_search(n_off, q, 10, Some(f)))
      let b = sorted_ids_of(@query.bm25_search(n_on, q, 10, Some(f)))
      let c = sorted_ids_of(@query.bm25_search(n_onb, q, 10, Some(f)))
      if a != b || a != c {
        bad += 1
      }
    }
  }
  println(
    "  stats 开关结果一致性：\{if bad == 0 { "OK" } else { "FAIL \{bad}" }}",
  )
}

///|
/// d：decode 缓存前后（同 bench 双跑）：冷缓存 = 每查询新 open，热缓存 = 复用
/// 已 open 的 namespace（per-segment dir/doc_len/id/matcher 缓存命中）。
fn run_extra_cache(
  store : @store.MemStore,
  bm25_qs : Array[String],
  vec_qvs : Array[Array[Float]],
) -> Unit raise @core.SpndError {
  println(
    "== Decode 缓存收益（10k docs；冷缓存 vs 复用 namespace 的解码缓存）==",
  )
  let ns = "bench"
  let rounds = 10
  let nq = 20
  let kinds : Array[(String, CostKind)] = [("bm25", KindBm25), ("vec", KindVec)]
  for kv in kinds {
    let (label, kind) = kv
    // 冷缓存：每查询重新 open（缓存为空）
    let cold : Array[Double] = Array()
    for _ in 0..<rounds {
      let t0 = @bench.monotonic_clock_start()
      for i in 0..<nq {
        let n = @query.open(store, ns)
        let _ = run_one_cost_query(kind, n, i, bm25_qs, vec_qvs)
      }
      let dt = @bench.monotonic_clock_end(t0)
      cold.push(dt / nq.to_double())
    }
    // 热缓存：open 一次 + 预热一轮
    let nw = @query.open(store, ns)
    let _ = run_one_cost_query(kind, nw, 0, bm25_qs, vec_qvs)
    let warm : Array[Double] = Array()
    for _ in 0..<rounds {
      let t0 = @bench.monotonic_clock_start()
      for i in 0..<nq {
        let _ = run_one_cost_query(kind, nw, i, bm25_qs, vec_qvs)
      }
      let dt = @bench.monotonic_clock_end(t0)
      warm.push(dt / nq.to_double())
    }
    cold.sort()
    warm.sort()
    let c = pct(cold, 0.5)
    let w = pct(warm, 0.5)
    println(
      "  \{sim_pad(label, 5)}: 冷缓存 p50=\{c}µs  热缓存 p50=\{w}µs  加速=\{if w > 0.0 { c / w } else { 0.0 }}x",
    )
  }
}

///|
/// IVF 性能：normalize_vecs=false vs true（cosine→dot，省掉每个候选的两次 norm）。
fn extra_ivf_measure(
  small : Array[@core.Doc],
  normalize : Bool,
) -> (Double, Double, Double) raise @core.SpndError {
  let store = @store.MemStore::new()
  let ns = "r2ivf"
  let base = @build.BuildConfig::default(ns)
  let cfg = {
    ..base,
    segment_rows: 2000,
    nlist: 16,
    use_f16: false,
    vec_storage: @build.VF16,
    normalize_vecs: normalize,
  }
  @build.ingest(store, cfg, small)
  let rng = @core.Rng::new(88U)
  let qvs = gen_vec_queries(rng, small, 20)
  let n0 = @query.open(store, ns)
  // recall@10（nprobe=8）
  let mut hits = 0.0
  for qv in qvs {
    let want = vec_bruteforce(store, ns, n0.manifest, qv, 10)
    let ws : Set[UInt64] = Set([])
    for id in want {
      ws.add(id)
    }
    for r in @query.vec_search(n0, qv, 10, 8, None) {
      if ws.contains(r.id) {
        hits += 1.0
      }
    }
  }
  let recall = hits / (qvs.length().to_double() * 10.0)
  // p50（热 namespace，20 轮 × 20 查询）
  let n = @query.open(store, ns)
  let _ = @query.vec_search(n, qvs[0], 10, 8, None)
  let rounds = 20
  let ts : Array[Double] = Array()
  for _ in 0..<rounds {
    let t0 = @bench.monotonic_clock_start()
    for qv in qvs {
      let _ = @query.vec_search(n, qv, 10, 8, None)
    }
    let dt = @bench.monotonic_clock_end(t0)
    ts.push(dt / qvs.length().to_double())
  }
  ts.sort()
  (pct(ts, 0.5), recall, store.total_object_bytes().to_double())
}

///|
/// IVF 性能对照：归一化写入 vs 旧路径（每次候选算 cosine + 两次 norm）。
fn run_extra_ivf(small : Array[@core.Doc]) -> Unit raise @core.SpndError {
  println(
    "== IVF 扫描性能（2000 docs, 768 维, nlist=16, nprobe=8, 20 查询 × 20 轮）==",
  )
  let (p0, r0, b0) = extra_ivf_measure(small, false)
  let (p1, r1, b1) = extra_ivf_measure(small, true)
  println(
    "  cosine 路径 : p50=\{extra_fmt(p0, 1)}µs recall@10=\{extra_fmt(r0, 3)} 存储=\{extra_fmt(b0 / 1024.0 / 1024.0, 2)}MB",
  )
  println(
    "  dot 路径    : p50=\{extra_fmt(p1, 1)}µs recall@10=\{extra_fmt(r1, 3)} 存储=\{extra_fmt(b1 / 1024.0 / 1024.0, 2)}MB",
  )
  println(
    "  加速=\{extra_fmt(p0 / p1, 2)}x（归一化写入只改向量尺度，cosine 排序不变）",
  )
}

///|
/// f：进程级 metadata 缓存的 S3 收益（每查询 open vs open_cached）。
fn run_extra_metadata(
  small : Array[@core.Doc],
  bm25_qs : Array[String],
) -> Unit raise @core.SpndError {
  println(
    "== Metadata cache（2000 docs, 4 段；每查询 open vs open_cached）==",
  )
  let store = @store.MemStore::new()
  let ns = "r2m"
  let base = small_cfg(ns, 16, @build.VF16, 500)
  @build.ingest(store, base, small)
  let nq = bm25_qs.length()
  // 无缓存：每查询新 open（seg 解码缓存全空）
  store.cold()
  store.reset_cost()
  let t0 = @bench.monotonic_clock_start()
  let mut off_req = 0
  let mut off_bytes = 0
  for q in bm25_qs {
    let n = @query.open(store, ns)
    let _ = @query.bm25_search(n, q, 10, None)
    let c = store.cost()
    off_req = c.total_requests()
    off_bytes = c.total_read_bytes()
  }
  let off_us = @bench.monotonic_clock_end(t0) / nq.to_double()
  // 有缓存：同一 MetadataCache，首查询填充后复用
  let cache : @query.MetadataCache[@store.MemStore] = @query.MetadataCache::new()
  store.cold()
  store.reset_cost()
  let t1 = @bench.monotonic_clock_start()
  for q in bm25_qs {
    let n = @query.open_cached(cache, store, ns)
    let _ = @query.bm25_search(n, q, 10, None)
  }
  let on_us = @bench.monotonic_clock_end(t1) / nq.to_double()
  let c = store.cost()
  println(
    "  no-cache : req=\{off_req} KB=\{extra_fmt(off_bytes.to_double() / 1024.0, 1)} p50=\{extra_fmt(off_us, 1)}µs",
  )
  println(
    "  cached   : req=\{c.total_requests()} KB=\{extra_fmt(c.total_read_bytes().to_double() / 1024.0, 1)} p50=\{extra_fmt(on_us, 1)}µs  hits=\{cache.hits} misses=\{cache.misses}",
  )
}

///|
/// g：namespace 级全局 IVF 分区 vs per-segment（S3 请求数）。
fn extra_global_measure(
  docs : Array[@core.Doc],
  use_global : Bool,
) -> (Double, Double, Int, Double) raise @core.SpndError {
  let store = @store.MemStore::new()
  let ns = "r2g"
  let base = @build.BuildConfig::default(ns)
  let cfg = {
    ..base,
    segment_rows: 2000,
    nlist: 16,
    vec_storage: @build.VF16,
    global_vec_parts: use_global,
  }
  @build.ingest(store, cfg, docs)
  let n0 = @query.open(store, ns)
  let rng = @core.Rng::new(99U)
  let qvs = gen_vec_queries(rng, docs, 10)
  let nq = qvs.length().to_double()
  let mut req = 0
  let mut bytes = 0
  for qv in qvs {
    store.cold()
    store.reset_cost()
    let nn = @query.open(store, ns)
    let _ = @query.vec_search(nn, qv, 10, 8, None)
    let c = store.cost()
    req += c.total_requests()
    bytes += c.total_read_bytes()
  }
  (
    req.to_double() / nq,
    bytes.to_double() / nq,
    n0.manifest.segments.length(),
    store.total_object_bytes().to_double(),
  )
}

///|
fn run_extra_global(docs : Array[@core.Doc]) -> Unit raise @core.SpndError {
  println(
    "== 全局 IVF 分区（10k docs, 5 段, nprobe=8, 10 个向量查询）==",
  )
  let (r0, b0, s0, sz0) = extra_global_measure(docs, false)
  let (r1, b1, s1, sz1) = extra_global_measure(docs, true)
  println(
    "  per-segment : 段数=\{s0} req/查询=\{extra_fmt(r0, 1)} KB/查询=\{extra_fmt(b0 / 1024.0, 1)} 存储=\{extra_fmt(sz0 / 1024.0 / 1024.0, 1)}MB",
  )
  println(
    "  global IVF  : 段数=\{s1} req/查询=\{extra_fmt(r1, 1)} KB/查询=\{extra_fmt(b1 / 1024.0, 1)} 存储=\{extra_fmt(sz1 / 1024.0 / 1024.0, 1)}MB",
  )
  println(
    "  请求降幅=\{extra_fmt((1.0 - r1 / r0) * 100.0, 1)}%（全局分区每 cid 一个对象，不再 nprobe×段数）",
  )
}

///|
/// h：段级 FTS Bloom 对“不存在的 term”的请求剪枝。
fn run_extra_bloom(small : Array[@core.Doc]) -> Unit raise @core.SpndError {
  println(
    "== FTS Bloom（2000 docs, 4 段；查询不存在的 term，10 次冷查询）==",
  )
  let q = "zzzznotfound"
  let mk = fn(bloom : Bool) -> @store.MemStore raise @core.SpndError {
    let store = @store.MemStore::new()
    let ns = "r2bl"
    let base = small_cfg(ns, 16, @build.VF16, 500)
    let cfg = { ..base, write_fts_bloom: bloom }
    @build.ingest(store, cfg, small)
    store
  }
  let off = mk(false)
  let on = mk(true)
  let measure = fn(
    store : @store.MemStore,
    label : String,
  ) -> Unit raise @core.SpndError {
    store.cold()
    store.reset_cost()
    for _ in 0..<10 {
      let n = @query.open(store, "r2bl")
      let _ = @query.bm25_search(n, q, 10, None)
    }
    let c = store.cost()
    println(
      "  \{sim_pad(label, 10)}: req/10=\{c.total_requests()} KB/10=\{extra_fmt(c.total_read_bytes().to_double() / 1024.0, 1)}",
    )
  }
  measure(off, "no-bloom")
  measure(on, "bloom")
  println(
    "  Bloom 嵌在 seg meta.json 中，不额外增加对象 GET；不存在的 term 直接跳过 dir/postings。",
  )
}
