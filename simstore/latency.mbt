// 延迟采样：对数正态（确定性，种子在 SimConfig.seed）。
//
// ===== RNG 顺序稳定性原则（全模拟器约定）=====
// - 整个 SimStore 共享**单个** @core.Rng 流（种子 = SimConfig.seed）。
// - 每个操作在开始处理时一次性抽取它需要的 uniform，抽取顺序固定：
//   1) 内存常驻档读（get/get_range 命中 resident_classes）：0 个
//      （延迟 = mem_us 固定值，不采样）；
//   2) 其余一切操作（NVMe 命中 / S3 冷读 / PUT / LIST / DELETE）：恰好 2 个，
//      先 u1 后 u2，构成一个对数正态样本；带宽时间用解析式计算，不消耗 uniform。
// - 除操作自身的采样外没有其他消费者（cold()/prime_nvme()/cost() 不抽随机数）。
// - 因此 rng 序列是「操作序列 + 缓存状态」的确定性函数：
//   同种子 + 同初始状态 + 同操作序列 ⇒ 完全一致的延迟与计费（可复现）。
// - 原则：**先判定档位/结果，再抽这一操作的样本**，一个操作的所有 uniform
//   连续抽取，中间不穿插其他操作的采样。
//
// 形状参数统一用 cfg.s3_ttfb_lognormal_sigma（配置只暴露这一个 sigma，
// GET/PUT/LIST/DELETE/NVMe 全部共用；p50 各用各的）。

///|
/// Box-Muller 变换正态采样：
/// z = sqrt(-2.0 * ln(u1)) * cos(2 * pi * u2)
/// 生成严格标准正态分布 N(0, 1)，包含真实的指数衰减长尾（无 Irwin-Hall [-2.449, 2.449] 截断）。
/// sample = p50 * exp(sigma * z)。消耗恰好 2 个 uniform（先 u1 后 u2），保持 RNG 序列严格确定性。
fn lognormal_from_uniforms(
  p50 : Double,
  sigma : Double,
  u1 : Double,
  u2 : Double,
) -> Double {
  let pi2 = 6.283185307179586
  let u1_clamped = if u1 <= 1.0e-12 {
    1.0e-12
  } else if u1 >= 1.0 {
    1.0 - 1.0e-12
  } else {
    u1
  }
  let z = (-2.0 * @math.ln(u1_clamped)).sqrt() * @math.cos(pi2 * u2)
  p50 * @math.exp(sigma * z)
}

///|
/// SimStore 共享 rng 的采样入口：消耗 2 个 uniform（先 u1 后 u2）。
fn SimStore::sample_lognormal(self : SimStore, p50 : Double) -> Double {
  let u1 = self.rng.next_f64()
  let u2 = self.rng.next_f64()
  lognormal_from_uniforms(p50, self.cfg.s3_ttfb_lognormal_sigma, u1, u2)
}

///|
/// 指定 sigma 的采样（用于 WAN jitter / spike / retry 等额外延迟）。
fn SimStore::sample_lognormal_sigma(
  self : SimStore,
  p50 : Double,
  sigma : Double,
) -> Double {
  let u1 = self.rng.next_f64()
  let u2 = self.rng.next_f64()
  lognormal_from_uniforms(p50, sigma, u1, u2)
}

///|
/// 故障注入：按概率决定本次请求是否失败。概率为 0 时不消耗 rng。
fn SimStore::should_fail(self : SimStore, p : Double) -> Bool {
  if p <= 0.0 {
    return false
  }
  self.rng.next_f64() < p
}

///|
/// S3 请求的额外延迟：WAN jitter + 随机 spike + 重试/backoff。
/// 默认全部为 0，不改变既有确定性；开启后按固定 rng 顺序采样。
fn SimStore::extra_s3_latency(self : SimStore) -> Double {
  let mut d = 0.0
  if self.cfg.wan_jitter_p50_us > 0.0 {
    d += self.sample_lognormal_sigma(
      self.cfg.wan_jitter_p50_us,
      self.cfg.s3_ttfb_lognormal_sigma,
    )
  }
  if self.cfg.spike_probability > 0.0 &&
    self.rng.next_f64() < self.cfg.spike_probability {
    d += self.sample_lognormal_sigma(self.cfg.spike_p50_us, 0.7)
  }
  if self.cfg.retry_probability > 0.0 &&
    self.rng.next_f64() < self.cfg.retry_probability {
    self.retries += 1
    d += self.sample_lognormal_sigma(self.cfg.retry_p50_us, 0.47)
  }
  d
}

///|
/// 带宽传输时间（微秒）：bytes / (mbps * 1e6 B/s) 秒 × 1e6 µs/s = bytes / mbps。
fn bandwidth_us(bytes : Int, mbps : Double) -> Double {
  bytes.to_double() / mbps
}

///|
/// 性能前提：延迟参数全部为正、并发度 >= 1。零延迟配置只用于正确性测试。
pub fn SimConfig::latency_ready(self : SimConfig) -> Bool {
  self.s3_get_ttfb_p50_us > 0.0 &&
  self.s3_put_ttfb_p50_us > 0.0 &&
  self.s3_list_p50_us > 0.0 &&
  self.s3_delete_p50_us > 0.0 &&
  self.s3_bandwidth_mbps > 0.0 &&
  self.nvme_read_p50_us > 0.0 &&
  self.nvme_bandwidth_mbps > 0.0 &&
  self.concurrency >= 1
}

///|
/// 性能 benchmark 硬门：延迟前提不满足时 raise Corrupt。
/// 正确性测试仍可零延迟运行（不调用本函数即可）。
pub fn SimStore::require_latency(self : SimStore) -> Unit raise @core.SpndError {
  let c = self.cfg
  if c.latency_ready() {
    return
  }
  let bad : Array[String] = Array()
  if !(c.s3_get_ttfb_p50_us > 0.0) {
    bad.push("s3_get_ttfb_p50_us")
  }
  if !(c.s3_put_ttfb_p50_us > 0.0) {
    bad.push("s3_put_ttfb_p50_us")
  }
  if !(c.s3_list_p50_us > 0.0) {
    bad.push("s3_list_p50_us")
  }
  if !(c.s3_delete_p50_us > 0.0) {
    bad.push("s3_delete_p50_us")
  }
  if !(c.s3_bandwidth_mbps > 0.0) {
    bad.push("s3_bandwidth_mbps")
  }
  if !(c.nvme_read_p50_us > 0.0) {
    bad.push("nvme_read_p50_us")
  }
  if !(c.nvme_bandwidth_mbps > 0.0) {
    bad.push("nvme_bandwidth_mbps")
  }
  if !(c.concurrency >= 1) {
    bad.push("concurrency")
  }
  let mut msg = "SimStore latency disabled: "
  for i in 0..<bad.length() {
    if i > 0 {
      msg = msg + ", "
    }
    msg = msg + bad[i]
  }
  raise @core.Corrupt(msg)
}

///|
/// 固定种子采 n 个对数正态样本（白盒测试用，独立 rng 不影响 SimStore 的流）。
pub fn sample_lognormal_seq(
  seed : UInt,
  n : Int,
  p50 : Double,
  sigma : Double,
) -> Array[Double] {
  let rng = @core.Rng::new(seed)
  let out : Array[Double] = Array()
  for _ in 0..<n {
    out.push(
      lognormal_from_uniforms(p50, sigma, rng.next_f64(), rng.next_f64()),
    )
  }
  out
}
