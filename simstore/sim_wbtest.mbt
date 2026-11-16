///|

// SimStore 白盒测试：
// 计费数学精确、延迟确定性、采样分布、三档行为、LRU 逐出、get_range、CAS、存储费。

///|
fn abs_f64(x : Double) -> Double {
  if x < 0.0 {
    -x
  } else {
    x
  }
}

///|
/// 混合操作序列（延迟确定性测试的驱动器）。
async fn drive_mixed_ops(s : SimStore) -> Unit {
  s.put("ns/_meta/namespace.json", b"m")
  s.put("ns/_segments/seg0/rows/id.bin", Bytes::make(4096, b'\x05'))
  s.put("ns/_segments/seg0/fts/postings.bin", Bytes::make(70000, b'\x06'))
  s.cold()
  let _ = s.get("ns/_segments/seg0/rows/id.bin")
  let _ = s.get_range("ns/_segments/seg0/fts/postings.bin", @store.ByteRange::{ off: 16, len: 1000 })
  let _ = s.get("ns/_meta/namespace.json")
  let _ = s.list("ns/_segments/")
  s.delete("ns/_segments/seg0/rows/id.bin")
}

///|
async test "billing exact: 1000 S3 GETs = $0.0004" {
  let s = SimStore::new(SimConfig::aws_default(1U))
  for i in 0..<1000 {
    s.put("ns/_segments/seg\{i}/rows/id.bin", Bytes::make(10, b'\x01'))
  }
  // write-through 已把对象放进 NVMe：cold 归零后才是真正的 S3 冷读
  s.cold()
  s.reset_cost()
  for i in 0..<1000 {
    let _ = s.get("ns/_segments/seg\{i}/rows/id.bin")
  }
  let c = s.cost()
  assert_eq(c.s3_gets, 1000)
  assert_eq(c.bytes_s3_read, 10000)
  assert_eq(abs_f64(c.bill_get - 0.0004) < 1.0e-12, true)
  // bill_requests_total = 四项之和（这里只有 GET）
  assert_eq(abs_f64(c.bill_requests_total - 0.0004) < 1.0e-12, true)
}

///|
async test "billing exact: 1000 PUTs = $0.005; CAS failure also billed" {
  let s = SimStore::new(SimConfig::aws_default(2U))
  s.reset_cost()
  for i in 0..<1000 {
    s.put("ns/_segments/seg\{i}/rows/id.bin", Bytes::make(8, b'\x02'))
  }
  let c = s.cost()
  assert_eq(c.puts, 1000)
  assert_eq(abs_f64(c.bill_put - 0.005) < 1.0e-12, true)
  // CAS 失败也计一次 PUT 费（真 S3 条件写失败也是一次请求）
  s.reset_cost()
  assert_eq(
    s.put_if_match("ns/_segments/seg0/rows/id.bin", @store.Expected(Some("v999")), b"x"),
    false,
  )
  let c2 = s.cost()
  assert_eq(c2.puts, 1)
  assert_eq(abs_f64(c2.bill_put - 0.005 / 1000.0) < 1.0e-12, true)
}

///|
async test "billing exact: 1000 LISTs = $0.0025; DELETE default rate zero" {
  let s = SimStore::new(SimConfig::aws_default(3U))
  s.put("ns/_segments/seg0/rows/id.bin", Bytes::make(8, b'\x03'))
  s.reset_cost()
  for _ in 0..<1000 {
    let _ = s.list("ns/_segments/")
  }
  let c = s.cost()
  assert_eq(c.lists, 1000)
  assert_eq(abs_f64(c.bill_list - 0.0025) < 1.0e-12, true)
  // DELETE：S3 Standard 默认 0，但仍是真实请求（延迟样本被消耗、计数递增）
  s.reset_cost()
  s.delete("ns/_segments/seg0/rows/id.bin")
  s.delete("ns/_segments/seg0/rows/id.bin") // 不存在也计请求
  let c2 = s.cost()
  assert_eq(c2.deletes, 2)
  assert_eq(c2.bill_delete, 0.0)
  assert_eq(abs_f64(c2.bill_requests_total - 0.0) < 1.0e-12, true)
  assert_eq(s.get("ns/_segments/seg0/rows/id.bin"), None)
}

