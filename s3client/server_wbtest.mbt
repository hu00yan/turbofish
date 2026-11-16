// 端到端测试：起一个最小的假 S3（moonbitlang/async @http.Server），
// 用真实 HTTP 往返验证状态码映射、Range、条件写、分页与重试。
// 不使用任何 mock transport/拦截器：走的是真 TCP + 真持久连接。

///|
priv struct FakeS3 {
  objects : Map[String, (Bytes, String)]
  mut etag_seq : Int
  mut flaky_left : Int
  list_queries : Array[String]
  errors : Array[String]
  // 并发观测：当前正在处理的请求数 / 历史峰值（验证客户端真并发）
  mut current_inflight : Int
  mut max_inflight_seen : Int
}

///|
fn FakeS3::new() -> FakeS3 {
  {
    objects: Map([]),
    etag_seq: 0,
    flaky_left: 2,
    list_queries: [],
    errors: [],
    current_inflight: 0,
    max_inflight_seen: 0,
  }
}

///|
/// 进入一个请求的处理区间，并刷新并发峰值
fn FakeS3::enter(self : FakeS3) -> Unit {
  self.current_inflight += 1
  if self.current_inflight > self.max_inflight_seen {
    self.max_inflight_seen = self.current_inflight
  }
}

///|
fn FakeS3::leave(self : FakeS3) -> Unit {
  self.current_inflight -= 1
}

///|
fn FakeS3::seed(self : FakeS3, path : String, body : Bytes, etag : String) -> Unit {
  self.objects.set(path, (body, etag))
}

///|
fn headers_of(pairs : Array[(String, String)]) -> @http.Headers {
  let hs : @http.Headers = Map([])
  for p in pairs {
    hs.set(@http.CaseInsensitiveString(p.0), p.1)
  }
  hs
}

///|
async fn reply(
  conn : @http.ServerConnection,
  code : Int,
  reason : String,
  body : Bytes,
  extra : Array[(String, String)],
  head? : Bool = false,
) -> Unit {
  let pairs : Array[(String, String)] = [("content-length", body.length().to_string())]
  for e in extra {
    pairs.push(e)
  }
  conn.send_response(code, reason, extra_headers=headers_of(pairs))
  if body.length() > 0 && !head {
    conn.write(body)
  }
  conn.end_response()
}

///|
fn list_xml(keys : Array[String], truncated : Bool, token : String?) -> String {
  let b = StringBuilder()
  b.write_string(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult><Name>bkt</Name>",
  )
  b.write_string("<KeyCount>\{keys.length()}</KeyCount><MaxKeys>1000</MaxKeys>")
  b.write_string(if truncated { "<IsTruncated>true</IsTruncated>" } else { "<IsTruncated>false</IsTruncated>" })
  match token {
    Some(t) => {
      b.write_string("<NextContinuationToken>")
      b.write_string(t)
      b.write_string("</NextContinuationToken>")
    }
    None => ()
  }
  for k in keys {
    b.write_string("<Contents><Key>")
    b.write_string(k)
    b.write_string("</Key><Size>1</Size><StorageClass>STANDARD</StorageClass></Contents>")
  }
  b.write_string("</ListBucketResult>")
  b.to_string()
}

