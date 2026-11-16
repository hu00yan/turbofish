// SimStore：三档存储层 + 延迟模型 + 多云请求计费。
//
// 三档判定（get / get_range，顺序严格）：
// 1. 内存常驻档（@store.classify_key(key) ∈ cfg.resident_classes；set_resident_enabled(false) 可关闭）：
//    延迟 += mem_us（固定值）；不打 S3 → 不计 GET 费、不消耗 rng。
// 2. NVMe 缓存档（cfg.nvme_capacity_bytes > 0 且 整对象在 nvme / 区间已登记 ranges）：
//    延迟 += nvme_read_p50_us 对数正态样本 + bytes/nvme 带宽；不计 GET 费。
// 3. S3 冷读：延迟 += s3_get_ttfb_p50_us 对数正态样本 + bytes/s3 带宽；计 1 次 GET 费；
//    get 整对象读回后准入 NVMe（LRU 逐出；单对象超容量不缓存，优先保留小对象）；
//    get_range 只登记命中区间（ranges 语义同 MemStore），不做整对象准入。
//
// 写路径：put/put_if_match 每次尝试计 PUT 延迟样本 + PUT 费（CAS 失败也是一次真实
// 请求）；成功写入 write-through 进 NVMe（受容量约束）。list/delete 各自样本 + 费用。
//
// 延迟单位统一微秒，累加进虚拟时钟（SimSnapshot.total_latency_us）；
// 不真睡、不建线程；查询延迟 = 顺序累加（保守上界）。
// rng 全模拟器共享单流，顺序稳定性原则见 latency.mbt 头注释。

///|
/// AWS S3 Standard（us-east-1，2026-02 公开价）费率表，单位：美元。
pub(all) struct BillRates {
  get_per_1k : Double // $0.0004
  put_per_1k : Double // $0.005
  list_per_1k : Double // $0.0025
  delete_per_1k : Double // $0.0
  storage_per_gb_month : Double // $0.023
  egress_per_gb : Double // $0.09（默认不启用）
}

///|
pub fn BillRates::aws_default() -> BillRates {
  {
    get_per_1k: 0.0004,
    put_per_1k: 0.005,
    list_per_1k: 0.0025,
    delete_per_1k: 0.0,
    storage_per_gb_month: 0.023,
    egress_per_gb: 0.09,
  }
}

///|
/// Cloudflare R2 费率：零出口流量费（Egress Free），Class A $4.50/M ($0.0045/1k)，Class B $0.36/M ($0.00036/1k)
pub fn BillRates::cloudflare_r2() -> BillRates {
  {
    get_per_1k: 0.00036,
    put_per_1k: 0.0045,
    list_per_1k: 0.0045,
    delete_per_1k: 0.0,
    storage_per_gb_month: 0.015,
    egress_per_gb: 0.0,
  }
}

///|
/// Google Cloud Storage Standard 费率
pub fn BillRates::gcp_standard() -> BillRates {
  {
    get_per_1k: 0.0004,
    put_per_1k: 0.005,
    list_per_1k: 0.005,
    delete_per_1k: 0.0,
    storage_per_gb_month: 0.020,
    egress_per_gb: 0.12,
  }
}

///|
/// Azure Blob Storage (Hot 档) 费率
pub fn BillRates::azure_hot() -> BillRates {
  {
    get_per_1k: 0.00052,
    put_per_1k: 0.0065,
    list_per_1k: 0.0065,
    delete_per_1k: 0.0,
    storage_per_gb_month: 0.018,
    egress_per_gb: 0.087,
  }
}

///|
/// 阿里云 OSS (标准存储) 费率
pub fn BillRates::aliyun_oss() -> BillRates {
  {
    get_per_1k: 0.00035,
    put_per_1k: 0.0045,
    list_per_1k: 0.0045,
    delete_per_1k: 0.0,
    storage_per_gb_month: 0.017,
    egress_per_gb: 0.07,
  }
}

