// circlease：熔断（CircuitBreaker）、令牌桶（TokenBucket）、全抖动退避（Backoff）。
//
// 这三件都是**纯感知型**设施：不做 I/O、不读时钟、不加锁。
// 时间由调用方以 now_ms 注入，随机源由调用方注入（本包自带确定性
// SplitMix64，零依赖、可直接用固定种子复现）。
//
// 当前仓库内**没有任何调用方**。本包只提供可独立测试的状态机，
// 接入线上路径（serve / compactd / 各 store）需要单独评审，不在本次范围内。

// ---------------------------------------------------------------------------
// Status：一次发送许可判定的结果
// ---------------------------------------------------------------------------

///|
/// 发送许可判定：放行 or 稍后重试。
#derive(Debug, Eq)
pub(all) enum Status {
  /// 放行，携带本次放行的请求数（>= 1）。
  Permits(Int32)
  /// 拒绝，建议在这么多毫秒后重试。
  RetryAfterMs(Int32)
}

///|
/// 是否放行。
pub fn Status::is_permitted(self : Status) -> Bool {
  match self {
    Permits(_) => true
    RetryAfterMs(_) => false
  }
}

///|
/// 放行数（拒绝时为 0）。
pub fn Status::permits(self : Status) -> Int32 {
  match self {
    Permits(n) => n
    RetryAfterMs(_) => 0
  }
}

///|
/// 建议重试等待（放行时为 0）。
pub fn Status::retry_after_ms(self : Status) -> Int32 {
  match self {
    Permits(_) => 0
    RetryAfterMs(ms) => ms
  }
}

// ---------------------------------------------------------------------------
// CircuitBreaker：closed → (连续失败达阈值) open → (open_ms 过期) half-open
// ---------------------------------------------------------------------------

///|
/// 熔断器相位。
#derive(Debug, Eq)
pub(all) enum BreakerPhase {
  /// 正常放行；连续失败计数中。
  Closed
  /// 熔断中：只回 RetryAfterMs。
  Open
  /// 半开试探：最多放行 `half_permits` 个请求。
  HalfOpen
}

///|
/// 熔断器状态机。字段全为感知量，无回调、无计时器。
///
/// 转移规则（唯一实现处是 `before_send` / `on_success` / `on_failure`）：
/// - closed：放行；`on_failure` 累加失败数，达 `failure_threshold` 立即 open。
/// - open：`before_send` 回 `RetryAfterMs(剩余等待)`；等待期满转 half-open 并放行 1 个。
/// - half-open：最多放行 `half_permits` 个探测；`on_success` 回 closed，
///   `on_failure` 立即回 open（重新计时）。
#derive(Debug, Eq)
pub(all) struct CircuitBreaker {
  /// 连续失败达此值即熔断（<1 时按 1 归一）。
  failure_threshold : Int32
  /// 熔断保持时长（ms，<0 时按 0 归一）。
  open_ms : Int32
  /// 半开期最多放行的探测请求数（<1 时按 1 归一）。
  half_permits : Int32
  mut phase : BreakerPhase
  mut failures : Int32
  mut opened_at_ms : Int32
  mut half_issued : Int32
}

///|
/// 构造一个 closed 相位的熔断器。
pub fn CircuitBreaker::new(
  failure_threshold : Int32,
  open_ms : Int32,
  half_permits : Int32,
) -> CircuitBreaker {
  {
    failure_threshold: if failure_threshold < 1 {
      1
    } else {
      failure_threshold
    },
    open_ms: if open_ms < 0 {
      0
    } else {
      open_ms
    },
    half_permits: if half_permits < 1 {
      1
    } else {
      half_permits
    },
    phase: Closed,
    failures: 0,
    opened_at_ms: 0,
    half_issued: 0,
  }
}

///|
/// 当前相位。
pub fn CircuitBreaker::phase(self : CircuitBreaker) -> BreakerPhase {
  self.phase
}

///|
/// 当前连续失败数（half-open / open 时保留熔断前的计数，便于观察）。
pub fn CircuitBreaker::failures(self : CircuitBreaker) -> Int32 {
  self.failures
}

///|
/// 发送前判定：是否放行、不放行要等多久。open → half-open 的相位迁移在此发生。
pub fn CircuitBreaker::before_send(
  self : CircuitBreaker,
  now_ms : Int32,
) -> Status {
  match self.phase {
    Closed => Permits(1)
    Open => {
      let elapsed = elapsed_since(now_ms, self.opened_at_ms)
      if elapsed < self.open_ms {
        RetryAfterMs(self.open_ms - elapsed)
      } else {
        // 熔断期结束：进入 half-open，本次即第一个探测许可。
        self.phase = HalfOpen
        self.half_issued = 1
        Permits(1)
      }
    }
    HalfOpen =>
      if self.half_issued < self.half_permits {
        self.half_issued = self.half_issued + 1
        Permits(1)
      } else {
        // 探测配额用完但尚无结论：继续观望一个熔断窗口。
        RetryAfterMs(self.open_ms)
      }
  }
}

///|
/// 一次成功：回 closed 并清零失败计数（兼容 half-open 探测成功）。
pub fn CircuitBreaker::on_success(self : CircuitBreaker) -> Unit {
  self.phase = Closed
  self.failures = 0
  self.half_issued = 0
}

///|
/// 一次失败：closed 下累计，达阈值熔断；half-open 下立即重新熔断。
pub fn CircuitBreaker::on_failure(
  self : CircuitBreaker,
  now_ms : Int32,
) -> Unit {
  let half_open = match self.phase {
    HalfOpen => true
    _ => false
  }
  self.failures = self.failures + 1
  if half_open || self.failures >= self.failure_threshold {
    self.phase = Open
    self.opened_at_ms = now_ms
    self.half_issued = 0
  }
}

