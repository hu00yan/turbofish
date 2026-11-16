// metad 控制面端到端测试：起真实 @http.Server，直接跑 main.mbt 的 dispatch，
// 再用 meta 包的 MetadClient 走真 TCP 打全部端点（租约 / 脏队列 / head / bundle）。

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
async test "e2e: metad 租约 / 脏队列 / head / bundle 304 / kv 兼容" {
  let dir = "/tmp/turbofish-metad-wbtest-\{@env.now()}"
  let state = MetadState::new(dir)
  let mut bound : (@http.Server, Int)? = None
  let mut port = 19511
  while port < 19561 && bound is None {
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
        async fn (req, reader, conn) {
          dispatch(state, req, reader, conn) catch {
            _ => respond_empty(conn, 400)
          }
        },
        allow_failure=true,
      )
    }
    let client = @meta.MetadClient::new("http://127.0.0.1:\{port}", max_inflight=4)
    defer client.close()
    // ---- /kv/* 兼容 ----
    client.put_kv("plain/key", @utf8.encode("value-1"))
    assert_eq(
      @utf8.decode_lossy(client.get_kv("plain/key").unwrap().exact_view()),
      "value-1",
    )
    assert_true(client.get_kv("plain/missing") is None)
    client.delete_kv("plain/key")
    assert_true(client.get_kv("plain/key") is None)
    // ---- /head/{ns} 与写穿缓存 ----
    client.put_kv("ns1/_head_ptr", @utf8.encode("manifest-001"))
    assert_eq(client.get_head("ns1"), Some("manifest-001"))
    assert_true(client.get_head("nope") is None)
    client.put_kv("ns1/_meta/namespace.json", @utf8.encode("{\"ns\":\"ns1\"}"))
    // ---- /v1/bundle/{ns} ----
    match client.get_bundle("ns1") {
      @meta.BundleResult::NotModified => fail("first bundle must carry payload")
      @meta.BundleResult::Bundle(head, ns_json) => {
        assert_eq(head, "manifest-001")
        assert_eq(ns_json, "{\"ns\":\"ns1\"}")
      }
    }
    match client.get_bundle("ns1", known_head=Some("manifest-001")) {
      @meta.BundleResult::NotModified => ()
      @meta.BundleResult::Bundle(_, _) => fail("known_head hit must be 304")
    }
    // head 前进后 known_head 过期 → 返回新快包
    client.put_kv("ns1/_head_ptr", @utf8.encode("manifest-002"))
    match client.get_bundle("ns1", known_head=Some("manifest-001")) {
      @meta.BundleResult::NotModified => fail("stale known_head must revalidate")
      @meta.BundleResult::Bundle(head, _) => assert_eq(head, "manifest-002")
    }
    // ---- /leases/* ----
    match client.acquire_lease("compact:ns1", "w1", 60000) {
      @meta.AcquireResult::Granted(_) => ()
      @meta.AcquireResult::Denied(_) => fail("fresh lease must be granted")
    }
    match client.acquire_lease("compact:ns1", "w2", 60000) {
      @meta.AcquireResult::Granted(_) => fail("lease must be exclusive")
      @meta.AcquireResult::Denied(h) => assert_eq(h, "w1")
    }
    assert_true(client.renew_lease("compact:ns1", "w1", 60000))
    assert_false(client.renew_lease("compact:ns1", "w2", 60000))
    assert_true(client.release_lease("compact:ns1", "w1"))
    match client.acquire_lease("compact:ns1", "w2", 60000) {
      @meta.AcquireResult::Granted(_) => ()
      @meta.AcquireResult::Denied(_) => fail("released lease must be acquirable")
    }
    // ---- /compact/* ----
    assert_true(client.mark_dirty("dns1"))
    let _ = client.mark_dirty("dns1") // 去重
    assert_eq(state.dirty().len(), 1)
    match client.claim_dirty("compactd-0", 60000) {
      @meta.ClaimResult::Claimed(ns, epoch) => {
        assert_eq(ns, "dns1")
        assert_true(epoch > 0UL)
      }
      @meta.ClaimResult::Empty => fail("dirty queue must yield dns1")
    }
    match client.claim_dirty("compactd-1", 60000) {
      @meta.ClaimResult::Empty => ()
      @meta.ClaimResult::Claimed(_, _) => fail("queue should be drained")
    }
  }
}
