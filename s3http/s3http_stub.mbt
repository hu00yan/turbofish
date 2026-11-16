// 非 native 后端的 HttpTransport 桩：真实网络只在 native/llvm 可用。
// 这样 s3http 包在默认 wasm-gc target 下也能编译；调用 execute 返回 0/空。

///|
pub struct CurlTransport {
  version : Int
  mut max_inflight : Int
}

///|
pub fn CurlTransport::new(max_inflight~ : Int = 0) -> CurlTransport {
  { version: 1, max_inflight }
}

///|
pub fn CurlTransport::set_max_inflight(
  self : CurlTransport,
  max_inflight : Int,
) -> Unit {
  self.max_inflight = max_inflight
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
  let _ = http_method
  let _ = url
  let _ = headers
  let _ = body
  (0, [], Bytes::make(0, b'\x00'))
}

///|
/// 非 native 后端没有真实网络：逐项调用 execute，保持长度/顺序。
pub impl @s3store.HttpTransport for CurlTransport with fn execute_many(
  self : CurlTransport,
  requests : Array[(String, String, Array[(String, String)], Bytes)],
) -> Array[(Int, Array[(String, String)], Bytes)] {
  let out : Array[(Int, Array[(String, String)], Bytes)] = Array(
    capacity=requests.length(),
  )
  for r in requests {
    out.push(self.execute(r.0, r.1, r.2, r.3))
  }
  out
}

///|
/// 非 native 后端没有真实网络；返回固定时间仅保证编译。
pub fn now_amz_date() -> String {
  "19700101T000000Z"
}

pub extend CurlTransport with @turbofish/s3store.HttpTransport::{execute, execute_many}
