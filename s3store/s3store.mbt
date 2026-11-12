// S3 协议层（纯 MoonBit，不接真实网络）：
// - HttpTransport trait：把"发 HTTP 请求"抽象出来，测试用 RecordingMock 注入
// - MockS3Transport：记录全部请求 + 可预置响应（FIFO）+ 内置一个最小 S3 状态模拟
//   （对象/ETag/条件写 412/ListObjectsV2 分页 XML），用于 put_if_match 语义测试
// - S3Store：ObjectStore 实现。请求全部经 sigv4 签名；
//   put_if_match 语义映射（见 NOTES3 §6）：
//     expected = None      → If-None-Match: *（对象不存在才成功）
//     expected = Some(etag)→ If-Match: <etag>（412 → false）
//   版本串 = ETag（与 MemStore 的 "v{n}" 同一地位：只做相等比较）。
//
// 限制（MVP）：ListObjectsV2 的 XML 用 tag 文本提取而非完整 XML 解析；
// mock 的 XML 不做 key 转义（测试 key 都是纯 ASCII）；不解析 ListOwner 等字段。

///|
/// HTTP 传输抽象：S3Store 只依赖它，真实网络实现由使用方注入（见 README）
pub(open) trait HttpTransport {
  fn execute(
    Self,
    http_method : String,
    url : String,
    headers : Array[(String, String)],
    body : Bytes,
  ) -> (Int, Array[(String, String)], Bytes)
}

///|
/// 被记录下来的请求（测试断言用）
pub(all) struct RecordedRequest {
  http_method : String
  url : String
  headers : Array[(String, String)]
  body : Bytes
} derive(Debug)

///|
/// 大小写不敏感地取响应头
pub fn header_get(headers : Array[(String, String)], name : String) -> String? {
  for h in headers {
    if h.0.to_lower() == name {
      return Some(h.1)
    }
  }
  None
}

// ---------- RecordingMock：记录 + 预置响应 + 最小 S3 状态模拟 ----------

///|
pub struct MockS3Transport {
  bucket : String
  objects : Map[String, Bytes]
  etags : Map[String, String]
  tokens : Map[String, Int]
  requests : Array[RecordedRequest]
  preset : Array[(Int, Array[(String, String)], Bytes)]
  mut preset_pos : Int
  mut next_etag : Int
  mut next_token : Int
  mut conditional_writes_supported : Bool
}

///|
pub fn MockS3Transport::new(bucket : String) -> MockS3Transport {
  {
    bucket,
    objects: Map([]),
    etags: Map([]),
    tokens: Map([]),
    requests: Array::new(),
    preset: Array::new(),
    preset_pos: 0,
    next_etag: 0,
    next_token: 0,
    conditional_writes_supported: true,
  }
}

///|
pub fn MockS3Transport::set_conditional_writes_supported(
  self : MockS3Transport,
  supported : Bool,
) -> Unit {
  self.conditional_writes_supported = supported
}

///|
/// 预置一个对象（键为对象 key，不含 bucket）
pub fn MockS3Transport::seed(
  self : MockS3Transport,
  key : String,
  content : Bytes,
) -> Unit {
  self.next_etag += 1
  let etag = "etag-\{self.next_etag}"
  self.objects.set(key, content)
  self.etags.set(key, etag)
}

///|
/// 预置响应（FIFO）：非空时 execute 直接弹出返回，不再走状态模拟
pub fn MockS3Transport::enqueue(
  self : MockS3Transport,
  status : Int,
  headers : Array[(String, String)],
  body : Bytes,
) -> Unit {
  self.preset.push((status, headers, body))
}

///|
pub impl HttpTransport for MockS3Transport with fn execute(
  self : MockS3Transport,
  http_method : String,
  url : String,
  headers : Array[(String, String)],
  body : Bytes,
) -> (Int, Array[(String, String)], Bytes) {
  self.requests.push({ http_method, url, headers, body })
  if self.preset_pos < self.preset.length() {
    let r = self.preset[self.preset_pos]
    self.preset_pos += 1
    return r
  }
  // 解析 URL：/ 之前是 scheme://host，路径 /{bucket}/... ，查询串 k=v&...
  let (path, query) = split_url(url)
  let prefix = "/" + self.bucket
  let key = if path.has_prefix(prefix + "/") {
    url_decode(path[prefix.length() + 1:].to_owned())
  } else if path == prefix {
    ""
  } else {
    url_decode(path[1:].to_owned())
  }
  let q = parse_query(query)
  match http_method {
    "GET" =>
      if q.get("list-type") is Some("2") {
        self.mock_list(q)
      } else {
        self.mock_get(key, headers)
      }
    "HEAD" => self.mock_head(key)
    "PUT" => self.mock_put(key, headers, body)
    "DELETE" => {
      self.objects.remove(key)
      self.etags.remove(key)
      (204, [], Bytes::make(0, b'\x00'))
    }
    _ => (405, [], Bytes::make(0, b'\x00'))
  }
}

