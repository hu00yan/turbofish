// simstore/chaos_wbtest.mbt
// 确定性仿真测试 (DST) 与混沌故障注入白盒测试
//
// 验证：
// 1. 底层存储健康透传与基础虚拟时钟累加。
// 2. S3 503 RateLimit / SlowDown 注入与重试韧性。
// 3. S3 412 PreconditionFailed (CAS 冲突) 注入与重试韧性。
// 4. S3 404 NotFound 针对性前缀注入与异常捕获。
// 5. ConnectionReset / Timeout 网络超时注入与零 sleep 虚拟时钟累加。
// 6. Partial / Truncated Range GET 尾部字节截断与 @core.Truncated 触发及重试恢复。
// 7. 同种子（UInt64）100% 可重现确定性时序回放（Deterministic Replay）。
// 8. replay_reset() 实例自回放一致性。
// 9. 不同种子产生不同故障序列验证。
// 10. 执行时序轨迹格式化 dump_trace 与摘要。
// 11. 双层集成：ChaosStore 包装 SimStore。

///|
async test "DST Chaos: passthrough healthy operations with virtual latency" {
  let mem = @store.MemStore::new()
  let store = ChaosStore::new(mem, 12345UL)
  store.set_base_latency(500.0) // 500us base latency

  // 1. put
  store.put("key1", b"hello world")
  assert_eq(store.total_calls(), 1)
  assert_eq(store.faults_injected(), 0)
  assert_eq(store.virtual_time_us(), 500.0)

  // 2. get
  let v = store.get("key1")
  assert_eq(v, Some(b"hello world"))
  assert_eq(store.total_calls(), 2)
  assert_eq(store.virtual_time_us(), 1000.0)

  // 3. get_range
  let r = store.get_range("key1", @store.ByteRange::{ off: 0, len: 5 })
  assert_eq(r, Some(b"hello"))
  assert_eq(store.virtual_time_us(), 1500.0)

  // 4. head_version
  let ver = store.head_version("key1")
  assert_eq(ver != None, true)
  assert_eq(store.virtual_time_us(), 2000.0)

  // 5. put_if_match
  let cas_ok = store.put_if_match("key1", ver, b"hello v2")
  assert_eq(cas_ok, true)
  assert_eq(store.virtual_time_us(), 2500.0)

  // 6. list
  let list = store.list("key")
  assert_eq(list, ["key1"])
  assert_eq(store.virtual_time_us(), 3000.0)

  // 7. delete
  store.delete("key1")
  assert_eq(store.get("key1"), None)
  assert_eq(store.total_calls(), 8)
  assert_eq(store.virtual_time_us(), 4000.0)

  // Trace assertions
  let trace = store.get_trace()
  assert_eq(trace.length(), 8)
  for i in 0..<7 {
    let ev = trace[i]
    assert_eq(ev.injected_fault, None)
    assert_eq(ev.success, true)
  }
  // 8th event was get on deleted key => returns None (success=false)
  assert_eq(trace[7].injected_fault, None)
  assert_eq(trace[7].success, false)
}

///|
async test "DST Chaos: S3 503 RateLimit/SlowDown fault injection and retry resilience" {
  let mem = @store.MemStore::new()
  let store = ChaosStore::new(mem, 42UL)
  store.set_base_latency(100.0)
  store.put("ns/meta", b"meta-content")

  // 注入 503，最多触发 2 次，每次增加 10,000us 虚拟退避
  store.inject_503(
    key_prefix="ns/meta",
    probability=1.0,
    latency_us=10000.0,
    max_triggers=2,
    msg="SlowDown test",
  )

  // 单次 get 应该失败（503）
  let direct1 = store.get("ns/meta")
  assert_eq(direct1, None)
  assert_eq(store.faults_injected(), 1)
  assert_eq(
    store.last_fault(),
    Some(InjectedFault::RateLimit503("SlowDown test")),
  )

  // 第二次 get 仍失败（第 2 次 503）
  let direct2 = store.get("ns/meta")
  assert_eq(direct2, None)
  assert_eq(store.faults_injected(), 2)

  // 第三次 get 超过 max_triggers，应该成功
  let direct3 = store.get("ns/meta")
  assert_eq(direct3, Some(b"meta-content"))
  assert_eq(store.faults_injected(), 2) // 没有增加

  // 使用 retry_get 自动化重试测试（新加一条 2 次 503 规则）
  store.inject_503(
    key_prefix="ns/meta",
    probability=1.0,
    latency_us=5000.0,
    max_triggers=2,
  )
  let retry_val = store.retry_get("ns/meta", 3)
  assert_eq(retry_val, Some(b"meta-content"))
}

