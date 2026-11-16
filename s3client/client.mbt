// 纯 MoonBit 异步 S3 客户端（无 curl / 无 C stub）。
//
// 职责边界：
//   - 签名与 URL/头构造：全部委托给 turbofish/s3store 的 sigv4_sign_request，
//     本包不重新实现 SigV4（也不做 canonical 化）。
//   - 传输：moonbitlang/async 的 @http.Client 持久连接（每槽位一条 TCP/TLS）。
//   - 状态码语义、重试/退避、ListObjectsV2 分页。
//
// 设计要点：
//   - S3Client::send 接收一个“重新构造请求”的闭包，每次重试都重新签名
//     （同时刷新 x-amz-date），因此 body 天然可重放。
//   - max_inflight 个连接槽位；每个槽位带一把 @async.Mutex，槽位间可并发，
//     槽位内串行（HTTP/1.1 一条连接同时只能有一个请求）。
//   - 网络错误 / 5xx 时会丢弃该槽位连接（关闭并在下次请求时重连）。

///|
/// 客户端错误：非 2xx 且不属于“明确业务语义”的状态码一律 raise 此类型。
pub suberror S3ClientError {
  /// (status, 请求方法与响应的简短描述)
  HttpStatus(Int, String)
  /// 无法解析的响应（例如缺少 Content-Length 语义的畸形响应）
  MalformedResponse(String)
}

///|
/// 单个连接槽位（持久连接 + 串行锁）
pub struct S3Slot {
  mut client : @http.Client?
  lock : @async.Mutex
}

///|
/// 一次原始 HTTP 往返的结果
priv struct RawResponse {
  status : Int
  headers : Array[(String, String)]
  body : Bytes
}

///|
/// 默认 ListObjectsV2 单页大小
const DEFAULT_MAX_KEYS : Int = 1000

///|
/// 退避基数（毫秒）与上限
const BACKOFF_BASE_MS : Int = 50

const BACKOFF_CAP_MS : Int = 2000

///|
/// 异步 S3 客户端
pub struct S3Client {
  scheme : String
  host : String
  bucket : String
  region : String
  creds : @s3store.S3Credentials
  max_inflight : Int
  max_attempts : Int
  now_amz_date : () -> String
  slots : Array[S3Slot]
  mut next_slot : Int
  pick : @async.Mutex
}

///|
/// 构造客户端。
///
/// - `endpoint`：`https://s3.amazonaws.com` / `http://127.0.0.1:9000`（可有尾斜杠）
/// - `max_inflight`：并发连接数上限（≥1）
/// - `max_attempts`：单次调用的最大尝试次数（≥1，含首次）
/// - `now_amz_date`：可选注入时钟（测试确定性用），默认取系统 UTC 时间
pub fn S3Client::new(
  endpoint : String,
  bucket : String,
  region : String,
  access_key : String,
  secret_key : String,
  max_inflight~ : Int = 16,
  max_attempts~ : Int = 3,
  now_amz_date? : (() -> String)? = None,
) -> S3Client {
  let (scheme, host) = split_endpoint(endpoint)
  let n = if max_inflight < 1 { 1 } else { max_inflight }
  let slots : Array[S3Slot] = []
  for _ in 0..<n {
    slots.push({ client: None, lock: @async.Mutex::Mutex() })
  }
  {
    scheme,
    host,
    bucket,
    region,
    creds: { access_key: access_key, secret_key: secret_key },
    max_inflight: n,
    max_attempts: if max_attempts < 1 { 1 } else { max_attempts },
    now_amz_date: match now_amz_date {
      Some(f) => f
      None => fn() { default_amz_date() }
    },
    slots,
    next_slot: 0,
    pick: @async.Mutex::Mutex(),
  }
}

///|
/// 关闭所有持久连接（幂等）。
pub fn S3Client::close(self : S3Client) -> Unit {
  for slot in self.slots {
    match slot.client {
      Some(c) => {
        c.close()
        slot.client = None
      }
      None => ()
    }
  }
}

