// simcluster 白盒测试：确定性 + 四条架构不变量。
//
// 1. 同 seed 两次仿真逐字节相等（JSON 全字段），换 seed 才变化；
// 2. async_io=true 的查询 p95 至少比同步 IO 快 3 倍（S3 等待不再霸占 CPU）；
// 3. dedicated_compactd=true 的 p99 至少比把压缩压在 serve 进程上快 3 倍；
// 4. 25ms 组提交的月 PUT 费不到直写的 1/10；
// 5. 4 进程相对 1 进程的吞吐至少 2.8 倍。

///|
fn test_rates() -> @simstore.BillRates {
  @simstore.BillRates::aws_default()
}

///|
/// 只读、无压缩、无组提交的基准配置（隔离 async_io 变量）。
fn read_only_cfg(async_io : Bool) -> ClusterSimConfig {
  let base = ClusterSimConfig::modern(test_rates())
  {
    ..base,
    async_io,
    group_commit_window_us: 0.0,
    dedicated_compactd: true,
  }
}

///|
/// 读 + 写、压缩内联 / 独立两种配置（隔离 dedicated_compactd 变量）。
fn write_mix_cfg(dedicated : Bool) -> ClusterSimConfig {
  let base = ClusterSimConfig::modern(test_rates())
  {
    ..base,
    async_io: true,
    group_commit_window_us: 0.0,
    dedicated_compactd: dedicated,
  }
}

///|
test "same seed is byte-identical, different seed diverges" {
  let cfg = ClusterSimConfig::modern(test_rates())
  let wl = WorkloadSpec::kv_mixed()
  let a = run_cluster_sim(cfg, wl)
  let b = run_cluster_sim(cfg, wl)
  assert_eq(a.to_json_string(), b.to_json_string())
  assert_eq(a.query_p99_ms, b.query_p99_ms)
  assert_eq(a.total_s3_gets, b.total_s3_gets)
  assert_eq(a.total_s3_puts, b.total_s3_puts)
  assert_eq(a.monthly_total_usd, b.monthly_total_usd)
  let c = run_cluster_sim(cfg, wl, seed=7U)
  assert_true(a.to_json_string() != c.to_json_string())
  // 显式 seed 覆盖同样确定
  let d = run_cluster_sim(cfg, wl, seed=7U)
  assert_eq(c.to_json_string(), d.to_json_string())
}

///|
test "async_io makes p95 at least 3x faster" {
  let wl : WorkloadSpec = {
    ..WorkloadSpec::kv_mixed(),
    duration_sec: 30.0,
    query_qps: 400.0,
    write_rps: 0.0,
    l0_delta_count: 0,
    cache_hit_ratio: 0.5,
  }
  let sync = run_cluster_sim(read_only_cfg(false), wl)
  let async_ = run_cluster_sim(read_only_cfg(true), wl)
  // 同步 IO：每个冷读的 TTFB 整段霸占进程 CPU → 过载排队，p95 秒级
  // 异步 IO：等待只占 slot，命中查询插空 → p95 只受 S3 尾部与 slot 排队影响
  assert_true(
    async_.query_p95_ms * 3.0 <= sync.query_p95_ms,
  )
  assert_true(async_.query_p95_ms < 200.0)
  // 同步模式下瓶颈必须被判成"事件循环被阻塞"，而不是笼统的 cpu_bound
  assert_eq(sync.bottleneck, "event_loop_blocked")
}

///|
test "dedicated compactd keeps p99 stable" {
  let wl : WorkloadSpec = {
    ..WorkloadSpec::kv_mixed(),
    duration_sec: 20.0,
    query_qps: 200.0,
    write_rps: 50.0,
    rows_per_write: 100,
    l0_delta_count: 6,
    cache_hit_ratio: 1.0,
  }
  let inline = run_cluster_sim(write_mix_cfg(false), wl)
  let dedicated = run_cluster_sim(write_mix_cfg(true), wl)
  assert_true(dedicated.compaction_events > 0)
  assert_eq(inline.compaction_events, dedicated.compaction_events)
  // 内联压缩：一次 180ms 的合并直接把 serve CPU 锁死，p99 被拖到百毫秒级
  assert_true(dedicated.query_p99_ms * 3.0 <= inline.query_p99_ms)
  assert_true(dedicated.query_p99_ms < 50.0)
  assert_true(inline.query_p99_ms > 100.0)
}

///|
test "25ms group commit cuts monthly PUT bill below 1/10" {
  let wl = WorkloadSpec::write_heavy(10.0, 3000.0, 1)
  let direct = run_cluster_sim(write_mix_cfg(true), wl)
  let base = write_mix_cfg(true)
  let grouped = run_cluster_sim(
    { ..base, group_commit_window_us: 25000.0 },
    wl,
  )
  // 直写：每写 1 次 PUT；组提交：每 25ms 窗口 3 次 PUT
  assert_eq(direct.total_s3_puts, 30000)
  assert_true(grouped.total_s3_puts < 3000)
  assert_true(grouped.monthly_s3_put_usd * 10.0 < direct.monthly_s3_put_usd)
  // 合并写入也把写延迟的尾部压下来了（同窗口内的请求共享一次提交）
  assert_true(grouped.write_p99_ms < direct.write_p99_ms)
}

///|
test "4 processes scale throughput at least 2.8x" {
  let heavy : CpuProfile = {
    ..CpuProfile::default_profile(),
    bm25_posting_ns: 400.0,
  }
  let wl = WorkloadSpec::cpu_bound_reads(10.0, 4000.0, 1000000)
  let one = ClusterSimConfig::modern(test_rates())
  let single = run_cluster_sim(
    {
      ..one,
      serve_processes: 1,
      cpu: heavy,
      group_commit_window_us: 0.0,
    },
    wl,
  )
  let quad = run_cluster_sim(
    {
      ..one,
      serve_processes: 4,
      cpu: heavy,
      group_commit_window_us: 0.0,
    },
    wl,
  )
  // 纯 CPU 负载：单进程被算力顶住，4 进程接近线性扩展
  assert_true(single.bottleneck == "cpu_bound")
  assert_true(quad.achieved_qps >= single.achieved_qps * 2.8)
}

///|
test "report renders summary table and json fields" {
  let r = run_cluster_sim(
    ClusterSimConfig::modern(test_rates()),
    WorkloadSpec::kv_mixed(),
  )
  let t = r.format_summary_table()
  assert_true(t.contains("query p99 (ms)"))
  assert_true(t.contains("monthly total (usd)"))
  assert_true(t.contains(r.bottleneck))
  let j = r.to_json_string()
  assert_true(j.contains("\"query_p99_ms\""))
  assert_true(j.contains("\"monthly_s3_put_usd\""))
  assert_true(j.contains("\"bottleneck\""))
  // 百分位单调
  assert_true(r.query_p50_ms <= r.query_p95_ms)
  assert_true(r.query_p95_ms <= r.query_p99_ms)
  // 成本可加
  let sum = r.monthly_s3_get_usd +
    r.monthly_s3_put_usd +
    r.monthly_storage_usd +
    r.monthly_compute_usd
  assert_true(sum > 0.0)
  assert_true((sum - r.monthly_total_usd) < 1.0e-6)
}