///|
/// SimStore 配置：三档延迟参数 + 缓存容量 + 费率。全部可配置。
pub(all) struct SimConfig {
  seed : UInt
  // S3 冷读（对数正态：sample = p50 * exp(sigma * z)）
  s3_get_ttfb_p50_us : Double
  s3_ttfb_lognormal_sigma : Double
  s3_bandwidth_mbps : Double
  s3_put_ttfb_p50_us : Double
  s3_list_p50_us : Double
  s3_delete_p50_us : Double
  // NVMe 缓存层
  nvme_read_p50_us : Double
  nvme_bandwidth_mbps : Double
  nvme_capacity_bytes : Int // 0 = 不启用 NVMe（全部冷读）
  // 内存常驻档
  mem_us : Double
  resident_classes : Array[String]
  // 计费
  rates : BillRates
  egress_enabled : Bool
  // 并发取数建模：1 = 顺序累加（保守）；>1 = n 个 worker 的 makespan
  concurrency : Int
  // 额外延迟注入（默认 0）：WAN 抖动 / 随机 spike / 重试 backoff
  wan_jitter_p50_us : Double
  spike_probability : Double
  spike_p50_us : Double
  retry_probability : Double
  retry_p50_us : Double
  // 故障注入（默认 0；只作用于真正打到 S3 的请求，用于验证上层错误处理）。
  // get 返回 None、put 不改对象、list 返回空、delete 不删除；仍在快照里计 errors。
  get_error_probability : Double
  put_error_probability : Double
  list_error_probability : Double
  delete_error_probability : Double
  // 缓存远端延迟注入因子（默认 0.0）：当 > 0 时，NVMe/内存缓存命中也会注入按比例模拟的 S3 延迟
  cache_remote_delay_factor : Double
}

///|
pub fn SimConfig::aws_default(seed : UInt) -> SimConfig {
  {
    seed,
    s3_get_ttfb_p50_us: 30000.0,
    s3_ttfb_lognormal_sigma: 0.47,
    s3_bandwidth_mbps: 100.0,
    s3_put_ttfb_p50_us: 60000.0,
    s3_list_p50_us: 25000.0,
    s3_delete_p50_us: 30000.0,
    nvme_read_p50_us: 80.0,
    nvme_bandwidth_mbps: 3000.0,
    nvme_capacity_bytes: 536870912, // 512MB
    mem_us: 2.0,
    resident_classes: ["meta", "manifest", "segmeta", "centroids"],
    rates: BillRates::aws_default(),
    egress_enabled: false,
    concurrency: 1,
    wan_jitter_p50_us: 0.0,
    spike_probability: 0.0,
    spike_p50_us: 0.0,
    retry_probability: 0.0,
    retry_p50_us: 0.0,
    get_error_probability: 0.0,
    put_error_probability: 0.0,
    list_error_probability: 0.0,
    delete_error_probability: 0.0,
    cache_remote_delay_factor: 0.0,
  }
}

///|
pub fn SimConfig::cloudflare_r2(seed : UInt) -> SimConfig {
  let base = SimConfig::aws_default(seed)
  { ..base, rates: BillRates::cloudflare_r2() }
}

///|
pub fn SimConfig::gcp_standard(seed : UInt) -> SimConfig {
  let base = SimConfig::aws_default(seed)
  { ..base, rates: BillRates::gcp_standard() }
}

///|
pub fn SimConfig::azure_hot(seed : UInt) -> SimConfig {
  let base = SimConfig::aws_default(seed)
  { ..base, rates: BillRates::azure_hot() }
}

///|
pub fn SimConfig::aliyun_oss(seed : UInt) -> SimConfig {
  let base = SimConfig::aws_default(seed)
  { ..base, rates: BillRates::aliyun_oss() }
}

///|
/// 极端长尾与故障注入配置：专门注入 5% 的 1 秒级长尾毛刺与公网网络抖动，检验系统在恶劣云环境下的稳健性
pub fn SimConfig::extreme_tail(seed : UInt) -> SimConfig {
  let base = SimConfig::aws_default(seed)
  {
    ..base,
    wan_jitter_p50_us: 15000.0, // 15ms WAN 网络抖动
    spike_probability: 0.05, // 5% 概率遭遇极端慢请求
    spike_p50_us: 1000000.0, // 1.0 秒长尾延迟毛刺 (1,000,000 µs)
    retry_probability: 0.01, // 1% 传输超时与重试
    retry_p50_us: 500000.0, // 500ms 重试退避
  }
}

///|
/// 计量快照：延迟（虚拟时钟，微秒）+ 计费（美元）+ 命中统计。
pub(all) struct SimSnapshot {
  total_latency_us : Double
  concurrent_latency_us : Double
  max_latency_us : Double
  retries : Int
  errors : Int
  op_count : Int
  bill_get : Double
  bill_put : Double
  bill_list : Double
  bill_delete : Double
  bill_egress : Double
  bill_requests_total : Double
  bill_total : Double
  bill_class_a : Double
  bill_class_b : Double
  class_a_ops : Int
  class_b_ops : Int
  s3_gets : Int
  bytes_s3_read : Int64
  bytes_nvme_read : Int64
  bytes_logical_read : Int64
  nvme_hits : Int
  puts : Int
  lists : Int
  deletes : Int
  storage_bytes : Int
}