///|
async fn fake_s3_handler(
  state : FakeS3,
  req : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  state.enter()
  defer state.leave()
  let payload = body.read_all().binary()
  let raw_path = req.path
  let (route, query) = match raw_path.find("?") {
    Some(i) => (raw_path[:i].to_owned(), raw_path[i + 1:].to_owned())
    None => (raw_path, "")
  }
  let hdr = fn(name : String) {
    req.headers.get(@http.CaseInsensitiveString(name))
  }
  // 慢路径：/bkt/slow/ 前缀模拟 40ms S3 RTT（用于验证批量接口是真并发）
  if route.has_prefix("/bkt/slow/") {
    @async.sleep(40)
  }
  // ---- ListObjectsV2 ----
  if req.meth is @http.Get && route == "/bkt" {
    state.list_queries.push(query)
    let second = query.contains("continuation-token=")
    let xml = if second {
      list_xml(["pfx/b"], false, None)
    } else {
      list_xml(["pfx/a"], true, Some("tok2"))
    }
    reply(
      conn,
      200,
      "OK",
      @utf8.encode(xml),
      [("content-type", "application/xml")],
    )
    return
  }
  // ---- 重试用：前两次 503，第三次 200 ----
  if req.meth is @http.Get && route == "/bkt/flaky" {
    if state.flaky_left > 0 {
      state.flaky_left -= 1
      reply(conn, 503, "Service Unavailable", b"slow down", [])
    } else {
      reply(conn, 200, "OK", b"ok", [])
    }
    return
  }
  if req.meth is @http.Get && route == "/bkt/always-fail" {
    reply(conn, 500, "Internal Server Error", b"boom", [])
    return
  }
  // ---- 忽略 Range 的服务端行为（用于验证客户端本地切片）----
  if req.meth is @http.Get && route == "/bkt/norange" {
    reply(conn, 200, "OK", b"0123456789", [])
    return
  }
  // ---- GetObject / HeadObject ----
  if req.meth is @http.Get || req.meth is @http.Head {
    match state.objects.get(route) {
      None =>
        reply(
          conn,
          404,
          "Not Found",
          b"<Error><Code>NoSuchKey</Code></Error>",
          [],
          head=req.meth is @http.Head,
        )
      Some(entry) => {
        let (stored, etag) = entry
        let extra : Array[(String, String)] = [("etag", etag)]
        let is_head = req.meth is @http.Head
        match hdr("range") {
          Some(r) =>
            match parse_range(r, stored.length()) {
              Some((start, stop)) => {
                extra.push((
                  "content-range",
                  "bytes \{start}-\{stop}/\{stored.length()}",
                ))
                reply(
                  conn,
                  206,
                  "Partial Content",
                  stored[start:stop + 1].to_owned(),
                  extra,
                  head=is_head,
                )
              }
              None =>
                reply(conn, 416, "Range Not Satisfiable", b"", extra, head=is_head)
            }
          None => reply(conn, 200, "OK", stored, extra, head=is_head)
        }
      }
    }
    return
  }
  // ---- PutObject（含条件写）----
  if req.meth is @http.Put {
    let if_none_match = hdr("if-none-match")
    let if_match = hdr("if-match")
    if if_none_match == Some("*") && state.objects.get(route) is Some(_) {
      reply(conn, 412, "Precondition Failed", b"", [])
      return
    }
    if if_match is Some(expected) {
      let cur = match state.objects.get(route) {
        Some(e) => e.1
        None => ""
      }
      if cur != expected {
        reply(conn, 412, "Precondition Failed", b"", [])
        return
      }
    }
    state.etag_seq += 1
    let etag = "\"v\{state.etag_seq}\""
    state.objects.set(route, (payload, etag))
    reply(conn, 200, "OK", b"", [("etag", etag)])
    return
  }
  // ---- DeleteObject ----
  if req.meth is @http.Delete {
    state.objects.remove(route)
    reply(conn, 204, "No Content", b"", [])
    return
  }
  reply(conn, 400, "Bad Request", b"unsupported", [])
}

///|
/// 解析 `bytes=start-stop`（闭区间），越界 → None
fn parse_range(header : String, total : Int) -> (Int, Int)? {
  let rest = match header.find("=") {
    Some(i) => header[i + 1:].to_owned()
    None => return None
  }
  let (a, b) = match rest.split_once("-") {
    Some(p) => (p.0.to_owned(), p.1.to_owned())
    None => return None
  }
  let start : Int = try {
    @string.parse_int(a)
  } catch {
    _ => return None
  }
  let stop : Int = try {
    @string.parse_int(b)
  } catch {
    _ => return None
  }
  if start < 0 || start >= total || stop < start {
    return None
  }
  Some((start, if stop >= total { total - 1 } else { stop }))
}

///|
fn as_text(b : Bytes) -> String {
  @utf8.decode_lossy(b.exact_view())
}

///|
async fn try_bind(port : Int) -> @http.Server? {
  try {
    Some(
      @http.Server::Server(
        @socket.Addr::parse("127.0.0.1:\{port}"),
        reuse_addr=true,
      ),
    )
  } catch {
    _ => None
  }
}