///|
/// 剥掉 scheme://host 后取 (path, query)
fn split_url(url : String) -> (String, String) {
  let mut rest = url
  match url.find("://") {
    Some(i) => rest = url[i + 3:].to_owned()
    None => ()
  }
  let slash = match rest.find("/") {
    Some(i) => i
    None => return ("/", "")
  }
  let path_q = rest[slash:]
  match path_q.find("?") {
    Some(j) => (path_q[:j].to_owned(), path_q[j + 1:].to_owned())
    None => (path_q.to_owned(), "")
  }
}

///|
fn parse_query(qs : String) -> Map[String, String] {
  let m : Map[String, String] = Map([])
  if qs == "" {
    return m
  }
  for kv in qs.split("&") {
    match kv.find("=") {
      Some(i) =>
        m.set(url_decode(kv[:i].to_owned()), url_decode(kv[i + 1:].to_owned()))
      None => m.set(url_decode(kv.to_owned()), "")
    }
  }
  m
}

///|
/// %XX 解码（查询串空格用 %20，'+' 不做特殊处理）
pub fn url_decode(s : String) -> String {
  let bytes = @utf8.encode(s)
  let b = Buffer()
  let n = bytes.length()
  let mut i = 0
  while i < n {
    let c = bytes.get(i).unwrap_or(b'\x00')
    if c.to_int() == 37 && i + 2 < n {
      let hi = hex_val_byte(bytes.get(i + 1).unwrap_or(b'\x00'))
      let lo = hex_val_byte(bytes.get(i + 2).unwrap_or(b'\x00'))
      if hi >= 0 && lo >= 0 {
        b.write_byte(((hi * 16 + lo) & 0xFF).to_byte())
        i += 3
        continue
      }
    }
    b.write_byte(c)
    i += 1
  }
  @utf8.decode(b.to_bytes().view()) catch {
    _ => s
  }
}

///|
fn hex_val_byte(c : Byte) -> Int {
  let v = c.to_int()
  if v >= 48 && v <= 57 {
    v - 48
  } else if v >= 97 && v <= 102 {
    v - 87
  } else if v >= 65 && v <= 70 {
    v - 55
  } else {
    -1
  }
}

///|
fn MockS3Transport::mock_get(
  self : MockS3Transport,
  key : String,
  req_headers : Array[(String, String)],
) -> (Int, Array[(String, String)], Bytes) {
  match self.objects.get(key) {
    None => (404, [], Bytes::make(0, b'\x00'))
    Some(content) => {
      let etag = self.etags.get(key).unwrap_or("etag-0")
      match header_get(req_headers, "range") {
        Some(r) =>
          match parse_range(r, content.length()) {
            RangeMiss => (416, [], Bytes::make(0, b'\x00'))
            RangeSlice(lo, hi) =>
              // 206 + [lo, hi)
              (206, [("ETag", etag)], content[lo:hi].to_owned())
            RangeFull => (200, [("ETag", etag)], content)
          }
        None => (200, [("ETag", etag)], content)
      }
    }
  }
}

///|
priv enum RangeParse {
  RangeFull
  RangeMiss
  RangeSlice(Int, Int)
}

///|
/// "bytes=a-b" / "bytes=a-" → [a, b]（含端）映射为 [a, b)
fn parse_range(r : String, size : Int) -> RangeParse {
  if !r.has_prefix("bytes=") {
    return RangeFull
  }
  let spec = r[6:]
  match spec.find("-") {
    None => RangeFull
    Some(dash) => {
      let a = parse_int_str(spec[:dash].to_owned())
      let b = parse_int_str(spec[dash + 1:].to_owned())
      match a {
        None => RangeFull
        Some(start) =>
          if start >= size {
            RangeMiss
          } else {
            let end = match b {
              Some(e) => if e >= size { size - 1 } else { e }
              None => size - 1
            }
            if end < start {
              RangeMiss
            } else {
              RangeSlice(start, end + 1)
            }
          }
      }
    }
  }
}

