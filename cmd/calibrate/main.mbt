// cmd/calibrate：用本机实测的算子成本校准 simcluster 的 CpuProfile，
// 再用它把「老架构 vs 新架构」的延迟/吞吐/账单跑出来对比。
//
// 实测项（@bench 单调时钟，微秒；每项热身 3 轮、测 15 轮取中位数）：
//   - @core.dot_f32 / @core.l2sq_f32：128 维与 768 维
//   - @format.encode_slab + @format.decode_slab_file（64 行 × 128 维的段）
//   - @format.encode_roaring + decode_roaring（1000 个 doc id 的倒排）
//   - 压缩合并：3 个 slab 解码 → 拼接 → 重编码（每篇文档成本）
//
// 输出：CpuProfile JSON（可直接贴进配置文件）+ 两套架构的对比表。
// 注意：墙钟实测值随机器波动，所以这里只打印、不 assert；仿真本身仍是确定性的。
// 重要：必须用 release 构建跑（debug 构建的算子耗时高一个数量级，会把画像带偏）：
//   moon run --target native --release cmd/calibrate

///|
const SLAB_ROWS : Int = 64

///|
const SLAB_DIM : Int = 128

///|
const ROARING_IDS : Int = 1000

///|
const BENCH_WARMUP : Int = 3

///|
const BENCH_ROUNDS : Int = 15

///|
/// 计时骨架：热身 warmup 轮后测 rounds 轮，返回每次调用的中位耗时（微秒）。
fn bench_us(warmup : Int, rounds : Int, iters : Int, f : () -> Double) -> Double {
  let mut checksum = 0.0
  for _ in 0..<warmup {
    checksum = checksum + f()
  }
  let ts : Array[Double] = Array()
  for _ in 0..<rounds {
    let t0 = @bench.monotonic_clock_start()
    for _ in 0..<iters {
      checksum = checksum + f()
    }
    ts.push(@bench.monotonic_clock_end(t0) / iters.to_double())
  }
  ts.sort()
  let _ = checksum
  ts[rounds / 2]
}

///|
/// 行主序 float 矩阵（rows 行 × dim 维），值域 [-1, 1)。
fn gen_vecs(rows : Int, dim : Int, seed : UInt) -> Array[Float] {
  let rng = @core.Rng::new(seed)
  let a : Array[Float] = Array()
  for _ in 0..<(rows * dim) {
    a.push(Float::from_double(rng.next_f64() * 2.0 - 1.0))
  }
  a
}

///|
/// 1000 个递增 doc id 的倒排表（encode_roaring 输入）。
fn gen_roaring(n : Int) -> Array[UInt64] {
  let ids : Array[UInt64] = Array()
  for i in 0..<n {
    ids.push(1000UL + i.to_uint64() * 3UL)
  }
  ids
}

///|
/// 构造一个 rows × dim 的段（id 列 + 向量列 + 倒排列），与真实 Slab 组件布局同构。
fn make_components(
  rows : Int,
  dim : Int,
  vecs : Array[Float],
) -> Array[@format.SlabComponentPayload] {
  let ids = Buffer()
  for i in 0..<rows {
    ids.write_uint64_le(1000UL + i.to_uint64())
  }
  let vb = Buffer()
  for i in 0..<(rows * dim) {
    vb.write_float_le(vecs[i])
  }
  let postings = @format.encode_roaring(gen_roaring(rows))
  [
    @format.SlabComponentPayload::new("rows/id", ids.to_bytes(), rows),
    @format.SlabComponentPayload::new("rows/vec", vb.to_bytes(), rows),
    @format.SlabComponentPayload::new("fts/postings", postings, rows),
  ]
}

///|
/// 解码一次段文件并切出向量列（校验和 = 切出的字节数）。
fn decode_once(slab : Bytes) -> Double {
  try {
    let (_ver, idx) = @format.decode_slab_file(slab)
    let mut n = 0.0
    match idx.get_slice(slab, "rows/vec") {
      Some(b) => n = n + b.length().to_double()
      None => ()
    }
    match idx.get_slice(slab, "rows/id") {
      Some(b) => n = n + b.length().to_double()
      None => ()
    }
    n
  } catch {
    _ => 0.0
  }
}

///|
fn decode_roaring_once(bs : Bytes) -> Double {
  try {
    let ids = @format.decode_roaring(bs)
    ids.length().to_double()
  } catch {
    _ => 0.0
  }
}