///|
async test "resident & NVMe hits incur no GET bill" {
  let s = SimStore::new(SimConfig::aws_default(4U))
  s.put("ns/_meta/namespace.json", b"meta") // meta → 内存常驻档
  s.put("ns/_segments/seg0/rows/id.bin", Bytes::make(100, b'\x04')) // rows → write-through 进 NVMe
  s.reset_cost()
  let _ = s.get("ns/_meta/namespace.json") // 内存档
  let _ = s.get("ns/_segments/seg0/rows/id.bin") // NVMe 命中
  let c = s.cost()
  assert_eq(c.s3_gets, 0)
  assert_eq(c.bill_get, 0.0)
  assert_eq(c.bill_requests_total, 0.0)
  assert_eq(c.nvme_hits, 1)
  assert_eq(c.bytes_s3_read, 0)
  assert_eq(c.bytes_nvme_read, 100)
}

///|
async test "latency determinism: same seed identical, different seed differs" {
  let s1 = SimStore::new(SimConfig::aws_default(42U))
  let s2 = SimStore::new(SimConfig::aws_default(42U))
  drive_mixed_ops(s1)
  drive_mixed_ops(s2)
  assert_eq(s1.cost().total_latency_us, s2.cost().total_latency_us)
  assert_eq(s1.cost().bill_requests_total, s2.cost().bill_requests_total)
  assert_eq(s1.cost().s3_gets, s2.cost().s3_gets)
  let s3 = SimStore::new(SimConfig::aws_default(43U))
  drive_mixed_ops(s3)
  assert_eq(s3.cost().total_latency_us == s1.cost().total_latency_us, false)
}

///|
async test "lognormal sampling: p50 within 20% of config, p99/p50 ratio in [2, 4.5]" {
  // sigma = 0.47 ⇒ 理论 p99/p50 = exp(0.47 * z99)，Irwin-Hall z99 ≈ 2.10 ⇒ ≈ 2.7
  let samples = sample_lognormal_seq(2024U, 10000, 30000.0, 0.47)
  let sorted = samples.copy()
  sorted.sort()
  let p50 = sorted[5000]
  let p99 = sorted[9900]
  assert_eq(p50 > 30000.0 * 0.8 && p50 < 30000.0 * 1.2, true)
  let ratio = p99 / p50
  assert_eq(ratio > 2.0 && ratio < 4.5, true)
}

///|
async test "three-tier: resident mem_us exact, cold read, NVMe warm, cold(), prime_nvme()" {
  let s = SimStore::new(SimConfig::aws_default(5U))
  s.put("ns/_meta/namespace.json", b"meta")
  s.put("ns/_segments/seg0/rows/id.bin", Bytes::make(1000, b'\x07'))
  // —— 第 1 档：内存常驻，延迟恰好 mem_us，无 S3 请求 ——
  s.reset_cost()
  let _ = s.get("ns/_meta/namespace.json")
  let c0 = s.cost()
  assert_eq(c0.total_latency_us, 2.0) // mem_us
  assert_eq(c0.s3_gets, 0)
  assert_eq(c0.bill_get, 0.0)
  assert_eq(c0.nvme_hits, 0)
  // resident miss 也不打 S3（常驻档数据要么在内存要么不存在）
  s.reset_cost()
  assert_eq(s.get("ns/_meta/nope.json"), None)
  let c0m = s.cost()
  assert_eq(c0m.total_latency_us, 2.0)
  assert_eq(c0m.s3_gets, 0)
  // resident get_range 同样只花 mem_us
  s.reset_cost()
  let _ = s.get_range("ns/_meta/namespace.json", @store.ByteRange::{ off: 0, len: 2 })
  assert_eq(s.cost().total_latency_us, 2.0)
  assert_eq(s.cost().s3_gets, 0)
  // —— 第 3 档：S3 冷读 ——
  s.cold()
  s.reset_cost()
  let _ = s.get("ns/_segments/seg0/rows/id.bin")
  let c1 = s.cost()
  assert_eq(c1.s3_gets, 1)
  assert_eq(c1.bytes_s3_read, 1000)
  assert_eq(abs_f64(c1.bill_get - 0.0004 / 1000.0) < 1.0e-15, true)
  assert_eq(c1.nvme_hits, 0)
  // TTFB 对数正态样本可能低于 p50，但必在 S3 量级（几十 ms），远大于 NVMe 的 ~80µs
  assert_eq(
    c1.total_latency_us > 5000.0 && c1.total_latency_us < 200000.0,
    true,
  )
  // —— 第 2 档：第二次读 NVMe 命中，无 GET 费 ——
  let _ = s.get("ns/_segments/seg0/rows/id.bin")
  let c2 = s.cost()
  assert_eq(c2.s3_gets, 1) // 不再增长
  assert_eq(c2.nvme_hits, 1)
  assert_eq(c2.bytes_nvme_read, 1000)
  assert_eq(c2.bill_get, c1.bill_get) // 费用未再增加
  // —— cold() 后又冷读 ——
  s.cold()
  s.reset_cost()
  let _ = s.get("ns/_segments/seg0/rows/id.bin")
  let c3 = s.cost()
  assert_eq(c3.s3_gets, 1)
  assert_eq(c3.nvme_hits, 0)
  // —— prime_nvme() 后全部命中（resident 走内存档，其余走 NVMe）——
  s.cold()
  s.prime_nvme()
  s.reset_cost()
  let _ = s.get("ns/_meta/namespace.json")
  let _ = s.get("ns/_segments/seg0/rows/id.bin")
  let c4 = s.cost()
  assert_eq(c4.s3_gets, 0)
  assert_eq(c4.bill_get, 0.0)
  assert_eq(c4.nvme_hits, 1)
}

