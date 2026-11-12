///|
using @test {assert_eq}

// benchx/benchx_wbtest.mbt —— 白盒测试：FFI 探针 + 数值一致性断言 + bench 数字输出。
// 运行：
//   moon test -p turbofish/benchx                            （默认 wasm-gc，C 内核行 N/A）
//   moon test -p turbofish/benchx --target native --release  （native 数字，RESULTS.md 用这个）

///|
test "probe add2" {
  // native：真 C 符号；其他后端：同语义桩。两边都应等于 42。
  assert_eq(probe_add2(20, 22), 42)
}

///|
test "probe f32/f64/mix/buf roundtrip" {
  assert_eq(probe_echo_f32(1.5), 2.5)
  assert_eq(probe_echo_f64(2.5), 3.5)
  // (Int, Float, Int) 混合传参：1+2+round(10.4)=13
  assert_eq(probe_mix(1, 10.4, 2), 13)
  // 缓冲写读回环
  assert_eq(probe_buf_roundtrip(3.25), 3.25)
}

///|
test "dot versions agree <1e-3" {
  // 各版本逐点互差 < 1e-3（double 累加版本之间应 ~1e-12 量级）。
  let rng = @core.Rng::new(7U)
  let a = gen_matrix(rng, ROWS, DIM)
  let b = gen_matrix(rng, ROWS, DIM)
  let mut max_diff_u : Double = 0.0
  for k in 0..<DOT_ITERS {
    let i = dot_row_i(k) * DIM
    let j = dot_row_j(k) * DIM
    let d = (dot_scalar(a, i, b, j, DIM) - dot_unroll8(a, i, b, j, DIM)).abs()
    if d > max_diff_u {
      max_diff_u = d
    }
  }
  if max_diff_u >= 1.0e-3 {
    fail("scalar vs unroll8 互差超标: \{max_diff_u}")
  }
  if c_kernel_available() {
    let ca = cmat_new(a, ROWS, DIM)
    let cb = cmat_new(b, ROWS, DIM)
    let mut max_diff_c1 : Double = 0.0
    let mut max_diff_c8 : Double = 0.0
    let mut max_diff_cf : Double = 0.0
    for k in 0..<DOT_ITERS {
      let i = dot_row_i(k)
      let j = dot_row_j(k)
      let s = dot_scalar(a, i * DIM, b, j * DIM, DIM)
      let d1 = (s - cmat_dot(ca, i, cb, j)).abs()
      let d8 = (s - cmat_dot_8acc(ca, i, cb, j)).abs()
      let df = (s - cmat_dot_facc(ca, i, cb, j)).abs()
      if d1 > max_diff_c1 {
        max_diff_c1 = d1
      }
      if d8 > max_diff_c8 {
        max_diff_c8 = d8
      }
      if df > max_diff_cf {
        max_diff_cf = df
      }
    }
    cmat_free(ca)
    cmat_free(cb)
    if max_diff_c1 >= 1.0e-3 {
      fail("scalar vs C scalar 互差超标: \{max_diff_c1}")
    }
    if max_diff_c8 >= 1.0e-3 {
      fail("scalar vs C 8acc 互差超标: \{max_diff_c8}")
    }
    if max_diff_cf >= 1.0e-3 {
      fail("scalar vs C facc 互差超标: \{max_diff_cf}")
    }
  }
}

///|
test "varint batch correctness" {
  let blob = gen_varint_blob()
  let fa = blob.to_fixedarray()
  let (s1, c1) = varint_per_item(blob)
  let (s2, c2) = varint_batch(fa)
  assert_eq(c1, c2)
  assert_eq(c1, VARINT_PAIRS * 2)
  assert_eq(s1, s2)
}

///|
test "varint batch known values" {
  // 含 0 / 1 字节边界 / 2 字节 / 3 字节等已知值，逐条与批量版对照。
  let b = Buffer()
  @core.write_uvarint(b, 0U)
  @core.write_uvarint(b, 127U)
  @core.write_uvarint(b, 128U)
  @core.write_uvarint(b, 300U)
  @core.write_uvarint(b, 0xFFFFFFU)
  let blob = b.to_bytes()
  let fa = blob.to_fixedarray()
  let (s1, c1) = varint_per_item(blob)
  let (s2, c2) = varint_batch(fa)
  assert_eq(c1, c2)
  assert_eq(c1, 5)
  assert_eq(s1, s2)
  assert_eq(s1, 0U + 127U + 128U + 300U + 0xFFFFFFU)
}

///|
test "cmat small dot" {
  // 小矩阵直接对照：2×2，dot(row0,row1)=1*3+2*4=11，dot(row0,row0)=5
  if c_kernel_available() {
    let arr : Array[Float] = [1.0, 2.0, 3.0, 4.0]
    let m = cmat_new(arr, 2, 2)
    assert_eq(cmat_dot(m, 0, m, 1), 11.0)
    assert_eq(cmat_dot(m, 0, m, 0), 5.0)
    cmat_free(m)
  }
}

///|
test "results" {
  // 计时跑法：moon test -p turbofish/benchx（默认 target）
  // 或        moon test -p turbofish/benchx --target native --release（RESULTS.md 口径）
  println(run_all())
}

///|
test "decode micro-bench (D)" {
  println(run_decode_bench())
}
