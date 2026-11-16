// 真实 HTTP transport（native，libcurl FFI）。
//
// S3Store 只依赖 `HttpTransport` trait；本文件把 execute 映射到 libcurl：
// - http_method/url/headers 以 NUL 结尾 C 字符串传入；
// - headers 用 "\n" 分隔的 "Key: Value" 列表；
// - body 用 FixedArray[Byte] 传入；
// - C 侧返回 opaque result，MoonBit 读取 status/headers/body 后释放。

///|
#external
priv type S3HttpResult

///|
#external
priv type S3HttpBatch

///|
#borrow(http_method, url, headers, body)
extern "C" fn s3http_perform(
  http_method : Bytes,
  url : Bytes,
  headers : Bytes,
  body : FixedArray[Byte],
  body_len : Int,
) -> S3HttpResult = "s3http_perform"

///|
/// 批量 HTTP：一次提交多个请求，C 侧用 libcurl multi 并发执行并复用连接。
/// `reqs` 是打包后的请求列表（方法/URL/头均为 NUL 结尾，body 前有 4 字节小端长度）。
/// 返回的 batch 与输入同长同序；错误/404 用每个 item 的 status 表达。
#borrow(reqs)
extern "C" fn s3http_perform_many(
  reqs : FixedArray[Byte],
  reqs_len : Int,
  count : Int,
  max_inflight : Int,
) -> S3HttpBatch = "s3http_perform_many"

///|
extern "C" fn s3http_batch_len(batch : S3HttpBatch) -> Int = "s3http_batch_len"

///|
extern "C" fn s3http_batch_get(
  batch : S3HttpBatch,
  index : Int,
) -> S3HttpResult = "s3http_batch_get"

///|
extern "C" fn s3http_batch_free(batch : S3HttpBatch) -> Unit = "s3http_batch_free"

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
  @utf8.decode(Bytes::from_array(buf.exact_view(start=0, end=n)).exact_view()) catch {
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
/// `max_inflight` <= 0 时由 C 侧读取 `S3HTTP_MAX_INFLIGHT`，默认 32。
pub struct CurlTransport {
  version : Int
  mut max_inflight : Int
}

///|
pub fn CurlTransport::new(max_inflight~ : Int = 0) -> CurlTransport {
  { version: 1, max_inflight }
}

///|
/// 设置批量传输的 in-flight 上限（0 = 由环境变量/默认值决定）。
pub fn CurlTransport::set_max_inflight(
  self : CurlTransport,
  max_inflight : Int,
) -> Unit {
  self.max_inflight = max_inflight
}

///|
/// 从 opaque C 结果读取 status/headers/body。
fn read_result(res : S3HttpResult) -> (Int, Array[(String, String)], Bytes) {
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
    @utf8.decode(Bytes::from_array(hbuf.exact_view()).exact_view()) catch {
      _ => ""
    }
  } else {
    ""
  }
  let hs : Array[(String, String)] = Array()
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
  let out = Bytes::from_array(bbuf.exact_view())
  (status, hs, out)
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
  let out = read_result(res)
  s3http_free(res)
  out
}

///|
/// 把多个请求打包成 C 侧可顺序解析的单一字节缓冲。
fn pack_requests(
  requests : Array[(String, String, Array[(String, String)], Bytes)],
) -> (Bytes, Int) {
  let b = Buffer()
  let mut hdr_s = ""
  for r in requests {
    hdr_s = ""
    for h in r.2 {
      hdr_s = hdr_s + h.0 + ": " + h.1 + "\n"
    }
    b.write_string_utf8(r.0)
    b.write_byte(b'\x00')
    b.write_string_utf8(r.1)
    b.write_byte(b'\x00')
    b.write_string_utf8(hdr_s)
    b.write_byte(b'\x00')
    let n = r.3.length()
    b.write_byte((n & 0xFF).to_byte())
    b.write_byte(((n >> 8) & 0xFF).to_byte())
    b.write_byte(((n >> 16) & 0xFF).to_byte())
    b.write_byte(((n >> 24) & 0xFF).to_byte())
    b.write_bytes(r.3.exact_view())
  }
  let bs = b.to_bytes()
  (bs, requests.length())
}

///|
/// 真实并发批量传输：libcurl multi + 持久连接池。
pub impl @s3store.HttpTransport for CurlTransport with fn execute_many(
  self : CurlTransport,
  requests : Array[(String, String, Array[(String, String)], Bytes)],
) -> Array[(Int, Array[(String, String)], Bytes)] {
  let out : Array[(Int, Array[(String, String)], Bytes)] = Array(
    capacity=requests.length(),
  )
  if requests.is_empty() {
    return out
  }
  let (packed, count) = pack_requests(requests)
  let fa = packed.to_fixedarray()
  let batch = s3http_perform_many(
    fa, fa.length(), count, self.max_inflight,
  )
  let n = s3http_batch_len(batch)
  for i in 0..<n {
    let res = s3http_batch_get(batch, i)
    out.push(read_result(res))
  }
  s3http_batch_free(batch)
  out
}

pub extend CurlTransport with @s3store.HttpTransport::{execute, execute_many}