///|
async test "LRU: capacity for 2 objects, third insert evicts least-recently-used" {
  let base = SimConfig::aws_default(6U)
  let cfg : SimConfig = { ..base, nvme_capacity_bytes: 250 } // 恰好装 2 个 100B 对象
  let s = SimStore::new(cfg)
  let k1 = "ns/_segments/segA/rows/id.bin"
  let k2 = "ns/_segments/segB/rows/id.bin"
  let k3 = "ns/_segments/segC/rows/id.bin"
  s.put(k1, Bytes::make(100, b'\x01'))
  s.put(k2, Bytes::make(100, b'\x02'))
  s.put(k3, Bytes::make(100, b'\x03')) // 300 > 250 → 逐出最久未用的 k1
  s.reset_cost()
  let _ = s.get(k2) // k2 仍在 NVMe
  let c1 = s.cost()
  assert_eq(c1.nvme_hits, 1)
  assert_eq(c1.s3_gets, 0)
  let _ = s.get(k1) // k1 被逐出 → S3 冷读
  let c2 = s.cost()
  assert_eq(c2.s3_gets, 1)
  assert_eq(c2.bytes_s3_read, 100)
  // 读回 k1 又超容量：k2 刚被摸过（recency 最新），k3 最旧 → k3 被逐出
  let _ = s.get(k3)
  let c3 = s.cost()
  assert_eq(c3.s3_gets, 2) // k3 已不在 NVMe → 又是冷读
  assert_eq(c3.nvme_hits, 1)
}

///|
async test "get_range: cold range billed once with range-length bytes, repeat hits" {
  let s = SimStore::new(SimConfig::aws_default(7U))
  let key = "ns/_segments/seg0/fts/postings.bin"
  s.put(key, Bytes::make(1000, b'\x09'))
  s.cold()
  s.reset_cost()
  let p1 = s.get_range(key, @store.ByteRange::{ off: 100, len: 50 })
  match p1 {
    Some(bytes) => {
      assert_eq(bytes.length(), 50)
      assert_eq(bytes[0], b'\x09')
    }
    None => fail("expected Some")
  }
  let c1 = s.cost()
  assert_eq(c1.s3_gets, 1) // 区间读计 1 次 GET 费
  assert_eq(c1.bytes_s3_read, 50) // bytes 口径 = 区间长度
  assert_eq(abs_f64(c1.bill_get - 0.0004 / 1000.0) < 1.0e-15, true)
  // 同区间再读 → ranges 命中，无 GET 费
  let _ = s.get_range(key, @store.ByteRange::{ off: 100, len: 50 })
  let c2 = s.cost()
  assert_eq(c2.s3_gets, 1)
  assert_eq(c2.bill_get, c1.bill_get)
  assert_eq(c2.nvme_hits, 1)
  assert_eq(c2.bytes_nvme_read, 50)
  // 未覆盖的新区间 → 又是冷读，再登记
  let _ = s.get_range(key, @store.ByteRange::{ off: 500, len: 60 })
  let c3 = s.cost()
  assert_eq(c3.s3_gets, 2)
  assert_eq(c3.bytes_s3_read, 110)
  // 整对象 get 不认区间缓存 → 冷读整对象（此后整对象命中）
  let _ = s.get(key)
  let c4 = s.cost()
  assert_eq(c4.s3_gets, 3)
  assert_eq(c4.bytes_s3_read, 1110)
  let _ = s.get(key)
  let c5 = s.cost()
  assert_eq(c5.s3_gets, 3)
  assert_eq(c5.nvme_hits, 2)
  assert_eq(c5.bill_get, c4.bill_get)
}