///|
fn parse_int_str(s : String) -> Int? {
  if s == "" {
    return None
  }
  let mut n = 0
  for ch in s.iter() {
    let c = ch.to_int()
    if c < 48 || c > 57 {
      return None
    }
    n = n * 10 + (c - 48)
  }
  Some(n)
}

///|
fn MockS3Transport::mock_head(
  self : MockS3Transport,
  key : String,
) -> (Int, Array[(String, String)], Bytes) {
  match self.objects.get(key) {
    None => (404, [], Bytes::make(0, b'\x00'))
    Some(_) =>
      (
        200,
        [("ETag", self.etags.get(key).unwrap_or("etag-0"))],
        Bytes::make(0, b'\x00'),
      )
  }
}

///|
fn MockS3Transport::mock_put(
  self : MockS3Transport,
  key : String,
  req_headers : Array[(String, String)],
  body : Bytes,
) -> (Int, Array[(String, String)], Bytes) {
  let empty = Bytes::make(0, b'\x00')
  let has_cond = header_get(req_headers, "if-match") is Some(_) ||
    header_get(req_headers, "if-none-match") is Some(_)
  if has_cond && !self.conditional_writes_supported {
    return (501, [], empty)
  }
  // 条件写：If-Match 优先于 If-None-Match
  match header_get(req_headers, "if-match") {
    Some(v) =>
      match self.etags.get(key) {
        None => return (412, [], empty) // 对象不存在
        Some(cur) => if cur != v { return (412, [], empty) }
      }
    None => ()
  }
  match header_get(req_headers, "if-none-match") {
    Some("*") => if self.objects.get(key) is Some(_) { return (412, [], empty) }
    _ => ()
  }
  self.next_etag += 1
  let etag = "etag-\{self.next_etag}"
  self.objects.set(key, body)
  self.etags.set(key, etag)
  (200, [("ETag", etag)], empty)
}

///|
fn MockS3Transport::mock_list(
  self : MockS3Transport,
  q : Map[String, String],
) -> (Int, Array[(String, String)], Bytes) {
  let prefix = q.get("prefix").unwrap_or("")
  let max_keys = match q.get("max-keys") {
    Some(s) => parse_int_str(s).unwrap_or(1000)
    None => 1000
  }
  // 全部 key 升序
  let keys : Array[String] = Array::new()
  for kv in self.objects.iter() {
    if kv.0.has_prefix(prefix) {
      keys.push(kv.0)
    }
  }
  keys.sort()
  // continuation token → 起始下标
  let mut start = 0
  match q.get("continuation-token") {
    Some(t) =>
      match self.tokens.get(t) {
        Some(i) => start = i
        None => ()
      }
    None => ()
  }
  let end_i = if start + max_keys < keys.length() {
    start + max_keys
  } else {
    keys.length()
  }
  let truncated = end_i < keys.length()
  let b = Buffer()
  b.write_string_utf8(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ListBucketResult>\n",
  )
  b.write_string_utf8("<IsTruncated>\{truncated}</IsTruncated>\n")
  if truncated {
    self.next_token += 1
    let tok = "tok-\{self.next_token}"
    self.tokens.set(tok, end_i)
    b.write_string_utf8(
      "<NextContinuationToken>\{tok}</NextContinuationToken>\n",
    )
  }
  for i in start..<end_i {
    b.write_string_utf8("<Contents><Key>\{keys[i]}</Key></Contents>\n")
  }
  b.write_string_utf8("</ListBucketResult>\n")
  (200, [], b.to_bytes())
}

// ---------- LeaseCoordinator（条件写降级仲裁） ----------

///|
/// Lease 协调器接口：在底层对象存储不支持原生 CAS（PutObject If-Match / If-None-Match）
/// 或使用方显式配置时，提供基于租约锁的并发互斥保障。
pub(open) trait LeaseCoordinator {
  fn acquire(Self, key : String, owner : String, ttl_ms : Int64) -> Bool
  fn release(Self, key : String, owner : String) -> Bool
}

///|
/// 内存 Lease 协调器：单机/测试环境下提供租约互斥支持。
pub struct MemLeaseCoordinator {
  leases : Map[String, (String, Int64)]
  now_ms : () -> Int64
}

