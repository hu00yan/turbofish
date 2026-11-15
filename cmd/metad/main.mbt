// metad：单机元数据服务。
//
// 元数据（namespace / manifest / segment meta / 列文件 / centroids / tombstones）
// 存在本机 SSD 上，查询节点通过 HTTP 读取，不再每次查询回 S3 拉元数据。
// 数据分片（segment vec/、FTS postings、global IVF 向量分片）仍由查询节点直接
// 向对象存储发 range GET。
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
async fn respond(
  conn : @http.ServerConnection,
  code : Int32,
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
  conn.send_response(code, if code == 200 { "OK" } else { "Not Found" }, extra_headers=headers)
  conn.write(body.exact_view())
  conn.end_response()
}

///|
async fn respond_json(
  conn : @http.ServerConnection,
  code : Int32,
  body : String,
) -> Unit {
  let headers : @http.Headers = Map([])
  headers.set(
    @http.CaseInsensitiveString("content-type"),
    "application/json",
  )
  conn.send_response(code, if code == 200 { "OK" } else { "Bad Request" }, extra_headers=headers)
  conn.write_string(body)
  conn.end_response()
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
async fn main {
  let port = env_or("SPND_META_PORT", "8090")
  let root = env_or("SPND_META_DIR", "/tmp/turbofish-metad")
  let store = @fsstore.FsStore::new(root)
  let addr = @socket.Addr::parse("0.0.0.0:\{port}")
  let server = @http.Server::Server(addr, reuse_addr=true)
  println("turbofish metad on 0.0.0.0:\{port}, root=\{root}")
  server.run_forever(
    async fn (req, reader, conn) {
      if req.path == "/health" && req.meth is @http.Get {
        respond_json(conn, 200, "{\"ok\":true,\"root\":\"\{root}\"}")
        return
      }
      match key_from_path(req.path) {
        Some(key) =>
          match req.meth {
            @http.Get => {
              match store.get(key) {
                Some(bs) => respond(conn, 200, bs)
                None => respond(conn, 404, b"")
              }
            }
            @http.Put => {
              let body = (reader.read_all()).binary()
              store.put(key, body)
              respond(conn, 200, b"")
            }
            @http.Delete => {
              store.delete(key)
              respond(conn, 200, b"")
            }
            @http.Head => {
              match store.head_version(key) {
                Some(v) => {
                  let headers : @http.Headers = Map([])
                  headers.set(
                    @http.CaseInsensitiveString("x-turbofish-version"),
                    v,
                  )
                  conn.send_response(200, "OK", extra_headers=headers)
                  conn.end_response()
                }
                None => {
                  conn.send_response(404, "Not Found")
                  conn.end_response()
                }
              }
            }
            _ => respond(conn, 400, b"")
          }
        None => respond(conn, 404, b"")
      }
    },
  )
}