///|
async test "put_if_match CAS semantics match MemStore" {
  let s = SimStore::new(SimConfig::aws_default(8U))
  // 期望不存在时才能写入
  assert_eq(s.put_if_match("head", @store.Expected(None), b"v1"), true)
  // 已存在，期望 None → 冲突
  assert_eq(s.put_if_match("head", @store.Expected(None), b"v2"), false)
  // 错误版本 → 冲突
  assert_eq(s.put_if_match("head", @store.Expected(Some("v9")), b"v3"), false)
  assert_eq(s.get("head"), Some(b"v1"))
  // 正确版本 → 成功
  let cur = s.head_version("head")
  match cur {
    Some(v) => assert_eq(s.put_if_match("head", @store.Expected(Some(v)), b"v4"), true)
    None => fail("expected version")
  }
  assert_eq(s.get("head"), Some(b"v4"))
  // 每次尝试（4 次，含 2 次失败）都计 PUT 费
  let c = s.cost()
  assert_eq(c.puts, 4)
  assert_eq(abs_f64(c.bill_put - 4.0 * 0.005 / 1000.0) < 1.0e-12, true)
}

///|
async test "storage_monthly_bill: known bytes x 0.023 / 2^30 exact" {
  let s = SimStore::new(SimConfig::aws_default(9U))
  s.put("ns/_segments/segA/rows/id.bin", Bytes::make(1048576, b'\x0a')) // 1 MiB
  assert_eq(s.total_object_bytes(), 1048576)
  // 2^20 / 2^30 = 2^-10（精确的 2 的幂缩放）× 0.023
  assert_eq(s.storage_monthly_bill(), 0.023 / 1024.0)
  s.put("ns/_segments/segB/rows/id.bin", Bytes::make(1048576, b'\x0b'))
  assert_eq(s.total_object_bytes(), 2097152)
  assert_eq(s.storage_monthly_bill(), 0.023 / 512.0)
}

///|
async test "prime_nvme prefers small objects; oversized object never cached" {
  let base = SimConfig::aws_default(10U)
  let cfg : SimConfig = { ..base, nvme_capacity_bytes: 150 }
  let s = SimStore::new(cfg)
  let big1 = "ns/_segments/segA/rows/id.bin" // 100B
  let big2 = "ns/_segments/segB/rows/id.bin" // 100B
  let tiny = "ns/_segments/segC/fts/dir.bin" // 50B
  let huge = "ns/_segments/segD/rows/vec.bin" // 200B > 容量
  s.put(big1, Bytes::make(100, b'\x01'))
  s.put(big2, Bytes::make(100, b'\x02'))
  s.put(tiny, Bytes::make(50, b'\x03'))
  s.put(huge, Bytes::make(200, b'\x04'))
  s.prime_nvme()
  s.reset_cost()
  // 装入顺序（体积升序）：tiny(50) → big1(100)（150 满）；big2/huge 装不下
  let _ = s.get(tiny)
  let _ = s.get(big1)
  let c1 = s.cost()
  assert_eq(c1.nvme_hits, 2)
  assert_eq(c1.s3_gets, 0)
  let _ = s.get(big2) // 未装入 → 冷读
  let c2 = s.cost()
  assert_eq(c2.s3_gets, 1)
  // 单对象超容量：write-through 不缓存，冷读回填也不缓存（优先保留小对象）
  let _ = s.get(huge)
  let _ = s.get(huge)
  let c3 = s.cost()
  assert_eq(c3.s3_gets, 3)
}