///|
pub fn MemLeaseCoordinator::new(
  now_ms~ : () -> Int64 = fn() { 0L },
) -> MemLeaseCoordinator {
  { leases: Map([]), now_ms }
}

///|
pub impl LeaseCoordinator for MemLeaseCoordinator with fn acquire(
  self : MemLeaseCoordinator,
  key : String,
  owner : String,
  ttl_ms : Int64,
) -> Bool {
  let now = (self.now_ms)()
  match self.leases.get(key) {
    Some((cur_owner, expire)) =>
      if cur_owner == owner {
        self.leases.set(key, (owner, now + ttl_ms))
        true
      } else if now >= expire {
        self.leases.set(key, (owner, now + ttl_ms))
        true
      } else {
        false
      }
    None => {
      self.leases.set(key, (owner, now + ttl_ms))
      true
    }
  }
}

///|
pub impl LeaseCoordinator for MemLeaseCoordinator with fn release(
  self : MemLeaseCoordinator,
  key : String,
  owner : String,
) -> Bool {
  match self.leases.get(key) {
    Some((cur_owner, _)) =>
      if cur_owner == owner {
        self.leases.remove(key)
        true
      } else {
        false
      }
    None => true
  }
}

///|
pub struct LeaseHandler {
  acquire_fn : (String, String, Int64) -> Bool
  release_fn : (String, String) -> Bool
}

// ---------- S3Store ----------

///|
/// 真实/模拟 S3 上的 ObjectStore。region 与凭据一律由构造参数传入，
/// 本包不含任何凭据字面量；时间由 now_amz_date 注入（返回 "YYYYMMDDTHHMMSSZ"）。
pub struct S3Store[T] {
  scheme : String
  host : String
  bucket : String
  region : String
  creds : S3Credentials
  transport : T
  now_amz_date : () -> String
  etag_cache : Map[String, String]
  mut conditional_writes_supported : Bool
  mut lease_coordinator : LeaseHandler?
  mut owner_id : String
}

///|
/// endpoint 形如 "https://s3.us-east-1.amazonaws.com" 或 "http://127.0.0.1:9000"
pub fn[T] S3Store::new(
  endpoint : String,
  bucket : String,
  region : String,
  creds : S3Credentials,
  transport : T,
  now_amz_date : () -> String,
) -> S3Store[T] raise @core.SpndError {
  let idx = match endpoint.find("://") {
    Some(i) => i
    None => raise @core.Corrupt("s3store: endpoint missing scheme://")
  }
  let mut host = endpoint[idx + 3:]
  while host.has_suffix("/") {
    host = host[:host.length() - 1]
  }
  {
    scheme: endpoint[:idx].to_owned(),
    host: host.to_owned(),
    bucket,
    region,
    creds,
    transport,
    now_amz_date,
    etag_cache: Map([]),
    conditional_writes_supported: true,
    lease_coordinator: None,
    owner_id: "s3store-worker-0",
  }
}

///|
/// 设置是否启用服务端原生条件写（If-Match / If-None-Match）。
/// 设为 false 时 put_if_match 自动回退至 Lease 协调器。
pub fn[T] S3Store::set_conditional_writes_supported(
  self : S3Store[T],
  supported : Bool,
) -> Unit {
  self.conditional_writes_supported = supported
}

///|
/// 当前是否支持/启用原生条件写
pub fn[T] S3Store::conditional_writes_supported(self : S3Store[T]) -> Bool {
  self.conditional_writes_supported
}

///|
/// 绑定 Lease 协调器与写者标识（当原生条件写不可用时作 fallback 仲裁）
pub fn[T, L : LeaseCoordinator] S3Store::set_lease_coordinator(
  self : S3Store[T],
  coordinator : L,
  owner_id~ : String = "s3store-worker-0",
) -> Unit {
  self.lease_coordinator = Some({
    acquire_fn: fn(k, o, ttl) { coordinator.acquire(k, o, ttl) },
    release_fn: fn(k, o) { coordinator.release(k, o) },
  })
  self.owner_id = owner_id
}

///|
/// 链式绑定 Lease 协调器
pub fn[T, L : LeaseCoordinator] S3Store::with_lease_coordinator(
  self : S3Store[T],
  coordinator : L,
  owner_id~ : String = "s3store-worker-0",
) -> S3Store[T] {
  self.set_lease_coordinator(coordinator, owner_id~)
  self
}

