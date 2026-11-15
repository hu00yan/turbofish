// 向量数学与确定性 PRNG（mulberry32），评分统一走 Double。

///|
pub fn dot_f32(
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

///|
pub fn l2sq_f32(
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
    let d0 = a[ai + i].to_double() - b[bi + i].to_double()
    s0 = s0 + d0 * d0
    let d1 = a[ai + i + 1].to_double() - b[bi + i + 1].to_double()
    s1 = s1 + d1 * d1
    let d2 = a[ai + i + 2].to_double() - b[bi + i + 2].to_double()
    s2 = s2 + d2 * d2
    let d3 = a[ai + i + 3].to_double() - b[bi + i + 3].to_double()
    s3 = s3 + d3 * d3
    let d4 = a[ai + i + 4].to_double() - b[bi + i + 4].to_double()
    s4 = s4 + d4 * d4
    let d5 = a[ai + i + 5].to_double() - b[bi + i + 5].to_double()
    s5 = s5 + d5 * d5
    let d6 = a[ai + i + 6].to_double() - b[bi + i + 6].to_double()
    s6 = s6 + d6 * d6
    let d7 = a[ai + i + 7].to_double() - b[bi + i + 7].to_double()
    s7 = s7 + d7 * d7
    i += 8
  }
  while i < dim {
    let d = a[ai + i].to_double() - b[bi + i].to_double()
    s0 = s0 + d * d
    i += 1
  }
  s0 + s1 + (s2 + s3) + (s4 + s5 + (s6 + s7))
}

///|
pub fn norm_f32(a : Array[Float], ai : Int, dim : Int) -> Double {
  let mut s : Double = 0.0
  for i in ai..<(ai + dim) {
    s = s + a[i].to_double() * a[i].to_double()
  }
  s.sqrt()
}

///|
pub fn cosine_dist_f32(
  a : Array[Float],
  ai : Int,
  b : Array[Float],
  bi : Int,
  dim : Int,
) -> Double {
  let d = dot_f32(a, ai, b, bi, dim)
  let na = norm_f32(a, ai, dim)
  let nb = norm_f32(b, bi, dim)
  if na == 0.0 || nb == 0.0 {
    return 1.0
  }
  1.0 - d / (na * nb)
}

///|
pub struct Rng {
  mut state : UInt
}

///|
pub fn Rng::new(seed : UInt) -> Rng {
  { state: seed }
}

///|
pub fn Rng::next_u32(self : Rng) -> UInt {
  self.state = self.state + 0x6D2B79F5U
  let mut t = self.state
  t = (t ^ (t >> 15)) * (t | 1U)
  t = t ^ (t + (t ^ (t >> 7)) * (t | 61U))
  t ^ (t >> 14)
}

///|
pub fn Rng::next_f64(self : Rng) -> Double {
  self.next_u32().to_double() / 4294967296.0
}

///|
pub fn Rng::next_range(self : Rng, lo : Double, hi : Double) -> Double {
  lo + (hi - lo) * self.next_f64()
}

///|
test "rng deterministic" {
  let r1 = Rng::new(42U)
  let r2 = Rng::new(42U)
  for _ in 0..<10 {
    assert_eq(r1.next_u32(), r2.next_u32())
  }
}

///|
test "dot cosine" {
  let a : Array[Float] = [1.0, 2.0, 3.0]
  let b : Array[Float] = [4.0, 5.0, 6.0]
  assert_eq(dot_f32(a, 0, b, 0, 3), 32.0)
  let d = cosine_dist_f32(a, 0, a, 0, 3)
  assert_eq(d < 1.0e-9, true)
}

///|
test "unroll8 dot and l2sq various dims" {
  // 验证不同维度下 unroll8 与标量循环的数值一致性：
  // 包括 0, 1, 7（小于8）, 8（恰好8）, 9（8+1）, 15, 16（2*8）, 25, 128
  let test_dims = [0, 1, 2, 7, 8, 9, 15, 16, 25, 64, 128]
  let rng = Rng::new(12345U)
  for dim in test_dims {
    let a : Array[Float] = Array(capacity=dim + 4)
    let b : Array[Float] = Array(capacity=dim + 4)
    // 前置 padding 模拟 offset > 0
    for _ in 0..<2 {
      a.push(0.0)
      b.push(0.0)
    }
    for _ in 0..<dim {
      a.push(Float::from_double(rng.next_range(-10.0, 10.0)))
      b.push(Float::from_double(rng.next_range(-10.0, 10.0)))
    }
    let ai = 2
    let bi = 2

    // 标量基准计算
    let mut exp_dot = 0.0
    let mut exp_l2sq = 0.0
    for k in 0..<dim {
      let ak = a[ai + k].to_double()
      let bk = b[bi + k].to_double()
      exp_dot += ak * bk
      let diff = ak - bk
      exp_l2sq += diff * diff
    }

    let act_dot = dot_f32(a, ai, b, bi, dim)
    let act_l2sq = l2sq_f32(a, ai, b, bi, dim)

    let diff_dot = (exp_dot - act_dot).abs()
    let diff_l2sq = (exp_l2sq - act_l2sq).abs()
    assert_eq(diff_dot < 1.0e-9, true)
    assert_eq(diff_l2sq < 1.0e-9, true)
  }
}