///|
async test "egress billing is separate from request bill" {
  let base = SimConfig::aws_default(12U)
  let cfg : SimConfig = { ..base, egress_enabled: true }
  let s = SimStore::new(cfg)
  s.put("ns/_segments/seg0/rows/id.bin", Bytes::make(1048576, b'\x0d')) // 1 MiB
  s.cold()
  s.reset_cost()
  let _ = s.get("ns/_segments/seg0/rows/id.bin")
  let c = s.cost()
  // GET 请求费与出口费分开记；bill_total 是两者之和。
  assert_eq(abs_f64(c.bill_get - 0.0004 / 1000.0) < 1.0e-12, true)
  assert_eq(abs_f64(c.bill_egress - 0.09 / 1024.0) < 1.0e-12, true)
  assert_eq(
    abs_f64(c.bill_total - (0.0004 / 1000.0 + 0.09 / 1024.0)) < 1.0e-12,
    true,
  )
}

///|
async test "concurrency makespan models parallel fetches" {
  let base = SimConfig::aws_default(20U)
  let cfg : SimConfig = { ..base, concurrency: 4, nvme_capacity_bytes: 0 }
  let s = SimStore::new(cfg)
  for i in 0..<100 {
    s.put("obj/\{i}.bin", b"xxxxxxxx")
  }
  s.reset_cost()
  for i in 0..<100 {
    let _ = s.get("obj/\{i}.bin")
  }
  let c = s.cost()
  assert_eq(c.concurrent_latency_us < c.total_latency_us, true)
  // 4 worker 的 makespan 应远低于顺序累加（至少 2x 加速）
  assert_eq(c.total_latency_us / c.concurrent_latency_us > 2.0, true)
  // concurrency=1 时两者相等
  let base1 = SimConfig::aws_default(21U)
  let cfg1 : SimConfig = { ..base1, concurrency: 1, nvme_capacity_bytes: 0 }
  let s1 = SimStore::new(cfg1)
  s1.put("a.bin", b"x")
  s1.reset_cost()
  let _ = s1.get("a.bin")
  let c1 = s1.cost()
  assert_eq(c1.concurrent_latency_us, c1.total_latency_us)
}

///|
async test "latency injection: jitter/spike/retry deterministic" {
  let base = SimConfig::aws_default(30U)
  let cfg : SimConfig = {
    ..base,
    nvme_capacity_bytes: 0,
    wan_jitter_p50_us: 2000.0,
    spike_probability: 0.5,
    spike_p50_us: 50000.0,
    retry_probability: 0.5,
    retry_p50_us: 10000.0,
  }
  let mk = async fn() -> SimStore {
    let s = SimStore::new(cfg)
    s.put("warm", b"x")
    s.reset_cost()
    for i in 0..<100 {
      let _ = s.get("missing/\{i}.bin")
    }
    s
  }
  let s1 = mk()
  let s2 = mk()
  let c1 = s1.cost()
  let c2 = s2.cost()
  assert_eq(c1.total_latency_us, c2.total_latency_us)
  assert_eq(c1.retries, c2.retries)
  assert_eq(c1.retries > 0, true)
  // 额外延迟 + spike/retry 必须显著高于纯 TTFB
  assert_eq(c1.total_latency_us > 100.0 * 30000.0, true)
  // 关闭注入时行为与旧一致（0 额外延迟/0 retry）
  let plain = SimStore::new(SimConfig::aws_default(31U))
  plain.put("warm", b"x")
  plain.reset_cost()
  for i in 0..<100 {
    let _ = plain.get("missing/\{i}.bin")
  }
  let cp = plain.cost()
  assert_eq(cp.retries, 0)
  assert_eq(cp.total_latency_us < c1.total_latency_us, true)
}

