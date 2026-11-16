// metad 的纯 MoonBit 异步客户端（彻底告别 @s3http.CurlTransport / libcurl）。
//
// 传输层：moonbitlang/async/http 的 @http.Client 持久连接槽位池。
//   - max_inflight 个槽位，槽位间可并发，槽位内串行（HTTP/1.1 一条连接只能
//     同时跑一个请求）；get_kv_many 会在多个槽位上并发拉取。
//   - 网络错误时丢弃该槽位连接（下次自动重连）。
//
// 语义层：/kv/*、/head/*、/v1/bundle/*、/leases/*、/compact/* 的状态码
// 在这里被翻译成明确的 Result（None / NotModified / Granted / Denied / Empty）。

///|
/// 客户端错误：非 2xx 且不属于“明确业务语义”的状态码。
pub suberror MetadError {
  /// (status, 请求方法与响应的简短描述)
  HttpStatus(Int, String)
  /// 无法解析的响应
  MalformedResponse(String)
}

///|
/// 一次原始 HTTP 往返的结果。
priv struct MetadResponse {
  status : Int
  body : Bytes
}

///|
/// 单个连接槽位（持久连接 + 串行锁）。
pub struct MetadSlot {
  mut client : @http.Client?
  lock : @async.Mutex
}

///|
/// 元数据服务客户端。
pub struct MetadClient {
  base : String
  max_inflight : Int
  slots : Array[MetadSlot]
  mut next_slot : Int
  pick : @async.Mutex
}

///|
/// 构造客户端。`base_url` 形如 `http://127.0.0.1:8090`（可带尾斜杠）。
pub fn MetadClient::new(
  base_url : String,
  max_inflight~ : Int = 16,
) -> MetadClient {
  let trimmed = base_url.trim()
  let base = if trimmed.has_suffix("/") {
    trimmed[:trimmed.length() - 1].to_owned()
  } else {
    trimmed.to_owned()
  }
  let n = if max_inflight < 1 { 1 } else { max_inflight }
  let slots : Array[MetadSlot] = []
  for _ in 0..<n {
    slots.push({ client: None, lock: @async.Mutex::Mutex() })
  }
  {
    base,
    max_inflight: n,
    slots,
    next_slot: 0,
    pick: @async.Mutex::Mutex(),
  }
}