///|
/// 读 head 指针：0 LIST，1 次 GET /{bucket}/{ns}/_head_ptr
pub fn[T : HttpTransport] S3Store::read_head_pointer(
  self : S3Store[T],
  ns : String,
) -> String? {
  @store.read_head_pointer(self, ns)
}

///|
/// 写 head 指针（PUT /{bucket}/{ns}/_head_ptr）
pub fn[T : HttpTransport] S3Store::write_head_pointer(
  self : S3Store[T],
  ns : String,
  manifest_id : String,
) -> Unit {
  @store.write_head_pointer(self, ns, manifest_id)
}

///|
/// 解析当前 head：优先经 _head_ptr 1 次 GET 解析；不存在时回退 fallback。
/// 保证读/打开路径 0 LIST 请求。
pub fn[T : HttpTransport] S3Store::resolve_head(
  self : S3Store[T],
  ns : String,
  fallback~ : String = "",
) -> String {
  @store.read_head(self, ns, fallback)
}

///|
/// 直接读指定版本的 manifest 对象（0 LIST，1 次 GET /{bucket}/{ns}/_manifest/{manifest_id}.json）
pub fn[T : HttpTransport] S3Store::get_versioned_manifest(
  self : S3Store[T],
  ns : String,
  manifest_id : String,
) -> Bytes? {
  @store.ObjectStore::get(self, "\{ns}/_manifest/\{manifest_id}.json")
}

///|
fn[T : HttpTransport] S3Store::do_req(
  self : S3Store[T],
  req : SignedRequest,
) -> (Int, Array[(String, String)], Bytes) {
  self.transport.execute(req.http_method, req.url, req.headers, req.body)
}

///|
/// key → canonical URI：/{bucket}/{按段 RFC3986 编码的 key}
pub fn[T] S3Store::object_path(self : S3Store[T], key : String) -> String {
  if key == "" {
    // ListObjectsV2 等桶级操作：/{bucket}（无尾斜杠）
    return "/" + self.bucket
  }
  let b = Buffer()
  b.write_string_utf8("/")
  b.write_string_utf8(self.bucket)
  for seg in key.split("/") {
    b.write_string_utf8("/")
    b.write_string_utf8(uri_encode(seg.to_owned(), true))
  }
  @utf8.decode(b.to_bytes().view()) catch {
    _ => "/"
  }
}

