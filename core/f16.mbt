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
  let e = exp.to_int() - 127 + 15
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
    let half = m >> (1 - e)
    return (sign | half).to_uint16()
  }
  (sign | (e.to_uint() << 10) | (man >> 13)).to_uint16()
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
    let mut e = -1
    let mut m = man
    while (m & 0x400U) == 0U {
      m = m << 1
      e -= 1
    }
    let e2 = e + 127
    return Float::reinterpret_from_uint(
      sign | (e2.to_uint() << 23) | ((m & 0x3FFU) << 13),
    )
  }
  if exp == 0x1FU {
    return Float::reinterpret_from_uint(sign | 0x7F800000U | (man << 13))
  }
  Float::reinterpret_from_uint(sign | ((exp + 112U) << 23) | (man << 13))
}
