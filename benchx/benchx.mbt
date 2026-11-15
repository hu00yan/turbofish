// benchx/benchx.mbt — micro-bench 主体。
// bench 1: dot product f32×768（标量 / 8 路展开 / extern "C" C 内核）
// bench 2: varint 批量解码（逐条 read_uvarint / FixedArray 批量扫描）
// 计时：@bench 单调时钟（monotonic_clock_start/end，单位微秒），
//       每项热身 3 轮后测 20 轮取 p50。数字口径见 run_all 输出。

///|
const DIM : Int = 768

///|
const ROWS : Int = 1000

///|
const DOT_ITERS : Int = 100

///|
const WARMUP : Int = 3

///|
const ROUNDS : Int = 20

///|
const VARINT_PAIRS : Int = 10000

///|
/// 定点格式化（正数，digits 位小数），避免依赖 Double Show 的可变长度。
fn fmt_fixed(x : Double, digits : Int) -> String {
  if digits == 3 {
    let n = (x * 1000.0 + 0.5).to_int()
    "\{n / 1000}.\{(n % 1000) / 100}\{(n % 100) / 10}\{n % 10}"
  } else {
    let n = (x * 100.0 + 0.5).to_int()
    "\{n / 100}.\{(n % 100) / 10}\{n % 10}"
  }
}

///|
/// 计时骨架：热身 warmup 轮后测 rounds 轮，每轮跑 iters 次 f（结果累加进
/// 校验和以防被优化掉），返回 (p50 µs/次, 校验和)。
fn bench_p50(
  warmup : Int,
  rounds : Int,
  iters : Int,
  f : () -> Double raise @core.SpndError,
) -> (Double, Double) raise @core.SpndError {
  let mut checksum : Double = 0.0
  for _ in 0..<warmup {
    checksum = checksum + f()
  }
  let ts : Array[Double] = Array::new()
  for _ in 0..<rounds {
    let t0 = @bench.monotonic_clock_start()
    for _ in 0..<iters {
      checksum = checksum + f()
    }
    let dt = @bench.monotonic_clock_end(t0) // 微秒
    ts.push(dt / iters.to_double())
  }
  ts.sort()
  (ts[rounds / 2], checksum)
}

// ---------------- 数据生成（确定性 @core.Rng） ----------------

///|
/// 行主序 float 矩阵（rows 行 × dim 维），值域 [-1, 1)。
fn gen_matrix(rng : @core.Rng, rows : Int, dim : Int) -> Array[Float] {
  let a : Array[Float] = Array::new()
  let n = rows * dim
  for _ in 0..<n {
    a.push(Float::from_double(rng.next_f64() * 2.0 - 1.0))
  }
  a
}

///|
/// 第 k 次迭代用的 A 行号（跨版本一致、确定性）。
fn dot_row_i(k : Int) -> Int {
  (k * 137 + 11) % ROWS
}

///|
/// 第 k 次迭代用的 B 行号。
fn dot_row_j(k : Int) -> Int {
  (k * 419 + 7) % ROWS
}

// ---------------- bench 1: dot product f32×768 ----------------

///|
/// 标量版（照抄 @core.dot_f32 语义：Double 累加、单累加器链式依赖）。
fn dot_scalar(
  a : Array[Float],
  ai : Int,
  b : Array[Float],
  bi : Int,
  dim : Int,
) -> Double {
  let mut s : Double = 0.0
  let end = ai + dim
  let mut i = ai
  let mut j = bi
  while i < end {
    s = s + a[i].to_double() * b[j].to_double()
    i += 1
    j += 1
  }
  s
}

///|
/// 手写 8 路展开：8 个独立 Double 累加器消除链式依赖，尾部标量收尾。
fn dot_unroll8(
  a : Array[Float],
  ai : Int,
  b : Array[Float],
  bi : Int,
  dim : Int,
) -> Double {
  let mut s0 : Double = 0.0
  let mut s1 : Double = 0.0
  let mut s2 : Double = 0.0
  let mut s3 : Double = 0.0
  let mut s4 : Double = 0.0
  let mut s5 : Double = 0.0
  let mut s6 : Double = 0.0
  let mut s7 : Double = 0.0
  let n = dim / 8 * 8
  let mut i = 0
  while i < n {
    s0 = s0 + a[ai + i].to_double() * b[bi + i].to_double()
    s1 = s1 + a[ai + i + 1].to_double() * b[bi + i + 1].to_double()
    s2 = s2 + a[ai + i + 2].to_double() * b[bi + i + 2].to_double()
    s3 = s3 + a[ai + i + 3].to_double() * b[bi + i + 3].to_double()
    s4 = s4 + a[ai + i + 4].to_double() * b[bi + i + 4].to_double()
    s5 = s5 + a[ai + i + 5].to_double() * b[bi + i + 5].to_double()
    s6 = s6 + a[ai + i + 6].to_double() * b[bi + i + 6].to_double()
    s7 = s7 + a[ai + i + 7].to_double() * b[bi + i + 7].to_double()
    i += 8
  }
  while i < dim {
    s0 = s0 + a[ai + i].to_double() * b[bi + i].to_double()
    i += 1
  }
  s0 + s1 + (s2 + s3) + (s4 + s5 + (s6 + s7))
}

