// HMAC-SHA256（RFC 2104）纯 MoonBit 实现。
// SigV4 签名链（date→region→service→aws4_request）与 string-to-sign 都用它。
// HMAC(K, m) = H((K' ^ opad) || H((K' ^ ipad) || m))，块大小 64 字节（SHA-256）。

///|
const HMAC_BLOCK_SIZE : Int = 64

///|
/// HMAC-SHA256 摘要（32 字节）
pub fn hmac_sha256(key : Bytes, msg : Bytes) -> Bytes {
  // 1. key 规范化：长于块大小先哈希；不足块大小右侧补 0
  let k = if key.length() > HMAC_BLOCK_SIZE { sha256(key) } else { key }
  let kb : FixedArray[Byte] = FixedArray::make(HMAC_BLOCK_SIZE, b'\x00')
  let karr = k.to_fixedarray()
  let kn = if karr.length() < HMAC_BLOCK_SIZE {
    karr.length()
  } else {
    HMAC_BLOCK_SIZE
  }
  for i in 0..<kn {
    kb[i] = karr[i]
  }
  // 2. ipad(0x36) / opad(0x5c)
  let inner = Buffer()
  let outer = Buffer()
  for i in 0..<HMAC_BLOCK_SIZE {
    inner.write_byte((kb[i].to_uint() ^ 0x36U).to_byte())
    outer.write_byte((kb[i].to_uint() ^ 0x5cU).to_byte())
  }
  inner.write_bytes(msg.view())
  outer.write_bytes(sha256(inner.to_bytes()).view())
  sha256(outer.to_bytes())
}

///|
/// HMAC-SHA256 小写 hex 摘要
pub fn hmac_sha256_hex(key : Bytes, msg : Bytes) -> String {
  bytes_to_hex(hmac_sha256(key, msg))
}
