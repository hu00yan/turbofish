// IEEE 754 half-precision (binary16) 位级转换。
// 截断式舍入（round-toward-zero）：对向量检索的量化噪声可接受，MVP 从简。

///|
pub fn f32_to_f16_bits(x : Float) -> UInt16 {
  let u = x.reinterpret_as_uint()
  let sign = (u >> 16) & 0x8000U
  let exp = (u >> 23) & 0xFFU
  let man = u & 0x7FFFFFU
  if exp == 0xFFU {
    // inf / nan
    let m = if man != 0U { 0x0200U } else { 0U }
    return (sign | 0x7C00U | m).to_uint16()
  }
  let e = exp.reinterpret_as_int() - 127 + 15
  if e >= 0x1F {
    // 溢出为 inf
    return (sign | 0x7C00U).to_uint16()
  }
  if e <= 0 {
    // 下溢：e >= -10 走 denormal，否则清零
    if e < -10 {
      return sign.to_uint16()
    }
    let m = man | 0x800000U
    let half = m >> (14 - e)
    return (sign | half).to_uint16()
  }
  (sign | (e.reinterpret_as_uint() << 10) | (man >> 13)).to_uint16()
}

///|
pub fn f16_bits_to_f32(h : UInt16) -> Float {
  let u = h.to_uint()
  let sign = (u & 0x8000U) << 16
  let exp = (u >> 10) & 0x1FU
  let man = u & 0x3FFU
  if exp == 0U {
    if man == 0U {
      return Float::reinterpret_from_uint(sign)
    }
    // denormal：规格化
    let mut e = -14
    let mut m = man
    while (m & 0x400U) == 0U {
      m = m << 1
      e -= 1
    }
    let e2 = e + 127
    return Float::reinterpret_from_uint(
      sign | (e2.reinterpret_as_uint() << 23) | ((m & 0x3FFU) << 13),
    )
  }
  if exp == 0x1FU {
    return Float::reinterpret_from_uint(sign | 0x7F800000U | (man << 13))
  }
  Float::reinterpret_from_uint(sign | ((exp + 112U) << 23) | (man << 13))
}

///|
test "f16 roundtrip includes subnormal range" {
  // 归一化向量的分量常在 1e-6~1e-2；覆盖 f16 次正规数边界
  let vals : Array[Float] = [
    0.0, 1.0, -1.0, 0.5, 0.04, 0.001, 1.0e-4, 3.57e-6, -3.57e-6, 6.1e-5, 6.0e-8,
    65504.0,
  ]
  for v in vals {
    let h = f32_to_f16_bits(v)
    let back = f16_bits_to_f32(h)
    let err = (back.to_double() - v.to_double()).abs()
    let tol = if v.to_double().abs() < 1.0e-4 {
      1.0e-6
    } else {
      v.to_double().abs() * 0.01 + 1.0e-6
    }
    assert_eq(err <= tol, true)
  }
}