///|
pub struct SimStore {
  cfg : SimConfig
  data : Map[String, Bytes]
  versions : Map[String, Int]
  ranges : Map[String, Array[(Int, Int)]]
  nvme : Set[String] // NVMe 缓存命中的整对象
  last_used : Map[String, Int] // LRU recency：key -> 全局时钟 tick
  mut lru_clock : Int // 全局单调时钟：每次 NVMe 触碰 +1（tick 唯一，逐出无并列）
  mut nvme_used : Int
  mut resident_enabled : Bool // false 时 is_resident 恒 false：_meta/ 等常驻 key 也走 NVMe/S3
  rng : @core.Rng // 全模拟器共享的确定性随机流（种子 = cfg.seed）
  mut next_ver : Int
  mut total_latency_us : Double
  mut concurrent_latency_us : Double
  workers : Array[Double]
  mut retries : Int
  mut errors : Int
  mut op_count : Int
  mut gets : Int
  mut s3_gets : Int
  mut bytes_s3_read : Int64
  mut bytes_nvme_read : Int64
  mut bytes_logical_read : Int64
  mut nvme_hits : Int
  mut puts : Int
  mut lists : Int
  mut deletes : Int
  mut cas_ok : Int
  mut cas_fail : Int
  mut bill_get : Double
  mut bill_put : Double
  mut bill_list : Double
  mut bill_delete : Double
  mut bill_egress : Double
  mut max_latency_us : Double
}

///|
pub fn SimStore::new(cfg : SimConfig) -> SimStore {
  {
    cfg,
    data: Map([]),
    versions: Map([]),
    ranges: Map([]),
    nvme: Set([]),
    last_used: Map([]),
    lru_clock: 0,
    nvme_used: 0,
    resident_enabled: true,
    rng: @core.Rng::new(cfg.seed),
    next_ver: 1,
    total_latency_us: 0.0,
    concurrent_latency_us: 0.0,
    workers: Array(),
    retries: 0,
    errors: 0,
    op_count: 0,
    gets: 0,
    s3_gets: 0,
    bytes_s3_read: 0,
    bytes_nvme_read: 0,
    bytes_logical_read: 0,
    nvme_hits: 0,
    puts: 0,
    lists: 0,
    deletes: 0,
    cas_ok: 0,
    cas_fail: 0,
    bill_get: 0.0,
    bill_put: 0.0,
    bill_list: 0.0,
    bill_delete: 0.0,
    bill_egress: 0.0,
    max_latency_us: 0.0,
  }
}

///|
fn version_string(v : Int) -> String {
  "v\{v}"
}

///|
/// 该 class 是否在 resident_classes 配置中（不看 resident_enabled 开关）。
fn SimStore::in_resident_classes(self : SimStore, cls : String) -> Bool {
  for c in self.cfg.resident_classes {
    if c == cls {
      return true
    }
  }
  false
}

///|
/// key 是否属于内存常驻档。resident_enabled 为 false 时恒返回 false
/// （cold-process / cold-metadata benchmark 在同一 SimStore 上关闭常驻档，不动 SimConfig）。
fn SimStore::is_resident(self : SimStore, cls : String) -> Bool {
  if self.resident_enabled && self.in_resident_classes(cls) {
    true
  } else {
    false
  }
}

///|
/// 开关内存常驻档（默认 true）。关闭后 _meta/ 等常驻 key 与普通 key
/// 一样走 NVMe/S3 判定，便于在同一 SimStore 上测 cold-process / cold-metadata。
pub fn SimStore::set_resident_enabled(self : SimStore, v : Bool) -> Unit {
  self.resident_enabled = v
  // resident 类 key 不能占用 NVMe/LRU/ranges：否则切回 true 后名额虚高，
  // cold-metadata 档也会被 write-through 污染成 warm-metadata。
  self.evict_resident_classes()
}

///|
/// 当前 resident 开关状态（报告用）。
pub fn SimStore::is_resident_enabled(self : SimStore) -> Bool {
  self.resident_enabled
}