///|
/// 关闭所有持久连接（幂等）。
pub fn MetadClient::close(self : MetadClient) -> Unit {
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

///|
/// 取一个连接槽位（并发上限 = 槽位数；同槽位串行）。
async fn MetadClient::acquire_slot(self : MetadClient) -> MetadSlot {
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
async fn MetadClient::ensure_client(
  self : MetadClient,
  slot : MetadSlot,
) -> @http.Client {
  match slot.client {
    Some(c) => c
    None => {
      let c = @http.Client::Client(self.base)
      slot.client = Some(c)
      c
    }
  }
}

///|
fn discard_slot(slot : MetadSlot) -> Unit {
  match slot.client {
    Some(c) => {
      c.close()
      slot.client = None
    }
    None => ()
  }
}

///|
/// 单次 HTTP 往返。
async fn MetadClient::send(
  self : MetadClient,
  meth : @http.RequestMethod,
  path : String,
  body : Bytes,
) -> MetadResponse {
  let headers : @http.Headers = Map([])
  let needs_length = body.length() > 0 ||
    (meth is @http.Put || meth is @http.Post)
  if needs_length {
    headers.set(
      @http.CaseInsensitiveString("content-length"),
      body.length().to_string(),
    )
  }
  let slot = self.acquire_slot()
  let attempt : Result[MetadResponse, Error] = try {
    let client = self.ensure_client(slot)
    client.request(meth, path, extra_headers=headers)
    if body.length() > 0 {
      client.write(body)
    }
    let resp = client.end_request()
    let data = client.read_all()
    Ok({ status: resp.code, body: data.binary() })
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
fn body_text(r : MetadResponse) -> String {
  @utf8.decode_lossy(r.body.exact_view())
}

///|
fn describe_status(req_desc : String, r : MetadResponse) -> String {
  let text = body_text(r)
  let snippet = if text.length() > 256 { text[:256].to_owned() } else { text }
  "\{req_desc} -> HTTP \{r.status}: \{snippet}"
}

///|
fn ensure_ok(req_desc : String, r : MetadResponse) -> Unit raise MetadError {
  if !is_ok_status(r.status) {
    raise MetadError::HttpStatus(r.status, describe_status(req_desc, r))
  }
}

///|
fn parse_json_body(req_desc : String, r : MetadResponse) -> Json raise MetadError {
  @json.parse(body_text(r)) catch {
    _ =>
      raise MetadError::MalformedResponse(
        "\{req_desc}: response body is not valid JSON",
      )
  }
}

///|
fn json_string_field(m : Map[String, Json], key : String) -> String? {
  match m.get(key) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn json_u64_field(m : Map[String, Json], key : String) -> UInt64? {
  match m.get(key) {
    Some(Number(d, ..)) =>
      if d < 0.0 || d >= 18446744073709551616.0 {
        None
      } else {
        Some(d.to_int64().reinterpret_as_uint64())
      }
    _ => None
  }
}

///|
fn json_bool_field(m : Map[String, Json], key : String) -> Bool? {
  match m.get(key) {
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => None
  }
}

// ---------- /kv/* ----------

///|
/// 读一个元数据对象：200 → Some(body)，404 → None。
pub async fn MetadClient::get_kv(
  self : MetadClient,
  key : String,
) -> Bytes? {
  let r = self.send(@http.Get, "/kv/" + key, b"")
  if r.status == 200 {
    Some(r.body)
  } else if r.status == 404 {
    None
  } else {
    raise MetadError::HttpStatus(r.status, describe_status("GET /kv/\{key}", r))
  }
}

///|
/// 并发批量读：每个 key 走各自槽位的持久连接，互不串行阻塞。
/// 返回数组与 `keys` 等长，缺失项为 None。
pub async fn MetadClient::get_kv_many(
  self : MetadClient,
  keys : Array[String],
) -> Array[Bytes?] {
  let jobs : Array[async () -> Bytes?] = []
  for k in keys {
    let key = k
    jobs.push(async fn () { self.get_kv(key) })
  }
  @async.all(jobs)
}

///|
/// 写一个元数据对象。
pub async fn MetadClient::put_kv(
  self : MetadClient,
  key : String,
  value : Bytes,
) -> Unit {
  let r = self.send(@http.Put, "/kv/" + key, value)
  if !is_ok_status(r.status) {
    raise MetadError::HttpStatus(
      r.status,
      describe_status("PUT /kv/\{key}", r),
    )
  }
}

///|
/// 删除一个元数据对象（幂等）。
pub async fn MetadClient::delete_kv(
  self : MetadClient,
  key : String,
) -> Unit {
  let r = self.send(@http.Delete, "/kv/" + key, b"")
  if !is_ok_status(r.status) {
    raise MetadError::HttpStatus(
      r.status,
      describe_status("DELETE /kv/\{key}", r),
    )
  }
}

// ---------- /head/* 与 /v1/bundle/* ----------

///|
/// 读当前 head manifest id：404 → None。
pub async fn MetadClient::get_head(
  self : MetadClient,
  ns : String,
) -> String? {
  let r = self.send(@http.Get, "/head/" + ns, b"")
  if r.status == 404 {
    return None
  }
  ensure_ok("GET /head/\{ns}", r)
  let j = parse_json_body("GET /head/\{ns}", r)
  match j {
    Object(m) =>
      match json_string_field(m, "head") {
        Some(h) => Some(h)
        None =>
          raise MetadError::MalformedResponse("GET /head/\{ns}: missing head")
      }
    _ => raise MetadError::MalformedResponse("GET /head/\{ns}: not an object")
  }
}

///|
/// 单次 RTT 元数据快包的结果。
pub(all) enum BundleResult {
  /// 客户端给出的 known_head 与当前 head 相同：服务端返回 304，没有 body
  NotModified
  /// 当前 head + namespace.json 全文
  Bundle(String, String)
}

///|
/// 单次 RTT 拉取 (head, namespace.json)：
///   - known_head 命中当前 head（且 head 非空）→ 304 → NotModified
///   - 否则 200 → Bundle(head, namespace_json)
pub async fn MetadClient::get_bundle(
  self : MetadClient,
  ns : String,
  known_head? : String? = None,
) -> BundleResult {
  let mut path = "/v1/bundle/" + ns
  match known_head {
    Some(h) => path = path + "?known_head=" + percent_encode(h)
    None => ()
  }
  let r = self.send(@http.Get, path, b"")
  if r.status == 304 {
    return BundleResult::NotModified
  }
  ensure_ok("GET /v1/bundle/\{ns}", r)
  // 空 body 视为没有变化（服务端可能用 200 + 空 body 表示 not modified）
  if r.body.length() == 0 {
    return BundleResult::NotModified
  }
  let j = parse_json_body("GET /v1/bundle/\{ns}", r)
  match j {
    Object(m) => {
      let head = match json_string_field(m, "head") {
        Some(h) => h
        None => ""
      }
      let ns_json = match json_string_field(m, "namespace_json") {
        Some(s) => s
        None => ""
      }
      BundleResult::Bundle(head, ns_json)
    }
    _ =>
      raise MetadError::MalformedResponse(
        "GET /v1/bundle/\{ns}: not an object",
      )
  }
}

// ---------- /leases/* ----------

///|
fn lease_body(resource : String, holder : String, ttl_ms : Int) -> Bytes {
  let m : Map[String, Json] = Map([])
  m.set("resource", Json::string(resource))
  m.set("holder", Json::string(holder))
  m.set("ttl_ms", Json::number(ttl_ms.to_double()))
  @utf8.encode(Json::object(m).stringify())
}

///|
/// 申请（或续期）租约。409 → Denied(当前 holder)。
pub async fn MetadClient::acquire_lease(
  self : MetadClient,
  resource : String,
  holder : String,
  ttl_ms : Int,
) -> AcquireResult {
  let r = self.send(
    @http.Post,
    "/leases/acquire",
    lease_body(resource, holder, ttl_ms),
  )
  if r.status == 409 {
    let j = parse_json_body("POST /leases/acquire", r)
    let current = match j {
      Object(m) =>
        match json_string_field(m, "holder") {
          Some(h) => h
          None => ""
        }
      _ => ""
    }
    return AcquireResult::Denied(current)
  }
  ensure_ok("POST /leases/acquire", r)
  let j = parse_json_body("POST /leases/acquire", r)
  match j {
    Object(m) =>
      match json_u64_field(m, "epoch") {
        Some(epoch) => AcquireResult::Granted(epoch)
        None =>
          raise MetadError::MalformedResponse(
            "POST /leases/acquire: missing epoch",
          )
      }
    _ =>
      raise MetadError::MalformedResponse(
        "POST /leases/acquire: not an object",
      )
  }
}

///|
/// 续期租约：仅当前合法 holder 成功，否则 false。
pub async fn MetadClient::renew_lease(
  self : MetadClient,
  resource : String,
  holder : String,
  ttl_ms : Int,
) -> Bool {
  let r = self.send(
    @http.Post,
    "/leases/renew",
    lease_body(resource, holder, ttl_ms),
  )
  if r.status == 409 {
    return false
  }
  ensure_ok("POST /leases/renew", r)
  match parse_json_body("POST /leases/renew", r) {
    Object(m) =>
      match json_bool_field(m, "ok") {
        Some(ok) => ok
        None => true
      }
    _ => true
  }
}

///|
/// 释放租约：holder 匹配（或资源不存在）成功，否则 false。
pub async fn MetadClient::release_lease(
  self : MetadClient,
  resource : String,
  holder : String,
) -> Bool {
  let m : Map[String, Json] = Map([])
  m.set("resource", Json::string(resource))
  m.set("holder", Json::string(holder))
  let r = self.send(
    @http.Post,
    "/leases/release",
    @utf8.encode(Json::object(m).stringify()),
  )
  if r.status == 409 {
    return false
  }
  ensure_ok("POST /leases/release", r)
  match parse_json_body("POST /leases/release", r) {
    Object(mm) =>
      match json_bool_field(mm, "ok") {
        Some(ok) => ok
        None => true
      }
    _ => true
  }
}

// ---------- /compact/* ----------

///|
/// 把 namespace 推入待合并脏队列（服务端去重）。
pub async fn MetadClient::mark_dirty(
  self : MetadClient,
  ns : String,
) -> Bool {
  let r = self.send(@http.Post, "/compact/dirty/" + ns, b"")
  ensure_ok("POST /compact/dirty/\{ns}", r)
  match parse_json_body("POST /compact/dirty/\{ns}", r) {
    Object(m) =>
      match json_bool_field(m, "queued") {
        Some(q) => q
        None => true
      }
    _ => true
  }
}

///|
/// 从脏队列领取一个 namespace（同时拿到 `compact:{ns}` 租约）。
/// 队列空（或全部被别的 compactor 持有）→ Empty。
pub async fn MetadClient::claim_dirty(
  self : MetadClient,
  holder : String,
  ttl_ms : Int,
) -> ClaimResult {
  let m : Map[String, Json] = Map([])
  m.set("holder", Json::string(holder))
  m.set("ttl_ms", Json::number(ttl_ms.to_double()))
  let r = self.send(
    @http.Post,
    "/compact/claim",
    @utf8.encode(Json::object(m).stringify()),
  )
  ensure_ok("POST /compact/claim", r)
  let j = parse_json_body("POST /compact/claim", r)
  match j {
    Object(mm) =>
      match mm.get("ns") {
        None =>
          raise MetadError::MalformedResponse("POST /compact/claim: missing ns")
        Some(Null) => ClaimResult::Empty
        Some(String(ns)) => {
          let epoch = match json_u64_field(mm, "epoch") {
            Some(e) => e
            None => 0UL
          }
          ClaimResult::Claimed(ns, epoch)
        }
        _ =>
          raise MetadError::MalformedResponse(
            "POST /compact/claim: bad ns field",
          )
      }
    _ =>
      raise MetadError::MalformedResponse("POST /compact/claim: not an object")
  }
}