///|
async test "DST Chaos: S3 412 PreconditionFailed CAS conflict and retry resilience" {
  let mem = @store.MemStore::new()
  let store = ChaosStore::new(mem, 99UL)
  store.set_base_latency(50.0)

  // 初始化 head
  assert_eq(store.put_if_match("ns/_head_ptr", @store.Expected(None), b"manifest-v1"), true)
  let v1 = store.head_version("ns/_head_ptr")

  // 注入 412 冲突，前 2 次 CAS 尝试必定失败
  store.inject_412(
    key_prefix="ns/_head_ptr",
    probability=1.0,
    latency_us=1000.0,
    max_triggers=2,
  )

  // 尝试 CAS 写入：第 1 次被混沌拦截为 412
  let cas1 = store.put_if_match("ns/_head_ptr", v1, b"manifest-v2")
  assert_eq(cas1, false)
  assert_eq(
    store.last_fault(),
    Some(InjectedFault::PreconditionFailed412("PreconditionFailed")),
  )

  // 尝试 CAS 写入：第 2 次仍被混沌拦截为 412
  let cas2 = store.put_if_match("ns/_head_ptr", v1, b"manifest-v2")
  assert_eq(cas2, false)

  // 尝试 CAS 写入：第 3 次超过 max_triggers，真实 CAS 成功
  let cas3 = store.put_if_match("ns/_head_ptr", v1, b"manifest-v2")
  assert_eq(cas3, true)
  assert_eq(store.get("ns/_head_ptr"), Some(b"manifest-v2"))

  // 使用 retry_cas 自动化重试
  let v2 = store.head_version("ns/_head_ptr")
  let _ = v2
  store.inject_412(key_prefix="ns/_head_ptr", max_triggers=2)
  let cas_retry_ok = store.retry_cas("ns/_head_ptr", 5, fn(_cur) {
    b"manifest-v3"
  })
  assert_eq(cas_retry_ok, true)
  assert_eq(store.get("ns/_head_ptr"), Some(b"manifest-v3"))
}

///|
async test "DST Chaos: S3 404 NotFound on targeted prefix" {
  let mem = @store.MemStore::new()
  let store = ChaosStore::new(mem, 77UL)

  store.put("safe/doc1", b"safe data")
  store.put("corrupt/doc2", b"corrupt data")

  // 仅针对 "corrupt/" 前缀注入 404
  store.inject_404(key_prefix="corrupt/", msg="SimulatedNoSuchKey")

  // safe 前缀正常读取
  assert_eq(store.get("safe/doc1"), Some(b"safe data"))

  // corrupt 前缀返回 None，被 404 故障拦截
  assert_eq(store.get("corrupt/doc2"), None)
  assert_eq(
    store.last_fault(),
    Some(InjectedFault::NotFound404("SimulatedNoSuchKey")),
  )

  // get_or_raise 对 404 抛出 @core.NotFound
  let mut raised_not_found = false
  try {
    let _ = store.get_or_raise("corrupt/doc2")

  } catch {
    @core.NotFound(_) => raised_not_found = true
    _ => ()
  }
  assert_eq(raised_not_found, true)
}

///|
async test "DST Chaos: ConnectionReset/Timeout with latency accumulation" {
  let mem = @store.MemStore::new()
  let store = ChaosStore::new(mem, 88UL)
  store.set_base_latency(100.0)

  // 注入 ConnectionReset，模拟 50,000us (50ms) 网络超时，触发 1 次
  store.inject_connection_reset(
    key_prefix="data/",
    latency_us=50000.0,
    max_triggers=1,
    msg="TCP connection reset by peer",
  )

  let t_before = store.virtual_time_us()
  // retry_put: 第 1 次超时失败，第 2 次成功
  let put_ok = store.retry_put("data/blob.bin", b"important data", 3)
  assert_eq(put_ok, true)
  let t_after = store.virtual_time_us()

  // 虚拟时间累加必须 >= 50,000us，且未做真实 sleep
  assert_eq(t_after - t_before >= 50000.0, true)
  assert_eq(store.get("data/blob.bin"), Some(b"important data"))
}

