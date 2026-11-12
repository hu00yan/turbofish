///|
using @test {assert_eq}

// 二进制小端读写原语。所有 seekpond/v1 数值字段均为 little-endian。
// 注意：MoonBit 的 String::to_bytes 是 UTF-16LE 且已废弃；任何字符串 → 字节
// 一律走 @utf8.encode，字节 → 字符串一律走 @utf8.decode。

///|
fn byte_at(bs : Bytes, pos : Int) -> Int raise SpndError {
  match bs.get(pos) {
    Some(b) => b.to_int()
    None => raise Truncated("read at \{pos}, len=\{bs.length()}")
  }
}

///|
pub fn magic_bytes(magic : String) -> Bytes {
  @utf8.encode(magic)
}

///|
pub fn read_u16_le(bs : Bytes, pos : Int) -> UInt16 raise SpndError {
  (byte_at(bs, pos) | (byte_at(bs, pos + 1) << 8)).to_uint16()
}

///|
pub fn read_u32_le(bs : Bytes, pos : Int) -> UInt raise SpndError {
  byte_at(bs, pos).reinterpret_as_uint() |
  (byte_at(bs, pos + 1).reinterpret_as_uint() << 8) |
  (byte_at(bs, pos + 2).reinterpret_as_uint() << 16) |
  (byte_at(bs, pos + 3).reinterpret_as_uint() << 24)
}

///|
pub fn read_i32_le(bs : Bytes, pos : Int) -> Int raise SpndError {
  read_u32_le(bs, pos).reinterpret_as_int()
}

///|
pub fn read_u64_le(bs : Bytes, pos : Int) -> UInt64 raise SpndError {
  byte_at(bs, pos).to_uint64() |
  (byte_at(bs, pos + 1).to_uint64() << 8) |
  (byte_at(bs, pos + 2).to_uint64() << 16) |
  (byte_at(bs, pos + 3).to_uint64() << 24) |
  (byte_at(bs, pos + 4).to_uint64() << 32) |
  (byte_at(bs, pos + 5).to_uint64() << 40) |
  (byte_at(bs, pos + 6).to_uint64() << 48) |
  (byte_at(bs, pos + 7).to_uint64() << 56)
}

///|
pub fn read_i64_le(bs : Bytes, pos : Int) -> Int64 raise SpndError {
  read_u64_le(bs, pos).reinterpret_as_int64()
}

///|
pub fn read_f32_le(bs : Bytes, pos : Int) -> Float raise SpndError {
  Float::reinterpret_from_uint(read_u32_le(bs, pos))
}

///|
pub fn read_uvarint(bs : Bytes, pos : Int) -> (UInt, Int) raise SpndError {
  let mut result : UInt = 0U
  let mut shift = 0
  let mut p = pos
  while true {
    if p >= bs.length() {
      raise Truncated("uvarint starting at \{pos}")
    }
    let b = byte_at(bs, p)
    p = p + 1
    result = result | ((b & 0x7F).reinterpret_as_uint() << shift)
    if (b & 0x80) == 0 {
      break
    }
    shift += 7
    if shift > 28 {
      raise Corrupt("uvarint too long starting at \{pos}")
    }
  }
  (result, p)
}

///|
pub fn write_uvarint(b : Buffer, v : UInt) -> Unit {
  let mut x = v
  while x >= 0x80U {
    b.write_byte(((x & 0x7FU) | 0x80U).to_byte())
    x = x >> 7
  }
  b.write_byte(x.to_byte())
}

///|
pub fn check_magic(bs : Bytes, magic : String) -> Unit raise SpndError {
  let m = magic_bytes(magic)
  if bs.length() < m.length() {
    raise Truncated("magic \{magic}")
  }
  for i in 0..<m.length() {
    if byte_at(bs, i) != byte_at(m, i) {
      raise BadMagic("expected \{magic}")
    }
  }
}

///|
test "u32/u64/uvarint roundtrip" {
  let b = Buffer()
  b.write_uint_le(0x89ABCDEFU)
  b.write_uint64_le(0x123456789ABCDEFUL)
  write_uvarint(b, 0U)
  write_uvarint(b, 127U)
  write_uvarint(b, 128U)
  write_uvarint(b, 300U)
  write_uvarint(b, 0xFFFFFFU)
  let bs = b.to_bytes()
  assert_eq(read_u32_le(bs, 0), 0x89ABCDEFU)
  assert_eq(read_u64_le(bs, 4), 0x123456789ABCDEFUL)
  let (v, p) = read_uvarint(bs, 12)
  assert_eq(v, 0U)
  let (v2, p2) = read_uvarint(bs, p)
  assert_eq(v2, 127U)
  let (v3, p3) = read_uvarint(bs, p2)
  assert_eq(v3, 128U)
  let (v4, p4) = read_uvarint(bs, p3)
  assert_eq(v4, 300U)
  let (v5, _) = read_uvarint(bs, p4)
  assert_eq(v5, 0xFFFFFFU)
}

///|
test "magic check" {
  let b = Buffer()
  b.write_string_utf8("SPNDCOL1")
  b.write_byte(b'\x00')
  check_magic(b.to_bytes(), "SPNDCOL1")
  try {
    check_magic(b.to_bytes(), "SPNDVEC1")
    panic()
  } catch {
    _ => ()
  }
}
