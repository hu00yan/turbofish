// 路由纯函数测试：namespace 归属必须确定性、范围内、可分散；
// 端口推导必须单调且可复现。

///|
test "writer_owner_for_ns: 确定性 + 范围内" {
  // 同一 ns 任意次计算都相同
  assert_eq(writer_owner_for_ns("ns1", 4), writer_owner_for_ns("ns1", 4))
  assert_eq(writer_owner_for_ns("", 4), writer_owner_for_ns("", 4))
  // 单 worker / 非法 worker_count → 恒 0
  assert_eq(writer_owner_for_ns("ns1", 1), 0)
  assert_eq(writer_owner_for_ns("ns1", 0), 0)
  assert_eq(writer_owner_for_ns("ns1", -3), 0)
  // 结果必须落在 [0, worker_count)
  for n in [2, 3, 4, 7, 16] {
    for i in 0..<200 {
      let ns = "tenant-\{i}/ns-\{i * 7}"
      let owner = writer_owner_for_ns(ns, n)
      assert_true(owner >= 0)
      assert_true(owner < n)
    }
  }
}

///|
test "writer_owner_for_ns: 分散到多个 worker" {
  let n = 4
  let seen : Array[Bool] = Array::make(n, false)
  for i in 0..<200 {
    seen[writer_owner_for_ns("ns-\{i}", n)] = true
  }
  let mut used = 0
  for s in seen {
    if s {
      used += 1
    }
  }
  // 200 个不同 namespace 至少覆盖一半以上 worker（FNV 分散性）
  assert_true(used >= n / 2)
}

///|
test "fnv1a64: 与已知向量一致" {
  // FNV-1a 64 标准测试向量
  assert_eq(fnv1a64(""), 0xcbf29ce484222325UL)
  assert_eq(fnv1a64("a"), 0xaf63dc4c8601ec8cUL)
  assert_eq(fnv1a64("foobar"), 0x85944171f73967e8UL)
}

///|
test "worker_internal_port / worker_serve_port: base + id" {
  assert_eq(worker_internal_port(19080, 0), 19080)
  assert_eq(worker_internal_port(19080, 3), 19083)
  assert_eq(worker_internal_port(19080, -1), 19080)
  assert_eq(worker_serve_port(8080, 0), 8080)
  assert_eq(worker_serve_port(8080, 5), 8085)
  assert_eq(worker_serve_port(8080, -2), 8080)
  // 相邻 worker 端口不重叠
  assert_true(worker_internal_port(19080, 1) > worker_internal_port(19080, 0))
  assert_true(worker_serve_port(8080, 1) > worker_serve_port(8080, 0))
}
