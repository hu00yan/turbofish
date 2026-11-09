// SimStore 白盒测试（NOTES2.md 第 6 节工人 S 验收标准）：
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
fn drive_mixed_ops(s : SimStore) -> Unit {
  s.put("ns/_meta/namespace.json", b"m")
  s.put("ns/_segments/seg0/rows/id.bin", Bytes::make(4096, b'\x05'))
  s.put("ns/_segments/seg0/fts/postings.bin", Bytes::make(70000, b'\x06'))
  s.cold()
  let _ = s.get("ns/_segments/seg0/rows/id.bin")
  let _ = s.get_range("ns/_segments/seg0/fts/postings.bin", 16, 1000)
  let _ = s.get("ns/_meta/namespace.json")
  let _ = s.list("ns/_segments/")
  s.delete("ns/_segments/seg0/rows/id.bin")
}

///|
test "billing exact: 1000 S3 GETs = $0.0004" {
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
test "billing exact: 1000 PUTs = $0.005; CAS failure also billed" {
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
  assert_eq(s.put_if_match("ns/_segments/seg0/rows/id.bin", Some("v999"), b"x"), false)
  let c2 = s.cost()
  assert_eq(c2.puts, 1)
  assert_eq(abs_f64(c2.bill_put - 0.005 / 1000.0) < 1.0e-12, true)
}

///|
test "billing exact: 1000 LISTs = $0.0025; DELETE default rate zero" {
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
test "resident & NVMe hits incur no GET bill" {
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
test "latency determinism: same seed identical, different seed differs" {
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
test "lognormal sampling: p50 within 20% of config, p99/p50 ratio in [2, 4.5]" {
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
test "three-tier: resident mem_us exact, cold read, NVMe warm, cold(), prime_nvme()" {
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
  let _ = s.get_range("ns/_meta/namespace.json", 0, 2)
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
  assert_eq(c1.total_latency_us > 5000.0 && c1.total_latency_us < 200000.0, true)
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
test "LRU: capacity for 2 objects, third insert evicts least-recently-used" {
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
test "get_range: cold range billed once with range-length bytes, repeat hits" {
  let s = SimStore::new(SimConfig::aws_default(7U))
  let key = "ns/_segments/seg0/fts/postings.bin"
  s.put(key, Bytes::make(1000, b'\x09'))
  s.cold()
  s.reset_cost()
  let p1 = s.get_range(key, 100, 50)
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
  let _ = s.get_range(key, 100, 50)
  let c2 = s.cost()
  assert_eq(c2.s3_gets, 1)
  assert_eq(c2.bill_get, c1.bill_get)
  assert_eq(c2.nvme_hits, 1)
  assert_eq(c2.bytes_nvme_read, 50)
  // 未覆盖的新区间 → 又是冷读，再登记
  let _ = s.get_range(key, 500, 60)
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
test "put_if_match CAS semantics match MemStore" {
  let s = SimStore::new(SimConfig::aws_default(8U))
  // 期望不存在时才能写入
  assert_eq(s.put_if_match("head", None, b"v1"), true)
  // 已存在，期望 None → 冲突
  assert_eq(s.put_if_match("head", None, b"v2"), false)
  // 错误版本 → 冲突
  assert_eq(s.put_if_match("head", Some("v9"), b"v3"), false)
  assert_eq(s.get("head"), Some(b"v1"))
  // 正确版本 → 成功
  let cur = s.head_version("head")
  match cur {
    Some(v) => assert_eq(s.put_if_match("head", Some(v), b"v4"), true)
    None => fail("expected version")
  }
  assert_eq(s.get("head"), Some(b"v4"))
  // 每次尝试（4 次，含 2 次失败）都计 PUT 费
  let c = s.cost()
  assert_eq(c.puts, 4)
  assert_eq(abs_f64(c.bill_put - 4.0 * 0.005 / 1000.0) < 1.0e-12, true)
}

///|
test "storage_monthly_bill: known bytes x 0.023 / 2^30 exact" {
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
test "prime_nvme prefers small objects; oversized object never cached" {
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
test "egress billing folds into bill_get when enabled" {
  let base = SimConfig::aws_default(12U)
  let cfg : SimConfig = { ..base, egress_enabled: true }
  let s = SimStore::new(cfg)
  s.put("ns/_segments/seg0/rows/id.bin", Bytes::make(1048576, b'\x0d')) // 1 MiB
  s.cold()
  s.reset_cost()
  let _ = s.get("ns/_segments/seg0/rows/id.bin")
  let c = s.cost()
  // GET 请求费 + (1/1024) GB × $0.09
  let expected = 0.0004 / 1000.0 + 0.09 / 1024.0
  assert_eq(abs_f64(c.bill_get - expected) < 1.0e-12, true)
}
