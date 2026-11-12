// cmd/main bench：seekpond/v1 端到端（NOTES 第 5 节）。
//
// 流程：生成确定性数据 → build.ingest（存根会 raise，捕获后打印提示退出）→
// 正确性 gate（BM25 暴力对照 / 向量 nprobe=64 精确 + nprobe=8 recall / 过滤 /
// delete 20 ids）→ 冷/热成本表（每类 20 查询，CostSnapshot::show_table）→
// 总存储一行汇总。性能计时无稳定 API，按 NOTES 只报请求次数与 KB。

///|
/// 错误转可读字符串（SpndError 只 derive 了 Debug，跨包插值不可靠，手写展开）。
fn err_msg(e : @core.SpndError) -> String {
  match e {
    @core.BadMagic(s) => "BadMagic(\{s})"
    @core.Truncated(s) => "Truncated(\{s})"
    @core.Corrupt(s) => "Corrupt(\{s})"
    @core.NotFound(s) => "NotFound(\{s})"
    @core.CommitConflict(s) => "CommitConflict(\{s})"
  }
}

///|
/// gate 断言：不满足即 raise（由 main 统一捕获打印）。
fn gate(cond : Bool, msg : String) -> Unit raise @core.SpndError {
  if !cond {
    raise @core.Corrupt("GATE FAIL: \{msg}")
  }
}

///|
fn ids_of_results(results : Array[@query.QueryResult]) -> Array[UInt64] {
  let out : Array[UInt64] = Array::new()
  for r in results {
    out.push(r.id)
  }
  out
}

///|
fn sorted_ids_of(results : Array[@query.QueryResult]) -> Array[UInt64] {
  let out = ids_of_results(results)
  out.sort()
  out
}

///|
fn show_ids(ids : Array[UInt64]) -> String {
  let mut out = ""
  for i in 0..<ids.length() {
    if i > 0 {
      out = out + ","
    }
    out = out + ids[i].to_string()
  }
  out
}

///|
fn contains_id(results : Array[@query.QueryResult], id : UInt64) -> Bool {
  for r in results {
    if r.id == id {
      return true
    }
  }
  false
}

///|
/// okapi BM25 打分（与 query 包公式逐字一致，保证对照同精度）。
fn bench_bm25_score(
  tf : Int,
  df : Int,
  n_docs : Int,
  dl : Int,
  avgdl : Double,
  k1 : Double,
  b : Double,
) -> Double {
  let tfd = tf.to_double()
  let dfd = df.to_double()
  let idf = @math.ln(1.0 + (n_docs.to_double() - dfd + 0.5) / (dfd + 0.5))
  let avg = if avgdl > 0.0 { avgdl } else { 1.0 }
  let denom = tfd + k1 * (1.0 - b + b * (dl.to_double() / avg))
  idf * (tfd * (k1 + 1.0)) / denom
}

