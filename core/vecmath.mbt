// 向量数学与确定性 PRNG（mulberry32），评分统一走 Double。

///|
pub fn dot_f32(
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
pub fn l2sq_f32(
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
    let d = a[i].to_double() - b[j].to_double()
    s = s + d * d
    i += 1
    j += 1
  }
  s
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
