// AWS Signature Version 4 签名（纯 MoonBit，无网络）。
//
// 流程（AWS 官方规范）：
//   1. CanonicalRequest = Method \n CanonicalURI \n CanonicalQuery \n
//                         CanonicalHeaders \n \n SignedHeaders \n PayloadHash
//   2. StringToSign     = "AWS4-HMAC-SHA256" \n AmzDate \n Scope \n SHA256(CanonicalRequest)
//   3. SigningKey       = HMAC(HMAC(HMAC(HMAC("AWS4"+SK, date), region), service), "aws4_request")
//   4. Signature        = hex(HMAC(SigningKey, StringToSign))
//
// S3 特例：canonical URI 用原始编码路径（不做多余规范化）；查询参数按 UTF-8
// 字节序排序（注意 MoonBit 的 String::compare 是长度优先，不能直接用，
// 这里自实现 byte_order_compare）。
// 日期一律由调用方注入（amz_date），保证测试确定性；不读真实时钟。

///|
/// AWS 凭据（只从构造参数传入，本包不含任何字面量凭据）
pub(all) struct S3Credentials {
  access_key : String
  secret_key : String
} derive(Debug)

///|
/// 签名完成的请求（可直接交给 HttpTransport）
pub(all) struct SignedRequest {
  http_method : String
  url : String
  headers : Array[(String, String)]
  body : Bytes
} derive(Debug)

///|
/// RFC 3986 百分号编码，大写 hex。unreserved = A-Za-z0-9 - . _ ~ 保留；
/// encode_slash=false 时 '/' 也保留（S3 canonical URI 按段编码）。
pub fn uri_encode(s : String, encode_slash : Bool) -> String {
  let bytes = @utf8.encode(s)
  let b = Buffer()
  for i in 0..<bytes.length() {
    let v = bytes.get(i).unwrap_or(b'\x00').to_int()
    let unreserved = (v >= 65 && v <= 90) ||
      (v >= 97 && v <= 122) ||
      (v >= 48 && v <= 57) ||
      v == 45 ||
      v == 46 ||
      v == 95 ||
      v == 126
    if unreserved || (v == 47 && !encode_slash) {
      b.write_char_utf8(bytes.get(i).unwrap_or(b'\x00').to_char())
    } else {
      b.write_char_utf8('%')
      b.write_char_utf8(hex_digit_upper(v >> 4))
      b.write_char_utf8(hex_digit_upper(v & 0xF))
    }
  }
  @utf8.decode(b.to_bytes().view()) catch {
    _ => ""
  }
}

///|
fn hex_digit_upper(v : Int) -> Char {
  if v < 10 {
    (48 + v).unsafe_to_char()
  } else {
    (55 + v).unsafe_to_char() // 'A'..'F'
  }
}

///|
/// UTF-8 字节序比较（SigV4 排序要求；String::compare 是长度优先不能用于此）
pub fn byte_order_compare(a : String, b : String) -> Int {
  let ab = @utf8.encode(a).to_fixedarray()
  let bb = @utf8.encode(b).to_fixedarray()
  let n = if ab.length() < bb.length() { ab.length() } else { bb.length() }
  for i in 0..<n {
    let x = ab[i].to_int()
    let y = bb[i].to_int()
    if x != y {
      return if x < y { -1 } else { 1 }
    }
  }
  ab.length() - bb.length()
}

///|
/// 去掉首尾空格（canonical header value 规范化的 MVP 子集：
/// 连续内部空格折叠不实现，本项目发出的头不含连续空格）
fn trim_spaces(s : String) -> String {
  let mut lo = 0
  let hi = s.length()
  let mut hi2 = hi
  while lo < hi2 && s[lo].to_int() == 32 {
    lo += 1
  }
  while hi2 > lo && s[hi2 - 1].to_int() == 32 {
    hi2 -= 1
  }
  s[lo:hi2].to_owned()
}

///|
/// canonical query string：键值都 RFC3986 编码后按字节序排序（先键后值），"a=1&b=2"
pub fn canonical_query(query : Array[(String, String)]) -> String {
  let enc : Array[(String, String)] = Array::new()
  for kv in query {
    enc.push((uri_encode(kv.0, true), uri_encode(kv.1, true)))
  }
  enc.sort_by((a, b) => {
    let c = byte_order_compare(a.0, b.0)
    if c != 0 {
      c
    } else {
      byte_order_compare(a.1, b.1)
    }
  })
  let b = Buffer()
  for i in 0..<enc.length() {
    if i > 0 {
      b.write_string_utf8("&")
    }
    b.write_string_utf8(enc[i].0)
    b.write_string_utf8("=")
    b.write_string_utf8(enc[i].1)
  }
  @utf8.decode(b.to_bytes().view()) catch {
    _ => ""
  }
}

