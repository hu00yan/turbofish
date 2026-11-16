// MetadClient 白盒端到端测试：起一个真实的本地 @http.Server（走真 TCP +
// 持久连接），用同一个 metad 状态机原语（LeaseTable / DirtyQueue）验证：
//   - /kv/* 读写删
//   - 租约互斥、续期、释放与过期抢占
//   - 脏队列去重、claim、以及“被别的 compactor 持有则跳过”
//   - get_bundle 命中 known_head → 304 → NotModified
//   - get_kv_many 在多槽位上真并发

///|
struct FakeMetad {
  store : Map[String, Bytes]
  leases : LeaseTable
  dirty : DirtyQueue
  lock : @async.Mutex
  mut active_gets : Int
  mut peak_gets : Int
}

///|
fn FakeMetad::new() -> FakeMetad {
  {
    store: Map([]),
    leases: LeaseTable::new(),
    dirty: DirtyQueue::new(),
    lock: @async.Mutex::Mutex(),
    active_gets: 0,
    peak_gets: 0,
  }
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
fn header_map(pairs : Array[(String, String)]) -> @http.Headers {
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
  body : String,
) -> Unit {
  let pairs : Array[(String, String)] = [
    ("content-type", "application/json"),
    ("content-length", body.length().to_string()),
  ]
  conn.send_response(code, reason, extra_headers=header_map(pairs))
  conn.write_string(body)
  conn.end_response()
}

///|
/// 无 body 的响应（304 必须没有 body 与 content-length: 0 之外的东西）。
async fn reply_empty(
  conn : @http.ServerConnection,
  code : Int,
  reason : String,
) -> Unit {
  conn.send_response(code, reason)
  conn.end_response()
}

///|
fn split_target(target : String) -> (String, String?) {
  match target.find("?") {
    Some(i) => (target[:i].to_owned(), Some(target[i + 1:].to_owned()))
    None => (target, None)
  }
}

///|
fn query_param(query : String?, name : String) -> String? {
  match query {
    None => None
    Some(q) => {
      let mut found : String? = None
      for pair in q.split("&") {
        match pair.find("=") {
          Some(i) => {
            if pair[:i] == name {
              found = Some(percent_decode(pair[i + 1:].to_owned()))
            }
          }
          None => ()
        }
      }
      found
    }
  }
}

///|
fn json_obj(body : Bytes) -> Map[String, Json]? {
  let j = @json.parse(as_text(body)) catch {
    _ => return None
  }
  match j {
    Object(m) => Some(m)
    _ => None
  }
}

///|
fn obj_str(m : Map[String, Json], key : String) -> String {
  match m.get(key) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn obj_int(m : Map[String, Json], key : String) -> Int {
  match m.get(key) {
    Some(Number(d, ..)) => d.to_int()
    _ => 0
  }
}

///|
fn ok_json(fields : Array[(String, Json)]) -> String {
  let m : Map[String, Json] = Map([])
  m.set("ok", Json::boolean(true))
  for f in fields {
    m.set(f.0, f.1)
  }
  Json::object(m).stringify()
}

///|
fn metad_head_key(ns : String) -> String {
  ns + "/_head_ptr"
}

///|
fn metad_ns_json_key(ns : String) -> String {
  ns + "/_meta/namespace.json"
}

///|
async fn fake_metad_handler(
  state : FakeMetad,
  req : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  let (path, query) = split_target(req.path)
  // ---------- /kv/* ----------
  if path.has_prefix(METAD_KV_PREFIX) {
    let key = path[METAD_KV_PREFIX.length():].to_owned()
    match req.meth {
      @http.Get => {
        state.lock.acquire()
        state.active_gets += 1
        if state.active_gets > state.peak_gets {
          state.peak_gets = state.active_gets
        }
        state.lock.release()
        // 人为延迟：让并发槽位在小批量读上也明显重叠
        @async.sleep(20)
        state.lock.acquire()
        state.active_gets -= 1
        state.lock.release()
        match state.store.get(key) {
          Some(v) => {
            let pairs : Array[(String, String)] = [
              ("content-type", "application/octet-stream"),
              ("content-length", v.length().to_string()),
            ]
            conn.send_response(200, "OK", extra_headers=header_map(pairs))
            conn.write(v)
            conn.end_response()
          }
          None => reply_empty(conn, 404, "Not Found")
        }
      }
      @http.Put => {
        let data = (body.read_all()).binary()
        state.store.set(key, data)
        reply_empty(conn, 200, "OK")
      }
      @http.Delete => {
        state.store.remove(key)
        reply_empty(conn, 200, "OK")
      }
      _ => reply_empty(conn, 400, "Bad Request")
    }
    return
  }
  // ---------- /head/{ns} ----------
  if path.has_prefix("/head/") {
    let ns = path[6:].to_owned()
    match state.store.get(metad_head_key(ns)) {
      Some(v) => {
        let m : Map[String, Json] = Map([])
        m.set("head", Json::string(as_text(v)))
        reply(conn, 200, "OK", Json::object(m).stringify())
      }
      None => reply_empty(conn, 404, "Not Found")
    }
    return
  }
  // ---------- /v1/bundle/{ns} ----------
  if path.has_prefix("/v1/bundle/") {
    let ns = path[11:].to_owned()
    let head = match state.store.get(metad_head_key(ns)) {
      Some(v) => as_text(v)
      None => ""
    }
    let known = match query_param(query, "known_head") {
      Some(h) => h
      None => ""
    }
    if head != "" && known == head {
      reply_empty(conn, 304, "Not Modified")
      return
    }
    let ns_json = match state.store.get(metad_ns_json_key(ns)) {
      Some(v) => as_text(v)
      None => ""
    }
    let m : Map[String, Json] = Map([])
    m.set("head", Json::string(head))
    m.set("namespace_json", Json::string(ns_json))
    reply(conn, 200, "OK", Json::object(m).stringify())
    return
  }
  // ---------- /leases/* ----------
  if path == "/leases/acquire" || path == "/leases/renew" ||
    path == "/leases/release" {
    let m = match json_obj((body.read_all()).binary()) {
      Some(m) => m
      None => {
        reply_empty(conn, 400, "Bad Request")
        return
      }
    }
    let resource = obj_str(m, "resource")
    let holder = obj_str(m, "holder")
    if path == "/leases/acquire" {
      let ttl = obj_int(m, "ttl_ms")
      match state.leases.acquire(resource, holder, ttl) {
        AcquireResult::Granted(epoch) =>
          reply(
            conn,
            200,
            "OK",
            ok_json([
              ("epoch", Json::number(epoch.to_double())),
              ("holder", Json::string(holder)),
            ]),
          )
        AcquireResult::Denied(current) => {
          let mm : Map[String, Json] = Map([])
          mm.set("ok", Json::boolean(false))
          mm.set("holder", Json::string(current))
          reply(conn, 409, "Conflict", Json::object(mm).stringify())
        }
      }
    } else if path == "/leases/renew" {
      let ttl = obj_int(m, "ttl_ms")
      if state.leases.renew(resource, holder, ttl) {
        reply(conn, 200, "OK", ok_json([]))
      } else {
        reply(conn, 409, "Conflict", "{\"ok\":false}")
      }
    } else {
      if state.leases.release(resource, holder) {
        reply(conn, 200, "OK", ok_json([]))
      } else {
        reply(conn, 409, "Conflict", "{\"ok\":false}")
      }
    }
    return
  }
  // ---------- /compact/dirty/{ns} ----------
  if path.has_prefix("/compact/dirty/") {
    let ns = path[15:].to_owned()
    let added = state.dirty.mark(ns)
    let m : Map[String, Json] = Map([])
    m.set("queued", Json::boolean(true))
    m.set("added", Json::boolean(added))
    reply(conn, 200, "OK", Json::object(m).stringify())
    return
  }
  // ---------- /compact/claim ----------
  if path == "/compact/claim" {
    let m = match json_obj((body.read_all()).binary()) {
      Some(m) => m
      None => {
        reply_empty(conn, 400, "Bad Request")
        return
      }
    }
    let holder = obj_str(m, "holder")
    let ttl = obj_int(m, "ttl_ms")
    let out : Map[String, Json] = Map([])
    match state.dirty.claim(state.leases, holder, ttl) {
      ClaimResult::Empty => out.set("ns", Json::null())
      ClaimResult::Claimed(ns, epoch) => {
        out.set("ns", Json::string(ns))
        out.set("epoch", Json::number(epoch.to_double()))
      }
    }
    reply(conn, 200, "OK", Json::object(out).stringify())
    return
  }
  reply_empty(conn, 404, "Not Found")
}

///|
async test "e2e: MetadClient 租约 / 脏队列 / bundle 304 / 并发批读" {
  let state = FakeMetad::new()
  let mut bound : (@http.Server, Int)? = None
  let mut port = 19411
  while port < 19461 && bound is None {
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
          fake_metad_handler(state, req, body, conn) catch {
            _ => reply_empty(conn, 500, "Internal Server Error")
          }
        },
        allow_failure=true,
      )
    }
    let client = MetadClient::new("http://127.0.0.1:\{port}", max_inflight=8)
    defer client.close()
    // ---- /kv/* ----
    client.put_kv("ns1/_head_ptr", @utf8.encode("manifest-001"))
    assert_eq(as_text(client.get_kv("ns1/_head_ptr").unwrap()), "manifest-001")
    assert_true(client.get_kv("ns1/nope") is None)
    client.delete_kv("ns1/_head_ptr")
    assert_true(client.get_kv("ns1/_head_ptr") is None)
    // ---- get_kv_many：6 个 key 并发拉取 ----
    for i in 0..<6 {
      client.put_kv("batch/k\{i}", @utf8.encode("v\{i}"))
    }
    let keys : Array[String] = []
    for i in 0..<6 {
      keys.push("batch/k\{i}")
    }
    let got = client.get_kv_many(keys)
    assert_eq(got.length(), 6)
    for i in 0..<6 {
      assert_eq(as_text(got[i].unwrap()), "v\{i}")
    }
    // 真并发证据：服务端观察到的并发 GET 峰值 > 1
    assert_true(state.peak_gets > 1)
    // ---- 租约互斥 / 续期 / 释放 ----
    match client.acquire_lease("compact:ns1", "w1", 60000) {
      Granted(e1) =>
        assert_true(e1 > 0UL)
      Denied(_) => fail("first acquire must be granted")
    }
    match client.acquire_lease("compact:ns1", "w2", 60000) {
      Granted(_) => fail("second holder must be denied")
      Denied(h) => assert_eq(h, "w1")
    }
    // 同一 holder 重复 acquire = 续期，epoch 递增
    let e2 = match client.acquire_lease("compact:ns1", "w1", 60000) {
      Granted(e) => e
      Denied(_) => {
        fail("same holder must re-acquire")
        0UL
      }
    }
    assert_true(e2 > 1UL)
    assert_true(client.renew_lease("compact:ns1", "w1", 60000))
    assert_false(client.renew_lease("compact:ns1", "w2", 60000))
    assert_true(client.release_lease("compact:ns1", "w1"))
    // 再次释放（资源已不存在）→ 幂等成功
    assert_true(client.release_lease("compact:ns1", "w1"))
    match client.acquire_lease("compact:ns1", "w2", 60000) {
      Granted(_) => ()
      Denied(_) => fail("released lease must be acquirable")
    }
    // ---- 过期抢占 ----
    match client.acquire_lease("compact:ns2", "w1", 40) {
      Granted(_) => ()
      Denied(_) => fail("fresh lease must be granted")
    }
    @async.sleep(90)
    // 过期后原 holder 不能再续期
    assert_false(client.renew_lease("compact:ns2", "w1", 60000))
    match client.acquire_lease("compact:ns2", "w2", 60000) {
      Granted(_) => ()
      Denied(_) => fail("expired lease must be stealable")
    }
    // ---- 脏队列：去重 + claim + 被占用则跳过 ----
    assert_true(client.mark_dirty("dns1"))
    let _ = client.mark_dirty("dns1")
    assert_eq(state.dirty.len(), 1)
    match client.claim_dirty("compactd-0", 60000) {
      Empty => fail("dirty queue must yield dns1")
      Claimed(ns, epoch) => {
        assert_eq(ns, "dns1")
        assert_true(epoch > 0UL)
      }
    }
    match client.claim_dirty("compactd-1", 60000) {
      Empty => ()
      Claimed(_, _) => fail("dirty queue should be empty now")
    }
    // dns2 已被别的 compactor 持有 → claim 跳过（返回 Empty 且留在队列里）
    let _ = client.mark_dirty("dns2")
    let _ = client.acquire_lease("compact:dns2", "other-compactor", 60000)
    match client.claim_dirty("compactd-1", 60000) {
      Empty => ()
      Claimed(ns, _) => fail("leased namespace must be skipped: " + ns)
    }
    assert_eq(state.dirty.len(), 1)
    assert_true(client.release_lease("compact:dns2", "other-compactor"))
    match client.claim_dirty("compactd-1", 60000) {
      Claimed(ns, _) => assert_eq(ns, "dns2")
      Empty => fail("released namespace must be claimable")
    }
    // ---- head / bundle / 304 ----
    client.put_kv("nsb/_head_ptr", @utf8.encode("manifest-2026:001"))
    client.put_kv("nsb/_meta/namespace.json", @utf8.encode("{\"ns\":\"nsb\"}"))
    assert_eq(client.get_head("nsb"), Some("manifest-2026:001"))
    assert_true(client.get_head("no-such-ns") is None)
    match client.get_bundle("nsb") {
      NotModified => fail("first bundle fetch must return the payload")
      Bundle(head, ns_json) => {
        assert_eq(head, "manifest-2026:001")
        assert_eq(ns_json, "{\"ns\":\"nsb\"}")
      }
    }
    // known_head 命中 → 304（空 body），客户端翻译成 NotModified
    match client.get_bundle("nsb", known_head=Some("manifest-2026:001")) {
      NotModified => ()
      Bundle(_, _) => fail("matching known_head must be 304")
    }
    // known_head 不命中 → 返回新快包
    match client.get_bundle("nsb", known_head=Some("manifest-old")) {
      NotModified => fail("stale known_head must return the payload")
      Bundle(head, _) => assert_eq(head, "manifest-2026:001")
    }
  }
}