///|
fn[T] S3Store::sign(
  self : S3Store[T],
  http_method : String,
  path : String,
  query : Array[(String, String)],
  extra_headers : Array[(String, String)],
  payload : Bytes,
) -> SignedRequest {
  sigv4_sign_request(
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
/// CreateBucket（PUT /{bucket}）。已存在时 S3 返回 409（BucketAlreadyOwnedByYou /
/// BucketAlreadyExists），按幂等成功处理。新版 MinIO 不再对首次 PUT 自动建桶，
/// 探针/工具应先调用本方法。
pub fn[T : HttpTransport] S3Store::create_bucket(self : S3Store[T]) -> Bool {
  let payload = Bytes::make(0, b'\x00')
  let extra : Array[(String, String)] = [
    ("x-amz-content-sha256", sha256_hex(payload)),
  ]
  let req = self.sign("PUT", self.object_path(""), [], extra, payload)
  let (status, _h, _b) = self.do_req(req)
  status == 200 || status == 409
}

///|
/// GetObject（range_header 形如 "bytes=16-47"，None 为整读）
pub fn[T] S3Store::build_get_object(
  self : S3Store[T],
  key : String,
  range_header : String?,
) -> SignedRequest {
  let payload = Bytes::make(0, b'\x00')
  let extra : Array[(String, String)] = [
    ("x-amz-content-sha256", sha256_hex(payload)),
  ]
  match range_header {
    Some(r) => extra.push(("Range", r))
    None => ()
  }
  self.sign("GET", self.object_path(key), [], extra, payload)
}

///|
/// PutObject（条件写：if_match → If-Match；if_none_match → If-None-Match）
pub fn[T] S3Store::build_put_object(
  self : S3Store[T],
  key : String,
  body : Bytes,
  if_match : String?,
  if_none_match : String?,
) -> SignedRequest {
  let extra : Array[(String, String)] = [
    ("x-amz-content-sha256", sha256_hex(body)),
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
pub fn[T] S3Store::build_head_object(
  self : S3Store[T],
  key : String,
) -> SignedRequest {
  let payload = Bytes::make(0, b'\x00')
  let extra : Array[(String, String)] = [
    ("x-amz-content-sha256", sha256_hex(payload)),
  ]
  self.sign("HEAD", self.object_path(key), [], extra, payload)
}

///|
/// ListObjectsV2（分页由调用方续传 continuation token）
pub fn[T] S3Store::build_list_objects_v2(
  self : S3Store[T],
  prefix : String,
  max_keys : Int,
  continuation_token : String?,
) -> SignedRequest {
  let payload = Bytes::make(0, b'\x00')
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
    ("x-amz-content-sha256", sha256_hex(payload)),
  ]
  self.sign("GET", self.object_path(""), query, extra, payload)
}

///|
pub fn[T] S3Store::build_delete_object(
  self : S3Store[T],
  key : String,
) -> SignedRequest {
  let payload = Bytes::make(0, b'\x00')
  let extra : Array[(String, String)] = [
    ("x-amz-content-sha256", sha256_hex(payload)),
  ]
  self.sign("DELETE", self.object_path(key), [], extra, payload)
}

///|
fn[T] S3Store::cache_etag(
  self : S3Store[T],
  key : String,
  status : Int,
  headers : Array[(String, String)],
) -> Unit {
  if status == 200 || status == 206 {
    match header_get(headers, "etag") {
      Some(e) => self.etag_cache.set(key, e)
      None => ()
    }
  }
}

///|
/// 当前版本串（= ETag）：缓存 miss 时 HEAD 填充。key 不存在 → None。
pub fn[T : HttpTransport] S3Store::head_version(
  self : S3Store[T],
  key : String,
) -> String? {
  match self.etag_cache.get(key) {
    Some(e) => Some(e)
    None => {
      let (st, hs, _) = self.do_req(self.build_head_object(key))
      if st != 200 {
        return None
      }
      match header_get(hs, "etag") {
        Some(e) => {
          self.etag_cache.set(key, e)
          Some(e)
        }
        None => None
      }
    }
  }
}

// ---------- ObjectStore 实现 ----------

///|
pub impl[T : HttpTransport] @store.ObjectStore for S3Store[T] with fn get(
  self : S3Store[T],
  key : String,
) -> Bytes? {
  let (st, hs, body) = self.do_req(self.build_get_object(key, None))
  if st == 200 {
    self.cache_etag(key, st, hs)
    Some(body)
  } else {
    None
  }
}

///|
pub impl[T : HttpTransport] @store.ObjectStore for S3Store[T] with fn put(
  self : S3Store[T],
  key : String,
  value : Bytes,
) -> Unit {
  let (st, hs, _) = self.do_req(self.build_put_object(key, value, None, None))
  self.cache_etag(key, st, hs)
  // 非 2xx 静默（trait 不允许 raise）；需要区分时用 build_put_object 自查
}

///|
/// CAS 写入接口：
/// - 原生模式（默认）：
///   expected=None  ⇒ If-None-Match: *（S3 创建 CAS；412 → false）
///   expected=Some  ⇒ If-Match: <ver>（S3 更新 CAS；412 → false）
/// - 若服务端返回 501/400（或显式 set_conditional_writes_supported(false)）
///   且配置了 lease_coordinator，则自动回退到 lease coordinator 仲裁：
///   获取租约 → 校验当前版本 → 无条件 PUT 写入 → 释放租约。
pub impl[T : HttpTransport] @store.ObjectStore for S3Store[T] with fn put_if_match(
  self : S3Store[T],
  key : String,
  expected : String?,
  value : Bytes,
) -> Bool {
  if self.conditional_writes_supported {
    let req = match expected {
      None => self.build_put_object(key, value, None, Some("*"))
      Some(v) => self.build_put_object(key, value, Some(v), None)
    }
    let (st, hs, _) = self.do_req(req)
    if st == 200 || st == 204 {
      self.cache_etag(key, st, hs)
      true
    } else if st == 412 {
      false
    } else if (st == 501 || st == 400) && self.lease_coordinator is Some(_) {
      self.conditional_writes_supported = false
      self.put_if_match_lease(key, expected, value)
    } else {
      false
    }
  } else {
    self.put_if_match_lease(key, expected, value)
  }
}

///|
fn[T : HttpTransport] S3Store::put_if_match_lease(
  self : S3Store[T],
  key : String,
  expected : String?,
  value : Bytes,
) -> Bool {
  match self.lease_coordinator {
    None => false
    Some(coord) => {
      // 1. 获取租约
      if !(coord.acquire_fn)(key, self.owner_id, 30000L) {
        return false
      }
      // 2. 租约保护下校验期望版本
      let cur_ver = self.head_version(key)
      let matched = match expected {
        None => cur_ver is None
        Some(exp) =>
          match cur_ver {
            Some(v) => v == exp
            None => false
          }
      }
      if !matched {
        let _ = (coord.release_fn)(key, self.owner_id)
        return false
      }
      // 3. 执行写入
      let (st, hs, _) = self.do_req(
        self.build_put_object(key, value, None, None),
      )
      let ok = st == 200 || st == 204
      if ok {
        self.cache_etag(key, st, hs)
      }
      // 4. 释放租约
      let _ = (coord.release_fn)(key, self.owner_id)
      ok
    }
  }
}

///|
/// 范围读 [offset, offset+len)。206 直接采用；200（服务器忽略 Range）手动截取；
/// 416（offset 越界）→ 空；404 → None。
pub impl[T : HttpTransport] @store.ObjectStore for S3Store[T] with fn get_range(
  self : S3Store[T],
  key : String,
  offset : Int,
  len : Int,
) -> Bytes? {
  if len <= 0 {
    let (st, _, _) = self.do_req(self.build_head_object(key))
    if st == 200 {
      return Some(Bytes::make(0, b'\x00'))
    }
    return None
  }
  let off = if offset < 0 { 0 } else { offset }
  let range = "bytes=\{off}-\{off + len - 1}"
  let (st, hs, body) = self.do_req(self.build_get_object(key, Some(range)))
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
/// 前缀列出：ListObjectsV2 + continuation token 翻页，升序返回。
/// page_size 可注入以便测试分页（ObjectStore::list 固定 1000）。
pub fn[T : HttpTransport] S3Store::list_page(
  self : S3Store[T],
  prefix : String,
  page_size : Int,
) -> Array[String] {
  let ps = if page_size < 1 {
    1
  } else if page_size > 1000 {
    1000
  } else {
    page_size
  }
  let out : Array[String] = Array::new()
  let mut token : String? = None
  let mut rounds = 0
  while rounds < 100000 {
    rounds += 1
    let (st, _, body) = self.do_req(
      self.build_list_objects_v2(prefix, ps, token),
    )
    if st != 200 {
      break
    }
    let xml = @utf8.decode(body.view()) catch { _ => break }
    for k in xml_all_texts(xml, "Key") {
      out.push(k)
    }
    if xml_first_text(xml, "IsTruncated") is Some("true") {
      match xml_first_text(xml, "NextContinuationToken") {
        Some(t) => token = Some(t)
        None => break
      }
    } else {
      break
    }
  }
  out.sort()
  out
}

///|
pub impl[T : HttpTransport] @store.ObjectStore for S3Store[T] with fn list(
  self : S3Store[T],
  prefix : String,
) -> Array[String] {
  self.list_page(prefix, 1000)
}

///|
pub impl[T : HttpTransport] @store.ObjectStore for S3Store[T] with fn delete(
  self : S3Store[T],
  key : String,
) -> Unit {
  let (_, _, _) = self.do_req(self.build_delete_object(key))
  self.etag_cache.remove(key)
}

// ---------- 极简 XML 文本提取 ----------

///|
/// 第一个 <tag>...</tag> 的文本
fn xml_first_text(xml : String, tag : String) -> String? {
  let open = "<\{tag}>"
  let close = "</\{tag}>"
  match xml.find(open) {
    None => None
    Some(i) => {
      let content_start = i + open.length()
      let rest = xml[content_start:]
      match rest.find(close) {
        None => None
        Some(j) => Some(rest[:j].to_owned())
      }
    }
  }
}

///|
/// 全部 <tag>...</tag> 的文本（按出现顺序）
fn xml_all_texts(xml : String, tag : String) -> Array[String] {
  let out : Array[String] = Array::new()
  let open = "<\{tag}>"
  let close = "</\{tag}>"
  let mut pos = 0
  while true {
    let rest = xml[pos:]
    match rest.find(open) {
      None => break
      Some(i) => {
        let content_start = pos + i + open.length()
        let after = xml[content_start:]
        match after.find(close) {
          None => break
          Some(j) => {
            out.push(after[:j].to_owned())
            pos = content_start + j + close.length()
          }
        }
      }
    }
  }
  out
}