///|
/// 压缩一次：3 个段各自解码 → 拼接列 → 重编码成一个新段（返回输出字节数）。
fn compact_once(
  slabs : Array[Bytes],
  rows_per_slab : Int,
  dim : Int,
) -> Double {
  try {
    let ib = Buffer()
    let vb = Buffer()
    for s in slabs {
      let (_ver, idx) = @format.decode_slab_file(s)
      match idx.get_slice(s, "rows/id") {
        Some(b) => ib.write_bytesview(b.exact_view(start=0, end=b.length()))
        None => ()
      }
      match idx.get_slice(s, "rows/vec") {
        Some(b) => vb.write_bytesview(b.exact_view(start=0, end=b.length()))
        None => ()
      }
    }
    let rows = rows_per_slab * slabs.length()
    let comps : Array[@format.SlabComponentPayload] = [
      @format.SlabComponentPayload::new("rows/id", ib.to_bytes(), rows),
      @format.SlabComponentPayload::new("rows/vec", vb.to_bytes(), rows),
      @format.SlabComponentPayload::new(
        "fts/postings",
        @format.encode_roaring(gen_roaring(rows)),
        rows,
      ),
    ]
    let _ = dim
    let (out, _idx) = @format.encode_slab(comps)
    out.length().to_double()
  } catch {
    _ => 0.0
  }
}

