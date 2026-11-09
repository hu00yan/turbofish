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
/// Irwin-Hall 两点近似正态：z = (u1 + u2 - 1.0) * 2.449
/// （均值 0、方差 1，支撑 [-2.449, 2.449]，无长尾）。
/// sample = p50 * exp(sigma * z)。拆成纯函数便于白盒测试直接驱动分布检查。
fn lognormal_from_uniforms(
  p50 : Double,
  sigma : Double,
  u1 : Double,
  u2 : Double,
) -> Double {
  let z = (u1 + u2 - 1.0) * 2.449
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
/// 带宽传输时间（微秒）：bytes / (mbps * 1e6 B/s) 秒 × 1e6 µs/s = bytes / mbps。
fn bandwidth_us(bytes : Int, mbps : Double) -> Double {
  bytes.to_double() / mbps
}

///|
/// 固定种子采 n 个对数正态样本（白盒测试用，独立 rng 不影响 SimStore 的流）。
fn sample_lognormal_seq(
  seed : UInt,
  n : Int,
  p50 : Double,
  sigma : Double,
) -> Array[Double] {
  let rng = @core.Rng::new(seed)
  let out : Array[Double] = Array::new()
  for _ in 0..<n {
    out.push(lognormal_from_uniforms(p50, sigma, rng.next_f64(), rng.next_f64()))
  }
  out
}
