// D：解码热路径的批量化读取原语。
//
// `Bytes::get(i) -> Byte?` 每字节产生一次 Option，是 decode 的主要开销。
// 这里把 Bytes 一次性转成 FixedArray[Byte]（O(n) 拷贝在计时区外/可接受），
// 然后用下标直取拼小端整数——热循环内无 Option、无逐字节 raise。

///|
fn fa_u16(fa : FixedArray[Byte], pos : Int) -> Int {
  fa[pos].to_int() | (fa[pos + 1].to_int() << 8)
}

///|
fn fa_u32(fa : FixedArray[Byte], pos : Int) -> UInt {
  fa[pos].to_int().reinterpret_as_uint() |
  (fa[pos + 1].to_int().reinterpret_as_uint() << 8) |
  (fa[pos + 2].to_int().reinterpret_as_uint() << 16) |
  (fa[pos + 3].to_int().reinterpret_as_uint() << 24)
}

///|
fn fa_i32(fa : FixedArray[Byte], pos : Int) -> Int {
  fa_u32(fa, pos).reinterpret_as_int()
}

///|
fn fa_u64(fa : FixedArray[Byte], pos : Int) -> UInt64 {
  fa[pos].to_int().to_uint64() |
  (fa[pos + 1].to_int().to_uint64() << 8) |
  (fa[pos + 2].to_int().to_uint64() << 16) |
  (fa[pos + 3].to_int().to_uint64() << 24) |
  (fa[pos + 4].to_int().to_uint64() << 32) |
  (fa[pos + 5].to_int().to_uint64() << 40) |
  (fa[pos + 6].to_int().to_uint64() << 48) |
  (fa[pos + 7].to_int().to_uint64() << 56)
}

///|
fn fa_i64(fa : FixedArray[Byte], pos : Int) -> Int64 {
  fa_u64(fa, pos).reinterpret_as_int64()
}

///|
fn fa_f32(fa : FixedArray[Byte], pos : Int) -> Float {
  Float::reinterpret_from_uint(fa_u32(fa, pos))
}

///|
/// 从 FixedArray 解一个 uvarint，返回 (值, 新位置)。调用方保证 pos < len。
pub fn fa_uvarint(
  fa : FixedArray[Byte],
  pos : Int,
  end : Int,
) -> (UInt, Int) raise @core.SpndError {
  let mut result : UInt = 0U
  let mut shift = 0
  let mut p = pos
  while true {
    if p >= end {
      raise @core.Truncated("uvarint at \{pos}")
    }
    let b = fa[p].to_int()
    p = p + 1
    result = result | ((b & 0x7F).reinterpret_as_uint() << shift)
    if (b & 0x80) == 0 {
      break
    }
    shift += 7
    if shift > 28 {
      raise @core.Corrupt("uvarint too long at \{pos}")
    }
  }
  (result, p)
}