///|
/// 三档 get：内存常驻 → NVMe 命中 → S3 冷读（详见文件头注释）。
pub impl @store.ObjectStore for SimStore with fn get(
  self : SimStore,
  key : String,
) -> Bytes? {
  self.op_count += 1
  self.gets += 1
  if self.is_resident(@store.classify_key(key)) {
    // 第 1 档：内存常驻。固定 mem_us，不打 S3（无 GET 费），不消耗 rng。
    let extra = if self.cfg.cache_remote_delay_factor > 0.0 {
      self.sample_lognormal(self.cfg.s3_get_ttfb_p50_us * self.cfg.cache_remote_delay_factor)
    } else {
      0.0
    }
    self.record_latency(self.cfg.mem_us + extra)
    return match self.data.get(key) {
      Some(v) => {
        self.bytes_logical_read += v.length().to_int64()
        Some(v)
      }
      None => None
    }
  }
  match self.data.get(key) {
    Some(value) => {
      let size = value.length()
      if self.nvme.contains(key) {
        // 第 2 档：NVMe 命中（无 GET 费）。
        self.nvme_hits += 1
        self.bytes_nvme_read += size.to_int64()
        self.bytes_logical_read += size.to_int64()
        let extra = if self.cfg.cache_remote_delay_factor > 0.0 {
          self.sample_lognormal(self.cfg.s3_get_ttfb_p50_us * self.cfg.cache_remote_delay_factor)
        } else {
          0.0
        }
        let lat = self.sample_lognormal(self.cfg.nvme_read_p50_us) +
          bandwidth_us(size, self.cfg.nvme_bandwidth_mbps) +
          extra
        self.record_latency(lat)
        self.nvme_admit(key, size) // 刷新 LRU recency（已是成员，不改变容量）
        return Some(value)
      }
      // 第 3 档：S3 冷读：计 1 次 GET 费；整对象读回后准入 NVMe。
      self.s3_gets += 1
      self.bytes_s3_read += size.to_int64()
      self.bytes_logical_read += size.to_int64()
      self.charge_get(size)
      self.charge_egress(size)
      let fail = self.should_fail(self.cfg.get_error_probability)
      let lat = self.sample_lognormal(self.cfg.s3_get_ttfb_p50_us) +
        bandwidth_us(size, self.cfg.s3_bandwidth_mbps) +
        self.extra_s3_latency()
      self.record_latency(lat)
      if fail {
        self.errors += 1
        return None
      }
      if !self.in_resident_classes(@store.classify_key(key)) || self.resident_enabled {
        self.nvme_admit(key, size)
      }
      Some(value)
    }
    None => {
      // miss 同样是一次真实 S3 GET（404 也产生请求与延迟），0 字节，无缓存副作用。
      self.s3_gets += 1
      self.charge_get(0)
      let fail = self.should_fail(self.cfg.get_error_probability)
      self.record_latency(
        self.sample_lognormal(self.cfg.s3_get_ttfb_p50_us) +
        self.extra_s3_latency(),
      )
      if fail {
        self.errors += 1
      }
      None
    }
  }
}

///|
/// 成功写入的数据面：版本推进、旧区间记录失效、write-through 进 NVMe。
fn SimStore::put_raw(self : SimStore, key : String, value : Bytes) -> Unit {
  // 覆盖写：旧对象若在 NVMe，先按旧大小回收容量，再按新大小重新准入。
  match self.data.get(key) {
    Some(old) => if self.nvme.contains(key) { self.nvme_used -= old.length() }
    None => ()
  }
  self.nvme.remove(key)
  self.last_used.remove(key)
  self.data.set(key, value)
  self.versions.set(key, self.next_ver)
  self.next_ver += 1
  self.ranges.remove(key) // 新版本使旧区间记录失效
  // resident 关闭期间不要把 resident 类 key 重新塞进 NVMe，否则 cold-metadata
  // 会被写路径污染成 warm-metadata。
  if !self.in_resident_classes(@store.classify_key(key)) || self.resident_enabled {
    self.nvme_admit(key, value.length()) // write-through（受容量约束）
  }
}

///|
pub impl @store.ObjectStore for SimStore with fn put(
  self : SimStore,
  key : String,
  value : Bytes,
) -> Unit {
  self.op_count += 1
  self.puts += 1
  let fail = self.should_fail(self.cfg.put_error_probability)
  self.record_latency(
    self.sample_lognormal(self.cfg.s3_put_ttfb_p50_us) + self.extra_s3_latency(),
  )
  self.charge_put()
  if fail {
    self.errors += 1
    return
  }
  self.put_raw(key, value)
}

///|
pub impl @store.ObjectStore for SimStore with fn put_if_match(
  self : SimStore,
  key : String,
  expected : String?,
  value : Bytes,
) -> Bool {
  self.op_count += 1
  self.puts += 1
  // 真 S3 条件写：无论 CAS 成败都是一次 PUT 请求（延迟 + 费用）。
  let fail = self.should_fail(self.cfg.put_error_probability)
  self.record_latency(
    self.sample_lognormal(self.cfg.s3_put_ttfb_p50_us) + self.extra_s3_latency(),
  )
  self.charge_put()
  if fail {
    self.errors += 1
    return false
  }
  let current = match self.versions.get(key) {
    Some(v) => Some(version_string(v))
    None => None
  }
  let ok = match (expected, current) {
    (None, None) => true
    (Some(e), Some(c)) => e == c
    _ => false
  }
  if ok {
    self.put_raw(key, value)
    self.cas_ok += 1
  } else {
    self.cas_fail += 1
  }
  ok
}