///|
async test "egress billing: enabled S3 read adds separate bill_egress" {
  let base = SimConfig::aws_default(77U)
  let cfg : SimConfig = { ..base, egress_enabled: true }
  let s = SimStore::new(cfg)
  let key = "ns/_segments/seg0/rows/id.bin"
  s.put(key, Bytes::make(1048576, b'\x01')) // 1 MiB
  s.cold()
  s.reset_cost()
  let _ = s.get(key)
  let c = s.cost()
  assert_eq(c.s3_gets, 1)
  // 1 MiB / 1 GiB * $0.09 = 0.09 / 1024
  assert_eq(abs_f64(c.bill_egress - 0.09 / 1024.0) < 1.0e-15, true)
  assert_eq(c.bill_requests_total, 0.0004 / 1000.0)
  assert_eq(
    abs_f64(c.bill_total - (0.0004 / 1000.0 + 0.09 / 1024.0)) < 1.0e-15,
    true,
  )
}

///|
async test "fault injection: put/get/list/delete failures are counted and observable" {
  let base = SimConfig::aws_default(78U)
  let cfg : SimConfig = {
    ..base,
    put_error_probability: 1.0,
    get_error_probability: 1.0,
    list_error_probability: 1.0,
    delete_error_probability: 1.0,
  }
  let s = SimStore::new(cfg)
  let key = "ns/_segments/seg0/rows/id.bin"
  s.put(key, b"v")
  assert_eq(s.get(key), None)
  assert_eq(s.list("ns/"), [])
  s.delete(key)
  let c = s.cost()
  assert_eq(c.errors, 4) // put + get + list + delete
  // 失败请求仍然计费：1 PUT + 1 GET + 1 LIST + 1 DELETE
  assert_eq(c.puts, 1)
  assert_eq(c.s3_gets, 1)
  assert_eq(c.lists, 1)
  assert_eq(c.deletes, 1)
}

///|
async test "turbopuffer scan bill: 1.28GB minimum and $1/PB above it" {
  assert_eq(abs_f64(tpu_scan_bill(0) - 1.28e-6) < 1.0e-18, true)
  assert_eq(abs_f64(tpu_scan_bill(1024) - 1.28e-6) < 1.0e-18, true)
  let two_gb = 2000000000L
  let bill = tpu_scan_bill(two_gb)
  assert_eq(bill > 1.99e-6 && bill < 2.01e-6, true)
}

///|
async test "resident disabled: _meta/ falls through to S3 (s3_gets grows)" {
  let s = SimStore::new(SimConfig::aws_default(50U))
  s.put("ns/_meta/namespace.json", b"meta")
  // resident enabled：内存档，不打 S3
  s.reset_cost()
  let _ = s.get("ns/_meta/namespace.json")
  assert_eq(s.cost().s3_gets, 0)
  // 关闭后同一 SimStore 上 _meta/ 也走 S3；set_resident_enabled(false)
  // 会 evict resident 类，下面的 cold() 只是清数据面，不是必须的。
  s.set_resident_enabled(false)
  s.cold()
  s.reset_cost()
  let _ = s.get("ns/_meta/namespace.json")
  let c1 = s.cost()
  assert_eq(c1.s3_gets, 1)
  assert_eq(c1.nvme_hits, 0) // 冷读，首次必打 S3
  assert_eq(c1.total_latency_us == 2.0, false) // 不再是 mem_us
  // resident miss 也不再是内存档：404 也是真实 S3 GET
  let _ = s.get("ns/_meta/nope.json")
  assert_eq(s.cost().s3_gets, 2)
  // get_range 同样穿透（cold 后无 NVMe/区间缓存）
  s.cold()
  let _ = s.get_range("ns/_meta/namespace.json", @store.ByteRange::{ off: 0, len: 2 })
  assert_eq(s.cost().s3_gets, 3)
  // 重新打开恢复内存档
  s.set_resident_enabled(true)
  s.reset_cost()
  let _ = s.get("ns/_meta/namespace.json")
  let c2 = s.cost()
  assert_eq(c2.s3_gets, 0)
  assert_eq(c2.total_latency_us, 2.0)
}