///|
async test "DST Chaos: partial truncated Range GET drops tail bytes and triggers Truncated error" {
  let mem = @store.MemStore::new()
  let store = ChaosStore::new(mem, 555UL)
  store.set_base_latency(50.0)

  // 写入 100 字节数据
  let full_data = Bytes::make(100, b'\xAA')
  store.put("seg/slab.bin", full_data)

  // 注入 TruncatedRangeGet：截断掉 30 个尾部字节，仅触发 1 次
  store.inject_truncated_range(30, key_prefix="seg/", max_triggers=1)

  // 第 1 次读取：被截断为 70 字节
  let truncated_read = store.get_range("seg/slab.bin", @store.ByteRange::{ off: 0, len: 100 })
  assert_eq(truncated_read != None, true)
  let bytes_read = truncated_read.unwrap()
  assert_eq(bytes_read.length(), 70)

  // get_range_or_raise 应该抛出 @core.Truncated
  // 重新注入 1 次以测试 get_range_or_raise
  store.inject_truncated_range(25, key_prefix="seg/", max_triggers=1)
  let mut raised_truncated = false
  try {
    let _ = store.get_range_or_raise("seg/slab.bin", 0, 100)

  } catch {
    @core.Truncated(_) => raised_truncated = true
    _ => ()
  }
  assert_eq(raised_truncated, true)

  // 使用 retry_get_range：第 1 次被截断，重试后获取完整 100 字节
  store.inject_truncated_range(40, key_prefix="seg/", max_triggers=1)
  let recovered = store.retry_get_range("seg/slab.bin", 0, 100, 3)
  assert_eq(recovered != None, true)
  assert_eq(recovered.unwrap().length(), 100)
}

///|
async test "DST Chaos: deterministic replay with identical seed" {
  // 驱动相同的随机混沌规则与工作负载，验证确定性回放
  async fn run_simulation_workload(s : ChaosStore[@store.MemStore]) -> Unit {
    s.put("ns/k1", b"val1")
    s.put("ns/k2", b"val2")
    let _ = s.get("ns/k1")
    let _ = s.get("ns/k2")
    let _ = s.get_range("ns/k1", @store.ByteRange::{ off: 0, len: 2 })
    let _ = s.put_if_match("ns/head", @store.Expected(None), b"h1")
    let v = s.head_version("ns/head")
    let _ = s.put_if_match("ns/head", v, b"h2")
    let _ = s.list("ns/")
    s.delete("ns/k2")
    let _ = s.get("ns/k2")
  }

  let seed = 0xDEADBEEFCAFEUL

  // 运行实例 1
  let mem1 = @store.MemStore::new()
  let store1 = ChaosStore::new(mem1, seed)
  store1.add_rule(
    FaultRule::rate_limit_503(
      key_prefix="ns/",
      probability=0.35,
      latency_us=5000.0,
    ),
  )
  store1.add_rule(
    FaultRule::cas_conflict_412(
      key_prefix="ns/",
      probability=0.4,
      latency_us=2000.0,
    ),
  )
  store1.add_rule(
    FaultRule::truncated_range_get(
      1,
      key_prefix="ns/",
      probability=0.5,
      latency_us=1500.0,
    ),
  )
  run_simulation_workload(store1)
  let trace1 = store1.get_trace()

  // 运行实例 2（相同种子、相同规则）
  let mem2 = @store.MemStore::new()
  let store2 = ChaosStore::new(mem2, seed)
  store2.add_rule(
    FaultRule::rate_limit_503(
      key_prefix="ns/",
      probability=0.35,
      latency_us=5000.0,
    ),
  )
  store2.add_rule(
    FaultRule::cas_conflict_412(
      key_prefix="ns/",
      probability=0.4,
      latency_us=2000.0,
    ),
  )
  store2.add_rule(
    FaultRule::truncated_range_get(
      1,
      key_prefix="ns/",
      probability=0.5,
      latency_us=1500.0,
    ),
  )
  run_simulation_workload(store2)
  let trace2 = store2.get_trace()

  // 核心断言：两份执行日志完全一致（事件数、虚拟时钟、操作、注入故障、成功标志、返回值摘要）
  assert_eq(trace1.length(), trace2.length())
  assert_eq(store1.virtual_time_us(), store2.virtual_time_us())
  assert_eq(store1.faults_injected(), store2.faults_injected())
  for i in 0..<trace1.length() {
    let ev1 = trace1[i]
    let ev2 = trace2[i]
    assert_eq(ev1.step, ev2.step)
    assert_eq(ev1.virtual_time_us, ev2.virtual_time_us)
    assert_eq(ev1.op, ev2.op)
    assert_eq(ev1.injected_fault, ev2.injected_fault)
    assert_eq(ev1.success, ev2.success)
    assert_eq(ev1.result_summary, ev2.result_summary)
  }
}