// ---------- URL / 请求构造 ----------

///|
/// 拆分 endpoint 为 (scheme, authority)，并去掉尾部路径/斜杠。
fn split_endpoint(endpoint : String) -> (String, String) {
  let e = endpoint.trim().to_owned()
  let (scheme, rest) = if e.has_prefix("http://") {
    ("http", e[7:].to_owned())
  } else if e.has_prefix("https://") {
    ("https", e[8:].to_owned())
  } else {
    ("https", e)
  }
  let auth = match rest.find("/") {
    Some(i) => rest[:i].to_owned()
    None => rest
  }
  (scheme, auth)
}

///|
/// 对象路径（与 s3store.S3Store::object_path 同规则：逐段百分号编码）。
fn S3Client::object_path(self : S3Client, key : String) -> String {
  if key == "" {
    return "/" + self.bucket
  }
  let b = StringBuilder()
  b.write_char('/')
  b.write_string(self.bucket)
  for seg in key.split("/") {
    b.write_char('/')
    b.write_string(@s3store.uri_encode(seg.to_owned(), true))
  }
  b.to_string()
}

///|
/// 统一签名入口：全部 URL / 头都来自 s3store.sigv4_sign_request。
fn S3Client::sign(
  self : S3Client,
  http_method : String,
  path : String,
  query : Array[(String, String)],
  extra_headers : Array[(String, String)],
  payload : Bytes,
) -> @s3store.SignedRequest {
  @s3store.sigv4_sign_request(
    http_method,
    self.scheme,
    self.host,
    path,
    query,
    extra_headers,
    payload,
    self.creds,
    self.region,
    "s3",
    (self.now_amz_date)(),
  )
}

///|
fn empty_payload() -> Bytes {
  Bytes::make(0, b'\x00')
}

///|
fn S3Client::build_get(
  self : S3Client,
  key : String,
  range_header : String?,
) -> @s3store.SignedRequest {
  let payload = empty_payload()
  let extra : Array[(String, String)] = [
    ("x-amz-content-sha256", @s3store.sha256_hex(payload)),
  ]
  match range_header {
    Some(r) => extra.push(("Range", r))
    None => ()
  }
  self.sign("GET", self.object_path(key), [], extra, payload)
}

///|
fn S3Client::build_put(
  self : S3Client,
  key : String,
  body : Bytes,
  if_match : String?,
  if_none_match : String?,
) -> @s3store.SignedRequest {
  let extra : Array[(String, String)] = [
    ("x-amz-content-sha256", @s3store.sha256_hex(body)),
  ]
  match if_match {
    Some(v) => extra.push(("If-Match", v))
    None => ()
  }
  match if_none_match {
    Some(v) => extra.push(("If-None-Match", v))
    None => ()
  }
  self.sign("PUT", self.object_path(key), [], extra, body)
}

///|
fn S3Client::build_delete(
  self : S3Client,
  key : String,
) -> @s3store.SignedRequest {
  let payload = empty_payload()
  let extra : Array[(String, String)] = [
    ("x-amz-content-sha256", @s3store.sha256_hex(payload)),
  ]
  self.sign("DELETE", self.object_path(key), [], extra, payload)
}

///|
fn S3Client::build_head(
  self : S3Client,
  key : String,
) -> @s3store.SignedRequest {
  let payload = empty_payload()
  let extra : Array[(String, String)] = [
    ("x-amz-content-sha256", @s3store.sha256_hex(payload)),
  ]
  self.sign("HEAD", self.object_path(key), [], extra, payload)
}

///|
fn S3Client::build_list(
  self : S3Client,
  prefix : String,
  max_keys : Int,
  continuation_token : String?,
) -> @s3store.SignedRequest {
  let payload = empty_payload()
  let query : Array[(String, String)] = [
    ("list-type", "2"),
    ("prefix", prefix),
    ("max-keys", max_keys.to_string()),
  ]
  match continuation_token {
    Some(t) => query.push(("continuation-token", t))
    None => ()
  }
  let extra : Array[(String, String)] = [
    ("x-amz-content-sha256", @s3store.sha256_hex(payload)),
  ]
  self.sign("GET", self.object_path(""), query, extra, payload)
}