///|
/// 范围读 [offset, offset+len)，返回可能截短的 payload（独立拷贝）。
pub impl @store.ObjectStore for SimStore with fn get_range(
  self : SimStore,
  key : String,
  offset : Int,
  len : Int,
) -> Bytes? {
  self.op_count += 1
  if self.is_resident(@store.classify_key(key)) {
    // 内存档范围读：对象整体在内存，区间拷贝，固定 mem_us，不打 S3。
    let extra = if self.cfg.cache_remote_delay_factor > 0.0 {
      self.sample_lognormal(self.cfg.s3_get_ttfb_p50_us * self.cfg.cache_remote_delay_factor)
    } else {
      0.0
    }
    self.record_latency(self.cfg.mem_us + extra)
    match self.data.get(key) {
      Some(value) => {
        let lo = if offset < 0 { 0 } else { offset }
        let hi = if offset + len > value.length() {
          value.length()
        } else {
          offset + len
        }
        self.bytes_logical_read += (if hi > lo { hi - lo } else { 0 }).to_int64()
        return Some(slice_bytes(value, offset, len))
      }
      None => return None
    }
  }
  match self.data.get(key) {
    Some(value) => {
      let lo = if offset < 0 { 0 } else { offset }
      let hi = if offset + len > value.length() {
        value.length()
      } else {
        offset + len
      }
      if hi <= lo {
        // 退化空区间：不产生请求。
        return Some(Bytes::make(0, b'\x00'))
      }
      let ranged_hit = match self.ranges.get(key) {
        Some(rs) => rs.iter().any(r => r.0 <= lo && r.1 >= hi)
        None => false
      }
      let nbytes = hi - lo
      if self.nvme.contains(key) || ranged_hit {
        // 第 2 档：整对象或命中区间已缓存（无 GET 费）。
        self.nvme_hits += 1
        self.bytes_nvme_read += nbytes.to_int64()
        self.bytes_logical_read += nbytes.to_int64()
        let extra = if self.cfg.cache_remote_delay_factor > 0.0 {
          self.sample_lognormal(self.cfg.s3_get_ttfb_p50_us * self.cfg.cache_remote_delay_factor)
        } else {
          0.0
        }
        let lat = self.sample_lognormal(self.cfg.nvme_read_p50_us) +
          bandwidth_us(nbytes, self.cfg.nvme_bandwidth_mbps) +
          extra
        self.record_latency(lat)
        // 只刷新 recency，不把范围读提升为整对象缓存。
        if self.nvme.contains(key) {
          self.nvme_admit(key, value.length())
        }
      } else {
        // 第 3 档：S3 冷区间读。bytes 口径 = 区间长度；
        // 只登记命中区间（同 MemStore 语义），不做整对象准入。
        self.s3_gets += 1
        self.bytes_s3_read += nbytes.to_int64()
        self.bytes_logical_read += nbytes.to_int64()
        self.charge_get(nbytes)
        self.charge_egress(nbytes)
        let fail = self.should_fail(self.cfg.get_error_probability)
        let lat = self.sample_lognormal(self.cfg.s3_get_ttfb_p50_us) +
          bandwidth_us(nbytes, self.cfg.s3_bandwidth_mbps) +
          self.extra_s3_latency()
        self.record_latency(lat)
        if fail {
          self.errors += 1
          return None
        }
        if self.cfg.nvme_capacity_bytes > 0 &&
          (!self.in_resident_classes(@store.classify_key(key)) || self.resident_enabled) {
          match self.ranges.get(key) {
            Some(rs) => rs.push((lo, hi))
            None => self.ranges.set(key, [(lo, hi)])
          }
        }
      }
      Some(slice_bytes(value, offset, len))
    }
    None => {
      // miss：一次真实 S3 range GET（404）。
      self.s3_gets += 1
      self.charge_get(0)
      let fail = self.should_fail(self.cfg.get_error_probability)
      self.record_latency(
        self.sample_lognormal(self.cfg.s3_get_ttfb_p50_us) +
        self.extra_s3_latency(),
      )
      if fail {
        self.errors += 1
      }
      None
    }
  }
}

