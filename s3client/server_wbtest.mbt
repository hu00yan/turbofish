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
}

///|
fn FakeS3::new() -> FakeS3 {
  { objects: Map([]), etag_seq: 0, flaky_left: 2, list_queries: [], errors: [] }
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
  let payload = body.read_all().binary()
  let raw_path = req.path
  let (route, query) = match raw_path.find("?") {
    Some(i) => (raw_path[:i].to_owned(), raw_path[i + 1:].to_owned())
    None => (raw_path, "")
  }
  let hdr = fn(name : String) {
    req.headers.get(@http.CaseInsensitiveString(name))
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
    assert_eq(as_text(client.get_range("obj", 3, 3).unwrap()), "lo-")
    // GET range：服务端忽略 Range 返回 200 → 客户端本地切片
    assert_eq(as_text(client.get_range("norange", 2, 3).unwrap()), "234")
    // GET range：越界 → 416 → None
    assert_true(client.get_range("obj", 99, 5) is None)
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
    assert_false(client.put_if_match("obj", b"x", None))
    // CAS：不存在时 create → true
    assert_true(client.put_if_match("cas", b"x", None))
    let v = client.head_version("cas").unwrap()
    // CAS：版本不匹配 → 412 → false
    assert_false(client.put_if_match("cas", b"y", Some("\"nope\"")))
    // CAS：版本匹配 → true
    assert_true(client.put_if_match("cas", b"y", Some(v)))
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