// ---------- 传输 ----------

///|
fn request_method(m : String) -> @http.RequestMethod raise S3ClientError {
  match m {
    "GET" => @http.Get
    "HEAD" => @http.Head
    "PUT" => @http.Put
    "POST" => @http.Post
    "DELETE" => @http.Delete
    other => raise S3ClientError::MalformedResponse("unsupported method " + other)
  }
}

///|
/// 从 SignedRequest.url 中取 `path?query`（Host 由 @http.Client 自动设置）。
fn request_path(url : String) -> String {
  let after_scheme = match url.find("://") {
    Some(i) => url[i + 3:].to_owned()
    None => url
  }
  match after_scheme.find("/") {
    Some(i) => after_scheme[i:].to_owned()
    None => "/"
  }
}

///|
fn header_get(headers : Array[(String, String)], name : String) -> String? {
  for h in headers {
    if h.0.equal_ignore_ascii_case(name) {
      return Some(h.1)
    }
  }
  None
}

///|
/// 取一个连接槽位（并发上限 = 槽位数；同槽位串行）。
async fn S3Client::acquire(self : S3Client) -> S3Slot {
  self.pick.acquire()
  let n = self.slots.length()
  let idx = self.next_slot % n
  self.next_slot = (self.next_slot + 1) % n
  self.pick.release()
  let slot = self.slots[idx]
  slot.lock.acquire()
  slot
}

///|
async fn S3Client::ensure_client(
  self : S3Client,
  slot : S3Slot,
) -> @http.Client {
  match slot.client {
    Some(c) => c
    None => {
      let c = @http.Client::Client(self.scheme + "://" + self.host)
      slot.client = Some(c)
      c
    }
  }
}

///|
/// 丢弃（关闭）槽位上的连接，下次请求时重连。
fn discard_slot(slot : S3Slot) -> Unit {
  match slot.client {
    Some(c) => {
      c.close()
      slot.client = None
    }
    None => ()
  }
}

///|
/// 单次 HTTP 往返。失败（网络错误）时关闭该槽位连接后把错误抛出。
async fn S3Client::raw_send(
  self : S3Client,
  req : @s3store.SignedRequest,
) -> RawResponse {
  let path = request_path(req.url)
  let meth = request_method(req.http_method)
  let headers : @http.Headers = Map([])
  for h in req.headers {
    let name = h.0.to_lower()
    if name == "host" {
      // Host 由 @http.Client 自动设置，不能重复添加
      continue
    }
    headers.set(@http.CaseInsensitiveString(name), h.1)
  }
  // @http.Client 在没有 Content-Length 时会退回 chunked 编码，S3 不接受；
  // 这里显式声明（PUT 即使空 body 也声明 0，避免 411 Length Required）。
  // 该头未参与签名（S3 只校验 SignedHeaders 中的头），不影响 Authorization。
  let needs_length = req.body.length() > 0 ||
    (meth is @http.Put || meth is @http.Post)
  if needs_length {
    headers.set(
      @http.CaseInsensitiveString("content-length"),
      req.body.length().to_string(),
    )
  }
  let slot = self.acquire()
  let attempt : Result[RawResponse, Error] = try {
    let client = self.ensure_client(slot)
    client.request(meth, path, extra_headers=headers)
    if req.body.length() > 0 {
      client.write(req.body)
    }
    let resp = client.end_request()
    let data = client.read_all()
    let hs : Array[(String, String)] = []
    for k, v in resp.headers {
      hs.push((k.to_string(), v))
    }
    Ok({ status: resp.code, headers: hs, body: data.binary() })
  } catch {
    e => Err(e)
  }
  match attempt {
    Ok(r) => {
      slot.lock.release()
      r
    }
    Err(e) => {
      discard_slot(slot)
      slot.lock.release()
      raise e
    }
  }
}

