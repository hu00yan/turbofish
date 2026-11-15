// Roaring bitmap（tombstone 压缩存储）。
//
// 标准 roaring 的简化版：按高 48 位分 container，low 16 位落在容器内：
//   - array container：low u16 升序（< 4096 个值）
//   - bitmap container：1024 × u64（>= 4096 个值）
// 不实现 run container（对本项目的 tombstone 规模收益有限）。
//
// 二进制布局：
//   [0..8)   magic "SPNDROAR"
//   [8..12)  container_count u32
//   per container:
//     high u64（id >> 16）+ type u8（0=array, 1=bitmap）+ count u32
//     array  : count × u16（low）
//     bitmap : 1024 × u64
// 输入 ids 必须已升序去重（delete_docs 保证）。

///|
pub const ROAR_MAGIC : String = "SPNDROAR"

///|
const ROAR_ARRAY_MAX : Int = 4096

///|
fn push_roaring_container(b : Buffer, high : UInt64, lows : Array[Int]) -> Unit {
  b.write_uint64_le(high)
  if lows.length() < ROAR_ARRAY_MAX {
    b.write_byte(b'\x00')
    b.write_uint_le(lows.length().reinterpret_as_uint())
    for lo in lows {
      b.write_uint16_le(lo.to_uint16())
    }
  } else {
    b.write_byte(b'\x01')
    b.write_uint_le(lows.length().reinterpret_as_uint())
    let words : Array[UInt64] = Array(capacity=1024)
    for _ in 0..<1024 {
      words.push(0UL)
    }
    for lo in lows {
      let w = lo / 64
      words[w] = words[w] | (1UL << (lo % 64))
    }
    for w in words {
      b.write_uint64_le(w)
    }
  }
}

///|
/// 编码升序去重的 u64 id 集合。
pub fn encode_roaring(ids : Array[UInt64]) -> Bytes {
  let b = Buffer()
  b.write_string_utf8(ROAR_MAGIC)
  // 按高 48 位分组（low = id & 0xFFFF）
  let highs : Array[UInt64] = Array()
  let groups : Array[Array[Int]] = Array()
  for id in ids {
    let high = id >> 16
    let low = (id & 0xFFFFUL).to_int()
    if highs.is_empty() || highs[highs.length() - 1] != high {
      highs.push(high)
      groups.push(Array())
    }
    groups[groups.length() - 1].push(low)
  }
  b.write_uint_le(groups.length().reinterpret_as_uint())
  for i in 0..<groups.length() {
    push_roaring_container(b, highs[i], groups[i])
  }
  b.to_bytes()
}

///|
/// 解码为升序 u64 数组。
pub fn decode_roaring(bs : Bytes) -> Array[UInt64] raise @core.SpndError {
  @core.check_magic(bs, ROAR_MAGIC)
  let fa = bs.to_fixedarray()
  let count = fa_i32(fa, 8)
  if count < 0 {
    raise @core.Corrupt("roaring container_count")
  }
  let out : Array[UInt64] = Array()
  let mut pos = 12
  for _ in 0..<count {
    if pos + 13 > bs.length() {
      raise @core.Truncated("roaring container header")
    }
    let high = fa_u64(fa, pos)
    pos += 8
    let typ = fa[pos].to_int()
    pos += 1
    let n = fa_i32(fa, pos)
    pos += 4
    if n < 0 {
      raise @core.Corrupt("roaring container count")
    }
    let high64 = high << 16
    if typ == 0 {
      if pos + n * 2 > bs.length() {
        raise @core.Truncated("roaring array container")
      }
      for i in 0..<n {
        out.push(high64 | fa_u16(fa, pos + i * 2).to_uint64())
      }
      pos += n * 2
    } else if typ == 1 {
      if pos + 8192 > bs.length() {
        raise @core.Truncated("roaring bitmap container")
      }
      for w in 0..<1024 {
        let word = fa_u64(fa, pos + w * 8)
        if word != 0UL {
          for bit in 0..<64 {
            if ((word >> bit) & 1UL) != 0UL {
              out.push(high64 | (w * 64 + bit).to_uint64())
            }
          }
        }
      }
      pos += 8192
    } else {
      raise @core.Corrupt("roaring container type \{typ}")
    }
  }
  out
}

///|
/// 高速测试 id 是否存在于 Roaring Bitmap 字节序列中。
/// 不分配完整 Array[UInt64]，直接就地二分/位测试。
pub fn roaring_contains(bs : Bytes, id : UInt64) -> Bool {
  if bs.length() < 12 {
    return false
  }
  let magic_match = bs.length() >= 8 &&
    bs[0] == b'S' &&
    bs[1] == b'P' &&
    bs[2] == b'N' &&
    bs[3] == b'D' &&
    bs[4] == b'R' &&
    bs[5] == b'O' &&
    bs[6] == b'A' &&
    bs[7] == b'R'
  if !magic_match {
    return false
  }
  let fa = bs.to_fixedarray()
  let count = fa_i32(fa, 8)
  if count <= 0 {
    return false
  }
  let target_high = id >> 16
  let target_low = (id & 0xFFFFUL).to_int()
  let mut pos = 12
  for _ in 0..<count {
    if pos + 13 > bs.length() {
      return false
    }
    let high = fa_u64(fa, pos)
    pos += 8
    let typ = fa[pos].to_int()
    pos += 1
    let n = fa_i32(fa, pos)
    pos += 4
    if n < 0 {
      return false
    }
    if high == target_high {
      if typ == 0 {
        if pos + n * 2 > bs.length() {
          return false
        }
        let mut lo = 0
        let mut hi = n - 1
        while lo <= hi {
          let mid = (lo + hi) / 2
          let v = fa_u16(fa, pos + mid * 2)
          if v == target_low {
            return true
          }
          if v < target_low {
            lo = mid + 1
          } else {
            hi = mid - 1
          }
        }
        return false
      } else if typ == 1 {
        if pos + 8192 > bs.length() {
          return false
        }
        let w = target_low / 64
        let bit = target_low % 64
        let word = fa_u64(fa, pos + w * 8)
        return ((word >> bit) & 1UL) != 0UL
      } else {
        return false
      }
    } else if high > target_high {
      return false
    } else {
      if typ == 0 {
        pos += n * 2
      } else if typ == 1 {
        pos += 8192
      } else {
        return false
      }
    }
  }
  false
}

