// circlease 单元测试：熔断状态机 / 令牌桶 / 指数退避。

///|
test "circlease: breaker closed → open → half-open → closed" {
  let cb = CircuitBreaker::new(3, 1000, 1)
  // closed：一律放行，失败未达阈值不熔断。
  assert_eq(cb.phase(), Closed)
  assert_true(cb.before_send(0).is_permitted())
  cb.on_failure(10)
  assert_eq(cb.phase(), Closed)
  assert_eq(cb.failures(), 1)
  // 成功一次清零失败连击。
  cb.on_success()
  assert_eq(cb.failures(), 0)
  // 连续 3 次失败（中间无成功）→ open。
  cb.on_failure(100)
  cb.on_failure(200)
  cb.on_failure(300)
  assert_eq(cb.phase(), Open)
  // open 期：不放行，且给出剩余等待。
  assert_eq(cb.before_send(300), RetryAfterMs(1000))
  assert_eq(cb.before_send(800), RetryAfterMs(500))
  assert_eq(cb.before_send(1200), RetryAfterMs(100))
  // 过期 → half-open，本次放行 1 个探测。
  assert_eq(cb.before_send(1300), Permits(1))
  assert_eq(cb.phase(), HalfOpen)
  // 探测配额（half_permits=1）已用完：继续观望。
  assert_eq(cb.before_send(1300), RetryAfterMs(1000))
  // 探测成功 → 回 closed。
  cb.on_success()
  assert_eq(cb.phase(), Closed)
  assert_eq(cb.failures(), 0)
  assert_eq(cb.before_send(1300), Permits(1))
}

///|
test "circlease: half-open failure reopens immediately" {
  let cb = CircuitBreaker::new(2, 50, 2)
  cb.on_failure(0)
  cb.on_failure(1)
  assert_eq(cb.phase(), Open)
  // 过期进 half-open，half_permits=2 → 连续放行 2 个。
  assert_eq(cb.before_send(100), Permits(1))
  assert_eq(cb.before_send(100), Permits(1))
  assert_eq(cb.before_send(100), RetryAfterMs(50))
  // 半开期任一失败立即重新熔断并重新计时（阈值 2 已无关）。
  cb.on_failure(120)
  assert_eq(cb.phase(), Open)
  assert_eq(cb.before_send(120), RetryAfterMs(50))
  assert_eq(cb.before_send(170), Permits(1))
  // 时间倒退不产生负等待、也不提前放行。
  let cb2 = CircuitBreaker::new(1, 100, 1)
  cb2.on_failure(1000)
  assert_eq(cb2.before_send(900), RetryAfterMs(100))
}

///|
test "circlease: token bucket refill and take" {
  let tb = TokenBucket::new(10, 0.01, 0)
  // 满桶：一次取 10 成功，再取 1 失败。
  assert_true(tb.try_take(0, 10))
  assert_false(tb.try_take(0, 1))
  // 1000 ms 补 10 个令牌 → 取 10 成功。
  assert_true(tb.try_take(1000, 10))
  assert_false(tb.try_take(1000, 10))
  // 部分补充：500 ms 补 5 个，取 5 成功、取 1 失败。
  assert_true(tb.try_take(1500, 5))
  assert_false(tb.try_take(1500, 1))
  // 补到容量上限为止，不会溢出。
  assert_true(tb.try_take(100000, 10))
  assert_false(tb.try_take(100000, 1))
  // 时间倒退不补充令牌、不倒退 last_ms。
  let tb2 = TokenBucket::new(5, 1.0, 1000)
  assert_true(tb2.try_take(1000, 5))
  assert_false(tb2.try_take(500, 1))
  assert_true(tb2.try_take(1001, 1))
  // 负数请求直接拒绝。
  assert_false(tb2.try_take(2000, -1))
  // 容量 0 的桶永远取不到。
  let tb0 = TokenBucket::new(0, 1.0, 0)
  assert_false(tb0.try_take(1000, 1))
}

///|
test "circlease: backoff full jitter with fixed seed" {
  // 固定种子的金标序列：全抖动必须可复现（跨平台一致，只有整数运算 + IEEE 除法）。
  let seed = 0x0123456789ABCDEFUL
  let b = Backoff::new(100, 2000, 2.0)
  let rng = SplitMix64::new(seed)
  let seq = []
  for _ in 0..<10 {
    seq.push(b.next_delay_ms(rng))
  }
  assert_eq(seq, [8, 167, 74, 509, 7, 162, 1445, 1072, 1950, 300])
  assert_eq(b.attempt, 10)
  // 同种子必须逐位相同。
  let b2 = Backoff::new(100, 2000, 2.0)
  let rng2 = SplitMix64::new(seed)
  let seq2 = []
  for _ in 0..<10 {
    seq2.push(b2.next_delay_ms(rng2))
  }
  assert_eq(seq2, seq)
  // 复位后可重现。
  b.reset()
  assert_eq(b.attempt, 0)
  let rng3 = SplitMix64::new(seed)
  assert_eq(b.next_delay_ms(rng3), 8)
  // 上界：第 i 次不超 min(max_ms, base*mult^i)。
  let b3 = Backoff::new(100, 2000, 2.0)
  let rng4 = SplitMix64::new(7UL)
  for i in 0..<12 {
    let cap = b3.capped_ms()
    let expect_cap = if 100 * (1 << i) > 2000 { 2000 } else { 100 * (1 << i) }
    assert_eq(cap, expect_cap)
    let d = b3.next_delay_ms(rng4)
    assert_true(d >= 0 && d <= cap)
  }
}

///|
test "circlease: backoff jitter is full (reaches low values)" {
  // full jitter 的标志：上界为 base 时，多次抽样会出现远低于 base 的值。
  // 固定种子即可复现，不依赖 wall clock。
  let b = Backoff::new(1000, 1000, 2.0)
  let rng = SplitMix64::new(42UL)
  let mut low = 1001
  let mut high = -1
  for _ in 0..<256 {
    let d = b.next_delay_ms(rng)
    if d < low {
      low = d
    }
    if d > high {
      high = d
    }
  }
  assert_true(low < 100)
  assert_true(high > 900)
  // mult < 1 被归一为 1（退避不收缩）。
  let flat = Backoff::new(10, 10, 0.5)
  assert_eq(flat.capped_ms(), 10)
  assert_eq(flat.attempt, 0)
}