// ---------------- bench 2: varint 批量解码 ----------------

///|
/// 生成 VARINT_PAIRS 对 (row_delta, tf) 的 varint 流（row_delta∈[1,60]、
/// tf∈[1,30]，覆盖 1~2 字节 varint，Rng 种子 11U）。
fn gen_varint_blob() -> Bytes {
  let rng = @core.Rng::new(11U)
  let b = Buffer()
  for _ in 0..<VARINT_PAIRS {
    let row_delta = 1U + rng.next_u32() % 60U
    let tf = 1U + rng.next_u32() % 30U
    @core.write_uvarint(b, row_delta)
    @core.write_uvarint(b, tf)
  }
  b.to_bytes()
}

///|
/// a. 逐条 @core.read_uvarint：每字节一次 Option 分配（byte_at→bs.get）、
///    每个 varint 一次 (UInt, Int) 元组分配，且在 raise 上下文逐次调用。
fn varint_per_item(blob : Bytes) -> (UInt, Int) raise @core.SpndError {
  let mut sum : UInt = 0U
  let mut pos = 0
  let mut count = 0
  let len = blob.length()
  while pos < len {
    let (v, p) = @core.read_uvarint(blob, pos)
    sum = sum + v
    pos = p
    count += 1
  }
  (sum, count)
}

///|
/// b. 批量展开：Bytes 一次性转 FixedArray[Byte]（O(n)，转换在计时区外），
///    随后下标直扫：无 Option、无元组、无 raise，逐 varint 推进 index。
fn varint_batch(fa : FixedArray[Byte]) -> (UInt, Int) {
  let len = fa.length()
  let mut sum : UInt = 0U
  let mut count = 0
  let mut p = 0
  while p < len {
    let mut result : UInt = 0U
    let mut shift = 0
    while true {
      let byte = fa[p].to_int()
      p += 1
      result = result | ((byte & 0x7F).reinterpret_as_uint() << shift)
      if (byte & 0x80) == 0 {
        break
      }
      shift += 7
    }
    sum = sum + result
    count += 1
  }
  (sum, count)
}

// ---------------- 汇总入口 ----------------