///|
fn is_ok_status(status : Int) -> Bool {
  status >= 200 && status < 300
}

///|
fn is_retryable_status(status : Int) -> Bool {
  status == 429 ||
  status == 500 ||
  status == 502 ||
  status == 503 ||
  status == 504
}

///|
/// 指数退避 + 抖动（0.75x..1.25x 区间内的离散抖动）。
async fn S3Client::backoff(attempt : Int) -> Unit {
  let mut delay = BACKOFF_BASE_MS
  let mut i = 1
  while i < attempt && delay < BACKOFF_CAP_MS {
    delay = delay * 2
    i += 1
  }
  if delay > BACKOFF_CAP_MS {
    delay = BACKOFF_CAP_MS
  }
  let base = delay - delay / 4
  let jitter = rand_below(delay / 2 + 1)
  @async.sleep(base + jitter)
}

///|
/// 0..<n 的均匀随机数（无则退化为 0）
fn rand_below(n : Int) -> Int {
  if n <= 1 {
    return 0
  }
  match @env.rand(8) {
    Some(b) => {
      let mut acc = 0UL
      for i in 0..<8 {
        acc = (acc << 8) | b.get(i).unwrap_or(b'\x00').to_int().to_uint64()
      }
      (acc % n.to_uint64()).to_int()
    }
    None => 0
  }
}

///|
/// 发送（带重试）：每次尝试都重新签名，因此 body 可重放。
///
/// 重试条件：429 / 500 / 502 / 503 / 504 / 网络错误。
async fn S3Client::send(
  self : S3Client,
  build : () -> @s3store.SignedRequest,
) -> RawResponse {
  let mut attempt = 1
  while attempt <= self.max_attempts {
    let req = build()
    let res : Result[RawResponse, Error] = try {
      Ok(self.raw_send(req))
    } catch {
      e => Err(e)
    }
    let should_retry = match res {
      Ok(r) => is_retryable_status(r.status)
      // 本版本 async 的 cancellation 不是 Error（见 catch 语义），
      // 因此 Err 分支就是网络/协议错误，可重试。
      Err(_) => true
    }
    if !should_retry || attempt >= self.max_attempts {
      match res {
        Ok(r) => return r
        Err(e) => raise e
      }
    }
    S3Client::backoff(attempt)
    attempt += 1
  }
  raise S3ClientError::MalformedResponse("retry loop exhausted")
}

///|
/// 构造错误描述（含响应体前缀，便于定位 S3 错误码）
fn describe_status(req_desc : String, r : RawResponse) -> String {
  let text = @utf8.decode_lossy(r.body.exact_view())
  let snippet = if text.length() > 512 { text[:512].to_owned() } else { text }
  "\{req_desc} -> HTTP \{r.status}: \{snippet}"
}

///|
fn ensure_ok(req_desc : String, r : RawResponse) -> Unit raise S3ClientError {
  if !is_ok_status(r.status) {
    raise S3ClientError::HttpStatus(r.status, describe_status(req_desc, r))
  }
}

///|
fn slice_bytes(body : Bytes, offset : Int, len : Int) -> Bytes {
  if offset >= body.length() || len <= 0 {
    return Bytes::make(0, b'\x00')
  }
  let end = if offset + len > body.length() {
    body.length()
  } else {
    offset + len
  }
  body.unsafe_view(start=offset, end=end).to_owned()
}

// ---------- 公开 API ----------

///|
/// GetObject：200/206 → Some(body)；404/416 → None；其他非 2xx → raise。
pub async fn S3Client::get(self : S3Client, key : String) -> Bytes? {
  let r = self.send(fn() { self.build_get(key, None) })
  if r.status == 200 || r.status == 206 {
    Some(r.body)
  } else if r.status == 404 || r.status == 416 {
    None
  } else {
    raise S3ClientError::HttpStatus(r.status, describe_status("GET " + key, r))
  }
}

///|
/// Range 头：`bytes=<offset>-<offset+len-1>`（闭区间）
pub fn range_header(offset : Int, len : Int) -> String {
  "bytes=\{offset}-\{offset + len - 1}"
}