///|
async test "require_latency: aws_default passes, zero TTFB raises Corrupt" {
  let s = SimStore::new(SimConfig::aws_default(51U))
  assert_eq(SimConfig::aws_default(51U).latency_ready(), true)
  let ok = try {
    s.require_latency()
    true
  } catch {
    _ => false
  }
  assert_eq(ok, true)
  let base = SimConfig::aws_default(51U)
  let cfg : SimConfig = { ..base, s3_get_ttfb_p50_us: 0.0 }
  assert_eq(cfg.latency_ready(), false)
  let s0 = SimStore::new(cfg)
  let raised = try {
    s0.require_latency()
    false
  } catch {
    @core.Corrupt(msg) => msg.has_prefix("SimStore latency disabled")
    _ => false
  }
  assert_eq(raised, true)
  // 并发度 < 1 同样不满足前提
  let cfg2 : SimConfig = { ..base, concurrency: 0 }
  assert_eq(cfg2.latency_ready(), false)
}

///|
async test "admit_all is a synonym for prime_nvme; label marks all-hot" {
  let mk = async fn() -> SimStore {
    let base = SimConfig::aws_default(52U)
    let cfg : SimConfig = { ..base, nvme_capacity_bytes: 150 }
    let s = SimStore::new(cfg)
    s.put("ns/_segments/segA/rows/id.bin", Bytes::make(100, b'\x01'))
    s.put("ns/_segments/segB/rows/id.bin", Bytes::make(100, b'\x02'))
    s.put("ns/_segments/segC/fts/dir.bin", Bytes::make(50, b'\x03'))
    s
  }
  let s1 = mk()
  let s2 = mk()
  s1.prime_nvme()
  s2.admit_all()
  s1.reset_cost()
  s2.reset_cost()
  for k in [
    "ns/_segments/segC/fts/dir.bin", // 先读已装入的两个，再读未装入的
    "ns/_segments/segA/rows/id.bin",
    "ns/_segments/segB/rows/id.bin",
  ] {
    let _ = s1.get(k)
    let _ = s2.get(k)
  }
  let c1 = s1.cost()
  let c2 = s2.cost()
  // 容量 150：只装得下 tiny(50) + 一个 100B → 两次命中、一次冷读，两者完全一致
  assert_eq(c1.nvme_hits, 2)
  assert_eq(c1.s3_gets, 1)
  assert_eq(c1.nvme_hits, c2.nvme_hits)
  assert_eq(c1.s3_gets, c2.s3_gets)
  assert_eq(c1.total_latency_us, c2.total_latency_us)
  // 标签直接供 benchmark 打标
  assert_eq(
    SimStore::admit_all_label(),
    "all-hot (synthetic upper bound, not a workload-achievable warm state)",
  )
}

///|
async test "cache_stats: five fields incl nvme_hits sane around hits" {
  let s = SimStore::new(SimConfig::aws_default(53U))
  let key = "ns/_segments/seg0/rows/id.bin"
  s.put(key, Bytes::make(100, b'\x01'))
  s.cold()
  s.reset_cost()
  let (n0, b0, r0, l0, h0, nb0) = s.cache_stats()
  assert_eq(n0, 0)
  assert_eq(b0, 0)
  assert_eq(r0, 0)
  assert_eq(l0, 0)
  assert_eq(h0, 0)
  assert_eq(nb0, 0)
  // 冷读：1 次 S3、100 逻辑字节、回填后 nvme 1 对象 / 100 字节
  let _ = s.get(key)
  let (n1, b1, r1, l1, h1, nb1) = s.cache_stats()
  assert_eq(n1, 1)
  assert_eq(b1, 100)
  assert_eq(r1, 1)
  assert_eq(l1, 100)
  assert_eq(h1, 0)
  assert_eq(nb1, 0)
  // 命中：S3 读数不变，逻辑读翻倍（每次逻辑读摊到的 S3 读远小于 1）
  let _ = s.get(key)
  let (n2, b2, r2, l2, h2, nb2) = s.cache_stats()
  assert_eq(n2, 1)
  assert_eq(b2, 100)
  assert_eq(r2, 1)
  assert_eq(l2, 200)
  assert_eq(h2, 1)
  assert_eq(nb2, 100)
}

