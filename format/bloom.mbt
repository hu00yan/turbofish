// 段级 FTS Bloom filter（嵌入 seg meta.json，避免额外 S3 GET）。
//
// 用途：LSM 式 segment 在查询 term 时先查 Bloom；若不可能存在，直接跳过
// `fts/dir.bin` / postings / doc_len 的读取。数据本身仍只存一份。
//
// 序列化：m（bit 数，64 的倍数）、k（hash 数）、bits 的 hex 字符串。
// 哈希：FNV-1a 64 + 二次混合，双重哈希定位 k 个 bit。

///|
pub(all) struct Bloom {
  m : Int
  k : Int
  bits : FixedArray[UInt64]
}

///|
fn bloom_hash(bytes : FixedArray[Byte]) -> UInt64 {
  let mut h : UInt64 = 14695981039346656037UL
  for i in 0..<bytes.length() {
    h = (h ^ bytes[i].to_int().to_uint64()) * 1099511628211UL
  }
  h
}

///|
fn bloom_mix(h : UInt64) -> UInt64 {
  let mut x = h
  x = x ^ (x >> 33)
  x = x * 0xff51afd7ed558ccdUL
  x = x ^ (x >> 33)
  x = x * 0xc4ceb9fe1a85ec53UL
  x ^ (x >> 33)
}

///|
fn bloom_index(h1 : UInt64, h2 : UInt64, i : Int, m : Int) -> Int {
  ((h1 + i.to_uint64() * h2) % m.to_uint64()).to_int()
}

///|
/// 构建 Bloom：m = max(64, next multiple of 64 >= terms*10)，k=7。
pub fn build_bloom(terms : Array[String], bits_per_term : Int) -> Bloom {
  let uniq : Set[String] = Set([])
  for t in terms {
    uniq.add(t)
  }
  let want = if uniq.length() * bits_per_term > 64 {
    uniq.length() * bits_per_term
  } else {
    64
  }
  let m = (want + 63) / 64 * 64
  let k = 7
  let words : FixedArray[UInt64] = FixedArray::make(m / 64, 0UL)
  for t in uniq {
    let bs = @utf8.encode(t).to_fixedarray()
    let h1 = bloom_hash(bs)
    let h2 = bloom_mix(h1) | 1UL
    for i in 0..<k {
      let bit = bloom_index(h1, h2, i, m)
      words[bit / 64] = words[bit / 64] | (1UL << (bit % 64))
    }
  }
  { m, k, bits: words }
}

///|
pub fn bloom_may_contain(b : Bloom, term : String) -> Bool {
  if b.m <= 0 {
    return false
  }
  let bs = @utf8.encode(term).to_fixedarray()
  let h1 = bloom_hash(bs)
  let h2 = bloom_mix(h1) | 1UL
  for i in 0..<b.k {
    let bit = bloom_index(h1, h2, i, b.m)
    if (b.bits[bit / 64] & (1UL << (bit % 64))) == 0UL {
      return false
    }
  }
  true
}

///|
fn hex_digit(v : Int) -> String {
  let digits : Array[String] = [
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f",
  ]
  digits[v]
}

///|
pub fn bloom_to_hex(b : Bloom) -> String {
  let out = Buffer()
  for w in b.bits {
    for i in 0..<16 {
      let shift = (15 - i) * 4
      out.write_string_utf8(hex_digit(((w >> shift) & 0xFUL).to_int()))
    }
  }
  @utf8.decode(out.to_bytes().exact_view()) catch {
    _ => ""
  }
}

///|
fn hex_val(c : Char) -> Int {
  let v = c.to_int()
  if v >= 48 && v <= 57 {
    v - 48
  } else if v >= 97 && v <= 102 {
    v - 97 + 10
  } else if v >= 65 && v <= 70 {
    v - 65 + 10
  } else {
    -1
  }
}

///|
pub fn bloom_from_hex(
  m : Int,
  k : Int,
  hex : String,
) -> Bloom raise @core.SpndError {
  if m <= 0 || m % 64 != 0 || k <= 0 || hex.length() != m / 64 * 16 {
    raise @core.Corrupt("bad bloom header/hex")
  }
  let chars : Array[Char] = []
  for c in hex {
    chars.push(c)
  }
  let words : FixedArray[UInt64] = FixedArray::make(m / 64, 0UL)
  for w in 0..<(m / 64) {
    let mut x : UInt64 = 0UL
    for i in 0..<16 {
      let v = hex_val(chars[w * 16 + i])
      if v < 0 {
        raise @core.Corrupt("bad bloom hex")
      }
      x = (x << 4) | v.to_uint64()
    }
    words[w] = x
  }
  { m, k, bits: words }
}