///|
/// BM25 暴力对照：整读 text/doc_len 列，逐行 tokenize 重算 tf/df，
/// 与 bm25_search 完全相同的管线（per-segment top-k → 合并 → tombstone → top-k）。
fn bm25_bruteforce(
  store : @store.MemStore,
  ns : String,
  meta : @format.NamespaceMeta,
  man : @format.ManifestData,
  query : String,
  k : Int,
) -> Array[UInt64] raise @core.SpndError {
  let terms : Array[String] = Array::new()
  let seen : Set[String] = Set([])
  for t in @core.tokenize(query) {
    if !seen.contains(t) {
      seen.add(t)
      terms.push(t)
    }
  }
  if terms.is_empty() || k <= 0 {
    return []
  }
  let tomb : Set[UInt64] = Set([])
  for d in man.deleted {
    tomb.add(d)
  }
  let merged : Array[(Int, Int, Double)] = Array::new()
  for si in 0..<man.segments.length() {
    let seg = man.segments[si]
    let base = "\{ns}/_segments/\{seg.id}"
    let texts = match
      @format.decode_col(
        match store.get("\{base}/rows/text.bin") {
          Some(x) => x
          None => raise @core.NotFound("\{base}/rows/text.bin")
        },
      ) {
      @format.ColStr(a) => a
      _ => raise @core.Corrupt("text column dtype")
    }
    let dls = match
      @format.decode_col(
        match store.get("\{base}/fts/doc_len.bin") {
          Some(x) => x
          None => raise @core.NotFound("\{base}/fts/doc_len.bin")
        },
      ) {
      @format.ColU32(a) => a
      _ => raise @core.Corrupt("doc_len column dtype")
    }
    let n_docs = seg.row_count
    let n_terms = terms.length()
    let tfs : Array[Array[Int]] = Array::new(capacity=n_docs)
    let dfs : Array[Int] = Array::new(capacity=n_terms)
    for _t in terms {
      dfs.push(0)
    }
    for row in 0..<n_docs {
      let counts : Array[Int] = Array::new(capacity=n_terms)
      for _t in terms {
        counts.push(0)
      }
      for tok in @core.tokenize(texts[row]) {
        for ti in 0..<n_terms {
          if terms[ti] == tok {
            counts[ti] += 1
          }
        }
      }
      for ti in 0..<n_terms {
        if counts[ti] > 0 {
          dfs[ti] += 1
        }
      }
      tfs.push(counts)
    }
    let seg_cands : Array[(Int, Double)] = Array::new()
    for row in 0..<n_docs {
      let dl = match dls.get(row) {
        Some(x) => x
        None => 0
      }
      let mut s = 0.0
      for ti in 0..<n_terms {
        let tf = tfs[row][ti]
        if tf > 0 {
          s = s +
            bench_bm25_score(
              tf,
              dfs[ti],
              n_docs,
              dl,
              man.avg_doc_len,
              meta.k1,
              meta.b,
            )
        }
      }
      if s > 0.0 {
        seg_cands.push((row, s))
      }
    }
    seg_cands.sort_by(fn(a, b) { b.1.compare(a.1) })
    if seg_cands.length() > k {
      seg_cands.truncate(k)
    }
    for c in seg_cands {
      merged.push((si, c.0, c.1))
    }
  }
  let id_cols : Map[Int, Array[UInt64]] = Map([])
  let scored : Array[(UInt64, Double)] = Array::new()
  for c in merged {
    let (si, row, score) = c
    let ids = match id_cols.get(si) {
      Some(a) => a
      None => {
        let seg = man.segments[si]
        let arr = match
          @format.decode_col(
            match store.get("\{ns}/_segments/\{seg.id}/rows/id.bin") {
              Some(x) => x
              None => raise @core.NotFound("id.bin")
            },
          ) {
          @format.ColU64(a) => a
          _ => raise @core.Corrupt("id column dtype")
        }
        id_cols.set(si, arr)
        arr
      }
    }
    let id = match ids.get(row) {
      Some(x) => x
      None => raise @core.Corrupt("row out of range")
    }
    if !tomb.contains(id) {
      scored.push((id, score))
    }
  }
  scored.sort_by(fn(a, b) { b.1.compare(a.1) })
  if scored.length() > k {
    scored.truncate(k)
  }
  let out : Array[UInt64] = Array::new()
  for c in scored {
    out.push(c.0)
  }
  out.sort()
  out
}

