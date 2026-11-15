// 非 native 后端的 HttpTransport 桩：真实网络只在 native/llvm 可用。
// 这样 s3http 包在默认 wasm-gc target 下也能编译；调用 execute 返回 0/空。

///|
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
  let _ = http_method
  let _ = url
  let _ = headers
  let _ = body
  (0, [], Bytes::make(0, b'\x00'))
}

///|
/// 非 native 后端没有真实网络；返回固定时间仅保证编译。
pub fn now_amz_date() -> String {
  "19700101T000000Z"
}

pub extend CurlTransport with @turbofish/s3store.HttpTransport::{execute}