///|
pub impl @store.ObjectStore for SimStore with fn list(
  self : SimStore,
  prefix : String,
) -> Array[String] {
  self.op_count += 1
  let fail = self.should_fail(self.cfg.list_error_probability)
  let out : Array[String] = Array()
  for kv in self.data.iter() {
    if kv.0.has_prefix(prefix) {
      out.push(kv.0)
    }
  }
  out.sort()
  if fail {
    self.lists += 1
    self.record_latency(
      self.sample_lognormal(self.cfg.s3_list_p50_us) + self.extra_s3_latency(),
    )
    self.charge_list()
    self.errors += 1
    return []
  }
  // ListObjectsV2 每页最多 1000 key；LIST 请求数 = 页数。
  let pages = if out.length() == 0 { 1 } else { (out.length() + 999) / 1000 }
  self.lists += pages
  for _ in 0..<pages {
    self.record_latency(
      self.sample_lognormal(self.cfg.s3_list_p50_us) + self.extra_s3_latency(),
    )
    self.charge_list()
  }
  out
}

///|
pub impl @store.ObjectStore for SimStore with fn delete(
  self : SimStore,
  key : String,
) -> Unit {
  self.op_count += 1
  self.deletes += 1
  // S3 DELETE：即使 key 不存在也是一次真实请求（延迟 + 费用，S3 Standard 费率默认 0）。
  let fail = self.should_fail(self.cfg.delete_error_probability)
  self.record_latency(
    self.sample_lognormal(self.cfg.s3_delete_p50_us) + self.extra_s3_latency(),
  )
  self.charge_delete()
  if fail {
    self.errors += 1
    return
  }
  match self.data.get(key) {
    Some(v) => if self.nvme.contains(key) { self.nvme_used -= v.length() }
    None => ()
  }
  self.data.remove(key)
  self.versions.remove(key)
  self.nvme.remove(key)
  self.last_used.remove(key)
  self.ranges.remove(key)
}

///|
pub impl @store.ObjectStore for SimStore with fn head_version(
  self : SimStore,
  key : String
) -> String? {
  self.head_version(key)
}

///|
/// NVMe 准入（LRU）：刷新 recency；新对象受容量约束，
/// 超容量逐出最久未用；单对象超过全容量则不缓存（优先保留小对象）。
fn SimStore::nvme_admit(self : SimStore, key : String, size : Int) -> Unit {
  if self.cfg.nvme_capacity_bytes <= 0 {
    return // NVMe 层未启用
  }
  if size > self.cfg.nvme_capacity_bytes {
    return // 单对象装不下：不缓存，避免为巨型对象清空全部小对象
  }
  self.lru_clock += 1
  self.last_used.set(key, self.lru_clock)
  if self.nvme.contains(key) {
    return // 已缓存：只刷新 recency
  }
  self.nvme.add(key)
  self.nvme_used += size
  while self.nvme_used > self.cfg.nvme_capacity_bytes {
    // 逐出最久未用（tick 全局单调唯一，无并列）。
    match self.nvme_lru_victim() {
      Some(victim) => {
        match self.data.get(victim) {
          Some(v) => self.nvme_used -= v.length()
          None => ()
        }
        self.nvme.remove(victim)
        self.last_used.remove(victim)
      }
      None => break // 缓存空了还超容量：理论不可达（size <= capacity 已挡），防御性退出
    }
  }
}

///|
/// 当前 NVMe 中最久未用的 key（last_used 最小）；空缓存返回 None。
fn SimStore::nvme_lru_victim(self : SimStore) -> String? {
  let mut victim = ""
  let mut best_tick = -1
  for k in self.nvme {
    match self.last_used.get(k) {
      Some(t) =>
        if best_tick < 0 || t < best_tick {
          victim = k
          best_tick = t
        }
      None => ()
    }
  }
  if best_tick < 0 {
    return None
  }
  Some(victim)
}

///|
/// 切片拷贝（模拟网络传出的独立缓冲区），钳位语义与 MemStore 一致。
fn slice_bytes(value : Bytes, offset : Int, len : Int) -> Bytes {
  let lo = if offset < 0 { 0 } else { offset }
  let hi = if offset + len > value.length() {
    value.length()
  } else {
    offset + len
  }
  if hi <= lo {
    return Bytes::make(0, b'\x00')
  }
  let b = Buffer()
  b.write_bytesview(value.exact_view(start=lo, end=hi))
  b.to_bytes()
}

