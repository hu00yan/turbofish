// metad：单机元数据服务（纯 MoonBit + moonbitlang/async，无 libcurl）。
//
// 元数据（namespace / manifest / segment meta / 列文件 / centroids / tombstones）
// 存在本机 SSD 上，查询节点通过 HTTP 读取，不再每次查询回 S3 拉元数据。
// 数据分片（segment vec/、FTS postings、global IVF 向量分片）仍由查询节点直接
// 向对象存储发 range GET。
//
// 端点：
//   GET|PUT|DELETE|HEAD /kv/{key}          原始元数据对象读写（完全向后兼容）
//   GET  /head/{ns}                       当前 head manifest id（内存写穿缓存）
//   GET  /v1/bundle/{ns}?known_head={h}   单次 RTT 元数据快包（命中 → 304）
//   POST /leases/acquire                  申请/续期租约（同一 holder 幂等）
//   POST /leases/renew                    仅合法 holder 续期
//   POST /leases/release                  释放租约
//   POST /compact/dirty/{ns}              推入待合并脏队列（去重）
//   POST /compact/claim                   领取一个可合并的 namespace（带租约 epoch）
//   GET  /health                          健康检查
//
// 环境变量：
//   SPND_META_PORT  监听端口，默认 8090
//   SPND_META_DIR   本地目录，默认 /tmp/turbofish-metad

///|
fn env_or(key : String, dflt : String) -> String {
  match @env.get_env_var(key) {
    Some(v) => if v.trim() == "" { dflt } else { v }
    None => dflt
  }
}

///|
fn reason_of(code : Int) -> String {
  match code {
    200 => "OK"
    204 => "No Content"
    304 => "Not Modified"
    400 => "Bad Request"
    404 => "Not Found"
    405 => "Method Not Allowed"
    409 => "Conflict"
    429 => "Too Many Requests"
    _ => "Error"
  }
}

///|
async fn respond(
  conn : @http.ServerConnection,
  code : Int,
  body : Bytes,
) -> Unit {
  let headers : @http.Headers = Map([])
  headers.set(
    @http.CaseInsensitiveString("content-type"),
    "application/octet-stream",
  )
  headers.set(
    @http.CaseInsensitiveString("content-length"),
    body.length().to_string(),
  )
  conn.send_response(code, reason_of(code), extra_headers=headers)
  conn.write(body.exact_view())
  conn.end_response()
}

///|
async fn respond_json(
  conn : @http.ServerConnection,
  code : Int,
  body : String,
) -> Unit {
  let headers : @http.Headers = Map([])
  headers.set(
    @http.CaseInsensitiveString("content-type"),
    "application/json",
  )
  headers.set(
    @http.CaseInsensitiveString("content-length"),
    body.length().to_string(),
  )
  conn.send_response(code, reason_of(code), extra_headers=headers)
  conn.write_string(body)
  conn.end_response()
}

///|
/// 无 body 响应（304 / 404 / 204 等）。
async fn respond_empty(
  conn : @http.ServerConnection,
  code : Int,
) -> Unit {
  conn.send_response(code, reason_of(code))
  conn.end_response()
}

///|
fn object_json(fields : Array[(String, Json)]) -> String {
  let m : Map[String, Json] = Map([])
  for f in fields {
    m.set(f.0, f.1)
  }
  Json::object(m).stringify()
}

///|
fn key_from_path(path : String) -> String? {
  if path.has_prefix(@meta.METAD_KV_PREFIX) {
    let key = path[@meta.METAD_KV_PREFIX.length():].to_owned()
    if key == "" {
      None
    } else {
      Some(key)
    }
  } else {
    None
  }
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
          Some(i) =>
            if pair[:i] == name {
              found = Some(@meta.percent_decode(pair[i + 1:].to_owned()))
            }
          None => ()
        }
      }
      found
    }
  }
}

///|
fn parse_json_object(body : Bytes) -> Map[String, Json]? {
  let j = @json.parse(@utf8.decode_lossy(body.exact_view())) catch {
    _ => return None
  }
  match j {
    Object(m) => Some(m)
    _ => None
  }
}