///|
fn env_pos_int(name : String, dflt : Int) -> Int {
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
fn dmax(a : Double, b : Double) -> Double {
  if a > b {
    a
  } else {
    b
  }
}

///|
fn main_impl() -> Unit {
  let f = @simcluster.fmt_fixed
  println("=== calibrate: measured operator costs (this host) ===")
  // ---- 1) 向量算子：dot / l2sq（128 维、768 维）----
  let a128 = gen_vecs(1, 128, 11U)
  let b128 = gen_vecs(1, 128, 22U)
  let a768 = gen_vecs(1, 768, 33U)
  let b768 = gen_vecs(1, 768, 44U)
  let dot128_us = bench_us(BENCH_WARMUP, BENCH_ROUNDS, 4000, fn() {
    @core.dot_f32(a128, 0, b128, 0, 128)
  })
  let l2_128_us = bench_us(BENCH_WARMUP, BENCH_ROUNDS, 4000, fn() {
    @core.l2sq_f32(a128, 0, b128, 0, 128)
  })
  let dot768_us = bench_us(BENCH_WARMUP, BENCH_ROUNDS, 2000, fn() {
    @core.dot_f32(a768, 0, b768, 0, 768)
  })
  let l2_768_us = bench_us(BENCH_WARMUP, BENCH_ROUNDS, 2000, fn() {
    @core.l2sq_f32(a768, 0, b768, 0, 768)
  })
  println(
    "  dot_f32    128d: " +
    f(dot128_us * 1000.0, 1) +
    " ns/op -> " +
    f(dot128_us * 1000.0 / 128.0, 3) +
    " ns/dim",
  )
  println(
    "  l2sq_f32   128d: " +
    f(l2_128_us * 1000.0, 1) +
    " ns/op -> " +
    f(l2_128_us * 1000.0 / 128.0, 3) +
    " ns/dim",
  )
  println(
    "  dot_f32    768d: " +
    f(dot768_us * 1000.0, 1) +
    " ns/op -> " +
    f(dot768_us * 1000.0 / 768.0, 3) +
    " ns/dim",
  )
  println(
    "  l2sq_f32   768d: " +
    f(l2_768_us * 1000.0, 1) +
    " ns/op -> " +
    f(l2_768_us * 1000.0 / 768.0, 3) +
    " ns/dim",
  )
  // ---- 2) 段编码 / 解码（64 行 × 128 维）----
  let vecs = gen_vecs(SLAB_ROWS, SLAB_DIM, 55U)
  let mut slab_bytes = Bytes::make(0, b'\x00')
  let encode_us = bench_us(BENCH_WARMUP, BENCH_ROUNDS, 200, fn() {
    let (bs, _idx) = @format.encode_slab(make_components(SLAB_ROWS, SLAB_DIM, vecs))
    slab_bytes = bs
    bs.length().to_double()
  })
  let decode_us = bench_us(BENCH_WARMUP, BENCH_ROUNDS, 300, fn() {
    decode_once(slab_bytes)
  })
  let slab_kb = slab_bytes.length().to_double() / 1024.0
  println(
    "  encode_slab  \{SLAB_ROWS}x\{SLAB_DIM}d: " +
    f(encode_us, 2) +
    " us (" +
    f(slab_kb, 1) +
    " KiB, " +
    f(encode_us * 1000.0 / dmax(slab_kb, 0.001), 1) +
    " ns/KiB)",
  )
  println(
    "  decode_slab  \{SLAB_ROWS}x\{SLAB_DIM}d: " +
    f(decode_us, 2) +
    " us (" +
    f(decode_us * 1000.0 / dmax(slab_kb, 0.001), 1) +
    " ns/KiB)",
  )
  // ---- 3) 倒排：roaring 编解码（1000 个 id）----
  let ids = gen_roaring(ROARING_IDS)
  let mut roaring_bytes = Bytes::make(0, b'\x00')
  let roaring_enc_us = bench_us(BENCH_WARMUP, BENCH_ROUNDS, 500, fn() {
    let bs = @format.encode_roaring(ids)
    roaring_bytes = bs
    bs.length().to_double()
  })
  let roaring_dec_us = bench_us(BENCH_WARMUP, BENCH_ROUNDS, 500, fn() {
    decode_roaring_once(roaring_bytes)
  })
  println(
    "  encode_roaring \{ROARING_IDS} ids: " +
    f(roaring_enc_us, 2) +
    " us -> " +
    f(roaring_enc_us * 1000.0 / ROARING_IDS.to_double(), 2) +
    " ns/id",
  )
  println(
    "  decode_roaring \{ROARING_IDS} ids: " +
    f(roaring_dec_us, 2) +
    " us -> " +
    f(roaring_dec_us * 1000.0 / ROARING_IDS.to_double(), 2) +
    " ns/id",
  )
  // ---- 4) 压缩合并：3 段 × 64 行 ----
  let slabs : Array[Bytes] = [slab_bytes, slab_bytes, slab_bytes]
  let compact_us = bench_us(BENCH_WARMUP, BENCH_ROUNDS, 100, fn() {
    compact_once(slabs, SLAB_ROWS, SLAB_DIM)
  })
  let merged_rows = (SLAB_ROWS * 3).to_double()
  println(
    "  compact_merge 3x\{SLAB_ROWS} rows: " +
    f(compact_us, 2) +
    " us -> " +
    f(compact_us / merged_rows, 3) +
    " us/doc",
  )
  // ---- 5) 组装 CpuProfile（只做正值下限保护，避免零/负成本把仿真变成无意义）----
  let profile : @simcluster.CpuProfile = {
    vec_dot_ns_per_dim: dmax(dot128_us * 1000.0 / 128.0, 0.01),
    bm25_posting_ns: dmax(roaring_dec_us * 1000.0 / ROARING_IDS.to_double(), 0.01),
    slab_decode_ns_per_kb: dmax(
      decode_us * 1000.0 / dmax(slab_kb, 0.001),
      0.01,
    ),
    ingest_doc_us: dmax(encode_us / SLAB_ROWS.to_double(), 0.001),
    compact_doc_us: dmax(
      dmax(compact_us / merged_rows, encode_us / SLAB_ROWS.to_double()),
      0.001,
    ),
  }
  println("")
  println("=== CpuProfile (JSON) ===")
  println(profile.to_json_string())
  // ---- 6) 旧架构 vs 新架构 ----
  let rates = @simstore.BillRates::aws_default()
  let legacy : @simcluster.ClusterSimConfig = {
    ..@simcluster.ClusterSimConfig::legacy(rates),
    cpu: profile,
  }
  let modern : @simcluster.ClusterSimConfig = {
    ..@simcluster.ClusterSimConfig::modern(rates),
    cpu: profile,
  }
  let duration = env_pos_int("CALIBRATE_DURATION_SEC", 30).to_double()
  let qps = env_pos_int("CALIBRATE_QPS", 400).to_double()
  let write_rps = env_pos_int("CALIBRATE_WRITE_RPS", 1000).to_double()
  let wl : @simcluster.WorkloadSpec = {
    ..@simcluster.WorkloadSpec::kv_mixed(),
    duration_sec: duration,
    query_qps: qps,
    write_rps: write_rps,
  }
  println(
    "=== workload: " +
    f(duration, 0) +
    "s, query " +
    f(qps, 0) +
    " qps, write " +
    f(write_rps, 0) +
    " rps x " +
    wl.rows_per_write.to_string() +
    " rows, " +
    wl.total_docs.to_string() +
    " docs, dim " +
    wl.dim.to_string() +
    ", tenants " +
    wl.num_tenants.to_string() +
    ", cache hit " +
    f(wl.cache_hit_ratio * 100.0, 0) +
    "% ===",
  )
  let old = @simcluster.run_cluster_sim(legacy, wl)
  let new = @simcluster.run_cluster_sim(modern, wl)
  println(
    @simcluster.format_comparison_table("legacy", old, "modern", new),
  )
  println(old.format_summary_table())
  println(new.format_summary_table())
}

///|
fn main {
  main_impl()
}