///|
/// 向量暴力对照：整读每段 rows/vector.bin（f16 解码，与 part 文件同精度），
/// 全量线性 cosine，排序后过滤 tombstone 取 top-k。
fn vec_bruteforce(
  store : @store.MemStore,
  ns : String,
  man : @format.ManifestData,
  qv : Array[Float],
  k : Int,
) -> Array[UInt64] raise @core.SpndError {
  let tomb : Set[UInt64] = Set([])
  for d in man.deleted {
    tomb.add(d)
  }
  let cands : Array[(UInt64, Double)] = Array::new()
  for si in 0..<man.segments.length() {
    let seg = man.segments[si]
    let base = "\{ns}/_segments/\{seg.id}"
    let (dim, data) = @format.decode_vec_col(
      match store.get("\{base}/rows/vector.bin") {
        Some(x) => x
        None => raise @core.NotFound("\{base}/rows/vector.bin")
      },
    )
    if qv.length() != dim {
      raise @core.Corrupt("query vec dim mismatch")
    }
    let ids = match
      @format.decode_col(
        match store.get("\{base}/rows/id.bin") {
          Some(x) => x
          None => raise @core.NotFound("\{base}/rows/id.bin")
        },
      ) {
      @format.ColU64(a) => a
      _ => raise @core.Corrupt("id column dtype")
    }
    let rows = data.length() / dim
    for row in 0..<rows {
      let score = 1.0 - @core.cosine_dist_f32(qv, 0, data, row * dim, dim)
      let id = match ids.get(row) {
        Some(x) => x
        None => raise @core.Corrupt("row out of range in id column")
      }
      if !tomb.contains(id) {
        cands.push((id, score))
      }
    }
  }
  cands.sort_by(fn(a, b) { b.1.compare(a.1) })
  let out : Array[UInt64] = Array::new()
  for c in cands {
    if out.length() >= k {
      break
    }
    out.push(c.0)
  }
  out.sort()
  out
}

///|
fn run_gates(
  store : @store.MemStore,
  cfg : @build.BuildConfig,
  docs : Array[@core.Doc],
  bm25_qs : Array[String],
  vec_qvs : Array[Array[Float]],
) -> Unit raise @core.SpndError {
  let ns = "bench"
  let n = @query.open(store, ns)
  // ---- gate 1: BM25 暴力对照
  println(
    "== gate 1: BM25 暴力对照（\{bm25_qs.length()} 个查询，top-10 id 集合必须一致）",
  )
  let mut ok1 = 0
  for i in 0..<bm25_qs.length() {
    let got = @query.bm25_search(n, bm25_qs[i], 10, None)
    let want = bm25_bruteforce(store, ns, n.meta, n.manifest, bm25_qs[i], 10)
    let got_ids = sorted_ids_of(got)
    if got_ids == want {
      ok1 += 1
    } else {
      println(
        "  mismatch q\{i} [\{bm25_qs[i]}]: got=[\{show_ids(got_ids)}] want=[\{show_ids(want)}]",
      )
    }
  }
  println("  bm25 set match: \{ok1}/\{bm25_qs.length()}")
  gate(
    ok1 == bm25_qs.length(),
    "bm25 brute-force top-10 set match \{ok1}/\{bm25_qs.length()}",
  )
  // ---- gate 2: 向量
  println(
    "== gate 2: 向量（nprobe=64 与暴力全量完全一致；nprobe=8 recall@10 ≥ 0.8）",
  )
  let mut exact = 0
  let mut recall_sum = 0.0
  for i in 0..<vec_qvs.length() {
    let want = vec_bruteforce(store, ns, n.manifest, vec_qvs[i], 10)
    let want_set : Set[UInt64] = Set([])
    for id in want {
      want_set.add(id)
    }
    let r64 = @query.vec_search(n, vec_qvs[i], 10, 64, None)
    if sorted_ids_of(r64) == want {
      exact += 1
    }
    let r8 = @query.vec_search(n, vec_qvs[i], 10, 8, None)
    let mut inter = 0
    for id in ids_of_results(r8) {
      if want_set.contains(id) {
        inter += 1
      }
    }
    let recall = inter.to_double() / 10.0
    recall_sum = recall_sum + recall
    println(
      "  q\{i}: exact64=\{sorted_ids_of(r64) == want} recall@10(nprobe=8)=\{recall}",
    )
  }
  let nq = vec_qvs.length()
  println(
    "  nprobe=64 exact: \{exact}/\{nq}, avg recall@10(nprobe=8)=\{recall_sum / nq.to_double()}",
  )
  gate(exact == nq, "vec nprobe=64 exact \{exact}/\{nq}")
  gate(recall_sum / nq.to_double() >= 0.8, "vec nprobe=8 avg recall@10 < 0.8")
  // ---- gate 3: 过滤
  println("== gate 3: 过滤 bm25_search(category=cat3)")
  let rf = @query.bm25_search(
    n,
    bm25_qs[0],
    10,
    Some(@query.FStr("category", "cat3")),
  )
  println("  filter 结果数: \{rf.length()}")
  gate(rf.length() > 0, "filter results empty")
  let mut all_cat3 = true
  for r in rf {
    if docs[r.id.to_int()].category != "cat3" {
      all_cat3 = false
    }
  }
  gate(all_cat3, "filter results contain non-cat3")
  // ---- gate 4: 删除
  println("== gate 4: delete 20 ids 后所有查询不再返回它们")
  let del_set : Set[UInt64] = Set([])
  for r in @query.bm25_search(n, bm25_qs[0], 10, None) {
    if del_set.length() < 10 {
      del_set.add(r.id)
    }
  }
  for r in @query.vec_search(n, vec_qvs[0], 10, 64, None) {
    if del_set.length() < 20 {
      del_set.add(r.id)
    }
  }
  let mut pad = 9001UL
  while del_set.length() < 20 {
    del_set.add(pad)
    pad = pad + 1UL
  }
  let del_ids : Array[UInt64] = Array::new()
  for id in del_set {
    del_ids.push(id)
  }
  println("  删除 ids: [\{show_ids(del_ids)}]")
  @build.delete_docs(store, cfg, del_ids)
  let n2 = @query.open(store, ns) // 重开绑定删除后的 manifest 快照
  let rb = @query.bm25_search(n2, bm25_qs[0], 10, None)
  let rv = @query.vec_search(n2, vec_qvs[0], 10, 64, None)
  let rh = @query.hybrid_search(n2, bm25_qs[1], vec_qvs[1], 10, 8, None)
  let mut leaked = false
  for id in del_ids {
    if contains_id(rb, id) || contains_id(rv, id) || contains_id(rh, id) {
      leaked = true
    }
  }
  gate(!leaked, "deleted ids still returned by queries")
  println(
    "  delete 后 bm25/vec/hybrid 均不含已删 ids（结果数 \{rb.length()}/\{rv.length()}/\{rh.length()}）",
  )
  println("== 全部 gate 通过")
}