///|
fn json_str(m : Map[String, Json], key : String, dflt : String) -> String {
  match m.get(key) {
    Some(String(s)) => s
    _ => dflt
  }
}

///|
fn json_int(m : Map[String, Json], key : String, dflt : Int) -> Int {
  match m.get(key) {
    Some(Number(d, ..)) => d.to_int()
    _ => dflt
  }
}

// ---------- /kv/*（向后兼容的原路由） ----------

///|
async fn handle_kv(
  state : MetadState,
  key : String,
  req : @http.Request,
  reader : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  let store = state.store()
  match req.meth {
    @http.Get =>
      match store.get(key) {
        Some(bs) => respond(conn, 200, bs)
        None => respond(conn, 404, b"")
      }
    @http.Put => {
      let body = (reader.read_all()).binary()
      store.put(key, body)
      state.note_put(key, body)
      respond(conn, 200, b"")
    }
    @http.Delete => {
      store.delete(key)
      state.note_delete(key)
      respond(conn, 200, b"")
    }
    @http.Head =>
      match store.head_version(key) {
        Some(v) => {
          let headers : @http.Headers = Map([])
          headers.set(
            @http.CaseInsensitiveString("x-turbofish-version"),
            v,
          )
          conn.send_response(200, reason_of(200), extra_headers=headers)
          conn.end_response()
        }
        None => respond_empty(conn, 404)
      }
    _ => respond_empty(conn, 405)
  }
}

// ---------- /leases/* ----------

///|
fn lease_fields(body : Map[String, Json]) -> (String, String, Int) {
  (
    json_str(body, "resource", ""),
    json_str(body, "holder", ""),
    json_int(body, "ttl_ms", 60000),
  )
}

///|
async fn handle_lease(
  state : MetadState,
  path : String,
  reader : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  let body = match parse_json_object((reader.read_all()).binary()) {
    Some(m) => m
    None => {
      respond_json(conn, 400, object_json([("ok", Json::boolean(false))]))
      return
    }
  }
  let (resource, holder, ttl_ms) = lease_fields(body)
  if resource == "" || holder == "" {
    respond_json(conn, 400, object_json([("ok", Json::boolean(false))]))
    return
  }
  match path {
    "/leases/acquire" =>
      match state.leases().acquire(resource, holder, ttl_ms) {
        @meta.AcquireResult::Granted(epoch) =>
          respond_json(
            conn,
            200,
            object_json([
              ("ok", Json::boolean(true)),
              ("epoch", Json::number(epoch.to_double())),
              ("holder", Json::string(holder)),
            ]),
          )
        @meta.AcquireResult::Denied(current) =>
          respond_json(
            conn,
            409,
            object_json([
              ("ok", Json::boolean(false)),
              ("holder", Json::string(current)),
            ]),
          )
      }
    "/leases/renew" =>
      if state.leases().renew(resource, holder, ttl_ms) {
        respond_json(conn, 200, object_json([("ok", Json::boolean(true))]))
      } else {
        respond_json(
          conn,
          409,
          object_json([
            ("ok", Json::boolean(false)),
            ("holder", Json::string(holder)),
          ]),
        )
      }
    _ =>
      if state.leases().release(resource, holder) {
        respond_json(conn, 200, object_json([("ok", Json::boolean(true))]))
      } else {
        respond_json(conn, 409, object_json([("ok", Json::boolean(false))]))
      }
  }
}

// ---------- /compact/* ----------

