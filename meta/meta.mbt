// 元数据对象判定：这些 key 由元数据服务（metad）承载，查询路径不应回源 S3。
//
// 数据对象（segment 的 vec/ 分片、FTS postings、global IVF 向量分片）不在此列，
// 仍由查询节点直接向对象存储发起读取。

///|
/// 是否为可放入元数据服务的小对象。
pub fn is_metadata_key(key : String) -> Bool {
  if key.has_suffix("/_meta/namespace.json") {
    return true
  }
  if key.has_suffix("/_head_ptr") {
    return true
  }
  if key.contains("/_heads/") {
    return true
  }
  if key.contains("/_manifest/") && key.has_suffix(".json") {
    return true
  }
  if key.contains("/_centroids/") {
    return true
  }
  if key.contains("/_tombstones/") {
    return true
  }
  if key.contains("/_segments/") {
    return key.has_suffix("/meta.json") ||
      key.contains("/rows/") ||
      key.has_suffix("/fts/dir.bin") ||
      key.has_suffix("/fts/doc_len.bin") ||
      key.has_suffix("/fts/blockmax.bin")
  }
  if key.contains("/vec/global/") && key.has_suffix("/meta.json") {
    return true
  }
  false
}

///|
/// 元数据服务的 HTTP 路径前缀。
pub const METAD_KV_PREFIX : String = "/kv/"

// ---------- URL 编解码（/v1/bundle?known_head=... 等查询参数用） ----------

///|
/// RFC 3986 百分号编码：unreserved（字母/数字/-._~）原样保留，其余按 UTF-8
/// 字节编码为 %XX。
pub fn percent_encode(s : String) -> String {
  let hex : Array[Char] = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E',
    'F',
  ]
  let raw = Buffer()
  raw.write_string_utf8(s)
  let bs = raw.to_bytes()
  let out = StringBuilder()
  for i in 0..<bs.length() {
    let c = bs[i].to_int()
    let unreserved = (c >= 65 && c <= 90) ||
      (c >= 97 && c <= 122) ||
      (c >= 48 && c <= 57) ||
      c == 45 ||
      c == 46 ||
      c == 95 ||
      c == 126
    if unreserved {
      out.write_char(bs[i].to_char())
    } else {
      out.write_char('%')
      out.write_char(hex[c / 16])
      out.write_char(hex[c % 16])
    }
  }
  out.to_string()
}

///|
fn hex_digit(c : Char) -> Int? {
  let v = c.to_int()
  if v >= 48 && v <= 57 {
    Some(v - 48)
  } else if v >= 65 && v <= 70 {
    Some(v - 55)
  } else if v >= 97 && v <= 102 {
    Some(v - 87)
  } else {
    None
  }
}

///|
/// 百分号解码（非法转义原样保留）。UTF-8 解码失败时按 lossy 处理。
pub fn percent_decode(s : String) -> String {
  let buf = Buffer()
  let chars = s.to_array()
  let n = chars.length()
  let mut i = 0
  while i < n {
    let c = chars[i]
    let mut consumed = 0
    if c == '%' && i + 2 < n {
      match (hex_digit(chars[i + 1]), hex_digit(chars[i + 2])) {
        (Some(h), Some(l)) => {
          buf.write_byte(((h * 16 + l) | 0).to_byte())
          consumed = 3
        }
        _ => ()
      }
    }
    if consumed == 0 {
      buf.write_char_utf8(c)
      consumed = 1
    }
    i += consumed
  }
  @utf8.decode_lossy(buf.to_bytes().exact_view())
}