///|
/// GetObject(range)：`Range: bytes=off-(off+len-1)`。
/// 206 → body；服务端忽略 Range 返回 200 → 本地切片；404/416 → None。
pub async fn S3Client::get_range(
  self : S3Client,
  key : String,
  offset : Int,
  len : Int,
) -> Bytes? {
  if len <= 0 {
    return Some(Bytes::make(0, b'\x00'))
  }
  let r = self.send(fn() { self.build_get(key, Some(range_header(offset, len))) })
  match r.status {
    200 => Some(slice_bytes(r.body, offset, len))
    206 => Some(r.body)
    404 | 416 => None
    s =>
      raise S3ClientError::HttpStatus(
        s,
        describe_status("GET(range) " + key, r),
      )
  }
}

///|
/// PutObject：2xx 成功，其他 raise。
pub async fn S3Client::put(
  self : S3Client,
  key : String,
  body : Bytes,
) -> Unit {
  let r = self.send(fn() { self.build_put(key, body, None, None) })
  ensure_ok("PUT " + key, r)
}

///|
/// 条件写（CAS）：
/// - `expected=None` → `If-None-Match: *`（仅当对象不存在时创建）
/// - `expected=Some(v)` → `If-Match: <v>`（仅当当前版本为 v 时更新）
/// 200/204 → true；409/412 → false；其他非 2xx → raise。
pub async fn S3Client::put_if_match(
  self : S3Client,
  key : String,
  body : Bytes,
  expected : String?,
) -> Bool {
  let r = self.send(fn() {
    match expected {
      None => self.build_put(key, body, None, Some("*"))
      Some(v) => self.build_put(key, body, Some(v), None)
    }
  })
  if is_ok_status(r.status) {
    true
  } else if r.status == 409 || r.status == 412 {
    false
  } else {
    raise S3ClientError::HttpStatus(
      r.status,
      describe_status("PUT(if-match) " + key, r),
    )
  }
}

///|
/// DeleteObject：2xx 或 404（幂等）成功，其他 raise。
pub async fn S3Client::delete(self : S3Client, key : String) -> Unit {
  let r = self.send(fn() { self.build_delete(key) })
  if is_ok_status(r.status) || r.status == 404 {
    ()
  } else {
    raise S3ClientError::HttpStatus(
      r.status,
      describe_status("DELETE " + key, r),
    )
  }
}

///|
/// HeadObject → ETag（版本串）；不存在 → None。
pub async fn S3Client::head_version(self : S3Client, key : String) -> String? {
  let r = self.send(fn() { self.build_head(key) })
  if r.status == 200 {
    header_get(r.headers, "etag")
  } else if r.status == 404 {
    None
  } else {
    raise S3ClientError::HttpStatus(
      r.status,
      describe_status("HEAD " + key, r),
    )
  }
}

///|
/// ListObjectsV2：按 `<IsTruncated>` / `<NextContinuationToken>` 自动翻页，
/// 返回所有 `<Key>`（不含 CommonPrefixes，本客户端不设 delimiter）。
pub async fn S3Client::list(
  self : S3Client,
  prefix : String,
) -> Array[String] {
  let out : Array[String] = []
  let mut token : String? = None
  let mut pages = 0
  while true {
    let r = self.send(fn() { self.build_list(prefix, DEFAULT_MAX_KEYS, token) })
    if !is_ok_status(r.status) {
      raise S3ClientError::HttpStatus(
        r.status,
        describe_status("LIST " + prefix, r),
      )
    }
    let xml = @utf8.decode_lossy(r.body.exact_view())
    for k in xml_tag_values(xml, "Key") {
      out.push(k)
    }
    let truncated = match xml_first_value(xml, "IsTruncated") {
      Some(v) => v.trim() == "true"
      None => false
    }
    let next = xml_first_value(xml, "NextContinuationToken")
    pages += 1
    if !truncated || next is None || pages > 100000 {
      break
    }
    token = next
  }
  out
}
