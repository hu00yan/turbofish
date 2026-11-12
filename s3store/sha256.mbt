// SHA-256（FIPS 180-4）纯 MoonBit 实现。
// core 没有密码学哈希，SigV4 需要 SHA-256（payload hash + canonical request hash）。
// - 输入 Bytes，输出 32 字节摘要（sha256）或小写 hex 串（sha256_hex）
// - 8×32 位状态 + 64 项轮常量表 K，全部 UInt 移位/异或/模加（2^32 自然回绕）

///|
/// 轮常量表 K（FIPS 180-4 §4.2.2：前 64 个素数的立方根小数部分前 32 位）
let k256 : Array[UInt] = [
  0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU, 0x59f111f1U, 0x923f82a4U,
  0xab1c5ed5U, 0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U, 0x72be5d74U, 0x80deb1feU,
  0x9bdc06a7U, 0xc19bf174U, 0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU, 0x2de92c6fU,
  0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU, 0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U,
  0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U, 0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU,
  0x53380d13U, 0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U, 0xa2bfe8a1U, 0xa81a664bU,
  0xc24b8b70U, 0xc76c51a3U, 0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U, 0x19a4c116U,
  0x1e376c08U, 0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
  0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U, 0x90befffaU, 0xa4506cebU, 0xbef9a3f7U,
  0xc67178f2U,
]

///|
fn rotr32(x : UInt, n : Int) -> UInt {
  (x >> n) | (x << (32 - n))
}

///|
/// SHA-256 摘要（32 字节）
pub fn sha256(data : Bytes) -> Bytes {
  let msg = data.to_fixedarray()
  let len = msg.length()
  // 填充：msg + 0x80 + 0x00.. + 64 位大端比特长度，总长为 64 的倍数
  let padded_len = (len + 9 + 63) / 64 * 64
  let padded : FixedArray[Byte] = FixedArray::make(padded_len, b'\x00')
  for i in 0..<len {
    padded[i] = msg[i]
  }
  padded[len] = b'\x80'
  let bits = len.to_uint64() * 8UL
  for i in 0..<8 {
    padded[padded_len - 1 - i] = ((bits >> (i * 8)) & 0xFFUL).to_byte()
  }
  // 初始哈希值（FIPS 180-4 §5.3.3）
  let mut h0 = 0x6a09e667U
  let mut h1 = 0xbb67ae85U
  let mut h2 = 0x3c6ef372U
  let mut h3 = 0xa54ff53aU
  let mut h4 = 0x510e527fU
  let mut h5 = 0x9b05688cU
  let mut h6 = 0x1f83d9abU
  let mut h7 = 0x5be0cd19U
  let w : Array[UInt] = Array::make(64, 0U)
  let n_blocks = padded_len / 64
  for blk in 0..<n_blocks {
    let base = blk * 64
    // 消息调度：前 16 字大端取值，其余扩展
    for t in 0..<16 {
      let i = base + t * 4
      w[t] = (padded[i].to_uint() << 24) |
        (padded[i + 1].to_uint() << 16) |
        (padded[i + 2].to_uint() << 8) |
        padded[i + 3].to_uint()
    }
    for t in 16..<64 {
      let wt15 = w[t - 15]
      let wt2 = w[t - 2]
      let s0 = rotr32(wt15, 7) ^ rotr32(wt15, 18) ^ (wt15 >> 3)
      let s1 = rotr32(wt2, 17) ^ rotr32(wt2, 19) ^ (wt2 >> 10)
      w[t] = w[t - 16] + s0 + w[t - 7] + s1
    }
    // 压缩
    let mut a = h0
    let mut b = h1
    let mut c = h2
    let mut d = h3
    let mut e = h4
    let mut f = h5
    let mut g = h6
    let mut h = h7
    for t in 0..<64 {
      let s1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)
      let ch = (e & f) ^ (e.lnot() & g)
      let temp1 = h + s1 + ch + k256[t] + w[t]
      let s0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)
      let maj = (a & b) ^ (a & c) ^ (b & c)
      let temp2 = s0 + maj
      h = g
      g = f
      f = e
      e = d + temp1
      d = c
      c = b
      b = a
      a = temp1 + temp2
    }
    h0 = h0 + a
    h1 = h1 + b
    h2 = h2 + c
    h3 = h3 + d
    h4 = h4 + e
    h5 = h5 + f
    h6 = h6 + g
    h7 = h7 + h
  }
  // 输出大端 32 字节
  let out : FixedArray[Byte] = FixedArray::make(32, b'\x00')
  let hs = [h0, h1, h2, h3, h4, h5, h6, h7]
  for i in 0..<8 {
    let v = hs[i]
    out[i * 4] = (v >> 24).to_byte()
    out[i * 4 + 1] = ((v >> 16) & 0xFFU).to_byte()
    out[i * 4 + 2] = ((v >> 8) & 0xFFU).to_byte()
    out[i * 4 + 3] = (v & 0xFFU).to_byte()
  }
  Bytes::from_array(out)
}

///|
/// hex 编码单个字节值（0..15 → '0'..'f'）
fn hex_digit(v : Int) -> Char {
  if v < 10 {
    (48 + v).unsafe_to_char()
  } else {
    (87 + v).unsafe_to_char()
  }
}

///|
/// 字节序列的小写 hex 编码
pub fn bytes_to_hex(data : Bytes) -> String {
  let arr = data.to_fixedarray()
  let n = arr.length()
  let chars = Array::makei(n * 2, i => {
    let b = arr[i / 2].to_int()
    let v = if i % 2 == 0 { (b >> 4) & 0xF } else { b & 0xF }
    hex_digit(v)
  })
  String::from_array(chars.view())
}

///|
/// SHA-256 小写 hex 摘要
pub fn sha256_hex(data : Bytes) -> String {
  bytes_to_hex(sha256(data))
}
