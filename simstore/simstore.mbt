// SimStore 存根：模拟器 v2（三档存储层 + 延迟模型 + AWS 费率计费）。
// 契约见 NOTES2.md。当前为退化实现（零延迟/零计费，数据面与 MemStore 等价），
// 由工人 S 替换为真实模型；签名不得更改（bench 已依赖）。

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
  }
}

///|
/// 计量快照：延迟（虚拟时钟，微秒）+ 计费（美元）+ 命中统计。
pub(all) struct SimSnapshot {
  total_latency_us : Double
  op_count : Int
  bill_get : Double
  bill_put : Double
  bill_list : Double
  bill_delete : Double
  bill_requests_total : Double
  s3_gets : Int
  bytes_s3_read : Int
  bytes_nvme_read : Int
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
  mut nvme_used : Int
  mut next_ver : Int
  mut total_latency_us : Double
  mut op_count : Int
  mut gets : Int
  mut s3_gets : Int
  mut bytes_s3_read : Int
  mut bytes_nvme_read : Int
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
}

///|
pub fn SimStore::new(cfg : SimConfig) -> SimStore {
  {
    cfg,
    data: Map::new(),
    versions: Map::new(),
    ranges: Map::new(),
    nvme: Set::new(),
    nvme_used: 0,
    next_ver: 1,
    total_latency_us: 0.0,
    op_count: 0,
    gets: 0,
    s3_gets: 0,
    bytes_s3_read: 0,
    bytes_nvme_read: 0,
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
  }
}

///|
fn version_string(v : Int) -> String {
  "v\{v}"
}

///|
/// 存根数据面：与 MemStore 等价的直读直写，零延迟零计费。
pub impl @store.ObjectStore for SimStore with get(self : SimStore, key : String) -> Bytes? {
  self.op_count += 1
  self.data.get(key)
}

///|
fn SimStore::put_raw(self : SimStore, key : String, value : Bytes) -> Unit {
  self.puts += 1
  self.data.set(key, value)
  self.versions.set(key, self.next_ver)
  self.next_ver += 1
  self.ranges.remove(key)
}

///|
pub impl @store.ObjectStore for SimStore with put(self : SimStore, key : String, value : Bytes) -> Unit {
  self.op_count += 1
  self.put_raw(key, value)
}

///|
pub impl @store.ObjectStore for SimStore with put_if_match(
  self : SimStore,
  key : String,
  expected : String?,
  value : Bytes,
) -> Bool {
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
pub impl @store.ObjectStore for SimStore with get_range(
  self : SimStore,
  key : String,
  offset : Int,
  len : Int,
) -> Bytes? {
  self.op_count += 1
  match self.data.get(key) {
    Some(value) => {
      let lo = if offset < 0 { 0 } else { offset }
      let hi = if offset + len > value.length() {
        value.length()
      } else {
        offset + len
      }
      if hi <= lo {
        return Some(Bytes::make(0, b'\x00'))
      }
      let ranged_hit = match self.ranges.get(key) {
        Some(rs) => rs.iter().any(r => r.0 <= lo && r.1 >= hi)
        None => false
      }
      let hit = self.nvme.contains(key) || ranged_hit
      if !hit {
        match self.ranges.get(key) {
          Some(rs) => rs.push((lo, hi))
          None => self.ranges.set(key, [(lo, hi)])
        }
      }
      let b = Buffer()
      b.write_bytesview(value.view(start=lo, end=hi))
      Some(b.to_bytes())
    }
    None => None
  }
}

///|
pub impl @store.ObjectStore for SimStore with list(self : SimStore, prefix : String) -> Array[String] {
  self.op_count += 1
  self.lists += 1
  let out : Array[String] = Array::new()
  for kv in self.data.iter() {
    if kv.0.has_prefix(prefix) {
      out.push(kv.0)
    }
  }
  out.sort()
  out
}

///|
pub impl @store.ObjectStore for SimStore with delete(self : SimStore, key : String) -> Unit {
  self.op_count += 1
  self.deletes += 1
  self.data.remove(key)
  self.versions.remove(key)
  self.nvme.remove(key)
  self.ranges.remove(key)
}

///|
pub fn SimStore::cost(self : SimStore) -> SimSnapshot {
  {
    total_latency_us: self.total_latency_us,
    op_count: self.op_count,
    bill_get: self.bill_get,
    bill_put: self.bill_put,
    bill_list: self.bill_list,
    bill_delete: self.bill_delete,
    bill_requests_total: self.bill_get + self.bill_put + self.bill_list + self.bill_delete,
    s3_gets: self.s3_gets,
    bytes_s3_read: self.bytes_s3_read,
    bytes_nvme_read: self.bytes_nvme_read,
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
  self.op_count = 0
  self.gets = 0
  self.s3_gets = 0
  self.bytes_s3_read = 0
  self.bytes_nvme_read = 0
  self.nvme_hits = 0
  self.puts = 0
  self.lists = 0
  self.deletes = 0
  self.bill_get = 0.0
  self.bill_put = 0.0
  self.bill_list = 0.0
  self.bill_delete = 0.0
}

///|
/// 冷启动：清 NVMe 与已读区间记录（内存常驻档不动）。
pub fn SimStore::cold(self : SimStore) -> Unit {
  self.nvme.clear()
  self.nvme_used = 0
  self.ranges.clear()
}

///|
/// 全部数据进 NVMe（超出容量按 key 字典序优先保留小对象）。
pub fn SimStore::prime_nvme(self : SimStore) -> Unit {
  ignore(self)
}

///|
/// 当前总对象字节的月度存储费。
pub fn SimStore::storage_monthly_bill(self : SimStore) -> Double {
  self.total_object_bytes().to_double() / 1073741824.0 * self.cfg.rates.storage_per_gb_month
}

///|
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
