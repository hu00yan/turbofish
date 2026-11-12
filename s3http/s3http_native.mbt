// 真实 HTTP transport（native，libcurl FFI）。
//
// S3Store 只依赖 `HttpTransport` trait；本文件把 execute 映射到 libcurl：
// - method/url/headers 以 NUL 结尾 C 字符串传入；
// - headers 用 "\n" 分隔的 "Key: Value" 列表；
// - body 用 FixedArray[Byte] 传入；
// - C 侧返回 opaque result，MoonBit 读取 status/headers/body 后释放。

///|
#external
type S3HttpResult

///|
#borrow(method, url, headers, body)
extern "C" fn s3http_perform(
  method : Bytes,
  url : Bytes,
  headers : Bytes,
  body : FixedArray[Byte],
  body_len : Int,
) -> S3HttpResult = "s3http_perform"

///|
extern "C" fn s3http_status(r : S3HttpResult) -> Int = "s3http_status"

///|
extern "C" fn s3http_headers_len(r : S3HttpResult) -> Int = "s3http_headers_len"

///|
extern "C" fn s3http_body_len(r : S3HttpResult) -> Int = "s3http_body_len"

///|
#borrow(buf)
extern "C" fn s3http_read_headers(
  r : S3HttpResult,
  buf : FixedArray[Byte],
  len : Int,
) -> Int = "s3http_read_headers"

///|
#borrow(buf)
extern "C" fn s3http_read_body(
  r : S3HttpResult,
  buf : FixedArray[Byte],
  len : Int,
) -> Int = "s3http_read_body"

///|
extern "C" fn s3http_free(r : S3HttpResult) -> Unit = "s3http_free"

///|
#borrow(buf)
extern "C" fn s3http_now_amz_date(buf : FixedArray[Byte], len : Int) -> Int = "s3http_now_amz_date"

///|
/// 当前 UTC 时间，格式 `YYYYMMDDTHHMMSSZ`（SigV4 要求）。
pub fn now_amz_date() -> String {
  let buf : FixedArray[Byte] = FixedArray::make(32, b'\x00')
  let n = s3http_now_amz_date(buf, 32)
  if n <= 0 {
    return "19700101T000000Z"
  }
  @utf8.decode(Bytes::from_array(buf.view(start=0, end=n)).view()) catch {
    _ => "19700101T000000Z"
  }
}

///|
fn cstr(s : String) -> Bytes {
  let b = Buffer()
  b.write_string_utf8(s)
  b.write_byte(b'\x00')
  b.to_bytes()
}

///|
fn trim_left(s : String) -> String {
  let cs = s.to_array()
  let mut i = 0
  while i < cs.length() && (cs[i] == ' ' || cs[i] == '\t') {
    i += 1
  }
  s[i:].to_owned()
}

///|
fn parse_header_line(line : String) -> (String, String)? {
  let cs = line.to_array()
  let mut ci = -1
  for i in 0..<cs.length() {
    if cs[i] == ':' {
      ci = i
      break
    }
  }
  if ci <= 0 {
    None
  } else {
    let name = line[0:ci].to_owned()
    let value = trim_left(line[ci + 1:].to_owned())
    Some((name, value))
  }
}

///|
/// 真实 curl transport。构造后可直接作为 S3Store 的传输层。
pub struct CurlTransport {
  version : Int
}

///|
pub fn CurlTransport::new() -> CurlTransport {
  { version: 1 }
}

///|
pub impl @s3store.HttpTransport for CurlTransport with fn execute(
  self : CurlTransport,
  http_method : String,
  url : String,
  headers : Array[(String, String)],
  body : Bytes,
) -> (Int, Array[(String, String)], Bytes) {
  let _ = self
  let mut hdr_s = ""
  for h in headers {
    hdr_s = hdr_s + h.0 + ": " + h.1 + "\n"
  }
  let body_fa = body.to_fixedarray()
  let res = s3http_perform(
    cstr(http_method),
    cstr(url),
    cstr(hdr_s),
    body_fa,
    body.length(),
  )
  let status = s3http_status(res)
  let hn = s3http_headers_len(res)
  let hbuf : FixedArray[Byte] = FixedArray::make(
    if hn > 0 {
      hn
    } else {
      0
    },
    b'\x00',
  )
  let _ = if hn > 0 { s3http_read_headers(res, hbuf, hn) } else { 0 }
  let hstr = if hn > 0 {
    @utf8.decode(Bytes::from_array(hbuf.view()).view()) catch {
      _ => ""
    }
  } else {
    ""
  }
  let hs : Array[(String, String)] = Array::new()
  for line in hstr.split("\n") {
    let l = line.to_owned()
    if l.length() > 0 {
      match parse_header_line(l) {
        Some(kv) => hs.push(kv)
        None => ()
      }
    }
  }
  let bn = s3http_body_len(res)
  let bbuf : FixedArray[Byte] = FixedArray::make(
    if bn > 0 {
      bn
    } else {
      0
    },
    b'\x00',
  )
  let _ = if bn > 0 { s3http_read_body(res, bbuf, bn) } else { 0 }
  let out = Bytes::from_array(bbuf.view())
  s3http_free(res)
  (status, hs, out)
}
