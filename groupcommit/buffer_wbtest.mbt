// 组提交缓冲器白盒测试：真实协程并发 + 真实异步 sleep，
// 不使用任何 mock，直接验证「20 次小写入被合并成 1~2 次刷盘」。

///|
struct FlushSpy {
  mut calls : Int
  mut entries : Int
  mut active : Int
  mut max_active : Int
  batch_sizes : Array[Int]
}

///|
fn FlushSpy::new() -> FlushSpy {
  { calls: 0, entries: 0, active: 0, max_active: 0, batch_sizes: [] }
}

///|
/// 模拟一次慢速 S3 刷盘：记录本批规模，sleep `latency_ms` 后返回新的 head。
async fn spy_flush(
  spy : FlushSpy,
  ns : String,
  payloads : Array[Bytes],
  latency_ms : Int,
) -> String {
  let _ = ns
  spy.calls += 1
  spy.entries += payloads.length()
  spy.batch_sizes.push(payloads.length())
  spy.active += 1
  if spy.active > spy.max_active {
    spy.max_active = spy.active
  }
  @async.sleep(latency_ms)
  spy.active -= 1
  "manifest-\{spy.calls}"
}

///|
async fn failing_flush(
  ns : String,
  payloads : Array[Bytes],
) -> String {
  let _ = (ns, payloads)
  @async.sleep(5)
  raise GroupCommitError::FlushFailed("simulated S3 failure")
}

///|
async test "group commit: 20 个并发协程的 200 行被合并为 <=2 次刷盘" {
  @async.with_task_group(async fn (group : @async.TaskGroup[Unit]) -> Unit {
    let spy = FlushSpy::new()
    let mgr = GroupCommitManager::new(
      group,
      async fn (ns : String, payloads : Array[Bytes]) -> String {
        spy_flush(spy, ns, payloads, 40)
      },
      config={
        flush_interval_ms: 25,
        max_batch_rows: 2048,
        max_batch_bytes: 8 * 1024 * 1024,
        max_l0_pending: 12,
      },
    )
    let tasks : Array[@async.Task[SubmitResult]] = []
    for i in 0..<20 {
      tasks.push(
        group.spawn(async fn () {
          let _ = i
          mgr.submit("ns1", 10, 128, Bytes::make(128, b'x'))
        }),
      )
    }
    let mut acked = 0
    for t in tasks {
      match t.wait() {
        Flushed(h) => {
          assert_true(h.length() > 0)
          acked += 1
        }
        AckedLazy => ()
      }
    }
    // 20 个协程全部拿到非空 head
    assert_eq(acked, 20)
    let calls = mgr.flush_count()
    assert_true(calls >= 1)
    // 铁证：20 次（共 200 行）小写入被合并成 1~2 次 S3 刷盘
    assert_true(calls <= 2)
    assert_eq(mgr.flushed_rows(), 200)
    // 20 条提交（每条 10 行）确实被合并进了同一批
    assert_eq(spy.entries, 20)
    // 每次刷盘都至少合并了多个提交（平均 20/2 = 10）
    for size in spy.batch_sizes {
      assert_true(size >= 10)
    }
  })
}

///|
async test "group commit: 活跃 L0 达到 max_l0_pending 时快速返回反压" {
  @async.with_task_group(async fn (group : @async.TaskGroup[Unit]) -> Unit {
    let spy = FlushSpy::new()
    let mgr = GroupCommitManager::new(
      group,
      async fn (ns : String, payloads : Array[Bytes]) -> String {
        spy_flush(spy, ns, payloads, 200)
      },
      config={
        flush_interval_ms: 1,
        max_batch_rows: 2048,
        max_batch_bytes: 8 * 1024 * 1024,
        max_l0_pending: 1,
      },
    )
    let first = group.spawn(async fn () {
      mgr.submit("ns1", 1, 1, b"a")
    })
    // 让第一批真正进入 flush_fn（inflight = 1）
    @async.sleep(40)
    assert_eq(mgr.inflight("ns1"), 1)
    let rejected = try {
      let _ = mgr.submit("ns1", 1, 1, b"b")
      false
    } catch {
      GroupCommitError::Backpressure(_) => true
      _ => false
    }
    assert_true(rejected)
    // 反压不丢已入批的数据
    match first.wait() {
      Flushed(h) => assert_true(h.length() > 0)
      AckedLazy => fail("strict submit must return a head")
    }
  })
}