///|
async test "e2e: 假 S3 服务器验证状态码映射 / Range / CAS / 分页 / 重试" {
  let state = FakeS3::new()
  state.seed("/bkt/obj", b"hello-s3", "\"v1\"")
  let mut bound : (@http.Server, Int)? = None
  let mut port = 19317
  while port < 19347 && bound is None {
    match try_bind(port) {
      Some(s) => bound = Some((s, port))
      None => ()
    }
    port += 1
  }
  let (server, port) = match bound {
    Some(x) => x
    None => panic()
  }
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
      server.run_forever(
        async fn (req, body, conn) {
          try {
            fake_s3_handler(state, req, body, conn)
          } catch {
            e => {
              state.errors.push(
                "\{@debug.to_string(req.meth)} \{req.path}: \{e}",
              )
            }
          }
        },
        allow_failure=true,
      )
    }
    let client = S3Client::new(
      "http://127.0.0.1:\{port}",
      "bkt",
      "us-east-1",
      "AKIDEXAMPLE",
      "secret",
      max_inflight=2,
      max_attempts=3,
    )
    defer client.close()
    // GET：200 / 404
    assert_eq(as_text(client.get("obj").unwrap()), "hello-s3")
    assert_true(client.get("missing") is None)
    // GET range：服务端返回 206
    assert_eq(as_text(client.fetch_range("obj", 3, 3).unwrap()), "lo-")
    // GET range：服务端忽略 Range 返回 200 → 客户端本地切片
    assert_eq(as_text(client.fetch_range("norange", 2, 3).unwrap()), "234")
    // GET range：越界 → 416 → None
    assert_true(client.fetch_range("obj", 99, 5) is None)
    // HEAD：ETag（服务端返回对象大小但无 body，符合 S3 语义）
    assert_eq(client.head_version("obj"), Some("\"v1\""))
    assert_true(client.head_version("missing") is None)
    // PUT + GET 回读
    client.put("new", b"abc")
    assert_eq(as_text(client.get("new").unwrap()), "abc")
    // 空 body 的 PUT（显式 Content-Length: 0，避免 411）
    client.put("empty", b"")
    assert_eq(as_text(client.get("empty").unwrap()), "")
    // CAS：已存在时 create → 412 → false
    assert_false(client.conditional_put("obj", b"x", None))
    // CAS：不存在时 create → true
    assert_true(client.conditional_put("cas", b"x", None))
    let v = client.head_version("cas").unwrap()
    // CAS：版本不匹配 → 412 → false
    assert_false(client.conditional_put("cas", b"y", Some("\"nope\"")))
    // CAS：版本匹配 → true
    assert_true(client.conditional_put("cas", b"y", Some(v)))
    assert_eq(as_text(client.get("cas").unwrap()), "y")
    // DELETE（幂等：删不存在的 key 也不报错）
    client.delete("cas")
    assert_true(client.get("cas") is None)
    client.delete("cas")
    // LIST：两页分页
    assert_eq(client.list("pfx/"), ["pfx/a", "pfx/b"])
    assert_false(state.list_queries[0].contains("continuation-token="))
    assert_true(state.list_queries[1].contains("continuation-token=tok2"))
    // 重试：503 / 503 / 200 → 最终成功
    assert_eq(as_text(client.get("flaky").unwrap()), "ok")
    // 重试耗尽 → raise
    let failed = try {
      let _ = client.get("always-fail")
      false
    } catch {
      _ => true
    }
    assert_true(failed)
    server.close()
  }
  for e in state.errors {
    println("fake-s3 handler error: \{e}")
  }
  assert_eq(state.errors.length(), 0)
}

