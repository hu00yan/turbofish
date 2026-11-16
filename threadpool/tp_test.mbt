// threadpool 测试（仅 native/llvm 编译，依赖真实 pthread/pipe）。
// 同步用 completion fd（tf_tp_wait_drain 内部是 poll，非 sleep 轮询），
// 每个等待循环都带明确的轮次上限，超限即断言失败而不是挂死。

///|
test "threadpool: 4 workers complete 1000 nop jobs" {
  let pool = @threadpool.tf_tp_create(4, 256)
  let total = 1000
  let mut submitted = 0
  let mut done = 0
  let mut rounds = 0
  while submitted < total {
    let r = @threadpool.tf_tp_submit_nop(pool, 0)
    if r == 0 {
      submitted += 1
    } else {
      // 队列满：等 worker 腾出容量再继续，不在调用方自旋
      assert_eq(r, -1)
      done += @threadpool.tf_tp_wait_drain(pool, 10)
      rounds += 1
      assert_eq(rounds < 2000, true)
    }
  }
  while done < total {
    done += @threadpool.tf_tp_wait_drain(pool, 50)
    rounds += 1
    assert_eq(rounds < 2000, true)
  }
  assert_eq(done, total)
  assert_eq(@threadpool.tf_tp_pending(pool), 0)
  assert_eq(@threadpool.tf_tp_drain(pool), 0)
  @threadpool.tf_tp_destroy(pool)
}

///|
test "threadpool: full queue rejects submit with -1" {
  // 1 worker + 容量 1：先用 1s 的 job 占住 worker，再打满队列。
  // 之后的 submit 至少有一个返回 -1（容量 1，worker 被 1s job 占住）。
  let pool = @threadpool.tf_tp_create(1, 1)
  assert_eq(@threadpool.tf_tp_submit_nop(pool, 1000000), 0)
  let mut accepted = 1
  let mut full_seen = false
  let mut i = 0
  while i < 16 && !full_seen {
    let r = @threadpool.tf_tp_submit_nop(pool, 200000)
    if r == -1 {
      full_seen = true
    } else {
      assert_eq(r, 0)
      accepted += 1
    }
    i += 1
  }
  assert_eq(full_seen, true)
  let mut done = 0
  let mut rounds = 0
  while done < accepted {
    done += @threadpool.tf_tp_wait_drain(pool, 50)
    rounds += 1
    assert_eq(rounds < 2000, true)
  }
  assert_eq(@threadpool.tf_tp_pending(pool), 0)
  @threadpool.tf_tp_destroy(pool)
}

///|
test "threadpool: shutdown rejects submit, destroy is idempotent" {
  let pool = @threadpool.tf_tp_create(2, 8)
  assert_eq(@threadpool.tf_tp_submit_nop(pool, 0), 0)
  @threadpool.tf_tp_shutdown(pool)
  assert_eq(@threadpool.tf_tp_submit_nop(pool, 0), -2)
  // shutdown 后已接受的 job 仍会被处理完（明确策略：排空队列）
  let mut done = 0
  let mut rounds = 0
  while done < 1 {
    done += @threadpool.tf_tp_wait_drain(pool, 50)
    rounds += 1
    assert_eq(rounds < 2000, true)
  }
  assert_eq(@threadpool.tf_tp_pending(pool), 0)
  @threadpool.tf_tp_destroy(pool)
  @threadpool.tf_tp_destroy(pool) // 重复 destroy 安全
  assert_eq(@threadpool.tf_tp_submit_nop(pool, 0), -2) // destroy 后 submit 安全
  assert_eq(@threadpool.tf_tp_drain(pool), 0)
  assert_eq(@threadpool.tf_tp_pending(pool), 0)
}

///|
test "threadpool: completion fd readable and drain accounting" {
  let pool = @threadpool.tf_tp_create(1, 4)
  assert_eq(@threadpool.tf_tp_completion_fd(pool) >= 0, true)
  for _ in 0..<3 {
    assert_eq(@threadpool.tf_tp_submit_nop(pool, 0), 0)
  }
  let mut done = 0
  let mut rounds = 0
  while done < 3 {
    done += @threadpool.tf_tp_wait_drain(pool, 50)
    rounds += 1
    assert_eq(rounds < 2000, true)
  }
  assert_eq(done, 3)
  assert_eq(@threadpool.tf_tp_drain(pool), 0) // 自上次 drain 后无新完成
  @threadpool.tf_tp_destroy(pool)
}