///|
/// 跑全部 micro-bench，返回汇总文本。
/// dot 的"一次" = 1 个 768 维 dot（µs）；varint 的"一次" = 1 个 varint（ns）。
pub fn run_all() -> String raise @core.SpndError {
  // ---- 数据（确定性）----
  let rng = @core.Rng::new(7U)
  let a = gen_matrix(rng, ROWS, DIM)
  let b = gen_matrix(rng, ROWS, DIM)
  let blob = gen_varint_blob()
  let fa = blob.to_fixedarray()

  let lines : Array[String] = Array::new()
  lines.push(
    "== benchx micro-bench（热身 3 轮 + 计时 20 轮取 p50，@bench 单调时钟；建议用 native --release）==",
  )
  lines.push(
    "C kernel 可用: \{c_kernel_available()}   FFI 探针 add2(20,22)=\{probe_add2(20, 22)}",
  )

  // ---- 版本间数值一致性预检（100 个 dot 逐点 max|Δ|，varint 校验和）----
  let mut max_diff_u : Double = 0.0
  for k in 0..<DOT_ITERS {
    let i = dot_row_i(k) * DIM
    let j = dot_row_j(k) * DIM
    let d = (dot_scalar(a, i, b, j, DIM) - dot_unroll8(a, i, b, j, DIM)).abs()
    if d > max_diff_u {
      max_diff_u = d
    }
  }

  // ---- [1] dot f32×768 ----
  lines.push("")
  lines.push(
    "[1] dot f32×768（1000 行×768 维行主序 Array[Float]，Rng 种子 7U；i=(k*137+11)%1000, j=(k*419+7)%1000）",
  )
  let (p50_s, chk_s) = bench_p50(WARMUP, ROUNDS, 1, fn() {
    let mut acc : Double = 0.0
    for k in 0..<DOT_ITERS {
      acc = acc + dot_scalar(a, dot_row_i(k) * DIM, b, dot_row_j(k) * DIM, DIM)
    }
    acc
  })
  lines.push(
    "  scalar  MoonBit      : \{fmt_fixed(p50_s / DOT_ITERS.to_double(), 3)} µs/dot   checksum=\{fmt_fixed(chk_s, 3)}",
  )
  let (p50_u, chk_u) = bench_p50(WARMUP, ROUNDS, 1, fn() {
    let mut acc : Double = 0.0
    for k in 0..<DOT_ITERS {
      acc = acc + dot_unroll8(a, dot_row_i(k) * DIM, b, dot_row_j(k) * DIM, DIM)
    }
    acc
  })
  lines.push(
    "  unroll8 MoonBit      : \{fmt_fixed(p50_u / DOT_ITERS.to_double(), 3)} µs/dot   checksum=\{fmt_fixed(chk_u, 3)}",
  )
  lines.push(
    "  → 展开/标量 = \{fmt_fixed(p50_s / p50_u, 2)}x（>1 说明消链式依赖有效）",
  )

  let mut p50_c1 = 0.0
  let mut p50_c8 = 0.0
  let mut p50_cf = 0.0
  let mut chk_c = 0.0
  let mut max_diff_c : Double = 0.0
  if c_kernel_available() {
    let ca = cmat_new(a, ROWS, DIM)
    let cb = cmat_new(b, ROWS, DIM)
    // C 标量
    let (p1, k1) = bench_p50(WARMUP, ROUNDS, 1, fn() {
      let mut acc : Double = 0.0
      for k in 0..<DOT_ITERS {
        acc = acc + cmat_dot(ca, dot_row_i(k), cb, dot_row_j(k))
      }
      acc
    })
    p50_c1 = p1
    // C 8 路展开
    let (p8, k8) = bench_p50(WARMUP, ROUNDS, 1, fn() {
      let mut acc : Double = 0.0
      for k in 0..<DOT_ITERS {
        acc = acc + cmat_dot_8acc(ca, dot_row_i(k), cb, dot_row_j(k))
      }
      acc
    })
    p50_c8 = p8
    // C float 累加
    let (pf, kf) = bench_p50(WARMUP, ROUNDS, 1, fn() {
      let mut acc : Double = 0.0
      for k in 0..<DOT_ITERS {
        acc = acc + cmat_dot_facc(ca, dot_row_i(k), cb, dot_row_j(k))
      }
      acc
    })
    p50_cf = pf
    chk_c = k1 + k8 + kf
    lines.push("  C checksum 合计        = \{fmt_fixed(chk_c, 3)}")
    // C 标量 vs MoonBit 标量 逐点 max|Δ|
    for k in 0..<DOT_ITERS {
      let i = dot_row_i(k)
      let j = dot_row_j(k)
      let d = (dot_scalar(a, i * DIM, b, j * DIM, DIM) - cmat_dot(ca, i, cb, j)).abs()
      if d > max_diff_c {
        max_diff_c = d
      }
    }
    cmat_free(ca)
    cmat_free(cb)
    lines.push(
      "  C kernel scalar      : \{fmt_fixed(p50_c1 / DOT_ITERS.to_double(), 3)} µs/dot",
    )
    lines.push(
      "  C kernel 8acc        : \{fmt_fixed(p50_c8 / DOT_ITERS.to_double(), 3)} µs/dot",
    )
    lines.push(
      "  C kernel facc        : \{fmt_fixed(p50_cf / DOT_ITERS.to_double(), 3)} µs/dot（float 累加，精度对照）",
    )
    lines.push(
      "  → C标量/MB标量 = \{fmt_fixed(p50_s / p50_c1, 2)}x   C8acc/C标量 = \{fmt_fixed(p50_c1 / p50_c8, 2)}x",
    )
    lines.push(
      "  数值一致性: |scalar−unroll8| max=\{fmt_fixed(max_diff_u, 3)}  |scalar−C| max=\{fmt_fixed(max_diff_c, 3)}  (断言 <1e-3 见 wbtest)",
    )
  } else {
    lines.push(
      "  C kernel             : N/A（非 native 后端，extern C 不可用）",
    )
  }

  // ---- [2] varint 批量解码 ----
  lines.push("")
  lines.push(
    "[2] varint 批量解码（\{VARINT_PAIRS} 对 row_delta/tf = \{VARINT_PAIRS * 2} 个 varint，1~2 字节，Rng 种子 11U）",
  )
  let (p50_pi, chk_pi) = bench_p50(WARMUP, ROUNDS, 1, fn() raise @core.SpndError {
    let (s, c) = varint_per_item(blob)
    s.to_double() + c.to_double()
  })
  let ns_pi = p50_pi * 1000.0 / (VARINT_PAIRS * 2).to_double()
  lines.push(
    "  per-item read_uvarint : \{fmt_fixed(ns_pi, 2)} ns/个   checksum=\{fmt_fixed(chk_pi, 3)}",
  )
  let (p50_b, chk_b) = bench_p50(WARMUP, ROUNDS, 1, fn() {
    let (s, c) = varint_batch(fa)
    s.to_double() + c.to_double()
  })
  let ns_b = p50_b * 1000.0 / (VARINT_PAIRS * 2).to_double()
  lines.push(
    "  batch FixedArray 扫描 : \{fmt_fixed(ns_b, 2)} ns/个   checksum=\{fmt_fixed(chk_b, 3)}",
  )
  lines.push(
    "  → 加速比 = \{fmt_fixed(ns_pi / ns_b, 2)}x   校验和一致: \{chk_pi == chk_b}",
  )

  // ---- 汇总 ----
  lines.push("")
  lines.push(
    "[summary] 比较 C 内核、展开版与标量版的稳态耗时",
  )

  let mut out = ""
  for line in lines {
    out = "\{out}\{line}\n"
  }
  out
}