///|
async test "e2e: 真并发批量 ObjectStore（put_many / get_many / get_range_many）+ CAS 参数顺序" {
  let state = FakeS3::new()
  let mut bound : (@http.Server, Int)? = None
  let mut port = 19347
  while port < 19377 && bound is None {
    match try_bind(port) {
      Some(s) => bound = Some((s, port))
      None => ()
    }
    port += 1
  }
  let (server, port) = match bound {
    Some(x) => x
    None => panic()
  }
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
      server.run_forever(
        async fn (req, body, conn) {
          try {
            fake_s3_handler(state, req, body, conn)
          } catch {
            e => {
              state.errors.push(
                "\{@debug.to_string(req.meth)} \{req.path}: \{e}",
              )
            }
          }
        },
        allow_failure=true,
      )
    }
    let client = S3Client::new(
      "http://127.0.0.1:\{port}",
      "bkt",
      "us-east-1",
      "AKIDEXAMPLE",
      "secret",
      max_inflight=4,
      max_attempts=3,
    )
    defer client.close()
    // ---- 1) 并发写 8 个对象（slow/ 前缀 → 每个 40ms RTT）----
    let n = 8
    let items : Array[(String, Bytes)] = Array(capacity=n)
    for i in 0..<n {
      items.push(("slow/k\{i}", @utf8.encode("body-\{i}")))
    }
    @store.ObjectStore::put_many(client, items)
    // 写入必须真的落进假 S3（8 个对象 + 1 个探测用 __none__ 都没有额外对象）
    assert_eq(state.objects.length(), n)
    // 铁证：写路径确实是并发在飞（max_inflight=4，顺序实现只会有 1）
    assert_true(state.max_inflight_seen >= 2)

    // ---- 2) 并发整读：下标与内容 100% 对上（中间夹一个缺失 key）----
    state.max_inflight_seen = 0
    let keys : Array[String] = ["slow/k0", "slow/missing", "slow/k1"]
    for i in 2..<n {
      keys.push("slow/k\{i}")
    }
    let got = @store.ObjectStore::get_many(client, keys)
    assert_eq(got.length(), keys.length())
    assert_eq(as_text(got[0].unwrap()), "body-0")
    // None 停在缺失 key 的原下标，不压缩、不重排
    assert_true(got[1] is None)
    assert_eq(as_text(got[2].unwrap()), "body-1")
    for i in 2..<n {
      assert_eq(as_text(got[i + 1].unwrap()), "body-\{i}")
    }
    assert_true(state.max_inflight_seen >= 2)

    // ---- 3) 并发范围读：区间切片与下标都对 ----
    state.max_inflight_seen = 0
    let ranges : Array[@store.KeyRange] = Array(capacity=n)
    for i in 0..<n {
      // "body-{i}" 的 [1, 4) → "ody"
      ranges.push(@store.KeyRange::{ key: "slow/k\{i}", off: 1, len: 3 })
    }
    let rg = @store.ObjectStore::get_range_many(client, ranges)
    assert_eq(rg.length(), ranges.length())
    for i in 0..<n {
      assert_eq(as_text(rg[i].unwrap()), "ody")
    }
    assert_true(state.max_inflight_seen >= 2)

    // ---- 4) BatchStore 是同一套并发能力的显式命名（结果逐位一致）----
    let again = @store.BatchStore::get_many(client, ["slow/k3", "slow/missing"])
    assert_eq(as_text(again[0].unwrap()), "body-3")
    assert_true(again[1] is None)
    let again_rg = @store.BatchStore::get_range_many(client, [@store.KeyRange::{ key: "slow/k4", off: 0, len: 5 }])
    assert_eq(as_text(again_rg[0].unwrap()), "body-")

    // ---- 5) 单键方法经 @store.ObjectStore trait 调用与直接调用等价 ----
    // （薄委托不能自我递归：trait 实现里调用的是 S3Client 自己的 inherent 方法）
    assert_eq(as_text(@store.ObjectStore::get(client, "slow/k5").unwrap()), "body-5")
    @store.ObjectStore::put(client, "slow/trait-put", b"tp")
    assert_eq(
      as_text(@store.ObjectStore::get_range(client, "slow/trait-put", @store.ByteRange::{ off: 0, len: 2 }).unwrap()),
      "tp",
    )
    assert_true(@store.ObjectStore::head_version(client, "slow/trait-put") is Some(_))
    // FakeS3 的 ListObjectsV2 是固定两页响应，这里只验证 trait 转发到了 list
    assert_eq(@store.ObjectStore::list(client, "pfx/"), ["pfx/a", "pfx/b"])
    @store.ObjectStore::delete(client, "slow/trait-put")
    assert_true(@store.ObjectStore::get(client, "slow/trait-put") is None)

    // ---- 6) ObjectStore::put_if_match 参数顺序 (key, expected, value) ----
    // create（expected=None → If-None-Match: *）成功
    assert_true(@store.ObjectStore::put_if_match(client, "slow/cas", None, b"v1"))
    assert_eq(as_text(client.get("slow/cas").unwrap()), "v1")
    // 已存在再 create → 412 → false
    assert_false(@store.ObjectStore::put_if_match(client, "slow/cas", None, b"v2"))
    assert_eq(as_text(client.get("slow/cas").unwrap()), "v1")
    // 版本不匹配 → false（参数没被写反：若写反，value 会被当成 expected）
    assert_false(
      @store.ObjectStore::put_if_match(
        client,
        "slow/cas",
        Some("\"nope\""),
        b"v3",
      ),
    )
    assert_eq(as_text(client.get("slow/cas").unwrap()), "v1")
    // 版本匹配 → true，新 body 落盘
    let cur = client.head_version("slow/cas").unwrap()
    assert_true(@store.ObjectStore::put_if_match(client, "slow/cas", Some(cur), b"v4"))
    assert_eq(as_text(client.get("slow/cas").unwrap()), "v4")

    server.close()
  }
  for e in state.errors {
    println("fake-s3 handler error: \{e}")
  }
  assert_eq(state.errors.length(), 0)
  // 全部请求处理完后在飞请求归零
  assert_eq(state.current_inflight, 0)
}