///|
/// 记录一次请求的延迟：顺序总延迟 + 并发 makespan（concurrency 个 worker）。
pub fn SimStore::record_latency(self : SimStore, d : Double) -> Unit {
  self.total_latency_us += d
  if d > self.max_latency_us {
    self.max_latency_us = d
  }
  let c = if self.cfg.concurrency > 0 { self.cfg.concurrency } else { 1 }
  if c <= 1 {
    self.concurrent_latency_us += d
    return
  }
  while self.workers.length() < c {
    self.workers.push(0.0)
  }
  let mut idx = 0
  for i in 1..<c {
    if self.workers[i] < self.workers[idx] {
      idx = i
    }
  }
  let finish = self.workers[idx] + d
  self.workers[idx] = finish
  if finish > self.concurrent_latency_us {
    self.concurrent_latency_us = finish
  }
}

///|
pub fn SimStore::cost(self : SimStore) -> SimSnapshot {
  {
    total_latency_us: self.total_latency_us,
    concurrent_latency_us: self.concurrent_latency_us,
    max_latency_us: self.max_latency_us,
    retries: self.retries,
    errors: self.errors,
    op_count: self.op_count,
    bill_get: self.bill_get,
    bill_put: self.bill_put,
    bill_list: self.bill_list,
    bill_delete: self.bill_delete,
    bill_egress: self.bill_egress,
    bill_requests_total: self.bill_get +
    self.bill_put +
    self.bill_list +
    self.bill_delete,
    bill_total: self.bill_get +
    self.bill_put +
    self.bill_list +
    self.bill_delete +
    self.bill_egress,
    bill_class_a: self.bill_put + self.bill_list,
    bill_class_b: self.bill_get,
    class_a_ops: self.puts + self.lists,
    class_b_ops: self.s3_gets,
    s3_gets: self.s3_gets,
    bytes_s3_read: self.bytes_s3_read,
    bytes_nvme_read: self.bytes_nvme_read,
    bytes_logical_read: self.bytes_logical_read,
    nvme_hits: self.nvme_hits,
    puts: self.puts,
    lists: self.lists,
    deletes: self.deletes,
    storage_bytes: self.total_object_bytes(),
  }
}

///|
pub fn SimStore::reset_cost(self : SimStore) -> Unit {
  self.total_latency_us = 0.0
  self.concurrent_latency_us = 0.0
  self.max_latency_us = 0.0
  self.retries = 0
  self.errors = 0
  for i in 0..<self.workers.length() {
    self.workers[i] = 0.0
  }
  self.op_count = 0
  self.gets = 0
  self.s3_gets = 0
  self.bytes_s3_read = 0
  self.bytes_nvme_read = 0
  self.bytes_logical_read = 0
  self.nvme_hits = 0
  self.puts = 0
  self.lists = 0
  self.deletes = 0
  self.bill_get = 0.0
  self.bill_put = 0.0
  self.bill_list = 0.0
  self.bill_delete = 0.0
  self.bill_egress = 0.0
}

///|
/// 冷启动：清 NVMe 与已读区间记录（内存常驻档不动）。
/// 语义 = clear_nvme() + clear_ranges()。
pub fn SimStore::cold(self : SimStore) -> Unit {
  self.clear_nvme()
  self.clear_ranges()
}

///|
/// 只清 NVMe 缓存（含 LRU 记账）；ranges 记录保留。
pub fn SimStore::clear_nvme(self : SimStore) -> Unit {
  self.nvme.clear()
  self.nvme_used = 0
  self.last_used.clear()
}

///|
/// 只清已登记的命中区间（get_range 的区间缓存）；NVMe 整对象缓存保留。
pub fn SimStore::clear_ranges(self : SimStore) -> Unit {
  self.ranges.clear()
}

///|
/// 逐出某一类 key（classify_key）的 NVMe/ranges/LRU 痕迹；数据本体不动。
pub fn SimStore::evict_class(self : SimStore, cls : String) -> Unit {
  let keys : Array[String] = Array()
  for kv in self.data.iter() {
    if @store.classify_key(kv.0) == cls {
      keys.push(kv.0)
    }
  }
  for k in keys {
    self.evict_key(k)
  }
}

///|
/// 逐出所有 resident_classes 的缓存痕迹（不删数据、不动累计计数）。
pub fn SimStore::evict_resident_classes(self : SimStore) -> Unit {
  for cls in self.cfg.resident_classes {
    self.evict_class(cls)
  }
}

///|
/// 逐出单个 key 的缓存痕迹（NVMe 整对象 + 区间登记 + LRU 记账）；数据本体不动。
pub fn SimStore::evict_key(self : SimStore, key : String) -> Unit {
  if self.nvme.contains(key) {
    match self.data.get(key) {
      Some(v) => self.nvme_used -= v.length()
      None => ()
    }
    self.nvme.remove(key)
  }
  self.last_used.remove(key)
  self.ranges.remove(key)
}