///|
/// canonical headers 块 + signed headers 名单。
/// 输入头名会被小写化、值去首尾空格；按名字节序排序。
/// 返回 (每行 "name:value\n" 的拼接块, "n1;n2;..." )
pub fn canonical_header_block(
  headers : Array[(String, String)],
) -> (String, String) {
  let norm : Array[(String, String)] = Array::new()
  for h in headers {
    norm.push((h.0.to_lower(), trim_spaces(h.1)))
  }
  norm.sort_by((a, b) => byte_order_compare(a.0, b.0))
  let block = Buffer()
  let names = Buffer()
  for i in 0..<norm.length() {
    block.write_string_utf8(norm[i].0)
    block.write_string_utf8(":")
    block.write_string_utf8(norm[i].1)
    block.write_string_utf8("\n")
    if i > 0 {
      names.write_string_utf8(";")
    }
    names.write_string_utf8(norm[i].0)
  }
  let b = @utf8.decode(block.to_bytes().view()) catch { _ => "" }
  let n = @utf8.decode(names.to_bytes().view()) catch { _ => "" }
  (b, n)
}

///|
/// canonical request 字符串
pub fn sigv4_canonical_request(
  http_method : String,
  canonical_uri : String,
  canonical_query_str : String,
  headers : Array[(String, String)],
  payload_hash : String,
) -> String {
  let (block, names) = canonical_header_block(headers)
  let b = Buffer()
  b.write_string_utf8(http_method)
  b.write_string_utf8("\n")
  b.write_string_utf8(canonical_uri)
  b.write_string_utf8("\n")
  b.write_string_utf8(canonical_query_str)
  b.write_string_utf8("\n")
  b.write_string_utf8(block)
  b.write_string_utf8("\n")
  b.write_string_utf8(names)
  b.write_string_utf8("\n")
  b.write_string_utf8(payload_hash)
  @utf8.decode(b.to_bytes().view()) catch {
    _ => ""
  }
}

///|
/// string-to-sign
pub fn sigv4_string_to_sign(
  amz_date : String,
  scope : String,
  canonical_request : String,
) -> String {
  let b = Buffer()
  b.write_string_utf8("AWS4-HMAC-SHA256\n")
  b.write_string_utf8(amz_date)
  b.write_string_utf8("\n")
  b.write_string_utf8(scope)
  b.write_string_utf8("\n")
  b.write_string_utf8(sha256_hex(@utf8.encode(canonical_request)))
  @utf8.decode(b.to_bytes().view()) catch {
    _ => ""
  }
}

///|
/// 派生签名密钥 kSigning（32 字节）
pub fn sigv4_signing_key(
  secret_key : String,
  date_stamp : String,
  region : String,
  service : String,
) -> Bytes {
  let k_date = hmac_sha256(
    @utf8.encode("AWS4" + secret_key),
    @utf8.encode(date_stamp),
  )
  let k_region = hmac_sha256(k_date, @utf8.encode(region))
  let k_service = hmac_sha256(k_region, @utf8.encode(service))
  hmac_sha256(k_service, @utf8.encode("aws4_request"))
}

///|
/// 完整签名：返回可直接发出的请求（URL / 含 Authorization 的头 / body）。
/// 固定携带 host / x-amz-date；x-amz-content-sha256 由调用方决定是否携带
/// （S3 要求携带，aws-sig-v4-test-suite 的 iam/service 向量不携带）。
pub fn sigv4_sign_request(
  http_method : String,
  scheme : String,
  host : String,
  canonical_uri : String,
  query : Array[(String, String)],
  extra_headers : Array[(String, String)],
  payload : Bytes,
  creds : S3Credentials,
  region : String,
  service : String,
  amz_date : String,
) -> SignedRequest {
  let payload_hash = sha256_hex(payload)
  let date_stamp = amz_date[:8].to_owned()
  let headers : Array[(String, String)] = Array::new()
  headers.push(("host", host))
  headers.push(("x-amz-date", amz_date))
  for h in extra_headers {
    headers.push((h.0.to_lower(), h.1))
  }
  let cq = canonical_query(query)
  let canonical = sigv4_canonical_request(
    http_method, canonical_uri, cq, headers, payload_hash,
  )
  let scope = "\{date_stamp}/\{region}/\{service}/aws4_request"
  let sts = sigv4_string_to_sign(amz_date, scope, canonical)
  let key = sigv4_signing_key(creds.secret_key, date_stamp, region, service)
  let signature = bytes_to_hex(hmac_sha256(key, @utf8.encode(sts)))
  let (_, signed_names) = canonical_header_block(headers)
  let authorization = "AWS4-HMAC-SHA256 Credential=\{creds.access_key}/\{scope}, SignedHeaders=\{signed_names}, Signature=\{signature}"
  let out_headers : Array[(String, String)] = Array::new()
  for h in headers {
    out_headers.push(h)
  }
  out_headers.push(("Authorization", authorization))
  let url = Buffer()
  url.write_string_utf8(scheme)
  url.write_string_utf8("://")
  url.write_string_utf8(host)
  url.write_string_utf8(canonical_uri)
  if cq != "" {
    url.write_string_utf8("?")
    url.write_string_utf8(cq)
  }
  {
    http_method,
    url: @utf8.decode(url.to_bytes().view()) catch {
      _ => ""
    },
    headers: out_headers,
    body: payload,
  }
}
