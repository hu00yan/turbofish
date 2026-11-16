// netutil：SO_REUSEPORT HTTP 服务器。
//
// 动机：`@http.Server::Server` 没有把 `@socket.TcpServer` 的 `reuse_port_lb`
// 暴露出来，于是无法让多个进程（或同一进程的多个 accept 循环）绑定同一个
// 监听地址、由内核按连接做负载均衡。这里直接用 `@socket.TcpServer` 自己拿着
// `reuse_port_lb`，再用 `@http.ServerConnection` 复刻 `@http.Server::run_forever`
// 的请求循环（keep-alive：一个连接上串行处理多个请求），从而补上这个缺口。
//
// ===== handler 契约（与 @http.Server::run_forever 的差异） =====
// `@http.ServerConnection` 的发送状态机（SendingHeader/WaitingResponseBody/
// SendingFixed/SendingBody）在包外不可见，所以本模块无法像上游那样
// “handler 忘了收尾就自动 end_response()”。因此每个请求 handler 必须自己
// 把响应写完：
//   1. `conn.send_response(code, reason, extra_headers=...)`
//   2. 写响应体（`conn.write(...)` / `conn.write_string(...)`）
//   3. `conn.end_response()`
// 三者齐备后连接才能进入下一个 keep-alive 请求（否则后续 send_response 会被
// 上游状态机 guard 打断）。循环在 handler 返回后会 flush 一次，保证已写内容
// 立刻发给对端。

///
/// 一个使用 `SO_REUSEPORT` 的 HTTP 服务器。
///
/// 多个进程/线程可以各自 `bind` 同一个地址，内核按 4 元组把新连接分给其中
/// 一个监听 socket（`reuse_port_lb`）。
pub struct ReusePortServer {
  addr : @socket.Addr
  server : @socket.TcpServer
  headers : @http.Headers
  mut closed : Bool
}

///|
/// 绑定 `addr` 并开始监听。
///
/// - `reuse_port=true`（默认）：设置 `SO_REUSEPORT`，允许同地址多次绑定，
///   由内核做连接级负载均衡。
/// - `reuse_addr=true`（默认）：设置 `SO_REUSEADDR`，避免 TIME_WAIT 期间
///   无法重启服务。
/// - `headers`：所有响应的公共头。
pub async fn ReusePortServer::bind(
  addr : @socket.Addr,
  reuse_port? : Bool = true,
  reuse_addr? : Bool = true,
  dual_stack? : Bool,
  headers? : @http.Headers = Map([]),
) -> ReusePortServer {
  let server = @socket.TcpServer(
    addr,
    dual_stack?,
    reuse_addr=reuse_addr,
    reuse_port_lb=reuse_port,
  )
  { addr: server.addr, server, headers, closed: false }
}

///|
/// 实际监听地址（端口 0 绑定后可用它拿到内核分配的端口）。
pub fn ReusePortServer::listen_addr(self : ReusePortServer) -> @socket.Addr {
  self.addr
}

///|
/// 关闭监听 socket。幂等：重复调用是空操作；关闭后再 `run_forever` 会立即返回。
pub fn ReusePortServer::close(self : ReusePortServer) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  self.server.close()
}

///|
/// 服务主循环：接受新连接，并在每个连接上串行处理 keep-alive 请求。
///
/// - `handler` 的三个参数分别是请求、可读请求体的 `@io.Reader`、以及用来
///   发送响应的 `@http.ServerConnection`（它同时也是 `@io.Writer`）。
///   handler 必须完成响应（`send_response` + 写 body + `end_response`）。
/// - `allow_failure=true`（默认）时 handler 抛出的错误只会中断当前连接，
///   不会带崩整个服务；连接一定被关闭。
/// - 传 `max_connections` 可限制并行客户端数量，多余的连接排队等待。
///
/// 关闭服务器（`close()`）会让本函数返回。
pub async fn ReusePortServer::run_forever(
  self : ReusePortServer,
  handler : async (@http.Request, &@io.Reader, @http.ServerConnection) -> Unit,
  allow_failure? : Bool = true,
  max_connections? : Int32,
) -> Unit {
  self.server.run_forever(
    (conn, _peer) => {
      let conn = @http.ServerConnection::new(conn, headers=self.headers)
      defer conn.close()
      for ;; {
        let request = conn.read_request()
        handler(request, conn, conn)
        // handler 已经把响应写完（含 end_response），这里只保证数据真的出门。
        conn.flush()
      }
    },
    allow_failure~,
    max_connections?,
  )
}