///|
/// all-hot 合成上界：全部数据进 NVMe，按（体积升序, key 字典序）依次装入，
/// 小对象优先保留，装不下即止（升序排列，后续只会更大）。
/// 装入顺序即 LRU 顺序（先装入的更冷）。
/// 注意：这是 **all-hot 合成上界**，不是任何真实 workload 可达的 warm 状态；
/// 会先清 ranges（区间缓存），再按容量装入整对象。不消耗 rng、不产生延迟与费用。
pub fn SimStore::prime_nvme(self : SimStore) -> Unit {
  self.clear_ranges()
  self.nvme.clear()
  self.last_used.clear()
  self.nvme_used = 0
  if self.cfg.nvme_capacity_bytes <= 0 {
    return
  }
  let entries : Array[(Int, String)] = Array()
  for kv in self.data.iter() {
    entries.push((kv.1.length(), kv.0))
  }
  entries.sort_by(fn(a, b) {
    if a.0 == b.0 {
      a.1.compare(b.1)
    } else {
      a.0.compare(b.0)
    }
  })
  for e in entries {
    let size = e.0
    if self.nvme_used + size > self.cfg.nvme_capacity_bytes {
      return // 后续对象只会更大，不必继续尝试
    }
    self.lru_clock += 1
    self.last_used.set(e.1, self.lru_clock)
    self.nvme.add(e.1)
    self.nvme_used += size
  }
}

///|
/// prime_nvme() 的同义入口（all-hot 语义，见 prime_nvme 注释）。
pub fn SimStore::admit_all(self : SimStore) -> Unit {
  self.prime_nvme()
}

///|
/// admit_all / prime_nvme 状态的报告标签：提醒读者这是 all-hot 合成上界，
/// 而非 workload 可达的 warm 状态。
pub fn SimStore::admit_all_label() -> String {
  "all-hot (synthetic upper bound, not a workload-achievable warm state)"
}

///|
/// 缓存统计：(nvme_objects, nvme_bytes, s3_reads, logical_reads, nvme_hits,
/// nvme_bytes_read)。命中率口径：请求级近似 `nvme_hits/(nvme_hits+s3_gets)`
/// （含 404/range），字节级 `nvme_bytes_read/logical_reads`。
pub fn SimStore::cache_stats(self : SimStore) -> (Int, Int, Int, Int64, Int, Int64) {
  (
    self.nvme.length(),
    self.nvme_used,
    self.s3_gets,
    self.bytes_logical_read,
    self.nvme_hits,
    self.bytes_nvme_read,
  )
}

///|
/// 当前总对象字节的月度存储费：bytes / 2^30 × storage_per_gb_month。
pub fn SimStore::storage_monthly_bill(self : SimStore) -> Double {
  self.total_object_bytes().to_double() /
  1073741824.0 *
  self.cfg.rates.storage_per_gb_month
}

///|
/// 全部数据进 NVMe 的总字节数（存储量口径）。
pub fn SimStore::total_object_bytes(self : SimStore) -> Int {
  let mut total = 0
  for kv in self.data.iter() {
    total += kv.1.length()
  }
  total
}

///|
pub fn SimStore::head_version(self : SimStore, key : String) -> String? {
  match self.versions.get(key) {
    Some(v) => Some(version_string(v))
    None => None
  }
}

///|
/// Turbopuffer 扫描计费口径：$1/PB，单查询最低 1.28GB（即 $1.28/1M 查询起）。
/// 传入本次查询从 S3/NVMe 读出的逻辑字节数即可得到同口径费用。
pub fn tpu_scan_bill(bytes : Int64) -> Double {
  let min_billable = 1280000000.0 // 1.28 GB（decimal）
  let b = if bytes.to_double() < min_billable {
    min_billable
  } else {
    bytes.to_double()
  }
  b / 1000000000000000.0 // $1 / PB（10^15 字节，与 Turbopuffer 十进制口径一致）
}

///|
/// 本快照按 Turbopuffer 扫描口径的查询费用（逻辑扫描字节：resident/NVMe/S3
/// 都计入；Turbopuffer 缓存命中也按扫描字节计费）。
pub fn SimStore::tpu_query_bill(self : SimStore) -> Double {
  tpu_scan_bill(self.bytes_logical_read)
}

pub extend SimStore with @turbofish/store.ObjectStore::{put_if_match, put, list, get_range, get, delete, get_many, get_range_many}
