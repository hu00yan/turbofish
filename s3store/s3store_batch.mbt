// S3Store 的批量读实现。
//
// 契约与单键 get / get_range 完全一致：
// - 返回数组与输入同长、同序；miss（404 / 不可读）为 None，不压缩、不重排。
// - 每个请求仍由现有的 build_* / sign 逻辑构造，因此 SigV4、Range、URI 编码、
//   条件头全部复用单发实现。
// - 批量只改变调度：先构造全部 SignedRequest，再交给 transport.execute_many。
//   默认 transport（未覆盖 execute_many）会顺序逐项执行，语义不变；CurlTransport
//   用 libcurl multi 并发执行。
// - ETag 缓存仍按原逻辑在结果到达后填充，不绕过 cache。

///|
/// 把多个 SignedRequest 交给 transport 的批量入口；若 transport 返回长度不符，
/// 用单发 do_req 补齐/截断到输入长度，保证对外契约不被破坏。
fn[T : HttpTransport] S3Store::do_many(
  self : S3Store[T],
  reqs : Array[SignedRequest],
) -> Array[(Int, Array[(String, String)], Bytes)] {
  let inputs : Array[(String, String, Array[(String, String)], Bytes)] = Array(
    capacity=reqs.length(),
  )
  for r in reqs {
    inputs.push((r.http_method, r.url, r.headers, r.body))
  }
  let got = self.transport.execute_many(inputs)
  if got.length() == reqs.length() {
    return got
  }
  // 防御性回退：transport 实现有 bug 时也不能破坏顺序/长度语义。
  let out : Array[(Int, Array[(String, String)], Bytes)] = Array(
    capacity=reqs.length(),
  )
  for i in 0..<reqs.length() {
    if i < got.length() {
      out.push(got[i])
    } else {
      out.push(self.do_req(reqs[i]))
    }
  }
  out
}

///|
/// 单键整读的结果收尾（与 ObjectStore::get 完全一致）。
fn[T] S3Store::finish_get(
  self : S3Store[T],
  key : String,
  res : (Int, Array[(String, String)], Bytes),
) -> Bytes? {
  let (st, hs, body) = res
  if st == 200 {
    self.cache_etag(key, st, hs)
    Some(body)
  } else {
    None
  }
}

///|
/// 单键范围读的结果收尾（与 ObjectStore::get_range 完全一致）。
fn[T] S3Store::finish_get_range(
  self : S3Store[T],
  key : String,
  offset : Int,
  len : Int,
  res : (Int, Array[(String, String)], Bytes),
) -> Bytes? {
  let (st, hs, body) = res
  if len <= 0 {
    if st == 200 {
      return Some(Bytes::make(0, b'\x00'))
    }
    return None
  }
  let off = if offset < 0 { 0 } else { offset }
  if st == 206 {
    self.cache_etag(key, st, hs)
    Some(body)
  } else if st == 200 {
    self.cache_etag(key, st, hs)
    let lo = off
    let hi = if off + len > body.length() { body.length() } else { off + len }
    if hi <= lo {
      Some(Bytes::make(0, b'\x00'))
    } else {
      Some(body[lo:hi].to_owned())
    }
  } else if st == 416 {
    Some(Bytes::make(0, b'\x00'))
  } else {
    None
  }
}

///|
/// 真实批量整读：一次构造所有 GetObject，交给批量 transport。
pub impl[T : HttpTransport] @store.ObjectStore for S3Store[T] with fn get_many(
  self : S3Store[T],
  keys : Array[String],
) -> Array[Bytes?] {
  let reqs : Array[SignedRequest] = Array(capacity=keys.length())
  for k in keys {
    reqs.push(self.build_get_object(k, None))
  }
  let results = self.do_many(reqs)
  let out : Array[Bytes?] = Array(capacity=keys.length())
  for i in 0..<keys.length() {
    out.push(self.finish_get(keys[i], results[i]))
  }
  out
}

///|
/// 真实批量范围读：len <= 0 的项用 HEAD（与单键 get_range 一致）。
pub impl[T : HttpTransport] @store.ObjectStore for S3Store[T] with fn get_range_many(
  self : S3Store[T],
  ranges : Array[@store.KeyRange],
) -> Array[Bytes?] {
  let reqs : Array[SignedRequest] = Array(capacity=ranges.length())
  for r in ranges {
    let key = r.key
    let offset = r.off
    let len = r.len
    if len <= 0 {
      reqs.push(self.build_head_object(key))
    } else {
      let off = if offset < 0 { 0 } else { offset }
      let range = "bytes=\{off}-\{off + len - 1}"
      reqs.push(self.build_get_object(key, Some(range)))
    }
  }
  let results = self.do_many(reqs)
  let out : Array[Bytes?] = Array(capacity=ranges.length())
  for i in 0..<ranges.length() {
    let key = ranges[i].key
    let offset = ranges[i].off
    let len = ranges[i].len
    out.push(self.finish_get_range(key, offset, len, results[i]))
  }
  out
}