// ---------------------------------------------------------------------------
// TokenBucket：容量上限 + 线性补充的令牌桶（每毫秒补充 refill_per_ms 个）
// ---------------------------------------------------------------------------

///|
/// 令牌桶。`tokens` 用 Double 承载部分令牌，容量与时间戳用整数。
#derive(Debug)
pub(all) struct TokenBucket {
  capacity : Int32
  mut tokens : Double
  refill_per_ms : Double
  mut last_ms : Int32
}

///|
/// 构造一个满桶。
pub fn TokenBucket::new(
  capacity : Int32,
  refill_per_ms : Double,
  now_ms : Int32,
) -> TokenBucket {
  let cap = if capacity < 0 { 0 } else { capacity }
  {
    capacity: cap,
    tokens: cap.to_double(),
    refill_per_ms: if refill_per_ms < 0.0 {
      0.0
    } else {
      refill_per_ms
    },
    last_ms: now_ms,
  }
}

///|
/// 按 `now_ms` 补充令牌（幂等；时间倒退时不补充也不回退 `last_ms`）。
pub fn TokenBucket::refill(self : TokenBucket, now_ms : Int32) -> Unit {
  if now_ms > self.last_ms {
    let gained = (now_ms - self.last_ms).to_double() * self.refill_per_ms
    let cap = self.capacity.to_double()
    let t = self.tokens + gained
    self.tokens = if t > cap { cap } else { t }
    self.last_ms = now_ms
  }
}

///|
/// 尝试取走 `n` 个令牌：够则扣减并返回 true，否则不动并返回 false。
pub fn TokenBucket::try_take(
  self : TokenBucket,
  now_ms : Int32,
  n : Int32,
) -> Bool {
  if n < 0 {
    return false
  }
  self.refill(now_ms)
  let need = n.to_double()
  if self.tokens >= need {
    self.tokens = self.tokens - need
    true
  } else {
    false
  }
}

// ---------------------------------------------------------------------------
// SplitMix64：本包自带的确定性随机源（零依赖，固定种子可复现）
// ---------------------------------------------------------------------------

///|
/// SplitMix64 伪随机数发生器。只用于退避抖动：不需要密码学强度，
/// 但需要固定种子可复现、跨平台一致（纯整数运算）。
#derive(Debug, Eq)
pub(all) struct SplitMix64 {
  mut state : UInt64
}

///|
/// 以 `seed` 初始化。同一个 seed 必须得到同一串数值。
pub fn SplitMix64::new(seed : UInt64) -> SplitMix64 {
  { state: seed, }
}

///|
/// 取下一个 64 位随机数（SplitMix64 标准常量混合）。
pub fn SplitMix64::next_uint64(self : SplitMix64) -> UInt64 {
  self.state = self.state + 0x9E3779B97F4A7C15UL
  let mut z = self.state
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL
  z ^ (z >> 31)
}

///|
/// 取 [0, 1) 的均匀 Double（取 64 位里的高 53 位，避免额外偏差）。
pub fn SplitMix64::next_unit_double(self : SplitMix64) -> Double {
  (self.next_uint64() >> 11).to_double() / 9007199254740992.0
}

// ---------------------------------------------------------------------------
// Backoff：指数退避 + full jitter
// ---------------------------------------------------------------------------

///|
/// 指数退避。第 `attempt` 次（0 起）的上界为
/// `min(max_ms, base_ms * mult^attempt)`，实际等待取 [0, 上界] 均匀分布
/// ——即 [Full Jitter](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/),
/// 用来把重试压平而不是聚成尖峰。
#derive(Debug)
pub(all) struct Backoff {
  base_ms : Int32
  max_ms : Int32
  mult : Double
  mut attempt : Int32
}

///|
/// 构造 attempt=0 的退避器。`mult` < 1 时按 1 归一（退避不应收缩）。
pub fn Backoff::new(base_ms : Int32, max_ms : Int32, mult : Double) -> Backoff {
  {
    base_ms: if base_ms < 0 {
      0
    } else {
      base_ms
    },
    max_ms: if max_ms < 0 {
      0
    } else {
      max_ms
    },
    mult: if mult < 1.0 {
      1.0
    } else {
      mult
    },
    attempt: 0,
  }
}

///|
/// 当前 attempt 的等待上界（不含抖动）。
pub fn Backoff::capped_ms(self : Backoff) -> Int32 {
  let max = self.max_ms.to_double()
  let mut v = self.base_ms.to_double()
  let mut i = 0
  while i < self.attempt {
    if v >= max {
      break
    }
    v = v * self.mult
    i = i + 1
  }
  if v > max {
    v = max
  }
  v.to_int()
}

///|
/// 取下一次等待毫秒数（full jitter: 均匀落在 [0, capped_ms]），并自增 attempt。
pub fn Backoff::next_delay_ms(self : Backoff, rng : SplitMix64) -> Int32 {
  let cap = self.capped_ms()
  let u = rng.next_unit_double()
  // full jitter：上界为整数 cap，取 [0, cap] 上的整数均匀分布。
  let mut d = (u * (cap.to_double() + 1.0)).to_int()
  if d > cap {
    d = cap
  }
  if d < 0 {
    d = 0
  }
  self.attempt = self.attempt + 1
  d
}

///|
/// 复位到 attempt=0（成功一次后调用）。
pub fn Backoff::reset(self : Backoff) -> Unit {
  self.attempt = 0
}

///|
/// 供区间计算用的时间差（时间倒退时钳为 0）。
fn elapsed_since(now_ms : Int32, then_ms : Int32) -> Int32 {
  if now_ms > then_ms {
    now_ms - then_ms
  } else {
    0
  }
}
