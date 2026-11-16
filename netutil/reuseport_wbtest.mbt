// netutil 白盒测试：真实 ReusePortServer + 真实 @http.Client（真 TCP，非 mock）。

///|
fn rp_addr(port : Int) -> @socket.Addr raise {
  @socket.Addr::parse("127.0.0.1:\{port}")
}

///|
fn rp_text(data : &@io.Data) -> String raise {
  data.text()
}

///|
/// 响应体长度头：显式 Content-Length，客户端才能按固定长度收完。
fn rp_len_header(body : Bytes) -> @http.Headers {
  let hs : @http.Headers = Map([])
  hs.set(@http.CaseInsensitiveString("content-length"), body.length().to_string())
  hs
}

///|
async test "netutil: SO_REUSEPORT permits a second bind of the same address on Linux" {
  // SO_REUSEPORT 的负载均衡语义是 Linux-only（macOS/BSD 上内核不按连接分流，
  // moonbitlang/async 因此只在 Linux 上真正设置该选项）。所以这里按运行时平台
  // 决定是否要求“第二次 bind 成功”。
  let addr = rp_addr(19831)
  let a = ReusePortServer::bind(addr, reuse_port=true)
  assert_eq(a.listen_addr().to_string(), "127.0.0.1:19831")
  let second = try {
    Some(ReusePortServer::bind(addr, reuse_port=true))
  } catch {
    _ => None
  }
  if @async.platform is @types.Platform::Linux {
    assert_true(second is Some(_))
  }
  match second {
    Some(s) => s.close()
    None => ()
  }
  a.close()
  // close 幂等
  a.close()
}

///|
async test "netutil: reuse-port server serves 5 keep-alive GET/POST round trips" {
  let port = 19847
  let server = ReusePortServer::bind(rp_addr(port), reuse_port=true)
  assert_eq(server.listen_addr().to_string(), "127.0.0.1:\{port}")
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
      server.run_forever(
        async fn (req, body, conn) {
          // GET /hello：固定小响应
          if req.meth is @http.Get && req.path == "/hello" {
            let payload = b"hello"
            conn.send_response(200, "OK", extra_headers=rp_len_header(payload))
            conn.write(payload)
            conn.end_response()
            return
          }
          // POST /echo：把请求体原样写回
          if req.meth is @http.Post && req.path == "/echo" {
            let payload = body.read_all().binary()
            conn.send_response(200, "OK", extra_headers=rp_len_header(payload))
            if payload.length() > 0 {
              conn.write(payload)
            }
            conn.end_response()
            return
          }
          let not_found = b"not found"
          conn.send_response(404, "Not Found", extra_headers=rp_len_header(not_found))
          conn.write(not_found)
          conn.end_response()
        },
        allow_failure=true,
      )
    }
    let client = @http.Client("http://127.0.0.1:\{port}")
    defer client.close()
    // 同一个连接上连发 5 轮 GET/POST，验证 keep-alive 复用
    for i in 0..<5 {
      client.request(@http.Get, "/hello")
      let resp = client.end_request()
      assert_eq(resp.code, 200)
      assert_eq(rp_text(client.read_all()), "hello")
      client.request(@http.Post, "/echo")
      client.write(@utf8.encode("ping-\{i}"))
      let resp2 = client.end_request()
      assert_eq(resp2.code, 200)
      assert_eq(rp_text(client.read_all()), "ping-\{i}")
    }
    // 未知路由：404 后连接仍可继续使用
    client.request(@http.Get, "/nope")
    let missing = client.end_request()
    assert_eq(missing.code, 404)
    assert_eq(rp_text(client.read_all()), "not found")
    client.request(@http.Get, "/hello")
    let again = client.end_request()
    assert_eq(again.code, 200)
    assert_eq(rp_text(client.read_all()), "hello")
    // 关闭监听：run_forever 必须返回，测试不得挂起
    server.close()
  }
  server.close()
}