///|
async test "DST Chaos: replay_reset restores state and reproduces exact trace" {
  let mem = @store.MemStore::new()
  let store = ChaosStore::new(mem, 0x123456789ABCUL)
  store.add_rule(FaultRule::rate_limit_503(probability=0.4, latency_us=3000.0))
  store.add_rule(FaultRule::latency_spike(12000.0, probability=0.3))

  store.put("a", b"1")
  let _ = store.get("a")
  let _ = store.list("")
  let first_trace = store.get_trace()
  let first_virtual_time = store.virtual_time_us()
  let first_faults = store.faults_injected()

  // 重置回放
  store.replay_reset()
  assert_eq(store.total_calls(), 0)
  assert_eq(store.faults_injected(), 0)
  assert_eq(store.virtual_time_us(), 0.0)

  // 再次执行相同序列
  store.put("a", b"1")
  let _ = store.get("a")
  let _ = store.list("")
  let second_trace = store.get_trace()

  assert_eq(store.virtual_time_us(), first_virtual_time)
  assert_eq(store.faults_injected(), first_faults)
  assert_eq(first_trace.length(), second_trace.length())
  for i in 0..<first_trace.length() {
    assert_eq(first_trace[i], second_trace[i])
  }
}

///|
async test "DST Chaos: different seeds produce different fault distributions" {
  let memA = @store.MemStore::new()
  let storeA = ChaosStore::new(memA, 111UL)
  storeA.add_rule(FaultRule::rate_limit_503(probability=0.5))

  let memB = @store.MemStore::new()
  let storeB = ChaosStore::new(memB, 9999999UL)
  storeB.add_rule(FaultRule::rate_limit_503(probability=0.5))

  for i in 0..<50 {
    let key = "k\{i}"
    storeA.put(key, b"v")
    storeB.put(key, b"v")
    let _ = storeA.get(key)
    let _ = storeB.get(key)
  }

  let traceA = storeA.get_trace()
  let traceB = storeB.get_trace()
  assert_eq(traceA.length(), traceB.length())

  // 种子不同，在 100 次操作下必有某些步骤注入状态不同
  let mut differences = 0
  for i in 0..<traceA.length() {
    if traceA[i].injected_fault != traceB[i].injected_fault {
      differences += 1
    }
  }
  assert_eq(differences > 0, true)
}

///|
async test "DST Chaos: execution trace formatting and dump_trace inspection" {
  let mem = @store.MemStore::new()
  let store = ChaosStore::new(mem, 777UL)
  store.inject_503(max_triggers=1)

  let _ = store.get("test/probe")
  store.put("test/probe", b"data")
  let _ = store.get("test/probe")

  let dump = store.dump_trace()
  assert_eq(dump.contains("GET test/probe"), true)
  assert_eq(dump.contains("503 RateLimit/SlowDown"), true)
  assert_eq(dump.contains("PUT test/probe"), true)
  assert_eq(dump.contains("OK"), true)

  let summary = store.trace_summary()
  assert_eq(summary.contains("ChaosStore[seed=777]"), true)
  assert_eq(summary.contains("3 calls"), true)
  assert_eq(summary.contains("1 faults injected"), true)
}

///|
async test "DST Chaos: dual-layer simulation with SimStore as underlying store" {
  let sim = SimStore::new(SimConfig::aws_default(1001U))
  let chaos = ChaosStore::new(sim, 2026UL)
  chaos.set_base_latency(200.0)

  // 注入 1 次 404
  chaos.inject_404(key_prefix="ns/head", max_triggers=1)

  // 第 1 次读取被 Chaos 404 拦截
  assert_eq(chaos.get("ns/head"), None)
  assert_eq(chaos.faults_injected(), 1)

  // 写入后正常读取
  chaos.put("ns/head", b"sim-head-data")
  let read_back = chaos.get("ns/head")
  assert_eq(read_back, Some(b"sim-head-data"))

  // 底层 SimStore 计费与状态保持有效
  let cost = sim.cost()
  assert_eq(cost.puts, 1)
}