///|
fn avg_i(arr : Array[Int]) -> Double {
  let mut s = 0
  for v in arr {
    s += v
  }
  if arr.is_empty() {
    0.0
  } else {
    s.to_double() / arr.length().to_double()
  }
}

///|
fn pctl(arr : Array[Int], p : Int) -> Int {
  if arr.is_empty() {
    return 0
  }
  let c = arr.copy()
  c.sort()
  let mut idx = c.length() * p / 100
  if idx >= c.length() {
    idx = c.length() - 1
  }
  c[idx]
}

///|
fn print_cost_line(
  label : String,
  reqs : Array[Int],
  bytes : Array[Int],
) -> Unit {
  println(
    "[\{label}] reqs avg=\{avg_i(reqs)} p50=\{pctl(reqs, 50)} p99=\{pctl(reqs, 99)} | KB avg=\{avg_i(bytes) / 1024.0} p50=\{pctl(bytes, 50).to_double() / 1024.0} p99=\{pctl(bytes, 99).to_double() / 1024.0}",
  )
}

///|
/// 成本测量类型。
enum CostKind {
  KindBm25
  KindVec
  KindHybrid
}

///|
/// 执行第 i 条查询（vec/hybrid 用 nprobe=8 的典型探查数）。
fn run_one_cost_query(
  kind : CostKind,
  n : @query.Namespace[@store.MemStore],
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
/// 单类查询的成本测量：冷（cold+reset 后每查询 open+search）与
/// 热（reset 后复用已 open 的 namespace 仅 search，缓存已热）。
fn measure_type(
  store : @store.MemStore,
  label : String,
  kind : CostKind,
  bm25_qs : Array[String],
  vec_qvs : Array[Array[Float]],
) -> Unit raise @core.SpndError {
  let ns = "bench"
  // 冷
  store.cold()
  store.reset_cost()
  let cr : Array[Int] = Array::new()
  let cb : Array[Int] = Array::new()
  let mut prev_r = 0
  let mut prev_b = 0
  for i in 0..<20 {
    let n = @query.open(store, ns)
    let _ = run_one_cost_query(kind, n, i, bm25_qs, vec_qvs)
    let c = store.cost()
    cr.push(c.total_requests() - prev_r)
    cb.push(c.total_read_bytes() - prev_b)
    prev_r = c.total_requests()
    prev_b = c.total_read_bytes()
  }
  let cold_snap = store.cost()
  // 热
  let n_hot = @query.open(store, ns)
  store.reset_cost()
  let hr : Array[Int] = Array::new()
  let hb : Array[Int] = Array::new()
  prev_r = 0
  prev_b = 0
  for i in 0..<20 {
    let _ = run_one_cost_query(kind, n_hot, i, bm25_qs, vec_qvs)
    let c = store.cost()
    hr.push(c.total_requests() - prev_r)
    hb.push(c.total_read_bytes() - prev_b)
    prev_r = c.total_requests()
    prev_b = c.total_read_bytes()
  }
  let hot_snap = store.cost()
  println(
    "== [\{label}] 成本（20 查询；冷=open+search，热=仅 search，缓存已热）",
  )
  print_cost_line("\{label} cold", cr, cb)
  print_cost_line("\{label} hot ", hr, hb)
  println("-- \{label} cold 类别明细 --")
  println(cold_snap.show_table())
  println("-- \{label} hot 类别明细 --")
  println(hot_snap.show_table())
}

///|
/// 三类查询各测冷/热成本。
fn run_cost(
  store : @store.MemStore,
  bm25_qs : Array[String],
  vec_qvs : Array[Array[Float]],
) -> Unit raise @core.SpndError {
  measure_type(store, "bm25", KindBm25, bm25_qs, vec_qvs)
  measure_type(store, "vec", KindVec, bm25_qs, vec_qvs)
  measure_type(store, "hybrid", KindHybrid, bm25_qs, vec_qvs)
}

///|
/// 单类查询的 native 延迟（缓存已热的"温服务"路径：复用 open 好的 namespace，
/// 只测 search 计算）。每轮 20 条查询取均值 µs，rounds 轮样本排序后取分位。
fn perf_one(
  n : @query.Namespace[@store.MemStore],
  kind : CostKind,
  bm25_qs : Array[String],
  vec_qvs : Array[Array[Float]],
  rounds : Int,
) -> Array[Double] raise @core.SpndError {
  let ts : Array[Double] = Array::new()
  for _ in 0..<rounds {
    let t0 = @bench.monotonic_clock_start()
    for i in 0..<20 {
      let _ = run_one_cost_query(kind, n, i, bm25_qs, vec_qvs)
    }
    let dt = @bench.monotonic_clock_end(t0) // 单位：微秒
    ts.push(dt / 20.0)
  }
  ts.sort()
  ts
}

///|
fn pct(arr : Array[Double], p : Double) -> Double {
  let idx = ((arr.length().to_double() - 1.0) * p).to_int()
  arr[idx]
}

///|
/// 三类查询的 native 性能（内存模拟器 = 纯计算上限，不含真实 S3 RTT）。
fn run_perf(
  store : @store.MemStore,
  bm25_qs : Array[String],
  vec_qvs : Array[Array[Float]],
) -> Unit raise @core.SpndError {
  let ns = "bench"
  let rounds = 50
  println(
    "== [perf] native 温服务延迟（namespace 已 open、缓存已热、50 轮 x 20 查询）==",
  )
  let kinds : Array[(String, CostKind)] = [
    ("bm25", KindBm25),
    ("vec", KindVec),
    ("hybrid", KindHybrid),
  ]
  for kv in kinds {
    let (label, kind) = kv
    // 预热一轮不计
    let warm = @query.open(store, ns)
    let _ = run_one_cost_query(kind, warm, 0, bm25_qs, vec_qvs)
    let n = @query.open(store, ns)
    let ts = perf_one(n, kind, bm25_qs, vec_qvs, rounds)
    let mut sum = 0.0
    for t in ts {
      sum = sum + t
    }
    let avg = sum / ts.length().to_double()
    println(
      "[\{label}] p50=\{pct(ts, 0.5)}µs p99=\{pct(ts, 0.99)}µs avg=\{avg}µs",
    )
  }
}

///|
fn main {
  println("== turbofish bench: seekpond/v1（BM25 + IVF + 过滤 + RRF）==")
  let rng = @core.Rng::new(42U)
  let cum = build_zipf_cum()
  println(
    "生成数据（10k docs, zipf 词表 \{vocab_en.length() + vocab_zh.length()} 词, 768 维 8 簇）...",
  )
  let docs = gen_docs(rng, cum)
  let bm25_gate_qs = gen_bm25_queries(rng, cum, 10)
  let vec_gate_qvs = gen_vec_queries(rng, docs, 3)
  let bm25_cost_qs = gen_bm25_queries(rng, cum, 20)
  let vec_cost_qvs = gen_vec_queries(rng, docs, 20)
  println(
    "查询集：bm25 gate=\{bm25_gate_qs.length()} vec gate=\{vec_gate_qvs.length()} cost=20x3",
  )
  let store = @store.MemStore::new()
  let cfg = @build.BuildConfig::default("bench")
  println(
    "ingest（build 包, segment_rows=\{cfg.segment_rows} nlist=\{cfg.nlist}）...",
  )
  let built = try {
    @build.ingest(store, cfg, docs)
    true
  } catch {
    e => {
      println("build 包未实现（等待写路径 agent）: \{err_msg(e)}")
      false
    }
  }
  if built {
    try {
      println(
        "ingest 完成: objects=\{store.object_count()} bytes=\{store.total_object_bytes()}",
      )
      store.cold()
      run_gates(store, cfg, docs, bm25_gate_qs, vec_gate_qvs)
      run_cost(store, bm25_cost_qs, vec_cost_qvs)
      run_perf(store, bm25_cost_qs, vec_cost_qvs)
      // ---- R2：阶段 3 集成 bench（追加场景，默认参数不变）
      let small = take_docs(docs, 2000)
      let r2_rng = @core.Rng::new(123U)
      let r2_bm25 = gen_bm25_queries(r2_rng, cum, 10)
      run_r2_quant(docs)
      run_r2_stats(small, r2_bm25)
      run_r2_cache(store, bm25_cost_qs, vec_cost_qvs)
      run_r2_ivf(small)
      run_r2_metadata(small, r2_bm25)
      run_r2_global(docs)
      run_r2_bloom(small)
    } catch {
      e => println("bench 失败: \{err_msg(e)}")
    }
  }
  println(
    "total storage: \{store.total_object_bytes()} bytes, \{store.object_count()} objects",
  )
  // ---- SimStore 场景（NOTES2.md 第 5 节）：数据生成一次、ingest 两次的第二次。
  // MemStore 流程保持原样；SimConfig 按 aws_default(42U) 拷贝构造，显式设
  // nvme_capacity_bytes = 512MB（≥ 全量 ~35MB → NVMe 可全热）。
  // 存根阶段延迟/计费为 0 属预期，simstore 实装后自动变真。
  if built {
    let base = @simstore.SimConfig::aws_default(42U)
    let sim_cfg = { ..base, nvme_capacity_bytes: 536870912 } // 512MB
    let store_sim = @simstore.SimStore::new(sim_cfg)
    run_sim(
      store, store_sim, "bench", docs, bm25_gate_qs, vec_gate_qvs, bm25_cost_qs,
      vec_cost_qvs,
    ) catch {
      e => println("SimStore 场景失败: \{err_msg(e)}")
    }
  }
}