///|
async test "group commit: lazy 模式立即返回且仍会被计时器刷盘" {
  @async.with_task_group(async fn (group : @async.TaskGroup[Unit]) -> Unit {
    let spy = FlushSpy::new()
    let mgr = GroupCommitManager::new(
      group,
      async fn (ns : String, payloads : Array[Bytes]) -> String {
        spy_flush(spy, ns, payloads, 10)
      },
      config={
        flush_interval_ms: 10,
        max_batch_rows: 2048,
        max_batch_bytes: 8 * 1024 * 1024,
        max_l0_pending: 12,
      },
    )
    let r = mgr.submit("ns1", 5, 8, b"lazy", durability_strict=false)
    assert_true(r is AckedLazy)
    assert_eq(mgr.flush_count(), 0)
    // 等计时器到点 + 刷盘完成
    @async.sleep(120)
    assert_eq(mgr.flush_count(), 1)
    assert_eq(mgr.flushed_rows(), 5)
    assert_eq(spy.entries, 1)
  })
}

///|
async test "group commit: flush_fn 失败时本批所有等待者收到错误" {
  @async.with_task_group(async fn (group : @async.TaskGroup[Unit]) -> Unit {
    let mgr = GroupCommitManager::new(
      group,
      failing_flush,
      config={
        flush_interval_ms: 5,
        max_batch_rows: 2048,
        max_batch_bytes: 8 * 1024 * 1024,
        max_l0_pending: 12,
      },
    )
    let tasks : Array[@async.Task[Bool]] = []
    for i in 0..<4 {
      tasks.push(
        group.spawn(async fn () {
          let _ = i
          try {
            let _ = mgr.submit("ns1", 1, 1, b"x")
            false
          } catch {
            _ => true
          }
        }),
      )
    }
    let mut failures = 0
    for t in tasks {
      if t.wait() {
        failures += 1
      }
    }
    assert_eq(failures, 4)
  })
}

///|
test "group commit: Backpressure 映射到 HTTP 429" {
  assert_eq(GroupCommitError::Backpressure("ns1").http_status(), 429)
  assert_eq(GroupCommitError::FlushFailed("boom").http_status(), 500)
}

///|
async test "group commit: 双缓冲——前一批刷盘期间下一批继续积累并并行刷盘" {
  // 单批 40 行 < max_batch_rows(64) → 靠计时器触发；flush 耗时 80ms。
  @async.with_task_group(async fn (group : @async.TaskGroup[Unit]) -> Unit {
    let spy = FlushSpy::new()
    let mgr = GroupCommitManager::new(
      group,
      async fn (ns : String, payloads : Array[Bytes]) -> String {
        spy_flush(spy, ns, payloads, 80)
      },
      config={
        flush_interval_ms: 5,
        max_batch_rows: 64,
        max_batch_bytes: 8 * 1024 * 1024,
        max_l0_pending: 4,
      },
    )
    let first = group.spawn(async fn () {
      mgr.submit("ns1", 40, 40, b"batch-1")
    })
    // 第一批已经进入慢速 flush_fn（80ms）时，第二批开始积累
    @async.sleep(25)
    assert_eq(mgr.inflight("ns1"), 1)
    let second = group.spawn(async fn () {
      mgr.submit("ns1", 40, 40, b"batch-2")
    })
    match first.wait() {
      Flushed(h1) => assert_true(h1.length() > 0)
      AckedLazy => fail("strict submit must return a head")
    }
    match second.wait() {
      Flushed(h2) => assert_true(h2.length() > 0)
      AckedLazy => fail("strict submit must return a head")
    }
    assert_eq(mgr.flush_count(), 2)
    assert_eq(mgr.flushed_rows(), 80)
    // 两批刷盘在时间上真重叠（双缓冲流水线，互不阻塞）
    assert_eq(spy.max_active, 2)
  })
}