///|
async test "resident disabled: put does not re-admit resident key into NVMe" {
  let s = SimStore::new(SimConfig::aws_default(54U))
  s.set_resident_enabled(false)
  s.reset_cost()
  s.put("ns/_meta/namespace.json", b"meta")
  // 写入后不应在 NVMe；紧接着 get 必须走 S3
  let c0 = s.cost()
  let (n0, _, _, _, _, _) = s.cache_stats()
  assert_eq(n0, 0)
  let _ = s.get("ns/_meta/namespace.json")
  let c1 = s.cost()
  assert_eq(c1.s3_gets > c0.s3_gets, true)
  s.set_resident_enabled(true)
}

///|
async test "multicloud profiles and Class A/B request accounting" {
  let s_r2 = SimStore::new(SimConfig::cloudflare_r2(60U))
  s_r2.put("ns/_parts/part1.cpt", Bytes::make(1024, b'\x01'))
  s_r2.put("ns/_manifest/manifest-1.json", Bytes::make(256, b'\x02'))
  let _ = s_r2.list("ns/_manifest/")
  s_r2.cold()
  let _ = s_r2.get("ns/_parts/part1.cpt")
  let c_r2 = s_r2.cost()

  // Class A: 2 puts + 1 list = 3
  assert_eq(c_r2.class_a_ops, 3)
  assert_eq(c_r2.puts, 2)
  assert_eq(c_r2.lists, 1)
  // Class B: 1 get = 1
  assert_eq(c_r2.class_b_ops, 1)
  assert_eq(c_r2.s3_gets, 1)
  // R2 费率：A 类 $4.50/M ($0.0045/1k), B 类 $0.36/M ($0.00036/1k), 出口流量费 $0
  let expected_a = 3.0 * (0.0045 / 1000.0)
  let expected_b = 1.0 * (0.00036 / 1000.0)
  assert_eq(abs_f64(c_r2.bill_class_a - expected_a) < 1.0e-9, true)
  assert_eq(abs_f64(c_r2.bill_class_b - expected_b) < 1.0e-9, true)
  assert_eq(c_r2.bill_egress, 0.0)
  assert_eq(c_r2.max_latency_us > 0.0, true)
}

///|
async test "cache remote delay factor injects S3-representative latency on cache hits" {
  // 零远端延迟注入配置
  let s_local = SimStore::new(SimConfig::aws_default(61U))
  s_local.put("ns/_meta/namespace.json", b"local_meta")
  s_local.reset_cost()
  let _ = s_local.get("ns/_meta/namespace.json")
  let c_local = s_local.cost()
  // 纯本地内存常驻命中延迟恰好为 mem_us (2.0 µs)
  assert_eq(c_local.total_latency_us, 2.0)

  // 开启 S3 等效远端延迟注入（factor = 1.0）
  let base = SimConfig::aws_default(62U)
  let cfg_remote : SimConfig = { ..base, cache_remote_delay_factor: 1.0 }
  let s_remote = SimStore::new(cfg_remote)
  s_remote.put("ns/_meta/namespace.json", b"remote_meta")
  s_remote.reset_cost()
  let _ = s_remote.get("ns/_meta/namespace.json")
  let c_remote = s_remote.cost()
  // 注入了等效 S3 延迟后，延迟应在毫秒级别（> 10,000 µs），真实反映网络环境
  assert_eq(c_remote.total_latency_us > 10000.0, true)
  assert_eq(c_remote.max_latency_us > 10000.0, true)
}

///|
async test "extreme tail latency injection: 1s long tail spikes properly simulated" {
  let s_tail = SimStore::new(SimConfig::extreme_tail(999U))
  // 写入 100 个对象并清空缓存，执行 100 次冷读
  for i in 0..<100 {
    s_tail.put("ns/_parts/part_\{i}.cpt", Bytes::make(200, b'\x09'))
  }
  s_tail.cold()
  s_tail.reset_cost()

  for i in 0..<100 {
    let _ = s_tail.get("ns/_parts/part_\{i}.cpt")
  }
  let c = s_tail.cost()
  assert_eq(c.s3_gets, 100)
  // 在 5% 的 1 秒长尾注入下，max_latency_us 必然突破 500ms（> 500,000 µs）
  assert_eq(c.max_latency_us > 500000.0, true)
}