///|
async fn handle_compact(
  state : MetadState,
  path : String,
  reader : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  if path.has_prefix("/compact/dirty/") {
    let ns = path[15:].to_owned()
    if ns == "" {
      respond_json(conn, 400, object_json([("queued", Json::boolean(false))]))
      return
    }
    let added = state.dirty().mark(ns)
    respond_json(
      conn,
      200,
      object_json([
        ("queued", Json::boolean(true)),
        ("added", Json::boolean(added)),
      ]),
    )
    return
  }
  // /compact/claim
  let body = match parse_json_object((reader.read_all()).binary()) {
    Some(m) => m
    None => {
      respond_json(conn, 400, object_json([("ns", Json::null())]))
      return
    }
  }
  let holder = json_str(body, "holder", "compactd-0")
  let ttl_ms = json_int(body, "ttl_ms", 60000)
  match state.dirty().claim(state.leases(), holder, ttl_ms) {
    @meta.ClaimResult::Empty =>
      respond_json(
        conn,
        200,
        object_json([
          ("ns", Json::null()),
          ("holder", Json::string(holder)),
        ]),
      )
    @meta.ClaimResult::Claimed(ns, epoch) =>
      respond_json(
        conn,
        200,
        object_json([
          ("ns", Json::string(ns)),
          ("epoch", Json::number(epoch.to_double())),
          ("holder", Json::string(holder)),
        ]),
      )
  }
}

// ---------- /head/* 与 /v1/bundle/* ----------

///|
async fn handle_head(
  state : MetadState,
  ns : String,
  conn : @http.ServerConnection,
) -> Unit {
  match state.head_of(ns) {
    Some(h) => respond_json(conn, 200, object_json([("head", Json::string(h))]))
    None => respond_empty(conn, 404)
  }
}

///|
async fn handle_bundle(
  state : MetadState,
  ns : String,
  known_head : String?,
  conn : @http.ServerConnection,
) -> Unit {
  match state.bundle(ns, known_head) {
    BundleReply::NotModified => respond_empty(conn, 304)
    BundleReply::NoHead => respond_empty(conn, 404)
    BundleReply::Payload(head, ns_json) =>
      respond_json(
        conn,
        200,
        object_json([
          ("head", Json::string(head)),
          ("namespace_json", Json::string(ns_json)),
        ]),
      )
  }
}

// ---------- 路由 ----------

///|
async fn dispatch(
  state : MetadState,
  req : @http.Request,
  reader : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  let (path, query) = split_target(req.path)
  if path == "/health" && req.meth is @http.Get {
    respond_json(
      conn,
      200,
      object_json([
        ("ok", Json::boolean(true)),
        ("root", Json::string(state.root())),
      ]),
    )
    return
  }
  match key_from_path(path) {
    Some(key) => handle_kv(state, key, req, reader, conn)
    None => {
      if path == "/leases/acquire" ||
        path == "/leases/renew" ||
        path == "/leases/release" {
        if req.meth is @http.Post {
          handle_lease(state, path, reader, conn)
        } else {
          respond_empty(conn, 405)
        }
        return
      }
      if path == "/compact/claim" {
        if req.meth is @http.Post {
          handle_compact(state, path, reader, conn)
        } else {
          respond_empty(conn, 405)
        }
        return
      }
      if path.has_prefix("/compact/dirty/") {
        if req.meth is @http.Post {
          handle_compact(state, path, reader, conn)
        } else {
          respond_empty(conn, 405)
        }
        return
      }
      if path.has_prefix("/head/") {
        let ns = path[6:].to_owned()
        if req.meth is @http.Get && ns != "" {
          handle_head(state, ns, conn)
        } else {
          respond_empty(conn, 404)
        }
        return
      }
      if path.has_prefix("/v1/bundle/") {
        let ns = path[11:].to_owned()
        if req.meth is @http.Get && ns != "" {
          handle_bundle(state, ns, query_param(query, "known_head"), conn)
        } else {
          respond_empty(conn, 404)
        }
        return
      }
      respond_empty(conn, 404)
    }
  }
}

///|
async fn main {
  let port = env_or("SPND_META_PORT", "8090")
  let root = env_or("SPND_META_DIR", "/tmp/turbofish-metad")
  let state = MetadState::new(root)
  let addr = @socket.Addr::parse("0.0.0.0:\{port}")
  let server = @http.Server::Server(addr, reuse_addr=true)
  println("turbofish metad on 0.0.0.0:\{port}, root=\{root}")
  server.run_forever(
    async fn (req, reader, conn) {
      dispatch(state, req, reader, conn) catch {
        _ => respond_json(conn, 400, "{\"ok\":false}")
      }
    },
  )
}
